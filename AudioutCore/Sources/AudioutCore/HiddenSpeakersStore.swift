// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Codable, versioned JSON persistence for the hidden-speakers list — the
/// device ids the user took out of the Output Speakers card via the footer's
/// "−" (they come back through the "+" menu's "Hidden speakers" section).
/// Hiding is DISPLAY-ONLY: it never touches selection, groups, or routing, and
/// a hidden speaker that IS selected (e.g. through a saved scene) still renders
/// — nothing may play invisibly. A sibling of `ExcludedAppsStore`/`GroupStore`:
/// same Application Support directory, its own file so the stores evolve
/// independently. The directory is injectable so tests never touch the real
/// `~/Library/Application Support`.
public struct HiddenSpeakersStore: Sendable {

    struct Envelope: Codable {
        var schemaVersion: Int
        var deviceIDs: [String]
    }

    /// Bump when the on-disk shape changes in a way old readers can't parse.
    static let currentSchemaVersion = 1

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// - Parameter directory: where `hidden-speakers.json` lives. Defaults to
    ///   the same `Application Support/Audiout/` directory as the other
    ///   stores; tests pass a throwaway temp directory.
    public init(directory: URL = GroupStore.defaultDirectory) {
        self.fileURL = directory.appendingPathComponent("hidden-speakers.json")
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.decoder = JSONDecoder()
    }

    /// Load the saved hidden device ids. Missing file → `nil` (first run — no
    /// hidden speakers). A file from a newer schema is treated as missing
    /// rather than crashing an older build.
    /// The file is moved aside first (`StoreRecovery.quarantine`) so the next save cannot overwrite a file this build cannot read.
    public func load() throws -> [String]? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        let envelope: Envelope
        do {
            envelope = try decoder.decode(Envelope.self, from: data)
        } catch {
            StoreRecovery.quarantine(fileURL)
            throw error
        }
        guard envelope.schemaVersion <= Self.currentSchemaVersion else {
            StoreRecovery.quarantine(fileURL)
            return nil
        }
        return envelope.deviceIDs
    }

    /// Overwrite the saved hidden device ids, creating the directory/file if needed.
    public func save(_ deviceIDs: [String]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let envelope = Envelope(schemaVersion: Self.currentSchemaVersion, deviceIDs: deviceIDs)
        let data = try encoder.encode(envelope)
        try data.write(to: fileURL, options: .atomic)
    }
}
