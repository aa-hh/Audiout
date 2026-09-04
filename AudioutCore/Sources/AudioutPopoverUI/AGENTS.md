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
- Height flows through `preferredContentSize`, pinned top and bottom. Exactly ONE `NSScrollView` exists in the panel: the Output Devices card's body (roadmap 039), which stops at `deviceListMaxHeight` (12 rows) or at what the screen leaves, whichever is lower. Its height is a constraint `fittingSizeSettled()` reconciles from the ROWS — a scroll view has no natural height, so measuring the scroll view instead gives a zero-height or screen-height panel. Every other card still pins its rows straight into its clip; do not add a second one.
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
- The header strip draws its OWN chrome, and the three tabs are ONE capsule: a single
  `NSToolbarItem` carries a `SurfaceToolbarTabCapsule` (a pill-shaped surface drawn
  once) with the three `SurfaceToolbarSeatButton`s layered over it. Three separate
  seats, one per tab, read as three islands and were rejected. The current tab is a
  soft rounded highlight INSIDE the pill, hover the same highlight weaker, an idle tab
  nothing — always painted ON the capsule, never instead of it, which is what keeps the
  current screen lighter than its ground in dark mode. Pin is the standalone button
  outside the capsule, wearing the same highlight; converting only half the strip failed
  review on 2026-08-30. The seat button is the folder's one custom-drawn exception
  (drawing only; tracking, keyboard and VoiceOver stay stock) because AppKit draws a
  bordered item's hover as a CIRCLE and its selection as a rounded SQUARE. Never put a
  cue behind `#available` — the package deploys to 14.2 (2026-09-04).
- The CURRENT tab shows its name beside its glyph; the other two never do (2026-09-04).
  One name on the strip at a time, clamped to `SurfaceToolbarSeat.maxNameWidth` and
  truncated past it — that pair is what makes the 2026-09-03 failure impossible, where
  three translated labels widened the strip until AppKit swept the tabs into the
  overflow chevron. Never reveal a second name, never lift the clamp, and never widen
  the strip on HOVER: the pointer must not reshape a control it is only passing over.
  The reveal grows the seat itself and runs on `FoldAnimator`, the app's one reveal
  clock, which is where Reduce Motion is already answered.
- The Mixer tab does NOT draw `slider.horizontal.3`: that is the device row's equalizer
  door (`DeviceRowView.eqSymbolName`), and sliders are what an equalizer looks like. The
  tab draws `waveform` (2026-09-04).
- Known stability findings in this target carry `STABILITY(id)` inline markers — details and fix sketches in [../../../dev/notes/stability-audit-2026-07-18.md](../../../dev/notes/stability-audit-2026-07-18.md).
- Long-form traps, dated decisions and the changelog: [AGENTS-HISTORY.md](AGENTS-HISTORY.md). Grep it before debugging anything here.

## Map

- `PopoverController` → the Mixer brain: card stack, device ingest, controller calls.
- `PopoverPanelViewController` → the panel view controller every host mounts.
- `AppSurfaceController` → owns the shell, swaps the three screens.
- `SurfaceToolbar` → the window's header strip; `SurfaceToolbarSeatButton` is what it draws.
