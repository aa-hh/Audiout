import Testing
import Foundation
@testable import AudiouterCore

/// T-SINK: the synced local sink stays silent until the output device's clock
/// reaches `capture_pts + presentationDelay − localOutputLatency − safetyMargin`,
/// then emits the buffered audio in order. These run fully offline — no
/// `AVAudioEngine.start()`, no real output device, no sound — by driving the
/// render core (`renderInterleaved`) directly with synthetic cycle times, exactly
/// the harness the plan's T-SINK verify step calls for.
@Suite final class SyncedLocalSinkTests: IsolatedSuite {

    // MARK: Pure timing math

    @Test func totalDelayNanos_subtractsLatencyAndMargin() {
        // 100 ms presentation − 10 ms local latency − 3 ms safety = 87 ms.
        let delay = SyncTiming.totalDelayNanos(
            presentationDelayMs: 100, localOutputLatencySeconds: 0.010, safetyMarginMs: 3)
        #expect(delay == 87_000_000)
    }

    @Test func totalDelayNanos_clampsAtZero() {
        // Local latency larger than the AirPlay buffer would go negative → clamp 0.
        let delay = SyncTiming.totalDelayNanos(
            presentationDelayMs: 5, localOutputLatencySeconds: 0.050, safetyMarginMs: 3)
        #expect(delay == 0)
    }

    // MARK: T-OFFSET-UI — manual ms sync-offset bias

    @Test func totalDelayNanos_defaultsToNoUserOffset() {
        // Omitting `userOffsetMs` must be identical to passing 0 — existing
        // callers (T-SINK/T-LIFECYCLE) that predate T-OFFSET-UI stay unaffected.
        let withDefault = SyncTiming.totalDelayNanos(
            presentationDelayMs: 100, localOutputLatencySeconds: 0.010, safetyMarginMs: 3)
        let withExplicitZero = SyncTiming.totalDelayNanos(
            presentationDelayMs: 100, localOutputLatencySeconds: 0.010, safetyMarginMs: 3, userOffsetMs: 0)
        #expect(withDefault == withExplicitZero)
        #expect(withDefault == 87_000_000)
    }

    @Test func totalDelayNanos_positiveUserOffset_shiftsTargetLater() {
        // 100 ms presentation − 10 ms latency − 3 ms safety = 87 ms base, +50 ms
        // user bias → 137 ms. The offset is a straightforward additive shift.
        let delay = SyncTiming.totalDelayNanos(
            presentationDelayMs: 100, localOutputLatencySeconds: 0.010, safetyMarginMs: 3, userOffsetMs: 50)
        #expect(delay == 137_000_000)
    }

    @Test func totalDelayNanos_negativeUserOffset_shiftsTargetEarlier() {
        // Same 87 ms base, −20 ms user bias → 67 ms.
        let delay = SyncTiming.totalDelayNanos(
            presentationDelayMs: 100, localOutputLatencySeconds: 0.010, safetyMarginMs: 3, userOffsetMs: -20)
        #expect(delay == 67_000_000)
    }

    @Test func totalDelayNanos_negativeUserOffset_stillClampsAtZero() {
        // A negative offset large enough to push the total below zero must still
        // floor at 0 — a delay can never be negative, whatever the user dials in.
        let delay = SyncTiming.totalDelayNanos(
            presentationDelayMs: 100, localOutputLatencySeconds: 0.010, safetyMarginMs: 3, userOffsetMs: -1_000)
        #expect(delay == 0)
    }

    @Test func totalDelayNanos_userOffsetShiftIsExactlyTheOffsetMagnitude() {
        // The general contract the plan's Verify step calls for: changing the
        // offset by N ms shifts the resulting delay by exactly N ms, regardless of
        // the base terms — as long as the result doesn't hit the zero floor.
        let base = SyncTiming.totalDelayNanos(
            presentationDelayMs: 300, localOutputLatencySeconds: 0.005, safetyMarginMs: 3)
        for offsetMs in [-200, -1, 1, 42, 400] {
            let shifted = SyncTiming.totalDelayNanos(
                presentationDelayMs: 300, localOutputLatencySeconds: 0.005, safetyMarginMs: 3,
                userOffsetMs: Double(offsetMs))
            #expect(shifted == base + Int64(offsetMs) * 1_000_000)
        }
    }

    /// A trivial `@unchecked Sendable` mutable box — lets the test mutate the
    /// user-offset value the sink's injected closure reads, across two calls,
    /// without a captured `var` tripping Swift 6 strict-concurrency capture
    /// checking on the `@Sendable () -> Int` closure parameter.
    private final class MutableIntBox: @unchecked Sendable {
        var value = 0
    }

    @Test func syncedLocalSink_measuresDelayUsingLiveUserOffset() throws {
        // End-to-end (still offline/no real device): the sink's own delay
        // measurement — not just the free `SyncTiming` function — must fold in
        // the injected `userOffsetMs` closure, and must re-read it live rather
        // than caching the value from `init`.
        let offset = MutableIntBox()
        let latency = LocalOutputLatencyMeasurement(
            safetyOffsetFrames: 0, deviceLatencyFrames: 0, streamLatencyFrames: 0,
            bufferFrameSizeFrames: 0, nominalSampleRate: 48_000)
        let sink = SyncedLocalSink(
            renderSampleRate: 48_000, channelCount: 1,
            safetyMarginMs: 0,
            presentationDelayMs: { 100 },
            localOutputLatency: { latency },
            userOffsetMs: { offset.value })

        let delay = sink.lifecycleHooks.remeasureLatency()
        #expect(delay == 100_000_000, "no offset yet: plain 100 ms presentation delay")

        offset.value = 25
        let shiftedDelay = sink.lifecycleHooks.remeasureLatency()
        #expect(shiftedDelay == 125_000_000, "the live closure must be re-read, not cached")
    }

    /// A zero presentation delay (edge case: an engine buffer config that reports
    /// no AirPlay-side latency at all) must never go negative — it clamps to 0, the
    /// same floor as any other combination that would otherwise underflow.
    @Test func totalDelayNanos_zeroPresentationDelay_clampsAtZero() {
        let delay = SyncTiming.totalDelayNanos(
            presentationDelayMs: 0, localOutputLatencySeconds: 0.001, safetyMarginMs: 3)
        #expect(delay == 0)
    }

