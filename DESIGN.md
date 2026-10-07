---
name: Audiout (Mac)
description: The menu-bar mixer half of Warm Signal — a cool near-neutral chassis in stock AppKit, gold reserved for audio state, calls to action, selection and completion, and five identity hues (plus one fixed brand mark) fenced to onboarding alone
colors:
  canvas: "#0A0A0C"
  panel: "#15171A"
  raised: "#1F232A"
  well: "#050507"
  label2: "#B7AC95"
  label3: "#9E947F"
  labelCool: "#A9B3BB"
  labelCool2: "#818C94"
  hairline: "#2A2E33"
  containerEdge: "#3D4247"
  rim: "#6B767D"
  railDormant: "#6B767D"
  gold: "#E8B84B"
  goldText: "#E8B84B"
  glow: "#FFD97A"
  ember: "#8A6A2F"
  emberText: "#A98341"
  inkOnFill: "#171104"
  ring: "#7FB4C4"
  failure: "#D9564A"
  muted: "#8E93F0"
  equalizer: "#41B07A"
  speakersAccent: "#41B07A"
  partyRampDeep: "#FF90E9"
  meter: "#464C55"
  socket: "#2A2E33"
  scopeGround: "#14110C"
  scopeFlatLine: "#9C9077"
  scopeBypassLine: "#8A7E68"
  stagePlate: "#100B07"
  stageRule: "#6A5F50"
  stageInk: "#EFE9DD"
  wireCore: "#2BFF8F"
  syncSignalDeep: "#2BFF8F"
  fuseWhite: "#FFF4E2"
  permissionSystemAudio: "#5B93C4"
  permissionLocalNetwork: "#9A6BC6"
  permissionRemoteControl: "#C066A2"
  permissionSpeakerSync: "#B86F41"
  permissionUsageStats: "#3F977A"
  permissionAudioutRemote: "#569347"
  bluetoothBrand: "#0082FC"
  iconWellBadge: "#0000008C"
  iconWellBadgeBorder: "#FFFFFF40"
typography:
  body:
    fontFamily: "SF Pro (system)"
    fontSize: "13pt (NSFont.systemFontSize)"
    fontWeight: 400
  bodyEmphasized:
    fontFamily: "SF Pro (system)"
    fontSize: "13pt"
    fontWeight: 600
  menuItem:
    fontFamily: "SF Pro (system), NSFont.menuFont"
    fontSize: "the system menu font's default size (menuFont(ofSize: 0))"
    fontWeight: 400
  heading:
    fontFamily: "SF Pro (system)"
    fontSize: "16pt (systemFontSize + 3)"
    fontWeight: 600
  headingDigits:
    fontFamily: "SF Pro (system), monospacedDigit"
    fontSize: "16pt"
    fontWeight: 600
  titleLarge:
    fontFamily: "SF Pro (system)"
    fontSize: "15pt (systemFontSize + 2)"
    fontWeight: 400
  subtitleLarge:
    fontFamily: "SF Pro (system)"
    fontSize: "12pt (systemFontSize - 1)"
    fontWeight: 400
  caption:
    fontFamily: "SF Pro (system)"
    fontSize: "11pt (smallSystemFontSize)"
    fontWeight: 400
  captionDigits:
    fontFamily: "SF Pro (system), monospacedDigit"
    fontSize: "11pt"
    fontWeight: 400
  captionMedium:
    fontFamily: "SF Pro (system)"
    fontSize: "11pt"
    fontWeight: 500
  captionEmphasized:
    fontFamily: "SF Pro (system)"
    fontSize: "11pt"
    fontWeight: 600
  detail:
    fontFamily: "SF Pro (system)"
    fontSize: "11pt (equal to caption)"
    fontWeight: 400
  keycap:
    fontFamily: "SF Pro (system)"
    fontSize: "11pt (equal to captionEmphasized)"
    fontWeight: 600
  microLabel:
    fontFamily: "SF Pro (system)"
    fontSize: "10pt"
    fontWeight: 600
    textCase: "sentence case, as authored — never transformed"
  readout:
    fontFamily: "SF Pro (system), monospacedDigit"
    fontSize: "11pt (smallSystemFontSize)"
    fontWeight: 600
  syncReadout:
    fontFamily: "SF Pro (system), monospacedDigit"
    fontSize: "12pt (off-scale)"
    fontWeight: 600
  plateTitle:
    fontFamily: "SF Pro (system)"
    fontSize: "15pt (off-scale)"
    fontWeight: 600
  display:
    fontFamily: "SF Pro (system)"
    fontSize: "20pt"
    fontWeight: 700
  displayLarge:
    fontFamily: "SF Pro (system)"
    fontSize: "24pt"
    fontWeight: 700
  wordmark:
    fontFamily: "ClashDisplay-Semibold (bundled at assembly, falls back to bold system)"
    fontSize: "sized per call site (gate primer, About)"
    fontWeight: 600
rounded:
  control: "10pt"
  row: "16pt"
  panel: "26pt"
  popoverShell: "12pt"
  permissionCard: "10pt"
spacing:
  surfaceWidth: "713pt"
  sidebarWidth: "210pt"
  leadingInset: "14pt"
  indentedLeadingInset: "30pt"
  trailingInset: "14pt"
  iconWidth: "26pt"
  sliderWidth: "150pt"
  readoutWidth: "40pt"
  muteWidth: "24pt"
  eqToMuteGap: "6pt"
  trailingControlWidth: "200pt"
  bodyRowHeight: "42pt"
  mainAudioRowHeight: "44pt"
  titleSubtitleSpacing: "2pt"
opacity:
  rowHoverWash: "0.10 (PopoverColumnGrid.rowHoverWashAlpha)"
  rowSelectionWash: "0.18 (PopoverColumnGrid.rowSelectionWashAlpha)"
  engagedFill: "0.22 (PopoverColumnGrid.engagedFillAlpha)"
  insetCardTint: "0.12 (PopoverColumnGrid.insetCardTintAlpha)"
  insetShade: "0.18 (Tokens.Color.insetShadeAlpha)"
components:
  button-prominent:
    backgroundColor: "{colors.gold}"
    textColor: "{colors.inkOnFill}"
    typography: "{typography.body}"
    rounded: "999pt (rounded bezel)"
  device-row:
    backgroundColor: "none at rest; the neutral hover wash on pointer-over, inset 5 × 2pt"
    textColor: "system labelColor (live) / {colors.labelCool} (idle) for the name; {colors.goldText} (live) / {colors.emberText} (idle) / {colors.labelCool2} (can't be adjusted) for the readout"
    typography: "{typography.menuItem}"
    rounded: "{rounded.control}"
    height: "{spacing.bodyRowHeight}"
---

# Design System: Audiout (Mac)

## Overview

**Creative North Star: temperature tells you where the sound is going — restated in stock AppKit.**

This is the Mac half of Warm Signal, migrated on 2026-09-03 onto the iPhone
companion's palette (`aa-hh/audiout-remote`, whose `DESIGN.md` is the shared
authority for every rule this file does not repeat). Both appearances are
cool-neutral now: `#0A0A0C` in dark, one flat `#FAFAFB` ground in light, with
warmth reserved for wherever the Mac is actually sending sound. Gold's core
jobs are audio state and calls to action; it also marks selection (the
appearance-tile ring) and completion (onboarding checkmarks). This
file exists because the
Mac is a second native surface, not a second skin of the same one: stock
AppKit chrome, `NSColor`/`NSFont` tokens instead of SwiftUI, and a menu-bar
popover as the primary shell rather than a phone screen. Where the two apps'
rules coincide, read the iOS file. What follows is what is Mac-only, or where
the Mac's build diverges from the phone's.

The build carries real Mac-only territory the migration deliberately kept:
five identity hues plus one fixed brand mark fenced to the first-run
permission spine, a fixed-dark
alignment-wizard stage that never themes with the window, the Groups
membership rail, and a graduated variant scheme — most custom colors ship
four hexes (light/dark × Increase Contrast), some ship two, and a handful are
fixed literals outside the dynamic system entirely — that iOS's simpler
light/dark pairing does not carry at all.

**Key Characteristics:**
- Temperature carries state through ink and instruments, not through a
  background-fill swap: a device row's name and readout shift color
  (system label / `labelCool` for the name, `goldText` / `emberText` for the
  readout) between sounding and idle
- A deliberately silenced output is the one state that takes a hue of its
  own rather than a dimmed neutral: `muted`, a cool periwinkle-indigo fenced
  to the Mixer rows' engaged mute control (see the Muted-Hue Fence)
- Gold's primary jobs are audio state and calls to action; it is also the
  app's one selection/completion mark — never a decoration outside those
  roles
- A two-position accent dial (Full / Subtle) remaps ten tokens —
  `gold`/`goldText`/`ember`/`emberText`/`glow` and all five permission
  identity hues — nothing else; Follow-System was deleted in this migration
- Five permission identity hues, plus one fixed Bluetooth brand blue outside
  that system, are the one Mac-only "identity, not state" palette, fenced to
  the first-run Setup spine and never reused elsewhere
- The alignment wizard is a fixed dark instrument stage that does not theme
  with light/dark mode — a gauge face, not chrome
- Stock AppKit controls and SF Symbols throughout; custom drawing is
  confined to a short, named list of chrome pieces and cell-level control
  skins, each called out per folder rather than invented ad hoc
- One radius ladder shared with iOS (10/16/26pt), plus two Mac-only radii for
  the popover shell (12pt) and onboarding's permission card (10pt, coincidentally
  equal to `control` but declared separately — see Shapes)

## Colors

