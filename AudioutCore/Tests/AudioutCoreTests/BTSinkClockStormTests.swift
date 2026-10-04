// Copyright (C) 2026 ahh and contributors.

import Foundation
import Testing
@testable import AudioutCore

/// A Bluetooth link whose pacing clock steps every second (customer session
/// D4C23DD3, 1.2.0, "Move 2" after a second Move joined): the sink must keep
/// playing each frame at `pts + delay` however unevenly the device pulls.
@Suite struct BTSinkClockStormTests {

    static let sampleRate = 48_000.0
    static let nsPerFrame = 1_000_000_000.0 / sampleRate
    static let anchorNanos: Int64 = 1_000 * 1_000_000_000
    static let delayMs: Int64 = 100   // Move 2's anchored delay in the log

    /// Every `bt_clock_jump` the Move logged, as (seconds after the first
    /// jump, ms). The first jump came 3 s after the gate opened.
    static let storm: [(second: Int, ms: Double)] = [
        (0, -42.4), (1, 13.8), (2, -12.0), (4, 2.7), (5, -96.2), (6, 53.1), (7, -84.9),
        (8, 3.2), (9, 2.3), (12, 79.3), (13, -88.2), (14, -4.8), (18, 78.7), (19, -61.7),
        (20, -18.3), (23, 78.1), (24, -60.6), (25, -11.2), (26, 78.2), (27, -73.8),
        (32, 78.1), (33, -55.4), (34, -37.3), (37, 79.8), (38, -101.9), (39, 41.8),
        (40, -53.7), (41, -36.2), (45, 46.8), (46, 36.5), (47, -94.2), (48, 82.4),
        (49, -35.5), (50, -25.1), (55, 78.5), (56, -68.9), (57, -24.1), (59, 78.6),
        (60, -66.9), (61, -32.1), (62, 2.1), (65, 45.9), (66, 11.2), (67, -72.2),
        (68, 92.6), (69, -66.6), (70, -32.0), (74, 52.5), (75, 11.2), (76, -79.0),
        (77, 81.5),
    ]
    static let leadInSeconds = 3

    /// ms the device's clock gained in each wall-clock second of the replay.
    static func stepPerSecond() -> [Double] {
        var steps = [Double](repeating: 0, count: leadInSeconds + 80)
        for jump in storm { steps[leadInSeconds + jump.second] = jump.ms }
        return steps
    }

    /// The series as fed really is what `BTClockStability` reports: a device
    /// that pulls `1000 + ms` ms of audio in a wall-clock second reads as a
    /// `.jumped(ms)` sample at the end of it.
    @Test func theReplayedPullsAreTheLoggedJumps() {
        var detector = BTClockStability()
        var sampleTime = 1_000.0
        _ = detector.observe(sampleTime: sampleTime, hostNanos: 0, nominalRate: Self.sampleRate)
        for (second, ms) in Self.stepPerSecond().enumerated() {
            sampleTime += (1_000 + ms) / 1_000 * Self.sampleRate
            let outcome = detector.observe(
                sampleTime: sampleTime, hostNanos: Int64(second + 1) * 1_000_000_000,
                nominalRate: Self.sampleRate)
            if ms == 0 {
                #expect(outcome == .advanced)
            } else if case .jumped(let got) = outcome {
                #expect(abs(got - ms) < 0.01)
            } else {
                Issue.record("second \(second): expected a \(ms) ms jump, got \(outcome)")
            }
        }
    }

