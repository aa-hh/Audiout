---
name: Audiouter Remote — Speakers (iOS)
description: Warm Signal under Liquid Glass — a mixer drawn as native SwiftUI instruments, dark-primary with a Circuit-adjacent light ground
colors:
  canvas: "#16130F"
  canvasHi: "#1B1712"
  panel: "#1D1915"
  raised: "#241F1A"
  well: "#100D0A"
  hairline: "#3A332B"
  label: "rgba(255,255,255,0.92)"
  label2: "rgba(255,255,255,0.55)"
  label3: "rgba(255,255,255,0.47)"
  gold: "#E8B84B"
  goldText: "#E8B84B"
  ember: "#8A6A2F"
  glow: "#FFD97A"
  ring: "#8D7D5E"
  rim: "#8D7D5E"
  fail: "#D9564A"
  caution: "#E29A3D"
  meter: "#4E463A"
  pill: "#38322B"
  socket: "#34302A"
  glass: "rgba(52,45,37,0.52)"
  glassEdge: "rgba(255,255,255,0.11)"
  glassHi: "rgba(255,255,255,0.10)"
  deckFill: "rgba(84,72,58,0.48)"
typography:
  title:
    fontFamily: "SF Pro (system)"
    fontSize: "26pt (@ScaledMetric, relativeTo: .title2)"
    fontWeight: 700
    letterSpacing: "-0.7pt"
  body:
    fontFamily: "SF Pro (system)"
    fontSize: "16.5pt (@ScaledMetric, relativeTo: .body)"
    fontWeight: "400, 600 when the row is the one playing"
    letterSpacing: "-0.2pt"
  readout:
    fontFamily: "SF system monospaced (design: .monospaced)"
    fontSize: "16pt at rest, 22pt while dragging (@ScaledMetric, relativeTo: .body/.subheadline)"
    fontWeight: 700
    letterSpacing: "-0.4pt"
    fontFeature: "monospacedDigit"
  microLabel:
    fontFamily: "SF system monospaced (design: .monospaced)"
    fontSize: "11pt floor (@ScaledMetric, relativeTo: .caption2)"
    fontWeight: 700
    letterSpacing: "9% of base point size"
rounded:
  control: "10pt"
  row: "16pt"
  panel: "26pt"
spacing:
  rowGutter: "12pt"
  hitTarget: "44pt"
  rowHeight: "60pt"
  listHorizontal: "14pt"
  headerHorizontal: "18pt"
components:
  button-mute:
    backgroundColor: "{colors.well}"
    rounded: "{rounded.control}"
    size: "28pt drawn, 44pt hit target"
  fader-track:
    backgroundColor: "{colors.well}"
    rounded: "999pt (capsule)"
    height: "18pt"
  status-banner:
    rounded: "10pt"
    padding: "10pt"
---

# Design System: Audiouter Remote — Speakers (iOS)

## Overview

**Creative North Star: "Warm Signal under Liquid Glass"**

The Speakers tab is where Audiouter's iOS companion draws its mixer as
instruments instead of chrome: a device row IS its own fader (a horizontal
drag anywhere on it sets the level — there is no separate slider), a
speaker's level reads as a gold arc traced around its own halo ring, and
Main Out floats as a frosted glass deck over the list rather than living in
a settings sheet. Two grounds ship — a warm near-black canvas with a gold
signal accent in dark, and a paper-toned canvas with a deepened gold in
light — and the app follows the system appearance automatically, with
nothing stored. This is the shared token file (`UI/Shared/WarmSignal.swift`)
and its scope is the whole companion app; Groups already draws from the same
palette, and the Speakers tab is documented here as its richest, most fully
worked expression.

Depth in both grounds comes from a graded ladder of surfaces and a hairline
stroke, not shadows — the one exception is the floating Main Out deck, the
only thing genuinely floating over moving content. Every state the screen
draws is also spoken: VoiceOver's value is built from the same source the
pixels are, optimistic echoes are bounded and time out back to truth, and a
control the current rule won't let you touch says why on its own hint
rather than going silently dead.

**Key Characteristics:**
- The row is the fader — no separate slider chrome; a live row tints its own
  untouched remainder mid-drag, so the row becomes a partial fill of itself
