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

import Foundation
import Testing
@testable import AirPlayEngine
import CAirPlayEngine

// `shims/outputs.c`'s device/callback registry is process-global C state, so
// this suite nests into the package's one `.serialized` parent (see
// SerializedEngineStateSuite.swift). Do NOT repeat `.serialized` here.
extension SerializedEngineState {

    // The dispatcher reset + registry drain fold into `init` alone
    // (cookbook §11(a): symmetric setup/teardown) — no `deinit` needed, so
    // this stays a `struct`.
    @Suite struct AirPlayEngineAPITests {

        init() {
            outputs_dispatcher_reset()
            drainRegistry()
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

        @Test func addOutputStreamingSucceeds() async throws {
            let id = OutputID(rawValue: 0xA1)
            makeRegistryDevice(id: id.rawValue)

            let engine = AirPlayEngine()
            // Headless: issue returns N=1 (one deferred completion promised), no HW.
            await engine.enterHeadlessTestMode(issue: { _, _ in 1 })
            await engine.registerKnownOutputForTest(id)

            // Drive addOutput and, concurrently, fire the completion once the waiter
            // is armed. The dispatcher uses slot 0 for the first armed callback.
            async let op: Void = engine.addOutput(id)
            try await fireWhenArmed(id: id.rawValue, state: OUTPUT_STATE_STREAMING, engine: engine)
            try await op

            let state = await engine.stateOf(id)
            #expect(state == .streaming)
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
        @Test func addOutputConnectedSucceeds() async throws {
            let id = OutputID(rawValue: 0xA1C0)
            makeRegistryDevice(id: id.rawValue)

            let engine = AirPlayEngine()
            await engine.enterHeadlessTestMode(issue: { _, _ in 1 })
            await engine.registerKnownOutputForTest(id)

            async let op: Void = engine.addOutput(id)
            try await fireWhenArmed(id: id.rawValue, state: OUTPUT_STATE_CONNECTED, engine: engine)
            try await op // must NOT hang: CONNECTED is the terminal for AP2 device_start

            let state = await engine.stateOf(id)
            #expect(state == .connected)
        }

        // MARK: - Terminal-state classification: the exact set the vendored sender can
        // report via a single callback_id-spending outputs_cb. Locks in the
        // 2026-07-16 fix (CONNECTED terminal) and guards against a regression that
        // would re-drop the AP2 device_start completion.
        //
        // STARTUP (INFO…RECORD progress) is the ONLY non-terminal — and in the
        // vendored sender it is never even emitted for device_start (session_status is
        // only called at sequence success/failure), so this guard is defensive.
        @Test func outputStateTerminalClassification() {
            #expect(OutputState.connected.isTerminal,
                    "CONNECTED is the AP2 device_start terminal (regression: 2026-07-16 hang)")
            #expect(OutputState.streaming.isTerminal)
            #expect(OutputState.stopped.isTerminal)
            #expect(OutputState.failed.isTerminal)
            #expect(OutputState.passwordRequired.isTerminal)
            #expect(!OutputState.startup.isTerminal, "STARTUP is intermediate progress")
        }

        // MARK: - addOutput: FAILED terminal state throws sessionFailed.

        @Test func addOutputFailedThrows() async throws {
            let id = OutputID(rawValue: 0xA2)
            makeRegistryDevice(id: id.rawValue)
            let engine = AirPlayEngine()
            await engine.enterHeadlessTestMode(issue: { _, _ in 1 })
            await engine.registerKnownOutputForTest(id)

            async let op: Void = engine.addOutput(id)
            try await fireWhenArmed(id: id.rawValue, state: OUTPUT_STATE_FAILED, engine: engine)

            do {
                try await op
                Issue.record("expected sessionFailed")
            } catch AirPlayEngineError.sessionFailed {
                // expected
            }
        }

        // MARK: - addOutput: PASSWORD terminal state throws passwordRequired.

        @Test func addOutputPasswordThrows() async throws {
            let id = OutputID(rawValue: 0xA3)
            makeRegistryDevice(id: id.rawValue)
            let engine = AirPlayEngine()
            await engine.enterHeadlessTestMode(issue: { _, _ in 1 })
            await engine.registerKnownOutputForTest(id)

            async let op: Void = engine.addOutput(id)
            try await fireWhenArmed(id: id.rawValue, state: OUTPUT_STATE_PASSWORD, engine: engine)

            do {
                try await op
                Issue.record("expected passwordRequired")
            } catch AirPlayEngineError.passwordRequired {
                // expected
            }
        }

        // MARK: - setVolume: awaits a completion, records volume on the C device.

        @Test func setVolumeDrivesDeviceAndCompletes() async throws {
            let id = OutputID(rawValue: 0xB1)
            makeRegistryDevice(id: id.rawValue)

            let engine = AirPlayEngine()
            await engine.enterHeadlessTestMode(issue: { device, _ in
                // airplay.c's volume model treats device->volume as a 0...100 PERCENT
                // (airplay_set_volume_one / airplay_volume_from_pct map 0..100 -> -30..0
                // dB). The normalized 0.5 must therefore land on 50, NOT be scaled by the
                // uninitialized `max_volume` field (which pinned every request to 0 => the
                // -30 dB "inaudible" floor). See applyVolumeOnDevice.
                #expect(device.pointee.volume == 50)
                return 1
            })
            await engine.registerKnownOutputForTest(id)

            async let op: Void = engine.setVolume(id, 0.5)
            try await fireWhenArmed(id: id.rawValue, state: OUTPUT_STATE_STREAMING, engine: engine)
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
        @Test func setVolumeMapsToPercentIgnoringUninitializedMaxVolume() async throws {
            let cases: [(Double, Int32)] = [(0.0, 0), (0.4, 40), (0.5, 50), (1.0, 100)]
            for (normalized, expectedPct) in cases {
                outputs_dispatcher_reset(); drainRegistry()
                let id = OutputID(rawValue: 0xB5)
                makeRegistryDevice(id: id.rawValue)
                // Deliberately DO NOT set max_volume: it stays 0 as in production.
                #expect(outputs_device_get(id.rawValue)!.pointee.max_volume == 0)

                let engine = AirPlayEngine()
                await engine.enterHeadlessTestMode(issue: { device, _ in
                    #expect(device.pointee.volume == expectedPct,
                            "normalized \(normalized) must map to \(expectedPct)% (device->volume is a 0..100 percent)")
                    return 1
                })
                await engine.registerKnownOutputForTest(id)

                async let op: Void = engine.setVolume(id, normalized)
                try await fireWhenArmed(id: id.rawValue, state: OUTPUT_STATE_STREAMING, engine: engine)
                try await op
            }
        }

        // MARK: - removeOutput: awaits stop completion.

        @Test func removeOutputCompletes() async throws {
            let id = OutputID(rawValue: 0xB2)
            makeRegistryDevice(id: id.rawValue, state: OUTPUT_STATE_STREAMING)
            let engine = AirPlayEngine()
            await engine.enterHeadlessTestMode(issue: { _, _ in 1 })
            await engine.registerKnownOutputForTest(id, state: .streaming)

            async let op: Void = engine.removeOutput(id)
            try await fireWhenArmed(id: id.rawValue, state: OUTPUT_STATE_STOPPED, engine: engine)
            try await op

            let state = await engine.stateOf(id)
            #expect(state == .stopped)
        }

        // MARK: - N<=0 op never hangs (issue returns 0 -> immediate resolve).

        @Test func zeroCallbackOpResolvesImmediately() async throws {
            let id = OutputID(rawValue: 0xB3)
            makeRegistryDevice(id: id.rawValue, state: OUTPUT_STATE_STREAMING)
            let engine = AirPlayEngine()
            // issue returns 0 -> no completion promised; startOp resolves inline.
            await engine.enterHeadlessTestMode(issue: { _, _ in 0 })
            await engine.registerKnownOutputForTest(id, state: .streaming)

            // Must NOT hang: no synthetic completion fired.
            try await engine.removeOutput(id)
            let state = await engine.stateOf(id)
            #expect(state == .stopped)
        }

        // MARK: - removeOutput with a torn-down (NULL) session must not crash (T5).

        // Regression for the confirmed EXC_BAD_ACCESS SIGSEGV (KERN_INVALID_ADDRESS
        // at 0x8) on thread "com.airplayengine.engine": airplay_device_stop
        // (airplay.c:4271) does `session = device->session; session->callback_id =
        // …` with no NULL check. When a device disappears mid-flight (a per-app
        // route torn down while a removeOutput is in progress) session_cleanup zeroes
        // device->session, yet device->state can still read STREAMING/CONNECTED — so
        // removeOutput's own idempotency check (which reads device->state) waves the
        // op through to issuing device_stop, which then dereferences a NULL session.
        //
        // The fix is a guard inside removeOutput's stop-issue closure:
        //   guard device.pointee.session != nil else { return 0 }
        // Returning <= 0 makes startOp resolve the op as `.stopped` via its N<=0
        // contract instead of calling airplay_device_stop.
        //
        // This test reproduces the exact race: a REAL registry device whose state is
        // STREAMING (so the idempotency check falls through) but whose session is
        // NULL (as session_cleanup would have left it). The headless issue closure
        // mirrors production — same guard, then the SAME real `output_airplay.
        // device_stop` — so it genuinely exercises calling that C entry point against
        // a NULL-session device. Without the guard this call SIGSEGVs and takes down
        // the test process; with it, removeOutput resolves cleanly as `.stopped`.
        @Test func removeOutputWithNullSessionDoesNotCrash() async throws {
            let id = OutputID(rawValue: 0xB4)
            // STREAMING state + (default) NULL session == the mid-flight teardown race.
            makeRegistryDevice(id: id.rawValue, state: OUTPUT_STATE_STREAMING)
            // Belt-and-suspenders: explicitly null the session, as session_cleanup does.
            outputs_device_session_remove(id.rawValue)
            #expect(outputs_device_get(id.rawValue)?.pointee.session == nil,
                    "precondition: the device has a torn-down (NULL) session")

            let engine = AirPlayEngine()
            // Faithful mirror of removeOutput's production stop-issue closure: guard
            // the NULL session, otherwise issue the real device_stop. If the guard is
            // ever dropped, this dereferences a NULL session and crashes the process.
            await engine.enterHeadlessTestMode(issue: { device, cbId in
                guard let stopFn = output_airplay.device_stop else { return -1 }
                guard device.pointee.session != nil else { return 0 }
                return stopFn(device, cbId)
            })
            await engine.registerKnownOutputForTest(id, state: .streaming)

            // Must neither crash nor hang: the guard short-circuits to the N<=0 path,
            // so no synthetic completion is needed and the op resolves inline.
            try await engine.removeOutput(id)

            let state = await engine.stateOf(id)
            #expect(state == .stopped, "a NULL-session stop resolves as .stopped")
        }

