// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterCore
import AudiouterSharedUI

// The file name predates the standalone Settings window's retirement
// (PLAN-ONE-SURFACE-032.md, U5); only `SettingsRootViewController` lives here
// now, and the one-surface host (`AudiouterPopoverUI.AppSurfaceController`)
// is its only host. Renaming the file to match is a pending follow-up.

/// The Settings content: one `NSTabViewItem` per settings pane
/// (General / Appearance / Audio — LOCKED by ahh 2026-07-22: "add tabs to
/// kill the long vertical scroll; each tab short + scannable").
///
/// Hosted by the one-surface shell (`AudiouterPopoverUI.AppSurfaceController`)
/// with `tabStyle: .segmentedControlOnTop`, so the panes' tab strip renders IN
/// the content, beneath the surface's own screen switcher. This controller
/// owns the host-sizing contract: every re-measure funnels through
/// ``fittedContentSize`` and is published via ``onFittedContentSizeChange``,
/// because `NSTabViewController` itself never resizes its host when the
/// selected tab changes (trap 2 below).
///
/// **THE SIZING TRAPS — probe-confirmed AppKit facts. They bind on WHOEVER
/// hosts these panes; do not weaken any of them.** An earlier tabbed build
/// shipped a mostly-empty giant window on every tab, every launch; a
/// single-screen rewrite dodged that bug rather than fixing it, so tabs
/// re-entered exactly the same minefield:
///
/// 1. **Never let a host measure or wrap an EMPTY tab controller.**
///    `NSWindow(contentViewController:)` on a tab controller with no tabs yet
///    yields AppKit's 500×500 fallback, and that fallback **never
///    self-corrects** — not when tabs are added afterward, not when a tab is
///    selected. (The original bug: `addTab` ran after `super.init`, and frame
///    autosave then persisted the bogus frame forever.) All tabs are therefore
///    mounted inside `init`, before any host can construct chrome around this
///    controller.
/// 2. **`NSTabViewController` does NOT resize its host when the selected tab
///    changes.** Probed: three tabs of genuinely different heights all left
///    the window at 460×200; re-probed on a genuinely on-screen window —
///    nothing native ever shrinks it back. The resize is ours to drive — see
///    ``tabView(_:didSelect:)``, which republishes ``fittedContentSize``.
/// 3. **`setContentSize` preserves a window's TOP edge**, so a host applying
///    the published size keeps its title/header anchored and grows downward
///    per tab — the correct native preferences feel, and the reason a host's
///    remembered position survives a tab switch. Re-probed on screen:
///    top-left stays put across all three tabs. (The surface's own animated
///    top-anchored resize rides this same fact.)
/// 4. **A subview that still translates its autoresizing mask FREEZES the
///    host's transient construction size into REQUIRED constraints.** This is
///    the one that shipped a visible bug (a 116pt dead gap under "Launch at
///    login"), and it is the nastiest, because the poisoned constraints look
///    inert: `constraintsAffectingLayout(for: .vertical)` on the content view
///    showed only `NSAutoresizingMaskLayoutConstraint`s, and no conflict is
///    ever logged. The background in ``viewDidLoad()`` was once built
///    `NSVisualEffectView(frame: view.bounds)` + `autoresizingMask`, on the
///    reasoning that an autoresized view "contributes nothing to the fitting
///    size". It does: the moment its superview is engine-managed, AppKit
///    synthesises mask constraints that pin its edges with the margins it
///    happened to have **at synthesis time** — and synthesis caught trap 1's
///    transient 500×500, with the background sized 460×192 (General's own
///    height) inside it. The frozen pair read `V:|-(308)-[background]` +
///    `background.minY == 0`, i.e. `contentHeight == backgroundHeight + 308`
///    — required, and unsatisfiable below 308pt, so every genuine layout pass
///    snapped the host back to `500 − pane height` no matter how often the
///    right size was re-applied. (Signature worth recognising: the *shorter*
///    the pane, the *bigger* the bloat.) The background is therefore pinned
///    with four explicit zero-constant edge constraints — no constants, so
///    nothing transient can ever be baked in. **Any view added to this
///    controller's hierarchy must set
///    `translatesAutoresizingMaskIntoConstraints = false`.**
///
///    A previously documented fifth fact — "the tab controller's own
///    `view.fittingSize` reads (0, 0) off any tab but the first" — was a
///    *symptom* of this same poisoning, not an `NSTabViewController`
///    property: with the mask constraints gone it reads truthfully both
///    offscreen and on screen. ``fittedContentSize`` still measures the
///    selected child rather than `self.view`, for the independent reason
///    given there.
@MainActor
public final class SettingsRootViewController: NSTabViewController {

