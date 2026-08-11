// SPDX-License-Identifier: GPL-2.0-or-later

import CoreBluetooth
import Foundation

/// Reads the live Bluetooth authorization. `CBManager.authorization` is a static
/// read: no `CBCentralManager`, no prompt, and — unlike an IOBluetooth call from
/// an ungranted process — no risk of the SIGABRT described in
/// ``BTDeviceEnumerator``'s class doc. Safe to call on any focus edge.
///
/// `.restricted` maps to `.denied` rather than a case of its own: the only
/// honest advice for either is "turn it on for this app in System Settings",
/// and MDM-restricted Macs are not a state this flow can talk the user out of.
public struct BluetoothPermissionReader: BluetoothPermissionReading {
    public init() {}

    public func currentStatus() -> PermissionStatus {
        Self.status(for: CBManager.authorization)
    }

    /// The mapping, split out from the live read so it can be tested against
    /// every case — `CBManager.authorization` is static and un-injectable, so a
    /// test of `currentStatus()` alone could only ever assert whatever this Mac
    /// happens to have granted.
    static func status(for authorization: CBManagerAuthorization) -> PermissionStatus {
        switch authorization {
        case .notDetermined:        return .unknown
        case .allowedAlways:        return .granted
        case .denied, .restricted:  return .denied
        @unknown default:           return .unknown
        }
    }
}

/// Fires the Bluetooth prompt via the module's one sanctioned ask,
/// ``BTAuthorizationRequest`` (CoreBluetooth only). The request is RETAINED
/// here for this object's lifetime — the same reason ``BTDeviceEnumerator``
/// stores its own: the `CBCentralManager` behind it has to outlive `prime` to
/// deliver the decision at all, and a released one simply never answers.
public final class BluetoothPermissionPrimer: BluetoothPermissionPriming, @unchecked Sendable {
    private let lock = NSLock()
    private var request: AnyObject?

    public init() {}

    public func prime(onDecided: @escaping @Sendable () -> Void) {
        let request = BTAuthorizationRequest(onDecided: onDecided)
        lock.withLock { self.request = request }
    }
}