        // MARK: - Guards: unknown output + not-started.

        @Test func unknownOutputThrows() async {
            let engine = AirPlayEngine()
            await engine.enterHeadlessTestMode()
            do {
                try await engine.addOutput(OutputID(rawValue: 0xDEAD))
                Issue.record("expected unknownOutput")
            } catch AirPlayEngineError.unknownOutput {
                // expected
            } catch {
                Issue.record("wrong error: \(error)")
            }
        }

        @Test func notStartedThrows() async {
            // A fresh engine that hasn't started() and isn't in test mode: addOutput
            // must throw engineNotRunning, not hang or crash.
            let engine = AirPlayEngine()
            do {
                try await engine.addOutput(OutputID(rawValue: 0x1))
                Issue.record("expected engineNotRunning")
            } catch AirPlayEngineError.engineNotRunning {
                // expected
            } catch {
                Issue.record("wrong error: \(error)")
            }
        }

        // MARK: - Discovery descriptor -> C registry mapping.

        @Test func discoveryDescriptorMapsDeviceID() async {
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
            #expect(desc.parsedID?.rawValue == 0xAABBCCDDEEFF)

            let engine = AirPlayEngine()
            // Note: airplayengine_feed_device needs the captured callback, which only
            // exists after airplay_init. Without a real init the feed is a no-op that
            // returns -1; we still verify the Swift-side parse + keyval build path
            // doesn't crash and the id parse is correct (the registry insertion is
            // covered end-to-end only in the gated live run).
            let mappedID = await engine.feedDescriptorForTest(desc)
            #expect(mappedID?.rawValue == 0xAABBCCDDEEFF)
        }

