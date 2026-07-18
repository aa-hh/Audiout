// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
import AppKit
@testable import AudiouterCore
@testable import AudiouterSharedUI
@testable import AudiouterPopoverUI

/// Icon-surfacing coverage for the popover (Groups window phase 2, T17):
/// a device row renders a `DeviceIconController` override when one is
/// injected and set, falls back to the `Device.Kind` default with no
/// controller (unchanged behavior), `GroupRowView` resolves a group's own
/// `iconSymbolName` the same way, and an `onChange`-driven refresh (the
/// icon-picker edit path) reaches a mounted row without a manual reopen.
/// Mirrors `PopoverControllerTests`'s harness pattern (`MockBackend` +
/// `GroupController` + temp-directory stores); the popover isn't visible to
/// CI, so this asserts the rendered `NSImage` via the same subview-traversal
/// technique `PopoverControllerTests.testExactFitSizeMatchesContentNoScroll`
/// uses for `NSScrollView`, since neither `DeviceRowView` nor `GroupRowView`
/// exposes a `test_iconSymbolName` hook (out of scope — this task touches only
/// this file).
@MainActor
final class PopoverIconTests: XCTestCase {

    // MARK: Harness

    private func makePopover(
        deviceIconController: DeviceIconController? = nil
    ) async throws -> (PopoverController, GroupController, MockBackend) {
        let backend = MockBackend(fleet: .demoFleet, staggerDiscovery: false,
                                  emitsLevels: false, simulatesDropouts: false)
        try await waitForFleet(backend, count: 7)
        let controller = GroupController(backend: backend,
                                         store: GroupStore(directory: tempDirectory()),
                                         routingStore: RoutingStore(directory: tempDirectory()),
                                         loadPersisted: false)
        let popover = PopoverController()
        // A closed popover deliberately never rebuilds on `update(devices:)`
        // (audit B8 — no hidden rebuild storms); headless there is no real
        // open, so opt into the shown-repaint path via the designated hook.
        popover.test_isShownOverride = true
        // Inject before `configure`/`update` so the first `rebuild()` those
        // trigger already resolves through the controller — matching the real
        // app's wiring order (deviceIconController is set once at launch).
        popover.deviceIconController = deviceIconController
        popover.configure(groupController: controller)
        controller.ensureDefaultSelection()
        popover.update(devices: backend.devices)
        return (popover, controller, backend)
    }

    private func waitForFleet(_ backend: MockBackend, count: Int) async throws {
        let stream = backend.makeEventStream()
        let expectation = expectation(description: "fleet discovered")
        let box = PopoverIconTestCountBox()
        let task = Task {
            for await event in stream {
                if case .deviceAdded = event, await box.increment() >= count {
                    expectation.fulfill(); break
                }
            }
        }
        backend.start()
        await fulfillment(of: [expectation], timeout: 2)
        task.cancel()
    }

    private func tempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PopoverIconTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The sole `NSImageView` in a row's subtree (both `DeviceRowView` and
    /// `GroupRowView` mount exactly one — every other glyph-bearing control is
    /// an `NSButton`), found by traversal since neither exposes its icon view.
    private func findImageView(in view: NSView) -> NSImageView? {
        if let imageView = view as? NSImageView { return imageView }
        for subview in view.subviews {
            if let found = findImageView(in: subview) { return found }
        }
        return nil
    }

    /// Two `NSImage`s are "the same rendered symbol" iff their bitmap data is
    /// byte-identical — the same equality the icon-well/row callers rely on
    /// being deterministic for a given (name, description, configuration).
    private func imagesEqual(_ a: NSImage?, _ b: NSImage?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return a.tiffRepresentation == b.tiffRepresentation
    }

