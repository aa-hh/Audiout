// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudioutCore

@Suite struct AppRouteStoreTests {

    private func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    @Test func saveLoadRoundTripPreservesRoutesIncludingBothDestinationKinds() throws {
        let dir = tempDirectory()
        let store = AppRouteStore(directory: dir)
        let routes = [
            AppRoute(bundleID: "com.apple.Music", displayName: "Music", destination: .currentDevice, volume: 80),
            AppRoute(bundleID: "com.spotify.client", displayName: "Spotify", destination: .device(id: "homepod-1"), volume: 60),
        ]
        try store.save(routes)

        let reloaded = try AppRouteStore(directory: dir).load()
        #expect(reloaded == routes)
    }

    /// The new `.noRedirect` case round-trips through save/load exactly like
    /// the other two, and survives sitting alongside them in the same file.
    @Test func saveLoadRoundTripPreservesNoRedirectDestination() throws {
        let dir = tempDirectory()
        let store = AppRouteStore(directory: dir)
        let routes = [
            AppRoute(bundleID: "com.apple.Music", displayName: "Music", destination: .noRedirect, volume: 100),
            AppRoute(bundleID: "com.apple.Podcasts", displayName: "Podcasts", destination: .currentDevice, volume: 70),
            AppRoute(bundleID: "com.spotify.client", displayName: "Spotify", destination: .device(id: "homepod-1"), volume: 60),
        ]
        try store.save(routes)

        let reloaded = try AppRouteStore(directory: dir).load()
        #expect(reloaded == routes)
        #expect(reloaded?.first?.destination == .noRedirect)
    }

    /// A file written by CODE THAT PREDATES `.noRedirect` — only ever
    /// `"currentDevice"`/`"device"` in `destinationKind`, no schema bump — must
    /// still decode correctly. `"currentDevice"` is preserved as the deliberate
    /// `.currentDevice` case it always named, NOT reinterpreted as `.noRedirect`
    /// (see `AppRouteStore.PersistedRoute`'s doc comment for the reasoning).
    @Test func loadOldFormatFileWithOnlyCurrentDeviceAndDeviceKindsDecodesCorrectly() throws {
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
        #expect(loaded == [
            AppRoute(bundleID: "com.apple.Music", displayName: "Music", destination: .currentDevice, volume: 80),
            AppRoute(bundleID: "com.spotify.client", displayName: "Spotify", destination: .device(id: "homepod-1"), volume: 60),
        ], "an old-format file (no noRedirect kind, no schema bump) must decode without loss")
    }

    /// An unrecognized `destinationKind` (belt-and-suspenders — shouldn't occur
    /// in practice) falls back to `.noRedirect`, the new safe default, rather
    /// than crashing or silently becoming `.currentDevice`.
    @Test func unrecognizedDestinationKindFallsBackToNoRedirect() throws {
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
        #expect(loaded?.first?.destination == .noRedirect)
    }

    @Test func loadWithNoFileReturnsNil() throws {
        let store = AppRouteStore(directory: tempDirectory())
        #expect(try store.load() == nil)
    }

    @Test func loadUnknownFutureSchemaVersionReturnsNilRatherThanCrashing() throws {
        let dir = tempDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let future = """
        {"schemaVersion": 999, "routes": [{"bundleID": "com.example.App", "displayName": "X", "destinationKind": "currentDevice", "volume": 100}]}
        """
        try Data(future.utf8).write(to: dir.appendingPathComponent("app-routes.json"))

        let store = AppRouteStore(directory: dir)
        #expect(try store.load() == nil, "a future schema version must not crash an old build")
    }

    // MARK: - Group destinations

    @Test func groupDestinationRoundTripsThroughDisk() throws {
        let dir = tempDirectory()
        let store = AppRouteStore(directory: dir)
        try store.save([AppRoute(bundleID: "com.apple.Safari", displayName: "Safari",
                                 destination: .group(id: "kitchen-group"), volume: 70)])

        #expect(try store.load()?.first?.destination == .group(id: "kitchen-group"))
    }

    /// The group id lands in its OWN key, and NO membership is written — a
    /// group route follows the group live, so a persisted member list would be
    /// a second, stale source of truth.
    @Test func groupDestinationPersistsOnlyTheGroupID() throws {
        let dir = tempDirectory()
        let store = AppRouteStore(directory: dir)
        try store.save([AppRoute(bundleID: "com.apple.Safari", displayName: "Safari",
                                 destination: .group(id: "kitchen-group"))])

        let json = try String(contentsOf: dir.appendingPathComponent("app-routes.json"),
                              encoding: .utf8)
        #expect(json.contains("\"destinationKind\" : \"group\""))
        #expect(json.contains("\"destinationGroupID\" : \"kitchen-group\""))
        #expect(!json.contains("destinationDeviceID"),
                "a group id must never be written into the device-id key")
        #expect(!json.contains("member"), "membership is resolved live, never persisted here")
    }

    /// A `"group"` entry whose id went missing falls back to the neutral state
    /// rather than failing the whole file (same rule `"device"` already has).
    @Test func groupKindWithNoIDFallsBackToNoRedirect() throws {
        let dir = tempDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = """
        {"schemaVersion": 1, "routes": [
            {"bundleID": "com.example.App", "displayName": "X", "destinationKind": "group", "volume": 100}
        ]}
        """
        try Data(json.utf8).write(to: dir.appendingPathComponent("app-routes.json"))

        #expect(try AppRouteStore(directory: dir).load()?.first?.destination == .noRedirect)
    }

    /// The unknown-kind fallback must never quarantine the file: the OTHER
    /// routes in it are perfectly good and the user would lose them all.
    @Test func unknownKindLeavesTheRestOfTheFileIntact() throws {
        let dir = tempDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = """
        {"schemaVersion": 1, "routes": [
            {"bundleID": "com.example.Future", "displayName": "F", "destinationKind": "zone", "destinationZoneID": "z1", "volume": 100},
            {"bundleID": "com.example.App", "displayName": "X", "destinationKind": "device", "destinationDeviceID": "office", "volume": 40}
        ]}
        """
        let file = dir.appendingPathComponent("app-routes.json")
        try Data(json.utf8).write(to: file)

        let loaded = try AppRouteStore(directory: dir).load()
        #expect(loaded?.count == 2)
        #expect(loaded?[0].destination == .noRedirect)
        #expect(loaded?[1].destination == .device(id: "office"))
        #expect(FileManager.default.fileExists(atPath: file.path),
                "an unrecognized kind is not a corrupt file — nothing may be quarantined")
    }

    @Test func volumeClampsOnInit() {
        let over = AppRoute(bundleID: "com.example.App", displayName: "X", volume: 150)
        #expect(over.volume == 100)

        let under = AppRoute(bundleID: "com.example.App", displayName: "X", volume: -10)
        #expect(under.volume == 0)
    }
}
