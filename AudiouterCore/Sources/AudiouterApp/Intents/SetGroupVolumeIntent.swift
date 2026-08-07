// SPDX-License-Identifier: GPL-2.0-or-later

import AppIntents
import AudiouterCore

/// Set a saved group's own level (0-100) — the middle stage of
/// `Main × Group × Device`.
///
/// Distinct from ``SetMainVolumeIntent``: Main moves everything the Mac is
/// playing, this moves one group relative to it, and each speaker's own level
/// still applies underneath. Setting the level of a group that is not the one
/// currently playing stores it for next time rather than changing what you can
/// hear now.
///
/// Shape copied from ``SetSpeakerVolumeIntent``.
struct SetGroupVolumeIntent: AppIntent {
    static var title: LocalizedStringResource { "Set Group Volume" }

    static var description: IntentDescription {
        IntentDescription("Set a saved group's overall level, keeping the balance between its speakers.")
    }

    @Parameter(title: "Group")
    var group: GroupEntity

    @Parameter(title: "Volume", default: 50)
    var volume: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Set \(\.$group) volume to \(\.$volume)")
    }

    func perform() async throws -> some IntentResult {
        let controller = try await AppIntentBridge.waitForGroupController()
        await MainActor.run {
            controller.setGroupVolume(volume, for: group.id)
        }
        return .result()
    }
}
