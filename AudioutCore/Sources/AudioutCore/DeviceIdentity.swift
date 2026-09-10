// SPDX-License-Identifier: GPL-2.0-or-later

import CryptoKit
import Foundation
import IOKit

/// The trial's name for this Mac.
///
/// The trial server needs one stable id per machine so a fourteen-day trial
/// cannot be restarted by reinstalling the app. The hardware UUID is that id,
/// but sending it raw would hand the server a permanent, cross-app machine
/// identifier, so only a hash of it leaves the Mac. The salt below is in
/// public GPL source and hides nothing by itself — the hash does the hiding.
public enum DeviceIdentity {

    private static let salt = "audiout-trial:"

    /// A lowercase 64-character hex SHA-256 digest naming this Mac.
    ///
    /// Stable for the life of the machine: the same Mac answers the same
    /// string across launches, reinstalls and app versions.
    ///
    /// When IOKit cannot produce the hardware UUID — which should not happen
    /// on a real Mac — the digest of a fixed placeholder is returned rather
    /// than a failure or a random value. A trial that cannot identify its
    /// machine has to fail as "no trial" at the server, and a random id per
    /// launch would instead look like an endless supply of fresh machines.
    public static func deviceHash() -> String {
        let digest = SHA256.hash(data: Data((salt + (hardwareUUID() ?? "unknown")).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// This Mac's `IOPlatformUUID`, or `nil` if the IOKit lookup fails.
    private static func hardwareUUID() -> String? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        let property = IORegistryEntryCreateCFProperty(
            service,
            kIOPlatformUUIDKey as CFString,
            kCFAllocatorDefault,
            0
        )
        return property?.takeRetainedValue() as? String
    }
}
