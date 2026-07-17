// T-ENG-CADENCE-1 headless tests for write-cadence deficit/overrun detection
// (first-light backlog #4).
//
// SCOPE: BUILD + HEADLESS ONLY. No real event loop, no sockets, no PTP.
//
// Two levels are exercised:
//   1. `WriteCadenceTracker` directly — deterministic control over the
//      "wall-clock elapsed" input via a fixed, injected sample count/rate and
//      real (but tiny, sleep-based) delays, so the deficit/overrun math is
//      verified without any dependency on the full engine/dispatcher.
//   2. `AirPlayEngine.write(pcm:pts:)` end-to-end in headless test mode —
//      proves the hot path actually feeds the tracker, and that
//      `writeCadenceSnapshot()` reflects it.

import XCTest
@testable import AirPlayEngine
import CAirPlayEngine

final class WriteCadenceTests: XCTestCase {

    // MARK: - WriteCadenceTracker unit tests

    /// A nominal (real-time-paced) feed should stay ~zero on both deficit and
    /// overrun: each write's wall-clock gap to the audio time it represents is
    /// small and roughly symmetric, so it should not accumulate a meaningful
    /// running deficit OR overrun.
    func testNominalFeedStaysNearZero() async throws {
        let tracker = WriteCadenceTracker()
        let sampleRate = 44100
        let samplesPerWrite = 352 // AirPlay frame size
        let audioSeconds = Double(samplesPerWrite) / Double(sampleRate)

        // First call only seeds the baseline (no prior write to compare
        // against) — matches the tracker's documented behavior.
        tracker.record(samples: samplesPerWrite, sampleRate: sampleRate)

        for _ in 0..<20 {
            // Sleep for exactly the audio duration this write represents, so
            // wall-clock elapsed ~= audio time delivered (nominal cadence).
            try await Task.sleep(nanoseconds: UInt64(audioSeconds * 1e9))
            tracker.record(samples: samplesPerWrite, sampleRate: sampleRate)
        }

        let snapshot = tracker.snapshot()
        XCTAssertEqual(snapshot.writeCount, 21)
        // Scheduling jitter under CI/parallel-agent load is real but bounded;
        // the nominal feed should never accumulate anywhere near the underfed
        // feed's magnitude (asserted below at >> 0.15s over a much shorter,
        // deliberately-stalled run).
        XCTAssertLessThan(snapshot.deficitSeconds, 0.15, "nominal feed should not accrue a meaningful deficit")
        XCTAssertLessThan(snapshot.overrunSeconds, 0.15, "nominal feed should not accrue a meaningful overrun")
    }

    /// A paced/underfed feed — where each write's wall-clock gap is much
    /// larger than the audio time it represents (e.g. the producer stalls) —
    /// must show up as a growing deficit, not get silently absorbed.
    func testUnderfedFeedReflectsDeficit() {
        let tracker = WriteCadenceTracker()
        let sampleRate = 44100
        let samplesPerWrite = 352
        let audioSeconds = Double(samplesPerWrite) / Double(sampleRate) // ~8ms

        tracker.record(samples: samplesPerWrite, sampleRate: sampleRate) // seed baseline

        // Simulate 5 writes, each arriving ~50ms late relative to the ~8ms of
        // audio it represents -> ~42ms deficit per write, ~210ms cumulative.
        let stallSeconds = 0.05
        for _ in 0..<5 {
            Thread.sleep(forTimeInterval: stallSeconds)
            tracker.record(samples: samplesPerWrite, sampleRate: sampleRate)
        }

        let snapshot = tracker.snapshot()
        XCTAssertEqual(snapshot.writeCount, 6)
        let expectedDeficitPerWrite = stallSeconds - audioSeconds
        let expectedTotal = expectedDeficitPerWrite * 5
        // Allow generous scheduling slop (Thread.sleep is not exact) but the
        // deficit must clearly reflect the stall, not be near zero.
        XCTAssertGreaterThan(snapshot.deficitSeconds, expectedTotal * 0.5)
        XCTAssertGreaterThan(snapshot.lastGapSeconds, 0, "last gap should be positive (behind) after a stall")
        XCTAssertEqual(snapshot.overrunSeconds, 0, accuracy: 0.01, "an underfed feed should not also register overrun")
    }

