---
name: Audiout
description: A dark room with lit instruments in it — warm near-black scaffolding that themes, signal colour that never does
colors:
  canvas: "#16130F"
  canvasHi: "#1B1712"
  panel: "#1D1915"
  raised: "#241F1A"
  well: "#100D0A"
  hairline: "#3A332B"
  containerEdge: "#3A332B"
  sidebarWarmTint: "#1F1A15"
  inkSecondary: "#B4ADA0"
  inkTertiary: "#969083"
  railDormant: "#7D7466"
  gold: "#E8B84B"
  ember: "#8A6A2F"
  glow: "#FFD97A"
  goldCTA: "#815E0E"
  inkOnGold: "#000000"
  caution: "#E29A3D"
  failure: "#D9564A"
  warningText: "#D08A45"
  success: "#5FC27E"
  ringConnected: "#8D7D5E"
  faderThumb: "#857762"
  faderRim: "#6B5F4E"
  meterTrack: "#4E463A"
  dotSocket: "#4A443B"
  feedPillFill: "#38322B"
  plateRim: "#7E7160"
  stagePlate: "#100B07"
  stageRule: "#6A5F50"
  stageInk: "#EFE9DD"
  syncSignal: "#2BFF8F"
  partySignal: "#FF90E9"
  fuseWhite: "#FFF4E2"
  permissionSystemAudio: "#5B93C4"
  permissionLocalNetwork: "#9A6BC6"
  permissionRemoteControl: "#C066A2"
  permissionSpeakerSync: "#B86F41"
  permissionUsageStats: "#3F977A"
  bluetoothBrand: "#0082FC"
typography:
  displayLarge:
    fontFamily: "SF Pro (system)"
    fontSize: "24pt"
    fontWeight: 700
  display:
    fontFamily: "SF Pro (system)"
    fontSize: "20pt"
    fontWeight: 700
  heading:
    fontFamily: "SF Pro (system)"
    fontSize: "16pt (systemFontSize + 3)"
    fontWeight: 600
  titleLarge:
    fontFamily: "SF Pro (system)"
    fontSize: "15pt (systemFontSize + 2)"
    fontWeight: 400
  body:
    fontFamily: "SF Pro (system)"
    fontSize: "13pt (NSFont.systemFontSize)"
    fontWeight: 400
  bodyEmphasized:
    fontFamily: "SF Pro (system)"
    fontSize: "13pt"
    fontWeight: 600
  caption:
    fontFamily: "SF Pro (system)"
    fontSize: "11pt (NSFont.smallSystemFontSize)"
    fontWeight: 400
  detail:
    fontFamily: "SF Pro (system)"
    fontSize: "11pt"
    fontWeight: 400
  syncReadout:
    fontFamily: "SF Pro (system)"
    fontSize: "12pt (smallSystemFontSize + 1)"
    fontWeight: 500
    fontFeature: "monospacedDigit"
  microLabel:
    fontFamily: "SF Pro (system)"
    fontSize: "10pt"
    fontWeight: 600
    textCase: "sentence case as authored — never transformed"
  keycap:
    fontFamily: "SF Mono (system monospaced)"
    fontSize: "11pt"
    fontWeight: 500
rounded:
  chip: "1px"
  faderTrack: "2.5px"
  faderThumb: "4px"
  feedPill: "5px"
  pill: "7px"
  groupedSection: "10px"
  banner: "11px"
  panel: "12px"
spacing:
  leadingInset: "14px"
  trailingInset: "14px"
  indentedLeadingInset: "30px"
  iconToLabelGap: "8px"
  busNodeClearance: "12px"
  bodyRowHeight: "42px"
  surfaceWidth: "623px"
  sidebarWidth: "210px"
