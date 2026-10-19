// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The hidden-speakers list an older build wrote (`hidden-speakers.json`):
/// the device ids the user took out of the Output Speakers card. Kept only as
/// a legacy import: `SpeakerLibraryController` reads it when it starts with no
/// speaker library file (nor a quarantined copy of one), and turns each id
/// into a "Hide when not in use" visibility. Nothing in the app writes it any
/// more; `save` remains for tests. The directory is injectable so tests never
/// touch the real `~/Library/Application Support`.
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
