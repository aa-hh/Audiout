// T-SHIM-2 focused unit tests for the newly-real shims (misc keyval/hextou,
// conffile defaults). These are cheap, pure, no-session tests — they don't open
// sockets or run a libevent loop (that's T-API-1 / the receiver harness). They
// pin the behaviour the vendored cluster relies on: TXT-record lookup, hex
// parsing of deviceid/features fields, and the config defaults airplay.c reads
// at init.

import Testing
import Foundation
@testable import AirPlayEngine
import CAirPlayEngine
import PTPHelperTestSupport

// Nested into `SerializedEngineState` because — despite the "cheap, pure,
// no-session" framing above — most of these tests read AND WRITE
// process-global C state, which XCTest's one-process-per-test-METHOD model
// made safe by accident and swift-testing's in-process concurrency does not:
//
//  - `cfg` / `libhash`: `configDefaults` asserts `timing_port == 0`,
//    `control_port == 0` and `ipv6 == 0` while its own siblings
//    `configSettersMutateDefaults` (sets 6001/6002 + a new libhash) and
//    `ipv6ShimDefaultIsOffAndSetterRoundTrips` (sets ipv6 true) are mutating
//    exactly those keys. Concurrently these three fail each other outright,
//    and the engine-starting suites in this package read the same `cfg` at
//    `airplay_init`.
//  - SIGPIPE disposition: `engineMaskSigpipeSetsIgnoreDisposition` resets it
//    to `SIG_DFL` at both ends of its body while
//    `engineMaskSigpipeIsIdempotent` asserts it is `SIG_IGN` — a direct
//    two-test race on a process-wide signal handler.
//  - `conffile_unknown_key_assert` / `conffile_unknown_key_count`:
//    before/after counter deltas, and a window where the debug abort is
//    disabled process-wide.
//  - `engine_crypto_init()`: libgcrypt's one-time init — the very global
//    whose race crashed the whole test process from
//    `MultiStreamMasterSessionTests` during this migration, which is why that
//    suite already lives under this parent. Serializing against it here is
//    the point, not a coincidence.
//  - `event_set_log_callback(nil)`: libevent's process-global log callback.
extension SerializedEngineState {

@Suite struct ShimUnitTests {

    // MARK: - keyval (the DNS-SD TXT parser interface)

    @Test func keyvalAddGetClear() {
        guard let kv = keyval_alloc() else { Issue.record("keyval_alloc returned NULL"); return }
        defer { keyval_clear(kv); free(kv) }

        #expect(keyval_add(kv, "deviceid", "AA:BB:CC:DD:EE:FF") == 0)
        #expect(keyval_add(kv, "features", "0x445F8A00,0x1C340") == 0)

        // Lookup is case-insensitive on the key (OwnTone uses strcasecmp).
        #expect(String(cString: keyval_get(kv, "deviceid")) == "AA:BB:CC:DD:EE:FF")
        #expect(String(cString: keyval_get(kv, "DEVICEID")) == "AA:BB:CC:DD:EE:FF")
        #expect(String(cString: keyval_get(kv, "features")) == "0x445F8A00,0x1C340")

        // Missing key -> NULL.
        #expect(keyval_get(kv, "model") == nil)
    }

    @Test func keyvalDuplicateSameValueOkDifferentRejected() {
        guard let kv = keyval_alloc() else { Issue.record("keyval_alloc returned NULL"); return }
        defer { keyval_clear(kv); free(kv) }

        #expect(keyval_add(kv, "k", "v1") == 0)
        // Same key + same value is a no-op success.
        #expect(keyval_add(kv, "k", "v1") == 0)
        // Same key + different value is rejected.
        #expect(keyval_add(kv, "k", "v2") == -1)
        // Original value preserved.
        #expect(String(cString: keyval_get(kv, "k")) == "v1")
    }

    // MARK: - safe_hextou32 / safe_hextou64

    @Test func safeHextou32() {
        var v: UInt32 = 0
        #expect(safe_hextou32("1C340", &v) == 0)
        #expect(v == 0x1C340)

        #expect(safe_hextou32("0xFF", &v) == 0) // strtoul accepts 0x prefix
        #expect(v == 0xFF)

        // Not hex at all -> error.
        #expect(safe_hextou32("zzz", &v) == -1)
        // NULL -> error.
        #expect(safe_hextou32(nil, &v) == -1)
        // Out of u32 range -> error.
        #expect(safe_hextou32("1FFFFFFFF", &v) == -1)
    }

