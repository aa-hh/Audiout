// Copyright (C) 2026 ahh and contributors.
//
// LICENSE-CLEAN by design, like SyncProbeCorrelator.swift which it drives:
// no GPL SPDX header, and no GPL-derived code may move in.

import AVFoundation
import CoreAudio
import Foundation
import ProbeKit

extension ISO8601DateFormatter {
    /// Colons are legal in a macOS filename but the Finder shows them as `/`,
    /// so the dump stamp drops them.
    static let micProbeDumpStamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withYear, .withMonth, .withDay, .withTime,
                           .withDashSeparatorInDate]
        return f
    }()
}

// MARK: - Mic permission

/// The microphone TCC gate for the probe (roadmap 064). A denied or
/// undecided mic is NEVER an error — the by-ear wizard is the fallback — so
/// this reports capability, not failure.
public enum MicCapturePermission {
    /// True only when macOS has already granted this app the microphone.
    public static var isGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// True only for the one status `ensure` answers by raising the system prompt.
    public static var isUndecided: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
    }

    /// Ask if undecided (the system prompt), report the outcome either way.
    public static func ensure(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default: completion(false)
        }
    }
}

// MARK: - Recorder

/// What ``MicProbeSession`` needs from a microphone — seam for tests.
public protocol MicProbeRecording {
    /// Begin capturing; returns the capture sample rate.
    func start() throws -> Double
    /// Stop and hand back everything captured, mono.
    func stop() -> [Float]
    /// The monotonic instant of the FIRST captured sample, nil until one has
    /// arrived. Passive drift tracking measures every delay from the instant
    /// shared by the capture and the retained program, so it cannot work
    /// without this; the chirp wizard measures one arrival against another
    /// inside the same capture and never asks.
    var firstSampleHostNanos: Int64? { get }
    /// RMS of the last `seconds` of capture in dBFS, nil while fewer samples
    /// than that have arrived. The probe reads the room with it just before
    /// arming, to pick its level step.
    func recentRMSdBFS(seconds: Double) -> Double?
}

public extension MicProbeRecording {
    var firstSampleHostNanos: Int64? { nil }
    func recentRMSdBFS(seconds: Double) -> Double? { nil }
}

/// Captures the Mac's BUILT-IN microphone, pinned by device ID.
///
/// Never the default input: with a Bluetooth speaker connected the default
/// input may BE that speaker's own mic, and opening it forces the A2DP→HFP
/// collapse this feature exists to avoid (PLAN-UNIVERSAL-SYNC risk R-A2DP/HFP).
public final class BuiltInMicRecorder: MicProbeRecording {

    public enum RecorderError: Error { case noBuiltInMicrophone, sampleRateChanged }

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var firstSampleNanos: Int64?
    /// Set when the tap restarted after `samples` was already dated: the
    /// restart leaves a hole in the capture, so `samples[i]` no longer sits at
    /// `firstSampleNanos + i / rate` and the timestamp must not be offered.
    private var timelineBroken = false
    /// `sampleRate` again, readable under `lock` from any thread.
    private var lockedSampleRate: Double = 0

    /// Every touch of `engine` happens on this queue, including the
    /// configuration-change observer's restart.
    private let recorderQueue = DispatchQueue(label: "mic-probe-recorder")
    private var configChangeObserver: NSObjectProtocol?
    /// Recorder queue only.
    private var sampleRate: Double = 0
    /// Recorder queue only.
    private var stopped = false

