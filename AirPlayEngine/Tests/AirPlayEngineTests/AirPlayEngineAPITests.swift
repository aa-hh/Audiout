// T-API-1 headless tests for the Swift wrapper (AirPlayEngine).
//
// SCOPE: BUILD + HEADLESS ONLY. These drive the wrapper's session logic through
// the REAL C async-callback dispatcher (shims/outputs.c) using the wrapper's
// headless test seam — NO real event loop against hardware, NO sockets to a real
// device, NO airplay_init/PTP. They prove:
//   - addOutput arms a waiter and resolves via a synthetic completion fired
//     through the genuine dispatcher (arm -> outputs_cb -> deferred drain ->
//     engine completion hook -> continuation resume).
//   - terminal-state mapping: STREAMING succeeds; FAILED/PASSWORD throw.
//   - setVolume / removeOutput state transitions.
//   - discovery-descriptor -> C registry mapping (deviceid parse).
//   - unknown-output and not-started guards.
//
// A genuine live session (real receiver + OwnTone stopped + human present) is a
// separate GATED step (see AirPlayEngine/README.md, engine-probe).

import XCTest
@testable import AirPlayEngine
import CAirPlayEngine

final class AirPlayEngineAPITests: XCTestCase {

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

    // MARK: helpers

    /// Put a device in the C registry (as real discovery would) and return its id.
    /// `state` seeds `device->state` — the LIVE state the idempotency guards read
    /// (they consult the C device, not just the Swift cache, so a stale cache
    /// can't mask an out-of-band FAILED). Defaults to STOPPED (the zero value).
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

    /// Fire a synthetic backend completion for `id` through the REAL dispatcher.
    /// This is what the RTSP state machine would do at the end of device_start.
    private func fireCompletion(id: UInt64, cbIdSlot: Int32, state: output_device_state) {
        outputs_cb(cbIdSlot, id, state)
        outputs_cb_deferred_run()
    }

    // MARK: - addOutput: STREAMING resolves the awaiting continuation.

    func testAddOutputStreamingSucceeds() async throws {
        let id = OutputID(rawValue: 0xA1)
        makeRegistryDevice(id: id.rawValue)

        let engine = AirPlayEngine()
        // Headless: issue returns N=1 (one deferred completion promised), no HW.
        await engine.enterHeadlessTestMode(issue: { _, _ in 1 })
        await engine.registerKnownOutputForTest(id)

        // Drive addOutput and, concurrently, fire the completion once the waiter
        // is armed. The dispatcher uses slot 0 for the first armed callback.
        async let op: Void = engine.addOutput(id)
        try await fireWhenArmed(id: id.rawValue, state: OUTPUT_STATE_STREAMING)
        try await op

        let state = await engine.stateOf(id)
        XCTAssertEqual(state, .streaming)
    }

    // MARK: - addOutput: CONNECTED resolves the waiter (the REAL Sonos/AP2 path).
    //
    // REGRESSION (2026-07-16 first-light hang): against a real AirPlay 2 buffered
    // receiver (Sonos Move), the FULL RTSP/PTP handshake succeeds and the vendored
    // sender reports its single device_start completion as OUTPUT_STATE_CONNECTED
    // (AIRPLAY_SEQ_START_PLAYBACK.on_success == session_connected, airplay.c:3620),
    // NOT STREAMING. STREAMING is reached later inside airplay_write() with no
    // further callback. This test fires exactly that observed callback and asserts
    // addOutput RESOLVES (does not hang). Before the fix, OutputState.connected was
    // classified non-terminal, so CompletionRegistry.deliver dropped this sole
    // completion and the waiter hung forever.
    func testAddOutputConnectedSucceeds() async throws {
        let id = OutputID(rawValue: 0xA1C0)
        makeRegistryDevice(id: id.rawValue)

        let engine = AirPlayEngine()
        await engine.enterHeadlessTestMode(issue: { _, _ in 1 })
        await engine.registerKnownOutputForTest(id)

        async let op: Void = engine.addOutput(id)
        try await fireWhenArmed(id: id.rawValue, state: OUTPUT_STATE_CONNECTED)
        try await op // must NOT hang: CONNECTED is the terminal for AP2 device_start

        let state = await engine.stateOf(id)
        XCTAssertEqual(state, .connected)
    }

