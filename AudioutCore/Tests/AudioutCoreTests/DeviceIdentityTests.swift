// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudioutCore

/// `DeviceIdentity` (`Sources/AudioutCore/DeviceIdentity.swift`) — the machine
/// id the trial server counts trials by.
///
/// The server treats two different strings as two different Macs, so a hash
/// that varied per call or per launch would hand out an unlimited number of
/// fourteen-day trials.
@Suite struct DeviceIdentityTests {

    /// Red if the digest were formatted as anything but lowercase hex — say
    /// with `%02X`, or base64.
    @Test func theHashIsSixtyFourLowercaseHexCharacters() {
        let hash = DeviceIdentity.deviceHash()
        #expect(hash.count == 64)
        #expect(hash.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    /// Red if the hash mixed in a timestamp, a UUID made per call, or any
    /// other value that changes between calls on one machine.
    @Test func theSameMacHashesToTheSameString() {
        #expect(DeviceIdentity.deviceHash() == DeviceIdentity.deviceHash())
    }
}