    /// The inverse: a burst of writes delivered faster than the audio time
    /// they represent (e.g. catching up after a stall) must register as
    /// overrun, tracked separately from deficit (never allowed to cancel a
    /// prior deficit out silently).
    func testBurstFeedReflectsOverrun() {
        let tracker = WriteCadenceTracker()
        let sampleRate = 44100
        // A large sample count per write so its audio-time is much bigger
        // than the (near-zero) wall-clock time consumed issuing the calls
        // back-to-back with no sleep in between.
        let samplesPerWrite = 44100 // 1 full second of audio per write

        tracker.record(samples: samplesPerWrite, sampleRate: sampleRate) // seed baseline
        for _ in 0..<3 {
            tracker.record(samples: samplesPerWrite, sampleRate: sampleRate)
        }

        let snapshot = tracker.snapshot()
        XCTAssertEqual(snapshot.writeCount, 4)
        XCTAssertGreaterThan(snapshot.overrunSeconds, 2.5, "back-to-back big-audio-time writes should register as overrun")
        XCTAssertLessThan(snapshot.lastGapSeconds, 0, "last gap should be negative (ahead) during a burst")
        XCTAssertEqual(snapshot.deficitSeconds, 0, accuracy: 0.01)
    }

    /// `reset()` clears counters AND forgets the last-write baseline, so the
    /// write immediately after a reset seeds fresh rather than comparing
    /// against a stale (now-ancient) timestamp and reporting a bogus deficit.
    func testResetClearsCountersAndBaseline() {
        let tracker = WriteCadenceTracker()
        tracker.record(samples: 352, sampleRate: 44100)
        Thread.sleep(forTimeInterval: 0.05)
        tracker.record(samples: 352, sampleRate: 44100)
        XCTAssertGreaterThan(tracker.snapshot().deficitSeconds, 0)

        tracker.reset()
        let afterReset = tracker.snapshot()
        XCTAssertEqual(afterReset.writeCount, 0)
        XCTAssertEqual(afterReset.deficitSeconds, 0)
        XCTAssertEqual(afterReset.overrunSeconds, 0)
        XCTAssertEqual(afterReset.lastGapSeconds, 0)

        // The very next record() call must seed the baseline again (no huge
        // deficit from comparing against the pre-reset timestamp).
        tracker.record(samples: 352, sampleRate: 44100)
        XCTAssertEqual(tracker.snapshot().writeCount, 1)
        XCTAssertEqual(tracker.snapshot().deficitSeconds, 0, "first record after reset only seeds the baseline")
    }

    /// Degenerate inputs (zero samples/rate) must be ignored, not corrupt the
    /// tracker or crash on a division.
    func testDegenerateInputsAreIgnored() {
        let tracker = WriteCadenceTracker()
        tracker.record(samples: 0, sampleRate: 44100)
        tracker.record(samples: 352, sampleRate: 0)
        XCTAssertEqual(tracker.snapshot().writeCount, 0)
    }

    // MARK: - AirPlayEngine.write(pcm:pts:) end-to-end

    /// The hot `write` path actually feeds the tracker: a paced/underfed
    /// synthetic feed through the real public API reflects a deficit via
    /// `writeCadenceSnapshot()`.
    func testEngineWritePathFeedsCadenceTracker() async throws {
        let engine = AirPlayEngine()
        await engine.enterHeadlessTestMode()

        let samplesPerWrite = 352
        let bytesPerSample = 2 * 2 // S16LE, stereo
        let pcm = Data(repeating: 0, count: samplesPerWrite * bytesPerSample)
        let pts = timespec(tv_sec: 0, tv_nsec: 0)

        engine.write(pcm: pcm, pts: pts) // seeds baseline

        for _ in 0..<5 {
            try await Task.sleep(nanoseconds: 50_000_000) // stall well beyond the ~8ms frame
            engine.write(pcm: pcm, pts: pts)
        }

        let snapshot = engine.writeCadenceSnapshot()
        XCTAssertEqual(snapshot.writeCount, 6)
        XCTAssertGreaterThan(snapshot.deficitSeconds, 0.1, "underfed real writes through the public API must show a deficit")
    }

    /// A nominal feed through the public API stays ~zero, mirroring the unit
    /// test above but exercised through the actual hot path.
    func testEngineWritePathNominalFeedStaysNearZero() async throws {
        let engine = AirPlayEngine()
        await engine.enterHeadlessTestMode()

        let samplesPerWrite = 352
        let sampleRate = 44100
        let audioSeconds = Double(samplesPerWrite) / Double(sampleRate)
        let pcm = Data(repeating: 0, count: samplesPerWrite * 4)
        let pts = timespec(tv_sec: 0, tv_nsec: 0)

        engine.write(pcm: pcm, pts: pts)
        for _ in 0..<10 {
            try await Task.sleep(nanoseconds: UInt64(audioSeconds * 1e9))
            engine.write(pcm: pcm, pts: pts)
        }

        let snapshot = engine.writeCadenceSnapshot()
        XCTAssertEqual(snapshot.writeCount, 11)
        XCTAssertLessThan(snapshot.deficitSeconds, 0.15)
        XCTAssertLessThan(snapshot.overrunSeconds, 0.15)
    }
}
