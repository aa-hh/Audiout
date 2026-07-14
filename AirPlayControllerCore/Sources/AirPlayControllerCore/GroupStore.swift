import Foundation

/// A named, ordered set of devices with remembered per-device volumes — a
/// saved output preset ("Whole house", "Downstairs"). SPEC.md §9: at most one
/// group is *active* at a time; activating a group switches the output set to
/// exactly its members.
public struct Group: Identifiable, Equatable, Codable, Sendable {

    public let id: String
    public var name: String

    /// Ordered — the menu lists members in this order (SPEC.md §9 "Expansion").
    public var memberIDs: [String]

    /// Last-known volume (0–100) per member, keyed by `Device.id`. Captured when
    /// the group is saved / edited so re-activating restores the balance the
    /// group was saved with, not whatever the devices happen to be at.
    public var memberVolumes: [String: Int]

    public init(id: String = UUID().uuidString, name: String, memberIDs: [String], memberVolumes: [String: Int]) {
        self.id = id
        self.name = name
        self.memberIDs = memberIDs
        self.memberVolumes = memberVolumes
    }
}

/// Codable, versioned JSON persistence for saved groups (SPEC.md §9, Q3(a) —
/// versioned JSON in Application Support).
///
/// The directory is injectable so tests never touch the real
/// `~/Library/Application Support` — see `init(directory:)`.
public struct GroupStore: Sendable {

    /// On-disk envelope. `schemaVersion` lets a future format change detect and
    /// migrate (or at least not crash on) files written by an older build.
    struct Envelope: Codable {
        var schemaVersion: Int
        var groups: [Group]
    }

    /// Bump when the on-disk shape changes in a way old readers can't parse.
    /// `load()` refuses anything newer than this rather than guessing.
    static let currentSchemaVersion = 1

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// - Parameter directory: where `groups.json` lives. Defaults to
    ///   `Application Support/AirPlay Controller/` under the user's Library.
    ///   Tests pass a throwaway temp directory instead.
    public init(directory: URL = GroupStore.defaultDirectory) {
        self.fileURL = directory.appendingPathComponent("groups.json")
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.decoder = JSONDecoder()
    }

    /// `~/Library/Application Support/AirPlay Controller/` — created lazily by
    /// `save(_:)`, not here (this is just a pure path computation).
    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("AirPlay Controller", isDirectory: true)
    }

    /// Load saved groups. Missing file → empty (first run, nothing saved yet).
    /// A file from a schema newer than this build understands is treated the
    /// same as missing — old builds must not crash on a future format, and
    /// silently discarding beats a hard launch failure over a preset list.
    ///
    /// - Throws: `DecodingError` / file-system errors for a file that exists,
    ///   claims a version we support (or older), and still fails to parse —
    ///   that's a real corruption we don't want to hide.
    public func load() throws -> [Group] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        let envelope = try decoder.decode(Envelope.self, from: data)
        guard envelope.schemaVersion <= Self.currentSchemaVersion else { return [] }
        return envelope.groups
    }

    /// Overwrite the saved groups with `groups`, creating the directory and
    /// file if needed. Always writes at `currentSchemaVersion`.
    public func save(_ groups: [Group]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let envelope = Envelope(schemaVersion: Self.currentSchemaVersion, groups: groups)
        let data = try encoder.encode(envelope)
        try data.write(to: fileURL, options: .atomic)
    }
}