        @Test func descriptorDefaultsToAirplayKind() {
            // Existing (pre-RAOP) call sites don't pass `kind`; they must still
            // route to output_airplay.
            let desc = DeviceDescriptor(
                name: "Living Room", address: "192.168.1.50", family: .ipv4, port: 7000,
                txtRecord: ["deviceid": "AA:BB:CC:DD:EE:FF"]
            )
            #expect(desc.kind == .airplay)
        }

        @Test func raopDescriptorMapsDeviceIDAndFeedsRaopBackend() async {
            // Same shape as discoveryDescriptorMapsDeviceID, but for an AP1/
            // RAOP descriptor (kind: .raop) — routed to airplayengine_feed_raop_device
            // instead of airplayengine_feed_device (T6).
            let desc = DeviceDescriptor(
                name: "Kitchen",
                hostname: "kitchen.local",
                address: "192.168.1.51",
                family: .ipv4,
                port: 5000,
                kind: .raop,
                txtRecord: ["deviceid": "11:22:33:44:55:66"]
            )
            #expect(desc.kind == .raop)
            #expect(desc.parsedID?.rawValue == 0x112233445566)

            let engine = AirPlayEngine()
            // Without a real raop_init the captured raop_device_cb doesn't exist yet,
            // so the feed is a no-op that returns -1 — same caveat as the AP2 test
            // above; this proves the Swift-side parse/dispatch path (routing by
            // `kind`) doesn't crash and the id still resolves correctly. Real
            // registry-under-output_raop insertion is covered end-to-end only in
            // the gated live run.
            let mappedID = await engine.feedDescriptorForTest(desc)
            #expect(mappedID?.rawValue == 0x112233445566)
        }