    /// A negative presentation delay should never reach this function in practice
    /// (the engine's ms value is always ≥ 0), but the clamp must hold defensively
    /// anyway — a negative input must never produce a negative (or, worse, huge
    /// unsigned-wraparound) delay.
    @Test func totalDelayNanos_negativePresentationDelay_clampsAtZero() {
        let delay = SyncTiming.totalDelayNanos(
            presentationDelayMs: -50, localOutputLatencySeconds: 0.010, safetyMarginMs: 3)
        #expect(delay == 0)
    }

    /// A zero presentation delay with zero latency/margin is the exact `delta == 0`
    /// boundary once fed through `plan(...)`: releases at frame 0 of the cycle that
    /// starts exactly at the target, not "silent forever" or an off-by-one frame.
    @Test func plan_exactlyAtTarget_releasesAtFrameZero() {
        let plan = SyncTiming.plan(
            cycleStartMonotonicNanos: 5_000_000_000, frameCount: 512,
            sampleRate: 48_000, targetReleaseMonotonicNanos: 5_000_000_000)
        #expect(plan == SyncTiming.RenderPlan(silentFrames: 0, releasesThisCycle: true))
    }

    /// T3 Part B: `plan(...)`'s frame math must be keyed off the LIVE
    /// `renderSampleRate` (`SyncedLocalSink.renderSampleRate`, never a hardcoded
    /// 44100 — the plan's verify step). The delay in TIME is identical whatever
    /// the device runs at, but the number of silent FRAMES needed to reach it
    /// scales up proportionally with the sample rate: the same 20 ms gap is 882
    /// frames at 44.1 kHz and 960 frames at 48 kHz — exactly the
    /// 48000/44100 ratio, and neither a fixed frame count nor a fixed 44.1 kHz
    /// assumption would produce that.
    @Test func plan_silentFrameOffset_scalesWithRenderSampleRate() {
        let cycleStart: Int64 = 1_000_000_000
        let deltaNanos: Int64 = 20_000_000 // 20 ms
        let target = cycleStart &+ deltaNanos

        let at44_1 = SyncTiming.plan(
            cycleStartMonotonicNanos: cycleStart, frameCount: 4_096,
            sampleRate: 44_100, targetReleaseMonotonicNanos: target)
        let at48 = SyncTiming.plan(
            cycleStartMonotonicNanos: cycleStart, frameCount: 4_096,
            sampleRate: 48_000, targetReleaseMonotonicNanos: target)

        #expect(at44_1.silentFrames == 882, "20 ms @ 44.1 kHz = 882 frames")
        #expect(at48.silentFrames == 960, "20 ms @ 48 kHz = 960 frames")
        #expect(at44_1.releasesThisCycle)
        #expect(at48.releasesThisCycle)

        let ratio = Double(at48.silentFrames) / Double(at44_1.silentFrames)
        #expect(abs(ratio - 48_000.0 / 44_100.0) <= 1e-6,
                       "the frame-offset ratio between rates must equal the sample-rate ratio")
    }

    /// Same property at the boundary: a gap wider than one cycle's worth of
    /// frames at the SLOWER rate must still fit within one cycle at the FASTER
    /// rate purely because more frames fit in the same wall-clock span — proof
    /// `plan` never silently assumes a fixed frame-count-per-cycle/rate pairing.
    @Test func plan_releaseWithinCycle_dependsOnRateNotJustFrameCount() {
        let cycleStart: Int64 = 0
        // A gap that is exactly 8 ms — 353 frames at 44.1 kHz (fits in a 400-frame
        // cycle) and 384 frames at 48 kHz (also fits) — but scaled differently.
        let deltaNanos: Int64 = 8_000_000
        let target = cycleStart &+ deltaNanos

        let at44_1 = SyncTiming.plan(
            cycleStartMonotonicNanos: cycleStart, frameCount: 400,
            sampleRate: 44_100, targetReleaseMonotonicNanos: target)
        let at48 = SyncTiming.plan(
            cycleStartMonotonicNanos: cycleStart, frameCount: 400,
            sampleRate: 48_000, targetReleaseMonotonicNanos: target)

        #expect(at44_1.releasesThisCycle)
        #expect(at48.releasesThisCycle)
        #expect(at44_1.silentFrames == 353)
        #expect(at48.silentFrames == 384)
        #expect(at48.silentFrames > at44_1.silentFrames,
                             "the same time gap costs more frames at the higher rate")
    }

    @Test func plan_silentBeforeTarget_thenReleasesAtFrameOffset() {
        let sampleRate = 48_000.0
        let target: Int64 = 1_000_000_000 + 87_000_000
        // A cycle wholly before the target is entirely silent, not releasing.
        let early = SyncTiming.plan(
            cycleStartMonotonicNanos: 1_000_000_000, frameCount: 512,
            sampleRate: sampleRate, targetReleaseMonotonicNanos: target)
        #expect(early == SyncTiming.RenderPlan(silentFrames: 512, releasesThisCycle: false))

        // A cycle straddling the target releases part-way through: the silent
        // prefix is the frame-accurate offset to the target.
        let cycleStart: Int64 = 1_000_000_000 + 80_000_000
        let straddle = SyncTiming.plan(
            cycleStartMonotonicNanos: cycleStart, frameCount: 512,
            sampleRate: sampleRate, targetReleaseMonotonicNanos: target)
        #expect(straddle.releasesThisCycle)
        let nsPerFrame = 1_000_000_000.0 / sampleRate
        let expectedOffset = Int((Double(target - cycleStart) / nsPerFrame).rounded())
        #expect(straddle.silentFrames == expectedOffset)
    }

    // MARK: End-to-end render gate (ramp in, first-non-silence lands on target)

    #if canImport(AVFoundation)
    @Test func rampReleasesAtComputedHostTime_withinOneFrame() throws {
        let sampleRate = 48_000.0
        let channels = 1
        let framesPerCycle = 512

        // 100 ms presentation − 10 ms measured latency − 3 ms safety = 87 ms delay.
        let latency = LocalOutputLatencyMeasurement(
            safetyOffsetFrames: 0, deviceLatencyFrames: 480, streamLatencyFrames: 0,
            bufferFrameSizeFrames: 0, nominalSampleRate: sampleRate)   // 480/48000 = 10 ms
        let sink = SyncedLocalSink(
            renderSampleRate: sampleRate,
            channelCount: channels,
            safetyMarginMs: 3,
            presentationDelayMs: { 100 },
            localOutputLatency: { latency })

        // Known ramp with a known pts. Every real sample is strictly non-zero
        // (starts at 1.0) so "first non-silence" is unambiguous, and strictly
        // increasing so we can confirm the drain starts at ramp element 0 (no
        // dropped/reordered samples ahead of the gate).
        let anchorPtsSec = 1_000
        let anchorNanos: Int64 = Int64(anchorPtsSec) * 1_000_000_000
        let rampCount = 20_000
        var ramp = [Float](repeating: 0, count: rampCount)
        for i in 0..<rampCount { ramp[i] = Float(i + 1) }
        ramp.withUnsafeBufferPointer { buf in
            sink.enqueue(
                interleavedFrames: buf.baseAddress!, frameCount: rampCount,
                pts: timespec(tv_sec: anchorPtsSec, tv_nsec: 0))
        }

        let nsPerFrame = 1_000_000_000.0 / sampleRate
        let expectedTargetNanos = anchorNanos + 87_000_000

        var firstNonSilenceHostTime: Int64?
        var firstRealSample: Float?
        var out = [Float](repeating: .nan, count: framesPerCycle)

        for cycle in 0..<40 {
            // Frame-accurate cycle start on the monotonic timeline.
            let cycleStart = anchorNanos + Int64((Double(cycle * framesPerCycle) * nsPerFrame).rounded())
            let produced = out.withUnsafeMutableBufferPointer { ob -> Bool in
                sink.renderInterleaved(
                    into: ob, frameCount: framesPerCycle, cycleStartMonotonicNanos: cycleStart)
            }

            if firstNonSilenceHostTime == nil {
                if let localIdx = out.firstIndex(where: { $0 != 0 }) {
                    firstNonSilenceHostTime = cycleStart + Int64((Double(localIdx) * nsPerFrame).rounded())
                    firstRealSample = out[localIdx]
                    // Everything before the release point in this cycle is silence.
                    #expect(out[0..<localIdx].allSatisfy { $0 == 0 })
                } else {
                    // Pre-release cycles are entirely silent and drain nothing.
                    #expect(!produced)
                    #expect(out.allSatisfy { $0 == 0 })
                }
            }
        }

        let hostTime = try #require(firstNonSilenceHostTime, "audio was never released")
        // First non-silence lands within one frame of the computed target.
        #expect(max(hostTime, expectedTargetNanos) - min(hostTime, expectedTargetNanos) <= Int64(nsPerFrame.rounded()))
        // And it is the very first ramp sample — the delay line released in order.
        #expect(firstRealSample == ramp[0])
        // The residual phase error the correction loop will read is sub-frame.
        #expect(abs(sink.latestPhaseErrorNanos) <= Int64(nsPerFrame.rounded()))
    }

    /// The `group × device` gain actually scales the samples it produces. The unity
    /// path is already pinned by `rampReleasesAtComputedHostTime_withinOneFrame`
    /// above — it never calls `setGain` and asserts the raw ramp value — so this
    /// covers the attenuating path, which no other render test exercises.
    ///
    /// Gains are powers of two so the expected products are exact in binary
    /// floating point and the assertion needs no epsilon.
    @Test(arguments: [Float(0.5), Float(0.25)])
    func gainScalesProducedSamples(gain: Float) throws {
        let sink = Self.rampSink()
        sink.setGain(gain)
        let ramp = Self.enqueueRamp(into: sink)

        let nsPerFrame = 1_000_000_000.0 / 48_000.0
        var firstRealSample: Float?
        var out = [Float](repeating: .nan, count: 512)

        for cycle in 0..<40 where firstRealSample == nil {
            let cycleStart = Self.rampAnchorNanos + Int64((Double(cycle * 512) * nsPerFrame).rounded())
            _ = out.withUnsafeMutableBufferPointer { ob -> Bool in
                sink.renderInterleaved(into: ob, frameCount: 512, cycleStartMonotonicNanos: cycleStart)
            }
            if let localIdx = out.firstIndex(where: { $0 != 0 }) { firstRealSample = out[localIdx] }
        }

        let sample = try #require(firstRealSample, "audio was never released")
        #expect(sample == ramp[0] * gain)
    }

    /// Roadmap 056 Part B: the Mac's half of the alignment wizard's arm gate —
    /// the wizard holds its first tick until every participating sink reports
    /// here, so this must be false before the delay gate opens and true after.
    @Test func hasStartedRenderingFlipsWhenTheDelayGateOpens() throws {
        let sink = Self.rampSink()
        #expect(!sink.hasStartedRendering, "nothing enqueued, nothing playing")
        _ = Self.enqueueRamp(into: sink)
        #expect(!sink.hasStartedRendering, "anchored, but still holding silence")

        let nsPerFrame = 1_000_000_000.0 / 48_000.0
        var out = [Float](repeating: .nan, count: 512)
        for cycle in 0..<40 where !sink.hasStartedRendering {
            let cycleStart = Self.rampAnchorNanos + Int64((Double(cycle * 512) * nsPerFrame).rounded())
            _ = out.withUnsafeMutableBufferPointer { ob -> Bool in
                sink.renderInterleaved(into: ob, frameCount: 512, cycleStartMonotonicNanos: cycleStart)
            }
        }
        #expect(sink.hasStartedRendering, "the gate opened — the Mac is audible")
    }

    /// Gain 0 is silence, not "quiet". Asserted separately from
    /// ``gainScalesProducedSamples(gain:)`` because at zero there is no non-zero
    /// sample to locate the release point by — the drain having run (`produced`)
    /// is the only signal that the gate opened at all.
    @Test func gainOfZeroProducesSilenceEvenAfterRelease() throws {
        let sink = Self.rampSink()
        sink.setGain(0)
        _ = Self.enqueueRamp(into: sink)

        let nsPerFrame = 1_000_000_000.0 / 48_000.0
        var everDrained = false
        var out = [Float](repeating: .nan, count: 512)

        for cycle in 0..<40 {
            let cycleStart = Self.rampAnchorNanos + Int64((Double(cycle * 512) * nsPerFrame).rounded())
            let produced = out.withUnsafeMutableBufferPointer { ob -> Bool in
                sink.renderInterleaved(into: ob, frameCount: 512, cycleStartMonotonicNanos: cycleStart)
            }
            everDrained = everDrained || produced
            // Silent whether the gate was open or not — that is the whole assertion.
            #expect(out.allSatisfy { $0 == 0 })
        }

        #expect(everDrained, "the gate never opened, so silence proves nothing")
    }

    // MARK: Shared ramp fixture (mirrors `rampReleasesAtComputedHostTime_withinOneFrame`)

    static let rampAnchorPtsSec = 1_000
    static let rampAnchorNanos = Int64(rampAnchorPtsSec) * 1_000_000_000

    /// A sink with the same 87 ms effective delay as the ramp-release test above
    /// (100 ms presentation − 10 ms measured latency − 3 ms safety), mono at 48 kHz.
    static func rampSink() -> SyncedLocalSink {
        let latency = LocalOutputLatencyMeasurement(
            safetyOffsetFrames: 0, deviceLatencyFrames: 480, streamLatencyFrames: 0,
            bufferFrameSizeFrames: 0, nominalSampleRate: 48_000.0)
        return SyncedLocalSink(
            renderSampleRate: 48_000.0,
            channelCount: 1,
            safetyMarginMs: 3,
            presentationDelayMs: { 100 },
            localOutputLatency: { latency })
    }

    /// Enqueue a strictly-increasing ramp starting at 1.0, so every real sample is
    /// non-zero and "first non-silence" is unambiguous. Returns the ramp.
    @discardableResult
    static func enqueueRamp(into sink: SyncedLocalSink) -> [Float] {
        var ramp = [Float](repeating: 0, count: 20_000)
        for i in 0..<ramp.count { ramp[i] = Float(i + 1) }
        ramp.withUnsafeBufferPointer { buf in
            sink.enqueue(
                interleavedFrames: buf.baseAddress!, frameCount: ramp.count,
                pts: timespec(tv_sec: rampAnchorPtsSec, tv_nsec: 0))
        }
        return ramp
    }

    @Test func noAudioBeforeEnqueue_isSilent() {
        let sink = SyncedLocalSink(
            renderSampleRate: 48_000, channelCount: 1,
            presentationDelayMs: { 100 }, localOutputLatency: { nil })
        var out = [Float](repeating: 1, count: 256)
        let produced = out.withUnsafeMutableBufferPointer { ob in
            sink.renderInterleaved(into: ob, frameCount: 256, cycleStartMonotonicNanos: 5_000_000_000)
        }
        #expect(!produced)
        #expect(out.allSatisfy { $0 == 0 })
    }

    // MARK: T-LIFECYCLE — device-change + sleep/wake rebuild

    /// Drives the trigger methods directly — no real device change, no real
    /// sleep/wake, no real `AVAudioEngine`/Core Audio device — and asserts the
    /// rebuild fires all four steps in the exact order the plan specifies: stop →
    /// re-measure → reset → restart. `lifecycleHooks` is swapped for a recording
    /// stub (reachable via `@testable import`) so this never touches the real
    /// engine or a Core Audio latency probe.
    @Test func deviceChange_firesRebuildStepsInOrder() {
        let sink = SyncedLocalSink(
            renderSampleRate: 48_000, channelCount: 1,
            presentationDelayMs: { 100 }, localOutputLatency: { nil })

        var order: [String] = []
        sink.lifecycleHooks = SyncedLocalSink.LifecycleHooks(
            stopEngine: { order.append("stop") },
            remeasureLatency: { order.append("remeasure"); return 42 },
            resetSessionState: { delay in
                #expect(delay == 42, "reset must receive the just-remeasured delay")
                order.append("reset")
            },
            restartEngine: { order.append("restart") })

        sink.handleDefaultOutputDeviceChanged()

        #expect(order == ["stop", "remeasure", "reset", "restart"])
    }

    /// Same assertion, driven via the sleep/wake entry points instead of the
    /// device-change one — all three triggers share one rebuild sequence per the
    /// plan's "always rebuild, don't diff" rule (brief §7/§3).
    @Test func willSleepAndDidWake_fireTheSameRebuildStepsInOrder() {
        let sink = SyncedLocalSink(
            renderSampleRate: 48_000, channelCount: 1,
            presentationDelayMs: { 100 }, localOutputLatency: { nil })

        var order: [String] = []
        func stubbedHooks() -> SyncedLocalSink.LifecycleHooks {
            SyncedLocalSink.LifecycleHooks(
                stopEngine: { order.append("stop") },
                remeasureLatency: { order.append("remeasure"); return 0 },
                resetSessionState: { _ in order.append("reset") },
                restartEngine: { order.append("restart") })
        }

        sink.lifecycleHooks = stubbedHooks()
        sink.handleSystemWillSleep()
        #expect(order == ["stop", "remeasure", "reset", "restart"])

        order.removeAll()
        sink.lifecycleHooks = stubbedHooks()
        sink.handleSystemDidWake()
        #expect(order == ["stop", "remeasure", "reset", "restart"])
    }

    /// The live (production-default) `resetSessionState`/`remeasureLatency` hooks
    /// — never swapped — must reach the real `clearSessionState()`/
    /// `measureTotalDelayNanos()` plumbing. Deliberately does NOT drive
    /// `restartEngine`/`stopEngine` here (those touch the real `AVAudioEngine`
    /// and a live device, which this suite avoids per house rule — no real
    /// audio/engine start in tests, verified by `swift build` + offline math
    /// only): after enqueueing then calling `remeasureLatency()` +
    /// `resetSessionState(_:)` directly, the anchor is gone and the sink is
    /// silent again, matching `test_noAudioBeforeEnqueue_isSilent`.
    @Test func liveResetSessionStateHook_clearsAnchorAfterEnqueue() {
        let sink = SyncedLocalSink(
            renderSampleRate: 48_000, channelCount: 1,
            presentationDelayMs: { 100 }, localOutputLatency: { nil })

        var ramp: [Float] = [1, 2, 3, 4]
        ramp.withUnsafeMutableBufferPointer { buf in
            sink.enqueue(
                interleavedFrames: buf.baseAddress!, frameCount: buf.count,
                pts: timespec(tv_sec: 1_000, tv_nsec: 0))
        }

        let delay = sink.lifecycleHooks.remeasureLatency()
        sink.lifecycleHooks.resetSessionState(delay)

        var out = [Float](repeating: 1, count: 128)
        let produced = out.withUnsafeMutableBufferPointer { ob in
            sink.renderInterleaved(into: ob, frameCount: 128, cycleStartMonotonicNanos: 1_000_000_000_000)
        }
        #expect(!produced, "the anchor must be gone after the live reset hook runs")
        #expect(out.allSatisfy { $0 == 0 })
    }

    // MARK: Ring overflow (sustained overrun)

    /// A single enqueue far larger than the ring's capacity must be dropped
    /// wholesale (the ring's producer never partially writes a chunk) rather than
    /// crash or corrupt the buffer. Anchoring still happens (the anchor set is
    /// independent of whether the ring write below it succeeds), so the sink is
    /// silent — never garbage — once the target is reached.
    @Test func enqueue_singleChunkLargerThanRingCapacity_isSilentlyDroppedNotCrash() {
        // maxBufferedSeconds tiny ⇒ a ring of only a few dozen samples' capacity.
        let sink = SyncedLocalSink(
            renderSampleRate: 48_000, channelCount: 1, maxBufferedSeconds: 0.001,
            presentationDelayMs: { 5 }, localOutputLatency: { nil })

        // Far more frames than the ring could ever hold.
        var huge = [Float](repeating: 0, count: 50_000)
        for i in 0..<huge.count { huge[i] = Float(i + 1) }
        huge.withUnsafeMutableBufferPointer { buf in
            sink.enqueue(interleavedFrames: buf.baseAddress!, frameCount: buf.count,
                         pts: timespec(tv_sec: 10, tv_nsec: 0))
        }

        // Past the (tiny) target: the whole chunk was dropped, so this must drain
        // as silence, never a crash and never stray/garbage samples.
        var out = [Float](repeating: 1, count: 256)
        let produced = out.withUnsafeMutableBufferPointer { ob in
            sink.renderInterleaved(into: ob, frameCount: 256, cycleStartMonotonicNanos: 20_000_000_000)
        }
        #expect(!produced, "an oversized chunk must be dropped, not partially admitted")
        #expect(out.allSatisfy { $0 == 0 })
    }

    /// Sustained overrun: many small chunks enqueued back-to-back, far exceeding
    /// what the small ring can hold, all BEFORE any draining happens (mirrors a
    /// consumer stalled behind a burst of captured audio). The ring must never
    /// corrupt already-accepted data by overwriting it out of order — whatever
    /// prefix survives must drain out strictly in the original ascending order,
    /// with no repeats and no reordering, even though later chunks were silently
    /// dropped for lack of space.
    @Test func enqueue_sustainedOverflow_drainsAcceptedPrefixInOrderWithoutCorruption() {
        let sink = SyncedLocalSink(
            renderSampleRate: 48_000, channelCount: 1, maxBufferedSeconds: 0.001,
            presentationDelayMs: { 1 }, localOutputLatency: { nil })

        let anchorSec = 100
        // Flood far more chunks than the ring can ever hold — some prefix is
        // accepted, the rest silently dropped (never partially written).
        let chunkSize = 16
        let chunkCount = 500
        var nextValue: Float = 1
        for _ in 0..<chunkCount {
            var chunk = [Float](repeating: 0, count: chunkSize)
            for i in 0..<chunkSize { chunk[i] = nextValue; nextValue += 1 }
            chunk.withUnsafeMutableBufferPointer { buf in
                sink.enqueue(interleavedFrames: buf.baseAddress!, frameCount: chunkSize,
                             pts: timespec(tv_sec: anchorSec, tv_nsec: 0))
            }
        }

        // Drain well past the tiny target delay; collect every non-zero sample.
        var drained: [Float] = []
        var out = [Float](repeating: .nan, count: 64)
        for cycle in 0..<20 {
            let cycleStart = Int64(anchorSec) * 1_000_000_000 + Int64(cycle) * 64 * 1_000_000_000 / 48_000
            out.withUnsafeMutableBufferPointer { ob in
                _ = sink.renderInterleaved(into: ob, frameCount: 64, cycleStartMonotonicNanos: cycleStart)
            }
            drained.append(contentsOf: out.filter { $0 != 0 })
        }

        #expect(!drained.isEmpty, "some accepted prefix must have survived the overrun")
        // Strictly ascending, no repeats, no reordering — proof the ring never
        // silently overwrote already-accepted data with a later, dropped chunk.
        for i in 1..<drained.count {
            #expect(drained[i] > drained[i - 1],
                                 "drained samples must stay in original ascending order at index \(i)")
        }
        // What did survive is a genuine PREFIX of the flood (starts at the very
        // first enqueued value), not some arbitrary later slice.
        #expect(drained.first == 1, "the surviving data must start at the first enqueued sample")
        // And it is far short of everything enqueued — the overrun genuinely
        // dropped data rather than the ring having (surprisingly) fit it all.
        #expect(drained.count < chunkSize * chunkCount,
                          "the tiny ring must not have accepted the entire flood")
    }

    // MARK: Lifecycle reset mid-flight (sleep/wake while a correction is running)

    /// A lifecycle rebuild (device change / sleep / wake) that fires WHILE the
    /// T-CORRECTION phase-lock loop has already accumulated a non-trivial
    /// correction (simulating: session has been running under clock skew, then the
    /// Mac sleeps) must leave NO residual state behind — `latestPhaseErrorNanos`
    /// resets to 0 and a fresh session starts exactly like a brand-new sink, never
    /// fighting the old session's stale integrator/resampler phase (plan risk R3:
    /// sleep/wake is a silent-failure mode, not a crash, so this must be checked
    /// explicitly rather than trusted to "probably reset").
    @Test func liveLifecycleReset_midFlightCorrection_clearsResidualPhaseState() {
        let sr = 48_000.0
        let cc = 1
        let N = 512
        let nsPerFrame = 1_000_000_000.0 / sr

        let latency = LocalOutputLatencyMeasurement(
            safetyOffsetFrames: 0, deviceLatencyFrames: 480, streamLatencyFrames: 0,
            bufferFrameSizeFrames: 0, nominalSampleRate: sr)
        let sink = SyncedLocalSink(
            renderSampleRate: sr, channelCount: cc, safetyMarginMs: 3,
            presentationDelayMs: { 100 }, localOutputLatency: { latency })

        let anchorSec = 2_000
        let anchorNanos = Int64(anchorSec) * 1_000_000_000

        var contentFrame = 0
        func enqueueChunk(_ frames: Int) {
            var buf = [Float](repeating: 0.1, count: frames * cc)
            let ptsNanos = anchorNanos + Int64((Double(contentFrame) * nsPerFrame).rounded())
            let sec = Int(ptsNanos / 1_000_000_000)
            let nsec = Int(ptsNanos % 1_000_000_000)
            buf.withUnsafeBufferPointer {
                sink.enqueue(interleavedFrames: $0.baseAddress!, frameCount: frames,
                             pts: timespec(tv_sec: sec, tv_nsec: nsec))
            }
            contentFrame += frames
        }

        // Pre-roll, then run many cycles under a sustained device-clock skew so the
        // PI loop's integrator accumulates a real, non-zero correction — "mid-flight".
        enqueueChunk(N * 40)
        let skewPpm = 80.0
        let deviceStep = Double(N) * nsPerFrame * (1.0 + skewPpm * 1e-6)
        var cycleStart = Double(anchorNanos)
        var out = [Float](repeating: 0, count: N * cc)
        for cycle in 0..<400 {
            if cycle < 200 { enqueueChunk(N) }
            out.withUnsafeMutableBufferPointer {
                _ = sink.renderInterleaved(into: $0, frameCount: N, cycleStartMonotonicNanos: Int64(cycleStart.rounded()))
            }
            cycleStart += deviceStep
        }
        #expect(sink.latestPhaseErrorNanos != 0,
                          "precondition: a real in-flight residual/correction must exist before the reset")

        // Fire the SAME live (production-default) hooks a real sleep/wake would —
        // remeasure then reset — exactly as ``handleSystemWillSleep()`` does, without
        // touching the real AVAudioEngine (house rule: no real engine start in tests).
        let delay = sink.lifecycleHooks.remeasureLatency()
        sink.lifecycleHooks.resetSessionState(delay)

        #expect(sink.latestPhaseErrorNanos == 0,
                       "the reset must zero the phase-error readout — no stale mid-flight residual survives")

        // And the sink behaves like a brand-new session: silent until a fresh
        // anchor, first sample of the NEW content lands at the newly-computed
        // target, unperturbed by the old session's skew/correction history.
        var out2 = [Float](repeating: .nan, count: 128)
        let producedBeforeReanchor = out2.withUnsafeMutableBufferPointer { ob in
            sink.renderInterleaved(into: ob, frameCount: 128, cycleStartMonotonicNanos: Int64(cycleStart.rounded()))
        }
        #expect(!producedBeforeReanchor, "silent until a fresh session is anchored")
        #expect(out2.allSatisfy { $0 == 0 })
    }

    // MARK: T-OFFSET-UI — live trim seek (roadmap 056 Part 1)
    //
    // A trim on the Mac's row used to cost a full rebuild: stop, re-measure,
    // reset, restart, then a fresh delay's worth of silence. These pin the live
    // seek that replaced it — the audio keeps playing and the delay moves.

    /// Drive `count` render cycles from the ramp anchor, returning each cycle's
    /// output sample at `probeFrame`. The ramp is `ramp[i] = i + 1`, so a value
    /// IS its content position: two runs that differ by N frames of delay differ
    /// by exactly N in every sample. `onCycle` fires before each cycle renders.
    static func probeRampCycles(
        _ sink: SyncedLocalSink, cycles: Int, probeFrame: Int = 100,
        onCycle: (Int, SyncedLocalSink) -> Void = { _, _ in }
    ) -> [Float] {
        let nsPerFrame = 1_000_000_000.0 / 48_000.0
        var probes: [Float] = []
        var out = [Float](repeating: 0, count: 512)
        for cycle in 0..<cycles {
            onCycle(cycle, sink)
            let cycleStart = rampAnchorNanos + Int64((Double(cycle * 512) * nsPerFrame).rounded())
            out.withUnsafeMutableBufferPointer {
                _ = sink.renderInterleaved(into: $0, frameCount: 512, cycleStartMonotonicNanos: cycleStart)
            }
            probes.append(out[probeFrame])
        }
        return probes
    }

    /// (a) Post-release, a `+10 ms` offset delta shifts the playout by EXACTLY
    /// 10 ms — 480 frames at 48 kHz — and by moving the read pointer BACKWARD:
    /// a larger offset plays the Mac LATER, so the seeked run is 480 frames
    /// EARLIER in the content at the same instant. Run against an identical
    /// un-seeked sink in lockstep, so the assertion is the difference between
    /// the two and owes nothing to the correction loop's exact ratio.
    @Test func postReleaseOffsetDelta_shiftsPlayoutByExactlyTheDelta() {
        let seeked = Self.rampSink(), reference = Self.rampSink()
        Self.enqueueRamp(into: seeked)
        Self.enqueueRamp(into: reference)

        let seekCycle = 14   // the 87 ms gate opens around cycle 8
        let seekedProbes = Self.probeRampCycles(seeked, cycles: 20) { cycle, sink in
            if cycle == seekCycle { sink.applyUserOffsetDelta(ms: 10) }
        }
        let referenceProbes = Self.probeRampCycles(reference, cycles: 20)

        // Before the seek the two runs are identical, sample for sample.
        #expect(Array(seekedProbes[0..<seekCycle]) == Array(referenceProbes[0..<seekCycle]))
        // After it (skipping the seek cycle itself, whose first frames still
        // carry the resampler's pre-seek interpolation window) the seeked run
        // sits exactly 480 frames back in the ramp, and stays there.
        for cycle in (seekCycle + 1)..<20 {
            #expect(abs(referenceProbes[cycle] - seekedProbes[cycle] - 480) < 0.05,
                    "cycle \(cycle): \(referenceProbes[cycle]) vs \(seekedProbes[cycle])")
        }
    }

    /// A NEGATIVE delta is the mirror: the Mac plays EARLIER, so the read
    /// pointer moves forward and the seeked run is 480 frames AHEAD. Pins the
    /// sign, which compiles either way.
    @Test func postReleaseNegativeOffsetDelta_seeksTheOtherWay() {
        let seeked = Self.rampSink(), reference = Self.rampSink()
        Self.enqueueRamp(into: seeked)
        Self.enqueueRamp(into: reference)

        let seekedProbes = Self.probeRampCycles(seeked, cycles: 20) { cycle, sink in
            if cycle == 14 { sink.applyUserOffsetDelta(ms: -10) }
        }
        let referenceProbes = Self.probeRampCycles(reference, cycles: 20)

        for cycle in 15..<20 {
            #expect(abs(seekedProbes[cycle] - referenceProbes[cycle] - 480) < 0.05,
                    "cycle \(cycle): \(seekedProbes[cycle]) vs \(referenceProbes[cycle])")
        }
    }

    /// (b) Pre-release — anchored but still holding silence — the delta moves
    /// the GATE instead of the audio: nothing has been emitted to be continuous
    /// with, so the release target is re-derived from the freshly-measured
    /// delay. 100 ms delay + a 10 ms offset ⇒ first sound 110 ms after the pts.
    @Test func preReleaseOffsetDelta_movesTheReleaseTarget() throws {
        let offset = MutableIntBox()
        let sink = SyncedLocalSink(
            renderSampleRate: 48_000, channelCount: 1, safetyMarginMs: 0,
            presentationDelayMs: { 100 }, localOutputLatency: { nil },
            userOffsetMs: { offset.value })
        Self.enqueueRamp(into: sink)

        let nsPerFrame = 1_000_000_000.0 / 48_000.0
        var firstNonSilence: Int64?
        var out = [Float](repeating: 0, count: 512)
        for cycle in 0..<40 where firstNonSilence == nil {
            // One rendered cycle first (still silent), so the change genuinely
            // lands mid-session rather than before the gate was ever evaluated.
            if cycle == 1 {
                offset.value = 10
                sink.applyUserOffsetDelta(ms: 10)
            }
            let cycleStart = Self.rampAnchorNanos + Int64((Double(cycle * 512) * nsPerFrame).rounded())
            out.withUnsafeMutableBufferPointer {
                _ = sink.renderInterleaved(into: $0, frameCount: 512, cycleStartMonotonicNanos: cycleStart)
            }
            if let idx = out.firstIndex(where: { $0 != 0 }) {
                firstNonSilence = cycleStart + Int64((Double(idx) * nsPerFrame).rounded())
            }
        }

        let released = try #require(firstNonSilence, "audio was never released")
        let expected = Self.rampAnchorNanos + 110_000_000
        #expect(abs(released - expected) <= Int64(nsPerFrame.rounded()),
                "released at \(released - Self.rampAnchorNanos) ns after the pts, wanted 110 ms")
    }

    /// (c) A REBUILD racing the delta must land it exactly once. The
    /// pre-release path measures the delay OFF the lock, and a rebuild landing
    /// inside that measurement clears the session and resets the ring — after
    /// which falling through to `ring.requestShift` parks a shift the NEXT
    /// session's first read applies, on top of an anchor that already sampled
    /// the new offset. The delta would land twice.
    @Test func aRebuildRacingTheOffsetDelta_appliesItOnce() {
        // `presentationDelayMs` is called from inside `measureTotalDelayNanos`,
        // i.e. exactly between `applyUserOffsetDelta`'s two lock takes — the
        // real window, not a simulated one.
        final class Race: @unchecked Sendable {
            var sink: SyncedLocalSink?
            var clearOnNextMeasure = false
        }
        let race = Race()
        let latency = LocalOutputLatencyMeasurement(
            safetyOffsetFrames: 0, deviceLatencyFrames: 480, streamLatencyFrames: 0,
            bufferFrameSizeFrames: 0, nominalSampleRate: 48_000.0)
        let raced = SyncedLocalSink(
            renderSampleRate: 48_000.0, channelCount: 1, safetyMarginMs: 3,
            presentationDelayMs: {
                if race.clearOnNextMeasure {
                    race.clearOnNextMeasure = false
                    race.sink?.lifecycleHooks.resetSessionState(0)
                }
                return 100
            },
            localOutputLatency: { latency })
        race.sink = raced

        Self.enqueueRamp(into: raced)     // anchored, gate still closed
        race.clearOnNextMeasure = true
        raced.applyUserOffsetDelta(ms: 10)

        // The session the rebuild left behind, driven exactly like an untouched
        // one: any parked shift shows up as the ramp reading from the wrong
        // place.
        Self.enqueueRamp(into: raced)
        let control = Self.rampSink()
        Self.enqueueRamp(into: control)
        #expect(Self.probeRampCycles(raced, cycles: 20) == Self.probeRampCycles(control, cycles: 20),
                "the rebuilt session plays the content it was handed, unshifted")
    }

    /// (d) A seek must not read as drift the correction loop then pulls back
    /// out. The loop's error term is `audioStart − target − consumedContentFrames`
    /// and a read-pointer move touches none of them, so its correction stays put:
    /// were the seek visible to it, a 10 ms step would slam the correction to the
    /// ±200 ppm clamp.
    @Test func aSeekDoesNotDisturbTheCorrectionLoop() {
        let sink = Self.rampSink()
        Self.enqueueRamp(into: sink)

        var beforeSeek: Double?
        _ = Self.probeRampCycles(sink, cycles: 30) { cycle, sink in
            if cycle == 14 {
                beforeSeek = sink.phaseCorrectionPpmForTesting
                sink.applyUserOffsetDelta(ms: 10)
            }
            if cycle > 14, let before = beforeSeek {
                #expect(abs(sink.phaseCorrectionPpmForTesting - before) < 10,
                        "cycle \(cycle): correction moved to \(sink.phaseCorrectionPpmForTesting) ppm from \(before)")
            }
        }
        #expect(beforeSeek != nil, "the seek never ran")
    }
    #endif

    // MARK: Ring-overflow drop counting

    /// A ring-full drop is COUNTED, no longer just silently discarded
    /// (whole-system dropout investigation): flooding a tiny ring past
    /// capacity moves the producer-side drop counters; an enqueue that fits
    /// counts nothing.
    @Test func enqueue_ringOverflow_countsDroppedWrites() {
        let sink = SyncedLocalSink(
            renderSampleRate: 48_000, channelCount: 1, maxBufferedSeconds: 0.001,
            presentationDelayMs: { 5 }, localOutputLatency: { nil })

        // A small chunk that fits counts nothing.
        var small = [Float](repeating: 0.5, count: 8)
        small.withUnsafeMutableBufferPointer { buf in
            sink.enqueue(interleavedFrames: buf.baseAddress!, frameCount: buf.count,
                         pts: timespec(tv_sec: 10, tv_nsec: 0))
        }
        #expect(sink.ringOverflowDropsForTesting.writes == 0,
                "an admitted chunk must not count as a drop")

        // A chunk far larger than the ring is dropped wholesale — and counted.
        var huge = [Float](repeating: 0.5, count: 50_000)
        huge.withUnsafeMutableBufferPointer { buf in
            sink.enqueue(interleavedFrames: buf.baseAddress!, frameCount: buf.count,
                         pts: timespec(tv_sec: 10, tv_nsec: 0))
        }
        let drops = sink.ringOverflowDropsForTesting
        #expect(drops.writes == 1, "the ring-full drop must be counted")
        #expect(drops.samples == 50_000)
    }
}