components:
  button-cta:
    backgroundColor: "{colors.goldCTA}"
    textColor: "#FFFFFF"
    typography: "{typography.body}"
    rounded: "{rounded.pill}"
  fader-track:
    backgroundColor: "{colors.well}"
    rounded: "{rounded.faderTrack}"
    height: "5px"
    width: "150px"
  fader-thumb:
    backgroundColor: "{colors.faderThumb}"
    rounded: "{rounded.faderThumb}"
    height: "17px"
    width: "10px"
  feed-pill:
    backgroundColor: "{colors.feedPillFill}"
    typography: "{typography.microLabel}"
    rounded: "{rounded.feedPill}"
    padding: "2px 4px"
  grouped-section:
    backgroundColor: "{colors.panel}"
    rounded: "{rounded.groupedSection}"
  banner:
    backgroundColor: "{colors.raised}"
    typography: "{typography.detail}"
    rounded: "{rounded.banner}"
  device-row:
    backgroundColor: "{colors.canvas}"
    typography: "{typography.body}"
    height: "42px"
  halo-ring:
    textColor: "{colors.ringConnected}"
    size: "30px"
  bus-node:
    backgroundColor: "{colors.gold}"
    textColor: "{colors.ember}"
    size: "13px"
---

# Design System: Audiout

Scope: the **macOS app**. The iPhone companion lives in its own repository
(`aa-hh/audiout-remote`) and its `DESIGN.md` there is the authority for that
surface — it shares this system's instrument hues and its north star, and
speaks its own platform's language for everything else.

## Overview

**Creative North Star: "The Instrument in a Dark Room"**

Audiout is a mixing desk for a house, and it looks like one: a warm near-black
chassis you stop noticing, with a small number of lit parts you never stop
reading. The room is the scaffolding — canvas, panels, wells, sidebars,
dividers — and it takes whatever light the Mac is set to. The instruments are
the gold bus that carries audio, the meters, the rings around each speaker, the
fader hardware, the failure and caution hues. Those keep their authored values
in every appearance, because each one means something and a meaning that
changes colour with the system theme is a meaning you can't trust.

That split — themed scaffolding, unthemed instruments — is the load-bearing
idea here, and most of the rules below fall out of it. It is also why the light
appearance is not a lightened version of the dark one. Dark is Warm Signal at
full strength: a near-black ladder from `#16130F` up to `#241F1A`, glazed with a
deterministic 5%-white grain, with a true recess at `#100D0A` under every fader
trough. Light is the Circuit theme — a neutral, near-white greige sheet
(`#FBFBF9` canvas and panel, `#F2F0EA` raised, `#E2DFD3` well) where surface
steps are small and hairlines carry most of the separation. Two different rooms.
The same instruments hang on the wall in both, retuned only far enough to clear
their contrast floors on paper.

The system is restrained on purpose. Chrome is quiet, flat, and largely
unstyled: stock AppKit controls, SF Symbols, system fonts, system materials
where a material is right. The expression budget is spent on the handful of
custom instruments that show what the audio is doing — and on the discipline
that keeps everything else out of their way. Nothing here reaches for
hand-rolled blur or glassmorphism; that is the one visual direction this project
has explicitly refused.

**Key Characteristics:**

- Warm near-black chassis in dark, neutral Circuit greige in light — two rooms, not one theme inverted
- Gold means signal, and only signal: in the mix, carrying audio, armed
- Every custom colour ships four variants (light, dark, and Increase Contrast for each) with a measured contrast rationale
- Instrument colour is fixed; scaffolding colour is themed
- Stock AppKit structure, custom drawing only where an instrument needs it
- One motion duration for every fold in the app
- Quiet until it matters

## Colors

Two families that behave by different rules: a warm surface ladder that themes,
and a set of instrument hues that don't.

### Primary

- **Lit Brass** (`#E8B84B` dark / `#9E761D` light): THE accent. The membership bus node, the route-armed dot, the meter's hot end, the ring around a speaker that is carrying audio. Measured 9.5:1 against dark panel; the light value is deepened to 3.11:1 against the light well, the darkest ground it is ever drawn on. Nothing decorative wears it.
- **Banked Ember** (`#8A6A2F` dark / `#947637` light): gold's dim companion — the bus line itself, the filled node's rim, the meter's low end. Dimmer than gold by luminance in dark; in light both inks are pinned just over the 3:1 floor, so ember reads as *less chromatic* rather than lighter (saturation 0.41 against gold's 0.48 at the same ~42° hue).
- **Bloom** (`#FFD97A` dark / `#E8B84B` light): the halo and arm-transition bloom under an armed dot. Floor-exempt on purpose — it never carries meaning alone; the ≥3:1 gold disc beneath it does.
- **Deep Brass** (`#815E0E` dark / `#775913` light): the one gold a text-bearing control may be filled with — the Setup finale CTA. The flagship gold gives white only 3.80:1; this is deepened until white ink wins decisively (5.93:1 dark, 6.52:1 light) while the fill still clears 3:1 against the window canvas behind it.