        @Test func descriptorWithoutDeviceIDIsInvalid() {
            let desc = DeviceDescriptor(
                name: "NoID", address: "10.0.0.1", family: .ipv4, port: 7000,
                txtRecord: ["features": "0x1"]
            )
            #expect(desc.parsedID == nil)
        }

        // MARK: - hashClientName is stable + non-zero (libhash seed), and differs
        // per-install (T-ENG-LIBHASH-1, first-light backlog #5.1).

        @Test func clientNameHashStableNonZero() {
            let a = AirPlayEngine.hashClientName("My Speakers", seed: 0x1111)
            let b = AirPlayEngine.hashClientName("My Speakers", seed: 0x1111)
            let c = AirPlayEngine.hashClientName("Other", seed: 0x1111)
            #expect(a == b)
            #expect(a != c)
            #expect(a != 0)
        }

        @Test func clientNameHashDiffersPerInstallSeed() {
            // Same clientName, different per-install seed -> different, non-zero
            // libhash — without the per-install seed, two installs on one LAN
            // advertising the same clientName hash identically.
            let seedA: UInt64 = 0xdead_beef_1234_5678
            let seedB: UInt64 = 0x1357_9bdf_0246_8ace
            let a = AirPlayEngine.hashClientName("My Speakers", seed: seedA)
            let b = AirPlayEngine.hashClientName("My Speakers", seed: seedB)
            #expect(a != b)
            #expect(a != 0)
            #expect(b != 0)
        }

