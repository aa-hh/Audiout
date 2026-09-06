// PLAN-LIVE-DIAGNOSTICS.md C3: the per-stream peak level and silence run
// behind the `stream_health` telemetry line.
//
// The defect these catch: a session that reads "connected" while carrying
// silence, indistinguishable in the log from healthy playback — which is what
// happened on 2026-09-05. So: silence must accumulate as seconds, a real
// signal must read as its dBFS and reset the run, and the window peak must
// not leak into the next window. Headless, no engine thread.

import Testing
import Foundation
@testable import AirPlayEngine

@Suite struct StreamLevelTests {

    private let sampleRate = 44100
    private let channels = 2
    /// One AirPlay frame: 352 stereo frames of S16LE.
    private let framesPerWrite = 352

    private func buffer(amplitude: Int16) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(framesPerWrite * channels * 2)
        let a = UInt16(bitPattern: amplitude)
        for _ in 0..<(framesPerWrite * channels) {
            bytes.append(UInt8(a & 0xFF))
            bytes.append(UInt8(a >> 8))
        }
        return bytes
    }

    private func write(_ tracker: StreamLevelTracker, streamId: UInt32, amplitude: Int16, times: Int) {
        let bytes = buffer(amplitude: amplitude)
        for _ in 0..<times {
            bytes.withUnsafeBytes { raw in
                tracker.record(streamId: streamId, bytes: raw.baseAddress!, byteCount: raw.count, channels: channels)
            }
        }
    }

    @Test func silenceAccumulatesAsSecondsAndReadsAsTheFloor() {
        let tracker = StreamLevelTracker()
        // 125 writes × 352 frames ≈ 1.0 s of zeros.
        write(tracker, streamId: 0, amplitude: 0, times: 125)

        let snap = tracker.snapshot(sampleRate: sampleRate)
        #expect(snap.count == 1)
        #expect(snap.first?.streamId == 0)
        #expect(snap.first?.peakDBFS == StreamLevelTracker.floorDBFS)
        #expect(abs((snap.first?.silentSeconds ?? 0) - 1.0) < 0.02, "≈1 s of zeros must read as ≈1 s silent")
        #expect(snap.first?.writes == 125)
    }

    @Test func signalReadsAsItsLevelAndResetsTheSilenceRun() {
        let tracker = StreamLevelTracker()
        write(tracker, streamId: 0, amplitude: 0, times: 125)
        // −6.02 dBFS: half of full scale.
        write(tracker, streamId: 0, amplitude: 16384, times: 1)

        let snap = tracker.snapshot(sampleRate: sampleRate)
        #expect(abs((snap.first?.peakDBFS ?? 0) - (-6.02)) < 0.05)
        #expect(snap.first?.silentSeconds == 0, "a write above −60 dBFS ends the silence run")
    }

    @Test func windowPeakResetsBetweenSnapshotsButTheRunPersists() {
        let tracker = StreamLevelTracker()
        write(tracker, streamId: 3, amplitude: -16384, times: 1)   // negative peaks count too
        #expect(abs((tracker.snapshot(sampleRate: sampleRate).first?.peakDBFS ?? 0) - (-6.02)) < 0.05)

        write(tracker, streamId: 3, amplitude: 0, times: 250)      // ≈2 s of zeros
        let second = tracker.snapshot(sampleRate: sampleRate)
        #expect(second.first?.peakDBFS == StreamLevelTracker.floorDBFS, "last window's peak must not carry over")
        #expect(abs((second.first?.silentSeconds ?? 0) - 2.0) < 0.02)

        write(tracker, streamId: 3, amplitude: 0, times: 125)      // +1 s, still silent
        #expect(abs((tracker.snapshot(sampleRate: sampleRate).first?.silentSeconds ?? 0) - 3.0) < 0.02,
                "the silence run counts across windows")
    }

    @Test func streamsAreTrackedApart() {
        let tracker = StreamLevelTracker()
        write(tracker, streamId: 0, amplitude: 0, times: 10)
        write(tracker, streamId: 7, amplitude: 3276, times: 10)    // −20 dBFS

        let snap = tracker.snapshot(sampleRate: sampleRate)
        #expect(snap.map(\.streamId) == [0, 7])
        #expect(snap[0].peakDBFS == StreamLevelTracker.floorDBFS)
        #expect(abs(snap[1].peakDBFS - (-20.0)) < 0.05)
        #expect(snap[1].silentSeconds == 0)
    }
}
