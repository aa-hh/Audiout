// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Codable, versioned JSON persistence for EQ settings — a sibling of
/// `DeviceIconStore`/`BTTrimStore`: same Application Support directory, its own
/// file so the stores evolve independently.
///
/// One envelope carries both halves because they are edited from the same
/// drawer and saved on the same commit: Main Out's whole-mix EQ, and one entry
/// per device id (a speaker keeps one EQ everywhere it appears — Selected
/// Devices or any group). Flat settings are REMOVED on save rather than stored,
/// so the file only ever holds settings a user actually dialled in.
///
/// The directory is injectable so tests never touch the real
/// `~/Library/Application Support`.
public struct DeviceEQStore: Sendable {

    struct Envelope: Codable {
        var schemaVersion: Int
        var mainOut: DeviceEQ?
        var devices: [String: DeviceEQ]
    }

    /// Bump when the on-disk shape changes in a way old readers can't parse.
    static let currentSchemaVersion = 1

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// - Parameter directory: where `device-eq.json` lives. Defaults to the same
    ///   `Application Support/Audiouter/` directory as the other stores; tests
    ///   pass a throwaway temp directory.
    public init(directory: URL = GroupStore.defaultDirectory) {
        self.fileURL = directory.appendingPathComponent("device-eq.json")
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.decoder = JSONDecoder()
    }

    /// Load the saved EQ settings. Missing file → `nil` (first run). A file from
    /// a newer schema is treated as missing rather than crashing an older build.
    public func load() throws -> (mainOut: DeviceEQ?, devices: [String: DeviceEQ])? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        let envelope = try decoder.decode(Envelope.self, from: data)
        guard envelope.schemaVersion <= Self.currentSchemaVersion else { return nil }
        return (envelope.mainOut, envelope.devices)
    }

    /// Overwrite the saved EQ settings, creating the directory/file if needed.
    /// Flat entries are dropped here rather than at each call site, so no writer
    /// can leave a neutral setting behind on disk.
    public func save(mainOut: DeviceEQ?, devices: [String: DeviceEQ]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let envelope = Envelope(
            schemaVersion: Self.currentSchemaVersion,
            mainOut: (mainOut?.isFlat ?? true) ? nil : mainOut,
            devices: devices.filter { !$0.value.isFlat })
        let data = try encoder.encode(envelope)
        try data.write(to: fileURL, options: .atomic)
    }
}