### Secondary

The state instruments. None of these is ever remapped by anything.

- **Alarm Red** (`#D9564A` dark / `#BB3A2F` light): failure, and failure only.
- **Hot Amber** (`#E29A3D` dark / `#B3701C` light): the meter's ceiling and the caution tier. A loud party tops out here.
- **Scorched Amber** (`#D08A45` dark / `#A55B22` light): warning sublabel text, where amber has to carry words rather than a bar.
- **Signal Green** (`#5FC27E` dark / `#2C7A46` light): a grant earned, a check passed.
- **Worn Brass Ring** (`#8D7D5E` dark / `#A08C66` light): the connected halo around a speaker icon.

### Tertiary

Identity hues — colour used to tell two things apart rather than to report a
state. Each is warmed and deepened off the macOS system colour the row used to
wear, and each stays clear of the two reserved bands: gold/amber `[28°, 68°)`
and failure-red `[0°, 12°) ∪ [350°, 360°)`.

- **Warm Slate** (`#5B93C4` dark / `#3A79AE` light), ~208°: System Audio permission.
- **Dusty Plum** (`#9A6BC6` dark / `#7749B5` light), ~271°: Local Network permission.
- **Muted Mauve** (`#C066A2` dark / `#AF3E7F` light), ~320°: Remote Control permission.
- **Deepened Brass** (`#B86F41` dark / `#A55B22` light), ~23°: Speaker Sync. Sits deliberately *below* the gold band's 28° floor — golden-adjacent without impersonating the accent.
- **Verdigris** (`#3F977A` dark / `#167656` light), ~160°: Usage Statistics, the one row asking for Audiout's own consent rather than the system's. ~20° off Signal Green and never in the same slot: this is the tile's identity glyph, that is the checkmark beside it.
- **Bluetooth Blue** (`#0082FC`, fixed in every appearance): the Bluetooth SIG brand mark. A logo colour, so it does not theme and does not join the warmed family.

### Neutral

The scaffolding — the half of the system that themes.

- **Warm Near-Black** (`#16130F` dark / `#FBFBF9` light): the canvas behind everything, and the control-panel shell's own fill so chrome and content read as one shape.
- **Lifted Near-Black** (`#1B1712` dark / `#FBFBF9` light): the canvas gradient's top stop. Collapses flat in light on purpose.
- **Panel** (`#1D1915` dark / `#FBFBF9` light): card and section fill; the reference ground every instrument's contrast is quoted against.
- **Raised** (`#241F1A` dark / `#F2F0EA` light): icon wells, name fields, active fills. Light's value exists so light has a real raised rung at all — it used to be identical to panel, which left the light appearance with no ladder.
- **Deep Well** (`#100D0A` dark / `#E2DFD3` light): the recess. Darker than canvas in dark, so a fader trough reads as a genuine trough rather than a raised strip.
- **Hairline** (`#3A332B` dark / `#D0CDC3` light): the divider between de-nested sections, and in light the main thing doing the separating.
- **Container Edge** (`#3A332B` dark / `#C4C0B4` light): the heavier of the two hairline weights — a container's own outer stroke, where Hairline rules that container's interior. In light it clears the divider by 1.143:1, enough to rank the two without reading as a second material. In dark it resolves to Hairline's own values, because dark still has a fill ladder and light does not.
- **Sidebar Warm Tint** (`#1F1A15` dark / `#F5F4ED` light): the source-list ground in the Groups and Settings screens.
- **Warm Ink** (`#B4ADA0` dark / `#5C574C` light) and **Faded Ink** (`#969083` dark / `#665F4C` light): secondary and tertiary text where the system's own label colours sit under the text floor on the warm ground.
- **Dormant Rail** (`#7D7466` dark / `#8A8272` light): the membership rail before anything is armed.

