# AudioutSettingsUI

## Purpose

The Settings content: General, Appearance and Audio as sections of a
sidebar-plus-pane `SettingsRootViewController`, hosted as the one surface's
Settings screen. There is no standalone Settings window.

## Rules

- Sections are sidebar rows, never tabs; a new section becomes another row.
- Never hand a host an empty controller: AppKit's 500x500 fallback never self-corrects.
- Every view here sets `translatesAutoresizingMaskIntoConstraints = false`, or a transient size freezes into a required constraint.
- A pane's own `fittingSize` grows but never shrinks; measure the column stack instead.
- `NSStackView` never gives back a shown child's height; collapse through a clipped wrapper.
- The surface frame is fixed: publish no pane size (a `preferredContentSize` becomes a priority-501 height constraint; a windowless over-measure stretched General and left 124pt of slack in its first row, 2026-09-03), and never make a pane width required.
- The pane host's root view is an opaque `WarmPanelView`; without it dark mode is illegible.
- `selectSection(at:)` drives real sidebar selection, not a direct pane swap, so tests exercise it.
- Call `paneView(at:)` on a fresh controller before any show, or the snapshot stretches.
- The `settings-snapshot` goldens are not regenerated on macOS 27; never regenerate them.
- Controls stay stock and no gold appears in these panes; only the background is warm.
- Theme tiles use absolute sRGB mirrors of the palette; live tokens would lie about appearance.
- Long-form traps, dated decisions and the changelog: [AGENTS-HISTORY.md](AGENTS-HISTORY.md). Grep it before debugging anything here.

## Map

- `SettingsRootViewController` → split controller: section sidebar plus one scrolling pane host.
- `SettingsSidebarViewController` → the section source list, in the Groups sidebar's geometry.
- `GeneralSettingsViewController` → launch at login, reconnect at launch, the licence row.
- `LicenseSheetViewController` → the Enter License sheet, the only editable key surface.
- `AppearanceSettingsViewController` → theme tiles and the accent dial.
- `AudioSettingsViewController` → excluded apps, connect volume, wake restore, Advanced disclosure.
