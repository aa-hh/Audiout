// T-SHIM-2 focused unit tests for the newly-real shims (misc keyval/hextou,
// conffile defaults). These are cheap, pure, no-session tests — they don't open
// sockets or run a libevent loop (that's T-API-1 / the receiver harness). They
// pin the behaviour the vendored cluster relies on: TXT-record lookup, hex
// parsing of deviceid/features fields, and the config defaults airplay.c reads
// at init.

import XCTest
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
}
