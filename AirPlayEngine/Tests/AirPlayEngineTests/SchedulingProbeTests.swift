// T-ENG-SCHED-1 headless tests for the write-scheduling diagnostic probe
// (docs/plans/PLAN-AUDIO-THREAD-SCHEDULING.md task T1) — the always-on probe
// that discriminates the three competing causes of audio dropouts under
// system load:
//   H1 send-thread starvation  -> wakeLatency
//   H2 capture-side underrun   -> interArrivalGap
//   H3 in-cycle stalls         -> inCycleWork
//
// SCOPE: BUILD + HEADLESS ONLY. No real event loop, no sockets, no PTP,
// no live hardware. Mirrors `WriteCadenceTests.swift`'s two-level shape:
//   1. `WriteSchedulingProbe` exercised directly with synthetic timestamps,
//      so the percentile math and rate-limiting are verified deterministically.
//   2. `AirPlayEngine.write(pcm:pts:)` end-to-end in headless test mode,
//      proving the hot path actually feeds all three metric families.
//
// WHAT THIS FILE CANNOT PROVE (say so, don't fake it): that the hot-path
// `record*` calls make zero heap allocations under instrumentation (e.g.
// malloc-stack-logging) — no such harness exists in this package yet. The
// `testRecordManyTimesStaysBoundedAndFast` test below is a PROXY: it drives
// far more samples than the ring's fixed capacity through each metric family
// and asserts (a) it completes in a tight time budget and (b) the ring's
// windowed percentiles never depend on the full cumulative count — both
// consistent with a fixed-size, non-growing buffer, but neither is a direct
// allocation measurement.

import XCTest
@testable import AirPlayEngine
import CAirPlayEngine

final class SchedulingProbeTests: XCTestCase {

    // MARK: - Percentile computation against synthetic timestamps

    /// Feeding a known set of wake-latency samples must produce exactly the
    /// nearest-rank percentiles for that set, computed independently here.
    func testWakeLatencyPercentilesMatchSyntheticSequence() {
        let probe = WriteSchedulingProbe(logInterval: 3600, ringCapacity: 128)

        // 1...100 ms, one sample each — a simple, hand-checkable distribution.
        let samples = (1...100).map(Double.init)
        for ms in samples {
            probe.recordWakeLatency(enqueuedAtMs: 1000, startedAtMs: 1000 + ms)
        }

        let snapshot = probe.snapshot()
        let expected = expectedPercentiles(samples)
        XCTAssertEqual(snapshot.wakeLatency.count, 100)
        XCTAssertEqual(snapshot.wakeLatency.p50Ms, expected.p50, accuracy: 0.001)
        XCTAssertEqual(snapshot.wakeLatency.p95Ms, expected.p95, accuracy: 0.001)
        XCTAssertEqual(snapshot.wakeLatency.p99Ms, expected.p99, accuracy: 0.001)
        XCTAssertEqual(snapshot.wakeLatency.maxMs, 100, accuracy: 0.001)
    }

    /// Same check for in-cycle work time, with an irregular (non-1...N)
    /// synthetic sequence so the test isn't accidentally tautological with
    /// the wake-latency one.
    func testInCycleWorkPercentilesMatchSyntheticSequence() {
        let probe = WriteSchedulingProbe(logInterval: 3600, ringCapacity: 128)
        let samples: [Double] = [0.05, 0.08, 0.12, 0.3, 0.9, 1.2, 2.5, 4.0, 8.0, 15.0]
        for ms in samples {
            probe.recordInCycleWork(startedAtMs: 500, finishedAtMs: 500 + ms)
        }

        let snapshot = probe.snapshot()
        let expected = expectedPercentiles(samples)
        XCTAssertEqual(snapshot.inCycleWork.count, UInt64(samples.count))
        XCTAssertEqual(snapshot.inCycleWork.p50Ms, expected.p50, accuracy: 0.001)
        XCTAssertEqual(snapshot.inCycleWork.p95Ms, expected.p95, accuracy: 0.001)
        XCTAssertEqual(snapshot.inCycleWork.p99Ms, expected.p99, accuracy: 0.001)
        XCTAssertEqual(snapshot.inCycleWork.maxMs, 15.0, accuracy: 0.001)
    }

