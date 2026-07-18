# AudioutedWindowUI

## Purpose

The "Groups" window — a CONFIGURATION-ONLY host for viewing and editing saved
groups. The window (via `MixerWindowController`) owns a source-list sidebar
(`SidebarViewController`) plus a detail pane that swaps between a mixer view
(`MixerViewController`) and a group editor (`GroupEditorViewController`).
Selecting a group opens its editor; selecting a device or nothing shows the
mixer. **Viewing or editing a group here never activates it or moves audio** —
activation lives in the app's popover only. All mixer math (groups, master,
mute) is delegated to the shared `GroupController` in
[../../AGENTS.md](../../AGENTS.md); this module never computes volumes or talks
to a backend directly.

## Rules

- **Configuration-only: sidebar selection ≠ activation.** Clicking a group row
  opens its editor so the user can rename it, add/remove members, or delete it.
  No member becomes active, no audio moves, no Main Out change. Activation
  lives in the popover (`../ AudioutedPopoverUI`), not here.
- **One row, two hosts.** The mixer pane reuses `DeviceRowView` from
  `../AudioutedSharedUI` through the same `GroupController` calls the
  popover's `PopoverController` uses. Fix a row bug there, not here.
- **The content pane is swapped, not toggled.** `swapContent(to:)` removes
  and re-adds the content `NSSplitViewItem`; there is no hidden/shown view
  pair to reach for instead.
- **Group creation moved to a sheet.** The old in-pane draft flow is gone.
  `GroupCreationSheetController` is a standard macOS sheet (`presentAsSheet`)
  that never activates a group — the caller selects the resolved group and
  opens its editor.
- **The sidebar always shows the Groups section** (design revamp: this window
  is groups-configuration only). When empty it displays "No groups yet"
  (a non-selectable placeholder), plus a labeled "New Group" button at the
  bottom. Devices section appears only when there are ungrouped speakers.
- **`GroupEditorViewController` is edit-only.** It shows an already-persisted
  group, allows renaming and membership edits, and can delete it. Group
  creation (`GroupCreationSheetController`) is a separate, parallel flow.
- **`MembershipRowView` is a shared checklist row.** Used by both the
  creation sheet and the group editor to present devices as a checkbox list
  (memberships, not routing). A separate `DeviceRowView` exists in the
  mixer for routing-and-volume use cases; never conflate them.
- **The toolbar hosts ONLY a master-volume slider** (the old presets popup
  was removed with the revamp — this window never switches the active group,
  so there is nothing to switch between).
- **No synthesized clicks in headless runs.** Every controller exposes
  `test_*` methods mirroring a real UI action; add one for any new
  user-facing action or it becomes untestable outside a live window.
- **Depends on the model, never the reverse.** No backend types are
  imported; everything comes through `GroupController` or `update(devices:)`.

## Map

| Type | Role |
|---|---|
| `MixerWindowController` | Owns `NSWindow`, split-view, toolbar, sheet; swaps content between mixer/editor. |
| `MixerViewController` | Mixer pane: device rows scoped to a group or all devices. |
| `SidebarViewController` | Source-list (Groups + Devices sections); selection drives the detail pane. |
| `GroupEditorViewController` | Edit-only pane: rename, membership toggles, delete; no creation flow. |
| `GroupCreationSheetController` | Standard macOS sheet for new groups; never activates. |
| `MembershipRowView` | Checkbox + icon + name row used in creation sheet and editor. |
| `ToolbarController` | Master-volume slider (no group switcher); reports to its delegate. |
| `SidebarSelection` | Enum: `.group(id:)` or `.device(id:)`. |
