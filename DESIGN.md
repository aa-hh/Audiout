---
name: Audiouter
description: Warm Signal — a warm near-black room where only the live things are lit, drawn as calibrated instruments over native Apple structure
colors:
  canvas: "#16130F"
  canvasHi: "#1B1712"
  panel: "#1D1915"
  raised: "#241F1A"
  well: "#100D0A"
  hairline: "#3A332B"
  sidebarWarmTint: "#1F1A15"
  gold: "#E8B84B"
  ember: "#8A6A2F"
  glow: "#FFD97A"
  goldCTA: "#815E0E"
  ringConnected: "#8D7D5E"
  failure: "#D9564A"
  caution: "#E29A3D"
  faderThumb: "#857762"
  faderRim: "#6B5F4E"
  dotSocket: "#34302A"
  meterTrack: "#4E463A"
  feedPillFill: "#38322B"
  permissionSystemAudio: "#5B93C4"
  permissionLocalNetwork: "#9A6BC6"
  permissionRemoteControl: "#C066A2"
  permissionSpeakerSync: "#B86F41"
typography:
  heading:
    fontFamily: "SF Pro (NSFont.systemFont)"
    fontSize: "16pt (systemFontSize + 3)"
    fontWeight: 600
  titleLarge:
    fontFamily: "SF Pro (NSFont.systemFont)"
    fontSize: "15pt (systemFontSize + 2)"
    fontWeight: 400
  subtitleLarge:
    fontFamily: "SF Pro (NSFont.systemFont)"
    fontSize: "12pt (systemFontSize - 1)"
    fontWeight: 400
  body:
    fontFamily: "SF Pro (NSFont.systemFont)"
    fontSize: "13pt (NSFont.systemFontSize)"
    fontWeight: 400
  bodyEmphasized:
    fontFamily: "SF Pro (NSFont.systemFont)"
    fontSize: "13pt"
    fontWeight: 600
  caption:
    fontFamily: "SF Pro (NSFont.systemFont)"
    fontSize: "11pt (NSFont.smallSystemFontSize)"
    fontWeight: 400
  captionEmphasized:
    fontFamily: "SF Pro (NSFont.systemFont)"
    fontSize: "11pt"
    fontWeight: 600
  microLabel:
    fontFamily: "SF Mono (NSFont.monospacedSystemFont)"
    fontSize: "8.5pt"
    fontWeight: 700
    letterSpacing: "0.765pt (+0.09em)"
  syncReadout:
    fontFamily: "SF Mono (monospacedDigitSystemFont)"
    fontSize: "12pt (smallSystemFontSize + 1)"
    fontWeight: 500
    fontFeature: "monospacedDigit"
rounded:
  panel: "12px"
  banner: "11px"
  groupedSection: "10px"
  selectionHighlight: "7px"
  mutePill: "7px"
  titleField: "6px"
  feedPill: "5px"
  syncChip: "5px"
  faderThumb: "4px"
  faderTrack: "2.5px"
  feedChip: "1px"
spacing:
  leadingInset: "14px"
  trailingInset: "14px"
  indentedLeadingInset: "30px"
  iconToName: "9px"
  nameToSlider: "12px"
  sliderToReadout: "6px"
  readoutToTrailingControl: "6px"
  bodyRowHeight: "42px"
  applicationsFooterRowHeight: "28px"
components:
  device-row:
    height: "42px"
    textColor: "{colors.label}"
  device-row-hover:
    backgroundColor: "{colors.selectedContentBackground}"
    rounded: "{rounded.selectionHighlight}"
  fader-track:
    backgroundColor: "{colors.well}"
    rounded: "{rounded.faderTrack}"
    height: "5px"
  fader-thumb:
    backgroundColor: "{colors.faderThumb}"
    rounded: "{rounded.faderThumb}"
    width: "10px"
    height: "17px"
  feed-pill:
    backgroundColor: "{colors.feedPillFill}"
    rounded: "{rounded.feedPill}"
    padding: "2px 4px"
  halo-ring:
    size: "30px"
  bus-node:
    backgroundColor: "{colors.gold}"
    size: "13px"
  route-armed-dot:
    backgroundColor: "{colors.gold}"
    size: "8px"
  route-armed-dot-idle:
    backgroundColor: "{colors.dotSocket}"
    size: "8px"
  button-gold-cta:
    backgroundColor: "{colors.goldCTA}"
    textColor: "#FFFFFF"
  grouped-section:
    backgroundColor: "{colors.panel}"
    rounded: "{rounded.groupedSection}"
  banner:
    rounded: "{rounded.banner}"
    padding: "11px"
  ios-device-row:
    height: "60px"
    rounded: "16px"
  ios-main-out-deck:
    rounded: "26px"
  ios-mute-button:
    backgroundColor: "{colors.well}"
    rounded: "10px"
    size: "28px drawn, 44px hit target"
