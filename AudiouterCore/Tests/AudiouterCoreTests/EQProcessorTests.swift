import Foundation
import Testing
@testable import AudiouterCore

/// `EQProcessor`'s audible contract, measured with sine probes rather than
/// asserted against coefficient tables: a band boost moves its own frequency and
/// leaves a distant one alone, the shelves reach where they should, balance
/// attenuates exactly one channel, and a boosted full-scale signal clips instead
/// of wrapping into noise. Pure DSP — no shared state.
@Suite struct EQProcessorTests {

    private let sampleRate = 44_100.0
    private let frames = 8_820          // 200 ms — long enough to settle and measure

    // MARK: Probe helpers

    /// Interleaved stereo S16LE holding the same sine in both channels.
    private func sine(hz: Double, amplitude: Double) -> Data {
        var samples = [Int16](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            let value = amplitude * sin(2 * Double.pi * hz * Double(frame) / sampleRate)
            let quantized = Int16(clamping: Int(round(value * 32_767)))
            samples[frame * 2] = quantized
            samples[frame * 2 + 1] = quantized
        }
        return samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// RMS of one channel over the SECOND half only, so the filters' start-up
    /// transient never lands in the measurement.
    private func rms(_ pcm: Data, channel: Int) -> Double {
        let samples = pcm.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        let start = frames / 2
        var sum = 0.0
        for frame in start..<frames {
            let value = Double(samples[frame * 2 + channel]) / 32_767
            sum += value * value
        }
        return (sum / Double(frames - start)).squareRoot()
    }

    private func gain(_ eq: DeviceEQ, atHz hz: Double, amplitude: Double = 0.1) -> Double {
        let input = sine(hz: hz, amplitude: amplitude)
        var output = input
        EQProcessor(eq: eq, sampleRate: sampleRate).process(&output)
        return rms(output, channel: 0) / rms(input, channel: 0)
    }

    private func bands(_ pairs: [Int: Double]) -> [Double] {
        var gains = [Double](repeating: 0, count: DeviceEQ.bandCount)
        for (index, value) in pairs { gains[index] = value }
        return gains
    }

    // MARK: Frequency response

    @Test func oneKilohertzBandBoostLiftsItsOwnFrequency() {
        let oneKIndex = DeviceEQ.bandCentresHz.firstIndex(of: 1_000)!
        let eq = DeviceEQ(bandGainsDB: bands([oneKIndex: 12]))
        let ratio = gain(eq, atHz: 1_000)
        // +12 dB is x3.98 in amplitude; the peaking filter's own centre gain.
        #expect(ratio > 3.6 && ratio < 4.4, "measured \(ratio)")
    }

    @Test func oneKilohertzBandBoostLeavesAHundredHertzAlone() {
        let oneKIndex = DeviceEQ.bandCentresHz.firstIndex(of: 1_000)!
        let eq = DeviceEQ(bandGainsDB: bands([oneKIndex: 12]))
        let dB = 20 * log10(gain(eq, atHz: 100))
        #expect(abs(dB) < 1, "a decade below the band should be untouched; measured \(dB) dB")
    }

    @Test func bassShelfLiftsFiftyHertz() {
        let ratio = gain(DeviceEQ(bassDB: 12), atHz: 50)
        #expect(ratio > 3 && ratio < 4.2, "measured \(ratio)")
    }

    @Test func bassShelfLeavesEightKilohertzAlone() {
        let dB = 20 * log10(gain(DeviceEQ(bassDB: 12), atHz: 8_000))
        #expect(abs(dB) < 1, "measured \(dB) dB")
    }

    @Test func trebleShelfLiftsTwelveKilohertzAndLeavesFiftyHertzAlone() {
        let eq = DeviceEQ(trebleDB: 12)
        let high = gain(eq, atHz: 12_000)
        #expect(high > 2.8, "measured \(high)")
        let lowDB = 20 * log10(gain(eq, atHz: 50))
        #expect(abs(lowDB) < 1, "measured \(lowDB) dB")
    }

    @Test func aCutIsTheMirrorOfABoost() {
        let index = DeviceEQ.bandCentresHz.firstIndex(of: 2_000)!
        let ratio = gain(DeviceEQ(bandGainsDB: bands([index: -12])), atHz: 2_000)
        #expect(ratio > 0.22 && ratio < 0.29, "measured \(ratio)")
    }

    @Test func sectionsAboveTheNyquistGuardAreSkipped() {
        // At 24 kHz (Bluetooth HFP) the 16 kHz band sits past 0.45 x rate, so it
        // emits no section — the rest of the chain must still run.
        let topBand = DeviceEQ.bandCentresHz.firstIndex(of: 16_000)!
        let eq = DeviceEQ(bandGainsDB: bands([topBand: 12]))
        var probe = [Float](repeating: 0.25, count: 512)
        EQProcessor(eq: eq, sampleRate: 24_000).process(floatInterleaved: &probe, frameCount: 256)
        #expect(probe.allSatisfy { abs($0 - 0.25) < 0.001 }, "no section means untouched samples")
    }

    // MARK: Balance

    @Test func balanceAttenuatesExactlyOneChannel() {
        let input = sine(hz: 1_000, amplitude: 0.5)
        var output = input
        EQProcessor(eq: DeviceEQ(balance: 0.5), sampleRate: sampleRate).process(&output)

        let leftRatio = rms(output, channel: 0) / rms(input, channel: 0)
        let rightRatio = rms(output, channel: 1) / rms(input, channel: 1)
        #expect(abs(leftRatio - 0.5) < 0.01, "panning right halves the left channel; measured \(leftRatio)")
        #expect(abs(rightRatio - 1) < 0.01, "the right channel is never boosted; measured \(rightRatio)")
    }

    @Test func negativeBalanceMirrorsTheAttenuation() {
        let input = sine(hz: 1_000, amplitude: 0.5)
        var output = input
        EQProcessor(eq: DeviceEQ(balance: -0.5), sampleRate: sampleRate).process(&output)
        #expect(abs(rms(output, channel: 0) / rms(input, channel: 0) - 1) < 0.01)
        #expect(abs(rms(output, channel: 1) / rms(input, channel: 1) - 0.5) < 0.01)
    }

    // MARK: Clipping

    @Test func fullScaleInputWithABoostClipsInsteadOfWrapping() {
        let oneKIndex = DeviceEQ.bandCentresHz.firstIndex(of: 1_000)!
        let eq = DeviceEQ(bandGainsDB: bands([oneKIndex: 12]))

        var pcm = sine(hz: 1_000, amplitude: 1.0)
        EQProcessor(eq: eq, sampleRate: sampleRate).process(&pcm)
        let s16 = pcm.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }

        #expect(s16.max() == 32_767, "a +12 dB boost on a full-scale sine must reach the ceiling")
        #expect(s16.min() == -32_767, "and the floor")
        #expect(!s16.contains(Int16.min), "-32768 would be the wrap artifact this clamp exists to prevent")

        // A wrap flips a sample's sign. Compare against the float path, which
        // clamps in floating point and cannot wrap by construction.
        var floats = floatMirror(of: sine(hz: 1_000, amplitude: 1.0))
        EQProcessor(eq: eq, sampleRate: sampleRate).process(floatInterleaved: &floats, frameCount: frames)
        for (index, sample) in s16.enumerated() where sample != 0 {
            #expect(sample.signum() == Int16(floats[index] < 0 ? -1 : 1), "sign flip at \(index)")
        }
    }

