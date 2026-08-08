// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Codable, versioned JSON persistence for the DISPLAY-hidden device set — a
/// sibling of `DeviceIconStore`/`AppRouteStore`/`GroupStore`: same Application
/// Support directory, its own file so the stores evolve independently. Payload
/// is `[deviceID: lastKnownName]`; the name is carried so the restore menu can
/// still NAME a device that isn't currently discovered. Hiding is display only
/// — nothing here participates in selection, group membership or routing, and
/// the routing stores must never read it. The directory is injectable so tests
/// never touch the real `~/Library/Application Support`.
public struct HiddenDeviceStore: Sendable {

    struct Envelope: Codable {
        var schemaVersion: Int
        var hidden: [String: String]
    }

    /// Bump when the on-disk shape changes in a way old readers can't parse.
    static let currentSchemaVersion = 1

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// - Parameter directory: where `hidden-devices.json` lives. Defaults to the
    ///   same `Application Support/Audiouter/` directory as the other stores;
    ///   tests pass a throwaway temp directory.
    public init(directory: URL = GroupStore.defaultDirectory) {
        self.fileURL = directory.appendingPathComponent("hidden-devices.json")
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.decoder = JSONDecoder()
    }

    /// Load the hidden set. Missing file → `nil` (first run — nothing hidden).
    /// A file from a newer schema is treated as missing rather than crashing an
    /// older build.
    public func load() throws -> [String: String]? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        let envelope = try decoder.decode(Envelope.self, from: data)
        guard envelope.schemaVersion <= Self.currentSchemaVersion else { return nil }
        return envelope.hidden
    }

    /// Overwrite the hidden set, creating the directory/file if needed.
    public func save(_ hidden: [String: String]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let envelope = Envelope(schemaVersion: Self.currentSchemaVersion, hidden: hidden)
        let data = try encoder.encode(envelope)
        try data.write(to: fileURL, options: .atomic)
    }
}