    /// THE DEFECT. The render cycles of a device whose clock steps are spaced
    /// by its own pulls, not by wall time: a second in which it pulls 958 ms
    /// of audio leaves 42 ms more in the ring, and a plain first-in-first-out
    /// ring plays everything after it 42 ms late. Summed over the storm that
    /// was a quarter of a second, which is what the user heard. Asserted on
    /// the median over each 5 s, so a correction may lag one step but never
    /// let the offset build up. The 60 ms row is red if the forward clamp
    /// keeps a fixed 100 ms margin instead of min(100 ms, anchored delay): the
    /// first 42 ms under-pull then moves 2 ms and the Move stays 40 ms late.
    @Test(arguments: [Self.delayMs, 60])
    func aSteppingClockDoesNotMoveThePlayoutOffset(delayMs: Int64) throws {
        let worst = try Self.worstStormOffsetMs(anchoredDelayMs: delayMs)
        #expect(abs(worst) <= 25,
                "the Move's playout offset built up to \(String(format: "%+.1f", worst)) ms (positive = late)")
    }

    /// A real tap hands over each 10 ms chunk once it is complete, so the ring
    /// holds the anchored delay less up to one chunk. Red if the margin cap is
    /// the anchored delay rather than the ring's room at release less one chunk.
    @Test func aCaptureThatDeliversOneChunkLateDoesNotMoveThePlayoutOffset() throws {
        let worst = try Self.worstStormOffsetMs(anchoredDelayMs: Self.delayMs, captureLagFrames: 480)
        #expect(abs(worst) <= 25,
                "the Move's playout offset built up to \(String(format: "%+.1f", worst)) ms (positive = late)")
    }

    /// A −115 ms trim committed at 200 ms while the first 42 ms under-pull is
    /// still below the re-alignment threshold spends that pending under-pull as
    /// room, so the ring settles at 85 ms, under the 100 ms margin. (At an
    /// anchored 100 ms a live trim can shorten the delay only by the pending
    /// under-pull, too little to tell the two caps apart.) Red if the margin cap
    /// is frozen at release and ignores the later trim.
    @Test func aTrimThatShortensTheDelayAfterReleaseDoesNotMoveThePlayoutOffset() throws {
        let worst = try Self.worstStormOffsetMs(anchoredDelayMs: 200, trim: (3.45, -115))
        #expect(abs(worst) <= 25,
                "the Move's playout offset built up to \(String(format: "%+.1f", worst)) ms (positive = late)")
    }

    /// Replays the storm against a sink anchored at `anchoredDelayMs` and
    /// returns the worst 5 s median of (playout − pts − delay), positive =
    /// late. The capture side hands over each chunk once `captureLagFrames`
    /// past its start pts have gone by on wall time; `trim`, if any, is applied
    /// and committed `atSecond` seconds after the anchor, and the offset is then
    /// measured against the trimmed delay.
    static func worstStormOffsetMs(
        anchoredDelayMs delayMs: Int64, captureLagFrames: Int = 0,
        trim: (atSecond: Double, ms: Double)? = nil
    ) throws -> Double {
        let manager = BTSyncedSink(
            renderSampleRate: Self.sampleRate, channelCount: 1,
            presentationDelayMs: { Int(delayMs) })
        manager.setComposition(BTGroupComposition(airPlayPresent: true, macLocalPresent: false))
        manager.setDevices([.init(deviceID: 0, uid: "move-2")])
        defer { manager.stop() }
        let sink = try #require(manager.sinkForTesting(uid: "move-2"))

        let chunkFrames = 480   // the tap's 10 ms delivery
        let cycleFrames = 512
        var written = 0         // producer frames so far; frame i carries value i + 1
        var chunk = [Float](repeating: 0, count: chunkFrames)
        var out = [Float](repeating: 0, count: cycleFrames)
        var host = Double(Self.anchorNanos)
        var errorsBySecond: [[Double]] = []
        var targetDelayMs = Double(delayMs)
        var pendingTrim = trim

        for (second, ms) in Self.stepPerSecond().enumerated() {
            let secondEnd = Double(Self.anchorNanos) + Double(second + 1) * 1e9
            let cyclePeriod = Double(cycleFrames) * Self.nsPerFrame * 1_000 / (1_000 + ms)
            var errors: [Double] = []
            while host < secondEnd {
                // The capture tap runs on wall time: everything captured by now.
                while Double(Self.anchorNanos) + Double(written + captureLagFrames) * Self.nsPerFrame <= host {
                    for i in 0..<chunkFrames { chunk[i] = Float(written + i + 1) }
                    let ptsNanos = Self.anchorNanos + Int64((Double(written) * Self.nsPerFrame).rounded())
                    chunk.withUnsafeBufferPointer {
                        sink.enqueue(
                            interleavedFrames: $0.baseAddress!, frameCount: chunkFrames,
                            pts: timespec(tv_sec: Int(ptsNanos / 1_000_000_000),
                                          tv_nsec: Int(ptsNanos % 1_000_000_000)))
                    }
                    written += chunkFrames
                }
                if let move = pendingTrim, host >= Double(Self.anchorNanos) + move.atSecond * 1e9 {
                    manager.setTrimMs(move.ms, forDeviceUID: "move-2")
                    manager.reanchorIfTrimClamped(forDeviceUID: "move-2")
                    sink.test_waitForPendingRebuild()
                    #expect(sink.hasStartedRendering, "the trim was clamped, so the commit re-anchored")
                    targetDelayMs += move.ms
                    pendingTrim = nil
                }
                out.withUnsafeMutableBufferPointer {
                    _ = sink.renderInterleaved(
                        into: $0, frameCount: cycleFrames, cycleStartMonotonicNanos: Int64(host))
                }
                if out[0] > 0 {
                    let pts = Double(Self.anchorNanos) + Double(out[0] - 1) * Self.nsPerFrame
                    errors.append((host - pts) / 1e6 - targetDelayMs)
                }
                host += cyclePeriod
            }
            errorsBySecond.append(errors)
        }

        var worst = 0.0
        for start in stride(from: Self.leadInSeconds, to: errorsBySecond.count - 4, by: 5) {
            let window = errorsBySecond[start..<start + 5].flatMap { $0 }.sorted()
            let median = window[window.count / 2]
            if abs(median) > abs(worst) { worst = median }
        }
        return worst
    }

    /// A cycle that arrives 900 ms after the last one (just under the stall
    /// bound) while the capture side delivered only 150 ms: the re-alignment
    /// asks for ~890 ms forward from a ring holding ~250 ms. Drop the
    /// `seekSafetyMarginMs` clamp from the forward branch of
    /// `realignToDevicePulls` and the seek drains the ring to the write
    /// pointer, so this cycle ends in silence and this test goes red.
    @Test func aForwardRealignmentStopsTheSafetyMarginShortOfTheWritePointer() throws {
        let manager = BTSyncedSink(
            renderSampleRate: Self.sampleRate, channelCount: 1,
            presentationDelayMs: { Int(Self.delayMs) })
        manager.setComposition(BTGroupComposition(airPlayPresent: true, macLocalPresent: false))
        manager.setDevices([.init(deviceID: 0, uid: "move-2")])
        defer { manager.stop() }
        let sink = try #require(manager.sinkForTesting(uid: "move-2"))

        let chunkFrames = 480
        let cycleFrames = 512
        var written = 0         // frame i carries value i + 1
        var chunk = [Float](repeating: 0, count: chunkFrames)
        var out = [Float](repeating: 0, count: cycleFrames)
        func writeChunk() {
            for i in 0..<chunkFrames { chunk[i] = Float(written + i + 1) }
            let ptsNanos = Self.anchorNanos + Int64((Double(written) * Self.nsPerFrame).rounded())
            chunk.withUnsafeBufferPointer {
                sink.enqueue(
                    interleavedFrames: $0.baseAddress!, frameCount: chunkFrames,
                    pts: timespec(tv_sec: Int(ptsNanos / 1_000_000_000),
                                  tv_nsec: Int(ptsNanos % 1_000_000_000)))
            }
            written += chunkFrames
        }
        func render(at host: Double) {
            out.withUnsafeMutableBufferPointer {
                _ = sink.renderInterleaved(
                    into: $0, frameCount: cycleFrames, cycleStartMonotonicNanos: Int64(host))
            }
        }

        // One second of even pulls: the gate opens and the ring settles at the delay.
        let cyclePeriod = Double(cycleFrames) * Self.nsPerFrame
        var host = Double(Self.anchorNanos)
        while host < Double(Self.anchorNanos) + 1e9 {
            while Double(Self.anchorNanos) + Double(written) * Self.nsPerFrame <= host { writeChunk() }
            render(at: host)
            host += cyclePeriod
        }
        #expect(out[cycleFrames - 1] > 0, "the gate never opened")

        for _ in 0..<15 { writeChunk() }    // 150 ms
        let stallHost = host - cyclePeriod + 900_000_000
        render(at: stallHost)

        let marginFrames = Int(BTDeviceSink.seekSafetyMarginMs / 1_000 * Self.sampleRate)
        var last = Int(out[cycleFrames - 1])
        #expect(last > 0, "the re-alignment drained the ring")
        // The margin is the ring's room at release less one cycle (the sink's
        // stand-in for a capture chunk), so it sits up to a cycle under 100 ms.
        #expect(written - last >= marginFrames - 2 * cycleFrames - 8,
                "the ring kept \(written - last) frames after the cycle")

        // Capture and device stalled together, so capture resumes at wall rate
        // from the stall while the device runs the storm's fast 92.6 ms second.
        // Red if the clamped shortfall is booked into `pullRealignedNanos`
        // instead of re-basing the measurement: the stuck forward remainder
        // swallows this over-pull, the backward move never runs, and the ring
        // drains.
        let captureBase = stallHost - Double(written) * Self.nsPerFrame
        let fastPeriod = cyclePeriod * 1_000 / 1_092.6
        let thresholdFrames = Int(BTDeviceSink.pullRealignThresholdMs / 1_000 * Self.sampleRate)
        var lowest = Int.max
        var movedBack = false
        host = stallHost + fastPeriod
        while host < stallHost + 1e9 {
            while captureBase + Double(written) * Self.nsPerFrame <= host { writeChunk() }
            render(at: host)
            let now = Int(out[cycleFrames - 1])
            #expect(out[0] > 0 && now > 0, "the over-pull ran the ring dry")
            if now < last { movedBack = true }
            lowest = min(lowest, written - now)
            last = now
            host += fastPeriod
        }
        // The ring may sag one threshold's worth before the backward move,
        // plus one cycle and one capture chunk of timing granularity.
        #expect(lowest >= marginFrames - thresholdFrames - cycleFrames - chunkFrames,
                "the ring fell to \(lowest) frames during the over-pull")
        #expect(movedBack, "the over-pull's backward re-alignment never ran")
    }
}