---

# Design System: Audiouter

**Scope.** This is the cross-platform record: the shared Warm Signal world, and how each of the two native surfaces expresses it. The macOS app (AppKit) is documented here in full; the iPhone companion is summarised here and documented in depth in its own file.

### Sources of truth

This document describes the system. These four files *are* it, and they win over anything written here:

| Source | Owns |
|---|---|
| `AudiouterCore/Sources/AudiouterSharedUI/Tokens.swift` | Every colour, type, motion and material token on macOS — and the only place in the codebase a hex literal may appear |
| `AudiouterCore/Sources/AudiouterSharedUI/PopoverColumnGrid.swift` | All macOS geometry: rows, columns, gaps, instrument dimensions |
| `docs/FIGMA-DESIGN-SYSTEM.md` | The code↔Figma contract, the Circuit light mapping and its measured contrast, and the upkeep rubric for keeping the Figma file true to the code |
| `ios/AudiouterRemote/DESIGN.md` | The iPhone surface in full. Its own authority; not superseded by this file |

**The Figma file** (`aGvr1qZ3tbqGD2e3jmA1Ru`) is bound to the code by *naming, not tooling* — Code Connect is blocked on seat licensing. Colour variables mirror `Tokens.Color` case names 1:1, layout variables mirror `PopoverColumnGrid` constants 1:1, and every variable carries its exact Swift constant as Code Syntax. That string is how a design change made in Figma names its own landing spot in code. Component descriptions name their Swift source file. Variant properties are named after the code's state enums. **Code wins over spec** — the file draws what the code does today; spec-only ideas live on the *Reference · Spec backlog* page.

**Layers are tagged `SYSTEM` or `OURS`.** `SYSTEM` layers are instances from the macOS 27 UI kit and are never rebuilt or restyled — only re-instanced. `OURS` layers are Warm Signal custom drawings. That tag is the "native structure, custom instruments" split made checkable.

### Three things a reader must know before trusting a value

1. The `ios/` directory lives on the `claude/ios-staging` branch and is absent from `main`, so the iOS pointer above dangles in a `main` checkout.
2. The two platforms **ship different light grounds on purpose** — flat near-white on Mac, a stepped ladder on iOS. See *The Two Light Grounds Rule* under Colors before assuming either is wrong. Dark mode is identical across both.
3. **Parts of the Figma file are stand-ins, not code truths.** Do not "fix" the code to match them: JetBrains Mono stands in for SF Mono (SF Mono is unavailable in Figma); SF Symbols are placeholder vectors, not the real glyphs; the dark canvas grain is not rendered at all (it exists only in `WarmCanvasView.swift`); `separator`, `underPageBackground`, `selectedContentBackground` and `tertiarySystemFill` are approximations of dynamic system colours; computed blends (the armed fader's ember-toward-gold gradient, the diagnosis panel's failure-tinted fill) are stored as dark-appearance literals because the code computes them at runtime; and the System-accent dial position is documented text rather than a variable mode, because an accent multiplier cannot be one.

## Overview

**Creative North Star: "The Instrument in a Dark Room"**

The room dims; the instruments hold their values. Everything structural in Audiouter — surfaces, dividers, sidebars, text, wells — recedes into a warm near-black ground and re-themes freely with the appearance. The instruments do not. Gold, failure red, caution amber, the connection rings, the meters, the fader hardware and the four permission hues keep their authored values in every appearance, every contrast setting, and every position of the accent dial, because each of them carries meaning that a theme has no business editing. That split — themed scaffolding, unthemed instruments — is the single load-bearing idea in the system, and almost every rule below is a consequence of it.