The palette is the iPhone companion's own hex values, adopted case-for-case
this migration (`Tokens.swift`'s own comment: "THE LADDER IS THE IPHONE
COMPANION'S"). Read the iOS `DESIGN.md` Colors section for the full grounds/
edges/ink/signal breakdown — every one of those tokens exists here under the
same name with the same dark hex. This section covers only what differs.

### Primary
- **Gold** (`#E8B84B` dark and light; Increase Contrast `#8A6614` light): the
  signal, audio state and
  calls to action. Identical values and identical rules to iOS. A Mixer card
  title turns `goldText` while audio comes out of its rows (see Mixer Card
  Header); that is the one place gold marks a heading.

### Neutral
- **canvas / panel / raised** (`#0A0A0C` / `#15171A` / `#1F232A` dark; flat
  `#FAFAFB` for all three in light): the cool chassis. Same values as iOS;
  light stays one flat ground with separation carried entirely by edge
  weight.
- **well** (`#050507` dark / `#E9EAEC` light): the one neutral that does NOT
  flatten to the paper ground in light — it stays a visibly recessed tone
  even on the flat chassis, because a recess still needs a fill to read as
  sunk, not just an edge.
- **hairline / containerEdge / rim**: the same three-weight edge family as
  iOS — divider, container edge, control edge — same hexes. A 1 pt rule is a
  `RuleView(tone:)` (`AudioutSharedUI`): `.containerEdge` on `raised` or
  `well`, `.hairline` on `panel` or a bare ground. A stock `NSBox`
  `.separator` appears only on stock chrome (the sidebar, Settings).
- **label2 / labelCool** on captions: `labelCool` for identity and status
  lines (a speaker's kind and state, a list row's caption), `label2` for a
  note that explains the controls beside it (`noteLabel`, see Typography).

### Named Rules

**The Variant Rule.** Not every custom color ships the same number of
authored values. Instrument, state and ink tokens (gold, ember, failure,
ring, muted, the permission hues, and most of the palette) author FOUR hexes:
light and dark, each with a separate Increase-Contrast value, resolved live by
`warmDynamic`/`accentDynamic`/`permissionDynamic` against both the window's
appearance and the live `NSWorkspace.accessibilityDisplayShouldIncreaseContrast`
flag on every draw — never a frozen snapshot. Resolving live is only half of
the job. Because the flag is read OUTSIDE the appearance — and because the app
pins its own appearance for the theme setting — toggling Increase Contrast
changes no view's effective appearance and fires no
`viewDidChangeEffectiveAppearance` at all, so a view that overrides only that
method keeps painting its standard-contrast hexes until some unrelated repaint
happens along. A view that draws a token must also subscribe to
`NSWorkspace.accessibilityDisplayOptionsDidChangeNotification` and repaint;
`NSView.redrawOnAccessibilityDisplayChange()` (`AudioutSharedUI`) is the one
place that wiring lives, and thirteen views across the surface's Scenes, Speakers and
Settings screens call it. A view whose colors are stamped `CGColor`s on a `CALayer`
needs more than a repaint and re-stamps in its own handler instead
(`DeviceIconWellView`, `HaloRingView`, `LevelMeterView`).
`IncreaseContrastLiveReconcileTests` walks the real view tree and fails on a
drawn view that subscribes to neither. Grounds (`canvas`, `panel`,
`raised`, `well`) author only TWO — light and dark —
by design: a background carries no stated contrast floor, so `Tokens.swift`'s
own comments say these have no separate Increase-Contrast value.
`iconWellBadge`/`iconWellBadgeBorder` author one hex plus two alphas (a fixed
hue that steps its opacity under Increase Contrast instead of changing
color). A small number of fixed literals participate in none of this:
`bluetoothBrand` is a plain `NSColor(srgbRed:)` literal with no appearance
branch and no Increase-Contrast response at all — it is the Bluetooth SIG's
own brand blue, held constant because it names a real-world mark, not a
Warm Signal instrument. Each token's own doc comment in `Tokens.swift`
carries its measured contrast rationale and is the source of truth for the
individual value; do not attempt to enumerate all of them here. The dynamic
mechanism declares 92 Increase-Contrast hexes across the file (74 distinct
values); that count is a snapshot of the current file, not a rule to hold
constant.

**The Accent Dial Rule.** Two positions remain: Full gold and Subtle
(`Tokens.accentStyle`, `AccentStyle.fullGold` / `.subtle`; Follow-System was
deleted this migration, per the owner's decision F3). The dial remaps exactly eleven
tokens: the five accent instruments `gold`, `goldText`, `ember`, `emberText`,
`glow` (via `accentDynamic`), and the six permission identity hues
`permissionSystemAudio`, `permissionLocalNetwork`, `permissionRemoteControl`,
`permissionSpeakerSync`, `permissionUsageStats`, `permissionAudioutRemote`
(via `permissionDynamic`,
whose own header names `Tokens.accentStyle` as the same switch). Nothing else
is dial-aware — `failure`/`rim`/`ring`/`muted` and `bluetoothBrand` are fixed
in every dial position. `glow` resolves a quieter halo of the same hue at
Subtle: it strokes the rail's connect bead and the ring and header-dot
blooms, which a `.clear` Subtle column would draw invisibly; the six
permission hues
always resolve a real, muted color at Subtle, because an opaque glyph fill
cannot go invisible the way a halo can. Changing the dial broadcasts
`Tokens.accentStyleDidChangeNotification`; a `CALayer`-stamped instrument
must observe it explicitly, the same way it observes appearance/Increase-
Contrast changes.

**The Permission-Hue Fence (Mac-only, not a system pattern).** Six identity
hues — `permissionSystemAudio` (warm slate), `permissionLocalNetwork` (dusty
plum), `permissionRemoteControl` (muted mauve), `permissionSpeakerSync`
(deepened brass, gold-adjacent but held below the gold/amber band),
`permissionUsageStats` (verdigris) and `permissionAudioutRemote` (moss green,
~108°, the band the other five leave open between brass at ~23° and verdigris
at ~160°) — mark each first-run Setup row's SF Symbol glyph and nothing
else. Each hue is permanent per-row identity, never
a state (granting a permission never recolours its glyph; the row's own
status chip carries the granted state). All six are reserved out of the
gold/amber band `[28°,68°)` and the failure-red band, and are mutually
distinguishable by ≥47° of hue (the closest pair is moss green and verdigris,
measured 50°) — a floor recorded in `Tokens.swift`'s own doc comments for each
token, not asserted by degree in any test;
`OnboardingPermissionColorTests`'s mutual-distinctness suite only checks that
the resolved colors are pairwise unequal, and its contrast sweep holds every
one of them to ≥3:1 against `panel` and `raised` in both dial columns and both
appearances. The
seventh glyph on the same spine, `bluetoothBrand` (the fixed Bluetooth SIG
blue, ~209°), sits outside this fence entirely — it is a real-world brand
mark, not a Warm Signal identity hue, and the same test suite deliberately
excludes it from the distinctness check (it sits only ~1° from
`permissionSystemAudio`'s ~208°, which is fine precisely because it is not
part of the six-hue system being kept distinguishable). This whole fence is
a Mac-only exception the migration deliberately kept (decision C2) — it
exists because six simultaneous, still-ungranted system permissions need to
read as distinct asks at a glance, a problem the phone's single-permission
gate does not have. It is not a general-purpose "identity color" system:
nothing outside the Setup spine may draw from this family.

**The Muted-Hue Fence.** One token, `Tokens.Color.muted` (`#8E93F0` dark /
`#585EC7` light, no separate Increase Contrast pair), means one thing:
this output is deliberately silent. Its only consumer is the engaged mute
control on the device row and the Main Audio row, which draws the slashed
outline symbol (`RowAccessorySymbol.muteEngaged`) in this ink (see Row
Accessory Controls). It may not appear anywhere else. It is not a second cool accent, not
a disabled or dimmed tone, and not available to a control that merely happens
to be off. A row silent for some OTHER reason — unavailable, failed, not a
member — keeps its existing treatment, because this hue answers "someone muted
this", not "no sound is coming out". `DeviceRowMutedStateTests` names the
files allowed to draw it and fails on any other. Why a new hue rather than one already
here: `gold`/`ember` mean the row is carrying audio, so mute can never borrow
them — that rule is the reason this token has to exist; `failure` red means
something went wrong and a mute is deliberate; `partyRampDeep` is group
identity, `ring` the wizard's reference light, the five `permission*` hues are
fenced to onboarding, and `bluetoothBrand` is a real-world mark. Cool is the
direction the temperature rule already sets — warm means sound is flowing
there, cool means silent — and this sits 40–43° of hue off `ring`'s
desaturated steel and 29° off `permissionSystemAudio`'s blue, measured ΔE
(CIE76) 35.1–66.1 from `ring` and never below 14.0 from any permission hue in
any of the four cells. Two candidates were rejected on that measurement: an
azure at 213° came within ΔE 6.4 of `permissionSystemAudio`, and a violet at
257° within ΔE 6.5 of `permissionLocalNetwork`.

**The Equalizer-Hue Fence.** One token, `Tokens.Color.equalizer` (`#41B07A`
dark / `#007835` light; Increase Contrast `#5FD597` / `#005A28`), means one
thing: a curve is not flat. It marks a shaped curve in four places across the
equalizer UI: the Mixer row's Equalizer door (the outline square, in green ink;
`DeviceRowView.updateEQButton()`), the icon leading the "Equalizer" heading on
the speaker page and the Main Audio page (the filled square when shaped), and
the stretch of each EQ slider from where the knob sits at 0 dB to the knob
(`EQGainFillCell` in `EQEditorView.swift`), and the Advanced section's
response curve (its 2 pt shaped trace and the 13 % fill under it,
`EQResponseCurveView`). A flat curve shows the door's rest ink and an empty
slider track instead. The one exception: the scope's 0.14-alpha band
gridlines are reference marks drawn in this green in every state, as the gold
ones were. `RowAccessorySymbol` draws the
door and heading images through `equalizerDoor(shaped:in:)` and
`equalizerHeading(shaped:in:pointSize:)`. On `scopeGround` only the dark hexes
draw, 6.92:1 (Increase Contrast 10.65:1). It is not a general "on"
green, not a success tone, and not available to a second control that happens
to be engaged; `DeviceRowMutedStateTests` names the files allowed to draw
it and fails on any other.
The door wore `goldText` until 2026-09-04, and gold means
"audio is flowing here" everywhere else, so one hue was carrying two ideas. Green was
unspoken for, and stays 84–86° of hue off `muted`, the control 6 pt to its
right, and 9° off `permissionUsageStats`, which is fenced to onboarding and
never shares a screen with a device row.

The two engaged marks are tuned **as a pair**, not to a floor each — but what
"pair" means depends on the ground, and the first attempt got that wrong. On
the dark row they pair on OKLCH lightness: 0.680 against `muted`'s 0.698, the
green a hair under its sibling, which is the intended order (mute is the kill
switch, the door is not). On the light row lightness is the wrong axis. A dark
stroke on near-white reads as an outline whatever its luminance; what separates
`muted`'s periwinkle from a plain dark line is chroma, which it carries at
0.161. A light green matched on lightness alone (`#1E7E52`, chroma 0.111)
measured 4.84:1 — far over the floor — and the owner's verdict from the live
build was still "almost invisible" (2026-09-14). So the light half pairs on
chroma instead, and takes its hue eight degrees toward the green primary to
find the room: sRGB tops out at chroma 0.116 near hue 158 at this lightness,
and at 0.138 near hue 150. Same green family, same 84–87° clear of `muted`;
only the room sRGB leaves differs between appearances.

Both marks draw at `RowAccessorySymbol.weight`, one shared constant. It went
from `.thin` to `.light` on 2026-09-14 — a 1.0 pt stroke to a 1.5 pt one on the
same 17.5 pt square — because a hairline outline stayed hard to see on a light
row however the hue was tuned. SF Symbols weights are discrete, so that is the
smallest step available; `.regular` draws the same 1.5 pt stroke but grows the
square to 18 pt, buying nothing for the size.

Measured against every ground a device row can put behind the door — `canvas`,
`panel`, `raised`, the hover wash — dark `#41B07A` runs
7.27 / 6.60 / 5.79 / 5.23 and light `#007835` runs 5.39 on the flat
grounds, 4.45 hovered, against a 3:1 non-text floor. The values they
replaced (`#227950` / `#1C6543`, 2026-09-05) were measured on `panel` alone:
the dark half sat at 2.66:1 on the gold wash rows painted behind a sounding speaker at the time, and the light half, at chroma 0.091, read as
near-black rather than as green.

**Unavailable speakers.** A speaker the Mac can't reach keeps its name in
`labelCool` and its icon in `labelCool2`, on every screen that lists it: the
sidebar and the scene editor's membership rows.

**`engagedChrome` washes.** Every hover, selection and press highlight is
`Tokens.Color.engagedChrome` (an alias of `label`) on one alpha ladder: 0.06
for the header strip's resting capsule, `PopoverColumnGrid.rowHoverWashAlpha`
(0.10) for hover, `rowSelectionWashAlpha` (0.18) for a selected or current
item, and `engagedFillAlpha` (0.22) for the open sync chip and a pressed
header-strip button. Only the header strip scales with Increase Contrast
(each step × 1.5, capped at 1); the row washes keep the same alpha. On a
Mixer row the wash is a rounded rectangle inset 5 × 2 pt at the `control`
radius, painted by `PopoverColumnGrid.fillRowWash(in:alpha:)`.
`HoverTracker` (`AudioutSharedUI`) owns the tracking area of each Mixer row,
card and subsection header and scene-editor membership row, and re-reads the
pointer whenever the area is rebuilt and on every pointer move, so a row
rebuilt under a still pointer neither stays lit nor misses the hover. Users: the
header strip, card and subsection headers, device and app rows, the icon
well, the sync chip. A wash is never gold.

**The Speakers tab's green.** `Tokens.Color.speakersAccent` (`#41B07A` dark /
`#007835` light, Increase Contrast `#63D199` / `#03642B`) means the Mac can
reach a speaker, and it also marks the tab's one add action. It has four
placements, all on the Speakers tab: the Overview's "Available" label, each
count tile's number above 0, the `plus.circle` glyph on "Pair Bluetooth
speaker…", and the "Ready" or "Connected" word in a speaker page's caption. It
is never selection, never a fill behind text in dark (white on the dark value
measures 2.72:1), and never the Mixer or the sidebar. Its base values are
`equalizer`'s, so the app has one green; the Increase Contrast pair is its own,
and it is not on the accent dial. Against a 4.5:1 floor it measures, light,
5.39 on `panel` and `raised` and 4.67 on `well` (7.04 / 6.10 with Increase
Contrast) and, dark, 6.60 / 5.79 / 7.48 (9.50 / 8.34 / 10.77).