    public init() {
        // AVAudioEngine stops itself on a configuration change, and macOS can
        // fire one shortly after the mic starts (observed 42 ms after the
        // first start following a fresh TCC grant, live 2026-09-12). Without
        // an observer nothing restarts it and the probe silently captures
        // nothing (`capturedSeconds 0.0`).
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.recorderQueue.async { self?.restartAfterConfigurationChange() }
        }
    }

    deinit {
        if let configChangeObserver { NotificationCenter.default.removeObserver(configChangeObserver) }
    }

    public var firstSampleHostNanos: Int64? {
        lock.lock(); defer { lock.unlock() }
        return timelineBroken ? nil : firstSampleNanos
    }

    public func recentRMSdBFS(seconds: Double) -> Double? {
        lock.lock(); defer { lock.unlock() }
        let count = Int(seconds * lockedSampleRate)
        guard count > 0, samples.count >= count else { return nil }
        let sumSquares = samples[(samples.count - count)...].reduce(0.0) { $0 + Double($1) * Double($1) }
        return 10 * log10(max(sumSquares / Double(count), 1e-20))
    }

    public func start() throws -> Double {
        try recorderQueue.sync {
            lock.lock(); samples = []; firstSampleNanos = nil; timelineBroken = false; lock.unlock()
            let format = try tapAndStart(expectedRate: nil)
            sampleRate = format.sampleRate
            lock.lock(); lockedSampleRate = sampleRate; lock.unlock()
            return sampleRate
        }
    }

    public func stop() -> [Float] {
        recorderQueue.sync {
            stopped = true
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        lock.lock(); defer { lock.unlock() }
        return samples
    }

    /// Recorder queue only. Resolves the built-in mic, taps it, and starts
    /// the engine; returns the format it tapped with. `expectedRate` is
    /// non-nil on a restart: if the hardware now reports a different rate,
    /// refuse rather than silently mixing two sample rates into `samples`.
    private func tapAndStart(expectedRate: Double?) throws -> AVAudioFormat {
        guard let mic = Self.builtInMicrophoneID() else {
            throw RecorderError.noBuiltInMicrophone
        }
        // The first start always pins: an un-pinned input unit can report the
        // built-in mic only because it is the current default input, and would
        // follow a later default-input change onto a Bluetooth mic. A restart
        // pins only when the device moved, because re-pinning the SAME device
        // can itself fire another configuration change (see
        // LocalPlaybackEngine.swift).
        if expectedRate == nil || engine.inputNode.auAudioUnit.deviceID != mic {
            try engine.inputNode.auAudioUnit.setDeviceID(mic)
        }
        // Pinning the device updates `inputFormat` but leaves `outputFormat`
        // reporting the PREVIOUS device's rate, and a tap installed with that
        // stale format (`format: nil` takes it) makes `start()` throw -10868
        // from InitializeActiveNodesInInputChain. Tap with the hardware format.
        let format = engine.inputNode.inputFormat(forBus: 0)
        if let expectedRate, format.sampleRate != expectedRate {
            throw RecorderError.sampleRateChanged
        }
        engine.inputNode.installTap(onBus: 0, bufferSize: 4_096, format: format) { [self] buffer, when in
            let frames = Int(buffer.frameLength)
            guard frames > 0, let data = buffer.floatChannelData else { return }
            let channels = Int(buffer.format.channelCount)
            var mono = [Float](repeating: 0, count: frames)
            for c in 0..<channels {
                for i in 0..<frames { mono[i] += data[c][i] }
            }
            if channels > 1 {
                let inverse = 1 / Float(channels)
                for i in 0..<frames { mono[i] *= inverse }
            }
            lock.lock()
            if firstSampleNanos == nil {
                // Nothing is kept until a buffer carries a valid host time:
                // `firstSampleHostNanos` names the instant of `samples[0]`, so
                // appending earlier frames would date the capture to a later
                // instant than it began and bias every delay measured from it
                // by one buffer (~85 ms at this tap size). Dropped, not guessed.
                guard when.isHostTimeValid else { lock.unlock(); return }
                // The same mach → CLOCK_MONOTONIC rebase the capture pts ride,
                // so the mic and the retained program share one timeline.
                firstSampleNanos = SyncTiming.monotonicNanos(
                    CoreAudioSystemTap.timespec(fromHostTime: when.hostTime))
            }
            samples.append(contentsOf: mono)
            lock.unlock()
        }
        engine.prepare()
        try engine.start()
        return format
    }

    /// Recorder queue only. Restarts the tap after macOS stopped the engine
    /// out from under us. `engine.isRunning` coalesces a burst of
    /// notifications after one successful restart into a single attempt.
    private func restartAfterConfigurationChange() {
        guard !stopped, sampleRate > 0, !engine.isRunning else { return }
        // A second installTap on a bus that still has one traps.
        engine.inputNode.removeTap(onBus: 0)
        lock.lock(); if firstSampleNanos != nil { timelineBroken = true }; lock.unlock()
        do {
            _ = try tapAndStart(expectedRate: sampleRate)
            // `start()` can return without error yet leave the engine stopped
            // after a configuration change (see LocalPlaybackEngine.swift). A
            // later notification, if one comes, retries through this path.
            guard engine.isRunning else {
                Telemetry.log(.localPlayback, "mic_probe_recorder_restart_failed",
                              ["error": "engine not running after start"])
                return
            }
            let capturedSeconds: Double = {
                lock.lock(); defer { lock.unlock() }
                return Double(samples.count) / sampleRate
            }()
            Telemetry.log(.localPlayback, "mic_probe_recorder_restarted",
                          ["capturedSeconds": String(format: "%.1f", capturedSeconds)])
        } catch {
            // Leave the engine stopped; already-captured samples are kept
            // for stop().
            Telemetry.log(.localPlayback, "mic_probe_recorder_restart_failed",
                          ["error": String(describing: error)])
        }
    }

    /// The first built-in device with input channels — nil on a Mac without
    /// one (a headless mini), in which case the probe simply never runs.
    public static func builtInMicrophoneID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioDeviceID](repeating: 0,
                                  count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &ids) == noErr else { return nil }
        return ids.first { id in
            var transportAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var transport: UInt32 = 0
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(id, &transportAddress, 0, nil,
                                             &transportSize, &transport) == noErr,
                  transport == kAudioDeviceTransportTypeBuiltIn else { return false }
            var configAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain)
            var configSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &configAddress, 0, nil,
                                                 &configSize) == noErr, configSize > 0
            else { return false }
            let raw = UnsafeMutableRawPointer.allocate(
                byteCount: Int(configSize), alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { raw.deallocate() }
            guard AudioObjectGetPropertyData(
                id, &configAddress, 0, nil, &configSize,
                raw.assumingMemoryBound(to: AudioBufferList.self)) == noErr else { return false }
            let buffers = UnsafeMutableAudioBufferListPointer(
                raw.assumingMemoryBound(to: AudioBufferList.self))
            return buffers.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
        }
    }
}

