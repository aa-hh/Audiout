# AudioutSettingsUI

## Purpose

The Settings content — General / Appearance / Audio as SECTIONS of a
sidebar-plus-pane `SettingsRootViewController` (an `NSSplitViewController`),
hosted as the one-surface shell's Settings screen
(`AudioutPopoverUI.AppSurfaceController`). There is no standalone Settings
window anymore; About keeps its own window as the one deliberate exception.
For the app's overall package layout and where the settings model types
(`AppSettings`, `ExcludedAppsController`, …) live, see
[../../AGENTS.md](../../AGENTS.md).

## Rules

- One section per sidebar row, not tabs — the sidebar is the Groups screen's
  own arrangement (`SurfaceLayout.sidebarWidth`, same cell geometry, same
  `SidebarWarmSurfaceView` wash, one header row), so the app has ONE tab
  level, the surface's. Starts on General, no persisted section. New sections
  become sidebar rows, never a second tab strip.
- **The sizing traps — probe-confirmed AppKit facts. Do not weaken any of
  them.**
  1. `NSWindow(contentViewController:)` on an empty container yields AppKit's
     500×500 fallback, which never self-corrects. Build the whole split tree
     inside `SettingsRootViewController.init` — never hand a host an empty
     controller.
  2. Every view in this hierarchy must set
     `translatesAutoresizingMaskIntoConstraints = false` — an autoresized
     subview freezes whatever transient size it had (e.g. the 500×500
     fallback) into a required height constraint, with no conflict ever
     logged.
  3. A windowless view's own `fittingSize`/`layoutSubtreeIfNeeded` can grow
     but never shrink back down (a higher-priority layout lock beats
     `fittingSize`'s pull-to-zero). `republishFittedHeight()` therefore
     measures the column stack's `fittingSize`, never `view.fittingSize` —
     any pane that can shrink at runtime must do the same.
  4. `NSStackView` never releases an in-place arranged child's height once
     shown (`isHidden`, visibility priority, and a zero-height constraint all
     fail to do it). Use the `CardView` clip idiom instead: a required
     height==0 constraint on a clipping wrapper is the one controlled value;
     the content's bottom pin stays `.defaultHigh`.
  5. The pane host's frame is fixed — no pane ever publishes its size to it.
     Panes hold width at `.defaultHigh`; the host's edge pins win.
- The pane host paints an explicit opaque `WarmPanelView` background, not the
  ambient window fill — without it, dark-mode child controls draw illegible
  light-adapted colors over whatever sits behind the window.
- `BorderedListView` hand-draws its border (no stock control gives a rounded
  separator-color border), resolved per-paint so it needs no manual
  appearance bookkeeping.
- `selectSection(at:)` drives REAL sidebar selection, not a direct pane swap
  — a delegate shortcut once let broken UI stay green across 78 tests.
  `paneView(at:)` must be called on a fresh controller before any show/switch
  or it snapshots at a stretched width. `settings-snapshot` renders each pane
  to PNG for dark-mode verification; its goldens don't regenerate on macOS 27
  (`NSVisualEffectView` composites opaque there).
- Settings stays stock except background; the Appearance pane owns the
  accent-dial write path (no second apply site); consequential controls
  carry a live hint line, never a static subtitle; header/readout look goes
  through `SettingsForm.sectionHeader`/`readoutWell`.

## Map

| Type | What it is |
|---|---|
| `SettingsRootViewController` | Section sidebar + one scrolling pane host; `selectSection(at:)` drives real sidebar selection. |
| `SettingsSidebarViewController` | The section source list. |
| `GeneralSettingsViewController` | Launch-at-login, reconnect-at-launch, license status/actions, footer (Setup/About/Check Updates). |
| `LicenseSheetViewController` | The Enter License… sheet — the only editable key surface. |
| `AppearanceSettingsViewController` | Theme tiles + Accent dial. |
| `AudioSettingsViewController` | Excluded-apps list + connect volume + wake restore + Advanced (Audio buffer) disclosure. |
