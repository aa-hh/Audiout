// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
import AppKit
import AudiouterSharedUI
@testable import AudiouterCore
@testable import AudiouterSettingsUI

/// The Settings panes aren't visible to a headless test run, so — exactly like
/// `PopoverControllerTests` — these drive `test_` hooks and public seams to
/// assert structure, the host-sizing contract (`fittedContentSize` +
/// `onFittedContentSizeChange`, which the one-surface host consumes), and that
/// the panes route their actions through the injected seams (login item,
/// `AppSettings`) rather than the real system.
///
/// Sizing assertions read the PUBLISHED size, never a window frame — the
/// surface applies that size to its window, and that application is
/// `AppSurfaceControllerTests`' job. Panes are assembled the way the app
/// assembles them (`AppDelegate.makeSettingsRoot`): built directly, callbacks
/// wired on the pane itself, mounted on a `SettingsRootViewController` with
/// the shipping `.segmentedControlOnTop` style.
@MainActor
@Suite struct SettingsRootViewControllerTests {

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

    /// The panes + root, assembled like the app assembles them. Returned as a
    /// tuple so a test can wire a pane's callback or drive its hooks directly.
    private func makeRoot(
        settings: AppSettings? = nil,
        loginItem: LoginItemManaging? = nil,
        excluded: ExcludedAppsController? = nil
    ) -> (root: SettingsRootViewController,
          general: GeneralSettingsViewController,
          appearance: AppearanceSettingsViewController,
          audio: AudioSettingsViewController) {
        let general = GeneralSettingsViewController(loginItem: loginItem ?? FakeLoginItem(enabled: false))
        let appearance = AppearanceSettingsViewController(settings: settings ?? makeSettings())
        let audio = AudioSettingsViewController(excluded: excluded ?? makeExcluded(),
                                                runningAppsProvider: { [] })
        let root = SettingsRootViewController(tabs: [
            .init(title: "General", symbolName: "gearshape", viewController: general),
            .init(title: "Appearance", symbolName: "paintpalette", viewController: appearance),
            .init(title: "Audio", symbolName: "speaker.wave.2", viewController: audio),
        ], tabStyle: .segmentedControlOnTop)
        return (root, general, appearance, audio)
    }