The room is warm rather than neutral on purpose. Audiouter is a mixing desk for a house, and its ground is the colour of a console in a listening room at night: `#16130F`, near-black but unmistakably warm, with a procedurally grained canvas in dark mode so a large flat surface has tooth rather than sitting dead. Onto that ground the app draws almost nothing at rest. A device that is connected but idle shows a hue-neutral warm-grey ring and nothing else. Gold arrives only when something is actually live — a route armed, a node joined to the rail, a meter moving — and it is drawn as small, bright, physically specific marks: a 13pt filled node, an 8pt dot with a bloom, a 2pt line. The scarcity is the mechanism. If gold were decoration, none of it would read.

Structure is not where the identity lives. Stock AppKit controls, SF Symbols, system materials and macOS grouped-list idioms carry navigation, chrome and every control the platform already draws well; the Figma file even tags every layer `SYSTEM` or `OURS` so the boundary can never blur. Warm Signal owns the ground, the accent, the type voice and the drawn instruments — and nothing else. On iPhone the same split holds against a different rulebook: HIG structure, Dynamic Type throughout, Liquid Glass for the one genuinely floating surface, and the identical instrument hues drawn as SwiftUI.

**Key Characteristics:**
- Themed scaffolding, unthemed instruments — the split that generates every other rule
- Gold is scarce and means *live*; a connected-but-idle device gets warm grey, not gold
- Every custom colour ships four authored values (light, light-HC, dark, dark-HC) with a measured contrast rationale written beside it
- One file may contain a hex literal; every other call site reaches colour through a token
- Native structure, custom instruments — the platform draws what it draws well
- A bold, tracked-out, uppercase monospaced micro-voice states facts; plain system type carries prose and names
- Bare numbers and units, never named presets, in every readout

## Colors

A warm near-black ground carrying a single gold signal accent, with a hand-authored light palette that is a second design rather than an inversion.

### Primary

- **Lit Brass** (`#E8B84B` dark / `#A67C1E` light): THE accent. Bus-node fill, route-armed dot, meter hot end, the rail spine while armed. Graphic use only — its light value clears the 3:1 non-text floor but fails 4.5:1 as text, which is what `goldCTA` exists to solve. One of only three tokens the accent dial remaps.
- **Banked Ember** (`#8A6A2F` dark / `#9C7E3C` light): gold's dim companion — the rail line ink, a filled node's rim, the meter's low end, the spine tone while idle. Dimmer than gold by luminance in dark, but by **chroma** in light: both inks are pinned just over 3:1 on the same ground, so light ember reads as less saturated rather than lighter (0.62 vs gold's 0.82 at the same ~41° hue).
- **Bloom** (`#FFD97A` dark / `#E8B84B` light): the halo and arm-transition bloom around the route-armed dot. Floor-exempt — it never carries meaning alone; the ≥3:1 disc beneath it does. Resolves fully transparent at the Subtle dial position.
- **Deep Brass** (`#815E0E` dark / `#775913` light): the one gold that may sit under white text — the Setup finale's "Start listening" button. The flagship gold cannot fill a text-bearing control (white on light gold measures 3.80:1), so this is the gold family deepened until white ink wins decisively while the fill still clears 3:1 against the canvas. Never remapped by the accent dial: it is contrast-governed on both sides.

### Secondary — the instrument set

- **Hue-Neutral Warm Grey** (`#8D7D5E` dark / `#A08C66` light): the connected ring, and the dashed connecting ring. Deliberately not gold — connection is not the same as live, and giving connection the accent would spend the system's scarcest signal on its most common state.
- **Signal Red** (`#D9564A` dark / `#BB3A2F` light): failure-exclusive. The failed connection ring, the failed row's sublabel, the diagnosis panel. Never remapped by anything.
- **Hot Amber** (`#E29A3D` dark / `#B3701C` light): the meter's ceiling. The warm meter gradient tops out here and never reaches red.
- **Worn Brass Knob** (`#857762` dark / `#8A7A62` light) and **Trough Rim** (`#6B5F4E` / `#9E8D6B`): the fader's grab handle and the 1px edge of its recess. Both are instrument-grade with real measured floors, because the earlier surface tokens used for these measured 1.09:1 and 1.21:1 — invisible.
- **Empty Socket** (`#34302A` dark / `#E0D8C6` light): the route-armed dot at rest. Deliberately quiet (1.33:1) — "nothing armed" must not compete with the lit dot.
- **Recessed Channel** (`#4E463A` dark / `#CBBEA1` light): the level meter's empty track. A meter reads a ratio, so the denominator has to stay visible at every level including zero — but it sits below the fill drawn over it so the fill still wins.