    // MARK: Entry-point parity

    @Test func floatEntryPointMatchesTheSixteenBitOneWithinQuantization() {
        let eq = DeviceEQ(bassDB: 6, trebleDB: -4, balance: 0.25, loudness: true,
                          bandGainsDB: bands([2: 5, 7: -5]))
        let input = sine(hz: 440, amplitude: 0.4)

        var pcm = input
        EQProcessor(eq: eq, sampleRate: sampleRate).process(&pcm)
        let s16 = pcm.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }

        var floats = floatMirror(of: input)
        EQProcessor(eq: eq, sampleRate: sampleRate).process(floatInterleaved: &floats, frameCount: frames)

        for index in s16.indices {
            let expected = Int(round(Double(floats[index]) * 32_767))
            #expect(abs(Int(s16[index]) - expected) <= 1, "diverged at \(index)")
        }
    }

    // MARK: Response curve

    /// The curve the Equalizer page draws has to be silent about a flat EQ —
    /// no section means no contribution, at every probe frequency.
    @Test func responseIsZeroEverywhereForFlat() {
        for hz in [20.0, 100, 1_000, 10_000, 20_000] {
            let db = EQProcessor.responseDB(for: .flat, atHz: hz, sampleRate: sampleRate)
            #expect(abs(db) < 1e-9, "flat must read 0 dB at \(hz) Hz, got \(db)")
        }
    }

    @Test func responseOfAOneKilohertzBandBoostPeaksThereAndLeavesAHundredHertzAlone() {
        let oneKIndex = DeviceEQ.bandCentresHz.firstIndex(of: 1_000)!
        let eq = DeviceEQ(bandGainsDB: bands([oneKIndex: 12]))
        #expect(abs(EQProcessor.responseDB(for: eq, atHz: 1_000, sampleRate: sampleRate) - 12) < 0.5)
        #expect(abs(EQProcessor.responseDB(for: eq, atHz: 100, sampleRate: sampleRate)) < 0.5)
    }

    @Test func responseOfABassShelfLiftsFiftyHertzNotFiveKilohertz() {
        let eq = DeviceEQ(bassDB: 6)
        #expect(abs(EQProcessor.responseDB(for: eq, atHz: 50, sampleRate: sampleRate) - 6) < 0.5)
        #expect(abs(EQProcessor.responseDB(for: eq, atHz: 5_000, sampleRate: sampleRate)) < 0.5)
    }

    /// A cut is the boost's mirror image, so the two cancel at the centre — the
    /// drawn curve stays symmetric about 0 dB.
    @Test func responseCutMirrorsBoost() {
        let oneKIndex = DeviceEQ.bandCentresHz.firstIndex(of: 1_000)!
        let cut = EQProcessor.responseDB(for: DeviceEQ(bandGainsDB: bands([oneKIndex: -6])),
                                         atHz: 1_000, sampleRate: sampleRate)
        let boost = EQProcessor.responseDB(for: DeviceEQ(bandGainsDB: bands([oneKIndex: 6])),
                                           atHz: 1_000, sampleRate: sampleRate)
        #expect(abs(cut + boost) < 1e-6, "cut \(cut) and boost \(boost) must cancel")
    }

    /// The curve reads from the same coefficients the DSP runs, so a band the
    /// Nyquist guard drops must not be drawn either.
    @Test func responseSkipsSectionsAboveTheNyquistGuard() {
        let topBand = DeviceEQ.bandCentresHz.firstIndex(of: 16_000)!
        let eq = DeviceEQ(bandGainsDB: bands([topBand: 12]))
        #expect(abs(EQProcessor.responseDB(for: eq, atHz: 1_000, sampleRate: 24_000)) < 1e-9)
    }

    // MARK: Retargeting

    /// The delay-carry rule with no threads in sight. Pair 0 is the input
    /// history the whole chain starts from and always carries; a section present
    /// in both lists keeps its own output pair; a section that has just appeared
    /// starts from its INPUT pair — the preceding pair, already carried —
    /// instead of from zero, which is what keeps a band crossing 0 dB silent.
    @Test func theDelayCarryKeepsSharedSectionsAndSeedsNewOnes() {
        let old: [EQProcessor.SectionKey] = [.band(2), .bass]
        let new: [EQProcessor.SectionKey] = [.band(2), .band(5), .bass]
        // Pair p reads (10p, 10p + 1), so every carried pair is identifiable.
        let delays: [Float] = [0, 1, 10, 11, 20, 21]

        let carried = EQProcessor.carriedDelays(delays, from: old, to: new)

        #expect(carried == [0, 1,      // pair 0, always carried
                            10, 11,    // band(2) kept its own output pair
                            10, 11,    // band(5) is new: seeded from its input pair
                            20, 21])   // bass kept its pair, one slot further along
    }

    /// One slider frame must not be audible as a click. A rebuilt processor
    /// starts with empty delay memory, dropping the signal back to the filter's
    /// start-up transient mid-note — the crackle the owner heard for the whole
    /// drag. A retarget carries the memory across, so the waveform either side
    /// of the swap stays as smooth as it already was.
    @Test func aRetargetDoesNotStepTheWaveform() {
        let chunk = 4_096
        let processor = EQProcessor(eq: DeviceEQ(bassDB: 4), sampleRate: sampleRate)

        var before = sineChunk(hz: 440, amplitude: 0.4, frameCount: chunk, from: 0)
        processor.process(&before)
        processor.retarget(to: DeviceEQ(bassDB: 5))
        var after = sineChunk(hz: 440, amplitude: 0.4, frameCount: chunk, from: chunk)
        processor.process(&after)

        let tail = leftChannel(before).suffix(512)
        let settled = maxStep(Array(tail))
        // The boundary sample is included, so the splice itself is measured.
        let across = maxStep(Array(tail.suffix(1)) + leftChannel(after).prefix(512))

        // 1.1×, measured rather than guessed: a carried swap lands at 1.01× the
        // settled step and a full rebuild of this stage at 1.53×, so a looser
        // bound would wave the rebuild straight through.
        #expect(across <= 1.1 * settled,
                "step across the swap \(across) vs \(settled) settled — the delay memory was lost")
    }

    /// A retarget is not merely quiet: the value it was pointed at is the one
    /// the audio actually comes out with.
    @Test func aRetargetedProcessorFiltersWithTheNewValue() {
        let processor = EQProcessor(eq: DeviceEQ(bassDB: 2), sampleRate: sampleRate)
        processor.retarget(to: DeviceEQ(bassDB: 6))

        let input = sine(hz: 50, amplitude: 0.1)
        var output = input
        processor.process(&output)

        let db = 20 * log10(rms(output, channel: 0) / rms(input, channel: 0))
        #expect(abs(db - 6) < 0.5, "expected the new 6 dB shelf, measured \(db) dB")
    }

    /// A phase-continuous slice starting at absolute frame `from`, so two
    /// consecutive calls splice into one uninterrupted signal.
    private func sineChunk(hz: Double, amplitude: Double, frameCount: Int, from start: Int) -> Data {
        var samples = [Int16](repeating: 0, count: frameCount * 2)
        for frame in 0..<frameCount {
            let value = amplitude * sin(2 * Double.pi * hz * Double(start + frame) / sampleRate)
            let quantized = Int16(clamping: Int(round(value * 32_767)))
            samples[frame * 2] = quantized
            samples[frame * 2 + 1] = quantized
        }
        return samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private func leftChannel(_ pcm: Data) -> [Double] {
        pcm.withUnsafeBytes { raw in
            let all = raw.bindMemory(to: Int16.self)
            return stride(from: 0, to: all.count, by: 2).map { Double(all[$0]) / 32_767 }
        }
    }

    /// The largest jump between neighbouring samples — a discontinuity shows up
    /// here and nowhere else.
    private func maxStep(_ samples: [Double]) -> Double {
        var largest = 0.0
        for index in 1..<samples.count {
            largest = max(largest, abs(samples[index] - samples[index - 1]))
        }
        return largest
    }

    /// The same PCM widened the way the S16 entry point widens it, so the two
    /// paths are fed bit-for-bit equivalent input.
    private func floatMirror(of pcm: Data) -> [Float] {
        pcm.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { Float($0) / 32_768 }
        }
    }
}
