// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 ahh and contributors.

import Foundation

#if canImport(AVFoundation)
import AVFoundation
#endif

/// Pure, hardware-free timing math for the synced local sink (T-SINK). Split out
/// so the delay computation and the per-render-cycle release decision are
/// unit-testable without an `AVAudioEngine` or any real audio device.
///
/// All time is `CLOCK_MONOTONIC`-based nanoseconds — the SAME timeline the
/// AirPlay sessions' `pts` live on (`CapturedBuffer.pts`, produced by
/// ``CoreAudioSystemTap/timespec(fromHostTime:)``). The render block rebases the
/// output device's `mHostTime` (mach) into this timeline via that same helper
/// before calling in here, so both sides of the comparison are one clock.
enum SyncTiming {

    static func monotonicNanos(_ ts: timespec) -> Int64 {
        Int64(ts.tv_sec) &* 1_000_000_000 &+ Int64(ts.tv_nsec)
    }

    /// How long after a captured sample's `pts` the local speaker must emit it to
    /// land level with the AirPlay receivers:
    /// `presentationDelay − localOutputLatency − safetyMargin`, clamped ≥ 0.
    ///
    /// `presentationDelayMs` MUST come from the live engine value
    /// (``AirPlayEngine/AirPlayEngine/currentPresentationDelayMs()`` /
    /// ``EngineConfig/presentationDelayMs``) — never a hardcoded copy of the
    /// 250 ms `AIRPLAY_AUDIO_LATENCY_MS` constant (plan risk R4): a later
    /// buffer-size tune must move both the AirPlay schedule and this one together.
    static func totalDelayNanos(
        presentationDelayMs: Int,
        localOutputLatencySeconds: Double,
        safetyMarginMs: Double
    ) -> Int64 {
        let presentationNanos = Int64(presentationDelayMs) &* 1_000_000
        let latencyNanos = Int64((localOutputLatencySeconds * 1_000_000_000).rounded())
        let marginNanos = Int64((safetyMarginMs * 1_000_000).rounded())
        return max(0, presentationNanos &- latencyNanos &- marginNanos)
    }

    static func targetReleaseMonotonicNanos(anchorPtsNanos: Int64, totalDelayNanos: Int64) -> Int64 {
        anchorPtsNanos &+ totalDelayNanos
    }

    /// Where, within a render cycle that starts at `cycleStartMonotonicNanos` and
    /// spans `frameCount` frames, the first non-silent frame falls.
    ///
    /// - `silentFrames == frameCount`, `releasesThisCycle == false`: the target is
    ///   still in the future — this whole cycle is silent.
    /// - `releasesThisCycle == true`: emit `silentFrames` of silence, then real
    ///   audio for the remainder. `silentFrames` is the sub-buffer (frame-accurate)
    ///   offset that keeps the released instant within one frame of the target,
    ///   which is what makes the alignment tight rather than buffer-granular.
    struct RenderPlan: Equatable {
        let silentFrames: Int
        let releasesThisCycle: Bool
    }

    static func plan(
        cycleStartMonotonicNanos: Int64,
        frameCount: Int,
        sampleRate: Double,
        targetReleaseMonotonicNanos: Int64
    ) -> RenderPlan {
        let deltaNanos = targetReleaseMonotonicNanos &- cycleStartMonotonicNanos
        // At or past the target (including a cycle we were late to gate): release
        // at frame 0; the residual is surfaced as the phase error, not hidden.
        if deltaNanos <= 0 { return RenderPlan(silentFrames: 0, releasesThisCycle: true) }
        let nsPerFrame = 1_000_000_000.0 / sampleRate
        let offsetFrames = Int((Double(deltaNanos) / nsPerFrame).rounded())
        if offsetFrames >= frameCount { return RenderPlan(silentFrames: frameCount, releasesThisCycle: false) }
        return RenderPlan(silentFrames: offsetFrames, releasesThisCycle: true)
    }
}

#if canImport(AVFoundation)

