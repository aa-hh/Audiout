// P2b (T2) — per-app multi-stream WRITE routing, at the Swift API boundary.
//
// T1 (MultiStreamMasterSessionTests.swift) proved the C-level primitive: two
// stream_ids at the same quality get two DISTINCT master sessions, keyed
// (stream_id, quality, use_ptp). This file proves the layer T1 didn't touch —
// that content fed through the actual SWIFT write API
// (`AirPlayEngine.write(pcm:streamId:pts:)` / `write(streams:pts:)`) reaches
// ONLY the master session for its own stream_id when it goes through the real
// C fan-out (`airplay_write`, sender/airplay.c), end to end:
//
//   Swift write(pcm:streamId:pts:) -> output_data.stream_id -> airplay_write's
//   `obuf->data[i].stream_id == ams->stream_id` guard -> per-stream
//   input_buffer_samples.
//
// It also proves `addOutput(_:streamId:)` binds a device's `output_device`
// BEFORE `device_start` is issued (the ordering `session_make` needs, since
// it reads `device->stream_id` once at session-creation time).
//
// SCOPE: BUILD + HEADLESS ONLY. No real event loop, no sockets, no PTP
// (all master sessions below use `use_ptp = false`). No RTP packets are ever
// sent: every write below stays well under one packet's worth of samples
// (352 at 44100/16/2, `AIRPLAY_SAMPLES_PER_PACKET`), so `airplay_write`'s
// fan-out only ever appends to `ams->input_buffer` and never reaches
// `packets_send`'s ALAC-encode/RTP path.
//
// Nested under `SerializedEngineState` (migration cookbook §22): this file
// mutates `shims/outputs.c`'s process-global device/callback registry, which
// is only safe one-test-at-a-time now that swift-testing runs tests
// concurrently in one process.

import Foundation
import Testing
@testable import AirPlayEngine
import CAirPlayEngine

extension SerializedEngineState {

    @Suite struct MultiStreamWriteRoutingTests {

        private func defaultQuality() -> media_quality {
            media_quality(sample_rate: 44100, bits_per_sample: 16, channels: 2, bit_rate: 0)
        }

        /// Interleaved S16LE stereo PCM of exactly `samples` sample-frames. Content
        /// doesn't matter for these tests (only the SAMPLE COUNT that reaches
        /// `input_buffer_samples`), so every byte is a fixed filler value.
        private func pcm(samples: Int, fill: UInt8 = 0xAB) -> Data {
            Data(repeating: fill, count: samples * 2 /* channels */ * 2 /* bytes/sample */)
        }

        init() {
            airplay_test_master_sessions_reset()
            outputs_dispatcher_reset()
            drainRegistry()
        }

        // MARK: - registry helpers (mirrors AirPlayEngineAPITests' pattern)

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

        private func drainRegistry() {
            while let head = outputs_list() { outputs_device_remove(head) }
        }

        private func fireCompletion(id: UInt64, cbIdSlot: Int32, state: output_device_state) {
            outputs_cb(cbIdSlot, id, state)
            outputs_cb_deferred_run()
        }

        /// Poll until the waiter for slot 0 is armed (see AirPlayEngineAPITests for
        /// why this can't just fire immediately), then resolve it.
        private func fireWhenArmed(id: UInt64, state: output_device_state, engine: AirPlayEngine) async throws {
            for _ in 0..<200 {
                if await engine.hasArmedWaiterForTest(callbackId: 0) {
                    fireCompletion(id: id, cbIdSlot: 0, state: state)
                    return
                }
                try await Task.sleep(nanoseconds: 1_000_000) // 1ms
            }
            Issue.record("waiter for callbackId 0 never armed")
        }

        // MARK: - write(pcm:streamId:pts:): no cross-talk between two streams.

