# AudioutWindowUI

## Purpose

The Groups screen's content: a configuration-only tree for viewing and editing
saved groups and for tuning speakers. It owns no window and talks to no
backend.

## Rules

- Configuration-only: selection is not activation, and nothing here calls `activateGroup`.
- Hosts drive visibility through `setHostVisible(_:)`; a hidden host still stores snapshots.
- The sidebar split must never collapse: nothing in the UI brings it back.
- The `mixer-4-device-detail` goldens are unreproducible on macOS 27; never regenerate them.
- Every fitting width derives from `SurfaceLayout`; raising one widens a window that must not.
- Header parity is geometric, in `GroupsPaneLayout`; half-point misses are the run's rounding grid.
- The rail overlay and the delete button anchor to the column, not the container.
- `viewDidAppear` Tab seeding never runs headless; do not delete it as dead code.
- Gold means LIVE, per row; it is never decoration here.
- Persistence failures go through `saveOrReport(_:)`, reported in plain words, never swallowed.
- An unavailable speaker may join a group; `orderedDevices()` is the one ordering rule (2026-08-28).
- Text colors are frozen: contrast lifts from surfaces, never hue.
- `DeviceIcon` is the single resolution point for a device or group symbol.
- Long-form traps, dated decisions and the changelog: [AGENTS-HISTORY.md](AGENTS-HISTORY.md). Grep it before debugging anything here.

## Map

- `MixerWindowController` → screen-content controller: split view, sheets, auto-select rule.
- `ContentPaneHostViewController` → swapped overview, editor and detail pane, plus footer.
- `GroupsOverviewViewController` → the group list: card grid, absorbed empty state.
- `SidebarViewController` → source list: Groups plate, System Audio, Speakers.
- `GroupEditorViewController` → edit-only pane: back band, rename, membership, delete.
- `GroupCreationSheetController` → standard sheet for new groups; never activates.
- `DeviceDetailViewController` → device pane: identity, Equalizer, Groups, About.
- `MainOutDetailViewController` → Main Audio page, non-editable icon well.
