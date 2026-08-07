// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The SYNC column's shared numeric contract (BT-OFFSET-UI): a per-device
/// signed manual trim in milliseconds, ±``rangeMs``, stepped by
/// ``coarseStepMs`` from the − / + buttons (typing in the value field allows
/// 1 ms). One clamp shared by the UI stepper and the backend write so the two
/// can never disagree on the range.
public enum BTSyncTrim {
    /// The trim's absolute bound (± this many ms). Chosen with the align aid's
    /// beat spacing in mind: ticks at ~72 BPM (~833 ms) keep a fully-offset
    /// device from aliasing as aligned one beat late — 500 ms spacing would.
    public static let rangeMs = 500
    /// The − / + buttons' step. The field itself accepts 1 ms typing.
    public static let coarseStepMs = 10

    public static func clamp(_ ms: Int) -> Int {
        Swift.min(rangeMs, Swift.max(-rangeMs, ms))
    }
}

/// Codable, versioned JSON persistence for per-device Bluetooth sync trims —
/// a sibling of `DeviceIconStore`: same Application Support directory, its own
/// file so the stores evolve independently. Payload is
/// `[deviceUID: trimMs]`, keyed by the Core Audio device UID (MAC-derived, so
/// a trim survives disconnect/rejoin AND un-pair/re-pair — never auto-purged).
/// The directory is injectable so tests never touch the real
/// `~/Library/Application Support`.
public struct BTTrimStore: Sendable {

    struct Envelope: Codable {
        var schemaVersion: Int
        var trims: [String: Int]
    }

    /// Bump when the on-disk shape changes in a way old readers can't parse.
    static let currentSchemaVersion = 1

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// - Parameter directory: where `bt-sync-trims.json` lives. Defaults to
    ///   the same `Application Support/Audiouter/` directory as the other
    ///   stores; tests pass a throwaway temp directory.
    public init(directory: URL = GroupStore.defaultDirectory) {
        self.fileURL = directory.appendingPathComponent("bt-sync-trims.json")
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.decoder = JSONDecoder()
    }

    /// Load the saved trims. Missing file → `nil` (first run — no trims). A
    /// file from a newer schema is treated as missing rather than crashing an
    /// older build.
    public func load() throws -> [String: Int]? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        let envelope = try decoder.decode(Envelope.self, from: data)
        guard envelope.schemaVersion <= Self.currentSchemaVersion else { return nil }
        return envelope.trims
    }

    /// Overwrite the saved trims, creating the directory/file if needed.
    public func save(_ trims: [String: Int]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let envelope = Envelope(schemaVersion: Self.currentSchemaVersion, trims: trims)
        let data = try encoder.encode(envelope)
        try data.write(to: fileURL, options: .atomic)
    }
}
