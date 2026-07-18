# AudiouterPopoverUI

## Purpose

The menu-bar popover UI (pure AppKit). `PopoverController` owns the `NSPopover`, builds the card stack, ingests `Device` snapshots via `update(devices:)`, and drives `GroupController`/`AppRoutingController`. Routing arithmetic lives in Core (see [../../AGENTS.md](../../AGENTS.md)); this folder only renders and turns clicks into controller calls. Shared row views live in [../AudiouterSharedUI/](../AudiouterSharedUI/).

## Rules

- Reacts only to `Device.connectionState` EDGES, not polling: `→ .failed` drops the device from Selected Devices and auto-expands its diagnosis panel once per episode; `guess → diagnosed` is the same episode and must not re-run cleanup.
- The diagnosis panel has no manual toggle — `openDiagnosisIDs` is the intent; "Try again" is just re-adding to Selected Devices.
- Every delegate callback mutates then calls `rebuild()`; rows aren't mutated in place after a structural change, except the refreshers used for mid-open repaints.
- Collapse state is keyed by the exact card header string — collapse calls must pass the same title the card was built with.
- Two rebuild flavors, not interchangeable: `rebuildForOpen()` resets collapse defaults, discarding this open's manual toggles; plain `rebuild()` preserves them.
- No `NSScrollView` — height flows through `preferredContentSize`. The card stack MUST stay pinned top AND bottom in `PopoverPanelViewController.loadView`, or Auto Layout collapses it to zero.
- `ConnectionDiagnosisView` never touches `NSPasteboard`; the host writes on `onCopyDetails`.
- `selectedAppBundleID` is host-owned, transient. All three removal entry points (± footer, "Remove from list", Delete/Backspace) must funnel through `removeApp(bundleID:)`.
- The Applications card's add/remove control is `ApplicationsFooterView` (± `NSSegmentedControl`), replacing the old "+ Add application…" row.
- Known stability findings in this target carry `STABILITY(id)` inline markers — details and fix sketches in [../../../dev/notes/stability-audit-2026-07-18.md](../../../dev/notes/stability-audit-2026-07-18.md).

## Map

| Type | What it is |
|---|---|
| `PopoverController` | Orchestrator: `NSPopover`, cards, `Device` ingestion. |
| `PopoverPanelViewController` | Card container: build/collapse by header title. |
| `CardView` | Rounded module: header rows + collapsible body. |
| `MainOutRowView` | System row — slider, mute, destination dropdown. |
| `ConnectionDiagnosisView` | "Couldn't connect" panel under a failed row. |
| `PopoverHeaderView` | Top bar: title + groups / settings / quit. |
| `GroupRowView` | Group's master row; built for the window, unused here. |
| `RunningAppInfo` | Snapshot of a running app for the add picker. |
