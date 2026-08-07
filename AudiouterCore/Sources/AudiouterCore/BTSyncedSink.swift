// Copyright (C) 2026 ahh and contributors.
//
// LICENSE-CLEAN by design (PLAN-UNIVERSAL-SYNC Decision 5): this file carries NO
// GPL SPDX header, unlike most siblings. It is a fresh Apple-only implementation
// (AVFoundation + Core Audio) written for this project against the shared
// license-clean `SyncCore.swift` seams. The GPL-headered `SyncedLocalSink.swift`
// was studied for its architectural SHAPE only — no code was copied from it; the
// engine wiring, ring, and drift machinery here are re-derived from the plan
// (`docs/plans/PLAN-UNIVERSAL-SYNC.md` E/F/G) and the spike findings
// (`dev/notes/bt-spike-findings-2026-08-07.md`). Do not add a GPL header to this
// file, and do not move GPL-derived code into it.

import AudioToolbox
import AVFoundation
import Foundation

// MARK: - BT-REFSEL — reference-timeline selection

/// Which kinds of outputs currently share the group with the Bluetooth devices.
/// Drives ``BTReferenceTimeline``'s choice of reference; recomputed (via a sink
/// rebuild) whenever the group's composition changes.
struct BTGroupComposition: Equatable, Sendable {
    /// At least one AirPlay receiver is streaming — its presentation timeline
    /// (authored by us as PTP grandmaster) is the one reference every other
    /// output delays to.
    var airPlayPresent: Bool
    /// The Mac's own speakers are in the mix. Deliberately carried even though
    /// it never changes a BT delay (see ``BTReferenceTimeline/delayNanos``):
    /// the "Mac joining changes nothing for BT" rule is explicit and testable
    /// instead of implicit in a missing parameter.
    var macLocalPresent: Bool
}

/// The BT-REFSEL rule (plan §E): AirPlay present → the AirPlay presentation
/// timeline is the reference and each BT device delays by
/// `presentationDelay − perDeviceOffset (+ trim)`; BT-only (with or without the
/// Mac's own speakers) → the Mac `hostTime` timeline is the reference and the
/// presentation term is a small fixed scheduling buffer instead. Always clamped
/// ≥ 0 (inside `SyncTiming.totalDelayNanos`).
enum BTReferenceTimeline {

    /// `presentationDelayMs` MUST be the LIVE engine value
    /// (`currentPresentationDelayMs()`), never a hardcoded copy of the 250 ms
    /// constant — plan risk R4: a buffer-size tune must move the AirPlay
    /// schedule and every BT delay together.
    ///
    /// `deviceOffsetMs` is the device's own output latency (BT stack + speaker,
    /// ~100–400 ms in the wild): it plays that much LATE on its own, so we
    /// schedule it that much EARLIER. `trimMs` is the signed manual nudge
    /// (BT-OFFSET-UI persists it later).
    ///
    /// `macLocalPresent` never changes the result: with AirPlay present the
    /// AirPlay timeline stays the single reference (the Mac's own sink delays
    /// itself to it separately); without AirPlay the Mac IS the reference
    /// clock whether or not its speakers play.
    static func delayNanos(
        composition: BTGroupComposition,
        presentationDelayMs: Int,
        btOnlyBufferMs: Int,
        deviceOffsetMs: Int,
        trimMs: Int
    ) -> Int64 {
        SyncTiming.totalDelayNanos(
            presentationDelayMs: composition.airPlayPresent ? presentationDelayMs : btOnlyBufferMs,
            localOutputLatencySeconds: Double(deviceOffsetMs) / 1_000,
            safetyMarginMs: 0,
            userOffsetMs: trimMs)
    }
}

// MARK: - BT-DRIFT — pacing-clock corrector with the adaptive settle gate

/// Per-device drift correction fed by the device's PACING clock (the host-side
/// BT stack's `AudioDeviceGetCurrentTime` timeline — NOT the speaker's remote
/// DAC, which nothing on this Mac can read). Live-verified 2026-08-07: the
/// pacing clock is brand-dependent — a Sonos Move 2 showed ±5–100 ms jumps for
/// ~40 s after connect while the stack re-buffered, a Sony XM3 was clean from
/// second one — so a fixed distrust window is wrong in both directions. This is
/// the ADAPTIVE settle gate the spike findings call for:
///
///  - **Settling (distrust):** the clock is not believed. The correction is
///    held — at neutral 0 before the first trust, at the last-good value after
///    it — and nothing is integrated, so a jumpy warm-up can never wind the
///    loop up.
///  - **Trust** is earned by being jump-free (per-sample step deviation below
///    ``jumpThresholdNanos``) for ``settleNanos``. Sony-class devices lock in
///    ~10 s; Sonos-class devices get the full protection automatically.
///  - **Any later jump re-enters distrust and re-anchors**: the step is
///    accepted as a measurement artifact of the stack re-buffering, never
///    "corrected" by slewing the audio rate to chase it.
///
/// While trusted, the accumulated misalignment between the device's pacing
/// clock and the host clock — minus the correction already applied — feeds the
/// shared ``PhaseController`` PI loop; its `correctionPpm` output is the
/// resampler rate the render path consumes (`ratio = 1 + ppm·1e-6`).
///
/// Pure and hardware-free: driven by ``ingest(deviceSampleTime:nominalRate:hostNanos:)``
/// with real or synthetic clock samples. Single-threaded by contract (the
/// device sink's clock queue); `reset()` only runs with the sampler stopped.
final class BTDriftCorrector {

