import AVFoundation
import AudioToolbox
import Darwin
import Foundation

// ============================================================================
// BTOutputEngine — T3: one AVAudioEngine pinned to a single Bluetooth output
// device, looping the shared ToneSource buffer (T4) through a per-device
// delay line and volume, so T5/T6 can drive N of these concurrently (one per
// paired BT speaker) and compare their behavior.
//
// Graph: player -> delay (pure delay line, wetDryMix=100) -> mainMixer -> output
// Output is pinned via outputNode.auAudioUnit.setDeviceID (pattern: LocalPlaybackEngine
// ~609-624/618). Start-before-play is guarded on engine.isRunning (pattern ~413-425)
// so a config-change race can never reach the uncatchable `play()` abort.
// ============================================================================

enum BTOutputEngineError: Error, CustomStringConvertible {
    case setDeviceIDFailed(OSStatus)
    case engineStartFailed(Error)
    case engineNotRunning

    var description: String {
        switch self {
        case .setDeviceIDFailed(let status): return "setDeviceID failed, status=\(status)"
        case .engineStartFailed(let error): return "engine.start() failed: \(error)"
        case .engineNotRunning: return "engine not running after start"
        }
    }
}

/// A snapshot of how many frames this device's engine has actually pushed to
/// its output tap, paired with a monotonic host-time stamp at the moment that
/// count was last updated. T5 diffs two devices' snapshots over the same wall
/// window to read real per-device clock drift (BT devices don't share a clock
/// the way AirPlay 2's PTP does).
struct BTRenderStats {
    let frames: UInt64
    let hostTimeNanos: UInt64
}

/// A reading of this device's REAL hardware DAC timeline — the sample position
/// its converter has actually clocked out, paired with the host-time (mach,
/// converted to nanoseconds) at which that position was current. This is the
/// definitive per-device clock the drift readout needs: unlike the software
/// render tap (which fires at the NOMINAL AVAudioEngine render rate and stamps
/// jittery callback-dispatch times), `mSampleTime` advances at the DAC's own
/// slightly-off-nominal rate, so `(ΔmSampleTime / ΔhostSeconds)` is the
/// speaker's true effective sample rate. `nominalRate` is the device's own
/// configured nominal rate (read at pin time, NOT assumed 44.1k). `valid` is
/// false when neither the query nor the fallback IOProc has produced a usable
/// timestamp yet (e.g. the very first call before the fallback's first fire).
struct BTDeviceClock {
    let mSampleTime: Double
    let hostTimeNanos: UInt64
    let nominalRate: Double
    let valid: Bool
}

final class BTOutputEngine {
    let deviceID: AudioObjectID
    let deviceName: String
    private let mode: ToneSourceMode

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let delay = AVAudioUnitDelay()

    // All graph mutation (pin/attach/connect/start/stop/config-change recovery)
    // is serialized here, mirroring LocalPlaybackEngine's graphQueue.
    private let graphQueue = DispatchQueue(label: "bt-multi-spike.BTOutputEngine.graph")
    private var isPinned = false
    private var isRunningTracked = false
    private var configObserver: NSObjectProtocol?
    private var tapInstalled = false

    private let statsLock = NSLock()
    private var renderedFrames: UInt64 = 0
    private var lastStampNanos: UInt64 = 0

