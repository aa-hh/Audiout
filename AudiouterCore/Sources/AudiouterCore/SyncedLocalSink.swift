// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 ahh and contributors.

import Foundation

#if canImport(AVFoundation)
import AVFoundation
#endif

#if canImport(AudioToolbox)
import AudioToolbox
#endif

// The pure timing math (`SyncTiming`) and the T-CORRECTION DSP
// (`FractionalResampler` + `PhaseController`) live in `SyncCore.swift` — the
// deliberately license-clean shared core (PLAN-UNIVERSAL-SYNC Decision 5).

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
/// ## Scope
/// The frame-accurate release gate, the T-LIFECYCLE device-change /
/// sleep-wake rebuild ("MARK: T-LIFECYCLE" below), the T-CORRECTION
/// continuous drift correction (`SyncCore.swift`'s resampler + PI
/// loop, driven from `renderInterleaved`), and the T-OFFSET-UI user bias
/// (`userOffsetMs`) all live here. The tap self-exclude that prevents an
/// echo feedback loop is the fan-out's job (T-FANOUT), not this file's.
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
    /// knob).
    public static let defaultSafetyMarginMs: Double = 3.0

    /// The device-native render rate this sink was built for (read ONCE at
    /// construction from `kAudioHardwarePropertyDefaultOutputDevice`'s
    /// `kAudioDevicePropertyNominalSampleRate`; see `makeBackend`). Public so the
    /// whole-system fan-out (``NativeCaptureCoordinator``) can base-resample the
    /// 44.1 kHz airplay feed UP to it once before the ring — opening the sink's
    /// engine at the device's own rate is what stops the "adding the Mac silences
    /// AirPlay" renegotiation (plan Part B). All render/timing math below is keyed
    /// off this value, never a hardcoded 44100.
    public let renderSampleRate: Double
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
    /// Reads the LIVE user sync-offset bias (T-OFFSET-UI, ms — signed,
    /// ``AppSettings/syncOffsetMs``). Sampled at the same points as
    /// `presentationDelayMs`/`localOutputLatency` (session anchor + lifecycle
    /// rebuild), never on the render path, so a Settings change takes effect on the
    /// next connect or rebuild rather than needing a render-thread-safe live poke.
    private let userOffsetMs: @Sendable () -> Int

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

    // T-CORRECTION — continuous phase-lock DSP (see `SyncCore.swift`). Both
    // are touched only by the single render (consumer) thread while streaming, and
    // reset only while the engine is stopped (`clearSessionState`), so they follow
    // the same single-consumer, no-render-thread-lock contract as the ring read.
    /// Reads the ring at a variable `1 ± ppm` rate via cubic interpolation, so the
    /// buffered audio can be micro-sped/slowed inaudibly to hold phase (replaces the
    /// old 1:1 `ring.read` at the drain site).
    private let resampler: FractionalResampler
    /// PI loop nulling the per-cycle residual phase error; drives `resampler`'s rate.
    private let phaseController = PhaseController()

    private let stateLock = NSLock()
    private let graphQueue = DispatchQueue(label: "com.audiouter.syncedlocalsink.graph")
    /// T-LIFECYCLE: dedicated queue for the default-output-device listener, kept
    /// independent of `graphQueue` so installing/removing the listener never
    /// contends with (or nests inside) a graph rebuild running on `graphQueue`.
    private let lifecycleQueue = DispatchQueue(label: "com.audiouter.syncedlocalsink.lifecycle")
    #if canImport(AudioToolbox)
    private var deviceChangeListenerBlock: AudioObjectPropertyListenerBlock?
    #endif
    private var started = false
    /// `stateLock`-guarded last-flushed baselines for the ring's cumulative
    /// overflow counters (see `clearSessionState()`'s `sync_ring_overflow`
    /// flush) — the ring's own counters are never reset, so a torn flush can
    /// never lose a drop; anything a flush misses rides into the next delta.
    private var lastReportedRingDroppedWrites = 0
    private var lastReportedRingDroppedSamples = 0
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
    /// frame at release, and the correction loop keeps it there over time.
    private var lastPhaseErrorNanos: Int64 = 0
    /// `group × device` gain applied to this sink's real-time output — deliberately
    /// EXCLUDING Main, which the Mac's own system volume already applies to this
    /// device; multiplying it again here would double-apply it. Set via `setGain(_:)`
    /// (``NativeBackend`` calls it whenever the computed gain changes).
    ///
    /// razor: piggybacked onto the render path's existing `stateLock.try()` (see
    /// `renderInterleaved`) rather than a dedicated atomic — the lock is already
    /// taken every cycle for `anchored`/`released`/`lastPhaseErrorNanos`, so one more
    /// `Float` costs nothing extra, and a missed `try()` just replays the previous
    /// cycle's gain for one render (inaudible), the same tradeoff the phase-error
    /// readout above already makes. If gain ever needs a harder guarantee (e.g.
    /// sample-accurate fades), upgrade to a lock-free atomic (bit-cast the `Float`
    /// into an `UnsafeAtomic<UInt32>`) instead of adding a second lock.
    private var gain: Float = 1.0

    public init(
        renderSampleRate: Double = 48_000,
        channelCount: Int = 2,
        maxBufferedSeconds: Double = 8,
        maxRenderFrames: Int = 8192,
        safetyMarginMs: Double = SyncedLocalSink.defaultSafetyMarginMs,
        presentationDelayMs: @escaping @Sendable () -> Int,
        localOutputLatency: @escaping @Sendable () -> LocalOutputLatencyMeasurement? = { try? LocalOutputLatency.measure() },
        userOffsetMs: @escaping @Sendable () -> Int = { AppSettings().syncOffsetMs }
    ) {
        let channels = max(1, channelCount)
        self.renderSampleRate = renderSampleRate
        self.channelCount = channels
        self.safetyMarginMs = safetyMarginMs
        self.maxRenderFrames = max(1, maxRenderFrames)
        self.presentationDelayMs = presentationDelayMs
        self.localOutputLatency = localOutputLatency
        self.userOffsetMs = userOffsetMs

        // The ring is the delay line: during the ~presentationDelay pre-roll the
        // producer fills while the consumer drains nothing, so capacity must exceed
        // the delay's worth of audio (default 8 s > the 5 s max start-buffer).
        let minSamples = Int((maxBufferedSeconds * renderSampleRate).rounded()) * channels
        self.ring = InterleavedFloatRing(minimumCapacitySamples: minSamples)

        self.deinterleaveScratchCapacity = self.maxRenderFrames * channels
        self.deinterleaveScratch = UnsafeMutablePointer<Float>.allocate(capacity: deinterleaveScratchCapacity)
        self.deinterleaveScratch.initialize(repeating: 0, count: deinterleaveScratchCapacity)

        self.resampler = FractionalResampler(channelCount: channels)

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
        self.lifecycleHooks = makeLiveLifecycleHooks()
    }

    deinit {
        stopObservingLifecycleEvents()
        deinterleaveScratch.deallocate()
    }

    /// Signed residual phase error (ns) captured at release — the seam
    /// T-SPIKE-PHASE reads and T-CORRECTION drives to zero.
    public var latestPhaseErrorNanos: Int64 {
        stateLock.withLock { lastPhaseErrorNanos }
    }

    /// Test seam: the ring's cumulative producer-overflow drop counters
    /// (chunks, samples). Never reset — see `clearSessionState()`'s flush.
    var ringOverflowDropsForTesting: (writes: Int, samples: Int) {
        (ring.droppedWrites, ring.droppedSamples)
    }

    /// Sets the `group × device` gain applied to this sink's output (see `gain`
    /// above for the synchronization contract and why Main is excluded). Callable
    /// from any thread — `NativeBackend` calls this off the render path whenever
    /// the computed gain changes.
    public func setGain(_ gain: Float) {
        stateLock.withLock { self.gain = gain }
    }

    // MARK: Lifecycle

    /// Build the graph and start the engine against the current default output
    /// device. Idempotent.
    public func start() throws {
        try graphQueue.sync {
            guard !started else { return }
            let delay = measureTotalDelayNanos()
            stateLock.withLock { cachedTotalDelayNanos = delay }

            engine.attach(sourceNode)

            // ── T-CORRECTION / T-SPIKE-PHASE ────────────────────────────────────
            // The rate correction is NOT a separate graph node. Per the
            // T-SPIKE-PHASE finding (`dev/notes/phase-lock-spike-findings.md` §5:
            // AVAudioUnitVarispeed adds a fixed 1 ms latency, AVAudioUnitTimePitch is
            // an unsuitable phase vocoder), the correction lives INSIDE this source
            // node's render block: `renderInterleaved` drains the ring through
            // `resampler` (a custom fractional cubic resampler) at a rate the
            // `phaseController` PI loop steers to null `latestPhaseErrorNanos`
            // continuously. So the graph stays the simple sourceNode → mixer
            // connection — no added node, no added latency, no reconnection race
            // with T-LIFECYCLE — and all the correction is in the DSP below.
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
        teardownEngine()
        clearSessionState()
    }

    /// Sample the delay off the render path, so the render block never touches
    /// the actor-isolated engine read or a Core Audio latency probe. Factored out
    /// of `start()` so T-LIFECYCLE's rebuild can call it as its own explicit
    /// "re-measure" step, independent of the engine attach/connect/start below.
    private func measureTotalDelayNanos() -> Int64 {
        SyncTiming.totalDelayNanos(
            presentationDelayMs: presentationDelayMs(),
            localOutputLatencySeconds: localOutputLatency()?.totalSeconds ?? 0,
            safetyMarginMs: safetyMarginMs,
            // `userOffsetMs` stays a whole-ms `Int` here (T-OFFSET-UI owns no
            // fractional resolution) — widened only at this call, matching
            // `totalDelayNanos`'s now-`Double` parameter (BT-SYNC-DRAWER T1).
            userOffsetMs: Double(userOffsetMs()))
    }

    /// Just the engine-level teardown half of `stop()` — no session-state reset.
    /// Split out so T-LIFECYCLE's rebuild can sequence "stop engine" and "reset
    /// session state" as two distinct, separately-testable steps even though a
    /// plain `stop()` still does both together.
    private func teardownEngine() {
        graphQueue.sync {
            if started {
                sourceNode.reset()
                engine.stop()
                started = false
            }
        }
    }

    /// Just the session/anchor-state half of `stop()` — no engine teardown. Split
    /// out for the same reason as `teardownEngine()` above.
    private func clearSessionState() {
        // Flush the ring's producer-side overflow counters as ONE
        // `sync_ring_overflow` line, only when drops actually accrued since the
        // last flush — a healthy session logs nothing. This is the sink's
        // off-render-thread choke point every session end passes through
        // (`stop()` and every T-LIFECYCLE rebuild), so the emission never runs
        // on the tap delivery or render thread; the producer pays one plain
        // increment per dropped chunk and nothing else.
        // razor: per-session-boundary flush, not mid-session sampling — this
        // sink has no periodic off-thread sampler to piggyback on; if one ever
        // exists, drive the same delta-gate from it.
        let droppedWrites = ring.droppedWrites
        let droppedSamples = ring.droppedSamples
        var writesDelta = 0
        var samplesDelta = 0
        stateLock.withLock {
            anchored = false
            released = false
            targetReleaseNanos = 0
            cachedTotalDelayNanos = nil
            lastPhaseErrorNanos = 0
            writesDelta = droppedWrites - lastReportedRingDroppedWrites
            samplesDelta = droppedSamples - lastReportedRingDroppedSamples
            lastReportedRingDroppedWrites = droppedWrites
            lastReportedRingDroppedSamples = droppedSamples
        }
        if writesDelta > 0 {
            Telemetry.log(.localPlayback, "sync_ring_overflow", [
                "droppedWritesDelta": String(writesDelta),
                "droppedFramesDelta": String(samplesDelta / channelCount),
                "droppedWritesTotal": String(droppedWrites),
                "droppedFramesTotal": String(droppedSamples / channelCount),
            ])
        }
        ring.reset()
        // T-CORRECTION: the render thread is stopped by the time a rebuild reaches
        // here (teardownEngine ran first), so resetting the render-thread-owned DSP
        // is safe. A stale phase accumulator / integrator from the pre-event session
        // would otherwise fight the fresh anchor's first cycles.
        resampler.reset()
        phaseController.reset()
    }

    // MARK: T-LIFECYCLE — device-change + sleep/wake rebuild

    /// The four steps of a lifecycle rebuild, factored into swappable closures so
    /// a unit test can assert their ORDER without a real device change, a real
    /// sleep/wake, or a real `AVAudioEngine`/Core Audio device (`@testable import`
    /// substitutes a recording stub before driving the trigger methods below).
    /// Production leaves this at its `init` default, which wires each step to the
    /// real engine/session methods on this type.
    ///
    /// Per the plan's "always rebuild, don't diff" rule (brief §7/§3): every
    /// trigger below — default-output-device change, sleep, or wake — runs this
    /// SAME full sequence. The mach↔`CLOCK_MONOTONIC` rebase used by the render
    /// block (`CoreAudioSystemTap.timespec(fromHostTime:)`) re-seeds itself on
    /// every call already (no cached offset in this file to go stale), so the only
    /// state this file must explicitly clear is the release anchor (`anchored`/
    /// `released`/`targetReleaseNanos`/`cachedTotalDelayNanos`/
    /// `lastPhaseErrorNanos`) — a stale anchor from before the event would target
    /// the OLD device's latency or a pts from before the sleep gap.
    struct LifecycleHooks {
        var stopEngine: () -> Void
        var remeasureLatency: () -> Int64
        var resetSessionState: (Int64) -> Void
        var restartEngine: () -> Void
    }

    var lifecycleHooks: LifecycleHooks!

    private func makeLiveLifecycleHooks() -> LifecycleHooks {
        LifecycleHooks(
            stopEngine: { [weak self] in self?.teardownEngine() },
            remeasureLatency: { [weak self] in self?.measureTotalDelayNanos() ?? 0 },
            resetSessionState: { [weak self] _ in self?.clearSessionState() },
            restartEngine: { [weak self] in try? self?.start() })
    }

    /// Runs the four hooks in order: stop → re-measure → reset → restart. Never
    /// throws — a failed restart (e.g. the new default device rejects the format
    /// momentarily) just leaves the sink stopped until the next lifecycle event,
    /// same posture as any other best-effort recovery path in this file.
    private func performLifecycleRebuild() {
        lifecycleHooks.stopEngine()
        let delay = lifecycleHooks.remeasureLatency()
        lifecycleHooks.resetSessionState(delay)
        lifecycleHooks.restartEngine()
    }

    /// Called by the Core Audio listener block installed in
    /// ``startObservingLifecycleEvents()`` when
    /// `kAudioHardwarePropertyDefaultOutputDevice` changes. Internal (not
    /// `private`) so a test can drive it directly — via `@testable import` — to
    /// simulate a device change without a real Core Audio callback.
    func handleDefaultOutputDeviceChanged() {
        performLifecycleRebuild()
    }

    /// Wave-4 delay agreement (BT-REFSEL follow-on): the REFERENCE TIMELINE
    /// itself moved — e.g. AirPlay joined or left a BT+Mac selection, flipping
    /// this sink's delay between the AirPlay start-buffer and the BT-only
    /// buffer. Same full rebuild as a device change: the fresh session anchor
    /// re-samples `presentationDelayMs`, which is what actually lands the new
    /// reference.
    public func requestReanchor(cause: String) {
        Telemetry.log(.localPlayback, "synced_local_reanchor", ["cause": cause])
        performLifecycleRebuild()
    }

    /// Wired externally to `NSWorkspace.willSleepNotification`. `AudiouterCore`
    /// must never import AppKit (package rule, `AudiouterCore/AGENTS.md`), so —
    /// same idiom as ``OutputBackend/handleSystemWillSleep()`` — this is a plain
    /// public method the AppKit-importing layer forwards the notification to,
    /// rather than an observer this type installs itself.
    public func handleSystemWillSleep() {
        performLifecycleRebuild()
    }

    /// Wired externally to `NSWorkspace.didWakeNotification` — see
    /// ``handleSystemWillSleep()``.
    public func handleSystemDidWake() {
        performLifecycleRebuild()
    }

    #if canImport(AudioToolbox)
    private var defaultOutputDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    /// Install the `kAudioHardwarePropertyDefaultOutputDevice` listener — same
    /// block-based `AudioObjectAddPropertyListenerBlock` idiom as
    /// `NativeCaptureCoordinator.installDefaultDeviceListener()` /
    /// `DefaultOutputObserver`, reused rather than reinvented. Idempotent. Kept
    /// independent of `start()`/`stop()` (its own queue, its own lifetime) so a
    /// device change that arrives while the sink is deliberately stopped doesn't
    /// need special-casing here — ``performLifecycleRebuild()`` calling `start()`
    /// again is the caller's concern (T-BACKEND wires whether the sink should be
    /// running at all).
    public func startObservingLifecycleEvents() {
        lifecycleQueue.sync {
            guard deviceChangeListenerBlock == nil else { return }
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.handleDefaultOutputDeviceChanged()
            }
            deviceChangeListenerBlock = block
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &defaultOutputDeviceAddress, lifecycleQueue, block)
        }
    }

    /// Remove the listener installed by ``startObservingLifecycleEvents()``.
    /// Idempotent; also called from `deinit`.
    public func stopObservingLifecycleEvents() {
        lifecycleQueue.sync {
            guard let block = deviceChangeListenerBlock else { return }
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &defaultOutputDeviceAddress, lifecycleQueue, block)
            deviceChangeListenerBlock = nil
        }
    }
    #else
    public func startObservingLifecycleEvents() {}
    public func stopObservingLifecycleEvents() {}
    #endif

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
                    safetyMarginMs: safetyMarginMs,
                    userOffsetMs: Double(userOffsetMs()))
                cachedTotalDelayNanos = delay
                anchored = true
                targetReleaseNanos = SyncTiming.targetReleaseMonotonicNanos(
                    anchorPtsNanos: ptsNanos, totalDelayNanos: delay)
                // Connect-latency diagnosis: the deliberate, by-design pre-roll
                // silence this session will hold before its first real frame
                // releases — distinguishes "intentional sync buffer" from
                // unexplained latency elsewhere in the pipeline. Fires once per
                // session anchor (this branch), not per render cycle — matches
                // this call's existing one-time-lock cost, not the RT render
                // path's stricter budget (see the doc comment above).
                Telemetry.log(.localPlayback, "sync_session_anchored", [
                    "delayNanos": "\(delay)",
                    "delayMs": String(format: "%.1f", Double(delay) / 1_000_000),
                ])
            }
            stateLock.unlock()
        }

        // A full ring drops the chunk (never blocks); the ring counts the drop
        // itself and `clearSessionState()` flushes it as `sync_ring_overflow`.
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
    ///
    /// T-CORRECTION: once released, the ring is drained through `resampler` at a rate
    /// the `phaseController` PI loop steers each cycle to null the residual phase
    /// error — the CONTINUOUS phase-lock, not a one-shot anchor. The phase error is
    /// re-estimated EVERY cycle (not just at release) as the gap between where the
    /// output's content position IS (`resampler.inputFramesConsumed`) and where the
    /// reference timeline says it SHOULD be at this cycle's presentation instant:
    /// any ppm clock skew between the reference (PTP-grandmaster) domain and the
    /// local output device shows up here as a slow drift the loop cancels.
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
        var target: Int64 = 0
        var gainSnapshot: Float = 1.0
        if stateLock.try() {
            gainSnapshot = gain
            if anchored {
                target = targetReleaseNanos
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

        // ── T-CORRECTION: measure phase error, drive the PI loop + resampler ──────
        // The instant the first real sample of THIS cycle is presented, and the
        // content position (input frames consumed) the output has reached going in.
        // At the release cycle `inputFramesConsumed == 0` and `audioStartNanos ≈
        // target`, so `phaseErrorNanos` reduces exactly to the old one-shot
        // `firstRealNanos − target` — this generalizes that readout to every cycle.
        let nsPerFrame = 1_000_000_000.0 / renderSampleRate
        let audioStartNanos = cycleStartMonotonicNanos
            &+ Int64((Double(silentFrames) * nsPerFrame).rounded())
        // The CONTINUOUS content position (fractional, not the integer pull count) —
        // using the integer count would leave a ±½-frame sawtooth the loop can't null.
        let contentFramesBefore = resampler.consumedContentFrames
        let phaseErrorNanos =
            Double(audioStartNanos &- target) - contentFramesBefore * nsPerFrame

        phaseController.update(phaseErrorNanos: phaseErrorNanos, nsPerFrame: nsPerFrame)
        let ratio = phaseController.ratio

        let outFrames = frameCount - silentFrames
        // Drain the ring at `ratio` input-frames-per-output-frame via cubic
        // interpolation. `pullFrame` reads exactly one interleaved frame; the ring
        // only ever holds whole frames (writes are frame-multiples), so a short read
        // means the ring is empty, not a partial frame.
        let produced = resampler.render(
            into: out, outFrameOffset: silentFrames, outFrames: outFrames, ratio: ratio
        ) { framePtr in
            ring.read(into: framePtr, maxCount: channelCount) == channelCount
        }

        // Apply the group×device gain (never Main — see `gain`'s doc comment) to the
        // real samples this cycle produced. Skipped entirely at unity so a gain of
        // 1.0 is byte-identical to the ungained render, not just numerically equal.
        if gainSnapshot != 1.0 {
            let start = silentFrames * channelCount
            let producedSamples = produced * channelCount
            for i in 0..<producedSamples { base[start + i] *= gainSnapshot }
        }

        // Underrun: zero-fill the shortfall so a starved ring is silence, not garbage.
        if produced < outFrames {
            let tailStart = (silentFrames + produced) * channelCount
            base.advanced(by: tailStart).update(repeating: 0, count: total - tailStart)
        }

        // Publish the phase-error readout the correction loop just acted on, for
        // `latestPhaseErrorNanos`. A missed `try()` just leaves the previous cycle's
        // value visible — it is a monitoring readout, never on the control path.
        if stateLock.try() {
            lastPhaseErrorNanos = Int64(phaseErrorNanos.rounded())
            stateLock.unlock()
        }
        return produced > 0
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
    // Producer-owned overflow counters (whole-system dropout investigation):
    // the overflow branch in `write` was the sink's one silently-discarded drop
    // site — a full ring ate whole chunks with zero visibility. Same
    // aligned-word/heap-cell idiom as `headPtr` (single writer: the producer
    // thread; word loads/stores are atomic on Apple silicon). Monotonic
    // diagnostics, so the off-thread reader tolerates a slightly-stale read and
    // no barrier is paid on this path.
    private let droppedWritesPtr: UnsafeMutablePointer<Int>
    private let droppedSamplesPtr: UnsafeMutablePointer<Int>

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
        self.droppedWritesPtr = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        self.droppedSamplesPtr = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        droppedWritesPtr.initialize(to: 0)
        droppedSamplesPtr.initialize(to: 0)
    }

    deinit {
        storage.deallocate()
        headPtr.deallocate()
        tailPtr.deallocate()
        droppedWritesPtr.deallocate()
        droppedSamplesPtr.deallocate()
    }

    /// Cumulative producer chunks dropped on overflow (never reset — the
    /// consumer keeps its own last-reported baseline).
    var droppedWrites: Int { droppedWritesPtr.pointee }
    /// Cumulative samples those dropped chunks carried.
    var droppedSamples: Int { droppedSamplesPtr.pointee }

    /// Producer side. Real-time safe: no allocation, no locks. Returns false if the
    /// chunk didn't fit (dropped — counted in `droppedWrites`/`droppedSamples`).
    @discardableResult
    func write(_ src: UnsafePointer<Float>, count: Int) -> Bool {
        let h = headPtr.pointee
        let t = tailPtr.pointee
        OSMemoryBarrier()                 // acquire: see the consumer's tail
        let used = (h &- t) & mask
        let free = capacity - 1 - used
        if count > free {
            droppedWritesPtr.pointee &+= 1
            droppedSamplesPtr.pointee &+= count
            return false
        }
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
    public let renderSampleRate: Double
    public init(
        renderSampleRate: Double = 48_000,
        channelCount: Int = 2,
        maxBufferedSeconds: Double = 8,
        maxRenderFrames: Int = 8192,
        safetyMarginMs: Double = SyncedLocalSink.defaultSafetyMarginMs,
        presentationDelayMs: @escaping @Sendable () -> Int,
        localOutputLatency: @escaping @Sendable () -> LocalOutputLatencyMeasurement? = { nil },
        userOffsetMs: @escaping @Sendable () -> Int = { AppSettings().syncOffsetMs }
    ) {
        self.renderSampleRate = renderSampleRate
    }
    public var latestPhaseErrorNanos: Int64 { 0 }
    public func start() throws {}
    public func stop() {}
    public func setGain(_ gain: Float) {}
    public func enqueue(interleavedFrames: UnsafePointer<Float>, frameCount: Int, pts: timespec) {}
    // T-LIFECYCLE: API parity no-ops for the AVFoundation-less fallback.
    public func handleSystemWillSleep() {}
    public func handleSystemDidWake() {}
    public func startObservingLifecycleEvents() {}
    public func stopObservingLifecycleEvents() {}
}

#endif
