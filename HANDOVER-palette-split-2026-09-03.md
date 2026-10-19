# HANDOVER — the Mac/iPhone palette split is deliberate, not drift

Written 2026-09-03.

## 1. The decision this file records

**The Mac does not change.** Alec, 2026-09-03: the two apps' chassis
palettes diverge on purpose, and this file is the record of that decision.
If you were sent here because someone noticed the greys don't match between
this app and the iPhone companion, that is expected. Do not "fix" it.

The iPhone companion's own design doc (`DESIGN.md` in the `audiout-remote`
repo) used to say the Mac would follow its restyle. That line was corrected
the same day this file was written, specifically so it stops pointing a
future session at this exact mistake.

## 2. What actually split

The iPhone companion (`audiout-remote`,
`AudioutRemote/UI/Shared/WarmSignal.swift`) took a cool-neutral restyle on
2026-08-30, in both light and dark. This app's tokens
(`AudioutCore/Sources/AudioutSharedUI/Tokens.swift`) did not move, in either
appearance.

| token         | Mac (light / dark)        | iPhone (light / dark)          |
|---------------|----------------------------|---------------------------------|
| canvas        | `#FBFBF9` / `#16130F`     | `#FAFAFB` / `#0A0A0C`          |
| canvasHi      | `#FBFBF9` / `#1B1712`     | (no such token)                 |
| panel         | `#FBFBF9` / `#1D1915`     | `#FAFAFB` / `#15171A`          |
| raised        | `#F2F0EA` / `#241F1A`     | `#FAFAFB` / `#1F232A`          |
| well          | `#E2DFD3` / `#100D0A`     | `#E9EAEC` / `#050507`          |
| hairline      | `#D0CDC3` / `#3A332B`     | `#CBCED4` / `#2A2E33`          |
| containerEdge | `#C4C0B4` / `#3A332B`     | `#AEB3BB` / `#3D4247`          |
| meterTrack    | `#CBBEA1` / `#4E463A`     | `#C6C9CE` / `#464C55` (iPhone calls it `meter`) |

Hue moved, not lightness — this app's greys lean yellow, the iPhone's lean
blue, at nearly the same brightness. On the light canvases the gap is
invisible: about 1.6 Lab units between `#FBFBF9` and `#FAFAFB`. On the edges
it's plain: about 8.7 between the two hairlines, about 13.6 between the
iPhone's `containerEdge` `#AEB3BB` and the older warm `#B8B2A2` its own
document used to name before the restyle.

## 3. What stayed together

Read against section 2 alone, the split looks wider than it is. The restyle
was scoped to the chassis — the grounds and the edges just tabled. The
signal family — gold, ember, glow, the warm inks, the live surfaces, the
Main Out deck — stayed warm on both apps, and in dark it's shared value for
value. Temperature carrying state is exactly why: the chassis had to go
cool so that warm could mean something, which means the things that
actually turn warm had to stay warm on both apps.

Identical in both apps, unchanged by the restyle:

| token         | value(s)                              |
|---------------|-----------------------------------------|
| gold, dark    | `#E8B84B`                               |
| glow          | light `#E8B84B` / dark `#FFD97A`        |
| ember, dark   | `#8A6A2F`                                |
| failure, dark | `#D9564A` (the iPhone calls it `fail`)  |

Same hue family, small per-app retunings, light only:

| token   | iPhone             | Mac                |
|---------|----------------------|----------------------|
| gold    | `#A67C1E` (41.5°)   | `#9E761D` (41.4°)   |
| ember   | `#7C5F24` (40.2°)   | `#7A5E2A` (39.0°)   |
| failure | `#B03327`            | `#BB3A2F`            |

This app's gold retuning has a recorded reason: a comment on the `gold`
token in `Tokens.swift` notes light gold went `#A67C1E` → `#9E761D` when
Direction 04 deepened light `well` to `#E2DFD3`, measuring 3.11:1. Each app
retuned its own light gold against its own ground — two apps solving the
same contrast constraint separately, not two design systems.

Warm on the iPhone too — the restyle never touched these:

- the warm ink family: `label` `#201D1A` / `#F5EFE4`, `label2` `#6B5F4E` /
  `#B7AC95`, `label3` `#6B6459` / `#9E947F`
- `goldText` `#825E0F` / `#E8B84B`
- `emberText` `#7A5A22` / `#A98341`
- the live surfaces: `liveRow` `#2E2518` dark, `liveRaised` `#2B241C` dark
- the Main Out deck: a warm tint over material

Cool on the iPhone, warm here — beyond the grounds and edges already
tabled:

| token  | iPhone    | this app (light)          |
|--------|-------------|------------------------------|
| rim    | `#66717A`  | `faderRim` `#9E8D6B`        |
| socket | `#DFE1E4`  | `dotSocket` `#E0D8C6`       |

So the divergence is real, but it's confined to the grounds, the edges, and
those two control colours. Gold, ember and glow are still shared with this
app, and identical in dark.