    /// One tab's definition. The SF Symbol is required, not decorative: a tab
    /// item with no `image` renders as a blank slot in image-bearing styles.
    public struct Tab {
        let title: String
        let symbolName: String
        let viewController: NSViewController

        public init(title: String, symbolName: String, viewController: NSViewController) {
            self.title = title
            self.symbolName = symbolName
            self.viewController = viewController
        }
    }

    /// Fired with the size the host should adopt for the content, whenever
    /// that size changes: on a tab switch, and when the selected pane's own
    /// preferred size changes at runtime. One listener at a time — the
    /// surface takes it over; never hand the surface a root whose callback
    /// something else still needs.
    public var onFittedContentSizeChange: ((NSSize) -> Void)?

    /// Re-measure trigger 3, held for the controller's lifetime — see the
    /// comment where they're installed for why this is KVO and not the
    /// documented AppKit callback.
    private var preferredSizeObservations: [NSKeyValueObservation] = []

    /// Height of tab chrome drawn INSIDE the content (0 for `.toolbar`, whose
    /// tab bar lives in a title-bar area this controller doesn't own).
    /// Measured at the end of `init`, never hardcoded: probed 2026-08-07,
    /// `.segmentedControlOnTop` adds exactly 30pt (a 24pt segmented control +
    /// 3pt above and below) on this OS headlessly and identically per tab —
    /// but that is an AppKit-authored layout that could drift, so it is read
    /// off the freshly-built view (`view.fittingSize` minus the first pane's
    /// published height), at the one moment nothing has stretched the panes
    /// (the same "fresh controller" caveat `tabRootView` documents).
    private var inContentTabChromeHeight: CGFloat = 0

