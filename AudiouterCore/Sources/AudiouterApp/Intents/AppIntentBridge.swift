// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterCore

/// Narrow app-level accessor (roadmap 035 T5) that lets an App Intent reach
/// the app's ONE live `GroupController` — never a second instance.
/// `AppDelegate` remains the sole owner: it hands the same controller to the
/// popover and the mixer window so all three stay in lockstep
/// (AudiouterApp/AGENTS.md); this type only knows how to reach what
/// `AppDelegate` already built, via `NSApp.delegate as? AppDelegate`, which
/// is safe because the delegate is retained for the process's entire
/// lifetime (main.swift). Deliberately not a `GroupController.shared` global
/// singleton — that would duplicate ownership instead of merely reaching it.
///
/// `GroupController` is NOT `@MainActor` (GroupController.swift:23), so every
/// entry point below hops to the main actor explicitly — the compiler cannot
/// catch an intent that calls it off-thread, and doing so would race the UI.
///
/// Zero product logic lives here: an intent's `perform()` calls
/// `waitForGroupController()`, gets back the live controller or a clear
/// error, and makes its own single call into `AudiouterCore` from there.
/// Any branching belongs in Core, where the test suite can reach it — this
/// type cannot be covered by it: App Intents run inside a live app process,
/// and Apple requires their tests in a UI testing bundle, which SwiftPM has
/// no equivalent of (dev/notes/app-intents-research-2026-08-07.md §3a).
enum AppIntentBridge {

    /// Thrown when no `GroupController` became reachable within the
    /// readiness wait.
    struct NotReady: LocalizedError {
        let setupPending: Bool

        var errorDescription: String? {
            setupPending
                ? "Audiouter hasn't finished first-run setup on this Mac yet. "
                    + "Open Audiouter and complete setup, then try again."
                : "Audiouter is still starting up. Try again in a few seconds."
        }
    }

    /// How long to wait for `AppDelegate` to finish launching and construct
    /// its `GroupController`. An intent can be the very thing that
    /// COLD-LAUNCHES the app (Shortcuts, Spotlight), so this covers ordinary
    /// process-launch latency — it is not a "something broke" timeout.
    private static let readinessTimeout: TimeInterval = 5
    private static let pollInterval: Duration = .milliseconds(100)

    /// The single live `GroupController`, waiting up to ~5s for a cold
    /// launch to finish constructing it if necessary. Always touches
    /// `AppDelegate`/`GroupController` on the main actor.
    static func waitForGroupController() async throws -> GroupController {
        let deadline = Date().addingTimeInterval(readinessTimeout)
        while true {
            if let controller = await MainActor.run(body: { currentGroupController() }) {
                return controller
            }
            if Date() >= deadline {
                throw NotReady(setupPending: await MainActor.run { firstRunSetupStillPending() })
            }
            try await Task.sleep(for: pollInterval)
        }
    }

    /// `AppDelegate`'s own live reference, re-read on every poll rather than
    /// cached — cheap, and it means there is nothing here that could ever go
    /// stale. Optional-chaining through the delegate's implicitly-unwrapped
    /// `groupController` never force-unwraps, so a still-launching app (the
    /// property not yet assigned) reads as `nil`, never a crash.
    @MainActor
    private static func currentGroupController() -> GroupController? {
        (NSApp.delegate as? AppDelegate)?.groupControllerForAppIntents
    }

    /// Whether an empty-handed wait is explained by this Mac never having
    /// finished first-run setup — reuses the exact decision `AppDelegate`
    /// itself makes at launch (`SetupModel.shouldPresentOnLaunch`) rather
    /// than re-deriving it. On such a machine the native backend's device
    /// discovery never starts until the user finishes onboarding
    /// (AudiouterApp/AGENTS.md), so no amount of waiting here would change
    /// the outcome — the timeout error says so instead of reporting a
    /// generic "still starting up." `SetupModel` is itself `@MainActor`, so
    /// this hops too even though it never touches `GroupController`.
    @MainActor
    private static func firstRunSetupStillPending() -> Bool {
        SetupModel.shouldPresentOnLaunch(settings: AppSettings(), backendKind: .resolved())
    }
}
