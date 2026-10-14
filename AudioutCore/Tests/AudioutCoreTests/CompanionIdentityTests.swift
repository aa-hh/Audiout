// SPDX-License-Identifier: GPL-2.0-or-later

import CryptoKit
import Foundation
import Network
import Security
import Testing
@testable import AudioutCore

/// The companion link's hand-assembled certificate and the keychain identity
/// built on it. Security's own parser and a real TLS 1.3 handshake are the
/// judges: nothing else in the system reads these bytes.
///
/// Every keychain test writes only to a throwaway file keychain made for that
/// test and deleted after it, never the login keychain: the login keychain
/// holds the owner's own identities, and over ssh it cannot be unlocked at
/// all. Serialized because creating and deleting a keychain each rewrite the
/// user's keychain search list. The handshake's listener is bound to
/// `127.0.0.1` only, so it never advertises or trips the Application Firewall.
@Suite(.serialized) struct CompanionIdentityTests {

    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T
        init(_ value: T) { stored = value }
        var value: T {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    /// A new, unlocked keychain file in the temporary folder. The caller
    /// deletes it with `SecKeychainDelete`, which also drops it from the
    /// search list.
    private static func scratchKeychain() throws -> SecKeychain {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("audiout-identity-test-\(UUID().uuidString).keychain").path
        var keychain: SecKeychain?
        let status = SecKeychainCreate(path, 4, "test", false, nil, &keychain)
        try #require(status == errSecSuccess, "SecKeychainCreate failed: \(status)")
        return try #require(keychain)
    }

    /// The items of `match` in `keychain` alone.
    private static func items(_ match: [String: Any], in keychain: SecKeychain) -> [[String: Any]] {
        var query = match
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnRef as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchSearchList as String] = [keychain]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return [] }
        return result as? [[String: Any]] ?? []
    }

    private static func certificates(_ label: String, in keychain: SecKeychain) -> [[String: Any]] {
        items([kSecClass as String: kSecClassCertificate, kSecAttrLabel as String: label], in: keychain)
    }

    private static func privateKeys(_ label: String, in keychain: SecKeychain) -> [[String: Any]] {
        items([kSecClass as String: kSecClassKey, kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
               kSecAttrApplicationTag as String: Data(label.utf8)], in: keychain)
    }

    private static func commonName(of identity: CompanionIdentity) -> String? {
        guard let certificate = SecCertificateCreateWithData(nil, identity.certificateDER as CFData) else { return nil }
        var name: CFString?
        SecCertificateCopyCommonName(certificate, &name)
        return name as String?
    }

    /// Turns red if the store returns any identity it did not make itself —
    /// the 2026-10-15 bug, where a `kSecClassIdentity` query ignored its label
    /// and the Mac presented the owner's Apple Distribution certificate on
    /// every handshake. A second identity under another label sits in the
    /// same keychain; the store must make and return its own.
    @Test func anotherIdentityInTheKeychainIsNeverReturned() throws {
        let keychain = try Self.scratchKeychain()
        defer { SecKeychainDelete(keychain) }
        let decoy = try KeychainCompanionIdentityStore(label: "Someone else's identity", keychain: keychain)
            .loadOrCreate()

        let label = "Audiout Remote link"
        let ours = try KeychainCompanionIdentityStore(label: label, keychain: keychain).loadOrCreate()

        #expect(ours.fingerprint != decoy.fingerprint)
        #expect(Self.commonName(of: ours) == SelfSignedCertificate.commonName)
        let stored = Self.certificates(label, in: keychain).compactMap { $0[kSecValueRef as String] }
            .map { SecCertificateCopyData($0 as! SecCertificate) as Data }
        #expect(stored == [ours.certificateDER], "the returned certificate is not the one stored under our label")
    }

    /// Turns red if a second load makes a new identity instead of finding the
    /// stored one: the fingerprint changes and every paired phone sees this
    /// Mac as a stranger.
    @Test func theStoredIdentityComesBackOnTheNextLoad() throws {
        let keychain = try Self.scratchKeychain()
        defer { SecKeychainDelete(keychain) }
        let first = try KeychainCompanionIdentityStore(keychain: keychain).loadOrCreate()
        let second = try KeychainCompanionIdentityStore(keychain: keychain).loadOrCreate()
        #expect(second.fingerprint == first.fingerprint)
    }

    /// Turns red if a half-written identity — a key whose certificate is
    /// gone, or a certificate whose key is gone — is returned, throws, or
    /// leaves its leftover beside the replacement, so the next launch could
    /// pick either.
    @Test(arguments: ["certificate", "private key"])
    func aHalfWrittenIdentityIsReplacedByOneWholeOne(missing: String) throws {
        let keychain = try Self.scratchKeychain()
        defer { SecKeychainDelete(keychain) }
        let label = "Audiout Remote link"
        let store = KeychainCompanionIdentityStore(label: label, keychain: keychain)
        let original = try store.loadOrCreate()
        let gone = missing == "certificate" ? Self.certificates(label, in: keychain)
                                            : Self.privateKeys(label, in: keychain)
        try #require(gone.count == 1)
        try #require(SecItemDelete([kSecValueRef as String: gone[0][kSecValueRef as String]!] as CFDictionary)
                     == errSecSuccess)

        let replacement = try store.loadOrCreate()

        #expect(replacement.fingerprint != original.fingerprint)
        #expect(Self.certificates(label, in: keychain).count == 1)
        #expect(Self.privateKeys(label, in: keychain).count == 1)
        #expect(try store.loadOrCreate().fingerprint == replacement.fingerprint)
    }

    /// Turns red if `SelfSignedCertificate.der` produces bytes Security cannot
    /// parse, or a certificate that does not carry the key it was built for
    /// or the `Audiout Remote` name.
    @Test func theGeneratedCertificateParsesAndCarriesTheKey() throws {
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                                         kSecAttrKeySizeInBits as String: 256]
        let key = try #require(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let publicKey = try #require(SecKeyCopyPublicKey(key))
        let x963 = try #require(SecKeyCopyExternalRepresentation(publicKey, nil) as Data?)

        let now = Date()
        let der = try SelfSignedCertificate.der(publicKeyX963: x963,
                                                notBefore: now.addingTimeInterval(-86_400),
                                                notAfter: now.addingTimeInterval(86_400),
                                                serial: Data(repeating: 0xFF, count: 16)) { tbs in
            try #require(SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, tbs as CFData, nil) as Data?)
        }

        let certificate = try #require(SecCertificateCreateWithData(nil, der as CFData),
                                       "Security refused the assembled DER")
        let certificateKey = try #require(SecCertificateCopyKey(certificate))
        #expect(SecKeyCopyExternalRepresentation(certificateKey, nil) as Data? == x963)
        #expect(SecCertificateCopySubjectSummary(certificate) as String? == SelfSignedCertificate.commonName)
    }

    /// Turns red if the keychain identity cannot be presented by a TLS 1.3
    /// listener, or if the certificate the client sees on the wire hashes to
    /// anything but `CompanionIdentity.fingerprint` — the value the Mac
    /// advertises and the phone pins.
    @Test func aLoopbackTLSHandshakeSucceedsWithTheGeneratedIdentity() async throws {
        let keychain = try Self.scratchKeychain()
        defer { SecKeychainDelete(keychain) }
        let identity = try KeychainCompanionIdentityStore(keychain: keychain).loadOrCreate()
        let queue = DispatchQueue(label: "CompanionIdentityTests.loopback")

        let serverTLS = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(serverTLS.securityProtocolOptions,
                                                try #require(sec_identity_create(identity.secIdentity)))
        sec_protocol_options_set_min_tls_protocol_version(serverTLS.securityProtocolOptions, .TLSv13)
        let serverParameters = NWParameters(tls: serverTLS)
        serverParameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: serverParameters)
        defer { listener.cancel() }
        let accepted = Box<[NWConnection]>([])
        defer { accepted.value.forEach { $0.cancel() } }
        let listenerReady = Box(false)
        listener.newConnectionHandler = { connection in
            accepted.value.append(connection)
            connection.start(queue: queue)
        }
        listener.stateUpdateHandler = { state in
            if case .ready = state { listenerReady.value = true }
        }
        listener.start(queue: queue)
        await SuiteWait.until("the loopback listener is ready") { listenerReady.value }
        let port = try #require(listener.port)
        try #require(port.rawValue != 0, "listener port never left the placeholder 0")

        let clientTLS = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(clientTLS.securityProtocolOptions, .TLSv13)
        let expected = identity.fingerprint
        let pinned = Box<Bool?>(nil)
        sec_protocol_options_set_verify_block(clientTLS.securityProtocolOptions, { _, trust, complete in
            let chain = SecTrustCopyCertificateChain(sec_trust_copy_ref(trust).takeRetainedValue()) as? [SecCertificate]
            let leaf = chain?.first.map { SecCertificateCopyData($0) as Data }
            let matches = leaf.map { Data(SHA256.hash(data: $0)) == expected } ?? false
            pinned.value = matches
            complete(matches)
        }, queue)
        let client = NWConnection(host: "127.0.0.1", port: port, using: NWParameters(tls: clientTLS))
        defer { client.cancel() }
        let ready = Box(false)
        client.stateUpdateHandler = { state in
            if case .ready = state { ready.value = true }
        }
        client.start(queue: queue)

        await SuiteWait.until("the client completes the TLS handshake") { ready.value }
        #expect(pinned.value == true, "the leaf certificate on the wire is not the one the fingerprint names")
    }
}