/// The delayed local Core Audio endpoint (T-SINK): an app-layer `AVAudioEngine`
/// whose `AVAudioSourceNode` is fed from a lock-free ring buffer and stays SILENT
/// until the output device's clock reaches
/// `capture_pts + presentationDelay − localOutputLatency − safetyMargin`, then
/// emits — so the Mac's own speakers play phase-aligned with the AirPlay
/// receivers instead of ~2 s ahead of them (brief `dev/notes/p2b-synced-local-brief.md`
/// §1/§4/§5.1). We are the PTP grandmaster, so this is a one-shot measured offset,
/// not a slave-side PTP feedback loop (brief §2).
///
/// ## Ownership / hot file
/// This file is the shared foundation later edited by T-LIFECYCLE (device-change /
/// sleep-wake rebuild), T-CORRECTION (continuous micro-rate correction), and
/// T-OFFSET-UI (user ms bias) — never concurrently. The graph topology and the
/// render block's `AVAudioTime` handling below leave explicit seams for those.
///
/// ## What this v1 does and does NOT do
/// It establishes the timeline anchor and the frame-accurate release gate. It does
/// NOT do drift correction (the source-device vs output-device ppm-clock skew that
/// accrues over long sessions) — that is T-CORRECTION, which plugs into the graph
/// seam and the `latestPhaseErrorNanos` readout marked below. It also does NOT
/// own device-change/sleep-wake rebuild (T-LIFECYCLE) or the tap self-exclude
/// that prevents an echo feedback loop (T-FANOUT).
///
/// `@unchecked Sendable`: the render (consumer) and enqueue (producer) paths meet
/// only through the lock-free SPSC ``InterleavedFloatRing``; the scalar release
/// state is guarded by `stateLock`, taken non-blockingly on the real-time render
/// path exactly as ``LocalPlaybackEngine`` does.
public final class SyncedLocalSink: @unchecked Sendable {

    /// A small constant fudge that schedules the release a hair EARLIER than the
    /// exact computed instant, absorbing render-thread scheduler jitter without an
    /// audible effect (brief §4 "a small negative safety margin is standard
    /// practice"). Kept intentionally small (the brief floats 10–20 ms; T-SINK
    /// scopes it to a few ms — the manual T-OFFSET-UI slider is the real tuning
    /// knob later).
    public static let defaultSafetyMarginMs: Double = 3.0

    private let renderSampleRate: Double
    private let channelCount: Int
    private let safetyMarginMs: Double
    private let maxRenderFrames: Int

    /// Reads the LIVE presentation delay (ms) — wired to
    /// `currentPresentationDelayMs()` in production so a buffer-size change moves
    /// local playback with it (R4). Must be cheap/non-blocking: it is sampled once
    /// per play session (when the release anchor is set), never on the render path.
    private let presentationDelayMs: @Sendable () -> Int
    /// Measures the current default output device's latency (`LocalOutputLatency`,
    /// T-LATENCY). Sampled off the render path (same points as the delay). Optional
    /// so a measurement failure just yields a slightly longer delay, never a crash.
    private let localOutputLatency: @Sendable () -> LocalOutputLatencyMeasurement?

    private let engine = AVAudioEngine()
    private let sourceNode: AVAudioSourceNode
    /// Deinterleaved standard Float32 — an `AVAudioSourceNode`→mixer connection
    /// rejects an interleaved format with an uncatchable Core Audio exception
    /// (-10868), the same lesson `LocalPlaybackEngine` encodes. The ring stores
    /// interleaved samples; the render block deinterleaves into this format's
    /// planar buffers via `deinterleaveScratch`.
    private let connectionFormat: AVAudioFormat

    private let ring: InterleavedFloatRing
    /// One persistent interleaved scratch buffer sized to `maxRenderFrames`, so the
    /// render block deinterleaves ring→planar with NO per-cycle allocation.
    private let deinterleaveScratch: UnsafeMutablePointer<Float>
    private let deinterleaveScratchCapacity: Int

