// SPDX-License-Identifier: GPL-2.0-or-later

import AppIntents
import AudiouterCore

/// Set one speaker's own volume (0-100). PATTERN FILE — the five other
/// tier-1 intents (roadmap 035 §4) copy this shape:
///
/// 1. `@Parameter`s only, no stored/computed state.
/// 2. `parameterSummary` covering every required parameter with no default —
///    see the comment on it below, this is not optional polish.
/// 3. `perform()` is exactly: resolve values → hop to the main actor via
///    `AppIntentBridge` → call ONE `GroupController`/`AudiouterCore` method →
///    return. No branching, no error translation beyond what the thrown
///    error already provides — any logic belongs in `AudiouterCore`, the
///    only layer this project's test suite can reach
///    (AppIntentBridge.swift, dev/notes/app-intents-research-2026-08-07.md §3a).
struct SetSpeakerVolumeIntent: AppIntent {
    static var title: LocalizedStringResource { "Set Speaker Volume" }

    static var description: IntentDescription {
        IntentDescription("Set an AirPlay speaker's volume.")
    }

    @Parameter(title: "Speaker")
    var speaker: SpeakerEntity

    @Parameter(title: "Volume", default: 50)
    var volume: Int

    /// MANDATORY, not polish: WWDC25 session 260 states an intent's action
    /// silently drops out of macOS Spotlight Actions — no crash, no log —
    /// unless its `ParameterSummary` covers every required parameter that
    /// has no default. Both `speaker` and `volume` are required here, so
    /// both must appear.
    static var parameterSummary: some ParameterSummary {
        Summary("Set \(\.$speaker) volume to \(\.$volume)")
    }

    /// `GroupController` is NOT `@MainActor` (GroupController.swift:23), but
    /// every entry point into it from an intent still hops explicitly via
    /// `AppIntentBridge` — the bridge's own doc comment explains why: the
    /// compiler cannot catch an off-thread call here, and calling directly
    /// off the main thread would race the UI, which owns the same controller.
    func perform() async throws -> some IntentResult {
        let controller = try await AppIntentBridge.waitForGroupController()
        await MainActor.run {
            controller.setMemberVolume(volume, for: speaker.id)
        }
        return .result()
    }
}
