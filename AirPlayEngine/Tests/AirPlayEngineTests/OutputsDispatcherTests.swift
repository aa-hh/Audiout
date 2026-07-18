// R-A correctness net (T-SHIM-1, item 2).
//
// Exercises the outputs_cb callback-accounting dispatcher (shims/outputs.c) in
// isolation against docs/outputs-dispatcher-contract.md — NO real AirPlay/PTP
// session, no libevent loop. The dispatcher's deferred delivery is driven
// synchronously via outputs_cb_deferred_run() (in production the same drain runs
// off the evbase_player deferred event).
//
// The core property under test: for every device_* op that promises N callbacks
// (N ∈ {0,1} in this cluster), the engine completion hook fires EXACTLY N times
// and the waiter unblocks — under the normal, error/FAILED, password, auth-retry
// (§4c id-hand-off), teardown and defensive-noop paths. Getting the count wrong
// hangs the engine; these tests assert it never does.

import XCTest
@testable import AirPlayEngine
import CAirPlayEngine

// MARK: - Observable state for the non-capturing C callbacks
//
// @convention(c) function pointers can't capture Swift state, so the C hooks
// record into these file-scope globals. Reset in setUp().

private var statusCbCalls: [(devicePresent: Bool, state: Int32)] = []
private var completionCalls: [(callbackId: Int32, deviceId: UInt64, state: Int32)] = []

// output_status_cb: void (*)(struct output_device*, enum output_device_state)
private let recordingStatusCb: @convention(c) (
    UnsafeMutablePointer<output_device>?, output_device_state
) -> Void = { device, state in
    statusCbCalls.append((devicePresent: device != nil, state: state.rawValue))
}

// A distinct second status cb, to prove per-device registration is independent.
private let otherStatusCb: @convention(c) (
    UnsafeMutablePointer<output_device>?, output_device_state
) -> Void = { _, _ in }

// outputs_engine_completion_cb: (int, uint64_t, state, void* ctx) -> void
private let recordingCompletionCb: @convention(c) (
    Int32, UInt64, output_device_state, UnsafeMutableRawPointer?
) -> Void = { callbackId, deviceId, state, _ in
    completionCalls.append((callbackId: callbackId, deviceId: deviceId, state: state.rawValue))
}

final class OutputsDispatcherTests: XCTestCase {

    override func setUp() {
        super.setUp()
        statusCbCalls.removeAll()
        completionCalls.removeAll()
        // Clean registry + hook for each case. (Also drains any device list from
        // a prior case that left devices registered.)
        outputs_dispatcher_reset()
        drainRegistry()
        outputs_engine_completion_set(recordingCompletionCb, nil)
    }

    override func tearDown() {
        outputs_dispatcher_reset()
        drainRegistry()
        super.tearDown()
    }

    // MARK: - Helpers

    /// Allocate a heap device, add it to the registry, return the canonical ptr.
    /// `advertised`/`session` control whether the deferred drain keeps it (a
    /// stopped/failed device with neither is removed+freed by the drain, exactly
    /// like OwnTone). We default advertised=true so the device survives delivery
    /// and the test can re-inspect it.
    @discardableResult
    private func makeDevice(id: UInt64, advertised: Bool = true, session: Bool = false)
        -> UnsafeMutablePointer<output_device>
    {
        let dev = UnsafeMutablePointer<output_device>.allocate(capacity: 1)
        dev.initialize(to: output_device())
        dev.pointee.id = id
        // Ownership transfers to the registry (freed by outputs_device_free).
        // NOTE: outputs_device_add (T-SHIM-2 real merge) always marks the device
        // advertised=1 — that's the real lifecycle (a device that just appeared
        // via discovery IS advertised; it only becomes advertised=0 later via
        // player_device_remove). So set the advertised/session flags AFTER the
        // add, to model the state the drain actually sees.
        let canonical = outputs_device_add(dev, false)!
        canonical.pointee.advertised = advertised ? 1 : 0
        canonical.pointee.session = session ? UnsafeMutableRawPointer(bitPattern: 0x1) : nil
        return canonical
    }

    /// Remove every device currently in the registry (frees them).
    private func drainRegistry() {
        while let head = outputs_list() {
            outputs_device_remove(head)
        }
    }

    // MARK: - Normal path: device_start promises N=1, one callback completes it.