// MARK: - Session

/// One mic-probe measurement, end to end: start the built-in-mic capture,
/// have the wizard feed play the probe's two lanes (Bluetooth first, the
/// engine/Mac lane `SyncProbe.Layout.laneSpacingSeconds` later), then
/// matched-filter the capture and reduce it to the one number the wizard
/// wants — how many ms LATER the Bluetooth side sounded than the reference.
///
/// The session never fails loudly: every path that cannot produce a
/// convincing measurement — permission lost, probe never armed (run torn
/// down), probe inaudible, low confidence or a near rival — completes with `nil`, and the
/// by-ear wizard simply proceeds as it always has.
public final class MicProbeSession {

    public struct Result: Equatable {
        /// Bluetooth arrival minus reference arrival, ms. Positive = the
        /// Bluetooth speaker is late = its applied latency is this much too
        /// small.
        public let deltaMs: Double
        /// The weaker of the two arrivals' peak-to-sidelobe ratios.
        public let confidence: Double
        /// The smaller of the two lanes' margins over their strongest rival
        /// lag (`ProbeAnalysis.peakMargin`); 1 means a rival matched.
        public let peakMargin: Double
    }

    /// Stages the probe on the live wizard feed. `levelStepDB` is asked once,
    /// at arm time, for the level step to play at; the two callbacks report
    /// the arm-gate opening and the last probe frame entering the feed.
    public typealias StageProbe = (_ levelStepDB: @escaping () -> Int,
                                   _ onStarted: @escaping (_ pipelineDelaySeconds: TimeInterval) -> Void,
                                   _ onFinished: @escaping () -> Void) -> Void

