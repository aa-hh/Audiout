// T3 focused unit tests for the vendored RAOP (AirPlay 1) sender
// (sender/raop.c). These are cheap, pure, no-session tests: they do NOT open a
// socket or run a libevent loop (that is the gated live test, which needs a real
// AirPlay-1 receiver). They pin two things:
//
//   1. `struct output_definition output_raop` — the backend descriptor — is
//      defined, linked, and wired to the raop_* entry points with the shape
//      docs/raop-seam-brief.md §8 specifies.
//   2. `output_raop.device_volume_to_pct` (raop_volume_to_pct) — the pure
//      RAOP volume-string parser, the one piece of the by-ear-relevant volume
//      path that IS reachable headlessly — parses the SET_PARAMETER "volume: dB"
//      form correctly across the -30..0 dB range, off, and malformed input.
//
// output_raop is reachable from Swift because engine_bridge.h declares it
// `extern` (it is raop.c's only non-static symbol) and the umbrella header
// exposes it, exactly as output_airplay is exposed.

import Testing
import Foundation
@testable import AirPlayEngine
import CAirPlayEngine

@Suite struct RaopBackendTests {

    // MARK: - output_raop descriptor shape (brief §8)

    @Test func outputRaopDescriptorIsWired() {
        // Neutral product name + shared "airplay" config section + the RAOP
        // dispatch type (OUTPUT_TYPE_RAOP == 0). PREFER_AIRPLAY2 is not defined,
        // so priority is 1.
        #expect(String(cString: output_raop.name) == "AirPlay 1")
        #expect(String(cString: output_raop.cfg_name) == "airplay")
        #expect(output_raop.type == OUTPUT_TYPE_RAOP)
        #expect(output_raop.priority == 1)
        #expect(output_raop.disabled == 0)

        // Every entry point the two-backend dispatcher will fan to must be wired.
        // `init`/`deinit` are Swift keywords, so the C fields need backticks.
        #expect(output_raop.`init` != nil, "raop_init unset")
        #expect(output_raop.`deinit` != nil, "raop_deinit unset")
        #expect(output_raop.device_start != nil, "raop_device_start unset")
        #expect(output_raop.device_stop != nil, "raop_device_stop unset")
        #expect(output_raop.device_flush != nil, "raop_device_flush unset")
        #expect(output_raop.device_probe != nil, "raop_device_probe unset")
        #expect(output_raop.device_cb_set != nil, "raop_device_cb_set unset")
        #expect(output_raop.device_free_extra != nil, "raop_device_free_extra unset")
        #expect(output_raop.device_volume_set != nil, "raop_set_volume_one unset")
        #expect(output_raop.device_volume_to_pct != nil, "raop_volume_to_pct unset")
        #expect(output_raop.write != nil, "raop_write unset")
        #expect(output_raop.device_authorize != nil, "raop_device_authorize unset")

        // Metadata is stubbed (audio-only): the three metadata slots are still
        // wired to raop.c's own functions (which reach the no-op db/artwork/dmap
        // shims), matching how airplay.c keeps its metadata slots.
        #expect(output_raop.metadata_prepare != nil, "raop_metadata_prepare unset")
        #expect(output_raop.metadata_send != nil, "raop_metadata_send unset")
        #expect(output_raop.metadata_purge != nil, "raop_metadata_purge unset")

        // device_quality_set is deliberately NOT set (brief §8).
        #expect(output_raop.device_quality_set == nil, "raop must not set device_quality_set")
    }

    // MARK: - Two-backend dispatch by device->type (T4, brief §6.1/§6.2)

    // The shared registry hosts AP1 and AP2 devices side by side; every
    // per-device op forwards through backend_for(device->type). Pin the routing
    // decision headlessly via the outputs_backend_definition_for test seam (which
    // returns the exact pointer the op wrappers dispatch through) — no socket, no
    // session. An OUTPUT_TYPE_RAOP device must resolve to &output_raop, an
    // OUTPUT_TYPE_AIRPLAY device to &output_airplay, and neither cross over.
    private func backendType(for type: output_types) -> UnsafePointer<output_definition>? {
        let dev = UnsafeMutablePointer<output_device>.allocate(capacity: 1)
        defer { dev.deinitialize(count: 1); dev.deallocate() }
        dev.initialize(to: output_device())
        dev.pointee.type = type
        return outputs_backend_definition_for(dev)
    }

