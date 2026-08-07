// SPDX-License-Identifier: GPL-2.0-or-later
//
// TEMPORARY — roadmap 035 T1's build-gate probe. Its only job is to give
// Shortcuts.app one real action to list, so scripts/make-app.sh's App
// Intents metadata wiring (dev/notes/app-intents-research-2026-08-07.md §2)
// can be proven end-to-end before any real intent is written. Delete this
// file once that live check has passed.

import AppIntents

struct GateProbeIntent: AppIntent {
    static var title: LocalizedStringResource { "Audiouter Gate Probe" }

    static var description: IntentDescription {
        IntentDescription("Does nothing — exists only to prove Shortcuts can list an Audiouter action.")
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Audiouter Gate Probe")
    }

    func perform() async throws -> some IntentResult {
        .result()
    }
}
