// SPDX-License-Identifier: GPL-2.0-or-later

import AppIntents
import AudiouterCore

/// The Shortcuts/Spotlight-facing entity for a saved ``Group`` — lets an
/// intent parameter show the user's real saved groups in a picker instead of
/// asking them to type a name by hand. Zero logic (AudiouterApp/AGENTS.md):
/// `id`/`title` mirror `Group.id`/`Group.name` directly (GroupStore.swift:9-10).
struct GroupEntity: AppEntity {

    let id: String
    let name: String

    /// Literal, not interpolated — same reason as ``SpeakerEntity``: a
    /// user-chosen group name is data, and the interpolating form came back
    /// truncated across the process boundary into Shortcuts.
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: LocalizedStringResource(stringLiteral: name))
    }

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Group"
    static let defaultQuery = GroupEntityQuery()
}

/// Reads the live saved groups through ``AppIntentBridge`` — never a second
/// `GroupController` instance.
struct GroupEntityQuery: EntityQuery {

    func entities(for identifiers: [String]) async throws -> [GroupEntity] {
        let controller = try await AppIntentBridge.waitForGroupController()
        let groups = await MainActor.run { controller.groups }
        return groups
            .filter { identifiers.contains($0.id) }
            .map { GroupEntity(id: $0.id, name: $0.name) }
    }

    func suggestedEntities() async throws -> [GroupEntity] {
        let controller = try await AppIntentBridge.waitForGroupController()
        let groups = await MainActor.run { controller.groups }
        return groups.map { GroupEntity(id: $0.id, name: $0.name) }
    }
}
