import Foundation
import Security

/// Per-speaker AirPlay passwords and on-screen-code pairing keys, keyed by `Device.id`.
public protocol AirPlayPasswordStoring: Sendable {
    func password(for deviceID: String) -> String?
    func setPassword(_ password: String, for deviceID: String)
    func removePassword(for deviceID: String)
    func pairingKey(for deviceID: String) -> String?
    func setPairingKey(_ key: String, for deviceID: String)
    func removePairingKey(for deviceID: String)
}

/// Session-only store: what a backend built without a store uses, and what tests inject.
public final class InMemoryAirPlayPasswordStore: AirPlayPasswordStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var passwords: [String: String] = [:]
    private var pairingKeys: [String: String] = [:]

    public init() {}

    public func password(for deviceID: String) -> String? {
        lock.withLock { passwords[deviceID] }
    }

    public func setPassword(_ password: String, for deviceID: String) {
        lock.withLock { passwords[deviceID] = password }
    }

    public func removePassword(for deviceID: String) {
        lock.withLock { _ = passwords.removeValue(forKey: deviceID) }
    }

    public func pairingKey(for deviceID: String) -> String? {
        lock.withLock { pairingKeys[deviceID] }
    }

    public func setPairingKey(_ key: String, for deviceID: String) {
        lock.withLock { pairingKeys[deviceID] = key }
    }

    public func removePairingKey(for deviceID: String) {
        lock.withLock { _ = pairingKeys.removeValue(forKey: deviceID) }
    }
}

/// Generic-password Keychain items under one service, `<bundle id>.airplay-password`:
/// a speaker's password has the device id as its account, and its pairing key
/// has the device id plus `/pairing-key`.
///
/// The app is not sandboxed, so the items land in the login keychain with an
/// access list pinned to the signing identity. A Developer ID build keeps that
/// identity across rebuilds; an ad-hoc build is asked again once per rebuild.
/// No entitlement or `make-app.sh` change is involved.
public final class KeychainAirPlayPasswordStore: AirPlayPasswordStoring {
    private let service = (Bundle.main.bundleIdentifier ?? "com.audiout.Audiout") + ".airplay-password"

    public init() {}

    private static func pairingAccount(_ deviceID: String) -> String { deviceID + "/pairing-key" }

    public func password(for deviceID: String) -> String? { read(deviceID) }

    public func setPassword(_ password: String, for deviceID: String) {
        save(password, account: deviceID, label: "Audiout AirPlay password")
    }

    public func removePassword(for deviceID: String) {
        _ = delete(deviceID, operation: "delete")
    }

    public func pairingKey(for deviceID: String) -> String? { read(Self.pairingAccount(deviceID)) }

    public func setPairingKey(_ key: String, for deviceID: String) {
        save(key, account: Self.pairingAccount(deviceID), label: "Audiout AirPlay pairing key")
    }

    public func removePairingKey(for deviceID: String) {
        _ = delete(Self.pairingAccount(deviceID), operation: "delete")
    }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private func read(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func save(_ value: String, account: String, label: String) {
        guard delete(account, operation: "save") else { return }
        var q = query(account)
        q[kSecAttrLabel as String] = label
        q[kSecValueData as String] = Data(value.utf8)
        let status = SecItemAdd(q as CFDictionary, nil)
        if status != errSecSuccess { report(status, account, operation: "save") }
    }

    private func delete(_ account: String, operation: String) -> Bool {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            report(status, account, operation: operation)
            return false
        }
        return true
    }

    private func report(_ status: OSStatus, _ account: String, operation: String) {
        Telemetry.fail(.airplay, "airplay:password_store_failed",
                       local: ["device": account, "status": "\(status)"],
                       shared: ["operation": operation])
    }
}
