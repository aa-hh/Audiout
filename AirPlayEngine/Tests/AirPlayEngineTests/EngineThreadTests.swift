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
    @Test func stopWaitsForAnInFlightEnqueueBeforeFreeingTheBase() async throws {
        let t = EngineThread(name: "com.airplayengine.engine.base-lock-test")
        try #require(t.start())

        let entered = Flag()
        let release = DispatchSemaphore(value: 0)
        t.beforeScheduleForTesting = { entered.value = true; release.wait() }

        let enqueueResult = Flag()
        let enqueueReturned = Flag()
        DispatchQueue.global().async {
            enqueueResult.value = t.enqueue({}, tracked: false)
            enqueueReturned.value = true
        }
        await SuiteWait.until("the enqueue is parked between its base check and the schedule") {
            entered.value
        }

        let stopBlocked = Flag()
        t.stopFoundBaseLockHeldForTesting = { stopBlocked.value = true }
        let stopReturned = Flag()
        DispatchQueue.global().async {
            t.stop()
            stopReturned.value = true
        }
        // The hook fires only when stop() finds the base lock still held by the
        // parked enqueue. An enqueue that let go of the lock after its base check
        // would let stop() take it at once and free the base.
        await SuiteWait.until("stop() finds the base lock held by the parked enqueue") {
            stopBlocked.value
        }
        #expect(!stopReturned.value, "stop() freed the base underneath an enqueue that had already passed its base check")

        release.signal()
        await SuiteWait.until("stop() returns once the enqueue lets go") { stopReturned.value }
        await SuiteWait.until("the enqueue returns") { enqueueReturned.value }
        #expect(enqueueResult.value == true)
    }
}
