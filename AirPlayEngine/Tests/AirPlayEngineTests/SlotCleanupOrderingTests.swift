// A9-F4 regression: a TIMED-OUT op's C-slot cleanup must never clobber the NEXT
// op that reuses the same callback slot on the same device.
//
// SCOPE: BUILD + HEADLESS ONLY (no engine thread, no libevent, no real device).
// These tests drive the wrapper's timeout path through the REAL C dispatcher
// (shims/outputs.c) via the headless test seam, exactly like AirPlayEngineAPITests.
//
// WHAT THIS PROVES (and what it can't). The A9-F4 ordering guarantee rests on
// three composed facts documented at `AirPlayEngine.scheduleSlotCleanup`:
//   (1) per-id op serialization (B5.1) — the next same-id op can't arm until the
//       timed-out startOp returns and releases the op gate;
//   (2) the timeout enqueues the slot cleanup STRICTLY BEFORE it resumes the
//       awaiting continuation (so cleanup is ordered before the next op's arm);
//   (3) the engine-thread work queue is FIFO (libevent's order-preserving
//       `event_base_once(tv=NULL)`).
// Facts (1) and (2) are the load-bearing invariants — they hold identically in
// production and headless. In HEADLESS mode `scheduleSlotCleanup` runs the
// cleanup INLINE before the resume (headlessFlag == true), so these tests can
// assert the observable contract deterministically: by the time a timed-out
// addOutput's throw is observed, the leaked slot is ALREADY cleared, and a next
// op reusing that slot resolves normally instead of being clobbered/hung. Fact
// (3)'s libevent FIFO ordering has no engine thread in headless mode and is
// covered by reasoning + libevent's source guarantee, not by these tests.
//
// REGRESSION VALUE: if someone reorders `scheduleSlotCleanup` to run AFTER the
// continuation resumes, or drops the per-id serialization (B5.1), the second op
// below would arm slot 0, then the late cleanup would memset slot 0 out from
// under it — the delivered completion would find no armed callback and the op
// would hang to its own timeout. testReusedSlotAfterTimeoutIsNotClobbered turns
// that into a hard failure.

import XCTest
@testable import AirPlayEngine
import CAirPlayEngine

final class SlotCleanupOrderingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        outputs_dispatcher_reset()
        drainRegistry()
    }

    override func tearDown() {
        outputs_dispatcher_reset()
        drainRegistry()
        super.tearDown()
    }

    // MARK: helpers (local copies of the AirPlayEngineAPITests seams)

    @discardableResult
    private func makeRegistryDevice(id: UInt64, state: output_device_state = OUTPUT_STATE_STOPPED) -> UInt64 {
        let dev = UnsafeMutablePointer<output_device>.allocate(capacity: 1)
        dev.initialize(to: output_device())
        dev.pointee.id = id
        let canonical = outputs_device_add(dev, false)!
        canonical.pointee.advertised = 1 // survive the deferred drain
        canonical.pointee.state = state
        return id
    }

    private func drainRegistry() {
        while let head = outputs_list() { outputs_device_remove(head) }
    }

    /// Fire a synthetic backend completion for `id` on slot `cbIdSlot` through the
    /// REAL dispatcher (what the RTSP state machine does at device_start's end).
    private func fireCompletion(id: UInt64, cbIdSlot: Int32, state: output_device_state) {
        outputs_cb(cbIdSlot, id, state)
        outputs_cb_deferred_run()
    }

    /// Fire slot 0's completion once its REGISTRY waiter is armed (not merely once
    /// the C callback slot is filled — the wrapper arms the C slot before the
    /// registry waiter, and a completion into that window would be dropped).
    private func fireSlot0WhenArmed(
        id: UInt64,
        state: output_device_state,
        engine: AirPlayEngine
    ) async throws {
        for _ in 0..<500 {
            if await engine.hasArmedWaiterForTest(callbackId: 0) {
                fireCompletion(id: id, cbIdSlot: 0, state: state)
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000) // 1ms
        }
        XCTFail("waiter was never armed for device \(String(format: "0x%llX", id))")
    }

    /// Whether the C callback register has ANY armed slot for this device.
    private func deviceHasArmedSlot(_ id: UInt64) -> Bool {
        guard let device = outputs_device_get(id) else { return false }
        return outputs_callback_get(device) != nil
    }

    // MARK: - A timed-out op frees its C slot BEFORE startOp returns.
    //
    // Proves facts (1)+(2): in headless mode the slot cleanup runs inline inside
    // `onTimeout` BEFORE the continuation is resumed, so by the time the awaiting
    // `addOutput` observes the `.opTimedOut` throw the leaked slot is already
    // cleared — the cleanup is strictly ordered before startOp returns (and thus
    // before its `defer releaseOp`, and thus before any next op can arm).
    func testTimedOutOpCleansItsSlotBeforeReturning() async throws {
        let id = OutputID(rawValue: 0xA9F4_0001)
        makeRegistryDevice(id: id.rawValue)

        let engine = AirPlayEngine()
        // N=1 arms a real waiter; short injected timeout; never deliver -> only the
        // timeout can resolve it.
        await engine.enterHeadlessTestMode(issue: { _, _ in 1 }, opTimeout: 0.2)
        await engine.registerKnownOutputForTest(id)

        do {
            try await engine.addOutput(id)
            XCTFail("a stalled op must throw opTimedOut")
        } catch AirPlayEngineError.opTimedOut {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }

        // The load-bearing assertion: the timed-out op's slot is ALREADY cleared
        // the instant its throw is observed. If cleanup were deferred past the
        // resume, this slot would still be armed here.
        XCTAssertFalse(deviceHasArmedSlot(id.rawValue),
                       "timed-out op must free its callback slot before startOp returns")

        await engine.stop()
    }

    // MARK: - The NEXT op reusing the timed-out op's slot is NOT clobbered.
    //
    // A on `id` times out (cleanup clears slot 0). B on the SAME `id` then reuses
    // slot 0, its completion is delivered, and it resolves STREAMING. A late/mis-
    // ordered cleanup would have wiped B's freshly-armed slot 0, so its delivered
    // completion would find no waiter and B would hang to its own timeout instead.
    func testReusedSlotAfterTimeoutIsNotClobbered() async throws {
        let id = OutputID(rawValue: 0xA9F4_0002)
        makeRegistryDevice(id: id.rawValue)

        let engine = AirPlayEngine()
        await engine.enterHeadlessTestMode(issue: { _, _ in 1 }, opTimeout: 0.25)
        await engine.registerKnownOutputForTest(id)

        // Op A: never delivered -> times out. Its cleanup clears slot 0.
        do {
            try await engine.addOutput(id)
            XCTFail("op A must time out")
        } catch AirPlayEngineError.opTimedOut {
            // expected
        }
        XCTAssertFalse(deviceHasArmedSlot(id.rawValue),
                       "op A's slot must be cleared before op B arms")

        // Op B: same id, reuses slot 0, delivered promptly -> must succeed.
        async let opB: Void = engine.addOutput(id)
        try await fireSlot0WhenArmed(id: id.rawValue, state: OUTPUT_STATE_STREAMING, engine: engine)
        do {
            try await opB
        } catch {
            XCTFail("op B reusing the timed-out slot must resolve, not fail/hang: \(error)")
        }

        let state = await engine.stateOf(id)
        XCTAssertEqual(state, .streaming,
                       "op B on the reused slot must complete normally (not clobbered by A's cleanup)")

        await engine.stop()
    }
}
