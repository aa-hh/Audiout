// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

// razor: Revert targets the drawer's open-time value, not a calibrated
// baseline — there is no calibration source yet. When the setup wizard
// lands it should persist a per-device baseline alongside the trim and
// Revert should prefer it.
/// The SYNC column's shared numeric contract (BT-OFFSET-UI/BT-SYNC-DRAWER): a
/// per-device signed manual trim in WHOLE milliseconds, ±``rangeMs``, changed
/// by the drawer's dual steppers — ``coarseStepMs`` (±10) and ``fineStepMs``
/// (±1) — or typed into the value field. One clamp shared by the UI and the
/// backend write so they can never disagree on the range.
///
/// Whole ms, not tenths (live finding): within a couple of milliseconds two
/// speakers sound identical (the ear can't resolve a flam below ~4 ms), so
/// decimal precision was control-feel theatre with no audible payoff. The
/// scrubbing ruler that decimals were built for was cut with them.
public enum BTSyncTrim {
    /// The trim's absolute bound (± this many ms). Chosen with the align aid's
    /// beat spacing in mind: ticks at ~72 BPM (~833 ms) keep a fully-offset
    /// device from aliasing as aligned one beat late — 500 ms spacing would.
    public static let rangeMs: Double = 500
    /// The coarse (±10) stepper's step — the "get close" control.
    public static let coarseStepMs: Double = 10
    /// The fine (±1) stepper's step, and the field's ↑/↓ arrow nudge — the
    /// "settle it" control.
    public static let fineStepMs: Double = 1
    /// The smallest change the trim ever takes: one whole millisecond. Every
    /// committed value is a whole multiple of this, so the readout, the
    /// steppers, and the persisted value can never disagree.
    public static let resolutionMs: Double = 1

    public static func clamp(_ ms: Double) -> Double {
        Swift.min(rangeMs, Swift.max(-rangeMs, ms))
    }

    /// Snap to whole ``resolutionMs`` milliseconds and clamp to ±``rangeMs``.
    /// Rounds half away from zero; a typed "22.6" or an old 0.1 ms value from
    /// disk both land on a clean integer.
    public static func quantise(_ ms: Double) -> Double {
        clamp((ms / resolutionMs).rounded(.toNearestOrAwayFromZero) * resolutionMs)
    }

    /// A spoken/hover description of a trim that spells out the direction
    /// (D7 — never a bare signed number, which readers get backwards). Shared
    /// by the row chip's tooltip and VoiceOver value and the drawer's field
    /// value, so the two can never phrase it differently.
    public static func spokenOffset(_ ms: Double) -> String {
        let whole = Int(quantise(ms))
        if whole == 0 { return "in sync" }
        return whole > 0 ? "\(whole) milliseconds later" : "\(abs(whole)) milliseconds earlier"
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