/// `sync_ring_overflow` emission: session boundaries (`stop()` / lifecycle
/// rebuild, via `clearSessionState()`) flush the ring's drop counters
/// only-when-nonzero. Nested inside `SerializedSharedState` because it
/// installs the process-global `Telemetry` test sink — same idiom and
/// rationale as `NativeCaptureCoordinatorTests`'
/// `startEmitsCaptureWSTransitionTelemetry`.
extension SerializedSharedState {
    @Suite struct SyncedLocalSinkRingOverflowTelemetryTests {

        /// Thread-safe capture box (Telemetry's sink runs on its own writer
        /// queue) — mirrors `NativeCaptureCoordinatorTests.TelemetryLineBox`.
        private final class LineBox: @unchecked Sendable {
            private let lock = NSLock()
            private var lines: [String] = []
            func append(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
            var snapshot: [String] { lock.lock(); defer { lock.unlock() }; return lines }
        }

        @Test func stopFlushesRingOverflowOnlyWhenNonzero() {
            let captured = LineBox()
            Telemetry._installTestSink { captured.append($0) }
            defer { Telemetry._installTestSink(nil) }

            let sink = SyncedLocalSink(
                renderSampleRate: 48_000, channelCount: 1, maxBufferedSeconds: 0.001,
                presentationDelayMs: { 5 }, localOutputLatency: { nil })

            func overflowLines() -> [String] {
                captured.snapshot.filter { $0.contains("\"evt\":\"sync_ring_overflow\"") }
            }

            // A clean session boundary flushes nothing.
            sink.stop()
            Telemetry._installTestSink { captured.append($0) } // flush barrier
            #expect(overflowLines().isEmpty, "a drop-free session must not log sync_ring_overflow")

            // Overflow the tiny ring, then hit the boundary: exactly one line.
            var huge = [Float](repeating: 0.5, count: 50_000)
            huge.withUnsafeMutableBufferPointer { buf in
                sink.enqueue(interleavedFrames: buf.baseAddress!, frameCount: buf.count,
                             pts: timespec(tv_sec: 10, tv_nsec: 0))
            }
            sink.stop()
            Telemetry._installTestSink { captured.append($0) } // flush barrier
            #expect(overflowLines().count == 1, "got: \(captured.snapshot)")
            #expect(overflowLines().first?.contains("\"droppedWritesDelta\":\"1\"") == true)
            #expect(overflowLines().first?.contains("\"droppedFramesDelta\":\"50000\"") == true)

            // Already-flushed drops must not re-emit on the next boundary.
            sink.stop()
            Telemetry._installTestSink(nil) // synchronous flush barrier
            #expect(overflowLines().count == 1, "an already-flushed drop must not re-emit")
        }

