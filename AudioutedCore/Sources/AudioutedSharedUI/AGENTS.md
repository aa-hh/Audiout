# AudioutedSharedUI

## Purpose

AppKit row views shared by the popover (`AudioutedPopoverUI`) and the mixer window (`AudioutedWindowUI`) so both hosts render the same device row from one implementation. Views here are pure UI: controls route out through a per-view `Delegate` (or closure), never touching a backend, store, or `GroupController` directly. For the routing model these rows render, see [../../AGENTS.md](../../AGENTS.md).

## Rules

- Views never read shared model state — hosts push a plain-value snapshot via `apply(...)`. `DeviceRowView` takes `selected` explicitly (membership lives in `GroupController`, not `Device`); `AppRowView` takes an isolated `Configuration`.
- Row geometry lives in `PopoverColumnGrid` (named constants, no magic numbers) — columns anchor to the row's *trailing* edge, so slider/status/trailing-control columns line up across sections despite different leading controls.
- Hover state is transient, separate from selection, reconciled via an app-local `.mouseMoved` monitor cleared on every `apply` — an `NSTrackingArea` alone never fires `mouseExited` for a bottom-most row with an untracked dead-zone below it.
- `DeviceRowView` computes `isInMenu` live from `enclosingMenuItem` to pick its drawing path and accessibility role — don't hardcode one path for both hosts.
- Each view exposes `test_*` hooks (`test_setVolume`, `test_toggleEnabled`, …) that must drive the exact same delegate path as the live control, since gestures can't be synthesized headlessly.
- The device row's trailing control is an `NSButton` checkbox under a "Selected" header (membership in "Selected Devices"), not an `NSSwitch`; the column is not "Enabled".
- `DeviceRowView.apply` takes `controllable` separate from `selected`: slider/mute enablement follows `controllable`, but the checkbox and the sublabel's "System" token follow `selected` alone.
- The popover header's icon buttons are stock `NSButton` (`bezelStyle = .smallSquare`) — no custom hover-button class exists here.

## Map

| Type | What it is |
|---|---|
| `DeviceRowView` | Shared device row: icon, name/sublabel, mute, slider, %, Selected checkbox. |
| `StatusDotView` | On-icon connection-status badge driven off `Device.connectionState`. |
| `PopoverColumnGrid` | Shared column-geometry constants. |
| `AppRowView` | Popover-only per-app row; owns its own selection highlight and hover wash. |
