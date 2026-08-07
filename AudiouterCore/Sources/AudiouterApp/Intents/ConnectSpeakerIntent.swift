// SPDX-License-Identifier: GPL-2.0-or-later

import AppIntents
import AudiouterCore

/// Start or stop sending audio to one speaker.
///
/// ## Why the volume is optional, and what blank means
/// An automation must never inherit the app-wide connect default — a shortcut
/// that runs at 3 a.m. deciding for itself how loud to be is the hazard this
/// whole parameter exists to close. So there is no "unset" that falls back to
/// a default: a stated volume connects at that volume, and a BLANK volume
/// connects the speaker MUTED. Either way the level is settled before the
/// first audio reaches the speaker, never corrected afterwards.
///
/// Blank-means-muted is also why this is safe to leave optional at all: the
/// empty box cannot be loud. The user unmutes (or sets a volume) as a separate,
/// deliberate step.
///
/// Shape copied from ``SetSpeakerVolumeIntent``, with one deliberate exception
/// noted at `perform()`.
struct ConnectSpeakerIntent: AppIntent {
    static var title: LocalizedStringResource { "Connect Speaker" }

    static var description: IntentDescription {
        IntentDescription("Start or stop sending audio to an AirPlay speaker. Leave the volume blank to connect it muted.")
    }

    @Parameter(title: "Speaker")
    var speaker: SpeakerEntity

    @Parameter(title: "Connected", default: true)
    var connected: Bool

    @Parameter(title: "Volume")
    var volume: Int?

    static var parameterSummary: some ParameterSummary {
        Summary("Set \(\.$speaker) connected to \(\.$connected) at volume \(\.$volume)")
    }

    /// The one branch permitted in this layer. An on/off parameter is two
    /// different `GroupController` calls and there is no third thing it could
    /// do; both destinations are separately tested in `AudiouterCore`, so this
    /// dispatches between tested behaviours rather than containing any of its
    /// own. Anything beyond a straight two-way dispatch belongs in
    /// `AudiouterCore` — this layer has no test coverage at all
    /// (dev/notes/app-intents-research-2026-08-07.md §3a).
    func perform() async throws -> some IntentResult {
        let controller = try await AppIntentBridge.waitForGroupController()
        await MainActor.run {
            if connected {
                _ = controller.connect(speaker.id, at: volume)
            } else {
                _ = controller.setDeviceSelected(speaker.id, false)
            }
        }
        return .result()
    }
}
