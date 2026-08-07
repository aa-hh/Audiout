// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterCore

/// The Settings window (the header gear's destination).
///
/// **Three tabs, not one screen** (screens follow-up, LOCKED by ahh 2026-07-22
/// — "add tabs to kill the long vertical scroll: General / Appearance / Audio;
/// each tab short + scannable"). This supersedes the 2026-07-17 single-screen
/// revision: the stacked column grew past 750pt and became the long scroll the
/// follow-up spec calls out. It is an ORDINARY TITLED STANDALONE WINDOW —
/// traffic lights, movable, position remembered — and it deliberately no longer
/// participates in the shared control-panel bubble, so a tall surface can never
/// dictate another surface's geometry (the other half of the same locked spec).
/// It stays NON-RESIZABLE (`[.titled, .closable, .miniaturizable]`): that's the
/// macOS preferences convention and it makes per-tab sizing unambiguous. It
/// **always opens on General** — no persisted last tab.
///
/// Chrome is stock AppKit (Warm Signal §5.2: "standard material, tabs, radio
/// buttons, dropdowns, typography — no warm canvas, no gold on the chrome"), so
/// `tabStyle = .toolbar` + `NSWindow.toolbarStyle = .preference`: the canonical
/// System-Settings/Safari/Xcode preferences idiom. The tab bar lives in the
/// title-bar area, so it costs ZERO height inside `contentRect` — the content
/// size below is exactly the selected pane's own fitting size.
///
/// **THE SIZING TRAP — probe-confirmed AppKit facts.** An earlier tabbed build
/// shipped a mostly-empty giant window on every tab, every launch; the
/// single-screen rewrite dodged that bug rather than fixing it, so re-adding
/// tabs re-enters exactly the same minefield. Do not weaken any of these:
///
/// 1. **Never build the window from an EMPTY tab controller.**
///    `NSWindow(contentViewController:)` on a tab controller with no tabs yet
///    yields AppKit's 500×500 fallback, and that fallback **never
///    self-corrects** — not when tabs are added afterward, not when a tab is
///    selected. (The original bug: `addTab` ran after `super.init`, and
///    `setFrameAutosaveName` then persisted the bogus frame forever.) All three
///    tabs are therefore added inside `SettingsRootViewController.init`, i.e.
///    before `NSWindow(contentViewController:)` below ever runs.
/// 2. **`NSTabViewController` does NOT resize its window when the selected tab
///    changes.** Probed: three tabs of genuinely different heights all left the
///    window at 460×200. Re-probed on a genuinely on-screen window: forcing the
///    window 460pt tall while Appearance (271pt) is selected leaves it at 460 —
///    nothing native ever shrinks it back. The resize is ours to drive — see
///    ``SettingsRootViewController/tabView(_:didSelect:)``.
/// 3. **`setContentSize` preserves the window's TOP edge**, so the title bar
///    stays anchored and the window grows downward per tab — the correct native
///    preferences feel, and the reason position memory survives a tab switch.
///    Re-probed on screen: top-left stays put across all three tabs.
/// 4. **A subview that still translates its autoresizing mask FREEZES the
///    window's transient construction size into REQUIRED constraints.** This is
///    the one that shipped a visible bug (a 116pt dead gap under "Launch at
///    login"), and it is the nastiest, because the poisoned constraints look
///    inert: `constraintsAffectingLayout(for: .vertical)` on the content view
///    showed only `NSAutoresizingMaskLayoutConstraint`s, and no conflict is ever
///    logged. The background in ``SettingsRootViewController/viewDidLoad()`` was
///    built `NSVisualEffectView(frame: view.bounds)` + `autoresizingMask`, on
///    the reasoning that an autoresized view "contributes nothing to the fitting
///    size". It does: the moment its superview is engine-managed, AppKit
///    synthesises mask constraints that pin its edges with the margins it
///    happened to have **at synthesis time** — and synthesis caught the
///    500×500 of trap 1, which `NSWindow(contentViewController:)` passes through
///    transiently even when the tab controller is correctly non-empty — with
///    the background sized 460×192 (General's own height) inside it. The frozen
///    pair read `V:|-(308)-[background]` + `background.minY == 0`, i.e.
///    `contentHeight == backgroundHeight + 308` (and `contentWidth ==
///    backgroundWidth + 40`) — required, and unsatisfiable below 308pt, so
///    every genuine layout pass snapped the window back to `500 − pane height`
///    no matter how often `setContentSize` was re-applied.
///    (Signature worth recognising: the *shorter* the pane, the *bigger* the
///    bloat. General 192 → 308; a two-row variant 136 → 364; Appearance 271 →
///    308; Audio 502 was tall enough to clear the floor, which is why only
///    General and Appearance ever looked wrong.) The background is therefore
///    pinned with four explicit zero-constant edge constraints — no constants,
///    so nothing transient can ever be baked in. **Any view added to this
///    window's hierarchy must set `translatesAutoresizingMaskIntoConstraints =
///    false`.**
///
///    A previously documented fifth fact — "the tab controller's own
///    `view.fittingSize` reads (0, 0) off any tab but the first" — was a
///    *symptom* of this same poisoning, not an `NSTabViewController` property:
///    with the mask constraints gone it reads truthfully (460×192 / 271 / 502)
///    both offscreen and on screen. ``SettingsRootViewController/fittedContentSize``
///    still measures the selected child rather than `self.view`, for the
///    independent reason given there.
///
/// Position memory uses `MixerWindowController`'s empirically-verified order:
/// `setFrameUsingName` to restore *and* reliably report, `setFrameAutosaveName`
/// only to arm ongoing autosave, `center()` only when there genuinely was no
/// saved frame (`setFrameAutosaveName`'s own `Bool` return does NOT mean "a
/// frame was restored" — it returns `true` for a brand-new name too). The
/// autosaved *size* is harmlessly overridden, since the content size is applied
/// explicitly on every show; top-left is preserved, so the position survives.
///
/// Sibling to `MixerWindowController`: same lazy-create-then-reuse lifecycle at
/// the call site, a no-arg `showWindow()`, and `test_` structure hooks (the
/// window isn't visible to a headless harness).
@MainActor
public final class SettingsWindowController: NSWindowController {

