// E1 (Phase 3 stability) — ownership-seam hardening across EngineThread /
// AirPlayEngine / CompletionRegistry / the C callback registry.
//
// Covers four interlocking defects (see dev/notes/stability-audit-2026-07-18.md):
//   B4 — EngineThread.enqueue silently dropped work + run() never resumed →
//        caller froze forever. Now enqueue returns Bool and run() fails fast.
//   B5 — completion-slot reuse: a leaked/timed-out slot exhausts the registry and
//        can resolve the wrong op. Now per-id op serialization + slot cleanup on
//        timeout + arm() refuses a duplicate waiter.
//   C2 — engine survives stop→start: a fresh EngineThread per start + a registry
//        clear so a new run doesn't inherit stale devices / leaked slots.
//   C3 — EngineThread.stop() deadlines its join instead of spinning forever.
//
// SCOPE: BUILD + HEADLESS ONLY, like the rest of this suite — no sockets, no PTP.
// The EngineThread cases drive a REAL libevent base + OS thread (that is not a
// network operation), but never call airplay_init. Wedged-thread and real
// rapid stop→start-vs-hardware behaviour is a separate GATED live test.

import XCTest
@testable import AirPlayEngine
import CAirPlayEngine

final class E1StabilityTests: XCTestCase {

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

    private func drainRegistry() {
        while let head = outputs_list() { outputs_device_remove(head) }
    }

    @discardableResult
    private func makeRegistryDevice(id: UInt64, state: output_device_state = OUTPUT_STATE_STOPPED) -> UInt64 {
        let dev = UnsafeMutablePointer<output_device>.allocate(capacity: 1)
        dev.initialize(to: output_device())
        dev.pointee.id = id
        let canonical = outputs_device_add(dev, false)!
        canonical.pointee.advertised = 1
        canonical.pointee.state = state
        return id
    }

    private let noopCb: output_status_cb = { _, _ in }

    // MARK: - C2 / B4: a fresh EngineThread starts, runs work, stops — repeatedly.

    func testEngineThreadStartStopStartCycle() async throws {
        // A single OS Thread cannot be restarted; C2's fix is to construct a
        // fresh EngineThread each cycle. Prove two full cycles work and that
        // enqueued work actually runs on each.
        for cycle in 0..<3 {
            let t = EngineThread()
            XCTAssertTrue(t.start(), "cycle \(cycle): fresh engine thread must start")
            XCTAssertNotNil(t.base, "cycle \(cycle): base must exist after start")

            let ran = try await t.run { 40 + 2 }
            XCTAssertEqual(ran, 42, "cycle \(cycle): run() must marshal and return")

            t.stop()
        }
    }

    // MARK: - B4: run()/enqueue fail fast (no hang) when the base is gone.

    func testEnqueueReturnsFalseBeforeStart() {
        let t = EngineThread()
        // Never started: base is nil, so enqueue cannot schedule and MUST say so
        // (the old code silently returned, stranding the caller).
        var ran = false
        XCTAssertFalse(t.enqueue { ran = true }, "enqueue must report failure with no base")
        XCTAssertFalse(ran, "the closure must not have run")
    }

    func testRunThrowsAfterStopInsteadOfHanging() async {
        let t = EngineThread()
        XCTAssertTrue(t.start())
        t.stop()
        // The base is freed; run() must throw promptly rather than await a
        // continuation that can never resume (the B4 freeze). The XCTest timeout
        // is the backstop that this doesn't hang.
        do {
            _ = try await t.run { 1 }
            XCTFail("run() after stop must throw, not hang")
        } catch {
            XCTAssertEqual(error as? AirPlayEngineError, .engineNotRunning)
        }
    }

    // MARK: - B5.3: CompletionRegistry.arm refuses to overwrite an existing waiter.

    func testArmRefusesDuplicateWaiter() {
        let reg = CompletionRegistry()
        var firstDelivered: OutputState?
        var secondDelivered: OutputState?

        // timeout: 0 disables the timer (deliver/cancel path only).
        let first = reg.arm(callbackId: 7, timeout: 0, onCancel: {}, onTimeout: {}) {
            firstDelivered = $0
        }
        XCTAssertTrue(first, "first arm must succeed")
        XCTAssertTrue(reg.hasWaiter(callbackId: 7))

        let second = reg.arm(callbackId: 7, timeout: 0, onCancel: {}, onTimeout: {}) {
            secondDelivered = $0
        }
        XCTAssertFalse(second, "arm must REFUSE a second waiter for the same id")
        XCTAssertTrue(reg.hasWaiter(callbackId: 7), "the original waiter must remain armed")

        // The original waiter must still be the one that resolves — the refused
        // second one never gets wired in.
        reg.deliverForTest(callbackId: 7, state: OUTPUT_STATE_STREAMING)
        XCTAssertEqual(firstDelivered, .streaming, "the original waiter delivers")
        XCTAssertNil(secondDelivered, "the refused waiter never delivers")
    }

    // MARK: - B5.2 (shim): outputs_callback_clear frees exactly one leaked slot.

