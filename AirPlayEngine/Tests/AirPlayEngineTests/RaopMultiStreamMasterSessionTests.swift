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
//
// This suite's tests reset/read the process-global RAOP master session list
// (`raop_test_master_sessions_reset()` / `raop_test_master_session_count()`),
// a distinct global from both `shims/outputs.c`'s device registry (see
// `SerializedEngineStateSuite.swift` §22) and the AirPlay-2 master session
// list in `MultiStreamMasterSessionTests.swift`. It nests under
// `SerializedEngineState` anyway: T16 (2026-07-26) verified that
// `raop_test_master_session_make` here crashes when run concurrently against
// either `airplay_test_master_session_make`
// (`MultiStreamMasterSessionTests.swift`, `MultiStreamWriteRoutingTests.swift`)
// with `fatal error in libgcrypt ... gcry_randomize: called in
// non-operational state` — a shared non-reentrant crypto-init path below the
// otherwise-unrelated globals. See `MultiStreamMasterSessionTests.swift`'s
// header comment for the full explanation, including why a separate,
// narrower serialized parent was tried first and still crashed. Do not
// repeat `.serialized` here — it inherits from `SerializedEngineState`.

import Testing
@testable import AirPlayEngine
import CAirPlayEngine

extension SerializedEngineState {

@Suite struct RaopMultiStreamMasterSessionTests {

    /// The single quality every RAOP device is wired to (44100/16/2). Both streams
    /// in these tests use it, so stream_id is the ONLY thing that can distinguish
    /// their master sessions.
    private func defaultQuality() -> media_quality {
        media_quality(sample_rate: 44100, bits_per_sample: 16, channels: 2, bit_rate: 0)
    }

    init() {
        raop_test_master_sessions_reset()
    }

    // MARK: - Two stream_ids => two DIFFERENT master sessions (the core property).

    @Test func distinctStreamIdsGetDistinctMasterSessions() {
        var q = defaultQuality()

        let a = raop_test_master_session_make(1, &q, false)
        let b = raop_test_master_session_make(2, &q, false)

        #expect(a != nil, "master session for stream 1 must be created")
        #expect(b != nil, "master session for stream 2 must be created")

        // Same quality, same encrypt — yet different pointers, because stream_id differs.
        #expect(a != b,
            "distinct stream_ids at the same quality MUST NOT share a master session")

        #expect(raop_test_master_session_count() == 2)

        #expect(raop_test_master_session_stream_id(a) == 1)
        #expect(raop_test_master_session_stream_id(b) == 2)
    }

    // MARK: - Same stream_id + same quality => the SAME master session is reused.

    @Test func sameStreamIdReusesMasterSession() {
        var q = defaultQuality()

        let first = raop_test_master_session_make(7, &q, false)
        let again = raop_test_master_session_make(7, &q, false)

        #expect(first != nil)
        #expect(first == again,
            "same (stream_id, quality, encrypt) must reuse the existing master session")
        #expect(raop_test_master_session_count() == 1,
            "reuse must not allocate a second master session")
    }

    // MARK: - stream_id 0 is the legacy single-stream default (pre-change path intact).

    @Test func streamIdZeroIsTheLegacyDefault() {
        var q = defaultQuality()

        let s0a = raop_test_master_session_make(0, &q, false)
        let s0b = raop_test_master_session_make(0, &q, false)

        #expect(s0a != nil)
        #expect(s0a == s0b, "stream_id 0 dedups exactly as before the change")
        #expect(raop_test_master_session_stream_id(s0a) == 0)
        #expect(raop_test_master_session_count() == 1)
    }

    // MARK: - The critical cross-talk guard: raop_write's fan-out routes a PCM
    // blob only into the master session whose stream_id matches. A write tagged
    // stream_id=1 must NEVER grow a stream_id=0 session's input buffer, and vice
    // versa. This is the correctness-critical line the whole fix turns on.

    @Test func writeRoutesOnlyToMatchingStreamId() {
        var q = defaultQuality()

        // Two master sessions, same quality, distinct streams.
        let s0 = raop_test_master_session_make(0, &q, false)
        let s1 = raop_test_master_session_make(1, &q, false)
        #expect(s0 != nil)
        #expect(s1 != nil)
        #expect(raop_test_master_session_input_buffer_samples(s0) == 0)
        #expect(raop_test_master_session_input_buffer_samples(s1) == 0)

        // A small PCM blob smaller than one packet's rawbuf, so it stays parked in
        // the input buffer (not drained into RTP packets) and we can read the count.
        // 100 frames * 2ch * 2 bytes = 400 bytes.
        let frames: UInt32 = 100
        let pcm = [UInt8](repeating: 0, count: Int(frames) * 2 * 2)

        // Feed ONLY stream 0.
        pcm.withUnsafeBytes { raw in
            raop_test_write_one(0, &q, raw.baseAddress, raw.count, frames, 1)
        }

        #expect(raop_test_master_session_input_buffer_samples(s0) == frames,
            "a stream_id=0 write must land in the stream_id=0 master session")
        #expect(raop_test_master_session_input_buffer_samples(s1) == 0,
            "a stream_id=0 write must NOT grow the stream_id=1 master session (no cross-talk)")

        // Now feed ONLY stream 1.
        pcm.withUnsafeBytes { raw in
            raop_test_write_one(1, &q, raw.baseAddress, raw.count, frames, 2)
        }

        #expect(raop_test_master_session_input_buffer_samples(s1) == frames,
            "a stream_id=1 write must land in the stream_id=1 master session")
        #expect(raop_test_master_session_input_buffer_samples(s0) == frames,
            "the stream_id=0 session's buffer must be unchanged by a stream_id=1 write")
    }
}

}