    @Test func safeHextou64() {
        var v: UInt64 = 0
        #expect(safe_hextou64("445F8A00", &v) == 0)
        #expect(v == 0x445F8A00)

        // Full 64-bit deviceid-style value.
        #expect(safe_hextou64("AABBCCDDEEFF0011", &v) == 0)
        #expect(v == 0xAABBCCDDEEFF0011)

        #expect(safe_hextou64("nope", &v) == -1)
        #expect(safe_hextou64(nil, &v) == -1)
    }

    // MARK: - conffile defaults (the global keys airplay.c reads at init)

    @Test func configDefaults() {
        let general = cfg_getsec(cfg, "general")
        let library = cfg_getsec(cfg, "library")
        let shared  = cfg_getsec(cfg, "airplay_shared")

        #expect(String(cString: cfg_getstr(general, "user_agent")) == "AirPlayEngine/0.1.0")
        #expect(String(cString: cfg_getstr(library, "name")) == "My Music on %h")

        // bind_address defaults to NULL (bind to any).
        #expect(cfg_getstr(general, "bind_address") == nil)

        // ipv6 OFF by default in the shim, matching OwnTone's general.ipv6=false
        // (first-light hardening #5). The Swift EngineConfig re-enables it via
        // conffile_set_ipv6() before airplay_init; the raw shim default is off.
        #expect(cfg_getbool(general, "ipv6") == 0)

        // Ports default to 0 (ephemeral bind).
        #expect(cfg_getint(shared, "timing_port") == 0)
        #expect(cfg_getint(shared, "control_port") == 0)

        // Per-device max_volume default.
        #expect(cfg_getint(general, "max_volume") == 11)

        // No per-device override section in the in-memory config.
        #expect(cfg_gettsec(cfg, "airplay", "SomeSpeaker") == nil)

        // libhash is a non-zero seed (device id / PTP clock seed).
        #expect(libhash != 0)
    }

    @Test func configSettersMutateDefaults() {
        // The T-API-1 setters populate the in-memory struct from the Swift config.
        // (Mutate then restore so this test doesn't leak into others.)
        let originalHash = libhash
        conffile_set_ports(6001, 6002)
        conffile_set_libhash(0xCAFEBABE)

        let shared = cfg_getsec(cfg, "airplay_shared")
        #expect(cfg_getint(shared, "timing_port") == 6001)
        #expect(cfg_getint(shared, "control_port") == 6002)
        #expect(libhash == 0xCAFEBABE)

        // Restore.
        conffile_set_ports(0, 0)
        conffile_set_libhash(originalHash)
    }

    // MARK: - general.ipv6 shim default off (first-light hardening #5a)
    //
    // The raw shim static default flipped to OFF (0) to match OwnTone's own
    // general.ipv6=false; the Swift EngineConfig re-enables it before init via
    // conffile_set_ipv6(). Pin both the off default and the setter round-trip.
    @Test func ipv6ShimDefaultIsOffAndSetterRoundTrips() {
        let general = cfg_getsec(cfg, "general")
        // Save whatever the current process-wide value is (another test/engine
        // may have set it) and restore at the end.
        let original = cfg_getbool(general, "ipv6")
        defer { conffile_set_ipv6(original != 0) }

        conffile_set_ipv6(false)
        #expect(cfg_getbool(general, "ipv6") == 0, "ipv6 shim default/off state")

        conffile_set_ipv6(true)
        #expect(cfg_getbool(general, "ipv6") != 0, "conffile_set_ipv6(true) must enable it")
    }