    /// A per-sample step deviation at or above this is a jump (the spike saw
    /// genuine jumps of 5–100 ms; genuine skew accumulates ~0.1 ms/s at 100 ppm,
    /// far below).
    static let defaultJumpThresholdNanos: Int64 = 2_000_000
    /// Jump-free time required before the clock is trusted.
    static let defaultSettleNanos: Int64 = 10_000_000_000

    enum Trust: Equatable {
        case settling
        case trusted
    }

    private let jumpThresholdNanos: Int64
    private let settleNanos: Int64
    /// The shared PI loop, with gains tuned for THIS corrector's ~1 Hz ingest
    /// cadence (``BTDeviceSink/clockSampleInterval``) rather than the per-render-
    /// cycle cadence the defaults target. Plant per 1 s update at 44.1–48 kHz:
    /// loop gain β = rate·1e-6 ≈ 0.044–0.048; Kp = 10 keeps β·Kp ≈ 0.5 (well
    /// damped) and Ki = 0.6 sits under the real-pole bound β·Kp²/4 ≈ 1.1.
    /// Deliberately NOT reset on re-anchor: its integrator carries the
    /// last-good rate estimate across a distrust window, so re-trust resumes
    /// smoothly instead of re-converging from zero.
    private let controller: PhaseController

    private(set) var trust: Trust = .settling
    /// The residual the PI loop last acted on (diagnostic; 0 while settling).
    private(set) var latestPhaseErrorNanos: Double = 0

    private var lastDeviceNanos: Double?
    private var lastHostNanos: Int64 = 0
    private var jumpFreeSinceHostNanos: Int64 = 0
    private var anchorDeviceNanos: Double = 0
    private var anchorHostNanos: Int64 = 0
    /// Content-time adjustment (ns) the applied corrections have already made
    /// since the anchor — the loop's own actuation, modeled so the measured
    /// pacing-clock skew is not double-corrected.
    private var appliedCorrectionNanos: Double = 0
    private var lastAppliedPpm: Double = 0

    /// The rate correction (ppm) the render path should apply right now.
    /// Changes only inside a trusted `ingest`; held steady during distrust.
    var correctionPpm: Double { controller.correctionPpm }

    init(
        jumpThresholdNanos: Int64 = BTDriftCorrector.defaultJumpThresholdNanos,
        settleNanos: Int64 = BTDriftCorrector.defaultSettleNanos,
        controller: PhaseController = PhaseController(
            kpPpmPerFrame: 10, kiPpmPerFrame: 0.6, maxPpm: 200, slewPpmPerCycle: 25)
    ) {
        self.jumpThresholdNanos = jumpThresholdNanos
        self.settleNanos = settleNanos
        self.controller = controller
    }

    /// Back to a fresh, neutral, distrusting state. Called on sink rebuild —
    /// a device/rate/config change is a new clock context, so the old trust and
    /// rate estimate are void.
    func reset() {
        trust = .settling
        latestPhaseErrorNanos = 0
        lastDeviceNanos = nil
        lastHostNanos = 0
        jumpFreeSinceHostNanos = 0
        appliedCorrectionNanos = 0
        lastAppliedPpm = 0
        controller.reset()
    }

    /// Feed one pacing-clock sample; returns the correction (ppm) to apply.
    /// `deviceSampleTime` is the device's `mSampleTime`, normalized here by
    /// `nominalRate` onto a nanosecond timeline; `hostNanos` is the paired host
    /// timestamp (mach ticks converted to ns — both clock paths deliver that).
    @discardableResult
    func ingest(deviceSampleTime: Double, nominalRate: Double, hostNanos: Int64) -> Double {
        guard nominalRate > 0 else { return correctionPpm }
        let deviceNanos = deviceSampleTime / nominalRate * 1_000_000_000.0

        guard let previousDeviceNanos = lastDeviceNanos else {
            // First sample: nothing to diff yet; the jump-free clock starts here.
            lastDeviceNanos = deviceNanos
            lastHostNanos = hostNanos
            jumpFreeSinceHostNanos = hostNanos
            return correctionPpm
        }

        let hostIntervalNanos = Double(hostNanos &- lastHostNanos)
        let stepDeviationNanos = (deviceNanos - previousDeviceNanos) - hostIntervalNanos
        lastDeviceNanos = deviceNanos
        lastHostNanos = hostNanos

        if abs(stepDeviationNanos) >= Double(jumpThresholdNanos) {
            // Jump: re-enter distrust and re-anchor. The correction holds at
            // last-good (or neutral 0 if the clock was never trusted).
            trust = .settling
            jumpFreeSinceHostNanos = hostNanos
            latestPhaseErrorNanos = 0
            return correctionPpm
        }

        switch trust {
        case .settling:
            if hostNanos &- jumpFreeSinceHostNanos >= settleNanos {
                trust = .trusted
                anchorDeviceNanos = deviceNanos
                anchorHostNanos = hostNanos
                appliedCorrectionNanos = 0
                lastAppliedPpm = controller.correctionPpm
            }
            return correctionPpm

        case .trusted:
            // What the render actually applied over the interval just elapsed,
            // at the correction that prevailed during it.
            appliedCorrectionNanos += lastAppliedPpm * 1e-6 * hostIntervalNanos
            let pacingSkewNanos =
                (deviceNanos - anchorDeviceNanos) - Double(hostNanos &- anchorHostNanos)
            // Positive misalignment = content running AHEAD of the reference
            // (device clock fast); the controller convention is error > 0 ⇒
            // BEHIND ⇒ speed up, so feed the negation.
            let phaseErrorNanos = -(pacingSkewNanos + appliedCorrectionNanos)
            latestPhaseErrorNanos = phaseErrorNanos
            controller.update(
                phaseErrorNanos: phaseErrorNanos,
                nsPerFrame: 1_000_000_000.0 / nominalRate)
            lastAppliedPpm = controller.correctionPpm
            return controller.correctionPpm
        }
    }
}

