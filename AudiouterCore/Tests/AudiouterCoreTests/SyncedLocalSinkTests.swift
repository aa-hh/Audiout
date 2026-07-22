import XCTest
@testable import AudiouterCore

/// T-SINK: the synced local sink stays silent until the output device's clock
/// reaches `capture_pts + presentationDelay − localOutputLatency − safetyMargin`,
/// then emits the buffered audio in order. These run fully offline — no
/// `AVAudioEngine.start()`, no real output device, no sound — by driving the
/// render core (`renderInterleaved`) directly with synthetic cycle times, exactly
/// the harness the plan's T-SINK verify step calls for.
final class SyncedLocalSinkTests: IsolatedTestCase {

    // MARK: Pure timing math

    func test_totalDelayNanos_subtractsLatencyAndMargin() {
        // 100 ms presentation − 10 ms local latency − 3 ms safety = 87 ms.
        let delay = SyncTiming.totalDelayNanos(
            presentationDelayMs: 100, localOutputLatencySeconds: 0.010, safetyMarginMs: 3)
        XCTAssertEqual(delay, 87_000_000)
    }

    func test_totalDelayNanos_clampsAtZero() {
        // Local latency larger than the AirPlay buffer would go negative → clamp 0.
        let delay = SyncTiming.totalDelayNanos(
            presentationDelayMs: 5, localOutputLatencySeconds: 0.050, safetyMarginMs: 3)
        XCTAssertEqual(delay, 0)
    }

    func test_plan_silentBeforeTarget_thenReleasesAtFrameOffset() {
        let sampleRate = 48_000.0
        let target: Int64 = 1_000_000_000 + 87_000_000
        // A cycle wholly before the target is entirely silent, not releasing.
        let early = SyncTiming.plan(
            cycleStartMonotonicNanos: 1_000_000_000, frameCount: 512,
            sampleRate: sampleRate, targetReleaseMonotonicNanos: target)
        XCTAssertEqual(early, SyncTiming.RenderPlan(silentFrames: 512, releasesThisCycle: false))

        // A cycle straddling the target releases part-way through: the silent
        // prefix is the frame-accurate offset to the target.
        let cycleStart: Int64 = 1_000_000_000 + 80_000_000
        let straddle = SyncTiming.plan(
            cycleStartMonotonicNanos: cycleStart, frameCount: 512,
            sampleRate: sampleRate, targetReleaseMonotonicNanos: target)
        XCTAssertTrue(straddle.releasesThisCycle)
        let nsPerFrame = 1_000_000_000.0 / sampleRate
        let expectedOffset = Int((Double(target - cycleStart) / nsPerFrame).rounded())
        XCTAssertEqual(straddle.silentFrames, expectedOffset)
    }

    // MARK: End-to-end render gate (ramp in, first-non-silence lands on target)

    #if canImport(AVFoundation)
    func test_rampReleasesAtComputedHostTime_withinOneFrame() throws {
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
                    XCTAssertTrue(out[0..<localIdx].allSatisfy { $0 == 0 })
                } else {
                    // Pre-release cycles are entirely silent and drain nothing.
                    XCTAssertFalse(produced)
                    XCTAssertTrue(out.allSatisfy { $0 == 0 })
                }
            }
        }

        let hostTime = try XCTUnwrap(firstNonSilenceHostTime, "audio was never released")
        // First non-silence lands within one frame of the computed target.
        XCTAssertLessThanOrEqual(abs(hostTime - expectedTargetNanos), Int64(nsPerFrame.rounded()))
        // And it is the very first ramp sample — the delay line released in order.
        XCTAssertEqual(firstRealSample, ramp[0])
        // The residual phase error the correction loop will read is sub-frame.
        XCTAssertLessThanOrEqual(abs(sink.latestPhaseErrorNanos), Int64(nsPerFrame.rounded()))
    }

    func test_noAudioBeforeEnqueue_isSilent() {
        let sink = SyncedLocalSink(
            renderSampleRate: 48_000, channelCount: 1,
            presentationDelayMs: { 100 }, localOutputLatency: { nil })
        var out = [Float](repeating: 1, count: 256)
        let produced = out.withUnsafeMutableBufferPointer { ob in
            sink.renderInterleaved(into: ob, frameCount: 256, cycleStartMonotonicNanos: 5_000_000_000)
        }
        XCTAssertFalse(produced)
        XCTAssertTrue(out.allSatisfy { $0 == 0 })
    }
    #endif
}
