// SPDX-License-Identifier: GPL-2.0-or-later

import AppIntents
import AudiouterCore

/// Switch playback to a saved group.
///
/// The optional volume sets MAIN — the overall level — and each member's own
/// remembered level still applies underneath it (`Main × Group × Device`), so
/// activating a group from a shortcut keeps whatever balance the user tuned
/// inside it. Left blank, Main is not touched at all.
///
/// `GroupController.setMainOut` carries the level rather than the intent
/// setting it separately, because Main has to be pushed BEFORE the routing
/// apply — that ordering is documented and tested in `AudiouterCore`, and
/// retyping it here would put it somewhere no test can reach.
///
/// Shape copied from ``SetSpeakerVolumeIntent``.
struct ActivateGroupIntent: AppIntent {
    static var title: LocalizedStringResource { "Activate Group" }

    static var description: IntentDescription {
        IntentDescription("Switch playback to a saved group of speakers.")
    }

    @Parameter(title: "Group")
    var group: GroupEntity

    @Parameter(title: "Main Volume")
    var mainVolume: Int?

    static var parameterSummary: some ParameterSummary {
        Summary("Activate \(\.$group) at main volume \(\.$mainVolume)")
    }

    func perform() async throws -> some IntentResult {
        let controller = try await AppIntentBridge.waitForGroupController()
        await MainActor.run {
            controller.setMainOut(.group(id: group.id), mainVolume: mainVolume)
        }
        return .result()
    }
}
