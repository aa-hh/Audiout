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
    backgroundColor: "none at rest; {colors.gold} at 12% wash while route-armed, or the neutral hover wash"
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
- **Gold** (`#E8B84B` dark / `#A67C1E` light): the signal, audio state and
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
place that wiring lives, and thirteen views across the Groups window and
Settings call it. A view whose colors are stamped `CGColor`s on a `CALayer`
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
deleted this migration, per Alec's decision F3). The dial remaps exactly ten
tokens: the five accent instruments `gold`, `goldText`, `ember`, `emberText`,
`glow` (via `accentDynamic`), and the five permission identity hues
`permissionSystemAudio`, `permissionLocalNetwork`, `permissionRemoteControl`,
`permissionSpeakerSync`, `permissionUsageStats` (via `permissionDynamic`,
whose own header names `Tokens.accentStyle` as the same switch). Nothing else
is dial-aware — `failure`/`rim`/`ring`/`muted` and `bluetoothBrand` are fixed
in every dial position. `glow` alone has no Subtle rendering and resolves fully
`.clear` at that dial position ("no glow shadow"); the five permission hues
always resolve a real, muted color at Subtle, because an opaque glyph fill
cannot go invisible the way a halo can. Changing the dial broadcasts
`Tokens.accentStyleDidChangeNotification`; a `CALayer`-stamped instrument
must observe it explicitly, the same way it observes appearance/Increase-
Contrast changes.

**The Permission-Hue Fence (Mac-only, not a system pattern).** Five identity
hues — `permissionSystemAudio` (warm slate), `permissionLocalNetwork` (dusty
plum), `permissionRemoteControl` (muted mauve), `permissionSpeakerSync`
(deepened brass, gold-adjacent but held below the gold/amber band), and
`permissionUsageStats` (verdigris) — mark each first-run permission row's SF
Symbol glyph and nothing else. Each hue is permanent per-row identity, never
a state (granting a permission never recolours its glyph; the row's own
status chip carries the granted state). All five are reserved out of the
gold/amber band `[28°,68°)` and the failure-red band, and are mutually
distinguishable by ≥47° of hue — a floor recorded in `Tokens.swift`'s own
doc comments for each of the five tokens (lines 785, 820, 842, 864, 890,
906), not asserted by degree in any test; `OnboardingPermissionColorTests`'s
mutual-distinctness suite only checks that the five resolved colors are
pairwise unequal. The
sixth glyph on the same spine, `bluetoothBrand` (the fixed Bluetooth SIG
blue, ~209°), sits outside this fence entirely — it is a real-world brand
mark, not a Warm Signal identity hue, and the same test suite deliberately
excludes it from the distinctness check (it sits only ~1° from
`permissionSystemAudio`'s ~208°, which is fine precisely because it is not
part of the five-hue system being kept distinguishable). This whole fence is
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

