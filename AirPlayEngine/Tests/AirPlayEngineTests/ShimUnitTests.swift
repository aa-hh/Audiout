// T-SHIM-2 focused unit tests for the newly-real shims (misc keyval/hextou,
// conffile defaults). These are cheap, pure, no-session tests — they don't open
// sockets or run a libevent loop (that's T-API-1 / the receiver harness). They
// pin the behaviour the vendored cluster relies on: TXT-record lookup, hex
// parsing of deviceid/features fields, and the config defaults airplay.c reads
// at init.

import XCTest
import Foundation
@testable import AirPlayEngine
import CAirPlayEngine

final class ShimUnitTests: XCTestCase {

    // MARK: - keyval (the DNS-SD TXT parser interface)

    func testKeyvalAddGetClear() {
        guard let kv = keyval_alloc() else { return XCTFail("keyval_alloc returned NULL") }
        defer { keyval_clear(kv); free(kv) }

        XCTAssertEqual(keyval_add(kv, "deviceid", "AA:BB:CC:DD:EE:FF"), 0)
        XCTAssertEqual(keyval_add(kv, "features", "0x445F8A00,0x1C340"), 0)

        // Lookup is case-insensitive on the key (OwnTone uses strcasecmp).
        XCTAssertEqual(String(cString: keyval_get(kv, "deviceid")), "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(String(cString: keyval_get(kv, "DEVICEID")), "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(String(cString: keyval_get(kv, "features")), "0x445F8A00,0x1C340")

        // Missing key -> NULL.
        XCTAssertNil(keyval_get(kv, "model"))
    }

    func testKeyvalDuplicateSameValueOkDifferentRejected() {
        guard let kv = keyval_alloc() else { return XCTFail("keyval_alloc returned NULL") }
        defer { keyval_clear(kv); free(kv) }

        XCTAssertEqual(keyval_add(kv, "k", "v1"), 0)
        // Same key + same value is a no-op success.
        XCTAssertEqual(keyval_add(kv, "k", "v1"), 0)
        // Same key + different value is rejected.
        XCTAssertEqual(keyval_add(kv, "k", "v2"), -1)
        // Original value preserved.
        XCTAssertEqual(String(cString: keyval_get(kv, "k")), "v1")
    }

    // MARK: - safe_hextou32 / safe_hextou64

    func testSafeHextou32() {
        var v: UInt32 = 0
        XCTAssertEqual(safe_hextou32("1C340", &v), 0)
        XCTAssertEqual(v, 0x1C340)

        XCTAssertEqual(safe_hextou32("0xFF", &v), 0) // strtoul accepts 0x prefix
        XCTAssertEqual(v, 0xFF)

        // Not hex at all -> error.
        XCTAssertEqual(safe_hextou32("zzz", &v), -1)
        // NULL -> error.
        XCTAssertEqual(safe_hextou32(nil, &v), -1)
        // Out of u32 range -> error.
        XCTAssertEqual(safe_hextou32("1FFFFFFFF", &v), -1)
    }

    func testSafeHextou64() {
        var v: UInt64 = 0
        XCTAssertEqual(safe_hextou64("445F8A00", &v), 0)
        XCTAssertEqual(v, 0x445F8A00)

        // Full 64-bit deviceid-style value.
        XCTAssertEqual(safe_hextou64("AABBCCDDEEFF0011", &v), 0)
        XCTAssertEqual(v, 0xAABBCCDDEEFF0011)

        XCTAssertEqual(safe_hextou64("nope", &v), -1)
        XCTAssertEqual(safe_hextou64(nil, &v), -1)
    }

    // MARK: - conffile defaults (the global keys airplay.c reads at init)

    func testConfigDefaults() {
        let general = cfg_getsec(cfg, "general")
        let library = cfg_getsec(cfg, "library")
        let shared  = cfg_getsec(cfg, "airplay_shared")

        XCTAssertEqual(String(cString: cfg_getstr(general, "user_agent")), "AirPlayEngine/0.1.0")
        XCTAssertEqual(String(cString: cfg_getstr(library, "name")), "My Music on %h")

        // bind_address defaults to NULL (bind to any).
        XCTAssertNil(cfg_getstr(general, "bind_address"))

        // ipv6 enabled by default (needed for PTP link-local v6 peers).
        XCTAssertNotEqual(cfg_getbool(general, "ipv6"), 0)

        // Ports default to 0 (ephemeral bind).
        XCTAssertEqual(cfg_getint(shared, "timing_port"), 0)
        XCTAssertEqual(cfg_getint(shared, "control_port"), 0)

        // Per-device max_volume default.
        XCTAssertEqual(cfg_getint(general, "max_volume"), 11)

        // No per-device override section in the in-memory config.
        XCTAssertNil(cfg_gettsec(cfg, "airplay", "SomeSpeaker"))

        // libhash is a non-zero seed (device id / PTP clock seed).
        XCTAssertNotEqual(libhash, 0)
    }

    func testConfigSettersMutateDefaults() {
        // The T-API-1 setters populate the in-memory struct from the Swift config.
        // (Mutate then restore so this test doesn't leak into others.)
        let originalHash = libhash
        conffile_set_ports(6001, 6002)
        conffile_set_libhash(0xCAFEBABE)

        let shared = cfg_getsec(cfg, "airplay_shared")
        XCTAssertEqual(cfg_getint(shared, "timing_port"), 6001)
        XCTAssertEqual(cfg_getint(shared, "control_port"), 6002)
        XCTAssertEqual(libhash, 0xCAFEBABE)

        // Restore.
        conffile_set_ports(0, 0)
        conffile_set_libhash(originalHash)
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
    func testAlacTranscodeShimProducesValidFrames() {
        let sampleRate: Int32 = 44100
        let channels: Int32 = 2
        let bits: Int32 = 16
        let samplesPerPacket = 352
        let bytesPerFrame = Int(channels) * Int(bits) / 8   // 4
        let rawbufSize = samplesPerPacket * bytesPerFrame     // 1408

        var quality = media_quality(sample_rate: sampleRate, bits_per_sample: bits, channels: channels, bit_rate: 0)

        // Set up the encoder the way master_session_make() does.
        let src = transcode_decode_setup_raw(XCODE_PCM16, &quality)
        XCTAssertNotNil(src, "transcode_decode_setup_raw returned NULL")
        var args = transcode_encode_setup_args()
        args.profile = XCODE_ALAC
        args.quality = withUnsafeMutablePointer(to: &quality) { $0 }
        args.src_ctx = src
        guard let ectx = transcode_encode_setup(args) else {
            transcode_decode_cleanup(&args.src_ctx)
            return XCTFail("transcode_encode_setup returned NULL (ffmpeg ALAC encoder unavailable?)")
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
            XCTAssertGreaterThan(len, 0, "transcode_encode produced no ALAC bytes for a full frame")

            // Pull this packet's bytes out (as packets_send does) and sanity-check.
            var pkt = [UInt8](repeating: 0, count: max(len, 1))
            let got = pkt.withUnsafeMutableBytes { evbuffer_remove(evbuf, $0.baseAddress, len) }
            XCTAssertEqual(Int(got), len)
            if packets == 0 { firstFrameByte = pkt[0] }
            // ALAC/44100/16/2 raw frames are well under the uncompressed ceiling
            // (352*4 = 1408 bytes + header); a full-size frame that large would
            // mean the "352 spf" hack failed and the encoder emitted its native
            // 4096-sample block.
            XCTAssertLessThan(len, rawbufSize + 32, "ALAC packet unexpectedly large — frame_size=352 hack may have failed")
            packets += 1
        }

        XCTAssertEqual(packets, frameCount, "one ALAC packet per 352-sample frame expected")
        // The ALAC element bitstream starts with a channel-element tag; for the
        // stereo tone the first byte is 0x20 (verified against the libavcodec
        // round-trip). Pin it so a planar/interleaved or channel-count regression
        // in the shim is caught.
        XCTAssertEqual(firstFrameByte, 0x20, "unexpected ALAC element header — channel layout / frame shape changed")
    }
}