        #if canImport(AVFoundation)
        /// (c) A move the ring cannot make — here a skip forward past everything
        /// buffered — falls back to the re-anchor, the ONE rebuild the live seek
        /// leaves in place. Nested here for the `Telemetry` sink that reads the
        /// cause; the rebuild itself runs through stubbed lifecycle hooks, so no
        /// real `AVAudioEngine` starts (house rule).
        @Test func anOffsetDeltaBeyondTheRingsHeadroomFallsBackToAReanchor() {
            let captured = LineBox()
            Telemetry._installTestSink { captured.append($0) }
            defer { Telemetry._installTestSink(nil) }

            // The ramp fixture, inlined: `SyncedLocalSinkTests`' copy is
            // main-actor isolated and this suite is not.
            let latency = LocalOutputLatencyMeasurement(
                safetyOffsetFrames: 0, deviceLatencyFrames: 480, streamLatencyFrames: 0,
                bufferFrameSizeFrames: 0, nominalSampleRate: 48_000)
            let sink = SyncedLocalSink(
                renderSampleRate: 48_000, channelCount: 1, safetyMarginMs: 3,
                presentationDelayMs: { 100 }, localOutputLatency: { latency })
            let anchorNanos = Int64(1_000) * 1_000_000_000
            var ramp = [Float](repeating: 0, count: 20_000)
            for i in 0..<ramp.count { ramp[i] = Float(i + 1) }
            ramp.withUnsafeBufferPointer {
                sink.enqueue(interleavedFrames: $0.baseAddress!, frameCount: ramp.count,
                             pts: timespec(tv_sec: 1_000, tv_nsec: 0))
            }

            var steps: [String] = []
            sink.lifecycleHooks = SyncedLocalSink.LifecycleHooks(
                stopEngine: { steps.append("stop") },
                remeasureLatency: { steps.append("remeasure"); return 0 },
                resetSessionState: { _ in steps.append("reset") },
                restartEngine: { steps.append("restart") })

            // Render past the 87 ms gate, then ask to skip a second of audio
            // forward — far more than the fraction of a second the ring holds.
            let nsPerFrame = 1_000_000_000.0 / 48_000.0
            var out = [Float](repeating: 0, count: 512)
            for cycle in 0..<20 {
                if cycle == 14 { sink.applyUserOffsetDelta(ms: -1_000) }
                let cycleStart = anchorNanos + Int64((Double(cycle * 512) * nsPerFrame).rounded())
                out.withUnsafeMutableBufferPointer {
                    _ = sink.renderInterleaved(
                        into: $0, frameCount: 512, cycleStartMonotonicNanos: cycleStart)
                }
            }

            #expect(steps == ["stop", "remeasure", "reset", "restart"],
                    "the fallback must be the full re-anchor: \(steps)")
            Telemetry._installTestSink(nil)   // flush barrier
            #expect(captured.snapshot.contains {
                $0.contains("\"evt\":\"synced_local_reanchor\"") && $0.contains("\"cause\":\"offset_change\"")
            }, "got: \(captured.snapshot)")
        }
        #endif
    }
}