### Tertiary — permission identity hues

Four hues that give onboarding's permission rows a permanent identity, warmed and deepened off each permission's original macOS colour family: **Warm Slate** (`#5B93C4`, from systemBlue), **Dusty Plum** (`#9A6BC6`, from systemIndigo), **Muted Mauve** (`#C066A2`, from systemPurple), **Deepened Brass** (`#B86F41`, replacing systemTeal). The hue lands on the SF Symbol glyph only; the tile keeps its neutral fill. Granting never recolours the glyph — the row's status chip carries state.

### Neutral — the ground ladder

- **Warm Near-Black** (`#16130F` dark / `#FBFBF9` light): the canvas behind everything, and the control-panel shell's own fill so chrome and content read as one warm shape. Dark mode adds a 48×48 procedural grain tile.
- **Lifted Near-Black** (`#1B1712` / `#FBFBF9`): the canvas gradient's top stop. In light it is identical to canvas — the gradient collapses flat on purpose.
- **Panel** (`#1D1915` / `#FBFBF9`) and **Raised** (`#241F1A` / `#FBFBF9`): card fill and icon wells. In light, all three collapse to one value; surface separation there comes from hairlines, not fill steps.
- **Deep Well** (`#100D0A` / `#E8E6DC`): the recess — fader troughs, dropdown fills. In dark it is *darker* than canvas, so the recess is real rather than a faintly raised strip.
- **Hairline** (`#3A332B` / `#D0CDC3`): the 1px section divider, and the only visual separation between de-nested cards.
- **Warm Sidebar Wash** (`#1F1A15` / `#F5F4ED`): the Groups sidebar. On macOS 26+ it rides at ~0.30 alpha over Apple's automatic Liquid Glass sidebar (there is no public API to tint the glass itself); below 26 the same colour is drawn fully opaque as the whole backing.

Text, dividers, selection washes and system fills are stock semantic `NSColor`s — `labelColor`, `secondaryLabelColor`, `separatorColor`, `controlAccentColor` and their siblings. They already resolve appearance and Increase Contrast correctly, so they are aliased, not re-authored.

### Named Rules

**The One Hex Rule.** `Tokens.swift` is the only file in the codebase where a colour may be written as a hex or RGB literal. Every other call site — views, controllers, drawing code across all five UI packages — reaches colour through `Tokens.Color`. A raw `NSColor` at a call site is a defect, not a shortcut.

**The Instruments Never Theme Rule.** Themes may remap scaffolding — canvas, panels, wells, dividers, sidebar, text. They may never remap an instrument. Gold, ember, glow, failure, caution, the rings, the meters including `meterTrack`, the fader hardware and the four permission hues keep their authored values in every appearance and every dial position. Red stays red; caution stays caution.

**The Four-Value Rule.** Every custom colour ships light, light-high-contrast, dark and dark-high-contrast values, and every one of them carries a written contrast rationale with the measured ratio and the surface it was measured against. A token added without its measurement is not finished.

**The Failure-Never-Meters Rule.** Failure red never appears in a meter. The warm meter gradient tops out at caution amber, so a loud party can never impersonate a broken speaker.

**The Reserved-Bands Rule.** Two hue windows are reserved and no derived or identity colour may land in them: the gold/amber window `[28°, 68°)`, because a colour there misreads as "armed"; and the failure-red window `[0°, 12°) ∪ [350°, 360°)`. Runtime-derived colours (per-app tether tints) steer out of both, and the permission hues sit ≥47° apart from each other and from both bands.

**The Two Light Grounds Rule.** Dark mode is byte-identical across both platforms. Light mode is deliberately **not**, and the difference is a decision rather than drift.

Mac light is the **Circuit theme**: `canvas`, `canvasHi`, `panel` and `raised` all resolve to the same near-white `#FBFBF9`, and surface separation comes entirely from hairlines. iOS light keeps a **stepped ladder** — `#F4F2EA` canvas rising to `#FFFFFF` raised in ~1.12:1 steps, about what a white cell gets from `systemGroupedBackground`. That was chosen against the flat ground on 2026-08-10 (`cb9b30a7`), because a flat light ground left "a speaker's halo, a panel and the screen behind them … one pixel value — instruments floating on nothing, while dark read as built." Moving the ground down rather than pushing surfaces up is what paper does, and what grouped tables do on that platform.

