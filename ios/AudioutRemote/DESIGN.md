---
name: Audiout Remote — Speakers (iOS)
description: Warm Signal under Liquid Glass — a mixer drawn as native SwiftUI instruments, dark-primary with a Circuit-adjacent light ground
colors:
  canvas: "#16130F"
  canvasHi: "#1B1712"
  panel: "#1D1915"
  raised: "#241F1A"
  well: "#100D0A"
  hairline: "#3A332B"
  containerEdge: "#3A332B"
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
    fontFamily: "SF Pro (system)"
    fontSize: "16pt at rest, 22pt while dragging (@ScaledMetric, relativeTo: .body/.subheadline)"
    fontWeight: 700
    fontFeature: "monospacedDigit"
  microLabel:
    fontFamily: "SF Pro (system)"
    fontSize: "11pt floor (@ScaledMetric, relativeTo: .caption2)"
    fontWeight: 600
    textCase: "sentence case, as authored — never transformed"
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

# Design System: Audiout Remote — Speakers (iOS)

## Overview

**Creative North Star: "Warm Signal under Liquid Glass"**

The Speakers tab is where Audiout's iOS companion draws its mixer as
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

Depth comes from drawn edges, not shadows: a graded ladder of surfaces in
dark, and in light a single flat near-white ground where the edge carries the
separation alone — the one exception is the floating Main Out deck, the only
thing genuinely floating over moving content. Every state the screen
draws is also spoken: VoiceOver's value is built from the same source the
pixels are, optimistic echoes are bounded and time out back to truth, and a
control the current rule won't let you touch says why on its own hint
rather than going silently dead.

**Key Characteristics:**
- The row is the fader — no separate slider chrome; a live row tints its own
  untouched remainder mid-drag, so the row becomes a partial fill of itself
- Level is a knob-style gold arc around the speaker's halo, not a bar or a
  numeric-only readout
- Three sections — Playing / Ready / Unavailable — address every speaker by
  what it is doing right now, never by transport (no separate Bluetooth or
  Pinned heading)
- Depth is a ground ladder in dark and edge weight in light; one shadow
  exists on the entire screen
- One label voice: small semibold sentence case in the plain system face
  carries every state word — state is told by tint and weight, never by
  capitals or a monospaced face
- Bare numbers, not named presets, for every level readout

## Colors

A warm near-black ground with a gold signal accent in dark; the same
instrument hues keep their authored values in light, where the ground moves
to paper and gold is deepened for text contrast.

### Primary
- **Gold** (`#E8B84B` dark / `#A67C1E` light): the live signal — fader fill,
  the halo's level arc, the routed-app dot, a fader cap's index bar. Graphic
  use only; clears 3:1 in both grounds but fails 4.5:1 as light-mode text.
- **Gold Text** (`#E8B84B` dark / `#825E0F` light): the same signal,
  repurposed for anything at or under 16pt that must read as gold — Main
  Out, a live volume readout, the Playing sub-label. Deepened in light so
  the identical hue clears the text floor instead of the graphic one.

### Neutral — the grounds and the two edges
- **canvas** (`#16130F` dark / `#FBFBF9` light): the screen behind
  everything.
- **canvasHi** (`#1B1712` / `#FBFBF9`): the top stop of the canvas gradient,
  which collapses flat in light.
- **panel** (`#1D1915` / `#FBFBF9`): one step up from canvas in dark.
- **raised** (`#241F1A` / `#FBFBF9`): halos, fader caps — things that sit on
  top.
- **well** (`#100D0A` / `#E8E6DC`): recessed — fader tracks, mute-button
  fill, the routed-dot's unlit state, the level arc's track.
- **hairline** (`#3A332B` / `#D0CDC3`): the rule INSIDE a container — a row
  separator, a section-header lead-in. Held to a ≥1.25:1 floor against the
  surface it divides: 1.54:1 on the flat light ground, 1.27:1 on `well`.
  Anything lighter is an edge you cannot see — `#E7E6DF` lands at 1.21:1.
- **containerEdge** (`#3A332B` / `#C4C0B4`): a container's OWN outer edge.
  Light measures 1.76:1 on the flat ground and 1.45:1 on `well`, ranking
  1.14:1 above the `hairline` divider — enough to tell the two apart, short of
  reading as two materials. Dark is `hairline`'s own value by decision: dark
  still has a fill ladder, and its hairline already measures 1.40:1 on `panel`
  and 1.56:1 on `well`, at or above where the light edge lands.

Both edges are the Mac app's hexes exactly, under the same two names.

**Light is one flat ground, and separation there is edge weight, not fill.**
This is Alec's decision (2026-08-12), taken on measurements against a rendered
comparison of every alternative. A stepped light ladder is the intuitive answer
and it fails measurement twice: its steps land at 1.04–1.08:1, under this
project's own 1.10:1 surface floor, so it buys perception without buying
separation; and every ink and instrument measures BEST on the flat near-white
and worse on each rung down (`label2` gives up 0.4 of a contrast point on a
stepped canvas, `gold` falls from 3.67:1 to 3.39:1). Moving an edge costs
neither, because nothing on this screen is ever drawn ON an edge. All five
light grounds now match the Mac app value for value.

### Ink
- **label** (92% white dark / `#1E1C1C` light): primary text — a playing
  device's name, the screen title.
- **label2** (55% white / `#706464`): secondary — eyebrow text, a muted
  sub-label, unselected section titles.
- **label3** (47% white / `#5F5A54`): tertiary — Ready sub-labels, counts,
  empty-state text. Lifted from the design document's own 28%-white value,
  which measured 1.93:1 against the dark ground; both grounds now clear the
  4.5:1 text floor.

