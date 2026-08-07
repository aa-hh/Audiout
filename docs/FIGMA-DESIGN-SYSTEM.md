# Figma design system — contract, map, upkeep

The Audiouter design system lives in Figma file **`aGvr1qZ3tbqGD2e3jmA1Ru`** (built
2026-08-07). This doc is how a future agent keeps that file true to the code. The
build itself is done — maintenance is incremental, per the rubric below.

## The contract

The Figma file and the code are bound by naming, not by tooling (Code Connect is
blocked — it needs a Dev/Full seat on an Org/Enterprise plan — so the contract is
carried in the file itself):

- **Color variable names mirror `Tokens.Color` case names 1:1**
  (`AudiouterCore/Sources/AudiouterSharedUI/Tokens.swift`; the code's canonical
  string is `NSColor.Name "WarmSignal.<caseName>"`).
- **Layout variable names mirror `PopoverColumnGrid` constant names 1:1**
  (`AudiouterCore/Sources/AudiouterSharedUI/PopoverColumnGrid.swift`), grouped by
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
  halo/ rows/ gaps/ fader/ field/ alphas/ surfaces/ sync/`. The `sync/` group
  (added 2026-08-07, BT-OFFSET-UI) mirrors the SYNC-column MARK:
  `syncStepperButtonWidth 15 · syncValueFieldWidth 32 · syncControlGap 2 ·
  syncAlignButtonWidth 18 · syncAlignGap 4 · btFeedReserveWidth 48 ·
  btFeedToSyncGap 4 · syncClusterWidth 88 · syncTrailing 66 ·
  syncCenterFromTrailing 110` (the last three are the code's derived vars,
  stored as their computed values).

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
| Atom · Shell & Banners | `45:18` |
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

### Components (all OURS custom drawings; source paths under `AudiouterCore/Sources/`)

| Component | Node ID | Swift source |
|---|---|---|
| HaloRing | `47:20` | `AudiouterSharedUI/HaloRingView.swift` |
| RouteArmedDot | `47:25` | `AudiouterSharedUI/RouteArmedDotView.swift` |
| LevelMeter | `48:50` | `AudiouterSharedUI/LevelMeterView.swift` |
| BusNode | `49:22` | `AudiouterSharedUI/MembershipBusView.swift` |
| RailSegment | `49:29` | `AudiouterSharedUI/BusRailOverlayView.swift` |
| RailDetourArc | `49:36` | `AudiouterSharedUI/BusRailOverlayView.swift` |
| RailOriginHook | `49:41` | `AudiouterSharedUI/BusRailOverlayView.swift` |
| RailTerminusDot | `49:48` | `AudiouterSharedUI/BusRailOverlayView.swift` |
| FeedChip | `50:9` | `AudiouterSharedUI/FeedChip.swift` |
| FeedPill | `50:28` | `AudiouterSharedUI/FeedPillView.swift` |
| WarmFader | `51:89` | `AudiouterSharedUI/WarmFaderCell.swift` |
| WarmCanvas | `52:4` | `AudiouterSharedUI/WarmCanvasView.swift` |
| GroupedSection | `52:5` | `AudiouterWindowUI/GroupedSectionView.swift` |
| RoundedContainer | `52:7` | `AudiouterOnboardingUI/OnboardingViewController.swift` (permission card) |
| Hairline | `52:9` | `AudiouterPopoverUI/CardView.swift` (card dividers) |
| ~~TabItem / TabGroup~~ | *deleted 2026-08-07* | See **Tab views** below — no component, by decision |
| WarmNameField | `54:15` | `AudiouterSharedUI/WarmNameFieldCell.swift` |
| DeviceIconWell | `54:70` | `AudiouterWindowUI/DeviceIconWellView.swift` |
| PermissionIconTile | `54:111` | `AudiouterOnboardingUI/PermissionRowView.swift` |
| ThemeTile | `55:134` | `AudiouterSettingsUI/AppearanceSettingsViewController.swift` |
| ControlPanelShell | `56:11` | `AudiouterSharedUI/ControlPanelBackingView.swift` |
| Banner | `56:28` | `AudiouterPopoverUI/SilenceFallbackBannerView.swift` (also `SystemAirPlayNoteBannerView.swift`) |
| ConnectionDiagnosis | `56:29` | `AudiouterPopoverUI/ConnectionDiagnosisView.swift` |
| BTAlignmentPrompt | `120:53` | `AudiouterPopoverUI/BTAlignmentPromptView.swift` |
| BTAlignmentWizard | `123:1923` (set: `Screen=intro` `123:70` · `Screen=question` `123:80` · `Screen=receipt` `123:1895` · `Screen=gracefulExit` `123:1912`) | `AudiouterPopoverUI/BTAlignmentWizardView.swift` (screens = `AudiouterCore/BTAlignmentWizardSession.swift`'s `Screen`) |
| DeviceRow | `61:258` (+6 BT variants 2026-08-07: `BT connected + sync` `103:297` · `BT connected idle (non-member)` `107:192` · `BT disconnected (greyed — click connects)` `104:146` · `BT connecting (unavailable — reconnect in flight)` `104:196` · `BT failed · Not paired` `105:168` · `BT failed · Connected elsewhere` `105:220`) | `AudiouterSharedUI/DeviceRowView.swift` |
| MainOutRow | `64:264` | `AudiouterPopoverUI/MainOutRowView.swift` |
| AppRow | `65:150` | `AudiouterSharedUI/AppRowView.swift` |
| GroupRow | `66:771` | `AudiouterPopoverUI/GroupRowView.swift` |
| MembershipRow | `66:833` | `AudiouterWindowUI/MembershipRowView.swift` |
| SectionHeader | `67:19` | `AudiouterPopoverUI/PopoverPanelViewController.swift` |
| SubsectionHeader | `101:79` (now a set: `columnTitle=None` `67:20` · `columnTitle=Sync` `101:76`) | `AudiouterPopoverUI/PopoverPanelViewController.swift` |
| CardNote | `67:22` | `AudiouterPopoverUI/PopoverPanelViewController.swift` |
| HeaderBar | `67:24` | `AudiouterPopoverUI/PopoverHeaderView.swift` |
| ApplicationsFooter | `67:38` | `AudiouterPopoverUI/PopoverController.swift` |
| RefusalNoteRow | `67:43` | `AudiouterSharedUI/DeviceRowView.swift` |
| PlaceholderRow | `67:47` | `AudiouterPopoverUI/PopoverController.swift` (empty states) |

### Assembled screens

| Screen | Node ID | Swift source |
|---|---|---|
| Popover | `68:2` (887 tall since the Bluetooth Devices subsection, 2026-08-07; LIGHT twin `111:981`; OUTPUT DEVICES "+" menu `109:981` / LIGHT `111:2222`; BT first-mix intercept state `125:1160` / LIGHT `125:2099`) | `AudiouterPopoverUI/PopoverPanelViewController.swift` |
| Groups window | `70:2` | `AudiouterWindowUI/MixerWindowController.swift` + `GroupEditorViewController.swift` + `SidebarViewController.swift` |
| Settings · General | `71:287` | `AudiouterSettingsUI/GeneralSettingsViewController.swift` |
| Settings · Appearance | `71:342` | `AudiouterSettingsUI/AppearanceSettingsViewController.swift` |
| Settings · Audio | `71:433` | `AudiouterSettingsUI/AudioSettingsViewController.swift` |
| Onboarding | `72:2` | `AudiouterOnboardingUI/OnboardingViewController.swift` |
| Menu bar | `73:2` | `AudiouterApp/StatusItemController.swift` + `AudiouterSharedUI/StatusItemIcon.swift` |
| Menu (right-click) | `73:14` | `AudiouterApp/StatusItemController.swift` |
| About | `73:21` | `AudiouterSettingsUI/AboutView.swift` |
| Quitting panel | `73:33` | `AudiouterApp/AppDelegate.swift` |
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
`sectionHeader S:950ba5fbf2d73e45804b467852ead0c8459429a6` (the one non-token
literal: 14 pt medium uppercase, `PopoverPanelViewController.swift:398`).

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
| Text Field (component set) | `5addd9d6fd1bbe1b5cacd6969ae86726f6b23946` (the BT rows' SYNC value field — `NSTextField .roundedBezel` small) |
| Button (component set) | `069f568d24a3ed47c701e5afd8b2bcc8a1cac6a0` — the titled push button. **Only `Size=XL` carries a title** (36 pt tall, hugs its label, label is the `Symbol#4389:1094` TEXT property); `Size=Medium` is a 24×24 icon-only button. There is no small/regular titled push button in the kit, so an XL instance stands in for `NSButton .rounded .small`/`.regular` and the drawn height is the kit's, not the code's. Flip its `Mode` variant to `Light` in light twins. |

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

