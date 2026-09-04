// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudioutCore
@testable import AudioutSharedUI

/// `DeviceIcon`'s validity/resolution rules and `DeviceIconController`'s
/// override lifecycle. Mirrors `ExcludedAppsTests`'s Store-then-Controller
/// split, but both halves live here since `DeviceIconStoreTests` already owns
/// the raw persistence file and this file owns the resolution semantics that
/// sit on top of it.
@Suite final class DeviceIconResolverTests {

    private let directory: URL

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioutTests-\(UUID().uuidString)", isDirectory: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeDevice(id: String = "office", kind: Device.Kind = .sonos) -> Device {
        Device(id: id, name: "Office", kind: kind)
    }

    // MARK: DeviceIcon.isValid / resolve

    @Test func isValidTrueForKnownCuratedSymbol() {
        #expect(DeviceIcon.isValid("speaker.wave.2.fill"))
    }

    @Test func isValidFalseForUnknownSymbol() {
        #expect(!DeviceIcon.isValid("definitely.not.a.symbol.zzz"))
    }

    @Test func resolveReturnsDefaultForNilOverride() {
        #expect(DeviceIcon.resolve(nil, default: "hifispeaker.fill") == "hifispeaker.fill")
    }

    @Test func resolveReturnsDefaultForInvalidOverride() {
        #expect(DeviceIcon.resolve("definitely.not.a.symbol.zzz", default: "hifispeaker.fill") == "hifispeaker.fill")
    }

    @Test func resolveReturnsOverrideWhenValid() {
        #expect(DeviceIcon.resolve("airpods", default: "hifispeaker.fill") == "airpods")
    }

    // MARK: DeviceIconController

    @Test func symbolNameForDeviceWithNoOverrideIsKindDefault() {
        let controller = DeviceIconController(store: DeviceIconStore(directory: directory), loadPersisted: false)
        let device = makeDevice(kind: .homePod)
        #expect(controller.symbolName(for: device) == Device.Kind.homePod.symbolName)
    }

    @Test func setSymbolNamePersistsAndResolves() {
        let store = DeviceIconStore(directory: directory)
        let controller = DeviceIconController(store: store, loadPersisted: false)
        let device = makeDevice()

        controller.setSymbolName("airpods", for: device.id)
        #expect(controller.symbolName(for: device) == "airpods")
        #expect(controller.overrides[device.id] == "airpods")

        // A fresh controller over the same store sees the persisted override.
        let reloaded = DeviceIconController(store: store)
        #expect(reloaded.symbolName(for: device) == "airpods")
    }

    @Test func setSymbolNameWithInvalidNameIsANoOp() throws {
        let store = DeviceIconStore(directory: directory)
        let controller = DeviceIconController(store: store, loadPersisted: false)
        var changeFired = false
        controller.onChange = { changeFired = true }

        controller.setSymbolName("definitely.not.a.symbol.zzz", for: "office")

        #expect(controller.overrides["office"] == nil)
        #expect(!changeFired, "an invalid symbol name must not persist or notify")
        #expect(try store.load() == nil, "nothing should have been written to disk")
    }

    @Test func resetIconClearsOverride() {
        let controller = DeviceIconController(store: DeviceIconStore(directory: directory), loadPersisted: false)
        let device = makeDevice(kind: .sonos)
        controller.setSymbolName("airpods", for: device.id)
        #expect(controller.symbolName(for: device) == "airpods")

        controller.resetIcon(for: device.id)
        #expect(controller.overrides[device.id] == nil)
        #expect(controller.symbolName(for: device) == Device.Kind.sonos.symbolName)
    }

    @Test func resetIconWithNoOverrideIsANoOp() {
        let controller = DeviceIconController(store: DeviceIconStore(directory: directory), loadPersisted: false)
        var changeFired = false
        controller.onChange = { changeFired = true }

        controller.resetIcon(for: "office")

        #expect(!changeFired, "resetting a device with no override must not notify")
    }

    @Test func onChangeFiresOnSetAndReset() {
        let controller = DeviceIconController(store: DeviceIconStore(directory: directory), loadPersisted: false)
        var changeCount = 0
        controller.onChange = { changeCount += 1 }

        controller.setSymbolName("airpods", for: "office")
        #expect(changeCount == 1)

        controller.resetIcon(for: "office")
        #expect(changeCount == 2)
    }

    @Test func settingSameSymbolNameTwiceOnlyFiresOnChangeOnce() {
        let controller = DeviceIconController(store: DeviceIconStore(directory: directory), loadPersisted: false)
        var changeCount = 0
        controller.onChange = { changeCount += 1 }

        controller.setSymbolName("airpods", for: "office")
        controller.setSymbolName("airpods", for: "office")
        #expect(changeCount == 1, "setting the same value again is a no-op")
    }

    @Test func missingFileLoadsAsEmptyOverrides() {
        // The store itself returns nil for a missing file; the controller is
        // the layer that turns that into an empty override map.
        let controller = DeviceIconController(store: DeviceIconStore(directory: directory))
        #expect(controller.overrides.isEmpty)
    }

    // MARK: DeviceIcon.image — the row-build cache

    /// Row builds are the hot path (sidebar, membership rows, the detail
    /// pane's group rows), and they used to mint a fresh `NSImage` per row per
    /// rebuild. The same request now comes back as the very same instance.
    @MainActor
    @Test func theSameSymbolRequestReturnsTheSameInstance() {
        let first = DeviceIcon.image("speaker.wave.2.fill")
        let second = DeviceIcon.image("speaker.wave.2.fill")
        #expect(first != nil)
        #expect(first === second, "one lookup, reused — that is the whole point of the cache")
    }

    /// The size is part of the key: a 13pt row glyph and an unconfigured one
    /// are different images and must not collide.
    @MainActor
    @Test func adifferentPointSizeIsADifferentCacheEntry() {
        let small = DeviceIcon.image("homepod.fill", pointSize: 13)
        let large = DeviceIcon.image("homepod.fill", pointSize: 24)
        #expect(small != nil)
        #expect(large != nil)
        #expect(small !== large)
        #expect(small !== DeviceIcon.image("homepod.fill"),
                "no point size at all is its own entry too")
    }

    /// Template, so every call site's `contentTintColor` is what colours it —
    /// which is also why a SHARED image is safe to hand out.
    @MainActor
    @Test func cachedImagesAreTemplates() throws {
        let image = try #require(DeviceIcon.image("appletv.fill", pointSize: 13))
        #expect(image.isTemplate)
    }

    @MainActor
    @Test func anUnknownSymbolIsNilAndNotCached() {
        #expect(DeviceIcon.image("definitely.not.a.symbol.zzz") == nil)
    }
}