    private let rootVC: SettingsRootViewController
    private let generalVC: GeneralSettingsViewController
    private let appearanceVC: AppearanceSettingsViewController
    private let audioVC: AudioSettingsViewController

    private static let frameAutosaveName: NSWindow.FrameAutosaveName = "SettingsWindow"

    /// Forwarded from the Appearance tab: fired when the user changes the
    /// theme so the app can apply it app-wide (`NSApp.appearance`).
    public var onThemeChanged: ((AppearanceTheme) -> Void)? {
        get { appearanceVC.onThemeChanged }
        set { appearanceVC.onThemeChanged = newValue }
    }

    /// Forwarded from the Appearance tab: fired when the user changes the
    /// Accent dial (W1, spec §1.3) — the pane has already persisted the choice
    /// and applied the live token remap (`Tokens.accentStyle`); this lets the
    /// app nudge open surfaces to repaint.
    public var onAccentChanged: ((AccentStyle) -> Void)? {
        get { appearanceVC.onAccentChanged }
        set { appearanceVC.onAccentChanged = newValue }
    }

    /// Forwarded from the Audio tab: fired when the excluded-apps list
    /// changes so the app can enforce the "excluded ⇒ un-routable" precedence
    /// (prune routes) and refresh the popover.
    public var onExcludedAppsChanged: (() -> Void)? {
        get { audioVC.onChange }
        set { audioVC.onChange = newValue }
    }

    /// Forwarded from the General tab: fired when "Check Permissions…" is
    /// clicked so the app can re-present the first-run onboarding flow.
    public var onRunSetupAgain: (() -> Void)? {
        get { generalVC.onRunSetupAgain }
        set { generalVC.onRunSetupAgain = newValue }
    }

