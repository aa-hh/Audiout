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

import XCTest
@testable import AirPlayEngine
import CAirPlayEngine

final class MultiStreamWriteRoutingTests: XCTestCase {

    private func defaultQuality() -> media_quality {
        media_quality(sample_rate: 44100, bits_per_sample: 16, channels: 2, bit_rate: 0)
    }

    /// Interleaved S16LE stereo PCM of exactly `samples` sample-frames. Content
    /// doesn't matter for these tests (only the SAMPLE COUNT that reaches
    /// `input_buffer_samples`), so every byte is a fixed filler value.
    private func pcm(samples: Int, fill: UInt8 = 0xAB) -> Data {
        Data(repeating: fill, count: samples * 2 /* channels */ * 2 /* bytes/sample */)
    }

    override func setUp() {
        super.setUp()
        airplay_test_master_sessions_reset()
        outputs_dispatcher_reset()
        drainRegistry()
    }

    override func tearDown() {
        airplay_test_master_sessions_reset()
        outputs_dispatcher_reset()
        drainRegistry()
        super.tearDown()
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
        XCTFail("waiter for callbackId 0 never armed")
    }

    // MARK: - write(pcm:streamId:pts:): no cross-talk between two streams.

    /// The core T2 property: two SEPARATE `write(pcm:streamId:pts:)` calls, one
    /// per stream_id, each only grow the input_buffer of THEIR OWN master
    /// session. Before T2 (single-stream `write`, no per-call stream_id) this
    /// wasn't even expressible; T1 fixed the C fan-out guard this test drives.
    func testDistinctStreamIdWritesDoNotCrossTalk() async {
        var q = defaultQuality()
        let amsA = airplay_test_master_session_make(1, &q, false)
        let amsB = airplay_test_master_session_make(2, &q, false)
        XCTAssertNotNil(amsA)
        XCTAssertNotNil(amsB)

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

        XCTAssertEqual(airplay_test_master_session_input_buffer_samples(amsA), 100,
            "stream 1's write must land in stream 1's master session, and ONLY there")
        XCTAssertEqual(airplay_test_master_session_input_buffer_samples(amsB), 40,
            "stream 2's write must land in stream 2's master session, and ONLY there — " +
            "a regression here would mean the Swift write API silently reintroduced cross-talk")
    }

    /// A second write on the SAME stream_id accumulates onto the same master
    /// session's input_buffer (proves the guard is a positive match, not just
    /// an exclusion of the other stream).
    func testRepeatedWritesOnSameStreamAccumulate() async {
        var q = defaultQuality()
        let ams = airplay_test_master_session_make(9, &q, false)
        XCTAssertNotNil(ams)

        let engine = AirPlayEngine()
        await engine.enterHeadlessTestMode()
        let pts = timespec(tv_sec: 0, tv_nsec: 0)

        engine.write(pcm: pcm(samples: 30), streamId: 9, pts: pts)
        engine.write(pcm: pcm(samples: 20), streamId: 9, pts: pts)
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(airplay_test_master_session_input_buffer_samples(ams), 50)
    }

    // MARK: - write(pcm:pts:) legacy overload == stream_id 0, unchanged.

    func testLegacyWriteDefaultsToStreamZeroAndDoesNotLeakToOtherStreams() async {
        var q = defaultQuality()
        let ams0 = airplay_test_master_session_make(0, &q, false)
        let ams7 = airplay_test_master_session_make(7, &q, false)
        XCTAssertNotNil(ams0)
        XCTAssertNotNil(ams7)

        let engine = AirPlayEngine()
        await engine.enterHeadlessTestMode()
        let pts = timespec(tv_sec: 0, tv_nsec: 0)

        // The ORIGINAL, pre-T2 call shape — must still compile and behave as
        // stream_id 0 with no source change required at any existing call site.
        engine.write(pcm: pcm(samples: 60), pts: pts)
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(airplay_test_master_session_input_buffer_samples(ams0), 60)
        XCTAssertEqual(airplay_test_master_session_input_buffer_samples(ams7), 0,
            "the legacy write(pcm:pts:) overload must never leak onto a non-zero stream")
    }

