// SPDX-License-Identifier: GPL-2.0-or-later

import CoreBluetooth
import Foundation
import IOBluetooth

/// The SDP half of the BT-HW-VOL capability gate. A Core Audio "volume
/// property is settable" verdict alone cannot tell a real hardware fader from
/// a driver's software-shim volume — `dev/notes/bt-absolute-volume-detection.md`
/// finding 4. This reads the speaker's cached AVRCP Target SDP record and
/// asks whether it claims AVRCP 1.4+ (the version that added absolute-volume
/// category 2) or advertises the category-2 feature bit directly.
enum BTAbsoluteVolumeSDP {
    /// `true`/`false` is a definitive verdict; `nil` means no SDP evidence
    /// either way (no Bluetooth grant, no paired device, no cached record) —
    /// the caller falls back to the settable-only gate rather than blocking
    /// on it.
    ///
    /// razor: reads the CACHED record only, never calls `performSDPQuery:` —
    /// a live re-query is the upgrade path if a stale cache proves to matter.
    static func claim(forUID uid: String) -> Bool? {
        // An IOBluetooth call from a process without the Bluetooth grant
        // SIGABRTs it — no prompt, no error (BTDeviceEnumerator's class doc).
        // Never touch IOBluetooth without this gate.
        guard CBManager.authorization == .allowedAlways else { return nil }
        guard let mac = BTDeviceEnumerator.macKey(uid) else { return nil }
        let address = stride(from: 0, to: 12, by: 2)
            .map { i -> Substring in
                let start = mac.index(mac.startIndex, offsetBy: i)
                return mac[start..<mac.index(start, offsetBy: 2)]
            }
            .joined(separator: "-")
        guard let device = IOBluetoothDevice(addressString: address) else { return nil }
        // 0x110C = kBluetoothSDPUUID16ServiceClassAVRemoteControlTarget.
        guard let record = device.getServiceRecord(for: IOBluetoothSDPUUID(uuid16: 0x110C)) else {
            return nil
        }

        // 0x0009 = kBluetoothSDPAttributeIdentifierBluetoothProfileDescriptorList:
        // a sequence of [UUID, version] pairs: AVRCP 1.4+ is category-2 capable.
        if let profiles = record.getAttributeDataElement(0x0009)?.getArrayValue() {
            for case let entry as IOBluetoothSDPDataElement in profiles {
                guard let parts = entry.getArrayValue(), parts.count >= 2,
                      let versionElement = parts[1] as? IOBluetoothSDPDataElement,
                      let version = versionElement.getNumberValue()?.uint16Value
                else { continue }
                if version >= 0x0104 { return true }
            }
        }
        // 0x0311 = kBluetoothSDPAttributeIdentifierSupportedFeatures: bit 0x0002
        // is the AVRCP Target category-2 (absolute volume) feature bit.
        if let features = record.getAttributeDataElement(0x0311)?.getNumberValue()?.uint16Value,
           features & 0x0002 != 0 {
            return true
        }
        return false
    }
}