**The Instrument Ground Rule (Mac-only).** The alignment wizard's stage
(`stagePlate`, `stageRule`, `stageInk`, `wireCore`, `fuseWhite`) authors the
same hex for dark and light — a fixed dark instrument face set into a
themed window, never a themed surface. `syncSignalDeep` is its one themed
companion, used where the target's identity hue must sit on the surrounding
window chrome (the plate rim/keycap tint in light mode) instead of the fixed
plate itself. `partyRampDeep` is NOT part of this stage — `Tokens.swift`'s
own comment states plainly that group identity is not drawn on this sheet;
`partyRampDeep` belongs to the surface and popover instead (see Group
Row and Membership Rail under Components). This is the one place in the app
a surface deliberately does not follow appearance, and it is authored that
way, not a bug.

The rule binds anything DRAWN on the plate, not only the five tokens above. A
themed token borrowed for the stage is resolved under `.darkAqua` before it is
drawn, because the ground it will be measured against is the fixed dark plate,
not the window: `AlignmentStageView.plateEdge` pins the plate's own bezel to
`rim`'s dark hex the way `referenceLight` already pins `ring`. Resolved with
the window instead, the light hexes measure 3.47:1 on the plate with Increase
Contrast off and 2.89:1 with it on — the setting a user turns on to read better
made the bezel worse and pushed it under the 3:1 non-text floor. Pinned, it
measures 3.70:1 and 5.02:1. Only geometry may read the window: the bezel's
alpha still steps from 0.35 to 0.9 in light mode, where a heavier edge is what
keeps a black plate off white paper.

**The Scope Instrument Rule (Mac-only).** The EQ response curve
(`scopeGround`/`scopeFlatLine`/`scopeBypassLine`, and `equalizer` for the
shaped trace, its fill and the band gridlines) is a hardware-analyser scope:
dark screen, lit trace, identical hex in both appearances, drawn under a
forced `NSAppearance(named: .darkAqua)`. A flat curve draws only the
`scopeFlatLine` hairline over the faint gridlines, shaping draws in
`equalizer`, and a bypassed shape goes dashed in `scopeBypassLine`. The wizard stage and this scope are the
Mac's two concrete cases of instruments that hold a fixed appearance rather
than themeing with the window (PRODUCT.md's Brand Commitments names the
broader "instruments never theme" principle for the gold family, failure,
rings, meters, fader hardware and permission hues generally; the stage and
scope are this codebase's most literal reading of that principle — a whole
surface, not just one token, pinned to one appearance).

## Typography

**Body Font:** San Francisco (system) throughout. Every voice in the table
below is a forwarding alias over a stock `NSFont.systemFont`/
`.monospacedDigitSystemFont`/`.menuFont` call, not a custom face.

**Wordmark Font:** ClashDisplay-Semibold, fetched at app-assembly time into
`Contents/Resources` (never checked into git — the ITF Free Font License
forbids redistributing the file through a public repo) and falling back to
the system bold face under `swift run`/`swift test`, where there is no
`.app` bundle. Sets the product name only, matching the iPhone file's
"Name Only Rule."

**Character:** the same one plain system voice at several sizes that the iOS
file describes, restated in AppKit's own size vocabulary (`systemFontSize`
= 13pt, `smallSystemFontSize` = 11pt) rather than Dynamic Type. There is no
`@ScaledMetric` layer on the Mac — sizes are fixed points, not scaled
relative to a text style.

### Hierarchy
- **Display** (700, 20pt; `displayLarge` 700/24pt for the licence gate's
  welcome headline): a window's own headline, where the headline is the
  reason the window opened.
