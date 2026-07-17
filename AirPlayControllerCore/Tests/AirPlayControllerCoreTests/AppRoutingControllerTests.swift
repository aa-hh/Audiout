// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Alec Henderson and contributors.

import XCTest
@testable import AirPlayControllerCore

final class AppRoutingControllerTests: XCTestCase {

    private func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func fileURL(in dir: URL) -> URL {
        dir.appendingPathComponent("app-routes.json")
    }

    // MARK: Add / set / remove round-trip through a reloaded controller

    func testAddSetRemoveRoundTripsThroughReloadedController() throws {
        let dir = tempDirectory()
        let controller = AppRoutingController(store: AppRouteStore(directory: dir), loadPersisted: false)

        controller.addRoute(bundleID: "com.apple.Music", displayName: "Music")
        controller.setDestination(.device(id: "homepod-1"), for: "com.apple.Music")
        controller.setVolume(42, for: "com.apple.Music")

        controller.addRoute(bundleID: "com.spotify.client", displayName: "Spotify")

        let reloaded = AppRoutingController(store: AppRouteStore(directory: dir), loadPersisted: true)
        XCTAssertEqual(reloaded.appRoutes, [
            AppRoute(bundleID: "com.apple.Music", displayName: "Music", destination: .device(id: "homepod-1"), volume: 42),
            AppRoute(bundleID: "com.spotify.client", displayName: "Spotify"),
        ])

        reloaded.removeRoute(bundleID: "com.apple.Music")
        let reloadedAgain = AppRoutingController(store: AppRouteStore(directory: dir), loadPersisted: true)
        XCTAssertEqual(reloadedAgain.appRoutes, [
            AppRoute(bundleID: "com.spotify.client", displayName: "Spotify"),
        ])
    }

    func testInsertionOrderIsStable() {
        let controller = AppRoutingController(store: AppRouteStore(directory: tempDirectory()), loadPersisted: false)
        controller.addRoute(bundleID: "b", displayName: "B")
        controller.addRoute(bundleID: "a", displayName: "A")
        controller.addRoute(bundleID: "c", displayName: "C")
        XCTAssertEqual(controller.appRoutes.map(\.bundleID), ["b", "a", "c"])
    }

    // MARK: routedAppCount

    func testRoutedAppCountCountsOnlyRedirectedRoutes() {
        let controller = AppRoutingController(store: AppRouteStore(directory: tempDirectory()), loadPersisted: false)
        controller.addRoute(bundleID: "com.apple.Music", displayName: "Music")
        controller.addRoute(bundleID: "com.spotify.client", displayName: "Spotify")
        controller.addRoute(bundleID: "com.apple.Safari", displayName: "Safari")

        XCTAssertEqual(controller.routedAppCount, 0)

        controller.setDestination(.device(id: "homepod-1"), for: "com.apple.Music")
        XCTAssertEqual(controller.routedAppCount, 1)

        controller.setDestination(.device(id: "office"), for: "com.spotify.client")
        XCTAssertEqual(controller.routedAppCount, 2)

        controller.setDestination(.currentDevice, for: "com.apple.Music")
        XCTAssertEqual(controller.routedAppCount, 1)
    }

    // MARK: handleDeviceUnavailable

    func testHandleDeviceUnavailableResetsMatchingRoutesAndPersists() throws {
        let dir = tempDirectory()
        let controller = AppRoutingController(store: AppRouteStore(directory: dir), loadPersisted: false)
        controller.addRoute(bundleID: "com.apple.Music", displayName: "Music")
        controller.addRoute(bundleID: "com.spotify.client", displayName: "Spotify")
        controller.addRoute(bundleID: "com.apple.Safari", displayName: "Safari")
        controller.setDestination(.device(id: "homepod-1"), for: "com.apple.Music")
        controller.setDestination(.device(id: "office"), for: "com.spotify.client")

        controller.handleDeviceUnavailable(id: "homepod-1")

        XCTAssertEqual(controller.appRoutes.first { $0.bundleID == "com.apple.Music" }?.destination, .currentDevice)
        XCTAssertEqual(controller.appRoutes.first { $0.bundleID == "com.spotify.client" }?.destination, .device(id: "office"),
                       "unrelated device routes must be untouched")

        let reloaded = AppRoutingController(store: AppRouteStore(directory: dir), loadPersisted: true)
        XCTAssertEqual(reloaded.appRoutes.first { $0.bundleID == "com.apple.Music" }?.destination, .currentDevice,
                       "the fallback must be persisted")
    }

    func testHandleDeviceUnavailableWithNoMatchIsNoOpAndDoesNotPersist() throws {
        let dir = tempDirectory()
        let controller = AppRoutingController(store: AppRouteStore(directory: dir), loadPersisted: false)
        controller.addRoute(bundleID: "com.apple.Music", displayName: "Music")
        // First mutation creates the file; capture its state before the no-op.
        let fileURL = fileURL(in: dir)
        let before = try Data(contentsOf: fileURL)

        controller.handleDeviceUnavailable(id: "some-other-device")

        let after = try Data(contentsOf: fileURL)
        XCTAssertEqual(before, after, "a no-op fallback must not rewrite the store")
    }

    // MARK: Duplicate addRoute is a no-op

    func testDuplicateAddRouteIsNoOp() {
        let controller = AppRoutingController(store: AppRouteStore(directory: tempDirectory()), loadPersisted: false)
        controller.addRoute(bundleID: "com.apple.Music", displayName: "Music")
        controller.setDestination(.device(id: "homepod-1"), for: "com.apple.Music")
        controller.setVolume(55, for: "com.apple.Music")

        controller.addRoute(bundleID: "com.apple.Music", displayName: "Different Name")

        XCTAssertEqual(controller.appRoutes.count, 1)
        XCTAssertEqual(controller.appRoutes[0].displayName, "Music", "duplicate add must not overwrite the existing route")
        XCTAssertEqual(controller.appRoutes[0].destination, .device(id: "homepod-1"))
        XCTAssertEqual(controller.appRoutes[0].volume, 55)
    }

