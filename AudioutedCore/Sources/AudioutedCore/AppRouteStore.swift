// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Alec Henderson and contributors.

import Foundation

/// Where a per-app redirect sends that app's audio (PLAN-POPOVER-ROUTING.md
/// decision 8): `.currentDevice` IS "no redirect" — the app plays locally —
/// there is no separate no-redirect state. `.device(id:)` names an AirPlay
/// target device by its stable `Device.id`.
public enum AppRouteDestination: Equatable, Sendable {
    case currentDevice
    case device(id: String)
}

/// A single app's redirect + volume (PLAN-POPOVER-ROUTING.md decision 2: model
/// backing the new "Applications" popover card, persisted independently of
/// `RoutingStore`/`GroupStore`). `bundleID` is the stable identity — it survives
/// the app quitting/relaunching, matching how `Device.id` survives a device
/// dropping off the network.
public struct AppRoute: Equatable, Sendable {
    public var bundleID: String
    public var displayName: String
    public var destination: AppRouteDestination
    public var volume: Int

    public init(
        bundleID: String,
        displayName: String,
        destination: AppRouteDestination = .currentDevice,
        volume: Int = 100
    ) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.destination = destination
        self.volume = volume.clampedToVolume
    }
}

/// Codable, versioned JSON persistence for per-app audio routes
/// (PLAN-POPOVER-ROUTING.md decision 2), mirroring ``RoutingStore``. Sibling of
/// `GroupStore`/`RoutingStore`: same Application Support directory, its own
/// file so the three evolve independently.
///
/// The directory is injectable so tests never touch the real
/// `~/Library/Application Support` — see `init(directory:)`.
public struct AppRouteStore: Sendable {

    /// The persisted form of one route. `AppRouteDestination` isn't directly
    /// `Codable` (associated value), so we flatten it to a `kind` + optional
    /// `deviceID`, same idiom as `RoutingStore.State`'s `mainOutKind`.
    public struct PersistedRoute: Codable, Equatable, Sendable {
        public var bundleID: String
        public var displayName: String
        public var destinationKind: String   // "currentDevice" | "device"
        public var destinationDeviceID: String?
        public var volume: Int

        public init(_ route: AppRoute) {
            self.bundleID = route.bundleID
            self.displayName = route.displayName
            self.volume = route.volume
            switch route.destination {
            case .currentDevice:        destinationKind = "currentDevice"; destinationDeviceID = nil
            case .device(let id):       destinationKind = "device";        destinationDeviceID = id
            }
        }

        /// Reconstruct the `AppRoute`. An unrecognized / device-without-id
        /// combination falls back to `.currentDevice` (decision 8's safe
        /// default — same fallback shape as `RoutingStore.State.mainOut`).
        public var route: AppRoute {
            let destination: AppRouteDestination
            switch destinationKind {
            case "device": destination = destinationDeviceID.map { .device(id: $0) } ?? .currentDevice
            default:       destination = .currentDevice
            }
            return AppRoute(bundleID: bundleID, displayName: displayName, destination: destination, volume: volume)
        }
    }

    struct Envelope: Codable {
        var schemaVersion: Int
        var routes: [PersistedRoute]
    }

    /// Bump when the on-disk shape changes in a way old readers can't parse.
    static let currentSchemaVersion = 1

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// - Parameter directory: where `app-routes.json` lives. Defaults to the
    ///   same `Application Support/Audiouted/` directory as
    ///   ``GroupStore`` (PLAN-POPOVER-ROUTING.md decision 7 relies on this
    ///   store surviving alongside device state). Tests pass a throwaway temp
    ///   directory instead.
    public init(directory: URL = GroupStore.defaultDirectory) {
        self.fileURL = directory.appendingPathComponent("app-routes.json")
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.decoder = JSONDecoder()
    }

    /// Load the saved app routes. Missing file → `nil` (first run — the caller
    /// applies its own defaults, i.e. no routes). A file from a newer schema is
    /// treated as missing rather than crashing an older build.
    public func load() throws -> [AppRoute]? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        let envelope = try decoder.decode(Envelope.self, from: data)
        guard envelope.schemaVersion <= Self.currentSchemaVersion else { return nil }
        return envelope.routes.map { $0.route }
    }

    /// Overwrite the saved app routes, creating the directory/file if needed.
    public func save(_ routes: [AppRoute]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let envelope = Envelope(schemaVersion: Self.currentSchemaVersion, routes: routes.map(PersistedRoute.init))
        let data = try encoder.encode(envelope)
        try data.write(to: fileURL, options: .atomic)
    }
}