// MARK: - Frame ring (delay line)

/// Single-producer / single-consumer wait-free ring of whole interleaved
/// FRAMES — the per-device delay line between the capture (producer) thread and
/// that device's render (consumer) thread. Monotonically-increasing head/tail
/// frame counters live in dedicated heap words (aligned word loads/stores are
/// atomic on Apple silicon) with `OSMemoryBarrier()` for acquire/release
/// ordering; the counters are masked only for addressing, so full-vs-empty is a
/// plain subtraction and the whole capacity is usable. The producer never
/// blocks and never splits a chunk: a chunk that does not fit is dropped
/// wholesale.
///
/// razor: no drop counters yet — BT-FANOUT (Wave 3), which owns the producer
/// side for real, adds observability there if live use shows drops.
private final class BTFrameRing {
    private let channelCount: Int
    private let capacityFrames: Int
    private let frameMask: Int
    private let samples: UnsafeMutablePointer<Float>
    private let writeCounter: UnsafeMutablePointer<Int>   // producer-owned
    private let readCounter: UnsafeMutablePointer<Int>    // consumer-owned

    init(minimumCapacityFrames: Int, channelCount: Int) {
        var capacity = 1
        while capacity < max(2, minimumCapacityFrames) { capacity <<= 1 }
        self.channelCount = max(1, channelCount)
        self.capacityFrames = capacity
        self.frameMask = capacity - 1
        let sampleCount = capacity * self.channelCount
        self.samples = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
        self.samples.initialize(repeating: 0, count: sampleCount)
        self.writeCounter = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        self.readCounter = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        writeCounter.initialize(to: 0)
        readCounter.initialize(to: 0)
    }

    deinit {
        samples.deallocate()
        writeCounter.deallocate()
        readCounter.deallocate()
    }

    /// Producer side; real-time safe (no allocation, no locks). Returns false
    /// when the chunk was dropped for lack of space.
    @discardableResult
    func write(interleavedFrames src: UnsafePointer<Float>, frameCount: Int) -> Bool {
        guard frameCount > 0 else { return true }
        let w = writeCounter.pointee
        OSMemoryBarrier()                       // acquire: see the consumer's counter
        let used = w &- readCounter.pointee
        guard frameCount <= capacityFrames &- used else { return false }
        var copied = 0
        while copied < frameCount {
            let dstFrame = (w &+ copied) & frameMask
            let span = min(frameCount - copied, capacityFrames - dstFrame)
            samples.advanced(by: dstFrame * channelCount)
                .update(from: src.advanced(by: copied * channelCount), count: span * channelCount)
            copied += span
        }
        OSMemoryBarrier()                       // release: publish data before the counter
        writeCounter.pointee = w &+ frameCount
        return true
    }

    /// Consumer side: copies exactly one interleaved frame, or returns false on
    /// empty. Shaped for `FractionalResampler.render`'s `pullFrame`.
    func readFrame(into dst: UnsafeMutablePointer<Float>) -> Bool {
        let r = readCounter.pointee
        OSMemoryBarrier()                       // acquire: see the producer's data
        guard writeCounter.pointee &- r > 0 else { return false }
        dst.update(from: samples.advanced(by: (r & frameMask) * channelCount), count: channelCount)
        OSMemoryBarrier()                       // release: finish the copy before the counter
        readCounter.pointee = r &+ 1
        return true
    }

    /// Drop everything buffered. Only while neither thread is active (engine
    /// stopped / offline tests).
    func reset() {
        OSMemoryBarrier()
        readCounter.pointee = writeCounter.pointee
        OSMemoryBarrier()
    }
}

// MARK: - Per-device sink

enum BTDeviceSinkError: Error, CustomStringConvertible {
    /// AVAudioEngine SILENTLY NO-OPS when pinned to an aggregate device
    /// (spike-verified): everything reports success and no audio flows. Refuse
    /// up front instead of debugging silence later.
    case aggregateDevice
    case engineNotRunning

    var description: String {
        switch self {
        case .aggregateDevice: return "aggregate/virtual devices silently no-op under AVAudioEngine"
        case .engineNotRunning: return "engine not running after start"
        }
    }
}

