import XCTest
@testable import AudiouterCore

/// T-CORRECTION: the continuous phase-lock DSP — a custom cubic fractional
/// resampler plus a PI control loop that nulls the residual phase error.
///
/// Every test here is PURE and OFFLINE: it drives the resampler and controller (and
/// the sink's render core) with SYNTHETIC signals and SYNTHETIC clock drift — no
/// `AVAudioEngine.start()`, no real output device, no sound. The drift is simulated
/// by advancing a "device clock" at a ppm skew from the reference timeline and
/// asserting the loop converges phase error toward zero and HOLDS it there without
/// over/under-shoot, exactly the T-CORRECTION verify step.
final class PhaseControllerTests: IsolatedTestCase {

    // MARK: - FractionalResampler

    /// Pulls whole interleaved frames from a Swift array — the offline stand-in for
    /// the sink's lock-free ring. Returns `false` when exhausted (underrun).
    private final class ArrayFramePuller {
        let samples: [Float]
        let channelCount: Int
        private(set) var frame = 0
        init(samples: [Float], channelCount: Int) {
            self.samples = samples
            self.channelCount = channelCount
        }
        var pull: (UnsafeMutablePointer<Float>) -> Bool {
            { [self] dst in
                let base = frame * channelCount
                guard base + channelCount <= samples.count else { return false }
                for ch in 0..<channelCount { dst[ch] = samples[base + ch] }
                frame += 1
                return true
            }
        }
    }

    /// At a constant `ratio == 1.0` the resampler is a bit-exact pass-through: each
    /// output frame equals the corresponding input frame (frac stays 0, so the cubic
    /// collapses to `d1` every step). Stereo, to exercise the multichannel path.
    func test_resampler_unityRatioIsBitExactPassthrough() {
        let cc = 2
        let inFrames = 500
        var input = [Float](repeating: 0, count: inFrames * cc)
        for f in 0..<inFrames {
            input[f * cc] = Float(f) * 0.001          // L ramp
            input[f * cc + 1] = Float(-f) * 0.002     // R ramp (distinct)
        }
        let puller = ArrayFramePuller(samples: input, channelCount: cc)
        let resampler = FractionalResampler(channelCount: cc)

        let outFrames = 400
        var out = [Float](repeating: .nan, count: outFrames * cc)
        let produced = out.withUnsafeMutableBufferPointer {
            resampler.render(into: $0, outFrameOffset: 0, outFrames: outFrames, ratio: 1.0,
                             pullFrame: puller.pull)
        }
        XCTAssertEqual(produced, outFrames)
        for f in 0..<outFrames {
            XCTAssertEqual(out[f * cc], input[f * cc], accuracy: 1e-6, "L frame \(f)")
            XCTAssertEqual(out[f * cc + 1], input[f * cc + 1], accuracy: 1e-6, "R frame \(f)")
        }
    }

    /// The very first emitted sample is bit-exactly input frame 0 regardless of the
    /// commanded ratio — the property that keeps the anchor release sample-accurate.
    func test_resampler_firstSampleIsExactInputZero_atAnyRatio() {
        for ratio in [0.9998, 1.0, 1.0002] {
            let cc = 1
            var input = [Float](repeating: 0, count: 64)
            for i in 0..<64 { input[i] = Float(i + 1) }   // input[0] == 1.0
            let puller = ArrayFramePuller(samples: input, channelCount: cc)
            let resampler = FractionalResampler(channelCount: cc)
            var out = [Float](repeating: .nan, count: 16)
            _ = out.withUnsafeMutableBufferPointer {
                resampler.render(into: $0, outFrameOffset: 0, outFrames: 16, ratio: ratio,
                                 pullFrame: puller.pull)
            }
            XCTAssertEqual(out[0], input[0], accuracy: 1e-6, "first sample at ratio \(ratio)")
        }
    }

