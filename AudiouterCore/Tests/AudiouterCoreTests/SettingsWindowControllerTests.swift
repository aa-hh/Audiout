// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
import AppKit
@testable import AudiouterCore
@testable import AudiouterSettingsUI

/// The Settings window isn't visible to a headless test run, so — exactly like
/// `PopoverControllerTests`/`MixerWindowControllerTests` — these drive the
/// `test_` hooks to assert structure and that the panes route their actions
/// through the injected seams (login item, `AppSettings`) rather than the real
/// system.
@MainActor
@Suite struct SettingsWindowControllerTests {

    /// A `LoginItemManaging` fake: records the requested state, optionally
    /// refuses (to exercise the revert path) — never touches `SMAppService`.
    private final class FakeLoginItem: LoginItemManaging {
        var enabled: Bool
        var refuse = false
        private(set) var setCallCount = 0
        init(enabled: Bool) { self.enabled = enabled }

        var isEnabled: Bool { enabled }
        func setEnabled(_ newValue: Bool) throws {
            setCallCount += 1
            if refuse { throw NSError(domain: "test", code: 1) }
            enabled = newValue
        }
    }

    private func makeSettings() -> AppSettings {
        let suite = "AudiouterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return AppSettings(defaults: defaults)
    }

    /// An excluded-apps controller over a throwaway temp store (never the real
    /// `~/Library/Application Support`).
    private func makeExcluded() -> ExcludedAppsController {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudiouterTests-\(UUID().uuidString)", isDirectory: true)
        return ExcludedAppsController(store: ExcludedAppsStore(directory: dir))
    }

    @Test func mountsAllThreeSectionsOnOneScreen() {
        let controller = SettingsWindowController(
            settings: makeSettings(), loginItem: FakeLoginItem(enabled: false),
            excludedApps: makeExcluded(), runningAppsProvider: { [] })
        #expect(controller.test_sectionTitles == ["General", "Appearance", "Audio"])
    }

    @Test func runSetupAgainForwardsFromGeneralPane() {
        let controller = SettingsWindowController(
            settings: makeSettings(), loginItem: FakeLoginItem(enabled: false),
            excludedApps: makeExcluded(), runningAppsProvider: { [] })
        var fired = 0
        controller.onRunSetupAgain = { fired += 1 }
        controller.test_general.test_tapRunSetupAgain()
        #expect(fired == 1, "Check Permissions… routes from the General pane out to the app")
    }

    /// The sizing-bug regression test: the assembled single-screen content must
    /// have a real, non-degenerate size (previously the window opened at an
    /// AppKit fallback size for an empty tab controller, leaving a huge empty
    /// gap below the actual content on every tab). A generous but bounded range
    /// catches both "collapsed to nothing" and "still oversized" regressions
    /// without pinning to an exact pixel height that'll drift as sections gain
    /// rows.
    @Test func contentSizeIsFittedNotDegenerate() {
        let controller = SettingsWindowController(
            settings: makeSettings(), loginItem: FakeLoginItem(enabled: false),
            excludedApps: makeExcluded(), runningAppsProvider: { [] })
        let size = controller.test_contentFittingSize
        // `accuracy` absorbs AppKit's sub-point fitting-size rounding (observed
        // 460.5 vs the 460 constraint — a device-pixel autolayout artifact, not
        // a real size discrepancy).
        #expect(abs(size.width - SettingsForm.contentWidth) <= 1)
        // Three real sections + headers + dividers land around ~760-770pt (a long
        // row title like "Volume when connecting a speaker" wraps to two lines by
        // design — SettingsForm titles now wrap rather than truncate). The bug this
        // guards against produced a window close to full screen height (1000+pt)
        // with the same three sections — 850 stays well clear of that while still
        // catching a "collapsed to nothing" regression.
        #expect(size.height > 150)
        #expect(size.height < 850)
    }

