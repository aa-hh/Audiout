// SPDX-License-Identifier: GPL-2.0-or-later

import AppIntents
import AudiouterCore

/// One AirPlay speaker, as Shortcuts sees it. Keyed on `Device.id`
/// (Device.swift:39) — the stable Bonjour identity — never `Device.name`
/// (Device.swift:41): a name-keyed shortcut would silently break the moment
/// the user renames a speaker, since the saved shortcut only carries
/// whatever `id` this entity returns.
struct SpeakerEntity: AppEntity {
    let id: String
    let name: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Speaker" }
    static var defaultQuery = SpeakerEntityQuery()

    /// `LocalizedStringResource(stringLiteral:)`, NOT the `"\(name)"`
    /// interpolation the AppIntents samples use. The interpolating form builds
    /// a format-string-plus-arguments resource, and a speaker's name is DATA,
    /// not a translatable template — crossing to the Shortcuts process it came
    /// back cut short ("Alec's MacBook Pro" listed as "Alec's"). The literal
    /// form carries the string whole. Never interpolate a device-supplied name
    /// into a `LocalizedStringResource` here.
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: LocalizedStringResource(stringLiteral: name))
    }
}

/// Backs the Shortcuts picker with the user's real, currently-known speakers
/// instead of asking them to type a name.
///
/// Excludes the local Mac (`Device.isLocalDevice`, Device.swift:57) on
/// purpose: it is passthrough, not an AirPlay receiver (SPEC.md §9b) —
/// listing it as a "speaker" would let an action like Mute Speaker or Set
/// Speaker Volume silently mute or change the volume of the user's own Mac
/// under a name that reads as "one of my AirPlay speakers." A future intent
/// that deliberately wants to target the Mac's own output should take that
/// as an explicit, separately-labeled option — not fall out of this query.
struct SpeakerEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [SpeakerEntity] {
        let devices = try await AppIntentBridge.waitForGroupController().devices
        return devices
            .filter { identifiers.contains($0.id) && !$0.isLocalDevice }
            .map { SpeakerEntity(id: $0.id, name: $0.name) }
    }

    func suggestedEntities() async throws -> [SpeakerEntity] {
        let devices = try await AppIntentBridge.waitForGroupController().devices
        return devices
            .filter { !$0.isLocalDevice }
            .map { SpeakerEntity(id: $0.id, name: $0.name) }
    }
}
