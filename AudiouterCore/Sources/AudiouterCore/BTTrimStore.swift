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
    /// The − / + buttons' plain step. The field itself accepts 1 ms typing.
    public static let coarseStepMs = 10
    /// The fine step: ⌥-click on − / +, and the field's ↑/↓ arrow nudge —
    /// 10 ms proved too coarse to collapse the flam by ear (live finding).
    public static let fineStepMs = 1

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
        /// Device UIDs whose first-mix alignment intercept the user dismissed
        /// with "Not now" (W3) — FINAL, never auto-prompted again. Optional so
        /// a pre-existing file (and an old reader on a new file) decodes
        /// cleanly; no schema bump needed.
        var alignmentPromptDismissed: [String]?
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
        try loadEnvelope()?.trims
    }

    /// Overwrite the saved trims, creating the directory/file if needed.
    /// Read-modify-write so the dismissal record survives a trim save.
    public func save(_ trims: [String: Int]) throws {
        var envelope = ((try? loadEnvelope()) ?? nil)
            ?? Envelope(schemaVersion: Self.currentSchemaVersion, trims: [:],
                        alignmentPromptDismissed: nil)
        envelope.schemaVersion = Self.currentSchemaVersion
        envelope.trims = trims
        try write(envelope)
    }

    /// Device UIDs whose first-mix intercept was dismissed ("Not now" — final).
    public func loadDismissedUIDs() throws -> Set<String> {
        Set((try loadEnvelope())?.alignmentPromptDismissed ?? [])
    }

    /// Overwrite the dismissal set, preserving trims (read-modify-write).
    public func saveDismissedUIDs(_ uids: Set<String>) throws {
        var envelope = ((try? loadEnvelope()) ?? nil)
            ?? Envelope(schemaVersion: Self.currentSchemaVersion, trims: [:],
                        alignmentPromptDismissed: nil)
        envelope.schemaVersion = Self.currentSchemaVersion
        envelope.alignmentPromptDismissed = uids.sorted()
        try write(envelope)
    }

    private func loadEnvelope() throws -> Envelope? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        let envelope = try decoder.decode(Envelope.self, from: data)
        guard envelope.schemaVersion <= Self.currentSchemaVersion else { return nil }
        return envelope
    }

    private func write(_ envelope: Envelope) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(envelope)
        try data.write(to: fileURL, options: .atomic)
    }
}
