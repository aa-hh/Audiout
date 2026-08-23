import AppKit
import Foundation
import Testing
@testable import AudioutCore

/// BT-DEVICE (PLAN-UNIVERSAL-SYNC): the `.bluetooth` `Device.Kind` — symbol
/// validity on this AppKit, the `isBluetooth` helper, and identity stability of
/// a UID-keyed BT `Device` across an availability flip (the model-level half;
/// the enumerator's derived-UID round-trip is covered in
/// `BTDeviceEnumeratorTests`).
@Suite final class DeviceBluetoothKindTests: IsolatedSuite {

    /// Plan open risk L: "SF Symbol validity for the BT kind; confirm an
    /// AppKit-usable glyph." `NSImage(systemSymbolName:)` returning non-nil is
    /// the same check `DeviceIcon.isValid` ships on — run it for EVERY kind so
    /// a future rename can't silently blank any row icon.
    @Test func everyKindSymbolResolvesInAppKit() {
        for kind in Device.Kind.allCases {
            #expect(NSImage(systemSymbolName: kind.symbolName, accessibilityDescription: nil) != nil,
                    "Device.Kind.\(kind) symbol '\(kind.symbolName)' must resolve on this AppKit")
        }
    }

    /// The BT glyph must not collide with the rows' mute-accessory glyph
    /// ("speaker.wave.2.fill" — DeviceRowView/MainOutRowView) and must be
    /// distinct from the AirPlay speaker kinds so BT rows read differently.
    @Test func bluetoothSymbolIsDistinct() {
        let symbol = Device.Kind.bluetooth.symbolName
        #expect(symbol == "hifispeaker.2.fill")
        #expect(symbol != "speaker.wave.2.fill", "collides with the mute accessory glyph")
        #expect(symbol != Device.Kind.sonos.symbolName)
        #expect(symbol != Device.Kind.generic.symbolName)
    }

    @Test func isBluetoothIsTrueForExactlyTheBluetoothKind() {
        for kind in Device.Kind.allCases {
            let device = Device(id: "x", name: "X", kind: kind)
            #expect(device.isBluetooth == (kind == .bluetooth))
        }
    }

    /// The BT id is the Core Audio device UID and is `let`-stable: an
    /// availability flip (disconnect/rejoin) mutates the snapshot's fields but
    /// can never move its identity — which is what lets a saved group keyed on
    /// the UID rejoin the same speaker.
    @Test func bluetoothDeviceIdentitySurvivesAvailabilityFlips() {
        let uid = "C4-38-75-0E-BF-4A:output"
        var device = Device(
            id: uid, name: "Sonos Move 2", kind: .bluetooth,
            isAvailable: true, supportsAirPlay2: false)
        device.isAvailable = false
        device.isAvailable = true
        #expect(device.id == uid)
        #expect(device.kind == .bluetooth)
        #expect(!device.supportsAirPlay2, "BT devices are never AirPlay-2 capable")
        #expect(!device.isLocalDevice, "BT is non-local — it may mix with AirPlay in groups")
    }
}