    // MARK: - Terminal-state classification: the exact set the vendored sender can
    // report via a single callback_id-spending outputs_cb. Locks in the
    // 2026-07-16 fix (CONNECTED terminal) and guards against a regression that
    // would re-drop the AP2 device_start completion.
    //
    // STARTUP (INFO…RECORD progress) is the ONLY non-terminal — and in the
    // vendored sender it is never even emitted for device_start (session_status is
    // only called at sequence success/failure), so this guard is defensive.
    func testOutputStateTerminalClassification() {
        XCTAssertTrue(OutputState.connected.isTerminal,
                      "CONNECTED is the AP2 device_start terminal (regression: 2026-07-16 hang)")
        XCTAssertTrue(OutputState.streaming.isTerminal)
        XCTAssertTrue(OutputState.stopped.isTerminal)
        XCTAssertTrue(OutputState.failed.isTerminal)
        XCTAssertTrue(OutputState.passwordRequired.isTerminal)
        XCTAssertFalse(OutputState.startup.isTerminal, "STARTUP is intermediate progress")
    }

    // MARK: - addOutput: FAILED terminal state throws sessionFailed.

    func testAddOutputFailedThrows() async throws {
        let id = OutputID(rawValue: 0xA2)
        makeRegistryDevice(id: id.rawValue)
        let engine = AirPlayEngine()
        await engine.enterHeadlessTestMode(issue: { _, _ in 1 })
        await engine.registerKnownOutputForTest(id)

        async let op: Void = engine.addOutput(id)
        try await fireWhenArmed(id: id.rawValue, state: OUTPUT_STATE_FAILED)

        do {
            try await op
            XCTFail("expected sessionFailed")
        } catch AirPlayEngineError.sessionFailed {
            // expected
        }
    }

    // MARK: - addOutput: PASSWORD terminal state throws passwordRequired.

    func testAddOutputPasswordThrows() async throws {
        let id = OutputID(rawValue: 0xA3)
        makeRegistryDevice(id: id.rawValue)
        let engine = AirPlayEngine()
        await engine.enterHeadlessTestMode(issue: { _, _ in 1 })
        await engine.registerKnownOutputForTest(id)

        async let op: Void = engine.addOutput(id)
        try await fireWhenArmed(id: id.rawValue, state: OUTPUT_STATE_PASSWORD)

        do {
            try await op
            XCTFail("expected passwordRequired")
        } catch AirPlayEngineError.passwordRequired {
            // expected
        }
    }

    // MARK: - setVolume: awaits a completion, records volume on the C device.

    func testSetVolumeDrivesDeviceAndCompletes() async throws {
        let id = OutputID(rawValue: 0xB1)
        makeRegistryDevice(id: id.rawValue)

        let engine = AirPlayEngine()
        await engine.enterHeadlessTestMode(issue: { device, _ in
            // airplay.c's volume model treats device->volume as a 0...100 PERCENT
            // (airplay_set_volume_one / airplay_volume_from_pct map 0..100 -> -30..0
            // dB). The normalized 0.5 must therefore land on 50, NOT be scaled by the
            // uninitialized `max_volume` field (which pinned every request to 0 => the
            // -30 dB "inaudible" floor). See applyVolumeOnDevice.
            XCTAssertEqual(device.pointee.volume, 50)
            return 1
        })
        await engine.registerKnownOutputForTest(id)

        async let op: Void = engine.setVolume(id, 0.5)
        try await fireWhenArmed(id: id.rawValue, state: OUTPUT_STATE_STREAMING)
        try await op
    }