Everything else in the app draws in stock semantic colours — `labelColor`,
`separatorColor`, `systemRed`, `systemOrange`, `systemBlue`. Those already
resolve their own appearance and contrast behaviour, and they are the reason
this palette is as small as it is.

### Named Rules

**The One Home Rule.** `AudioutCore/Sources/AudioutSharedUI/Tokens.swift` is
the only file in the codebase where a custom colour value may be written. Views,
controllers, and drawing code across every UI package reach colour through
`Tokens.Color` or they don't get it. A hex literal anywhere else is a defect,
not a shortcut.

**The Instruments Don't Theme Rule.** The gold family, failure, caution,
success, rings, meters, fader hardware, and the permission identity hues keep
their authored values in every appearance and are never remapped by a theme. If
a token carries meaning, the meaning owns its colour.

**The Two Weights Rule.** A container's outer edge draws in `containerEdge`;
the rules inside it draw in `hairline`. They are one mechanism at two ranks,
and the rank is free because nothing in this app is ever drawn *on* a hairline
— each is only ever a stroke or a divider fill, so separating them costs no
text and no instrument contrast. In light, `canvas`, `canvasHi` and `panel` are
the same `#FBFBF9`, so a container's edge is the only boundary pixel it has;
that is what the heavier weight exists for. Dark needs no second value and
does not get one.

**The Measured Floor Rule.** Every custom colour ships light, dark,
light-Increase-Contrast, and dark-Increase-Contrast values, each with a written
contrast measurement against the surfaces it is actually drawn on — not against
`panel` by default. Text clears 4.5:1, non-text instruments clear 3:1, and the
numbers are pinned in tests (`TokenContrastMatrixTests`,
`MembershipWellContrastTests`, `AlignmentTokenContrastTests`), so a retune that
breaks a floor fails the suite rather than shipping.

**The Dial Touches Three Rule.** The Appearance › Accent dial (Full gold /
Subtle / Follow system) remaps exactly three tokens: `gold`, `ember`, and
`glow`. Not failure, not caution, not the rings, not a single text token. Red
stays red and caution stays caution at every dial position.

**The Gold Means Signal Rule.** Gold means *in the mix, carrying audio*.
Painting a mute control gold states the opposite of what mute does; a gold hover
wash claims membership the pointer hasn't granted. Engaged chrome — mute pills,
the sync chip, row hover and selection washes — draws in the neutral
`engagedChrome` tone at graded alphas (hover 0.10 < selection 0.18 < mute fill
0.22 < full for a glyph or border). Strength separates them, never hue.

**The Meter Never Reds Rule.** The warm meter gradient tops out at Hot Amber.
Failure red never appears in a meter, so a loud party can never impersonate a
broken speaker.

## Typography

**Display Font:** SF Pro, the system face. There is no brand face on this
surface.
**Body Font:** SF Pro at `NSFont.systemFontSize` (13 pt).
**Mono Font:** the system monospaced face, used only for a stepping number and
for keycap chips.

**Character:** the type does no expressive work at all, and that is the
decision. Every size in the app is either a stock system size or a documented
step off one, so the app reads as a Mac app and the eye's whole attention budget
goes to the instruments. The one custom voice — the micro-label — earns its
place by weight, not by a face, a case transform, or a colour.

### Hierarchy

