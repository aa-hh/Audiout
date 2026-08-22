import Foundation
@testable import ProbeKit

/// Builds a recording of the probe the way a phone would have heard it: a
/// random lead-in, a tick-free stretch the length of the probe's preamble, then
/// the REF/TGT block schedule, with room noise and one reflection per tick.
///
/// The ticks come from the same synthesis the analyzer matches against, so
/// these tests measure the ANALYSIS, not the synthesis.
struct SyntheticProbeRecording {

    var sampleRate: Double
    var pattern = ProbePattern.spike
    /// Delay applied to every target tick. Positive = the target sounds late.
    var targetOffsetMs: Double = 0
    var includeTicks = true
    var includeTarget = true
    /// Tick-to-noise ratio, measured over the tick's own 30 ms.
    var snrDB: Double? = 10
    /// One reflection per tick. The two devices sit in different places, so
    /// their reflections can differ — which is the case that would BIAS a
    /// measurement rather than just blur it.
    var referenceReflection: Reflection? = .default
    var targetReflection: Reflection? = .default
    /// Truncate the first tick of every block, as a late mute switch would.
    var clipFirstTickOfEachBlock = false
    var seed: UInt64 = 0xA5A5_1234_C0FF_EE01

    struct Reflection {
        var delaySeconds: Double
        var gain: Float
        static let `default` = Reflection(delaySeconds: 0.008, gain: 0.501)  // −6 dB
    }

    static let clippedTickSeconds = 0.006
    static let preambleSeconds = 5.0

    func build() -> [Float] {
        var random = SplitMix64(seed: seed)
        let period = pattern.beatPeriodSeconds
        let template = TickTemplate.render(sampleRate: sampleRate)
        let gridOrigin = 0.25 + random.nextUnit() * 1.0 + Self.preambleSeconds
        let beats = pattern.repetitions * pattern.blockStrideBeats * 2
        let duration = gridOrigin + Double(beats) * period + 1.0

        var samples = [Float](repeating: 0, count: Int(duration * sampleRate))
        if let snrDB {
            let noiseRMS = rms(of: template) * pow(10, -snrDB / 20)
            let peak = Float(noiseRMS * 3.0.squareRoot())  // uniform noise of this RMS
            for index in samples.indices {
                samples[index] = Float(random.nextUnit() * 2 - 1) * peak
            }
        }
        guard includeTicks else { return samples }

        for repetition in 0..<pattern.repetitions {
            for slot in 0...1 where slot == 0 || includeTarget {
                let delay = slot == 1 ? targetOffsetMs / 1000 : 0
                let reflection = slot == 1 ? targetReflection : referenceReflection
                let firstBeat = (repetition * 2 + slot) * pattern.blockStrideBeats
                for tick in 0..<pattern.ticksPerBlock {
                    let at = gridOrigin + Double(firstBeat + tick) * period + delay
                    let clipped = clipFirstTickOfEachBlock && tick == 0
                    let frames = clipped ? Int(Self.clippedTickSeconds * sampleRate) : template.count
                    let source = Array(template.prefix(frames))
                    mix(source, at: at, gain: 1, into: &samples)
                    if let reflection {
                        mix(source, at: at + reflection.delaySeconds, gain: reflection.gain, into: &samples)
                    }
                }
            }
        }
        return samples
    }

    private func mix(_ source: [Float], at seconds: Double, gain: Float, into samples: inout [Float]) {
        let start = Int(seconds * sampleRate)
        for (index, value) in source.enumerated() where start + index < samples.count {
            samples[start + index] += value * gain
        }
    }

    private func rms(of values: [Float]) -> Double {
        let sum = values.reduce(0.0) { $0 + Double($1) * Double($1) }
        return (sum / Double(values.count)).squareRoot()
    }
}

/// SplitMix64 — the cheap deterministic generator `AlignmentTickInjector` also
/// uses for its noise bed. Seeded, so a test that fails fails every time.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func nextUnit() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
}