- **JetBrains Mono** stands in for SF Mono (`microLabel`; SF Mono is unavailable
  in Figma — noted on the style).
- **SF Symbols are placeholder vectors**, not the real glyphs the app renders.
- **Canvas grain is not rendered** (dark-mode 48×48 procedural tile exists only
  in `WarmCanvasView.swift`).
- **`separator`, `underPageBackground`, `selectedContentBackground`,
  `tertiarySystemFill` are approximations** of dynamic system colors.
- **Computed blends are stored as dark-appearance literals** (e.g. the armed
  fader gradient's ember-toward-gold blend, diagnosis panel's failure-tinted
  fill) — code computes them at runtime.
- The **System accent dial** (accent-color multipliers) is documented text, not
  a variable mode.

## Light mode = Circuit theme (decision, Alec 2026-08-07)

The **Light and Light HC** mode values of the 18 scaffolding tokens below are
**aliases into the `Theme · Circuit` collection** (`@sumup-oss/design-tokens`,
kept in the Figma file). Dark modes stay pure Warm Signal, and the
**instruments are NEVER Circuit-mapped in any mode** — gold, ember, glow,
`spineTone`, meters incl. `meterTrack`, halo rings, `ringConnected`, armed dot,
`dotSocket`, `failure`, `caution`, `faderThumb`, `faderRim`, permission hues.
Circuit themes only scaffolding: canvas/rows, text, dividers, wells/text boxes,
banners, sidebar. This is a color theme only — no Circuit UI components.

