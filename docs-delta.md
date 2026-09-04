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