    private let stateLock = NSLock()
    private let graphQueue = DispatchQueue(label: "com.audiouter.syncedlocalsink.graph")
    private var started = false
    /// Set on the first enqueue of a play session; pins ring-sample 0 to a pts.
    private var anchored = false
    /// Flips true (once) inside the render block when the gate opens.
    private var released = false
    private var targetReleaseNanos: Int64 = 0
    /// Cached at `start()`; falls back to a lazy sample on first enqueue if the
    /// caller enqueues without starting the engine (the offline test path).
    private var cachedTotalDelayNanos: Int64?
    /// Signed residual (actual scheduled first-real-sample instant − target) from
    /// the release cycle. The phase-readout seam T-SPIKE-PHASE measures and
    /// T-CORRECTION's control loop nulls; with frame-accurate placement it is < 1
    /// frame at release, and a future correction loop keeps it there over time.
    private var lastPhaseErrorNanos: Int64 = 0

    public init(
        renderSampleRate: Double = 48_000,
        channelCount: Int = 2,
        maxBufferedSeconds: Double = 8,
        maxRenderFrames: Int = 8192,
        safetyMarginMs: Double = SyncedLocalSink.defaultSafetyMarginMs,
        presentationDelayMs: @escaping @Sendable () -> Int,
        localOutputLatency: @escaping @Sendable () -> LocalOutputLatencyMeasurement? = { try? LocalOutputLatency.measure() }
    ) {
        let channels = max(1, channelCount)
        self.renderSampleRate = renderSampleRate
        self.channelCount = channels
        self.safetyMarginMs = safetyMarginMs
        self.maxRenderFrames = max(1, maxRenderFrames)
        self.presentationDelayMs = presentationDelayMs
        self.localOutputLatency = localOutputLatency

        // The ring is the delay line: during the ~presentationDelay pre-roll the
        // producer fills while the consumer drains nothing, so capacity must exceed
        // the delay's worth of audio (default 8 s > the 5 s max start-buffer).
        let minSamples = Int((maxBufferedSeconds * renderSampleRate).rounded()) * channels
        self.ring = InterleavedFloatRing(minimumCapacitySamples: minSamples)

        self.deinterleaveScratchCapacity = self.maxRenderFrames * channels
        self.deinterleaveScratch = UnsafeMutablePointer<Float>.allocate(capacity: deinterleaveScratchCapacity)
        self.deinterleaveScratch.initialize(repeating: 0, count: deinterleaveScratchCapacity)

        guard let format = AVAudioFormat(standardFormatWithSampleRate: renderSampleRate, channels: AVAudioChannelCount(channels)) else {
            fatalError("SyncedLocalSink: could not build a \(renderSampleRate)/\(channels)ch render format")
        }
        self.connectionFormat = format

        // Render block built with an unowned box so `self` can wire it in the same
        // init; it is only ever invoked between `start()` and `stop()`.
        var boxed: SyncedLocalSink?
        self.sourceNode = AVAudioSourceNode(format: format) { isSilence, timestamp, frameCount, audioBufferList in
            boxed?.render(isSilence: isSilence, timestamp: timestamp, frameCount: frameCount, audioBufferList: audioBufferList) ?? noErr
        }
        boxed = self
    }

    deinit {
        deinterleaveScratch.deallocate()
    }

    /// Signed residual phase error (ns) captured at release — the seam
    /// T-SPIKE-PHASE reads and T-CORRECTION drives to zero.
    public var latestPhaseErrorNanos: Int64 {
        stateLock.withLock { lastPhaseErrorNanos }
    }

    // MARK: Lifecycle