    /// Rate accuracy: at a constant ratio the resampler consumes input frames at
    /// exactly that rate. Checked directly and deterministically via
    /// `inputFramesConsumed` (which zero-crossing counting can't resolve at ppm
    /// scale): after K output frames it must have pulled ≈ K·ratio input frames.
    func test_resampler_constantRatioRateAccuracy() {
        for ratio in [0.99985, 1.0001, 1.02] {
            let cc = 1
            let outFrames = 100_000
            // Enough input headroom for the fastest ratio plus the priming window.
            let inFrames = Int(Double(outFrames) * ratio) + 16
            var input = [Float](repeating: 0, count: inFrames)
            let w = 2.0 * Double.pi * 1_000.0 / 48_000.0
            for i in 0..<inFrames { input[i] = 0.9 * Float(sin(w * Double(i))) }
            let puller = ArrayFramePuller(samples: input, channelCount: cc)
            let resampler = FractionalResampler(channelCount: cc)

            var out = [Float](repeating: 0, count: outFrames)
            let produced = out.withUnsafeMutableBufferPointer {
                resampler.render(into: $0, outFrameOffset: 0, outFrames: outFrames, ratio: ratio,
                                 pullFrame: puller.pull)
            }
            XCTAssertEqual(produced, outFrames, "ratio \(ratio): no underrun")
            // Consumed ≈ K·ratio; the constant priming/read-ahead offset is ≤ 4 frames.
            let expected = Double(outFrames) * ratio
            XCTAssertEqual(Double(resampler.inputFramesConsumed), expected, accuracy: 4.0,
                           "ratio \(ratio): input consumed must track the commanded rate")
        }
    }

    /// Click-free under a continuous ppm sweep: sweeping the ratio 1.0 → 1.0002
    /// (0→200 ppm, the spike's validated range), the worst output first-difference
    /// stays within the clean-sine slope bound — no discontinuity injected.
    func test_resampler_continuousSweepIsClickFree() {
        let sr = 48_000.0
        let freq = 1_000.0
        let cc = 1
        let inFrames = Int(sr) * 4 + 64
        var input = [Float](repeating: 0, count: inFrames)
        let w = 2.0 * Double.pi * freq / sr
        for i in 0..<inFrames { input[i] = 0.9 * Float(sin(w * Double(i))) }
        let puller = ArrayFramePuller(samples: input, channelCount: cc)
        let resampler = FractionalResampler(channelCount: cc)

        // Sweep in blocks so the ratio changes continuously across the render, like
        // the control loop nudging it cycle to cycle.
        let block = 512
        let outFrames = Int(sr) * 3
        var out = [Float](repeating: 0, count: outFrames)
        out.withUnsafeMutableBufferPointer { ob in
            var done = 0
            while done < outFrames {
                let n = min(block, outFrames - done)
                let frac = Double(done) / Double(outFrames)
                let ratio = 1.0 + 0.0002 * frac
                let got = resampler.render(into: ob, outFrameOffset: done, outFrames: n,
                                           ratio: ratio, pullFrame: puller.pull)
                if got < n { break }
                done += n
            }
        }

        let skip = 4_000
        var maxDiff: Float = 0
        for i in (skip + 1)..<out.count { maxDiff = max(maxDiff, abs(out[i] - out[i - 1])) }
        // Clean-sine per-sample slope bound: 2π f / sr · amp.
        let cleanBound = Float(2.0 * Double.pi * freq / sr) * 0.9
        XCTAssertLessThan(maxDiff, cleanBound * 1.5,
                          "no first-difference beyond the clean-sine slope ⇒ no click")
    }

    // MARK: - PhaseController closed-loop convergence (synthetic drift)

    /// Result of a synthetic closed-loop run: the per-cycle phase-error trace (in
    /// frames) and the final correction (ppm).
    private struct LoopRun {
        var errorsFrames: [Double]
        var finalCorrectionPpm: Double
    }

    /// Simulate the sink's phase loop against a device clock running at `skewPpm`
    /// relative to the reference, starting from `initialErrorFrames` of residual.
    ///
    /// Plant (matches `SyncedLocalSink.renderInterleaved`): each cycle the content
    /// position advances by `N·ratio` input frames while the reference/device time
    /// advances by `N·(1 + skewPpm·1e-6)` frames; phase error is their difference.
    private func runLoop(
        controller: PhaseController,
        cycles: Int,
        framesPerCycle N: Double,
        sampleRate sr: Double,
        skewPpm: Double,
        initialErrorFrames: Double
    ) -> LoopRun {
        let nsPerFrame = 1_000_000_000.0 / sr
        var contentPos = 0.0
        var deviceTimeFrames = initialErrorFrames      // ⇒ initial phaseError == initial
        var trace = [Double]()
        trace.reserveCapacity(cycles)
        for _ in 0..<cycles {
            let errorFrames = deviceTimeFrames - contentPos
            trace.append(errorFrames)
            controller.update(phaseErrorNanos: errorFrames * nsPerFrame, nsPerFrame: nsPerFrame)
            let ratio = controller.ratio
            contentPos += N * ratio
            deviceTimeFrames += N * (1.0 + skewPpm * 1e-6)
        }
        return LoopRun(errorsFrames: trace, finalCorrectionPpm: controller.correctionPpm)
    }

