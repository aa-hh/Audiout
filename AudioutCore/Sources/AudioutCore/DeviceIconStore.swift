// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Codable, versioned JSON persistence for per-device icon overrides — a
/// sibling of `ExcludedAppsStore`/`AppRouteStore`/`GroupStore`: same
/// Application Support directory, its own file so the stores evolve
/// independently. Payload is `[deviceID: symbolName]`; `symbolName` is an
/// SF Symbols name string, resolved via `NSImage(systemSymbolName:)` at
/// render time — an unknown or unavailable name simply falls back to the
/// default icon, so this store never validates symbol names itself. The
/// directory is injectable so tests never touch the real
/// `~/Library/Application Support`.
public struct DeviceIconStore: Sendable {

    struct Envelope: Codable {
        var schemaVersion: Int
        var icons: [String: String]
    }

    /// Bump when the on-disk shape changes in a way old readers can't parse.
    static let currentSchemaVersion = 1

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// - Parameter directory: where `device-icons.json` lives. Defaults to the
    ///   same `Application Support/Audiout/` directory as the other
    ///   stores; tests pass a throwaway temp directory.
    public init(directory: URL = GroupStore.defaultDirectory) {
        self.fileURL = directory.appendingPathComponent("device-icons.json")
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.decoder = JSONDecoder()
    }

    /// Load the saved icon overrides. Missing file → `nil` (first run — no
    /// overrides). A file from a newer schema is treated as missing rather
    /// than crashing an older build.
    public func load() throws -> [String: String]? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        let envelope: Envelope
        do {
            envelope = try decoder.decode(Envelope.self, from: data)
        } catch {
            StoreRecovery.quarantine(fileURL)
            throw error
        }
        guard envelope.schemaVersion <= Self.currentSchemaVersion else { return nil }
        return envelope.icons
    }

    /// Overwrite the saved icon overrides, creating the directory/file if needed.
    public func save(_ icons: [String: String]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let envelope = Envelope(schemaVersion: Self.currentSchemaVersion, icons: icons)
        let data = try encoder.encode(envelope)
        try data.write(to: fileURL, options: .atomic)
    }
}
