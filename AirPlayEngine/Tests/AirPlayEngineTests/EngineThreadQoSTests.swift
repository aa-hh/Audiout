// T4 (docs/plans/PLAN-AUDIO-THREAD-SCHEDULING.md §E, hypothesis H1): proves
// EngineThread's underlying OS thread is scheduled at .userInteractive QoS,
// set in `init` before `start()` so it applies to the thread's initial
// scheduling. No experiment/kill-switch here — this is unconditional (Q2).

import XCTest
@testable import AirPlayEngine

final class EngineThreadQoSTests: XCTestCase {
    func testEngineThreadRunsAtUserInteractiveQoS() throws {
        let engine = EngineThread(name: "com.airplayengine.engine.qos-test")
        let started = engine.start()
        defer { engine.stop() }
        try XCTSkipUnless(started, "engine thread failed to start (libevent base unavailable)")

        let expectation = expectation(description: "observed QoS on engine thread")
        var observedQoS: qos_class_t = QOS_CLASS_UNSPECIFIED

        _ = engine.enqueue({
            observedQoS = qos_class_self()
            expectation.fulfill()
        }, tracked: false)

        wait(for: [expectation], timeout: 5.0)
        XCTAssertEqual(
            observedQoS, QOS_CLASS_USER_INTERACTIVE,
            "engine thread must run at .userInteractive QoS (H1 mitigation, T4)")
    }
}