- Level is a knob-style gold arc around the speaker's halo, not a bar or a
  numeric-only readout
- Three sections — PLAYING / READY / UNAVAILABLE — address every speaker by
  what it is doing right now, never by transport (no separate Bluetooth or
  Pinned heading)
- Depth is a ground ladder and hairlines; one shadow exists on the entire
  screen
- A bold, tracked-out, uppercase monospaced micro-voice carries every state
  word; sentence case is reserved for text the app didn't write itself (a
  failure headline is the Mac's own sentence)
- Bare numbers, not named presets, for every level readout

## Colors

A warm near-black ground with a gold signal accent in dark; the same
instrument hues keep their authored values in light, where the ground moves
to paper and gold is deepened for text contrast.

### Primary
- **Gold** (`#E8B84B` dark / `#A67C1E` light): the live signal — fader fill,
  the halo's level arc, the routed-app dot, a fader cap's index bar. Graphic
  use only; clears 3:1 in both grounds but fails 4.5:1 as light-mode text.
- **Gold Text** (`#E8B84B` dark / `#866210` light): the same signal,
  repurposed for anything at or under 16pt that must read as gold — MAIN
  OUT, a live volume readout, the PLAYING sub-label. Deepened in light so
  the identical hue clears the text floor instead of the graphic one.

### Neutral — the ground ladder
- **canvas** (`#16130F` dark / `#F4F2EA` light): the screen behind
  everything.
- **canvasHi** (`#1B1712` / `#F7F5EF`): the top stop of the canvas gradient.
- **panel** (`#1D1915` / `#FCFBF7`): one step up from canvas.
- **raised** (`#241F1A` / `#FFFFFF`): halos, fader caps — things that sit on
  top.
- **well** (`#100D0A` / `#EDEAE0`): recessed — fader tracks, mute-button
  fill, the routed-dot's unlit state.
- **hairline** (`#3A332B` / `#D0CDC3`): every drawn edge that stands in for
  a shadow. Light is the Mac app's own hairline hex, held to a ≥1.25:1 floor
  against the surface it divides (1.54:1 on `panel`, 1.42:1 on `canvas`);
  anything lighter is an edge you cannot see — `#E7E6DF` lands at 1.21:1.

The steps are small on purpose — about 1.12:1 canvas→raised, close to what
`systemGroupedBackground` gives a white cell — because elevation you can see
is not elevation you notice.

The five light grounds are the one place this palette deliberately does not
match the Mac app, which took `#FBFBF9` flat across canvas/canvasHi/panel/
raised. The Mac separates surfaces with hairlines and window chrome that iOS
has no equivalent of; here a flat ground leaves a halo, a panel and the screen
behind them the same pixel. Everything below the ladder — `hairline` and every
instrument — is the same value on both platforms.

### Ink
- **label** (92% white dark / `#1E1C1C` light): primary text — a playing
  device's name, the screen title.
- **label2** (55% white / `#706464`): secondary — eyebrow text, a muted
  sub-label, unselected section titles.
- **label3** (47% white / `#5F5A54`): tertiary — READY sub-labels, counts,
  empty-state text. Lifted from the design document's own 28%-white value,
  which measured 1.93:1 against the dark ground; both grounds now clear the
  4.5:1 text floor.

### Instruments
- **ember** (`#8A6A2F` / `#9C7E3C`) and **glow** (`#FFD97A` / `#E8B84B`):
  reserved signal variants, not yet drawn on this screen. Light ember is the
  Mac's own hex and carries `gold`'s 3:1 floor on every ground (3.19:1 on
  `well`) — a lighter tan reads as "dimmer" and clears nothing (`#C2A05A` is
  2.06:1 on `well`).
- **ring** (`#8D7D5E` / `#8B7958`): the connected solid halo and the dashed
  connecting/reconnecting halo. A graphic, so it holds the 3:1 floor on every
  ground it draws on — and being shared with the Mac, on the Mac's grounds
  too. The tightest is the Mac's `well` `#E8E6DC` at 3.37:1; on this screen
  the tightest is `well` at 3.51:1, the loosest `raised` at 4.22:1. The Mac's
  hex exactly.
- **rim** (`#8D7D5E` / `#8A7A62`): the stroke on every raised control —
  fader track, fader cap, mute button.