        @Test func clientNameHashNonZeroForZeroSeed() {
            // Even a degenerate all-zero seed must not produce a zero libhash —
            // the C side asserts a non-zero seed.
            #expect(AirPlayEngine.hashClientName("", seed: 0) != 0)
            #expect(AirPlayEngine.hashClientName("X", seed: 0) != 0)
        }

        // MARK: - device_start/stop idempotency guards (first-light hardening #5e).
        //
        // Re-adding an output that is already streaming/connected, or re-stopping one
        // that is already stopped, must be a no-op SUCCESS that does NOT re-issue the
        // backend op. We prove "no op issued" by NOT firing any synthetic completion:
        // if the guard failed and the wrapper armed a waiter, the awaited call would
        // hang (no completion arrives) and the test would time out. Reaching the
        // assertion below means the guard short-circuited before arming.

        @Test func addOutputIsIdempotentWhenAlreadyStreaming() async throws {
            let id = OutputID(rawValue: 0xC1)
            makeRegistryDevice(id: id.rawValue, state: OUTPUT_STATE_STREAMING)
            let engine = AirPlayEngine()
            // issue would FAIL the test if ever called: the guard must skip it.
            await engine.enterHeadlessTestMode(issue: { _, _ in
                Issue.record("device_start must not be issued for an already-streaming output")
                return 1
            })
            await engine.registerKnownOutputForTest(id, state: .streaming)

            // No fireWhenArmed: a working guard resolves immediately with no waiter.
            try await engine.addOutput(id)
            let state = await engine.stateOf(id)
            #expect(state == .streaming, "state unchanged by the no-op re-add")
        }

        @Test func addOutputIsIdempotentWhenAlreadyConnected() async throws {
            let id = OutputID(rawValue: 0xC1C0)
            makeRegistryDevice(id: id.rawValue, state: OUTPUT_STATE_CONNECTED)
            let engine = AirPlayEngine()
            await engine.enterHeadlessTestMode(issue: { _, _ in
                Issue.record("device_start must not be issued for an already-connected output")
                return 1
            })
            await engine.registerKnownOutputForTest(id, state: .connected)

            try await engine.addOutput(id)
            let state = await engine.stateOf(id)
            #expect(state == .connected)
        }

        // REGRESSION (first-light hardening #5 fix): the idempotency guard must read
        // the LIVE C device state, not a stale Swift cache. Scenario: addOutput
        // resolved CONNECTED (cache = .connected), then the receiver dropped RTSP and
        // an out-of-band outputs_cb(-1, FAILED) flipped device->state to FAILED. A
        // recovery addOutput MUST re-issue device_start — a cache-only guard would
        // see .connected and silently no-op, and audio would never resume.
        @Test func addOutputReissuesWhenLiveStateFailedDespiteStaleConnectedCache() async throws {
            let id = OutputID(rawValue: 0xC1FA)
            // Live C state is FAILED (receiver dropped), even though the cache below
            // still reads .connected (the state stream hasn't reconciled it yet).
            makeRegistryDevice(id: id.rawValue, state: OUTPUT_STATE_FAILED)
            let engine = AirPlayEngine()
            var reissued = false
            await engine.enterHeadlessTestMode(issue: { _, _ in reissued = true; return 1 })
            await engine.registerKnownOutputForTest(id, state: .connected) // stale cache

            async let op: Void = engine.addOutput(id)
            try await fireWhenArmed(id: id.rawValue, state: OUTPUT_STATE_CONNECTED, engine: engine)
            try await op

            #expect(reissued, "a live-FAILED session must re-issue device_start despite a stale .connected cache")
            let state = await engine.stateOf(id)
            #expect(state == .connected, "the re-issued session resolves CONNECTED again")
        }

