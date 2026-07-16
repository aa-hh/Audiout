// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Alec Henderson and contributors.

import XCTest
@testable import AirPlayControllerCore

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
