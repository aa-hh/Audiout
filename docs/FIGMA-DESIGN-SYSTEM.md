# Figma design system — contract, map, upkeep

The Audiout design system lives in Figma file **`aGvr1qZ3tbqGD2e3jmA1Ru`** (built
2026-08-07). This doc is how a future agent keeps that file true to the code. The
build itself is done — maintenance is incremental, per the rubric below.

## The contract

The Figma file and the code are bound by naming, not by tooling (Code Connect is
blocked — it needs a Dev/Full seat on an Org/Enterprise plan — so the contract is
carried in the file itself):

- **Color variable names mirror `Tokens.Color` case names 1:1**
  (`AudioutCore/Sources/AudioutSharedUI/Tokens.swift`; the code's canonical
  string is `NSColor.Name "WarmSignal.<caseName>"`).
- **Layout variable names mirror `PopoverColumnGrid` constant names 1:1**
  (`AudioutCore/Sources/AudioutSharedUI/PopoverColumnGrid.swift`), grouped by
  slash prefix (`rows/bodyRowHeight`, `columns/sliderWidth`, …).
- **Every variable carries Code Syntax (platform "iOS") = its exact Swift
  constant** — e.g. `Tokens.Color.canvas`, `PopoverColumnGrid.bodyRowHeight`.
  "iOS" is just Figma's only Swift-shaped slot; it means Swift, not iOS.
- **Every component description names its Swift source file** (plus line refs
  for drawing specs).
- **Variant properties are named after the code's state enums** — e.g. DeviceRow's
  `connectionState` = off / connecting / reconnecting / connected / failed.
- **SYSTEM vs OURS**: layers tagged `SYSTEM` are instances from the **macOS 27
  UI kit** — never rebuilt or redrawn, only re-instanced. Layers tagged `OURS`
  are Warm Signal custom drawings owned by this file. The macOS 27 kit is the
  kit of record (library key
  `lk-9b6046629e11db2bbe15e5a3fa0443ecd557a34812bc69997a2b8598852d86fb806d4036ca6c146521c7e1cf898a1e3d46dda55a15bf1f86579794b29480aa80`);
  the file is also subscribed to a macOS 26 kit — **do not use it**.
- **Code wins over spec.** The file draws what the code does today; spec-only
  ideas live on the *Reference · Spec backlog* page, never in components/screens.

## The map

Node IDs are stable lookup keys (`figma.getNodeById(...)` via the Plugin API).

### Variable collections

| Collection | ID | Modes (mode ID) |
|---|---|---|
| Warm Signal color | `VariableCollectionId:41:2` | Dark `41:0` · Dark HC `41:1` · Light `41:2` · Light HC `41:3` |
| Accent (dial) | `VariableCollectionId:42:25` | Full `42:0` · Subtle `42:1` |
| Layout | `VariableCollectionId:43:2` | single mode `43:0` |
| macOS kit colors (library) | `VariableCollectionId:158c3760fc1910e82f0b41413d89c0fb0b20c306/4311:30` | Dark mode `207:0` — set as an **explicit mode on every content page** |

Variable names (each resolvable by name; IDs ledgered in the build state):

- **Color collection** — surface ladder `canvas canvasHi panel raised well
  hairline meterTrack sidebarWarmTint`; instruments `ringConnected failure
  caution faderThumb faderRim dotSocket`; system pass-throughs `label
  secondaryLabel tertiaryLabel quaternaryLabel accent destructive warning
  windowBackground separator underPageBackground selectedContentBackground
  tertiarySystemFill shadow clear`; plus `src/` accent sources
  (`gold-full`, `gold-subtle`, `ember-full`, `ember-subtle`, `glow-full`,
  `glow-subtle`, and the four `permission*-full/-subtle` pairs) carrying the
  four appearance modes.
- **Accent collection** — `gold ember glow permissionSystemAudio
  permissionLocalNetwork permissionRemoteControl permissionSpeakerSync`; each is
  an **alias into the matching `src/` variable** per dial mode (Full → `*-full`,
  Subtle → `*-subtle`). The third code dial, System accent
  (`controlAccentColor` multipliers), is documented on the Foundations page
  only — it cannot be a Figma mode.