/// One Bluetooth device's delayed, drift-corrected render endpoint (BT-SINK):
/// an `AVAudioEngine` pinned to that device via
/// `outputNode.auAudioUnit.setDeviceID` (spike-proven; pinned BEFORE the first
/// start), whose `AVAudioSourceNode` stays silent until the reference timeline
/// reaches `capture_pts + delay`, then drains the ring through the shared
/// `FractionalResampler` at the rate the ``BTDriftCorrector`` commands.
///
/// NEVER install a tap on `engine.outputNode` — that raises an uncatchable
/// AVFAudio exception at install time (spike gotcha, live-verified); if a tap
/// is ever needed here, it goes on `mainMixerNode`.
///
/// `@unchecked Sendable`: producer (enqueue) and consumer (render) meet only
/// through the wait-free ``BTFrameRing``; the scalar gate/drift state is behind
/// `stateLock`, taken non-blockingly on the render path. Graph mutation is
/// serialized on `graphQueue`; pacing-clock sampling on `clockQueue`.
///
/// Lock order: a device's `stateLock` may take the manager's table lock (the
/// one-time anchor samples `delayNanosProvider`); the manager must NEVER call
/// into a sink while holding its table lock.
final class BTDeviceSink: @unchecked Sendable {

    /// Pacing-clock sampling cadence. The ``BTDriftCorrector`` PI gains are
    /// tuned for this; retune them if this ever changes.
    static let clockSampleInterval: TimeInterval = 1.0

    let deviceID: AudioObjectID
    let deviceUID: String
    let renderSampleRate: Double
    private let channelCount: Int
    private let maxRenderFrames: Int
    /// Sampled ONCE per session (at the anchor, on the enqueue thread) — never
    /// on the render path. A delay change therefore lands via `rebuild(cause:)`
    /// + re-anchor, not a live poke.
    private let delayNanosProvider: @Sendable () -> Int64

    // Producer/consumer state.
    private let ring: BTFrameRing
    private let resampler: FractionalResampler
    private let stateLock = NSLock()
    private var anchored = false
    private var released = false
    private var targetReleaseNanos: Int64 = 0
    /// Published by the clock sampler; snapshotted by the render path each
    /// cycle under the same non-blocking `stateLock.try()` as the gate.
    private var driftPpm: Double = 0

    // Engine (all mutation on `graphQueue`).
    private let graphQueue: DispatchQueue
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let connectionFormat: AVAudioFormat
    private var running = false
    private var configChangeObserver: NSObjectProtocol?
    private var rateListenerBlock: AudioObjectPropertyListenerBlock?
    private let listenerQueue: DispatchQueue
    /// Interleaved render scratch (the source node's connection format is
    /// deinterleaved standard Float32 — an interleaved source-node format blows
    /// up in Core Audio with an uncatchable -10868; render fills this
    /// interleaved buffer, then deinterleaves into the node's planes).
    private let scratch: UnsafeMutablePointer<Float>
    private let scratchCapacity: Int

    // Pacing clock (BT-DRIFT). Sampling on `clockQueue`; the IOProc fallback
    // follows the spike's lock discipline: `installLock` guards IOProc
    // create/destroy, `clockLock` guards the three fields the HAL's real-time
    // block writes. DISTINCT locks on purpose — the RT block takes only
    // `clockLock`, so holding `installLock` across `AudioDeviceStart` (which
    // may fire the block before returning) can never deadlock against it.
    private let clockQueue: DispatchQueue
    private var clockTimer: DispatchSourceTimer?
    private var nominalRate: Double
    private let driftCorrector: BTDriftCorrector
    private var lastLoggedTrust: BTDriftCorrector.Trust = .settling
    private let installLock = NSLock()
    private let clockLock = NSLock()
    private var timingIOProcID: AudioDeviceIOProcID?
    private var fallbackSampleTime: Double = 0
    private var fallbackHostNanos: Int64 = 0
    private var fallbackValid = false

