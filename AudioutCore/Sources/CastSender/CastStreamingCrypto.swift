// Copyright (C) 2026 ahh and contributors.
//
// LICENSE-CLEAN by design: this file carries NO GPL SPDX header. It is a
// clean-room Google Cast (CASTV2) implementation written from the public wire
// behaviour only; no code was copied from any GPL/LGPL project. Do not add a
// GPL header to this file and do not move GPL-derived code into it.

import CommonCrypto
import Foundation
import Security

/// Cast Streaming payload encryption: AES-128-CTR, keyed per session by the
/// OFFER's `aesKey`, with a per-frame nonce derived from the frame id and the
/// OFFER's `aesIvMask`. The counter restarts at zero for every frame, so
/// encrypting and decrypting are the same call.
public struct CastFrameCrypto: Equatable, Sendable {
    public let key: [UInt8]
    public let ivMask: [UInt8]

    public init(key: [UInt8], ivMask: [UInt8]) {
        precondition(key.count == 16 && ivMask.count == 16, "AES-128 key and IV mask are 16 bytes each")
        self.key = key
        self.ivMask = ivMask
    }

    /// Parses the OFFER's two 32-hex-digit fields; nil when either is malformed.
    public init?(hexKey: String, hexIVMask: String) {
        guard let key = Self.bytes(fromHex: hexKey), let mask = Self.bytes(fromHex: hexIVMask) else { return nil }
        self.init(key: key, ivMask: mask)
    }

    public static func random() -> CastFrameCrypto {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return CastFrameCrypto(key: Array(bytes[0..<16]), ivMask: Array(bytes[16..<32]))
    }

    public var hexKey: String { Self.hex(key) }
    public var hexIVMask: String { Self.hex(ivMask) }

    /// Sixteen zero bytes with the frame id's low 32 bits big-endian at offset
    /// 8, XORed byte-wise with the IV mask.
    public static func nonce(frameID: UInt32, ivMask: [UInt8]) -> [UInt8] {
        var nonce = [UInt8](repeating: 0, count: 16)
        nonce[8] = UInt8(truncatingIfNeeded: frameID >> 24)
        nonce[9] = UInt8(truncatingIfNeeded: frameID >> 16)
        nonce[10] = UInt8(truncatingIfNeeded: frameID >> 8)
        nonce[11] = UInt8(truncatingIfNeeded: frameID)
        for i in 0..<16 { nonce[i] ^= ivMask[i] }
        return nonce
    }

    public func crypt(frameID: UInt32, _ data: Data) -> Data {
        let nonce = Self.nonce(frameID: frameID, ivMask: ivMask)
        var cryptor: CCCryptorRef?
        let created = CCCryptorCreateWithMode(
            CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding),
            nonce, key, key.count, nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &cryptor)
        precondition(created == kCCSuccess, "CCCryptorCreateWithMode failed: \(created)")
        defer { CCCryptorRelease(cryptor) }
        let input = [UInt8](data)
        var output = [UInt8](repeating: 0, count: input.count)
        var moved = 0
        let updated = CCCryptorUpdate(cryptor, input, input.count, &output, output.count, &moved)
        precondition(updated == kCCSuccess && moved == input.count, "CCCryptorUpdate failed: \(updated)")
        return Data(output)
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func bytes(fromHex text: String) -> [UInt8]? {
        let chars = Array(text.utf8)
        guard chars.count == 32 else { return nil }
        var out: [UInt8] = []
        for i in stride(from: 0, to: 32, by: 2) {
            guard let byte = UInt8(String(decoding: chars[i...i + 1], as: UTF8.self), radix: 16) else { return nil }
            out.append(byte)
        }
        return out
    }
}