    // MARK: - write(streams:pts:): N entries in ONE call, still no cross-talk.

    /// The batched/phase-aligned primitive T5's mixer is expected to prefer:
    /// several streams' PCM in one call, sharing one `output_buffer`/pts. Each
    /// entry must still only reach its own master session.
    func testBatchedWriteRoutesEachEntryToItsOwnMasterSessionInOneCall() async {
        var q = defaultQuality()
        let ams1 = airplay_test_master_session_make(1, &q, false)
        let ams2 = airplay_test_master_session_make(2, &q, false)
        let ams3 = airplay_test_master_session_make(3, &q, false)
        XCTAssertNotNil(ams1); XCTAssertNotNil(ams2); XCTAssertNotNil(ams3)

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

        XCTAssertEqual(airplay_test_master_session_input_buffer_samples(ams1), 11)
        XCTAssertEqual(airplay_test_master_session_input_buffer_samples(ams2), 22)
        XCTAssertEqual(airplay_test_master_session_input_buffer_samples(ams3), 33)
    }

    /// A write for a stream_id with NO live master session is simply dropped by
    /// the C fan-out (no matching `ams` to accumulate into) — must not crash or
    /// spuriously feed an unrelated session.
    func testWriteForUnknownStreamIdIsDroppedNotMisrouted() async {
        var q = defaultQuality()
        let ams1 = airplay_test_master_session_make(1, &q, false)
        XCTAssertNotNil(ams1)

        let engine = AirPlayEngine()
        await engine.enterHeadlessTestMode()
        let pts = timespec(tv_sec: 0, tv_nsec: 0)

        engine.write(pcm: pcm(samples: 15), streamId: 404, pts: pts) // no ams for 404
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(airplay_test_master_session_input_buffer_samples(ams1), 0,
            "a write for an unregistered stream_id must not misroute onto an unrelated master session")
    }

    // MARK: - addOutput(_:streamId:): binds device->stream_id BEFORE device_start.

    /// `session_make` (T1) reads `device->stream_id` exactly once, at
    /// session-creation time, and passes it to `master_session_make`. This
    /// proves the Swift `addOutput(_:streamId:)` writes that field before the
    /// backend op is issued, so a real `device_start` would bind to the right
    /// master session.
    func testAddOutputWithStreamIdBindsDeviceBeforeStart() async throws {
        let id = OutputID(rawValue: 0xC001)
        makeRegistryDevice(id: id.rawValue)
        guard let device = outputs_device_get(id.rawValue) else {
            return XCTFail("device must exist in the registry")
        }
        XCTAssertEqual(device.pointee.stream_id, 0, "freshly registered device starts at the default stream")

        let engine = AirPlayEngine()
        await engine.enterHeadlessTestMode(issue: { _, _ in 1 })
        await engine.registerKnownOutputForTest(id)

        async let op: Void = engine.addOutput(id, streamId: 42)
        try await fireWhenArmed(id: id.rawValue, state: OUTPUT_STATE_STREAMING, engine: engine)
        try await op

        XCTAssertEqual(device.pointee.stream_id, 42,
            "addOutput(_:streamId:) must set device->stream_id before device_start runs")
    }

    /// The legacy `addOutput(_:)` overload is exactly `streamId: 0` — a device
    /// added the old way is never accidentally routed onto a non-zero stream.
    func testLegacyAddOutputLeavesStreamIdZero() async throws {
        let id = OutputID(rawValue: 0xC002)
        makeRegistryDevice(id: id.rawValue)
        guard let device = outputs_device_get(id.rawValue) else {
            return XCTFail("device must exist in the registry")
        }

        let engine = AirPlayEngine()
        await engine.enterHeadlessTestMode(issue: { _, _ in 1 })
        await engine.registerKnownOutputForTest(id)

        async let op: Void = engine.addOutput(id) // original, pre-T2 call shape
        try await fireWhenArmed(id: id.rawValue, state: OUTPUT_STATE_STREAMING, engine: engine)
        try await op

        XCTAssertEqual(device.pointee.stream_id, 0)
    }
}
