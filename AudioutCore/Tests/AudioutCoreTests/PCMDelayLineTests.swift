import Foundation
import Testing

@testable import AudioutCore

/// `PCMDelayLine` — the cadence-preserving S16LE delay line for Phase (ii)
/// sync. Pure and offline: every test drives `exchange` directly with synthetic
/// ramp blocks, so a frame's value IS its global index and "which audio came
/// out" is decidable by reading a sample.
@Suite struct PCMDelayLineTests {

    // MARK: - Fixtures

    /// Frames of stereo S16LE whose left AND right sample both equal the
    /// frame's global index + 1. The `+ 1` keeps real audio distinguishable
    /// from the silence a freshly grown delay emits.
    private func ramp(fromFrame startFrame: Int, frames: Int) -> Data {
        var data = Data(count: frames * 4)
        data.withUnsafeMutableBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<frames {
                let value = Int16(startFrame + i + 1)
                samples[i * 2] = value
                samples[i * 2 + 1] = value
            }
        }
        return data
    }

    /// A steady level on both channels, for the tests that read the crossfade's
    /// shape and so need the two sides of the join to be flat.
    private func constant(_ value: Int16, frames: Int) -> Data {
        var data = Data(count: frames * 4)
        data.withUnsafeMutableBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for sample in 0..<(frames * 2) { samples[sample] = value }
        }
        return data
    }

    /// Run a block through the line and throw the output away — history is all
    /// these callers are building.
    private func feed(_ line: PCMDelayLine, _ pcm: Data) {
        var block = pcm
        line.exchange(&block)
    }

    /// One value per frame, checked to be identical on both channels — a delay
    /// line that lost the interleave would show up here rather than as a
    /// mysterious byte mismatch.
    private func frameValues(_ data: Data) -> [Int16] {
        data.withUnsafeBytes { raw -> [Int16] in
            let samples = raw.bindMemory(to: Int16.self)
            var values: [Int16] = []
            values.reserveCapacity(samples.count / 2)
            for frame in 0..<(samples.count / 2) {
                #expect(samples[frame * 2] == samples[frame * 2 + 1])
                values.append(samples[frame * 2])
            }
            return values
        }
    }

    // MARK: - Tests

    @Test func delayZeroIsIdentity() {
        let line = PCMDelayLine(capacityFrames: 8192)
        for block in 0..<50 {
            let input = ramp(fromFrame: block * 512, frames: 512)
            var pcm = input
            line.exchange(&pcm)
            #expect(pcm == input)
        }
        #expect(line.delayFrames == 0)
    }

    /// The value-returning twin the capture fan-out uses: the caller keeps its
    /// own undelayed block (three more consumers read it after the engine
    /// write) and gets the delayed one back, with identical semantics.
    @Test func returningExchangeLeavesTheCallersBlockAlone() {
        let inPlace = PCMDelayLine(capacityFrames: 8192)
        let returning = PCMDelayLine(capacityFrames: 8192)
        inPlace.setDelayFrames(1000)
        returning.setDelayFrames(1000)

        for block in 0..<30 {
            let input = ramp(fromFrame: block * 512, frames: 512)
            var mutated = input
            inPlace.exchange(&mutated)
            let returned = returning.exchange(input)
            #expect(returned == mutated, "block \(block): both forms must emit the same audio")
        }
        // The caller's own copy is untouched — that is the whole reason this
        // form exists.
        let live = ramp(fromFrame: 30 * 512, frames: 512)
        _ = returning.exchange(live)
        #expect(live == ramp(fromFrame: 30 * 512, frames: 512))
    }

    @Test func cadenceIsPreserved() {
        let line = PCMDelayLine(capacityFrames: 8192)
        line.setDelayFrames(1000)
        for block in 0..<50 {
            let input = ramp(fromFrame: block * 512, frames: 512)
            var pcm = input
            line.exchange(&pcm)
            #expect(pcm.count == input.count)
        }
        #expect(line.delayFrames == 1000)
    }

    @Test func contentIsDelayedByExactlyD() {
        let line = PCMDelayLine(capacityFrames: 8192)
        line.setDelayFrames(1000)
        var fedIn: [Int16] = []
        var cameOut: [Int16] = []
        for block in 0..<30 {
            var pcm = ramp(fromFrame: block * 512, frames: 512)
            fedIn += frameValues(pcm)
            line.exchange(&pcm)
            cameOut += frameValues(pcm)
        }
        #expect(cameOut.count == fedIn.count)
        #expect(cameOut[0..<1000].allSatisfy { $0 == 0 })
        #expect(Array(cameOut[1000...]) == Array(fedIn[0..<(fedIn.count - 1000)]))
    }

    @Test func growEmitsSilenceNotHistory() {
        let line = PCMDelayLine(capacityFrames: 4096)
        line.setDelayFrames(500)
        var lastBeforeChange: Int16 = 0
        for block in 0..<20 {
            var pcm = ramp(fromFrame: block * 512, frames: 512)
            line.exchange(&pcm)
            lastBeforeChange = frameValues(pcm).last!
        }
        #expect(lastBeforeChange == 9740)  // 20 × 512 written, 500 frames behind

        line.setDelayFrames(1500)
        var afterChange: [Int16] = []
        for block in 20..<24 {
            var pcm = ramp(fromFrame: block * 512, frames: 512)
            line.exchange(&pcm)
            afterChange += frameValues(pcm)
        }
        #expect(line.delayFrames == 1500)
        // Exactly the 1000 frames the line grew by are silent — the history now
        // under the read position is NOT replayed — and then the audio picks up
        // precisely where the last pre-change block left off.
        #expect(afterChange[0..<1000].allSatisfy { $0 == 0 })
        #expect(afterChange[1000] == lastBeforeChange + 1)
        #expect(Array(afterChange[1000..<1024]) == (1...24).map { lastBeforeChange + Int16($0) })
    }

    @Test func shrinkDropsContent() {
        let line = PCMDelayLine(capacityFrames: 4096)
        line.setDelayFrames(1500)
        var lastBeforeChange: Int16 = 0
        for block in 0..<20 {
            var pcm = ramp(fromFrame: block * 512, frames: 512)
            line.exchange(&pcm)
            lastBeforeChange = frameValues(pcm).last!
        }
        #expect(lastBeforeChange == 8740)  // 20 × 512 written, 1500 frames behind

        line.setDelayFrames(500)
        var pcm = ramp(fromFrame: 20 * 512, frames: 512)
        line.exchange(&pcm)
        let afterChange = frameValues(pcm)
        #expect(line.delayFrames == 500)
        // A shrink jumps forward onto audio the line already holds: the 1000
        // frames between the old and new read positions are skipped outright.
        // Measured past the 5 ms crossfade that hides the join — inside it the
        // two positions are still mixed.
        #expect(afterChange[220] == lastBeforeChange + 1001 + 220)
        // And the join is a fade, not a cut: the first frame out is still the
        // audio the OLD position was about to emit.
        #expect(afterChange[0] == lastBeforeChange + 1)
    }

    /// The fade itself, on a signal built so its shape is readable: the old
    /// read position sits in silence and the new one in a steady tone, so the
    /// output IS the fade-in curve.
    @Test func shrinkCrossfadesAcrossTheJoin() {
        let line = PCMDelayLine(capacityFrames: 8192)
        line.setDelayFrames(2000)
        for _ in 0..<8 { feed(line, constant(0, frames: 512)) }
        for _ in 0..<3 { feed(line, constant(1000, frames: 512)) }

        line.setDelayFrames(500)
        var pcm = constant(1000, frames: 512)
        line.exchange(&pcm)
        let values = frameValues(pcm)

        #expect(line.delayFrames == 500)
        expectEqualPowerFadeIn(values, to: 1000)
    }

    /// A block shorter than the 220-frame fade must not restart the fade every
    /// block — the two counters have to carry it across the boundaries.
    @Test func aShrinkFadeCarriesAcrossShortBlocks() {
        let line = PCMDelayLine(capacityFrames: 8192)
        line.setDelayFrames(2000)
        for _ in 0..<64 { feed(line, constant(0, frames: 64)) }
        for _ in 0..<24 { feed(line, constant(1000, frames: 64)) }

        line.setDelayFrames(500)
        var values: [Int16] = []
        for _ in 0..<5 {
            var pcm = constant(1000, frames: 64)
            line.exchange(&pcm)
            values += frameValues(pcm)
        }

        // A per-block restart would put the curve back at 0 on every boundary.
        #expect(values[64] > 0)
        expectEqualPowerFadeIn(values, to: 1000)
    }

    /// The fade the line is specified to run: equal power (`cos² + sin² = 1`)
    /// over 220 frames — from the silent old side into `level` — and nothing
    /// but `level` afterwards.
    private func expectEqualPowerFadeIn(
        _ values: [Int16], to level: Double, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        for frame in 0..<220 {
            let expected = (level * sin(Double.pi / 2 * Double(frame) / 220)).rounded()
            #expect(abs(Double(values[frame]) - expected) <= 1,
                    Comment(rawValue: "frame \(frame): \(values[frame]) vs \(expected)"),
                    sourceLocation: sourceLocation)
        }
        #expect(values[220...].allSatisfy { Double($0) == level },
                "past the fade the output is the new position, unmixed",
                sourceLocation: sourceLocation)
    }

    @Test func delayIsClampedToCapacityMinusBlock() {
        let line = PCMDelayLine(capacityFrames: 2048)
        line.setDelayFrames(4000)
        var pcm = ramp(fromFrame: 0, frames: 512)
        line.exchange(&pcm)
        #expect(line.capacityFrames == 2048)
        #expect(line.delayFrames == 1536)
    }

    @Test func partialTrailingBytesAreLeftAlone() {
        let line = PCMDelayLine(capacityFrames: 64)
        line.setDelayFrames(4)
        var pcm = ramp(fromFrame: 0, frames: 10)
        pcm.append(contentsOf: [0xAB, 0xCD])  // half a frame, deliberately

        line.exchange(&pcm)

        #expect(pcm.count == 42)
        #expect(Array(pcm.suffix(2)) == [0xAB, 0xCD])
        // The 10 whole frames still went through the line: 4 frames of
        // start-up silence, then the first 6 frames fed in.
        #expect(frameValues(pcm.prefix(40)) == [0, 0, 0, 0, 1, 2, 3, 4, 5, 6])
    }
}
