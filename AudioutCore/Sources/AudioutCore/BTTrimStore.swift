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
    /// A CAST row's bound, twice the Bluetooth one. The protocol's own buffer
    /// (seconds) is measured on the wire and taken out automatically; what this
    /// offset covers is everything AFTER the receiver's media clock — its
    /// output stage, its DAC, and, when the target is a TV, the whole
    /// HDMI → TV → soundbar chain, none of which any Cast surface reports.
    /// Google's own published residues are 0–40 ms for a speaker, 0–80 ms for a
    /// soundbar and 0–70 ms for a receiver; a TV feeding a soundbar over ARC
    /// plausibly passes 400 ms, so ±1000 ms is headroom over the worst chain,
    /// NOT a dial for seconds. The align aid's beat-aliasing argument behind
    /// ``rangeMs`` does not apply: no bisection wizard runs on a Cast row.
    public static let castRangeMs: Double = 1000

    public static func clamp(_ ms: Double, rangeMs: Double = BTSyncTrim.rangeMs) -> Double {
        Swift.min(rangeMs, Swift.max(-rangeMs, ms))
    }

    /// Round to whole ``resolutionMs`` milliseconds, half away from zero, with
    /// NO bound applied — for the intermediate steps that a caller's own
    /// per-device range clamp immediately follows, and for readouts of a value
    /// something else has already bounded.
    public static func snap(_ ms: Double) -> Double {
        (ms / resolutionMs).rounded(.toNearestOrAwayFromZero) * resolutionMs
    }

    /// Snap to whole ``resolutionMs`` milliseconds and clamp to ±`rangeMs`.
    /// Rounds half away from zero; a typed "22.6" or an old 0.1 ms value from
    /// disk both land on a clean integer.
    public static func quantise(_ ms: Double, rangeMs: Double = BTSyncTrim.rangeMs) -> Double {
        clamp(snap(ms), rangeMs: rangeMs)
    }

    /// A spoken/hover description of a trim that spells out the direction
    /// (D7 — never a bare signed number, which readers get backwards). Shared
    /// by the row chip's tooltip and VoiceOver value and the drawer's field
    /// value, so the two can never phrase it differently.
    /// Rounds but deliberately does NOT clamp: the row chip also speaks a
    /// measured latency plus its nudge, and a speaker whose measured latency
    /// exceeds the trim's own ±``rangeMs`` bound must be described as it is,
    /// not shrunk to the bound. Every caller passing a trim passes an
    /// already-clamped one, so nothing else changes.
    public static func spokenOffset(_ ms: Double) -> String {
        let whole = Int(ms.rounded(.toNearestOrAwayFromZero))
        if whole == 0 { return "in sync" }
        return whole > 0 ? "\(whole) milliseconds later" : "\(abs(whole)) milliseconds earlier"
    }
}

/// Codable, versioned JSON persistence for per-device sync trims — a sibling
/// of `DeviceIconStore`: same Application Support directory, its own file so
/// the stores evolve independently. Payload is `[deviceKey: trimMs]`.
///
/// The Bluetooth instance keys by the Core Audio device UID (MAC-derived, so a
/// trim survives disconnect/rejoin AND un-pair/re-pair — never auto-purged);
/// the CAST instance (``castFileName``) keys by the receiver's advertised id
/// and uses only the `trims` map, since a Cast row has no measured latency and
/// no first-mix intercept. One type, two files: the envelope's extra maps are
/// optional, so the Cast file is a plain `{schemaVersion, trims}` and the two
/// stores can never write over each other. The directory is injectable so
/// tests never touch the real `~/Library/Application Support`.
public struct BTTrimStore: Sendable {

    /// The Bluetooth trims' file — the default, unchanged.
    public static let bluetoothFileName = "bt-sync-trims.json"
    /// The Cast user offsets' file, beside it in the same directory.
    public static let castFileName = "cast-sync-offsets.json"