    // MARK: Real-DAC-clock state (drift readout — see BTDeviceClock)
    // The device's OWN nominal sample rate, read once at pin time (NOT assumed
    // 44.1k). Set on graphQueue in setDeviceIDOnGraphQueue; read as a plain
    // Double snapshot from currentDeviceClock().
    private var deviceNominalRate: Double = ToneSource.sampleRate
    // Lazy timing-only IOProc fallback, used ONLY when the primary
    // AudioDeviceGetCurrentTime query errors while the engine drives the device.
    // `installLock` guards create/destroy of the IOProc (idempotent lazy init +
    // teardown); `clockLock` guards the three data fields the RT block writes.
    // They are DISTINCT locks on purpose: the RT block only ever takes clockLock,
    // so holding installLock across AudioDeviceStart (which may begin firing the
    // block before it returns) can never deadlock against it.
    private let installLock = NSLock()
    private let clockLock = NSLock()
    private var timingIOProcID: AudioDeviceIOProcID?
    private var fallbackSampleTime: Double = 0
    private var fallbackHostTimeNanos: UInt64 = 0
    private var fallbackValid = false
    // RMS accumulator over "since last drain" window — T5's --selftest and
    // the interactive loop drain this periodically rather than reading a
    // running total, so a stale/never-reset "it was loud once" can't pass as
    // "it's flowing now".
    private var sumSquares: Double = 0
    private var squaredSampleCount: UInt64 = 0