    // MARK: Volume clamps

    func testSetVolumeClamps() {
        let controller = AppRoutingController(store: AppRouteStore(directory: tempDirectory()), loadPersisted: false)
        controller.addRoute(bundleID: "com.apple.Music", displayName: "Music")

        controller.setVolume(150, for: "com.apple.Music")
        XCTAssertEqual(controller.appRoutes[0].volume, 100)

        controller.setVolume(-20, for: "com.apple.Music")
        XCTAssertEqual(controller.appRoutes[0].volume, 0)
    }

    // MARK: No-op setDestination / setVolume must not rewrite the file

    func testNoOpSetDestinationDoesNotRewriteFile() throws {
        let dir = tempDirectory()
        let controller = AppRoutingController(store: AppRouteStore(directory: dir), loadPersisted: false)
        controller.addRoute(bundleID: "com.apple.Music", displayName: "Music")
        let fileURL = fileURL(in: dir)
        let before = try Data(contentsOf: fileURL)

        controller.setDestination(.currentDevice, for: "com.apple.Music") // already .currentDevice

        let after = try Data(contentsOf: fileURL)
        XCTAssertEqual(before, after, "setting the same destination must not rewrite the store")
    }

    func testNoOpSetVolumeDoesNotRewriteFile() throws {
        let dir = tempDirectory()
        let controller = AppRoutingController(store: AppRouteStore(directory: dir), loadPersisted: false)
        controller.addRoute(bundleID: "com.apple.Music", displayName: "Music") // volume defaults to 100
        let fileURL = fileURL(in: dir)
        let before = try Data(contentsOf: fileURL)

        controller.setVolume(100, for: "com.apple.Music") // same value

        let after = try Data(contentsOf: fileURL)
        XCTAssertEqual(before, after, "setting the same volume must not rewrite the store")
    }

    func testNoOpMutationsDoNotChangeState() {
        let controller = AppRoutingController(store: AppRouteStore(directory: tempDirectory()), loadPersisted: false)
        controller.addRoute(bundleID: "com.apple.Music", displayName: "Music")
        let before = controller.appRoutes

        controller.setDestination(.currentDevice, for: "com.apple.Music")
        controller.setVolume(100, for: "com.apple.Music")
        controller.setDestination(.currentDevice, for: "unknown.bundle.id")
        controller.setVolume(50, for: "unknown.bundle.id")
        controller.removeRoute(bundleID: "unknown.bundle.id")

        XCTAssertEqual(controller.appRoutes, before)
    }

    // MARK: routedAppNames(for:) — feeds the DeviceRowView routing sublabel

    func testRoutedAppNamesFiltersByDeviceIDAndExcludesCurrentDevice() {
        let controller = AppRoutingController(store: AppRouteStore(directory: tempDirectory()), loadPersisted: false)
        controller.addRoute(bundleID: "com.apple.Music", displayName: "Music")
        controller.addRoute(bundleID: "com.spotify.client", displayName: "Spotify")
        controller.addRoute(bundleID: "com.apple.Safari", displayName: "Safari")

        controller.setDestination(.device(id: "homepod-1"), for: "com.apple.Music")
        controller.setDestination(.device(id: "office"), for: "com.spotify.client")
        // com.apple.Safari stays .currentDevice (no redirect) — must be excluded.

        XCTAssertEqual(controller.routedAppNames(for: "homepod-1"), ["Music"])
        XCTAssertEqual(controller.routedAppNames(for: "office"), ["Spotify"])
        XCTAssertEqual(controller.routedAppNames(for: "some-other-device"), [],
                       "a device with no routes gets an empty list")
    }

    func testRoutedAppNamesExcludesCurrentDeviceRoutesEntirely() {
        let controller = AppRoutingController(store: AppRouteStore(directory: tempDirectory()), loadPersisted: false)
        controller.addRoute(bundleID: "com.apple.Music", displayName: "Music")
        // Never redirected — stays .currentDevice.

        XCTAssertEqual(controller.routedAppNames(for: "homepod-1"), [])
    }

    func testRoutedAppNamesPreservesStableRouteOrder() {
        let controller = AppRoutingController(store: AppRouteStore(directory: tempDirectory()), loadPersisted: false)
        controller.addRoute(bundleID: "b", displayName: "Zebra App")
        controller.addRoute(bundleID: "a", displayName: "Alpha App")
        controller.addRoute(bundleID: "c", displayName: "Charlie App")

        controller.setDestination(.device(id: "homepod-1"), for: "b")
        controller.setDestination(.device(id: "homepod-1"), for: "a")
        controller.setDestination(.device(id: "homepod-1"), for: "c")

        XCTAssertEqual(controller.routedAppNames(for: "homepod-1"), ["Zebra App", "Alpha App", "Charlie App"],
                       "insertion order is preserved, not sorted")
    }

    func testRoutedAppNamesUpdatesWhenDestinationChanges() {
        let controller = AppRoutingController(store: AppRouteStore(directory: tempDirectory()), loadPersisted: false)
        controller.addRoute(bundleID: "com.apple.Music", displayName: "Music")
        controller.setDestination(.device(id: "homepod-1"), for: "com.apple.Music")
        XCTAssertEqual(controller.routedAppNames(for: "homepod-1"), ["Music"])

        controller.setDestination(.currentDevice, for: "com.apple.Music")
        XCTAssertEqual(controller.routedAppNames(for: "homepod-1"), [],
                       "reverting to .currentDevice removes it from the routing set")
    }
}
