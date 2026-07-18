# AudioutedWindowUI

## Purpose

The full mixer window — a source-list sidebar plus mixer/editor detail pane
— is the second host for the same device-row UI the menu-bar popover uses,
not a separate implementation of it. All mixer math (groups, proportional
master, mute, the Selected/Enabled set) is delegated to the shared
`GroupController` in [../../AGENTS.md](../../AGENTS.md); this module never
computes volumes or talks to a backend directly.

## Rules

- **One row, two hosts.** The detail pane reuses `DeviceRowView` from
  `../AudioutedSharedUI` through the same `GroupController` calls the
  popover's `PopoverController` uses. Fix a row bug there, not here — a
  fix applied only in this module won't reach the popover.
- **The content pane is swapped, not toggled.** `swapContent(to:)` removes
  and re-adds the content `NSSplitViewItem`; there is no hidden/shown view
  pair to reach for instead.
- **A draft group has no id.** While `isCreatingDraft` is true, `refreshAll()`
  deliberately leaves the editor alone — there's no persisted id to rebuild
  it from. Don't turn `refreshAll()` into an unconditional reload; it will
  wipe an in-progress draft.
- **No synthesized clicks in headless runs.** Every controller exposes
  `test_*` methods mirroring a real UI action; add one for any new
  user-facing action or it becomes untestable outside a live window.
- **Depends on the model, never the reverse.** No backend types are
  imported; everything comes through `GroupController` or `update(devices:)`.

## Map

| Type | Role |
|---|---|
| `MixerWindowController` | Owns the `NSWindow` + split-view; wires child callbacks to `GroupController`. |
| `MixerViewController` | Detail pane: reused `DeviceRowView`s scoped to a group or all devices. |
| `SidebarViewController` | Source-list outline of groups/devices; reports selection via `onSelect`. |
| `GroupEditorViewController` | Rename/membership/delete pane, plus the unsaved draft-create flow. |
| `ToolbarController` | Hosts the master slider + presets popup; reports to its delegate. |
| `SidebarSelection` | The sidebar-to-pane contract: `.group(id:)` or `.device(id:)`. |