**The Instrument Ground Rule (Mac-only).** The alignment wizard's stage
(`stagePlate`, `stageRule`, `stageInk`, `wireCore`, `fuseWhite`) authors the
same hex for dark and light — a fixed dark instrument face set into a
themed window, never a themed surface. `syncSignalDeep` is its one themed
companion, used where the target's identity hue must sit on the surrounding
window chrome (the plate rim/keycap tint in light mode) instead of the fixed
plate itself. `partyRampDeep` is NOT part of this stage — `Tokens.swift`'s
own comment states plainly that group identity is not drawn on this sheet;
`partyRampDeep` belongs to the Groups window and popover instead (see Group
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
("Output Groups", "AirPlay Devices") is an `NSMenuItem.sectionHeader` — the
only item AppKit documents as non-interactive, so it cannot be highlighted,
hovered or picked. A hand-disabled plain item does not substitute: an
`NSPopUpButton` re-points every item's action at its own cell, and while
`autoenablesItems` is on AppKit ignores `isEnabled` outright, so the header
lights back up. Its appearance is owned by `NSMenu` and is not customised.
Because One Case leaves the header in the entries' own type register, the
separation is structural instead: a rule above every section but the first,
and every entry one indentation level in, so its header hangs to the left.
That indentation is a deliberate departure from the HIG, which prefers a
submenu to indenting menu items (Alec, 2026-09-05) — a submenu would put
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
Output Devices card's list of speakers stops at twelve rows
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

**Row geometry** is centralized in `PopoverColumnGrid`, which `Tokens.Layout`
forwards rather than duplicates: 14pt leading and trailing insets, a 26pt
icon column, a 150pt slider, a 40pt readout column, a 24pt mute control, a
140pt trailing-control reservation, and a 42pt body row height. Columns
anchor to the row's trailing edge, matching the iPhone file's own row-as-
fader grammar in AppKit terms.

**Settings** is a sidebar-plus-pane split (`SettingsRootViewController`),
never tabs — a new section becomes another sidebar row. It is its own
window-hosted surface, not a sheet.

**Groups** is a separate window (`MixerWindowController`) with a sidebar
split that must never collapse, hosting a card-grid overview and a
configuration-only editor pane. Selection there is never activation.

**Onboarding** is a floating first-run window: a spine of status rows beside
one hero panel, gating Done until every check passes.

## Elevation & Depth

Mostly flat, matching iOS: the dark ground ladder (canvas → panel → raised)
and, in light, edge weight alone carry depth. `Tokens.Color.shadow` (an
alias of `NSColor.black`) has three real consumers, every one of them a flat
clipped band rather than a blurred `NSShadow`: `AlignmentPlateCell` (the
wizard's answer-plate lip shading, rim shadow blend, and chip shadow fill),
`WarmFaderCell` (the fader trough's inset shade, 0.18 alpha), and
`GroupedSectionView`'s `.well` style (a 1pt band at that same 0.18, clipped
inside the shape's top edge). `.well` is the page card recessed: the
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
NSTextFieldCell` (the Groups window's inline-rename field), and
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
emphasized weight for a finale CTA). It exists specifically to patch a stock
AppKit defect — a `bezelColor` fill drops to a plain bezel when its window
resigns key, but AppKit does not recolor the title to match, so `inkOnFill`
reads dark-on-dark or white-on-white — by tracking key state and swapping to
`Tokens.Color.label` when the window is not key. It also accepts the first
click after the app is reactivated by returning from System Settings mid-
onboarding, rather than spending that click only on activation.

### Surface Header Strip (popover shell, Mac-only)
Four items, all drawn the same way: the three screen tabs (Mixer, Groups,
Settings) and Pin. There is no Quit item on the strip. Each is an `NSButton`
wearing `SurfaceToolbarSeatCell`, seated in an `NSToolbarItem` as its custom
view; the `NSToolbar` itself stays because it is the window's unified
title-bar strip and supplies the system material and the Reduce Transparency
handling.

One shape carries every state: a rounded rectangle at `Radius.control` (10pt)
on a fixed 30 × 26pt seat, glyph at 15pt. Ten on a 26pt-tall seat leaves 6pt of
straight edge top and bottom, so it reads as a rounded rectangle and not the
capsule a larger radius would give. Four states, three drawn weights, in
`engagedChrome` at the ladder the mixer's rows already use: rest draws no seat
at all, hover takes `PopoverColumnGrid.rowHoverWashAlpha` (0.10), the current
screen and a pinned Pin take `rowSelectionWashAlpha` (0.18), and a press takes
`mutePillFillAlpha` (0.22). Increase Contrast multiplies all three by 1.5,
capped at 1, read live at draw time. The glyph's ink steps with the seat rather
than against it — `label` engaged, `label2` idle — so the current screen is
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

The seats are icon-only and fixed-width so the strip's width cannot change
with the selection, the appearance or the language — a widening strip is what
would sweep the tabs behind the overflow chevron, and primary navigation cannot
live behind a chevron.

### Device Row (shared with Groups and the popover)
The row-as-fader grammar restated in AppKit, but through INK, not a
background-fill swap: `liveRow`/`liveRaised` are declared in `Tokens.swift`
but have zero call sites anywhere in `Sources/` today — the halo/fill they
were authored for is not what actually ships. What the shipped row does:
the name label takes the system label color while sounding and
`Tokens.Color.labelCool` while idle; the readout takes `goldText` while
route-armed, `emberText` while idle-but-adjustable, and drops to
`labelCool2` when the slider is disabled or the row is in the muted-
unconnected treatment (`DeviceRowView.swift`). Warm ink and a gold wash mean
`isRouteArmed`; cool means silent. Instruments are flat — no `CALayer`
blooms.

### Equalizer Door (Mixer, Mac-only)
The Mixer carries an equalizer DOOR only — the row button beside mute, and
the row context menu — plus one mark. When the speaker's curve is not flat
the door draws a gold seat: a `Tokens.Color.gold` fill 24 × 22pt, cornered at
6pt, with a 1pt `Tokens.Color.inkOnFill` border, and the `slider.horizontal.3`
glyph on top in that same dark ink at 15pt semibold. At rest there is no seat
at all — a `Tokens.Color.label2` glyph at the row's 13pt accessory size.

Both numbers on the seat are measured against what sits inside it and what
sits 6pt trailing. The 15pt glyph draws 15.5 × 13.5pt of ink, so on the door's
own 24pt column that leaves 4.5 / 4pt of gold each side, and 22pt of height
gives the same 4.5 / 4pt above and below: the mark sits in even padding
instead of overrunning a seat that has a 1pt border on it. A full 24 × 24 seat
would stand 71% taller than the engaged mute pill's measured 19 × 14 and
dominate a 42pt row. The 6pt corner is deliberately not `Radius.control` (10):
6 stays visibly short of the 11pt capsule point of a 22pt-high seat, so the
door reads as a rounded SQUARE and never as a second copy of the mute pill,
whose own 10 clamps to 7 on a 14pt pill and makes a true capsule. The seat is
its own view behind the button rather than a fill on the button's layer,
because an `.accessoryBar` `NSButton` frames larger than the alignment rect
its constraints size — the door's 24 × 24 constraint pair produces a measured
24.5 × 30.5 frame, which would put a 30pt gold slab in a 24pt slot, sat 1.5pt
high of centre.

A fill carries this state because a hue swap measurably cannot. The mark was a
bare gold glyph until 2026-09-04: gold runs 3.64:1 on `canvas` in light where
the at-rest `label2` runs 5.97:1, so the "on" state read 39% dimmer than the
"off" state; dark separated the two by 1.22:1; and under the Subtle accent the
relationship inverted in every appearance. `canvas` was added to gold's tested
grounds in `TokenContrastMatrixTests` at the same time — its absence is why
3.64:1 was never caught. The border resolves `inkOnFill` under `.darkAqua`
whatever the row's own appearance is: that token turns white under light plus
Increase Contrast, which is right for a glyph sitting ON the gold and wrong for
the outline around it, since a white outline on the light canvas is no outline
at all. This mark is a dark border around a gold fill in every appearance.

The border is a deliberate reversal of the rule this section used to state. It
said: no border, because the mute button beside the door already says "engaged"
with a filled pill, and a second shape for the same idea would give one row
three vocabularies. Alec overruled it on 2026-09-04 knowing mute sits 6pt away.
The two engaged marks are drawn to stay legibly apart by shape, hue and border
at once: the door is an opaque gold rounded square with a dark border and an
oversized, heavier glyph; mute is a borderless cool capsule at the at-rest
glyph size. The door's slot and the 6pt gap to mute are unchanged — the mark
grew inside the seat the door already had.

Still no magenta: magenta is group identity (`partyRampDeep`), never the
wizard's territory — this migration moved the wizard's own reference light to
`Tokens.Color.ring` (blue), and `Tokens.swift`'s own comment says group
identity is "not drawn on this sheet" (see the Instrument Ground Rule under
Colors). No editor, no curve, and no tone control lives on the Mixer itself
(2026-08-22, amended 2026-09-03 and 2026-09-04); the door opens
`DeviceDetailViewController` where the real Equalizer control lives.

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
`canvas`, 5.69 on `raised`, 5.14 on the gold live wash and 5.15 on the hover
wash in dark; 6.17 / 6.17 / 6.17 / 5.41 / 5.10 in light; 8.90 / 9.80 / 7.81 /
6.90 / 7.07 dark Increase Contrast; 8.22 / 8.22 / 8.22 / 7.03 / 6.80 light
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
clipped mid-word — to about "Unava". Alec chose the consistent version on
2026-09-04 over fitting words where they fit, so an AirPlay row's wider slot
draws the same bare glyph. This knowingly retires the Bluetooth-UI rule that
"Connected elsewhere" and "Not paired" must read distinctly ON THE ROW; they
still read apart, on the tooltip and in the spoken value.

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

### Permission Row (Onboarding, signature component, Mac-only)
`IconTileView`'s neutral `raised` fill and hairline rim stay untouched; only
the SF Symbol glyph carries one of the six spine hues (five dial-aware
identity hues plus the fixed Bluetooth brand blue), permanently, per row.
See the Permission-Hue Fence under Colors. The whole row is the press
target; locked and auto-passed rows refuse silently rather than looking
pressable.

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
- **Do** keep the five permission identity hues fenced to the first-run
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
