// SPDX-License-Identifier: GPL-2.0-or-later

import AppIntents
import AudiouterCore

/// Set the overall output level (0-100) — the Main stage of the
/// `Main × Group × Device` chain, so it moves every speaker at once without
/// disturbing the balance between them.
///
/// Shape copied from ``SetSpeakerVolumeIntent``; see that file for why each
/// part is the way it is.
struct SetMainVolumeIntent: AppIntent {
    static var title: LocalizedStringResource { "Set Main Volume" }

    static var description: IntentDescription {
        IntentDescription("Set Audiouter's overall output level.")
    }

    @Parameter(title: "Volume", default: 50)
    var volume: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Set main volume to \(\.$volume)")
    }

    func perform() async throws -> some IntentResult {
        let controller = try await AppIntentBridge.waitForGroupController()
        await MainActor.run {
            controller.setMainOutMasterVolume(volume)
        }
        return .result()
    }
}
