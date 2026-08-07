// SPDX-License-Identifier: GPL-2.0-or-later

import AppIntents
import AudiouterCore

/// Mute or unmute one speaker, leaving its own volume setting intact so an
/// unmute returns it to the level it had.
///
/// Calls the same `GroupController.setMuted` the popover's mute button does,
/// deliberately: that path is the one that keeps both of the app's mute
/// representations in step (AudiouterCore/AGENTS.md). Shape copied from
/// ``SetSpeakerVolumeIntent``.
struct MuteSpeakerIntent: AppIntent {
    static var title: LocalizedStringResource { "Mute Speaker" }

    static var description: IntentDescription {
        IntentDescription("Mute or unmute an AirPlay speaker.")
    }

    @Parameter(title: "Speaker")
    var speaker: SpeakerEntity

    @Parameter(title: "Muted", default: true)
    var muted: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Set \(\.$speaker) muted to \(\.$muted)")
    }

    func perform() async throws -> some IntentResult {
        let controller = try await AppIntentBridge.waitForGroupController()
        await MainActor.run {
            controller.setMuted(muted, for: speaker.id)
        }
        return .result()
    }
}
