// SPDX-License-Identifier: GPL-2.0-or-later

import AppIntents
import AudiouterCore

/// Stop sending audio to every AirPlay speaker; sound returns to the Mac's own
/// output.
///
/// Not silence — the Mac keeps playing — and the saved groups and the user's
/// speaker choices survive, so this is "stop sending to the speakers", not a
/// reset. `GroupController.disconnectAll` owns that definition, including the
/// part an intent could easily get wrong: under a group target, clearing the
/// selection alone would leave the group still streaming.
///
/// Shape copied from ``SetSpeakerVolumeIntent``. A parameterless intent still
/// declares a `parameterSummary` — it is what the action shows in Spotlight.
struct DisconnectAllSpeakersIntent: AppIntent {
    static var title: LocalizedStringResource { "Disconnect All Speakers" }

    static var description: IntentDescription {
        IntentDescription("Stop sending audio to every AirPlay speaker; sound returns to this Mac.")
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Disconnect all speakers")
    }

    func perform() async throws -> some IntentResult {
        let controller = try await AppIntentBridge.waitForGroupController()
        await MainActor.run {
            controller.disconnectAll()
        }
        return .result()
    }
}