    // MARK: - conffile unknown-key loud miss (first-light hardening #5c)
    //
    // An unserved config key must no longer masquerade as a 0/NULL default: the
    // miss is logged and (in debug) asserts. Exercising the assert would abort
    // the test process, so the shim exposes a test seam
    // (conffile_unknown_key_assert) to disable ONLY the abort while still
    // counting + logging + returning the safe default. This test flips it off,
    // confirms an unknown lookup bumps the counter and returns the default, and
    // confirms a KNOWN key does NOT trip the counter.
    @Test func conffileUnknownKeyIsLoudAndCounted() {
        let savedAssert = conffile_unknown_key_assert
        conffile_unknown_key_assert = false
        defer { conffile_unknown_key_assert = savedAssert }

        let general = cfg_getsec(cfg, "general")

        // A known key must NOT count as a miss.
        let before = conffile_unknown_key_count
        #expect(String(cString: cfg_getstr(general, "user_agent")) == "AirPlayEngine/0.1.0")
        #expect(conffile_unknown_key_count == before, "a served key must not register a miss")

        // Unknown str key -> counted, logged, returns NULL (safe default).
        #expect(cfg_getstr(general, "totally_bogus_key") == nil)
        #expect(conffile_unknown_key_count == before + 1, "unknown str key must register one miss")

        // Unknown int key -> counted, returns 0.
        #expect(cfg_getint(general, "no_such_int") == 0)
        #expect(conffile_unknown_key_count == before + 2, "unknown int key must register one miss")

        // Unknown bool key -> counted, returns 0. (ipv6 is the only served bool.)
        #expect(cfg_getbool(general, "no_such_bool") == 0)
        #expect(conffile_unknown_key_count == before + 3, "unknown bool key must register one miss")

        // ipv6 is served -> no additional miss.
        _ = cfg_getbool(general, "ipv6")
        #expect(conffile_unknown_key_count == before + 3, "ipv6 is a served bool key")
    }

    // MARK: - gcry_check_version min-version floor (first-light hardening #5d)
    //
    // engine_crypto_init() now passes a real minimum version to
    // gcry_check_version instead of NULL, so it enforces a floor (and still runs
    // libgcrypt's mandatory pre-init side effect). Since the installed libgcrypt
    // is comfortably newer than the floor, init must still succeed and be
    // idempotent — a floor that rejected the real library would return -1 here.
    @Test func engineCryptoInitSucceedsWithVersionFloor() {
        #expect(engine_crypto_init() == 0, "crypto init must pass the version floor on a modern libgcrypt")
        // Idempotent (GCRYCTL_INITIALIZATION_FINISHED already set on 2nd call).
        #expect(engine_crypto_init() == 0)
    }

    // MARK: - libevent log bridge (first-light hardening #5b)
    //
    // engine_logger_wire_libevent() installs our adapter as libevent's log
    // callback (event_set_log_callback). Hermetic check: calling it must not
    // crash and must be idempotent; then drive a libevent warning through
    // event_warn-style output indirectly by re-wiring. We can't easily force
    // libevent to emit, so assert the wiring call itself is safe/idempotent and
    // that our adapter is installed (event_set_log_callback has no getter, so
    // this is a smoke test of the wiring path — the real value shows up as
    // L_EVENT lines in Console during a live session).
    @Test func libeventLogWiringIsSafeAndIdempotent() {
        engine_logger_wire_libevent()
        engine_logger_wire_libevent()
        // Restore libevent's default writer so we don't leave a dangling adapter
        // pointer installed for other tests in this process image.
        event_set_log_callback(nil)
    }

    // MARK: - Engine log file (PLAN-LIVE-DIAGNOSTICS.md C2)
    //
    // The defects this catches: a line written without the ISO timestamp the
    // host's decision log uses (the two files could no longer interleave by
    // eye), or a file that grows past its cap because rotation never fires or
    // fires without reopening (the tail of a live session would be lost).
    @Test func engineLogFileStampsLinesAndRotatesAtTheCap() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("engine-log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            engine_logger_set_file(nil, 0)
            try? FileManager.default.removeItem(at: dir)
        }
        let active = dir.appendingPathComponent("engine.log")
        let backup = dir.appendingPathComponent("engine.log.1")

        // `DPRINTF` is C-variadic, which Swift cannot call; `DVPRINTF` is the
        // same path one step in.
        func emit(_ fmt: String, _ args: CVarArg...) {
            withVaList(args) { DVPRINTF(E_LOG, L_RAOP, fmt, $0) }
        }

