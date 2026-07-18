// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// One application the user has excluded from capture (Settings › Audio).
/// LOCKED DECISION (2026-07-17): "excluded" means **never captured** — the app's
/// audio always plays on this Mac and is never redirected, even under an active
/// group; an excluded app is un-routable (its per-app route is pruned and it's
/// hidden from the Applications card / picker). `bundleID` is the stable identity
/// (survives quit/relaunch), exactly like `AppRoute`.
public struct ExcludedApp: Equatable, Sendable {
    public var bundleID: String
    public var displayName: String

    public init(bundleID: String, displayName: String) {
        self.bundleID = bundleID
        self.displayName = displayName
    }
}

/// Codable, versioned JSON persistence for the excluded-apps denylist — the
/// *list* half of the settings persistence split (scalars live in `AppSettings`
/// over `UserDefaults`). A sibling of `AppRouteStore`/`GroupStore`/`RoutingStore`:
/// same Application Support directory, its own file so the stores evolve
/// independently. The directory is injectable so tests never touch the real
/// `~/Library/Application Support`.
public struct ExcludedAppsStore: Sendable {

    /// The persisted form of one excluded app.
    public struct PersistedApp: Codable, Equatable, Sendable {
        public var bundleID: String
        public var displayName: String

        public init(_ app: ExcludedApp) {
            self.bundleID = app.bundleID
            self.displayName = app.displayName
        }

        public var app: ExcludedApp { ExcludedApp(bundleID: bundleID, displayName: displayName) }
    }

    struct Envelope: Codable {
        var schemaVersion: Int
        var apps: [PersistedApp]
    }

    /// Bump when the on-disk shape changes in a way old readers can't parse.
    static let currentSchemaVersion = 1

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// - Parameter directory: where `excluded-apps.json` lives. Defaults to the
    ///   same `Application Support/Audiouted/` directory as the other
    ///   stores; tests pass a throwaway temp directory.
    public init(directory: URL = GroupStore.defaultDirectory) {
        self.fileURL = directory.appendingPathComponent("excluded-apps.json")
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.decoder = JSONDecoder()
    }

    /// Load the saved excluded apps. Missing file → `nil` (first run — no
    /// exclusions). A file from a newer schema is treated as missing rather than
    /// crashing an older build.
    public func load() throws -> [ExcludedApp]? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        let envelope = try decoder.decode(Envelope.self, from: data)
        guard envelope.schemaVersion <= Self.currentSchemaVersion else { return nil }
        return envelope.apps.map { $0.app }
    }

    /// Overwrite the saved excluded apps, creating the directory/file if needed.
    public func save(_ apps: [ExcludedApp]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let envelope = Envelope(schemaVersion: Self.currentSchemaVersion, apps: apps.map(PersistedApp.init))
        let data = try encoder.encode(envelope)
        try data.write(to: fileURL, options: .atomic)
    }
}