- **Display Large** (bold, 24 pt): one consumer, the first-open licence gate's headline, where the headline *is* why the window opened and has no sibling chrome to be measured against.
- **Display** (bold, 20 pt): Setup window step headlines.
- **Heading** (semibold, 16 pt): device-detail and group-editor name fields — the one step up from body.
- **Title Large** (regular, 15 pt) with **Subtitle Large** (regular, 12 pt): the mixer window's empty state, the only place a message is the whole screen.
- **Body** (regular, 13 pt) and **Body Emphasized** (semibold, 13 pt): row names, form labels, section titles. **Body Bold** marks the one active or selected row name.
- **Caption** (regular, 11 pt), with medium and semibold weights: sublabels, readouts, hints, footers, and row titles set at the small size.
- **Detail** (regular, 11 pt): the compact explanatory voice — alignment prompt copy, card notes.
- **Sync Readout** (medium, 12 pt, monospaced digits): the click-to-edit delay value in the Bluetooth sync drawer. Monospaced so the number keeps its width as it steps; sized one point over caption because two live findings cut a 26 pt and then a 15 pt version down for dwarfing and clipping.
- **Micro Label** (semibold, 10 pt): the state vocabulary ("Muted") and inline tags ("AP1").
- **Keycap** (medium, 11 pt, monospaced): "←", "→", "SPACE", "⏎" chips on the alignment wizard's plates.

### Named Rules

**The One Case Rule.** The micro-label is the plain system face, semibold,
sentence case exactly as authored. It replaced an SF Mono bold UPPERCASE + kern
treatment: a token that has to stand out from the body text sharing its line
does it by weight alone. Nothing in this app applies a case transform to a
string a human wrote.

**The No-Reflow Rule.** The micro-label is 10 pt because that is what the
sublabel line it rides in already is. A state word appearing or disappearing
must not change the height of its line, so a row never reflows when a speaker
mutes.

## Layout

The app is one fixed surface. `SurfaceLayout.width` pins every screen — Mixer,
Groups, Settings — to **623 pt** of content width; the two arrangement screens
carry a source-list sidebar pinned at **210 pt** min and max, leaving 413 pt of
content pane. Nothing here is fluid, and nothing resizes horizontally: the
surface is a piece of hardware with a fixed faceplate, and every screen reads
the same numbers so no two can drift apart.

Vertically the unit is the **42 pt body row** — a device, a group, an app, all
the same height. Rows lay out on a shared column grid
(`PopoverColumnGrid`, the geometry authority every layout token forwards to):
14 pt leading and trailing insets, a 30 pt indented inset for nested rows, a
26 pt icon column, a 150 pt fader, a 40 pt readout, a 24 pt mute column, and a
140 pt trailing control column. The membership bus runs in its own 30 pt gutter
at a fixed centre-line x of 20 pt, with 12 pt of clearance kept around every
node.

Density is deliberately tight — this is a control surface, not a document — but
never at the cost of a target: interactive elements keep real hit boxes even
where their drawn size is small (the bus node draws at 13 pt inside a wider hit
target; the route-armed dot draws at 8 pt inside an 18 pt box).

**The Grid Is The Authority Rule.** Row geometry lives in `PopoverColumnGrid`
and layout tokens forward to it. A view that needs a column width asks; it never
types a number. The same applies to the surface frame and both sidebars, which
read `SurfaceLayout`.

## Elevation & Depth

Depth here is **tonal, not cast**. Surfaces are flat: the ladder from `well`
through `canvas`, `panel`, and `raised` does the layering in dark, and in light —
where those steps are much smaller, and where `panel` on `canvas` is no step at
all — drawn edges carry most of the separation instead, at the two ranks the
Two Weights Rule sets out. Cards were explicitly de-nested: they no longer draw their own
material, shadow, or rim, and a hairline is the only thing between one section
and the next.

Shadow exists in the system, but almost never as elevation. It appears as a
**bloom under a lit instrument** — the halo around a connected speaker, the
route-armed dot's glow at 3.5 pt radius, the bead travelling the membership
rail, the alignment stage's span. In every one of those cases the shadow is the
same hue as the thing casting it and it means "this is live", not "this is on
top". The two real drop shadows in the app are on the onboarding demo pane and
its knob, and they sit outside the mixer's own vocabulary.

The canvas itself carries the only texture: a vertical gradient from `canvasHi`
down to `canvas`, glazed in dark mode with a fully deterministic ~5%-white
grain tile. In light the gradient collapses flat (both stops resolve to
`#FBFBF9`) and the grain is omitted entirely — white noise over near-white paper
reads as dirt, not texture. Under Reduce Transparency *or* Increase Contrast,
both the gradient and the grain are replaced by a flat opaque `canvas` fill.

