# AudioutSharedUI

## Purpose

AppKit row views and window chrome shared by the popover and the Groups screen.
Pure UI: controls route out through a delegate, never touching a backend, a
store, or `GroupController`.

## Rules

- Views never read shared model state; hosts push a snapshot via `apply(...)`.
- Row geometry lives in `PopoverColumnGrid`; columns anchor to the row's trailing edge.
- `test_*` hooks must drive the same delegate path as the live control.
- `controllable` is separate from `selected`: the checkbox follows `selected` alone.
- Membership checkbox enablement is `isAvailable || selected`, because failure keeps selection intent.
- A greyed Bluetooth row's name click CONNECTS, never selects.
- Always write `NSApp?.`, never bare `NSApp.`, which force-unwraps and crashes.
- TRAP: `CATransition` ignores a custom animation key; it files under "transition".
- The "Removed, Undo" offer is host state; the row draws it and decides nothing.
- Instruments reconcile accessibility-display changes live; the accent dial is a third trigger.
- `setContent`'s `defaultSize:` seeds only the first mount of a content controller.
- `ControlPanelBackingView` is an approved custom-drawn exception; NSPanel has no arrow.
- Known stability findings in this target carry `STABILITY(id)` inline markers — details and fix sketches in [../../../dev/notes/stability-audit-2026-07-18.md](../../../dev/notes/stability-audit-2026-07-18.md).
- Long-form traps, dated decisions and the changelog: [AGENTS-HISTORY.md](AGENTS-HISTORY.md). Grep it before debugging anything here.

## Map

- `DeviceRowView` → the shared device row every host mounts.
- `PopoverColumnGrid` → named column geometry for every row.
- `ControlPanelBackingView` → custom-drawn panel background with the menu-bar beak.
