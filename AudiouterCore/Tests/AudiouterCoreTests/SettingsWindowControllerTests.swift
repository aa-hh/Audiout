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

    @Test func tabLabelsInOrder() {
        let controller = SettingsWindowController(
            settings: makeSettings(), loginItem: FakeLoginItem(enabled: false),
            excludedApps: makeExcluded(), runningAppsProvider: { [] })
        #expect(controller.test_tabLabels == ["General", "Appearance", "Audio"])
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

    /// Owner decision (AGENTS.md): the window never persists the last-viewed
    /// tab — every `showWindow()` resets to General. `showWindow()` is safe to
    /// call headlessly: it always runs the tab-select + resize logic, and only
    /// the actual on-screen order-front is gated behind `HeadlessRuntime`.
    @Test func freshControllerOpensOnGeneral() {
        let controller = SettingsWindowController(
            settings: makeSettings(), loginItem: FakeLoginItem(enabled: false),
            excludedApps: makeExcluded(), runningAppsProvider: { [] })
        controller.showWindow()
        #expect(controller.test_selectedTabIndex == 0)
        #expect(controller.test_tabLabels[controller.test_selectedTabIndex] == "General")
    }

    /// Per-tab sizing-bug regression test: EACH tab's assembled content must
    /// have a real, non-degenerate size (previously the window opened at an
    /// AppKit fallback size for an empty tab controller). Bounded per-tab
    /// rather than one shared range now that content is split across three
    /// panes instead of one long scrolling column — a single pane collapsing
    /// to near-zero, or ballooning back toward the pre-tabs single-screen
    /// height, should each fail this.
    @Test func eachTabHasNonDegenerateFittedSize() {
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
            #expect(abs(size.width - SettingsForm.contentWidth) <= 1,
                    Comment(rawValue: "tab \(index) (\(controller.test_tabLabels[index]))"))
            #expect(size.height > 50,
                    Comment(rawValue: "tab \(index) (\(controller.test_tabLabels[index])) collapsed to near-zero"))
            #expect(size.height < oldSingleScreenCeiling,
                    Comment(rawValue: "tab \(index) (\(controller.test_tabLabels[index])) is still oversized"))
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
    @Test func selectingEachTabResizesTheMeasuredContent() throws {
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
            let window = try #require(controller.window, "tab \(index)")
            heightByTab.append(window.frame.height)
            widths.insert(window.frame.width.rounded())
            topEdges.insert(window.frame.maxY.rounded())
        }

        // Trap 2, guarded: a broken resize path would leave every tab at
        // whichever tab's height the window happened to already be (one
        // distinct value instead of three).
        #expect(Set(heightByTab.map { $0.rounded() }).count == 3,
                Comment(rawValue: "expected three distinct per-tab WINDOW heights, got \(heightByTab) — " +
                "the tab-switch resize (tabView(_:didSelect:)) may not be running"))
        // The width contract: panes never reflow sideways.
        #expect(widths.count == 1, Comment(rawValue: "the window's width must stay pinned across every tab: \(widths)"))
        // Trap 3: the window grows DOWNWARD — the top edge (frame.maxY) is the
        // anchor, never the bottom.
        #expect(topEdges.count == 1, Comment(rawValue: "the window's top edge must stay anchored across a tab switch: \(topEdges)"))

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

    /// Trap 4's regression guard: **nothing in the window's content hierarchy
    /// may carry a translated autoresizing mask.** One such view (the pane
    /// background) froze `NSWindow(contentViewController:)`'s transient 500×500
    /// into required constraints, so the window could never go below
    /// `500 −` the pane's own height — General shipped with a 116pt dead gap
    /// under "Launch at login", Appearance with 37pt, and no constraint
    /// conflict was ever logged.
    ///
    /// A headless run can't display the window, and the frozen constraints only
    /// bind on a genuine layout pass — but they poison the ROOT view's fitting
    /// size immediately, and that IS readable headlessly. So the assertion is
    /// the invariant the poisoning breaks: for every tab, the tab controller's
    /// own root view must want exactly what that tab's pane wants, no more (it
    /// read 460×308 on General and 40×308 on Appearance while poisoned).
    /// Deliberately relative, not absolute — a pane's real height is free to
    /// change.
    @Test func rootViewWantsExactlyTheSelectedPaneSizeOnEveryTab() throws {
        let controller = SettingsWindowController(
            settings: makeSettings(), loginItem: FakeLoginItem(enabled: false),
            excludedApps: makeExcluded(), runningAppsProvider: { [] })

        for index in 0..<3 {
            controller.test_selectTab(at: index)
            let pane = try #require([controller.test_general as NSViewController,
                                      controller.test_appearance,
                                      controller.test_audio][index].view)
            pane.layoutSubtreeIfNeeded()
            let paneWants = pane.fittingSize
            let rootWants = controller.test_rootView.fittingSize
            #expect(abs(rootWants.height - paneWants.height) <= 0.5,
                    Comment(rawValue: "tab \(index): the root view wants \(rootWants.height)pt but its pane only " +
                    "needs \(paneWants.height)pt — the surplus renders as dead space. A view in " +
                    "the hierarchy is translating its autoresizing mask and has frozen a " +
                    "transient window size into required constraints."))
            #expect(abs(rootWants.width - SettingsForm.contentWidth) <= 0.5,
                    Comment(rawValue: "tab \(index): the root view's wanted width must stay pinned to the pane " +
                    "column, got \(rootWants.width)"))
        }
    }

    /// Re-measure trigger 3: `AudioSettingsViewController.rebuildList()`
    /// republishes `preferredContentSize` at runtime with no tab switch to
    /// trigger a re-measure — driven by KVO on the pane's own
    /// `preferredContentSize`, deliberately NOT AppKit's documented
    /// `preferredContentSizeDidChange(for:)` (probed: AppKit never calls that
    /// for a tab item's view controller). Tests the BEHAVIOUR — the window
    /// follows the pane — not the KVO mechanism itself.
    @Test func audioPaneGrowthAtRuntimeGrowsTheWindowWhenSelected() throws {
        let controller = SettingsWindowController(
            settings: makeSettings(), loginItem: FakeLoginItem(enabled: false),
            excludedApps: makeExcluded(), runningAppsProvider: { [] })
        controller.test_selectTab(at: 2) // Audio
        let baselineHeight = controller.test_contentFittingSize.height
        let windowBefore = try #require(controller.window).frame.height

        controller.test_audio.test_addExcluded(bundleID: "us.zoom.xos", displayName: "Zoom")
        let afterOne = controller.test_contentFittingSize.height
        #expect(afterOne > baselineHeight,
                "adding an excluded-app row must grow the measured pane")
        let windowAfterOne = try #require(controller.window).frame.height
        #expect(windowAfterOne > windowBefore,
                "the window must follow the pane's runtime growth with no tab switch")

        controller.test_audio.test_addExcluded(bundleID: "com.spotify.client", displayName: "Spotify")
        let afterTwo = controller.test_contentFittingSize.height
        #expect(afterTwo > afterOne, "a second added row must grow it further")
        let windowAfterTwo = try #require(controller.window).frame.height
        #expect(windowAfterTwo > windowAfterOne)
    }

    /// The other half of the same contract: a pane republishing its
    /// `preferredContentSize` while it is NOT the selected tab must be a
    /// no-op for the window — the KVO handler filters on `selectedViewController`
    /// precisely so a background pane's growth doesn't yank the window out from
    /// under whatever tab the user is actually looking at.
    @Test func audioPaneGrowthWhileNotSelectedDoesNotResizeTheWindow() throws {
        let controller = SettingsWindowController(
            settings: makeSettings(), loginItem: FakeLoginItem(enabled: false),
            excludedApps: makeExcluded(), runningAppsProvider: { [] })
        controller.test_selectTab(at: 0) // General — NOT Audio
        let generalHeight = controller.test_contentFittingSize.height
        let windowBefore = try #require(controller.window).frame.height

        controller.test_audio.test_addExcluded(bundleID: "us.zoom.xos", displayName: "Zoom")

        #expect(abs(controller.test_contentFittingSize.height - generalHeight) <= 0.5,
                Comment(rawValue: "Audio republishing its preferredContentSize while unselected must not move " +
                "the measured (General) content size"))
        let windowAfter = try #require(controller.window).frame.height
        #expect(abs(windowAfter - windowBefore) <= 0.5,
                "the window must not resize for an unselected pane's growth")
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
