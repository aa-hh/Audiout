// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

// razor: Revert targets the drawer's open-time value, not a calibrated
// baseline — there is no calibration source yet. When the setup wizard
// lands it should persist a per-device baseline alongside the trim and
// Revert should prefer it.
/// The SYNC column's shared numeric contract (BT-OFFSET-UI/BT-SYNC-DRAWER): a
/// per-device signed manual trim in milliseconds, ±``rangeMs``, stepped by
/// ``coarseStepMs`` from the − / + buttons (typing in the value field allows
/// 1 ms) and resolved to ``resolutionMs`` by the drawer's ruler. One clamp
/// shared by the UI and the backend write so they can never disagree on the
/// range.
public enum BTSyncTrim {
    /// The trim's absolute bound (± this many ms). Chosen with the align aid's
    /// beat spacing in mind: ticks at ~72 BPM (~833 ms) keep a fully-offset
    /// device from aliasing as aligned one beat late — 500 ms spacing would.
    public static let rangeMs: Double = 500
    /// The − / + buttons' plain step. The field itself accepts 1 ms typing.
    public static let coarseStepMs: Double = 10
    /// The fine step: ⌥-click on − / +, and the field's ↑/↓ arrow nudge —
    /// 10 ms proved too coarse to collapse the flam by ear (live finding).
    public static let fineStepMs: Double = 1
    /// The scrub's quantum. Every committed trim is a whole multiple of this,
    /// so the readout, the ruler, and the persisted value can never disagree
    /// about what "22.4" means.
    public static let resolutionMs: Double = 0.1

    public static func clamp(_ ms: Double) -> Double {
        Swift.min(rangeMs, Swift.max(-rangeMs, ms))
    }

    /// Snap to ``resolutionMs`` and clamp to ±``rangeMs``. Scales up by 10
    /// (not down by 0.1 — division amplifies the input's own binary-float
    /// dust) before rounding half-away-from-zero, so two values that are
    /// decimal-equal but bit-different going in (`0.1 * 3` vs `0.3`) always
    /// land on the exact same `Double` coming out.
    public static func quantise(_ ms: Double) -> Double {
        let snapped = (ms * 10).rounded(.toNearestOrAwayFromZero) / 10
        return clamp(snapped)
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
        var trims: [String: Double]
    }

    /// Bump when the on-disk shape changes in a way old readers can't parse.
    /// NOT bumped for the `Int` → `Double` widening (BT-SYNC-DRAWER T1): a v1
    /// file's values are bare JSON numbers (`22`), and `JSONDecoder` reads a
    /// JSON integer straight into a `Double` field with no loss — the feature
    /// had never shipped when this changed, so no on-disk file needed a
    /// migration. Do not "fix" this into a version bump.
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
    public func load() throws -> [String: Double]? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        let envelope = try decoder.decode(Envelope.self, from: data)
        guard envelope.schemaVersion <= Self.currentSchemaVersion else { return nil }
        return envelope.trims
    }

    /// Overwrite the saved trims, creating the directory/file if needed.
    public func save(_ trims: [String: Double]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let envelope = Envelope(schemaVersion: Self.currentSchemaVersion, trims: trims)
        let data = try encoder.encode(envelope)
        try data.write(to: fileURL, options: .atomic)
    }
}