    /// The injector's lead before the probe; the wizard view reads it here
    /// because `AlignmentTickInjector` is internal to this module.
    public static let probeLeadSeconds = AlignmentTickInjector.probeLeadSeconds
    /// Only the companion stand-down reads this fixed wait now.
    public static let pipelineTailSeconds = 3.0
    /// Air lags the feed by the room delay the stage reports at the gate
    /// opening (the slowest participating lane). The recording runs that long
    /// past the last probe frame entering the feed, plus this margin, capped
    /// at `pipelineTailCeilingSeconds`.
    public static let pipelineTailMarginSeconds = 1.5
    public static let pipelineTailCeilingSeconds = 10.0

    public static func listeningTailSeconds(pipelineDelaySeconds: TimeInterval,
                                            margin: TimeInterval = pipelineTailMarginSeconds) -> TimeInterval {
        min(pipelineTailCeilingSeconds, max(0, pipelineDelaySeconds) + margin)
    }

    private let recorder: MicProbeRecording
    private let timeout: TimeInterval
    private let pipelineTail: TimeInterval
    private let queue = DispatchQueue(label: "mic-probe-session")
    private var sampleRate: Double = 0
    /// Monotonic nanoseconds, the clock `firstSampleHostNanos` is on.
    private var startedAt: Int64?
    private var recordingBegan: Int64?
    private var finished = false
    private var completion: ((Result?) -> Void)?
    /// What the level closure answered, for `mic_probe_finished`.
    private var levelStepDB: Int?
    private var ambientDBFS: Double?
    private var pipelineDelaySeconds: TimeInterval?

    public init(recorder: MicProbeRecording = BuiltInMicRecorder(),
                timeout: TimeInterval = 40,
                pipelineTail: TimeInterval = MicProbeSession.pipelineTailMarginSeconds) {
        self.recorder = recorder
        self.timeout = timeout
        self.pipelineTail = pipelineTail
    }

