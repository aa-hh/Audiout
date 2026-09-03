# AudioutPopoverUI

## Purpose

The menu-bar popover UI, and the one-surface host: `AppSurfaceController` owns
the shell and swaps the Mixer, Groups and Settings screens through it. This
folder renders; routing arithmetic lives in Core.

## Rules

- Reacts to `Device.connectionState` EDGES, never polling; a failed device stays selected.
- Open intent is pruned against MEMBERSHIP too (2026-08-06); `.failed` is sticky.
- Every delegate callback mutates, then calls `rebuild()`; no in-place mutation afterwards.
- The popover is the only host of `PopoverPanelViewController`, in dev and shipping.
- The surface claims the panel through `claimPanelForSurfaceHosting()`, the one handover door.
- No `NSScrollView`: height flows through `preferredContentSize`, pinned top and bottom.
- `insertRow`/`removeRow` own the re-fit; never add your own height republish.
- Two rebuild flavors: `rebuildForOpen()` discards manual toggles, `rebuild()` preserves them.
- A subsection collapses by animating its own clip height, never rebuilding (2026-08-10).
- A collapsed subsection cuts the rail exactly as a collapsed card does (2026-08-11).
- Hidden means idle: ingest skips behind `isEffectivelyShown`, and every open rebuilds.
- At most one sync drawer is open; `expandedSyncDeviceID` is the single owner.
- A live scrub applies to audio but must not persist until committed.
- The alignment wizard is a sheet the popover cannot close under; its lights are green and steel blue (`wireCore`/`ring`), never magenta (C1).
- A selected Bluetooth device that loses availability is deselected here, on the edge.
- The Mixer carries an equalizer DOOR (the row button beside mute, and the row menu) and one mark (magenta border when the curve is not flat). No editor, no curve, no tone control on the Mixer (2026-08-22, amended 2026-09-03).
- A never-aligned Bluetooth row's chip IS the wizard's door; a measured one opens the drawer.
- A first-join alignment note is session state: ✕ hides it, nothing is written down.
- Known stability findings in this target carry `STABILITY(id)` inline markers — details and fix sketches in [../../../dev/notes/stability-audit-2026-07-18.md](../../../dev/notes/stability-audit-2026-07-18.md).
- Long-form traps, dated decisions and the changelog: [AGENTS-HISTORY.md](AGENTS-HISTORY.md). Grep it before debugging anything here.

## Map

- `PopoverController` → the Mixer brain: card stack, device ingest, controller calls.
- `PopoverPanelViewController` → the panel view controller every host mounts.
- `AppSurfaceController` → owns the shell, swaps the three screens.
