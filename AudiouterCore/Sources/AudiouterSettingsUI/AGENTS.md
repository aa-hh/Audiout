# AudiouterSettingsUI

## Purpose

The Settings content — General / Appearance / Audio panes on a
`SettingsRootViewController`, hosted as the one-surface shell's Settings
screen (`AudiouterPopoverUI.AppSurfaceController`). There is no standalone
Settings window anymore (retired in U5, PLAN-ONE-SURFACE-032.md); About keeps
its own window as the one deliberate exception. For the app's overall package
layout and where the settings model types (`AppSettings`,
`ExcludedAppsController`, …) live, see [../../AGENTS.md](../../AGENTS.md).

## Rules

- **Three tabs, not one screen** (screens follow-up, LOCKED by ahh 2026-07-22:
  "add tabs to kill the long vertical scroll: General / Appearance / Audio;
  each tab short + scannable"). `SettingsRootViewController` is an
  `NSTabViewController` with one `NSTabViewItem` per pane. It always starts
  on General (no persisted last tab).
- **One host: the surface.** The host passes `.segmentedControlOnTop`, so the
  tabs render IN the content, beneath the surface's own screen switcher. An
  in-content style puts the tab chrome INSIDE the content rect, so
  `fittedContentSize` adds a chrome height it MEASURES off the freshly-built
  view at init (probed 2026-08-07: exactly 30pt — a 24pt segmented control +
  3pt above and below — identical per tab, headless and on screen; measured
  rather than hardcoded because the layout is AppKit-authored and can drift).
  The four sizing traps below bind on WHOEVER hosts these panes (plan R5).
  The host's per-tab resize rides `onFittedContentSizeChange`, which has ONE
  listener at a time — never hand the surface a root whose callback something
  else still needs.
- **The sizing trap — probe-confirmed AppKit facts. Do not weaken any of
  them.** An earlier tabbed build shipped a mostly-empty giant window on every
  tab, every launch; the one-screen rewrite dodged that bug rather than fixing
  it, so re-adding tabs re-entered the same minefield:
  1. `NSWindow(contentViewController:)` on an **empty** tab controller yields
     AppKit's 500×500 fallback, and that fallback **never self-corrects** —
     not when tabs are added later, not when a tab is selected. (Original bug:
     `addTab` ran after `super.init`, then frame autosave persisted the bogus
     frame forever.) All three tabs are therefore added inside
     `SettingsRootViewController.init`, before any host wraps the controller.
  2. `NSTabViewController` **does not resize its host when the selected tab
     changes** — probed offscreen and re-probed on a genuinely on-screen
     window. The resize is ours: `tabView(_:didSelect:)` republishes.
  3. `setContentSize` preserves a window's **top** edge, so a host applying
     the published size keeps its chrome anchored and grows downward per tab —
     the native preferences feel; the surface's top-anchored resize rides it.
  4. **Every view in this controller's hierarchy must set
     `translatesAutoresizingMaskIntoConstraints = false`.** An autoresized
     subview of an engine-managed superview is not neutral: AppKit synthesises
     mask constraints from the margins it holds *at synthesis time*, and here
     that caught trap 1's transient 500×500 and froze it into a **required**
     `contentHeight == subviewHeight + 308`. No conflict is ever logged, the
     host just refuses to go under 308pt, and the surplus lands as dead
     space inside the pane. Recognise it by the signature: the **shorter** the
     pane, the **bigger** the bloat (every pane snaps to `500 −` its own
     height). This is why `viewDidLoad`'s background is pinned with four
     zero-constant edge constraints — a zero constant cannot capture a
     transient.

  A fifth "fact" was retired: the tab controller's own `view.fittingSize` does
  **not** inherently lie — it was reading trap 4's frozen floor.

  **A sixth fact, probed 2026-08-12 (roadmap 050, the Advanced disclosure):
  a pane's own `fittingSize` is safe for GROWTH only, never for SHRINK.**
  `layoutSubtreeIfNeeded` on a windowless top-level view installs a
  priority-501 height constraint pinning the ROOT to its current frame;
  `fittingSize`'s pull-to-zero sits at priority 50 and loses to it every
  time, so a root-based measure can grow but can never shrink back down —
  probed live, the root held `h==424` while its own column stack had
  already solved to `214`. `AudioSettingsViewController` therefore never
  reads its own `view.fittingSize` to republish; `republishFittedHeight()`
  measures the COLUMN stack's `fittingSize` (which carries no such lock)
  plus the standard vertical insets instead, and both `rebuildList()` and
  the Advanced disclosure toggle route through it. Any future pane that
  can shrink at runtime must measure its column, not its root, or it will
  keep dead space forever after the shrink.

  Also probed there: **`NSStackView` does not release an in-place
  arranged child's height** once the child has been shown — not via
  `isHidden`, not via `setVisibilityPriority(.notVisible)`, not via a
  priority-999 zero-height constraint. All three left the stack still
  demanding the expanded height. Physical `removeView`/`addView` is the
  one mechanism whose collapse the stack actually honors, so that's what
  the Advanced disclosure uses to detach/reattach its content — see
  `advancedDisclosureToggled()`.

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

  There are exactly **two re-measure trigger points inside this module**, and
  both are needed: the tab-switch delegate `tabView(_:didSelect:)` (trap 2),
  and — for a pane that grows at runtime with no tab switch
  (`AudioSettingsViewController.rebuildList()` when the excluded-apps list
  changes) — **KVO on each pane's `preferredContentSize`**. That last one is
  deliberately NOT AppKit's documented `preferredContentSizeDidChange(for:)`:
  probed, AppKit never calls it for a tab item's view controller (republishing
  a selected pane at 600pt left the window at 452pt), while KVO on the same
  property fires reliably. The override is kept as a harmless second path
  only. The third trigger the retired window ran on every `showWindow()` is
  the HOST's job now: the surface re-reads `fittedContentSize` when the
  Settings screen is shown, so a show can't inherit a stale size.