    func testNormalStartOneCallbackCompletes() {
        let deviceId: UInt64 = 0xAABB
        makeDevice(id: deviceId)
        let dev = outputs_device_get(deviceId)!

        // Issuer arms the waiter (this is what player/engine does right before
        // calling airplay_device_start, which returns N=1).
        let cbId = outputs_callback_add(dev, recordingStatusCb)
        XCTAssertGreaterThanOrEqual(cbId, 0, "callback_add must yield a valid id")

        // Backend reports STREAMING once (the terminal completion for start).
        outputs_cb(cbId, deviceId, OUTPUT_STATE_STREAMING)

        // Nothing delivered until the deferred pass runs (re-entrancy safety).
        XCTAssertEqual(completionCalls.count, 0, "delivery must be deferred, not inline")

        outputs_cb_deferred_run()

        // Exactly one completion, carrying the right id/device/state.
        XCTAssertEqual(completionCalls.count, 1)
        XCTAssertEqual(completionCalls.first?.callbackId, cbId)
        XCTAssertEqual(completionCalls.first?.deviceId, deviceId)
        XCTAssertEqual(completionCalls.first?.state, OUTPUT_STATE_STREAMING.rawValue)

        // Status cb also fired once, with a live device, and device->state updated.
        XCTAssertEqual(statusCbCalls.count, 1)
        XCTAssertEqual(statusCbCalls.first?.devicePresent, true)
        XCTAssertEqual(outputs_device_get(deviceId)?.pointee.state.rawValue,
                       OUTPUT_STATE_STREAMING.rawValue)

        // The slot is spent: a second drain delivers nothing (no double-count).
        outputs_cb_deferred_run()
        XCTAssertEqual(completionCalls.count, 1, "id must fire exactly once")
    }

    // MARK: - REAL AP2 device_start terminal is CONNECTED (2026-07-16 first-light).
    //
    // Against a real AirPlay 2 buffered receiver (Sonos Move), the vendored sender
    // reports device_start's single completion as OUTPUT_STATE_CONNECTED (state=2)
    // — AIRPLAY_SEQ_START_PLAYBACK.on_success == session_connected (airplay.c:3620,
    // 1338). This is the exact callback observed on hardware. Assert it flows
    // through the engine hook once, carrying CONNECTED, so the async waiter can
    // resolve. (The Swift-side terminal classification of .connected is covered in
    // AirPlayEngineAPITests.testOutputStateTerminalClassification.)
    func testAirPlay2StartReportsConnected() {
        let deviceId: UInt64 = 0x542A1B79089E // the real Sonos Move device id
        // A live device_start has an attached session; keep it advertised so the
        // drain doesn't drop it (the CONNECTED report is NOT a teardown).
        makeDevice(id: deviceId, advertised: true, session: true)
        let dev = outputs_device_get(deviceId)!
        let cbId = outputs_callback_add(dev, recordingStatusCb)

        // The single completion the RTSP state machine fires at end of
        // START_PLAYBACK (session_connected -> session_status -> outputs_cb).
        outputs_cb(cbId, deviceId, OUTPUT_STATE_CONNECTED)
        outputs_cb_deferred_run()

        XCTAssertEqual(completionCalls.count, 1, "CONNECTED is device_start's sole terminal — must fire once")
        XCTAssertEqual(completionCalls.first?.callbackId, cbId)
        XCTAssertEqual(completionCalls.first?.deviceId, deviceId)
        XCTAssertEqual(completionCalls.first?.state, OUTPUT_STATE_CONNECTED.rawValue)
        // device->state advanced to CONNECTED; device survives (session live).
        XCTAssertEqual(outputs_device_get(deviceId)?.pointee.state.rawValue,
                       OUTPUT_STATE_CONNECTED.rawValue)
    }