        // REGRESSION (out-of-band FAILED must update device->state): the test above
        // seeds device->state=FAILED directly, which simulates a write the real
        // out-of-band path must perform. This one drives the ACTUAL path end to end:
        // a device is CONNECTED (as after addOutput resolved), then the receiver
        // drops RTSP and airplay.c's session_status fires outputs_cb(-1, id, FAILED)
        // — the spent-id, out-of-band report. The drain routes it through the state
        // ring (never a completion). It MUST also write device->state = FAILED, or
        // liveDeviceState stays pinned at CONNECTED and the recovery re-add no-ops.
        @Test func outOfBandFailedUpdatesDeviceStateAndReAddReissues() async throws {
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
            #expect(live != nil)
            #expect(live?.pointee.state == OUTPUT_STATE_FAILED,
                    "out-of-band FAILED must update device->state, not just the state hook")

            // End-to-end: a recovery addOutput now reads the live FAILED and re-issues
            // device_start, even though the Swift cache still reads .connected.
            let engine = AirPlayEngine()
            var reissued = false
            await engine.enterHeadlessTestMode(issue: { _, _ in reissued = true; return 1 })
            await engine.registerKnownOutputForTest(id, state: .connected) // stale cache

            async let op: Void = engine.addOutput(id)
            try await fireWhenArmed(id: id.rawValue, state: OUTPUT_STATE_CONNECTED, engine: engine)
            try await op

            #expect(reissued, "an out-of-band FAILED must let a recovery addOutput re-issue device_start")
        }

        @Test func removeOutputIsIdempotentWhenAlreadyStopped() async throws {
            let id = OutputID(rawValue: 0xC2)
            makeRegistryDevice(id: id.rawValue)
            let engine = AirPlayEngine()
            await engine.enterHeadlessTestMode(issue: { _, _ in
                Issue.record("device_stop must not be issued for an already-stopped output")
                return 1
            })
            await engine.registerKnownOutputForTest(id, state: .stopped)

            try await engine.removeOutput(id)
            let state = await engine.stateOf(id)
            #expect(state == .stopped)
        }

        // A guard must NOT swallow a legitimate stop: an active (streaming) output
        // still issues device_stop and resolves through the real completion path.
        @Test func removeOutputStillStopsActiveOutput() async throws {
            let id = OutputID(rawValue: 0xC3)
            makeRegistryDevice(id: id.rawValue, state: OUTPUT_STATE_STREAMING)
            let engine = AirPlayEngine()
            var issued = false
            await engine.enterHeadlessTestMode(issue: { _, _ in issued = true; return 1 })
            await engine.registerKnownOutputForTest(id, state: .streaming)

            async let op: Void = engine.removeOutput(id)
            try await fireWhenArmed(id: id.rawValue, state: OUTPUT_STATE_STOPPED, engine: engine)
            try await op

            #expect(issued, "device_stop must be issued for an active output")
            let state = await engine.stateOf(id)
            #expect(state == .stopped)
        }

        // MARK: - device_flush re-anchor (F-REANCHOR, 2026-07-26).
        //
        // flushOutput WIRES the vendored device_flush: an RTSP FLUSH that re-anchors
        // the receiver's timeline WITHOUT tearing down the session (unlike
        // removeOutput). It makes NO device->state pre-guard (that field diverges
        // from the session->state the vendored flush acts on — the mismatch that let
        // a no-op masquerade as success); instead it returns whether a flush was
        // ACTUALLY issued (the vendored call returned n>0), which the caller uses to
        // decide whether the teardown fallback is still needed. These tests drive the
        // issue count via the headless override.

        @Test func flushOutputReturnsTrueAndKeepsSessionWhenFlushIssues() async throws {
            let id = OutputID(rawValue: 0xF1)
            makeRegistryDevice(id: id.rawValue, state: OUTPUT_STATE_STREAMING)
            let engine = AirPlayEngine()
            await engine.enterHeadlessTestMode(issue: { _, _ in 1 })  // vendored flush issues one op
            await engine.registerKnownOutputForTest(id, state: .streaming)

            async let op: Bool = engine.flushOutput(id)
            // Re-anchor keeps the session STREAMING — the completion is NOT a stop.
            try await fireWhenArmed(id: id.rawValue, state: OUTPUT_STATE_STREAMING, engine: engine)
            let issued = try await op

            #expect(issued, "a flush that issued (n>0) must report true")
            let state = await engine.stateOf(id)
            #expect(state == .streaming, "flush must re-anchor in place, never tear the session down")
        }