    /// Under a constant clock skew the PI loop drives the residual phase error to
    /// ≈ zero (a P-only loop would leave a standing offset) and the correction
    /// converges to the skew itself — true continuous phase-lock, held indefinitely.
    func test_controller_convergesToZeroUnderConstantSkew() {
        for skewPpm in [50.0, -50.0, 120.0] {
            let controller = PhaseController()
            let run = runLoop(controller: controller, cycles: 6_000,
                              framesPerCycle: 512, sampleRate: 48_000,
                              skewPpm: skewPpm, initialErrorFrames: 0.5)

            let nsPerFrame = 1_000_000_000.0 / 48_000.0
            // Held near zero over the final second (~90 cycles): the target is NOT a
            // one-time small value but an ongoing hold. 0.02 frame ≈ 0.4 µs — far
            // below the ~10 µs (½-frame) placement floor the spike measured.
            let tail = run.errorsFrames.suffix(90)
            let worstTailFrames = tail.map { abs($0) }.max() ?? .infinity
            XCTAssertLessThan(worstTailFrames, 0.02,
                              "skew \(skewPpm): residual must hold near zero (\(worstTailFrames * nsPerFrame) ns)")
            // Correction converged to the skew (steady-state ratio == 1 + skew).
            XCTAssertEqual(run.finalCorrectionPpm, skewPpm, accuracy: 1.0,
                           "skew \(skewPpm): correction should match the clock skew")
        }
    }

    /// The step response is over-damped: from an initial residual with a constant
    /// skew, the error decays without ringing — it never overshoots zero to the
    /// opposite side by more than a hair, and never blows up past its start.
    func test_controller_noOvershootOrOscillation() {
        let initial = 1.0
        let controller = PhaseController()
        let run = runLoop(controller: controller, cycles: 4_000,
                          framesPerCycle: 512, sampleRate: 48_000,
                          skewPpm: 40, initialErrorFrames: initial)

        let peak = run.errorsFrames.map { abs($0) }.max() ?? .infinity
        XCTAssertLessThanOrEqual(peak, initial * 1.05,
                                 "error must never grow meaningfully beyond its start (no blow-up)")
        // Opposite-sign overshoot below zero stays tiny (over-damped, not ringing).
        let mostNegative = run.errorsFrames.min() ?? -.infinity
        XCTAssertGreaterThan(mostNegative, -0.10,
                             "any undershoot past zero must be negligible")

        // Monotone-ish settle: once inside a small band it stays inside (no late
        // oscillation re-diverging).
        if let firstInBand = run.errorsFrames.firstIndex(where: { abs($0) < 0.05 }) {
            let after = run.errorsFrames[firstInBand...]
            XCTAssertTrue(after.allSatisfy { abs($0) < 0.10 },
                          "once within band the loop stays within band — no oscillation")
        } else {
            XCTFail("loop never reached the settle band")
        }
    }

    /// A large initial offset (e.g. a stale anchor after a lifecycle event) is still
    /// pulled in cleanly: the slew limit and ppm clamp bound the aggressiveness, and
    /// the loop still converges to ≈ zero without blowing up.
    func test_controller_largeInitialOffsetConvergesWithinClamp() {
        let controller = PhaseController()
        let run = runLoop(controller: controller, cycles: 20_000,
                          framesPerCycle: 512, sampleRate: 48_000,
                          skewPpm: 0, initialErrorFrames: 6.0)

        // Correction never exceeds the validated click-free band, even transiently.
        // (Reconstruct the max |correction| by re-running with a probe.)
        let probe = PhaseController()
        var maxPpm = 0.0
        let nsPerFrame = 1_000_000_000.0 / 48_000.0
        var contentPos = 0.0, deviceTimeFrames = 6.0
        for _ in 0..<20_000 {
            let e = deviceTimeFrames - contentPos
            probe.update(phaseErrorNanos: e * nsPerFrame, nsPerFrame: nsPerFrame)
            maxPpm = max(maxPpm, abs(probe.correctionPpm))
            contentPos += 512 * probe.ratio
            deviceTimeFrames += 512
        }
        XCTAssertLessThanOrEqual(maxPpm, 200.0 + 1e-6, "correction stays within the ±200 ppm band")

        let worstTail = run.errorsFrames.suffix(90).map { abs($0) }.max() ?? .infinity
        XCTAssertLessThan(worstTail, 0.02, "converges to ≈ zero from a large offset")
    }

    // MARK: - Integrated: SyncedLocalSink render core under synthetic device skew

