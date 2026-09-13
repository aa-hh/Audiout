// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Per-Bluetooth-speaker opt-out for "Control speaker volume": whether this
/// speaker's slider drives the speaker's OWN hardware volume. A sibling of
/// `BTTrimStore` — same Application Support directory, its own file so the
/// stores evolve independently, same injectable directory so tests never
/// touch the real `~/Library/Application Support`.
///
/// DEFAULT ON, so what is persisted is the set of UIDs turned OFF. Absence of
/// a record means enabled, and someone who never touches the toggle never
/// grows a file. Keys are the Core Audio device UID (MAC-derived, so the
/// choice survives disconnect/rejoin and un-pair/re-pair), exactly as
/// `BTTrimStore` keys its trims.
///
/// A class, not a struct, because the backend hangs off ``onChange``: it
/// applies (or stops applying) hardware volume the moment the toggle flips,
/// without polling the file.
public final class BTHardwareVolumeStore {

    public static let fileName = "bt-hardware-volume.json"

    struct Envelope: Codable {
        var schemaVersion: Int
        /// The UIDs turned OFF. An array, not a set, so the JSON is a plain
        /// sorted list a human can read.
        var disabledUIDs: [String]
    }

    /// Bump when the on-disk shape changes in a way old readers can't parse.
    static let currentSchemaVersion = 1

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    /// Guarded by `lock`: the pane's checkbox writes on the main thread while
    /// the backend reads on its own state queue during a connect re-decide.
    private let lock = NSLock()
    private var disabled: Set<String>

    /// Fired after a ``setEnabled(_:uid:)`` that actually changed something,
    /// with the UID and its new state — the backend's cue to start or stop
    /// driving that speaker's hardware volume.
    public var onChange: ((String, Bool) -> Void)?

    /// - Parameters:
    ///   - directory: where the file lives. Defaults to the same
    ///     `Application Support/Audiout/` directory as the other stores;
    ///     tests pass a throwaway temp directory.
    ///   - fileName: which file — ``fileName`` by default.
    public init(directory: URL = GroupStore.defaultDirectory,
                fileName: String = BTHardwareVolumeStore.fileName) {
        self.fileURL = directory.appendingPathComponent(fileName)
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.decoder = JSONDecoder()
        self.disabled = Self.loadDisabled(fileURL: fileURL, decoder: decoder)
    }

    /// Default-on: a UID with no record is enabled.
    public func isEnabled(uid: String) -> Bool {
        lock.withLock { !disabled.contains(uid) }
    }

    /// Persist the choice for one speaker and tell ``onChange`` about it. A
    /// write that fails still changes the in-memory answer — the toggle the
    /// user just clicked must not lie back at them for the rest of the
    /// session — and is reported through `Telemetry.fail`. Returns whether the
    /// choice reached DISK (unchanged counts as persisted): success-gated
    /// callers (the analytics capture) key off it.
    @discardableResult
    public func setEnabled(_ enabled: Bool, uid: String) -> Bool {
        let (changed, snapshot): (Bool, Set<String>) = lock.withLock {
            let wasEnabled = !disabled.contains(uid)
            if enabled { disabled.remove(uid) } else { disabled.insert(uid) }
            return (wasEnabled != enabled, disabled)
        }
        guard changed else { return true }
        var persisted = true
        do {
            try write(disabled: snapshot)
        } catch {
            persisted = false
            Telemetry.fail(.localPlayback, "bt_volume:store_write_failed",
                           local: ["error": String(describing: error)])
        }
        onChange?(uid, enabled)
        return persisted
    }

    private static func loadDisabled(fileURL: URL, decoder: JSONDecoder) -> Set<String> {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else { return [] }
        let envelope: Envelope
        do {
            envelope = try decoder.decode(Envelope.self, from: data)
        } catch {
            // Same recovery as every other store here: move the unreadable
            // file aside rather than fight it on every launch.
            StoreRecovery.quarantine(fileURL)
            return []
        }
        guard envelope.schemaVersion <= currentSchemaVersion else { return [] }
        return Set(envelope.disabledUIDs)
    }

    private func write(disabled: Set<String>) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let envelope = Envelope(schemaVersion: Self.currentSchemaVersion,
                                disabledUIDs: disabled.sorted())
        let data = try encoder.encode(envelope)
        try data.write(to: fileURL, options: .atomic)
    }
}