        /// The core T2 property: two SEPARATE `write(pcm:streamId:pts:)` calls, one
        /// per stream_id, each only grow the input_buffer of THEIR OWN master
        /// session. Before T2 (single-stream `write`, no per-call stream_id) this
        /// wasn't even expressible; T1 fixed the C fan-out guard this test drives.
        @Test func distinctStreamIdWritesDoNotCrossTalk() async {
            var q = defaultQuality()
            let amsA = airplay_test_master_session_make(1, &q, false)
            let amsB = airplay_test_master_session_make(2, &q, false)
            #expect(amsA != nil)
            #expect(amsB != nil)

            let engine = AirPlayEngine()
            await engine.enterHeadlessTestMode()

            let pts = timespec(tv_sec: 0, tv_nsec: 0)
            engine.write(pcm: pcm(samples: 100), streamId: 1, pts: pts)
            engine.write(pcm: pcm(samples: 40), streamId: 2, pts: pts)

            // Give the (headless-inline) write a moment to land — headless mode runs
            // the C call synchronously on the calling thread, but `write` itself is
            // nonisolated/fire-and-forget by contract, so poll briefly rather than
            // assume same-instant visibility.
            try? await Task.sleep(nanoseconds: 20_000_000) // 20ms

            #expect(airplay_test_master_session_input_buffer_samples(amsA) == 100,
                "stream 1's write must land in stream 1's master session, and ONLY there")
            #expect(airplay_test_master_session_input_buffer_samples(amsB) == 40,
                "stream 2's write must land in stream 2's master session, and ONLY there — a regression here would mean the Swift write API silently reintroduced cross-talk")
        }

        /// A second write on the SAME stream_id accumulates onto the same master
        /// session's input_buffer (proves the guard is a positive match, not just
        /// an exclusion of the other stream).
        @Test func repeatedWritesOnSameStreamAccumulate() async {
            var q = defaultQuality()
            let ams = airplay_test_master_session_make(9, &q, false)
            #expect(ams != nil)

            let engine = AirPlayEngine()
            await engine.enterHeadlessTestMode()
            let pts = timespec(tv_sec: 0, tv_nsec: 0)

            engine.write(pcm: pcm(samples: 30), streamId: 9, pts: pts)
            engine.write(pcm: pcm(samples: 20), streamId: 9, pts: pts)
            try? await Task.sleep(nanoseconds: 20_000_000)

            #expect(airplay_test_master_session_input_buffer_samples(ams) == 50)
        }

        // MARK: - write(pcm:pts:) legacy overload == stream_id 0, unchanged.

        @Test func legacyWriteDefaultsToStreamZeroAndDoesNotLeakToOtherStreams() async {
            var q = defaultQuality()
            let ams0 = airplay_test_master_session_make(0, &q, false)
            let ams7 = airplay_test_master_session_make(7, &q, false)
            #expect(ams0 != nil)
            #expect(ams7 != nil)

            let engine = AirPlayEngine()
            await engine.enterHeadlessTestMode()
            let pts = timespec(tv_sec: 0, tv_nsec: 0)

            // The ORIGINAL, pre-T2 call shape — must still compile and behave as
            // stream_id 0 with no source change required at any existing call site.
            engine.write(pcm: pcm(samples: 60), pts: pts)
            try? await Task.sleep(nanoseconds: 20_000_000)

            #expect(airplay_test_master_session_input_buffer_samples(ams0) == 60)
            #expect(airplay_test_master_session_input_buffer_samples(ams7) == 0,
                "the legacy write(pcm:pts:) overload must never leak onto a non-zero stream")
        }

        // MARK: - write(streams:pts:): N entries in ONE call, still no cross-talk.

        /// The batched/phase-aligned primitive T5's mixer is expected to prefer:
        /// several streams' PCM in one call, sharing one `output_buffer`/pts. Each
        /// entry must still only reach its own master session.
        @Test func batchedWriteRoutesEachEntryToItsOwnMasterSessionInOneCall() async {
            var q = defaultQuality()
            let ams1 = airplay_test_master_session_make(1, &q, false)
            let ams2 = airplay_test_master_session_make(2, &q, false)
            let ams3 = airplay_test_master_session_make(3, &q, false)
            #expect(ams1 != nil); #expect(ams2 != nil); #expect(ams3 != nil)

            let engine = AirPlayEngine()
            await engine.enterHeadlessTestMode()
            let pts = timespec(tv_sec: 0, tv_nsec: 0)

            engine.write(
                streams: [
                    (pcm: pcm(samples: 11), streamId: 1),
                    (pcm: pcm(samples: 22), streamId: 2),
                    (pcm: pcm(samples: 33), streamId: 3),
                ],
                pts: pts
            )
            try? await Task.sleep(nanoseconds: 20_000_000)

            #expect(airplay_test_master_session_input_buffer_samples(ams1) == 11)
            #expect(airplay_test_master_session_input_buffer_samples(ams2) == 22)
            #expect(airplay_test_master_session_input_buffer_samples(ams3) == 33)
        }

        /// A write for a stream_id with NO live master session is simply dropped by
        /// the C fan-out (no matching `ams` to accumulate into) — must not crash or
        /// spuriously feed an unrelated session.
        @Test func writeForUnknownStreamIdIsDroppedNotMisrouted() async {
            var q = defaultQuality()
            let ams1 = airplay_test_master_session_make(1, &q, false)
            #expect(ams1 != nil)

            let engine = AirPlayEngine()
            await engine.enterHeadlessTestMode()
            let pts = timespec(tv_sec: 0, tv_nsec: 0)

            engine.write(pcm: pcm(samples: 15), streamId: 404, pts: pts) // no ams for 404
            try? await Task.sleep(nanoseconds: 20_000_000)

            #expect(airplay_test_master_session_input_buffer_samples(ams1) == 0,
                "a write for an unregistered stream_id must not misroute onto an unrelated master session")
        }

        // MARK: - addOutput(_:streamId:): binds device->stream_id BEFORE device_start.

        /// `session_make` (T1) reads `device->stream_id` exactly once, at
        /// session-creation time, and passes it to `master_session_make`. This
        /// proves the Swift `addOutput(_:streamId:)` writes that field before the
        /// backend op is issued, so a real `device_start` would bind to the right
        /// master session.
        @Test func addOutputWithStreamIdBindsDeviceBeforeStart() async throws {
            let id = OutputID(rawValue: 0xC001)
            makeRegistryDevice(id: id.rawValue)
            guard let device = outputs_device_get(id.rawValue) else {
                Issue.record("device must exist in the registry")
                return
            }
            #expect(device.pointee.stream_id == 0, "freshly registered device starts at the default stream")

            let engine = AirPlayEngine()
            await engine.enterHeadlessTestMode(issue: { _, _ in 1 })
            await engine.registerKnownOutputForTest(id)

            async let op: OutputBindResult = engine.addOutput(id, streamId: 42)
            try await fireWhenArmed(id: id.rawValue, state: OUTPUT_STATE_STREAMING, engine: engine)
            #expect(try await op == .bound, "a fresh device really binds — not the already-bound no-op")

            #expect(device.pointee.stream_id == 42,
                "addOutput(_:streamId:) must set device->stream_id before device_start runs")
        }

        /// The legacy `addOutput(_:)` overload is exactly `streamId: 0` — a device
        /// added the old way is never accidentally routed onto a non-zero stream.
        @Test func legacyAddOutputLeavesStreamIdZero() async throws {
            let id = OutputID(rawValue: 0xC002)
            makeRegistryDevice(id: id.rawValue)
            guard let device = outputs_device_get(id.rawValue) else {
                Issue.record("device must exist in the registry")
                return
            }

            let engine = AirPlayEngine()
            await engine.enterHeadlessTestMode(issue: { _, _ in 1 })
            await engine.registerKnownOutputForTest(id)

            async let op: Void = engine.addOutput(id) // original, pre-T2 call shape
            try await fireWhenArmed(id: id.rawValue, state: OUTPUT_STATE_STREAMING, engine: engine)
            try await op

            #expect(device.pointee.stream_id == 0)
        }

        // MARK: - T6 — the already-bound no-op is VISIBLE, and rebinding is possible.
        //
        // Architecture review 2026-07-26, defect B: `addOutput(_:streamId:)` on a
        // device that already had a live session returned a SILENT success while
        // the C session stayed on its old stream. The caller bookkept a bind that
        // never happened, wrote PCM to a stream the device never joined, and the
        // app showed "routed" while being inaudible. These tests pin the three
        // behaviours that make that state expressible and fixable.

        /// Like `fireWhenArmed`, but ALSO moves `device->state` the way a real
        /// backend does before reporting its terminal completion — the shim's
        /// `outputs_cb` only resolves the waiter, it never touches the device, so a
        /// multi-op test (rebind = stop then re-add) would otherwise see a device
        /// still reading STREAMING after its stop completed.
        private func fireBackendTransition(
            id: UInt64,
            to state: output_device_state,
            engine: AirPlayEngine
        ) async throws {
            for _ in 0..<400 {
                if await engine.hasArmedWaiterForTest(callbackId: 0) {
                    outputs_device_get(id)?.pointee.state = state
                    fireCompletion(id: id, cbIdSlot: 0, state: state)
                    return
                }
                try await Task.sleep(nanoseconds: 1_000_000) // 1ms
            }
            Issue.record("waiter for callbackId 0 never armed")
        }

        /// Re-adding a live device on the stream it is ALREADY on (the converge
        /// path that re-adds an unchanged device) still succeeds and still does not
        /// re-issue `device_start` — but now says so: `.alreadyBound(5)` for a
        /// request of 5 is the honest idempotent case a caller can accept as-is.
        @Test func addOutputOnLiveDeviceAtSameStreamReportsAlreadyBound() async throws {
            let id = OutputID(rawValue: 0xC010)
            makeRegistryDevice(id: id.rawValue, state: OUTPUT_STATE_STREAMING)
            guard let device = outputs_device_get(id.rawValue) else {
                Issue.record("device must exist in the registry")
                return
            }
            device.pointee.stream_id = 5

            let engine = AirPlayEngine()
            await engine.enterHeadlessTestMode(issue: { _, _ in 1 })
            await engine.registerKnownOutputForTest(id)

            // No completion is fired anywhere in this test: if the idempotency
            // no-op regressed into a real device_start, this call would arm a
            // waiter and never return.
            let result = try await engine.addOutput(id, streamId: 5)

            #expect(result == .alreadyBound(streamId: 5))
            #expect(device.pointee.stream_id == 5)
            #expect(await engine.boundStreamId(for: id) == 5)
        }

        /// THE DEFECT-B CASE: a live device asked for a DIFFERENT stream. The
        /// session genuinely cannot move (`session_make` read `stream_id` once, at
        /// creation), so the engine still refuses — but it now reports the stream
        /// the device is REALLY on, so the caller can see its assumption was wrong
        /// instead of recording a phantom bind.
        @Test func addOutputOnLiveDeviceAtDifferentStreamReportsTheRealBinding() async throws {
            let id = OutputID(rawValue: 0xC011)
            makeRegistryDevice(id: id.rawValue, state: OUTPUT_STATE_CONNECTED)
            guard let device = outputs_device_get(id.rawValue) else {
                Issue.record("device must exist in the registry")
                return
            }
            device.pointee.stream_id = 0 // whole-system stream

            let engine = AirPlayEngine()
            await engine.enterHeadlessTestMode(issue: { _, _ in 1 })
            await engine.registerKnownOutputForTest(id)

            let result = try await engine.addOutput(id, streamId: 7) // per-app stream

            #expect(result == .alreadyBound(streamId: 0),
                "the caller asked for stream 7 and must be told the session is still on 0 — a bare success here is the silent no-op that makes an app show as routed while inaudible")
            #expect(result != .bound)
            #expect(device.pointee.stream_id == 0,
                "the live session's binding must not be perturbed by a refused add")
            #expect(await engine.boundStreamId(for: id) == 0)
        }

        /// The query half: no live session means nothing is bound, so a caller
        /// knows a plain `addOutput` will bind fresh.
        @Test func boundStreamIdIsNilWhenNoLiveSession() async {
            let id = OutputID(rawValue: 0xC012)
            makeRegistryDevice(id: id.rawValue, state: OUTPUT_STATE_STOPPED)
            outputs_device_get(id.rawValue)?.pointee.stream_id = 3 // stale field, no session

            let engine = AirPlayEngine()
            await engine.enterHeadlessTestMode(issue: { _, _ in 1 })
            await engine.registerKnownOutputForTest(id)

            #expect(await engine.boundStreamId(for: id) == nil,
                "device->stream_id is only meaningful while a session is live")
            // An id the engine never saw is likewise unbound, not a crash.
            #expect(await engine.boundStreamId(for: OutputID(rawValue: 0xDEAD)) == nil)
        }

        /// The write half: `rebindOutput` DOES move a live device — stop, then
        /// re-add bound to the new stream — which is the operation `addOutput`
        /// alone can never perform.
        @Test func rebindOutputMovesALiveSessionToTheNewStream() async throws {
            let id = OutputID(rawValue: 0xC013)
            makeRegistryDevice(id: id.rawValue, state: OUTPUT_STATE_STREAMING)
            guard let device = outputs_device_get(id.rawValue) else {
                Issue.record("device must exist in the registry")
                return
            }
            device.pointee.stream_id = 0

            let engine = AirPlayEngine()
            await engine.enterHeadlessTestMode(issue: { _, _ in 1 })
            await engine.registerKnownOutputForTest(id, state: .streaming)

            async let op: Void = engine.rebindOutput(id, toStreamId: 7)
            try await fireBackendTransition(id: id.rawValue, to: OUTPUT_STATE_STOPPED, engine: engine)
            try await fireBackendTransition(id: id.rawValue, to: OUTPUT_STATE_STREAMING, engine: engine)
            try await op

            #expect(device.pointee.stream_id == 7,
                "rebind must land the new stream_id on the device before the re-add's device_start, or session_make binds the old one again")
            #expect(await engine.boundStreamId(for: id) == 7)
        }

        /// Rebinding a device with NO live session is not an error — the stop half
        /// takes the existing idempotent no-op and the add half binds fresh. This
        /// lets a caller use `rebindOutput` unconditionally.
        @Test func rebindOutputOnIdleDeviceBindsFresh() async throws {
            let id = OutputID(rawValue: 0xC014)
            makeRegistryDevice(id: id.rawValue, state: OUTPUT_STATE_STOPPED)
            guard let device = outputs_device_get(id.rawValue) else {
                Issue.record("device must exist in the registry")
                return
            }

            let engine = AirPlayEngine()
            await engine.enterHeadlessTestMode(issue: { _, _ in 1 })
            await engine.registerKnownOutputForTest(id)

            // Only ONE completion: the stop half no-ops on an already-stopped
            // device (it arms nothing), so the add half is the only armed op.
            async let op: Void = engine.rebindOutput(id, toStreamId: 4)
            try await fireBackendTransition(id: id.rawValue, to: OUTPUT_STATE_STREAMING, engine: engine)
            try await op

            #expect(device.pointee.stream_id == 4)
        }

        /// `rebindOutput` holds the SAME per-`OutputID` `opsInFlight` slot across
        /// both halves (it does not introduce a second serialization mechanism), so
        /// a concurrent `removeOutput` on the same device cannot interleave between
        /// the stop and the re-add. The load-bearing assertion is simply that this
        /// terminates: if `rebindOutput` re-entered `acquireOp` for its inner ops it
        /// would deadlock against its own slot and this test would hang.
        @Test func rebindOutputHoldsOneOpSlotAcrossBothHalves() async throws {
            let id = OutputID(rawValue: 0xC015)
            makeRegistryDevice(id: id.rawValue, state: OUTPUT_STATE_STREAMING)
            let engine = AirPlayEngine()
            await engine.enterHeadlessTestMode(issue: { _, _ in 1 })
            await engine.registerKnownOutputForTest(id, state: .streaming)

            async let rebind: Void = engine.rebindOutput(id, toStreamId: 2)
            try await fireBackendTransition(id: id.rawValue, to: OUTPUT_STATE_STOPPED, engine: engine)
            try await fireBackendTransition(id: id.rawValue, to: OUTPUT_STATE_STREAMING, engine: engine)
            try await rebind

            // The slot is released again afterwards — a follow-up op still runs.
            async let stop: Void = engine.removeOutput(id)
            try await fireBackendTransition(id: id.rawValue, to: OUTPUT_STATE_STOPPED, engine: engine)
            try await stop

            #expect(await engine.boundStreamId(for: id) == nil)
        }
    }
}
