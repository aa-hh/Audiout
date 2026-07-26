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

import Foundation
import Testing
@testable import AirPlayEngine
import CAirPlayEngine

// `shims/outputs.c`'s device/callback registry is process-global C state, so this
// suite nests into the package's one `.serialized` parent (see
// SerializedEngineStateSuite.swift). Do NOT repeat `.serialized` here.
extension SerializedEngineState {

    // A `final class`, not a `struct`: the per-test teardown below frees the heap
    // devices this suite registers, and `deinit` is illegal on a struct.
    @Suite final class E1StabilityTests {

        init() {
            outputs_dispatcher_reset()
            drainRegistry()
        }

        deinit {
            outputs_dispatcher_reset()
            drainRegistry()
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

        @Test func engineThreadStartStopStartCycle() async throws {
            // A single OS Thread cannot be restarted; C2's fix is to construct a
            // fresh EngineThread each cycle. Prove two full cycles work and that
            // enqueued work actually runs on each.
            for cycle in 0..<3 {
                let t = EngineThread()
                #expect(t.start(), "cycle \(cycle): fresh engine thread must start")
                #expect(t.base != nil, "cycle \(cycle): base must exist after start")

                let ran = try await t.run { 40 + 2 }
                #expect(ran == 42, "cycle \(cycle): run() must marshal and return")

                t.stop()
            }
        }

        // MARK: - B4: run()/enqueue fail fast (no hang) when the base is gone.

        @Test func enqueueReturnsFalseBeforeStart() {
            let t = EngineThread()
            // Never started: base is nil, so enqueue cannot schedule and MUST say so
            // (the old code silently returned, stranding the caller).
            var ran = false
            let scheduled = t.enqueue { ran = true }
            #expect(!scheduled, "enqueue must report failure with no base")
            #expect(!ran, "the closure must not have run")
        }

        @Test func runThrowsAfterStopInsteadOfHanging() async {
            let t = EngineThread()
            #expect(t.start())
            t.stop()
            // The base is freed; run() must throw promptly rather than await a
            // continuation that can never resume (the B4 freeze). The test-runner
            // timeout is the backstop that this doesn't hang.
            do {
                _ = try await t.run { 1 }
                Issue.record("run() after stop must throw, not hang")
            } catch {
                #expect(error as? AirPlayEngineError == .engineNotRunning)
            }
        }

        // MARK: - B5.3: CompletionRegistry.arm refuses to overwrite an existing waiter.

        @Test func armRefusesDuplicateWaiter() {
            let reg = CompletionRegistry()
            var firstDelivered: OutputState?
            var secondDelivered: OutputState?

            // timeout: 0 disables the timer (deliver/cancel path only).
            let first = reg.arm(callbackId: 7, timeout: 0, onCancel: {}, onTimeout: {}) {
                firstDelivered = $0
            }
            #expect(first, "first arm must succeed")
            #expect(reg.hasWaiter(callbackId: 7))

            let second = reg.arm(callbackId: 7, timeout: 0, onCancel: {}, onTimeout: {}) {
                secondDelivered = $0
            }
            #expect(!second, "arm must REFUSE a second waiter for the same id")
            #expect(reg.hasWaiter(callbackId: 7), "the original waiter must remain armed")

            // The original waiter must still be the one that resolves — the refused
            // second one never gets wired in.
            reg.deliverForTest(callbackId: 7, state: OUTPUT_STATE_STREAMING)
            #expect(firstDelivered == .streaming, "the original waiter delivers")
            #expect(secondDelivered == nil, "the refused waiter never delivers")
        }

        // MARK: - B5.2 (shim): outputs_callback_clear frees exactly one leaked slot.

        @Test func callbackClearFreesOneSlotForReuse() {
            let a = makeRegistryDevice(id: 0xA)
            let b = makeRegistryDevice(id: 0xB)
            let devA = outputs_device_get(a)!
            let devB = outputs_device_get(b)!

            let idA = outputs_callback_add(devA, noopCb)
            let idB = outputs_callback_add(devB, noopCb)
            #expect(idA >= 0)
            #expect(idB >= 0)
            #expect(idA != idB)

            // Simulate a timed-out op: its slot stays armed (get() is non-nil) — this
            // is the leak that eventually exhausts the register. Clear it explicitly.
            #expect(outputs_callback_get(devA) != nil)
            outputs_callback_clear(idA)
            #expect(outputs_callback_get(devA) == nil, "cleared slot must be free")
            #expect(outputs_callback_get(devB) != nil, "the OTHER slot must be untouched")

            // A fresh add can reuse the freed slot.
            let c = makeRegistryDevice(id: 0xC)
            let devC = outputs_device_get(c)!
            let idC = outputs_callback_add(devC, noopCb)
            #expect(idC == idA, "the freed slot is the lowest free index — reused")
        }

        // MARK: - C2 (shim): outputs_registry_clear empties the registry + slots.

        @Test func registryClearEmptiesDevicesAndSlots() {
            let a = makeRegistryDevice(id: 0x11)
            let devA = outputs_device_get(a)!
            _ = outputs_callback_add(devA, noopCb)
            makeRegistryDevice(id: 0x22)

            #expect(outputs_list() != nil, "registry has devices before clear")

            outputs_registry_clear()

            #expect(outputs_list() == nil, "registry must be empty after clear")
            #expect(outputs_device_get(0x11) == nil)
            #expect(outputs_device_get(0x22) == nil)
            // Slots reset: a fresh add after a clear starts at slot 0.
            let n = makeRegistryDevice(id: 0x33)
            let devN = outputs_device_get(n)!
            #expect(outputs_callback_add(devN, noopCb) == 0, "callback register reset by clear")
        }

        // MARK: - B5.2 (end-to-end): a timed-out op clears its slot so the next op
        // on that device can re-arm instead of colliding / being rejected.

        @Test func timedOutOpClearsSlotSoNextOpReArms() async throws {
            let id = OutputID(rawValue: 0xD1)
            makeRegistryDevice(id: id.rawValue)

            let engine = AirPlayEngine()
            // Issue promises N=1 but we NEVER fire a completion → the op times out.
            // Short timeout so the test is fast.
            await engine.enterHeadlessTestMode(issue: { _, _ in 1 }, opTimeout: 0.05)
            await engine.registerKnownOutputForTest(id)

            do {
                try await engine.addOutput(id)
                Issue.record("op with no completion must time out")
            } catch {
                #expect(error as? AirPlayEngineError == .opTimedOut)
            }

            // The timed-out slot must have been cleared (B5.2). A SECOND op on the
            // same device must therefore arm a fresh waiter (slot 0 again) and, when
            // completed, succeed — proving no leaked slot and no arm-refusal collision.
            async let op: Void = engine.addOutput(id)
            try await fireWhenArmed(id: id.rawValue, engine: engine)
            try await op

            let state = await engine.stateOf(id)
            #expect(state == .connected)
        }

        // MARK: - B5.1: two overlapping ops on ONE id serialize (no clobbered waiter).

        @Test func overlappingOpsOnSameIdSerialize() async throws {
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
            // Neither call hangs (the test-runner timeout is the backstop).
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
            Issue.record("waiter was never armed for device \(String(format: "0x%llX", id))")
        }
    }
}