        // A cap two lines wide: the third line lands in a fresh file.
        engine_logger_set_file(active.path, 120)
        emit("first %d\n", 1)
        let firstLine = try String(contentsOf: active, encoding: .utf8)
        let stamp = try #require(firstLine.split(separator: " ").first)
        #expect(stamp.wholeMatch(of: #/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z/#) != nil,
                "expected an ISO-8601 UTC stamp, got \(stamp)")
        #expect(firstLine.contains("[raop] first 1"))

        emit("second, long enough to cross one hundred and twenty bytes of cap\n")
        emit("third\n")
        #expect(FileManager.default.fileExists(atPath: backup.path), "reaching the cap must rotate")
        let rotated = try String(contentsOf: backup, encoding: .utf8)
        #expect(rotated.contains("first 1") && rotated.contains("second"))
        let fresh = try String(contentsOf: active, encoding: .utf8)
        #expect(fresh.contains("third") && !fresh.contains("first 1"), "the active file restarts after rotation")
    }

    // MARK: - SIGPIPE masking (first-light backlog #2)
    //
    // OwnTone's main() sets SIGPIPE to SIG_IGN process-wide before spawning any
    // threads (main.c:718-732); our hosting never did. `engine_mask_sigpipe()`
    // is the shim `start()` calls on the engine thread before `airplay_init`
    // opens any sockets (AirPlayEngine.swift). This test drives the shim
    // directly — hermetic, no engine thread / event loop / sockets needed —
    // and asserts the actual process disposition via sigaction(2).
    @Test func engineMaskSigpipeSetsIgnoreDisposition() {
        // Start from a known non-IGN disposition so the assertion is meaningful.
        signal(SIGPIPE, SIG_DFL)

        engine_mask_sigpipe()

        var current = sigaction()
        #expect(sigaction(SIGPIPE, nil, &current) == 0)
        let handlerBits = unsafeBitCast(current.__sigaction_u.__sa_handler, to: Int.self)
        let sigIgnBits = unsafeBitCast(SIG_IGN, to: Int.self)
        #expect(handlerBits == sigIgnBits,
                        "engine_mask_sigpipe() must set SIGPIPE disposition to SIG_IGN")

        // Restore default so this test doesn't leak process-wide state into others.
        signal(SIGPIPE, SIG_DFL)
    }

    @Test func engineMaskSigpipeIsIdempotent() {
        engine_mask_sigpipe()
        engine_mask_sigpipe()

        var current = sigaction()
        #expect(sigaction(SIGPIPE, nil, &current) == 0)
        let handlerBits = unsafeBitCast(current.__sigaction_u.__sa_handler, to: Int.self)
        let sigIgnBits = unsafeBitCast(SIG_IGN, to: Int.self)
        #expect(handlerBits == sigIgnBits)

        signal(SIGPIPE, SIG_DFL)
    }

    // MARK: - ALAC transcode shim (the encode seam)
    //
    // Regression for first-light forensics (2026-07-17): drive the REAL ffmpeg-
    // backed transcode.c shim exactly like airplay.c's alac_encode()/packets_send()
    // — 352-sample interleaved-S16 frames at 44100/16/2 into an evbuffer — and
    // assert the produced ALAC bitstream is well-formed. A companion out-of-tree
    // decode (libavcodec ALAC decode with the SETUP-advertised magic cookie)
    // confirmed the recovered PCM is a clean 440 Hz tone (Goertzel spike ~400x
    // over neighbouring bins); this in-suite test guards the shim's frame layout
    // and output shape so a future refactor can't silently break the encoder while
    // the session still looks healthy.
    @Test func alacTranscodeShimProducesValidFrames() {
        let sampleRate: Int32 = 44100
        let channels: Int32 = 2
        let bits: Int32 = 16
        let samplesPerPacket = 352
        let bytesPerFrame = Int(channels) * Int(bits) / 8   // 4
        let rawbufSize = samplesPerPacket * bytesPerFrame     // 1408

        var quality = media_quality(sample_rate: sampleRate, bits_per_sample: bits, channels: channels, bit_rate: 0)

        // Set up the encoder the way master_session_make() does.
        let src = transcode_decode_setup_raw(XCODE_PCM16, &quality)
        #expect(src != nil, "transcode_decode_setup_raw returned NULL")
        var args = transcode_encode_setup_args()
        args.profile = XCODE_ALAC
        args.quality = withUnsafeMutablePointer(to: &quality) { $0 }
        args.src_ctx = src
        guard let ectx = transcode_encode_setup(args) else {
            transcode_decode_cleanup(&args.src_ctx)
            Issue.record("transcode_encode_setup returned NULL (ffmpeg ALAC encoder unavailable?)")
            return
        }
        transcode_decode_cleanup(&args.src_ctx)
        defer { var e: OpaquePointer? = ectx; transcode_encode_cleanup(&e) }

        // Synthesize a 440 Hz interleaved S16LE stereo tone, encode 200 frames.
        let evbuf = evbuffer_new()
        defer { evbuffer_free(evbuf) }
        var rawbuf = [UInt8](repeating: 0, count: rawbufSize)

        let frameCount = 200
        var sampleIndex = 0
        var packets = 0
        var firstFrameByte: UInt8 = 0xFF
        for _ in 0..<frameCount {
            for i in 0..<samplesPerPacket {
                let t = Double(sampleIndex) / Double(sampleRate)
                let v = Int16(16000.0 * sin(2.0 * Double.pi * 440.0 * t))
                let lo = UInt8(truncatingIfNeeded: Int(v))
                let hi = UInt8(truncatingIfNeeded: Int(v) >> 8)
                let base = i * bytesPerFrame
                rawbuf[base + 0] = lo; rawbuf[base + 1] = hi   // left
                rawbuf[base + 2] = lo; rawbuf[base + 3] = hi   // right
                sampleIndex += 1
            }

            let len: Int = rawbuf.withUnsafeMutableBytes { rb -> Int in
                guard let frame = transcode_frame_new(rb.baseAddress, rawbufSize, Int32(samplesPerPacket), &quality) else { return -1 }
                defer { transcode_frame_free(frame) }
                return Int(transcode_encode(evbuf, ectx, frame, 0))
            }
            #expect(len > 0, "transcode_encode produced no ALAC bytes for a full frame")

            // Pull this packet's bytes out (as packets_send does) and sanity-check.
            var pkt = [UInt8](repeating: 0, count: max(len, 1))
            let got = pkt.withUnsafeMutableBytes { evbuffer_remove(evbuf, $0.baseAddress, len) }
            #expect(Int(got) == len)
            if packets == 0 { firstFrameByte = pkt[0] }
            // ALAC/44100/16/2 raw frames are well under the uncompressed ceiling
            // (352*4 = 1408 bytes + header); a full-size frame that large would
            // mean the "352 spf" hack failed and the encoder emitted its native
            // 4096-sample block.
            #expect(len < rawbufSize + 32, "ALAC packet unexpectedly large — frame_size=352 hack may have failed")
            packets += 1
        }

        #expect(packets == frameCount, "one ALAC packet per 352-sample frame expected")
        // The ALAC element bitstream starts with a channel-element tag; for the
        // stereo tone the first byte is 0x20 (verified against the libavcodec
        // round-trip). Pin it so a planar/interleaved or channel-count regression
        // in the shim is caught.
        #expect(firstFrameByte == 0x20, "unexpected ALAC element header — channel layout / frame shape changed")
    }
}

} // extension SerializedEngineState