    // MARK: - setVolume regression: normalized -> 0..100 percent, NOT scaled by
    // the uninitialized `max_volume` field.
    //
    // First-light bug (2026-07-17): applyVolumeOnDevice computed
    // `device->volume = max_volume * normalized`, but `struct output_device`'s
    // `max_volume` is never initialized by this engine (calloc'd to 0) and is not
    // the quantity airplay.c's AirPlay-2 volume path uses. That pinned EVERY
    // setVolume to device->volume = 0 => airplay_volume_from_pct(0) = -30.0 dB,
    // the quietest non-muted level — inaudible on a Sonos, "green never white".
    // The C layer wants device->volume as a 0..100 PERCENT. This asserts the
    // full-range mapping with a device left at the production default max_volume=0.
    func testSetVolumeMapsToPercentIgnoringUninitializedMaxVolume() async throws {
        let cases: [(Double, Int32)] = [(0.0, 0), (0.4, 40), (0.5, 50), (1.0, 100)]
        for (normalized, expectedPct) in cases {
            outputs_dispatcher_reset(); drainRegistry()
            let id = OutputID(rawValue: 0xB5)
            makeRegistryDevice(id: id.rawValue)
            // Deliberately DO NOT set max_volume: it stays 0 as in production.
            XCTAssertEqual(outputs_device_get(id.rawValue)!.pointee.max_volume, 0)

            let engine = AirPlayEngine()
            await engine.enterHeadlessTestMode(issue: { device, _ in
                XCTAssertEqual(device.pointee.volume, expectedPct,
                               "normalized \(normalized) must map to \(expectedPct)% (device->volume is a 0..100 percent)")
                return 1
            })
            await engine.registerKnownOutputForTest(id)

            async let op: Void = engine.setVolume(id, normalized)
            try await fireWhenArmed(id: id.rawValue, state: OUTPUT_STATE_STREAMING)
            try await op
        }
    }

    // MARK: - removeOutput: awaits stop completion.

    func testRemoveOutputCompletes() async throws {
        let id = OutputID(rawValue: 0xB2)
        makeRegistryDevice(id: id.rawValue, state: OUTPUT_STATE_STREAMING)
        let engine = AirPlayEngine()
        await engine.enterHeadlessTestMode(issue: { _, _ in 1 })
        await engine.registerKnownOutputForTest(id, state: .streaming)

        async let op: Void = engine.removeOutput(id)
        try await fireWhenArmed(id: id.rawValue, state: OUTPUT_STATE_STOPPED)
        try await op

        let state = await engine.stateOf(id)
        XCTAssertEqual(state, .stopped)
    }

    // MARK: - N<=0 op never hangs (issue returns 0 -> immediate resolve).

    func testZeroCallbackOpResolvesImmediately() async throws {
        let id = OutputID(rawValue: 0xB3)
        makeRegistryDevice(id: id.rawValue, state: OUTPUT_STATE_STREAMING)
        let engine = AirPlayEngine()
        // issue returns 0 -> no completion promised; startOp resolves inline.
        await engine.enterHeadlessTestMode(issue: { _, _ in 0 })
        await engine.registerKnownOutputForTest(id, state: .streaming)

        // Must NOT hang: no synthetic completion fired.
        try await engine.removeOutput(id)
        let state = await engine.stateOf(id)
        XCTAssertEqual(state, .stopped)
    }

    // MARK: - Guards: unknown output + not-started.

