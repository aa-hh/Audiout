import Foundation
import Testing
@testable import AirPlayEngine

@Suite struct EngineThreadTests {

    /// Lock-guarded Bool handed from a background queue back to the test thread.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = false
        var value: Bool {
            get { lock.withLock { _value } }
            set { lock.withLock { _value = newValue } }
        }
    }

    // Defect: `enqueue` on the write path reads a live `base`, is preempted,
    // `stop()` lets the engine thread `event_base_free` it, then
    // `event_base_once` runs on freed memory. `beforeScheduleForTesting` parks
    // the enqueue exactly at that preemption point.
    @Test func stopWaitsForAnInFlightEnqueueBeforeFreeingTheBase() throws {
        let t = EngineThread(name: "com.airplayengine.engine.base-lock-test")
        try #require(t.start())

        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        t.beforeScheduleForTesting = { entered.signal(); release.wait() }

        let enqueueResult = Flag()
        let enqueueDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            enqueueResult.value = t.enqueue({}, tracked: false)
            enqueueDone.signal()
        }
        entered.wait()

        let stopReturned = Flag()
        let stopDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            t.stop()
            stopReturned.value = true
            stopDone.signal()
        }

        Thread.sleep(forTimeInterval: 0.3)
        #expect(!stopReturned.value, "stop() freed the base underneath an enqueue that had already passed its base check")

        release.signal()
        #expect(stopDone.wait(timeout: .now() + 5) == .success, "stop() did not return within 5s")
        #expect(stopReturned.value)
        #expect(enqueueDone.wait(timeout: .now() + 5) == .success, "enqueue did not return within 5s")
        #expect(enqueueResult.value == true)
    }
}