## 4. Four structural differences, not just hue

A hex-for-hex swap wouldn't work even if someone wanted it:

1. This app ships high-contrast variants for its edge and meter tokens —
   `hairline`, `containerEdge` and `meterTrack` each carry
   `darkHighContrast` and `lightHighContrast` (hairline `#76716B` light-HC,
   `containerEdge` `#6C6761` light-HC). The surface ladder (`canvas`,
   `canvasHi`, `panel`, `raised`, `well`) carries none. The iPhone's
   `warm(light:dark:)` helper has no high-contrast branch at all — it reads
   only `userInterfaceStyle` — so there is nothing to copy for the HC modes.
2. This app uses one hex for both `hairline` and `containerEdge` in dark
   (`#3A332B`). The iPhone splits them into two deliberately different
   weights (`#2A2E33` and `#3D4247`) and its light mode depends on that
   split — on its flat light ground, the edge is the only thing separating a
   row from the screen. Taking the iPhone palette means taking that split
   too.
3. This app has `canvasHi` (a canvas gradient top) with no iPhone
   equivalent. The iPhone has `liveRow` and `liveRaised` (warm live
   surfaces) with no equivalent here.
4. This app takes `label`, `secondaryLabel` and `tertiaryLabel` as macOS
   system pass-throughs. The iPhone defines its own three-step warm ink
   family instead. So the two apps' text colours aren't comparable
   value-for-value at all — one defers to the system, the other doesn't.

## 5. Why this app's light mode is not drift

This is the part to actually read before touching anything. The warm light
values are bound to an external design system called Circuit, not left over
from before the iPhone restyle:

- `PRODUCT.md:92` lists it as a Brand Commitment: "Light mode is the Circuit
  theme (Alec, 2026-08-07; landed in code 2026-08-11, superseding the
  earlier warm-paper light)" — the scaffolding tokens resolve to Circuit
  values in light and light-high-contrast, and the light canvas is flat
  rather than graded.
- `docs/FIGMA-DESIGN-SYSTEM.md` is the design system of record and carries
  the mapping: `canvas` `#FBFBF9` is Circuit `bg/normal`; `hairline`
  `#D0CDC3` is Circuit `border/normal`; `well` ships `#E2DFD3` rather than
  Circuit `bg/highlight` `#E8E6DC` because `#E8E6DC` measured 1.098:1
  against light `raised` `#F2F0EA`, under that checklist's locked 1.15:1
  raised-vs-well floor.
- The Figma file of record is `aGvr1qZ3tbqGD2e3jmA1Ru`. Its Warm Signal
  colour collection has four modes: Dark, Dark HC, Light, Light HC. The
  contract there is names-mirror-code, and code wins over spec.

Changing this app's light greys is not a tidy-up. It breaks a brand
commitment, unbinds Circuit, and obsoletes two of the four Figma modes.

One small correctness note while you're in that file:
`docs/FIGMA-DESIGN-SYSTEM.md` cites `PRODUCT.md:84` for the Circuit pull
date, but that line has since moved to `PRODUCT.md:92`. The citation needs a
refresh — nothing else about it is wrong.

## 6. Why the iPhone moved

From the iPhone repo's `DESIGN.md` Decision Record (Alec, 2026-08-30): the
old all-warm-gold mix melded together, lacked contrast, and read as
AI-generated. The restyle moved the chassis — grounds and edges — to cool,
and kept the signal family warm, because temperature carrying state depends
on it: a warm surface or warm ink means the Mac is sending sound here, cool
means it isn't, and that only holds if the chassis itself is cool in both
appearances. A warm ground under warm accents was the exact meld it was
undoing.

Worth saying plainly: that same record originally said "both apps restyle
together — the Mac follows this app." That didn't happen, and as of
2026-09-03 it isn't going to. The iPhone's `DESIGN.md` has been corrected to
say so.

## 7. If this is ever re-opened

Not a plan, just what a future session needs to check first:

- It's a brand-commitment change. It needs Alec's explicit decision first,
  not an agent's judgment call.
- Both appearances move or neither does. Light-only leaves this app warm in
  dark and cool in light, which breaks the temperature rule in dark.
- All four Figma modes in `aGvr1qZ3tbqGD2e3jmA1Ru` get rebuilt — Light and
  Light HC most of all.
- High-contrast values have to be invented for every token, because the
  iPhone has none to copy.
- Every measured floor in `docs/FIGMA-DESIGN-SYSTEM.md` gets re-measured
  against the new grounds — in particular the 1.10:1 surface-separation and
  1.15:1 raised-vs-well floors that decided `well` `#E2DFD3` in the first
  place.
- `PRODUCT.md:92` and `docs/FIGMA-DESIGN-SYSTEM.md` both need amending, or
  this repo carries a commitment it no longer honours.
- The iPhone's own reference values live in `audiout-remote` at
  `AudioutRemote/UI/Shared/WarmSignal.swift` and `DESIGN.md`.
