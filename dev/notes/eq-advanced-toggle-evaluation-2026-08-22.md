# EQ "Advanced" fold — where the toggle belongs (2026-08-22)

Planning only. Answers the owner: "the Advanced button disappears … maybe a toggle".

## Recommendation: keep the disclosure, make the row a section (Option A) + a "bands set" readout

The triangle is the right control; the row around it is too quiet. Fix the row,
don't change the control:

```
│  ☐ Loudness                               Reset  │
│ ──────────────────────────────────────────────── │  ← hairline (Settings' Advanced has one)
│  ▸ Advanced   10 bands                 3 set     │  ← whole row clickable; readout in the 0 dB column
└──────────────────────────────────────────────────┘

open:
│  ▾ Advanced   10 bands                 3 set     │
│   ┃  ┃  ┃  ┃  ┃  ┃  ┃  ┃  ┃  ┃                   │
│   31 63 125 250 500 1k 2k 4k 8k 16k          Hz  │
```

Labels (plain speech, Settings' word kept): title **"Advanced"**, hint **"10 bands"**
(`tertiaryLabel`), readout **"3 set"** when any band is non-zero, blank when flat
(matches Bass "0 dB" → not "Flat": a readout that always says something stops
saying anything). Spoken: "Advanced, 10 bands, 3 set, collapsed".

**Indicator, not force-open.** A shaped band never yanks the card open — that
blows the height budget on every device visit and the scope already draws the
shaping in gold. The readout is the second, unmissable signal: hidden bands
changing sound always print a number on the visible row. Forcing open would
also fight persistence (below).

**Persistence: one global switch, remembered across launches.** Today the state
is an in-memory bool on the editor; `apply(eq:)` never touches it, and each
detail controller owns one editor, so the fold already survives device switches
within a session and forgets on relaunch. Settings' Advanced is the same (no
`UserDefaults`). Someone who uses bands uses them on every speaker, so remember
it globally (one key, injectable suite like `AudioSettingsViewController:102`).
Per-device state adds a surprise per click for nothing.

## Why not the others

### B — Segmented "Simple | Advanced" at the card top (SoundSource)
```
│  Equalizer        [ Tone | Bands ]  │
```
Swaps the body, so the card height stays put — tempting. But `DeviceEQ` keeps
both tiers live at once (header doc :28-33): set Bass +3, switch to Bands, and
Bass vanishes while still colouring the sound. HIG: segmented controls and tab
views show *mutually exclusive* content; these tiers aren't. Breaks "the UI
never lies" (PRODUCT.md). SoundSource gets away with it because its tabs hold
different things. Reject.

### C — NSSwitch "Show 10 bands" on the title line
HIG Toggles: a switch sets a binary *setting*; don't use it to show or hide
content. Worse here: a switch on an Equalizer card reads as "EQ on/off", the
one meaning that would make the user think their sound changed. Reject.

### D — Text button "Show Advanced…" / "Hide Advanced"
Not actually the Settings idiom — Settings uses the same triangle
(`AudioSettingsViewController:410-432`); its only extra is that the word
"Advanced" is a borderless button, so clicks on the label work. Adopt that
detail, not the text button: "…" promises a dialog, and a push button for
in-place expansion is a second idiom where the framework allows one.

### E — Always show the bands
+95 pt: card ≈ 325 pt, Groups and About pushed a full row further below the
fold, ten 76 pt faders become the loudest element on every speaker page for the
majority who never touch them. Breaks the framework's above-the-fold promise.
Reject — unless the scope becomes the band editor (see below).

## HIG fit of A
Disclosure controls: a triangle shows/hides content *in place*, one per view is
fine, and the label must name what it discloses — "Advanced" alone fails that;
"Advanced · 10 bands" passes. Stock `bezelStyle = .disclosure`, stock text.
Warm Signal: no new colour; the readout sits in `secondaryLabel` like every
other readout; gold stays inside the scope.

## Discoverability and height
Collapsed card: +1 hairline and ~8 pt ≈ 238 pt, still inside the ≈242 budget.
Open: unchanged (+95). The hairline moves the row off the card's bottom edge so
it stops reading as a footer, and the "3 set" readout gives it a reason to be
looked at.

## Changes to `EQEditorView` (high level)
1. `configureAdvancedTier`: insert a hairline row (`Tokens.Color.hairline`
   `NSBox`) before the header; make `advancedTitle` a borderless `NSButton`
   targeting the same toggle (copy Settings :422-432); append hint + trailing
   readout label to the header row (flexible width, trailing aligned; the
   48 pt readout column won't fit "12 set"? it will — 5 chars).
2. `refreshDisplay`: `shaped = eq.bandGainsDB.filter { $0 != 0 }.count`;
   readout = shaped == 0 ? "" : "\(shaped) set"; set the disclosure's
   accessibility value.
3. `setAdvancedExpanded`: write the global key; `init` reads it and applies
   headless-instant.
4. Tests (`EQEditorViewTests`): readout flat/shaped, title click toggles,
   key round-trip. `DeviceDetailViewTests` string pins: check "Advanced".

## Interaction with the scope-rendering work
- If the scope grows **band markers** when the fold is closed, that is the
  visual half of this readout — keep both; the number is what VoiceOver gets.
- If the scope becomes a **drag-to-edit curve**, the ten faders lose their
  reason to exist and E becomes moot; the row then shrinks to the readout alone.
- The "Not applied" bypass line stays above this row; the readout should not
  dim with it (values are still stored).
