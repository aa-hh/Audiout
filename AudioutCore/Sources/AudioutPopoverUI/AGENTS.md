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
- A collapsed subsection cuts the rail as a collapsed card does (2026-08-11), but only when it hides an ON-SPINE device and is the lowest that does; the card's own fold outranks it. `railNodeIsOnSpine` asks the MODEL, since the rows are gone by then, so it must track `DeviceRowView.updateBus`.
- Hidden means idle: ingest skips behind `isEffectivelyShown`, and every open rebuilds.
- At most one sync drawer is open; `expandedSyncDeviceID` is the single owner.
- A live scrub applies to audio but must not persist until committed.
- The alignment wizard is a sheet the popover cannot close under; its lights are green and steel blue (`wireCore`/`ring`), never magenta (C1).
- A selected Bluetooth device that loses availability is deselected here, on the edge.
- The Mixer carries an equalizer DOOR (the row button beside mute, and the row menu) and one mark (magenta border when the curve is not flat). No editor, no curve, no tone control on the Mixer (2026-08-22, amended 2026-09-03).
- A never-aligned Bluetooth row's chip IS the wizard's door; a measured one opens the drawer.
- A first-join alignment note is session state: ✕ hides it, nothing is written down.
- The header strip is BORDERED `NSToolbarItem`s — every tab and Pin alike — and the
  current screen is AppKit's own `selectedItemIdentifier`, never an authored fill
  (2026-09-05, replacing the custom-drawn capsule that stood here). Two defects killed
  the drawn version: every cue sat behind `if #available(macOS 26.0, *)` while the
  package deploys to 14.2, so macOS 14-25 showed three identical circles and no current
  screen at all; and the authored fill had to clear the UNSELECTED capsule, which in dark
  mode was already the same grey, so the current tab rendered as the darkest thing in the
  strip. Never put a cue behind `#available`, and never re-author this chrome: a custom
  view is nested INSIDE the system's own rounded-square wrapper, which is why a
  hand-drawn Pin could never come out a circle. Pin's pinned state reads off the glyph
  (`pin` / `pin.fill`) for the same reason — the system owns that item's chrome.
- The animated tab-name reveal is GONE (2026-09-05), removed with the custom capsule it
  was built on. Tabs now carry a plain `item.label` and AppKit decides what it shows. The
  constraint that produced the reveal still stands if anyone rebuilds it: never let three
  translated labels widen the strip, which on 2026-09-03 pushed the tabs into the overflow
  chevron. One name at a time, clamped and truncated, was the shape that worked.
- The Mixer tab does NOT draw `slider.horizontal.3`: that is the device row's equalizer
  door (`DeviceRowView.eqSymbolName`), and sliders are what an equalizer looks like. The
  tab draws `waveform` (2026-09-04).
- Groups and Settings are BUILT a turn after the surface opens, never on the click that
  selects them (`prewarmScreens`). Building is not mounting — neither reaches `setContent`.
- A screen swap dissolves the incoming screen in: opacity 0 → 1 on `FoldAnimator`, the app's
  one reveal clock, which is also where Reduce Motion is answered. Opacity is the ONLY thing
  that travels, and every tick puts the session frame back, because showing the fade makes
  the window lay out and a freshly mounted split view takes that as its chance to widen it.
- An App Routing row may target a saved GROUP. The one-role-per-speaker filter hides a Main Out member from the DEVICE list but never the group containing it — the group entry discloses how much of itself the app gets, and only greys out when no member is free.
- A group's membership is read LIVE on every rebuild (`groupRouteTargets()`); never cache it.
- A group edit reaches the surface ONLY through `groupsDidChange()`; no other trigger watches it.
- Known stability findings in this target carry `STABILITY(id)` inline markers — details and fix sketches in [../../../dev/notes/stability-audit-2026-07-18.md](../../../dev/notes/stability-audit-2026-07-18.md).
- Long-form traps, dated decisions and the changelog: [AGENTS-HISTORY.md](AGENTS-HISTORY.md). Grep it before debugging anything here.

## Map

- `PopoverController` → the Mixer brain: card stack, device ingest, controller calls.
- `PopoverPanelViewController` → the panel view controller every host mounts.
- `AppSurfaceController` → owns the shell, swaps the three screens.
- `SurfaceToolbar` → the window's header strip, built from bordered `NSToolbarItem`s.