// MARK: - T2b: shims/ptpd.c deferred-lookup contract (ptp-helper-design.md
// §1.3/§5.1-5.2)
//
// The root ptp-helper daemon is demand-started (spins up on the user's first
// connect, not at engine launch), so ptpd_init() finding no daemon yet must
// NOT permanently disable PTP for the process — see shims/ptpd.h's
// "DEFERRED LOOKUP CONTRACT" comment for the full contract. These tests
// exercise shims/ptpd.c directly, not the vendored sender, so they can't
// observe airplay.c's airplay_ptp_is_disabled latch itself (sender/airplay.c
// is vendored and untouched by this task; that flag is only reachable via a
// live session) — they pin the shim-level return values that latch depends on.
//
// Nested under `SerializedLibairptpState` (SerializedLibairptpStateSuite.swift),
// NOT `SerializedEngineState` above: every test here reads/writes
// shims/ptpd.c's module-static `ptpd_hdl` and/or overrides libairptp's
// process-wide `airptp_event_port`/`airptp_general_port`/`airptp_shm_name`
// (the same globals PTPHelperIPCTests.swift uses) — a different shared-state
// domain from this file's `ShimUnitTests` (shims/outputs.c's device
// registry), and one that must stay mutually exclusive with
// PTPHelperIPCTests.swift's own daemon bind/start/find, not just with itself.
extension SerializedLibairptpState {

