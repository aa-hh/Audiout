// T4 (docs/plans/PLAN-AUDIO-THREAD-SCHEDULING.md §E, hypothesis H1): proves
// EngineThread's underlying OS thread is scheduled at .userInteractive QoS,
// set in `init` before `start()` so it applies to the thread's initial
// scheduling. No experiment/kill-switch here — this is unconditional (Q2).

import Foundation
import Testing
@testable import AirPlayEngine

@Suite struct EngineThreadQoSTests {

    /// Thread-safe box for the QoS observed on the engine thread's enqueued
    /// closure, read back from the awaiting test thread.
    private final class QoSBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: qos_class_t = QOS_CLASS_UNSPECIFIED
        var value: qos_class_t {
            get { lock.withLock { _value } }
            set { lock.withLock { _value = newValue } }
        }
    }

    @Test func engineThreadRunsAtUserInteractiveQoS() async throws {
        let engine = EngineThread(name: "com.airplayengine.engine.qos-test")
        let started = engine.start()
        defer { engine.stop() }
        // `EngineThread.start()` failing means the libevent base could not be
        // created in this environment. E1StabilityTests (same class, already
        // converted) treats that as a hard requirement rather than an
        // environment-dependent skip — matching that precedent here, since
        // swift-testing traits can only gate at discovery time and this
        // condition is only known after actually starting the thread.
        try #require(started, "engine thread failed to start (libevent base unavailable)")

        let box = QoSBox()
        _ = engine.enqueue({
            box.value = qos_class_self()
        }, tracked: false)

        var deadline = 500   // 500 x 10ms = 5s
        while box.value == QOS_CLASS_UNSPECIFIED && deadline > 0 {
            try await Task.sleep(for: .milliseconds(10))
            deadline -= 1
        }

        #expect(
            box.value == QOS_CLASS_USER_INTERACTIVE,
            "engine thread must run at .userInteractive QoS (H1 mitigation, T4)")
    }
}