> **CORRECTED 2026-08-08 (roadmap 036 closed as Figma-only):** the surface-ladder
> rows below are STALE for `canvas canvasHi panel raised well hairline` — their
> Light/Light-HC aliasing into Circuit collapsed the ladder to one hex
> (`bg/normal` #FBFBF9), which the code never does. Those six now carry
> `Tokens.swift`'s real resolved values as DIRECT hexes (see the 2026-08-08
> surface-fix ledger entry). The remaining rows (text, dividers via `separator`,
> washes, danger/warning) still alias Circuit as tabled.

| Warm Signal (Light alias) | Circuit token |
|---|---|
| ~~`canvas`, `canvasHi`, `panel`, `raised`~~ (superseded — direct hexes now), `underPageBackground`, `windowBackground` | `bg/normal` |
| ~~`well`~~ (superseded), `sidebarWarmTint` | `bg/subtle` |
| ~~`hairline`~~ (superseded), `separator` | `border/divider` |
| `label` / `secondaryLabel` / `tertiaryLabel` | `fg/normal` / `fg/subtle` / `fg/placeholder` |
| `quaternaryLabel`, `tertiarySystemFill` | `bg/highlight` |
| `destructive` / `warning` | `fg/danger` / `fg/warning` |
| `selectedContentBackground` (hover wash @10%) | `fg/normal` |

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

**Two NEW tokens the code does not have yet** (added 2026-08-07 fixing a measured
FEED-pill contrast failure; both carry iOS code syntax and land with roadmap 033):

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