    init(
        deviceID: AudioObjectID,
        deviceUID: String,
        renderSampleRate: Double,
        channelCount: Int,
        maxBufferedSeconds: Double = 8,
        maxRenderFrames: Int = 8192,
        delayNanosProvider: @escaping @Sendable () -> Int64
    ) {
        let channels = max(1, channelCount)
        self.deviceID = deviceID
        self.deviceUID = deviceUID
        self.renderSampleRate = renderSampleRate
        self.channelCount = channels
        self.maxRenderFrames = max(1, maxRenderFrames)
        self.delayNanosProvider = delayNanosProvider
        self.nominalRate = renderSampleRate
        self.graphQueue = DispatchQueue(label: "com.audiouter.btsink.graph.\(deviceUID)")
        self.listenerQueue = DispatchQueue(label: "com.audiouter.btsink.listener.\(deviceUID)")
        self.clockQueue = DispatchQueue(label: "com.audiouter.btsink.clock.\(deviceUID)")
        self.driftCorrector = BTDriftCorrector()

        // The ring is the delay line: it must hold the full delay's worth of
        // pre-roll (the BT-only buffer or the ~2 s AirPlay presentation delay).
        self.ring = BTFrameRing(
            minimumCapacityFrames: Int((maxBufferedSeconds * renderSampleRate).rounded()),
            channelCount: channels)
        self.resampler = FractionalResampler(channelCount: channels)
        self.scratchCapacity = self.maxRenderFrames * channels
        self.scratch = UnsafeMutablePointer<Float>.allocate(capacity: scratchCapacity)
        self.scratch.initialize(repeating: 0, count: scratchCapacity)

        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: renderSampleRate,
            channels: AVAudioChannelCount(channels))
        else {
            fatalError("BTDeviceSink: no standard \(renderSampleRate)/\(channels)ch format")
        }
        self.connectionFormat = format
    }

    deinit {
        // Direct, no graphQueue hop: a pending `requestRebuild` block retains
        // self, so deinit can run ON graphQueue (as that last block releases
        // the final reference) — a `graphQueue.sync` here would deadlock. By
        // deinit nothing else references the sink, so the direct calls are
        // exclusive whichever thread this runs on.
        stopLocked()
        scratch.deallocate()
    }

    // MARK: Lifecycle

    /// Pin to the device and start the engine (idempotent). Throws on an
    /// aggregate/virtual device (silent no-op trap) or a failed start.
    func start() throws {
        try graphQueue.sync { try startLocked() }
    }

    func stop() {
        graphQueue.sync { stopLocked() }
    }

    /// Tear down and (if the sink was running) rebuild against the device's
    /// current configuration, resetting THIS device's drift state — a config
    /// change or nominal-rate renegotiation (the silent-tap bug family applied
    /// to BT: a rebuilt route keeps "working" while the timeline it renders on
    /// has moved) voids the session anchor AND the pacing-clock trust.
    func requestRebuild(cause: String) {
        graphQueue.async { self.rebuildLocked(cause: cause) }
    }

    private func startLocked() throws {
        guard !running else { return }
        if let transport = Self.transportType(deviceID),
           transport == kAudioDeviceTransportTypeAggregate
            || transport == kAudioDeviceTransportTypeAutoAggregate
            || transport == kAudioDeviceTransportTypeVirtual {
            Telemetry.log(.localPlayback, "bt_sink_refused_aggregate", ["uid": deviceUID])
            throw BTDeviceSinkError.aggregateDevice
        }
        // Pin BEFORE the first start — a pin after start is silently ignored.
        // A failed transport read above falls OPEN (a momentarily unreadable
        // real speaker must not be refused); the pin below still targets the
        // exact device either way.
        try engine.outputNode.auAudioUnit.setDeviceID(deviceID)
        if let liveRate = Self.nominalSampleRate(deviceID) { nominalRate = liveRate }

        let node = sourceNode ?? makeSourceNode()
        sourceNode = node
        if node.engine == nil { engine.attach(node) }
        try catchingObjCException {
            engine.connect(node, to: engine.mainMixerNode, format: connectionFormat)
        }
        engine.prepare()
        try engine.start()
        running = engine.isRunning
        guard running else { throw BTDeviceSinkError.engineNotRunning }
        installEventListenersLocked()
        startClockSamplerLocked()
    }

    private func stopLocked() {
        stopClockSamplerLocked()
        teardownTimingIOProc()
        removeEventListenersLocked()
        if running || engine.isRunning {
            sourceNode?.reset()
            engine.stop()
        }
        running = false
        clearSessionStateLocked()
    }

    private func rebuildLocked(cause: String) {
        let wasRunning = running
        stopLocked()
        Telemetry.log(.localPlayback, "bt_sink_rebuild", ["uid": deviceUID, "cause": cause])
        guard wasRunning else { return }
        do {
            try startLocked()
        } catch {
            Telemetry.log(.localPlayback, "bt_sink_restart_failed", [
                "uid": deviceUID, "cause": cause, "error": String(describing: error),
            ])
        }
    }

    /// Void the session (anchor, ring, resampler) AND the drift state. The
    /// render thread is stopped by every caller (engine down), so resetting the
    /// render-owned resampler is safe; the clock sampler is likewise stopped,
    /// so resetting the corrector is exclusive.
    private func clearSessionStateLocked() {
        stateLock.withLock {
            anchored = false
            released = false
            targetReleaseNanos = 0
            driftPpm = 0
        }
        ring.reset()
        resampler.reset()
        driftCorrector.reset()
        lastLoggedTrust = .settling
    }

    // MARK: Producer (capture → ring)

    /// Enqueue one captured block of interleaved Float32 frames with its
    /// capture `pts` (`CLOCK_MONOTONIC` — the same `CapturedBuffer.pts`
    /// timeline the AirPlay sessions consume). Called on the tap delivery
    /// thread; real-time safe — a wait-free ring write plus a one-time
    /// non-blocking anchor set (a missed `try()` defers the anchor one buffer:
    /// a sub-ms pts shift, never a wrong order). Format conversion to this
    /// sink's rate/channel layout is the caller's job (BT-FANOUT).
    func enqueue(interleavedFrames: UnsafePointer<Float>, frameCount: Int, pts: timespec) {
        guard frameCount > 0 else { return }
        if stateLock.try() {
            if !anchored {
                anchored = true
                targetReleaseNanos = SyncTiming.targetReleaseMonotonicNanos(
                    anchorPtsNanos: SyncTiming.monotonicNanos(pts),
                    totalDelayNanos: delayNanosProvider())
            }
            stateLock.unlock()
        }
        ring.write(interleavedFrames: interleavedFrames, frameCount: frameCount)
    }

    // MARK: Consumer (ring → render)

    private func makeSourceNode() -> AVAudioSourceNode {
        AVAudioSourceNode(format: connectionFormat) { [weak self] isSilence, timestamp, frameCount, audioBufferList in
            guard let self else {
                isSilence.pointee = true
                return noErr
            }
            return self.render(
                isSilence: isSilence, timestamp: timestamp,
                frameCount: frameCount, audioBufferList: audioBufferList)
        }
    }

    private func render(
        isSilence: UnsafeMutablePointer<ObjCBool>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        frameCount: AVAudioFrameCount,
        audioBufferList: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        let frames = Int(frameCount)
        guard frames > 0, frames * channelCount <= scratchCapacity,
              #available(macOS 14.2, *)   // the capture path feeding us needs 14.2 anyway
        else {
            isSilence.pointee = true
            return noErr
        }
        // Rebase the cycle's mach host time onto CLOCK_MONOTONIC with the
        // shared sleep-aware helper — the pts timeline the gate compares on.
        let cycleStart = SyncTiming.monotonicNanos(
            CoreAudioSystemTap.timespec(fromHostTime: timestamp.pointee.mHostTime))

        let buffer = UnsafeMutableBufferPointer(start: scratch, count: frames * channelCount)
        let producedAudio = renderInterleaved(
            into: buffer, frameCount: frames, cycleStartMonotonicNanos: cycleStart)

        let planes = UnsafeMutableAudioBufferListPointer(audioBufferList)
        for ch in 0..<min(channelCount, planes.count) {
            guard let dst = planes[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
            for f in 0..<frames { dst[f] = scratch[f * channelCount + ch] }
        }
        isSilence.pointee = ObjCBool(!producedAudio)
        return noErr
    }

    /// The testable render core (no engine, no clocks): fills `frameCount`
    /// interleaved frames for a cycle starting at `cycleStartMonotonicNanos`
    /// and reports whether any real audio was emitted. Silent (and
    /// non-draining) until the gate opens at the anchored target; after that,
    /// the ring drains through the resampler at the drift-commanded rate.
    @discardableResult
    func renderInterleaved(
        into out: UnsafeMutableBufferPointer<Float>,
        frameCount: Int,
        cycleStartMonotonicNanos: Int64
    ) -> Bool {
        guard let base = out.baseAddress, frameCount > 0,
              frameCount * channelCount <= out.count else { return false }
        // Silence-first: real audio overwrites its slice; whatever the drain
        // cannot fill (pre-release frames, a ring underrun tail) stays zero.
        base.update(repeating: 0, count: frameCount * channelCount)

        var plan = SyncTiming.RenderPlan(silentFrames: frameCount, releasesThisCycle: false)
        var ratio = 1.0
        guard stateLock.try() else { return false }   // no snapshot → silent cycle
        if anchored {
            if released {
                plan = SyncTiming.RenderPlan(silentFrames: 0, releasesThisCycle: true)
            } else {
                plan = SyncTiming.plan(
                    cycleStartMonotonicNanos: cycleStartMonotonicNanos,
                    frameCount: frameCount,
                    sampleRate: renderSampleRate,
                    targetReleaseMonotonicNanos: targetReleaseNanos)
                if plan.releasesThisCycle { released = true }
            }
            ratio = 1.0 + driftPpm * 1e-6
        }
        stateLock.unlock()
        guard plan.releasesThisCycle else { return false }

        let produced = resampler.render(
            into: out,
            outFrameOffset: plan.silentFrames,
            outFrames: frameCount - plan.silentFrames,
            ratio: ratio
        ) { frame in
            self.ring.readFrame(into: frame)
        }
        return produced > 0
    }

    // MARK: Rebuild triggers (config change / nominal-rate renegotiation)

    private func installEventListenersLocked() {
        if configChangeObserver == nil {
            configChangeObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
            ) { [weak self] _ in
                self?.requestRebuild(cause: "config_change")
            }
        }
        if rateListenerBlock == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.requestRebuild(cause: "rate_change")
            }
            rateListenerBlock = block
            var address = Self.nominalRateAddress
            AudioObjectAddPropertyListenerBlock(deviceID, &address, listenerQueue, block)
        }
    }

    private func removeEventListenersLocked() {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        if let block = rateListenerBlock {
            var address = Self.nominalRateAddress
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, listenerQueue, block)
            rateListenerBlock = nil
        }
    }

    // MARK: Pacing-clock sampling (BT-DRIFT)

    private func startClockSamplerLocked() {
        guard clockTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: clockQueue)
        timer.schedule(
            deadline: .now() + Self.clockSampleInterval,
            repeating: Self.clockSampleInterval,
            leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.sampleClockTick() }
        timer.resume()
        clockTimer = timer
    }

    private func stopClockSamplerLocked() {
        guard let timer = clockTimer else { return }
        timer.cancel()
        clockTimer = nil
        // Drain any in-flight tick so corrector/nominalRate mutation after this
        // point is exclusive.
        clockQueue.sync {}
    }

    private func sampleClockTick() {
        guard let sample = readPacingClock() else { return }
        let ppm = driftCorrector.ingest(
            deviceSampleTime: sample.sampleTime,
            nominalRate: nominalRate,
            hostNanos: sample.hostNanos)
        let trust = driftCorrector.trust
        if trust != lastLoggedTrust {
            lastLoggedTrust = trust
            Telemetry.log(.localPlayback, "bt_drift_trust", [
                "uid": deviceUID,
                "state": trust == .trusted ? "trusted" : "settling",
                "ppm": String(format: "%.1f", ppm),
            ])
        }
        stateLock.withLock { driftPpm = ppm }
    }

    /// Query-first read of the device's pacing clock: `AudioDeviceGetCurrentTime`
    /// worked passively on real hardware (Sonos, Sony — spike); if it refuses,
    /// lazily attach a timing-only IOProc whose block records the HAL's own
    /// timestamps, and read the latest recorded pair.
    private func readPacingClock() -> (sampleTime: Double, hostNanos: Int64)? {
        var ts = AudioTimeStamp()
        if AudioDeviceGetCurrentTime(deviceID, &ts) == noErr,
           ts.mFlags.contains(.sampleTimeValid), ts.mFlags.contains(.hostTimeValid) {
            return (ts.mSampleTime, Self.machNanos(fromHostTime: ts.mHostTime))
        }
        ensureTimingIOProc()
        clockLock.lock()
        defer { clockLock.unlock() }
        guard fallbackValid else { return nil }
        return (fallbackSampleTime, fallbackHostNanos)
    }

    private func ensureTimingIOProc() {
        installLock.lock()
        defer { installLock.unlock() }
        guard timingIOProcID == nil else { return }
        var procID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, nil) {
            [weak self] inNow, _, _, _, _ in
            // HAL REAL-TIME THREAD: two number stores under clockLock — no
            // allocation, no logging, no other lock.
            guard let self else { return }
            let now = inNow.pointee
            guard now.mFlags.contains(.sampleTimeValid), now.mFlags.contains(.hostTimeValid) else { return }
            let nanos = Self.machNanos(fromHostTime: now.mHostTime)
            self.clockLock.lock()
            self.fallbackSampleTime = now.mSampleTime
            self.fallbackHostNanos = nanos
            self.fallbackValid = true
            self.clockLock.unlock()
        }
        guard createStatus == noErr, let procID else { return }
        guard AudioDeviceStart(deviceID, procID) == noErr else {
            _ = AudioDeviceDestroyIOProcID(deviceID, procID)
            return
        }
        timingIOProcID = procID
    }

    private func teardownTimingIOProc() {
        installLock.lock()
        defer { installLock.unlock() }
        guard let procID = timingIOProcID else { return }
        _ = AudioDeviceStop(deviceID, procID)
        _ = AudioDeviceDestroyIOProcID(deviceID, procID)
        timingIOProcID = nil
        clockLock.lock()
        fallbackValid = false
        clockLock.unlock()
    }

    // MARK: Core Audio property helpers

    private static let nominalRateAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private static func nominalSampleRate(_ device: AudioObjectID) -> Double? {
        var address = nominalRateAddress
        var rate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr,
              rate > 0 else { return nil }
        return rate
    }

    private static func transportType(_ device: AudioObjectID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr
        else { return nil }
        return transport
    }

    /// mach host ticks → nanoseconds (mach-absolute timescale, signed so
    /// interval math stays plain). Both pacing-clock paths deliver host times
    /// through this one conversion, so the corrector diffs one time axis.
    private static func machNanos(fromHostTime hostTime: UInt64) -> Int64 {
        let timebase = cachedTimebase
        return Int64(bitPattern: hostTime &* UInt64(timebase.numer) / UInt64(max(1, timebase.denom)))
    }

    private static let cachedTimebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb
    }()
}

