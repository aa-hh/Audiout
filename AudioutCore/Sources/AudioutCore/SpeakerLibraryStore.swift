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
public struct SpeakerMetadata: Equatable, Sendable {
    public var name: String
    public var kind: Device.Kind

    public init(name: String, kind: Device.Kind) {
        self.name = name
        self.kind = kind
    }
}

public struct SpeakerLibraryState: Equatable, Sendable {
    public var metadata: [String: SpeakerMetadata]
    public var visibility: [String: SpeakerMixerVisibility]

    public init(metadata: [String: SpeakerMetadata] = [:], visibility: [String: SpeakerMixerVisibility] = [:]) {
        self.metadata = metadata
        self.visibility = visibility.filter { $0.value != .whenAvailable }
    }
}

public struct SpeakerLibraryStore: Sendable {
    /// Raw strings, so one unknown kind or visibility drops that entry instead of failing the whole file;
    /// `load` then keeps a copy of the file, since the next save drops the entry for good.
    private struct Envelope: Codable {
        struct Metadata: Codable {
            var name: String
            var kind: String
        }

        var schemaVersion: Int
        var metadata: [String: Metadata]
        var visibility: [String: String]
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

    public func load() throws -> SpeakerLibraryState? { try loadReportingDrops()?.state }

    /// `droppedEntries` tells the caller to save the cleaned state once; until it does, every load drops the
    /// same entries again and keeps another copy.
    func loadReportingDrops() throws -> (state: SpeakerLibraryState, droppedEntries: Bool)? {
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
        let metadata = envelope.metadata.compactMapValues { entry in
            Device.Kind(rawValue: entry.kind).map { SpeakerMetadata(name: entry.name, kind: $0) }
        }
        let visibility = envelope.visibility.compactMapValues(SpeakerMixerVisibility.init(rawValue:))
        let droppedEntries = metadata.count < envelope.metadata.count || visibility.count < envelope.visibility.count
        if droppedEntries {
            StoreRecovery.preserveCopy(fileURL)
        }
        return (SpeakerLibraryState(metadata: metadata, visibility: visibility), droppedEntries)
    }

    public func save(_ state: SpeakerLibraryState) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let visibility = state.visibility.filter { $0.value != .whenAvailable }
        let data = try encoder.encode(Envelope(schemaVersion: 1,
                                              metadata: state.metadata.mapValues { .init(name: $0.name, kind: $0.kind.rawValue) },
                                              visibility: visibility.mapValues(\.rawValue)))
        try data.write(to: fileURL, options: .atomic)
    }
}
