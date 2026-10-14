// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Security

/// What a ``SecretStoring`` read found.
public enum SecretRead: Equatable, Sendable {
    case value(String)
    /// Nothing is stored under the key.
    case missing
    /// The store would not answer (a locked login keychain, a dismissed access
    /// prompt), so a value may still be there.
    case refused
}

/// Where ``AppSettings`` keeps the two values that unlock the app and the
/// iPhone (the licence key and the companion token), so they are not plain text
/// in the preferences file. `write(nil, ...)` deletes. `write` answers true
/// only when the store now holds exactly `value`, or, for `nil`, holds nothing
/// under `key`; a caller must keep its own copy of a value the store refused.
public protocol SecretStoring {
    func read(_ key: String) -> SecretRead
    func write(_ value: String?, for key: String) -> Bool
}

/// Generic-password Keychain items under one service, `<bundle id>.license`,
/// with the settings key as the account. Same shape as
/// ``KeychainAirPlayPasswordStore``: no sandbox, so the items land in the login
/// keychain with an access list pinned to the signing identity.
public final class KeychainSecretStore: SecretStoring {
    private let service = (Bundle.main.bundleIdentifier ?? "com.audiout.Audiout") + ".license"

    public init() {}

    public func read(_ key: String) -> SecretRead {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        guard status != errSecItemNotFound else { return .missing }
        guard status == errSecSuccess else {
            report(status, operation: "read")
            return .refused
        }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else { return .missing }
        return .value(value)
    }

    public func write(_ value: String?, for key: String) -> Bool {
        guard delete(key, operation: "save") else { return false }
        guard let value else { return true }
        var q = query(key)
        q[kSecAttrLabel as String] = "Audiout licence"
        q[kSecValueData as String] = Data(value.utf8)
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else {
            report(status, operation: "save")
            return false
        }
        return true
    }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private func delete(_ account: String, operation: String) -> Bool {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            report(status, operation: operation)
            return false
        }
        return true
    }

    /// A local log line only: the account is a settings key, the value is never logged.
    private func report(_ status: OSStatus, operation: String) {
        Telemetry.log(.settings, "secret_store_failed", ["operation": operation, "status": "\(status)"])
    }
}

/// Keeps the values in a `UserDefaults`, under the same keys ``AppSettings``
/// always used. What `AppSettings` picks under `swift test` (and in headless
/// tools), so suites that set a key through a throwaway suite never touch the
/// real login keychain.
public struct DefaultsSecretStore: SecretStoring {
    private let defaults: UserDefaults

    public init(_ defaults: UserDefaults) { self.defaults = defaults }

    public func read(_ key: String) -> SecretRead { defaults.string(forKey: key).map(SecretRead.value) ?? .missing }

    public func write(_ value: String?, for key: String) -> Bool {
        defaults.set(value, forKey: key)
        return true
    }
}
