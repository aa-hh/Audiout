// P2b (T1) — multi-stream master-session keying.
//
// The per-app-routing fix hinges on one property of the vendored sender: two
// devices routed to DIFFERENT content streams must get DIFFERENT master sessions
// (independent RTP timeline / ALAC encoder / input buffer), even when they share
// the one wired audio quality (44100/16/2). Before this change master_session_make
// deduplicated purely on (quality, use_ptp), so every device collapsed onto one
// master session and every speaker received byte-identical audio. This change adds
// a stream_id dimension so the cache key is (stream_id, quality, use_ptp).
//
// These are pure, headless C-seam tests in the ShimUnitTests / OutputsDispatcher
// mold — no receiver, no PTP (use_ptp = false so no ptpd handle is needed), no
// engine thread, no sockets. They drive the REAL master_session_make via the
// test-only accessors in shims/engine_bridge.h (airplay_test_master_session_*),
// so they exercise the production keying rather than a reimplementation.

import XCTest
@testable import AirPlayEngine
import CAirPlayEngine

final class MultiStreamMasterSessionTests: XCTestCase {

    /// The single quality every AirPlay 2 device is wired to (airplay.c forces
    /// 44100/16/2). Both streams in these tests use it, so stream_id is the ONLY
    /// thing that can distinguish their master sessions.
    private func defaultQuality() -> media_quality {
        media_quality(sample_rate: 44100, bits_per_sample: 16, channels: 2, bit_rate: 0)
    }

    override func setUp() {
        super.setUp()
        // No sessions are attached in these tests, so the reset frees any master
        // sessions a prior case created (process-global list).
        airplay_test_master_sessions_reset()
    }

    override func tearDown() {
        airplay_test_master_sessions_reset()
        super.tearDown()
    }

    // MARK: - Two stream_ids => two DIFFERENT master sessions (the core property).

    func testDistinctStreamIdsGetDistinctMasterSessions() {
        var q = defaultQuality()

        let a = airplay_test_master_session_make(1, &q, false)
        let b = airplay_test_master_session_make(2, &q, false)

        XCTAssertNotNil(a, "master session for stream 1 must be created")
        XCTAssertNotNil(b, "master session for stream 2 must be created")

        // Same quality, same use_ptp — yet different pointers, because stream_id differs.
        XCTAssertNotEqual(a, b,
            "distinct stream_ids at the same quality MUST NOT share a master session")

        // Two live master sessions now exist (pre-change there would be exactly one).
        XCTAssertEqual(airplay_test_master_session_count(), 2)

        // Each master session carries the stream_id it was made for.
        XCTAssertEqual(airplay_test_master_session_stream_id(a), 1)
        XCTAssertEqual(airplay_test_master_session_stream_id(b), 2)
    }

    // MARK: - Same stream_id + same quality => the SAME master session is reused.
    // This is the dedup path that keeps "N speakers, one stream" cheap (one encoder).

    func testSameStreamIdReusesMasterSession() {
        var q = defaultQuality()

        let first = airplay_test_master_session_make(7, &q, false)
        let again = airplay_test_master_session_make(7, &q, false)

        XCTAssertNotNil(first)
        XCTAssertEqual(first, again,
            "same (stream_id, quality, use_ptp) must reuse the existing master session")
        XCTAssertEqual(airplay_test_master_session_count(), 1,
            "reuse must not allocate a second master session")
    }

    // MARK: - stream_id 0 is the legacy single-stream default (Phase-1 path intact).

    func testStreamIdZeroIsTheLegacyDefault() {
        var q = defaultQuality()

        let s0a = airplay_test_master_session_make(0, &q, false)
        let s0b = airplay_test_master_session_make(0, &q, false)

        XCTAssertNotNil(s0a)
        XCTAssertEqual(s0a, s0b, "stream_id 0 dedups exactly as before the change")
        XCTAssertEqual(airplay_test_master_session_stream_id(s0a), 0)
        XCTAssertEqual(airplay_test_master_session_count(), 1)
    }
}