**The direction is one flat white ground on both platforms** (Alec, 2026-08-12): *"The white, the flat light ground is what we want. We need to figure out a way to have contrast."* So the ladder is not the destination — but neither is today's Mac, where hairlines carry the entire separation load and `cb9b30a7`'s critique still applies. The open problem is the mechanism: hairline borders, recession, a per-appearance shadow, inset/grouped-table geometry, or a combination. That exploration is in flight on `claude/light-separation-options`, which owes rendered comparisons and measurements before anything is chosen.

**Until it lands, change neither ground.** Both are load-bearing and both were reasoned; picking one unilaterally would trade a known divergence for an unmeasured one.

What *was* genuine drift on iOS — three instrument values that had gone stale or never cleared their floor — is fixed on `claude/ios-light-circuit`: `hairline` `#E7E6DF` → `#D0CDC3` (it measured 1.04:1 against `well`), `ember` `#C2A05A` → `#9C7E3C` (it cleared 3:1 against nothing — 2.06:1 on `well`), and `gold` `#A97F1E` → `#A67C1E`. Instruments are shared across platforms; grounds are not.

**Open, and it needs both platforms decided at once:** `ringConnected` / `ring` `#A08C66` measures 3.08:1 against the Mac's light `panel` — passing, tight, already flagged for the accessibility sweep — but only **2.71:1** against the iOS light `well` it is actually drawn over there. One hex, two grounds, one pass and one fail. Retuning either platform alone trades one divergence for another.

## Typography

**Body Font:** San Francisco — system on both platforms (`NSFont.systemFont` on Mac, SF Pro under Dynamic Type on iOS).
**Micro/Readout Font:** the system monospaced design (SF Mono), reserved for two jobs — the uppercase micro-label voice and numeric readouts.

**Character:** two voices, and the split is about who is speaking. A plain system face carries anything a person reads as prose or a name — device names, headings, sentences the app or the Mac wrote. A bold, tracked-out, uppercase monospaced voice carries anything the screen *states as a fact*: a level, a state word, a count, a section caption. The mixing desk is in the second voice; the household language is in the first.

### Hierarchy

- **Heading** (semibold, 16pt / `systemFontSize + 3`): device-detail and group-editor name fields.
- **Title Large** (regular, 15pt) and **Subtitle Large** (regular, 12pt): paired for large empty-state messages.
- **Body** (regular, 13pt / `NSFont.systemFontSize`): the most common label in the app — row names, headings, form labels. **Body Emphasized** (semibold) for permission-row and section titles; **Body Bold** marks an active or selected row name.
- **Caption** (regular, 11pt / `NSFont.smallSystemFontSize`): all secondary and detail text — sublabels, readouts, hints, footers. **Caption Medium** and **Caption Emphasized** step it up for tiles and small row titles.
- **Micro Label** (bold, 8.5pt monospaced, uppercase, +0.09em tracking): the state vocabulary — `LIVE` / `MUTED` / `IDLE` — and section captions. 8.5pt is the bottom of the spec's band, sized so it rides as a leading token *inside* an existing 11pt sublabel line without changing that line's height.
- **Sync Readout** (medium, 12pt monospaced digits): the click-to-edit sync value. Monospaced digits so the number keeps its width as it steps.

On iOS every size is a `@ScaledMetric` relative to a system text style, never a bare point size, and the micro-label voice sits at an 11pt floor rather than 8.5 — the HIG minimum for any text, and the reason the two platforms' micro-voices are not the same size.

### Named Rules

**The Micro-Voice Rule.** The tracked-out uppercase monospaced voice is for facts the screen states — levels, state words, counts, section captions. It is never used for a sentence, a name, or anything the app did not author itself.

**The No-Reflow Rule.** A micro-label riding inside an existing line is sized to that line's height. Adding state vocabulary to a row must not change the row's geometry.

## Layout

The macOS geometry authority is `PopoverColumnGrid` — one file, every constant named, and the Figma file mirrors those names 1:1 with slash prefixes (`rows/bodyRowHeight`, `columns/sliderWidth`).

