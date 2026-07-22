# AudiouterPopoverUI

## Purpose

The menu-bar popover UI (pure AppKit). `PopoverController` owns the `NSPopover`, builds the card stack, ingests `Device` snapshots via `update(devices:)`, and drives `GroupController`/`AppRoutingController`. Routing arithmetic lives in Core (see [../../AGENTS.md](../../AGENTS.md)); this folder only renders and turns clicks into controller calls. Shared row views live in [../AudiouterSharedUI/](../AudiouterSharedUI/).

## Rules

- Reacts only to `Device.connectionState` EDGES, not polling: `→ .failed` drops the device from Selected Devices and auto-expands its diagnosis panel once per episode; `guess → diagnosed` is the same episode and must not re-run cleanup.
- Diagnosis panels auto-drive off `.failed` edges — `openDiagnosisIDs` is the open intent; a user ✕ records into `dismissedDiagnosisIDs` for the current episode, so no repaint/rebuild or mid-episode re-report resurrects a dismissed panel. A fresh `→ .failed` edge is a NEW episode: it clears the dismissal and re-expands. "Try again" is just re-adding to Selected Devices.
- Every delegate callback mutates then calls `rebuild()`; rows aren't mutated in place after a structural change, except the refreshers used for mid-open repaints.
- Collapse state is keyed by the exact card header string — collapse calls must pass the same title the card was built with.
- Two rebuild flavors, not interchangeable: `rebuildForOpen()` resets collapse defaults, discarding this open's manual toggles; plain `rebuild()` preserves them.
- No `NSScrollView` — height flows through `preferredContentSize`. The card stack MUST stay pinned top AND bottom in `PopoverPanelViewController.loadView`, or Auto Layout collapses it to zero.
- `ConnectionDiagnosisView` never touches `NSPasteboard`; the host writes on `onCopyDetails`.
- `selectedAppBundleID` is host-owned, transient. All three removal entry points (± footer, "Remove from list", Delete/Backspace) must funnel through `removeApp(bundleID:)`.
- The Applications card's add/remove control is `ApplicationsFooterView` (± `NSSegmentedControl`), replacing the old "+ Add application…" row.
- `PopoverController.updateLevel(_ rms:, for id:)` is the live push path from `AppDelegate`'s `.level` handling: it early-returns when the popover `isShown` is false, so a backend still emitting behind a closed popover doesn't do wasted view work. `test_pushLevel(_:for:)` is the same dispatch WITHOUT the `isShown` gate, for headless snapshots/tests that never actually show the popover. Both route to `deviceRowsByID[id]?.setLevel(rms)` and, for the Main Out id, `mainOutRow.setLevel(rms)`.
- `PopoverController.updateAppLevel(_ rms:, for bundleID:)` mirrors `updateLevel(_:for:)` for the Applications card: same `isShown` gate, same gate-free test twin (`test_pushAppLevel(_:for:)`), both routing to `appRowsByBundleID[bundleID]?.setLevel(rms)`. Unlike a device level, an app level never feeds `mainOutRow` — Main Out mirrors the selected DEVICE's level, not any one app's contribution. `makeAppRow` constructs its `AppRowView(showsMeter: true)` so the row actually has a meter to push into.
- Closing the popover zeroes every meter rather than leaving a stale bar: the close path calls `resetLevel()` on every row in `deviceRowsByID`, on `mainOutRow`, and on every row in `appRowsByBundleID`.
- Metering itself is gated off the wall-clock cost of RMS computation while the popover is closed: `PopoverController` drives `(backend as? MeteringControlling)?.setMeteringActive(_:)` — on when the popover opens, off when it closes — so the backend only computes RMS (and only runs the metering-only taps) while there's a UI to show it to.
- Known stability findings in this target carry `STABILITY(id)` inline markers — details and fix sketches in [../../../dev/notes/stability-audit-2026-07-18.md](../../../dev/notes/stability-audit-2026-07-18.md).

## Map

| Type | What it is |
|---|---|
| `PopoverController` | Orchestrator: `NSPopover`, cards, `Device` ingestion. |
| `PopoverPanelViewController` | Card container: build/collapse by header title. |
| `CardView` | Rounded module: header rows + collapsible body. |
| `MainOutRowView` | System Audio "Main Audio" row — slider, mute, "Output" destination dropdown, under-name `LevelMeterView`, and the membership rail's `.origin` hook (rises in the left gutter and turns into the meter). |
| `ConnectionDiagnosisView` | "Couldn't connect" panel under a failed row. |
| `PopoverHeaderView` | Top bar: title + groups / settings / quit. |
| `GroupRowView` | Group's master row; built for the window, unused here. |
| `RunningAppInfo` | Snapshot of a running app for the add picker. |
