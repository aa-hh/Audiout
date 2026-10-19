import Foundation
import Testing
@testable import AudioutCore

/// Roadmap 085 ticket 01: the rolling outgoing-audio history that passive drift
/// tracking correlates mic captures against. Pure in-memory — no capture, no
/// devices.
@Suite final class ReferenceAudioRingTests: IsolatedSuite {

    /// 1 kHz mono, 2 bytes/frame, 0.5 s capacity = 500 frames — small enough
    /// that wraparound is a few appends away.
    static func makeRing() -> ReferenceAudioRing {
        ReferenceAudioRing(capacitySeconds: 0.5, sampleRate: 1_000, channels: 1)
    }

    /// `count` S16LE mono frames whose sample VALUE is its absolute frame
    /// index from `start` — so any slice's bytes say exactly which frames they
    /// are.
    static func frames(_ start: Int, count: Int) -> Data {
        var data = Data(count: count * 2)
        data.withUnsafeMutableBytes { (buf: UnsafeMutableRawBufferPointer) in
            let samples = buf.bindMemory(to: Int16.self)
            for i in 0..<count { samples[i] = Int16(truncatingIfNeeded: start + i) }
        }
        return data
    }

    static func pts(frame: Int) -> timespec {
        // 1 kHz → one frame per millisecond, anchored at t = 100 s.
        timespec(tv_sec: 100 + frame / 1_000, tv_nsec: (frame % 1_000) * 1_000_000)
    }

    static let baseNanos = Int64(100) * 1_000_000_000

    static func sampleValues(_ pcm: Data) -> [Int16] {
        pcm.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    }

    /// THE DEFECT. The ring sits on the delivery path unconditionally; if
    /// `append` ever retains while disarmed, every session keeps a rolling tape
    /// of the user's audio with nobody measuring — a privacy hole, not a bug in
    /// math.
    @Test func disarmed_retainsNothing_andDisarmDropsWhatWasHeld() {
        let ring = Self.makeRing()
        ring.append(Self.frames(0, count: 100), pts: Self.pts(frame: 0))
        #expect(ring.retainedRangeNanos() == nil, "disarmed appends must vanish")

        ring.setArmed(true)
        ring.append(Self.frames(0, count: 100), pts: Self.pts(frame: 0))
        #expect(ring.retainedRangeNanos() != nil)

        ring.setArmed(false)
        #expect(ring.retainedRangeNanos() == nil, "disarming drops the retained audio")
    }

    /// THE DEFECT. The correlator turns a peak's lag into a delay via the
    /// slice's `startPtsNanos`; a frame of offset error in the pts↔frame math
    /// becomes a systematic alignment error on every passive measurement.
    @Test func slice_returnsExactFramesWithExactStartPts() {
        let ring = Self.makeRing()
        ring.setArmed(true)
        // Three contiguous blocks: frames 0..<300 over 300 ms.
        for block in 0..<3 {
            ring.append(Self.frames(block * 100, count: 100),
                        pts: Self.pts(frame: block * 100))
        }

        // 50 ms..250 ms = frames 50..<250.
        let slice = ring.slice(fromNanos: Self.baseNanos + 50_000_000,
                               toNanos: Self.baseNanos + 250_000_000)
        #expect(slice != nil)
        guard let slice else { return }
        #expect(slice.startPtsNanos == Self.baseNanos + 50_000_000)
        #expect(Self.sampleValues(slice.pcm) == (50..<250).map { Int16($0) })
    }