Rows are a fixed **42pt** with a 14pt inset on both edges (30pt when indented), and the columns run at fixed widths from the trailing edge inward: a 140pt trailing control, a 40pt readout, a 150pt slider, a 24pt mute, a 26pt icon. Gaps are small and specific — 9pt icon-to-name, 12pt name-to-slider, 6pt slider-to-readout and readout-to-trailing-control. Because positions are anchored from the trailing edge rather than laid out left to right, every row in every surface aligns on the same vertical rules regardless of name length.

The membership rail runs in its own 30pt column at a 20pt centre line, with 12pt of clearance around each node. Instruments have their own geometry vocabulary: a 30pt halo ring at 1.6pt stroke (1.8pt when failed, dashed 2.6/2.6 when connecting), a 34pt Main Audio ring, a 13pt bus node (15 selected, 11 unselected) on a 2pt line, an 8pt route-armed dot with a 3.5pt glow radius, a 5pt fader track carrying a 10×17pt thumb.

The macOS primary surface is a pinnable popover hosting Mixer, Groups and Settings; a fuller window exists for groups and settings. On iPhone the model is a single scrolling `ScrollView` + `LazyVStack` — deliberately not `List`, because every row is custom-drawn and carries its own horizontal drag gesture that `List`'s cell chrome would fight. Rows there are 60pt (8pt air, a 44pt halo, 8pt air), and the Main Out deck is a bottom `.overlay` rather than a `.safeAreaInset`, so content keeps scrolling underneath the frosted glass instead of stopping above it.

## Elevation & Depth

*Descriptive — the depth doctrine is not settled, so this records what the code does rather than fixing a rule.*

Both surfaces are close to flat, and both get their depth from the tonal ground ladder plus a hairline rather than from shadows. On macOS the cards were de-nested: they no longer draw their own material, shadow or rim, and the 1px hairline is the only visual separation left between sections. The ladder itself does the work — canvas → canvasHi → panel → raised, with `well` sitting *below* canvas as a true recess.

Shadow, where it appears, is currently doing one of two jobs. It marks something genuinely floating: the iPhone's Main Out deck carries the only shadow on its entire screen, tuned per appearance because one value cannot serve both grounds. Or it is a glow marking live state: the route-armed dot's bloom, the halo ring's arrival bloom, the rail bead's travelling glow. The onboarding demo pane also carries a conventional drop shadow (radius 18, opacity 0.55 dark / 0.28 light) as a presentation surface.

### Shadow Vocabulary

- **Armed-dot glow** (`shadowRadius: 3.5`, `shadowOpacity: 0.6`, colour `glow`): the route-armed dot's static halo. Registered as a Figma effect style.
- **Ring bloom** (`shadowRadius: 4`, `shadowOpacity: 0.8`): the halo ring's arrival bloom when a connection lands.
- **Demo-pane lift** (`shadowRadius: 18`, `shadowOpacity: 0.55` dark / `0.28` light): the onboarding demo surface.

## Shapes

Corners are small, specific and shared rather than scaled. Three radii are consolidated in `Tokens.Layout` precisely because they were previously duplicated across UI packages: the rounded-panel body at **12pt** (the control-panel shell, the quit HUD), the inset banner at **11pt**, and the macOS grouped inset-list card at **10pt** — that last one explicitly modelled on the System Settings idiom, so the app's cards read as the platform's cards.

Below those, radius drops fast and tracks the size of the object: 7pt for a selection highlight or mute pill, 6pt for a title field, 5pt for the FEED pill and sync chip, 4pt for the fader thumb, 2.5pt for the fader track, and 1pt for the 7pt FEED chip. Nothing is fully rounded except iOS's capsule fader track.

The form language of the instruments is circles and lines: rings, discs, dots, a 2pt rail with a 6.5pt detour bulge and a hooked landing. The rail is drawn as **one continuous wire** from origin through every joined node to its terminus — never as a recessed groove, and never as separate segments that happen to align.

iOS runs a larger radius family suited to a touch surface: 10pt controls, 16pt rows, 26pt on the Main Out glass panel.

## Components

### Faders