    @Test func audioExcludeAndRemoveDrivesTheModelAndNotifies() {
        let excluded = makeExcluded()
        let controller = SettingsWindowController(
            settings: makeSettings(), loginItem: FakeLoginItem(enabled: false),
            excludedApps: excluded, runningAppsProvider: { [] })
        var changes = 0
        controller.onExcludedAppsChanged = { changes += 1 }

        controller.test_audio.test_addExcluded(bundleID: "us.zoom.xos", displayName: "Zoom")
        #expect(controller.test_audio.test_excludedBundleIDs == ["us.zoom.xos"])
        #expect(excluded.isExcluded("us.zoom.xos"))
        #expect(changes == 1)

        // Excluding the same app again is a no-op (no duplicate, no extra notify).
        controller.test_audio.test_addExcluded(bundleID: "us.zoom.xos", displayName: "Zoom")
        #expect(controller.test_audio.test_excludedBundleIDs == ["us.zoom.xos"])

        controller.test_audio.test_removeExcluded(bundleID: "us.zoom.xos")
        #expect(controller.test_audio.test_excludedBundleIDs == [])
        #expect(!excluded.isExcluded("us.zoom.xos"))
    }

    @Test func launchAtLoginReflectsLiveStateOnSync() {
        let login = FakeLoginItem(enabled: true)
        let controller = SettingsWindowController(settings: makeSettings(), loginItem: login)
        controller.test_general.test_syncFromLoginItem()
        #expect(controller.test_general.test_launchAtLoginIsOn)
    }

    @Test func togglingLaunchAtLoginDrivesTheSeam() {
        let login = FakeLoginItem(enabled: false)
        let controller = SettingsWindowController(settings: makeSettings(), loginItem: login)
        controller.test_general.test_toggleLaunchAtLogin(true)
        #expect(login.enabled)
        #expect(login.setCallCount == 1)
        #expect(controller.test_general.test_launchAtLoginIsOn)
    }

    @Test func failedLaunchAtLoginChangeRevertsTheSwitch() {
        let login = FakeLoginItem(enabled: false)
        login.refuse = true
        let controller = SettingsWindowController(settings: makeSettings(), loginItem: login)
        controller.test_general.test_toggleLaunchAtLogin(true)
        // The system refused: state stays off and the switch bounces back.
        #expect(!login.enabled)
        #expect(!controller.test_general.test_launchAtLoginIsOn)
    }

    @Test func selectingThemePersistsAndNotifies() {
        let settings = makeSettings()
        let controller = SettingsWindowController(settings: settings, loginItem: FakeLoginItem(enabled: false))
        var applied: [AppearanceTheme] = []
        controller.onThemeChanged = { applied.append($0) }

        controller.test_appearance.test_selectTheme(.dark)
        #expect(controller.test_appearance.test_selectedTheme == .dark)
        #expect(settings.theme == .dark)
        #expect(applied == [.dark])
    }

    @Test func appearancePaneInitialisesFromPersistedTheme() {
        let settings = makeSettings()
        settings.theme = .light
        let controller = SettingsWindowController(settings: settings, loginItem: FakeLoginItem(enabled: false))
        // Force the pane to load its view, then read the selection.
        #expect(controller.test_appearance.test_selectedTheme == .light)
    }

    // MARK: Theme tile VoiceOver selected-state (A11Y-LABELS)

    /// Before this fix all three tiles sounded identical to VoiceOver — only
    /// the currently-selected theme's tile should report itself as AX-selected.
    @Test func onlyTheSelectedThemeTileReportsAccessibilitySelected() {
        let settings = makeSettings()
        settings.theme = .dark
        let controller = SettingsWindowController(settings: settings, loginItem: FakeLoginItem(enabled: false))
        let appearance = controller.test_appearance

        #expect(appearance.test_isTileAccessibilitySelected(.dark))
        #expect(!appearance.test_isTileAccessibilitySelected(.light))
        #expect(!appearance.test_isTileAccessibilitySelected(.system))
    }

    /// Picking a different tile flips the AX-selected state live, so a
    /// VoiceOver user re-querying the picker hears the new selection.
    @Test func tappingATileMovesAccessibilitySelectedStateToIt() {
        let settings = makeSettings()
        let controller = SettingsWindowController(settings: settings, loginItem: FakeLoginItem(enabled: false))
        let appearance = controller.test_appearance

        appearance.test_selectTheme(.light)
        #expect(appearance.test_isTileAccessibilitySelected(.light))
        #expect(!appearance.test_isTileAccessibilitySelected(.dark))

        appearance.test_selectTheme(.dark)
        #expect(appearance.test_isTileAccessibilitySelected(.dark))
        #expect(!appearance.test_isTileAccessibilitySelected(.light))
    }
}