// MARK: - Manager (BT-SINK: the N-instance owner)

/// The N-instance Bluetooth sink manager: one ``BTDeviceSink`` per selected BT
/// device, all fed the SAME captured PCM+pts (`enqueue` fans out), each delayed
/// to the current reference timeline (``BTReferenceTimeline``) with its own
/// offset/trim and its own drift loop.
///
/// Feeding it from the whole-system capture and driving it from selection
/// transitions is BT-FANOUT/BT-BACKEND's partition
/// (`docs/plans/PLAN-UNIVERSAL-SYNC.md` §G), not a missing hookup here.
///
/// `@unchecked Sendable`: `tableLock` guards the tables below and is NEVER held
/// across a call into a sink (sinks are collected under the lock, called after
/// it drops) — the reverse order (a sink's anchor sampling its delay provider,
/// which takes `tableLock`) is the sanctioned nesting.
final class BTSyncedSink: @unchecked Sendable {

    struct DeviceSpec: Equatable, Sendable {
        let deviceID: AudioObjectID
        /// Stable identity (`kAudioDevicePropertyDeviceUID`) — the key offsets
        /// and trims survive a disconnect/rejoin under.
        let uid: String
    }

    /// BT-only reference: the small fixed scheduling buffer ahead of the Mac
    /// `hostTime` timeline. 500 ms clears the real-world BT output-latency
    /// spread (~100–400 ms), so per-device offsets keep their full relative
    /// effect without hitting the zero clamp; latency is a non-goal (music, not
    /// lip-sync — Decision 1).
    static let defaultBTOnlyBufferMs = 500