- `SettingsRootViewController` puts an explicit opaque, appearance-adaptive
  background behind the panes rather than relying on the ambient window fill —
  confirmed necessary by rendering in dark mode via `settings-snapshot`:
  without it, child controls draw with dark-adapted (light) text/colors over
  whatever happens to sit behind the window, which is illegible. Since the
  2026-08-07 canvas unification that background is `WarmPanelView`
  (`AudiouterSharedUI`) — the flat warm `panel` fill every surface screen sits
  on. Opaque by construction, so it needs no `ReduceTransparencyFallbackView`
  (About's stock-material background still carries one). It is pinned with
  four zero-constant edge constraints and **must not** go back to an
  autoresizing mask (trap 4).
- `BorderedListView` (`AudioSettingsViewController.swift`) draws its rounded
  hairline border around the excluded-apps list in `draw(_:)` — no stock
  control gives a rounded separator-color border, and drawing (vs a stamped
  layer color) lets the color resolve under the current appearance each paint
  with no manual appearance-change bookkeeping.
- Test/snapshot seams: assemble the panes directly (the way
  `AppDelegate.makeSettingsRoot` does), wire callbacks on the pane itself, and
  use the root's public surface — `selectTab(at:)`, `fittedContentSize`,
  `onFittedContentSizeChange`, `tabRootView(at:)`. **`selectTab(at:)` drives
  real `NSTabView` selection, not a direct delegate call** — that distinction
  is load-bearing: a hook that called a delegate directly once let genuinely
  broken UI stay green across 78 tests (`MainOutRowView.selectionChanged`),
  and tests go through it precisely to prove the tab-switch publish path runs.
  `tabRootView(at:)` exposes one pane's laid-out view for offscreen snapshot
  rendering — call it on a FRESH controller, before any show or tab
  selection, or the pane snapshots at the stretched width described above.
  The `settings-snapshot` executable target renders each pane to a PNG for
  visual/dark-mode verification without any window — run it after any layout
  change here.

- **Settings CONTROLS stay system; the BACKGROUND is the one warm surface
  canvas.** Warm Signal §5.2's "Settings on stock chrome" is SUPERSEDED for
  the in-surface world (owner decision, live build review 2026-08-07): the
  screen sits on the same flat `panel` fill as the Groups content pane. The
  controls themselves stay stock — still no gold anywhere in these panes. The
  ONLY warm/gold pixels beyond the background are inside the theme tiles'
  previews, and those use ABSOLUTE sRGB mirrors of the spec palette on
  purpose — a tile depicts an appearance; live `Tokens` would adopt the
  current appearance/accent and lie. Don't "fix" them to semantic tokens.
- **The Appearance pane is the accent dial's writer**: a radio click persists
  `AppSettings.accentStyle` AND applies the live remap (`Tokens.accentStyle`)
  itself, then fires `onAccentChanged` as a repaint nudge only. The app layer
  seeds `Tokens.accentStyle` from settings once at launch — don't add a second
  apply path.
- **Consequential controls carry a LIVE hint line** (spec §5.2,
  `SettingsForm.hintLabel`): the owning pane re-writes the hint on every value
  change so it always states the current value's consequence — don't replace
  one with a static subtitle. Kill static explanation paragraphs instead: the
  sync-offset row (roadmap 050) moved its old five-line subtitle into a stock
  `.helpButton`'s `NSPopover`, leaving only the live hint on the pane itself.
- **Section headers and value readouts share one look across panes**
  (roadmap 050, `SettingsForm`): `sectionHeader(_:)` is a semibold caption in
  the secondary color; `readoutWell(_:width:)` draws a monospaced-digit value
  label on `Tokens.Color.well`, in `draw(_:)` like `BorderedListView`, so it
  re-resolves under the current appearance with no bookkeeping. Both connect
  volume and sync offset use `readoutWell` at `width: 56` so their sliders'
  value columns line up.

## Map

| Type | What it is |
|---|---|
| `SettingsRootViewController` | Public `NSTabViewController` holding the panes; measures `fittedContentSize` (pane + in-content chrome) and publishes it via `onFittedContentSizeChange`. |
| `GeneralSettingsViewController` | Launch at login / "Reconnect last speakers when Audiouter starts" (switch on `AppSettings.reconnectAtLaunch`, live hint) / a hairline + footer button strip (`Setup…`, `About Audiouter…`) in place of the old full-row Setup and About. |
| `AppearanceSettingsViewController` | Theme tiles (warm product previews) + Accent dial. |
| `AudioSettingsViewController` | Excluded-apps list (heading via `SettingsForm.sectionHeader`) + connect volume + wake restore + Advanced (Audio buffer, sync offset), Advanced a disclosure collapsed by default that physically adds/removes its content from the column stack. |