    /// Build the graph and start the engine against the current default output
    /// device. Idempotent. (Device-change / sleep-wake teardown-and-rebuild is
    /// T-LIFECYCLE; v1 builds once.)
    public func start() throws {
        try graphQueue.sync {
            guard !started else { return }

            // Sample the delay off the render path, so the render block never
            // touches the actor-isolated engine read or a Core Audio latency probe.
            let delay = SyncTiming.totalDelayNanos(
                presentationDelayMs: presentationDelayMs(),
                localOutputLatencySeconds: localOutputLatency()?.totalSeconds ?? 0,
                safetyMarginMs: safetyMarginMs)
            stateLock.withLock { cachedTotalDelayNanos = delay }

            engine.attach(sourceNode)

            // ── T-CORRECTION / T-SPIKE-PHASE INSERTION SEAM ─────────────────────
            // The continuous rate-correction node (AVAudioUnitTimePitch /
            // AVAudioUnitVarispeed, or a custom fractional resampler per the
            // T-SPIKE-PHASE finding) is inserted HERE, between the source node and
            // the mixer: attach it and connect sourceNode → correction → mainMixer
            // instead of the direct connection below, driving its rate parameter
            // from `latestPhaseErrorNanos`. v1 wires the source node straight to
            // the mixer with no correction.
            try catchingObjCException {
                engine.connect(sourceNode, to: engine.mainMixerNode, format: connectionFormat)
            }
            _ = engine.mainMixerNode
            engine.prepare()
            try engine.start()
            started = engine.isRunning
        }
    }

    public func stop() {
        graphQueue.sync {
            if started {
                sourceNode.reset()
                engine.stop()
                started = false
            }
            stateLock.withLock {
                anchored = false
                released = false
                targetReleaseNanos = 0
                cachedTotalDelayNanos = nil
                lastPhaseErrorNanos = 0
            }
            ring.reset()
        }
    }

    // MARK: Producer (capture → ring)

    /// Enqueue one captured block of INTERLEAVED Float32 frames (channel-count
    /// interleaved) plus its capture `pts` (on the `CLOCK_MONOTONIC` timeline —
    /// the same `CapturedBuffer.pts` the AirPlay `write(pcm:pts:)` consumes).
    /// Called on the tap delivery thread. Real-time safe: a single lock-free ring
    /// write, and a one-time brief lock only to set the session anchor.
    ///
    /// The fan-out that feeds this from the same capture that feeds the AirPlay
    /// engine — and the tap self-exclude that stops the delayed output being
    /// re-captured as an echo — is T-FANOUT, not this file. Format conversion from
    /// an arbitrary ``TapFormat`` to this sink's interleaved-Float32 render format
    /// is the caller's job (the codebase's `PCMConverting`/`AVFormatConverter`),
    /// keeping this type about scheduling, not format bridging.
    public func enqueue(interleavedFrames: UnsafePointer<Float>, frameCount: Int, pts: timespec) {
        guard frameCount > 0 else { return }
        let ptsNanos = SyncTiming.monotonicNanos(pts)

        // Set the release anchor on the FIRST frame of a session, holding the lock
        // only for the scalar set so the anchor pts corresponds to sample 0 in the
        // ring (the write below is lock-free). A missed `try()` just defers the
        // anchor to the next buffer — a sub-ms pts error, never a wrong ordering.
        if stateLock.try() {
            if !anchored {
                let delay = cachedTotalDelayNanos ?? SyncTiming.totalDelayNanos(
                    presentationDelayMs: presentationDelayMs(),
                    localOutputLatencySeconds: localOutputLatency()?.totalSeconds ?? 0,
                    safetyMarginMs: safetyMarginMs)
                cachedTotalDelayNanos = delay
                anchored = true
                targetReleaseNanos = SyncTiming.targetReleaseMonotonicNanos(
                    anchorPtsNanos: ptsNanos, totalDelayNanos: delay)
            }
            stateLock.unlock()
        }

        _ = ring.write(interleavedFrames, count: frameCount * channelCount)
    }

    // MARK: Consumer (ring → render)

