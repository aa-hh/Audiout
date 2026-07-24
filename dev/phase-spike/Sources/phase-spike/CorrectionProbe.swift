import Foundation
import AVFoundation

// Q2: can a rate-correction node be inserted into an AVAudioEngine graph and
// driven CONTINUOUSLY without audible clicks — and what latency / precision does
// each add? Measured entirely in OFFLINE manual-rendering mode: the engine
// renders into a buffer we analyse, never touching a real output device, so this
// is silent by construction.

enum CorrectionKind: String {
    case timePitch
    case varispeed
    case none
}

struct CorrectionResult {
    let kind: String
    let latencyFramesAtUnity: Int          // measured group delay (impulse) at rate 1.0
    let latencySecondsAtUnity: Double
    let continuousSweepMaxDiff: Float      // worst first-difference during a continuous ppm rate sweep
    let cleanSineDiffBound: Float          // expected bound for the source sine (no node)
    let discontinuityRatio: Float          // sweepMaxDiff / cleanBound  (>~2 ⇒ visible click)
    let achievedRateError: Double          // |measured output-length ratio − commanded rate|, steady rate
    let notes: String
}

final class CorrectionProbe {
    let sampleRate: Double
    let channels: AVAudioChannelCount
    let maxFrames: AVAudioFrameCount = 512   // realistic device buffer granularity
    let format: AVAudioFormat

