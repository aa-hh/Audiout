// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
import AppKit
@testable import AudioutCore
@testable import AudioutSharedUI
@testable import AudioutPopoverUI

/// Icon-surfacing coverage for the popover (Groups window phase 2, T17):
/// a device row renders a `DeviceIconController` override when one is
/// injected and set, falls back to the `Device.Kind` default with no
/// controller (unchanged behavior), and an `onChange`-driven refresh (the
/// icon-picker edit path) reaches a mounted row without a manual reopen.
/// Mirrors `PopoverControllerTests`'s harness pattern (`MockBackend` +
/// `GroupController` + temp-directory stores); the popover isn't visible to
/// CI, so this asserts the rendered `NSImage` via the same subview-traversal
/// technique `PopoverControllerTests.testExactFitSizeMatchesContentNoScroll`
/// uses for `NSScrollView`, since `DeviceRowView` does not expose a
/// `test_iconSymbolName` hook.
@MainActor
@Suite struct PopoverIconTests {

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
        let box = PopoverIconTestCountBox()
        try await confirmation("fleet discovered") { received in
            let task = Task {
                for await event in stream {
                    if case .deviceAdded = event, await box.increment() >= count {
                        received(); break
                    }
                }
            }
            defer { task.cancel() }
            backend.start()
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { _ = await task.value }
                group.addTask { try await Task.sleep(for: .seconds(2)) }
                try await group.next()
                group.cancelAll()
            }
        }
    }

    private func tempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PopoverIconTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The sole `NSImageView` in a row's subtree (a device row mounts exactly
    /// one — every other glyph-bearing control is an `NSButton`), found by
    /// traversal since the row does not expose its icon view.
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
        DeviceIcon.rowGlyph(symbolName)
    }

    // MARK: Device row — override injected

    /// With a `DeviceIconController` injected and an override set for a
    /// device, the popover's device row renders the override symbol, not the
    /// `Device.Kind` default.
    @Test func deviceRowRendersInjectedOverride() async throws {
        let iconController = DeviceIconController(store: DeviceIconStore(directory: tempDirectory()),
                                                   loadPersisted: false)
        iconController.setSymbolName("airpods", for: "office")
        let (popover, _, backend) = try await makePopover(deviceIconController: iconController)

        let device = try #require(backend.devices.first { $0.id == "office" })
        #expect(device.kind.symbolName != "airpods",
                "sanity: the override differs from the device's own default")

        let row = try #require(popover.test_deviceRow(for: "office"))
        let imageView = try #require(findImageView(in: row))
        #expect(imagesEqual(imageView.image, expectedDeviceIcon(symbolName: "airpods", deviceName: device.name)),
                "the row renders the injected override symbol, not the kind default")
        #expect(!imagesEqual(imageView.image,
                             expectedDeviceIcon(symbolName: device.kind.symbolName, deviceName: device.name)),
                "the row is no longer showing the kind default once an override is set")
    }

    // MARK: Device row — no controller

    /// Without a `DeviceIconController` injected (`nil`, the default), device
    /// rows behave exactly as before: the `Device.Kind` default renders,
    /// unaffected by there being no override source at all.
    @Test func deviceRowWithNoControllerRendersKindDefault() async throws {
        let (popover, _, backend) = try await makePopover(deviceIconController: nil)

        let device = try #require(backend.devices.first { $0.id == "office" })
        let row = try #require(popover.test_deviceRow(for: "office"))
        let imageView = try #require(findImageView(in: row))
        #expect(imagesEqual(imageView.image,
                            expectedDeviceIcon(symbolName: device.kind.symbolName, deviceName: device.name)),
                "with no controller injected, the row falls back to the kind default unchanged")
    }

    /// A `DeviceIconController` with no override set for a particular device
    /// still renders that device's kind default — the controller only changes
    /// rendering for ids it actually has an override for.
    @Test func deviceRowWithControllerButNoOverrideRendersKindDefault() async throws {
        let iconController = DeviceIconController(store: DeviceIconStore(directory: tempDirectory()),
                                                   loadPersisted: false)
        let (popover, _, backend) = try await makePopover(deviceIconController: iconController)

        let device = try #require(backend.devices.first { $0.id == "office" })
        let row = try #require(popover.test_deviceRow(for: "office"))
        let imageView = try #require(findImageView(in: row))
        #expect(imagesEqual(imageView.image,
                            expectedDeviceIcon(symbolName: device.kind.symbolName, deviceName: device.name)),
                "a controller with no override for this device still shows its kind default")
    }

    // MARK: onChange-driven refresh

    /// Setting a NEW override through the injected controller after the
    /// popover is already built fires `onChange`, which the popover chains to
    /// `refreshDeviceRows()` — the mounted row picks up the new symbol without
    /// a manual `rebuild()`/reopen.
    @Test func onChangeRefreshPicksUpNewOverride() async throws {
        let iconController = DeviceIconController(store: DeviceIconStore(directory: tempDirectory()),
                                                   loadPersisted: false)
        let (popover, _, backend) = try await makePopover(deviceIconController: iconController)

        let device = try #require(backend.devices.first { $0.id == "office" })
        let row = try #require(popover.test_deviceRow(for: "office"))
        let imageView = try #require(findImageView(in: row))
        #expect(imagesEqual(imageView.image,
                            expectedDeviceIcon(symbolName: device.kind.symbolName, deviceName: device.name)),
                "starts on the kind default (no override yet)")

        iconController.setSymbolName("homepod.2.fill", for: "office")

        #expect(imagesEqual(imageView.image,
                            expectedDeviceIcon(symbolName: "homepod.2.fill", deviceName: device.name)),
                "onChange refreshed the already-mounted row's icon in place, no rebuild call needed")
    }

    /// The refresh is per-device: setting an override for a DIFFERENT id must
    /// not disturb `office`'s row, which stays on its kind default.
    @Test func onChangeRefreshOnlyTouchesTheChangedDevice() async throws {
        let iconController = DeviceIconController(store: DeviceIconStore(directory: tempDirectory()),
                                                   loadPersisted: false)
        let (popover, _, backend) = try await makePopover(deviceIconController: iconController)

        let officeDevice = try #require(backend.devices.first { $0.id == "office" })
        let officeRow = try #require(popover.test_deviceRow(for: "office"))
        let officeImageView = try #require(findImageView(in: officeRow))

        iconController.setSymbolName("airpodspro", for: "homepod-bed")

        #expect(imagesEqual(officeImageView.image,
                            expectedDeviceIcon(symbolName: officeDevice.kind.symbolName,
                                               deviceName: officeDevice.name)),
                "an override on a different device doesn't affect office's row")
    }

    private static let scale: CGFloat = 4

    /// No row glyph comes near touching its ring. One point size for every
    /// symbol let `radio.fill` (the Bluetooth fallback) and `hifispeaker.2.fill`
    /// touch the ring; `DeviceIcon.rowGlyphFits` sizes each symbol so none does.
    /// Renders the real `DeviceIcon.rowGlyph` image and measures its farthest ink
    /// pixel from the ring's centre. The floor is 1 pt, not the 2 pt design
    /// target: SF Symbols art differs between macOS versions (the same glyph
    /// measured 2.14 pt on one Mac and 1.99 pt on another), so a 2 pt floor would
    /// pass or fail by machine.
    ///
    /// Farthest point of ink (alpha > 25 %) from the image centre, in pt.
    private func farthestInk(_ image: NSImage) -> CGFloat? {
        let side = Int(PopoverColumnGrid.iconWidth * Self.scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        let c = CGFloat(side) / 2
        var far: CGFloat = 0
        for y in 0..<side {
            for x in 0..<side where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.25 {
                // Pixel corner farthest from the centre, so the measure never flatters.
                let dx = abs(CGFloat(x) + 0.5 - c) + 0.5
                let dy = abs(CGFloat(y) + 0.5 - c) + 0.5
                far = max(far, (dx * dx + dy * dy).squareRoot())
            }
        }
        return far / Self.scale
    }

    /// Turns red if a `rowGlyphFits` size or offset pushes a glyph within 1 pt of its ring.
    @Test func noRowGlyphTouchesItsRing() throws {
        let names = Set(DeviceIcon.rowGlyphFits.keys).union(DeviceIcon.curated.filter(DeviceIcon.isValid))
        for name in names.sorted() where DeviceIcon.isValid(name) {
            let isMainAudio = name == "hifispeaker.arrow.forward.fill"
            let diameter = isMainAudio ? PopoverColumnGrid.mainAudioRingDiameter : PopoverColumnGrid.haloRingDiameter
            let innerEdge = diameter / 2 - PopoverColumnGrid.ringStrokeWidth / 2
            let image = try #require(DeviceIcon.rowGlyph(name))
            let ink = try #require(farthestInk(image))
            let clearance = innerEdge - ink
            #expect(clearance >= 1.0, "\(name) is \(clearance) pt from its ring's inner edge")
        }
    }
}

private actor PopoverIconTestCountBox {
    private var count = 0
    func increment() -> Int { count += 1; return count }
}