    #if canImport(AVFoundation)
    /// The real-time `AVAudioSourceNode` render block. Rebases the output device's
    /// `mHostTime` (mach) onto `CLOCK_MONOTONIC` by REUSING
    /// ``CoreAudioSystemTap/timespec(fromHostTime:)`` (the sleep-aware mach↔
    /// MONOTONIC helper — not reimplemented here), fills an interleaved scratch via
    /// ``renderInterleaved(into:frameCount:cycleStartMonotonicNanos:)``, then
    /// deinterleaves into the node's planar buffers.
    private func render(
        isSilence: UnsafeMutablePointer<ObjCBool>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        frameCount: AVAudioFrameCount,
        audioBufferList: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        let frames = Int(frameCount)
        let interleavedCount = frames * channelCount
        guard frames > 0, interleavedCount <= deinterleaveScratchCapacity else {
            isSilence.pointee = true
            return noErr
        }

        // mach hostTime → CLOCK_MONOTONIC ns via the shared, sleep-aware rebase.
        // Called only while still gated: once `released`, `renderInterleaved`
        // short-circuits before this timeline read, so the two `clock_gettime`
        // calls the helper resamples are paid during pre-roll only, not steady state.
        // The rebase lives on `CoreAudioSystemTap` (macOS 14.2+); below that the
        // process-tap capture path that feeds this sink doesn't exist, so nothing
        // is ever enqueued — emit silence.
        let cycleStartMonotonicNanos: Int64
        if #available(macOS 14.2, *) {
            let monoTs = CoreAudioSystemTap.timespec(fromHostTime: timestamp.pointee.mHostTime)
            cycleStartMonotonicNanos = SyncTiming.monotonicNanos(monoTs)
        } else {
            isSilence.pointee = true
            return noErr
        }

        let scratch = UnsafeMutableBufferPointer(start: deinterleaveScratch, count: interleavedCount)
        let producedNonSilence = renderInterleaved(
            into: scratch, frameCount: frames, cycleStartMonotonicNanos: cycleStartMonotonicNanos)

        let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
        let planes = min(channelCount, abl.count)
        for ch in 0..<planes {
            guard let dst = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
            for f in 0..<frames { dst[f] = deinterleaveScratch[f * channelCount + ch] }
        }
        isSilence.pointee = ObjCBool(!producedNonSilence)
        return noErr
    }
    #endif

    /// The testable render core (no AVFoundation, no clocks): fills `frameCount`
    /// frames of interleaved output for a cycle beginning at
    /// `cycleStartMonotonicNanos`, and returns whether any non-silence was emitted.
    /// Silent (and non-draining) until the gate opens at `targetReleaseNanos`.
    @discardableResult
    func renderInterleaved(
        into out: UnsafeMutableBufferPointer<Float>,
        frameCount: Int,
        cycleStartMonotonicNanos: Int64
    ) -> Bool {
        guard let base = out.baseAddress else { return false }
        let total = frameCount * channelCount

        var silentFrames = frameCount
        var shouldDrain = false
        if stateLock.try() {
            if anchored {
                if released {
                    silentFrames = 0
                    shouldDrain = true
                } else {
                    let plan = SyncTiming.plan(
                        cycleStartMonotonicNanos: cycleStartMonotonicNanos,
                        frameCount: frameCount,
                        sampleRate: renderSampleRate,
                        targetReleaseMonotonicNanos: targetReleaseNanos)
                    silentFrames = plan.silentFrames
                    if plan.releasesThisCycle {
                        released = true
                        shouldDrain = true
                        let firstRealNanos = cycleStartMonotonicNanos
                            &+ Int64((Double(silentFrames) * 1_000_000_000.0 / renderSampleRate).rounded())
                        lastPhaseErrorNanos = firstRealNanos &- targetReleaseNanos
                    }
                }
            }
            stateLock.unlock()
        } else {
            // Couldn't snapshot the gate state; emit silence this cycle.
            base.update(repeating: 0, count: total)
            return false
        }

        let silentSamples = silentFrames * channelCount
        if silentSamples > 0 { base.update(repeating: 0, count: silentSamples) }
        guard shouldDrain else { return false }

        let wanted = total - silentSamples
        let got = ring.read(into: base.advanced(by: silentSamples), maxCount: wanted)
        // Underrun: zero-fill the shortfall so a starved ring is silence, not garbage.
        if got < wanted {
            base.advanced(by: silentSamples + got).update(repeating: 0, count: wanted - got)
        }
        return got > 0
    }
}