    /// No default `tabStyle` on purpose: with a single shipping host, every
    /// construction states the style it renders under (the surface passes
    /// `.segmentedControlOnTop`).
    public init(tabs: [Tab], tabStyle style: NSTabViewController.TabStyle) {
        super.init(nibName: nil, bundle: nil)
        // Set the style BEFORE mounting items: `addTabViewItem` loads the view,
        // and the style decides what that view is built as.
        tabStyle = style
        // Trap 1: every tab is mounted inside this initializer, so the
        // controller a host wraps is never empty.
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

        // Measure the in-content tab chrome (see `inContentTabChromeHeight`)
        // off the freshly-built, never-shown view — the first pane is selected
        // and unstretched, so `view.fittingSize` minus its height is exactly
        // the segmented control's strip. Same published-height-else-fitting
        // fallback `fittedContentSize` uses.
        if style != .toolbar, let first = tabs.first {
            view.layoutSubtreeIfNeeded()
            let published = first.viewController.preferredContentSize.height
            let paneHeight = published > 0 ? published
                                           : first.viewController.view.fittingSize.height
            inContentTabChromeHeight = max(0, view.fittingSize.height - paneHeight)
        }
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        // An explicit opaque, appearance-adaptive background behind the panes —
        // matching the popover's own convention of never relying on the ambient
        // window fill. Confirmed necessary by rendering in dark mode
        // (`settings-snapshot`): without it, child controls draw with
        // dark-adapted (light) text/colors over whatever happens to sit behind,
        // which is illegible. The fill is `WarmPanelView` — the ONE surface
        // canvas (owner decision D2, live build review 2026-08-07: every
        // screen sits on the Groups content pane's flat warm `panel`; this
        // supersedes Warm Signal §5.2's "Settings on stock chrome" for the
        // in-surface world). Opaque by construction, so the old
        // `ReduceTransparencyFallbackView` cover is no longer needed here.
        //
        // TRAP 4 LIVES HERE — the four edge constraints below are load-bearing,
        // do not "simplify" them back to an autoresizing mask. This view used to
        // be built `NSVisualEffectView(frame: view.bounds)` + `autoresizingMask`
        // on the reasoning that an autoresized view stays out of the constraint
        // system. It does not: its superview is engine-managed, so AppKit
        // synthesised mask constraints froze the margins this view happened to
        // have at synthesis time — the host's transient 500×500 (trap 1) — into
        // a REQUIRED `contentHeight == myHeight + 308`. Nothing logged a
        // conflict; the host simply refused to be shorter than 308pt for the
        // rest of its life, and the surplus showed up as a dead gap inside the
        // General pane. Zero-constant edge pins can't capture a transient, so
        // they're immune. (They also make this view genuinely cover the pane:
        // under the mask it had settled at 420×0 inside a 460×308 content
        // view, drawing nothing at all.)
        let background = WarmPanelView()
        background.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(background, positioned: .below, relativeTo: nil)
        test_background = background
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            background.topAnchor.constraint(equalTo: view.topAnchor),
            background.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// The unified-canvas background (nil before `viewDidLoad`), for
    /// structural tests asserting D2's one-background rule.
    public private(set) var test_background: NSView?

    /// The size the host's content should be for the CURRENTLY SELECTED tab:
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
    ///   don't reflow"). A host that changed width when you clicked a tab
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
    /// and genuinely needs 502 on screen; the host lands on 502, with no gap).
    ///
    /// The `fittingSize` fallback only covers a pane that never published a
    /// preferred size — better a rough measurement than a collapsed host.
    ///
    /// In-content tab styles add `inContentTabChromeHeight` on top: the
    /// segmented control lives INSIDE the content (unlike `.toolbar`, whose
    /// tab bar costs zero content height), so the host must size for pane +
    /// chrome or every pane gets squeezed by exactly the chrome's height.
    public var fittedContentSize: NSSize {
        guard let child = selectedViewController else { return .zero }
        child.view.layoutSubtreeIfNeeded()
        let published = child.preferredContentSize.height
        let height = published > 0 ? published : child.view.fittingSize.height
        return NSSize(width: SettingsForm.contentWidth,
                      height: height + inContentTabChromeHeight)
    }

    /// The selected tab's view controller. `NSTabViewController` exposes only
    /// `selectedTabViewItemIndex`, and that index is `-1` before anything is
    /// selected — hence the bounds check rather than a bare subscript.
    private var selectedViewController: NSViewController? {
        let index = selectedTabViewItemIndex
        guard tabViewItems.indices.contains(index) else { return nil }
        return tabViewItems[index].viewController
    }

    /// One tab's pane view, laid out at the fixed content width (for snapshots
    /// — `settings-snapshot` renders it offscreen; the live surface isn't
    /// visible to an agent shell). Loads that tab's view if it hasn't been
    /// shown yet, and pins the width for the same reason ``fittedContentSize``
    /// does — so a snapshot renders the pane at the width it actually ships at.
    ///
    /// Call this on a FRESH controller, before any show or tab selection: a
    /// pane that has been shown gets stretched to the tab view's bounds, and
    /// headless (no display cycle) nothing ever puts it back, so it would
    /// snapshot wider than it ships. Unshown, it measures at
    /// `SettingsForm.contentWidth`.
    public func tabRootView(at index: Int) -> NSView {
        guard let view = tabViewItems[index].viewController?.view else { return self.view }
        view.setFrameSize(NSSize(width: SettingsForm.contentWidth, height: view.frame.height))
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// Select a tab through the real `NSTabView`, exactly as a click on the
    /// segmented control does — so `tabView(_:didSelect:)` runs and the host
    /// resizes. Tests drive this rather than a direct delegate call on
    /// purpose: a `test_` hook that invoked a delegate directly once let
    /// genuinely broken UI stay green across 78 tests
    /// (`MainOutRowView.selectionChanged`).
    public func selectTab(at index: Int) {
        tabView.selectTabViewItem(at: index)
    }

    /// Re-measure trigger 2. `NSTabViewController` does NOT resize its host on
    /// a tab switch (trap 2, probed: three panes of 200/480/700pt all left the
    /// window at 460×200) — this is where that resize comes from.
    public override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        // Put the incoming pane back at the fixed content width first. On screen
        // it already is (the host is that wide); headless — tests and
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
    /// actually carries a runtime growth to the host. Both funnel through the
    /// same publisher, and a duplicate size application is a no-op, so it is
    /// harmless if a future macOS starts calling it.
    public override func preferredContentSizeDidChange(for viewController: NSViewController) {
        super.preferredContentSizeDidChange(for: viewController)
        guard viewController === selectedViewController else { return }
        onFittedContentSizeChange?(fittedContentSize)
    }
}