    @Suite struct PtpdShimTests {

        /// Dedicated test-only shm name / high ports for this suite — never
        /// the production "/airptp_shm" (a real root ptp-helper daemon may
        /// actually be running on this machine outside of CI, per
        /// ptp-helper-design.md §2; reading its real shm would make "no
        /// daemon present" nondeterministic) and distinct from
        /// PTPHelperIPCTests.swift's own test values (serialized against it
        /// via the shared parent, but kept distinct so it's never ambiguous
        /// which suite owns a given name/port in a log or a leaked shm).
        private static let testShmName = "/airptp_shm_test_ptpd_shim"
        private static let testEventPort: UInt16 = 30419
        private static let testGeneralPort: UInt16 = 30420

        /// Point libairptp's process-globals at this suite's dedicated
        /// test-only shm name/ports. Every test below calls this before
        /// touching shims/ptpd.c's entry points, so the airptp_daemon_find()
        /// they call internally can never see a real production daemon.
        private func overrideToTestNamespace() {
            Self.testShmName.withCString { ptp_test_shm_name_override($0) }
            ptp_test_ports_override(Self.testEventPort, Self.testGeneralPort)
        }

        /// Restore the shipping defaults so this suite can't leak its
        /// overrides into PTPHelperIPCTests.swift or a future real session in
        /// this same process (mirrors that file's own `deinit`).
        private func restoreProductionNamespace() {
            "/airptp_shm".withCString { ptp_test_shm_name_override($0) }
            ptp_test_ports_override(319, 320)
        }

        // MARK: ptpd teardown idempotency (T-ENG-SIGABRT-1 regression) —
        // moved here from ShimUnitTests/SerializedEngineState (T2b): it
        // reads/writes the same ptpd_hdl static the rest of this suite does,
        // so it belongs in this lock domain, not that one (see this suite's
        // header comment).
        //
        // The vendored airplay_deinit() already calls ptpd_deinit() (airplay.c:
        // "After freeing sessions, since that's where the active ptp peers get
        // removed"), and the engine's stop() then calls ptpd_deinit() a second
        // time for symmetry with the hosting-added ptpd_find_or_bind() in
        // start(). Before the shim was made idempotent that second call
        // re-entered daemon_stop() on an already-joined pthread —
        // pthread_join() on a stale tid → SIGABRT (exit 134) at "Stopping
        // airptp event loop" (first-light backlog #1).
        //
        // The full crash only manifests with a live, privileged,
        // bound-and-started daemon (binds UDP 319/320, spawns the PTP
        // thread) — that is the gated path, so this headless test pins the
        // reachable half of the contract: with no daemon ever bound
        // (ptpd_hdl == NULL), ptpd_deinit() is a safe no-op and stays safe
        // when called repeatedly.
        @Test func ptpdDeinitIsIdempotentNoOpWithoutBind() {
            // No ptpd_find_or_bind()/ptpd_init() ran first in this test, so
            // ptpd_hdl is NULL. Each call routes to airptp_end(NULL), which
            // returns immediately. The NULL-out keeps it NULL, so any number
            // of calls stay no-ops. A crash here (double free / pthread_join
            // on a stale tid) fails the test.
            ptpd_deinit()
            ptpd_deinit()
            ptpd_deinit()
        }

        // MARK: T2b — ptpd_init() defers rather than latching "unavailable"
        @Test func ptpdInitReturnsDeferredZeroWithNoDaemonPresent() {
            overrideToTestNamespace()
            defer { ptpd_deinit(); restoreProductionNamespace() }

            // No daemon was ever bound under this suite's dedicated test shm
            // name, so ptpd_init()'s internal airptp_daemon_find() finds
            // nothing. Pre-T2b this returned -1, which the vendored
            // airplay.c latches into airplay_ptp_is_disabled for the rest of
            // the process; it must now return 0 ("deferred", not
            // "unavailable") so a helper daemon that starts later is still
            // picked up (see ptpdLazyFindPicksUpDaemonStartedAfterInit
            // below).
            #expect(ptpd_init(0xC0FFEE) == 0, "ptpd_init() must return 0 (deferred) rather than -1 when no daemon is found yet")
        }