        /// The load-bearing discriminator: when the vendored flush NO-OPs (returns 0
        /// — device not STREAMING / session gone), flushOutput must return FALSE and
        /// resolve immediately (no hang), so the caller falls back to a real teardown
        /// instead of mistaking the no-op for a successful recovery.
        @Test func flushOutputReturnsFalseWhenVendoredFlushNoOps() async throws {
            let id = OutputID(rawValue: 0xF2)
            makeRegistryDevice(id: id.rawValue, state: OUTPUT_STATE_STOPPED)
            let engine = AirPlayEngine()
            await engine.enterHeadlessTestMode(issue: { _, _ in 0 })  // vendored no-op
            await engine.registerKnownOutputForTest(id, state: .connected)

            // Must NOT hang (n<=0 resolves inline) and must report "did not flush".
            let issued = try await engine.flushOutput(id)
            #expect(!issued, "a no-op flush (n==0) must report false so the caller tears down")
        }

        @Test func flushOutputRejectsUnknownOutput() async {
            let engine = AirPlayEngine()
            await engine.enterHeadlessTestMode()
            do {
                try await engine.flushOutput(OutputID(rawValue: 0xF0F0))
                Issue.record("expected unknownOutput")
            } catch AirPlayEngineError.unknownOutput {
                // expected
            } catch {
                Issue.record("wrong error: \(error)")
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
        @Test func stopResumesInFlightOpContinuation() async throws {
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
            #expect(stopResult, "stop() must not hang when an op is in flight")

            // The in-flight op resumed by THROWING (cancellation), not by leaking.
            let opError = await opTask.value
            #expect(opError != nil, "the in-flight op continuation must be resumed (throwing) on teardown, not leaked")
            if let opError {
                #expect(opError as? AirPlayEngineError == .engineNotRunning,
                        "teardown resumes the in-flight op with a cancellation-style error")
            }
        }

        // MARK: - Op stalls mid-run: the timeout resumes the continuation (throwing),
        // it does NOT leak.
        //
        // REGRESSION (toggle-spam session 2026-07-17): /tmp/app-native.log showed 177
        // "SWIFT TASK CONTINUATION MISUSE: startOp(id:issue:) leaked its continuation!"
        // When a receiver's media/PTP path stalled mid-op (a bad IPv6 link-local
        // address in that session, but ANY mid-op drop does it) the promised deferred
        // completion never fired, so the awaiting continuation leaked forever — and
        // the earlier stop()-only cancellation (stopResumesInFlightOpContinuation)
        // does NOT cover a stall during NORMAL running (the app keeps running; the op
        // just leaks). This drives exactly that: arm a real waiter, NEVER deliver its
        // completion, and assert the awaited call returns by THROWING `.opTimedOut`
        // within the (short, injected) timeout — and that no residual waiter is left.
        @Test func stalledOpTimesOutInsteadOfLeaking() async throws {
            let id = OutputID(rawValue: 0xDEAD_0002)
            makeRegistryDevice(id: id.rawValue)

            let engine = AirPlayEngine()
            // N=1 arms a real waiter; a short injected timeout keeps the test fast.
            // We deliberately NEVER fire a completion — only the timeout can resolve it.
            await engine.enterHeadlessTestMode(issue: { _, _ in 1 }, opTimeout: 0.2)
            await engine.registerKnownOutputForTest(id)

            let start = Date()
            do {
                try await engine.addOutput(id)
                Issue.record("a stalled op must throw opTimedOut, not resolve or leak")
            } catch AirPlayEngineError.opTimedOut {
                // expected: the continuation was resumed (throwing), not leaked.
            } catch {
                Issue.record("wrong error: \(error)")
            }
            // Sanity: it resolved via the timeout window, not instantly.
            #expect(Date().timeIntervalSince(start) >= 0.15,
                    "should resolve at the timeout, not immediately")

            // No residual waiter: the timeout removed it from the registry under the
            // same lock deliver/cancel use, so exactly one of {deliver, cancel,
            // timeout} resolved this op. `knownOutputs` is unchanged because the throw
            // happened before addOutput's `knownOutputs[id] = terminal` assignment —
            // i.e. the op never resolved a state, it threw.
            let state = await engine.stateOf(id)
            #expect(state == .stopped, "a timed-out addOutput throws before recording any terminal state")

            // Tear down cleanly so the (removed) waiter and the process-wide registry
            // don't leak into the next test.
            await engine.stop()
        }