    func testCallbackClearFreesOneSlotForReuse() {
        let a = makeRegistryDevice(id: 0xA)
        let b = makeRegistryDevice(id: 0xB)
        let devA = outputs_device_get(a)!
        let devB = outputs_device_get(b)!

        let idA = outputs_callback_add(devA, noopCb)
        let idB = outputs_callback_add(devB, noopCb)
        XCTAssertGreaterThanOrEqual(idA, 0)
        XCTAssertGreaterThanOrEqual(idB, 0)
        XCTAssertNotEqual(idA, idB)

        // Simulate a timed-out op: its slot stays armed (get() is non-nil) — this
        // is the leak that eventually exhausts the register. Clear it explicitly.
        XCTAssertNotNil(outputs_callback_get(devA))
        outputs_callback_clear(idA)
        XCTAssertNil(outputs_callback_get(devA), "cleared slot must be free")
        XCTAssertNotNil(outputs_callback_get(devB), "the OTHER slot must be untouched")

        // A fresh add can reuse the freed slot.
        let c = makeRegistryDevice(id: 0xC)
        let devC = outputs_device_get(c)!
        let idC = outputs_callback_add(devC, noopCb)
        XCTAssertEqual(idC, idA, "the freed slot is the lowest free index — reused")
    }

    // MARK: - C2 (shim): outputs_registry_clear empties the registry + slots.

    func testRegistryClearEmptiesDevicesAndSlots() {
        let a = makeRegistryDevice(id: 0x11)
        let devA = outputs_device_get(a)!
        _ = outputs_callback_add(devA, noopCb)
        makeRegistryDevice(id: 0x22)

        XCTAssertNotNil(outputs_list(), "registry has devices before clear")

        outputs_registry_clear()

        XCTAssertNil(outputs_list(), "registry must be empty after clear")
        XCTAssertNil(outputs_device_get(0x11))
        XCTAssertNil(outputs_device_get(0x22))
        // Slots reset: a fresh add after a clear starts at slot 0.
        let n = makeRegistryDevice(id: 0x33)
        let devN = outputs_device_get(n)!
        XCTAssertEqual(outputs_callback_add(devN, noopCb), 0, "callback register reset by clear")
    }

    // MARK: - B5.2 (end-to-end): a timed-out op clears its slot so the next op
    // on that device can re-arm instead of colliding / being rejected.

    func testTimedOutOpClearsSlotSoNextOpReArms() async throws {
        let id = OutputID(rawValue: 0xD1)
        makeRegistryDevice(id: id.rawValue)

        let engine = AirPlayEngine()
        // Issue promises N=1 but we NEVER fire a completion → the op times out.
        // Short timeout so the test is fast.
        await engine.enterHeadlessTestMode(issue: { _, _ in 1 }, opTimeout: 0.05)
        await engine.registerKnownOutputForTest(id)

        do {
            try await engine.addOutput(id)
            XCTFail("op with no completion must time out")
        } catch {
            XCTAssertEqual(error as? AirPlayEngineError, .opTimedOut)
        }

        // The timed-out slot must have been cleared (B5.2). A SECOND op on the
        // same device must therefore arm a fresh waiter (slot 0 again) and, when
        // completed, succeed — proving no leaked slot and no arm-refusal collision.
        async let op: Void = engine.addOutput(id)
        try await fireWhenArmed(id: id.rawValue, engine: engine)
        try await op

        let state = await engine.stateOf(id)
        XCTAssertEqual(state, .connected)
    }

    // MARK: - B5.1: two overlapping ops on ONE id serialize (no clobbered waiter).

    func testOverlappingOpsOnSameIdSerialize() async throws {
        let id = OutputID(rawValue: 0xD2)
        makeRegistryDevice(id: id.rawValue)

        let engine = AirPlayEngine()
        await engine.enterHeadlessTestMode(issue: { _, _ in 1 })
        await engine.registerKnownOutputForTest(id)

        // Fire two setVolume ops concurrently. Without per-id serialization the
        // second arm would clobber the first's waiter (permanent hang + false
        // timeout). With it, both resolve. Each op arms slot 0 in turn; the
        // firer waits for a waiter then fires, so it services whichever op holds
        // the gate at that moment; do it twice.
        async let op1: Void = engine.setVolume(id, 0.3)
        async let op2: Void = engine.setVolume(id, 0.7)
        // Two completions, one per serialized op.
        try await fireWhenArmed(id: id.rawValue, engine: engine, state: OUTPUT_STATE_STREAMING)
        try await fireWhenArmed(id: id.rawValue, engine: engine, state: OUTPUT_STATE_STREAMING)
        // Neither call hangs (the XCTest timeout is the backstop).
        try await op1
        try await op2
    }

    // MARK: helpers

    /// Fire one synthetic completion once the registry waiter for slot 0 is armed.
    private func fireWhenArmed(
        id: UInt64,
        engine: AirPlayEngine,
        state: output_device_state = OUTPUT_STATE_CONNECTED
    ) async throws {
        for _ in 0..<400 {
            if await engine.hasArmedWaiterForTest(callbackId: 0) {
                outputs_cb(0, id, state)
                outputs_cb_deferred_run()
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("waiter was never armed for device \(String(format: "0x%llX", id))")
    }
}
