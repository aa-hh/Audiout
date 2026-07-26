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
//
// This suite's tests reset/read the process-global master session list
// (`airplay_test_master_sessions_reset()` / `airplay_test_master_session_count()`),
// a different global than `shims/outputs.c`'s device registry that
// `SerializedEngineState` exists for (see `SerializedEngineStateSuite.swift`
// §22) — but it nests under `SerializedEngineState` anyway, for a different
// reason than that suite's own doc comment describes: T16 (2026-07-26)
// verified that `airplay_test_master_session_make` here, run concurrently
// against EITHER `raop_test_master_session_make`
// (`RaopMultiStreamMasterSessionTests.swift`) or the same
// `airplay_test_master_session_make` call from `MultiStreamWriteRoutingTests`
// (which is mandated to sit under `SerializedEngineState` — it also touches
// the outputs.c registry), crashes with `fatal error in libgcrypt ...
// gcry_randomize: called in non-operational state`. All three master/session
// constructors apparently share a single non-reentrant crypto-init path one
// level down the vendored C, regardless of which higher-level global (device
// registry vs. session list) each test otherwise cares about. A SEPARATE
// serialized parent for just the two master-session files was tried first
// and still crashed, because it could still run concurrently against
// `MultiStreamWriteRoutingTests`'s `SerializedEngineState`. Putting all three
// under the one lock that `MultiStreamWriteRoutingTests` already required is
// the only arrangement that removed the race in repeated runs. Do not repeat
// `.serialized` here — it inherits from `SerializedEngineState`.

import Testing
@testable import AirPlayEngine
import CAirPlayEngine

extension SerializedEngineState {

@Suite struct MultiStreamMasterSessionTests {

    /// The single quality every AirPlay 2 device is wired to (airplay.c forces
    /// 44100/16/2). Both streams in these tests use it, so stream_id is the ONLY
    /// thing that can distinguish their master sessions.
    private func defaultQuality() -> media_quality {
        media_quality(sample_rate: 44100, bits_per_sample: 16, channels: 2, bit_rate: 0)
    }

    init() {
        // No sessions are attached in these tests, so the reset frees any master
        // sessions a prior case created (process-global list).
        airplay_test_master_sessions_reset()
    }

    // MARK: - Two stream_ids => two DIFFERENT master sessions (the core property).

    @Test func distinctStreamIdsGetDistinctMasterSessions() {
        var q = defaultQuality()

        let a = airplay_test_master_session_make(1, &q, false)
        let b = airplay_test_master_session_make(2, &q, false)

        #expect(a != nil, "master session for stream 1 must be created")
        #expect(b != nil, "master session for stream 2 must be created")

        // Same quality, same use_ptp — yet different pointers, because stream_id differs.
        #expect(a != b,
            "distinct stream_ids at the same quality MUST NOT share a master session")

        // Two live master sessions now exist (pre-change there would be exactly one).
        #expect(airplay_test_master_session_count() == 2)

        // Each master session carries the stream_id it was made for.
        #expect(airplay_test_master_session_stream_id(a) == 1)
        #expect(airplay_test_master_session_stream_id(b) == 2)
    }

    // MARK: - Same stream_id + same quality => the SAME master session is reused.
    // This is the dedup path that keeps "N speakers, one stream" cheap (one encoder).

    @Test func sameStreamIdReusesMasterSession() {
        var q = defaultQuality()

        let first = airplay_test_master_session_make(7, &q, false)
        let again = airplay_test_master_session_make(7, &q, false)

        #expect(first != nil)
        #expect(first == again,
            "same (stream_id, quality, use_ptp) must reuse the existing master session")
        #expect(airplay_test_master_session_count() == 1,
            "reuse must not allocate a second master session")
    }

    // MARK: - stream_id 0 is the legacy single-stream default (Phase-1 path intact).

    @Test func streamIdZeroIsTheLegacyDefault() {
        var q = defaultQuality()

        let s0a = airplay_test_master_session_make(0, &q, false)
        let s0b = airplay_test_master_session_make(0, &q, false)

        #expect(s0a != nil)
        #expect(s0a == s0b, "stream_id 0 dedups exactly as before the change")
        #expect(airplay_test_master_session_stream_id(s0a) == 0)
        #expect(airplay_test_master_session_count() == 1)
    }
}

}
