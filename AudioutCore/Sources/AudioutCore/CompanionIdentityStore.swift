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
/// both under ``label``, with the key also carrying ``label`` as its
/// application tag.
///
/// Lookup never asks the keychain for an identity. A `kSecClassIdentity`
/// query on the file-based login keychain ignores `kSecAttrLabel`, so it
/// handed back whatever identity came first: on the owner's Mac that was the
/// Apple Distribution identity, whose certificate (real name, team id) every
/// TLS handshake then presented to the LAN. Instead this finds its own
/// certificate and its own private key by label and tag, checks both
/// attributes in code rather than trusting the query to have applied them,
/// pairs them with `SecIdentityCreateWithCertificate`, and returns the pair
/// only when the certificate is the self-signed `CN=Audiout Remote` one and
/// the identity's private key matches the public key the certificate carries.
///
/// Not the data protection keychain (`kSecUseDataProtectionKeychain`): on
/// macOS it needs a `keychain-access-groups` or `application-identifier`
/// entitlement, which only a provisioning profile can grant, and
/// `scripts/make-app.sh` signs with Developer ID and no profile.
public final class KeychainCompanionIdentityStore: CompanionIdentityStoring {
    private let label: String
    private let tag: Data
    private let keychain: SecKeychain?

    /// `keychain` confines every read and write to that one keychain; tests
    /// pass a throwaway one. `nil` writes to the default (login) keychain and
    /// reads the user's keychain search list.
    public init(label: String = "Audiout Remote link", keychain: SecKeychain? = nil) {
        self.label = label
        self.tag = Data(label.utf8)
        self.keychain = keychain
    }

    public func loadOrCreate() throws -> CompanionIdentity {
        if let stored = try findIdentity() { return stored }
        // Every query above succeeded and no certificate of ours pairs with a
        // key of ours: what is left is a half-written identity (a key with no
        // certificate, a certificate whose key is gone) or one from before
        // keys carried the tag. Delete only items carrying our own label or
        // tag, then make a fresh pair, so the next launch finds exactly one.
        try removeOwnItems()
        return try createIdentity()
    }

    private func findIdentity() throws -> CompanionIdentity? {
        let certificates = try ownItems([kSecClass as String: kSecClassCertificate,
                                         kSecAttrLabel as String: label]) {
            $0[kSecAttrLabel as String] as? String == label
        }
        let keys = try ownItems([kSecClass as String: kSecClassKey,
                                 kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
                                 kSecAttrApplicationTag as String: tag]) {
            $0[kSecAttrApplicationTag as String] as? Data == tag
        }
        let ownPublicKeys = keys.compactMap { item -> Data? in
            guard let ref = item[kSecValueRef as String], CFGetTypeID(ref as CFTypeRef) == SecKeyGetTypeID()
            else { return nil }
            return Self.publicKeyBytes(ofPrivate: ref as! SecKey)
        }
        for item in certificates {
            guard let ref = item[kSecValueRef as String],
                  CFGetTypeID(ref as CFTypeRef) == SecCertificateGetTypeID() else { continue }
            let certificate = ref as! SecCertificate
            guard Self.isOurSelfSigned(certificate),
                  let certificateKey = SecCertificateCopyKey(certificate)
                    .flatMap({ SecKeyCopyExternalRepresentation($0, nil) as Data? }),
                  ownPublicKeys.contains(certificateKey) else { continue }

            var identity: SecIdentity?
            let status = SecIdentityCreateWithCertificate(keychain, certificate, &identity)
            if status == errSecItemNotFound { continue }
            guard status == errSecSuccess, let identity else { throw CompanionIdentityError.keychain(status) }
            var privateKey: SecKey?
            guard SecIdentityCopyPrivateKey(identity, &privateKey) == errSecSuccess,
                  let privateKey, Self.publicKeyBytes(ofPrivate: privateKey) == certificateKey else { continue }
            return CompanionIdentity(secIdentity: identity,
                                     certificateDER: SecCertificateCopyData(certificate) as Data)
        }
        return nil
    }

