# AudiouterSettingsUI

## Purpose

The Settings window content — General / Appearance / Audio, reachable from
the popover header's gear icon. Sibling to `AudiouterWindowUI` (the Groups
mixer window): same lazy-create-then-reuse controller lifecycle at the
`AppDelegate` call site, a no-arg `showWindow()`, and `test_` structure hooks
because the window isn't visible to a headless harness. For the app's overall
package layout and where the settings model types (`AppSettings`,
`ExcludedAppsController`, …) live, see [../../AGENTS.md](../../AGENTS.md).

## Rules

- **Three tabs, not one screen** (screens follow-up, LOCKED by ahh 2026-07-22:
  "add tabs to kill the long vertical scroll: General / Appearance / Audio;
  each tab short + scannable"). This supersedes the 2026-07-17 one-screen
  revision — the stacked column had grown past 750pt into exactly the scroll
  the spec calls out. `SettingsRootViewController` is now an
  `NSTabViewController` with one `NSTabViewItem` per pane; the panes
  themselves were not restructured. It is an **ordinary titled standalone
  window** (traffic lights, movable, position remembered via
  `setFrameUsingName`/`setFrameAutosaveName`), it **always opens on General**
  (no persisted last tab), and it stays **non-resizable**
  (`[.titled, .closable, .miniaturizable]`) — the preferences convention, and
  it keeps per-tab sizing unambiguous.
- **Chrome stays stock:** `tabStyle = .toolbar` + `NSWindow.toolbarStyle =
  .preference` (the System-Settings/Safari/Xcode idiom, matching Warm Signal
  §5.2's "no warm canvas, no gold on the chrome"). Each tab item needs an SF
  Symbol `image` or it renders as a blank toolbar slot. The tab bar lives in
  the title-bar area, so it costs zero height inside the content rect — the
  window's content size IS the selected pane's fitting size, nothing to
  subtract.
- **The sizing trap — four probe-confirmed AppKit facts. Do not weaken any of
  them.** An earlier tabbed build shipped a mostly-empty giant window on every
  tab, every launch; the one-screen rewrite dodged that bug rather than fixing
  it, so re-adding tabs re-entered the same minefield with two additional
  traps the original note never knew about:
  1. `NSWindow(contentViewController:)` on an **empty** tab controller yields
     AppKit's 500×500 fallback, and that fallback **never self-corrects** —
     not when tabs are added later, not when a tab is selected. (Original bug:
     `addTab` ran after `super.init`, then `setFrameAutosaveName` persisted the
     bogus frame forever.) All three tabs are therefore added inside
     `SettingsRootViewController.init`, before the window is constructed.
  2. `NSTabViewController` **does not resize its window when the selected tab
     changes** — probed, three panes of 200/480/700pt all left the window at
     460×200. The resize is ours: `tabView(_:didSelect:)`.
  3. The tab controller's **own `view.fittingSize` lies** — probed, it reads
     (0, 0) for every tab except the first. This is why `fittedContentSize`
     measures the **selected child**, never `self.view`; measuring itself
     would collapse the window on any other tab.
  4. `setContentSize` preserves the window's **top** edge, so the title bar
     stays anchored and the window grows downward per tab — the native
     preferences feel, and why the remembered position survives a tab switch.

  **Only the HEIGHT is ever measured.** The width is pinned to
  `SettingsForm.contentWidth`, and the height is taken from the pane's own
  `preferredContentSize` (every pane publishes one) rather than its live
  `view.fittingSize`. Measuring the live view feeds back on itself: when a tab
  is shown, the tab view stretches the pane to ITS bounds, the pane's wrapping
  labels re-read `preferredMaxLayoutWidth` from that wider frame and stop
  wrapping, and `fittingSize` then reports the stretched width as if it were
  required — probed, the Audio pane reads 460×221 fresh and 561×205 once shown
  (wider AND shorter). Feeding that back would ratchet the window sideways and
  clip it vertically.

  There are exactly **three re-measure trigger points**, and all three are
  needed: `showWindow()` (a show can't inherit a stale frame), the tab-switch
  delegate `tabView(_:didSelect:)` (trap 2), and — for a pane that grows at
  runtime with no tab switch (`AudioSettingsViewController.rebuildList()` when
  the excluded-apps list changes) — **KVO on each pane's
  `preferredContentSize`**. That last one is deliberately NOT AppKit's
  documented `preferredContentSizeDidChange(for:)`: probed, AppKit never calls
  it for a tab item's view controller (republishing a selected pane at 600pt
  left the window at 452pt), while KVO on the same property fires reliably.
  The override is kept as a harmless second path only.
- `SettingsRootViewController` puts an explicit opaque, appearance-adaptive
  `NSVisualEffectView` (`.windowBackground`, `.behindWindow`) behind the panes
  rather than relying on the ambient window fill — confirmed necessary by
  rendering in dark mode via `settings-snapshot`: without it, child controls
  draw with dark-adapted (light) text/colors over whatever happens to sit
  behind the window, which is illegible. It's autoresized, not constrained, so
  it contributes nothing to the fitting-size measurements above. Stock
  material, not a `Tokens` one — Settings chrome stays system.
- Test/snapshot hooks: `test_general` / `test_appearance` / `test_audio` reach
  each pane's view controller directly; `test_tabLabels` and
  `test_selectedTabIndex` read live `NSTabView` state; `test_contentFittingSize`
  is the SELECTED tab's fitted size, so a test can assert sizing is
  deterministic, non-degenerate, and genuinely per-tab without a live window;
  `test_tabRootView(at:)` exposes one pane's laid-out view for offscreen
  snapshot rendering (per-tab, because with tabs there's no single "the
  content" view) — call it on a FRESH controller, before any show or tab
  selection, or the pane snapshots at the stretched width described above —
  and `test_rootView` exposes the tab controller's own root.
  **`test_selectTab(at:)` drives real `NSTabView` selection, not a direct
  delegate call** — that distinction is load-bearing: a hook that called a
  delegate directly once let genuinely broken UI stay green across 78 tests
  (`MainOutRowView.selectionChanged`), and this hook exists precisely to prove
  the tab-switch resize path runs. The `settings-snapshot` executable target
  renders a pane to a PNG for visual/dark-mode verification without opening a
  real window — run it after any layout change here.

- **Settings chrome stays system** (Warm Signal spec §5.2): no warm canvas and
  no gold anywhere in these panes. The ONLY warm/gold pixels are inside the
  theme tiles' previews, and those use ABSOLUTE sRGB mirrors of the spec
  palette on purpose — a tile depicts an appearance; live `Tokens` would adopt
  the current appearance/accent and lie. Don't "fix" them to semantic tokens.
- **The Appearance pane is the accent dial's writer**: a radio click persists
  `AppSettings.accentStyle` AND applies the live remap (`Tokens.accentStyle`)
  itself, then fires `onAccentChanged` as a repaint nudge only. The app layer
  seeds `Tokens.accentStyle` from settings once at launch — don't add a second
  apply path.
- **Consequential controls carry a LIVE hint line** (spec §5.2,
  `SettingsForm.hintLabel`): the owning pane re-writes the hint on every value
  change so it always states the current value's consequence — don't replace
  one with a static subtitle.

## Map

| Type | What it is |
|---|---|
| `SettingsWindowController` | Owns the standalone titled window + its frame autosave, forwards `onThemeChanged`/`onExcludedAppsChanged`, applies the per-tab content size, exposes the `test_*` hooks. |
| `SettingsRootViewController` | `NSTabViewController` (toolbar style) holding the three panes; measures `fittedContentSize` off the selected child and publishes it via `onFittedContentSizeChange`. |
| `GeneralSettingsViewController` | Launch-at-login. |
| `AppearanceSettingsViewController` | Theme tiles (warm product previews) + Accent dial. |
| `AudioSettingsViewController` | Excluded-apps list + Advanced › Audio buffer (when `LatencyConfigurable`). |