    #if canImport(AVFoundation)
    /// End-to-end through the real `renderInterleaved`: enqueue content, cross the
    /// release gate, then drive many cycles whose synthetic "device clock"
    /// (`cycleStartMonotonicNanos`) advances at a ppm SKEW from the reference the
    /// content's pts lives on — mimicking the capture-vs-output clock drift. Assert
    /// the sink's `latestPhaseErrorNanos` converges toward zero and HOLDS, proving
    /// the resampler+PI path actually locks phase over time (not just at release).
    func test_renderCore_holdsPhaseUnderDeviceClockSkew() {
        let sr = 48_000.0
        let cc = 1
        let N = 512
        let nsPerFrame = 1_000_000_000.0 / sr

        // 100 ms presentation − 10 ms latency − 3 ms safety = 87 ms delay.
        let latency = LocalOutputLatencyMeasurement(
            safetyOffsetFrames: 0, deviceLatencyFrames: 480, streamLatencyFrames: 0,
            bufferFrameSizeFrames: 0, nominalSampleRate: sr)
        let sink = SyncedLocalSink(
            renderSampleRate: sr, channelCount: cc, safetyMarginMs: 3,
            presentationDelayMs: { 100 }, localOutputLatency: { latency })

        let anchorSec = 1_000
        let anchorNanos = Int64(anchorSec) * 1_000_000_000

        // Enqueue one chunk of content at a continuing pts (only the first sets the
        // anchor). Content values are irrelevant to phase; use a low sine.
        var contentFrame = 0
        func enqueueChunk(_ frames: Int) {
            var buf = [Float](repeating: 0, count: frames * cc)
            let w = 2.0 * Double.pi * 440.0 / sr
            for i in 0..<frames {
                buf[i * cc] = 0.2 * Float(sin(w * Double(contentFrame + i)))
            }
            let ptsFrame = contentFrame
            let ptsNanos = anchorNanos + Int64((Double(ptsFrame) * nsPerFrame).rounded())
            let sec = Int(ptsNanos / 1_000_000_000)
            let nsec = Int(ptsNanos % 1_000_000_000)
            buf.withUnsafeBufferPointer {
                sink.enqueue(interleavedFrames: $0.baseAddress!, frameCount: frames,
                             pts: timespec(tv_sec: sec, tv_nsec: nsec))
            }
            contentFrame += frames
        }

        // Pre-roll: build a healthy ring buffer before the gate opens (~87 ms + slack).
        enqueueChunk(N * 40)

        // The device clock runs 60 ppm SLOW relative to the reference timeline.
        let skewPpm = 60.0
        let deviceStep = Double(N) * nsPerFrame * (1.0 + skewPpm * 1e-6)

        var cycleStart = Double(anchorNanos)     // start at the anchor pts
        var out = [Float](repeating: 0, count: N * cc)
        var errorsNs = [Int64]()
        var released = false

        for cycle in 0..<3_000 {
            // Keep the ring fed at the reference rate (one chunk per cycle).
            if cycle % 1 == 0 { enqueueChunk(N) }
            let produced = out.withUnsafeMutableBufferPointer {
                sink.renderInterleaved(into: $0, frameCount: N,
                                       cycleStartMonotonicNanos: Int64(cycleStart.rounded()))
            }
            if produced { released = true }
            if released { errorsNs.append(sink.latestPhaseErrorNanos) }
            cycleStart += deviceStep
        }

        XCTAssertTrue(released, "audio must have been released")
        XCTAssertGreaterThan(errorsNs.count, 2_000, "should have many post-release cycles")

        // Held near zero over the final ~1 s: |error| well under one frame (20.8 µs)
        // — in fact within a few µs — despite the continuous 60 ppm skew that a
        // 1:1 (uncorrected) drain would let accrue without bound.
        // Held to ≈ zero over the final ~1 s (in practice sub-nanosecond, rounding to
        // 0 ns): the continuous PI correction cancels the 60 ppm skew that a 1:1
        // (uncorrected) drain would let accrue without bound. This is the target —
        // latestPhaseErrorNanos held near zero indefinitely, not just small at release.
        let tail = errorsNs.suffix(90)
        let worstTailNs = tail.map { abs($0) }.max() ?? .max
        XCTAssertLessThan(worstTailNs, 3_000,
                          "phase held within a few µs under skew (was \(worstTailNs) ns)")

        // And it genuinely CONVERGED: the tail is much tighter than the early
        // post-release transient.
        let earlyWorst = errorsNs.prefix(200).map { abs($0) }.max() ?? 0
        XCTAssertLessThan(worstTailNs, max(earlyWorst, 1), "the loop tightened phase over time")
    }
    #endif
}
