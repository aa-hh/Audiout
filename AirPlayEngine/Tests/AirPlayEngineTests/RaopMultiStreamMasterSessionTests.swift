// P2b (T1 mirror) — RAOP/AirPlay-1 multi-stream master-session keying.
//
// The per-app-routing fix for the RAOP sender hinges on the same property as the
// AirPlay-2 sender (see MultiStreamMasterSessionTests): two devices routed to
// DIFFERENT content streams must get DIFFERENT master sessions (independent RTP
// timeline / ALAC encoder / input buffer), even when they share the one wired
// audio quality (44100/16/2). Before this change raop.c's master_session_make
// deduplicated purely on (quality, encrypt), so every device collapsed onto one
// master session and audio from different app-streams doubled up into a single
// RAOP session — the live-tested pitch-up/crackle bug. This change adds a
// stream_id dimension so the cache key is (stream_id, quality, encrypt), and
// raop_write's fan-out gates ingest on obuf stream_id == master-session stream_id.
//
// These are pure, headless C-seam tests (no receiver, no PTP, no engine thread,
// no sockets). They drive the REAL raop.c master_session_make / raop_write via the
// test-only accessors in shims/engine_bridge.h (raop_test_master_session_* /
// raop_test_write_one), so they exercise the production keying and fan-out, not a
// reimplementation.

import XCTest
@testable import AirPlayEngine
import CAirPlayEngine

final class RaopMultiStreamMasterSessionTests: XCTestCase {

    /// The single quality every RAOP device is wired to (44100/16/2). Both streams
    /// in these tests use it, so stream_id is the ONLY thing that can distinguish
    /// their master sessions.
    private func defaultQuality() -> media_quality {
        media_quality(sample_rate: 44100, bits_per_sample: 16, channels: 2, bit_rate: 0)
    }

    override func setUp() {
        super.setUp()
        raop_test_master_sessions_reset()
    }

    override func tearDown() {
        raop_test_master_sessions_reset()
        super.tearDown()
    }

    // MARK: - Two stream_ids => two DIFFERENT master sessions (the core property).

    func testDistinctStreamIdsGetDistinctMasterSessions() {
        var q = defaultQuality()

        let a = raop_test_master_session_make(1, &q, false)
        let b = raop_test_master_session_make(2, &q, false)

        XCTAssertNotNil(a, "master session for stream 1 must be created")
        XCTAssertNotNil(b, "master session for stream 2 must be created")

        // Same quality, same encrypt — yet different pointers, because stream_id differs.
        XCTAssertNotEqual(a, b,
            "distinct stream_ids at the same quality MUST NOT share a master session")

        XCTAssertEqual(raop_test_master_session_count(), 2)

        XCTAssertEqual(raop_test_master_session_stream_id(a), 1)
        XCTAssertEqual(raop_test_master_session_stream_id(b), 2)
    }

    // MARK: - Same stream_id + same quality => the SAME master session is reused.

    func testSameStreamIdReusesMasterSession() {
        var q = defaultQuality()

        let first = raop_test_master_session_make(7, &q, false)
        let again = raop_test_master_session_make(7, &q, false)

        XCTAssertNotNil(first)
        XCTAssertEqual(first, again,
            "same (stream_id, quality, encrypt) must reuse the existing master session")
        XCTAssertEqual(raop_test_master_session_count(), 1,
            "reuse must not allocate a second master session")
    }

    // MARK: - stream_id 0 is the legacy single-stream default (pre-change path intact).

    func testStreamIdZeroIsTheLegacyDefault() {
        var q = defaultQuality()

        let s0a = raop_test_master_session_make(0, &q, false)
        let s0b = raop_test_master_session_make(0, &q, false)

        XCTAssertNotNil(s0a)
        XCTAssertEqual(s0a, s0b, "stream_id 0 dedups exactly as before the change")
        XCTAssertEqual(raop_test_master_session_stream_id(s0a), 0)
        XCTAssertEqual(raop_test_master_session_count(), 1)
    }

    // MARK: - The critical cross-talk guard: raop_write's fan-out routes a PCM
    // blob only into the master session whose stream_id matches. A write tagged
    // stream_id=1 must NEVER grow a stream_id=0 session's input buffer, and vice
    // versa. This is the correctness-critical line the whole fix turns on.

    func testWriteRoutesOnlyToMatchingStreamId() {
        var q = defaultQuality()

        // Two master sessions, same quality, distinct streams.
        let s0 = raop_test_master_session_make(0, &q, false)
        let s1 = raop_test_master_session_make(1, &q, false)
        XCTAssertNotNil(s0)
        XCTAssertNotNil(s1)
        XCTAssertEqual(raop_test_master_session_input_buffer_samples(s0), 0)
        XCTAssertEqual(raop_test_master_session_input_buffer_samples(s1), 0)

        // A small PCM blob smaller than one packet's rawbuf, so it stays parked in
        // the input buffer (not drained into RTP packets) and we can read the count.
        // 100 frames * 2ch * 2 bytes = 400 bytes.
        let frames: UInt32 = 100
        let pcm = [UInt8](repeating: 0, count: Int(frames) * 2 * 2)

        // Feed ONLY stream 0.
        pcm.withUnsafeBytes { raw in
            raop_test_write_one(0, &q, raw.baseAddress, raw.count, frames, 1)
        }

        XCTAssertEqual(raop_test_master_session_input_buffer_samples(s0), frames,
            "a stream_id=0 write must land in the stream_id=0 master session")
        XCTAssertEqual(raop_test_master_session_input_buffer_samples(s1), 0,
            "a stream_id=0 write must NOT grow the stream_id=1 master session (no cross-talk)")

        // Now feed ONLY stream 1.
        pcm.withUnsafeBytes { raw in
            raop_test_write_one(1, &q, raw.baseAddress, raw.count, frames, 2)
        }

        XCTAssertEqual(raop_test_master_session_input_buffer_samples(s1), frames,
            "a stream_id=1 write must land in the stream_id=1 master session")
        XCTAssertEqual(raop_test_master_session_input_buffer_samples(s0), frames,
            "the stream_id=0 session's buffer must be unchanged by a stream_id=1 write")
    }
}
