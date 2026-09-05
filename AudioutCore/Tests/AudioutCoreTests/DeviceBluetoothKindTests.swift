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
    /// The kind's own glyph is the fallback for a pairing whose device class
    /// says nothing useful; it was "hifispeaker.2.fill" until 2026-09-04, when
    /// a stereo pair of cabinets for a set of earbuds made it the defect.
    @Test func bluetoothSymbolIsDistinct() {
        let symbol = Device.Kind.bluetooth.symbolName
        #expect(symbol == "radio.fill")
        #expect(symbol != "speaker.wave.2.fill", "collides with the mute accessory glyph")
        #expect(symbol != Device.Kind.sonos.symbolName)
        #expect(symbol != Device.Kind.generic.symbolName)
    }

    /// The device-class branch: a pairing that says it is a headset, hands-free
    /// unit or headphones draws headphones; car audio draws a car; every
    /// speaker class and every unknown value keeps the kind's neutral speaker.
    /// The numbers are the Audio/Video minor device classes from
    /// `BluetoothAssignedNumbers.h`.
    @Test func bluetoothGlyphFollowsTheDeviceClass() {
        func symbol(forMinorClass minor: UInt32?) -> String {
            Device(id: "x", name: "X", kind: .bluetooth, bluetoothDeviceClassMinor: minor).symbolName
        }
        for headphoneClass: UInt32 in [0x01, 0x02, 0x06] {
            #expect(symbol(forMinorClass: headphoneClass) == "headphones")
        }
        #expect(symbol(forMinorClass: 0x08) == "car.fill")
        for speakerClass: UInt32 in [0x00, 0x05, 0x07, 0x0a, 0x7f] {
            #expect(symbol(forMinorClass: speakerClass) == Device.Kind.bluetooth.symbolName)
        }
        #expect(symbol(forMinorClass: nil) == Device.Kind.bluetooth.symbolName,
                "no readable paired record must fall back, never blank the row")
    }

    /// Both branch glyphs have to resolve on the deployment floor (macOS 14.2),
    /// and neither may be an Apple-product glyph or a stereo pair (the owner's
    /// two stated exclusions). `everyKindSymbolResolvesInAppKit` covers the
    /// kind defaults; these two are reachable only through the class branch.
    @Test func deviceClassGlyphsResolveInAppKit() {
        for symbol in ["headphones", "car.fill"] {
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil,
                    "'\(symbol)' must resolve on this AppKit")
        }
    }

    /// The name branch, on the string this layer exists for. The owner's own
    /// pair is called "My AirPods Pro #2": an exact-name table would miss it,
    /// and a table that checked "AirPods" before "AirPods Pro" would draw the
    /// wrong product. The class routing under it never gets a say — 0x06 would
    /// otherwise draw plain headphones.
    @Test func productNameBeatsTheDeviceClass() {
        let device = Device(id: "x", name: "My AirPods Pro #2", kind: .bluetooth,
                            bluetoothDeviceClassMinor: 0x06)
        #expect(device.symbolName == "airpodspro")
    }

    /// Every phrase that contains a shorter phrase has to beat it: the Pro, Max
    /// and generation models over bare "AirPods", "Powerbeats Pro" over
    /// "Powerbeats", the Studio Buds over Studio. The shorter phrase still gets
    /// its own glyph when it stands alone.
    @Test func moreSpecificProductPhrasesWin() {
        func symbol(_ name: String) -> String? { Device.bluetoothProductSymbol(forName: name) }
        #expect(symbol("AirPods Max") == "airpodsmax")
        #expect(symbol("AirPods Pro") == "airpodspro")
        #expect(symbol("AirPods (4th generation)") == "airpods.gen4")
        #expect(symbol("AirPods (3rd generation)") == "airpods.gen3")
        #expect(symbol("AirPods") == "airpods")
        #expect(symbol("Powerbeats Pro") == "beats.powerbeatspro")
        #expect(symbol("Powerbeats") == "beats.earphones")
        #expect(symbol("Beats Studio Buds") == "beats.studiobud.right")
        #expect(symbol("Beats Studio Pro") == "beats.headphones")
    }

    /// Case and punctuation carry no meaning — people type their speakers'
    /// names by hand, and the words AROUND the product may be any language,
    /// which is why only the product phrase itself is ever matched.
    @Test func productMatchingIgnoresCaseAndPunctuation() {
        #expect(Device.bluetoothProductSymbol(forName: "my airpods pro") == "airpodspro")
        #expect(Device.bluetoothProductSymbol(forName: "AIRPODS-MAX") == "airpodsmax")
        #expect(Device.bluetoothProductSymbol(forName: "Küchen AirPods") == "airpods")
    }

    /// The two fall-throughs, which is the whole safety story: a name that
    /// states no product hands over to the device class, and a device class
    /// that states nothing hands over to the kind's own glyph. There is no
    /// third outcome — a wrong glyph is worse than a generic one.
    @Test func anUnknownNameFallsThroughToTheClassRouting() {
        func symbol(_ name: String, _ minor: UInt32?) -> String {
            Device(id: "x", name: name, kind: .bluetooth, bluetoothDeviceClassMinor: minor).symbolName
        }
        #expect(symbol("Kitchen", 0x06) == "headphones")
        #expect(symbol("Kitchen", nil) == Device.Kind.bluetooth.symbolName)
        #expect(symbol("Sony WH-1000XM4", 0x06) == "headphones")
        #expect(symbol("", nil) == Device.Kind.bluetooth.symbolName)
    }

    /// Every glyph the product table can return must resolve, or a typo ships
    /// as a blank row icon. None of them may be an AirPlay kind's glyph either:
    /// a product glyph is an exception to the Bluetooth/AirPlay distinctness
    /// rule ONLY because it names one real device rather than a category.
    @Test func everyProductGlyphResolvesInAppKit() {
        let airPlayGlyphs = Set(Device.Kind.allCases
            .filter { $0 != .bluetooth }
            .map(\.symbolName))
        for entry in Device.bluetoothProductGlyphs {
            #expect(NSImage(systemSymbolName: entry.symbol, accessibilityDescription: nil) != nil,
                    "'\(entry.symbol)' (\(entry.phrase)) must resolve on this AppKit")
            #expect(!airPlayGlyphs.contains(entry.symbol),
                    "'\(entry.symbol)' is an AirPlay kind's glyph — a BT row would read as one")
        }
    }

    /// Neither the name nor the device class moves a non-Bluetooth row's glyph
    /// — both branches are gated on the kind, so neither a stray class value
    /// nor an AirPlay receiver someone named "AirPods" can repaint it.
    @Test func deviceClassOnlyAffectsBluetoothRows() {
        for kind in Device.Kind.allCases where kind != .bluetooth {
            let device = Device(id: "x", name: "AirPods", kind: kind, bluetoothDeviceClassMinor: 0x06)
            #expect(device.symbolName == kind.symbolName)
        }
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