Materials are used sparingly and only where the platform's own is right: the
system `menu` material behind the quit HUD, `windowBackground` behind the Setup,
Settings, and About windows. Everything else paints `WarmCanvasView`, which is a
plain layer-backed view with a custom `draw` — never an `NSVisualEffectView` —
so it is fully opaque in every accessibility mode by construction rather than by
a fallback path.

The depth doctrine is recorded here descriptively because it is **not settled**.
Do not promote "flat plus hairlines plus glow-means-live" into a rule without
asking first.

## Shapes

Corners are soft and small, and the radius says what kind of object something
is:

- **12 px** — the rounded panel: the control-panel shell's bubble body and the quit HUD.
- **11 px** — inset warning and note banners.
- **10 px** — the grouped inset-list card, modelled directly on the System Settings idiom (onboarding's permission card, the Groups window's sections). Its 1 pt outer stroke is `containerEdge`; the dividers between its rows are `hairline`.
- **7 px** — pills and the row selection highlight: the mute pill, the selection wash inset 5 pt horizontally and 2 pt vertically.
- **5 px** — the FEED pill, at 4 pt horizontal and 2 pt vertical padding.
- **4 px / 2.5 px** — the fader thumb (10 × 17 pt) and its 5 pt track.
- **1 px** — the 7 pt FEED chip, small enough that the radius is barely a chamfer.

The recurring silhouettes are circular: the 30 pt halo ring around a speaker
icon, the 34 pt Main Audio ring, the 13 pt bus node with its 1.5 pt rim, the
8 pt route-armed dot in its socket. Circles mean *a thing audio can flow to or
from*; rounded rectangles mean *a container or a control*. The membership bus
connects them with a 2 pt line that bulges 6.5 pt to detour around obstacles and
hooks 10 pt into the Main Audio ring — one continuous drawn line, not a stack of
segments.

## Components

### Buttons

- **Shape:** stock `NSButton` throughout — the app does not ship a custom button style. Rounded rect, system radius, system control sizes.
- **CTA (Setup finale):** Deep Brass fill (`#815E0E` dark / `#775913` light) with white ink at 5.93:1 / 6.52:1, and the fill itself clearing 3:1 against the window canvas. This is the only text-bearing gold control in the app.
- **Alignment wizard plates:** filled with gold's *dark-appearance* value in both appearances, with black ink pinned to match (11.4:1). A plate is a piece of hardware, so it does not flip with the window.
- **Hover / Focus:** system behaviour, untouched. Custom rows get a neutral `engagedChrome` wash at 0.10 alpha on hover and 0.18 on selection.

### Fader

The one piece of custom hardware every row carries. A 150 × 5 pt recessed
trough filled with `well` — genuinely darker than canvas in dark, so it reads as
cut into the surface — rimmed in `faderRim`, with a 10 × 17 pt thumb in
`faderThumb` at a 4 pt radius. Disabled drops the whole control to 0.4 alpha.
The trough's darkness is what makes everything drawn in it legible; the measured
consequence is that the fill colours over it gain contrast rather than sinking.

### Device Row

42 pt tall, on the shared column grid: icon well, name with an optional 74 × 3 pt
level meter under it, fader, readout, mute column, trailing control column. The
meter track is a quiet warm recess (`meterTrack`) that stays visible at zero,
because a meter reports a ratio and the denominator has to be there. The fill
runs ember at the low end to gold at the hot end, ceilinged at caution.

### Halo Ring

A 30 pt ring around the speaker icon carrying connection state by stroke, not by
colour alone: 1.6 pt solid in `ringConnected` when connected, 1.6 pt while
connecting, 1.8 pt dashed (2.6 pt on, 2.6 pt off) on failure. 6 pt of breathing
room is reserved around it so nothing crowds the ring.

### FEED Pill

The routing readout. Reads by **fill alone** — its border measured 1.14:1 in
dark and 1.00:1 in light against its own fill, so it was removed rather than
retuned. `feedPillFill` background, micro-label type, 5 px radius, 4 × 2 pt
padding, 3 pt between pills. Its text token is mode-aware: secondary label in
dark, full label in light, because secondary text on the light fill measured
4.54:1 — barely passing — while label lifts it to 10.66:1.

