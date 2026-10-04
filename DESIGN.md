---
name: Audiout (Mac)
description: The menu-bar mixer half of Warm Signal — a cool near-neutral chassis in stock AppKit, gold reserved for audio state, calls to action, selection and completion, and five identity hues (plus one fixed brand mark) fenced to onboarding alone
colors:
  canvas: "#0A0A0C"
  panel: "#15171A"
  raised: "#1F232A"
  well: "#050507"
  liveRow: "#2E2518"
  liveRaised: "#2B241C"
  label2: "#B7AC95"
  label3: "#9E947F"
  labelCool: "#A9B3BB"
  labelCool2: "#818C94"
  hairline: "#2A2E33"
  containerEdge: "#3D4247"
  rim: "#6B767D"
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
  bluetoothBrand: "#0082FC"
typography:
  body:
    fontFamily: "SF Pro (system)"
    fontSize: "13pt (NSFont.systemFontSize)"
    fontWeight: 400
  bodyEmphasized:
    fontFamily: "SF Pro (system)"
    fontSize: "13pt"
    fontWeight: 600
  heading:
    fontFamily: "SF Pro (system)"
    fontSize: "16pt (systemFontSize + 3)"
    fontWeight: 600
  caption:
    fontFamily: "SF Pro (system)"
    fontSize: "11pt (smallSystemFontSize)"
    fontWeight: 400
  microLabel:
    fontFamily: "SF Pro (system)"
    fontSize: "10pt"
    fontWeight: 600
    textCase: "sentence case, as authored — never transformed"
  readout:
    fontFamily: "SF Pro (system), monospacedDigit"
    fontSize: "11pt (smallSystemFontSize)"
    fontWeight: 600
  display:
    fontFamily: "SF Pro (system)"
    fontSize: "20pt"
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
  groupedSection: "10pt"
spacing:
  leadingInset: "14pt"
  trailingInset: "14pt"
  iconWidth: "26pt"
  sliderWidth: "150pt"
  readoutWidth: "40pt"
  muteWidth: "24pt"
  trailingControlWidth: "140pt"
  bodyRowHeight: "42pt"
components:
  button-prominent:
    backgroundColor: "{colors.gold}"
    textColor: "{colors.inkOnFill}"
    typography: "{typography.body}"
    rounded: "999pt (rounded bezel)"
  device-row:
    backgroundColor: "none at rest; the neutral hover wash on pointer-over"
    textColor: "system labelColor (live) / {colors.labelCool} (idle) for the name; {colors.goldText} (live) / {colors.emberText} (idle) for the readout"
    rounded: "{rounded.row}"
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
jobs are audio state and calls to action; it also marks selection (the icon
picker's selected cell, the appearance-tile ring) and completion (onboarding
checkmarks), and the EQ scope draws its own reference trace in gold too. This
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
  to the device row's engaged mute button (see the Muted-Hue Fence)
- Gold's primary jobs are audio state and calls to action; it is also the
  app's one selection/completion mark and the EQ scope's own signal trace —
  never a decoration outside those roles
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
  the popover shell (12pt) and grouped-section cards (10pt, coincidentally
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
  calls to action. Identical values and identical rules to iOS.

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
  iOS — divider, container edge, control edge — same hexes.

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
`raised`, `well`, `liveRow`, `liveRaised`) author only TWO — light and dark —
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
`#4A50C7` light, Increase Contrast `#ADB1F7` / `#393FA8`), means one thing:
this output is deliberately silent. Its only consumer is the device row's
engaged mute button (`DeviceRowView.updateMuteTint()`), which fills the pill
opaquely in this hue and knocks a `speaker.slash.fill` glyph out of it in
`panel`. It may not appear anywhere else. It is not a second cool accent, not
a disabled or dimmed tone, and not available to a control that merely happens
to be off. A row silent for some OTHER reason — unavailable, failed, not a
member — keeps its existing treatment, because this hue answers "someone muted
this", not "no sound is coming out". `DeviceRowMutedStateTests` fails if a
second call site appears in `Sources/`. Why a new hue rather than one already
here: `gold`/`ember` mean the row is carrying audio, so mute can never borrow
them — that rule is the reason this token has to exist; `failure` red means
something went wrong and a mute is deliberate; `party`/`partyRampDeep` is group
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
dark / `#007835` light), means one thing: this speaker's curve is not flat.
Its only call site is `DeviceRowView`, which inks two marks with it: the
device row's engaged Equalizer door (`DeviceRowView.updateEQButton()`) and
the mark beside the speaker page's Equalizer summary, which takes its image
from `DeviceRowView.equalizerEngagedMarkImage(in:)`. Both are the door's
custom square symbol drawn in this hue. It is not a general "on"
green, not a success tone, and not available to a second control that happens
to be engaged; `DeviceRowMutedStateTests` fails if a second call site appears
in `Sources/`. The door wore `goldText` until 2026-09-04, and gold means
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
(`scopeGround`/`scopeFlatLine`/`scopeBypassLine`, plus a `gold` shaped trace
and reference gridline) is a hardware-analyser scope: dark screen, lit
trace, identical hex in both appearances, drawn under a forced
`NSAppearance(named: .darkAqua)`. The wizard stage and this scope are the
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
- **Heading** (600, 16pt): device-detail and group-editor name fields, form
  section titles — one step above body.