- **Heading** (600, 16pt; `headingDigits` 600/16pt with tabular digits for
  the Overview's counts): a window page's name and the "Equalizer" heading
  on the speaker page and the Main Audio page — one step above body.
- **Title Large / Subtitle Large** (`titleLarge` 400/15pt, `subtitleLarge`
  400/12pt): the licence gate's explanation and key field, and the Scenes
  overview's empty-state subtitle.
- **Body** (400, 13pt; `bodyEmphasized` 600/13pt for the sidebar plates and
  the password sheet's heading):
  list-row titles, form labels, and a section title above a box (the scene
  editor's "Speakers"), in `label2`. The Equalizer heading is the one section
  title set in Heading.
- **Menu item** (`menuItem`, the system menu font): every Mixer row name —
  Main Audio, device rows, app rows, and the message in an empty or
  permission row. It matches the `NSMenuItem` text in the rows' own menus.
- **Caption** (400, 11pt; `captionMedium` 500/11pt; `captionEmphasized`
  600/11pt; `captionDigits` 400/11pt with tabular digits for the sidebar's
  "N unavailable" divider and the Overview's total): secondary/detail text —
  sublabels, readouts, hints, footers. `noteLabel` (`AudioutSharedUI`) is the
  explanatory note under a box: caption in `label2`, wrapping to at most two
  lines with the second truncating.
- **Micro Label** (600, 10pt, sentence case): the state vocabulary ("Muted")
  and inline tags ("AP1") — the Mac's version of the iOS Micro Label voice,
  one point smaller because it rides the sublabel line and must not change
  that line's height (the no-reflow rule).
- **Readout** (600, 11pt, tabular digits): the row `%` readout.

### Named Rules

**One Case (shared with iOS).** Every string renders in sentence case as
authored. No uppercase transform, no monospaced design outside the readout's
tabular-digit feature. The Mac's own history here: the micro-label voice
replaced an SF Mono bold UPPERCASE + kern treatment in 2026-08-23 for the
same reason iOS states it — a token now stands out from body text sharing
its line by weight alone, not by shouting.

**Menu Section Headers Indent Their Entries.** A dropdown's section header
("Scenes", "This Mac", "AirPlay Speakers") is an `NSMenuItem.sectionHeader` — the
only item AppKit documents as non-interactive, so it cannot be highlighted,
hovered or picked. A hand-disabled plain item does not substitute: an
`NSPopUpButton` re-points every item's action at its own cell, and while
`autoenablesItems` is on AppKit ignores `isEnabled` outright, so the header
lights back up. Its appearance is owned by `NSMenu` and is not customised.
Because One Case leaves the header in the entries' own type register, the
separation is structural instead: a rule above every section but the first,
and every entry one indentation level in, so its header hangs to the left.
That indentation is a deliberate departure from the HIG, which prefers a
submenu to indenting menu items (owner's call, 2026-09-05) — a submenu would put
every speaker an extra hop away, and reaching a speaker fast is what this
menu is for. Do not "fix" it back.

**Off-Scale Sizes Are Ledgered, Not Silently Tokenized.** `Tokens.swift`'s
own header records that its Font aliases mirror shipped call sites as of the
audit pass that created them, not a claim every size in the five UI packages
is on-scale. Two sizes sit off the scale by design and are documented at
their declaration: `syncReadout` (12pt monospaced semibold, the BT sync
drawer's editable value; while a Cast offset edit or reset waits out the
stream lag its digits breathe `pendingInkDim` to `goldText`, a `pendingGlow`
halo 2.5pt around the field breathes with the fader thumb's curve, and the
field's label adds "applying") and `plateTitle` (15pt semibold, the wizard's two
hero answer plates). `detail` and `keycap` are names for intent only: they
equal `caption` and `captionEmphasized`.

**Titles Are Headings.** A window page's name and every section title (the
sidebar's section and group titles, a Mixer card title, "Equalizer", the
scene editor's "Speakers", the Overview's "Available") carry
the VoiceOver heading role, so the heading rotor walks a page by its titles.

## Layout

The popover is the primary shell: `AppSurfaceController` swaps its four
screens (Mixer, Scenes, Speakers, Settings) through one hosted panel, sized
through `preferredContentSize` — height flows from content, pinned top and
bottom. Width does not flow: the surface is 713 pt wide on every screen
(`SurfaceLayout.width`), and the Speakers and Settings sidebars take a pinned
210 pt of it (`SurfaceLayout.sidebarWidth`). Height has one ceiling. The
Output Speakers card's list of speakers stops at twelve rows
(`PopoverPanelViewController.deviceListMaxHeight`, twelve times the 42pt body
row = 504pt) and scrolls past that, so a large fleet cannot push the surface
off the bottom of the screen. The list alone scrolls: the header strip, the
warning banners, the System Audio card and that card's own header row hold
still above it, on overlay scrollers that take no width from the columns.
Twelve is picked off the content rather than off the screen — twelve speakers
is a list you read down, and the thirteenth row is visibly cut, which is what
tells you it scrolls. The screen clamp stays as the upper bound and
`applyContentHeightLimit` takes the lower of the two, floored at three rows, so
a short screen lowers the list rather than overflowing and still shows one. A
short list ignores the ceiling and hugs its rows exactly. The ceiling is
applied before the session frame is measured, so the frame is still measured
once per open, never animated and never re-centred.

The Output Speakers header holds **Manage speakers…** beside its column
labels. **Pair Bluetooth speaker…** is a row at the end of the speaker list,
outside the Bluetooth subsection so it remains visible when that subsection
is collapsed. The Main Audio destination menu offers **Save selected speakers
as scene** under Scenes, including when no scene has been saved.

**Row geometry** is centralized in `PopoverColumnGrid`, which `Tokens.Layout`
forwards rather than duplicates: 14pt leading and trailing insets (30pt for
an indented row, `indentedLeadingInset`), a 26pt icon column, a 150pt
slider, a 40pt readout column, a 24pt mute control, a 200pt trailing-control
column, and a 42pt body row height (44pt for Main Audio). A name and the
sublabel or caption line under it sit `Tokens.Layout.titleSubtitleSpacing`
(2pt) apart, on Mixer rows, list rows, page headers and sidebar rows alike.
The trailing column
is 200pt so a row can show "System" plus one app pill beside the 84pt Offset
chip; the surface grew to 713pt to pay for it. Columns anchor to the row's
trailing edge, matching the iPhone file's own row-as-fader grammar in AppKit
terms.

**Settings** is a sidebar-plus-pane split (`SettingsRootViewController`),
never tabs; a new section becomes another sidebar row. It is its own
window-hosted surface, not a sheet. The sidebar is the Speakers sidebar's
two-line row (`IconLabelCellView` on a `SidebarRowView`) under a "Settings"
header in `labelCool`: 40pt with one readout line, 54pt with two, the 22pt
glyph at the cell's leading edge and the readout in `caption`/`labelCool` 2pt
under the name. Each readout follows one rule: something the user must act on,
else what changes what they hear or who can control the Mac, else the
section's headline setting. VoiceOver hears the row as "name, readout", each
" · " spoken as a comma ("License, Trial, 9 days left"). Each pane opens with
`PageHeaderView` carrying a bare 30pt glyph in the 48pt slot, no well; its
content sits on the 14pt lane in `ListRowView` rows over `GroupedSectionView`
`.card` boxes at the `row` radius, and the License pane is one `.well` at the
same radius holding the status sentence and its buttons. Buy Audiout is a
`ProminentButton` and shows in the trial and unregistered states (and for a
key the server refused); Enter license… and Change… stay stock. The sidebar
glyph and the License header glyph take `ring` in the states marked below and
`labelCool` otherwise.

Eight Settings explanations use stock help buttons immediately beside their
row or page title: Touch Bar controls, anonymous usage statistics, iPhone
control, connection volume, wake restore, Bluetooth pauses, Audio buffer and
License. Hover shows a native tooltip; keyboard activation or a click opens
a transient text popover. The same copy is exposed to VoiceOver. Changing a
setting updates its help text and any open popover. License check-in help
appears beside License only while a server and saved key exist. Launch at
login, reconnect, Theme, Accent, the Remote invitation and Apps that stay on
this Mac have plain titles without explanatory subtitles.
The empty Apps that stay on this Mac card fits one 44 pt Add app row plus
6 pt card padding above and below. Removing the last app returns it to that
height.
Status readouts, Allowed/Denied phone captions, launch-option and Login Items
warnings, and buffer reconnect results remain visible. Advanced mounts its
feedback row only while reconnecting or showing a result; clearing feedback
removes that row and its divider. Its forced-launch-option warning remains
visible. Removing a help anchor, switching panes, leaving Settings or
collapsing Advanced dismisses its popover.

| Section | Readout | Glyph |
|---|---|---|
| General | "Needs Login Items approval" | `ring` |
| | "Opens at login", "Doesn't open at login" | `labelCool` |
| Audiout Remote (companion builds only) | "Off", "On · no iPhones yet", "On · no iPhones allowed", "On · 1 iPhone allowed", "On · N iPhones allowed" | `labelCool` |
| Appearance | "{theme} · {accent}", e.g. "Match system · Full gold" | `labelCool` |
| Audio | "No apps stay on this Mac", "1 app stays on this Mac", "N apps stay on this Mac"; second line "Buffer N ms" while the buffer is not 1000 ms | `labelCool` |
| License (builds with a licence server only) | "Trial · N days left", "Registered", "Key saved, not verified" | `labelCool` |
| | "Unregistered", "Trial ended", "Key refunded", "Payment reversed", "Key revoked", "Key not recognized", "Not an Audiout key"; second line "One speaker at a time" while the install is limited and no trial runs | `ring` |

The Scenes and Speakers content (`MixerWindowController`) has two roots. The
Scenes root is a card-grid scene overview and a configuration-only scene
editor, with no sidebar. The Speakers root is a sidebar split that must never
collapse: the sidebar is the only speaker list, beside the Speakers page, a
speaker's page or Main Audio. Selection on either is never activation. Both
host their pages in `ContentPaneHostViewController`, on `WarmPanelView`, with
a 1 pt `hairline` rule under the title bar at the safe-area top (the content
pane only; the sidebar runs the full height). The Scenes host adds a footer:
one centred caption line in `label2`, 6 pt below the page and 8 pt above the
window's bottom edge. The speaker page, Main Audio, the scene editor and the
scene creation sheet are top-anchored scrolling columns capped at
`GroupsPaneLayout.contentMaxWidth`, each with a `FlippedView`
(`AudioutWindowUI`) as document view so content starts at the top. The
Scenes overview scrolls a collection view; the Speakers overview does not
scroll.

The **Speakers page** (`SpeakersPageViewController`), behind the sidebar's
Overview plate, lists no speakers. It opens with the shared page header (see
Speakers Sidebar and Pages): the title "Overview" and one caption in
`Tokens.Font.captionDigits` / `Tokens.Color.labelCool` holding the total ("No
speakers", "1 speaker", "N speakers"). Below it, one
`GroupedSectionView` card ends at its last row. Its first row is the counts
strip: "Available" in `captionEmphasized` / `speakersAccent` over four kind
tiles (AirPlay, Bluetooth, Cast, This Mac), then Unavailable behind a 1 pt
`containerEdge` rule. A tile is a 16 pt `labelCool2` glyph, its number in
`Tokens.Font.headingDigits` and its label in `caption` / `labelCool`; a kind's
number is `speakersAccent` above 0, Unavailable's is `label`, and both are
`labelCool2` at 0. This Mac counts as This Mac; any other speaker counts under
its kind only while the Mac can reach it and as Unavailable otherwise, so
Unavailable equals the rows under the sidebar's dividers. After the strip come
one-line `ListRowView` rows, built once and only shown while true: "N speakers
can't be found" with "Forget N speakers…", "Local Network access is off" with
"Open Privacy Settings…", "Bluetooth access is off" with its action button, and
"Pair Bluetooth speaker…" with a `speakersAccent` `plus.circle` and a
`labelCool2` chevron, always last. Each row's longer sentence is its tooltip
and VoiceOver hint. Nothing on the tab uses `systemGreen`.

`SpeakerSearch` decides when each number is known: This Mac once it is
listed, Bluetooth after 0.5 s with no change, AirPlay and Cast after 2 s, and
every kind 10 s after the search starts (the first speaker listed or the
page's first appearance, whichever is first). Until then a 20×12 `meter`
placeholder stands in for the number, and a 14×8 one for the total, with one
highlight crossing every placeholder on a shared 1.6 s cycle; a number fades
in over 0.18 s when it arrives. Under Reduce Motion there are no placeholders:
the tiles show "–" and the caption "Looking for speakers…". The can't-be-found
list stays empty until that 10 s mark, and never holds a Bluetooth speaker
without Bluetooth access, or a network speaker while Local Network is denied
or before any network speaker has answered, so when every network speaker
is gone none of them is offered Forget.

**Onboarding** is a floating first-run window: a spine of status rows beside
one hero panel, gating Done until every check passes.

## Elevation & Depth

Mostly flat, matching iOS: the dark ground ladder (canvas → panel → raised)
and, in light, edge weight alone carry depth. `Tokens.Color.shadow` (an
alias of `NSColor.black`) has four real consumers, every one of them a flat
clipped band rather than a blurred `NSShadow`: `AlignmentPlateCell` (the
wizard's answer-plate lip shading, rim shadow blend, and chip shadow fill),
`WarmFaderCell` (the fader trough's inset shade at
`Tokens.Color.insetShadeAlpha`, 0.18),
`GroupedSectionView`'s `.well` style (a 1pt band at that same alpha, clipped
inside the shape's top edge), and `SetupPreviewFrameView` (the onboarding demo
frame, which blends the same 0.18 lip and a 0.06 darkening of its own `well`
fill, because it is layer-backed rather than hand-drawn). `.well` is the page card recessed: the
`Tokens.Color.well` fill in place of `.card`'s `raised`, the same
`containerEdge` stroke and, by default, the `panel` radius; both Equalizer
wells take the `row` radius (16 pt), the radius of the list below them, so
each of those pages carries one corner. Both Equalizers wear it —
`DeviceDetailViewController`'s `eqWell` and `MainOutDetailViewController`'s —
because `.card`'s `raised` fill IS the flat `#FAFAFB` ground in light,
identical to the `canvas`/`panel` it sits on, so a card there is a 1pt outline
around nothing. `well` (`#E9EAEC` light / `#050507` dark) is the one neutral
that stays visibly recessed on the flat chassis: 1.154:1 on the light ground,
1.134:1 on dark `panel`, both figures recorded in `Tokens.swift`'s own doc
comment on `well`. The band gives that recess a shaded lip on top of the edge
stroke below.

Two background views carry the ground. `WarmPanelView` paints flat `panel`
behind every screen inside the surface: the Mixer, the splash, Settings, and
the Scenes and Speakers content host. `WarmCanvasView` paints `canvas`, with
a faint grain in dark mode only, behind the windows that open outside the
surface: the Setup window and the alignment wizard sheet. A new screen inside
the surface takes `WarmPanelView`.

The popover's own
`ControlPanelBackingView` (a custom-drawn bubble-plus-beak shape, because
`NSPanel` has no arrow) is a separate, named custom-drawn exception that
does not itself draw a shadow.

### Named Rules

**Custom Drawing Is a Short, Named List.** Root `AGENTS.md` names the
sanctioned custom-drawn Warm Signal pieces as: the canvas, the connection
ring, the signal dot, the meter, the bus control, the fader skin, and the
shell bubble fill. Below that chrome-level list, eight drawing-only AppKit
cell subclasses carry the same "paint changes, behavior stays stock"
contract, each installed FIRST and the control configured on top of it, so tracking,
keyboard input and VoiceOver stay untouched: `WarmFaderCell: NSSliderCell`
(the row volume sliders), `AlignmentPlateCell: NSButtonCell` (the wizard's
answer plates), `SyncChipCell` and `InvisibleSwitchCell` (both
`NSButtonCell`, in `DeviceRowView.swift` — the sync chip and the membership
node's checkbox), `GroupRowButtonCell: NSButtonCell`
(`DeviceDetailViewController.swift`), `WarmNameFieldCell:
NSTextFieldCell` (the scene editor's inline-rename field), and
`SurfaceToolbarSeatCell: NSButtonCell` (`SurfaceToolbarSeatButton.swift` —
every item of the surface header strip), and `EQGainFillCell: NSSliderCell`
(`EQEditorView.swift` — the EQ sliders' green stretch; stock bar, knob and
tick). Each folder's own
`AGENTS.md` names its own local exception rather than one file listing them
all — `AudioutSharedUI/AGENTS.md` names `ControlPanelBackingView`,
`GroupedSectionView` and `DeviceIconWellView`,
`AudioutPopoverUI/AGENTS.md` names the seat cell,
`AudioutOnboardingUI/AGENTS.md` names `DemoPaneView`, and
`AudioutWindowUI/AGENTS.md` names the icon picker's cells and `EqualizerMarkView`. Anything not
on one of these lists draws with stock AppKit chrome; a new custom-drawn
piece gets named in its owning folder's `AGENTS.md`, not invented silently.

## Shapes

Three radii shared with iOS: **control** (10pt), **row** (16pt), **panel**
(26pt) — adopted this migration so the two apps round the same shapes by the
same amounts (rows, cards, seats and chips on Groups). Two further radii are
Mac-only and predate the shared ladder, kept because nothing forced their
consolidation: **popover shell** (12pt — `ControlPanelBackingView`'s bubble
body and the quit-in-progress HUD, previously two independent literals) and
**permission card** (10pt, `permissionCardCornerRadius` — onboarding's
permission card, matching System Settings' own inset-list card radius, not
the shared `control` value by intent even though the number happens to
match). `GroupedSectionView` takes **panel** or **row**, never this one.

On the speaker page and the Main Audio page every box (the Equalizer well and
the list) rounds at **row** (16pt), so the page carries one corner. The scene
editor's checklist and the Speakers page list stay at **panel**. Mixer row
washes, the sidebar plates, the icon well, note banners and inset cards all
round at **control** (10pt).

## Components

### ProminentButton (signature component)
The one call-to-action button in the app: `Tokens.Color.gold` fill via
`bezelColor`, `Tokens.Color.inkOnFill` ink, `Tokens.Font.body` (or the
emphasized weight for a finale CTA). Fill and ink are pinned to their DARK
values (`#E8B84B` with `#171104`) in both appearances: one light gold with dark
text everywhere, the same pin as the alignment wizard's primary plates. Light
mode's paper gold `#A67C1E` is shaded by the rounded bezel into a muddy olive
that dark text cannot read on, and a deepened gold with white text is not an
official gold. It exists specifically to patch a stock
AppKit defect — a `bezelColor` fill drops to a plain bezel when its window
resigns key, but AppKit does not recolor the title to match, so `inkOnFill`
reads dark-on-dark or white-on-white — by tracking key state and swapping to
`Tokens.Color.label` when the window is not key. It also accepts the first
click after the app is reactivated by returning from System Settings mid-
onboarding, rather than spending that click only on activation.

### Surface Header Strip (popover shell, Mac-only)
Five items: the four screen tabs (Mixer, Scenes, Speakers, Settings) in one
capsule, and Pin outside it; the brand lockup sits centred between them and is
decorative. There is no Quit item on the strip. Each tab and Pin is an
`NSButton` wearing `SurfaceToolbarSeatCell` (`SurfaceToolbarSeatButton.swift`);
the four tabs sit in one `SurfaceToolbarTabCapsule`, a single `NSToolbarItem`'s
custom view. The `NSToolbar` itself stays because it is the window's unified
title-bar strip and supplies the system material and the Reduce Transparency
handling. ⌘1–⌘4 select the tabs in order.

Geometry comes from `SurfaceToolbarSeat`. The strip is 34pt tall and a tab
28pt. Tabs are laid out by their glyphs' measured ink, never by the symbol
image's own box, which is 2–4pt bigger than the ink by a different amount per
symbol. Each glyph starts at 15pt and is drawn smaller until its ink fits an
18 × 15pt box (`glyphBox`: Mixer 14.5pt, Scenes 13, Speakers 12.75, Settings
14.25), with its ink centred top to bottom. A collapsed tab is its glyph's ink
with 7.5pt (`glyphPadding`) on each side, so the four are 28.5, 33, 29.5 and
30pt wide; the capsule is those side by side plus 3pt of padding on every
side, so its floor width (`capsuleSize`) is 127pt. Every highlight is cut at half its own
height, so a tab's highlight is a stadium concentric with the pill and Pin, a
28pt square, is a circle. Weights follow the `engagedChrome` wash ladder
under Colors: the capsule at 0.06, hover at 0.10, the current screen and a
pinned Pin at 0.18, a press at 0.22, Increase Contrast read live at draw
time; Reduce Transparency gives the capsule the heavier `rim` edge instead of
a heavier fill. The glyph's ink steps with the seat rather
than against it, `label` engaged and `label2` idle, so the current screen is
marked twice. Neutral, never gold: gold means audio in the mix and a header
seat is navigation.

The seat exists because AppKit draws a bordered `NSToolbarItem`'s hover state
as a circle and its selected state as a rounded square, two shapes for two
states of one control, and neither shape is settable. Taking the drawing means
taking the spoken state too: `toolbarSelectableItemIdentifiers` is deliberately
empty, and each tab reports itself as a radio button through its own
accessibility value and `isAccessibilitySelected`. Two rejected versions are on
the record. Converting only the tabs failed live review on 2026-08-30 — three
bare glyphs beside two bordered circles, two styles in one header — so the
strip is converted whole or not at all. And nothing in the seat is behind
`#available`: the version this replaces put every cue inside
`if #available(macOS 26.0, *)` while the package deploys to 14.4, so macOS
14–25 showed three identical circles and no current screen at all.

Only the current tab shows its name, to the right of its glyph, at
`Tokens.Font.captionMedium`. The glyph keeps its place and the tab grows to the
right, with the same 7.5pt from the glyph's ink to the name's first letter and
after its last letter, measured off the drawn letters rather than the label's
frame. The others are icon-only, and the tooltip
("Scenes (⌘2)") and VoiceOver label carry every name. The name is clamped to
`maxNameWidth` (120pt) and truncates past it, so the widest the strip can be
is `widestCapsuleWidth` plus Pin, 282.5pt of the fixed 713pt surface, in any
language: a widening strip is what would sweep the tabs behind the overflow
chevron, and primary navigation cannot live behind a chevron.

### Mixer Card Header (popover, Mac-only)
A Mixer card (`CardView`) draws no fill, border or shadow of its own; every
card runs the full panel width on the `panel` ground. The only separation
between two cards is a 1 pt `containerEdge` `RuleView` before every card but
the first, starting at the icon column so the rail's gutter stays clear.
`PopoverPanelViewController` builds the headers in two ranks.

- **Card header**, 28 pt: a 16 pt-wide chevron in `label2`, then the title
  in `captionEmphasized` / `label2`, which turns `goldText` while audio comes
  out of the card's rows (the host decides, `setCardHeaderLive`). An
  optional small text action follows the title ("Manage speakers…",
  `menuItem`, `.accessoryBar`). Column legends sit on the same line at the
  trailing side, in `captionMedium` / `label2`, each centred over its column.
  The title is a VoiceOver heading.
- **Subsection header**, 22 pt ("AirPlay Speakers", "Bluetooth Speakers"):
  the same chevron, title in `captionMedium` / `label3`, indented to
  `subsectionHeaderLeading`. The two ranks differ by indent, size and row
  height only.

Both ranks are one click target that folds the body below it, and both show
the hover wash. A **card note** ("Inactive — Audio Out is using …") is one
truncating line in `detail` / `label2`, 18 pt tall, starting where the title's
text starts (`headerTitleLeading`); it is a header row, so it stays visible
when the card folds. The App Routing card ends in a ± footer
(`CardFooterView`), a 28 pt row of 50 × 20 pt controls.

### Device Row (shared with Groups and the popover)
The row-as-fader grammar restated in AppKit, but through INK, never a
background fill: the row paints nothing behind itself except the hover wash
(see `engagedChrome` washes under Colors) and its one-shot attention flash.
The name, in `menuItem`, takes the system label color while sounding and
`Tokens.Color.labelCool` while idle; the readout takes `goldText` while
route-armed, `emberText` while idle-but-adjustable, and drops to
`labelCool2` when the slider is disabled or the row is in the muted-
unconnected treatment (see Row Fader). Warm ink means `isRouteArmed`; cool
means silent. Instruments are flat — no `CALayer` blooms. The one exception
is the pending Cast hold (see Row Fader).

An unavailable retained row keeps its name, glyph and connection node. A
caption in the trailing control area gives its status while live controls
are unavailable. Where recovery is offered, the name itself is the action,
also reachable by keyboard and VoiceOver; there is no separate Connect
button. A nonlocal row's context menu carries a **Show in Mixer** section with
the shared **When available**, **Always** and **Hide when not in use**
choices, the current one checked, then **Speaker settings…**, which opens
that speaker's page. A speaker in current use remains
visible even when its saved choice is Hide when not in use.

A speaker that asks for a password, an on-screen code or a Home member
carries a stock `lock.fill` (10pt semibold, template) 4pt after its name. It
takes the name's own ink (`rowTextColor`), never gold, and the name truncates
before the lock gives way. Its spoken label names the kind of lock. Joining a
password speaker with nothing saved, or the diagnosis panel's
"Enter Password…" button, raises a sheet on the panel
(`SpeakerPasswordSheetViewController`): a one-line heading in
`bodyEmphasized`, a stock secure field, then Cancel and a gold `ProminentButton` Connect, right-aligned. A
caption-size result line appears only once Connect is pressed: "Connecting…",
then the reason if the attempt fails. A connect dismisses the sheet. The
row shows no diagnosis panel while its sheet is up; Cancel with the speaker
still failed opens the panel. A speaker waiting for its first password draws
the connecting ring and a caption-size "Enter Password…" `TextLinkButton` in
the trailing slot (the same slot as the Undo and Play here offers), which,
like a click on the selected row, raises the sheet; red is reserved for a
refused password.

### Main Audio Row (Mixer)
`MainOutRowView` is the device row's grammar with the differences that make
it the head of the mix: 44 pt tall against 42; a 6 pt meter against 3
(`masterMeterThickness`); a 34 pt ring (`mainAudioRingDiameter`) in the
rail's `spineTone` where the rail joins it (see Connection Ring); the slider
stays enabled while muted; mute only, no Equalizer door (the row menu's
"Equalizer…" opens the Main Audio page); and a destination pop-up in the
trailing column, small, in `caption`, bordered so keyboard focus shows, its
title truncating with "…". `GroupIdentityGlowView` glows magenta behind the
icon only while the destination is a scene. The name is `menuItem`, like
every Mixer row name.

### App Row (App Routing card)
`AppRowView` reuses the device row's ink rules. The name is `menuItem`, in
`label` while the app is routed and running and `labelCool` otherwise; a
routed app that is not running adds " (idle)" in `labelCool2` and draws its
icon at 50 % alpha. Routed and running counts as route-armed for the readout,
meter and fader fill. It adds a small `caption` destination pop-up in the
trailing column, the 0.18 selection wash over the 0.10 hover wash, a row menu
whose "Remove from list" is set in `failure`, and a small warning badge on
the icon of an unrouted app that is not running. An empty card shows a
`CardMessageRow`.

### Row Fader and Level Meter (Mixer rows)
`RowVolumeFader` (`AudioutSharedUI`) is the slider and `%` readout every
Mixer row places at `sliderTrailing`: Main Audio, device rows and app rows.
It lays out a 150 pt slider, 6 pt, then the 40 pt readout in `readout`
(11 pt semibold, tabular digits), formatted by `VolumePercent`. It owns the
drag guard: while the user drags, a model update does not move the thumb,
and a mouse-up watcher clears the drag even when the slider's last callback
was not the mouse-up, so the knob always resumes following volume changes
made elsewhere (the phone, the keyboard). It owns the readout ink too:
`goldText` route-armed, `emberText` idle, `labelCool2` when the row can't be
adjusted.

The slider wears `WarmFaderCell`, a drawing-only skin over stock
`NSSliderCell` behaviour:

| State | Track and fill |
|---|---|
| Route-armed | gold gradient, its low end `ember` blended halfway to `gold` |
| Idle | `rim` fill |
| Can't be adjusted (connecting, unavailable, failed; `isMutedControl`) | idle look at 0.4 alpha (`faderDisabledAlpha`), still enabled |
| Disabled | idle look at 0.4 alpha |
| Volume still landing on a Cast speaker (`isPendingApply`) | route-armed fill; the thumb glows (below) |

The trough is 5 pt of `well` with a `rim` edge and a 1 pt top shade
(`shadow` at `insetShadeAlpha`); the thumb is a 10 × 17 pt capsule, a `raised` body read
by its `rim` edge, that stops flush with the track's ends.

`WarmFaderCell` also draws the pending Cast hold, the owner's pick on
2026-10-06 after three animated explorations. While a Cast volume or mute
change waits out the measured stream lag, the thumb lights from inside: three
flat halo rings 1, 2 and 3pt out (alphas 0.34 / 0.16 / 0.07 dark, 0.50 /
0.26 / 0.11 light) and a body blended toward the light by 0.85 (dark) or 0.42
(light), all in `Tokens.Color.pendingGlow`: white halfway to `glow` in dark
(`#FFECBD`), `glow` itself in light, where white vanishes on the near-white
ground. The strength follows `PendingPulse`: a 160 ms ramp, then a 1.4 s
breath from 0.35 to 1 in 0.4 s and back in 1.0 s. When the hold ends the
light rises to 1 in 100 ms and goes out over 450 ms. Reduce Motion holds 0.7
and goes out with no fade. The fill under it stays the solid gold gradient.
While it runs, an armed readout breathes in step with the thumb from
`pendingInkDim` (dark `emberText`'s `#A98341`; light `#64480C`, 8.14:1 on the
light ground) to `goldText`, holds the dim end under Reduce Motion, and
VoiceOver hears "applying volume". To fit the outer ring, `DeviceRowView`
builds its `RowVolumeFader` with `haloRoom` 3: the slider frame is 24pt tall
and `sliderWidth + 6` wide, the cell leaves 3pt empty at each end, and the
readout's gap and the row's mute glyph give the 3pt back, so the trough sits
exactly where the 16pt × `sliderWidth` frame put it. Main Audio and the app
rows never go pending and keep `haloRoom` 0.

`LevelMeterView` is the meter under a row's name: a 74 × 3 pt bar (6 pt on
Main Audio) whose fill uncovers an `ember` → `gold` ramp fixed to the track.
Red never appears in a meter. It rises fast and falls slow, and its display
link stops once the bar reaches zero, so a silent row costs nothing. It shows
only on a route-armed row. A mute drains it through the fall rate; any other
reason to hide it resets it at once. Under Reduce Motion it snaps to the
level.

### Row Accessory Controls (Mixer rows, Mac-only)
Mute and the Equalizer door are four custom SF Symbols
(`RowAccessorySymbol`), each an outline square with a mark inside: a speaker
for mute, sliders for the Equalizer. The glyph says which control it is;
ink then tells engaged from resting.

| Control | Rest | Engaged |
|---|---|---|
| Mute (device rows, Main Audio) | `custom.speaker.square` in `label` | `custom.speaker.slash.square` in `Tokens.Color.muted` |
| Equalizer door (device rows) | `custom.slider.horizontal.2.square` in `label` (flat curve) | the same outline in `Tokens.Color.equalizer` (shaped curve) |

Both draw at 20 pt, weight `.light` (`RowAccessorySymbol.weight`), monochrome,
unscaled in a 24 pt column (`muteWidth` / `eqButtonWidth`) with the door 6 pt
before mute (`eqToMuteGap`). The drawn square is 17.5 pt with a 1.5 pt
stroke. No fill, no capsule, no seat behind either. Mute adds the slash, so
its state does not rest on colour alone. The filled square
(`custom.slider.horizontal.2.square.fill`) is the Equalizer heading icon's
shaped state and never appears on the door. Palette rendering is refused:
it paints the filled symbol's cut-outs instead of erasing them.

The door is green, not gold, because gold means "audio is flowing here"; the
Equalizer-Hue Fence under Colors lists every place that green may appear. No
magenta either: magenta is group identity. No editor, no curve and no tone
control lives on the Mixer itself; the door, and the row menu's
"Equalizer…", open `DeviceDetailViewController`, where the Equalizer sits
open. Main Audio has no door; its row menu's "Equalizer…" opens the Main
Audio page.

### Card Message Row (Mixer)
`CardMessageRow` (`AudioutPopoverUI`) is every empty or permission row on a
Mixer card: "Looking for speakers…", no speakers found, Local Network or
Bluetooth access off, no routed apps. The message is `menuItem` in `label2`;
an optional hint below it is `captionMedium` in `label2` and wraps. Both
start on the name column (`nameColumnLeading`). The row is at least 42 pt and
grows with its hint. It may carry a spinner (not under Reduce Motion) or one
small action button. The message is never `label3`: the line that explains
why a card is empty must not be the faintest text on the panel.

### Note Banner, Inset Cards and the Thank-You Card (Mixer)
**Note banner** (`SystemAirPlayNoteBannerView`, a `TintedNoteBackgroundView`
subclass): a glyph and a wrapping label in `label`. It mounts in two
places, the warning banner at the top of the panel and the note slot. Two
severities:

| Severity | Tint | Glyph |
|---|---|---|
| Info | `ring` | `info.circle.fill` |
| Warning | `failure` | `exclamationmark.triangle.fill` |

It may carry a trailing button, pinned to the trailing edge, and an
underlined `TextLinkButton` left of it; never more than one link beside a
button. A banner is not dismissible.

`TintedNoteBackgroundView` (`AudioutSharedUI`) is the ground every tinted
notice shares: the tint at 12 % (`PopoverColumnGrid.insetCardTintAlpha`), a
10 pt (`control`) corner, and a 1 pt border in the full tint under Increase
Contrast, re-stamped when that setting changes. Three tints: `ring` for the
info banner, `failure` for the warning banner and the diagnosis card, `gold`
for the thank-you card.

**Thank-you card**: the note slot's other occupant, shown once after a
purchase. The same background in `gold`, 112 pt tall, the emitter's settled
rings in a 96 pt well at the leading edge, a headline in `heading`, body
text in `body` / `label2`, and a small rounded **Close** text button. The
rings play one surge on appearing, then rest.

**Inset cards under a device row**: the first-join alignment note (a `well`
card with a `containerEdge` edge; one wrapping sentence in `detail` /
`label2` whose last words, "Align it now.", are the button, set in
`goldText` semibold) and the connection diagnosis card (a `failure`-tinted
`TintedNoteBackgroundView`). Each starts at the icon column, 10 pt inset at
the trailing edge and 4 pt above and below, pads its content 10 pt, and
mounts through the panel's `insertRow` / `removeRow`, one per row.

**Dismissing.** Every dismissible Mixer notice closes with the diagnosis
card's ✕ (`NSButton.noticeDismissButton`, `AudioutPopoverUI`): `xmark` at 12 pt bold in `label2`, a hit area of at least 24 × 24
pt. Only the diagnosis card's ✕ answers Escape; the alignment note's does not,
so Escape keeps the surface's order (thank-you card, then the Scenes editor,
then the bubble closes). The thank-you card is the exception and keeps its
**Close** text button.

### Text Link
`TextLinkButton` (`AudioutSharedUI`) is the app's one underlined text link:
the underline is its only signal, in `label2` (`label3` while disabled), with
the pointing-hand cursor, at `.body` or `.caption` size. Users: a note
banner's text action, a row's "Enter Password…", the licence gate's two
links.
Never gold.

### Failure Pill (Mixer FEED column)
A failing device's FEED pill carries the `exclamationmark.triangle` glyph at
9pt semibold in `Tokens.Color.failure` and NO WORDS, on every row width,
inside the same `well` fill and `rim` edge every FEED pill wears. Both failure
rungs draw this one pill — the `.failed` state and the unavailable state.
Their words move to `feedStack`'s tooltip and to the row's spoken
accessibility value, so they stay reachable by pointer and by screen reader.

Words do not fit the narrowest slot the column has. "Couldn't connect" needs
113.2pt of the Bluetooth row's 52pt feed slot and "Unavailable" needs 83.3pt of
the same, with the triangle eating 19pt before the first character, so the pill
clipped mid-word — to about "Unava". The owner chose the consistent version on
2026-09-04 over fitting words where they fit, so an AirPlay row's wider slot
draws the same bare glyph. This knowingly retires the Bluetooth-UI rule that
"Connected elsewhere" and "Not paired" must read distinctly ON THE ROW; they
still read apart, on the tooltip and in the spoken value.

### Connection Ring and Status Dot (Mixer rows)
Every ring on a Mixer row strokes at one width,
`PopoverColumnGrid.ringStrokeWidth` (1.6 pt): the glyph ring in every form,
Main Audio's ring, and the rail's node circles. Weight never carries state;
colour and dash do on the glyph ring, fill and the line gap on the rail node.
`HaloRingView` draws one form per connection state: no
ring while off; dashed `rim` while connecting or reconnecting; solid `rim`
while connected; solid `failure` when failed. A speaker waiting for its first
password draws the connecting form, with an underlined caption-size
"Enter Password…" link in the row's trailing slot (the same slot as the Undo
and Play here offers); red is reserved for a refused password. The rail node for a connecting
speaker (`MembershipBusView`'s `.connecting`) is a plain hollow `gold` circle
at `ringStrokeWidth`, and the line stops `busConnectingNodeRailGap` (9 pt)
short of it above and below, against `busNodeRailGap` (3 pt) for a member:
the state reads by the break in the line, not by colour, because `gold` alone
is 1.77:1 in light mode. The connecting pulse only
grows the ring outward from its resting radius, by at most
`PopoverColumnGrid.haloRingBreathGrowth` (2 pt), so it never crosses the
glyph; under Reduce Motion the dashed ring stays, still.
`DeviceRowConnectionStateTests` pins the forms, dashes and colours;
`MembershipBusTests` pins the node's rim colours and `MainOutRowRingTests`
pins Main Audio's connecting ring as `rim`.

Main Audio's ring sets `joinsSpine`, so where a device row's connected ring
is `rim`, Main Audio's is `Tokens.Color.spineTone`, the rail's own tone. It
also has a resting form a device row never shows: while the rail is live but
no member has connected yet, the ring draws solid in `spineTone` instead of
hiding, so the rail's curve never lands on nothing. `RingRailToneLockTests`
pins the ring to the rail's ink in every accent setting and both appearances,
and a device row's connected ring to `rim`.

The connected glyph ring is `rim`, the same grey as an unarmed volume
slider's fill. The iPhone app draws a speaker's volume as its ring, so the
ring and the slider are one colour on both platforms.

The status dot (`RouteArmedDotView`) shows only while a ring is drawn. The
ring hands the dot its stroke colour on every repaint
(`HaloRingView.cutoutDot` sets the dot's `ringColor`, `nil` when no ring is
drawn), so a ring colour change moves both, and a speaker with no ring has
no dot and no cut-out. Not playing, the dot is a hollow 1.5 pt ring
(`routeArmedDotRingWidth`) in the ring's own colour: hollow `rim` while
connecting, hollow `failure` when failed, hollow `rim` when connected but
silent or muted, and hollow `spineTone` on Main Audio. Playing, it is a
`gold` disc with a 1 pt `ember` edge (`routeArmedDotEdgeWidth`), because
light `gold` alone measures 1.77:1 against the ground. A device row's dot
turns gold only while the row is route-armed AND its speaker is connected
(`DeviceRowView.apply`): a per-app feed arms a row whose speaker is still
connecting, and that dot stays hollow `rim`. The backend reports a
speaker fed only by a per-app route `.connecting` while its leg starts,
`.connected` once it streams (AirPlay when the bind returns, Bluetooth when
the sink reports it rendering), `.failed` when the bind fails, and `.off`
when the route is removed, unless the speaker's own failure dropped the
route, which keeps `.failed`, so its row draws the same ring and dot as a
member while its rail node stays hollow. Main Audio's dot is gold
while the spine is live, a connected member playing unmuted or the Mac
playing on its own. Subtle dark `ember` is `#7D6B44` so the non-member node's
hollow 1.6 pt rim clears 3:1 on `raised`, the brighter ground (3.47:1 on
`panel`); it stays 1.94:1 dimmer than Subtle dark `gold`. `RouteArmedSignalTests`
pins the armed rules, the gold disc, and a hollow dot in each ring's colour.
`BusRailCollapseResolveTests` pins the 9 pt gap before a connecting node.

Row glyphs are sized and optically centred per symbol by one table,
`DeviceIcon.rowGlyphFits`, drawn by `DeviceIcon.rowGlyph` (derivation in
`dev/notes/ring-glyph-optical-table-2026-10-03.md`). The 8 pt dot
(`routeArmedDotDiameter`) sits on a 10.5 pt cut-out
(`routeArmedDotCutoutDiameter`) in the popover ground, `panel`, so it reads
as a badge over the glyph. On a device row the cut-out also takes the row's
current wash (`rowWash`): the 10 % `engagedChrome` hover wash
(`rowHoverWashAlpha`) and the row's one-shot `gold` attention flash
(`flash(_:)`), so it matches the ground under it in every row state. Main
Audio paints no row wash, so its cut-out is plain `panel`. Main Audio's ring
strokes at 1.6 pt against the rail's 2 pt `busLineWidth` where the two meet.

### Speakers Sidebar and Pages
The sidebar is the only speaker list. Two section titles in
`Tokens.Font.captionEmphasized`, **System Audio** over the Main Audio plate
and **Speakers** over the Overview plate, then two groups that are the Mixer
visibility setting, titled in `captionMedium`: **Shown in Mixer**, with This
Mac first, and, only when it has rows, **Hidden unless in use**, which folds
through the stock hover Show/Hide control. Every title is `labelCool` and
spoken as a heading. The plates are 8 pt taller than a speaker row, filled
`raised` in light and `label` at 5% in dark. Within each group the speakers
the Mac can reach come first, by name; then a divider row (a slashed-antenna
glyph, "N unavailable" in `captionDigits` / `labelCool` and a separator rule,
spoken "N unavailable speakers"); then the speakers it can't reach, by name,
the name in `labelCool` and the icon in `labelCool2`, each with a tooltip
saying Unavailable, Not connected or Can't be found. The split waits until the
search knows every kind, so a cold launch never shows every speaker as
unavailable. Rows keep their identity: an update moves, fades in and fades out
rows inside one outline update (with no animation under Reduce Motion or off
screen), a selection moves with its rows, and nothing moves while the pointer
is over the sidebar, its menu is open or a drag is running. Rows are one line,
except a hidden speaker in use, which carries **Shown while in use** on a row
12 pt taller. A selected row's inks take the selection pill's text colour.
The right-click menu offers **Hide from Mixer** or **Show in Mixer**, **Show
even when unavailable** (checked for Always), **Speaker settings…**, and
**Forget…** only for speakers on the search's can't-be-found list;
Command-Delete forgets the selected ones on that list. Dragging rows onto the
other group's header moves them between groups. Forget asks first in a
warning sheet whose Return key is Cancel. It names every speaker when there
are at most three and each has saved details, otherwise the first two and a
count of the rest, and says that a speaker which turns up again comes back to
the speaker list but not to its scenes. It refuses when a scene would be left
with no speaker, naming the scene to delete first, and when Main Audio or an
app is still set to play on the speaker. A failed Forget shows the scene
editor's "couldn't be updated" alert.

Each plate is a `control`-radius rounded rectangle with a 1 pt
`containerEdge` stroke, inset 10 pt from each side so it covers the same
footprint as the source list's selection pill; its name is `bodyEmphasized`
and a 10 pt semibold `chevron.right` in `labelCool2` closes the row. The plate
and the selection pill take turns and never stack: selected, the row draws
nothing and the stock pill stands alone; unselected, the plate stands alone.
Under `.sourceList` the pill cannot be suppressed, so a plate drawn at any
other inset shows its corners past the pill's ends.

The sidebar ends in a bar the height of an outline row holding **Add
scene**: a borderless `recessed` button in `body`, its 13 pt medium `plus` on
the speaker rows' icon column inside a 26 × 22 image. With two or more
speakers selected it reads **Add scene from N speakers…** and creates a
scene from them. ⌘N reaches it. It opens the scene sheet and never activates
anything.

Every window page opens with one header, `PageHeaderView`
(`AudioutSharedUI`): the 48 pt icon well, the name in `heading`, and an
optional caption line in `labelCool`, the name and caption sitting as one
block centred on the well, `titleSubtitleSpacing` (2 pt) apart. On the Overview, a speaker's page and
Main Audio the well starts on the page's rail-free 14 pt inset, level with
the list and the "Equalizer" heading below it; the scene editor starts it at
its rail inset, and passes its editable name field as the title.
`GroupsHeaderParityTests` holds the pages level. The page name is a VoiceOver
heading. A speaker's caption is its kind and
status ("Sonos · Ready") with "Ready" or "Connected" in `speakersAccent`,
"This Mac", or a `labelCool2` `questionmark.circle` and "Can't be found" once
the search lists the speaker; before that a remembered speaker reads as
unavailable. The Equalizer sits open below. Its heading is a 25 pt icon, then the word "Equalizer" in the page name's 16 pt semibold, in `label2`: the
icon is the outline square in the door's rest ink on a flat curve and the
filled square in the equalizer green on a shaped one. The drawn square, not
the symbol's wider box, sits on the page's 14 pt inset. Only the user's own
drag, step, Loudness tick or Reset animates the flip: going shaped, a 0.15 s cross-fade with
a brief grow to 114% and back over 0.30 s; going flat, a 0.12 s cross-fade;
under Reduce Motion, the cross-fade alone. VoiceOver hears "Equalizer shaped"
or "Equalizer flat" once per gesture. The
summary ("Bass 3 dB, Loudness on", or "Flat") is read out by VoiceOver and
shown as a tooltip on the heading, never as text. Reset, a small stock
rounded button in `caption`, sits at the trailing edge and is hidden while
the curve is flat, on both pages. An unavailable speaker keeps its
editor, which carries the note "Changes will be applied when the speaker next
connects." A speaker the Mac can't find shows no editor; when its curve is
shaped it shows the same note. A Forget button appears only for a speaker on
the can't-be-found list. Then an outlined list of `ListRowView` rows on the
same 14 pt inset: first, on a Bluetooth speaker that can take it, **Control
speaker volume**, captioned with what it does, with a trailing stock
checkbox; **Show in Mixer**, whose caption
explains the current choice beside its pop-up (absent for This Mac),
**Scenes**, linking each scene the speaker belongs to, one link per line on
the row's trailing side, and, only while a password is saved for the speaker,
**Password**, captioned "Saved", with a small stock Forget button.

The Main Audio page has no caption, and its icon well is a plain picture with
no edit badge. Below the Equalizer well sits the note "Applies to audio sent
to speakers." in `noteLabel`'s style.

Scene checkboxes change membership. Their rows give an unavailable member's
status and nothing about visibility; scene cards count unavailable members
alongside the existing Playing and Feeding labels.

### List Row (window pages)
`ListRowView` (`AudioutSharedUI`) is one row of the outlined list on the
Overview and a speaker's page:

- an optional 16 pt leading glyph (`ListRowView.glyph`, default `label2`),
  10 pt before the text;
- the title in `body` / `label`, and an optional caption
  `titleSubtitleSpacing` (2 pt) below in `caption` / `labelCool`, at most two
  lines;
- one optional trailing accessory 10 pt after the text: a button, pop-up,
  switch, spinner, link stack or chevron;
- 9 pt top and bottom padding, a 44 pt minimum height, and the page's
  rail-free 14 pt lane on both sides.

A row built with `captionSpansRow` keeps its title and accessory on one line
and runs the caption the full lane width beneath them.

Titles truncate by default. The Audio connection-volume row opts into a
two-line title at the existing font size. Its help button sits beside the
title, and the help button, slider and value stay vertically centered against
both title lines. The slider and value keep their existing widths.

`isClickThrough` puts the whole row inside a borderless button, so the row is
one target and the button does the speaking. Rows stack on a
`GroupedSectionView` `.card` whose dividers start at
`ListRowView.leadingInset`.

### Grouped Section (window pages)
`GroupedSectionView` (`AudioutSharedUI`) is the box under a window page's
rows, drawn in `draw(_:)` and never hit-tested. A box is earned by holding a
different instrument, never by length.

| Style | Fill | Edge | Default radius | Dividers | Used for |
|---|---|---|---|---|---|
| `.card` | `raised` | 1 pt `containerEdge` | `panel` | `containerEdge` | the list on the Overview, a speaker's page and the scene editor |
| `.well` | `well`, 1 pt `shadow` band at `insetShadeAlpha` inside the top edge | 1 pt `containerEdge` | `panel` | `containerEdge` | both Equalizers |
| `.bare` | none | none | none | `hairline` | no page uses it today |

A page may set `radiusOverride`; the speaker page and the Main Audio page
round every box at `row`. Dividers start at `contentLeadingInset` and stop
`contentTrailingInset` short of the trailing edge, and a section with fewer
than two rows draws none. Onboarding's permission card
(`RoundedContainerView`) is a separate look on purpose: `panel` fill,
`hairline` border, 10 pt radius.

### Icon Well, Icon Picker and Equalizer Heading Icon (window pages)
Three custom-drawn pieces: the icon well is named in `AudioutSharedUI/AGENTS.md`, the icon picker's cells and `EqualizerMarkView` in `AudioutWindowUI/AGENTS.md`.

- **`DeviceIconWellView`**, the 48 pt well that opens every page header: a
  `control`-radius square filled `raised` with a 1 pt `containerEdge` edge,
  the glyph inset 9 pt in `labelCool`, or `label` while what it fronts is
  sounding. A
  22 pt pencil badge (`iconWellBadge` scrim, `iconWellBadgeBorder` rim) sits
  in the bottom-trailing corner at all times and steps up in alpha on hover
  or keyboard focus, beside the 0.10 hover wash; the whole well is the click
  target and opens the icon picker. The well fronting the active scene draws
  a 1.5 pt `gold` edge. With `isEditable` off (Main Audio) it is a plain
  picture: no badge, no hover, no click.
- **Icon picker** (`IconPickerViewController`), an anchored popover: a grid
  of curated SF Symbols, each cell `well` with a 1 pt `hairline` edge and the
  glyph in `labelCool`; the current icon wears the stock system selection
  highlight, never gold or green. A search field filters the grid and accepts
  any symbol name, previewed on a `control`-radius `canvas` tile with a
  `containerEdge` edge; Apply and "Use default icon" are stock buttons.
- **`EqualizerMarkView`**, the 25 pt icon leading the "Equalizer" heading:
  the outline square in `label` on a flat curve, the filled square in
  `equalizer` on a shaped one. It draws into its own layer so only a
  deliberate flip animates (timings under Speakers Sidebar and Pages).

### Group Row and Membership Rail (Groups, signature component)
`GroupIdentityGlowView` sits behind every group seat, active or not, and
behind the Main Audio row's icon while its destination is a scene, drawn in
`partyRampDeep` — the Mac's own instance of the iOS "magenta is identity,
never state" rule. Ink carries temperature per decision C5: `labelCool` on idle
names and glyphs, `label` on the live one, pinned by
`GroupsInkTemperatureTests`. The membership rail's one dormancy tone is
`railDormant`, the same hex as `rim`, so a dormant wire, an idle connected
ring and an unarmed fader fill read as one tone — a Mac-only instrument with
no iOS equivalent (the phone has no membership rail).

The rail is one colour from its start to its end.
`BusRailOverlayView.originColor(for:)` picks it once for the whole line:
`railDormant` when the rail is dormant; otherwise the host's
`unarmedLineTone` when one is set and Main Audio's spine is not armed;
otherwise `Tokens.Color.spineTone`, which is `gold`. Hook, segments, end
dots, collapsed-header dots, and Main Audio's ring where the line joins it
all take that one colour. The Mixer never sets `unarmedLineTone`, so its
line is `gold` in every state but dormant: the system always has Main Audio
connected, so an idle Mixer rail never occurs. The Groups editor sets
`unarmedLineTone` to `ember` (`GroupEditorViewController`), and its spine is
armed only while the group is the active one, so the editor's line is `ember`
for an inactive group, matching its saved member discs, and `gold` for the
active group (`MembershipRailTests`). A segment feeding a connecting
speaker keeps the line's colour and stops 9 pt short of its plain `gold` node
above and below (`BusRailCollapseResolveTests`); a failed speaker is not
reached. `armed` also gates the connect pulse.

#### Membership rail extent
Where the Mixer rail starts and stops. The situations behind it are drawn in
`dev/notes/rail-extent-variants-2026-10-04.md`. "Reached" means a listed
speaker whose node is a member, connecting, or the origin
(`BusRailOverlayView.railReaches`), visible or folded away.

1. The rail starts at the Main Audio ring. When the System Audio card is
   collapsed and the ring has left the card's shrinking visible band, it
   starts at a dot centred on that header's line instead, so the start rides
   up with the collapse rather than jumping.
2. The rail exists only while some listed speaker is reached
   (`RailPlan.isLive`). Failed and unselected speakers never count.
3. Every collapsed header that hides a reached speaker gets a dot centred on
   the header's own text line (`headerDotY`), the vertical centre of the
   header row. That covers each collapsed subsection whose header is fully
   in view, and the Output Speakers card while a collapse is actually hiding
   a reached speaker, never just because its collapse flag is set. A collapsing
   card hides a speaker once its centre passes the shrinking floor. While the
   body is still closing, the dot sits the same distance above the
   shrinking floor that the header's centre sits above the band's top, so it
   lands on the centre as the body shuts.
4. The rail ends at the lowest visible reached node or the lowest dotted
   header, whichever is lower, passing straight through any dotted header
   above that. A node counts as visible while its centre is inside the
   list's visible band, so a reached row the top edge cuts through still
   ends the rail.
5. A collapsed header hiding no reached speaker gets nothing on the rail.
6. Above the end, unselected speakers keep the detour arc. Below the end,
   rows show their own circle and no line.
7. The rail never draws outside the scrolling list's visible band, top or
   bottom. When a reached speaker or a dotted header lies below the visible
   bottom edge and the card is not collapsing, the rail ends on the lowest
   fully visible reached row: its own circle is the end, with no extra
   dot. When reached speakers exist but none is visible and no dot shows,
   the line runs to the edge they lie past, with no dot.
8. Dormant changes only the colour (to `railDormant`), never where the rail
   starts or stops.

`RailPlan.resolve` (`BusRailOverlayView.swift`) is the one implementation and
carries no state, so re-expanding restores the identical rail.
`BusRailCollapseResolveTests` and `PopoverDeviceVisibilityTests` pin it. The
Groups editor's rail passes no sections, so only rules 2, 6 and 8 reach it.

### QR Tile (invitations to Audiout Remote, Mac-only)
`RemoteInviteView` (`AudioutSharedUI`) is one view hosted three times: the
alignment wizard sheet's first page at 96 pt, Settings › General under the
Allow switch at 72 pt, and the Setup window's iPhone card at 160 pt. It
encodes `https://audiout.app/remote` and nothing else, generated with
CoreImage's own QR filter at error-correction level M — a system framework,
no dependency, and no bundled image.

Black modules on a white tile, FIXED in every appearance, every accent-dial
position and under Increase Contrast. A QR code is a print artifact a camera
reads, not chrome, so it joins the wizard stage and the EQ scope under
"instruments never theme" — and it is the one place outside `Tokens` where a
literal colour is sanctioned, because `NSColor.white` is the specification.
No corner radius, no edge, no shadow: the quiet zone is the boundary.

Modules are drawn at a whole number of DEVICE pixels with interpolation off,
so none lands on a half pixel and blurs, and the code carries at least the
standard four-module quiet zone (the generator draws one of those itself).
Whatever the integer scale leaves over stays white, which is more quiet zone
and never worse. The tile is never a button and never gold: the pressable way
to the same page is a stock push button beside it. The tile is hidden from
accessibility and the address printed under it — `audiout.app/remote`, no
scheme, in the surface's own caption voice — is the element, so a person who
cannot or will not scan can type it.

### Permission Row (Onboarding, signature component, Mac-only)
`IconTileView`'s neutral `raised` fill and hairline rim stay untouched; only
the SF Symbol glyph carries one of the seven spine hues (six dial-aware
identity hues plus the fixed Bluetooth brand blue), permanently, per row.
See the Permission-Hue Fence under Colors. The whole row is the press
target; locked and auto-passed rows refuse silently rather than looking
pressable.

## Motion

Every fold in the app runs on one clock, `FoldAnimator` (`AudioutSharedUI`):
a Mixer card or subsection folding, a row revealed or removed through
`insertRow` / `removeRow`, the Equalizer's and Settings' Advanced
disclosures. It tweens one value, a clip's height constraint, over
`Tokens.Motion.collapseRevealDuration` (0.15 s) on a quadratic ease-in-out,
ticked by the display link, and lays everything else out from that value on
each tick. `FoldingClipView` (`AudioutSharedUI`) is the clip for the two
Advanced disclosures: it owns the collapsed-height constraint, seeds from the
live constant, and hides its content on arriving closed. Card bodies and the
panel's row clips keep their own clips, because the rail reads their
generation or closing guard, which `FoldingClipView` does not model. Constants are set directly, never
through `animator()` or an `NSAnimationContext`, because a second clock on
the same value falls out of phase with the window. In-surface fades (a
screen mounting, the thank-you card appearing) ride the same clock.

Under Reduce Motion nothing travels: every fold lands at its end state in
the caller's own turn, the connecting ring stays dashed and still, the meter
snaps, the row flash does not play, the Equalizer heading only cross-fades,
and the Overview shows no loading placeholders.

Instrument timings live beside the instrument in `PopoverColumnGrid`, one
per job, and are not shared:

| Constant | Duration | What moves |
|---|---|---|
| `statusDotBreathDuration` | 1.6 s | the connecting ring's breathing |
| `routeArmedBloomDuration` | 0.45 s | the status dot turning gold |
| `railConnectPulseDuration` | 0.84 s | the rail's connect pulse |
| `railConnectPulseArrivalDuration` | 0.4 s | the pulse's arrival at a node |
| `busNodeHoverGrowDuration` | 0.12 s | a rail node growing under the pointer |

Elsewhere: the row's gold attention flash is 0.5 s; the icon well's badge
fades over 0.12 s; the Equalizer heading flips as described under Speakers
Sidebar and Pages; the Overview's placeholders and number fade are under
Layout; the volume HUD fades over 0.25 s on its own
`NSAnimationContext`, the one window-level transient outside the fold clock.

## Copy

Rules for every surface that mentions the iPhone app or an offset's source.
The words are shared with the phone, which hand-copies them, so a change here
is a change in two apps.

- The iPhone app is **"Audiout Remote"** in full at its first mention on a
  surface, **"your iPhone"** after that. Never "the companion app", never
  "the app".
- The address is always **`audiout.app/remote`**, with no scheme, in caption
  voice, beside every QR tile and in every invitation line.
- No invitation names the App Store, a price, "free", or "download". The
  website says what the store's state is; the Mac does not know and does not
  guess.
- Source words are the glossary's, verbatim: **"Measured"**, **"First pass"**,
  **"Timing from last time"** (`BTOffsetSource` in `AudioutSharedUI` owns the
  sentences; `AudioutProtocol.AlignmentSource` owns the wire strings).
- **"Align by ear"** names the Mac's paired-click wizard and nothing else —
  the untuned chip, the row menu, the wizard page's trailing panel. The
  drawer's metronome toggle is **"Play ticks"** on the Mac and "Start the
  ticks" / "Stop the ticks" on the phone; both apps say "ticks".

## Do's and Don'ts

### Do:
- **Do** reach every color, font, layout constant and material through
  `Tokens` (`AudioutCore/Sources/AudioutSharedUI/Tokens.swift`) — the single
  source of truth for every LIVE-resolved color in the app. Two files are
  deliberate, pinned exceptions rather than violations:
  `AppearanceSettingsViewController.swift` hand-duplicates roughly twenty
  absolute sRGB literals for its theme-preview tiles, because a "Light" tile
  must render light even while the app itself is in dark mode —
  `PreviewPaletteTokenPinTests` pins several of them against the live tokens
  so a re-tune fails loudly there instead of drifting silently — and
  `DemoPaneView.swift` carries its own hex-resolution helper for the same
  reason: it rehearses a real macOS system prompt's chrome, which must stay
  visually accurate even when it is not live UI reading through `Tokens`.
- **Do** treat the alignment wizard's stage tokens and the EQ scope's own
  tokens as fixed-hue instruments that never theme (the scope's shaped trace,
  fill and gridlines draw `equalizer` under its pinned dark appearance, so
  they never theme either), matching their documented intent, not as a bug to
  "fix" toward appearance-awareness.
- **Do** keep the six permission identity hues fenced to the first-run
  Setup spine; a new surface needing a per-item identity hue asks for its
  own decision, it does not borrow from this set.

### Don't:
- **Don't** draw MUTE, or any hover/selection wash, in gold — gold means the
  row is carrying audio, so a mute state and a live state may never share a
  hue. The washes stay on `engagedChrome` (an alias of `label`), the
  deliberately neutral "this control is engaged" tone. The device row's mute
  button no longer draws from it: it has its own reserved hue,
  `Tokens.Color.muted` (see the Muted-Hue Fence under Colors).
- **Don't** draw `hairline` on `raised` — `MembershipWellContrastTests`
  pins `containerEdge` at ≥1.25:1 and ranks it above `hairline`, which is how
  the codebase encodes that `hairline`'s own measured 1.154:1 there falls
  under the edge floor; use `containerEdge` on that surface instead.
- **Don't** invent a new custom-drawn chrome surface or control-cell skin
  outside the pieces named in Elevation & Depth's Named Rule above; a new
  one gets named in its owning folder's `AGENTS.md`, not added silently.
- **Don't** add a `Tokens.Color` case without a real consumer — the module's
  own governance comment states this. `liveRow`, `liveRaised` and `party`
  were deleted for having none.
- **Don't** hand-build a piece the library already has: a row's slider and
  readout (`RowVolumeFader`), a hover wash (`HoverTracker`,
  `PopoverColumnGrid.fillRowWash(in:alpha:)`), an empty or permission row
  (`CardMessageRow`), an underlined link (`TextLinkButton`), a tinted notice
  (`TintedNoteBackgroundView`), a 1 pt rule (`RuleView`), a folding clip
  (`FoldingClipView`), a page header (`PageHeaderView`) or an explanatory
  note (`noteLabel`).
