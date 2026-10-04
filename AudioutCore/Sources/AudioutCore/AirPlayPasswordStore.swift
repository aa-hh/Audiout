import Foundation
import Security

/// Per-speaker AirPlay passwords, keyed by `Device.id`.
public protocol AirPlayPasswordStoring: Sendable {
    func password(for deviceID: String) -> String?
    func setPassword(_ password: String, for deviceID: String)
    func removePassword(for deviceID: String)
}

/// Session-only store: what a backend built without a store uses, and what tests inject.
public final class InMemoryAirPlayPasswordStore: AirPlayPasswordStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var passwords: [String: String] = [:]

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
}

/// Generic-password Keychain items, one per speaker: service
/// `<bundle id>.airplay-password`, account = device id.
///
/// The app is not sandboxed, so the items land in the login keychain with an
/// access list pinned to the signing identity. A Developer ID build keeps that
/// identity across rebuilds; an ad-hoc build is asked again once per rebuild.
/// No entitlement or `make-app.sh` change is involved.
/// PR 2: a pairing key is a second account under the same service.
public final class KeychainAirPlayPasswordStore: AirPlayPasswordStoring {
    private let service = (Bundle.main.bundleIdentifier ?? "com.audiout.Audiout") + ".airplay-password"

    public init() {}

    private func query(_ deviceID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: deviceID]
    }

    public func password(for deviceID: String) -> String? {
        var q = query(deviceID)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setPassword(_ password: String, for deviceID: String) {
        guard delete(deviceID, operation: "save") else { return }
        var q = query(deviceID)
        q[kSecAttrLabel as String] = "Audiout AirPlay password"
        q[kSecValueData as String] = Data(password.utf8)
        let status = SecItemAdd(q as CFDictionary, nil)
        if status != errSecSuccess { report(status, deviceID, operation: "save") }
    }

    public func removePassword(for deviceID: String) {
        _ = delete(deviceID, operation: "delete")
    }

    private func delete(_ deviceID: String, operation: String) -> Bool {
        let status = SecItemDelete(query(deviceID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            report(status, deviceID, operation: operation)
            return false
        }
        return true
    }

    private func report(_ status: OSStatus, _ deviceID: String, operation: String) {
        Telemetry.fail(.airplay, "airplay:password_store_failed",
                       local: ["device": deviceID, "status": "\(status)"],
                       shared: ["operation": operation])
    }
}
