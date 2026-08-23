# AudiouterSettingsUI

## Purpose

The Settings content — General / Appearance / Audio as SECTIONS of a
sidebar-plus-pane `SettingsRootViewController` (an `NSSplitViewController`),
hosted as the one-surface shell's Settings screen
(`AudiouterPopoverUI.AppSurfaceController`). There is no standalone Settings
window anymore (retired in U5, PLAN-ONE-SURFACE-032.md); About keeps its own
window as the one deliberate exception. For the app's overall package layout
and where the settings model types (`AppSettings`, `ExcludedAppsController`,
…) live, see [../../AGENTS.md](../../AGENTS.md).

## Rules

- **Sections in a sidebar, not tabs.** The owner's 2026-07-22 "short,
  scannable" intent survives as one section per sidebar row; the sidebar is the
  Groups screen's own arrangement (`SurfaceLayout.sidebarWidth`, same cell
  geometry, same `SidebarWarmSurfaceView` wash, one header row), so the app has
  ONE tab level — the surface's. Starts on General, no persisted section. New
  owner-planned sections (per-output-type settings, delay trim, what's
  connected) become sidebar rows, never a second tab strip.
- **The sizing traps — probe-confirmed AppKit facts. Do not weaken any of
  them.** An earlier build shipped a mostly-empty giant window on every tab,
  every launch:
  1. `NSWindow(contentViewController:)` on an **empty** container yields
     AppKit's 500×500 fallback, and that fallback **never self-corrects** —
     not when children are added later, not when one is selected. (Original
     bug: `addTab` ran after `super.init`, then frame autosave persisted the
     bogus frame forever.) The whole split tree is therefore built inside
     `SettingsRootViewController.init` — never hand a host an empty
     controller.
  2. **Every view in this controller's hierarchy must set
     `translatesAutoresizingMaskIntoConstraints = false`.** An autoresized
     subview of an engine-managed superview is not neutral: AppKit synthesises
     mask constraints from the margins it holds *at synthesis time*, and here
     that caught trap 1's transient 500×500 and froze it into a **required**
     `contentHeight == subviewHeight + 308`. No conflict is ever logged, the
     host just refuses to go under 308pt, and the surplus lands as dead space
     inside the pane. Recognise it by the signature: the **shorter** the pane,
     the **bigger** the bloat.

  **Probed 2026-08-12 (roadmap 050, the Advanced disclosure): a pane's own
  `fittingSize` is safe for GROWTH only, never for SHRINK.**
  `layoutSubtreeIfNeeded` on a windowless top-level view installs a
  priority-501 height constraint pinning the ROOT to its current frame;
  `fittingSize`'s pull-to-zero sits at priority 50 and loses to it every time,
  so a root-based measure can grow but can never shrink back down — probed
  live, the root held `h==424` while its own column stack had already solved
  to `214`. `AudioSettingsViewController` therefore never reads its own
  `view.fittingSize` to republish; `republishFittedHeight()` measures the
  COLUMN stack's `fittingSize` (which carries no such lock) plus the standard
  vertical insets instead, and both `rebuildList()` and the Advanced
  disclosure toggle route through it. Any future pane that can shrink at
  runtime must measure its column, not its root, or it will keep dead space
  forever after the shrink.

  Also probed there: **`NSStackView` does not release an in-place arranged
  child's height** once the child has been shown — not via `isHidden`, not via
  `setVisibilityPriority(.notVisible)`, not via a priority-999 zero-height
  constraint fighting the child's own required internals. All three left the
  stack still demanding the expanded height. The Advanced disclosure therefore
  uses the app's one collapse idiom, the `CardView` clip (AudiouterPopoverUI):
  the content lives inside a layer-clipped wrapper whose REQUIRED height==0
  constraint is the single controlled value, and the content's bottom pin into
  the wrapper is `.defaultHigh` — the clip always wins, no conflict, and the
  stack only ever sees the wrapper. Toggling that one constraint is the whole
  collapse — see `advancedDisclosureToggled()`. The fold is ANIMATED on
  `FoldAnimator.shared` (public in `AudiouterSharedUI`), the app's one fold
  clock. Instant under Reduce Motion and `HeadlessRuntime`, per the popover
  module's fold rules.

  **The surface frame is FIXED, so no pane size is ever published to a host.**
  The pane sits top-aligned inside the pane host's transparent
  overlay-scroller scroll view (the Groups detail panes' idiom); short panes
  leave calm canvas below, tall ones scroll. `SettingsForm.contentWidth` is
  `SurfaceLayout.contentPaneWidth`; panes hold it at `.defaultHigh` and the
  host's required edge pins win, so never make a pane width required again.
- The pane host puts an explicit opaque, appearance-adaptive background behind
  the pane rather than relying on the ambient window fill — confirmed
  necessary by rendering in dark mode via `settings-snapshot`: without it,
  child controls draw with dark-adapted (light) text/colors over whatever
  happens to sit behind the window, which is illegible. Since the 2026-08-07
  canvas unification that background is `WarmPanelView` (`AudiouterSharedUI`)
  — the flat warm `panel` fill every surface screen sits on — and it is the
  host's ROOT view, so nothing inside it can freeze a transient size (trap 2).
  Opaque by construction, so it needs no `ReduceTransparencyFallbackView`
  (About's stock-material background still carries one).
- `BorderedListView` (`AudioSettingsViewController.swift`) draws its rounded
  hairline border around the excluded-apps list in `draw(_:)` — no stock
  control gives a rounded separator-color border, and drawing (vs a stamped
  layer color) lets the color resolve under the current appearance each paint
  with no manual appearance-change bookkeeping.
- Test/snapshot seams: assemble the panes directly (the way
  `AppDelegate.makeSettingsRoot` does), wire callbacks on the pane itself, and
  use the root's public surface — `selectSection(at:)`, `paneView(at:)`,
  `test_hostedPaneView`, `test_scrollDocumentHeight`, `test_sidebarSplitItem`.
  **`selectSection(at:)` drives real sidebar (outline view) selection, not a
  direct pane swap** — that distinction is load-bearing: a hook that called a
  delegate directly once let genuinely broken UI stay green across 78 tests
  (`MainOutRowView.selectionChanged`), and tests go through it precisely to
  prove the selection → swap path runs. `paneView(at:)` exposes one section's
  laid-out view for offscreen snapshot rendering — call it on a FRESH
  controller, before any show or section switch, or the pane snapshots at a
  stretched width. The `settings-snapshot` executable target renders each pane
  to a PNG for visual/dark-mode verification without any window — run it after
  any layout change here; its goldens are not regenerated on macOS 27
  (`NSVisualEffectView` composites opaque there).

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
  Audio-buffer row's hint states the currently-applied value's consequence up
  front rather than carrying a separate subtitle.
- **Section headers and value readouts share one look across panes**
  (roadmap 050, `SettingsForm`): `sectionHeader(_:)` is a semibold caption in
  the secondary color; `readoutWell(_:width:)` draws a monospaced-digit value
  label on `Tokens.Color.well`, in `draw(_:)` like `BorderedListView`, so it
  re-resolves under the current appearance with no bookkeeping. The connect
  volume slider uses `readoutWell` at `width: 56`.

## Map

| Type | What it is |
|---|---|
| `SettingsRootViewController` | Public `NSSplitViewController`: section sidebar + one scrolling pane host; `selectSection(at:)` drives real sidebar selection. |
| `SettingsSidebarViewController` | The section source list — one "Settings" header row over one leaf row per section, in the Groups sidebar's geometry and warm wash. |
| `GeneralSettingsViewController` | Launch at login / "Reconnect last speakers when Audiouter starts" (switch on `AppSettings.reconnectAtLaunch`, live hint) / a hairline + footer button strip (`Setup…`, `About Audiouter…`) in place of the old full-row Setup and About. |
| `AppearanceSettingsViewController` | Theme tiles (warm product previews) + Accent dial. |
| `AudioSettingsViewController` | Excluded-apps list (heading via `SettingsForm.sectionHeader`) + connect volume + wake restore + Advanced (Audio buffer), Advanced a disclosure collapsed by default via the CardView-style clip (required height==0 vs a `.defaultHigh` bottom pin). |
