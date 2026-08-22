import Foundation
import Testing

@testable import AudiouterCore

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
        let firstAfterChange = frameValues(pcm).first!
        #expect(line.delayFrames == 500)
        // A shrink jumps forward onto audio the line already holds: the 1000
        // frames between the old and new read positions are skipped outright.
        #expect(firstAfterChange == lastBeforeChange + 1001)
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
