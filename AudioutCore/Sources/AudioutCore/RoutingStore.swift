// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Where the Main Out selector currently points (SPEC.md §9 2026-07-14b —
/// SoundSource-inspired, two-section selector). This is THE routing decision:
/// one place answers "where is my audio going?".
///
/// - `.selectedDevices` — the ad-hoc "Selected Speakers" set composed by the
///   per-device toggles below. The Mac's own output is just one more device in
///   that set; there is NO separate local-speakers target. **Passthrough is
///   derived**: when the set is exactly {the local device}, the app streams
///   nothing (`GroupController.isPassthrough` is true, backend output set empty).
/// - `.group(id)` — a saved output group.
public enum MainOutTarget: Equatable, Sendable {
    case selectedDevices
    case group(id: String)
}

/// Codable, versioned JSON persistence for the routing state that lives
/// alongside groups (SPEC.md §9 2026-07-14): the persistent "Selected Speakers"
/// set and the current Main Out target. Sibling of ``GroupStore``; same
/// Application Support directory, its own file so the two evolve independently.
///
/// The directory is injectable so tests never touch the real
/// `~/Library/Application Support` — see `init(directory:)`.
public struct RoutingStore: Sendable {

    /// The persisted routing state. `MainOutTarget` isn't directly `Codable`
    /// (associated value), so we flatten it to a `kind` + optional `groupID`.
    public struct State: Codable, Equatable, Sendable {
        public var selectedDeviceIDs: [String]
        public var mainOutKind: String        // "selected" | "group"
        public var mainOutGroupID: String?

        public init(selectedDeviceIDs: [String], mainOut: MainOutTarget) {
            self.selectedDeviceIDs = selectedDeviceIDs
            switch mainOut {
            case .selectedDevices:  mainOutKind = "selected"; mainOutGroupID = nil
            case .group(let id):    mainOutKind = "group";    mainOutGroupID = id
            }
        }

        /// Reconstruct the `MainOutTarget`. An unrecognized / group-without-id
        /// combination falls back to `.selectedDevices` (the safe default).
        public var mainOut: MainOutTarget {
            switch mainOutKind {
            case "group": return mainOutGroupID.map { .group(id: $0) } ?? .selectedDevices
            default:      return .selectedDevices
            }
        }
    }

    struct Envelope: Codable {
        var schemaVersion: Int
        var state: State
    }

    /// Bump when the on-disk shape changes in a way old readers can't parse.
    static let currentSchemaVersion = 1

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// - Parameter directory: where `routing.json` lives. Defaults to the same
    ///   `Application Support/Audiout/` directory as ``GroupStore``.
    ///   Tests pass a throwaway temp directory instead.
    public init(directory: URL = GroupStore.defaultDirectory) {
        self.fileURL = directory.appendingPathComponent("routing.json")
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.decoder = JSONDecoder()
    }

    /// Load the saved routing state. Missing file → `nil` (first run — the caller
    /// applies its own defaults). A file from a newer schema is treated as
    /// missing rather than crashing an older build.
    public func load() throws -> State? {
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
        return envelope.state
    }

    /// Overwrite the saved routing state, creating the directory/file if needed.
    public func save(_ state: State) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let envelope = Envelope(schemaVersion: Self.currentSchemaVersion, state: state)
        let data = try encoder.encode(envelope)
        try data.write(to: fileURL, options: .atomic)
    }
}