    struct Envelope: Codable {
        var schemaVersion: Int
        var trims: [String: Double]
        /// Roadmap 056 Part A: each Bluetooth device's MEASURED output latency
        /// in ms — what the alignment wizard now writes, distinct from the
        /// user's `trims` nudge on top of it. Optional so a file holding only
        /// trims still decodes; no schema bump needed.
        var latencyMs: [String: Double]?
        /// A small counting number per Bluetooth device UID, handed out in
        /// order of first sighting and never reused. It is what the release
        /// analytics event names a speaker by, because the UID itself is
        /// derived from the MAC address and a hash of one is reversible by
        /// enumerating the address space. An index carries nothing but "this
        /// install's second speaker". Optional for the same reason
        /// `latencyMs` is: a file without it still decodes, so no schema bump.
        var speakerIndex: [String: Int]?
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

    /// - Parameters:
    ///   - directory: where the file lives. Defaults to the same
    ///     `Application Support/Audiout/` directory as the other stores; tests
    ///     pass a throwaway temp directory.
    ///   - fileName: which file — ``bluetoothFileName`` by default,
    ///     ``castFileName`` for the Cast offsets.
    public init(directory: URL = GroupStore.defaultDirectory,
                fileName: String = BTTrimStore.bluetoothFileName) {
        self.fileURL = directory.appendingPathComponent(fileName)
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.decoder = JSONDecoder()
    }

    /// Load the saved trims. Missing file → `nil` (first run — no trims). A
    /// file from a newer schema is treated as missing rather than crashing an
    /// older build.
    public func load() throws -> [String: Double]? {
        try loadEnvelope()?.trims
    }

    /// Overwrite the saved trims, creating the directory/file if needed.
    /// Read-modify-write so the dismissal record survives a trim save.
    public func save(_ trims: [String: Double]) throws {
        var envelope = existingEnvelope()
        envelope.trims = trims
        try write(envelope)
    }

    /// The saved measured latencies (ms per device UID). Missing file, or a
    /// file written before this map existed → `nil`.
    public func loadLatencies() throws -> [String: Double]? {
        try loadEnvelope()?.latencyMs
    }

    /// The saved per-install speaker indices. Missing file, or a file written
    /// before this map existed → `nil`.
    public func loadSpeakerIndex() throws -> [String: Int]? {
        try loadEnvelope()?.speakerIndex
    }

    /// Overwrite the saved speaker indices, preserving every other map
    /// (read-modify-write, same as every other writer here).
    public func saveSpeakerIndex(_ index: [String: Int]) throws {
        var envelope = existingEnvelope()
        envelope.speakerIndex = index
        try write(envelope)
    }

    /// Overwrite the saved latencies, preserving trims and dismissals
    /// (read-modify-write, same as every other writer here).
    public func saveLatencies(_ latencies: [String: Double]) throws {
        var envelope = existingEnvelope()
        envelope.latencyMs = latencies
        try write(envelope)
    }

    /// Delete BOTH of a device's alignment entries — its measured latency and
    /// its trim — in one read-modify-write (roadmap 056: the drawer's "Reset
    /// alignment"). Deleting rather than saving 0 is the whole point: "tuned"
    /// is decided by whether an entry EXISTS, so a stored 0 would leave the row
    /// reading "0 ms" forever instead of returning it to "Not set".
    ///
    /// The speaker's index is deliberately left alone: resetting a speaker's
    /// timing does not make it a different speaker, and a second index would
    /// split one speaker's history in two.
    public func clearAlignment(deviceUID: String) throws {
        var envelope = existingEnvelope()
        envelope.trims.removeValue(forKey: deviceUID)
        envelope.latencyMs?.removeValue(forKey: deviceUID)
        try write(envelope)
    }

    /// The file as it stands (or a fresh envelope), stamped with the current
    /// schema version — the read half of every writer's read-modify-write, so
    /// saving one map can never drop another.
    private func existingEnvelope() -> Envelope {
        var envelope = ((try? loadEnvelope()) ?? nil)
            ?? Envelope(schemaVersion: Self.currentSchemaVersion, trims: [:],
                        latencyMs: nil, speakerIndex: nil)
        envelope.schemaVersion = Self.currentSchemaVersion
        return envelope
    }

    private func loadEnvelope() throws -> Envelope? {
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
        return envelope
    }

    private func write(_ envelope: Envelope) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(envelope)
        try data.write(to: fileURL, options: .atomic)
    }
}
