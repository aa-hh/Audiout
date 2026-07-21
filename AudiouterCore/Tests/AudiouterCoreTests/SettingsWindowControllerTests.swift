// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
import AppKit
@testable import AudiouterCore
@testable import AudiouterSettingsUI

/// The Settings window isn't visible to a headless test run, so — exactly like
/// `PopoverControllerTests`/`MixerWindowControllerTests` — these drive the
/// `test_` hooks to assert structure and that the panes route their actions
/// through the injected seams (login item, `AppSettings`) rather than the real
/// system.
@MainActor
final class SettingsWindowControllerTests: XCTestCase {

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
        let suite = "AudiouterTests.\(name).\(ObjectIdentifier(self).hashValue)"
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

    func testMountsAllThreeSectionsOnOneScreen() {
        let controller = SettingsWindowController(
            settings: makeSettings(), loginItem: FakeLoginItem(enabled: false),
            excludedApps: makeExcluded(), runningAppsProvider: { [] })
        XCTAssertEqual(controller.test_sectionTitles, ["General", "Appearance", "Audio"])
    }

    func testRunSetupAgainForwardsFromGeneralPane() {
        let controller = SettingsWindowController(
            settings: makeSettings(), loginItem: FakeLoginItem(enabled: false),
            excludedApps: makeExcluded(), runningAppsProvider: { [] })
        var fired = 0
        controller.onRunSetupAgain = { fired += 1 }
        controller.test_general.test_tapRunSetupAgain()
        XCTAssertEqual(fired, 1, "Check Permissions… routes from the General pane out to the app")
    }

    /// The sizing-bug regression test: the assembled single-screen content must
    /// have a real, non-degenerate size (previously the window opened at an
    /// AppKit fallback size for an empty tab controller, leaving a huge empty
    /// gap below the actual content on every tab). A generous but bounded range
    /// catches both "collapsed to nothing" and "still oversized" regressions
    /// without pinning to an exact pixel height that'll drift as sections gain
    /// rows.
    func testContentSizeIsFittedNotDegenerate() {
        let controller = SettingsWindowController(
            settings: makeSettings(), loginItem: FakeLoginItem(enabled: false),
            excludedApps: makeExcluded(), runningAppsProvider: { [] })
        let size = controller.test_contentFittingSize
        // `accuracy` absorbs AppKit's sub-point fitting-size rounding (observed
        // 460.5 vs the 460 constraint — a device-pixel autolayout artifact, not
        // a real size discrepancy).
        XCTAssertEqual(size.width, SettingsForm.contentWidth, accuracy: 1)
        // Three real sections + headers + dividers land around ~550-600pt. The
        // bug this guards against produced a window close to full screen height
        // (1000+pt) with the same three sections — 750 stays well clear of that
        // while still catching a "collapsed to nothing" regression.
        XCTAssertGreaterThan(size.height, 150)
        XCTAssertLessThan(size.height, 750)
    }

    func testAudioExcludeAndRemoveDrivesTheModelAndNotifies() {
        let excluded = makeExcluded()
        let controller = SettingsWindowController(
            settings: makeSettings(), loginItem: FakeLoginItem(enabled: false),
            excludedApps: excluded, runningAppsProvider: { [] })
        var changes = 0
        controller.onExcludedAppsChanged = { changes += 1 }

        controller.test_audio.test_addExcluded(bundleID: "us.zoom.xos", displayName: "Zoom")
        XCTAssertEqual(controller.test_audio.test_excludedBundleIDs, ["us.zoom.xos"])
        XCTAssertTrue(excluded.isExcluded("us.zoom.xos"))
        XCTAssertEqual(changes, 1)

        // Excluding the same app again is a no-op (no duplicate, no extra notify).
        controller.test_audio.test_addExcluded(bundleID: "us.zoom.xos", displayName: "Zoom")
        XCTAssertEqual(controller.test_audio.test_excludedBundleIDs, ["us.zoom.xos"])

        controller.test_audio.test_removeExcluded(bundleID: "us.zoom.xos")
        XCTAssertEqual(controller.test_audio.test_excludedBundleIDs, [])
        XCTAssertFalse(excluded.isExcluded("us.zoom.xos"))
    }

