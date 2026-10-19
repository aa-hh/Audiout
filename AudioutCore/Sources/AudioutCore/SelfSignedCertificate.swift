// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The DER bytes of the companion link's self-signed X.509 v3 certificate.
/// `Security` parses certificates but has no public call that makes one, so
/// this assembles the one fixed shape the link needs: ECDSA P-256 with
/// SHA-256, issuer and subject both `CN=Audiout Remote`, a critical
/// basicConstraints that is not a CA, and extKeyUsage serverAuth.
///
/// Nobody evaluates this certificate's chain. The phone pins the SHA-256 of
/// these exact bytes (the Bonjour TXT `fp` key), so the only requirements are
/// that Security's own parser accepts them and that TLS can present them.
enum SelfSignedCertificate {

    /// The subject and issuer common name of every certificate this makes.
    static let commonName = "Audiout Remote"

    /// `sign` receives the DER `tbsCertificate` and returns the DER
    /// `SEQUENCE { r, s }` that `SecKeyCreateSignature(_,
    /// .ecdsaSignatureMessageX962SHA256, _)` produces; it is placed in the
    /// signature BIT STRING as is. `publicKeyX963` is the 65-byte uncompressed
    /// point, `serial` 16 random bytes (its first byte is forced positive and
    /// non-zero so the INTEGER needs no padding). Both dates must fall before
    /// 2050, the end of UTCTime.
    static func der(publicKeyX963: Data, notBefore: Date, notAfter: Date, serial: Data,
                    sign: (Data) throws -> Data) throws -> Data {
        precondition(serial.count == 16, "the serial is 16 random bytes")
        var serialBytes = [UInt8](serial)
        serialBytes[0] = (serialBytes[0] & 0x7F) | 0x01

        let signatureAlgorithm = Data([0x30, 0x0A, 0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02])
        let commonName = Data([0x06, 0x03, 0x55, 0x04, 0x03]) + tlv(0x0C, Data(commonName.utf8))
        let name = sequence(setOf(sequence(commonName)))
        let validity = sequence(utcTime(notBefore) + utcTime(notAfter))
        let ecPublicKey = Data([0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01])
        let prime256v1 = Data([0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07])
        let subjectPublicKeyInfo = sequence(sequence(ecPublicKey + prime256v1) + bitString(publicKeyX963))
        let basicConstraints = sequence(Data([0x06, 0x03, 0x55, 0x1D, 0x13])
                                        + Data([0x01, 0x01, 0xFF])
                                        + tlv(0x04, Data([0x30, 0x00])))
        let serverAuth = Data([0x06, 0x08, 0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01])
        let extKeyUsage = sequence(Data([0x06, 0x03, 0x55, 0x1D, 0x25]) + tlv(0x04, sequence(serverAuth)))
        let extensions = tlv(0xA3, sequence(basicConstraints + extKeyUsage))

        let version3 = Data([0xA0, 0x03, 0x02, 0x01, 0x02])
        let tbs = sequence(version3 + tlv(0x02, Data(serialBytes)) + signatureAlgorithm
                           + name + validity + name + subjectPublicKeyInfo + extensions)
        return sequence(tbs + signatureAlgorithm + bitString(try sign(tbs)))
    }

    /// Tag, DER length (short form below 128, else `81 n` or `82 n n`), value.
    private static func tlv(_ tag: UInt8, _ value: Data) -> Data {
        var out = Data([tag])
        let count = value.count
        if count < 0x80 {
            out.append(UInt8(count))
        } else if count < 0x100 {
            out += [0x81, UInt8(count)]
        } else {
            out += [0x82, UInt8(count >> 8), UInt8(count & 0xFF)]
        }
        return out + value
    }

    private static func sequence(_ value: Data) -> Data { tlv(0x30, value) }

    private static func setOf(_ value: Data) -> Data { tlv(0x31, value) }

    /// A BIT STRING with no unused bits.
    private static func bitString(_ value: Data) -> Data { tlv(0x03, Data([0x00]) + value) }

    /// `YYMMDDHHMMSSZ` in UTC.
    private static func utcTime(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        return tlv(0x17, Data(formatter.string(from: date).utf8))
    }
}