    /// D2 (live build review 2026-08-07): Settings sits on the ONE surface
    /// canvas — the flat warm `panel` fill (`WarmPanelView`) the Groups
    /// content pane draws — not the retired stock `.windowBackground`
    /// material. Opaque by construction, so no Reduce Transparency cover is
    /// needed (or present) any more.
    @Test func backgroundIsTheUnifiedWarmPanelCanvas() throws {
        let (root, _, _, _) = makeRoot()
        _ = root.view  // force viewDidLoad, which builds the background
        let background = try #require(root.test_background)

        #expect(background is WarmPanelView,
                "Settings draws the same flat panel canvas as the Groups content pane")
        #expect(!(background is NSVisualEffectView),
                "the stock material background is retired inside the surface")
    }

    @Test func tabLabelsInOrder() {
        let (root, _, _, _) = makeRoot()
        #expect(root.tabViewItems.map(\.label) == ["General", "Appearance", "Audio"])
    }

    @Test func runSetupAgainForwardsFromGeneralPane() {
        let (_, general, _, _) = makeRoot()
        var fired = 0
        general.onRunSetupAgain = { fired += 1 }
        general.test_tapRunSetupAgain()
        #expect(fired == 1, "Open Setup… routes from the General pane out to the app")
    }

    /// Owner decision (AGENTS.md): Settings always opens on General. A fresh
    /// root starts there by construction; the surface builds/keeps the root
    /// and owns any reset-on-show policy of its own.
    @Test func freshRootStartsOnGeneral() {
        let (root, _, _, _) = makeRoot()
        #expect(root.selectedTabViewItemIndex == 0)
        #expect(root.tabViewItems[root.selectedTabViewItemIndex].label == "General")
    }

    /// Per-tab sizing-bug regression test: EACH tab's assembled content must
    /// have a real, non-degenerate size (previously the host opened at an
    /// AppKit fallback size for an empty tab controller). Bounded per-tab
    /// rather than one shared range now that content is split across three
    /// panes instead of one long scrolling column — a single pane collapsing
    /// to near-zero, or ballooning back toward the pre-tabs single-screen
    /// height, should each fail this.
    @Test func eachTabHasNonDegenerateFittedSize() {
        let (root, _, _, _) = makeRoot()
        // Comfortably under the OLD single-screen ceiling (previously ~850pt
        // for all three sections combined) — a per-tab pane should be nowhere
        // near that now that the content is split three ways.
        let oldSingleScreenCeiling: CGFloat = 850
        for index in 0..<3 {
            root.selectTab(at: index)
            let size = root.fittedContentSize
            // `accuracy` absorbs AppKit's sub-point fitting-size rounding
            // (observed 460.5 vs the 460 constraint — a device-pixel
            // autolayout artifact, not a real size discrepancy).
            #expect(abs(size.width - SettingsForm.contentWidth) <= 1,
                    Comment(rawValue: "tab \(index) (\(root.tabViewItems[index].label))"))
            #expect(size.height > 50,
                    Comment(rawValue: "tab \(index) (\(root.tabViewItems[index].label)) collapsed to near-zero"))
            #expect(size.height < oldSingleScreenCeiling,
                    Comment(rawValue: "tab \(index) (\(root.tabViewItems[index].label)) is still oversized"))
        }
    }

    /// THE regression guard: `NSTabViewController` does NOT resize its host
    /// when the selected tab changes (probed by T2 — three panes of genuinely
    /// different heights all left the window at the first tab's size). Goes
    /// through **real `NSTabView` selection** via `selectTab(at:)` — not a
    /// direct delegate call — because a `test_` hook that bypassed real AppKit
    /// dispatch once let broken UI stay green across 78 tests
    /// (`MainOutRowView.selectionChanged`).
    ///
    /// Measured off the PUBLISHED sizes, not `fittedContentSize` — that
    /// property computes fresh on every read, so it would report the right
    /// answer even if the push path the surface actually resizes from
    /// (`tabView(_:didSelect:)` → `onFittedContentSizeChange`) never ran.
    /// Only a size delivered through the publisher proves the push happened.
    /// (The standalone window's top-edge-anchor assertion moved with the
    /// window: applying the published size is now the surface's job, covered
    /// by `AppSurfaceControllerTests`.) Each tab is visited TWICE: the first
    /// visit can load the pane's view and publish its initial
    /// `preferredContentSize` via the KVO re-measure path (trigger 3)
    /// independently of the tab-switch delegate, so only a SECOND,
    /// reselect-only visit isolates trigger 2 with no fresh KVO fire to fall
    /// back on.
    @Test func selectingEachTabPublishesThatTabsSize() throws {
        let (root, _, _, _) = makeRoot()
        for index in 0..<3 { root.selectTab(at: index) }

        var heightByTab: [CGFloat] = []
        var widths: Set<CGFloat> = []
        for index in 0..<3 {
            var published: NSSize?
            root.onFittedContentSizeChange = { published = $0 }
            root.selectTab(at: index)
            let size = try #require(published,
                                    "tab \(index): the tab-switch push (tabView(_:didSelect:)) never published a size")
            heightByTab.append(size.height)
            widths.insert(size.width.rounded())
        }
        root.onFittedContentSizeChange = nil

        // Trap 2, guarded: a broken push path would either publish nothing
        // (caught above) or the same stale height for every tab.
        #expect(Set(heightByTab.map { $0.rounded() }).count == 3,
                Comment(rawValue: "expected three distinct per-tab published heights, got \(heightByTab)"))
        // The width contract: panes never reflow sideways.
        #expect(widths.count == 1, Comment(rawValue: "the published width must stay pinned across every tab: \(widths)"))
    }

    /// Trap 4's regression guard: **nothing in the content hierarchy may carry
    /// a translated autoresizing mask.** One such view (the pane background)
    /// froze a transient 500×500 into required constraints, so the host could
    /// never go below `500 −` the pane's own height — General shipped with a
    /// 116pt dead gap under "Launch at login", Appearance with 37pt, and no
    /// constraint conflict was ever logged.
    ///
    /// A headless run can't display anything, and the frozen constraints only
    /// bind on a genuine layout pass — but they poison the ROOT view's fitting
    /// size immediately, and that IS readable headlessly. So the assertion is
    /// the invariant the poisoning breaks: for every tab, the root view must
    /// want exactly what that tab's pane wants plus one CONSTANT chrome strip
    /// (the in-content segmented control — ~30pt, bounded not hardcoded
    /// because AppKit authors it). While poisoned the surplus instead read
    /// `500 − pane height`: large, and different on every tab.
    @Test func rootViewWantsExactlyTheSelectedPaneSizePlusConstantChrome() throws {
        let (root, general, appearance, audio) = makeRoot()
        let panes: [NSViewController] = [general, appearance, audio]

        var surpluses: [CGFloat] = []
        for index in 0..<3 {
            root.selectTab(at: index)
            let pane = panes[index].view
            pane.layoutSubtreeIfNeeded()
            let paneWants = pane.fittingSize
            root.view.layoutSubtreeIfNeeded()
            let rootWants = root.view.fittingSize
            surpluses.append(rootWants.height - paneWants.height)
            #expect(abs(rootWants.width - SettingsForm.contentWidth) <= 0.5,
                    Comment(rawValue: "tab \(index): the root view's wanted width must stay pinned to the pane " +
                    "column, got \(rootWants.width)"))
        }
        let spread = try #require(surpluses.max()).rounded() - (try #require(surpluses.min())).rounded()
        #expect(spread <= 1,
                Comment(rawValue: "the root-over-pane surplus must be one constant chrome strip on every tab, " +
                "got \(surpluses) — a varying surplus means a view is translating its autoresizing mask " +
                "and has frozen a transient host size into required constraints"))
        #expect(surpluses.allSatisfy { $0 >= 0 && $0 <= 60 },
                Comment(rawValue: "surplus \(surpluses) is not a plausible tab-strip height — dead space " +
                "would render inside the pane"))
    }

    /// Re-measure trigger 3: `AudioSettingsViewController.rebuildList()`
    /// republishes `preferredContentSize` at runtime with no tab switch to
    /// trigger a re-measure — driven by KVO on the pane's own
    /// `preferredContentSize`, deliberately NOT AppKit's documented
    /// `preferredContentSizeDidChange(for:)` (probed: AppKit never calls that
    /// for a tab item's view controller). Tests the BEHAVIOUR — the published
    /// size follows the pane — not the KVO mechanism itself.
    @Test func audioPaneGrowthAtRuntimePublishesTheGrownSizeWhenSelected() throws {
        let (root, _, _, audio) = makeRoot()
        root.selectTab(at: 2) // Audio
        let baselineHeight = root.fittedContentSize.height

        var publishedHeights: [CGFloat] = []
        root.onFittedContentSizeChange = { publishedHeights.append($0.height) }

        audio.test_addExcluded(bundleID: "us.zoom.xos", displayName: "Zoom")
        let afterOne = root.fittedContentSize.height
        #expect(afterOne > baselineHeight,
                "adding an excluded-app row must grow the measured pane")
        #expect(publishedHeights.last.map { $0 > baselineHeight } == true,
                Comment(rawValue: "the grown size must reach the host through the publisher with no tab " +
                "switch (KVO trigger 3), got \(publishedHeights)"))

        audio.test_addExcluded(bundleID: "com.spotify.client", displayName: "Spotify")
        let afterTwo = root.fittedContentSize.height
        #expect(afterTwo > afterOne, "a second added row must grow it further")
        #expect(publishedHeights.last.map { $0 > afterOne } == true)
    }

    /// The other half of the same contract: a pane republishing its
    /// `preferredContentSize` while it is NOT the selected tab must be a
    /// no-op for the host — the KVO handler filters on the selected pane
    /// precisely so a background pane's growth doesn't yank the host out from
    /// under whatever tab the user is actually looking at.
    @Test func audioPaneGrowthWhileNotSelectedPublishesNothing() {
        let (root, _, _, audio) = makeRoot()
        root.selectTab(at: 0) // General — NOT Audio
        let generalHeight = root.fittedContentSize.height

        var publishes = 0
        root.onFittedContentSizeChange = { _ in publishes += 1 }

        audio.test_addExcluded(bundleID: "us.zoom.xos", displayName: "Zoom")

        #expect(publishes == 0, "an unselected pane's growth must not push a resize at the host")
        #expect(abs(root.fittedContentSize.height - generalHeight) <= 0.5,
                Comment(rawValue: "Audio republishing its preferredContentSize while unselected must not move " +
                "the measured (General) content size"))
    }

    @Test func audioExcludeAndRemoveDrivesTheModelAndNotifies() {
        let excluded = makeExcluded()
        let audio = AudioSettingsViewController(excluded: excluded, runningAppsProvider: { [] })
        var changes = 0
        audio.onChange = { changes += 1 }

        audio.test_addExcluded(bundleID: "us.zoom.xos", displayName: "Zoom")
        #expect(audio.test_excludedBundleIDs == ["us.zoom.xos"])
        #expect(excluded.isExcluded("us.zoom.xos"))
        #expect(changes == 1)

        // Excluding the same app again is a no-op (no duplicate, no extra notify).
        audio.test_addExcluded(bundleID: "us.zoom.xos", displayName: "Zoom")
        #expect(audio.test_excludedBundleIDs == ["us.zoom.xos"])

        audio.test_removeExcluded(bundleID: "us.zoom.xos")
        #expect(audio.test_excludedBundleIDs == [])
        #expect(!excluded.isExcluded("us.zoom.xos"))
    }

    @Test func launchAtLoginReflectsLiveStateOnSync() {
        let login = FakeLoginItem(enabled: true)
        let general = GeneralSettingsViewController(loginItem: login)
        general.test_syncFromLoginItem()
        #expect(general.test_launchAtLoginIsOn)
    }

    @Test func togglingLaunchAtLoginDrivesTheSeam() {
        let login = FakeLoginItem(enabled: false)
        let general = GeneralSettingsViewController(loginItem: login)
        general.test_toggleLaunchAtLogin(true)
        #expect(login.enabled)
        #expect(login.setCallCount == 1)
        #expect(general.test_launchAtLoginIsOn)
    }

    @Test func failedLaunchAtLoginChangeRevertsTheSwitch() {
        let login = FakeLoginItem(enabled: false)
        login.refuse = true
        let general = GeneralSettingsViewController(loginItem: login)
        general.test_toggleLaunchAtLogin(true)
        // The system refused: state stays off and the switch bounces back.
        #expect(!login.enabled)
        #expect(!general.test_launchAtLoginIsOn)
    }

    @Test func selectingThemePersistsAndNotifies() {
        let settings = makeSettings()
        let appearance = AppearanceSettingsViewController(settings: settings)
        var applied: [AppearanceTheme] = []
        appearance.onThemeChanged = { applied.append($0) }

        appearance.test_selectTheme(.dark)
        #expect(appearance.test_selectedTheme == .dark)
        #expect(settings.theme == .dark)
        #expect(applied == [.dark])
    }

    @Test func appearancePaneInitialisesFromPersistedTheme() {
        let settings = makeSettings()
        settings.theme = .light
        let appearance = AppearanceSettingsViewController(settings: settings)
        // `test_selectedTheme` forces the lazy view load, then reads the selection.
        #expect(appearance.test_selectedTheme == .light)
    }

    // MARK: Theme tile VoiceOver selected-state (A11Y-LABELS)

    /// Before this fix all three tiles sounded identical to VoiceOver — only
    /// the currently-selected theme's tile should report itself as AX-selected.
    @Test func onlyTheSelectedThemeTileReportsAccessibilitySelected() {
        let settings = makeSettings()
        settings.theme = .dark
        let appearance = AppearanceSettingsViewController(settings: settings)

        #expect(appearance.test_isTileAccessibilitySelected(.dark))
        #expect(!appearance.test_isTileAccessibilitySelected(.light))
        #expect(!appearance.test_isTileAccessibilitySelected(.system))
    }

    /// Picking a different tile flips the AX-selected state live, so a
    /// VoiceOver user re-querying the picker hears the new selection.
    @Test func tappingATileMovesAccessibilitySelectedStateToIt() {
        let settings = makeSettings()
        let appearance = AppearanceSettingsViewController(settings: settings)

        appearance.test_selectTheme(.light)
        #expect(appearance.test_isTileAccessibilitySelected(.light))
        #expect(!appearance.test_isTileAccessibilitySelected(.dark))

        appearance.test_selectTheme(.dark)
        #expect(appearance.test_isTileAccessibilitySelected(.dark))
        #expect(!appearance.test_isTileAccessibilitySelected(.light))
    }
}