    init(sampleRate: Double = 48_000, channels: AVAudioChannelCount = 1) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
    }

    // A procedural source node: either an impulse train position or a continuous
    // sine, selected by mode. Never underruns (generates on demand), so the only
    // discontinuities in the OUTPUT come from the correction node, not starvation.
    private enum SourceMode { case sine(freq: Double); case impulse(at: Int) }

    private func buildEngine(kind: CorrectionKind, source: SourceMode,
                             rateProvider: @escaping () -> Float) throws -> (AVAudioEngine, AVAudioNode) {
        let engine = AVAudioEngine()
        let counter = FrameCounter()
        let sr = sampleRate
        let src = AVAudioSourceNode(format: format) { _, _, frameCount, ablPtr in
            let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
            let n = Int(frameCount)
            let base = counter.advance(by: n)
            for buf in abl {
                guard let p = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
                switch source {
                case .sine(let freq):
                    let w = 2.0 * Double.pi * freq / sr
                    for i in 0..<n { p[i] = 0.9 * Float(sin(w * Double(base + i))) }
                case .impulse(let at):
                    for i in 0..<n { p[i] = (base + i == at) ? 1.0 : 0.0 }
                }
            }
            return noErr
        }
        engine.attach(src)

        var tail: AVAudioNode = src
        switch kind {
        case .timePitch:
            let unit = AVAudioUnitTimePitch()
            unit.rate = rateProvider()
            engine.attach(unit)
            engine.connect(src, to: unit, format: format)
            tail = unit
            // keep the closure able to re-read rate each cycle via KVO-free poll
            rateDrivers.append { unit.rate = rateProvider() }
        case .varispeed:
            let unit = AVAudioUnitVarispeed()
            unit.rate = rateProvider()
            engine.attach(unit)
            engine.connect(src, to: unit, format: format)
            tail = unit
            rateDrivers.append { unit.rate = rateProvider() }
        case .none:
            break
        }
        engine.connect(tail, to: engine.mainMixerNode, format: format)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: maxFrames)
        try engine.start()
        return (engine, tail)
    }

    private var rateDrivers: [() -> Void] = []

    private final class FrameCounter {
        private var v = 0
        func advance(by n: Int) -> Int { let cur = v; v += n; return cur }
    }

    /// Render `totalFrames` offline, driving the rate node each cycle from `rateAt`
    /// (called with the absolute output-frame index at the START of the cycle).
    private func render(engine: AVAudioEngine, totalFrames: Int) throws -> [Float] {
        let out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                   frameCapacity: engine.manualRenderingMaximumFrameCount)!
        var collected = [Float]()
        collected.reserveCapacity(totalFrames)
        var rendered = 0
        while rendered < totalFrames {
            for d in rateDrivers { d() }   // continuous per-cycle rate update
            let want = AVAudioFrameCount(min(Int(maxFrames), totalFrames - rendered))
            let status = try engine.renderOffline(want, to: out)
            switch status {
            case .success:
                let n = Int(out.frameLength)
                if let ch = out.floatChannelData {
                    let p = ch[0]
                    for i in 0..<n { collected.append(p[i]) }
                }
                rendered += n
            case .insufficientDataFromInputNode:
                // procedural source never returns this, but guard anyway
                rendered += Int(want)
            case .cannotDoInCurrentContext:
                usleep(500)
            case .error:
                throw NSError(domain: "phase-spike", code: 1, userInfo: [NSLocalizedDescriptionKey: "renderOffline error"])
            @unknown default:
                rendered += Int(want)
            }
        }
        return collected
    }

    // MARK: measurements

    /// Group delay at unity rate: feed a single impulse, find it in the output.
    func measureLatency(kind: CorrectionKind) throws -> Int {
        rateDrivers = []
        let impulseAt = 4096
        let (engine, _) = try buildEngine(kind: kind, source: .impulse(at: impulseAt), rateProvider: { 1.0 })
        defer { engine.stop() }
        let out = try render(engine: engine, totalFrames: impulseAt + 16384)
        let (peakIdx, peakVal) = Signal.peakIndex(out)
        guard peakVal > 0.01 else { return -1 }
        return peakIdx - impulseAt
    }

    /// Continuous ppm-level rate sweep on a sine; report the worst output
    /// first-difference vs the clean-sine bound (click detector), plus the
    /// steady-state achieved-rate error.
    func measureContinuous(kind: CorrectionKind) throws -> (maxDiff: Float, cleanBound: Float, rateErr: Double) {
        rateDrivers = []
        let freq = 1000.0
        // Slowly ramp rate over the whole render: 1.0 → 1.0002 (±200 ppm), the
        // realistic magnitude of a ppm-drift correction, updated every cycle.
        let totalFrames = 48_000 * 4   // 4 s of audio
        var cyclePhase = 0
        let rateProvider: () -> Float = {
            let frac = Double(cyclePhase) / Double(totalFrames)
            return Float(1.0 + 0.0002 * frac)
        }
        let (engine, _) = try buildEngine(kind: kind, source: .sine(freq: freq), rateProvider: rateProvider)
        defer { engine.stop() }
        // wrap render to advance cyclePhase
        let out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                   frameCapacity: engine.manualRenderingMaximumFrameCount)!
        var collected = [Float](); collected.reserveCapacity(totalFrames)
        var rendered = 0
        while rendered < totalFrames {
            cyclePhase = rendered
            for d in rateDrivers { d() }
            let want = AVAudioFrameCount(min(Int(maxFrames), totalFrames - rendered))
            let status = try engine.renderOffline(want, to: out)
            if status == .success {
                let n = Int(out.frameLength)
                if let ch = out.floatChannelData { for i in 0..<n { collected.append(ch[0][i]) } }
                rendered += n
            } else if status == .cannotDoInCurrentContext { usleep(500) }
            else { rendered += Int(want) }
        }
        // Skip the node's startup ramp (first latency+ samples) before diff scan.
        let skip = min(collected.count / 4, 20_000)
        let tail = Array(collected[skip...])
        let (maxDiff, _) = Signal.maxAbsFirstDiff(tail)
        let cleanBound = Signal.sineDiffBound(freq: freq, sr: sampleRate, amp: 0.9)

        // Steady-rate achieved-ratio check: hold a constant 1.0001 and compare the
        // OUTPUT length the node produces for a fixed input pull count. For a
        // pull-based graph in offline mode, output length ≈ input/rate; we instead
        // verify commanded vs realised by rendering a fixed output and measuring the
        // sine's realised frequency shift indirectly via zero-crossing count.
        let rateErr = try measureRealisedRate(kind: kind, commanded: 1.0001, freq: freq)
        return (maxDiff, cleanBound, rateErr)
    }

    /// Realised-rate check: at a constant rate r, a source sine of freq f exits the
    /// varispeed/timepitch resampled such that its period changes by 1/r
    /// (varispeed shifts pitch; timepitch preserves pitch → f unchanged). We count
    /// zero crossings in the output over a known span and infer realised f, then
    /// compare to the commanded transform. Returns |realised − commanded| as a
    /// fractional rate error.
    private func measureRealisedRate(kind: CorrectionKind, commanded: Float, freq: Double) throws -> Double {
        rateDrivers = []
        let (engine, _) = try buildEngine(kind: kind, source: .sine(freq: freq), rateProvider: { commanded })
        defer { engine.stop() }
        let total = 48_000 * 2
        let out = try render(engine: engine, totalFrames: total)
        let skip = min(out.count / 4, 20_000)
        let tail = Array(out[skip...])
        // count zero crossings (rising)
        var crossings = 0
        for i in 1..<tail.count { if tail[i - 1] <= 0 && tail[i] > 0 { crossings += 1 } }
        let seconds = Double(tail.count) / sampleRate
        let realisedFreq = Double(crossings) / seconds
        switch kind {
        case .varispeed:
            // varispeed multiplies pitch by rate → expected realised = freq*commanded
            let expected = freq * Double(commanded)
            return abs(realisedFreq - expected) / expected
        case .timePitch:
            // timepitch preserves pitch → expected realised = freq
            return abs(realisedFreq - freq) / freq
        case .none:
            return abs(realisedFreq - freq) / freq
        }
    }

    func run() {
        print("== Q2: correction-node probe (offline manual rendering, silent) ==")
        print("sampleRate=\(sampleRate) buffer=\(maxFrames) frames  (buffer period = \(String(format: "%.3f", Double(maxFrames)/sampleRate*1000)) ms)")
        for kind in [CorrectionKind.timePitch, .varispeed] {
            do {
                let lat = try measureLatency(kind: kind)
                let latSec = lat >= 0 ? Double(lat) / sampleRate : Double.nan
                let cont = try measureContinuous(kind: kind)
                let ratio = cont.cleanBound > 0 ? cont.maxDiff / cont.cleanBound : Float.nan
                print("""
                --- \(kind.rawValue) ---
                  group delay @ unity : \(lat) frames  (\(String(format: "%.3f", latSec * 1000)) ms)
                  continuous ppm sweep: maxΔ=\(String(format: "%.5f", cont.maxDiff))  cleanSineΔbound=\(String(format: "%.5f", cont.cleanBound))  ratio=\(String(format: "%.2f", ratio))×
                  realised-rate error : \(String(format: "%.3e", cont.rateErr)) (fractional)
                  click verdict       : \(ratio < 1.5 ? "NO audible discontinuity (within clean-signal bound)" : "POSSIBLE discontinuity — inspect")
                """)
            } catch {
                print("--- \(kind.rawValue) --- ERROR: \(error)")
            }
        }
    }
}
