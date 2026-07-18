// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import AudiouterCore
@testable import AudiouterSharedUI

/// `DeviceIcon`'s validity/resolution rules and `DeviceIconController`'s
/// override lifecycle. Mirrors `ExcludedAppsTests`'s Store-then-Controller
/// split, but both halves live here since `DeviceIconStoreTests` already owns
/// the raw persistence file and this file owns the resolution semantics that
/// sit on top of it.
final class DeviceIconResolverTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudiouterTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        super.tearDown()
    }

    private func makeDevice(id: String = "office", kind: Device.Kind = .sonos) -> Device {
        Device(id: id, name: "Office", kind: kind)
    }

    // MARK: DeviceIcon.isValid / resolve

    func testIsValidTrueForKnownCuratedSymbol() {
        XCTAssertTrue(DeviceIcon.isValid("speaker.wave.2.fill"))
    }

    func testIsValidFalseForUnknownSymbol() {
        XCTAssertFalse(DeviceIcon.isValid("definitely.not.a.symbol.zzz"))
    }

    func testResolveReturnsDefaultForNilOverride() {
        XCTAssertEqual(DeviceIcon.resolve(nil, default: "hifispeaker.fill"), "hifispeaker.fill")
    }

    func testResolveReturnsDefaultForInvalidOverride() {
        XCTAssertEqual(DeviceIcon.resolve("definitely.not.a.symbol.zzz", default: "hifispeaker.fill"), "hifispeaker.fill")
    }

    func testResolveReturnsOverrideWhenValid() {
        XCTAssertEqual(DeviceIcon.resolve("airpods", default: "hifispeaker.fill"), "airpods")
    }

    // MARK: DeviceIconController

    func testSymbolNameForDeviceWithNoOverrideIsKindDefault() {
        let controller = DeviceIconController(store: DeviceIconStore(directory: directory), loadPersisted: false)
        let device = makeDevice(kind: .homePod)
        XCTAssertEqual(controller.symbolName(for: device), Device.Kind.homePod.symbolName)
    }

    func testSetSymbolNamePersistsAndResolves() {
        let store = DeviceIconStore(directory: directory)
        let controller = DeviceIconController(store: store, loadPersisted: false)
        let device = makeDevice()

        controller.setSymbolName("airpods", for: device.id)
        XCTAssertEqual(controller.symbolName(for: device), "airpods")
        XCTAssertEqual(controller.overrides[device.id], "airpods")

        // A fresh controller over the same store sees the persisted override.
        let reloaded = DeviceIconController(store: store)
        XCTAssertEqual(reloaded.symbolName(for: device), "airpods")
    }

    func testSetSymbolNameWithInvalidNameIsANoOp() {
        let store = DeviceIconStore(directory: directory)
        let controller = DeviceIconController(store: store, loadPersisted: false)
        var changeFired = false
        controller.onChange = { changeFired = true }

        controller.setSymbolName("definitely.not.a.symbol.zzz", for: "office")

        XCTAssertNil(controller.overrides["office"])
        XCTAssertFalse(changeFired, "an invalid symbol name must not persist or notify")
        XCTAssertNil(try store.load(), "nothing should have been written to disk")
    }

    func testResetIconClearsOverride() {
        let controller = DeviceIconController(store: DeviceIconStore(directory: directory), loadPersisted: false)
        let device = makeDevice(kind: .sonos)
        controller.setSymbolName("airpods", for: device.id)
        XCTAssertEqual(controller.symbolName(for: device), "airpods")

        controller.resetIcon(for: device.id)
        XCTAssertNil(controller.overrides[device.id])
        XCTAssertEqual(controller.symbolName(for: device), Device.Kind.sonos.symbolName)
    }

    func testResetIconWithNoOverrideIsANoOp() {
        let controller = DeviceIconController(store: DeviceIconStore(directory: directory), loadPersisted: false)
        var changeFired = false
        controller.onChange = { changeFired = true }

        controller.resetIcon(for: "office")

        XCTAssertFalse(changeFired, "resetting a device with no override must not notify")
    }

    func testOnChangeFiresOnSetAndReset() {
        let controller = DeviceIconController(store: DeviceIconStore(directory: directory), loadPersisted: false)
        var changeCount = 0
        controller.onChange = { changeCount += 1 }

        controller.setSymbolName("airpods", for: "office")
        XCTAssertEqual(changeCount, 1)

        controller.resetIcon(for: "office")
        XCTAssertEqual(changeCount, 2)
    }

    func testSettingSameSymbolNameTwiceOnlyFiresOnChangeOnce() {
        let controller = DeviceIconController(store: DeviceIconStore(directory: directory), loadPersisted: false)
        var changeCount = 0
        controller.onChange = { changeCount += 1 }

        controller.setSymbolName("airpods", for: "office")
        controller.setSymbolName("airpods", for: "office")
        XCTAssertEqual(changeCount, 1, "setting the same value again is a no-op")
    }

    func testMissingFileLoadsAsEmptyOverrides() {
        // The store itself returns nil for a missing file; the controller is
        // the layer that turns that into an empty override map.
        let controller = DeviceIconController(store: DeviceIconStore(directory: directory))
        XCTAssertTrue(controller.overrides.isEmpty)
    }
}