    /// THE DEFECT. Once retention exceeds capacity the copy path wraps; wrong
    /// modular arithmetic hands the correlator a slice with the join in the
    /// wrong place — bytes that never went to any speaker in that order.
    @Test func wraparound_dropsOldestAndSlicesAcrossTheJoin() {
        let ring = Self.makeRing()   // capacity 500 frames
        ring.setArmed(true)
        // 8 × 100 = 800 frames: 0..<300 fall off, 300..<800 retained.
        for block in 0..<8 {
            ring.append(Self.frames(block * 100, count: 100),
                        pts: Self.pts(frame: block * 100))
        }

        let range = ring.retainedRangeNanos()
        #expect(range?.lowerBound == Self.baseNanos + 300_000_000)
        #expect(range?.upperBound == Self.baseNanos + 800_000_000)

        // A slice straddling the ring's physical join (frame 500) comes back
        // in timeline order.
        let slice = ring.slice(fromNanos: Self.baseNanos + 450_000_000,
                               toNanos: Self.baseNanos + 550_000_000)
        #expect(slice?.startPtsNanos == Self.baseNanos + 450_000_000)
        #expect(slice.map { Self.sampleValues($0.pcm) } == (450..<550).map { Int16($0) })

        // Asking for what fell off clamps to the oldest retained frame.
        let clamped = ring.slice(fromNanos: Self.baseNanos,
                                 toNanos: Self.baseNanos + 350_000_000)
        #expect(clamped?.startPtsNanos == Self.baseNanos + 300_000_000)
        #expect(clamped.map { Self.sampleValues($0.pcm) } == (300..<350).map { Int16($0) })
    }

    /// THE DEFECT. The delivered pts ride the capture device's clock, which
    /// runs a few parts per million off nominal. Measuring each block's
    /// expected pts by accumulating nominal durations from the run's first
    /// block lets that offset pile up past the 1 ms continuity tolerance and
    /// restart a perfectly gapless history — truncating the window the
    /// correlator needs, on healthy hardware, every few seconds.
    @Test func aSteadyClockOffsetDoesNotRestartTheHistory() {
        let ring = Self.makeRing()   // capacity 500 frames
        ring.setArmed(true)
        // Eight contiguous 100-frame (100 ms) blocks whose pts each run 0.5 ms
        // ahead of where nominal accumulation would put them.
        for block in 0..<8 {
            let nanos = Self.baseNanos
                + Int64(block) * 100_000_000
                + Int64(block) * 500_000
            ring.append(Self.frames(block * 100, count: 100),
                        pts: timespec(tv_sec: Int(nanos / 1_000_000_000),
                                      tv_nsec: Int(nanos % 1_000_000_000)))
        }
        let range = ring.retainedRangeNanos()
        #expect(range.map { $0.upperBound - $0.lowerBound } == 500_000_000,
                "a whole capacity's worth must still be retained, not one block")

        // A genuine hole still restarts the history.
        ring.append(Self.frames(1_000, count: 100),
                    pts: Self.pts(frame: 1_000))
        let after = ring.retainedRangeNanos()
        #expect(after.map { $0.upperBound - $0.lowerBound } == 100_000_000)
        #expect(after?.lowerBound == Self.baseNanos + 1_000_000_000)
    }

    /// THE DEFECT. A tap rebuild or producer handoff leaves a hole in the pts
    /// timeline; splicing across it silently would hand the correlator a
    /// reference whose frame positions lie about their send time, and every
    /// delay measured against it would be off by the hole.
    @Test func ptsGap_restartsTheHistoryAtTheNewBlock() {
        let ring = Self.makeRing()
        ring.setArmed(true)
        ring.append(Self.frames(0, count: 100), pts: Self.pts(frame: 0))
        // 200 ms hole (frames 100..<300 never delivered).
        ring.append(Self.frames(300, count: 100), pts: Self.pts(frame: 300))

        let range = ring.retainedRangeNanos()
        #expect(range?.lowerBound == Self.baseNanos + 300_000_000,
                "the pre-gap audio must be gone")
        #expect(range?.upperBound == Self.baseNanos + 400_000_000)
        let slice = ring.slice(fromNanos: 0, toNanos: .max)
        #expect(slice.map { Self.sampleValues($0.pcm) } == (300..<400).map { Int16($0) })
    }
}
