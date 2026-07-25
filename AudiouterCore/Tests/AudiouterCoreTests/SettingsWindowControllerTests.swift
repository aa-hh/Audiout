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
final class SettingsWindowControllerTests: IsolatedTestCase {

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
        AppSettings(defaults: isolatedDefaults)
    }

    /// An excluded-apps controller over a throwaway temp store (never the real
    /// `~/Library/Application Support`).
    private func makeExcluded() -> ExcludedAppsController {
        ExcludedAppsController(store: ExcludedAppsStore(directory: scratchDir))
    }

    func testTabLabelsInOrder() {
        let controller = SettingsWindowController(
            settings: makeSettings(), loginItem: FakeLoginItem(enabled: false),
            excludedApps: makeExcluded(), runningAppsProvider: { [] })
        XCTAssertEqual(controller.test_tabLabels, ["General", "Appearance", "Audio"])
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

    /// Owner decision (AGENTS.md): the window never persists the last-viewed
    /// tab — every `showWindow()` resets to General. `showWindow()` is safe to
    /// call headlessly: it always runs the tab-select + resize logic, and only
    /// the actual on-screen order-front is gated behind `HeadlessRuntime`.
    func testFreshControllerOpensOnGeneral() {
        let controller = SettingsWindowController(
            settings: makeSettings(), loginItem: FakeLoginItem(enabled: false),
            excludedApps: makeExcluded(), runningAppsProvider: { [] })
        controller.showWindow()
        XCTAssertEqual(controller.test_selectedTabIndex, 0)
        XCTAssertEqual(controller.test_tabLabels[controller.test_selectedTabIndex], "General")
    }

    /// Per-tab sizing-bug regression test: EACH tab's assembled content must
    /// have a real, non-degenerate size (previously the window opened at an
    /// AppKit fallback size for an empty tab controller). Bounded per-tab
    /// rather than one shared range now that content is split across three
    /// panes instead of one long scrolling column — a single pane collapsing
    /// to near-zero, or ballooning back toward the pre-tabs single-screen
    /// height, should each fail this.
    func testEachTabHasNonDegenerateFittedSize() {
        let controller = SettingsWindowController(
            settings: makeSettings(), loginItem: FakeLoginItem(enabled: false),
            excludedApps: makeExcluded(), runningAppsProvider: { [] })
        // Comfortably under the OLD single-screen ceiling (previously ~850pt
        // for all three sections combined) — a per-tab pane should be nowhere
        // near that now that the content is split three ways.
        let oldSingleScreenCeiling: CGFloat = 850
        for index in 0..<3 {
            controller.test_selectTab(at: index)
            let size = controller.test_contentFittingSize
            // `accuracy` absorbs AppKit's sub-point fitting-size rounding
            // (observed 460.5 vs the 460 constraint — a device-pixel
            // autolayout artifact, not a real size discrepancy).
            XCTAssertEqual(size.width, SettingsForm.contentWidth, accuracy: 1,
                          "tab \(index) (\(controller.test_tabLabels[index]))")
            XCTAssertGreaterThan(size.height, 50,
                                "tab \(index) (\(controller.test_tabLabels[index])) collapsed to near-zero")
            XCTAssertLessThan(size.height, oldSingleScreenCeiling,
                              "tab \(index) (\(controller.test_tabLabels[index])) is still oversized")
        }
    }

    /// THE regression guard: `NSTabViewController` does NOT resize its window
    /// when the selected tab changes (probed by T2 — three panes of genuinely
    /// different heights all left the window at the first tab's size). Goes
    /// through **real `NSTabView` selection** via `test_selectTab(at:)` — not a
    /// direct delegate call — because a `test_` hook that bypassed real AppKit
    /// dispatch once let broken UI stay green across 78 tests
    /// (`MainOutRowView.selectionChanged`). Asserts the SHAPE T2's probe found
    /// (three distinct heights, one pinned width, one constant top edge)
    /// rather than hardcoding the probe's exact pixel values, which would be
    /// brittle to any future content change in a pane.
    func testSelectingEachTabResizesTheMeasuredContent() throws {
        let controller = SettingsWindowController(
            settings: makeSettings(), loginItem: FakeLoginItem(enabled: false),
            excludedApps: makeExcluded(), runningAppsProvider: { [] })

        // Measured off the REAL WINDOW, not `test_contentFittingSize` — that
        // hook computes `rootVC.fittedContentSize` fresh on every read, so it
        // would report the right answer even if the push-and-apply path that
        // actually resizes the window (`onFittedContentSizeChange` ->
        // `applyContentSize` -> `window.setContentSize`) never ran. Only the
        // window's own `frame` proves the resize actually happened. Each tab
        // is visited TWICE: the first visit can load the pane's view and
        // publish its initial `preferredContentSize` via the KVO re-measure
        // path (trigger 3) independently of the tab-switch delegate, so only
        // a SECOND, reselect-only visit isolates trigger 2
        // (`tabView(_:didSelect:)`) with no fresh KVO fire to fall back on.
        for index in 0..<3 { controller.test_selectTab(at: index) }

        var heightByTab: [CGFloat] = []
        var widths: Set<CGFloat> = []
        var topEdges: Set<CGFloat> = []
        for index in 0..<3 {
            controller.test_selectTab(at: index)
            let window = try XCTUnwrap(controller.window, "tab \(index)")
            heightByTab.append(window.frame.height)
            widths.insert(window.frame.width.rounded())
            topEdges.insert(window.frame.maxY.rounded())
        }

        // Trap 2, guarded: a broken resize path would leave every tab at
        // whichever tab's height the window happened to already be (one
        // distinct value instead of three).
        XCTAssertEqual(Set(heightByTab.map { $0.rounded() }).count, 3,
                       "expected three distinct per-tab WINDOW heights, got \(heightByTab) — " +
                       "the tab-switch resize (tabView(_:didSelect:)) may not be running")
        // The width contract: panes never reflow sideways.
        XCTAssertEqual(widths.count, 1, "the window's width must stay pinned across every tab: \(widths)")
        // Trap 4: the window grows DOWNWARD — the top edge (frame.maxY) is the
        // anchor, never the bottom.
        XCTAssertEqual(topEdges.count, 1, "the window's top edge must stay anchored across a tab switch: \(topEdges)")

        // NOTE on T2's probe numbers (General 460×192, Appearance 460×271,
        // Audio 460×452, all at frame.maxY 833): used only to sanity-check
        // this test measures the right thing while writing it — this fixture
        // (no latency/wake-restore models, no excluded apps) legitimately
        // measures a SHORTER Audio pane than Appearance, since those optional
        // sections aren't mounted here. Asserting a fixed height ordering
        // would be exactly the brittle-to-content-changes trap this test is
        // supposed to avoid, so only the shape (three distinct heights, one
        // pinned width, one constant top edge) is asserted above.
    }

    /// Re-measure trigger 3: `AudioSettingsViewController.rebuildList()`
    /// republishes `preferredContentSize` at runtime with no tab switch to
    /// trigger a re-measure — driven by KVO on the pane's own
    /// `preferredContentSize`, deliberately NOT AppKit's documented
    /// `preferredContentSizeDidChange(for:)` (probed: AppKit never calls that
    /// for a tab item's view controller). Tests the BEHAVIOUR — the window
    /// follows the pane — not the KVO mechanism itself.
    func testAudioPaneGrowthAtRuntimeGrowsTheWindowWhenSelected() throws {
        let controller = SettingsWindowController(
            settings: makeSettings(), loginItem: FakeLoginItem(enabled: false),
            excludedApps: makeExcluded(), runningAppsProvider: { [] })
        controller.test_selectTab(at: 2) // Audio
        let baselineHeight = controller.test_contentFittingSize.height
        let windowBefore = try XCTUnwrap(controller.window).frame.height

        controller.test_audio.test_addExcluded(bundleID: "us.zoom.xos", displayName: "Zoom")
        let afterOne = controller.test_contentFittingSize.height
        XCTAssertGreaterThan(afterOne, baselineHeight,
                             "adding an excluded-app row must grow the measured pane")
        let windowAfterOne = try XCTUnwrap(controller.window).frame.height
        XCTAssertGreaterThan(windowAfterOne, windowBefore,
                             "the window must follow the pane's runtime growth with no tab switch")

        controller.test_audio.test_addExcluded(bundleID: "com.spotify.client", displayName: "Spotify")
        let afterTwo = controller.test_contentFittingSize.height
        XCTAssertGreaterThan(afterTwo, afterOne, "a second added row must grow it further")
        let windowAfterTwo = try XCTUnwrap(controller.window).frame.height
        XCTAssertGreaterThan(windowAfterTwo, windowAfterOne)
    }

    /// The other half of the same contract: a pane republishing its
    /// `preferredContentSize` while it is NOT the selected tab must be a
    /// no-op for the window — the KVO handler filters on `selectedViewController`
    /// precisely so a background pane's growth doesn't yank the window out from
    /// under whatever tab the user is actually looking at.
    func testAudioPaneGrowthWhileNotSelectedDoesNotResizeTheWindow() throws {
        let controller = SettingsWindowController(
            settings: makeSettings(), loginItem: FakeLoginItem(enabled: false),
            excludedApps: makeExcluded(), runningAppsProvider: { [] })
        controller.test_selectTab(at: 0) // General — NOT Audio
        let generalHeight = controller.test_contentFittingSize.height
        let windowBefore = try XCTUnwrap(controller.window).frame.height

        controller.test_audio.test_addExcluded(bundleID: "us.zoom.xos", displayName: "Zoom")

        XCTAssertEqual(controller.test_contentFittingSize.height, generalHeight, accuracy: 0.5,
                      "Audio republishing its preferredContentSize while unselected must not move " +
                      "the measured (General) content size")
        let windowAfter = try XCTUnwrap(controller.window).frame.height
        XCTAssertEqual(windowAfter, windowBefore, accuracy: 0.5,
                      "the window must not resize for an unselected pane's growth")
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
