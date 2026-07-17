// Latency-budget tests (docs/latency-analysis.md): the configurable sender
// start buffer (outputs shim + EngineConfig) and the env-gated pts-freshness
// probe. Cheap, pure, no-session tests in the ShimUnitTests mold — no sockets,
// no libevent loop, no receiver.

import XCTest
import Foundation
@testable import AirPlayEngine
import CAirPlayEngine

final class StartBufferAndLatencyProbeTests: XCTestCase {

    // MARK: - outputs shim: settable start buffer

    /// The shim's start buffer is PROCESS-GLOBAL state; every test that touches
    /// it must restore the default so unrelated tests (e.g. the scaffold test's
    /// 2250 assertion) stay order-independent.
    private func withRestoredStartBuffer(_ body: () -> Void) {
        defer { outputs_set_buffer_duration_ms(UInt64(OUTPUTS_START_BUFFER_MS_DEFAULT)) }
        body()
    }

    func testStartBufferDefaultsToOwnToneParity() {
        XCTAssertEqual(outputs_buffer_duration_ms_get(), 2250)
        XCTAssertEqual(UInt64(OUTPUTS_START_BUFFER_MS_DEFAULT), outputs_buffer_duration_ms_get())
    }

    func testStartBufferSetterRoundTrips() {
        withRestoredStartBuffer {
            outputs_set_buffer_duration_ms(1000)
            XCTAssertEqual(outputs_buffer_duration_ms_get(), 1000)
            outputs_set_buffer_duration_ms(300)
            XCTAssertEqual(outputs_buffer_duration_ms_get(), 300)
        }
    }

    func testStartBufferClampsOutOfRangeValues() {
        withRestoredStartBuffer {
            // Below the floor (airplay.c rejects sessions at <= 250 ms): clamped
            // up to a playable value, never passed through.
            outputs_set_buffer_duration_ms(0)
            XCTAssertEqual(outputs_buffer_duration_ms_get(), UInt64(OUTPUTS_START_BUFFER_MS_MIN))
            outputs_set_buffer_duration_ms(250)
            XCTAssertEqual(outputs_buffer_duration_ms_get(), UInt64(OUTPUTS_START_BUFFER_MS_MIN))
            // Above the ceiling: clamped down.
            outputs_set_buffer_duration_ms(60_000)
            XCTAssertEqual(outputs_buffer_duration_ms_get(), UInt64(OUTPUTS_START_BUFFER_MS_MAX))
        }
    }

    func testEngineConfigDefaultMatchesOwnTone() {
        XCTAssertEqual(EngineConfig().startBufferMs, 2250)
    }

    /// `setStartBufferMs` reaches the C shim (headless mode applies inline, no
    /// engine thread) — the primitive `NativeBackend.applyStartBuffer` builds on.
    func testSetStartBufferMsReachesShim() async {
        await withRestoredStartBufferAsync {
            let engine = AirPlayEngine(config: EngineConfig(startBufferMs: 1000))
            await engine.enterHeadlessTestMode()
            await engine.setStartBufferMs(1500)
            XCTAssertEqual(outputs_buffer_duration_ms_get(), 1500)
        }
    }

    private func withRestoredStartBufferAsync(_ body: () async -> Void) async {
        defer { outputs_set_buffer_duration_ms(UInt64(OUTPUTS_START_BUFFER_MS_DEFAULT)) }
        await body()
    }

    // MARK: - WriteLatencyProbe (pts→now age)

    func testDisabledProbeRecordsNothing() {
        let probe = WriteLatencyProbe(startBufferMs: 2250, enabled: false)
        var now = timespec()
        clock_gettime(CLOCK_MONOTONIC, &now)
        probe.record(pts: now)

        let snapshot = probe.snapshot()
        XCTAssertFalse(snapshot.isEnabled)
        XCTAssertEqual(snapshot.writeCount, 0)
        XCTAssertEqual(snapshot.averagePtsAgeMs, 0)
    }

    func testEnabledProbeMeasuresPtsAge() {
        let probe = WriteLatencyProbe(startBufferMs: 2250, enabled: true, logInterval: 3600)

        // A pts stamped 50 ms in the past on the pts's own clock domain.
        var now = timespec()
        clock_gettime(CLOCK_MONOTONIC, &now)
        var nanos = Int64(now.tv_sec) * 1_000_000_000 + Int64(now.tv_nsec) - 50_000_000
        if nanos < 0 { nanos = 0 }
        let pts = timespec(tv_sec: Int(nanos / 1_000_000_000), tv_nsec: Int(nanos % 1_000_000_000))
        probe.record(pts: pts)

        let snapshot = probe.snapshot()
        XCTAssertTrue(snapshot.isEnabled)
        XCTAssertEqual(snapshot.writeCount, 1)
        // ≥ the stamped 50 ms; the upper bound is generous (scheduling noise on
        // a loaded CI box) but still catches unit errors (5 s, 50 s, …).
        XCTAssertGreaterThanOrEqual(snapshot.averagePtsAgeMs, 49.0)
        XCTAssertLessThan(snapshot.averagePtsAgeMs, 1000.0)
        XCTAssertEqual(snapshot.minPtsAgeMs, snapshot.maxPtsAgeMs)
    }

    func testProbeAccumulatesMinMax() {
        let probe = WriteLatencyProbe(startBufferMs: 1000, enabled: true, logInterval: 3600)
        var now = timespec()
        clock_gettime(CLOCK_MONOTONIC, &now)
        let base = Int64(now.tv_sec) * 1_000_000_000 + Int64(now.tv_nsec)

        for ageMs in [10, 20, 90] {
            let nanos = base - Int64(ageMs) * 1_000_000
            let pts = timespec(tv_sec: Int(nanos / 1_000_000_000), tv_nsec: Int(nanos % 1_000_000_000))
            probe.record(pts: pts)
        }

        let snapshot = probe.snapshot()
        XCTAssertEqual(snapshot.writeCount, 3)
        XCTAssertGreaterThanOrEqual(snapshot.maxPtsAgeMs, 89.0)
        XCTAssertLessThan(snapshot.minPtsAgeMs, snapshot.maxPtsAgeMs)
    }
}