    /// Kick the measurement off. `completion` is called exactly once, on the
    /// main queue.
    public func start(stage: @escaping StageProbe, completion: @escaping (Result?) -> Void) {
        queue.async { [self] in
            guard self.completion == nil, !finished else { return }
            self.completion = completion
            do {
                sampleRate = try recorder.start()
            } catch {
                Telemetry.log(.localPlayback, "mic_probe_recorder_failed",
                              ["error": String(describing: error)])
                finish(analyze: false)
                return
            }
            recordingBegan = Self.nowNanos()
            let recorder = recorder
            stage({ [weak self] in
                let rms = recorder.recentRMSdBFS(seconds: 0.5)
                let step = Self.levelStepDB(ambientRMSdBFS: rms)
                self?.queue.async { self?.levelStepDB = step; self?.ambientDBFS = rms }
                return step
            }, { [weak self] delay in
                self?.queue.async { self?.startedAt = Self.nowNanos(); self?.pipelineDelaySeconds = delay }
            }, { [weak self] in
                guard let self else { return }
                self.queue.async {
                    let tail = Self.listeningTailSeconds(pipelineDelaySeconds: self.pipelineDelaySeconds ?? 0,
                                                         margin: self.pipelineTail)
                    self.queue.asyncAfter(deadline: .now() + tail) {
                        self.finish(analyze: true)
                    }
                }
            })
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(analyze: true)
            }
        }
    }

    /// Abandon the run (wizard cancelled). The recorder is stopped; the
    /// completion still fires, with nil.
    public func cancel() {
        queue.async { self.finish(analyze: false) }
    }

    /// `queue` only. Idempotent.
    private func finish(analyze: Bool) {
        guard !finished else { return }
        finished = true
        let recording = sampleRate > 0 ? recorder.stop() : []
        let result: Result? = analyze ? measure(recording: recording) : nil
        // Diagnosis hatch: AUDIOUT_MIC_PROBE_DUMP=1 keeps the raw capture
        // (mono Float32) beside the telemetry, so a refused measurement can
        // be analysed offline instead of guessed at. Debug only, nothing
        // reads it in a shipping run.
        //
        // One file PER RUN. A fixed name cost a whole investigation on
        // 2026-08-28: three runs failed, a fourth succeeded and overwrote
        // them, and the surviving bytes were analysed for hours as though
        // they were the failure. Refusals are exactly what a diagnosis hatch
        // exists to preserve, and they are the runs a retry follows.
        if ProcessInfo.processInfo.environment["AUDIOUT_MIC_PROBE_DUMP"] == "1",
           !recording.isEmpty {
            let stamp = ISO8601DateFormatter.micProbeDumpStamp.string(from: Date())
            let url = FileManager.default.urls(for: .libraryDirectory,
                                               in: .userDomainMask)[0]
                .appendingPathComponent(
                    "Logs/Audiout/mic-probe-\(stamp)-\(result != nil ? "ok" : "refused").f32")
            recording.withUnsafeBufferPointer { try? Data(buffer: $0).write(to: url) }
            Telemetry.log(.localPlayback, "mic_probe_dump", [
                "path": url.path,
                "rate": String(Int(sampleRate)),
                "startedAtSeconds": startedSeconds().map { String(format: "%.2f", $0) } ?? "-",
            ])
        }
        Telemetry.log(.localPlayback, "mic_probe_finished", [
            "ok": result != nil ? "1" : "0",
            "deltaMs": result.map { String(format: "%.2f", $0.deltaMs) } ?? "-",
            "confidence": result.map { String(format: "%.1f", $0.confidence) } ?? "-",
            "capturedSeconds": sampleRate > 0
                ? String(format: "%.1f", Double(recording.count) / sampleRate) : "0",
            "levelStepDB": levelStepDB.map { String($0) } ?? "-",
            "ambientDBFS": ambientDBFS.map { String(format: "%.1f", $0) } ?? "-",
        ])
        let completion = completion
        self.completion = nil
        DispatchQueue.main.async { completion?(result) }
    }

    private func measure(recording: [Float]) -> Result? {
        guard sampleRate > 0, !recording.isEmpty else { return nil }
        // Ambient = the capture up to just before the arm gate opened; the
        // search starts just before the sweeps entered the feed, a probe lead
        // after the gate. Air can only lag the feed, so nothing ahead of that
        // is a sweep. Both keep 0.25 s of slack for the main-queue hop that
        // stamps `startedAt` late.
        var ambientEnd = 0
        var searchFrom = 0
        if let seconds = startedSeconds() {
            func index(_ s: Double) -> Int { min(max(0, Int(s * sampleRate)), recording.count) }
            ambientEnd = index(seconds - 0.25)
            searchFrom = index(seconds + AlignmentTickInjector.probeLeadSeconds - 0.25)
        }
        return Self.analyze(recording: recording, sampleRate: sampleRate,
                            ambientEnd: ambientEnd, searchFrom: searchFrom)
    }

    /// Seconds from `recording[0]` to the arm gate opening. Dated from the
    /// recorder's first sample when it offers one: a cold or restarted mic
    /// can deliver its first sample most of a second after `start()`
    /// returned (live, v1.2.0: 6.1 s captured of a 6.5 s listen), and dating
    /// from the return would place the sweeps that much later in the capture
    /// than they sit, cutting a real one out of the search.
    private func startedSeconds() -> Double? {
        guard let startedAt, let origin = recorder.firstSampleHostNanos ?? recordingBegan
        else { return nil }
        return Double(startedAt - origin) / 1e9
    }

    private static func nowNanos() -> Int64 {
        var now = timespec()
        clock_gettime(CLOCK_MONOTONIC, &now)
        return SyncTiming.monotonicNanos(now)
    }

    /// The analysis, split from the wall-clock bookkeeping so tests can hand
    /// it a scene with an exact ambient boundary.
    ///
    /// Arrivals are searched for only from `searchFrom` on. Searched over the
    /// whole capture, a missing Bluetooth lane's best match comes from
    /// whatever played before the probe (live, v1.2.0: Δ −778 to −3748 ms
    /// at confidence 5.9–7.9, shown as an implausible reading). Such a match
    /// scores with the loudness of that earlier sound, so no confidence
    /// floor can tell it from a weak real arrival; where it sits can.
    ///
    /// The weighted-then-plain fallback lives in `ProbeAnalyzer`: the
    /// ambient slice describes the room BEFORE the probe, and during a wizard
    /// entry it legitimately carries the tail of the user's music still
    /// draining through the sinks' ~2 s delay (live finding, 2026-08-28), so
    /// a weighted search that finds nothing hands over to the plain matched
    /// filter.
    static func analyze(recording: [Float], sampleRate: Double,
                        ambientEnd: Int, searchFrom: Int = 0) -> Result? {
        guard let analysis = try? ProbeAnalyzer(sampleRate: sampleRate)
            .analyze(recording: recording, ambientEndSample: ambientEnd,
                     searchFromSample: searchFrom) else { return nil }
        return accepting(Result(deltaMs: analysis.offsetMs,
                                confidence: analysis.confidence,
                                peakMargin: analysis.peakMargin))
    }

    /// The weakest arrival the wizard trusts. ProbeKit's own floor (5) only
    /// tells a sweep from pure noise. Live on 2026-09-26, with the Bluetooth
    /// speaker silent, two false matches scored 7.2 (−4,876 ms) and 55.3
    /// (668 ms, a believable number); the speaker's real arrivals that day
    /// scored 684, 734 and 1,724. The floor cannot go above the 55: a true
    /// reading taken over a music tail scores about 23 (see the music-tail
    /// test), so a score alone refuses the 7.2 but not the 55.
    static let minConfidence = 20.0

    /// A Bluetooth-target run pins its reference this far ahead, so no
    /// alignable speaker can sound further than this from the reference.
    static let maxPlausibleDeltaMs = Double(NativeBackend.btWizardReferenceBufferMs)

    /// The smallest margin, 6 dB, a lane's peak must hold over its strongest
    /// rival lag. A parallel glide or a strong reflection matches the
    /// template almost as well as the true arrival, and the per-lane margin
    /// is the one number that sees a rival anywhere in the searched range,
    /// not only near the winner.
    static let minPeakMargin = 1.995

    /// A weak, ambiguous or physically impossible measurement is refused
    /// rather than proposed: the wizard then falls back to asking by ear.
    static func accepting(_ result: Result) -> Result? {
        guard result.confidence >= minConfidence,
              result.peakMargin >= minPeakMargin,
              abs(result.deltaMs) <= maxPlausibleDeltaMs else { return nil }
        return result
    }

    /// The probe's level step for the room the mic heard during the lead-in:
    /// 0, 6 or 12 dB above the staged level. The thresholds take the
    /// 2026-08-28 capture's −71 dBFS floor as the bench's standard room and
    /// the bench's +10 dB condition as a loud one
    /// (`dev/notes/wizard-sync-tone-2026-10-06/shaped/ROUND3-OPTIONS.md`).
    /// razor: three fixed steps; tune the thresholds from the `levelStepDB` /
    /// `ambientDBFS` fields of `mic_probe_finished` once runs are logged.
    static func levelStepDB(ambientRMSdBFS: Double?) -> Int {
        guard let rms = ambientRMSdBFS, rms > -68 else { return 0 }
        return rms <= -62 ? 6 : 12
    }
}
