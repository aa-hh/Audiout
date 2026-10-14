// SPDX-License-Identifier: GPL-2.0-or-later

import CryptoKit
import Foundation
import Security

/// The Mac's TLS identity on the companion link: a P-256 key in the login
/// keychain and the self-signed certificate over it. The phone pins
/// ``fingerprint``, so the same identity must come back on every launch — a
/// new one makes every paired phone refuse this Mac as a stranger.
public struct CompanionIdentity: @unchecked Sendable {
    public let secIdentity: SecIdentity
    public let certificateDER: Data

    /// SHA-256 of ``certificateDER``: what the Bonjour TXT `fp` key carries
    /// and what the phone compares the TLS leaf certificate against.
    public var fingerprint: Data { Data(SHA256.hash(data: certificateDER)) }
}

public protocol CompanionIdentityStoring {
    /// The stored identity, or a new one created and stored on first use.
    func loadOrCreate() throws -> CompanionIdentity
}

public enum CompanionIdentityError: Error {
    /// A keychain or key call failed with this status.
    case keychain(OSStatus)
    /// `SecCertificateCreateWithData` refused the assembled DER.
    case unreadableCertificate
    /// The certificate was stored but no identity formed from it and its key.
    case identityNotFound
}

/// The identity in the login keychain: a permanent EC key and a certificate,
/// both under ``label``, which the keychain pairs into one `SecIdentity`.
public final class KeychainCompanionIdentityStore: CompanionIdentityStoring {
    private let label: String

    public init(label: String = "Audiout Remote link") {
        self.label = label
    }

    public func loadOrCreate() throws -> CompanionIdentity {
        if let stored = try findIdentity() { return stored }
        return try createIdentity()
    }

    /// Deletes this label's certificate and keys. For tests only: the app
    /// never removes its identity, because a new one changes the fingerprint
    /// every paired phone pinned.
    public func removeAll() {
        SecItemDelete([kSecClass as String: kSecClassCertificate,
                       kSecAttrLabel as String: label] as CFDictionary)
        SecItemDelete([kSecClass as String: kSecClassKey,
                       kSecAttrLabel as String: label] as CFDictionary)
    }

    private func findIdentity() throws -> CompanionIdentity? {
        let query: [String: Any] = [kSecClass as String: kSecClassIdentity,
                                    kSecAttrLabel as String: label,
                                    kSecReturnRef as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let result,
              CFGetTypeID(result) == SecIdentityGetTypeID() else {
            throw CompanionIdentityError.keychain(status)
        }
        let identity = result as! SecIdentity
        var certificate: SecCertificate?
        let copyStatus = SecIdentityCopyCertificate(identity, &certificate)
        guard copyStatus == errSecSuccess, let certificate else {
            throw CompanionIdentityError.keychain(copyStatus)
        }
        return CompanionIdentity(secIdentity: identity,
                                 certificateDER: SecCertificateCopyData(certificate) as Data)
    }

    private func createIdentity() throws -> CompanionIdentity {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrIsPermanent as String: true,
            kSecAttrLabel as String: label,
            kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: true,
                                            kSecAttrLabel as String: label],
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw Self.failure(error)
        }
        guard let publicKey = SecKeyCopyPublicKey(key),
              let x963 = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw Self.failure(error)
        }

        var serial = Data(count: 16)
        let randomStatus = serial.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!)
        }
        guard randomStatus == errSecSuccess else { throw CompanionIdentityError.keychain(randomStatus) }

        let now = Date()
        let der = try SelfSignedCertificate.der(
            publicKeyX963: x963,
            notBefore: now.addingTimeInterval(-86_400),
            notAfter: Calendar(identifier: .gregorian).date(byAdding: .year, value: 10, to: now)!,
            serial: serial
        ) { tbs in
            var signError: Unmanaged<CFError>?
            guard let signature = SecKeyCreateSignature(
                key, .ecdsaSignatureMessageX962SHA256, tbs as CFData, &signError) as Data? else {
                throw Self.failure(signError)
            }
            return signature
        }
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw CompanionIdentityError.unreadableCertificate
        }
        let addStatus = SecItemAdd([kSecClass as String: kSecClassCertificate,
                                    kSecValueRef as String: certificate,
                                    kSecAttrLabel as String: label] as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw CompanionIdentityError.keychain(addStatus) }
        guard let identity = try findIdentity() else { throw CompanionIdentityError.identityNotFound }
        return identity
    }

    private static func failure(_ error: Unmanaged<CFError>?) -> CompanionIdentityError {
        guard let error = error?.takeRetainedValue() else { return .keychain(errSecInternalError) }
        return .keychain(OSStatus(truncatingIfNeeded: CFErrorGetCode(error)))
    }
}