    private let renderSampleRate: Double
    private let channelCount: Int
    private let btOnlyBufferMs: Int
    /// The LIVE AirPlay presentation delay (`currentPresentationDelayMs()` in
    /// production — plan risk R4 forbids a hardcoded copy). Sampled per session
    /// anchor via each sink's delay provider.
    private let presentationDelayMs: @Sendable () -> Int

    private let tableLock = NSLock()
    private var sinksByUID: [String: BTDeviceSink] = [:]
    private var composition = BTGroupComposition(airPlayPresent: false, macLocalPresent: false)
    private var offsetMsByUID: [String: Int] = [:]
    private var trimMsByUID: [String: Int] = [:]
    private var desiredRunning = false

    init(
        renderSampleRate: Double = 44_100,
        channelCount: Int = 2,
        btOnlyBufferMs: Int = BTSyncedSink.defaultBTOnlyBufferMs,
        presentationDelayMs: @escaping @Sendable () -> Int
    ) {
        self.renderSampleRate = renderSampleRate
        self.channelCount = max(1, channelCount)
        self.btOnlyBufferMs = btOnlyBufferMs
        self.presentationDelayMs = presentationDelayMs
    }

    deinit {
        stop()
    }

    // MARK: Selection / lifecycle

    /// Arm the manager: current and future sinks start their engines.
    func start() {
        let sinks = tableLock.withLock { () -> [BTDeviceSink] in
            desiredRunning = true
            return Array(sinksByUID.values)
        }
        for sink in sinks { startSink(sink) }
    }