    // MARK: - Failure-after-connect: once CONNECTED spent the id (session_status
    // set callback_id=-1), the later RTSP-close failure fires outputs_cb(-1,…),
    // which is a defensive no-op. This is the OTHER half of the first-light hang:
    // if the CONNECTED completion is dropped upstream, the failure CANNOT recover
    // the waiter. Assert the -1 report delivers nothing (the waiter must be
    // released by the CONNECTED report, not this one).
    func testFailureAfterConnectIsNoOpOnSpentId() {
        let deviceId: UInt64 = 0x542A1B79089E
        makeDevice(id: deviceId, advertised: true, session: true)
        let dev = outputs_device_get(deviceId)!
        let cbId = outputs_callback_add(dev, recordingStatusCb)

        // 1) CONNECTED fires and is delivered — the id is now spent.
        outputs_cb(cbId, deviceId, OUTPUT_STATE_CONNECTED)
        outputs_cb_deferred_run()
        XCTAssertEqual(completionCalls.count, 1)

        // 2) The receiver later closes RTSP; session_status runs with callback_id
        //    already -1 (spent). outputs_cb(-1,…) must be ignored — no second
        //    completion, no crash.
        outputs_cb(-1, deviceId, OUTPUT_STATE_FAILED)
        outputs_cb_deferred_run()
        XCTAssertEqual(completionCalls.count, 1, "spent id (-1) must not deliver a second completion")
    }

    // MARK: - Error path: FAILED still unblocks (never hangs).

    func testErrorPathFailedStillCompletes() {
        let deviceId: UInt64 = 0xC0FFEE
        makeDevice(id: deviceId)
        let dev = outputs_device_get(deviceId)!
        let cbId = outputs_callback_add(dev, recordingStatusCb)

        outputs_cb(cbId, deviceId, OUTPUT_STATE_FAILED)
        outputs_cb_deferred_run()

        XCTAssertEqual(completionCalls.count, 1, "error path must unblock the waiter")
        XCTAssertEqual(completionCalls.first?.state, OUTPUT_STATE_FAILED.rawValue)
    }

    // MARK: - Password path: AUTH -> PASSWORD is a terminal report, fires once.

    func testPasswordPathCompletesOnce() {
        let deviceId: UInt64 = 0x50
        makeDevice(id: deviceId)
        let dev = outputs_device_get(deviceId)!
        let cbId = outputs_callback_add(dev, recordingStatusCb)

        outputs_cb(cbId, deviceId, OUTPUT_STATE_PASSWORD)
        outputs_cb_deferred_run()

        XCTAssertEqual(completionCalls.count, 1)
        XCTAssertEqual(completionCalls.first?.state, OUTPUT_STATE_PASSWORD.rawValue)
    }

    // MARK: - §4c auth-retry / ipv6->ipv4: same callback_id survives a session
    // teardown and is re-used by a new session; still exactly ONE completion.

    func testAuthRetryIdHandoffFiresExactlyOnce() {
        let deviceId: UInt64 = 0x6A6A
        makeDevice(id: deviceId)
        let dev = outputs_device_get(deviceId)!

        // Original device_start arms callback_id.
        let cbId = outputs_callback_add(dev, recordingStatusCb)

        // start_retry (airplay.c:2990) tears down the old session WITHOUT firing
        // (callback_id was moved out first) and starts a NEW session re-using the
        // SAME id. Critically, session teardown must NOT clear the pending slot —
        // so we deliberately do NOT call outputs_callback_remove here. The new
        // session simply carries `cbId` forward and eventually reports once.
        XCTAssertEqual(outputs_callback_get(dev).map { _ in true } ?? false, true,
                       "pending slot must survive session teardown (contract §4c)")

        // New session reaches STREAMING and reports once against the same id.
        outputs_cb(cbId, deviceId, OUTPUT_STATE_STREAMING)
        outputs_cb_deferred_run()

        XCTAssertEqual(completionCalls.count, 1, "id survives retry -> exactly one completion")
        XCTAssertEqual(completionCalls.first?.callbackId, cbId)
    }

    // MARK: - Replace-on-add: a new op on the same device overwrites the old
    // registration (one pending callback per device).

    func testReplaceOnAddSameDevice() {
        let deviceId: UInt64 = 0x77
        makeDevice(id: deviceId)
        let dev = outputs_device_get(deviceId)!

        let firstId = outputs_callback_add(dev, otherStatusCb)
        let secondId = outputs_callback_add(dev, recordingStatusCb)
        XCTAssertEqual(firstId, secondId,
                       "replace-on-add reuses the freed slot for the same device")

        outputs_cb(secondId, deviceId, OUTPUT_STATE_CONNECTED)
        outputs_cb_deferred_run()

        // Only the surviving (second) registration delivers, once.
        XCTAssertEqual(completionCalls.count, 1)
        XCTAssertEqual(statusCbCalls.count, 1)
    }

    // MARK: - N=0 flush (not streaming): issuer registers NO waiter, so nothing
    // is ever delivered and nothing hangs.

