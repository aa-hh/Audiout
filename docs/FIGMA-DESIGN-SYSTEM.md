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
  halo/ rows/ gaps/ fader/ field/ alphas/ surfaces/`.

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
| Atom · Tabs | `45:17` |
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
| TabItem | `53:18` | `AudiouterSettingsUI/SettingsWindowController.swift` (code uses stock `NSTabViewController` `.toolbar`; Figma tabs follow Alec's custom spec) |
| TabGroup | `53:49` | `AudiouterSettingsUI/SettingsWindowController.swift` |
| WarmNameField | `54:15` | `AudiouterSharedUI/WarmNameFieldCell.swift` |
| DeviceIconWell | `54:70` | `AudiouterWindowUI/DeviceIconWellView.swift` |
| PermissionIconTile | `54:111` | `AudiouterOnboardingUI/PermissionRowView.swift` |
| ThemeTile | `55:134` | `AudiouterSettingsUI/AppearanceSettingsViewController.swift` |
| ControlPanelShell | `56:11` | `AudiouterSharedUI/ControlPanelBackingView.swift` |
| Banner | `56:28` | `AudiouterPopoverUI/SilenceFallbackBannerView.swift` (also `SystemAirPlayNoteBannerView.swift`) |
| ConnectionDiagnosis | `56:29` | `AudiouterPopoverUI/ConnectionDiagnosisView.swift` |
| DeviceRow | `61:258` | `AudiouterSharedUI/DeviceRowView.swift` |
| MainOutRow | `64:264` | `AudiouterPopoverUI/MainOutRowView.swift` |
| AppRow | `65:150` | `AudiouterSharedUI/AppRowView.swift` |
| GroupRow | `66:771` | `AudiouterPopoverUI/GroupRowView.swift` |
| MembershipRow | `66:833` | `AudiouterWindowUI/MembershipRowView.swift` |
| SectionHeader | `67:19` | `AudiouterPopoverUI/PopoverPanelViewController.swift` |
| SubsectionHeader | `67:20` | `AudiouterPopoverUI/PopoverPanelViewController.swift` |
| CardNote | `67:22` | `AudiouterPopoverUI/PopoverPanelViewController.swift` |
| HeaderBar | `67:24` | `AudiouterPopoverUI/PopoverHeaderView.swift` |
| ApplicationsFooter | `67:38` | `AudiouterPopoverUI/PopoverController.swift` |
| RefusalNoteRow | `67:43` | `AudiouterSharedUI/DeviceRowView.swift` |
| PlaceholderRow | `67:47` | `AudiouterPopoverUI/PopoverController.swift` (empty states) |

### Assembled screens

| Screen | Node ID | Swift source |
|---|---|---|
| Popover | `68:2` | `AudiouterPopoverUI/PopoverPanelViewController.swift` |
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

## Pull direction (Figma → code)

A design change made in Figma names its own landing spot: read the changed
variable's **iOS code syntax** — that string is the exact Swift constant to edit
(`Tokens.Color.*` in `Tokens.swift`, `PopoverColumnGrid.*` in
`PopoverColumnGrid.swift`). For component changes, the component description
names the Swift file. Everything else in the app uses semantic `NSColor` /
system controls — if a Figma edit has no code-syntax target, it is either a
SYSTEM kit instance (code change = pick a different stock control) or a
spec-backlog idea, not an app edit.