    /// The items `match` finds, with refs and attributes, kept only where
    /// `isOurs` holds. An empty result is `[]`; any other failure throws, so a
    /// locked keychain never reads as "nothing stored" and triggers a delete.
    private func ownItems(_ match: [String: Any],
                          isOurs: ([String: Any]) -> Bool) throws -> [[String: Any]] {
        var query = match
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnRef as String] = true
        query[kSecReturnAttributes as String] = true
        if let keychain { query[kSecMatchSearchList as String] = [keychain] }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw CompanionIdentityError.keychain(status) }
        return (result as? [[String: Any]] ?? []).filter(isOurs)
    }

    /// Deletes, one reference at a time, the certificates under ``label`` and
    /// the keys under ``label`` or ``tag``. The attribute is re-checked on
    /// each returned item, so a query that ignored its label cannot widen
    /// this to anyone else's certificate or key.
    private func removeOwnItems() throws {
        let label = label, tag = tag
        let searches: [([String: Any], ([String: Any]) -> Bool)] = [
            ([kSecClass as String: kSecClassCertificate, kSecAttrLabel as String: label],
             { $0[kSecAttrLabel as String] as? String == label }),
            ([kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: tag],
             { $0[kSecAttrApplicationTag as String] as? Data == tag }),
            ([kSecClass as String: kSecClassKey, kSecAttrLabel as String: label],
             { $0[kSecAttrLabel as String] as? String == label }),
        ]
        // One search at a time, deleting before the next runs: a key carrying
        // both the tag and the label is gone before the label search looks.
        for (match, isOurs) in searches {
            for item in try ownItems(match, isOurs: isOurs) {
                guard let ref = item[kSecValueRef as String] else { continue }
                let status = SecItemDelete([kSecValueRef as String: ref] as CFDictionary)
                guard status == errSecSuccess || status == errSecItemNotFound else {
                    throw CompanionIdentityError.keychain(status)
                }
            }
        }
    }

    /// Issuer and subject are the same name and its common name is exactly
    /// the one `SelfSignedCertificate` writes.
    private static func isOurSelfSigned(_ certificate: SecCertificate) -> Bool {
        var commonName: CFString?
        guard SecCertificateCopyCommonName(certificate, &commonName) == errSecSuccess,
              commonName as String? == SelfSignedCertificate.commonName,
              let subject = SecCertificateCopyNormalizedSubjectSequence(certificate),
              let issuer = SecCertificateCopyNormalizedIssuerSequence(certificate) else { return false }
        return (subject as Data) == (issuer as Data)
    }

    private static func publicKeyBytes(ofPrivate key: SecKey) -> Data? {
        SecKeyCopyPublicKey(key).flatMap { SecKeyCopyExternalRepresentation($0, nil) as Data? }
    }

    private func createIdentity() throws -> CompanionIdentity {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrIsPermanent as String: true,
            kSecAttrLabel as String: label,
            kSecAttrApplicationTag as String: tag,
            kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: true,
                                            kSecAttrLabel as String: label,
                                            kSecAttrApplicationTag as String: tag],
        ].merging(keychain.map { [kSecUseKeychain as String: $0] } ?? [:]) { $1 }
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
        // The file keychain ignores `kSecAttrLabel` on this add and labels the
        // certificate with its common name, so the label goes on afterwards,
        // to the certificate found by its public key hash (SHA-1 of the point).
        var add: [String: Any] = [kSecClass as String: kSecClassCertificate,
                                  kSecValueRef as String: certificate]
        if let keychain { add[kSecUseKeychain as String] = keychain }
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw CompanionIdentityError.keychain(addStatus) }
        let keyHash = Data(Insecure.SHA1.hash(data: x963))
        for item in try ownItems([kSecClass as String: kSecClassCertificate,
                                  kSecAttrPublicKeyHash as String: keyHash],
                                 isOurs: { $0[kSecAttrPublicKeyHash as String] as? Data == keyHash }) {
            guard let ref = item[kSecValueRef as String] else { continue }
            let labelStatus = SecItemUpdate([kSecValueRef as String: ref] as CFDictionary,
                                            [kSecAttrLabel as String: label] as CFDictionary)
            guard labelStatus == errSecSuccess else { throw CompanionIdentityError.keychain(labelStatus) }
        }
        guard let identity = try findIdentity() else { throw CompanionIdentityError.identityNotFound }
        return identity
    }

    private static func failure(_ error: Unmanaged<CFError>?) -> CompanionIdentityError {
        guard let error = error?.takeRetainedValue() else { return .keychain(errSecInternalError) }
        return .keychain(OSStatus(truncatingIfNeeded: CFErrorGetCode(error)))
    }
}
