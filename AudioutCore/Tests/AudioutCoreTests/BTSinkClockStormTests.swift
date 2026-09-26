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
    /// let the offset build up.
    @Test func aSteppingClockDoesNotMoveThePlayoutOffset() throws {
        let manager = BTSyncedSink(
            renderSampleRate: Self.sampleRate, channelCount: 1,
            presentationDelayMs: { Int(Self.delayMs) })
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

        for (second, ms) in Self.stepPerSecond().enumerated() {
            let secondEnd = Double(Self.anchorNanos) + Double(second + 1) * 1e9
            let cyclePeriod = Double(cycleFrames) * Self.nsPerFrame * 1_000 / (1_000 + ms)
            var errors: [Double] = []
            while host < secondEnd {
                // The capture tap runs on wall time: everything captured by now.
                while Double(Self.anchorNanos) + Double(written) * Self.nsPerFrame <= host {
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
                out.withUnsafeMutableBufferPointer {
                    _ = sink.renderInterleaved(
                        into: $0, frameCount: cycleFrames, cycleStartMonotonicNanos: Int64(host))
                }
                if out[0] > 0 {
                    let pts = Double(Self.anchorNanos) + Double(out[0] - 1) * Self.nsPerFrame
                    errors.append((host - pts) / 1e6 - Double(Self.delayMs))
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
        #expect(abs(worst) <= 25,
                "the Move's playout offset built up to \(String(format: "%+.1f", worst)) ms (positive = late)")
    }
}
