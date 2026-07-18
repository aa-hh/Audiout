// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Where a per-app redirect sends that app's audio (PLAN-POPOVER-ROUTING.md
/// decision 8, EXTENDED with a genuine third state). Three cases:
///  - `.noRedirect` — the neutral/unset state. The default for a newly-added
///    app; no deliberate choice has been made yet.
///  - `.currentDevice` — an explicit, deliberate "play on this Mac" pick, now
///    its own selectable menu item (previously this doubled as both the
///    default AND the explicit choice — no longer).
///  - `.device(id:)` — names an AirPlay target device by its stable `Device.id`.
///
/// `.noRedirect` and `.currentDevice` are ENGINE/CAPTURE-EQUIVALENT: both mean
/// "this app plays locally, is not captured for remote streaming, and stays in
/// the whole-system mix." They differ only in the popover UI (default/unset vs.
/// a deliberate pick) — every engine/capture call site should pattern-match
/// positively on `.device` (as they already do) rather than negatively on
/// `.currentDevice`, so both local states are treated identically without
/// needing a shared case.
public enum AppRouteDestination: Equatable, Sendable {
    case noRedirect
    case currentDevice
    case device(id: String)
}

extension AppRouteDestination {
    /// True only for `.device(id:)` — the app is actually redirected to an
    /// AirPlay target. Both `.noRedirect` and `.currentDevice` mean "plays
    /// locally" and return `false`. The single source of truth for "is this
    /// route actually routed away" — use this instead of `!= .currentDevice`,
    /// which silently miscounts `.noRedirect` as routed.
    public var isDeviceRoute: Bool {
        if case .device = self { return true }
        return false
    }
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
        destination: AppRouteDestination = .noRedirect,
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
    ///
    /// ## Backward compatibility (no schema bump needed)
    /// Adding `.noRedirect` is a PURELY ADDITIVE change to `destinationKind`'s
    /// string vocabulary — old files only ever contain `"currentDevice"` or
    /// `"device"`, both of which still decode to the exact same case they
    /// always did (`.currentDevice` is preserved as `.currentDevice`, NOT
    /// reinterpreted as `.noRedirect`, even though it used to double as the
    /// unset/default state — a persisted route the user never touched still
    /// round-trips to the same value, and behaves identically at the engine/
    /// capture level either way since both are `isDeviceRoute == false`). No
    /// old reader ever needs to understand `"noRedirect"` (this app doesn't
    /// ship an older binary that reads a newer file), so `currentSchemaVersion`
    /// stays at 1.
    public struct PersistedRoute: Codable, Equatable, Sendable {
        public var bundleID: String
        public var displayName: String
        public var destinationKind: String   // "noRedirect" | "currentDevice" | "device"
        public var destinationDeviceID: String?
        public var volume: Int

        public init(_ route: AppRoute) {
            self.bundleID = route.bundleID
            self.displayName = route.displayName
            self.volume = route.volume
            switch route.destination {
            case .noRedirect:            destinationKind = "noRedirect";     destinationDeviceID = nil
            case .currentDevice:         destinationKind = "currentDevice"; destinationDeviceID = nil
            case .device(let id):        destinationKind = "device";        destinationDeviceID = id
            }
        }

        /// Reconstruct the `AppRoute`. An unrecognized kind, a `"device"`
        /// entry missing its id, or the explicit `"noRedirect"` kind all fall
        /// back to `.noRedirect` — the neutral/unset state is the safe default
        /// now (previously `.currentDevice` played that role; see the type's
        /// doc comment). `"currentDevice"` is preserved as the deliberate
        /// `.currentDevice` case it always named.
        public var route: AppRoute {
            let destination: AppRouteDestination
            switch destinationKind {
            case "device":         destination = destinationDeviceID.map { .device(id: $0) } ?? .noRedirect
            case "currentDevice":  destination = .currentDevice
            default:               destination = .noRedirect   // "noRedirect" + any unrecognized value
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
    ///   same `Application Support/Audiouter/` directory as
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
