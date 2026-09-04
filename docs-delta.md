# DESIGN.md delta — TRACK 1 (header strip)

One replacement, in the "Named Rules" section under **Elevation & Depth**.

## Replace the **Custom Drawing Is a Short, Named List** paragraph (DESIGN.md:370-387)

The list of drawing-only AppKit cell subclasses gains a seventh entry, and the
count word "six" becomes "seven". Nothing else in the paragraph changes.

### Current

> **Custom Drawing Is a Short, Named List.** Root `AGENTS.md` names the
> sanctioned custom-drawn Warm Signal pieces as: the canvas, the connection
> ring, the signal dot, the meter, the bus control, the fader skin, and the
> shell bubble fill. Below that chrome-level list, six drawing-only AppKit
> cell subclasses carry the same "paint changes, behavior stays stock"
> contract, each installed FIRST and the control configured on top of it, so tracking,
> keyboard input and VoiceOver stay untouched: `WarmFaderCell: NSSliderCell`
> (the row volume sliders), `AlignmentPlateCell: NSButtonCell` (the wizard's
> answer plates), `SyncChipCell` and `InvisibleSwitchCell` (both
> `NSButtonCell`, in `DeviceRowView.swift` — the sync chip and the membership
> node's checkbox), `GroupRowButtonCell: NSButtonCell`
> (`DeviceDetailViewController.swift`), and `WarmNameFieldCell:
> NSTextFieldCell` (the Groups window's inline-rename field). Each folder's own
> `AGENTS.md` names its own local exception rather than one file listing them
> all — `AudioutSharedUI/AGENTS.md` names `ControlPanelBackingView`,
> `AudioutOnboardingUI/AGENTS.md` names `DemoPaneView` separately. Anything not
> on one of these lists draws with stock AppKit chrome; a new custom-drawn
> piece gets named in its owning folder's `AGENTS.md`, not invented silently.

### Replacement

**Custom Drawing Is a Short, Named List.** Root `AGENTS.md` names the
sanctioned custom-drawn Warm Signal pieces as: the canvas, the connection
ring, the signal dot, the meter, the bus control, the fader skin, and the
shell bubble fill. Below that chrome-level list, seven drawing-only AppKit
cell subclasses carry the same "paint changes, behavior stays stock"
contract, each installed FIRST and the control configured on top of it, so tracking,
keyboard input and VoiceOver stay untouched: `WarmFaderCell: NSSliderCell`
(the row volume sliders), `AlignmentPlateCell: NSButtonCell` (the wizard's
answer plates), `SyncChipCell` and `InvisibleSwitchCell` (both
`NSButtonCell`, in `DeviceRowView.swift` — the sync chip and the membership
node's checkbox), `GroupRowButtonCell: NSButtonCell`
(`DeviceDetailViewController.swift`), `WarmNameFieldCell:
NSTextFieldCell` (the Groups window's inline-rename field), and
`SurfaceToolbarSeatCell: NSButtonCell` (`SurfaceToolbarSeatButton.swift` —
every item of the one-surface header strip). Each folder's own
`AGENTS.md` names its own local exception rather than one file listing them
all — `AudioutSharedUI/AGENTS.md` names `ControlPanelBackingView`,
`AudioutOnboardingUI/AGENTS.md` names `DemoPaneView` separately. Anything not
on one of these lists draws with stock AppKit chrome; a new custom-drawn
piece gets named in its owning folder's `AGENTS.md`, not invented silently.

## Why the header strip needed a seventh entry

AppKit draws a bordered `NSToolbarItem`'s hover state as a circle and its
selected state as a rounded square — two shapes for two states of one control,
and neither shape is settable. Alec asked for one shape (2026-09-04), so the
strip's items now draw themselves: one rounded rectangle at the control radius
for rest, hover, pressed, selected and Pin's on/off. The `NSToolbar` itself
stays, because it is the window's unified title-bar strip and supplies the
system material and the Reduce Transparency handling.

All four items were converted, not just the three tabs. Converting half the
strip is what failed live review on 2026-08-30: three bare glyphs beside two
bordered circles, two styles in one header.

Nothing in the seat is behind `#available`. The version this replaces put
every cue inside `if #available(macOS 26.0, *)` while the package deploys to
14.2, so macOS 14–25 showed three identical circles and no current screen at
all.

## No change needed to the gold rule

The seat washes in `Tokens.Color.engagedChrome` at the weights the mixer's
rows already use — `PopoverColumnGrid.rowHoverWashAlpha` (hover),
`rowSelectionWashAlpha` (selected), `mutePillFillAlpha` (pressed). Neutral,
never gold, exactly as "Don't draw MUTE, or any hover/selection wash, in gold"
already requires.
