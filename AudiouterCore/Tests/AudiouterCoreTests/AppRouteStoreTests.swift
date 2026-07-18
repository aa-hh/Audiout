// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import AudiouterCore

final class AppRouteStoreTests: XCTestCase {

    private func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    func testSaveLoadRoundTripPreservesRoutesIncludingBothDestinationKinds() throws {
        let dir = tempDirectory()
        let store = AppRouteStore(directory: dir)
        let routes = [
            AppRoute(bundleID: "com.apple.Music", displayName: "Music", destination: .currentDevice, volume: 80),
            AppRoute(bundleID: "com.spotify.client", displayName: "Spotify", destination: .device(id: "homepod-1"), volume: 60),
        ]
        try store.save(routes)

        let reloaded = try AppRouteStore(directory: dir).load()
        XCTAssertEqual(reloaded, routes)
    }

    /// The new `.noRedirect` case round-trips through save/load exactly like
    /// the other two, and survives sitting alongside them in the same file.
    func testSaveLoadRoundTripPreservesNoRedirectDestination() throws {
        let dir = tempDirectory()
        let store = AppRouteStore(directory: dir)
        let routes = [
            AppRoute(bundleID: "com.apple.Music", displayName: "Music", destination: .noRedirect, volume: 100),
            AppRoute(bundleID: "com.apple.Podcasts", displayName: "Podcasts", destination: .currentDevice, volume: 70),
            AppRoute(bundleID: "com.spotify.client", displayName: "Spotify", destination: .device(id: "homepod-1"), volume: 60),
        ]
        try store.save(routes)

        let reloaded = try AppRouteStore(directory: dir).load()
        XCTAssertEqual(reloaded, routes)
        XCTAssertEqual(reloaded?.first?.destination, .noRedirect)
    }

    /// A file written by CODE THAT PREDATES `.noRedirect` — only ever
    /// `"currentDevice"`/`"device"` in `destinationKind`, no schema bump — must
    /// still decode correctly. `"currentDevice"` is preserved as the deliberate
    /// `.currentDevice` case it always named, NOT reinterpreted as `.noRedirect`
    /// (see `AppRouteStore.PersistedRoute`'s doc comment for the reasoning).
    func testLoadOldFormatFileWithOnlyCurrentDeviceAndDeviceKindsDecodesCorrectly() throws {
        let dir = tempDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let oldFormat = """
        {"schemaVersion": 1, "routes": [
            {"bundleID": "com.apple.Music", "displayName": "Music", "destinationKind": "currentDevice", "volume": 80},
            {"bundleID": "com.spotify.client", "displayName": "Spotify", "destinationKind": "device", "destinationDeviceID": "homepod-1", "volume": 60}
        ]}
        """
        try Data(oldFormat.utf8).write(to: dir.appendingPathComponent("app-routes.json"))

        let store = AppRouteStore(directory: dir)
        let loaded = try store.load()
        XCTAssertEqual(loaded, [
            AppRoute(bundleID: "com.apple.Music", displayName: "Music", destination: .currentDevice, volume: 80),
            AppRoute(bundleID: "com.spotify.client", displayName: "Spotify", destination: .device(id: "homepod-1"), volume: 60),
        ], "an old-format file (no noRedirect kind, no schema bump) must decode without loss")
    }

    /// An unrecognized `destinationKind` (belt-and-suspenders — shouldn't occur
    /// in practice) falls back to `.noRedirect`, the new safe default, rather
    /// than crashing or silently becoming `.currentDevice`.
    func testUnrecognizedDestinationKindFallsBackToNoRedirect() throws {
        let dir = tempDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let malformed = """
        {"schemaVersion": 1, "routes": [
            {"bundleID": "com.example.App", "displayName": "X", "destinationKind": "somethingElse", "volume": 100}
        ]}
        """
        try Data(malformed.utf8).write(to: dir.appendingPathComponent("app-routes.json"))

        let store = AppRouteStore(directory: dir)
        let loaded = try store.load()
        XCTAssertEqual(loaded?.first?.destination, .noRedirect)
    }

    func testLoadWithNoFileReturnsNil() throws {
        let store = AppRouteStore(directory: tempDirectory())
        XCTAssertNil(try store.load())
    }

    func testLoadUnknownFutureSchemaVersionReturnsNilRatherThanCrashing() throws {
        let dir = tempDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let future = """
        {"schemaVersion": 999, "routes": [{"bundleID": "com.example.App", "displayName": "X", "destinationKind": "currentDevice", "volume": 100}]}
        """
        try Data(future.utf8).write(to: dir.appendingPathComponent("app-routes.json"))

        let store = AppRouteStore(directory: dir)
        XCTAssertNil(try store.load(), "a future schema version must not crash an old build")
    }

    func testVolumeClampsOnInit() {
        let over = AppRoute(bundleID: "com.example.App", displayName: "X", volume: 150)
        XCTAssertEqual(over.volume, 100)

        let under = AppRoute(bundleID: "com.example.App", displayName: "X", volume: -10)
        XCTAssertEqual(under.volume, 0)
    }
}