        // MARK: - Normal completion BEFORE the timeout still succeeds and does NOT
        // later double-resume when the (now-cancelled) timeout deadline passes.
        //
        // The complement to the leak test: a real completion arriving inside the
        // timeout window wins the race, cancels the timer, and resolves normally. We
        // then wait PAST the original deadline to prove the cancelled timer never
        // fires a second (double) resume.
        @Test func completionBeforeTimeoutSucceedsAndDoesNotDoubleResume() async throws {
            let id = OutputID(rawValue: 0xDEAD_0003)
            makeRegistryDevice(id: id.rawValue)

            let engine = AirPlayEngine()
            await engine.enterHeadlessTestMode(issue: { _, _ in 1 }, opTimeout: 0.3)
            await engine.registerKnownOutputForTest(id)

            // Fire the real completion well within the 0.3s window: it must win.
            async let op: Void = engine.addOutput(id)
            try await fireWhenArmed(id: id.rawValue, state: OUTPUT_STATE_STREAMING, engine: engine)
            try await op // resolves normally (no throw)

            let state = await engine.stateOf(id)
            #expect(state == .streaming)

            // Wait past the ORIGINAL timeout deadline. If the timer weren't cancelled
            // on delivery it would fire now against an already-resumed continuation
            // and trap the process. Reaching the assertion means it stayed cancelled.
            try await Task.sleep(nanoseconds: 400_000_000) // 0.4s > 0.3s deadline
            let stillStreaming = await engine.stateOf(id)
            #expect(stillStreaming == .streaming,
                    "a delivered op must not be disturbed by the (cancelled) timeout")
        }

        // MARK: - internal helper: fire the synthetic completion once the waiter is
        // armed. The wrapper arms synchronously inside startOp's continuation body
        // (headless mode runs inline), so the slot exists by the time the awaiting
        // op has suspended. We poll the registry briefly for the armed slot to avoid
        // depending on scheduling order.

        private func fireWhenArmed(
            id: UInt64,
            state: output_device_state,
            engine: AirPlayEngine
        ) async throws {
            // Fire only once the REGISTRY waiter is armed, not merely once the C
            // callback slot is filled. `startOp` does `outputs_callback_add` (which
            // makes `outputs_callback_get` non-nil) BEFORE `completions.arm`, so a
            // helper that gated on the C callback alone could fire into that window —
            // the completion would drain to `CompletionRegistry.deliver` with no
            // waiter, be dropped (and the slot cleared), and the op would then hang
            // until its timeout (a flaky 12s `opTimedOut` before this fix). The
            // wrapper always uses the lowest free slot (0 for a single op after
            // reset), so we wait for waiter 0 then fire slot 0.
            for _ in 0..<200 {
                if await engine.hasArmedWaiterForTest(callbackId: 0) {
                    fireCompletion(id: id, cbIdSlot: 0, state: state)
                    return
                }
                try await Task.sleep(nanoseconds: 1_000_000) // 1ms
            }
            Issue.record("waiter was never armed for device \(String(format: "0x%llX", id))")
        }
    }
}
