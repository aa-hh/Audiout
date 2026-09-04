# AudioutWindowUI

## Purpose

The Groups screen's content: a configuration-only tree for viewing and editing
saved groups and for tuning speakers. It owns no window and talks to no
backend.

## Rules

- A group card's "Feeding …" clause states route intent, not playback; this screen assigns nothing.
- Configuration-only: selection is not activation, and nothing here calls `activateGroup`.
- Every way out of the editor lands in `MixerWindowController.dismissEditor()`: “‹ Groups”, ⌘[, the primary button, the Groups plate re-click, and the surface's Escape (which closes the window only when there is no editor to pop).
- Hosts drive visibility through `setHostVisible(_:)`; a hidden host still stores snapshots.
- The sidebar split must never collapse: nothing in the UI brings it back.
- The `mixer-4-device-detail` goldens are unreproducible on macOS 27; never regenerate them.
- Every fitting width derives from `SurfaceLayout`; raising one widens a window that must not.
- Header parity is geometric, in `GroupsPaneLayout`; half-point misses are the run's rounding grid.
- The rail overlay and the delete button anchor to the column, not the container.
- `viewDidAppear` Tab seeding never runs headless; do not delete it as dead code.
- Gold means LIVE, per row; it is never decoration here.
- Magenta is identity, never state: `GroupIdentityGlowView` sits behind every group seat, active or not.
- Persistence failures go through `saveOrReport(_:)`, reported in plain words, never swallowed.
- An unavailable speaker may join a group; `orderedDevices()` is the one ordering rule (2026-08-28).
- Ink carries temperature (C5, 2026-09-03): `labelCool` on idle names and glyphs, `label` on the live one; chrome and the sidebar stay stock. `GroupsInkTemperatureTests` pins it.
- `DeviceIcon` is the single resolution point for a device or group symbol.
- Long-form traps, dated decisions and the changelog: [AGENTS-HISTORY.md](AGENTS-HISTORY.md). Grep it before debugging anything here.

## Map

- `MixerWindowController` → screen-content controller: split view, sheets, auto-select rule.
- `ContentPaneHostViewController` → swapped overview, editor and detail pane, plus footer.
- `GroupsOverviewViewController` → the group list: card grid with seats, absorbed empty state.
- `SidebarViewController` → source list: Groups plate, System Audio, Speakers. A click on the already-selected Groups plate re-reports `.groupsOverview` (the click action, not the selection delegate).
- `GroupEditorViewController` → edit-only pane: a top band carrying “‹ Groups” and the primary, then rename, membership, delete. Edits autosave, so the primary reads “Done”; it reads “Save” only while the name field holds text that has not been committed, and pressing it then commits before leaving.
- `GroupCreationSheetController` → standard sheet for new groups; never activates.
- `DeviceDetailViewController` → device pane: identity, Equalizer, Groups, About.
- `MainOutDetailViewController` → Main Audio page, non-editable icon well.