- **Character:** the daily-primary control, and the one place the system spends instrument-grade colour on ordinary hardware.
- **Shape:** a 5pt track at 2.5pt radius carrying a 10×17pt thumb at 4pt radius.
- **Colour:** the track is `well` — genuinely darker than canvas, so the recess reads — outlined by a 1px `faderRim` that is load-bearing where no fill covers it. The thumb is `faderThumb`, held to ≥3:1 against *both* canvas and well in both appearances.
- **Disabled:** 0.4 alpha.
- **Why dedicated tokens:** the surface tokens originally used here measured 1.09:1 (thumb) and 1.21:1 (rim). The fader sank into the canvas. Instrument-grade values with measured floors are the fix, and reusing a surface token here is a regression.

### Rows

- **Character:** quiet until it matters. A row at rest is a name, an icon and a ring; state arrives as small marks rather than as a change of the row itself.
- **Shape:** 42pt tall, hover and selection washes drawn at 7pt radius inset 5×2pt.
- **States:** hover wash at 0.10 alpha, selection at 0.18. A muted row shows an engaged slashed-glyph pill (0.22 alpha fill, 7pt radius) — a mute is a control that looks engaged, not merely a tint.
- **iOS variant:** the row *is* the fader. A horizontal drag anywhere on it sets the level, there is no separate slider, and the fill runs edge-to-edge ignoring the row gutter so the finger and the fill's edge can never disagree about where the value is.

### Connection ring (halo)

- **Character:** the app's most-repeated instrument, and the reason gold stays scarce.
- **Shape:** a 30pt ring with 6pt of breathing room around a 26pt icon.
- **States:** connected is a 1.6pt solid `ringConnected` stroke; connecting is the *same colour* as a 2.6/2.6 dash — form carries pending, not a new hue; failed is a 1.8pt `failure` stroke. Driven by connection state alone.

### Membership rail

- **Character:** the signature component — a literal drawing of what is joined to what.
- **Shape:** one continuous 2pt line in its own 30pt column, with 13pt nodes (15 selected, 11 unselected), a 1.5pt rim, a 6.5pt detour bulge around skipped rows, and a hooked landing onto the Main Audio ring.
- **Colour:** the whole spine resolves its tone from one place (`spineTone`) — gold when armed, ember otherwise — because the rail and the ring it lands on are required to read as a single continuous line. Two instruments picking gold independently is how the accent dial once moved one and not the other.

### Route-armed dot

- **Character:** the smallest thing in the app that means the most.
- **Shape:** an 8pt disc in an 18pt box.
- **States:** armed is `gold` with a 3.5pt `glow` bloom at 0.6 opacity; at rest it is `dotSocket`, a quiet recess that must not compete with the lit state.

### Level meter

- **Shape:** a 74×3pt strip under the name; 6pt thick for the master.
- **Colour:** a warm gradient from `ember` at the low end to `gold`, ceilinged at `caution`. The empty track is `meterTrack` — visibly present at every level, because a meter reads a ratio and the denominator has to be legible even at zero.

### FEED pill

- **Shape:** 5pt radius, 4×2pt padding, 3pt gaps.
- **Colour:** reads by **fill alone**. Its border was removed after measuring 1.14:1 dark and 1.00:1 light against its own fill — decorative in both modes. Text is `feedPillText`, which resolves `secondaryLabel` in dark but `label` in light, because secondary text on the light fill measured 4.54:1 while `label` lifts it to 10.66:1.

### Buttons and stock controls

- **Character:** calibrated, not styled. Sliders, checkboxes, switches, segmented controls, pop-up buttons and push buttons are stock AppKit, instanced from the macOS 27 UI kit in Figma and tagged `SYSTEM`. They are never rebuilt or restyled.
- **The one exception:** the Setup finale CTA, filled `goldCTA` with white text — the single text-bearing control the system fills with its own colour, and it exists only because it was measured into existence on both sides (ink and canvas).

### Grouped sections and banners

- **Grouped section:** 10pt radius, explicitly the macOS System Settings inset-list idiom, shared by onboarding's permission card and the Groups window.
- **Banner:** 11pt radius, tinted by tier — `info` blue for notes, `caution` for the one banner that is an actual problem.

### iOS Main Out deck

The companion's signature surface: a frosted `.ultraThinMaterial` panel at 26pt radius carrying a warm `deckFill` tint — deliberately warmer than plain glass, never a neutral grey — with a single 11% white edge stroke. It floats as a bottom overlay so the list scrolls beneath it, and it carries the only shadow on the screen.

## Do's and Don'ts

### Do:

- **Do** reach every colour through `Tokens.Color`. `Tokens.swift` is the one file allowed to contain a hex literal.
- **Do** ship four authored values per custom colour — light, light-HC, dark, dark-HC — each with a written, measured contrast rationale naming the surface it was measured against.
- **Do** measure against the ground the instrument is actually drawn on. Light gold and ember were both retuned on 2026-08-12 after measuring fine on `panel` but failing the 3:1 floor on `well`, which is what the Groups editor actually fills its sections with.
- **Do** spend gold only on *live*. Armed routes, joined nodes, moving meters. A connected-but-idle device gets `ringConnected`.
- **Do** carry state by form when a new colour would cost more than it earns — the connecting ring is the connected ring, dashed.
- **Do** use stock AppKit controls and SF Symbols for anything the platform draws well, and let Warm Signal own the ground, the accent, the type voice and the drawn instruments.
- **Do** make a token mode-aware when one value cannot serve both grounds, rather than forking the component. `feedPillText` is the pattern.
- **Do** honour Reduce Motion at every animation site, and run every fold and reveal on the one shared 0.15s clock (`Tokens.Motion.collapseRevealDuration`) so an expand is the exact mirror of its collapse.
- **Do** state facts in the tracked uppercase monospaced micro-voice and prose in plain system type.
- **Do** show bare numbers and units in readouts, never named presets.
- **Do** mirror a new or changed token into the Figma file in **all four appearance modes**, with its scopes and its exact Swift constant as Code Syntax, and update the swatch table on the matching Foundations page. The upkeep rubric in `docs/FIGMA-DESIGN-SYSTEM.md` is the step-by-step.
- **Do** resolve every new element in **both** appearances. Light is not a coat of paint applied later; it is the second half of every token. Bind scaffolding to tokens and light mode is free — hardcode and you have silently shipped a dark-only element.
- **Do** add a new element to the **light twin** of every Figma screen it appears on. Twins are clones, not instances, so an edit mirrored into only one of them diverges silently.
- **Do** verify a screen change against the checked-in snapshot PNGs under `dev/notes/*-snapshots/` (popover, window, settings, onboarding — light and dark).

### Don't:

- **Don't** hand-roll blur or glassmorphism. Use the system materials the platform provides — `NSVisualEffectView` on Mac, `.ultraThinMaterial` on iOS — and nothing else. Chrome that isn't a system material paints the warm canvas.
- **Don't** let a theme remap an instrument. Gold, ember, glow, failure, caution, the rings, the meters including `meterTrack`, the fader hardware and the permission hues keep their authored values in every mode.
- **Don't** put failure red in a meter. The gradient ceilings at caution.
- **Don't** land a hue in the reserved bands — gold/amber `[28°, 68°)` or failure-red `[0°, 12°) ∪ [350°, 360°)`.
- **Don't** fill a text-bearing control with the flagship `gold`; white on it measures 3.80:1. Use `goldCTA`.
- **Don't** reuse a surface token as an instrument. `raised` as a fader thumb measured 1.09:1; `hairline` as its rim measured 1.21:1.
- **Don't** draw the membership rail as a recessed groove or as separate aligned segments. It is one continuous wire.
- **Don't** run a second animation clock alongside `FoldAnimator`. Two clocks kept in step by hand silently drift.
- **Don't** invent a Figma component for a stock control the macOS 27 kit doesn't ship. Leave a labelled positional placeholder and point at the HIG — a hand-built stand-in diverges from the real control, which is worse than nothing. Tab views are the known case, and the components that briefly existed for them were deleted for exactly this reason.
- **Don't** reuse a dark-mode hex in light mode. It measured 2.17:1 the one time it happened.
- **Don't** rebuild, restyle or redraw a layer tagged `SYSTEM`. Re-instance it from the macOS 27 kit. (The file is also subscribed to a macOS 26 kit — do not use it.)
- **Don't** change the code to match a Figma stand-in. The list of known stand-ins is in the preamble above; treat anything on it as a Figma limitation, not a spec.
- **Don't** add an `Appearance=Light|Dark` variant axis to a Figma component. Appearance is a variable **mode**, never a variant axis — an axis doubles every set and duplicates all future edits.
- **Don't** put paint-level opacity on a variable-bound paint in Figma. Use a full-strength bound fill on a child node and set that node's opacity.
