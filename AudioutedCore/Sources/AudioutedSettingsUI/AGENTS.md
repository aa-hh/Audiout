# AudioutedSettingsUI

## Purpose

The Settings window content — General / Appearance / Audio, reachable from
the popover header's gear icon. Sibling to `AudioutedWindowUI` (the Groups
mixer window): same lazy-create-then-reuse controller lifecycle at the
`AppDelegate` call site, a no-arg `showWindow()`, and `test_` structure hooks
because the window isn't visible to a headless harness. For the app's overall
package layout and where the settings model types (`AppSettings`,
`ExcludedAppsController`, …) live, see [../../AGENTS.md](../../AGENTS.md).

## Rules

- **One screen, not tabs** (design revision 2026-07-17 — ahh: "this feels
  like it should maybe just be one screen at the moment"). With three
  single-control sections, a tab bar was pure navigation overhead — General /
  Appearance / Audio render as bold-labeled sections stacked in one
  scrolling-free column (`SettingsRootViewController`), divided by hairlines,
  in a single fixed-size window. Each section keeps its own `NSViewController`
  so re-splitting into tabs later only touches `SettingsRootViewController`,
  not the sections themselves.
- **The sizing-bug history this replaced:** the previous `NSTabViewController`
  build called `NSWindow(contentViewController: tabController)` *before* any
  tabs were added, so the window's initial size was AppKit's fallback for an
  empty, content-less tab controller — much larger than any real pane.
  `setFrameAutosaveName` then persisted that oversized frame, and nothing ever
  forced a correct resize afterward. **Do not remove or weaken the fix**:
  `showWindow()` explicitly re-measures the assembled content
  (`rootVC.view.layoutSubtreeIfNeeded()` then `window?.setContentSize(rootVC.view.fittingSize)`)
  immediately before every show, so no stale saved frame (or AppKit fallback)
  can ever stick. This mirrors the popover's own explicit
  `panelContentDidChangeHeight` re-measure before every show — same shape,
  same reason.
- `SettingsRootViewController`'s content view is an explicit opaque,
  appearance-adaptive `NSVisualEffectView` (`.windowBackground`,
  `.behindWindow`), not left to the ambient window fill — confirmed necessary
  by rendering in dark mode via `settings-snapshot`: without it, child
  controls draw with dark-adapted (light) text/colors over whatever happens to
  sit behind the window, which is illegible.
- Test/snapshot hooks: `test_general` / `test_appearance` / `test_audio`
  reach each section's view controller directly; `test_sectionTitles` is a
  structural sanity check that all three sections mounted (the single-screen
  replacement for the old `test_tabLabels`); `test_contentFittingSize` lets a
  test assert sizing is deterministic and non-degenerate without a live
  window; `test_rootView` exposes the laid-out content view for offscreen
  snapshot rendering. The `settings-snapshot` executable target renders this
  content view to a PNG for visual/dark-mode verification without opening a
  real window — run it after any layout change here.
- **`settingsContentViewController` is now also hostable in the shared
  control-panel shell** (`AudioutedSharedUI.ControlPanelWindowController`,
  behind `AIRPLAY_CONTROL_PANEL=1`): it exposes the same `rootVC` this window
  uses as its `contentViewController`, so the shell can mount the identical
  assembled content without this type constructing a second copy of the
  sections. Named `settingsContentViewController`, not `contentViewController`
  — `NSWindowController` already declares a mutable, optional
  `contentViewController` property, and a same-named override with a
  non-optional return type fails to compile (covariance mismatch). This
  accessor is additive only — it does not change `showWindow()`'s explicit
  re-measure behavior or the existing standalone window path, which remains
  the shipping default.

## Map

| Type | What it is |
|---|---|
| `SettingsWindowController` | Owns the window, forwards `onThemeChanged`/`onExcludedAppsChanged`, exposes `settingsContentViewController` + `test_*` hooks. |
| `SettingsRootViewController` | Assembles the three sections into one scrolling-free column; `preferredContentSize` follows `fittingSize`. |
| `GeneralSettingsViewController` | Launch-at-login. |
| `AppearanceSettingsViewController` | Theme picker (icon-tile). |
| `AudioSettingsViewController` | Excluded-apps list + Advanced › Audio buffer (when `LatencyConfigurable`). |
