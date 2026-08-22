# EQ rendering research — 2026-08-22

How well-known products draw an equalizer, and what that says about our
Equalizer card (`EQEditorView` + `EQResponseCurveView`). Planning only.

## Recommendation

**Move the scope into the Advanced tier and make it share an x-axis with the
ten faders. At rest, the card is Bass / Treble / Balance / Loudness alone.**

- Every consumer tone page found (Sonos, Bose, Apple Music, iOS Settings,
  AirPods) shows **sliders only, no curve**. "+2 dB" in a readout says more
  to a first-time user than a gentle shelf shape.
- Every product that *does* draw a curve (Logic, GarageBand, Roon, Spotify)
  ties it to the controls: the curve **is** the control, or it is the line
  **joining the slider knobs**. Curve and controls share one horizontal axis.
  Ours sits over three sliders whose axis means something else — that is why
  it reads as "a black bar with a line through it".
- The ten faders are octave-spaced, so on a log axis they are evenly spaced:
  our grid lines already land where fader columns would. Scope above faders,
  same width, and the scope *explains* the faders.
- Wherever the scope lives, dress it like an instrument (proposal A): dB on
  the edge, Hz ticks on the bottom, dotted 0 line. The centred caption row
  "+12 dB · −12 dB" has no counterpart in any product surveyed.

This depends on the separate "where does Advanced live" evaluation — see the
last section.

## What the products do

