// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Codable, versioned JSON persistence for the speakers the user has hidden
/// from the Groups sidebar's list — a sibling of `DeviceIconStore`/`GroupStore`:
/// same Application Support directory, its own file so the stores evolve
/// independently. Payload is a list of `Device.id`s.
///
/// Hiding is DISPLAY-ONLY: an id in here never affects group membership,
/// selection, or routing — a hidden device that belongs to a group keeps
/// playing. Ids are never pruned against the live fleet either, because a
/// device that has dropped off (a Bluetooth speaker that is merely switched
/// off) is exactly the one the user hid and will come back.
///
/// The set is written as a sorted array so an unchanged selection produces a
/// byte-identical file. The directory is injectable so tests never touch the
/// real `~/Library/Application Support`.
public struct HiddenSpeakersStore: Sendable {

    struct Envelope: Codable {
        var schemaVersion: Int
        var hiddenDeviceIDs: [String]
    }

    /// Bump when the on-disk shape changes in a way old readers can't parse.
    static let currentSchemaVersion = 1

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// - Parameter directory: where `hidden-speakers.json` lives. Defaults to
    ///   the same `Application Support/Audiouter/` directory as the other
    ///   stores; tests pass a throwaway temp directory.
    public init(directory: URL = GroupStore.defaultDirectory) {
        self.fileURL = directory.appendingPathComponent("hidden-speakers.json")
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.decoder = JSONDecoder()
    }

    /// Load the hidden device ids. Missing file → `nil` (first run — nothing
    /// hidden). A file from a newer schema is treated as missing rather than
    /// crashing an older build.
    public func load() throws -> Set<String>? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        let envelope = try decoder.decode(Envelope.self, from: data)
        guard envelope.schemaVersion <= Self.currentSchemaVersion else { return nil }
        return Set(envelope.hiddenDeviceIDs)
    }

    /// Overwrite the hidden device ids, creating the directory/file if needed.
    public func save(_ hiddenDeviceIDs: Set<String>) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let envelope = Envelope(schemaVersion: Self.currentSchemaVersion,
                                hiddenDeviceIDs: hiddenDeviceIDs.sorted())
        let data = try encoder.encode(envelope)
        try data.write(to: fileURL, options: .atomic)
    }
}