    func testZeroCallbackOpRegistersNoWaiter() {
        let deviceId: UInt64 = 0x99
        makeDevice(id: deviceId)

        // device_flush returned 0 -> the issuer must NOT arm a waiter. We model
        // that by simply not calling outputs_callback_add. A drain delivers nothing.
        outputs_cb_deferred_run()

        XCTAssertEqual(completionCalls.count, 0, "N=0 op must never produce a completion")
    }

    // MARK: - Defensive no-ops: illegal ids are ignored, never hang/crash.

    func testDefensiveIllegalIdsAreNoOps() {
        let deviceId: UInt64 = 0x11
        makeDevice(id: deviceId)

        // Negative id (the "no callback promised" sentinel airplay.c clears to -1).
        outputs_cb(-1, deviceId, OUTPUT_STATE_STREAMING)
        // Out-of-range id (>= OUTPUTS_MAX_CALLBACKS == 64).
        outputs_cb(64, deviceId, OUTPUT_STATE_STREAMING)
        outputs_cb(9999, deviceId, OUTPUT_STATE_STREAMING)
        // In-range but empty slot (no callback_add was done for it).
        outputs_cb(5, deviceId, OUTPUT_STATE_STREAMING)

        outputs_cb_deferred_run()
        XCTAssertEqual(completionCalls.count, 0, "illegal ids must be ignored, not delivered")
    }

    // MARK: - Teardown/stop: stopped device with no advertise/session is removed
    // by the drain (device delivered as NULL), still exactly one completion.

    func testStopRemovesDeadDeviceAndDeliversNull() {
        let deviceId: UInt64 = 0xDEAD
        // advertised=false, session=nil -> the drain drops it from the registry.
        makeDevice(id: deviceId, advertised: false, session: false)
        let dev = outputs_device_get(deviceId)!
        let cbId = outputs_callback_add(dev, recordingStatusCb)

        outputs_cb(cbId, deviceId, OUTPUT_STATE_STOPPED)
        outputs_cb_deferred_run()

        XCTAssertEqual(completionCalls.count, 1)
        XCTAssertEqual(completionCalls.first?.state, OUTPUT_STATE_STOPPED.rawValue)
        // Status cb saw a NULL device (it left the building).
        XCTAssertEqual(statusCbCalls.first?.devicePresent, false)
        // And it's gone from the registry.
        XCTAssertNil(outputs_device_get(deviceId))
    }

    // MARK: - Multiple independent devices in flight: each fires once, no cross-talk.

    func testMultipleDevicesEachCompleteOnce() {
        let ids: [UInt64] = [0x1, 0x2, 0x3]
        var cbIds: [Int32] = []
        for id in ids {
            makeDevice(id: id)
            let dev = outputs_device_get(id)!
            cbIds.append(outputs_callback_add(dev, recordingStatusCb))
        }
        // All distinct slots.
        XCTAssertEqual(Set(cbIds).count, ids.count)

        for (i, id) in ids.enumerated() {
            outputs_cb(cbIds[i], id, OUTPUT_STATE_STREAMING)
        }
        outputs_cb_deferred_run()

        XCTAssertEqual(completionCalls.count, ids.count)
        XCTAssertEqual(Set(completionCalls.map { $0.deviceId }), Set(ids))
    }

    // MARK: - removeOutput TOCTOU guard (crash fix, A2)
    //
    // A receiver-side RTSP drop frees the airplay_session and NULLs
    // device->session (shims/outputs.c outputs_device_session_remove) while the
    // device stays registered (FAILED, not yet .stopped). removeOutput's issue
    // closure must not call the vendored device_stop against a NULL session
    // (airplay_device_stop dereferences it unconditionally -> EXC_BAD_ACCESS).
    // startOp swaps in issueOverride under test, so the guard predicate is
    // extracted to `AirPlayEngine.stopSessionIsLive` and exercised directly here.

    func testStopSessionIsLiveFalseWhenSessionIsNull() {
        let dev = makeDevice(id: 0xCAFE, session: false)
        XCTAssertFalse(AirPlayEngine.stopSessionIsLive(dev))
    }

    func testStopSessionIsLiveTrueWhenSessionIsSet() {
        let dev = makeDevice(id: 0xCAFE + 1, session: true)
        XCTAssertTrue(AirPlayEngine.stopSessionIsLive(dev))
    }
}