### Membership Bus

The signature component. A 2 pt line in ember running a 30 pt gutter, with gold
nodes (13 pt filled, 15 pt selected, 11 pt unselected) rimmed at 1.5 pt in ember,
hooking into the Main Audio ring at the top. Line and ring resolve their tone
from one place (`spineTone(armed:)`) because the two are required to read as a
single continuous line — when they each picked their own colour, the accent dial
moved one and not the other.

### Alignment Stage

A fixed dark instrument plate (`stagePlate` `#100B07`) that does **not** theme
with the window — in light mode it is deliberately a dark screen set into a
light chassis. It carries its own eight-token vocabulary including two signal
hues that exist nowhere else: `syncSignal` green `#2BFF8F` and `partySignal`
pink `#FF90E9`, used to tell one speaker's lane from another's. Neither is
accent-dial remapped, so the dial can never collide with "which speaker".

### Inputs

`WarmNameFieldCell` draws a `raised` well behind the text — a faint warm recess
in both appearances. Focus is the system focus ring, unmodified.

### Navigation

Two source-list sidebars (Groups, Settings), both pinned at 210 pt, both on
`sidebarWarmTint`, both with 22 pt icons and an 8 pt gap to the label. The
popover header carries icon-only tabs between the three screens.

## Do's and Don'ts

### Do:

- **Do** add every new colour to `Tokens.swift` with all four variants and a written contrast measurement against the surfaces it is actually drawn on, and pin the numbers in a test.
- **Do** reach for a stock semantic colour, font, or control first. The custom palette exists for instruments; everything else should be indistinguishable from the rest of macOS.
- **Do** measure a light instrument against `well`, not just `panel` — the Groups editor fills its sections with `well`, so the rail and its nodes run over the darker of the two grounds.
- **Do** read row geometry from `PopoverColumnGrid` and surface geometry from `SurfaceLayout`.
- **Do** use `Tokens.Motion.collapseRevealDuration` (0.15 s, `.easeInEaseOut`) for anything that folds. One value means an expand is the exact mirror of its collapse; a second constant kept in step by hand silently drifts.
- **Do** re-resolve colour on `viewDidChangeEffectiveAppearance`, on `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification`, and — if the view stamps `gold`, `ember`, or `glow` into a `CALayer` — on `Tokens.accentStyleDidChangeNotification`.
- **Do** stroke a container's outer edge with `containerEdge` and rule its interior with `hairline`. On the light ground a card's edge is the only thing separating it from the page.
- **Do** give a state-branching view an `else` branch. A resting halo with no else branch was an invisible bare fill at 1.000:1 on the flat light ground.

### Don't:

- **Don't** write a hex literal, an `NSColor(red:...)`, or a raw font size outside `Tokens.swift`.
- **Don't** hand-roll blur or glassmorphism. It is the one visual direction this project has explicitly refused.
- **Don't** paint mute, hover, or selection gold. Gold means carrying audio; those states mean the opposite or nothing.
- **Don't** let failure red into a meter.
- **Don't** remap failure, caution, success, the rings, or any text token with the accent dial. It touches `gold`, `ember`, and `glow`, and nothing else.
- **Don't** use `controlAccentColor` for engaged mixer chrome — it follows the user's macOS accent and paints `#007AFF` into a warm vocabulary. Use `engagedChrome`.
- **Don't** cache a resolved `.cgColor` outside a live draw or an appearance refresh. A frozen colour sits outside Increase Contrast forever.
- **Don't** apply a case transform to authored copy, and don't change the height of a line to make room for a state word.
- **Don't** give `containerEdge` a third value in dark. Dark already has both a fill ladder and a hairline sitting where light's edge lands; a separate dark value buys nothing and starts drawing frames around things.
- **Don't** treat the light appearance as the dark one lightened. Light is Circuit: neutral, near-white, with hairlines doing the separating.
- **Don't** promote the depth behaviour described above into doctrine without asking. That decision is open.
