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
/// The handshake test writes to the login keychain under a label unique to
/// the run and deletes it again; its listener is bound to `127.0.0.1` only,
/// so it never advertises or trips the Application Firewall.
@Suite struct CompanionIdentityTests {

    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T
        init(_ value: T) { stored = value }
        var value: T {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
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
        #expect(SecCertificateCopySubjectSummary(certificate) as String? == "Audiout Remote")
    }

    /// Turns red if the keychain identity cannot be presented by a TLS 1.3
    /// listener, or if the certificate the client sees on the wire hashes to
    /// anything but `CompanionIdentity.fingerprint` — the value the Mac
    /// advertises and the phone pins.
    @Test func aLoopbackTLSHandshakeSucceedsWithTheGeneratedIdentity() async throws {
        let store = KeychainCompanionIdentityStore(label: "Audiout Remote link test \(UUID().uuidString)")
        defer { store.removeAll() }
        let identity = try store.loadOrCreate()
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