- **Body** (400, 13pt; `bodyEmphasized` 600/13pt): the most common label
  font — row names, headings, form labels.
- **Caption** (400, 11pt; `captionMedium` 500/11pt; `captionEmphasized`
  600/11pt): secondary/detail text — sublabels, readouts, hints, footers.
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
is on-scale. A handful of narrow, single-consumer sizes exist by design and
are documented at their declaration rather than promoted into the shared
scale: `syncReadout` (12pt monospaced, the BT sync drawer's editable value),
`keycap` (11pt, the wizard's key-chip glyphs), `plateTitle` (15pt, the
wizard's two hero answer plates), `detail` (11pt, compact explanatory copy).
Do not read these as a second type scale — each is pinned to the one row or
sheet that measured it.

## Layout

The popover is the primary shell: `AppSurfaceController` swaps Mixer/Groups/
Settings through one hosted panel, sized through `preferredContentSize` —
height flows from content, pinned top and bottom. It has one ceiling. The
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
forwards rather than duplicates: 14pt leading and trailing insets, a 26pt
icon column, a 150pt slider, a 40pt readout column, a 24pt mute control, a
140pt trailing-control reservation, and a 42pt body row height. Columns
anchor to the row's trailing edge, matching the iPhone file's own row-as-
fader grammar in AppKit terms.

**Settings** is a sidebar-plus-pane split (`SettingsRootViewController`),
never tabs — a new section becomes another sidebar row. It is its own
window-hosted surface, not a sheet.

The Scenes and Speakers content (`MixerWindowController`) has two roots. The
Scenes root is a card-grid scene overview and a configuration-only scene
editor, with no sidebar. The Speakers root is a sidebar split that must never
collapse: the sidebar is the only speaker list, beside the Speakers page, a
speaker's page or Main Audio. Selection on either is never activation.

The **Speakers page** (`SpeakersPageViewController`) lists no speakers. Its
column sits at the top of the pane on `GroupsPaneLayout` insets: the 48 pt
icon well, the title, and one caption line in `Tokens.Font.caption` /
`Tokens.Color.label2` that reports the search for speakers. While looking it
reads a small spinner, "Looking for speakers on your network…" and "· N found
so far". Once `SpeakerSearch` decides the search is done (the list of speakers
the Mac can see has not changed for 0.5 s, the popover's first-open quiet
window, or a 10 s ceiling ran out; once per launch) it shows an
`NSColor.systemGreen` check and either "All N speakers found" or "Done
looking · ● F found · ○ A away", the dots drawn by the sidebar's own
`SidebarPresenceDotView` at 7 pt. Below it, one `GroupedSectionView` card
ends at its last row. Its first row counts every kept speaker by kind
(AirPlay, Bluetooth, Cast, This Mac, Unknown; a kind with none is left out):
a 16 pt glyph, the count in `Tokens.Font.heading`, the label in caption ink.
Then one-line `ListRowView` rows, each only when true: "Bluetooth access is
off" with its action button, "N speakers can't be found" with "Forget N
speakers…" (only after the search is done), and "Pair Bluetooth speaker…"
with a chevron, always last. Each row's longer sentence is its tooltip and
VoiceOver hint.

**Onboarding** is a floating first-run window: a spine of status rows beside
one hero panel, gating Done until every check passes.

## Elevation & Depth

Mostly flat, matching iOS: the dark ground ladder (canvas → panel → raised)
and, in light, edge weight alone carry depth. `Tokens.Color.shadow` (an
alias of `NSColor.black`) has four real consumers, every one of them a flat
clipped band rather than a blurred `NSShadow`: `AlignmentPlateCell` (the
wizard's answer-plate lip shading, rim shadow blend, and chip shadow fill),
`WarmFaderCell` (the fader trough's inset shade, 0.18 alpha),
`GroupedSectionView`'s `.well` style (a 1pt band at that same 0.18, clipped
inside the shape's top edge), and `SetupPreviewFrameView` (the onboarding demo
frame, which blends the same 0.18 lip and a 0.06 darkening of its own `well`
fill, because it is layer-backed rather than hand-drawn). `.well` is the page card recessed: the
`Tokens.Color.well` fill in place of `.card`'s `raised`, the same
`containerEdge` stroke and the same `panel` radius. Both Equalizers wear it —
`DeviceDetailViewController`'s `eqWell` and `MainOutDetailViewController`'s —
because `.card`'s `raised` fill IS the flat `#FAFAFB` ground in light,
identical to the `canvas`/`panel` it sits on, so a card there is a 1pt outline
around nothing. `well` (`#E9EAEC` light / `#050507` dark) is the one neutral
that stays visibly recessed on the flat chassis: 1.154:1 on the light ground,
1.134:1 on dark `panel`, both figures recorded in `Tokens.swift`'s own doc
comment on `well`. The band gives that recess a shaded lip on top of the edge
stroke below. The popover's own
`ControlPanelBackingView` (a custom-drawn bubble-plus-beak shape, because
`NSPanel` has no arrow) is a separate, named custom-drawn exception that
does not itself draw a shadow.

### Named Rules

**Custom Drawing Is a Short, Named List.** Root `AGENTS.md` names the
sanctioned custom-drawn Warm Signal pieces as: the canvas, the connection
ring, the signal dot, the meter, the bus control, the fader skin, and the
shell bubble fill. Below that chrome-level list, seven drawing-only AppKit
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
every item of the surface header strip). Each folder's own
`AGENTS.md` names its own local exception rather than one file listing them
all — `AudioutSharedUI/AGENTS.md` names `ControlPanelBackingView`,
`AudioutPopoverUI/AGENTS.md` names the seat cell, and
`AudioutOnboardingUI/AGENTS.md` names `DemoPaneView` separately. Anything not
on one of these lists draws with stock AppKit chrome; a new custom-drawn
piece gets named in its owning folder's `AGENTS.md`, not invented silently.

## Shapes

Three radii shared with iOS: **control** (10pt), **row** (16pt), **panel**
(26pt) — adopted this migration so the two apps round the same shapes by the
same amounts (rows, cards, seats and chips on Groups). Two further radii are
Mac-only and predate the shared ladder, kept because nothing forced their
consolidation: **popover shell** (12pt — `ControlPanelBackingView`'s bubble
body and the quit-in-progress HUD, previously two independent literals) and
**grouped section** (10pt — onboarding's permission card, matching System
Settings' own inset-list card radius, not the shared `control` value by
intent even though the number happens to match).

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
28pt square, is a circle. Weights are `engagedChrome` at the ladder the
mixer's rows already use: the capsule itself washes at 0.06, hover at
`PopoverColumnGrid.rowHoverWashAlpha` (0.10), the current screen and a pinned
Pin at `rowSelectionWashAlpha` (0.18), and a press at `mutePillFillAlpha`
(0.22). Increase Contrast multiplies all of them by 1.5, capped at 1, read
live at draw time; Reduce Transparency gives the capsule the heavier `rim`
edge instead of a heavier fill. The glyph's ink steps with the seat rather
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
`if #available(macOS 26.0, *)` while the package deploys to 14.2, so macOS
14–25 showed three identical circles and no current screen at all.

Only the current tab shows its name, to the right of its glyph, at
`Tokens.Font.captionMedium`. The glyph keeps its place and the tab grows to the
right, with the same 7.5pt from the glyph's ink to the name's first letter and
after its last letter, measured off the drawn letters rather than the label's
frame. The others are icon-only, and the tooltip
("Scenes (⌘2)") and VoiceOver label carry every name. The name is clamped to
`maxNameWidth` (120pt) and truncates past it, so the widest the strip can be
is `widestCapsuleWidth` plus Pin, 282.5pt of the fixed 653pt surface, in any
language: a widening strip is what would sweep the tabs behind the overflow
chevron, and primary navigation cannot live behind a chevron.

### Device Row (shared with Groups and the popover)
The row-as-fader grammar restated in AppKit, but through INK, not a
background-fill swap: `liveRow`/`liveRaised` are declared in `Tokens.swift`
but have zero call sites anywhere in `Sources/` today — the halo/fill they
were authored for is not what actually ships. What the shipped row does:
the name label takes the system label color while sounding and
`Tokens.Color.labelCool` while idle; the readout takes `goldText` while
route-armed, `emberText` while idle-but-adjustable, and drops to
`labelCool2` when the slider is disabled or the row is in the muted-
unconnected treatment (`DeviceRowView.swift`). Warm ink means
`isRouteArmed`; cool means silent. Instruments are flat — no `CALayer`
blooms.

An unavailable retained row keeps its name, glyph and connection node. A
caption in the trailing control area gives its status while live controls
are unavailable. Where recovery is offered, the name itself is the action,
also reachable by keyboard and VoiceOver; there is no separate Connect
button. A nonlocal row's context menu carries a **Show in Mixer** section with
the shared **When available**, **Always** and **Hide when not in use**
choices, the current one checked, then **Speaker settings…**, which opens
that speaker's page. A speaker in current use remains
visible even when its saved choice is Hide when not in use.

### Speakers Sidebar and Pages
The sidebar is the only speaker list. Under the System Audio row and the
Speakers plate it holds two groups that are the Mixer visibility setting:
**In the Mixer**, with This Mac first and the rest alphabetical, and, only
when it has rows, **Hidden unless playing**, which folds through the stock
hover Show/Hide control. Rows are one line. A 9 pt dot before the icon shows
presence, never routing: a filled `ember` disc for a speaker on the network, a
1.5 pt `ember` ring for one that is away, a `gold` disc with a 1 pt `ember`
ring for one that is playing, and the `failure` `exclamationmark.triangle` at
11 pt for one the Mac can't find. The one caption is **In the Mixer while it
plays**, on a 40 pt row, for a hidden speaker in use. The right-click menu
offers **Hide from Mixer** or **Show in Mixer**, **Keep in Mixer when
unavailable** (checked for Always), **Speaker settings…**, and **Forget…** for
speakers the Mac can't find; dragging rows onto the other group's header moves
them between groups. Forget asks first in a warning sheet whose Return key is
Cancel, and refuses when a scene would be left with no speaker, naming the
scene to delete first.

Every window page opens with a 48 pt icon well, a 16 pt semibold name and one
caption line. A speaker's caption is its kind and status ("Sonos · Ready"),
"This Mac", or the failure glyph and "Can't be found". The Equalizer sits open
below: its title row carries the green engaged mark, a one-line summary
("Bass 3 dB, Loudness on", or "Flat") and a Reset button hidden while the
curve is flat. A speaker the Mac can't find shows no editor, only a note that
its curve is kept when it is shaped, and a Forget button. Then a two-row
outlined list: **Show in Mixer**, whose caption explains the current choice
beside its pop-up (absent for This Mac), and **Scenes**, linking each scene the
speaker belongs to.

The Speakers plate's page lists no speakers. Under a subtitle counting the
speakers in the Mixer and hidden, one outlined list holds only the rows that
are true: the discovery result (a `systemGreen` `checkmark.circle.fill` when
every speaker is found, a small spinner while looking), Bluetooth access while
it is off, the speakers that can't be found with a Forget button, and **Pair
Bluetooth speaker…** last. The found mark is stock `systemGreen` because the
equalizer green is fenced.

Scene checkboxes change membership. Their rows give an unavailable member's
status and nothing about visibility; scene cards count unavailable members
alongside the existing Playing and Feeding labels.

### Equalizer Door (Mixer, Mac-only)
The Mixer carries an equalizer DOOR only (the row button beside mute, and the
row context menu) plus one mark. The door is one custom symbol,
`custom.slider.horizontal.2.square` (`RowAccessorySymbol.equalizerRest`),
which `DeviceRowView.updateEQButton()` draws in two inks: the row's at-rest
`label` ink while the curve is flat, and `Tokens.Color.equalizer` over
everything the symbol draws while it is not (since 2026-09-05). Mute, 6 pt
trailing, sits in the same square outline but carries a different glyph: a
speaker for mute, sliders for the Equalizer. The glyph says which control it
is, and colour then tells engaged from resting.

The door is green, not gold, because it wore `goldText` until the symbols
landed and gold means "audio is flowing here" everywhere else, including the
live wash this row draws behind the door. The Equalizer-Hue Fence under
Colors holds the hue to this mark and the speaker page's summary mark. No
magenta either: magenta is group identity. No editor, no curve and no tone
control lives on the Mixer itself; the door opens `DeviceDetailViewController`,
where the Equalizer sits open.

### Mute Button (Mixer row)
At rest: `speaker.wave.2.fill` at the shared 13pt accessory size, tinted
`label2`, no fill. Muted: `speaker.slash.fill` at that same size and weight,
knocked out in `Tokens.Color.panel`, on an OPAQUE `Tokens.Color.muted` capsule
at `mutePillCornerRadius` (`Radius.control`, clamped by the pill's own height)
with no border.

The fill is opaque because a translucent one measurably cannot do this job. A
tint of this hue tops out at 2.31:1 against the row ground even at 45% alpha,
under the 3:1 non-text floor in every appearance — which is why the
`engagedChrome`-at-0.22 pill it replaces, holding an unslashed speaker, read as
a faint grey pill with an ordinary speaker in it. Opaque, the pill clears that
floor on every ground the row can put behind it: 6.48:1 on `panel`, 7.14 on
`canvas`, 5.69 on `raised`, and 5.15 on the hover
wash in dark; 6.17 / 6.17 / 6.17 / 5.10 in light; 8.90 / 9.80 / 7.81 /
7.07 dark Increase Contrast; 8.22 / 8.22 / 8.22 / 6.80 light
Increase Contrast.

The glyph's ink is `panel`, the row's own ground, so the mark reads as punched
THROUGH the pill — and because `panel` is dark in dark and light in light it
flips polarity with the fill for free, at 6.17:1 in the worst cell. `inkOnFill`
cannot do this: it is authored as dark ink on the gold family and turns white
under light plus Increase Contrast. This is the one place `panel` is a
foreground rather than a ground, and `TokenContrastMatrixTests` holds it to the
4.5:1 glyph floor there.

The slash retires the older "the icon never changes on toggle" decision.
`.fill` rather than plain `speaker.slash` so it keeps the weight of the at-rest
glyph it replaces; it landed in macOS 10.15, well under the package's 14.2
floor. It collides with nothing — `Device.Kind.symbolName` already avoids the
`speaker.*` family for the Bluetooth row icon for this reason.

`MainOutRowView` has not been given this treatment and still draws the old
`engagedChrome`-at-0.22 pill behind an unslashed speaker.

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
while connected; solid `failure` when failed. The rail node for a connecting
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

### Group Row and Membership Rail (Groups, signature component)
`GroupIdentityGlowView` sits behind every group seat, active or not, drawn
in `partyRampDeep` — the Mac's own instance of the iOS "magenta is identity,
never state" rule, and the actual consumer of that hue (the sibling `party`
token has no call sites and is not carried in this file's frontmatter for
that reason). Ink carries temperature per decision C5: `labelCool` on idle
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
- **Do** treat the alignment wizard's stage tokens and the EQ scope's tokens
  as fixed-hue instruments that never theme, matching their documented
  intent, not as a bug to "fix" toward appearance-awareness.
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
  own governance comment states this, and `liveRow`/`liveRaised` (declared,
  zero call sites) and the `party` token (declared, zero call sites — its
  alias `partySignal` is what forwards to it; only `partyRampDeep` renders) are the two live examples of the drift this
  rule exists to prevent. Recording them as active system rules here would
  have papered over that drift rather than naming it — they are listed as
  the codebase's own reason to keep this Don't, not as usable tokens.