- **fail** (`#D9564A` / `#BB3A2F`): the one red on the screen, and it is
  only ever the failure ring.
- **caution** (`#E29A3D` / `#B3701C`): the local-fallback status banner —
  the one banner that is an actual problem.
- **meter** (`#4E463A` / `#CBBEA1`), **pill** (`#38322B` / `#D0CDC3`),
  **socket** (`#34302A` / `#E0D8C6`): supporting tints — `pill` is the
  in-drag remainder tint; `socket` is the routed-dot's unlit fill.

### Glass
- **glass** (`rgba(52,45,37,0.52)` dark / `rgba(250,247,238,0.66)` light)
  over `.ultraThinMaterial`, **glassEdge** (11%/10% white-on-ink) as the
  panel's one stroke, **glassHi** unused on this screen's current panel
  (a prior highlight stroke was removed — one edge reads cleaner than two).
- **deckFill** (`rgba(84,72,58,0.48)` / `rgba(250,247,238,0.78)`): the Main
  Out deck's own warm glass tint — deliberately warmer than plain `glass`,
  never a neutral grey.

### Named Rules
**The Text/Graphic Gold Split Rule.** `gold` and `goldText` are the same hue
family but different hexes in light mode, because the same value clears 3:1
as a fill everywhere it's used but fails 4.5:1 as text. Any text at or under
16pt that must read as gold uses `goldText`; everything else — fills, arcs,
dots — uses `gold`.

**The One Red Rule.** Exactly one thing on this screen is red: the failure
ring. A failure card's headline text stays `label2`, not `fail` — red on the
card's widest element would read as the app being broken, not one speaker.

## Typography

**Body Font:** San Francisco (system), entirely Dynamic Type — every size on
this screen is a `@ScaledMetric` relative to a system text style, never a
bare point size.
**Micro/Readout Font:** the system monospaced design (`design: .monospaced`),
reserved for two jobs — the uppercase micro-label voice and numeric
readouts — both scaled the same way.

**Character:** a mixer's own two voices: a plain, slightly tightened
system face for anything a person reads as prose or a name, and a bold
tracked-out monospaced voice for anything the screen states as a fact —
a level, a state word, a count.

### Hierarchy
- **Title** (700, 26pt, tracking −0.7pt): "Speakers" — the screen draws its
  own header; there is no `NavigationStack` title.
- **Body** (400 / 600 when playing, 16.5pt, tracking −0.2pt): a device's
  name — the one place weight itself carries state.
- **Readout** (700 monospaced, 16pt at rest / 22pt mid-drag, tracking
  −0.4pt, tabular digits): any volume number. Main Out's and a device row's
  are drawn at the same resting size on purpose — the same kind of number,
  said one way.
- **Micro Label** (700 monospaced, 11pt floor, tracking 9% of base size,
  uppercase by default): section headers, sub-labels (PLAYING/READY/
  MUTED/CONNECTING…), "MAIN OUT", the gesture-coach line. 11pt is both the
  HIG floor for any text and this voice's default — the source design's own
  values ran 9–9.5pt, under that floor.

### Named Rules
**The Sentence-Case Exception.** Uppercase is the default for every state
word, except text the app did not choose — a failure headline is the Mac's
own sentence, and a sentence in capitals is a shout. That one string keeps
sentence case and `label2`, never the micro-label treatment.

## Layout

One scrolling list — `ScrollView` + `LazyVStack`, deliberately not `List`:
every row is fully custom-drawn and carries its own horizontal drag gesture,
which `List`'s cell chrome and swipe handling would fight. The list is cut
into three sections that are always present — PLAYING, READY, UNAVAILABLE —
so an empty heading is the honest answer to "nothing is playing," and
membership is read off device state, never off transport (a Bluetooth
speaker is just a speaker with a Bluetooth-shaped icon).

The Main Out deck is an `.overlay(alignment: .bottom)` on the scroll view,
never a `.safeAreaInset` — content keeps scrolling underneath the frosted
glass instead of stopping above it. The list's bottom padding is the deck's
own measured height (`onGeometryChange`) plus 16pt, not a constant: the
deck's interior is entirely Dynamic Type, so at accessibility sizes it can
grow well past any fixed guess.