/// Single-producer / single-consumer lock-free ring of interleaved `Float`
/// samples — the delay line between the capture (producer) thread and the
/// `AVAudioSourceNode` render (consumer) thread. Same SPSC design as the capture
/// side's byte ring (`dev/audiocap/Sources/audiocap/RingBuffer.swift`), in sample
/// units: word-sized head/tail indices in heap storage (aligned word loads/stores
/// are atomic on Apple silicon) paired with `OSMemoryBarrier()` for acquire/
/// release ordering, capacity rounded to a power of two so wraparound is a mask,
/// one slot left unused to tell full from empty. Producer never blocks: on
/// overflow it drops the chunk.
private final class InterleavedFloatRing {
    private let storage: UnsafeMutablePointer<Float>
    private let capacity: Int
    private let mask: Int
    private let headPtr: UnsafeMutablePointer<Int>   // producer-owned: next write index
    private let tailPtr: UnsafeMutablePointer<Int>   // consumer-owned: next read index

    init(minimumCapacitySamples: Int) {
        var cap = 1
        while cap < max(2, minimumCapacitySamples) { cap <<= 1 }
        self.capacity = cap
        self.mask = cap - 1
        self.storage = UnsafeMutablePointer<Float>.allocate(capacity: cap)
        self.storage.initialize(repeating: 0, count: cap)
        self.headPtr = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        self.tailPtr = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        headPtr.initialize(to: 0)
        tailPtr.initialize(to: 0)
    }

    deinit {
        storage.deallocate()
        headPtr.deallocate()
        tailPtr.deallocate()
    }

    /// Producer side. Real-time safe: no allocation, no locks. Returns false if the
    /// chunk didn't fit (dropped).
    @discardableResult
    func write(_ src: UnsafePointer<Float>, count: Int) -> Bool {
        let h = headPtr.pointee
        let t = tailPtr.pointee
        OSMemoryBarrier()                 // acquire: see the consumer's tail
        let used = (h &- t) & mask
        let free = capacity - 1 - used
        if count > free { return false }
        let first = min(count, capacity - (h & mask))
        storage.advanced(by: h & mask).update(from: src, count: first)
        if count > first { storage.update(from: src.advanced(by: first), count: count - first) }
        OSMemoryBarrier()                 // release: publish data before advancing head
        headPtr.pointee = (h &+ count) & mask
        return true
    }

    /// Consumer side. Copies up to `maxCount` available samples into `dst`,
    /// returning the count copied.
    func read(into dst: UnsafeMutablePointer<Float>, maxCount: Int) -> Int {
        let t = tailPtr.pointee
        let h = headPtr.pointee
        OSMemoryBarrier()                 // acquire: see the producer's data
        let available = (h &- t) & mask
        if available == 0 { return 0 }
        let count = min(available, maxCount)
        let first = min(count, capacity - (t & mask))
        dst.update(from: storage.advanced(by: t & mask), count: first)
        if count > first { dst.advanced(by: first).update(from: storage, count: count - first) }
        OSMemoryBarrier()                 // release: finish reading before advancing tail
        tailPtr.pointee = (t &+ count) & mask
        return count
    }

    /// Drop all buffered samples. Only safe while neither thread is active (call
    /// from `stop()`).
    func reset() {
        OSMemoryBarrier()
        tailPtr.pointee = headPtr.pointee
        OSMemoryBarrier()
    }
}

#else

/// Fallback for platforms without AVFoundation (none ship this package — the floor
/// is macOS 14 — but this keeps the file compiling anywhere). Inert no-ops.
public final class SyncedLocalSink: @unchecked Sendable {
    public static let defaultSafetyMarginMs: Double = 3.0
    public init(
        renderSampleRate: Double = 48_000,
        channelCount: Int = 2,
        maxBufferedSeconds: Double = 8,
        maxRenderFrames: Int = 8192,
        safetyMarginMs: Double = SyncedLocalSink.defaultSafetyMarginMs,
        presentationDelayMs: @escaping @Sendable () -> Int,
        localOutputLatency: @escaping @Sendable () -> LocalOutputLatencyMeasurement? = { nil }
    ) {}
    public var latestPhaseErrorNanos: Int64 { 0 }
    public func start() throws {}
    public func stop() {}
    public func enqueue(interleavedFrames: UnsafePointer<Float>, frameCount: Int, pts: timespec) {}
}

#endif