        // MARK: T2b — no crash, existing sentinels, with no daemon
        @Test func ptpdClockIdGetAndSlaveAddReturnFailureSentinelsWithNoDaemon() {
            overrideToTestNamespace()
            defer { ptpd_deinit(); restoreProductionNamespace() }

            // ptpd_hdl is NULL (no prior bind/find in this test); both
            // functions must lazily attempt airptp_daemon_find(), fail (no
            // daemon at this shm name), and return their pre-existing
            // failure sentinels rather than dereferencing a NULL handle —
            // airptp_clock_id_get()/airptp_peer_add() read hdl->state
            // immediately with no NULL check of their own.
            #expect(ptpd_clock_id_get() == UInt64.max, "ptpd_clock_id_get() must return the (uint64_t)-1 sentinel, not crash, with no daemon")

            var slaveID: UInt32 = 0
            let addRet = "127.0.0.1".withCString { ptpd_slave_add(&slaveID, $0) }
            #expect(addRet != 0, "ptpd_slave_add() must return a non-zero failure sentinel, not crash, with no daemon")

            // ptpd_slave_remove() only NULL-guards (no lazy find — removing
            // a slave that was never added is correctly a no-op); must also
            // not crash.
            ptpd_slave_remove(slaveID)
        }

        // MARK: T2b — the actual deferred-lookup payoff: a daemon that
        // starts AFTER ptpd_init() ran is still found, lazily, at
        // connect/session time.
        @Test func ptpdLazyFindPicksUpDaemonStartedAfterInit() {
            overrideToTestNamespace()
            defer { ptpd_deinit(); restoreProductionNamespace() }

            // 1. ptpd_init() runs first, exactly like AirPlayEngine.start()
            //    would against a helper that hasn't been demand-started yet.
            #expect(ptpd_init(0xC0FFEE) == 0)
            // Confirm the "no daemon yet" half of the contract: a call right
            // now still gets the failure sentinel, proving what follows is
            // genuinely a LATE find rather than something ptpd_init() itself
            // already cached.
            #expect(ptpd_clock_id_get() == UInt64.max, "no daemon should be reachable yet")

            // 2. NOW start a test daemon on the same overridden shm
            //    name/ports — stands in for the helper's demand-start
            //    happening after the engine already ran ptpd_init() (the
            //    exact race this task fixes). High ports + explicit
            //    loopback bind, per PTPHelperIPCTests.swift's documented
            //    CI-safe convention (never 319/320; an all-interfaces bind
            //    trips the Application Firewall prompt for the xctest host).
            guard let masterHdl = "127.0.0.1".withCString({ ptp_test_daemon_bind($0) }) else {
                Issue.record("Could not bind PTP test ports \(Self.testEventPort)/\(Self.testGeneralPort) - \(String(cString: ptp_test_errmsg_get()))")
                return
            }
            defer { ptp_test_end(masterHdl) }

            let startRet = ptp_test_daemon_start(masterHdl, 0xFEED_BEEF, /* is_shared: */ true)
            #expect(startRet == 0, "airptp_daemon_start() failed: \(String(cString: ptp_test_errmsg_get()))")
            guard startRet == 0 else { return }

            // 3. The lazy find inside ptpd_clock_id_get()/ptpd_slave_add()
            //    must now pick up the daemon that just started — this is the
            //    behavior T2b adds; pre-T2b these functions only ever used
            //    whatever ptpd_hdl was left after ptpd_init()/ptpd_find_or_bind
            //    and never retried.
            let clockID = ptpd_clock_id_get()
            #expect(clockID != UInt64.max, "ptpd_clock_id_get() must lazily find the daemon that started after ptpd_init()")

            var slaveID: UInt32 = 0
            let addRet = "127.0.0.1".withCString { ptpd_slave_add(&slaveID, $0) }
            #expect(addRet == 0, "ptpd_slave_add() must lazily find the daemon that started after ptpd_init()")
            ptpd_slave_remove(slaveID)
        }
    }
}
