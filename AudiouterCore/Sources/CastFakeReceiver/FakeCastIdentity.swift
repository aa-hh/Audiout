// Copyright (C) 2026 ahh and contributors.
//
// LICENSE-CLEAN by design: this file carries NO GPL SPDX header. It is a
// clean-room Google Cast (CASTV2) implementation written from the public wire
// behaviour only; no code was copied from any GPL/LGPL project. Do not add a
// GPL header to this file and do not move GPL-derived code into it.

import CastSender
import Foundation
import Network
import Security

/// The fake receiver's TLS identity.
///
/// A THROWAWAY self-signed RSA-2048 key, generated once with `openssl req
/// -x509 … -subj "/CN=fake-cast"`, exported as PKCS#12 with the passphrase
/// `fake`, and pasted in below as base64. It secures nothing: a real receiver
/// presents its own certificate, and the sender accepts any certificate anyway
/// (`sec_protocol_options_set_verify_block` → `complete(true)`). Dev and test
/// only — never used by the shipping app, never used against real hardware.
///
/// `kSecImportToMemoryOnly` is what keeps a test run out of the login keychain:
/// without it `SecPKCS12Import` writes the key there and macOS prompts. That
/// option is macOS 15+, which is where this type's availability comes from.
@available(macOS 15, *)
enum FakeCastIdentity {

    /// The passphrase the PKCS#12 blob below was exported with.
    private static let passphrase = "fake"

    static func load() throws -> sec_identity_t {
        guard let blob = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
            throw CastError.connectionFailed("the embedded PKCS#12 blob is not valid base64")
        }
        var items: CFArray?
        let options: [String: Any] = [
            kSecImportExportPassphrase as String: passphrase,
            kSecImportToMemoryOnly as String: true,
        ]
        let status = SecPKCS12Import(blob as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess,
              let entries = items as? [[String: Any]],
              let identity = entries.first?[kSecImportItemIdentity as String],
              CFGetTypeID(identity as CFTypeRef) == SecIdentityGetTypeID() else {
            throw CastError.connectionFailed("SecPKCS12Import failed with status \(status)")
        }
        guard let wrapped = sec_identity_create(identity as! SecIdentity) else {
            throw CastError.connectionFailed("sec_identity_create returned nil")
        }
        return wrapped
    }

    private static let base64 = """
        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
        GgICCAA=
        """
}
