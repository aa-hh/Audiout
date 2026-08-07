// T7 (docs/plans/PLAN-AUDIO-THREAD-SCHEDULING.md §E), engine-side half: the
// join/leave lifecycle ON THE ENGINE THREAD — the thread that actually runs the
// encode/encrypt/send work, and therefore the only thread allowed to perform
// either call (`os_workgroup_join`/`leave` act on the CALLING thread).
//
// The coordinator-side half (which lifecycle edges call join/leave, in what
// order) lives in AudiouterCoreTests/WorkgroupLifecycleTests.swift.
//
// CANNOT BE TESTED HERE, on purpose:
//   * that joining a workgroup changes scheduling. It is a kernel hint with no
//     hermetic observable.
//   * a SUCCESSFUL join. That needs a live Core Audio device publishing
//     `kAudioDevicePropertyIOThreadOSWorkgroup`, i.e. real hardware — and per
//     plan risk #6, whether a TAP-BEARING aggregate publishes one at all is
//     still unproven (only a synthetic aggregate was ever measured). Asserting
//     a successful join here would be asserting something we do not know.
// What IS testable, and is what this file covers: the failure/skip contracts,
// the "no engine thread" contract, and that the thread can be started, driven
// through membership churn, and stopped without tripping the shim's abort paths
// or wedging its exit.

import Foundation
import Testing
@testable import AirPlayEngine

@Suite struct WorkgroupLifecycleTests {

    /// Thread-safe latch used to fence on "this closure ran on the engine
    /// thread."
    private final class Fence: @unchecked Sendable {
        private let lock = NSLock()
        private var _fired = false
        func fire() { lock.withLock { _fired = true } }
        var fired: Bool { lock.withLock { _fired } }
    }

    /// Polls `fence.fired` for up to `timeout`.
    private func awaitFence(_ fence: Fence, timeout: Duration = .seconds(5)) async throws {
        var remainingMs = Int(timeout.components.seconds * 1000)
        while !fence.fired && remainingMs > 0 {
            try await Task.sleep(for: .milliseconds(10))
            remainingMs -= 10
        }
        #expect(fence.fired, "timed out waiting for the engine thread to run the fence closure")
    }

    /// A device id that cannot possibly publish a workgroup: `kAudioObjectUnknown`.
    /// `engine_workgroup_join` maps "no such property" to EINVAL, which is exactly
    /// the cancelled/torn-down race the coordinator can hit when a device-change
    /// notification fires against a tap that is already mid-teardown.
    private let noSuchDevice: UInt32 = 0

    @Test func updateWorkgroupIsNotSchedulableBeforeStart() {
        // No base yet => nothing to schedule onto, and no membership to worry
        // about. The caller must be able to tell, hence the Bool.
        let thread = EngineThread(name: "com.airplayengine.engine.wg-prestart")
        #expect(!thread.updateWorkgroup(deviceID: 42))
        #expect(!thread.updateWorkgroup(deviceID: nil))
    }

    @Test func joinAgainstACancelledDeviceIsSkippedNotFatal() async throws {
        let thread = EngineThread(name: "com.airplayengine.engine.wg-einval")
        let started = thread.start()
        defer { thread.stop() }
        // See EngineThreadQoSTests for why this is a hard requirement rather
        // than a skip under swift-testing (traits can't gate on a runtime-only
        // condition discovered mid-body).
        try #require(started, "engine thread failed to start (libevent base unavailable)")

        #expect(
            thread.updateWorkgroup(deviceID: noSuchDevice),
            "the update is schedulable; whether the join succeeds is Core Audio's answer")

        // The join runs on the engine thread. Fence behind a later enqueue: the
        // engine thread is FIFO, so once this closure runs the join has already
        // been attempted — and the process is still alive, which is the assertion
        // (EINVAL must be logged and skipped, never crash and never retry-loop).
        let fence = Fence()
        _ = thread.enqueue({ fence.fire() }, tracked: false)
        try await awaitFence(fence)
    }

    @Test func repeatedUpdatesAndLeavesAreSafeAndOrdered() async throws {
        let thread = EngineThread(name: "com.airplayengine.engine.wg-churn")
        let started = thread.start()
        defer { thread.stop() }
        try #require(started, "engine thread failed to start (libevent base unavailable)")

        // Membership churn of the shape a rebuild storm produces. Each update is
        // internally leave-then-join, and successive updates are FIFO-ordered on
        // the engine thread — so a redundant leave (nothing joined) must be a
        // no-op rather than a double-leave, which the shim documents as a process
        // abort.
        for id in [noSuchDevice, 1, noSuchDevice, 2] {
            #expect(thread.updateWorkgroup(deviceID: id))
        }
        #expect(thread.updateWorkgroup(deviceID: nil))
        #expect(thread.updateWorkgroup(deviceID: nil), "leave is idempotent")

        let fence = Fence()
        _ = thread.enqueue({ fence.fire() }, tracked: false)
        try await awaitFence(fence)
    }

    @Test func threadStopsCleanlyAfterAJoinAttempt() async throws {
        // Edge 2: `threadMain` must unwind any membership before returning. A
        // thread that exits while joined is UNDEFINED BEHAVIOR, so the observable
        // proxy is that stop() completes promptly and cleanly after the thread has
        // been driven through the join path.
        let thread = EngineThread(name: "com.airplayengine.engine.wg-exit")
        let started = thread.start()
        try #require(started, "engine thread failed to start (libevent base unavailable)")

        #expect(thread.updateWorkgroup(deviceID: noSuchDevice))
        let fence = Fence()
        _ = thread.enqueue({ fence.fire() }, tracked: false)
        try await awaitFence(fence)

        let before = Date()
        thread.stop()
        // `EngineThread.stopJoinDeadline` is 3s; anything under it means the clean
        // exit path ran (and with it `threadMain`'s leave), not the leak path.
        #expect(
            Date().timeIntervalSince(before) < 3.0,
            "the thread unwound within the stop deadline — it did not wedge on the way out")
        thread.stop() // idempotent
    }

    @Test func engineWithNoThreadReportsWorkgroupCallsAsUnscheduled() async {
        // The public cross-package surface AudiouterCore drives. A never-started
        // engine has no thread to marshal onto; the coordinator treats that as
        // "nothing to manage" rather than an error.
        let engine = AirPlayEngine(config: EngineConfig())
        #expect(!engine.joinIOWorkgroup(deviceID: 1))
        #expect(!engine.leaveIOWorkgroup())
    }
}
