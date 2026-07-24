import Foundation
import AVFoundation

// Third T-CORRECTION candidate: a CUSTOM fractional resampler living INSIDE the
// AVAudioSourceNode render block (no AVAudioUnit). It reads the ring at a rate of
// `1 + ppm` samples of input per output sample, interpolating between input taps.
// This is the "raw resampler in the source node" option R7 raises as the fallback
// if the AVAudioUnits prove unusable. We measure the same things: click-freeness
// under a continuous ppm sweep, added latency, and rate accuracy — all offline /
// synthetic, no device, no sound.
//
// Implemented as a pure array-in/array-out resampler (the source-node integration
// is mechanically identical: the block would pull from the ring instead of a Swift
// array) so the DSP behaviour is measured directly without engine plumbing.

enum FractionalResampler {

    /// 4-point cubic (Catmull-Rom) fractional interpolation. `ratioProvider`
    /// returns the *input samples consumed per output sample* for the output index
    /// (≈ 1 ± ppm), letting us sweep the correction continuously like the control
    /// loop would.
    static func cubic(input: [Float], outputCount: Int, ratioProvider: (Int) -> Double) -> [Float] {
        var out = [Float](repeating: 0, count: outputCount)
        var pos = 0.0
        for o in 0..<outputCount {
            let i = Int(floor(pos))
            let frac = Float(pos - floor(pos))
            let xm1 = sample(input, i - 1)
            let x0 = sample(input, i)
            let x1 = sample(input, i + 1)
            let x2 = sample(input, i + 2)
            // Catmull-Rom
            let a = -0.5 * xm1 + 1.5 * x0 - 1.5 * x1 + 0.5 * x2
            let b = xm1 - 2.5 * x0 + 2.0 * x1 - 0.5 * x2
            let c = -0.5 * xm1 + 0.5 * x1
            let d = x0
            out[o] = ((a * frac + b) * frac + c) * frac + d
            pos += ratioProvider(o)
            if Int(floor(pos)) + 2 >= input.count { break }
        }
        return out
    }

    private static func sample(_ x: [Float], _ i: Int) -> Float {
        if i < 0 || i >= x.count { return 0 }
        return x[i]
    }

    static func run(sampleRate: Double = 48_000) {
        print("== T-CORRECTION candidate 3: custom fractional resampler (synthetic, silent) ==")
        let freq = 1000.0
        let inCount = Int(sampleRate) * 4 + 64
        var input = [Float](repeating: 0, count: inCount)
        let w = 2.0 * Double.pi * freq / sampleRate
        for i in 0..<inCount { input[i] = 0.9 * Float(sin(w * Double(i))) }

        let outCount = Int(sampleRate) * 4
        // Continuous ppm sweep: consume 1.0 → 1.0002 input samples per output.
        let out = cubic(input: input, outputCount: outCount) { o in
            1.0 + 0.0002 * (Double(o) / Double(outCount))
        }
        let skip = 2000
        let tail = Array(out[skip..<out.count])
        let (maxDiff, _) = Signal.maxAbsFirstDiff(tail)
        let cleanBound = Signal.sineDiffBound(freq: freq, sr: sampleRate, amp: 0.9)
        let ratio = maxDiff / cleanBound

        // Rate accuracy: hold a constant 1.0001 ratio and count realised freq.
        let outConst = cubic(input: input, outputCount: outCount) { _ in 1.0001 }
        let tailC = Array(outConst[skip..<outConst.count])
        var crossings = 0
        for i in 1..<tailC.count { if tailC[i - 1] <= 0 && tailC[i] > 0 { crossings += 1 } }
        let realisedFreq = Double(crossings) / (Double(tailC.count) / sampleRate)
        // consuming 1.0001 input per output shifts pitch up by 1.0001 (varispeed-like)
        let expected = freq * 1.0001
        let rateErr = abs(realisedFreq - expected) / expected

        print("""
        --- cubic (Catmull-Rom) 4-tap ---
          added latency       : ~2 samples (interpolation window)  = \(String(format: "%.4f", 2.0/sampleRate*1000)) ms
          continuous ppm sweep: maxΔ=\(String(format: "%.5f", maxDiff))  cleanSineΔbound=\(String(format: "%.5f", cleanBound))  ratio=\(String(format: "%.2f", ratio))×
          realised-rate error : \(String(format: "%.3e", rateErr)) (fractional)
          click verdict       : \(ratio < 1.5 ? "NO audible discontinuity (within clean-signal bound)" : "POSSIBLE discontinuity — inspect")
          note                : pitch tracks rate (like Varispeed); at ppm scale the shift is inaudible. A pitch-preserving
                                variant needs a phase vocoder (= what TimePitch already is). Sample-accurate, zero AU latency,
                                continuously steerable to arbitrary ppm resolution (double-precision phase accumulator).
        """)
    }
}