    @Test func ap1DeviceRoutesToOutputRaop() {
        let backend = backendType(for: OUTPUT_TYPE_RAOP)
        #expect(backend != nil, "an AP1 device must resolve to a backend")
        #expect(backend == withUnsafePointer(to: &output_raop) { $0 },
                       "OUTPUT_TYPE_RAOP must dispatch to output_raop")
        #expect(backend != withUnsafePointer(to: &output_airplay) { $0 },
                          "AP1 must not route to the AP2 backend")
        // The routed backend is the RAOP one — spot-check a wired entry point.
        #expect(backend?.pointee.device_start != nil, "output_raop.device_start unset")
        #expect(backend?.pointee.type == OUTPUT_TYPE_RAOP)
    }

    @Test func ap2DeviceRoutesToOutputAirplay() {
        let backend = backendType(for: OUTPUT_TYPE_AIRPLAY)
        #expect(backend != nil, "an AP2 device must resolve to a backend")
        #expect(backend == withUnsafePointer(to: &output_airplay) { $0 },
                       "OUTPUT_TYPE_AIRPLAY must dispatch to output_airplay")
        #expect(backend?.pointee.type == OUTPUT_TYPE_AIRPLAY)
    }

    // MARK: - RAOP volume-string parse (raop_volume_to_pct)

    // raop_volume_to_pct maps a RAOP "volume:" dB value (a float in [-30, 0], or
    // -144 off) to a 0-100 percentage, scaled by device->max_volume against
    // RAOP_CONFIG_MAX_VOLUME (11). With the default max_volume == 11 the scale
    // factor is 1, so the mapping is the plain (dB/30 + 1) * 100.
    private func volumeToPct(_ volstr: String, maxVolume: Int32 = 11) -> Int32 {
        let dev = UnsafeMutablePointer<output_device>.allocate(capacity: 1)
        defer { dev.deinitialize(count: 1); dev.deallocate() }
        dev.initialize(to: output_device())
        dev.pointee.max_volume = maxVolume
        guard let parse = output_raop.device_volume_to_pct else {
            Issue.record("output_raop.device_volume_to_pct is NULL")
            return -999
        }
        return volstr.withCString { parse(dev, $0) }
    }

    @Test func volumeToPctMapsDbRange() {
        // 0 dB is full scale. (volstr[0] == '0' keeps atof()==0 from being read
        // as the "invalid" case.)
        #expect(volumeToPct("0") == 100)
        #expect(volumeToPct("0.0") == 100)

        // Midpoint: -15 dB -> 50%.
        #expect(volumeToPct("-15.0") == 50)

        // -7.5 dB -> 75%, -22.5 dB -> 25%.
        #expect(volumeToPct("-7.5") == 75)
        #expect(volumeToPct("-22.5") == 25)

        // Floor: -30 dB and anything below clamps to 0%.
        #expect(volumeToPct("-30.0") == 0)
        #expect(volumeToPct("-45.0") == 0)
        // -144 is RAOP's "off" sentinel; it is <= -30 so it reads as 0%.
        #expect(volumeToPct("-144.0") == 0)
    }

    @Test func volumeToPctRejectsInvalid() {
        // A positive dB value is invalid for RAOP -> -1.
        #expect(volumeToPct("5.0") == -1)
        // Non-numeric parses as 0.0 but volstr[0] != '0' -> flagged invalid -> -1.
        #expect(volumeToPct("garbage") == -1)
    }

    @Test func volumeToPctScalesByMaxVolume() {
        // raop_volume_to_pct divides by device->max_volume (against the fixed
        // RAOP_CONFIG_MAX_VOLUME of 11). Halving max_volume doubles the reported
        // percentage for the same dB, clamped to 100. At -15 dB the base is 50%;
        // with max_volume == 5.5-equivalent (use integer 5) the scaled value
        // exceeds 100 and clamps. Use max_volume 22 to halve it instead: 50 ->
        // 25 (11/22 = 0.5).
        #expect(volumeToPct("-15.0", maxVolume: 22) == 25)
        // With a very small max_volume the same dB clamps at the 0..100 ceiling.
        #expect(volumeToPct("-7.5", maxVolume: 5) == 100)
    }

    // MARK: - New misc shims backing the RAOP handshake

    // b64_encode backs the classic RSA-AES SDP handshake: the RSA-wrapped AES
    // key (a=rsaaeskey), the AES IV (a=aesiv) and the Apple-Challenge are all
    // base64-encoded before they go on the wire (raop.c:851/1598/4681). Pin the
    // standard RFC-4648 vectors (including '=' padding, which raop.c strips
    // itself where the protocol wants it stripped).
    private func b64(_ s: String) -> String? {
        let bytes = Array(s.utf8)
        let out: UnsafeMutablePointer<CChar>? = bytes.withUnsafeBufferPointer { bp in
            b64_encode(bp.baseAddress, Int32(bp.count))
        }
        guard let out else { return nil }
        defer { free(out) }
        return String(cString: out)
    }

    @Test func b64EncodeRfc4648Vectors() {
        #expect(b64("") == "")
        #expect(b64("f") == "Zg==")
        #expect(b64("fo") == "Zm8=")
        #expect(b64("foo") == "Zm9v")
        #expect(b64("foob") == "Zm9vYg==")
        #expect(b64("fooba") == "Zm9vYmE=")
        #expect(b64("foobar") == "Zm9vYmFy")
    }

    @Test func b64EncodeBinaryPayload() {
        // A 16-byte all-0xFF blob (the size class of an AES IV) is 5 full 3-byte
        // groups (-> 20 '/') plus one trailing byte, whose 8 bits become "/w=="
        // (6 bits -> '/', 2 bits zero-padded -> 'w', then "=="). 16 bytes -> 24
        // chars, one trailing '=='-padded group.
        let iv = [UInt8](repeating: 0xFF, count: 16)
        let enc: String = iv.withUnsafeBufferPointer { bp -> String in
            let out = b64_encode(bp.baseAddress, Int32(bp.count))!
            defer { free(out) }
            return String(cString: out)
        }
        #expect(enc == "/////////////////////w==")
        #expect(enc.count == 24)
    }

    // safe_atoi32 parses the decimal SETUP transport ports (server_port/
    // control_port/timing_port) and the sr/ss/ch quality TXT values.
    @Test func safeAtoi32() {
        var v: Int32 = 0
        #expect(safe_atoi32("352", &v) == 0)
        #expect(v == 352)

        #expect(safe_atoi32("44100", &v) == 0)
        #expect(v == 44100)

        #expect(safe_atoi32("-14", &v) == 0)
        #expect(v == -14)

        #expect(safe_atoi32("0", &v) == 0)
        #expect(v == 0)

        // Not a number / NULL / out of i32 range -> error, *val untouched.
        #expect(safe_atoi32("nope", &v) == -1)
        #expect(safe_atoi32(nil, &v) == -1)
        #expect(safe_atoi32("9999999999", &v) == -1)
    }
}