Row height is a fixed 60pt (8pt air, a 44pt halo, 8pt air). A section header
claims the full 44pt tap-target height across the row's whole width, not
just the chevron. Horizontal padding: 14pt around the list, 18pt around the
header, 12pt (`rowGutter`) inside each row — the fader fill and its in-drag
remainder ignore the gutter and run edge-to-edge, so there is exactly one
coordinate system for a level's value and the finger can never disagree with
where the fill's own edge is.

## Elevation & Depth

Almost entirely flat. Depth comes from the six-step ground ladder (canvas →
canvasHi → panel → raised → well, plus a hairline stroke) rather than
shadows — a drawn edge is cheaper than a shadow and doesn't smear across a
paper ground. Exactly one shadow exists on the whole screen, on the Main Out
deck, because it is the only element genuinely floating over moving content;
even that shadow is tuned per appearance, because the same 0.4-black-at-17pt
that reads as height in dark reads as a grey smudge over the light paper
ground.

### Shadow Vocabulary
- **Deck, dark** (`black 28%, radius 24, y −6`): the deck's own elevation
  against the near-black ground.
- **Deck, light** (`black 8%, radius 18, y −4`): the same deck, softened —
  full dark-mode opacity smudges rather than lifts over paper.

### Named Rules
**The One Shadow Rule.** Every surface but the Main Out deck separates from
what's behind it with a hairline stroke, never a shadow.

## Shapes

Three corner radii and nothing between them: **control** (10pt — mute
buttons, well backgrounds), **row** (16pt — a device row's clip shape),
**panel** (26pt — the Main Out deck). The prior screen had eight individually
plausible radii; three is what's left once they're actually counted and
reused.

Faders, the level pill, and the status pill are capsules, never rounded
rects — the shape reads as the value's own track, not a decorated
rectangle. The section chevron is the one hand-drawn glyph on the screen: a
9×9pt stroked path (two 1.8pt-wide straight segments, `lineCap: .butt`,
`lineJoin: .miter`) rather than an SF Symbol, rotated between −45° (pointing
down, expanded) and 135° (pointing right, collapsed) — drawn so its two
strokes read at exactly the weight the rest of the screen's lines do.

## Components

### Device Row (signature component)
The row is its own fader and its own button: a tap starts or stops the
speaker; a horizontal drag anywhere across the row sets its level. There is
no drawn slider.
- **Halo:** a 44pt circle, `raised` fill, an SF Symbol glyph tinted by
  state, ringed by `LevelDial` while live (a knob-style 300°-of-360° gold
  arc with a 60° dead zone centred on the routed-app dot — drawn on `well`,
  never `ring`, because a gold arc on `ring` measures 1.12:1 in light,
  under the 3:1 control floor).
- **Wash:** while playing, a flat 5%-opacity gold rectangle sits behind the
  whole row — a "this row is live" signal, never the level itself.
- **Drag instrument:** mid-drag, the row tints its own untouched remainder
  in `pill` at 50% opacity — the row's own width divides in two, so the
  instrument is the row, never a second overlaid object.
- **Mute:** a 28pt well/rim square, overlaid rather than composed into the
  row's own gesture subtree (so a mute tap never also toggles play); only
  drawn on a row that is actually sounding.
- **States:** PLAYING (gold sub-label, semibold name) · READY (label3,
  regular name) · CONNECTING…/RECONNECTING… (dashed ring, no section
  change) · MUTED · UNAVAILABLE (0.45 opacity on the halo only — never on
  text, which is already dim enough via `label3`) · failed (volume and mute
  are replaced outright by a failure card: headline, optional Diagnose
  disclosure, Try Again).

### Main Out Deck (signature component)
A frosted `glassPanel` (26pt radius, `.ultraThinMaterial` plus a warm
`deckFill` tint and a single 0.5pt `glassEdge` stroke) floating over the
list — the screen's one shadowed surface.
- **Header:** a fixed "MAIN OUT" micro-label that never truncates, paired
  with `MainOutPicker` — a `Menu` with a hand-drawn `Text` label so it can
  truncate instead. Between the two, the picker is the designated loser for
  width.
- **MainOutRow:** a mute button identical in construction to a device row's,
  a 44pt-tall fader (18pt well/rim capsule track, gold fill capsule, and a
  22×34pt raised capsule cap carrying a 3pt gold index bar down its centre),
  and a 16pt gold readout.

### Section Header
A rotating chevron, a tinted micro-label title (gold for PLAYING, label2
otherwise), a label3 count, and a hairline rule that runs to the trailing
edge — the full row is a 44pt tap target that collapses or expands the
section.

### Status Banner
An SF Symbol plus footnote text on a 10pt-radius rounded rect filled with
the banner's own tint at 12% opacity. Exactly two tints are ever used —
`caution` for the one real problem (speakers unreachable, playing locally)
and `label2` for notes (a PTP-timing permission prompt, a double-AirPlay-
path warning) — deliberately never reaching for system orange or blue,
which would be the one hue family Warm Signal doesn't otherwise use (and
blue reads as a link on iOS).

