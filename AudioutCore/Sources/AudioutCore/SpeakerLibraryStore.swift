// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

public enum SpeakerMixerVisibility: String, Codable, CaseIterable, Sendable {
    case whenAvailable
    case always
    case hideWhenNotInUse

    public var label: String {
        switch self {
        case .whenAvailable: return "When available"
        case .always: return "Always"
        case .hideWhenNotInUse: return "Hide when not in use"
        }
    }
}

/// Remembered identity only. Live capabilities and playback stay in Device.
public struct SpeakerMetadata: Equatable, Codable, Sendable {
    public var name: String
    public var kind: Device.Kind

    public init(name: String, kind: Device.Kind) {
        self.name = name
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey { case name, kind }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        let rawKind = try container.decode(String.self, forKey: .kind)
        guard let kind = Device.Kind(rawValue: rawKind) else {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "Unknown speaker kind")
        }
        self.kind = kind
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(kind.rawValue, forKey: .kind)
    }
}

public struct SpeakerLibraryState: Equatable, Codable, Sendable {
    public var metadata: [String: SpeakerMetadata]
    public var visibility: [String: SpeakerMixerVisibility]

    public init(metadata: [String: SpeakerMetadata] = [:], visibility: [String: SpeakerMixerVisibility] = [:]) {
        self.metadata = metadata
        self.visibility = visibility.filter { $0.value != .whenAvailable }
    }
}

public struct SpeakerLibraryStore: Sendable {
    private struct Envelope: Codable {
        var schemaVersion: Int
        var metadata: [String: SpeakerMetadata]
        var visibility: [String: SpeakerMixerVisibility]
    }

    private let fileURL: URL

    public init(directory: URL = GroupStore.defaultDirectory) {
        fileURL = directory.appendingPathComponent("speaker-library.json")
    }

    public var exists: Bool { FileManager.default.fileExists(atPath: fileURL.path) }

    var hasAuthoritativeHistory: Bool {
        if exists { return true }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: fileURL.deletingLastPathComponent().path)) ?? []
        return names.contains { $0.hasPrefix("speaker-library.corrupt-") && $0.hasSuffix(".json") }
    }

    public func load() throws -> SpeakerLibraryState? {
        guard exists else { return nil }
        let data = try Data(contentsOf: fileURL)
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            StoreRecovery.quarantine(fileURL)
            throw error
        }
        guard envelope.schemaVersion <= 1 else {
            StoreRecovery.quarantine(fileURL)
            return nil
        }
        return SpeakerLibraryState(metadata: envelope.metadata, visibility: envelope.visibility)
    }

    public func save(_ state: SpeakerLibraryState) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Envelope(schemaVersion: 1, metadata: state.metadata,
                                              visibility: state.visibility.filter { $0.value != .whenAvailable }))
        try data.write(to: fileURL, options: .atomic)
    }
}