    func testLaunchAtLoginReflectsLiveStateOnSync() {
        let login = FakeLoginItem(enabled: true)
        let controller = SettingsWindowController(settings: makeSettings(), loginItem: login)
        controller.test_general.test_syncFromLoginItem()
        XCTAssertTrue(controller.test_general.test_launchAtLoginIsOn)
    }

    func testTogglingLaunchAtLoginDrivesTheSeam() {
        let login = FakeLoginItem(enabled: false)
        let controller = SettingsWindowController(settings: makeSettings(), loginItem: login)
        controller.test_general.test_toggleLaunchAtLogin(true)
        XCTAssertTrue(login.enabled)
        XCTAssertEqual(login.setCallCount, 1)
        XCTAssertTrue(controller.test_general.test_launchAtLoginIsOn)
    }

    func testFailedLaunchAtLoginChangeRevertsTheSwitch() {
        let login = FakeLoginItem(enabled: false)
        login.refuse = true
        let controller = SettingsWindowController(settings: makeSettings(), loginItem: login)
        controller.test_general.test_toggleLaunchAtLogin(true)
        // The system refused: state stays off and the switch bounces back.
        XCTAssertFalse(login.enabled)
        XCTAssertFalse(controller.test_general.test_launchAtLoginIsOn)
    }

    func testSelectingThemePersistsAndNotifies() {
        let settings = makeSettings()
        let controller = SettingsWindowController(settings: settings, loginItem: FakeLoginItem(enabled: false))
        var applied: [AppearanceTheme] = []
        controller.onThemeChanged = { applied.append($0) }

        controller.test_appearance.test_selectTheme(.dark)
        XCTAssertEqual(controller.test_appearance.test_selectedTheme, .dark)
        XCTAssertEqual(settings.theme, .dark)
        XCTAssertEqual(applied, [.dark])
    }

    func testAppearancePaneInitialisesFromPersistedTheme() {
        let settings = makeSettings()
        settings.theme = .light
        let controller = SettingsWindowController(settings: settings, loginItem: FakeLoginItem(enabled: false))
        // Force the pane to load its view, then read the selection.
        XCTAssertEqual(controller.test_appearance.test_selectedTheme, .light)
    }

    // MARK: Theme tile VoiceOver selected-state (A11Y-LABELS)

    /// Before this fix all three tiles sounded identical to VoiceOver — only
    /// the currently-selected theme's tile should report itself as AX-selected.
    func testOnlyTheSelectedThemeTileReportsAccessibilitySelected() {
        let settings = makeSettings()
        settings.theme = .dark
        let controller = SettingsWindowController(settings: settings, loginItem: FakeLoginItem(enabled: false))
        let appearance = controller.test_appearance

        XCTAssertTrue(appearance.test_isTileAccessibilitySelected(.dark))
        XCTAssertFalse(appearance.test_isTileAccessibilitySelected(.light))
        XCTAssertFalse(appearance.test_isTileAccessibilitySelected(.system))
    }

    /// Picking a different tile flips the AX-selected state live, so a
    /// VoiceOver user re-querying the picker hears the new selection.
    func testTappingATileMovesAccessibilitySelectedStateToIt() {
        let settings = makeSettings()
        let controller = SettingsWindowController(settings: settings, loginItem: FakeLoginItem(enabled: false))
        let appearance = controller.test_appearance

        appearance.test_selectTheme(.light)
        XCTAssertTrue(appearance.test_isTileAccessibilitySelected(.light))
        XCTAssertFalse(appearance.test_isTileAccessibilitySelected(.dark))

        appearance.test_selectTheme(.dark)
        XCTAssertTrue(appearance.test_isTileAccessibilitySelected(.dark))
        XCTAssertFalse(appearance.test_isTileAccessibilitySelected(.light))
    }
}