### One-Time Gesture Coach
An inline micro-label line under the first visible row — "TAP TO PLAY · DRAG
TO SET LEVEL … GOT IT" — never a modal or a spotlight tour. It leaves for
good once both gestures have actually been used, or immediately on tap.

### App Route Row (Apps tab)
The row-as-fader grammar restated on a routing row. Same 44pt identity tile
(`raised` fill, `hairline` stroke, control radius — SF Symbol or a mono
initial; never a per-app hue, there is no hue left in the palette to spend),
same flat gold wash while the app is running, same in-drag remainder divide,
same detent/rail haptics. What differs from a device row, and why:
- **No tap action, no touch-down flash** — the protocol has no app mute, so
  the row has nothing to promise a tap.
- **The destination chip** is the row's one tap target: a `Menu` with a
  drawn label on a `well` + `rim` capsule — the recessed-control recipe the
  mute buttons and fader tracks wear, chosen over `pill` because `pill` was
  never a text backdrop and fails as one (3.5:1 light against the 4.5:1
  floor; `well` clears in both grounds). Chip text: `goldText` when
  redirected to a device (the same gold thread as the Speakers routed dot),
  `label2` otherwise. Its menu also carries the destructive "Stop Routing" —
  horizontal swipes are the fader, so swipe-to-delete is gone.
- **The readout never hides**: a silent app's level is a stored preset —
  true, so shown — but in `label3`, because gold is reserved for live.
- **Silent apps sink**: running rows first, then not-running, each half in
  the Mac's own order (a stable two-pass partition), dimmed by tint only —
  never whole-row opacity.

### Follow Note (Apps tab)
The header's one line of context — a 6pt gold dot and "Apps without a route
follow Main Out" in footnote `label2` ("Main Out" in `label`). No container:
a glass pill would promise a press, the same reasoning the Speakers status
pill is built on.

## Do's and Don'ts

### Do:
- **Do** hold every tappable control to the 44pt hit-target floor via
  padding outward (`hittable(drawn:)`) — never grow the control's own drawn
  size to reach it.
- **Do** use `goldText`, never `gold`, for text at or under 16pt — the
  graphic hue fails the light-mode text contrast floor.
- **Do** drive a row's cross-section travel and a section's collapse off
  the same one spring (`.spring(duration: 0.25)`, no bounce) — one tempo
  for the whole screen, not one per animated thing.
- **Do** confirm mute from the Mac's own answer before flipping the icon or
  firing its haptic — sound is live in another room; this control is not
  optimistic.
- **Do** measure the Main Out deck's real height and use it as the list's
  bottom inset — Dynamic Type can grow the deck past any fixed constant.

### Don't:
- **Don't** reach for `List` for the speaker rows — its cell chrome and
  swipe handling fight the row's own horizontal drag.
- **Don't** draw a shadow anywhere but the Main Out deck — every other
  surface separates with a `hairline` stroke.
- **Don't** invent a third status-banner hue — `caution` and `label2` cover
  the two real cases; reaching for orange or blue is a Warm Signal
  violation, not a gap to fill.
- **Don't** cap the level arc with `.round` — a round cap paints a stray dot
  of gold at the zero stop. Use `.butt`, so the fill's own end is the value.
- **Don't** read volume off the live snapshot mid-drag — always read the
  local in-drag echo (`localVolume`), or the ~50ms server round-trip fights
  the finger under it.
