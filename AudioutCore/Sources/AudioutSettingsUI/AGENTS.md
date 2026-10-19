# AudioutSettingsUI

## Purpose

The Settings content: General, Audiout Remote, Appearance, Audio and License as sections of a sidebar-plus-pane `SettingsRootViewController`, hosted as the one surface's Settings screen.

## Rules

- Sections are sidebar rows, never tabs; a new section becomes another row.
- A row's readout is read from the pane's own source, never cached or rounded into a nicer state.
- Never hand a host an empty controller: AppKit's 500x500 fallback never self-corrects.
- Every view here sets `translatesAutoresizingMaskIntoConstraints = false`, or a transient size freezes into a required constraint.
- A pane's own `fittingSize` grows but never shrinks; measure the column stack instead.
- `NSStackView` never gives back a shown child's height; collapse through `FoldingClipView`.
- The surface frame is fixed: publish no pane size, and never make a pane width required.
- The pane host's root view is an opaque `WarmPanelView`; without it dark mode is illegible.
- `selectSection(at:)` drives real sidebar selection, not a direct pane swap, so tests exercise it.
- Call `paneView(at:)` on a fresh controller before any show, or the snapshot stretches.
- The `settings-snapshot` goldens are not regenerated on macOS 27; never regenerate them.
- Controls stay stock. Gold is Buy Audiout and the sheet's Register; `ring` tints a glyph only while the user must act.
- Theme tiles use absolute sRGB mirrors of the palette; live tokens would lie about appearance.
- Long-form traps, dated decisions and the changelog: [AGENTS-HISTORY.md](AGENTS-HISTORY.md).

## Map

- `SettingsRootViewController` → section sidebar plus one scrolling pane host.
- `SettingsSidebarViewController` → the section source list with readouts.
- `GeneralSettingsViewController` → launch at login, reconnect, Touch Bar, usage statistics.
- `RemoteSettingsViewController` → iPhone switch, invitation, remembered phones.
- `LicenseSettingsViewController` → the licence well.
- `LicenseSheetViewController` → the Enter License sheet, the only key field.
- `AppearanceSettingsViewController` → theme tiles and the accent dial.
- `AudioSettingsViewController` → excluded apps, connect volume, wake restore, Advanced.
