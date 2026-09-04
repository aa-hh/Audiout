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
> its own height — and Alec read them as two unrelated kinds of control. Hue,
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
> Alec read the engaged door as too hard to see in light before anyone measured
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
> 4.94:1 so the seat itself can clear its ground, which is the half Alec could
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

