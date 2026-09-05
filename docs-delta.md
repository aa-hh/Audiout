## from bf2-rowshape
# DESIGN.md replacement prose — row shape, the door's light gold, the failure chip

Five edits from `claude/bf2-rowshape` (2026-09-04). DESIGN.md is not edited
directly; paste these over the passages named.

---

## 1. Replace the second half of **Equalizer Door (Mixer, Mac-only)**

DESIGN.md lines 548-592 today describe a `Tokens.Color.gold` seat, a border
pinned under `.darkAqua`, and a door shaped deliberately unlike the mute pill.
All three changed. Replace from "the door draws a gold seat" through "the mark
grew inside the seat the door already had." with:

> the door draws a gold seat: a `Tokens.Color.goldText` fill 24 × 22pt,
> cornered at 6pt, with a 1pt `Tokens.Color.inkOnFill` border, and the
> `slider.horizontal.3` glyph on top in that same ink at 15pt semibold. At rest
> there is no seat at all — a `Tokens.Color.label2` glyph at the row's 13pt
> accessory size.
>
> The seat's size and corner are `PopoverColumnGrid.engagedSeatSize` and
> `engagedSeatCornerRadius`, shared with the engaged mute button 6pt trailing,
> because the two engaged marks are ONE shape. They were two until 2026-09-04 —
> this rounded square beside a capsule whose `Radius.control` clamped to half
> its own height — and the owner read them as two unrelated kinds of control. Hue,
> border and glyph tell them apart now: the door is gold, bordered and
> oversized; mute is a cool fill with a slashed speaker at the at-rest glyph
> size. Geometry no longer carries any of that.
>
> The 22pt height is measured against the mark inside it. The 15pt glyph draws
> 15.5 × 13.5pt of ink, so on the door's own 24pt column that leaves 4.5 / 4pt
> of gold each side, and 22pt gives the same above and below: the mark sits in
> even padding instead of overrunning a seat that has a 1pt border on it. The
> 6pt corner is deliberately not `Radius.control` (10) — 6 stays visibly short
> of the 11pt capsule point of a 22pt-high seat, so both engaged marks read as
> rounded squares rather than capsules. Each seat is its own view behind its
> button rather than a fill on the button's layer: an `.accessoryBar`
> `NSButton` frames larger than the alignment rect its constraints size (the
> door's 24 × 24 constraint pair measures 24.5 × 30.5), and the mute button
> carries no height constraint at all, so a fill on it changed size every time
> the glyph slashed between `speaker.wave.2.fill` and `speaker.slash.fill`.
>
> A fill carries this state because a hue swap measurably cannot. The mark was
> a bare gold glyph until 2026-09-04: `gold` runs 3.64:1 on `canvas` in light
> where the at-rest `label2` runs 5.97:1, so the "on" state read 39% dimmer
> than the "off" state; dark separated the two by 1.22:1; and under the Subtle
> accent the relationship inverted in every appearance.
>
> The fill is `goldText`, not `gold`, for a second measured reason. `gold` is
> authored as a fill on the DARK ground, where the seat clears every ground it
> can sit on comfortably (9.74:1 at rest, 7.73:1 on the gold live wash, 7.36:1
> on the neutral hover wash). In LIGHT the same value is a pale wash on paper:
> 3.64 / 3.20 / 2.91:1 — the hovered row is under the 3:1 non-text floor, and
> The owner read the engaged door as too hard to see in light before anyone measured
> it. `goldText` is the same accent voice deepened for light and carries
> `gold`'s own hexes in dark, so the dark door does not move a pixel and the
> light one goes to 5.66 / 4.96 / 4.52:1. Increase Contrast raises all six
> (light 8.14 / 6.96 / 6.49, dark 11.21 / 8.69 / 8.47).
>
> The border and the glyph are ONE ink — whatever `inkOnFill` resolves to in
> the row's own appearance, which is `#171104` in three cells and white in
> light plus Increase Contrast. The border used to be pinned under `.darkAqua`
> because that white flip is right for a glyph sitting ON a pale gold seat and
> wrong for the outline around it: a white outline on light paper is no
> outline. Deepening the seat retired the pin along with its reason — on the
> light-Increase-Contrast seat `#64480C` the pinned dark ink measures 2.21:1,
> under the 3:1 edge floor, where white measures 8.49:1. On the seat the ink
> now measures 3.18 / 8.49 / 10.18 / 11.72:1 across the four cells. That first
> number is the trade this deepening makes: the glyph inside the seat gives up
> 4.94:1 so the seat itself can clear its ground, which is the half the owner could
> not see. `CompositedTokenContrastTests` measures both halves in all four
> cells, and `increaseContrastDrops` is now EMPTY — the pinned border was its
> only entry.

Then keep the existing closing paragraph ("Still no magenta: …") unchanged.

---

## 2. Replace **The Muted-Hue Fence**'s consumer sentence

DESIGN.md line 271-278: "Its only consumer is the device row's engaged mute
button (`DeviceRowView.updateMuteTint()`), which fills the pill opaquely in
this hue …" and "`DeviceRowMutedStateTests` fails if a second call site appears
in `Sources/`." Both are now wrong — the Main Out row wears the same mute
language, landed on `claude/bf-mute`, and the fence test was failing on the
branch because of it. Replace with:

> Its consumers are the two engaged mute buttons — the device row's
> (`DeviceRowView.updateMuteTint()`) and the Main Out row's
> (`MainOutRowView.updateMuteTint()`), which wear one mute language — and each
> fills its seat opaquely in this hue with a `speaker.slash.fill` glyph knocked
> out of it in `panel`. It may not appear anywhere else.
> `DeviceRowMutedStateTests` fails if a THIRD call site appears in `Sources/`.

Also, wherever the section says "the pill", say "the seat": the mark is
`PopoverColumnGrid.engagedSeatSize` at `engagedSeatCornerRadius`, the same
rounded rectangle the Equalizer door draws, not a capsule.

---

## 3. Replace the shape sentence in **Mute Button (Mixer row)**

DESIGN.md lines 604-607 say the muted state draws "an OPAQUE
`Tokens.Color.muted` capsule at `mutePillCornerRadius` (`Radius.control`,
clamped by the pill's own height) with no border." That constant is gone.
Replace with:

> knocked out in `Tokens.Color.panel`, on an OPAQUE `Tokens.Color.muted` SEAT —
> `PopoverColumnGrid.engagedSeatSize` (24 × 22pt) at `engagedSeatCornerRadius`
> (6pt), with no border. That is the same rounded rectangle the Equalizer door
> 6pt leading draws, on its own view behind the button, because the two engaged
> marks on a row are one shape (see Equalizer Door). Nothing about the fill's
> measurements changed — the seat is the same hue at the same opacity, on a
> mark 24 × 22 instead of the button's own 19 × 14.

The section's last line — "`MainOutRowView` has not been given this treatment
and still draws the old …" — was already wrong before this branch (the Main Out
row took the same glyph and hue on `claude/bf-mute`) and is wronger now: it
draws the same seat too. Delete it, or replace with:

> `MainOutRowView` wears the same treatment: same two glyphs, same hue, same
> seat from the same two grid constants.

---

## 4. Add one paragraph to **Failure Pill (Mixer FEED column)**

After "…they still read apart, on the tooltip and in the spoken value.", add:

> Because it carries no words, the glyph pill CENTRES in the FEED column
> instead of sitting on the leading edge a left-aligned text pill needs. It sat
> there until 2026-09-04, which on an AirPlay row left the triangle at the
> column's left margin with most of a 140pt column empty beside it. `feedStack`
> holds two placements and exactly one is ever active: leading-aligned on
> `feedColumnLeadingFromTrailing` for pills that carry words, so a list of rows
> reads down one edge, and centred on the column's own centre
> (`trailingControlCenterFromTrailing`, or half of `btFeedSlotWidth` in on a
> sync-capable row) for the lone glyph. `FeedColumnTests` pins both, including
> the recovery: a row that stops failing puts its pills back on the leading
> edge.

---

## 5. `AudioutCore/Sources/AudioutSharedUI/AGENTS.md` — two folder rules are now wrong

Not edited here: three other tracks are working in this folder and an AGENTS.md
edit would collide. The coordinator should land these two line replacements.

Replace:

> - `Tokens.Color.muted` is fenced to the device row's engaged mute button; a second consumer fails a test.

with:

> - `Tokens.Color.muted` is fenced to the TWO engaged mute buttons (device row + Main Out); a third consumer fails a test.

Replace:

> - The row's Equalizer button is a DOOR plus one mark; the row edits and stores no tone.

with:

> - The row's Equalizer button is a DOOR plus one mark; the row edits and stores no tone.
> - Mute and the Equalizer door draw ONE shape — `PopoverColumnGrid.engagedSeatSize` at `engagedSeatCornerRadius`, on a seat view behind the button, never a fill on the button's own layer.

## from bf2-header
# DESIGN.md replacement prose — surface header strip (track bf2-header)

Two edits. DESIGN.md itself is untouched, per the track's instruction.

## 1. Replace the whole "### Surface Header Strip (popover shell, Mac-only)" section (DESIGN.md lines 496–533)

### Surface Header Strip (popover shell, Mac-only)
Two items: one capsule holding the three screen tabs (Mixer, Groups,
Settings), and Pin standing outside it. There is no Quit item on the strip.
The `NSToolbar` stays because it is the window's unified title-bar strip and
supplies the system material and the Reduce Transparency handling.

The three tabs are ONE surface. A single `NSToolbarItem` carries a
`SurfaceToolbarTabCapsule`: a 96 × 32pt pill (radius 16pt, half its height)
drawn once, with the three tabs as `NSButton`s wearing `SurfaceToolbarSeatCell`
layered over it, 3pt of padding on all four sides. Its size is derived from
three fixed 30 × 26pt tabs, so the selection moving can neither resize it nor
reflow anything inside it. The capsule fills with `engagedChrome` at 0.06 —
one rung below the hover weight, so a hovered tab still separates from the
surface it sits on — under a 1pt `containerEdge` hairline, both resolved at
draw time.

The current tab is marked by a soft rounded highlight INSIDE that capsule: the
same `Radius.control` (10pt) rectangle on the tab's own 30 × 26pt area, glyph
at 15pt. Ten on a 26pt-tall highlight leaves 6pt of straight edge top and
bottom, so it reads as a highlight sitting in the pill rather than a second
pill or a separate seat. Four states, three drawn weights, in `engagedChrome`
at the ladder the mixer's rows already use: rest draws nothing, hover takes
`PopoverColumnGrid.rowHoverWashAlpha` (0.10), the current screen and a pinned
Pin take `rowSelectionWashAlpha` (0.18), and a press takes `mutePillFillAlpha`
(0.22). The glyph's ink steps with the highlight rather than against it —
`label` engaged, `label2` idle — so the current screen is marked twice.
Neutral, never gold: gold means audio in the mix and a header highlight is
navigation.

Because the highlight is painted ON the capsule and never instead of it, it can
only add: in dark mode the current screen lands lighter than the capsule, with
no per-appearance branch anywhere in the drawing.

Pin is the standalone button beside the group, wearing the same highlight for
its pinned state. The macOS 26 toolbar grouping this follows puts such a button
outside the pill, optionally behind a thin divider; here a `.flexibleSpace`
already throws the full width of the strip between them, so no divider is
drawn — one would sit orphaned in the middle of that gap.

Both accessibility settings are read live on every draw. Increase Contrast
multiplies every weight, the capsule's included, by 1.5 capped at 1, so the
ladder keeps its spacing instead of collapsing. Reduce Transparency does not
touch the capsule's fill — raising it toward 0.10 would close the gap to the
hover rung — and swaps its edge for the heavier `rim` instead, since the strip's
material goes flat and the pill then has to carry itself.

The strip is drawn at all because AppKit draws a bordered `NSToolbarItem`'s
hover state as a circle and its selected state as a rounded square, two shapes
for two states of one control, and neither shape is settable. Taking the
drawing means taking the spoken state too: `toolbarSelectableItemIdentifiers`
is deliberately empty, the capsule reports itself as a radio group, and each
tab reports itself as a radio button through its own accessibility value and
`isAccessibilitySelected`. Four rejected versions are on the record: an
`NSToolbarItemGroup` segmented control whose divider moved with the selection;
custom-view tabs beside a bordered Pin, three bare glyphs next to two bordered
circles, which is why the conversion is all of the strip or none of it; an
authored fill with every cue inside `if #available(macOS 26.0, *)` while the
package deploys to 14.2, so macOS 14–25 showed no current screen at all, and
which cleared an unselected capsule that already sat at the same dark grey so
the user's own location rendered as the darkest thing on the strip; and three
`.space`-separated items each drawing its own seat, which read as three islands
rather than one control. Nothing in the capsule or the highlight is behind
`#available`.

Every tab is icon-only and fixed-width so the strip's width cannot change with
the selection, the appearance or the language — a widening strip is what would
sweep the tabs behind the overflow chevron, and primary navigation cannot live
behind a chevron. The Mixer tab draws `waveform`, not `slider.horizontal.3`:
the sliders glyph is the device row's equalizer door, and sliders are what an
equalizer looks like, so the equalizer keeps them.

## 2. One-line correction in the custom-drawn cell list (DESIGN.md lines 462–463)

Replace:

> `SurfaceToolbarSeatCell: NSButtonCell` (`SurfaceToolbarSeatButton.swift` —
> every item of the surface header strip)

with:

> `SurfaceToolbarSeatCell: NSButtonCell` (`SurfaceToolbarSeatButton.swift` —
> every clickable item of the surface header strip; the same file's
> `SurfaceToolbarTabCapsule` draws the pill they sit in)


## from bf3-btnames
# DESIGN.md addition — the Bluetooth row icon

DESIGN.md has no passage on how a Bluetooth row picks its glyph; lines 631-632
only say `Device.Kind.symbolName` avoids the `speaker.*` family for it. Add the
following where that row icon is described.

> A Bluetooth row's icon is decided in three steps, each falling through to the
> next rather than guessing, because a wrong glyph is worse than a generic one.
> First the NAME: a name carrying a product phrase — "AirPods Pro", "Powerbeats
> Pro", "Beats Studio Buds" — names one model, and the row draws that product's
> own SF Symbol. Phrases are matched with everything but letters and digits
> stripped and the most specific phrase checked first, because people rename
> their speakers: the pair this was written for is called "the owner's AirPods Pro
> #2", and a table that checked "AirPods" before "AirPods Pro" would draw the
> wrong product on every Pro. Only the product phrase is matched — Apple does
> not translate those, while the owner's own words around them may be any
> language.
>
> A product glyph is the one deliberate exception to the rule that Bluetooth
> rows stay visually distinct from the AirPlay kinds: it names a real device
> rather than a category, so it cannot be mistaken for one. Apple and Beats
> only, since SF Symbols draws no other manufacturer's headphones, and no entry
> may return a glyph an AirPlay kind already wears (which is why Beats Pill,
> whose best glyph would be the generic `hifispeaker.fill` cabinet, is
> deliberately absent). `DeviceBluetoothKindTests` fails on both counts.
>
> Second the DEVICE CLASS the pairing reports — headset, hands-free or
> headphones draw `headphones`, car audio draws `car.fill`. Third and last, the
> kind's own `radio.fill`, for a name that names no product and a class that is
> a speaker, unknown, or unreadable.
## from bf2-rowshape
# DESIGN.md replacement prose — row shape, the door's light gold, the failure chip

Five edits from `claude/bf2-rowshape` (2026-09-04). DESIGN.md is not edited
directly; paste these over the passages named.

---

## 1. Replace the second half of **Equalizer Door (Mixer, Mac-only)**

DESIGN.md lines 548-592 today describe a `Tokens.Color.gold` seat, a border
pinned under `.darkAqua`, and a door shaped deliberately unlike the mute pill.
All three changed. Replace from "the door draws a gold seat" through "the mark
grew inside the seat the door already had." with:

> the door draws a gold seat: a `Tokens.Color.goldText` fill 24 × 22pt,
> cornered at 6pt, with a 1pt `Tokens.Color.inkOnFill` border, and the
> `slider.horizontal.3` glyph on top in that same ink at 15pt semibold. At rest
> there is no seat at all — a `Tokens.Color.label2` glyph at the row's 13pt
> accessory size.
>
> The seat's size and corner are `PopoverColumnGrid.engagedSeatSize` and
> `engagedSeatCornerRadius`, shared with the engaged mute button 6pt trailing,
> because the two engaged marks are ONE shape. They were two until 2026-09-04 —
> this rounded square beside a capsule whose `Radius.control` clamped to half
> its own height — and the owner read them as two unrelated kinds of control. Hue,
> border and glyph tell them apart now: the door is gold, bordered and
> oversized; mute is a cool fill with a slashed speaker at the at-rest glyph
> size. Geometry no longer carries any of that.
>
> The 22pt height is measured against the mark inside it. The 15pt glyph draws
> 15.5 × 13.5pt of ink, so on the door's own 24pt column that leaves 4.5 / 4pt
> of gold each side, and 22pt gives the same above and below: the mark sits in
> even padding instead of overrunning a seat that has a 1pt border on it. The
> 6pt corner is deliberately not `Radius.control` (10) — 6 stays visibly short
> of the 11pt capsule point of a 22pt-high seat, so both engaged marks read as
> rounded squares rather than capsules. Each seat is its own view behind its
> button rather than a fill on the button's layer: an `.accessoryBar`
> `NSButton` frames larger than the alignment rect its constraints size (the
> door's 24 × 24 constraint pair measures 24.5 × 30.5), and the mute button
> carries no height constraint at all, so a fill on it changed size every time
> the glyph slashed between `speaker.wave.2.fill` and `speaker.slash.fill`.
>
> A fill carries this state because a hue swap measurably cannot. The mark was
> a bare gold glyph until 2026-09-04: `gold` runs 3.64:1 on `canvas` in light
> where the at-rest `label2` runs 5.97:1, so the "on" state read 39% dimmer
> than the "off" state; dark separated the two by 1.22:1; and under the Subtle
> accent the relationship inverted in every appearance.
>
> The fill is `goldText`, not `gold`, for a second measured reason. `gold` is
> authored as a fill on the DARK ground, where the seat clears every ground it
> can sit on comfortably (9.74:1 at rest, 7.73:1 on the gold live wash, 7.36:1
> on the neutral hover wash). In LIGHT the same value is a pale wash on paper:
> 3.64 / 3.20 / 2.91:1 — the hovered row is under the 3:1 non-text floor, and
> The owner read the engaged door as too hard to see in light before anyone measured
> it. `goldText` is the same accent voice deepened for light and carries
> `gold`'s own hexes in dark, so the dark door does not move a pixel and the
> light one goes to 5.66 / 4.96 / 4.52:1. Increase Contrast raises all six
> (light 8.14 / 6.96 / 6.49, dark 11.21 / 8.69 / 8.47).
>
> The border and the glyph are ONE ink — whatever `inkOnFill` resolves to in
> the row's own appearance, which is `#171104` in three cells and white in
> light plus Increase Contrast. The border used to be pinned under `.darkAqua`
> because that white flip is right for a glyph sitting ON a pale gold seat and
> wrong for the outline around it: a white outline on light paper is no
> outline. Deepening the seat retired the pin along with its reason — on the
> light-Increase-Contrast seat `#64480C` the pinned dark ink measures 2.21:1,
> under the 3:1 edge floor, where white measures 8.49:1. On the seat the ink
> now measures 3.18 / 8.49 / 10.18 / 11.72:1 across the four cells. That first
> number is the trade this deepening makes: the glyph inside the seat gives up
> 4.94:1 so the seat itself can clear its ground, which is the half the owner could
> not see. `CompositedTokenContrastTests` measures both halves in all four
> cells, and `increaseContrastDrops` is now EMPTY — the pinned border was its
> only entry.

Then keep the existing closing paragraph ("Still no magenta: …") unchanged.

---

## 2. Replace **The Muted-Hue Fence**'s consumer sentence

DESIGN.md line 271-278: "Its only consumer is the device row's engaged mute
button (`DeviceRowView.updateMuteTint()`), which fills the pill opaquely in
this hue …" and "`DeviceRowMutedStateTests` fails if a second call site appears
in `Sources/`." Both are now wrong — the Main Out row wears the same mute
language, landed on `claude/bf-mute`, and the fence test was failing on the
branch because of it. Replace with:

> Its consumers are the two engaged mute buttons — the device row's
> (`DeviceRowView.updateMuteTint()`) and the Main Out row's
> (`MainOutRowView.updateMuteTint()`), which wear one mute language — and each
> fills its seat opaquely in this hue with a `speaker.slash.fill` glyph knocked
> out of it in `panel`. It may not appear anywhere else.
> `DeviceRowMutedStateTests` fails if a THIRD call site appears in `Sources/`.

Also, wherever the section says "the pill", say "the seat": the mark is
`PopoverColumnGrid.engagedSeatSize` at `engagedSeatCornerRadius`, the same
rounded rectangle the Equalizer door draws, not a capsule.

---

## 3. Replace the shape sentence in **Mute Button (Mixer row)**

DESIGN.md lines 604-607 say the muted state draws "an OPAQUE
`Tokens.Color.muted` capsule at `mutePillCornerRadius` (`Radius.control`,
clamped by the pill's own height) with no border." That constant is gone.
Replace with:

> knocked out in `Tokens.Color.panel`, on an OPAQUE `Tokens.Color.muted` SEAT —
> `PopoverColumnGrid.engagedSeatSize` (24 × 22pt) at `engagedSeatCornerRadius`
> (6pt), with no border. That is the same rounded rectangle the Equalizer door
> 6pt leading draws, on its own view behind the button, because the two engaged
> marks on a row are one shape (see Equalizer Door). Nothing about the fill's
> measurements changed — the seat is the same hue at the same opacity, on a
> mark 24 × 22 instead of the button's own 19 × 14.

The section's last line — "`MainOutRowView` has not been given this treatment
and still draws the old …" — was already wrong before this branch (the Main Out
row took the same glyph and hue on `claude/bf-mute`) and is wronger now: it
draws the same seat too. Delete it, or replace with:

> `MainOutRowView` wears the same treatment: same two glyphs, same hue, same
> seat from the same two grid constants.

---

## 4. Add one paragraph to **Failure Pill (Mixer FEED column)**

After "…they still read apart, on the tooltip and in the spoken value.", add:

> Because it carries no words, the glyph pill CENTRES in the FEED column
> instead of sitting on the leading edge a left-aligned text pill needs. It sat
> there until 2026-09-04, which on an AirPlay row left the triangle at the
> column's left margin with most of a 140pt column empty beside it. `feedStack`
> holds two placements and exactly one is ever active: leading-aligned on
> `feedColumnLeadingFromTrailing` for pills that carry words, so a list of rows
> reads down one edge, and centred on the column's own centre
> (`trailingControlCenterFromTrailing`, or half of `btFeedSlotWidth` in on a
> sync-capable row) for the lone glyph. `FeedColumnTests` pins both, including
> the recovery: a row that stops failing puts its pills back on the leading
> edge.

---

## 5. `AudioutCore/Sources/AudioutSharedUI/AGENTS.md` — two folder rules are now wrong

Not edited here: three other tracks are working in this folder and an AGENTS.md
edit would collide. The coordinator should land these two line replacements.

Replace:

> - `Tokens.Color.muted` is fenced to the device row's engaged mute button; a second consumer fails a test.

with:

> - `Tokens.Color.muted` is fenced to the TWO engaged mute buttons (device row + Main Out); a third consumer fails a test.

Replace:

> - The row's Equalizer button is a DOOR plus one mark; the row edits and stores no tone.

with:

> - The row's Equalizer button is a DOOR plus one mark; the row edits and stores no tone.
> - Mute and the Equalizer door draw ONE shape — `PopoverColumnGrid.engagedSeatSize` at `engagedSeatCornerRadius`, on a seat view behind the button, never a fill on the button's own layer.

## from bf2-header
# DESIGN.md replacement prose — surface header strip (track bf2-header)

Two edits. DESIGN.md itself is untouched, per the track's instruction.

## 1. Replace the whole "### Surface Header Strip (popover shell, Mac-only)" section (DESIGN.md lines 496–533)

### Surface Header Strip (popover shell, Mac-only)
Two items: one capsule holding the three screen tabs (Mixer, Groups,
Settings), and Pin standing outside it. There is no Quit item on the strip.
The `NSToolbar` stays because it is the window's unified title-bar strip and
supplies the system material and the Reduce Transparency handling.

The three tabs are ONE surface. A single `NSToolbarItem` carries a
`SurfaceToolbarTabCapsule`: a 96 × 32pt pill (radius 16pt, half its height)
drawn once, with the three tabs as `NSButton`s wearing `SurfaceToolbarSeatCell`
layered over it, 3pt of padding on all four sides. Its size is derived from
three fixed 30 × 26pt tabs, so the selection moving can neither resize it nor
reflow anything inside it. The capsule fills with `engagedChrome` at 0.06 —
one rung below the hover weight, so a hovered tab still separates from the
surface it sits on — under a 1pt `containerEdge` hairline, both resolved at
draw time.

The current tab is marked by a soft rounded highlight INSIDE that capsule: the
same `Radius.control` (10pt) rectangle on the tab's own 30 × 26pt area, glyph
at 15pt. Ten on a 26pt-tall highlight leaves 6pt of straight edge top and
bottom, so it reads as a highlight sitting in the pill rather than a second
pill or a separate seat. Four states, three drawn weights, in `engagedChrome`
at the ladder the mixer's rows already use: rest draws nothing, hover takes
`PopoverColumnGrid.rowHoverWashAlpha` (0.10), the current screen and a pinned
Pin take `rowSelectionWashAlpha` (0.18), and a press takes `mutePillFillAlpha`
(0.22). The glyph's ink steps with the highlight rather than against it —
`label` engaged, `label2` idle — so the current screen is marked twice.
Neutral, never gold: gold means audio in the mix and a header highlight is
navigation.

Because the highlight is painted ON the capsule and never instead of it, it can
only add: in dark mode the current screen lands lighter than the capsule, with
no per-appearance branch anywhere in the drawing.

Pin is the standalone button beside the group, wearing the same highlight for
its pinned state. The macOS 26 toolbar grouping this follows puts such a button
outside the pill, optionally behind a thin divider; here a `.flexibleSpace`
already throws the full width of the strip between them, so no divider is
drawn — one would sit orphaned in the middle of that gap.

Both accessibility settings are read live on every draw. Increase Contrast
multiplies every weight, the capsule's included, by 1.5 capped at 1, so the
ladder keeps its spacing instead of collapsing. Reduce Transparency does not
touch the capsule's fill — raising it toward 0.10 would close the gap to the
hover rung — and swaps its edge for the heavier `rim` instead, since the strip's
material goes flat and the pill then has to carry itself.

The strip is drawn at all because AppKit draws a bordered `NSToolbarItem`'s
hover state as a circle and its selected state as a rounded square, two shapes
for two states of one control, and neither shape is settable. Taking the
drawing means taking the spoken state too: `toolbarSelectableItemIdentifiers`
is deliberately empty, the capsule reports itself as a radio group, and each
tab reports itself as a radio button through its own accessibility value and
`isAccessibilitySelected`. Four rejected versions are on the record: an
`NSToolbarItemGroup` segmented control whose divider moved with the selection;
custom-view tabs beside a bordered Pin, three bare glyphs next to two bordered
circles, which is why the conversion is all of the strip or none of it; an
authored fill with every cue inside `if #available(macOS 26.0, *)` while the
package deploys to 14.2, so macOS 14–25 showed no current screen at all, and
which cleared an unselected capsule that already sat at the same dark grey so
the user's own location rendered as the darkest thing on the strip; and three
`.space`-separated items each drawing its own seat, which read as three islands
rather than one control. Nothing in the capsule or the highlight is behind
`#available`.

Every tab is icon-only and fixed-width so the strip's width cannot change with
the selection, the appearance or the language — a widening strip is what would
sweep the tabs behind the overflow chevron, and primary navigation cannot live
behind a chevron. The Mixer tab draws `waveform`, not `slider.horizontal.3`:
the sliders glyph is the device row's equalizer door, and sliders are what an
equalizer looks like, so the equalizer keeps them.

## 2. One-line correction in the custom-drawn cell list (DESIGN.md lines 462–463)

Replace:

> `SurfaceToolbarSeatCell: NSButtonCell` (`SurfaceToolbarSeatButton.swift` —
> every item of the surface header strip)

with:

> `SurfaceToolbarSeatCell: NSButtonCell` (`SurfaceToolbarSeatButton.swift` —
> every clickable item of the surface header strip; the same file's
> `SurfaceToolbarTabCapsule` draws the pill they sit in)


---

## from bf3-tabnames
# DESIGN.md replacement prose — the current tab shows its name

One edit from `claude/bf3-tabnames` (2026-09-04). DESIGN.md is not edited
directly; paste this over the passage named.

---

## Replace the last paragraph of **Surface Header Strip (popover shell, Mac-only)**

DESIGN.md's Surface Header Strip section ends with "The seats are icon-only and
fixed-width so the strip's width cannot change with the selection, the
appearance or the language — a widening strip is what would sweep the tabs
behind the overflow chevron, and primary navigation cannot live behind a
chevron." That is no longer what the strip does. Replace that paragraph with:

> The CURRENT tab shows its name beside its glyph, at 11pt medium
> (`Tokens.Font.captionMedium`) in the same `label` ink the engaged glyph
> takes; the other two are icon-only. The name is revealed by the seat itself
> growing to the right of the glyph — the glyph keeps the leading 30pt slot it
> had while collapsed, so it never slides — and the capsule around the three
> tabs widens by exactly that one name. Pin does not move: a `.flexibleSpace`
> holds the full width of the strip between them, and the capsule spends part
> of it.
>
> Names were on all three tabs once and were removed on 2026-09-03, because
> three translated labels widened the strip until AppKit swept the tabs into
> the overflow menu and primary navigation cannot live behind a chevron. Two
> rules make that impossible rather than unlikely. Only the selected tab is
> ever open, so the strip carries ONE name however many words a language needs
> for the other two. And that name is clamped to
> `SurfaceToolbarSeat.maxNameWidth` (120pt) and truncates with an ellipsis past
> it, so the widest the strip can be in any language is 226pt of capsule plus
> 30pt of Pin, against the fixed 653pt surface. For scale, "Settings" — the
> widest of the three English names — measures 49pt.
>
> Hover does not open a name. It stays what it was — the same rounded highlight
> at the weaker weight — because a strip that reshapes as the pointer crosses
> it moves the two tabs you might be reaching for. Nor does the name collapse
> again after a moment: it is a label for where you are, not a reward for
> clicking, so it stays for as long as that screen does, and the header is
> never nameless.
>
> The reveal is motion with a job: the seat's own width is the one animated
> value, at `Tokens.Motion.collapseRevealDuration` (0.15s) on `FoldAnimator`,
> the same clock and the same length every card body and inserted row in the
> app opens at. Reduce Motion is answered where that driver already answers it
> — the width settles synchronously, so the name is simply there, with no
> frame of travel and nothing left moving.
>
> The name is drawn, but it is not spoken twice: it is the same string the tab
> already reports as its accessibility label, and it is excluded from the
> accessibility tree, so the radio button's spoken name, value and selection
> are exactly what they were when the tabs were icon-only.
## from bf2-rowshape
# DESIGN.md replacement prose — row shape, the door's light gold, the failure chip

Five edits from `claude/bf2-rowshape` (2026-09-04). DESIGN.md is not edited
directly; paste these over the passages named.

---

## 1. Replace the second half of **Equalizer Door (Mixer, Mac-only)**

DESIGN.md lines 548-592 today describe a `Tokens.Color.gold` seat, a border
pinned under `.darkAqua`, and a door shaped deliberately unlike the mute pill.
All three changed. Replace from "the door draws a gold seat" through "the mark
grew inside the seat the door already had." with:

> the door draws a gold seat: a `Tokens.Color.goldText` fill 24 × 22pt,
> cornered at 6pt, with a 1pt `Tokens.Color.inkOnFill` border, and the
> `slider.horizontal.3` glyph on top in that same ink at 15pt semibold. At rest
> there is no seat at all — a `Tokens.Color.label2` glyph at the row's 13pt
> accessory size.
>
> The seat's size and corner are `PopoverColumnGrid.engagedSeatSize` and
> `engagedSeatCornerRadius`, shared with the engaged mute button 6pt trailing,
> because the two engaged marks are ONE shape. They were two until 2026-09-04 —
> this rounded square beside a capsule whose `Radius.control` clamped to half
> its own height — and the owner read them as two unrelated kinds of control. Hue,
> border and glyph tell them apart now: the door is gold, bordered and
> oversized; mute is a cool fill with a slashed speaker at the at-rest glyph
> size. Geometry no longer carries any of that.
>
> The 22pt height is measured against the mark inside it. The 15pt glyph draws
> 15.5 × 13.5pt of ink, so on the door's own 24pt column that leaves 4.5 / 4pt
> of gold each side, and 22pt gives the same above and below: the mark sits in
> even padding instead of overrunning a seat that has a 1pt border on it. The
> 6pt corner is deliberately not `Radius.control` (10) — 6 stays visibly short
> of the 11pt capsule point of a 22pt-high seat, so both engaged marks read as
> rounded squares rather than capsules. Each seat is its own view behind its
> button rather than a fill on the button's layer: an `.accessoryBar`
> `NSButton` frames larger than the alignment rect its constraints size (the
> door's 24 × 24 constraint pair measures 24.5 × 30.5), and the mute button
> carries no height constraint at all, so a fill on it changed size every time
> the glyph slashed between `speaker.wave.2.fill` and `speaker.slash.fill`.
>
> A fill carries this state because a hue swap measurably cannot. The mark was
> a bare gold glyph until 2026-09-04: `gold` runs 3.64:1 on `canvas` in light
> where the at-rest `label2` runs 5.97:1, so the "on" state read 39% dimmer
> than the "off" state; dark separated the two by 1.22:1; and under the Subtle
> accent the relationship inverted in every appearance.
>
> The fill is `goldText`, not `gold`, for a second measured reason. `gold` is
> authored as a fill on the DARK ground, where the seat clears every ground it
> can sit on comfortably (9.74:1 at rest, 7.73:1 on the gold live wash, 7.36:1
> on the neutral hover wash). In LIGHT the same value is a pale wash on paper:
> 3.64 / 3.20 / 2.91:1 — the hovered row is under the 3:1 non-text floor, and
> The owner read the engaged door as too hard to see in light before anyone measured
> it. `goldText` is the same accent voice deepened for light and carries
> `gold`'s own hexes in dark, so the dark door does not move a pixel and the
> light one goes to 5.66 / 4.96 / 4.52:1. Increase Contrast raises all six
> (light 8.14 / 6.96 / 6.49, dark 11.21 / 8.69 / 8.47).
>
> The border and the glyph are ONE ink — whatever `inkOnFill` resolves to in
> the row's own appearance, which is `#171104` in three cells and white in
> light plus Increase Contrast. The border used to be pinned under `.darkAqua`
> because that white flip is right for a glyph sitting ON a pale gold seat and
> wrong for the outline around it: a white outline on light paper is no
> outline. Deepening the seat retired the pin along with its reason — on the
> light-Increase-Contrast seat `#64480C` the pinned dark ink measures 2.21:1,
> under the 3:1 edge floor, where white measures 8.49:1. On the seat the ink
> now measures 3.18 / 8.49 / 10.18 / 11.72:1 across the four cells. That first
> number is the trade this deepening makes: the glyph inside the seat gives up
> 4.94:1 so the seat itself can clear its ground, which is the half the owner could
> not see. `CompositedTokenContrastTests` measures both halves in all four
> cells, and `increaseContrastDrops` is now EMPTY — the pinned border was its
> only entry.

Then keep the existing closing paragraph ("Still no magenta: …") unchanged.

---

## 2. Replace **The Muted-Hue Fence**'s consumer sentence

DESIGN.md line 271-278: "Its only consumer is the device row's engaged mute
button (`DeviceRowView.updateMuteTint()`), which fills the pill opaquely in
this hue …" and "`DeviceRowMutedStateTests` fails if a second call site appears
in `Sources/`." Both are now wrong — the Main Out row wears the same mute
language, landed on `claude/bf-mute`, and the fence test was failing on the
branch because of it. Replace with:

> Its consumers are the two engaged mute buttons — the device row's
> (`DeviceRowView.updateMuteTint()`) and the Main Out row's
> (`MainOutRowView.updateMuteTint()`), which wear one mute language — and each
> fills its seat opaquely in this hue with a `speaker.slash.fill` glyph knocked
> out of it in `panel`. It may not appear anywhere else.
> `DeviceRowMutedStateTests` fails if a THIRD call site appears in `Sources/`.

Also, wherever the section says "the pill", say "the seat": the mark is
`PopoverColumnGrid.engagedSeatSize` at `engagedSeatCornerRadius`, the same
rounded rectangle the Equalizer door draws, not a capsule.

---

## 3. Replace the shape sentence in **Mute Button (Mixer row)**

DESIGN.md lines 604-607 say the muted state draws "an OPAQUE
`Tokens.Color.muted` capsule at `mutePillCornerRadius` (`Radius.control`,
clamped by the pill's own height) with no border." That constant is gone.
Replace with:

> knocked out in `Tokens.Color.panel`, on an OPAQUE `Tokens.Color.muted` SEAT —
> `PopoverColumnGrid.engagedSeatSize` (24 × 22pt) at `engagedSeatCornerRadius`
> (6pt), with no border. That is the same rounded rectangle the Equalizer door
> 6pt leading draws, on its own view behind the button, because the two engaged
> marks on a row are one shape (see Equalizer Door). Nothing about the fill's
> measurements changed — the seat is the same hue at the same opacity, on a
> mark 24 × 22 instead of the button's own 19 × 14.

The section's last line — "`MainOutRowView` has not been given this treatment
and still draws the old …" — was already wrong before this branch (the Main Out
row took the same glyph and hue on `claude/bf-mute`) and is wronger now: it
draws the same seat too. Delete it, or replace with:

> `MainOutRowView` wears the same treatment: same two glyphs, same hue, same
> seat from the same two grid constants.

---

## 4. Add one paragraph to **Failure Pill (Mixer FEED column)**

After "…they still read apart, on the tooltip and in the spoken value.", add:

> Because it carries no words, the glyph pill CENTRES in the FEED column
> instead of sitting on the leading edge a left-aligned text pill needs. It sat
> there until 2026-09-04, which on an AirPlay row left the triangle at the
> column's left margin with most of a 140pt column empty beside it. `feedStack`
> holds two placements and exactly one is ever active: leading-aligned on
> `feedColumnLeadingFromTrailing` for pills that carry words, so a list of rows
> reads down one edge, and centred on the column's own centre
> (`trailingControlCenterFromTrailing`, or half of `btFeedSlotWidth` in on a
> sync-capable row) for the lone glyph. `FeedColumnTests` pins both, including
> the recovery: a row that stops failing puts its pills back on the leading
> edge.

---

## 5. `AudioutCore/Sources/AudioutSharedUI/AGENTS.md` — two folder rules are now wrong

Not edited here: three other tracks are working in this folder and an AGENTS.md
edit would collide. The coordinator should land these two line replacements.

Replace:

> - `Tokens.Color.muted` is fenced to the device row's engaged mute button; a second consumer fails a test.

with:

> - `Tokens.Color.muted` is fenced to the TWO engaged mute buttons (device row + Main Out); a third consumer fails a test.

Replace:

> - The row's Equalizer button is a DOOR plus one mark; the row edits and stores no tone.

with:

> - The row's Equalizer button is a DOOR plus one mark; the row edits and stores no tone.
> - Mute and the Equalizer door draw ONE shape — `PopoverColumnGrid.engagedSeatSize` at `engagedSeatCornerRadius`, on a seat view behind the button, never a fill on the button's own layer.

## from bf2-header
# DESIGN.md replacement prose — surface header strip (track bf2-header)

Two edits. DESIGN.md itself is untouched, per the track's instruction.

## 1. Replace the whole "### Surface Header Strip (popover shell, Mac-only)" section (DESIGN.md lines 496–533)

### Surface Header Strip (popover shell, Mac-only)
Two items: one capsule holding the three screen tabs (Mixer, Groups,
Settings), and Pin standing outside it. There is no Quit item on the strip.
The `NSToolbar` stays because it is the window's unified title-bar strip and
supplies the system material and the Reduce Transparency handling.

The three tabs are ONE surface. A single `NSToolbarItem` carries a
`SurfaceToolbarTabCapsule`: a 96 × 32pt pill (radius 16pt, half its height)
drawn once, with the three tabs as `NSButton`s wearing `SurfaceToolbarSeatCell`
layered over it, 3pt of padding on all four sides. Its size is derived from
three fixed 30 × 26pt tabs, so the selection moving can neither resize it nor
reflow anything inside it. The capsule fills with `engagedChrome` at 0.06 —
one rung below the hover weight, so a hovered tab still separates from the
surface it sits on — under a 1pt `containerEdge` hairline, both resolved at
draw time.

The current tab is marked by a soft rounded highlight INSIDE that capsule: the
same `Radius.control` (10pt) rectangle on the tab's own 30 × 26pt area, glyph
at 15pt. Ten on a 26pt-tall highlight leaves 6pt of straight edge top and
bottom, so it reads as a highlight sitting in the pill rather than a second
pill or a separate seat. Four states, three drawn weights, in `engagedChrome`
at the ladder the mixer's rows already use: rest draws nothing, hover takes
`PopoverColumnGrid.rowHoverWashAlpha` (0.10), the current screen and a pinned
Pin take `rowSelectionWashAlpha` (0.18), and a press takes `mutePillFillAlpha`
(0.22). The glyph's ink steps with the highlight rather than against it —
`label` engaged, `label2` idle — so the current screen is marked twice.
Neutral, never gold: gold means audio in the mix and a header highlight is
navigation.

Because the highlight is painted ON the capsule and never instead of it, it can
only add: in dark mode the current screen lands lighter than the capsule, with
no per-appearance branch anywhere in the drawing.

Pin is the standalone button beside the group, wearing the same highlight for
its pinned state. The macOS 26 toolbar grouping this follows puts such a button
outside the pill, optionally behind a thin divider; here a `.flexibleSpace`
already throws the full width of the strip between them, so no divider is
drawn — one would sit orphaned in the middle of that gap.

Both accessibility settings are read live on every draw. Increase Contrast
multiplies every weight, the capsule's included, by 1.5 capped at 1, so the
ladder keeps its spacing instead of collapsing. Reduce Transparency does not
touch the capsule's fill — raising it toward 0.10 would close the gap to the
hover rung — and swaps its edge for the heavier `rim` instead, since the strip's
material goes flat and the pill then has to carry itself.

The strip is drawn at all because AppKit draws a bordered `NSToolbarItem`'s
hover state as a circle and its selected state as a rounded square, two shapes
for two states of one control, and neither shape is settable. Taking the
drawing means taking the spoken state too: `toolbarSelectableItemIdentifiers`
is deliberately empty, the capsule reports itself as a radio group, and each
tab reports itself as a radio button through its own accessibility value and
`isAccessibilitySelected`. Four rejected versions are on the record: an
`NSToolbarItemGroup` segmented control whose divider moved with the selection;
custom-view tabs beside a bordered Pin, three bare glyphs next to two bordered
circles, which is why the conversion is all of the strip or none of it; an
authored fill with every cue inside `if #available(macOS 26.0, *)` while the
package deploys to 14.2, so macOS 14–25 showed no current screen at all, and
which cleared an unselected capsule that already sat at the same dark grey so
the user's own location rendered as the darkest thing on the strip; and three
`.space`-separated items each drawing its own seat, which read as three islands
rather than one control. Nothing in the capsule or the highlight is behind
`#available`.

Every tab is icon-only and fixed-width so the strip's width cannot change with
the selection, the appearance or the language — a widening strip is what would
sweep the tabs behind the overflow chevron, and primary navigation cannot live
behind a chevron. The Mixer tab draws `waveform`, not `slider.horizontal.3`:
the sliders glyph is the device row's equalizer door, and sliders are what an
equalizer looks like, so the equalizer keeps them.

## 2. One-line correction in the custom-drawn cell list (DESIGN.md lines 462–463)

Replace:

> `SurfaceToolbarSeatCell: NSButtonCell` (`SurfaceToolbarSeatButton.swift` —
> every item of the surface header strip)

with:

> `SurfaceToolbarSeatCell: NSButtonCell` (`SurfaceToolbarSeatButton.swift` —
> every clickable item of the surface header strip; the same file's
> `SurfaceToolbarTabCapsule` draws the pill they sit in)


---

## from bf3-symbols


Written here, not into DESIGN.md, per the work order. Three sections: the new
token, the retired drawn seat, and asset catalogues as a new kind of resource
in this package.

**One part of this is NOT true of the shipped build yet.** The engaged
"coloured square, white marks" split does not render, because the four SVG
templates compile to single-layer monochrome symbols. See "Blocked" at the
bottom before adopting any of this prose.

## The engaged accessory fill

A device row carries two accessory controls: mute, and the Equalizer door 6 pt
leading of it. Each has an at-rest state and an engaged state, and both wear
the same shape in the engaged state — one rounded square, in two colours. Hue
alone says which control it is.

`Tokens.Color.muted` — `#4A50C7` — means "this output is deliberately silent".
`Tokens.Color.equalizer` — `#227950` — means "this speaker's curve is not
flat". Both are fenced to their one job: `muted` to the two engaged mute
buttons (the device row's and Main Out's), `equalizer` to the device row's
engaged Equalizer door. A second consumer fails a test.

Both are ONE value in light and dark, which almost nothing else here is. The
rule is the owner's (2026-09-04): an engaged control wears the same fill in both
appearances, so a muted row looks like a muted row wherever you meet it.
Neither carries an Increase Contrast variant, and that follows from the single
value rather than being a separate decision — one value sits between two
opposite grounds, so darkening it lifts the light row and drops the dark one
while lightening does the reverse. Every candidate lowers one side, and the
contrast suites assert that Increase Contrast never lowers a ratio.

`equalizer` replaces `goldText` on the door. Gold means "audio is flowing here"
everywhere else in the app, including the live wash this same row draws behind
the door, so one hue was carrying two ideas. Green was unspoken for. `#227950`
was chosen over six other candidates on separation: 85° of hue off `muted`,
which is the control 6 pt to its right, and 11° off `permissionUsageStats`,
which is fenced to onboarding and never shares a screen with a device row.

## The drawn seat is retired

Until 2026-09-04 each engaged mark was a rounded rectangle painted on its own
`NSView` behind an ordinary system glyph — `PopoverColumnGrid.engagedSeatSize`
at `engagedSeatCornerRadius`, plus a 1 pt border on the door's. Two views, two
layers, two appearance re-stamps, and a size that had to be pinned by hand
because an `.accessoryBar` `NSButton` frames larger than the alignment rect its
constraints size, and a button with no height constraint frames to whatever
glyph is currently mounted.

The enclosing square belongs to the symbol now. `engagedSeatSize` and
`engagedSeatCornerRadius` are gone with the views that drew them, and the
controls' geometry is one shared point size (`RowAccessorySymbol.pointSize`)
inside the 24 pt columns the row already reserved. The 6 pt gap between the two
controls is untouched, because neither button's frame moved.

## Asset catalogues in this package

`AudioutCore/Sources/AudioutSharedUI/Resources/Symbols.xcassets` is the
package's first asset catalogue. It holds four `.symbolset`s, each one SF
Symbols template SVG exported from the SF Symbols app.

Two things about it are load-bearing and neither is obvious:

**SwiftPM does not compile asset catalogues.** Declaring one as `.process(...)`
in `Package.swift` copies the `.xcassets` DIRECTORY into the resource bundle
verbatim. No `actool` runs, no `Assets.car` is produced, and
`Bundle.module.image(forResource:)` returns nil for every symbol in it — with
no build error and no crash, just a control that draws nothing. Xcode's own
build system does run `actool`, which is why the same manifest looks correct
there. The compile is therefore declared by a build tool plugin,
`AudioutCore/Plugins/CompileAssetCatalog`, which emits one `actool` command per
catalogue in the target.

**A custom symbol is not a system symbol.** `NSImage(systemSymbolName:)` only
ever finds Apple's. Ours are reached through `image(forResource:)` on
`Bundle.module`, which is why the loader lives in `AudioutSharedUI` — the
target that owns the resource — and why `RowAccessorySymbolTests` asserts all
four resolve. That test exists because the failure mode is a blank button
rather than a red build.

## Blocked: the two-colour engaged mark

The intended engaged treatment is the enclosing square in `muted` /
`equalizer` with the marks inside it in white, drawn by palette rendering. It
does not work with the four SVGs in `dev/symbols/`.

All four compile to SINGLE-LAYER MONOCHROME symbols: every rendition in the
built `Assets.car` reports `"ColorModel": "Monochrome"`, and a two-colour
palette paints the whole mark in the second colour (a three-colour palette
paints it all in the third). The same palette code splits an Apple two-layer
symbol correctly, so the configuration is right and the assets are the
limitation — `speaker.slash.square.fill.svg`'s `LayerTree` has an EMPTY layer 0
with the whole glyph in layer 1, and the slider pair carries no `LayerTree` at
all.

Re-exporting the four symbols with the enclosure on its own layer would make
this prose true as written. Until then the engaged square can only be one
colour, with the marks punched through it as transparency.

---

## from bf4-transitions
# DESIGN.md addition — the screen swap

One addition from `claude/bf4-transitions` (2026-09-05). DESIGN.md has no
passage on what happens between two surface screens; add this near the Surface
Header Strip section, which describes the control that triggers it.

> ### Screen Swap (surface, Mac-only)
>
> Clicking a tab dissolves the incoming screen in: its opacity travels 0 → 1 at
> `Tokens.Motion.collapseRevealDuration` (0.15s) on `FoldAnimator`, the same
> clock and the same length every card body, inserted row and tab name in the
> app runs on. Nothing else moves. There is no slide, no push and no direction,
> because the three screens are siblings rather than a stack — a horizontal
> travel would claim an order they do not have. Reduce Motion is answered where
> that driver already answers it: the opacity settles synchronously, so the new
> screen is simply there.
>
> The window FRAME does not participate and cannot. It is fixed for the whole
> open session, and the dissolve actually defends that: showing a fade makes the
> window lay out, and a freshly mounted split view takes any layout pass as its
> chance to widen the window toward its own minimum (probed at a one-point widen
> on the Settings mount, and at 560 → 707pt in the earlier mid-mount case the
> chrome inset is written against). So every tick of the dissolve puts the
> session frame back. The value never changes, so this is not a second clock —
> it is the one clock holding the frame still while the content changes behind
> it.
>
> Motion is the second half of the answer, and the smaller half. The owner's report
> was that Groups and the Equalizer door "load very juddery" (2026-09-04), and
> measured headless against the seven-speaker demo fleet the first Groups
> selection blocked the main thread for 56 ms — 50 of them constructing
> `MixerWindowController` and its panes — where every later visit cost 8 ms; the
> Equalizer door paid a further 31 ms for the device page. Three to four dropped
> frames inside one click is not something a transition can cover, so the screens
> are now built a turn after the surface opens, behind the launch hold, and the
> click only mounts what already exists. First Groups selection measures 17 ms
> after that, and the Equalizer door 38 ms against 86.

---

## from bf4-capsule

# DESIGN.md replacement prose — the header strip's two shapes and its one height

One edit from `claude/bf4-capsule` (2026-09-05), from the owner's live-build
review. DESIGN.md is not edited directly; paste this over the passage named.

Note for whoever lands this: the surrounding **Surface Header Strip** section
also still describes the tabs as fixed-width and icon-only, which a sibling
track changed when it added the name reveal. Only the shape-and-size paragraph
is mine; leave the rest to that track's own delta.

---

## Replace the second paragraph of **Surface Header Strip (popover shell, Mac-only)**

DESIGN.md lines 504-515 today describe one rounded rectangle at
`Radius.control` (10pt) on a fixed 30 × 26pt seat, shared by all four items.
The radius, both sizes and the one-shape claim all changed. Replace from
"One shape carries every state" through "a header seat is navigation." with:

> One shape carries every STATE, and each kind of item has its own: every seat
> is cut at HALF ITS OWN HEIGHT (`SurfaceToolbarSeat.seatCornerRadius`). Pin is
> square at 34 × 34pt, so it draws a true CIRCLE; a screen tab is 30 × 28pt
> collapsed and wider once its name opens, so the same rule draws a stadium.
> Hover, selection and press stay one outline at three weights on both.
>
> Two things are derived from that and must never be retyped. The capsule is
> exactly `pinDiameter` tall, so the pill and Pin stand at the same 34pt — they
> were 32 and 26 until 2026-09-05, and the owner read the mismatch immediately. And
> a tab's height is the capsule minus its 3pt padding, which puts the tab's
> radius at `capsuleCornerRadius - capsulePadding` (17 − 3 = 14): the arithmetic
> concentric rounded rectangles require. Cutting the highlight at 10pt inside a
> 17pt pill left a gap that measured 3pt at the tab's mid-height and 6pt into
> its corner, and against the pill's rounded end that unevenness is what the owner
> rejected as "the highlight does not perfectly conform with the border".
>
> Four states, three drawn weights, in `engagedChrome` at the ladder the mixer's
> rows already use: rest draws no seat at all, hover takes
> `PopoverColumnGrid.rowHoverWashAlpha` (0.10), the current screen and a pinned
> Pin take `rowSelectionWashAlpha` (0.18), and a press takes `mutePillFillAlpha`
> (0.22). Increase Contrast multiplies all three by 1.5, capped at 1, read live
> at draw time. The glyph is 15pt and its ink steps with the seat rather than
> against it — `label` engaged, `label2` idle — so the current screen is marked
> twice. Neutral, never gold: gold means audio in the mix and a header seat is
> navigation.

### One line to amend in the paragraph after it

That paragraph opens "The seat exists because AppKit draws a bordered
`NSToolbarItem`'s hover state as a circle and its selected state as a rounded
square, two shapes for two states of one control". That reason still stands and
should stay — but it is about two shapes for two STATES, and since 2026-09-05
the strip deliberately does draw two shapes for its two kinds of ITEM. Add
after that sentence:

> Two shapes for two states of one control is still the defect; two shapes for
> two kinds of item is the intent, and one rule produces both.

---

## from bf5-ring
## The Main Audio resting ring covers the mixed set

Reported live 2026-09-05: "the circle is missing around the main audio". The
ring's own drawing is correct in every state that specifies one — the host was
handing it `.off` with `restingArmed` false.

The resting ring's condition is now **the local device is AMONG the Main Audio
target's members**, not "every member is the local device". The mixed set
{This Mac, an AirPlay speaker} is reachable — `setDeviceSelected` auto-swaps
the Mac out only when it is the sole member — and the Mac keeps rendering
audio in it, so a speaker sitting selected-but-not-connected beside the Mac
used to blank the ring and leave the rail curving up into nothing. A member
that does connect still wins: `mainOutConnectionState` reports `.connected`
and the connected form overrides the resting one.