- **Layout collection** — every `PopoverColumnGrid` constant, slash-grouped:
  `insets/ rail/ meter/ mainAudioRing/ columns/ anchors/ feed/ statusBadge/
  halo/ rows/ gaps/ fader/ field/ alphas/ surfaces/`.
  Awaiting mirroring (2026-09-03): `syncDrawerAlignAgainButtonWidth` (104),
  `eqButtonWidth` (24) and `eqToMuteGap` (6) are new;
  `syncDrawerRevertButtonWidth` is deleted with the drawer's Revert button.
  The surface frame also widened, `SurfaceLayout.width` 623 → 653, so every
  frame built at the old width needs resizing — the trailing columns are
  anchored from the trailing edge and do not move; the name column absorbs
  the 30 pt.

### Pages

| Page | Node ID |
|---|---|
| Cover | `0:1` |
| Getting Started | `45:3` |
| Foundations · Color | `45:5` |
| Foundations · Type | `45:6` |
| Foundations · Layout | `45:7` |
| Atom · Canvas | `45:9` |
| Atom · Halo | `45:10` |
| Atom · Dot | `45:11` |
| Atom · Meter | `45:12` |
| Atom · Bus Rail | `45:13` |
| Atom · Feed | `45:14` |
| Atom · Fader | `45:15` |
| Atom · Fields | `45:16` |
| Note · Tab views (no kit component) | `45:17` |
| Atom · Shell | `45:18` |
| Component · Device Row | `45:20` |
| Component · Main Row | `45:21` |
| Component · App Row | `45:22` |
| Component · Group Rows | `45:23` |
| Component · Chrome | `45:24` |
| Screen · Popover | `45:26` |
| Screen · Groups | `45:27` |
| Screen · Settings | `45:28` |
| Screen · Onboarding | `45:29` |
| Screen · Menu Bar | `45:30` |
| Reference · Spec backlog | `45:32` |
| Reference · v3.4 hand mock | `45:33` (mock frame `1:2` — kept until Alec's live review confirms the rebuilt screens match, then delete) |

### Components (all OURS custom drawings; source paths under `AudioutCore/Sources/`)

| Component | Node ID | Swift source |
|---|---|---|
| HaloRing | `47:20` | `AudioutSharedUI/HaloRingView.swift` |
| RouteArmedDot | `47:25` | `AudioutSharedUI/RouteArmedDotView.swift` |
| LevelMeter | `48:50` | `AudioutSharedUI/LevelMeterView.swift` |
| BusNode | `49:22` | `AudioutSharedUI/MembershipBusView.swift` |
| RailSegment | `49:29` | `AudioutSharedUI/BusRailOverlayView.swift` |
| RailDetourArc | `49:36` | `AudioutSharedUI/BusRailOverlayView.swift` |
| RailOriginHook | `49:41` | `AudioutSharedUI/BusRailOverlayView.swift` |
| RailTerminusDot | `49:48` | `AudioutSharedUI/BusRailOverlayView.swift` |
| FeedChip | `50:9` | `AudioutSharedUI/FeedChip.swift` |
| FeedPill | `50:28` | `AudioutSharedUI/FeedPillView.swift` |
| WarmFader | `51:89` | `AudioutSharedUI/WarmFaderCell.swift` |
| WarmCanvas | `52:4` | `AudioutSharedUI/WarmCanvasView.swift` |
| GroupedSection | `52:5` | `AudioutWindowUI/GroupedSectionView.swift` |
| RoundedContainer | `52:7` | `AudioutOnboardingUI/OnboardingViewController.swift` (permission card) |
| Hairline | `52:9` | `AudioutPopoverUI/CardView.swift` (card dividers) |
| ~~TabItem / TabGroup~~ | *deleted 2026-08-07* | See **Tab views** below — no component, by decision |
| WarmNameField | `54:15` | `AudioutSharedUI/WarmNameFieldCell.swift` |
| DeviceIconWell | `54:70` | `AudioutWindowUI/DeviceIconWellView.swift` |
| PermissionIconTile | `54:111` | `AudioutOnboardingUI/PermissionRowView.swift` |
| ThemeTile | `55:134` | `AudioutSettingsUI/AppearanceSettingsViewController.swift` |
| ControlPanelShell | `56:11` | `AudioutSharedUI/ControlPanelBackingView.swift` |
| Banner | `56:28` | `AudioutPopoverUI/SilenceFallbackBannerView.swift` (also `SystemAirPlayNoteBannerView.swift`) |
| ConnectionDiagnosis | `56:29` | `AudioutPopoverUI/ConnectionDiagnosisView.swift` |
| DeviceRow | `61:258` | `AudioutSharedUI/DeviceRowView.swift` |
| MainOutRow | `64:264` | `AudioutPopoverUI/MainOutRowView.swift` |
| AppRow | `65:150` | `AudioutSharedUI/AppRowView.swift` |
| GroupRow | `66:771` | `AudioutPopoverUI/GroupRowView.swift` |
| MembershipRow | `66:833` | `AudioutWindowUI/MembershipRowView.swift` |
| SectionHeader | `67:19` | `AudioutPopoverUI/PopoverPanelViewController.swift` |
| SubsectionHeader | `67:20` | `AudioutPopoverUI/PopoverPanelViewController.swift` |
| CardNote | `67:22` | `AudioutPopoverUI/PopoverPanelViewController.swift` |
| HeaderBar | `67:24` | `AudioutPopoverUI/PopoverHeaderView.swift` |
| ApplicationsFooter | `67:38` | `AudioutPopoverUI/PopoverController.swift` |
| RefusalNoteRow | `67:43` | `AudioutSharedUI/DeviceRowView.swift` |
| PlaceholderRow | `67:47` | `AudioutPopoverUI/PopoverController.swift` (empty states) |
| EQResponseCurve | *owed — Atom · Scope* | `AudioutSharedUI/EQResponseCurveView.swift` |

### Assembled screens

| Screen | Node ID | Swift source |
|---|---|---|
| Popover | `68:2` | `AudioutPopoverUI/PopoverPanelViewController.swift` |
| Groups window | `70:2` | `AudioutWindowUI/MixerWindowController.swift` + `GroupEditorViewController.swift` + `SidebarViewController.swift` |
| Settings · General | `71:287` | `AudioutSettingsUI/GeneralSettingsViewController.swift` |
| Settings · Appearance | `71:342` | `AudioutSettingsUI/AppearanceSettingsViewController.swift` |
| Settings · Audio | `71:433` | `AudioutSettingsUI/AudioSettingsViewController.swift` |
| Onboarding | `72:2` | `AudioutOnboardingUI/OnboardingViewController.swift` |
| Menu bar | `73:2` | `AudioutApp/StatusItemController.swift` + `AudioutSharedUI/StatusItemIcon.swift` |
| Menu (right-click) | `73:14` | `AudioutApp/StatusItemController.swift` |
| About | `73:21` | `AudioutSettingsUI/AboutView.swift` |
| Quitting panel | `73:33` | `AudioutApp/AppDelegate.swift` |
| Cover art | `74:1053` | — |

### Text styles (mirror `Tokens.Font`)

`body S:121ac430fdcc6dd33058e0c02ee6ff03a2e1236c` ·
`bodyEmphasized S:ee3e4c5e5692d7a2ff28be1d850a0c9ad1cbbdba` ·
`bodyBold S:8034fc40996c9cc63b799eb38bfd96e72b7b638d` ·
`heading S:d07393550e57b7148cc4380914bb5c3abc861992` ·
`titleLarge S:fef701d48cb2026735ca7f25e41e70b9765b476f` ·
`subtitleLarge S:f979879e996d778a2dcb410bc1611e6e67a50a87` ·
`caption S:37d08694d9862afb93c6ca41610676b6f9a44ba9` ·
`captionMedium S:b2a9d0b8b0894db4eb587e6dad4e82af47a20563` ·
`captionEmphasized S:994995ce46163b66f2458d284bf1e4f0a90b56d1` ·
`menuItem S:bc95f1e439be17551730b8ff6e01124f36b82ccc` ·
`microLabel S:43af1e806b5dc49b03cea864de6847f411c923a9` ·
`sectionHeader S:950ba5fbf2d73e45804b467852ead0c8459429a6`.

**One Case rule (2026-08-23, supersedes the Figma styles above where they
disagree):** no UI text is uppercased or set in a monospaced face. `microLabel`
is now the plain system face, 10 pt semibold, sentence case as authored (was
SF Mono 8.5 pt bold UPPERCASE + kern); the popover's legend/section headers and
menu headers render their title-case strings untransformed. Numeric readouts
keep `monospacedDigit` only. The Figma styles still show the old caps voice —
resync owed under roadmap 034.

### Effect style

`glowRouteArmedDot S:cd4f06d8cac5b52b9122e82a1ec6f77ca0beeb80` — the armed-dot
glow shadow (glow color, radius 3.5, opacity .6) from `RouteArmedDotView.swift`.

### macOS 27 kit component keys used (SYSTEM instances)

| Kit component | Key |
|---|---|
| Slider (component set) | `fe70fb549a4532136b1b36909d3e8b4785025ad5` |
| Segmented Control (chosen) | `d0ff53e2b023d7082ec554492a6eff56dd8cb675` (siblings `756207525239d0698f4c13c5059f6ec297ccdf45`, `9e5d6984206d77cb123ed751afce4cbe6c73940d`) |
| Pop-Up Button | `8fec6001a4e01c26307114001044fba72d6702d0` (**macOS 26 key — reference only**; re-import from the macOS 27 kit when touched) |
| Labels/Primary | `df304ed73df11d374391b2948d82ab8985d448bc` |
| Labels/Secondary | `d03a5d70952c199e33a41228bb0ab1849d100c58` |
| Labels/Tertiary | `61f83bc48f9d952cae5b73330b47a7cb802453c1` |
| Labels/Quaternary | `a83bfc3074ffa334b517adb28239353b0cd02ad5` |
| Window Background | `9df28a13dc9169a9369e098c4ce0ab8070290ba0` |
| Accents/Red | `883b5d7ccd148ee111e83d94fb40c8ccd1234f27` |
| Accents/Orange | `217ec9fc3d0cba151f9fd834caebcf3a2209f515` |
| Accents/Blue | `ff84b0ff8ceb09a62d86ed2e9f119a1aa7c6b8cb` |

Checkbox, Switch, Radio and Button instances also come from the macOS 27 kit;
their keys were not ledgered — find them by name in the kit library
(`importComponentSetByKeyAsync` after a library search), never redraw them.

## The upkeep rubric — when code changes, do this in Figma

This is the process that built the file; repeat it incrementally.

a. **New/changed token** in `Tokens.swift` or `PopoverColumnGrid.swift` →
   add/update the variable in the matching collection, in **all four appearance
   modes** (canvas-ladder tokens without HC variants duplicate the base value
   into the HC modes), set scopes and the iOS code syntax to the exact Swift
   constant, and update the swatch/table on the matching Foundations page.

b. **New custom-drawn view** → new *Atom · X* page; a component set with
   variants named after the code's state enum; **every fill/stroke bound to
   variables** (never raw hex); description = drawing spec + Swift file + line
   refs; then instance it into the row components and screens it appears in.

c. **New/changed stock-AppKit usage** → instance from the macOS 27 kit, tag the
   layer `SYSTEM` in its name, never rebuild or restyle it.
   **If the kit has no equivalent, do NOT invent a component.** A hand-built
   stand-in silently diverges from the real control, which is worse than having
   nothing. Instead: leave a clearly-labelled positional placeholder in the
   screen (position + real names only, no styling), and point at Apple's HIG as
   the source of truth. **Tab views** are the known case — the kit ships none
   (Segmented Control and Utility Panel Tab Bar are different controls), so the
   Settings tab strip is a placeholder and the visual comes from
   <https://developer.apple.com/design/human-interface-guidelines/tab-views> at
   implementation time. TabItem/TabGroup components existed briefly on
   2026-08-07 and were deleted for exactly this reason; see the Figma page
   *Note · Tab views (no kit component)*. Don't rebuild them.

d. **Screen change** → update the assembled screen from components. Code wins
   over spec; spec-only ideas go on the *Reference · Spec backlog* page.
   Every screen has a **LIGHT twin** beside it — a clone pinned to the Light
   modes (`Color · Warm Signal` → Light `41:2`, macOS 27 kit `Colors` → Light
   `1:0`, kit control instances' `Mode` property → Light). Twins are plain
   clones, NOT instances: mirror any screen edit into both, or re-clone and
   re-pin. Variable-bound fills re-theme themselves; only literals (computed
   blends, sidebar/menu chrome approximations) need hand-adjusting.
   **Appearance is a variable MODE, never a variant axis** (decision, Alec
   2026-08-07): do NOT add `Appearance=Light|Dark` variants to any component —
   per-instance light mode = the Appearance panel (apply the Light modes to the
   instance). An appearance variant axis would double every set and duplicate
   all future edits. Demo + how-to live on the *Getting Started* Figma page.

e. **Verify** against the checked-in snapshot PNGs under `dev/notes/*-snapshots/`
   (`popover-snapshots/`, `window-snapshots/`, `settings-snapshots/`,
   `onboarding-snapshots/`, light + dark).

f. **Known Plugin-API traps** (from the build ledger, verbatim — they prevent
   repeated debugging):
   - "paint opacity + variable binding: NEVER paint-level opacity on bound paints — use full-strength bound fill on a child node with node.opacity"
   - "variant children coords are SET-RELATIVE — regrid inside the set frame"
   - "vector resize() stretches path data — author paths in local coords, position via x/y only"
   - "variant names must not contain commas outside Prop=Value pairs"
   - "kit imports: importComponentSetByKeyAsync → defaultVariant may be undefined, fall back to children[0]"

g. **Light mode — every new element must resolve in BOTH appearances.** Light is
   not a coat of paint applied later; it is the second half of every token. Rules:
   - **Scaffolding binds to tokens, never to a hex.** Surfaces, text, dividers,
     borders and washes must bind to the Warm Signal tokens whose Light values
     already alias Circuit (see the mapping table below). Bind and light mode is
     free; hardcode and you have silently shipped a dark-only element.
   - **Instruments never go Circuit, in any mode** — the gold family, `failure`,
     `caution`, rings, meters incl. `meterTrack`, fader hardware, permission hues.
     They carry meaning, so they keep their authored Warm Signal values.
   - **When one token cannot serve both grounds, make it mode-aware** rather than
     forking the component. Example: `feedPillText` resolves `secondaryLabel` in
     dark but `label` in light, because the light pill fill would otherwise drop
     the text to 3.57:1. Two modes, one component.
   - **Literals that cannot be tokenised still need light values.** Runtime-derived
     colours (app tether tints) are modelled as `_example/tether-*` variables
     carrying a dark hue AND its light-adapted counterpart (the code's
     `lightBrightnessDrop`); computed blends carry a documented dark literal.
     A dark-mode hex reused in light is a bug — it measured 2.17:1 before this
     was fixed.
   - **Measure, don't eyeball:** instruments ≥3:1 as graphical objects
     (WCAG 1.4.11), text ≥4.5:1 body, against BOTH canvases. Light backgrounds
     are near-white, so mid-tone colours that read fine on the warm near-black
     will fail — check every one.
   - **Beware the fill/text tug-of-war:** pushing a container's fill away from the
     canvas pushes it toward mid-tone text. Verify both the container-vs-canvas
     and the text-on-container ratios before settling on a value.
   - **Add the element to the LIGHT twin** of every screen it appears on (twins
     are clones — see step d).

## Figma-side placeholders that are NOT code truths

Do not "fix" the code to match any of these; they are Figma stand-ins:

- **JetBrains Mono** stood in for SF Mono on the old `microLabel` style; the
  voice is no longer monospaced at all (One Case rule above), so the stand-in
  goes away on resync.
- **SF Symbols are placeholder vectors**, not the real glyphs the app renders.
- **Canvas grain is not rendered** (dark-mode 48×48 procedural tile exists only
  in `WarmCanvasView.swift`).
- **`separator`, `underPageBackground`, `selectedContentBackground`
  are approximations** of dynamic system colors.
- **Computed blends are stored as dark-appearance literals** (e.g. the armed
  fader gradient's ember-toward-gold blend, diagnosis panel's failure-tinted
  fill) — code computes them at runtime.
- The **System accent dial** (accent-color multipliers) is documented text, not
  a variable mode.
- **Atom · Scope** (the EQ response curve) is owed in Figma; convention: an
  instrument page whose ground is the authored dark value in every mode.

## Light mode = Circuit theme (decision, Alec 2026-08-07)

The **Light and Light HC** mode values of the 18 scaffolding tokens below are
**aliases into the `Theme · Circuit` collection** (`@sumup-oss/design-tokens`,
kept in the Figma file). Dark modes stay pure Warm Signal, and the
**instruments are NEVER Circuit-mapped in any mode** — gold, ember, glow,
`spineTone`, meters incl. `meterTrack`, halo rings, `ringConnected`, armed dot,
`dotSocket`, `failure`, `caution`, `faderThumb`, `faderRim`, permission hues.
Circuit themes only scaffolding: canvas/rows, text, dividers, wells/text boxes,
banners, sidebar. This is a color theme only — no Circuit UI components.

| Warm Signal (Light alias) | Circuit token |
|---|---|
| `canvas`, `canvasHi` (gradient collapses flat), `panel`, `raised`, `underPageBackground`, `windowBackground` | `bg/normal` |
| `well` | shipped `#E2DFD3`, off-sheet (see below) |
| `sidebarWarmTint` | shipped `#F5F4ED`, off-sheet, near `bg/normal` |
| `hairline` | shipped `#D0CDC3` = Circuit `border/normal` (see below) |
| `separator` | `border/divider` |
| `label` / `secondaryLabel` / `tertiaryLabel` | `fg/normal` / `fg/subtle` / `fg/placeholder` |
| `quaternaryLabel` | `bg/highlight` |
| `destructive` / `warning` | `fg/danger` / `fg/warning` |
| `selectedContentBackground` (hover wash @10%) | `fg/normal` |

**Shipped departures from the raw alias, measured** (`well` and `hairline` are
NOT plain Circuit aliases in code — both were re-tuned after the alias
measured under a locked floor):
- `well` mapped to Circuit `bg/highlight` `#E8E6DC` rather than `bg/subtle`
  (`bg/subtle` measured 1.06:1 vs the flat Circuit `panel`, under the
  membership checklist's locked 1.10:1 surface-separation floor); `#E8E6DC`
  itself then measured 1.098:1 against Direction 04's light `raised`
  `#F2F0EA`, under the checklist's locked 1.15:1 raised-vs-well floor, so it
  was re-tuned one step deeper, OFF the Circuit sheet entirely, to the
  shipped `#E2DFD3` (`Tokens.swift:269-292`).
- `hairline` mapped to Circuit `border/normal` `#D0CDC3` rather than
  `border/divider` (`border/divider` measured 1.21:1 vs the flat Circuit
  `panel`, under the checklist's locked 1.25:1 separator floor;
  `border/normal` holds 1.53:1 and is still a Circuit-family hex —
  `Tokens.swift:296-319`).
- `separator` stays mapped straight to `border/divider` as the table states —
  it carries no separate floor of its own.
- `sidebarWarmTint` light is `#F5F4ED`, off-sheet, near `bg/normal` (not a
  Circuit alias at all).

**Contrast, measured 2026-08-07** (instruments vs `bg/normal` #FBFBF9; 3:1 is
the WCAG 1.4.11 bar for graphical objects): gold **3.53** (up from 3.20 on the
old warm-paper canvas — Circuit's lighter ground gave every dark instrument
headroom, nothing regressed), failure 5.39, caution 3.86, faderThumb 4.02,
ringConnected 3.15, faderRim 3.13 — all pass. Below the bar: **ember 2.39**
(pre-existing, ~2.2 on warm paper; it carries "idle rail / not tapped", so it
is the one instrument worth darkening in the light contrast pass), plus
meterTrack 1.77, glow 1.78, dotSocket 1.37 — those three are intentionally
quiet backdrops, not signal-bearers. Circuit's own text tokens all pass body
contrast (fg/normal 16.4, fg/subtle 5.48, fg/placeholder 4.67).

**Two tokens landed since the Figma proposal** (added 2026-08-07 fixing a measured
FEED-pill contrast failure; both shipped with roadmap 035 — `Tokens.swift:1057`
and `:1071`):

- `feedPillFill` — dark `#38322B` / dark-HC `#423B33`, light aliases Circuit
  `border/normal`, light-HC `bg/neutral-strong`. Replaces
  `NSColor.quaternaryLabelColor`.
- `feedPillText` — aliases `secondaryLabel` in dark, `label` in light.

**`FeedPillView` loses its border.** Measured border-vs-fill was **1.14:1 dark
and 1.00:1 light** — the outline was decorative in both modes (a latent
code-side issue Circuit merely exposed: old warm-paper light measured ~1.04:1).
The pill now reads by fill alone — 1.46:1 vs canvas dark (was 1.31), 1.54:1
light (was 1.21) — while keeping the error pill at 3.24:1 and lifting light
neutral text from 4.54 to **10.66:1**. `feedPillBorderWidth` becomes unused.

**The Circuit pull LANDED** (`PRODUCT.md:84` dates it 2026-08-11, superseding
the earlier warm-paper light): code ships light `canvas` `#FBFBF9`
(`Tokens.swift:241`), not the old warm-paper `#F4EFE7`. Figma and code now
describe the same light state — this section documents the mapping that
shipped, not a pending proposal.

`accent` deliberately KEEPS the macOS system accent in light (Alec's call).
Any frame showing light mode must also pin `Theme · Circuit` → Light (`79:0`)
so the alias chain resolves (all light twins already do). Pulling light values
to code now means pulling the resolved Circuit hexes into `Tokens.swift`'s
light/lightHC columns.

**Owed to Figma (wrap-up, design-token audit 2026-08-27).** This pass landed
several token changes in code that Figma does not carry yet. This is the
handoff list — making the Figma edit itself is not this pass's job (root
AGENTS.md's "Figma mirrors the UI code" rule).

Variables to ADD:
- `secondaryLabel` — now mode-aware: light `#5C574C` / light-HC `#453F35`
  (previously a plain alias of the system secondary label).
- `inkTertiary` — dark `#969083` / dark-HC `#AFA79A` / light `#665F4C` /
  light-HC `#4A443A`.
- `railDormant` — dark `#7D7466` / dark-HC `#948C7C` / light `#8A8272` /
  light-HC `#7A7263`.
- Subtle-column `ember` light — `#877750` (was `#AE9668`).
- IC variants for `warningText` (dark `#E09A55` / light `#8F4E1D`),
  `inkSecondary` (dark `#C6C0B4` / light `#453F35`), and `success` (dark
  `#7BD495` / light `#246B3C`).
- Two text styles mirroring `Tokens.Font`: `detail` (11 pt regular) and
  `display` (20 pt bold).

Variables to DELETE:
- `tertiarySystemFill` (dead in code — zero consumers).
- The `Tokens.Material.sidebar` alias (also dead in code — zero consumers;
  no separate Figma note currently names it, so there is nothing else to
  drop alongside it).

## Pull direction (Figma → code)

A design change made in Figma names its own landing spot: read the changed
variable's **iOS code syntax** — that string is the exact Swift constant to edit
(`Tokens.Color.*` in `Tokens.swift`, `PopoverColumnGrid.*` in
`PopoverColumnGrid.swift`). For component changes, the component description
names the Swift file. Everything else in the app uses semantic `NSColor` /
system controls — if a Figma edit has no code-syntax target, it is either a
SYSTEM kit instance (code change = pick a different stock control) or a
spec-backlog idea, not an app edit.