    func stop() {
        let sinks = tableLock.withLock { () -> [BTDeviceSink] in
            desiredRunning = false
            return Array(sinksByUID.values)
        }
        for sink in sinks { sink.stop() }
    }

    /// Reconcile toward exactly `specs`: new devices get a sink (started only
    /// while the manager is armed), vanished devices' sinks stop and drop.
    /// Unchanged devices are untouched — their sessions keep playing.
    func setDevices(_ specs: [DeviceSpec]) {
        var added: [BTDeviceSink] = []
        var removed: [BTDeviceSink] = []
        var shouldStart = false
        tableLock.lock()
        let wantedByUID = Dictionary(specs.map { ($0.uid, $0) }, uniquingKeysWith: { first, _ in first })
        for (uid, sink) in sinksByUID where wantedByUID[uid] == nil {
            sinksByUID[uid] = nil
            removed.append(sink)
        }
        for (uid, spec) in wantedByUID where sinksByUID[uid] == nil {
            let sink = makeSink(spec)
            sinksByUID[uid] = sink
            added.append(sink)
        }
        shouldStart = desiredRunning
        tableLock.unlock()

        for sink in removed { sink.stop() }
        if shouldStart {
            for sink in added { startSink(sink) }
        }
    }

    /// BT-REFSEL: recompute every device's delay when the group's composition
    /// changes. Applied as a rebuild + re-anchor per sink — the reference
    /// timeline itself moved, so the running sessions' targets are void.
    func setComposition(_ newComposition: BTGroupComposition) {
        let sinks = tableLock.withLock { () -> [BTDeviceSink] in
            guard composition != newComposition else { return [] }
            composition = newComposition
            return Array(sinksByUID.values)
        }
        for sink in sinks { sink.requestRebuild(cause: "composition_change") }
    }

    /// The settable per-device output-latency figure (ms) — the UI wave
    /// persists it (keyed by device UID) later.
    func setOffsetMs(_ ms: Int, forDeviceUID uid: String) {
        let sink = tableLock.withLock { () -> BTDeviceSink? in
            guard offsetMsByUID[uid] != ms else { return nil }
            offsetMsByUID[uid] = ms
            return sinksByUID[uid]
        }
        sink?.requestRebuild(cause: "offset_change")
    }

    /// The settable per-device signed manual trim (ms).
    func setTrimMs(_ ms: Int, forDeviceUID uid: String) {
        let sink = tableLock.withLock { () -> BTDeviceSink? in
            guard trimMsByUID[uid] != ms else { return nil }
            trimMsByUID[uid] = ms
            return sinksByUID[uid]
        }
        sink?.requestRebuild(cause: "trim_change")
    }

    // MARK: Feed

    /// Fan one captured block to every device's delay line. Called on the tap
    /// delivery thread; the sink list is snapshotted under `tableLock`, the
    /// per-sink work happens after it drops (lock-order rule above).
    func enqueue(interleavedFrames: UnsafePointer<Float>, frameCount: Int, pts: timespec) {
        let sinks = tableLock.withLock { Array(sinksByUID.values) }
        for sink in sinks {
            sink.enqueue(interleavedFrames: interleavedFrames, frameCount: frameCount, pts: pts)
        }
    }

    // MARK: Internals

    private func makeSink(_ spec: DeviceSpec) -> BTDeviceSink {
        let uid = spec.uid
        return BTDeviceSink(
            deviceID: spec.deviceID,
            deviceUID: uid,
            renderSampleRate: renderSampleRate,
            channelCount: channelCount,
            delayNanosProvider: { [weak self] in self?.delayNanos(forUID: uid) ?? 0 })
    }

    private func delayNanos(forUID uid: String) -> Int64 {
        tableLock.lock()
        let currentComposition = composition
        let offsetMs = offsetMsByUID[uid] ?? 0
        let trimMs = trimMsByUID[uid] ?? 0
        let bufferMs = btOnlyBufferMs
        tableLock.unlock()
        return BTReferenceTimeline.delayNanos(
            composition: currentComposition,
            presentationDelayMs: presentationDelayMs(),
            btOnlyBufferMs: bufferMs,
            deviceOffsetMs: offsetMs,
            trimMs: trimMs)
    }

    private func startSink(_ sink: BTDeviceSink) {
        do {
            try sink.start()
        } catch {
            Telemetry.log(.localPlayback, "bt_sink_start_failed", [
                "uid": sink.deviceUID, "error": String(describing: error),
            ])
        }
    }

    // MARK: Test seam

    /// The live sink for a UID — offline tests drive its render core directly.
    func sinkForTesting(uid: String) -> BTDeviceSink? {
        tableLock.withLock { sinksByUID[uid] }
    }
}
