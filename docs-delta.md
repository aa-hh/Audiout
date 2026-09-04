# DESIGN.md delta — Track 4, item 4B (Equalizer card recess)

Do not edit DESIGN.md directly; this is the replacement text for the coordinator
to apply centrally.

## Section: "Elevation & Depth" (root `DESIGN.md`)

Replace the paragraph that currently reads:

> Mostly flat, matching iOS: the dark ground ladder (canvas → panel → raised)
> and, in light, edge weight alone carry depth. `Tokens.Color.shadow` (an
> alias of `NSColor.black`) has two real consumers, both control cells rather
> than the popover's card chrome: `AlignmentPlateCell` (the wizard's answer-
> plate lip shading, rim shadow blend, and chip shadow fill) and
> `WarmFaderCell` (the fader trough's inset shade). The popover's own
> `ControlPanelBackingView` (a custom-drawn bubble-plus-beak shape, because
> `NSPanel` has no arrow) is a separate, named custom-drawn exception that
> does not itself draw a shadow.

with:

> Mostly flat, matching iOS: the dark ground ladder (canvas → panel → raised)
> and, in light, edge weight alone carry depth. `Tokens.Color.shadow` (an
> alias of `NSColor.black`) has three real consumers: `AlignmentPlateCell`
> (the wizard's answer-plate lip shading, rim shadow blend, and chip shadow
> fill), `WarmFaderCell` (the fader trough's inset shade), and —
> since 2026-09-04 — `GroupedSectionView`'s new `.well` style (the Equalizer
> recess on both the device detail page and Main Audio): a 1 pt band at 0.18
> alpha, clipped inside the shape's top edge, the same flat recipe the other
> two already draw. Both Equalizers switched from `.card` to `.well` because
> `.card`'s `raised` fill is the flat `#FAFAFB` ground in light — identical
> to the `canvas`/`panel` it sits on — leaving a 1 pt outline around nothing;
> `well` (`#E9EAEC` light / `#050507` dark) is the one neutral that stays
> visibly recessed on the flat chassis. Measured separation: light `well` on
> the flat ground is 1.154:1; dark `well` on `panel` is 1.134:1 (`Tokens.swift`'s
> own doc comment on `well` carries both figures). The popover's own
> `ControlPanelBackingView` (a custom-drawn bubble-plus-beak shape, because
> `NSPanel` has no arrow) is a separate, named custom-drawn exception that
> does not itself draw a shadow.

### Why

`DeviceDetailViewController.swift:83` built `eqWell` as a `GroupedSectionView`
and never set its style, so it stayed the default `.card`. In light mode
`.card`'s `raised` fill resolves to the same flat `#FAFAFB` as the pane's own
`canvas`/`panel` ground, so the Equalizer card was a 1 pt `containerEdge`
outline around nothing. `GroupedSectionView` gained a fourth `Style` case,
`.well`, which fills with `Tokens.Color.well` instead of `raised`, keeps the
same `containerEdge` stroke and panel radius as `.card`, and adds a flat,
clipped inset-shade band along the visual top edge — the same recipe already
shipping in `WarmFaderCell.swift:87-95` (the fader trough's inset shade) and
`AlignmentPlateCell.swift:23-39`/`:184-198` (the wizard plate's bevel lips):
a 1 pt rect filled at `Tokens.Color.shadow` alpha 0.18, clipped to the
shape's own path, no blur, no `NSShadow`. Both Equalizers wear it:
`DeviceDetailViewController`'s `eqWell` and `MainOutDetailViewController`'s
own `eqWell` on the Main Audio page, which carried the identical defect.

Measured, independently recomputed from the WCAG relative-luminance formula
against the hex values in `Tokens.swift`:
- light `well` (`#E9EAEC`) vs the flat `canvas`/`panel`/`raised` ground
  (`#FAFAFB`): **1.154:1**
- dark `well` (`#050507`) vs `panel` (`#15171A`): **1.134:1**

Both match the figures already recorded in `Tokens.swift`'s own doc comment on
`well`.

---

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


---

# DESIGN.md delta — Track 3 (the device row's two marks)

Branch `claude/brand-fixes-rowmarks`. The coordinator applies these; DESIGN.md was
not edited here.

---

## 1. Replace the whole "Equalizer Door (Mixer, Mac-only)" section

It currently sits at `DESIGN.md:427-443`, under Signature Components. Replace
the entire section — heading and body — with:

```markdown
### Equalizer Door (Mixer, Mac-only)
The Mixer carries an equalizer DOOR only — the row button beside mute, and the
row context menu — plus one mark. When the speaker's curve is not flat the door
draws a GOLD SEAT: a `Tokens.Color.gold` fill in a 7 pt rounded square with a
1 pt `Tokens.Color.inkOnFill` border, the glyph on top in that same dark ink at
15 pt semibold. At rest there is no seat at all — a `Tokens.Color.label2` glyph
at the row's 13 pt accessory size.

The mark was a bare gold GLYPH until 2026-09-04 and failed on measurement: gold
runs 3.64:1 on `canvas` in light where the at-rest `label2` runs 5.97:1, so the
"on" state read 39% dimmer than the "off" state; dark separated the two by
1.22:1; and under the Subtle accent the relationship inverted in every
appearance. A hue swap cannot carry this state, so a fill carries it. `canvas`
was added to gold's tested grounds in `TokenContrastMatrixTests` at the same
time — its absence is why 3.64:1 was never caught.

The border is a DELIBERATE reversal of the rule this section used to state.
It said: no border, because the mute button beside the door already says
"engaged" with a filled pill, and a second shape for the same idea would give
one row three vocabularies. Alec overruled it on 2026-09-04, knowing mute sits
6 pt away — "when clicked could we give it a black border with a gold fill?
make it just a bit bigger". The two engaged marks are drawn to stay legibly
apart: MUTE is a translucent NEUTRAL capsule (`engagedChrome` at 0.22, no
border, its glyph unchanged in size); the DOOR is an opaque GOLD rounded square
with a dark border and a larger, heavier glyph. Mute's radius is
`Radius.control` clamped by its own height, so it renders as a capsule; the
door's 7 pt on a 24 pt seat stays visibly square. The door's slot, and the 6 pt
gap to mute, are unchanged — the mark grew inside the seat the door already had.

Still no magenta: magenta is group identity (`partyRampDeep`), never the
wizard's territory — this migration moved the wizard's own reference light to
`Tokens.Color.ring` (blue), and `Tokens.swift`'s own comment says group
identity is "not drawn on this sheet" (see the Instrument Ground Rule under
Colors). No editor, no curve, and no tone control lives on the Mixer itself
(2026-08-22, amended 2026-09-03 and 2026-09-04); the door opens
`DeviceDetailViewController` where the real Equalizer control lives.
```

**Note for whoever applies it:** DESIGN.md's Don'ts include "Don't draw MUTE, or
any hover/selection wash, in gold". That rule is untouched — mute stays neutral.
The door is not a wash and not mute; gold there still means audio state (this
speaker's tone is shaped), which is the meaning the token already carries.

---

## 2. The failure chip stops using words

I could not find a section in DESIGN.md that states the failure pill's copy rule,
so this is an ADDITION rather than a replacement, and the coordinator should
place it wherever the FEED column is described (grep `FeedPillView`). If the
section does not exist, it can be dropped in under Signature Components:

```markdown
### Failure Pill (Mixer FEED column)
A `.failed` device's FEED pill carries the `exclamationmark.triangle` glyph in
`Tokens.Color.failure` and NO WORDS, on every row width. The failure's own
headline moves to the pill's tooltip and to the row's spoken accessibility
value, so it stays reachable by pointer and by screen reader.

Every one of the twelve headlines overflowed the 52 pt Bluetooth feed slot —
"Couldn't connect" needs 113.2 pt, and the triangle eats 19 pt before the first
character, so the pill clipped mid-word. Alec chose the consistent version on
2026-09-04 ("glyph always, words in the tooltip") rather than fitting words
where they fit, so an AirPlay row's wider slot draws the same bare glyph.

This retires the Bluetooth-UI rule that "Connected elsewhere" and "Not paired"
must read distinctly ON THE ROW. They still read apart — on the tooltip and in
the spoken value. The "Unavailable" rung is a separate one and keeps its word.
```