**Figma light is AHEAD of code.** `Tokens.swift`'s light/lightHC columns still
hold the original warm-paper values (canvas #F4EFE7 …), so the shipping app is
unchanged — Figma holds the proposal until those Circuit hexes are pulled
across. The warm-paper light values remain recoverable from the code.

`accent` deliberately KEEPS the macOS system accent in light (Alec's call).
Any frame showing light mode must also pin `Theme · Circuit` → Light (`79:0`)
so the alias chain resolves (all light twins already do). Pulling light values
to code now means pulling the resolved Circuit hexes into `Tokens.swift`'s
light/lightHC columns.

## Upkeep pass 2026-08-07 — Bluetooth UI (BT-UI / BT-OFFSET-UI)

Mirrored the shipped Bluetooth work (worktree `foreman-roadmap-004-bt` @
`ff645565` + the locked UI spec in `PLAN-UNIVERSAL-SYNC.md`):

- **`sync/` Layout variables** (10, listed in the collection bullet above), all
  with iOS code syntax; the Foundations · Layout page gained a BT
  trailing-slot diagram (`101:63`) and the summary text now carries the sync
  numbers.
- **DeviceRow BT variants** (node IDs in the components table): hifispeaker.2.fill
  placeholder glyph; SYNC cluster = − / bare-ms value / + (frames named
  `SYSTEM: NSButton accessoryBar`, same stand-in convention as the mute
  button) + align-by-ear `metronome.fill` placeholder; the value field is a
  real macOS 27 kit **Text Field** instance (key above), `State=Disabled` on
  read-only rows. The BT FEED pill **right-aligns inside the row** (frame
  `FEED pills (BT — right-aligned into btFeedReserveWidth, clips overlong)`),
  deliberately NOT a FeedPill variant — the code puts the right-alignment in
  `DeviceRowView`'s constraints, `FeedPillView` is unchanged. Overlong pills
  ("Unavailable", "Not paired", "Connected elsewhere") honestly clip at the
  48 pt reserve, as the code's mask does.
- **SubsectionHeader** is now a set (`columnTitle=None|Sync`); the SYNC title
  reuses the card header's column-label voice, centered
  `syncCenterFromTrailing` from trailing.
- **Screen · Popover** gained the "Bluetooth Devices" subsection (4
  recency-sorted demo rows: playing+sync, connected idle, greyed
  disconnected, failed "Not paired"), a gold rail extension to the BT playing
  row (`107:1523` — the new lowest selected node), and the OUTPUT DEVICES "+"
  **NSMenu frame** (`109:981`, precedent: the Secondary-click menu `73:14`)
  with "Save Selected Devices as group" + "Pair a Bluetooth speaker…". Light
  twins re-cloned + re-pinned per the rubric (`111:981`, menu `111:2222`).
- **Verification**: no BT snapshots exist under `dev/notes/*-snapshots/` yet —
  structure was verified against the code + the locked spec instead
  (geometry from `PopoverColumnGrid`, states from `DeviceRowView.updateBus`/
  `updateFeedText`, headlines from `ConnectionState.swift`).
- **Repair found in passing**: the dark Popover's `WarmCanvas` instance
  (`68:3`) carried a stray explicit `Color · Warm Signal → Light` mode AND a
  fill bound directly to Circuit `bg/subtle` — the dark screen rendered on the
  light canvas (Circuit's default mode is Light). Rebound the fill to the
  Warm Signal `canvas` variable and cleared the stray pin; dark now resolves
  the authored warm near-black, the light twin still resolves Circuit
  `bg/normal` through its pins, per the mapping table.
- No new color literals: the cluster's glyphs bind `secondaryLabel`, the
  active align tint is the `accent` alias, failure pills reuse `failure` —
  all pre-measured tokens; the kit Text Field re-themes through the kit
  collection's mode. The one hand-adjusted literal is the "+" menu twin's
  chrome fill, copied from the Secondary-click menu · LIGHT precedent.

## Upkeep pass 2026-08-08 — alignment wizard (W3/W4)

Mirrored the first-mix intercept card and the alignment wizard (worktree
`foreman-roadmap-004-bt` @ `f77cc397`; UX spec = `PLAN-UNIVERSAL-SYNC.md`
"ALIGNMENT WIZARD UX LOCKED 2026-08-08"). Extends the 2026-08-07 BT pass, does
not duplicate it.

- **No new variables.** `BTAlignmentPromptView`/`BTAlignmentWizardView` add no
  `PopoverColumnGrid` constants and no `Tokens.Color` cases — their insets are
  private per-view statics (10 / 4 / 10 / r7 / 8 / 6), exactly like
  `ConnectionDiagnosisView`'s, and the contract only mirrors `PopoverColumnGrid`
  1:1. The only shared geometry they consume is `firstElementLeading(indented:)`
  = 38.5, already a variable. Foundations · Layout therefore unchanged.
- **`BTAlignmentPrompt` `120:53`** and **`BTAlignmentWizard` `123:1923`** live on
  *Atom · Shell & Banners* (`45:18`), beside `ConnectionDiagnosis` — the view
  both of them copy. No new Component page: these are anchored panels, not row
  parts. Wizard variants are named after the code's own enum
  (`Screen=intro|question|receipt|gracefulExit`).
- **Both bind `panel`, not a literal.** This is the one place they differ from
  the diagnosis panel: the card is an OFFER, not an error, so
  `BTAlignmentPromptView.applyBackgroundTint` uses plain `Tokens.Color.panel`
  with no failure blend (house rule 8) — a real variable binding where the
  diagnosis panel needs a computed dark literal.
- **Buttons are real macOS 27 kit `Button` instances** (key ledgered above),
  tagged `SYSTEM: NSButton .rounded …` and never restyled. The kit ships only
  one titled size (XL, 36 pt), so the drawn height is the kit's and the layer
  name records the code's real `controlSize`. This supersedes the older
  hand-drawn `(SYSTEM — swap: macOS 27 Push Button small)` stand-ins inside
  `ConnectionDiagnosis` — swap those next time that component is touched.
- **One stand-in remains**, per rubric c: the wizard's narrowing indicator
  (`NSProgressIndicator .bar .small` determinate). No screen in the file
  instances one, so no kit key was harvestable and library search returns
  nothing on this plan. It is a clearly-labelled positional placeholder (track
  `quaternaryLabel`, fill `accent`, 180×4 at 60 %) naming the real control —
  re-instance it from the kit when the key turns up.
- **Screen** — *Screens · Popover* gained **`125:1160`**, a focused state frame
  (SYNC subsection header + the four BT rows + the card anchored under
  "Bathroom Flip 6" at leading 38.5 / vertical inset 4). Deliberately a sibling
  frame rather than a second full clone of `68:2`: the page's own convention for
  a secondary popover state is the standalone frame (`109:981`, the "+" menu),
  and nothing outside the BT block changes. LIGHT twin `125:2099`, pinned to the
  three light modes and with the nested kit buttons' `Mode` flipped, per rubric d.
- **Verification**: no snapshots exist for these views under
  `dev/notes/*-snapshots/`, so structure was checked against code + the locked
  spec instead — copy strings against the `static let`s in both views, screens
  against `BTAlignmentWizardSession.Screen`, geometry against each view's
  layout constants, mount/teardown against `PopoverController`
  `reconcileBTAlignmentPanels` / `startBTAlignmentWizard`.
- **Light-mode finding — RESOLVED same day, it was a MIRROR bug**: the 1.00:1
  panel-vs-canvas collapse measured during this pass was caused by the file's
  own Light aliasing (surface ladder → Circuit `bg/normal`), not by the code.
  Fixed in the follow-up entry below; the three remediation options logged on
  *Reference · Spec backlog* are marked MOOT there. Text/glyph contrast
  measurements stand (body/education 5.48–16.4:1, dismiss ✕ 4.67:1).

## Upkeep pass 2026-08-08 — light surface-ladder fix (roadmap 036, Figma-only)

Verified against `Tokens.swift`: the app's light surfaces never collapse — the
code branches high-contrast on `accessibilityDisplayShouldIncreaseContrast`,
not the appearance, and backgrounds deliberately carry no IC variant. The
mirror's Light/Light-HC aliasing of the six surface variables into Circuit was
wrong. Their Light (`41:2`) and Light HC (`41:3`) modes now hold the code's
real resolved values as **direct hexes** (before: aliases into Circuit):

| Variable | Was (Light & Light HC) | Now Light | Now Light HC |
|---|---|---|---|
| `canvas` | alias `bg/normal` #FBFBF9 | `#F4EFE7` | `#F4EFE7` |
| `canvasHi` | alias `bg/normal` | `#F7F3EC` | `#F7F3EC` |
| `panel` | alias `bg/normal` | `#FBF8F2` | `#FBF8F2` |
| `raised` | alias `bg/normal` | `#FFFFFF` | `#FFFFFF` |
| `well` | alias `bg/subtle` #F5F4ED | `#ECE5D8` | `#ECE5D8` |
| `hairline` | alias `border/divider` | `#E2DACC` | `#9B8768` (the one IC variant) |

Dark modes untouched (already correct). The doc's "Figma light is AHEAD of
code" claim no longer applies to these six — file and `Tokens.swift` now agree.
Both Popover light twins re-verified rendering the ladder distinctly
(`111:981` full screen, `125:2099` intercept state — the anchored cards read as
inset panels again). Spec-backlog remediation options marked MOOT on `74:1052`
("code was never wrong — mirror aliasing fixed, 2026-08-08").

## Pull direction (Figma → code)

A design change made in Figma names its own landing spot: read the changed
variable's **iOS code syntax** — that string is the exact Swift constant to edit
(`Tokens.Color.*` in `Tokens.swift`, `PopoverColumnGrid.*` in
`PopoverColumnGrid.swift`). For component changes, the component description
names the Swift file. Everything else in the app uses semantic `NSColor` /
system controls — if a Figma edit has no code-syntax target, it is either a
SYSTEM kit instance (code change = pick a different stock control) or a
spec-backlog idea, not an app edit.