    init(deviceID: AudioObjectID, deviceName: String, mode: ToneSourceMode = .tone) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.mode = mode
        buildGraph()
        observeConfigurationChanges()
    }

    deinit {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
        stop()
        // stop() already tears the IOProc down; call again unconditionally so a
        // path that reached deinit without a clean stop() still can't leak it.
        teardownTimingIOProc()
    }

    // MARK: - Graph setup (attach/connect only — no device pin, no start yet)

    private func buildGraph() {
        engine.attach(player)
        engine.attach(delay)
        // Pure delay line: 100% wet (delayed) signal out, no feedback (no
        // repeat/echo tail) — this is a variable-latency pass-through, not an
        // effect.
        delay.wetDryMix = 100
        delay.feedback = 0
        delay.delayTime = 0

        let format = ToneSource.format
        engine.connect(player, to: delay, format: format)
        engine.connect(delay, to: engine.mainMixerNode, format: format)
    }

    /// Pin the engine's output to `deviceID` (once). MUST run on `graphQueue`,
    /// before the first `engine.start()` — pattern: LocalPlaybackEngine
    /// .configureBuiltInOutput/~609-624.
    private func setDeviceIDOnGraphQueue() throws {
        guard !isPinned else { return }
        do {
            try engine.outputNode.auAudioUnit.setDeviceID(deviceID)
            isPinned = true
            // Read the device's OWN nominal sample rate once, here — different
            // BT DACs report different nominal rates and we must NOT assume the
            // 44.1k the tone source happens to use, or every drift figure is
            // scaled against the wrong denominator.
            if let rate = BTOutputEngine.readNominalSampleRate(deviceID) {
                deviceNominalRate = rate
            }
            log("pinned to deviceID=\(deviceID) nominalRate=\(deviceNominalRate)")
        } catch {
            log("setDeviceID(\(deviceID)) FAILED: \(error)")
            throw error
        }
    }

    private func installRenderTapOnGraphQueue() {
        guard !tapInstalled else { return }
        tapInstalled = true
        // NOTE: installTap on engine.outputNode itself throws AVFAudio's
        // uncatchable "_isInput" NSException at install time (discovered live
        // by T5's --selftest, both with outputFormat(forBus:) and
        // inputFormat(forBus:)) — the hardware sink node doesn't support a
        // tap the way a regular graph node does. Tap mainMixerNode instead:
        // it's the last node before the (pinned) output node, so a fired
        // callback with non-zero frames is still proof the graph rendered
        // audio all the way up to the device hand-off, which is the signal
        // this exists to catch (a silent no-op pin).
        let tapFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let frames = UInt64(buffer.frameLength)
            let now = DispatchTime.now().uptimeNanoseconds

            var sum: Double = 0
            var count: UInt64 = 0
            if let channels = buffer.floatChannelData {
                let channelCount = Int(buffer.format.channelCount)
                let frameLength = Int(buffer.frameLength)
                for ch in 0..<channelCount {
                    let data = channels[ch]
                    for frame in 0..<frameLength {
                        let s = Double(data[frame])
                        sum += s * s
                        count += 1
                    }
                }
            }

            self.statsLock.lock()
            self.renderedFrames += frames
            self.lastStampNanos = now
            self.sumSquares += sum
            self.squaredSampleCount += count
            self.statsLock.unlock()
        }
    }

    // MARK: - Start / stop

    func start() throws {
        try graphQueue.sync {
            guard !isRunningTracked else { return }
            try setDeviceIDOnGraphQueue()
            installRenderTapOnGraphQueue()

            _ = engine.mainMixerNode
            engine.prepare()
            do {
                try engine.start()
            } catch {
                log("engine.start() FAILED: \(error)")
                throw BTOutputEngineError.engineStartFailed(error)
            }
            isRunningTracked = engine.isRunning
            log("start done isRunning=\(engine.isRunning)")

            // NEVER call play() on a stopped engine — AVAudioPlayerNode.play()
            // asserts engine->IsRunning() and aborts the whole process (an
            // uncatchable exception) if it isn't. Pattern: LocalPlaybackEngine
            // .addApp ~413-425.
            guard engine.isRunning else {
                throw BTOutputEngineError.engineNotRunning
            }
            scheduleLoopOnGraphQueue()
            player.play()
        }
    }

    func stop() {
        // Tear the timing-only fallback IOProc down FIRST — it's independent of
        // the AVAudioEngine graph and idempotent, so it's safe here even if the
        // engine wasn't running. Must pair exactly with ensureTimingIOProc().
        teardownTimingIOProc()
        graphQueue.sync {
            guard isRunningTracked || engine.isRunning else { return }
            player.stop()
            engine.stop()
            isRunningTracked = false
            log("stopped")
        }
    }

    private func scheduleLoopOnGraphQueue() {
        let buffer = ToneSource.makeBuffer(for: mode)
        player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
    }

    // MARK: - Live-adjustable per-device delay (ms) and volume

    /// Sets the pure-delay-line latency in milliseconds. Safe to call while
    /// playing — AVAudioUnitDelay.delayTime is a live-settable AU parameter,
    /// not a graph mutation. Clamped to AVAudioUnitDelay's supported range
    /// (0...2 seconds).
    func setDelay(ms: Double) {
        let seconds = max(0, min(2, ms / 1000.0))
        delay.delayTime = seconds
    }

    /// Sets per-device output volume (0...1). Safe to call while playing —
    /// AVAudioPlayerNode.volume is a live-settable property, not a graph
    /// mutation (pattern: LocalPlaybackEngine.setVolume).
    func setVolume(_ volume: Float) {
        player.volume = min(1, max(0, volume))
    }

    /// Restart the looped source so it begins exactly at `when` — a host time
    /// shared across every engine — phase-locking all devices' click/tone grids
    /// to one instant. After a resync, any remaining click offset between
    /// speakers is their REAL per-device latency (plus whatever per-device delay
    /// is dialed in), not the arbitrary gap between when each device was added.
    /// Safe to call while playing; a no-op if this engine isn't running.
    func restartLoop(at when: AVAudioTime) {
        graphQueue.sync {
            guard isRunningTracked, engine.isRunning else { return }
            player.stop()
            let buffer = ToneSource.makeBuffer(for: mode)
            player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
            player.play(at: when)
        }
    }

    // MARK: - Drift instrumentation (T5)

    /// Frames actually rendered through this device's output tap, paired with
    /// a monotonic host-time stamp of the last tap fire. T5 samples this on
    /// two-plus devices at the same wall-clock moment and compares the
    /// frames/time ratio to read real clock drift between BT speakers.
    func currentRenderStats() -> BTRenderStats {
        statsLock.lock()
        defer { statsLock.unlock() }
        return BTRenderStats(frames: renderedFrames, hostTimeNanos: lastStampNanos)
    }

    /// Which of `currentDeviceClock()`'s two paths most recently produced its
    /// returned reading. Both paths read the same real DAC timeline — this is
    /// diagnostic only (not part of the drift math) — surfaced so T2's
    /// `--drift-selftest` can report which path this Mac actually exercised.
    enum ClockPath: CustomStringConvertible {
        case query
        case ioProcFallback
        case unavailable

        var description: String {
            switch self {
            case .query: return "query"
            case .ioProcFallback: return "ioproc-fallback"
            case .unavailable: return "n/a"
            }
        }
    }
    private(set) var lastClockPath: ClockPath = .unavailable

    /// The device's DEFINITIVE hardware DAC clock (see `BTDeviceClock`).
    /// Query-first with a lazy IOProc fallback — both read the same real DAC
    /// timeline; the fallback is only a safer way to obtain it if the direct
    /// query refuses.
    ///
    /// PRIMARY: `AudioDeviceGetCurrentTime` hands back the device's current
    /// `AudioTimeStamp` directly. We require both the sample-time and host-time
    /// valid flags, then convert `mHostTime` (mach ticks) to nanoseconds so the
    /// caller can diff two devices on one common time axis.
    ///
    /// FALLBACK: if the query errors (e.g. `kAudioHardwareNotRunningError` in a
    /// window where the HAL won't answer a bare query even though the engine is
    /// driving the device), we lazily attach a timing-only IOProc — it does
    /// nothing but record the callback timestamp's `mSampleTime`/`mHostTime`
    /// under `clockLock` on the HAL's real-time thread — and return its last
    /// recorded pair.
    func currentDeviceClock() -> BTDeviceClock {
        let rate = deviceNominalRate

        var ts = AudioTimeStamp()
        let status = AudioDeviceGetCurrentTime(deviceID, &ts)
        if status == noErr,
           ts.mFlags.contains(.sampleTimeValid),
           ts.mFlags.contains(.hostTimeValid) {
            let nanos = BTOutputEngine.machHostTimeToNanos(ts.mHostTime)
            lastClockPath = .query
            return BTDeviceClock(
                mSampleTime: ts.mSampleTime,
                hostTimeNanos: nanos,
                nominalRate: rate,
                valid: true)
        }

        // Query didn't give us a usable timestamp — fall back to the IOProc.
        ensureTimingIOProc()
        clockLock.lock()
        let sampleTime = fallbackSampleTime
        let hostNanos = fallbackHostTimeNanos
        let ok = fallbackValid
        clockLock.unlock()
        lastClockPath = ok ? .ioProcFallback : .unavailable
        return BTDeviceClock(
            mSampleTime: sampleTime,
            hostTimeNanos: hostNanos,
            nominalRate: rate,
            valid: ok)
    }

    // MARK: - Real-DAC-clock helpers

    /// The device's configured nominal sample rate, or nil if it can't be read.
    private static func readNominalSampleRate(_ device: AudioObjectID) -> Double? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var rate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        let err = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &rate)
        guard err == noErr, rate > 0 else { return nil }
        return rate
    }

    /// The mach timebase, read once (it never changes over a process's life).
    private static let machTimebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb
    }()

    /// mach host ticks -> nanoseconds on the mach-absolute timescale. We keep
    /// both device timestamps in this ONE domain and diff them against each
    /// other, so (unlike the NativeCaptureCoordinator path that must rebase onto
    /// CLOCK_MONOTONIC for the vendored receiver) no monotonic rebase is needed
    /// here — only the tick->ns scale matters for a rate ratio.
    private static func machHostTimeToNanos(_ hostTime: UInt64) -> UInt64 {
        let tb = machTimebase
        return hostTime &* UInt64(tb.numer) / UInt64(max(1, tb.denom))
    }

    /// Lazily attach a timing-only IOProc as the DAC-clock fallback. Idempotent;
    /// serialized by `installLock`. The block runs on a HAL real-time thread —
    /// it allocates nothing, takes only `clockLock`, stores two numbers, returns.
    private func ensureTimingIOProc() {
        installLock.lock()
        defer { installLock.unlock() }
        guard timingIOProcID == nil else { return }

        var procID: AudioDeviceIOProcID?
        let createErr = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, nil) {
            [weak self] inNow, _, _, _, _ in
            // ---- REAL-TIME THREAD: no allocation, no logging, no other lock. ----
            guard let self else { return }
            let now = inNow.pointee
            let nanos = BTOutputEngine.machHostTimeToNanos(now.mHostTime)
            self.clockLock.lock()
            self.fallbackSampleTime = now.mSampleTime
            self.fallbackHostTimeNanos = nanos
            self.fallbackValid = true
            self.clockLock.unlock()
        }
        guard createErr == noErr, let procID else {
            log("timing IOProc create FAILED status=\(createErr)")
            return
        }
        let startErr = AudioDeviceStart(deviceID, procID)
        guard startErr == noErr else {
            log("timing IOProc start FAILED status=\(startErr)")
            _ = AudioDeviceDestroyIOProcID(deviceID, procID)
            return
        }
        timingIOProcID = procID
        log("timing IOProc fallback installed")
    }

    /// Stop + destroy the fallback IOProc if it was installed. Idempotent and
    /// safe to call more than once; MUST pair exactly with `ensureTimingIOProc`
    /// (AudioDeviceStop then AudioDeviceDestroyIOProcID) or the HAL leaks/faults.
    private func teardownTimingIOProc() {
        installLock.lock()
        defer { installLock.unlock() }
        guard let procID = timingIOProcID else { return }
        let stopErr = AudioDeviceStop(deviceID, procID)
        if stopErr != noErr { log("timing IOProc stop status=\(stopErr)") }
        let destroyErr = AudioDeviceDestroyIOProcID(deviceID, procID)
        if destroyErr != noErr { log("timing IOProc destroy status=\(destroyErr)") }
        timingIOProcID = nil
    }

    /// Root-mean-square amplitude of every sample the render tap has actually
    /// pulled since the last call to this method, then resets the accumulator.
    /// This is the T5 "make-or-break" signal: a non-zero result means the
    /// output tap's callback genuinely fired with non-silent frames — proof
    /// audio flowed, not just that setDeviceID/engine.isRunning reported
    /// success while the device stayed silent.
    func drainRMS() -> Float {
        statsLock.lock()
        defer {
            sumSquares = 0
            squaredSampleCount = 0
            statsLock.unlock()
        }
        guard squaredSampleCount > 0 else { return 0 }
        return Float(sqrt(sumSquares / Double(squaredSampleCount)))
    }

    // MARK: - Configuration-change recovery

    /// AVAudioEngineConfigurationChange fires on ANY device's route change,
    /// not just this engine's pinned device — e.g. connecting/disconnecting
    /// any other Bluetooth or system-default output re-fires it for every
    /// running engine. Registered per-engine so each instance's log line is
    /// unambiguous about which device it's talking about.
    private func observeConfigurationChanges() {
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.log("AVAudioEngineConfigurationChange FIRED")
            self.graphQueue.async {
                self.handleConfigurationChangeOnGraphQueue()
            }
        }
    }

    /// Recover from a configuration change (the engine has already stopped
    /// itself). A bare engine.start() retry does not reliably bring the
    /// engine back — pattern: LocalPlaybackEngine.handleConfigurationChangeOnGraphQueue
    /// ~250-316. Reconnect player->delay->mixer, restart, re-play.
    private func handleConfigurationChangeOnGraphQueue() {
        isRunningTracked = false
        let format = ToneSource.format
        engine.connect(player, to: delay, format: format)
        engine.connect(delay, to: engine.mainMixerNode, format: format)
        _ = engine.mainMixerNode
        engine.prepare()
        do {
            try engine.start()
        } catch {
            log("configChange restart FAILED: \(error)")
            return
        }
        guard engine.isRunning else {
            log("configChange restart: engine still not running")
            return
        }
        isRunningTracked = true
        scheduleLoopOnGraphQueue()
        player.play()
        log("configChange recovered — engine running again")
    }

    // MARK: - Logging

    private func log(_ message: String) {
        print("BTOutputEngine[\(deviceName) id=\(deviceID)]: \(message)")
    }
}