    func testUnknownOutputThrows() async {
        let engine = AirPlayEngine()
        await engine.enterHeadlessTestMode()
        do {
            try await engine.addOutput(OutputID(rawValue: 0xDEAD))
            XCTFail("expected unknownOutput")
        } catch AirPlayEngineError.unknownOutput {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testNotStartedThrows() async {
        // A fresh engine that hasn't started() and isn't in test mode: addOutput
        // must throw engineNotRunning, not hang or crash.
        let engine = AirPlayEngine()
        do {
            try await engine.addOutput(OutputID(rawValue: 0x1))
            XCTFail("expected engineNotRunning")
        } catch AirPlayEngineError.engineNotRunning {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - Discovery descriptor -> C registry mapping.

    func testDiscoveryDescriptorMapsDeviceID() async {
        // A descriptor with a colon-hex deviceid should parse to the matching id.
        let desc = DeviceDescriptor(
            name: "Living Room",
            hostname: "livingroom.local",
            address: "192.168.1.50",
            family: .ipv4,
            port: 7000,
            txtRecord: [
                "deviceid": "AA:BB:CC:DD:EE:FF",
                // Minimal AP2 features so airplay_device_cb accepts it.
                "features": "0x445F8A00,0x1C340",
                "model": "AudioAccessory5,1",
            ]
        )
        XCTAssertEqual(desc.parsedID?.rawValue, 0xAABBCCDDEEFF)

        let engine = AirPlayEngine()
        // Note: airplayengine_feed_device needs the captured callback, which only
        // exists after airplay_init. Without a real init the feed is a no-op that
        // returns -1; we still verify the Swift-side parse + keyval build path
        // doesn't crash and the id parse is correct (the registry insertion is
        // covered end-to-end only in the gated live run).
        let mappedID = await engine.feedDescriptorForTest(desc)
        XCTAssertEqual(mappedID?.rawValue, 0xAABBCCDDEEFF)
    }

    func testDescriptorWithoutDeviceIDIsInvalid() {
        let desc = DeviceDescriptor(
            name: "NoID", address: "10.0.0.1", family: .ipv4, port: 7000,
            txtRecord: ["features": "0x1"]
        )
        XCTAssertNil(desc.parsedID)
    }

    // MARK: - localOutput placeholder surface (SPEC §8.1).

    func testLocalOutputPlaceholder() async {
        let engine = AirPlayEngine()
        var sink = await engine.localOutput
        XCTAssertFalse(sink.isEnabled)
        XCTAssertFalse(sink.isImplemented)

        await engine.setLocalOutputEnabled(true)
        sink = await engine.localOutput
        XCTAssertTrue(sink.isEnabled)
        XCTAssertFalse(sink.isImplemented, "still a placeholder in T-API-1")
    }

    // MARK: - hashClientName is stable + non-zero (libhash seed), and differs
    // per-install (T-ENG-LIBHASH-1, first-light backlog #5.1).

    func testClientNameHashStableNonZero() {
        let a = AirPlayEngine.hashClientName("My Speakers", seed: 0x1111)
        let b = AirPlayEngine.hashClientName("My Speakers", seed: 0x1111)
        let c = AirPlayEngine.hashClientName("Other", seed: 0x1111)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertNotEqual(a, 0)
    }

    func testClientNameHashDiffersPerInstallSeed() {
        // Same clientName, different per-install seed -> different, non-zero
        // libhash. This is the collision this task fixes: two installs on one
        // LAN advertising the same clientName used to hash identically.
        let seedA: UInt64 = 0xdead_beef_1234_5678
        let seedB: UInt64 = 0x1357_9bdf_0246_8ace
        let a = AirPlayEngine.hashClientName("My Speakers", seed: seedA)
        let b = AirPlayEngine.hashClientName("My Speakers", seed: seedB)
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, 0)
        XCTAssertNotEqual(b, 0)
    }

    func testClientNameHashNonZeroForZeroSeed() {
        // Even a degenerate all-zero seed must not produce a zero libhash —
        // the C side asserts a non-zero seed.
        XCTAssertNotEqual(AirPlayEngine.hashClientName("", seed: 0), 0)
        XCTAssertNotEqual(AirPlayEngine.hashClientName("X", seed: 0), 0)
    }

    // MARK: - device_start/stop idempotency guards (first-light hardening #5e).
    //
    // Re-adding an output that is already streaming/connected, or re-stopping one
    // that is already stopped, must be a no-op SUCCESS that does NOT re-issue the
    // backend op. We prove "no op issued" by NOT firing any synthetic completion:
    // if the guard failed and the wrapper armed a waiter, the awaited call would
    // hang (no completion arrives) and the test would time out. Reaching the
    // assertion below means the guard short-circuited before arming.

    func testAddOutputIsIdempotentWhenAlreadyStreaming() async throws {
        let id = OutputID(rawValue: 0xC1)
        makeRegistryDevice(id: id.rawValue, state: OUTPUT_STATE_STREAMING)
        let engine = AirPlayEngine()
        // issue would FAIL the test if ever called: the guard must skip it.
        await engine.enterHeadlessTestMode(issue: { _, _ in
            XCTFail("device_start must not be issued for an already-streaming output")
            return 1
        })
        await engine.registerKnownOutputForTest(id, state: .streaming)

        // No fireWhenArmed: a working guard resolves immediately with no waiter.
        try await engine.addOutput(id)
        let state = await engine.stateOf(id)
        XCTAssertEqual(state, .streaming, "state unchanged by the no-op re-add")
    }

    func testAddOutputIsIdempotentWhenAlreadyConnected() async throws {
        let id = OutputID(rawValue: 0xC1C0)
        makeRegistryDevice(id: id.rawValue, state: OUTPUT_STATE_CONNECTED)
        let engine = AirPlayEngine()
        await engine.enterHeadlessTestMode(issue: { _, _ in
            XCTFail("device_start must not be issued for an already-connected output")
            return 1
        })
        await engine.registerKnownOutputForTest(id, state: .connected)

        try await engine.addOutput(id)
        let state = await engine.stateOf(id)
        XCTAssertEqual(state, .connected)
    }

    // REGRESSION (first-light hardening #5 fix): the idempotency guard must read
    // the LIVE C device state, not a stale Swift cache. Scenario: addOutput
    // resolved CONNECTED (cache = .connected), then the receiver dropped RTSP and
    // an out-of-band outputs_cb(-1, FAILED) flipped device->state to FAILED. A
    // recovery addOutput MUST re-issue device_start — a cache-only guard would
    // see .connected and silently no-op, and audio would never resume.
    func testAddOutputReissuesWhenLiveStateFailedDespiteStaleConnectedCache() async throws {
        let id = OutputID(rawValue: 0xC1FA)
        // Live C state is FAILED (receiver dropped), even though the cache below
        // still reads .connected (the state stream hasn't reconciled it yet).
        makeRegistryDevice(id: id.rawValue, state: OUTPUT_STATE_FAILED)
        let engine = AirPlayEngine()
        var reissued = false
        await engine.enterHeadlessTestMode(issue: { _, _ in reissued = true; return 1 })
        await engine.registerKnownOutputForTest(id, state: .connected) // stale cache

        async let op: Void = engine.addOutput(id)
        try await fireWhenArmed(id: id.rawValue, state: OUTPUT_STATE_CONNECTED)
        try await op

        XCTAssertTrue(reissued, "a live-FAILED session must re-issue device_start despite a stale .connected cache")
        let state = await engine.stateOf(id)
        XCTAssertEqual(state, .connected, "the re-issued session resolves CONNECTED again")
    }

    // REGRESSION (out-of-band FAILED must update device->state): the test above
    // seeds device->state=FAILED directly, which simulates a write the real
    // out-of-band path must perform. This one drives the ACTUAL path end to end:
    // a device is CONNECTED (as after addOutput resolved), then the receiver
    // drops RTSP and airplay.c's session_status fires outputs_cb(-1, id, FAILED)
    // — the spent-id, out-of-band report. The drain routes it through the state
    // ring (never a completion). It MUST also write device->state = FAILED, or
    // liveDeviceState stays pinned at CONNECTED and the recovery re-add no-ops.
    func testOutOfBandFailedUpdatesDeviceStateAndReAddReissues() async throws {
        let id = OutputID(rawValue: 0xC1FB)
        // Device is CONNECTED, exactly as after a successful addOutput.
        makeRegistryDevice(id: id.rawValue, state: OUTPUT_STATE_CONNECTED)

        // Receiver drops RTSP: session_status fires the spent-id report and then
        // the deferred pass drains the out-of-band state-note ring.
        outputs_cb(-1, id.rawValue, OUTPUT_STATE_FAILED)
        outputs_cb_deferred_run()

        // The fix: the out-of-band drain re-resolves the device by id and writes
        // device->state. Without it, this stays CONNECTED.
        let live = outputs_device_get(id.rawValue)
        XCTAssertNotNil(live)
        XCTAssertEqual(live?.pointee.state, OUTPUT_STATE_FAILED,
                       "out-of-band FAILED must update device->state, not just the state hook")

        // End-to-end: a recovery addOutput now reads the live FAILED and re-issues
        // device_start, even though the Swift cache still reads .connected.
        let engine = AirPlayEngine()
        var reissued = false
        await engine.enterHeadlessTestMode(issue: { _, _ in reissued = true; return 1 })
        await engine.registerKnownOutputForTest(id, state: .connected) // stale cache

        async let op: Void = engine.addOutput(id)
        try await fireWhenArmed(id: id.rawValue, state: OUTPUT_STATE_CONNECTED)
        try await op

        XCTAssertTrue(reissued, "an out-of-band FAILED must let a recovery addOutput re-issue device_start")
    }

    func testRemoveOutputIsIdempotentWhenAlreadyStopped() async throws {
        let id = OutputID(rawValue: 0xC2)
        makeRegistryDevice(id: id.rawValue)
        let engine = AirPlayEngine()
        await engine.enterHeadlessTestMode(issue: { _, _ in
            XCTFail("device_stop must not be issued for an already-stopped output")
            return 1
        })
        await engine.registerKnownOutputForTest(id, state: .stopped)

        try await engine.removeOutput(id)
        let state = await engine.stateOf(id)
        XCTAssertEqual(state, .stopped)
    }

    // A guard must NOT swallow a legitimate stop: an active (streaming) output
    // still issues device_stop and resolves through the real completion path.
    func testRemoveOutputStillStopsActiveOutput() async throws {
        let id = OutputID(rawValue: 0xC3)
        makeRegistryDevice(id: id.rawValue, state: OUTPUT_STATE_STREAMING)
        let engine = AirPlayEngine()
        var issued = false
        await engine.enterHeadlessTestMode(issue: { _, _ in issued = true; return 1 })
        await engine.registerKnownOutputForTest(id, state: .streaming)

        async let op: Void = engine.removeOutput(id)
        try await fireWhenArmed(id: id.rawValue, state: OUTPUT_STATE_STOPPED)
        try await op

        XCTAssertTrue(issued, "device_stop must be issued for an active output")
        let state = await engine.stateOf(id)
        XCTAssertEqual(state, .stopped)
    }

    // MARK: - device_flush NO-OP seam (first-light hardening #5f).
    //
    // flushOutput is a stable API surface for a FUTURE pause/seek feature; in
    // this phase it must NOT issue the vendored device_flush. Prove it resolves
    // immediately (no waiter armed -> would hang if it did) and that its state
    // guard rejects an unknown output.

    func testFlushOutputIsNoOpSeamForKnownOutput() async throws {
        let id = OutputID(rawValue: 0xF1)
        makeRegistryDevice(id: id.rawValue)
        let engine = AirPlayEngine()
        await engine.enterHeadlessTestMode(issue: { _, _ in
            XCTFail("flushOutput is a no-op seam and must not issue any backend op")
            return 1
        })
        await engine.registerKnownOutputForTest(id, state: .streaming)

        // Resolves immediately (no completion fired). State is untouched.
        try await engine.flushOutput(id)
        let state = await engine.stateOf(id)
        XCTAssertEqual(state, .streaming, "flush seam must not alter output state")
    }

    func testFlushOutputRejectsUnknownOutput() async {
        let engine = AirPlayEngine()
        await engine.enterHeadlessTestMode()
        do {
            try await engine.flushOutput(OutputID(rawValue: 0xF0F0))
            XCTFail("expected unknownOutput")
        } catch AirPlayEngineError.unknownOutput {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - Teardown with an op in flight: stop() resumes the continuation.
    //
    // REGRESSION (toggle-spam session 2026-07-17): on app quit with an op still in
    // flight the process logged "SWIFT TASK CONTINUATION MISUSE: startOp(id:issue:)
    // leaked its continuation!" and then HUNG — teardown awaited a completion the
    // dispatcher would never deliver (the hook was already unset), because
    // uninstall() dropped the armed waiter instead of resuming it. The fix: stop()'s
    // completion-registry uninstall CANCELS every armed waiter, resuming its
    // continuation (throwing) so nothing leaks and stop() returns promptly.
    func testStopResumesInFlightOpContinuation() async throws {
        let id = OutputID(rawValue: 0xDEAD_0001)
        makeRegistryDevice(id: id.rawValue)

        let engine = AirPlayEngine()
        // N=1: the op arms a real waiter and suspends awaiting a completion we
        // deliberately NEVER fire — only stop() can resolve it.
        await engine.enterHeadlessTestMode(issue: { _, _ in 1 })
        await engine.registerKnownOutputForTest(id)

        // Launch addOutput; it will arm a waiter and suspend.
        let opTask = Task { () -> Error? in
            do { try await engine.addOutput(id); return nil }
            catch { return error }
        }

        // Wait until the waiter is armed (the op has suspended), WITHOUT firing a
        // completion.
        for _ in 0..<200 {
            if let dev = outputs_device_get(id.rawValue), outputs_callback_get(dev) != nil { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        // Tear down with the op in flight. This must resume the awaiting
        // continuation (throwing) — not leak it — and complete promptly.
        let stopDone = Task { await engine.stop() }
        let stopResult = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask { await stopDone.value; return true }
            group.addTask {
                try? await Task.sleep(nanoseconds: 3_000_000_000) // 3s watchdog
                return false
            }
            let first = await group.next()!
            group.cancelAll()
            return first
        }
        XCTAssertTrue(stopResult, "stop() must not hang when an op is in flight")

        // The in-flight op resumed by THROWING (cancellation), not by leaking.
        let opError = await opTask.value
        XCTAssertNotNil(opError, "the in-flight op continuation must be resumed (throwing) on teardown, not leaked")
        if let opError {
            XCTAssertEqual(opError as? AirPlayEngineError, .engineNotRunning,
                           "teardown resumes the in-flight op with a cancellation-style error")
        }
    }

    // MARK: - internal helper: fire the synthetic completion once the waiter is
    // armed. The wrapper arms synchronously inside startOp's continuation body
    // (headless mode runs inline), so the slot exists by the time the awaiting
    // op has suspended. We poll the registry briefly for the armed slot to avoid
    // depending on scheduling order.

    private func fireWhenArmed(id: UInt64, state: output_device_state) async throws {
        // Find the armed callback slot for this device by scanning: the wrapper
        // uses outputs_callback_add which fills the first free slot. We identify
        // it by the device having a registered callback. Since there is exactly
        // one op in flight per test, slot search by "has cb" is unambiguous.
        for _ in 0..<200 {
            if let dev = outputs_device_get(id), outputs_callback_get(dev) != nil {
                // Slot index isn't directly exposed; re-derive by firing each
                // in-range id until one is ready. But the wrapper always uses the
                // lowest free slot (0 for a single op after reset), so fire 0.
                fireCompletion(id: id, cbIdSlot: 0, state: state)
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000) // 1ms
        }
        XCTFail("waiter was never armed for device \(String(format: "0x%llX", id))")
    }
}