| Product | Curve? | Resting state | Source |
|---|---|---|---|
| Apple Music (macOS) Equalizer window | No | 10 vertical sliders centred, preset popup reads "Flat", On checkbox | [Apple Support](https://support.apple.com/guide/music/adjust-the-sound-quality-museb684a3de/mac) |
| iOS Settings › Music › EQ | No | A list of 23 presets, no sliders at all | [How-To Geek](https://www.howtogeek.com/405942/how-to-adjust-music-equalizer-on-iphone-and-ipad/) |
| Sonos app (Bass/Treble/Balance/Loudness) | No | Sliders only — "Drag the sliders to make adjustments" | [Sonos Support](https://support.sonos.com/en-us/article/adjust-the-bass-treble-balance-and-loudness) |
| Bose Music | No | Bass/Mid/Treble sliders ±10 | [Cult of Mac](https://www.cultofmac.com/news/bose-adds-customizable-eq-to-quietcomfort-45-headphones) |
| AirPods Adaptive / Headphone Accommodations | No | Plain sliders (Tone, Amplification, Balance) | [Apple Support](https://support.apple.com/en-us/102663) |
| Spotify | Line joins slider dots | Dots in a row, flat line between them — reads as controls, not a screen | [Spotify Support](https://support.spotify.com/us/article/equalizer/), [Medium rebuild](https://medium.com/@kheldiente/how-to-recreate-spotifys-equalizer-for-android-4c31b2ecd973) |
| eqMac | No | "Basic" = Bass/Mid/Treble knobs; "Advanced" = 10/31 sliders | [eqmac.app](https://eqmac.app/), [Softpedia](https://mac.softpedia.com/get/Audio/eqMac2.shtml) |
| SoundSource 10-band | No | Compact preset chip; click reveals a popover of sliders + preamp | [Rogue Amoeba manual](https://rogueamoeba.com/support/manuals/soundsource/?page=built-in-effects) |
| Boom 3D | Curve over 10/31 sliders | Visual feedback sits on the sliders themselves | [Global Delight](https://blog.globaldelight.com/boom-3d-mac/why-should-you-use-a-31-band-equalizer) |
| Logic Pro Channel EQ | Yes — dark display | Grid, dB scale on the right, Hz along the bottom, coloured control points ON the zero line; drag "anywhere in the space between the zero line and EQ curve" | [Apple Support](https://support.apple.com/guide/logicpro/channel-eq-parameters-lgcef1edc1d7/mac) |
| GarageBand Visual EQ | Yes — dark display | Same idiom; each band a coloured area; "click a curve line segment, the control point, or in the colored area" | [Apple Support](https://support.apple.com/en-kz/guide/garageband/gbnd56ab9fca/10.4/mac/11.0) |
| Roon DSP parametric EQ | Yes | Graph plus a filter table; graph is the readout for the table | [Roon KB](https://help.roonlabs.com/portal/kb/articles/dsp-engine-parametric-equalizer) |

No product showed a **non-interactive** curve above tone sliders. No formal
design-pattern literature was found; the products carry the conventions.

## Answers

**1. Is a black scope with a flat line the norm?** Only in pro tools, and
there it is never empty: Logic's display at rest carries a dB ruler, Hz
ticks and coloured handles sitting on the zero line — an instrument waiting
for input. A bare dark panel with a hairline and no numbers is an outlier.
Consumer products avoid the question: no curve at all.

**2. Does a tone page show a curve?** No. Curves appear exactly when many
bands sum — our Advanced tier.

**Flat-state idioms:** dotted 0 dB line (Logic), the word "Flat" (Apple
Music; our VoiceOver summary already says it), knobs visibly centred.
Colour: pro tools colour per band, consumer apps use one accent; nobody
colours boost vs cut. Our gold-shaped / neutral-flat rule fits.

## Three proposals

Scope ground stays `#14110C` (`scopeGround`) in A and B. Text inside the
scope is drawn in the pinned dark appearance: `secondaryLabel` ≈ 5.7:1 on the
ground (passes 4.5:1); `tertiaryLabel` ≈ 2:1 (fails — do not use for tick
text). Gridlines are exempt from the floor. Estimates; measure before use.

### A — Keep the scope, fix the resting read

```
┌──────────────────────────────────────┐
│+12                                   │
│  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  · 0│  ← dotted 0 dB line, hairline on top
│−12                                   │
│ 31   125   500   2k    8k            │  ← Hz ticks inside, bottom edge
└──────────────────────────────────────┘
  Bass   ────────●────────    0 dB
```

- Flat: dotted zero + neutral hairline, rulers visible. Shaped / bypassed:
  as now. Identical both appearances.
- Drop the caption row; "+12 / 0 / −12" on the left edge, Hz ticks along
  the bottom, `secondaryLabel`. Grid to ~0.14 alpha.
- Tradeoff: still a curve over sliders on a different axis. Least change;
  fixes "empty", not "odd".

### B — Scope only with the bands (recommended)

```
  Bass      ────────●────────    0 dB
  Treble    ────────●────────    0 dB
  Balance  L────────●────────R  Center
  ☐ Loudness                    Reset
  ▾ Advanced
  ┌──────────────────────────────────┐
  │+12 ·  ·  ·  ·  ·  ·  ·  ·  ·  · │
  │ 0 ─────────────────────────────── │
  │−12                                │
  └──┬───┬───┬───┬───┬───┬───┬───┬──┘
     │   │   │   │   │   │   │   │      ← faders under their grid lines
     ●   ●   ●   ●   ●   ●   ●   ●
    31  63  125 250 500 1k  2k  4k …
```

- At rest the card is tone sliders only — the Sonos shape. Open Advanced
  and the scope appears bonded to the faders, same width and x-axis; fader
  labels are the Hz ruler, so the scope needs only the dB edge.
- Flat: dotted zero + hairline, handles centred under it. Shaped: gold; a
  Bass/Treble shelf still draws, since the curve plots the whole chain.
  Bypassed: dashed. Appearance rules unchanged.
- Tradeoff: a shaped tone tier is not pictured at rest — readouts carry it.
  Loses the board's "curve is always the state"; gains the
  curve-explains-controls bond every reference has.

### C — Curve on the card, no black panel

```
  Equalizer
  +12 ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·
   0 ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─
  −12 ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·
      31    125    500    2k    8k
  Bass   ────────●────────    0 dB
```

- Flat: a dotted ruler on the `raised` card — a ruler, not an empty screen.
  Shaped: gold trace + fill on the card (gold on light `raised` 3.64:1
  passes the 3:1 non-text floor; dark 8.86:1). Bypassed: dashed.
- Tradeoff: breaks "the scope is authored dark in both appearances"; needs
  a themed flat line (`scopeFlatLine` ≈2.6:1 on light `raised` — exempt as a
  gridline, but it would vanish). Strongest fix for "odd", weakest fit with
  the board.

## What B changes, high level

- `EQEditorView`: move `curve` from the top of `contentStack` into
  `advancedContent` above the faders; fader columns centred on `Plan.gridX`
  across the scope's width instead of fixed 26 pt columns; caption row
  removed.
- `EQResponseCurveView`: add a dB edge ruler (`secondaryLabel`) and a dotted
  0 dB line; Plan, pinned appearance and three states unchanged. Height
  64 → ~80 pt.
- Tests: `EQEditorViewTests` caption/fader frame checks change; `Plan` tests
  untouched.

## Dependency on the Advanced evaluation

- **B depends on it.** B assumes the ten faders stay reachable in the card
  (disclosure, tab, or a separate page). If Advanced moves to its own page,
  the scope moves with it — same design, different host. If Advanced is cut
  entirely, B collapses to "no scope", and C becomes the fallback.
- **A and C are independent** of that decision.
