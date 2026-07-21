// T-ENG-STATESTREAM-1 headless tests for the async device-state stream.
//
// SCOPE: BUILD + HEADLESS ONLY. No real event loop, no sockets, no PTP. These
// drive the REAL C dispatcher (shims/outputs.c) with synthetic outputs_cb calls
// + a synchronous deferred run, and assert:
//
//   1. (C layer) A post-terminal report that SPENDS NO callback_id —
//      outputs_cb(-1, device_id, state), the exact shape airplay.c fires from
//      session_status() after the id was cleared to -1 — is surfaced to the
//      device-state hook, not dropped. This is the out-of-band transition the
//      completion hook can't see (its id is spent).
//
//   2. (Swift layer) engine.makeStateStream() yields (OutputID, OutputState)
//      for that transition, mirroring OutputBackend.makeEventStream().
//
//   3. The `.connected -> .failed` regression the stream exists for: an armed
//      device_start resolves on CONNECTED (spending the id), then a later
//      out-of-band FAILED (rtsp_close_cb -> session_failure -> outputs_cb(-1,…))
//      is delivered to the stream even though addOutput has already returned.

import XCTest
@testable import AirPlayEngine
import CAirPlayEngine

// @convention(c) hooks can't capture Swift state — record into file-scope globals.
private var stateHookCalls: [(deviceId: UInt64, state: Int32)] = []

private let recordingStateCb: @convention(c) (
    UInt64, output_device_state, UnsafeMutableRawPointer?
) -> Void = { deviceId, state, _ in
    stateHookCalls.append((deviceId: deviceId, state: state.rawValue))
}

final class StateStreamTests: XCTestCase {

    override func setUp() {
        super.setUp()
        stateHookCalls.removeAll()
        outputs_dispatcher_reset()
        drainRegistry()
    }

    override func tearDown() {
        outputs_dispatcher_reset()
        drainRegistry()
        super.tearDown()
    }

    // MARK: helpers

    @discardableResult
    private func makeDevice(id: UInt64, advertised: Bool = true, session: Bool = false)
        -> UnsafeMutablePointer<output_device>
    {
        let dev = UnsafeMutablePointer<output_device>.allocate(capacity: 1)
        dev.initialize(to: output_device())
        dev.pointee.id = id
        let canonical = outputs_device_add(dev, false)!
        canonical.pointee.advertised = advertised ? 1 : 0
        canonical.pointee.session = session ? UnsafeMutableRawPointer(bitPattern: 0x1) : nil
        return canonical
    }

    private func drainRegistry() {
        while let head = outputs_list() { outputs_device_remove(head) }
    }

    // MARK: - C layer: a SPENT-id (-1) report reaches the state hook, not dropped.
    //
    // This is the crux of the backlog item. outputs_cb(-1, …) previously returned
    // immediately (the "no callback promised / already spent" sentinel), so a
    // transition reported after an op's completion had spent its id was invisible.
    // Now it is routed out-of-band to the state hook.
    func testSpentIdReportReachesStateHook() {
        let deviceId: UInt64 = 0x542A1B79089E
        makeDevice(id: deviceId, advertised: true, session: true)
        outputs_engine_state_set(recordingStateCb, nil)

        // The exact call session_status() makes after callback_id was cleared to
        // -1: a genuine state transition with no live waiter.
        outputs_cb(-1, deviceId, OUTPUT_STATE_FAILED)

        // Deferred, never inline (re-entrancy safety) — same as the armed path.
        XCTAssertEqual(stateHookCalls.count, 0, "state delivery must be deferred")

        outputs_cb_deferred_run()

        XCTAssertEqual(stateHookCalls.count, 1, "spent-id transition must reach the state hook")
        XCTAssertEqual(stateHookCalls.first?.deviceId, deviceId)
        XCTAssertEqual(stateHookCalls.first?.state, OUTPUT_STATE_FAILED.rawValue)
    }

    // MARK: - C layer: an ARMED report also reaches the state hook (once), so a
    // subscriber sees op-driven transitions too, not only out-of-band ones.
    func testArmedReportAlsoReachesStateHook() {
        let deviceId: UInt64 = 0xAABB
        let dev = makeDevice(id: deviceId, advertised: true, session: true)
        outputs_engine_state_set(recordingStateCb, nil)

        let cbId = outputs_callback_add(dev, { _, _ in }) // non-NULL status cb required
        outputs_cb(cbId, deviceId, OUTPUT_STATE_CONNECTED)
        outputs_cb_deferred_run()

        XCTAssertEqual(stateHookCalls.count, 1)
        XCTAssertEqual(stateHookCalls.first?.deviceId, deviceId)
        XCTAssertEqual(stateHookCalls.first?.state, OUTPUT_STATE_CONNECTED.rawValue)

        // Spent slot: a second drain delivers nothing (no double-count).
        outputs_cb_deferred_run()
        XCTAssertEqual(stateHookCalls.count, 1)
    }