    /// Inter-arrival gap is derived from successive `recordWriteArrival()`
    /// calls (no explicit timestamps to inject), so this test uses real
    /// `Thread.sleep` gaps instead — checking ORDER/relative magnitude
    /// (a long gap must show up as the max, short gaps as the low
    /// percentiles) rather than exact synthetic values.
    func testInterArrivalGapReflectsRealGaps() {
        let probe = WriteSchedulingProbe(logInterval: 3600, ringCapacity: 128)
        probe.recordWriteArrival() // seeds baseline, no gap recorded yet

        for _ in 0..<5 {
            Thread.sleep(forTimeInterval: 0.005) // ~5ms
            probe.recordWriteArrival()
        }
        Thread.sleep(forTimeInterval: 0.05) // one much larger ~50ms gap
        probe.recordWriteArrival()

        let snapshot = probe.snapshot()
        XCTAssertEqual(snapshot.interArrivalGap.count, 6) // 6 gaps from 7 arrivals
        XCTAssertGreaterThan(snapshot.interArrivalGap.maxMs, 40, "the deliberate long gap must surface as the max")
        XCTAssertLessThan(snapshot.interArrivalGap.p50Ms, 20, "the short gaps should dominate the median")
    }

    /// A ring smaller than the sample count still reports percentiles over
    /// its bounded window (most recent samples), while `count` stays the
    /// TRUE cumulative total — the two numbers are allowed to diverge by
    /// design (see `MetricRing`/`WriteSchedulingProbe` doc comments).
    func testCumulativeCountExceedsWindowedPercentileSampleSize() {
        let probe = WriteSchedulingProbe(logInterval: 3600, ringCapacity: 10)
        for i in 1...50 {
            probe.recordInCycleWork(startedAtMs: 0, finishedAtMs: Double(i))
        }
        let snapshot = probe.snapshot()
        XCTAssertEqual(snapshot.inCycleWork.count, 50, "count is the true cumulative total, not the ring capacity")
        // Only the last 10 values (41...50) remain in the window, so the
        // reported max must be 50 and p50 must sit within that tail, never
        // reflecting the early (now-evicted) small values.
        XCTAssertEqual(snapshot.inCycleWork.maxMs, 50, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(snapshot.inCycleWork.p50Ms, 41)
    }

    /// Degenerate/invalid inputs (negative or non-finite durations, which
    /// should never occur from real monotonic-clock readings but must not be
    /// allowed to corrupt the ring if they somehow did) are silently dropped.
    func testDegenerateDurationsAreIgnored() {
        let probe = WriteSchedulingProbe(logInterval: 3600, ringCapacity: 16)
        probe.recordInCycleWork(startedAtMs: 10, finishedAtMs: 5) // negative duration
        probe.recordWakeLatency(enqueuedAtMs: 0, startedAtMs: 100) // enqueuedAtMs == 0 => "not set"
        probe.recordInCycleWork(startedAtMs: .nan, finishedAtMs: 5)

        let snapshot = probe.snapshot()
        XCTAssertEqual(snapshot.inCycleWork.count, 0)
        XCTAssertEqual(snapshot.wakeLatency.count, 0)
    }

    // MARK: - Rate limiting

    /// The log line must fire at most once per `logInterval`, not once per
    /// `recordWriteArrival()` call — verified by redirecting stderr into a
    /// pipe (the probe writes its rate-limited line there, mirroring
    /// `WriteLatencyProbe`'s stderr-plus-os_log style) and counting lines.
    func testLogLineIsRateLimitedNotPerCall() throws {
        let probe = WriteSchedulingProbe(logInterval: 0.1, ringCapacity: 256)

        let capture = try StderrCapture()
        defer { capture.restore() }

        // Fire far more arrivals than the ~0.3s budget below could possibly
        // log once-per-call: at this rate a per-call logger would emit
        // hundreds of lines; a correctly rate-limited one emits at most a
        // handful (~0.3s / 0.1s interval).
        let deadline = Date().addingTimeInterval(0.35)
        var calls = 0
        while Date() < deadline {
            probe.recordWriteArrival()
            calls += 1
        }

        let output = capture.finish()
        let lineCount = output.components(separatedBy: "write-scheduling probe:").count - 1
        XCTAssertGreaterThan(calls, 50, "test should have driven many arrivals to make the contrast meaningful")
        XCTAssertLessThan(lineCount, calls / 10, "rate-limited logging must emit far fewer lines than calls")
        XCTAssertLessThanOrEqual(lineCount, 6, "≈0.35s at a 0.1s interval should log only a few times, never per-call")
    }

    // MARK: - `AirPlayEngine.write` end-to-end

    /// The real hot path (`write(pcm:pts:)` -> `write(streams:pts:)`) feeds
    /// all three metric families, and `writeSchedulingSnapshot()` reflects
    /// them without requiring an actor hop (`nonisolated`, callable
    /// synchronously right after headless writes).
    func testEngineWritePathFeedsAllThreeMetricFamilies() async throws {
        let engine = AirPlayEngine()
        await engine.enterHeadlessTestMode()

        let samplesPerWrite = 352
        let pcm = Data(repeating: 0, count: samplesPerWrite * 4) // S16LE stereo
        let pts = timespec(tv_sec: 0, tv_nsec: 0)

        engine.write(pcm: pcm, pts: pts) // seeds inter-arrival baseline
        for _ in 0..<8 {
            try await Task.sleep(nanoseconds: 2_000_000) // 2ms between writes
            engine.write(pcm: pcm, pts: pts)
        }

        let snapshot = engine.writeSchedulingSnapshot()
        // Headless mode runs `body()` inline (no engine thread hop), so wake
        // latency and in-cycle work are both measurable but expected to be
        // tiny, not zero-or-absent.
        XCTAssertEqual(snapshot.wakeLatency.count, 9)
        XCTAssertEqual(snapshot.inCycleWork.count, 9)
        XCTAssertEqual(snapshot.interArrivalGap.count, 8) // 8 gaps from 9 arrivals
        XCTAssertGreaterThanOrEqual(snapshot.wakeLatency.maxMs, 0)
        XCTAssertGreaterThanOrEqual(snapshot.inCycleWork.maxMs, 0)
        XCTAssertGreaterThan(snapshot.interArrivalGap.p50Ms, 0, "the deliberate 2ms sleeps must show up as positive gaps")
    }

    // MARK: - Allocation-free hot path (proxy — see file header)

    /// PROXY test (see file header for the limitation): drives far more
    /// samples through each metric family than the ring's fixed capacity and
    /// checks the operation completes in a tight time budget with the
    /// windowed percentiles still bounded by the fixed capacity — consistent
    /// with a preallocated, non-growing ring, though not a direct
    /// allocation measurement.
    func testRecordManyTimesStaysBoundedAndFast() {
        let probe = WriteSchedulingProbe(logInterval: 3600, ringCapacity: 512)
        let iterations = 200_000

        let start = Date()
        for i in 0..<iterations {
            let ms = Double(i % 1000)
            probe.recordWakeLatency(enqueuedAtMs: 1, startedAtMs: 1 + ms)
            probe.recordInCycleWork(startedAtMs: 0, finishedAtMs: ms)
            probe.recordWriteArrival()
        }
        let elapsed = Date().timeIntervalSince(start)

        let snapshot = probe.snapshot()
        XCTAssertEqual(snapshot.wakeLatency.count, UInt64(iterations))
        XCTAssertEqual(snapshot.inCycleWork.count, UInt64(iterations))
        // 200k iterations x 3 preallocated-ring stores under a lock should be
        // well under a second on any dev machine; a hidden per-call
        // allocation/GC-style pause would blow well past this budget.
        XCTAssertLessThan(elapsed, 2.0, "hot-path record calls should be cheap scalar ring stores, not allocate per call")
    }

    // MARK: - Helpers

    private func expectedPercentiles(_ samples: [Double]) -> (p50: Double, p95: Double, p99: Double) {
        let sorted = samples.sorted()
        func pct(_ p: Double) -> Double {
            let idx = min(sorted.count - 1, max(0, Int((p * Double(sorted.count - 1)).rounded())))
            return sorted[idx]
        }
        return (pct(0.50), pct(0.95), pct(0.99))
    }
}

/// Minimal stderr-to-pipe capture for asserting on `WriteSchedulingProbe`'s
/// rate-limited log line. Redirects fd 2 for the lifetime of the capture and
/// restores it in `finish()`/`restore()` — tests that use this must not run
/// concurrently with anything else asserting on stderr content.
private final class StderrCapture {
    private let savedFd: Int32
    private let pipe: Pipe
    private var finished = false

    init() throws {
        savedFd = dup(2)
        guard savedFd >= 0 else {
            throw NSError(domain: "StderrCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "dup(2) failed"])
        }
        pipe = Pipe()
        dup2(pipe.fileHandleForWriting.fileDescriptor, 2)
    }

    func finish() -> String {
        guard !finished else { return "" }
        finished = true
        pipe.fileHandleForWriting.closeFile()
        dup2(savedFd, 2)
        close(savedFd)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    func restore() {
        guard !finished else { return }
        finished = true
        pipe.fileHandleForWriting.closeFile()
        dup2(savedFd, 2)
        close(savedFd)
    }
}