### Instruments
- **ember** (`#8A6A2F` / `#9C7E3C`) and **glow** (`#FFD97A` / `#E8B84B`):
  reserved signal variants, not yet drawn on this screen. Light ember is the
  Mac's own hex and carries `gold`'s 3:1 floor on every ground (3.07:1 on
  `well`) — a lighter tan reads as "dimmer" and clears nothing (`#C2A05A` is
  2.06:1 on `well`).
- **ring** (`#8D7D5E` / `#8B7958`): the connected solid halo and the dashed
  connecting/reconnecting halo. A graphic, so it holds the 3:1 floor on every
  ground it draws on — and being shared with the Mac, on the Mac's grounds
  too. The tightest ground on either platform is the now-shared `well`
  `#E8E6DC` at 3.37:1; the loosest is the flat light ground at 4.08:1. The
  Mac's hex exactly.
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
**Micro/Readout Font:** the same system face. There is no second family and
no monospaced design anywhere: numeric readouts get tabular digits via
`.monospacedDigit()` (fixed-width digits in the normal face, so a value
doesn't shuffle under a finger), and micro labels are simply a smaller,
semibold cut of the one voice.

**Character:** one plain voice at three sizes. What the screen states as a
fact — a level, a state word, a count — is distinguished by weight, size,
and tint, never by a monospaced face or capitals. Nothing in the app is set
in all caps, and no string is ever case-transformed (`.textCase` is banned);
strings render exactly as authored, in sentence case.

### Hierarchy
- **Title** (700, 26pt, tracking −0.7pt): "Speakers" — the screen draws its
  own header; there is no `NavigationStack` title.
- **Body** (400 / 600 when playing, 16.5pt, tracking −0.2pt): a device's
  name — the one place weight itself carries state.
- **Readout** (700, 16pt at rest / 22pt mid-drag, tabular digits): any
  volume number. Main Out's and a device row's are drawn at the same resting
  size on purpose — the same kind of number, said one way.
- **Micro Label** (600, 11pt floor, sentence case): section headers,
  sub-labels (Playing/Ready/Muted/Connecting…), "Main Out", the
  gesture-coach line. 11pt is both the HIG floor for any text and this
  voice's default — the source design's own values ran 9–9.5pt, under that
  floor.

### Named Rules
**One Case.** Every string is authored in sentence case (product names like
"Main Out" keep their title case) and rendered exactly as written. No
`.textCase(.uppercase)`, no all-caps string literals, no monospaced design —
capitals-as-styling reads as a shout and is banned across the app. This rule
is the portable one: the Mac app adopts the same voice (roadmap 059).

## Layout

One scrolling list — `ScrollView` + `LazyVStack`, deliberately not `List`:
every row is fully custom-drawn and carries its own horizontal drag gesture,
which `List`'s cell chrome and swipe handling would fight. The list is cut
into three sections that are always present — Playing, Ready, Unavailable —
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

Almost entirely flat. Depth comes from the dark ground ladder (canvas →
canvasHi → panel → raised, with `well` recessed below), and in light from
`containerEdge` and `hairline` alone, rather than from shadows — a drawn edge is cheaper than a shadow and doesn't smear across a
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
  state, and a resting 1pt `containerEdge` rim — the fill matches the ground
  in light, so the rim is the halo's whole boundary. The rim is replaced,
  never joined, by each state ring: `LevelDial` while live (a knob-style
  300°-of-360° gold arc with a 60° dead zone centred on the routed-app dot —
  drawn on `well`, never `ring`, because a gold arc on `ring` measures 1.11:1
  in light, under the 3:1 control floor), a dashed `ring` while connecting, a
  `fail` ring when it failed.
- **Wash:** while playing, a flat 5%-opacity gold rectangle sits behind the
  whole row — a "this row is live" signal, never the level itself.
- **Drag instrument:** mid-drag, the row tints its own untouched remainder
  in `pill` at 50% opacity — the row's own width divides in two, so the
  instrument is the row, never a second overlaid object.
- **Mute:** a 28pt well/rim square, overlaid rather than composed into the
  row's own gesture subtree (so a mute tap never also toggles play); only
  drawn on a row that is actually sounding.
- **States:** Playing (gold sub-label, semibold name) · Ready (label3,
  regular name) · Connecting…/REConnecting… (dashed ring, no section
  change) · Muted · Unavailable (0.45 opacity on the halo only — never on
  text, which is already dim enough via `label3`) · failed (volume and mute
  are replaced outright by a failure card: headline, optional Diagnose
  disclosure, Try Again).

### Main Out Deck (signature component)
A frosted `glassPanel` (26pt radius, `.ultraThinMaterial` plus a warm
`deckFill` tint and a single 0.5pt `glassEdge` stroke) floating over the
list — the screen's one shadowed surface.
- **Header:** a fixed "Main Out" micro-label that never truncates, paired
  with `MainOutPicker` — a `Menu` with a hand-drawn `Text` label so it can
  truncate instead. Between the two, the picker is the designated loser for
  width.
- **MainOutRow:** a mute button identical in construction to a device row's,
  a 44pt-tall fader (18pt well/rim capsule track, gold fill capsule, and a
  22×34pt raised capsule cap carrying a 3pt gold index bar down its centre),
  and a 16pt gold readout.

### Section Header
A rotating chevron, a tinted micro-label title (gold for Playing, label2
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
An inline micro-label line under the first visible row — "Tap to play · Drag
to set level … Got it" — never a modal or a spotlight tour. It leaves for
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