    // MARK: - Swift layer: makeStateStream() yields the out-of-band transition.
    //
    // Full engine path through the genuine dispatcher: fire a synthetic
    // post-terminal outputs_cb(-1,…) + deferred run and assert the stream yields
    // the (OutputID, OutputState) transition. No polling anywhere.
    func testStateStreamYieldsOutOfBandTransition() async throws {
        let id = OutputID(rawValue: 0xC0FFEE)
        makeDevice(id: id.rawValue, advertised: true, session: true)

        let engine = AirPlayEngine()
        await engine.enterHeadlessTestMode() // installs the state hook (no start())

        let reader = StreamReader(engine.makeStateStream())

        // Fire the out-of-band FAILED transition (spent id) through the REAL
        // dispatcher, exactly as airplay.c's rtsp_close_cb -> session_failure ->
        // session_status(callback_id == -1) would. Delivery is synchronous into
        // the stream's buffer, so the reader below returns it immediately; the
        // timeout only guards against a regression (dropped delivery) hanging.
        outputs_cb(-1, id.rawValue, OUTPUT_STATE_FAILED)
        outputs_cb_deferred_run()

        let element = try await reader.next(timeout: 2)
        XCTAssertEqual(element.0, id)
        XCTAssertEqual(element.1, .failed)

        await engine.stop() // finishes the stream cleanly
    }

    // MARK: - Swift layer: the `.connected -> .failed` regression this exists for.
    //
    // addOutput resolves on CONNECTED (spending the callback_id). AFTERWARD the
    // receiver drops RTSP and a FAILED transition arrives out-of-band. The
    // completion bridge can't see it (id spent); the state stream must.
    func testStreamObservesFailAfterAddOutputResolved() async throws {
        let id = OutputID(rawValue: 0x542A1B79089E)
        makeDevice(id: id.rawValue, advertised: true, session: true)

        let engine = AirPlayEngine()
        await engine.enterHeadlessTestMode(issue: { _, _ in 1 })
        await engine.registerKnownOutputForTest(id)

        let reader = StreamReader(engine.makeStateStream())

        // 1) addOutput resolves via the armed CONNECTED completion (id now spent).
        async let op: Void = engine.addOutput(id)
        try await fireWhenArmed(id: id.rawValue, state: OUTPUT_STATE_CONNECTED, engine: engine)
        try await op
        let resolved = await engine.stateOf(id)
        XCTAssertEqual(resolved, .connected)

        // The stream also observed the CONNECTED transition (armed report).
        let first = try await reader.next(timeout: 2)
        XCTAssertEqual(first.1, .connected)

        // 2) Out-of-band FAILED after the op resolved — the transition the
        //    completion bridge is blind to.
        outputs_cb(-1, id.rawValue, OUTPUT_STATE_FAILED)
        outputs_cb_deferred_run()

        let failed = try await reader.next(timeout: 2)
        XCTAssertEqual(failed.0, id)
        XCTAssertEqual(failed.1, .failed)

        await engine.stop()
    }

    // MARK: - PTP clock availability (T4)
    //
    // Headless mode never calls start() (no engine thread, no ptpd_find_or_bind),
    // so the only thing assertable without a real/gated session is the default:
    // ptpClockAvailable stays `true` until a real start() determines otherwise,
    // matching every pre-T4 caller's existing (unchanged) behavior.
    func testPtpClockAvailableDefaultsTrueBeforeStart() async {
        let engine = AirPlayEngine()
        let available = await engine.ptpClockAvailable
        XCTAssertTrue(available, "clock availability must default healthy until a real start() says otherwise")
    }

    // MARK: - internal helpers

    /// Fire a synthetic completion once the waiter is armed (same pattern as
    /// AirPlayEngineAPITests). The wrapper uses the lowest free slot (0 after a
    /// reset) for a single in-flight op.
    private func fireWhenArmed(
        id: UInt64,
        state: output_device_state,
        engine: AirPlayEngine
    ) async throws {
        // Gate on the REGISTRY waiter, not just the C callback slot: `startOp`
        // arms `outputs_callback_add` before `completions.arm`, so firing on the
        // C callback alone can hit the window before the waiter exists — the
        // completion is then dropped and the op hangs until its timeout. See the
        // twin helper in AirPlayEngineAPITests for the full rationale.
        for _ in 0..<200 {
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

/// Drains an `AsyncStream` into a thread-safe FIFO on a background task, and
/// exposes a timeout-guarded `next()` the test polls. This sidesteps the
/// single-consumer / non-Sendable-iterator constraints (one dedicated task owns
/// the iterator; the test only reads the buffer) while still failing fast — a
/// dropped-delivery regression drains nothing, so `next()` times out instead of
/// hanging the suite.
private final class StreamReader: @unchecked Sendable {
    private let task: Task<Void, Never>
    private let sink: Sink

    init(_ stream: AsyncStream<(OutputID, OutputState)>) {
        // Capture into a local so the closure doesn't touch `self` before init.
        let sink = Sink()
        self.sink = sink
        self.task = Task {
            for await element in stream { sink.append(element) }
        }
    }

    /// A tiny locked FIFO shared with the draining task.
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(OutputID, OutputState)] = []
        func append(_ e: (OutputID, OutputState)) { lock.lock(); items.append(e); lock.unlock() }
        func popFirst() -> (OutputID, OutputState)? {
            lock.lock(); defer { lock.unlock() }
            return items.isEmpty ? nil : items.removeFirst()
        }
    }

    /// The next buffered element, or throws `StateStreamTestTimeout` after
    /// `timeout` s. Polls a short interval so a synchronously-delivered element
    /// (the normal path) returns almost immediately.
    func next(timeout seconds: Double) async throws -> (OutputID, OutputState) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let element = sink.popFirst() { return element }
            try await Task.sleep(nanoseconds: 2_000_000) // 2ms
        }
        throw StateStreamTestTimeout()
    }

    deinit { task.cancel() }
}

private struct StateStreamTestTimeout: Error {}
