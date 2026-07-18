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
- `DeviceRowView` gets a `showsMeter: Bool = false` init param; the mixer window and `GroupRowView` never pass `true`, so they stay visually unchanged. The leading VU meter (`LevelMeterView`) is mounted only when `showsMeter`, positioned via `PopoverColumnGrid.firstElementLeading(indented:)` so icon columns still align with meter-less rows. `setLevel(_:)`/`resetLevel()` are no-ops when `showsMeter` is false; `test_meterLevel()` returns the last pushed level (`0` with no meter or after a reset).
- `LevelMeterView` is layer-backed, non-interactive (`hitTest` returns `nil`), single-color (`systemGreen`, no yellow/red ramp, no peak-hold). It exposes `setLevel(_ rms: Float)`, `reset()`, `static let columnWidth: CGFloat`, and a deterministic `test_setDisplayedLevel(_:)` hook that sets the displayed fill synchronously with no display link, for snapshots/tests. Ballistics (attack faster than decay) live in the pure `static func ballisticsStep(displayed:target:) -> CGFloat` so the animation curve is unit-testable without a live view.
- `PopoverColumnGrid.meterWidth` and `.meterToLeading` size the new leading meter column; `firstElementLeading(indented:)` computes where the icon/first control starts as `(indented ? indentedLeadingInset : leadingInset) + meterWidth + meterToLeading`, so meter and meter-less rows still line up on the same grid.
- `AppRowView` gets the same `showsMeter: Bool = false` init param and leading `LevelMeterView` as `DeviceRowView` (task T4); every existing caller (`PopoverController`'s `AppRowView()`) omits it and is visually unchanged. When shown, the meter anchors at the row's leading edge and the icon repoints off the meter's trailing edge + `PopoverColumnGrid.meterToLeading` — the same x `firstElementLeading(indented:)` already reserved. `setLevel(_:)`/`resetLevel()`/`test_meterLevel()` mirror `DeviceRowView`'s signatures; the per-app level signal (`BackendEvent.appLevel`) drives `setLevel(_:)` via `PopoverController.updateAppLevel`, never from `apply(_:)`.
- Known stability findings in this target carry `STABILITY(id)` inline markers — details and fix sketches in [../../../dev/notes/stability-audit-2026-07-18.md](../../../dev/notes/stability-audit-2026-07-18.md).
- `DeviceIcon` is the single resolution point for "what SF Symbol represents this device/group" — `DeviceIcon.resolve(_:default:)` falls back to the kind/group default when an override is `nil` or no longer resolves on this OS (`DeviceIcon.isValid`), so every row/detail/icon-well caller shares one staleness check instead of its own nil-check-plus-validate dance. `DeviceIconController` is the only place a per-device icon override is looked up or written (`AudioutedCore.DeviceIconStore` persists it); only the bare symbol name string is ever persisted, never a resolved image or a color.

## Map

| Type | What it is |
|---|---|
| `DeviceRowView` | Shared device row: icon, name/sublabel, mute, slider, %, Selected checkbox; optional leading `LevelMeterView` via `showsMeter`. |
| `LevelMeterView` | Shared leading VU bar (single-color fill, ballistics-driven, non-interactive). |
| `StatusDotView` | On-icon connection-status badge driven off `Device.connectionState`. |
| `PopoverColumnGrid` | Shared column-geometry constants, including the leading meter column (`meterWidth`, `meterToLeading`). |
| `AppRowView` | Popover-only per-app row; owns its own selection highlight and hover wash. Optional leading `LevelMeterView` via `showsMeter`, driven by `BackendEvent.appLevel`. |
| `DeviceIcon` | Single resolution point (+ curated symbol list) for device/group icon names, with render-time fallback. |
| `DeviceIconController` | Loads/persists per-device icon overrides via `AudioutedCore.DeviceIconStore`; the only read/write path for them. |
