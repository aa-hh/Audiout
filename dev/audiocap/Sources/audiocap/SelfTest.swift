import Foundation

// ============================================================================
// --selftest — no-TCC, no-audio unit checks that can run from ANY shell (agent
// or human), so the conversion math is verified without the audio-capture grant.
// Prints PASS/FAIL per case and returns non-zero if any case fails.
// ============================================================================

func runSelfTest() -> Int32 {
    var failures = 0

    func check(_ name: String, _ got: Int16, _ want: Int16) {
        if got == want {
            elog("PASS  \(name): floatToInt16 -> \(got)")
        } else {
            elog("FAIL  \(name): floatToInt16 -> \(got), expected \(want)")
            failures += 1
        }
    }

    // Scalar conversion vectors. SYMMETRIC scale x*32767 with round-half-away-from-
    // zero. The input is first clamped to [-1, 1], so out-of-range values saturate
    // to +/-32767 (symmetric, equal magnitude, no asymmetric clip). We never emit
    // the asymmetric int16 floor -32768 — that's the intended, DC-offset-free behavior.
    check("zero",              floatToInt16(0.0),       0)
    check("full-positive",     floatToInt16(1.0),       32767)
    check("full-negative",     floatToInt16(-1.0),     -32767)   // symmetric
    check("over-positive",     floatToInt16(1.5),       32767)   // clamp to +peak
    check("over-negative",     floatToInt16(-2.0),     -32767)   // clamp to -peak (symmetric)
    check("half-positive",     floatToInt16(0.5),       16384)   // round(16383.5)
    check("half-negative",     floatToInt16(-0.5),     -16384)   // round(-16383.5)
    check("nan-is-zero",       floatToInt16(Float.nan), 0)
    check("tiny-positive",     floatToInt16(0.00001),   0)       // rounds to 0
    check("quarter",           floatToInt16(0.25),      8192)    // round(8191.75)

    // Byte-order + buffering: convert a 4-sample interleaved block and confirm
    // little-endian byte layout.
    let samples: [Float] = [0.0, 1.0, -1.0, 0.5]
    var bytes = [UInt8](repeating: 0, count: samples.count * 2)
    samples.withUnsafeBufferPointer { sp in
        bytes.withUnsafeMutableBufferPointer { bp in
            convertFloat32ToS16LE(sp.baseAddress!, count: samples.count, into: bp.baseAddress!)
        }
    }
    // Expected int16s: 0, 32767, -32767, 16384 (symmetric scaling)
    // LE bytes: 0->00 00 ; 32767->FF 7F ; -32767->01 80 ; 16384->00 40
    let wantBytes: [UInt8] = [0x00, 0x00, 0xFF, 0x7F, 0x01, 0x80, 0x00, 0x40]
    if bytes == wantBytes {
        elog("PASS  s16le-byte-layout: \(bytes.map { String(format: "%02X", $0) }.joined(separator: " "))")
    } else {
        elog("FAIL  s16le-byte-layout: got \(bytes.map { String(format: "%02X", $0) }.joined(separator: " ")), "
            + "expected \(wantBytes.map { String(format: "%02X", $0) }.joined(separator: " "))")
        failures += 1
    }

    if failures == 0 {
        elog("SELFTEST: PASS (all conversion checks passed)")
        return 0
    } else {
        elog("SELFTEST: FAIL (\(failures) check(s) failed)")
        return 1
    }
}