    /// Reconstructs the exact `NSImage` `DeviceRowView.apply` renders for
    /// `symbolName`, so a row's actual icon can be compared against it.
    private func expectedDeviceIcon(symbolName: String, deviceName: String) -> NSImage? {
        NSImage(systemSymbolName: symbolName, accessibilityDescription: deviceName)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: PopoverColumnGrid.iconGlyphPointSize,
                                                                  weight: .regular))
    }

    /// Reconstructs the exact `NSImage` `GroupRowView.apply` renders for
    /// `symbolName`.
    private func expectedGroupIcon(symbolName: String) -> NSImage? {
        NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
    }

    // MARK: Device row — override injected

    /// With a `DeviceIconController` injected and an override set for a
    /// device, the popover's device row renders the override symbol, not the
    /// `Device.Kind` default.
    func testDeviceRowRendersInjectedOverride() async throws {
        let iconController = DeviceIconController(store: DeviceIconStore(directory: tempDirectory()),
                                                   loadPersisted: false)
        iconController.setSymbolName("airpods", for: "office")
        let (popover, _, backend) = try await makePopover(deviceIconController: iconController)

        let device = try XCTUnwrap(backend.devices.first { $0.id == "office" })
        XCTAssertNotEqual(device.kind.symbolName, "airpods",
                          "sanity: the override differs from the device's own default")

        let row = try XCTUnwrap(popover.test_deviceRow(for: "office"))
        let imageView = try XCTUnwrap(findImageView(in: row))
        XCTAssertTrue(imagesEqual(imageView.image, expectedDeviceIcon(symbolName: "airpods", deviceName: device.name)),
                      "the row renders the injected override symbol, not the kind default")
        XCTAssertFalse(imagesEqual(imageView.image,
                                   expectedDeviceIcon(symbolName: device.kind.symbolName, deviceName: device.name)),
                       "the row is no longer showing the kind default once an override is set")
    }

    // MARK: Device row — no controller

    /// Without a `DeviceIconController` injected (`nil`, the default), device
    /// rows behave exactly as before: the `Device.Kind` default renders,
    /// unaffected by there being no override source at all.
    func testDeviceRowWithNoControllerRendersKindDefault() async throws {
        let (popover, _, backend) = try await makePopover(deviceIconController: nil)

        let device = try XCTUnwrap(backend.devices.first { $0.id == "office" })
        let row = try XCTUnwrap(popover.test_deviceRow(for: "office"))
        let imageView = try XCTUnwrap(findImageView(in: row))
        XCTAssertTrue(imagesEqual(imageView.image,
                                  expectedDeviceIcon(symbolName: device.kind.symbolName, deviceName: device.name)),
                      "with no controller injected, the row falls back to the kind default unchanged")
    }

    /// A `DeviceIconController` with no override set for a particular device
    /// still renders that device's kind default — the controller only changes
    /// rendering for ids it actually has an override for.
    func testDeviceRowWithControllerButNoOverrideRendersKindDefault() async throws {
        let iconController = DeviceIconController(store: DeviceIconStore(directory: tempDirectory()),
                                                   loadPersisted: false)
        let (popover, _, backend) = try await makePopover(deviceIconController: iconController)

        let device = try XCTUnwrap(backend.devices.first { $0.id == "office" })
        let row = try XCTUnwrap(popover.test_deviceRow(for: "office"))
        let imageView = try XCTUnwrap(findImageView(in: row))
        XCTAssertTrue(imagesEqual(imageView.image,
                                  expectedDeviceIcon(symbolName: device.kind.symbolName, deviceName: device.name)),
                      "a controller with no override for this device still shows its kind default")
    }

    // MARK: Group row

    /// `GroupRowView` (mounted for the mixer window, built here directly per
    /// `AudiouterPopoverUI/AGENTS.md`'s map) shows the group's own
    /// `iconSymbolName` when one is set.
    func testGroupRowRendersGroupIconSymbolNameWhenSet() {
        let group = Group(name: "Whole House", memberIDs: ["office", "homepod-bed"],
                          memberVolumes: ["office": 40, "homepod-bed": 60],
                          iconSymbolName: "house.fill")
        let row = GroupRowView(group: group, isActive: false, isExpanded: false, masterVolume: 50)

        let imageView = findImageView(in: row)
        XCTAssertNotNil(imageView, "the group row mounts an icon image view")
        XCTAssertTrue(imagesEqual(imageView?.image, expectedGroupIcon(symbolName: "house.fill")),
                      "the group row renders its own iconSymbolName")
    }

    /// A group with no `iconSymbolName` (or an unrecognized/stale one) falls
    /// back to `Group.defaultIconSymbolName` — the same render-time staleness
    /// handling every other icon surface uses.
    func testGroupRowRendersDefaultIconWhenUnset() {
        let group = Group(name: "Whole House", memberIDs: ["office"], memberVolumes: ["office": 40])
        let row = GroupRowView(group: group, isActive: false, isExpanded: false, masterVolume: 50)

        let imageView = findImageView(in: row)
        XCTAssertTrue(imagesEqual(imageView?.image, expectedGroupIcon(symbolName: Group.defaultIconSymbolName)),
                      "no iconSymbolName ⇒ the group row falls back to the documented default")
    }

    func testGroupRowRendersDefaultIconWhenStale() {
        let group = Group(name: "Whole House", memberIDs: ["office"], memberVolumes: ["office": 40],
                          iconSymbolName: "definitely.not.a.real.symbol.zzz")
        let row = GroupRowView(group: group, isActive: false, isExpanded: false, masterVolume: 50)

        let imageView = findImageView(in: row)
        XCTAssertTrue(imagesEqual(imageView?.image, expectedGroupIcon(symbolName: Group.defaultIconSymbolName)),
                      "an unresolvable saved name falls back to the default, same as a nil override")
    }

    // MARK: onChange-driven refresh

    /// Setting a NEW override through the injected controller after the
    /// popover is already built fires `onChange`, which the popover chains to
    /// `refreshDeviceRows()` — the mounted row picks up the new symbol without
    /// a manual `rebuild()`/reopen.
    func testOnChangeRefreshPicksUpNewOverride() async throws {
        let iconController = DeviceIconController(store: DeviceIconStore(directory: tempDirectory()),
                                                   loadPersisted: false)
        let (popover, _, backend) = try await makePopover(deviceIconController: iconController)

        let device = try XCTUnwrap(backend.devices.first { $0.id == "office" })
        let row = try XCTUnwrap(popover.test_deviceRow(for: "office"))
        let imageView = try XCTUnwrap(findImageView(in: row))
        XCTAssertTrue(imagesEqual(imageView.image,
                                  expectedDeviceIcon(symbolName: device.kind.symbolName, deviceName: device.name)),
                      "starts on the kind default (no override yet)")

        iconController.setSymbolName("homepod.2.fill", for: "office")

        XCTAssertTrue(imagesEqual(imageView.image,
                                  expectedDeviceIcon(symbolName: "homepod.2.fill", deviceName: device.name)),
                      "onChange refreshed the already-mounted row's icon in place, no rebuild call needed")
    }

    /// The refresh is per-device: setting an override for a DIFFERENT id must
    /// not disturb `office`'s row, which stays on its kind default.
    func testOnChangeRefreshOnlyTouchesTheChangedDevice() async throws {
        let iconController = DeviceIconController(store: DeviceIconStore(directory: tempDirectory()),
                                                   loadPersisted: false)
        let (popover, _, backend) = try await makePopover(deviceIconController: iconController)

        let officeDevice = try XCTUnwrap(backend.devices.first { $0.id == "office" })
        let officeRow = try XCTUnwrap(popover.test_deviceRow(for: "office"))
        let officeImageView = try XCTUnwrap(findImageView(in: officeRow))

        iconController.setSymbolName("airpodspro", for: "homepod-bed")

        XCTAssertTrue(imagesEqual(officeImageView.image,
                                  expectedDeviceIcon(symbolName: officeDevice.kind.symbolName,
                                                     deviceName: officeDevice.name)),
                      "an override on a different device doesn't affect office's row")
    }
}

private actor PopoverIconTestCountBox {
    private var count = 0
    func increment() -> Int { count += 1; return count }
}
