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

    /// User-chosen SF Symbol name for this group's icon (persisted as a bare
    /// string — resolved via `NSImage(systemSymbolName:)` at render time).
    /// `nil` means "use the default"; an unrecognized name also falls back to
    /// the default at render time rather than failing to decode.
    public var iconSymbolName: String?

    /// Fallback SF Symbol used when `iconSymbolName` is `nil` or unrecognized.
    public static let defaultIconSymbolName = "rectangle.3.group"

    /// Group-level master volume (0–100), applied on top of Main Out: what
    /// reaches a device is `Main × Group × Device`. Defaults to `100` (no
    /// attenuation) so groups saved before this field existed are unaffected.
    public var masterVolume: Int

    public init(id: String = UUID().uuidString, name: String, memberIDs: [String], memberVolumes: [String: Int], iconSymbolName: String? = nil, masterVolume: Int = 100) {
        self.id = id
        self.name = name
        self.memberIDs = memberIDs
        self.memberVolumes = memberVolumes
        self.iconSymbolName = iconSymbolName
        self.masterVolume = masterVolume.clampedToVolume
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, memberIDs, memberVolumes, iconSymbolName, masterVolume
    }

    /// Hand-written to stay backward-compatible: a `groups.json` written
    /// before `masterVolume` existed has no such key, and must still decode
    /// (rather than throw) so `GroupController`'s `(try? store.load()) ?? []`
    /// doesn't silently erase every saved group. Missing key → `100` (no
    /// attenuation), matching the memberwise initializer's default.
    ///
    /// Clamped on the way in, like every other volume (`Int.clampedToVolume`):
    /// this value multiplies into the `Main × Group × Device` gain chain, so a
    /// hand-edited or corrupt file holding `500` would be a 5× amplification
    /// into the user's speakers rather than a merely odd-looking slider.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        memberIDs = try container.decode([String].self, forKey: .memberIDs)
        memberVolumes = try container.decode([String: Int].self, forKey: .memberVolumes)
        iconSymbolName = try container.decodeIfPresent(String.self, forKey: .iconSymbolName)
        masterVolume = (try container.decodeIfPresent(Int.self, forKey: .masterVolume) ?? 100).clampedToVolume
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
    ///   `Application Support/Audiout/` under the user's Library.
    ///   Tests pass a throwaway temp directory instead.
    public init(directory: URL = GroupStore.defaultDirectory) {
        self.fileURL = directory.appendingPathComponent("groups.json")
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.decoder = JSONDecoder()
    }

    /// `~/Library/Application Support/Audiout/` — created lazily by
    /// `save(_:)`, not here (this is just a pure path computation).
    ///
    /// A side-by-side dev copy (make-app.sh's `BUNDLE_ID` override) gets its
    /// own folder named after its bundle id: defaults and the PTP helper
    /// label were already per-bundle-id, but this directory was hardcoded,
    /// so a dev copy read AND wrote the live app's groups/app-routes/
    /// approvals (live-caught 2026-08-06). The canonical id and bundle-less
    /// callers (swift test, CLI tools) keep the historical folder — no
    /// existing install migrates.
    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        // Only an Audiout-FAMILY override diverges: foreign hosts (the
        // swift-test runner is com.apple.dt.xctest.tool, CLI tools have
        // none) stay on the historical folder too.
        let folder: String
        if let id = Bundle.main.bundleIdentifier,
           id.hasPrefix("com.audiout."), id != "com.audiout.Audiout" {
            folder = id
        } else {
            folder = "Audiout"
        }
        return base.appendingPathComponent(folder, isDirectory: true)
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