    /// - Parameters:
    ///   - settings: the scalar preference store (theme lives here).
    ///   - loginItem: the launch-at-login seam; defaults to the real
    ///     `SMAppService` impl, injected as a fake in tests.
    ///   - excludedApps: the excluded-apps denylist model (Audio tab);
    ///     defaults to the on-disk store, injected over a temp store in tests.
    ///   - runningAppsProvider: candidate list for the Audio "Add application…"
    ///     picker; defaults to the real running apps, injected as a fixed list in
    ///     tests.
    ///   - latency: the Advanced › Audio buffer model (PLAN-LATENCY-SETTING.md);
    ///     nil (the default) when the backend isn't `LatencyConfigurable`, in
    ///     which case the Audio tab renders no Advanced sub-section at all.
    public init(settings: AppSettings,
                loginItem: LoginItemManaging = SMAppServiceLoginItem(),
                excludedApps: ExcludedAppsController = ExcludedAppsController(),
                runningAppsProvider: @escaping () -> [AppPickerItem] = RunningApps.regularRunningApps,
                latency: LatencySettingModel? = nil,
                wakeRestore: WakeAudioRestoreModel? = nil) {
        generalVC = GeneralSettingsViewController(loginItem: loginItem)
        appearanceVC = AppearanceSettingsViewController(settings: settings)
        audioVC = AudioSettingsViewController(excluded: excludedApps,
                                              runningAppsProvider: runningAppsProvider,
                                              latency: latency,
                                              wakeRestore: wakeRestore)
        // Trap 1: every tab is mounted inside this initializer, so the tab
        // controller handed to `NSWindow(contentViewController:)` below is
        // never empty. An empty one locks the window at a 500×500 fallback that
        // nothing later un-sticks.
        rootVC = SettingsRootViewController(tabs: [
            .init(title: "General", symbolName: "gearshape", viewController: generalVC),
            .init(title: "Appearance", symbolName: "paintpalette", viewController: appearanceVC),
            .init(title: "Audio", symbolName: "speaker.wave.2", viewController: audioVC),
        ])

        let window = NSWindow(contentViewController: rootVC)
        // Non-resizable on purpose: the preferences convention, and it keeps
        // per-tab sizing unambiguous (the window is only ever the size of the
        // pane it's showing).
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.title = "Settings"
        // The tab bar renders as the window's toolbar — the stock preferences
        // look, and no chrome inside `contentRect` to subtract when sizing.
        window.toolbarStyle = .preference
        // Restore FIRST (this is the call that both applies a saved frame and
        // truthfully reports whether one existed), then arm autosave.
        let hasSavedFrame = window.setFrameUsingName(Self.frameAutosaveName)
        window.setFrameAutosaveName(Self.frameAutosaveName)
        // Appear on the active Space (over a fullscreen app) rather than
        // Space-switching to the window's home (window-panel.md M1).
        window.collectionBehavior.formUnion([.moveToActiveSpace, .fullScreenAuxiliary])
        // No forced `NSAppearance` — the app applies the theme override on
        // `NSApp`, and this window inherits it like everything else.

        super.init(window: window)

        // Re-measure trigger 2 & 3: a tab switch, and a pane that grows at
        // runtime (the Audio tab's excluded-apps list). Trigger 1 is
        // `showWindow()`.
        rootVC.onFittedContentSizeChange = { [weak self] size in
            self?.applyContentSize(size)
        }
        applyContentSize(rootVC.fittedContentSize)
        // Only center a genuinely new window — centering after a restore would
        // silently throw the remembered position away.
        if !hasSavedFrame { window.center() }
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Open/focus the window (mirrors `MixerWindowController.showWindow()`).
    /// Always resets to the General tab and re-applies that tab's content size —
    /// see the sizing-trap note on the type: neither a stale autosaved frame nor
    /// AppKit's empty-tab-controller fallback may ever survive a show.
    public func showWindow() {
        // Sizing always runs headlessly too — `testContentSizeIsFittedNotDegenerate`
        // depends on it. Only the actual on-screen presentation is gated: never
        // order a real window on screen under `swift test`/a headless tool
        // (`HeadlessRuntime`) — those hold a real WindowServer connection, so an
        // un-gated order-front here would flash a real, empty window on the
        // developer's actual screen.
        rootVC.selectTab(at: 0)
        // Selecting a tab that is ALREADY selected fires no delegate callback,
        // so the size is applied unconditionally here rather than relying on
        // `onFittedContentSizeChange`.
        applyContentSize(rootVC.fittedContentSize)
        guard !HeadlessRuntime.isActive else { return }
        NSApp?.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Resize the window to `size`, keeping its top-left corner put (trap 3), so
    /// the title bar stays anchored and the window grows downward. A degenerate
    /// measurement is ignored rather than applied — collapsing the window to
    /// nothing is strictly worse than leaving it where it was.
    private func applyContentSize(_ size: NSSize) {
        guard size.width > 0, size.height > 0 else { return }
        window?.setContentSize(size)
    }

    // MARK: Test-support hooks

    public var test_general: GeneralSettingsViewController { generalVC }
    public var test_appearance: AppearanceSettingsViewController { appearanceVC }
    public var test_audio: AudioSettingsViewController { audioVC }

    /// The tab labels, in order, read off the live `NSTabView` items (structural
    /// sanity check that all three tabs mounted).
    public var test_tabLabels: [String] { rootVC.tabViewItems.map(\.label) }

    /// The index of the currently selected tab, read off the live tab view.
    public var test_selectedTabIndex: Int { rootVC.selectedTabViewItemIndex }

    /// Select a tab the way a click on the toolbar does — through **real
    /// `NSTabView` selection**, so `tabView(_:didSelect:)` and the resize it
    /// drives actually run. Deliberately NOT a direct delegate call: a `test_`
    /// hook that invoked a delegate directly once let genuinely broken UI stay
    /// green across 78 tests (`MainOutRowView.selectionChanged`), and this hook
    /// exists precisely to prove the resize path.
    public func test_selectTab(at index: Int) { rootVC.selectTab(at: index) }

    /// The size `showWindow()`/a tab switch applies — the SELECTED tab's fitted
    /// size (``SettingsRootViewController/fittedContentSize`` measures the
    /// selected child, not the tab controller itself). Lets a test assert sizing
    /// is deterministic, non-degenerate, and genuinely per-tab without a live
    /// window.
    public var test_contentFittingSize: NSSize { rootVC.fittedContentSize }

    /// One tab's laid-out pane view, for offscreen snapshot rendering (mirrors
    /// `PopoverController.test_panelView`; the window isn't visible to an agent
    /// shell). Per-tab because with tabs there is no single "the content" view
    /// to render anymore.
    ///
    /// Call this on a FRESH controller, before `showWindow()`/`test_selectTab`:
    /// a pane that has been shown gets stretched to the tab view's bounds, and
    /// headless (no display cycle) nothing ever puts it back, so it would
    /// snapshot wider than it ships. Unshown, it measures at
    /// `SettingsForm.contentWidth`.
    public func test_tabRootView(at index: Int) -> NSView { rootVC.tabRootView(at: index) }

    /// The tab controller's own root view (the window's content view), laid
    /// out. Renders whichever tab is selected — use `test_tabRootView(at:)` to
    /// snapshot a specific one.
    public var test_rootView: NSView {
        rootVC.view.layoutSubtreeIfNeeded()
        return rootVC.view
    }
}

/// The tabbed content: one `NSTabViewItem` per settings pane, in toolbar style.
/// Owns the window-sizing contract described on `SettingsWindowController` —
/// every re-measure funnels through ``fittedContentSize`` and is published via
/// ``onFittedContentSizeChange``, because `NSTabViewController` itself never
/// resizes its window when the selected tab changes (trap 2).
@MainActor
final class SettingsRootViewController: NSTabViewController {

    /// One tab's definition. The SF Symbol is required, not decorative: in
    /// toolbar style an item with no `image` renders as a blank toolbar slot.
    struct Tab {
        let title: String
        let symbolName: String
        let viewController: NSViewController
    }

    /// Fired with the size the window should adopt, whenever that size changes:
    /// on a tab switch, and when the selected pane's own preferred size changes
    /// at runtime. The window controller is the only listener.
    var onFittedContentSizeChange: ((NSSize) -> Void)?

    /// Re-measure trigger 3, held for the controller's lifetime — see the
    /// comment where they're installed for why this is KVO and not the
    /// documented AppKit callback.
    private var preferredSizeObservations: [NSKeyValueObservation] = []

    init(tabs: [Tab]) {
        super.init(nibName: nil, bundle: nil)
        // Set the style BEFORE mounting items: `addTabViewItem` loads the view,
        // and the style decides what that view is built as.
        tabStyle = .toolbar
        for tab in tabs {
            let item = NSTabViewItem(viewController: tab.viewController)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbolName, accessibilityDescription: tab.title)
            addTabViewItem(item)
        }
        // Re-measure trigger 3: a pane that grows at RUNTIME with no tab switch
        // (`AudioSettingsViewController.rebuildList()` republishes
        // `preferredContentSize` when the excluded-apps list changes). Without
        // this the pane would simply clip — nothing else would re-measure.
        //
        // This watches the panes by KVO rather than overriding AppKit's
        // documented `preferredContentSizeDidChange(for:)`, because that
        // callback does NOT fire for tab-item children: probed by republishing a
        // selected pane's `preferredContentSize` as 600pt tall and watching the
        // window stay at 452. KVO on the same property fires reliably.
        preferredSizeObservations = tabs.map { tab in
            tab.viewController.observe(\.preferredContentSize, options: [.new]) { [weak self] child, _ in
                MainActor.assumeIsolated {
                    guard let self, child === self.selectedViewController else { return }
                    self.onFittedContentSizeChange?(self.fittedContentSize)
                }
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        // An explicit opaque, appearance-adaptive background behind the panes —
        // matching the popover's own convention of never relying on the ambient
        // window fill. Confirmed necessary by rendering in dark mode
        // (`settings-snapshot`): without it, child controls draw with
        // dark-adapted (light) text/colors over whatever happens to sit behind,
        // which is illegible. Stock `NSVisualEffectView` material, not a
        // `Tokens` one — Settings chrome stays system (Warm Signal §5.2).
        //
        // TRAP 4 LIVES HERE — the four edge constraints below are load-bearing,
        // do not "simplify" them back to an autoresizing mask. This view used to
        // be built `NSVisualEffectView(frame: view.bounds)` + `autoresizingMask`
        // on the reasoning that an autoresized view stays out of the constraint
        // system. It does not: its superview is engine-managed, so AppKit
        // synthesised mask constraints froze the margins this view happened to
        // have at synthesis time — which was `NSWindow(contentViewController:)`'s
        // transient 500×500 — into a REQUIRED `contentHeight == myHeight + 308`.
        // Nothing logged a conflict; the window simply refused to be shorter
        // than 308pt for the rest of its life, and the surplus showed up as a
        // dead gap inside the General pane. Zero-constant edge pins can't
        // capture a transient, so they're immune. (They also make this view
        // genuinely cover the pane: under the mask it had settled at 420×0
        // inside a 460×308 content view, drawing nothing at all.)
        let background = NSVisualEffectView()
        background.material = .windowBackground
        background.blendingMode = .behindWindow
        background.state = .followsWindowActiveState
        background.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(background, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            background.topAnchor.constraint(equalTo: view.topAnchor),
            background.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// The size the window's content should be for the CURRENTLY SELECTED tab:
    /// `SettingsForm.contentWidth` wide, as tall as that pane needs at that
    /// width.
    ///
    /// Measures the selected CHILD, never `self.view`. `self.view.fittingSize`
    /// was long documented as simply lying; it doesn't — it lied only while
    /// trap 4's frozen mask constraints were poisoning the root view (it then
    /// read the frozen floor, e.g. 40×308 on Appearance). The child measurement
    /// is kept anyway because it is the only one that is **identical offscreen
    /// and on screen**: `settings-snapshot` and the test suite never run a
    /// display cycle, so nothing there ever resolves a root-view measurement the
    /// way a real window does.
    ///
    /// **The width is pinned, not measured**, and the height comes from the
    /// pane's own `preferredContentSize` (every pane publishes
    /// `(SettingsForm.contentWidth, its fitting height)` when it loads, and the
    /// Audio pane re-publishes it as its list grows). Both choices are measured,
    /// not stylistic:
    /// * Width is a fixed design contract (`SettingsForm.contentWidth`, "panes
    ///   don't reflow"). A window that changed width when you clicked a tab
    ///   would read as a bug.
    /// * Measuring off the LIVE view can feed back on itself: when a tab is
    ///   shown the tab view stretches the incoming pane to ITS current bounds,
    ///   and any wrapping label that takes `preferredMaxLayoutWidth` from that
    ///   wider frame stops wrapping, so `view.fittingSize` reports the stretched
    ///   width as if it were required (probed: the Audio pane read 460×221
    ///   fresh, then 561×205 once shown — wider AND shorter).
    ///   `preferredContentSize` is captured at the fixed width instead, so it
    ///   is stable.
    ///
    /// This is a floor, not a ceiling, and deliberately so: a pane whose own
    /// required constraints need more than it published still gets it, because
    /// the pane view fills the tab view with zero margins (Audio publishes 486
    /// and genuinely needs 502 on screen; the window lands on 502, with no gap).
    ///
    /// The `fittingSize` fallback only covers a pane that never published a
    /// preferred size — better a rough measurement than a collapsed window.
    var fittedContentSize: NSSize {
        guard let child = selectedViewController else { return .zero }
        child.view.layoutSubtreeIfNeeded()
        let published = child.preferredContentSize.height
        let height = published > 0 ? published : child.view.fittingSize.height
        return NSSize(width: SettingsForm.contentWidth, height: height)
    }

    /// The selected tab's view controller. `NSTabViewController` exposes only
    /// `selectedTabViewItemIndex`, and that index is `-1` before anything is
    /// selected — hence the bounds check rather than a bare subscript.
    private var selectedViewController: NSViewController? {
        let index = selectedTabViewItemIndex
        guard tabViewItems.indices.contains(index) else { return nil }
        return tabViewItems[index].viewController
    }

    /// One tab's pane view, laid out at the fixed content width (for snapshots).
    /// Loads that tab's view if it hasn't been shown yet, and pins the width for
    /// the same reason ``fittedContentSize`` does — so a snapshot renders the
    /// pane at the width it actually ships at.
    func tabRootView(at index: Int) -> NSView {
        guard let view = tabViewItems[index].viewController?.view else { return self.view }
        view.setFrameSize(NSSize(width: SettingsForm.contentWidth, height: view.frame.height))
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// Select a tab through the real `NSTabView`, exactly as a toolbar click
    /// does — so `tabView(_:didSelect:)` runs and the window resizes.
    func selectTab(at index: Int) {
        tabView.selectTabViewItem(at: index)
    }

    /// Re-measure trigger 2. `NSTabViewController` does NOT resize its window on
    /// a tab switch (trap 2, probed: three panes of 200/480/700pt all left the
    /// window at 460×200) — this is where that resize comes from.
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        // Put the incoming pane back at the fixed content width first. On screen
        // it already is (the window is that wide); headless — tests and
        // `settings-snapshot`, where no display cycle ever resizes the tab view
        // — AppKit hands it the tab view's stale bounds instead, and a pane that
        // re-measures ITSELF from there (the Audio pane does, on every
        // excluded-apps change) would publish a height for the wrong width.
        selectedViewController.map {
            $0.view.setFrameSize(NSSize(width: SettingsForm.contentWidth, height: $0.view.frame.height))
        }
        onFittedContentSizeChange?(fittedContentSize)
    }

    /// Trigger 3's documented AppKit route, kept as a belt-and-braces second
    /// path. It is NOT the one that works — probed, AppKit never calls it for a
    /// tab item's view controller — so the KVO installed in `init` is what
    /// actually carries a runtime growth to the window. Both funnel through the
    /// same publisher, and a duplicate `setContentSize` to the same size is a
    /// no-op, so it is harmless if a future macOS starts calling it.
    override func preferredContentSizeDidChange(for viewController: NSViewController) {
        super.preferredContentSizeDidChange(for: viewController)
        guard viewController === selectedViewController else { return }
        onFittedContentSizeChange?(fittedContentSize)
    }
}
