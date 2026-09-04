# PR 1 work order: shared tokens + wordmark font

Executor: Opus. Branch `claude/macos-design-md-migration-059ffa`, worktree
`/Users/alechenderson/Projects/AirPlay Controller/.claude/worktrees/delay-trim-sync-wizard-b99148`.
Every path below is relative to that worktree unless absolute. Every ratio below was computed
with the WCAG 2.x relative-luminance formula (the same one `MembershipWellContrastTests` carries)
by `scratchpad/contrast.py` during scoping; the executor may cite them without recomputing.

## Goal

Re-value `Tokens.Color` to the iPhone companion's cool ladders (dark and light), add the iOS
instrument/ink tokens the surface PRs will consume, retire or rename the Mac-only tokens through
deprecated aliases so every surface still compiles, delete the Follow-system accent position, and
bundle ClashDisplay-Semibold as `Tokens.Font.wordmark(size:)`. No surface changes its code;
PRs 3–8 do that on top of this foundation.

## Scope fences — PR 1 must NOT touch

- No file under `AudioutCore/Sources/AudioutPopoverUI`, `AudioutWindowUI`, `AudioutOnboardingUI`,
  `AudioutSettingsUI`, `AudioutApp` except: the four edits in
  `AudioutSettingsUI/AppearanceSettingsViewController.swift` named in Step 3 (accentOrder, the two
  switch arms, the theme-tile literals + their comments) and the one-line/comment edits named in
  Steps 4–7 (`OnboardingChrome.swift`, `AlignmentWizardViewController.swift`,
  `BTSyncDrawerView.swift`, `AppTetherColor.swift`). No consumer is re-pointed from an old token name to a new one; the
  deprecated aliases carry them. Do not sweep call sites even though the compiler will warn.
- `WarmCanvasView.swift`, `SidebarWarmSurfaceView.swift`, `LevelMeterView.swift`,
  `WarmFaderCell.swift` (drawing code), `HaloRingView.swift`, `FeedPillView.swift`,
  `DeviceRowView.swift`, `AppRowView.swift`, `DeviceIconWellView.swift`: untouched
  (`WarmFaderCell.swift` gets two comment edits only, Step 5).
- No new consumer of `Tokens.Font.wordmark`, `liveRow`, `liveRaised`, `labelCool`, `labelCool2`,
  `goldText`, `emberText`, `rim`, `ring`, `socket`, `meter`, `inkOnFill`, or `Tokens.Layout.Radius`.
- `label` stays `NSColor.labelColor` (see Decisions). `engagedChrome`, `separator`,
  `windowBackground`, `underPageBackground`, `selectedContentBackground`, `shadow`, `clear`,
  `railDormant`, `scopeGround`/`scopeFlatLine`/`scopeBypassLine`, `iconWellBadge`/`iconWellBadgeBorder`,
  the five `permission*` tokens, `bluetoothBrand`, `stagePlate`/`stageRule`/`stageInk`/`syncSignalDeep`/
  `fuseWhite`, `glow`: hexes unchanged (comments re-measured where they quote a retired ground).
- `PopoverColumnGrid.swift`: two comment lines only (Step 6). No geometry, no radius re-pointing.
- No edits to `AGENTS.md` files, `PRODUCT.md`, `docs/FIGMA-DESIGN-SYSTEM.md`, `ROADMAP.jsonl`
  (PR 2 owns docs). No `.impeccable`, no DESIGN.md.
- Do not regenerate any snapshot PNG or golden. Do not run `make-app.sh`; no live-test slot is needed.
- No cleanup, no abstractions, no error handling for impossible cases, no backwards-compat shims
  beyond the deprecated aliases this document specifies. Do not remove the dark-mode grain in
  `WarmCanvasView`. Do not delete `Tokens.Color.warning`/`info`/`accent`/`destructive` outright —
  they become aliases (Step 1F).
- Tests outside the list in "Test plan" are not edited, even where they name a deprecated token
  (they compile through the alias; surface PRs rename them).
- Do not edit any other file in `dev/notes/design-migration-scoping/` — tokens.md's stale "certain
  break" list is corrected by this work order's Verified facts, not by editing it.

## Decisions recorded (the executor does not re-open these)

- D1 `label` stays `.labelColor`. 42 source sites and `GroupsWindowTextColorLockTests` treat it as a
  stock semantic; the iOS authored `#F5EFE4/#201D1A` lands when the rows PR (PR 3) and the Groups
  PR (C5) move ink temperature. `engagedChrome` therefore also stays.
- D2 `failure` keeps its Mac name (iOS: `fail`). 15 source + 14 test references; renaming adds an
  alias and a doc line for zero behavioural gain. Its light hex is re-valued to iOS `#B03327`.
- D3 Light `gold` adopts iOS `#A67C1E`. Light `ember` KEEPS Mac `#7A5E2A`: iOS `#7C5F24` measures a
  saturation gap of 0.110 against the new gold, under `MembershipWellContrastTests`' 0.15 floor;
  `#7A5E2A` gives 0.164, hue difference 0.0069 (floor 0.03), luminance gap 1.595 (band 1.40–1.60).
- D4 `inkOnFill` is `#171104` in dark, dark-IC, and light; its light Increase-Contrast variant is
  `#FFFFFF`. Reason: light-IC `gold` `#8A6614` gives `#171104` only 3.57:1 and pure black 3.99:1 —
  no dark ink clears 4.5 on it — while white gives 5.26:1 (6.32:1 on Subtle light-IC `#6F5E33`).
  iOS has no Increase Contrast column, so its "one value in both appearances" has nothing to say
  here. This is the same flip `ProminentButton.measuredKeyInk` already performs live.
- D5 `partyRampDeep` keeps the Mac's four values (dark `#FF90E9`, light `#752C68`, light-IC
  `#5E2354`): the wizard's dark rim uses the electric value at full strength by owner ruling
  2026-08-23 (Tokens.swift:1259-1262). Only the name changes.
- D6 Subtle-dial columns for `goldText`/`emberText` follow the gold/ember pattern; where the base
  subtle hex already clears the text floor it is reused (see table). `goldText`'s and `emberText`'s
  Subtle light-IC hexes coincide at `#584C2E` by derivation; recorded, accepted.
- D7 Increase-Contrast method (matches Tokens.swift precedent "IC pushes further from the ground"):
  blend the base hex toward white (dark appearance) or black (light appearance) in sRGB until the
  ratio on the token's TIGHTEST guaranteed ground reaches max(target, 1.25 × base ratio), then
  round to a hex and re-measure. Targets: text 7.0:1, graphics/controls 4.5:1, `hairline` 3.0:1 on
  `panel`, `containerEdge` = hairline-IC ratio × 1.158 (the existing light rank). Grounds carry no
  IC variant (existing precedent, Tokens.swift:289-292); `liveRow`/`liveRaised`/`socket`/`meter`
  IC values are hand-picked and measured.
- D8 The three iOS radii land as a nested enum `Tokens.Layout.Radius { control = 10, row = 16,
  panel = 26 }` (mirrors iOS `WarmSignal.Radius`, WarmSignal.swift). The existing
  `Tokens.Layout.panelCornerRadius` (12) is a different thing (the shell bubble) and stays.
- D9 `AppSettings.accentStyle` needs NO getter change: `AccentStyle(rawValue: "systemAccent")`
  returns nil once the case is gone and the existing `?? .fullGold` (AppSettings.swift:131) is the
  fallback. A test pins it (Test plan → SettingsAccentAndHintsTests).
- D10 Deprecation warnings are accepted in this PR. Baseline `bash scripts/build.sh` already prints
  258 `warning:` lines; nothing treats warnings as errors (`scripts/build.sh` has no such flag —
  verified by grep). Expect roughly 350 more after Step 1.

## Pre-flight (all from the worktree root)

No livetest slot, no dev build. Baseline observed during scoping (2026-09-03, HEAD 50bb0048):

```bash
bash scripts/build.sh
#   build: compiled clean on remote … — exit 0 (34 s)
AUDIOUT_TEST_NO_CACHE=1 bash scripts/run-tests.sh --filter 'MembershipWellContrastTests|TokenContrastMatrixTests|AlignmentTokenContrastTests|PreviewPaletteTokenPinTests|SettingsAccentAndHintsTests|OnboardingPermissionColorTests|RailConnectPulseTests|GroupsWindowTextColorLockTests|NoteBannerColorTests|RingRailToneLockTests|EQResponseCurveTests|AppTetherColorTests|AccessibilitySignalSweepTests|NoTintOnRingsOrMetersGuardTests|RouteArmedSignalTests|BrandMarkTests'
#   Test run with 205 tests in 17 suites passed
bash scripts/run-tests.sh
#   suite: sources unchanged since a passing run — skipping (cache hit on HEAD)
```

Never a bare `swift build`/`swift test`. `run-tests.sh` forwards extra args to `swift test`, so
`--filter` takes a regex alternation as above.

## Verified facts (file:line, checked 2026-09-03)

- `Tokens.Color` is `public enum Color` of `static var`/`static let` members (Tokens.swift:90);
  `secondaryLabel` (:116) and `inkTertiary` (:537) are `static let` because tests compare by
  instance identity (:100-104). `railDormant` (:556) is `static let` too.
- `warmDynamic(name:dark:darkHighContrast:light:lightHighContrast:)` (Tokens.swift:1521-1535);
  `WarmVariants` (:1556-1566); `accentDynamic(name:full:subtle:systemAccentScale:)` (:1578-1595)
  with the `.systemAccent` branch at :1591-1592; `systemAccentColor(in:scale:)` (:1602-1613);
  `permissionDynamic` `case .fullGold, .systemAccent:` (:1650).
- `AccentStyle` cases at AppSettings.swift:25-29; getter fallback :131.
- Only these source files reference `.systemAccent` outside Tokens.swift:
  AppearanceSettingsViewController.swift:48, :554, :564; OnboardingChrome.swift:187, :191;
  WarmFaderCell.swift:42, :118 (comments); AppSettings.swift:20, :28.
- Tests referencing `.systemAccent`: OnboardingPermissionColorTests.swift:184-212 (the deleted
  test), plus two COMMENT lines in the same file that survive the deletion — :17 (file doc: "while
  `.systemAccent` leaves them at their authored Full-gold hues") and :219 (doc comment of the KEPT
  test `goldOnRaisedClearsTheGlyphFloorInBothDialColumnsAndAppearances`: "`.systemAccent` is
  excluded on the token's own terms…"); SettingsAccentAndHintsTests.swift:65-66, :87, :116-117;
  RingRailToneLockTests.swift:180; TokenContrastMatrixTests.swift:29 (comment). The final
  `grep systemAccent` check needs every one of these gone.
- `RailConnectPulseTests` references only `Tokens.accentStyleDidChangeNotification` (:277, :368,
  :451) — it does NOT break. `EQResponseCurveTests` measures `secondaryLabel` on `scopeGround`
  (:208-209): the new dark `label2` measures 8.38:1 there — it does NOT break. `AppTetherColorTests`
  never reads `Tokens.Color.canvas`: `measuredContrast_clearsWCAGFloor` hardcodes the OLD grounds
  as literals (`0x16130F` dark, `0xFBFBF9` light, AppTetherColorTests.swift:316-317) and measures
  against those (:343, :349) — so it does NOT break, and its light literal is simply stale after
  this PR (C4/PR 3 deletes the type and the suite). Corrections to tokens.md's "certain break" list.
- Theme tiles: `WarmPreviewPalette.dark` literals AppearanceSettingsViewController.swift:329-334,
  `.light` :342-347; the Circuit comment :336-338. `PreviewPaletteTokenPinTests` pins
  canvas/well/gold/ember only (:60-82).
- `WarmCanvasView.draw` builds its gradient from `Tokens.Color.canvasHi.cgColor` and
  `Tokens.Color.canvas.cgColor` (WarmCanvasView.swift:85-86); aliasing `canvasHi` to `canvas`
  therefore flattens the gradient with no code change. The dark grain stays (:108-110).
- `AccessibilitySignalSweepTests.flattenedCanvasIsTheFlatOpaqueBaseColor` (:233-272) asserts the
  dark un-flattened top/bottom delta > 0.5/255 (:271). It will NOT fail after the alias: the dark
  grain (WarmCanvasView.swift:109-110, per-pixel white at alpha 0…12/255) keeps that delta above
  the threshold, so the assertion passes vacuously while no longer measuring a gradient. The
  rewrite in the Test plan replaces a meaningless check, not a failing one.
- Figma-mirror comments: PopoverColumnGrid.swift:682 and :759, BTSyncDrawerView.swift:89.
  Tokens.swift:200-216 is the block citing `docs/FIGMA-DESIGN-SYSTEM.md` (:203, :215) and the Figma
  proposal (:206). The word "Circuit" appears in Swift at: Tokens.swift (:150, :203, :205, :208,
  :213, :239, :246-247, :252, :278-280, :283, :328-335, :374, :419-421, :430, :730, :821, :1159,
  :1173, :1179), AppearanceSettingsViewController.swift:336-337, AlignmentWizardViewController.swift:249,
  AppTetherColor.swift:475-480, AccessibilitySignalSweepTests.swift:237. `PTPHelperActivationTests`
  `enabledDoesNotShortCircuit` is a different word; leave it.
- iOS font: `AudioutRemote/Info.plist:18-20` lists `ClashDisplay-Semibold.otf` under `UIAppFonts`;
  call sites use `.custom("ClashDisplay-Semibold", size:)` (AboutView.swift:45,
  ConnectGateView.swift:725). The `.otf`'s PostScript name (name-table id 6) is
  `ClashDisplay-Semibold`; full name `Clash Display Semibold`; sha256
  `e70dce86ab1ba52063e2f85a536c21d70c3a9dee271f1fa453e58147be3c2f60`, 27 116 bytes — byte-identical
  to the Semibold in Fontshare's current download zip.
- `CTFontManagerRegisterFontsForURL(_:_:_:)` exists in the SDK (CTFontManager.h:171) and the
  shape `CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)` type-checks together with
  the deprecated-alias shape below (probe compiled with `swiftc -typecheck`, scoping session).
- `LicenseGateViewController.swift:121-122` sets "Welcome to Audiout" in `Tokens.Font.displayLarge`
  — the wordmark's first consumer, in a later PR.
- Guard 4 (`.githooks/pre-commit:165-223`) runs `scripts/run-tests.sh` on any commit touching
  AudioutCore Swift; there is no `AUDIOUT_FULL_SUITE` variable. The runner's cache
  (`AUDIOUT_TEST_NO_CACHE=1` to bypass) makes the hook a no-op when the same sources already passed.
  Guard 7 requires `bash scripts/self-review.sh` before a Swift commit.
- Repo `aa-hh/Audiout` is private (`gh repo view --json isPrivate` → true).

## Step-by-step

Build is red between Step 1 and the end of Step 4 (the accent case deletion spans five files —
Tokens.swift, AppSettings.swift, AppearanceSettingsViewController.swift, OnboardingChrome.swift:191
— and the tests); run `bash scripts/build.sh` after Step 4, then after every later step.

### Step 1 — `AudioutCore/Sources/AudioutSharedUI/Tokens.swift`

1A. Ladder re-value. Replace the hexes in `canvas` (:241-243), `canvasHi` (see 1D), `panel`
(:254-256), `raised` (:266-268), `well` (:293-295), `hairline` (:337-340), `containerEdge`
(:375-378) with the "Token table" values. Grounds keep no IC variant; `hairline` and
`containerEdge` get the IC hexes from the table. Rewrite each doc comment: the measured ratios
from the table, the iOS rule that `hairline` is never drawn on `raised` (1.154:1 dark, under the
1.25 edge floor — use `containerEdge` there), light is one flat ground (`canvas` = `panel` =
`raised` = `#FAFAFB`; separation on paper is edge weight). The `// MARK: Warm Signal custom palette (V2, spec §1)` line at :200 SURVIVES, retitled
`// MARK: Warm Signal custom palette`. Delete the block comment under it (:201-232) and
replace it with a short one: the ladder is the iPhone companion's (`audiout-remote`
`AudioutRemote/UI/Shared/WarmSignal.swift`), both appearances cool-neutral (Alec 2026-08-30/2026-09-03), four
variants per token per house rule 3, resolved live by `NSColor(name:dynamicProvider:)`. No
"Circuit", no Figma, no `@sumup-oss` anywhere in the file after this step.

1B. Add, in the ladder section after `well`: `liveRow`, `liveRaised` (warmDynamic; light = flat
ground; IC = base by the background precedent — pass the same hex explicitly for the IC
parameters so the four values are visible). After `containerEdge`: `rim`. Doc comments carry the
table's ratios and the iOS meaning (rim = a CONTROL's edge, held to 3:1).

1C. Ink. Replace `secondaryLabel` (:93-121) with `public static let label2` (warmDynamic, table
hexes; `static let` — identity comparisons), and `tertiaryLabel` (:122-124) with
`public static let label3`. Delete `inkSecondary` (:501-516) and `inkTertiary` (:518-539) as
declarations (they become aliases in 1F). Add `labelCool`, `labelCool2` (`static let`, same
reason) next to them. Doc comments: floors 4.5:1 on canvas/panel/raised/well in both
appearances with the table ratios; `labelCool`/`labelCool2`/`emberText` barred from
`liveRow`/`liveRaised` (4.38:1 / 4.31:1 measured on `liveRow`).

1D. Retire declarations: delete `canvasHi` (:244-250), `iconSeatFill` (:296-312),
`meterTrack` (:380-399; replaced by `meter`), `sidebarWarmTint` (:401-434), `ringConnected`
(:436-468 incl. the MARK block), `warningText` (:484-499), `success` (:560-572), `caution`
(:714-738 incl. the MARK block text; in its place write `// MARK: Glow + socket (accent halo and the routed dot's seat)`, which then heads `glow` and the new `socket`), `goldCTA` (:761-786),
`inkOnGold` (:788-801; replaced by `inkOnFill`), the fader MARK block + `faderThumb` +
`faderRim` (:803-843), `dotSocket` (:845-871; replaced by `socket`), the FEED-pill block
`feedPillFill` + `feedPillText` (:1159-1199), `plateRim` (:1299-1313). Each comes back as a
one-line alias in 1F.

1E. Re-value / rename declarations:
- `gold` (:630-641): light full `0x9E761D` → `0xA67C1E`; everything else unchanged. Delete the
  four-line light re-tune comment inside the call (:632-635); the doc comment's Subtle/IC
  measurements are re-stated from the table; drop the "Follow-system resolves controlAccentColor"
  sentence (:627-629).
- `ember` (:660-699): hexes unchanged; doc comment loses ":658 Follow-system = accent × 0.55" and
  the ratios are re-stated from the table (light raised is now the flat ground: 5.82:1).
- `glow` (:753-759): hexes unchanged; drop the Follow-system sentence (:751-752); light "1.74:1 vs
  panel" becomes 1.77:1 vs the flat ground.
- `failure` (:479-482): light `0xBB3A2F` → `0xB03327`, light IC `0xA62A20` → `0x962C21`. Doc:
  dark panel 4.60 / raised 4.04 (IC raised 5.28); light ground 6.01 / well 5.21 (IC 7.51 / 6.51);
  add the iOS rule: never body text (4.04:1 on dark `raised`).
- Add `goldText` and `emberText` via `accentDynamic` (Subtle columns per the table).
- Placement of the four new instruments: `ring` directly after `failure`; `inkOnFill` where
  `inkOnGold` was (:788-801); `socket` where `dotSocket` was (:845-871, under the new MARK above);
  `meter` where `meterTrack` was (:380-399).
- Add `ring` (warmDynamic), `inkOnFill` (warmDynamic: `dark: 0x171104, darkHighContrast: 0x171104,
  light: 0x171104, lightHighContrast: 0xFFFFFF`; doc records D4 and the eight measured gold cells),
  `socket`, `meter` (warmDynamic, table hexes).
- Rename `syncSignal` → `wireCore` (:1251-1254), `partySignal` → `party` (:1276-1279),
  `partySignalDeep` → `partyRampDeep` (:1286-1289); hexes unchanged; `syncSignalDeep` and
  `fuseWhite` unchanged. Update the two references inside `syncSignalDeep`'s and
  `partySignalDeep`'s comments.
- `railDormant` (:541-558): hexes unchanged; doc ratios re-measured: dark canvas 4.30 / panel 3.90 /
  raised 3.42 (IC 5.94 / 5.39 / 4.73); light ground 3.65, well 3.16 (IC 4.56 / 3.95).
- `bluetoothBrand` (:1145-1157): hex unchanged; doc: dark raised 4.20 / panel 4.79; light ground
  3.60 / well 3.12.
- `permission*` ×5 (:1022-1143): hexes unchanged; each rationale's numbers replaced by the
  "Kept tokens re-measured" table below; the block comment :975-986 (DIAL RESOLUTION) rewritten
  to say `.fullGold` resolves the Full column and `.subtle` the Subtle column, nothing about
  Follow-System.
- `stagePlate`…`fuseWhite`: unchanged except `syncSignalDeep`'s light ratios (5.18:1 on the flat
  ground) and `partyRampDeep`'s (8.69:1).
- `scope*` block (:873-911): unchanged (scopeGround is its own ground: flat 5.98, bypass 4.72).
- `engagedChrome` doc (:148-150): replace "warm near-black ground … flat Circuit light one" with
  "the cool near-black ground and the flat near-white one".

1F. Aliases. Add ONE section at the end of `public enum Color`, `// MARK: Deprecated aliases
(removed by the surface PRs)`, containing exactly these, each declared as
`@available(*, deprecated, renamed: "<new>") public static var <old>: NSColor { <new> }`:

| old | resolves to |
|---|---|
| `secondaryLabel`, `inkSecondary`, `warningText`, `feedPillText` | `label2` |
| `tertiaryLabel`, `inkTertiary` | `label3` |
| `canvasHi` | `canvas` |
| `iconSeatFill`, `faderThumb` | `raised` |
| `sidebarWarmTint` | `panel` |
| `feedPillFill` | `well` |
| `ringConnected`, `faderRim`, `plateRim` | `rim` |
| `caution`, `success`, `accent`, `goldCTA` | `gold` |
| `warning`, `destructive` | `failure` |
| `info` | `ring` |
| `inkOnGold` | `inkOnFill` |
| `dotSocket` | `socket` |
| `meterTrack` | `meter` |
| `syncSignal` | `wireCore` |
| `partySignal` | `party` |
| `partySignalDeep` | `partyRampDeep` |

Mechanism, verified by `swiftc -typecheck` during scoping: an enum cannot alias a case, but
`Tokens.Color` has no cases — its members are static properties — so a deprecated computed static
property forwarding to the new member is the alias. Because `label2`/`label3` are `static let`,
`Tokens.Color.secondaryLabel === Tokens.Color.label2` holds, which is what the identity-comparing
tests need. Delete the original `accent`/`warning`/`info`/`destructive` declarations (:125-133,
:172-191) — the alias rows above replace them. `renamed:` must name the bare member
(e.g. `"label2"`), not `"Tokens.Color.label2"`.

1G. Accent dial. In `accentDynamic` (:1578-1595) remove the `systemAccentScale` parameter and the
`.systemAccent` case; delete `systemAccentColor(in:scale:)` (:1597-1613); in `permissionDynamic`
(:1650) `case .fullGold, .systemAccent:` → `case .fullGold:`; drop `systemAccentScale:` from the
three call sites (`gold` :640, `ember` :698, `glow` :758) and the new `goldText`/`emberText`.
The `// MARK: - Accent dial (spec §1.3, W1)` line at :30 SURVIVES unchanged. Rewrite the
`accentStyle` doc (:32-49): the dial has two positions, Full and Subtle, remaps only
`gold`/`ember`/`glow`/`goldText`/`emberText`, never `failure`/`rim`/`ring`/text. Rewrite the
`accentDynamic` doc (:1568-1577) and `permissionDynamic` doc (:1615-1642) without Follow-system.
Line :583 "Full-gold/Subtle/Follow-accent" → "Full-gold/Subtle".

1H. Layout + Font. In `Tokens.Layout` (:1431-1466) add the nested `public enum Radius` with
`control: CGFloat = 10`, `row: CGFloat = 16`, `panel: CGFloat = 26` and a doc comment naming the
iOS source (`WarmSignal.Radius`) and stating no consumer is re-pointed in this PR. In
`Tokens.Font` (:1328-1417) add `public static func wordmark(size: CGFloat) -> NSFont`. It resolves
`Bundle.main.url(forResource: "ClashDisplay-Semibold", withExtension: "otf")`; when that is nil it
returns `.boldSystemFont(ofSize: size)` WITHOUT calling `NSFont(name:)` (so a Clash Display copy
installed in Font Book can never make a non-`.app` process differ). Concrete shape (type-checked
with a `swiftc` probe during scoping): `private static let wordmarkRegistered: Bool = { guard let url =
Bundle.main.url(forResource: "ClashDisplay-Semibold", withExtension: "otf") else { return false };
return CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }()` and `wordmark(size:)` reads
`guard wordmarkRegistered else { return .boldSystemFont(ofSize: size) }` then returns
`NSFont(name: "ClashDisplay-Semibold", size: size) ?? .boldSystemFont(ofSize: size)`.
Add `import CoreText` at the top of Tokens.swift. Doc comment: the wordmark sets the product name
only (iOS "Name Only Rule"); the font is in neither git nor the SwiftPM resource bundle —
`scripts/make-app.sh` fetches it at assembly into `Contents/Resources` (Step 8) — so under
`swift run`, `swift test` and the snapshot tools there is no `.app` and the system bold fallback is
the normal path, not an error. `BrandMark.resourceBundle` is not involved and stays `private`.
when the resource bundle is missing.

### Step 2 — `AudioutCore/Sources/AudioutCore/AppSettings.swift`

Delete `case systemAccent` (:28). Rewrite the enum doc (:17-24): two positions, `.subtle`
desaturates gold and removes the glow; a stored value from a build that had a third position
falls back to `.fullGold` through the getter's existing `?? .fullGold` (:131). No getter change.

### Step 3 — `AudioutCore/Sources/AudioutSettingsUI/AppearanceSettingsViewController.swift`

`accentOrder` (:48) → `[.fullGold, .subtle]`. Delete the `.systemAccent` arms of `displayName`
(:554) and `hintLine` (:564). Comments: :84 "three stock radios" → "two", :110 "the three dial names fit" →
"the two dial names fit", :549 "three dial names" → "two". Theme tiles (Step H of the brief):
`.dark` literals (:329-334): `canvas` `0x16/0x13/0x0F` → `0x0A/0x0A/0x0C`; `well` `0x10/0x0D/0x0A`
→ `0x05/0x05/0x07`; `gold` and `ember` unchanged. `.light` literals (:342-347): `canvas`
`0xFB/0xFB/0xF9` → `0xFA/0xFA/0xFB`; `well` `0xE2/0xDF/0xD3` → `0xE9/0xEA/0xEC`; `gold`
`0x9E/0x76/0x1D` → `0xA6/0x7C/0x1E`; `ember` unchanged. `name`/`nameDim` untouched (not pinned;
`label` did not move). Rewrite :319-327 and :336-338 comments: dark and light preview the cool
ladder; `well` and `gold` are pinned by `PreviewPaletteTokenPinTests`. No "Circuit".

### Step 4 — `AudioutCore/Sources/AudioutOnboardingUI/OnboardingChrome.swift`

Delete line :191 (`guard Tokens.accentStyle != .systemAccent else { return .white }`) and the
"— except under the `.systemAccent` dial…" clause of the doc comment (:186-189) so it reads:
white or black over the resolved fill, by WCAG contrast. Nothing else in the file.

Now run `bash scripts/build.sh` — expect exit 0 with deprecation warnings.

### Step 5 — `AudioutCore/Sources/AudioutSharedUI/WarmFaderCell.swift` (comments only)

:42-43: drop the parenthetical about `.systemAccent`; the sentence ends at "the accent dial
(spec §1.3 — `gold`/`ember` remap)". :118-119: delete the "under `.systemAccent` this resolves to
controlAccentColor and its dimmed companion" clause.

### Step 6 — Figma-mirror comments

`PopoverColumnGrid.swift:682`: "Named constants only — the Figma design-system contract mirrors
this file 1:1." → "Named constants only." `PopoverColumnGrid.swift:759-760`: "Named constants only
— the Figma design-system contract mirrors this file." (no "1:1" there) → "Named constants only."
`BTSyncDrawerView.swift:89-90`: "`PopoverColumnGrid` is the Figma
contract's mirror and holds METRICS" → "`PopoverColumnGrid` holds METRICS".

### Step 7 — remaining "Circuit" comments

`AlignmentWizardViewController.swift:249`: "visible only as banding on the Circuit ground" →
"visible only as banding on the flat light ground". `AppTetherColor.swift:475-480`: rewrite the
sentence WITHOUT numbers: the 0.40 drop exists so a light tint carries against the FEED pill's fill
(now `well`) as well as the canvas. Do not re-measure — C4 (PR 3) deletes the type. The stale
"`Tokens.Color.canvas` ≈ `#16130F`" at `AppTetherColor.swift:485-486` is LEFT AS IS (PR 3 owns
it). No other change in these two files.

### Step 8 — wordmark font: fetched at app assembly, never in git

Alec: this repo WILL go public, and the ITF Free Font License §02 forbids redistributing the font
through a public repository. So: nothing under `AudioutSharedUI/Resources/`, no `Package.swift`
change, `BrandMark.resourceBundle` stays `private`. The font reaches the app only through
`scripts/make-app.sh`'s local assembly phase. `scripts/make-staging.sh` calls `make-app.sh`
(make-staging.sh:110) and duplicates no assembly, so it inherits the step.

8.1 `.gitignore`: append after the last line (`.env`, line 46) one blank line and:

```
# The wordmark face, ClashDisplay-Semibold: the ITF Free Font License forbids
# redistributing it through a public repo, so scripts/make-app.sh fetches it
# at assembly (scripts/fetch-wordmark-font.sh). Never commit a copy.
*.otf
ClashDisplay-*
```

Cite lines 48-51 in the PR body. `build/` (line 5) already covers the download cache.

8.2 New file `scripts/fetch-wordmark-font.sh` (mode 755, `chmod +x`). Style mirrors
`scripts/bundle-dylibs.sh` (header comment with SPDX and WHY, `set -euo pipefail`, usage check)
and `make-app.sh`'s error idiom (`… || { echo "ERROR: …" >&2; exit 1; }`, `echo "==> …"` banners,
no backslash continuations — make-app.sh:22). Verified facts it relies on: the Fontshare package
URL `https://api.fontshare.com/v2/fonts/download/clash-display` returned HTTP 200
`application/zip`, 774 207 bytes, sha256
`1f93e17103f05b49b58ccb66704aae3bd570c361c41233c2bfd4db1a3e48952c` on two downloads five minutes
apart (stable); entries `ClashDisplay_Complete/Fonts/OTF/ClashDisplay-Semibold.otf` (sha256
`e70dce86ab1ba52063e2f85a536c21d70c3a9dee271f1fa453e58147be3c2f60`) and
`ClashDisplay_Complete/License/FFL.txt` (12 734 bytes, sha256
`145e7fe2429a3336ba215c070ef722000e01348a3e1baaa127e871bb5012f554`) exist at exactly those paths
(`unzip -l`). `unzip -p … > file || { … }` is a redirect, not a pipe, so `pipefail` is not in play:
`unzip` itself exits 11 on a missing entry and the `||` guard fires (confirmed during scoping under
`set -euo pipefail`: "caution: filename not matched" → "guard fired", exit 1; the redirect leaves a
0-byte file behind, which the next step never ships). The licence copy happens only AFTER the font
checksum passes, so a zip that lacks or corrupts the `.otf` can never put a partial
`ClashDisplay-FFL.txt` into the `.app` either.

```bash
#!/bin/bash
# fetch-wordmark-font.sh — put ClashDisplay-Semibold.otf (the wordmark face,
# Tokens.Font.wordmark) and its licence text into a .app's Contents/Resources.
#
# SPDX-License-Identifier: GPL-2.0-or-later
#
# WHY THIS EXISTS: the font is Indian Type Foundry's, under the ITF Free Font
# License — embedding in a desktop app is permitted (§01), redistributing the
# file through a public repository is not (§02). This repo is public, so the
# .otf never enters git: it is fetched from Fontshare at assembly, pinned by
# sha256, and only ever lands under build/ (gitignored) and inside the .app.
# Fontshare's download URL is not a published contract; the pins are the
# guard, and AUDIOUT_WORDMARK_FONT is the fallback when the URL dies.
#
# Usage:  scripts/fetch-wordmark-font.sh <Contents/Resources dir> [cache dir]
# Env:    AUDIOUT_WORDMARK_FONT=/path/to/ClashDisplay-Semibold.otf  use this
#         file instead of downloading (offline builds). Still checksummed.
set -euo pipefail

if [ $# -lt 1 ]; then echo "Usage: $0 <Contents/Resources dir> [cache dir]" >&2; exit 1; fi
DEST="$1"
CACHE="${2:-$(cd "$(dirname "$0")/.." && pwd)/build/font-cache}"
FONT_NAME="ClashDisplay-Semibold.otf"
LICENSE_NAME="ClashDisplay-FFL.txt"
FONT_SHA="e70dce86ab1ba52063e2f85a536c21d70c3a9dee271f1fa453e58147be3c2f60"
ZIP_URL="https://api.fontshare.com/v2/fonts/download/clash-display"
ZIP_SHA="1f93e17103f05b49b58ccb66704aae3bd570c361c41233c2bfd4db1a3e48952c"
ZIP="$CACHE/clash-display.zip"
ZIP_FONT_ENTRY="ClashDisplay_Complete/Fonts/OTF/ClashDisplay-Semibold.otf"
ZIP_LICENSE_ENTRY="ClashDisplay_Complete/License/FFL.txt"

sha256_of() { shasum -a 256 "$1" | cut -d' ' -f1; }

mkdir -p "$CACHE" "$DEST"

if [ -n "${AUDIOUT_WORDMARK_FONT:-}" ]; then
  FONT_SRC="$AUDIOUT_WORDMARK_FONT"
  [ -f "$FONT_SRC" ] || { echo "ERROR: AUDIOUT_WORDMARK_FONT=$FONT_SRC does not exist" >&2; exit 1; }
else
  # Cached zip with the pinned hash → skip the network. A re-packaged zip (new
  # hash) is still accepted as long as the .otf inside matches its own pin.
  if [ ! -f "$ZIP" ] || [ "$(sha256_of "$ZIP")" != "$ZIP_SHA" ]; then
    echo "==> Fetching Clash Display from Fontshare into $CACHE"
    curl -fsSL --compressed --max-time 120 -A "Mozilla/5.0" "$ZIP_URL" -o "$ZIP" || { echo "ERROR: could not download $FONT_NAME from $ZIP_URL — set AUDIOUT_WORDMARK_FONT to a local copy" >&2; exit 1; }
  fi
  unzip -p "$ZIP" "$ZIP_FONT_ENTRY" > "$CACHE/$FONT_NAME" || { echo "ERROR: $ZIP_FONT_ENTRY missing from the Fontshare zip — the package layout changed; set AUDIOUT_WORDMARK_FONT" >&2; exit 1; }
  unzip -p "$ZIP" "$ZIP_LICENSE_ENTRY" > "$CACHE/$LICENSE_NAME" || { echo "ERROR: $ZIP_LICENSE_ENTRY missing from the Fontshare zip" >&2; exit 1; }
  FONT_SRC="$CACHE/$FONT_NAME"
fi

ACTUAL="$(sha256_of "$FONT_SRC")"
[ "$ACTUAL" = "$FONT_SHA" ] || { echo "ERROR: $FONT_NAME sha256 $ACTUAL != pinned $FONT_SHA — the wordmark face changed upstream or the file is corrupt; not shipping it" >&2; exit 1; }
cp "$FONT_SRC" "$DEST/$FONT_NAME"
if [ -f "$CACHE/$LICENSE_NAME" ]; then cp "$CACHE/$LICENSE_NAME" "$DEST/$LICENSE_NAME"; else echo "WARNING: $LICENSE_NAME not in $CACHE (AUDIOUT_WORDMARK_FONT build) — the licence text ships only from a Fontshare fetch" >&2; fi
echo "==> $FONT_NAME ($ACTUAL) -> $DEST"
```

8.3 `scripts/make-app.sh`: insert directly after line 407 (`cp -R "$BUILT_RESOURCE_BUNDLE"
"$RESOURCES_DIR/$RESOURCE_BUNDLE_NAME"`), before the `# --- SMAppService launchd daemon plist`
section (:409). This is the LOCAL assembly phase (the compile — remote or local — is finished at
:377-380; codesign starts at :958), so the step runs identically for a remote-mule compile.

```bash
# --- Wordmark font (ClashDisplay-Semibold) ---------------------------------
# NOT in git and NOT in the SwiftPM resource bundle: the ITF Free Font License
# forbids redistributing the file through a public repository, so
# scripts/fetch-wordmark-font.sh pulls it from Fontshare at assembly (cached
# under build/, sha256-pinned; AUDIOUT_WORDMARK_FONT=<path> for offline) and
# Tokens.Font.wordmark finds it in Contents/Resources through Bundle.main.
# A missing or mismatched font FAILS the build: a shipped app must never
# fall back to the system face silently.
"$SCRIPT_DIR/fetch-wordmark-font.sh" "$RESOURCES_DIR" "$OUTPUT_DIR/font-cache"
test -f "$RESOURCES_DIR/ClashDisplay-Semibold.otf" || { echo "ERROR: ClashDisplay-Semibold.otf missing from $RESOURCES_DIR after fetch" >&2; exit 1; }
```

Codesign needs nothing for it: the app is signed once as a bundle (`codesign … --sign
"$CODESIGN_IDENTITY" "$APP_BUNDLE"`, make-app.sh:1063), which seals everything under
`Contents/Resources`; the `.icns` (:666) and the SwiftPM resource bundle (:407) are plain copies
with no codesign call of their own, and a font is data, not nested code, so `--deep` verification
(:1092) never looks at it. `xattr -cr` (:955) runs after the copy and before signing.

### Step 9 — tests (see "Test plan"; one file at a time, build between files is optional)

## Token table

Columns: dark, dark-IC, light, light-IC. Grounds: dark canvas `#0A0A0C`, panel `#15171A`,
raised `#1F232A`, well `#050507`, liveRow `#2E2518`; light ground (= canvas = panel = raised)
`#FAFAFB`, well `#E9EAEC`. "g" = the light flat ground.

### Grounds (status: re-valued unless marked; no IC variant — IC parameters carry the base hex)

| token | dark | light | separation measured | status |
|---|---|---|---|---|
| canvas | #0A0A0C | #FAFAFB | — | re-valued |
| panel | #15171A | #FAFAFB | dark 1.101 on canvas; light 1.000 | re-valued |
| raised | #1F232A | #FAFAFB | dark 1.139 on panel, 1.255 on canvas, 1.292 on well | re-valued |
| well | #050507 | #E9EAEC | dark 1.134 on panel, 1.029 on canvas (read by its edge); light 1.154 on g | re-valued |
| liveRow | #2E2518 | #FAFAFB | dark 1.313 on canvas, 1.192 on panel, 1.352 on well | NEW |
| liveRaised | #2B241C | #FAFAFB | dark 1.292 on canvas, 1.016 on liveRow (well ring divides them, 1.330) | NEW |

### Edges

| token | dark | dark-IC | light | light-IC | ratios (base → IC) | status |
|---|---|---|---|---|---|---|
| hairline | #2A2E33 | #616467 | #CBCED4 | #727377 | dark: canvas 1.45, panel 1.31, well 1.49, raised 1.15 (BANNED) → IC panel 3.02, canvas 3.32. light: g 1.51, well 1.31 → IC g 4.54, well 3.93 | re-valued |
| containerEdge | #3D4247 | #6A6E72 | #AEB3BB | #67696E | dark: canvas 1.95, panel 1.77, raised 1.55, liveRow 1.48 → IC panel 3.49, raised 3.07, 1.159 over hairline-IC. light: g 2.02, well 1.75 → IC g 5.27, well 4.56, 1.160 over hairline-IC | re-valued |
| rim | #6B767D | #818B90 | #66717A | #586269 | dark: well 4.38, canvas 4.25, panel 3.86, raised 3.39 → IC raised 4.53, well 5.85. light: g 4.78, well 4.15 → IC well 5.18, g 5.98 | NEW |

### Ink (floor 4.5:1 on canvas/panel/raised/well, both appearances)

| token | dark | dark-IC | light | light-IC | ratios (base → IC) | status |
|---|---|---|---|---|---|---|
| label | `.labelColor` | | | | unchanged (D1) | kept |
| label2 | #B7AC95 | #C9C1AF | #6B5F4E | #554C3E | dark canvas 8.81, panel 7.99, raised 7.02, well 9.07, liveRow 6.71 → IC raised 8.81. light g 5.97, well 5.17 → IC well 7.01, g 8.09 | renamed (secondaryLabel + inkSecondary) |
| label3 | #9E947F | #B4AD9C | #6B6459 | #524C44 | dark canvas 6.59, panel 5.98, raised 5.25, well 6.78 → IC raised 7.06. light g 5.60, well 4.86 → IC well 7.05, g 8.13 | renamed (tertiaryLabel + inkTertiary) |
| labelCool | #A9B3BB | #C0C8CD | #4E5A63 | #414B53 | dark canvas 9.28, panel 8.43, raised 7.40, well 9.55 → IC raised 9.30. light g 6.79, well 5.88 → IC well 7.40, g 8.54. Barred from liveRow (7.07 passes but the rule is temperature) | NEW |
| labelCool2 | #818C94 | #A6AEB3 | #5F6A73 | #464E55 | dark canvas 5.76, panel 5.23, raised 4.59, well 5.93; liveRow 4.38 (BANNED) → IC raised 7.00. light g 5.30, well 4.60 → IC well 7.03, g 8.11 | NEW |

### Gold family (dial-aware; Full column / Subtle column)

| token | Full dark / dark-IC / light / light-IC | Subtle dark / dark-IC / light / light-IC | ratios | status |
|---|---|---|---|---|
| gold | #E8B84B / #F2C75E / #A67C1E / #8A6614 | #B99B53 / #CBAF6A / #8F7B4A / #6F5E33 | Full dark canvas 10.73, panel 9.74, raised 8.55, well 11.04 (IC 12.35/11.21/9.84/12.71); Full light g 3.64, well 3.16 (IC 5.04 / 4.37); Subtle dark raised 5.91 (IC 7.42); Subtle light g 3.95, well 3.42 (IC 6.06 / 5.25) | light re-valued |
| goldText | #E8B84B / #F2C75E / #825E0F / #64480C | #B99B53 / #CBAF6A / #79683F / #584C2E | text floor 4.5: Full dark = gold (raised 8.55); Full light g 5.66, well 4.90 → IC well 7.05, g 8.14; Subtle dark raised 5.91 (IC 7.42); Subtle light well 4.51, g 5.21 → IC well 7.01 | NEW |
| ember | #8A6A2F / #A5824A / #7A5E2A / #5E4922 | #6D5B34 / #877146 / #71613B / #5C5030 | Full dark canvas 3.94, panel 3.58, raised 3.14, well 4.06 (IC 5.55/5.04/4.42/5.71); Full light g 5.82, well 5.04 (IC 8.21 / 7.11); Subtle dark canvas 3.01, panel 2.73, raised 2.40, well 3.10 (documented under-floor 2 pt line, IC 4.22/3.83/3.36/4.34); Subtle light g 5.79, well 5.02 (IC 7.61 / 6.59) | unchanged (D3) |
| emberText | #A98341 / #C4AA7C / #7A5A22 / #62491B | #95886B / #B6AC98 / #71613B / #584C2E | text floor 4.5: Full dark canvas 5.66, panel 5.14, raised 4.51, well 5.83; liveRow 4.31 (BANNED) → IC raised 7.05; Full light g 6.08, well 5.27 → IC well 7.01, g 8.09; Subtle dark raised 4.51, canvas 5.66, panel 5.14, well 5.83 → IC 7.01; Subtle light well 5.02, g 5.79 → IC well 7.01 | NEW |
| glow | #FFD97A / #FFD97A / #E8B84B / #E8B84B | none (`.clear`) | floor-exempt halo; dark panel 13.22; light g 1.77 | unchanged |
| inkOnFill | #171104 / #171104 / #171104 / #FFFFFF | (not dial-aware) | on gold: Full dark 10.18, dark-IC 11.72, light 4.94, light-IC (white) 5.26; Subtle dark 7.04, dark-IC 8.83, light 4.56, light-IC (white) 6.32; on wireCore-family `#21D477` 9.61 | renamed from inkOnGold, re-valued (D4) |

Light-ember/gold relationship (MembershipWellContrastTests): gap 1.595 (band 1.40–1.60 — 0.005
of margin, deterministic), saturation 0.819 vs 0.656 (gap 0.164 ≥ 0.15), hue 41.5° vs 39.0°
(0.0069 of a turn ≤ 0.03), luminance 0.2262 > 0.1231. Subtle light gap 1.468.

### Instruments

| token | dark | dark-IC | light | light-IC | ratios | status |
|---|---|---|---|---|---|---|
| ring | #7FB4C4 | #9FC7D3 | #2C6E86 | #265E73 | floor 3.0 on canvas/panel/raised: dark 8.69 / 7.89 / 6.93, well 8.95 → IC raised 8.70, canvas 10.91; light g 5.47, well 4.74 → IC g 6.87, well 5.95 | NEW |
| failure | #D9564A | #F26B5C | #B03327 | #962C21 | floor 3.0 on panel/raised: dark 4.60 / 4.04 (never body text) → IC raised 5.28; light g 6.01, well 5.21 → IC g 7.51, well 6.51 | light re-valued |
| socket | #2A2E33 | #3D4247 | #DFE1E4 | #CBCED4 | floor ≥1.4 vs the rim that rings it; the 16 cells the test can produce (appearance × dial column × IC on/off, IC applied to socket AND rim together): dark IC-off ember 2.72 / gold 7.41, Subtle ember 2.08 (tightest) / gold 5.12; dark IC-on ember 2.85 / gold 6.34, Subtle ember 2.17 / gold 4.78; light IC-off ember 4.63 / gold 2.90, Subtle ember 4.61 / gold 3.14; light IC-on ember 5.43 / gold 3.34, Subtle ember 5.03 / gold 4.01. Quiet on its ground: dark panel 1.31 (IC 1.77), light g 1.26 (IC 1.51) | renamed from dotSocket, re-valued |
| meter | #464C55 | #545B66 | #C6C9CE | #B4B8BF | no floor (recess): dark canvas 2.28 (IC 2.89), ember over it 1.72, gold over it 4.70; light g 1.59 (IC 1.91), ember over it 3.65 (Subtle 3.64) | renamed from meterTrack, re-valued |
| wireCore | #2BFF8F ×4 | | | | 14.73 on stagePlate | renamed from syncSignal |
| party | #FF90E9 ×4 | | | | 9.71 on stagePlate | renamed from partySignal |
| partyRampDeep | #FF90E9 | #FF90E9 | #752C68 | #5E2354 | light g 8.69, well 7.53 | renamed from partySignalDeep (D5) |
| railDormant | #7D7466 | #948C7C | #8A8272 | #7A7263 | dark canvas 4.30, panel 3.90, raised 3.42 (IC 5.94/5.39/4.73); light g 3.65, well 3.16 (IC 4.56/3.95) | kept, re-measured |
| bluetoothBrand | #0082FC ×4 | | | | dark raised 4.20, panel 4.79; light g 3.60, well 3.12 | kept, re-measured |
| syncSignalDeep | #2BFF8F | #2BFF8F | #0B7A45 | #086237 | light g 5.18, well 4.49 | kept, re-measured |

### Kept tokens re-measured — permission hues (floor 3.0 on panel AND raised, both columns, both appearances)

| token | Full dark canvas/panel/raised | Full dark-IC | Subtle dark | Subtle dark-IC | Full light g/well | Full light-IC | Subtle light | Subtle light-IC |
|---|---|---|---|---|---|---|---|---|
| permissionSystemAudio | 6.04 / 5.49 / 4.82 | 9.32 / 8.46 / 7.43 | 4.28 / 3.88 / 3.41 | 6.72 / 6.10 / 5.36 | 4.45 / 3.85 | 6.73 / 5.83 | 4.02 / 3.48 | 7.49 / 6.49 |
| permissionLocalNetwork | 4.99 / 4.53 / 3.97 | 8.40 / 7.63 / 6.70 | 3.85 / 3.49 / 3.07 | 6.05 / 5.50 / 4.82 | 5.91 / 5.12 | 8.48 / 7.34 | 4.60 / 3.98 | 8.67 / 7.52 |
| permissionRemoteControl | 5.33 / 4.84 / 4.25 | 8.29 / 7.52 / 6.60 | 3.96 / 3.60 / 3.16 | 6.22 / 5.65 / 4.96 | 5.27 / 4.57 | 7.94 / 6.88 | 4.22 / 3.66 | 7.88 / 6.83 |
| permissionSpeakerSync | 5.08 / 4.61 / 4.04 | 8.08 / 7.34 / 6.44 | 3.99 / 3.62 / 3.18 | 5.95 / 5.40 / 4.74 | 4.89 / 4.23 | 7.58 / 6.57 | 5.39 / 4.67 | 9.38 / 8.13 |
| permissionUsageStats | 5.58 / 5.06 / 4.44 | 9.21 / 8.36 / 7.34 | 4.24 / 3.85 / 3.38 | 6.56 / 5.95 / 5.22 | 5.35 / 4.64 | 8.20 / 7.10 | 5.46 / 4.74 | 8.73 / 7.56 |

### Layout

| constant | value | status |
|---|---|---|
| `Tokens.Layout.Radius.control` | 10 | NEW |
| `Tokens.Layout.Radius.row` | 16 | NEW |
| `Tokens.Layout.Radius.panel` | 26 | NEW |

### Retired by alias (no hex of their own after PR 1)

canvasHi→canvas · iconSeatFill→raised · sidebarWarmTint→panel · ringConnected→rim · caution→gold ·
success→gold · warningText→label2 · warning→failure · info→ring · destructive→failure · accent→gold ·
goldCTA→gold · faderThumb→raised · faderRim→rim · plateRim→rim · feedPillFill→well ·
feedPillText→label2.

## Interim visible effects (between PR 1 merge and the owning surface PR)

| alias | live surface (file:line) | what Alec will see until the surface PR |
|---|---|---|
| canvasHi→canvas | WarmCanvasView.swift:85 | Dark popover/window canvas is flat `#0A0A0C` with grain, no gradient. |
| sidebarWarmTint→panel | SidebarWarmSurfaceView.swift:106 | Groups sidebar wash goes cool (panel at ~0.30 alpha); C6 deletes it later. |
| iconSeatFill→raised | DeviceIconWellView.swift:252, GroupsOverviewViewController.swift:806 | Icon seats become raised-coloured (dark `#1F232A` on the card, light = flat ground); only the containerEdge stroke defines them. |
| ringConnected→rim | HaloRingView.swift:246/251/266, WarmFaderCell.swift:168, AppTetherColor.swift:78 | Connected/connecting/resting rings and the unarmed fader fill turn cool steel grey. |
| caution→gold | LevelMeterView.swift:190 | Meter ramp is ember → gold → gold (ceiling is gold, C3). |
| success→gold | SetupCheckRowView.swift:66, SetupCardView.swift:311 | Earned checkmarks are gold, not green. |
| warningText→label2 | AudioSettingsViewController.swift:639, SetupCardView.swift:323, OnboardingViewController.swift:1380-1715 | Permission-lost and ribbon status text lose the orange; read as ordinary secondary text until the onboarding PR adds the `failure` glyph. |
| warning→failure | SilenceFallbackBannerView.swift:29/130-131, SystemAirPlayNoteBannerView.swift:41, GeneralSettingsViewController.swift:231/551 | Silence/warning banners tint red at 14 %/40 % alpha instead of orange; the two Settings notes go red. |
| info→ring | SystemAirPlayNoteBannerView.swift:40 | Info banner tints steel blue `#7FB4C4`/`#2C6E86` instead of system blue. |
| destructive→failure | AppRowView.swift:727 | "Remove from list" menu text is `failure` red (a text use iOS forbids; C4 rewrites the pill/menu). |
| accent→gold | OnboardingChrome.swift:99 (ProminentButton default fill → UsageStatsConsentCard.swift:42, OnboardingChrome.swift:16), DeviceRowView.swift:2967, AppearanceSettingsViewController.swift:368 | Every prominent onboarding button, the row attention flash, and the selected theme tile's ring are gold instead of the macOS accent. |
| goldCTA→gold | LicenseGateViewController.swift:273, SetupRibbonView.swift:492 | Gate and finale CTAs fill with `gold`; `picksInkFromFill` measures black on both appearances (light 5.52:1). `#171104` ink lands with the onboarding PR. |
| faderThumb→raised, faderRim→rim | WarmFaderCell.swift:178, :211-233 | Fader thumb body becomes `raised` (dark 1.29:1 on the trough, light 1.15:1) with its derived highlight/outline; the trough rim becomes `rim` (dark 4.38:1). The thumb reads faint until PR 3 re-skins the fader. |
| plateRim→rim | AlignmentPlateCell.swift:162, AlignmentStageView.swift:1648 | Wizard plate rims go steel grey (4.25:1 on canvas). |
| feedPillFill→well, feedPillText→label2 | FeedPillView.swift:138, DeviceRowView.swift:1150/1243 | FEED pills are well-filled with label2 text (light 5.17:1 on the fill); C4 deletes the pills. |
| secondaryLabel→label2, tertiaryLabel→label3 | 104 + 18 sites | Dark secondary text goes from the translucent system grey to authored warm `#B7AC95`; tertiary to `#9E947F`. |
| inkOnGold→inkOnFill | AlignmentPlateCell.swift:328/395 | Plate titles are `#171104` instead of pure black (10.18:1). |
| Follow-system dial deleted | Settings › Appearance | Third radio gone; a Mac that had it selected shows Full Gold. |

## Test plan

Update only these files. Every ratio a test asserts is in the Token table above.

### MembershipWellContrastTests.swift
- `wellVsPanelClearsTheContainerFloorBothAppearances`: keep (dark 1.134, light 1.154 ≥ 1.10).
- `hairlineVsPanelClearsTheSeparatorFloorBothAppearances`: keep (1.31 / 1.51).
- `containerEdgeClearsTheCardEdgeFloorAndOutranksTheDivider`: keep; update the doc comment and the
  failure message's "1.07:1 dark / 1.10:1 light" to "1.139:1 dark / 1.000:1 light" (edge 1.55 / 2.02;
  divider on raised 1.15 / 1.51).
- `containerEdgeClearsTheSeparatorFloorOnTheIconSeat`: DELETE (iconSeatFill is `raised`; the test
  above already pins containerEdge vs raised).
- `authoredInksClearTheBodyFloorOnEveryGroupsGround`: rewrite — inks `label3`, `label2`; grounds
  `panel`, `raised`, `well` (drop `sidebarWarmTint`). Expected tightest: dark label3 on raised 5.25,
  light label3 on well 4.86. Update the doc comment's alias story to name `label2`/`label3`.
- `hairlineVsRaisedClearsTheDividerFloorInsideACard`: DELETE. Replace with
  `hairlineIsBarredFromRaisedByMeasurement`: dark `hairline` vs `raised` is UNDER 1.25 (expected
  1.154) and `containerEdge` vs `raised` is ≥ 1.25 in both appearances — the self-cleaning idiom
  `TokenContrastMatrixTests.exceptions` uses: if a re-tune ever lifts the pair over the floor the
  test fails and the ban comment is revisited.
- `lightEmberClearsTheNonTextFloorOnBothSurfaces`, `lightGoldClearsTheNonTextFloorOnBothSurfaces`,
  `lightGoldStaysTheLouderInkBesideEmber`, `lightEmberStaysTheDullerInkBesideGold`,
  `lightEmberStaysTellableFromGold`: keep unchanged (values in the table; gap 1.595).
- `warmPaneChecklistHasARecessedWellBehindTheRows`, `wellRowCountFollowsARebuild`: keep.
- File doc comment: replace the sentence quoting "1.060:1 dark and 1.000:1 light" with 1.101 / 1.000.

### TokenContrastMatrixTests.swift
- Doc comment (:9-46): rewrite the exclusions list — floor-exempt backdrops are now
  `canvas`/`panel`/`raised`/`well`/`liveRow`/`liveRaised`/`glow`/`socket`/`meter`; permission
  hues + `bluetoothBrand` + gold-on-raised stay with `OnboardingPermissionColorTests`; drop the
  `goldCTA`, `.systemAccent`, `warning`/`destructive`/`info` sentences.
- `everyInstrumentClearsItsFloorAcrossAppearanceAndIncreaseContrast`: replace the `entries` array
  with — TEXT 4.5 on `[canvas, panel, raised, well]`: `label2`, `label3`, `labelCool`, `labelCool2`,
  `goldText`, `emberText`. NON-TEXT 3.0: `failure` [panel, raised]; `gold` [panel, raised, well];
  `ember` [panel, raised, well]; `ring` [canvas, panel, raised]; `rim` [canvas, raised, well];
  `railDormant` [canvas, panel, raised]; `scopeFlatLine`, `scopeBypassLine` [scopeGround]. Delete the
  `iconSeatFill`/`feedPillFill` locals. `exceptions` becomes an empty array with its doc comment
  saying none are listed today (keep the mechanism). Tightest expected cells: dark `emberText` on
  raised 4.51, dark `labelCool2` on raised 4.59, light `gold` on well 3.16.
- `subtleColumnEmberAndGoldClearTheNonTextFloorOnWellAndPanel`: keep; add a second loop asserting
  `goldText` and `emberText` in `.subtle` clear 4.5 on light `well` and `panel` (expected 4.51 / 5.21
  and 5.02 / 5.79). Update the doc comment's expected numbers to 3.42 well / 3.95 panel (gold) and
  5.02 / 5.79 (ember).
- `emberIncreaseContrastIsStrictlyFurtherFromPanelThanBase`: keep (dark 3.58 → 5.04; light 5.82 → 8.21).
- `dimmedNodeSeatSeparatesFromBothRimTones`: rename `dotSocket` → `socket` in code and comment;
  keep the 1.4 floor; the comment's "tightest cell is Subtle dark ember, 1.47:1" → "tightest cell
  is Subtle dark ember, 2.08:1".
- `accentDialReStampsLayerColorInstrumentsLive`: keep.

### AlignmentTokenContrastTests.swift
- `stageRule…`, `stageInk…`: keep.
- `syncPartyAndFuseSignalsClearTheNonTextFloorOnThePlateBothAppearances`: rename references to
  `wireCore` / `party`; keep.
- `plateRimClearsTheRimFloorVsRaisedAndCanvasBothAppearances`: reference `rim`; keep (dark 3.39 /
  4.25, light 4.78 / 4.78).
- `inkOnGoldClearsTheBodyFloorOnThePinnedPrimaryPlateGold` → rename to `inkOnFill…`, compare
  `Tokens.Color.inkOnFill` resolved under `.darkAqua` (10.18).
- `lightSyncSignalDeep…`: keep. `lightPartySignalDeep…`: reference `partyRampDeep`; keep (8.69).

### PreviewPaletteTokenPinTests.swift
- Both tests keep unchanged; they pass once Step 3's literals land. Doc comment :17-19 may keep its
  history sentence.

### SettingsAccentAndHintsTests.swift
- `accentStyleDefaultsToFullGold`, `accentStyleRoundTripsEveryCase`,
  `accentStyleUnknownStoredValueFallsBack`, `accentDialDefaultsToFullGold`,
  `selectingAccentPersistsRemapsAndNotifies`, `subtleRemapsGoldAndRemovesGlow`: keep.
- `accentDialInitialisesFromPersistedStyle`: `.systemAccent` → `.subtle` (both lines).
- `accentHintTracksSelection`: `.systemAccent` → `.subtle`.
- `systemAccentPullsControlAccentIntoGold`: DELETE.
- `accentDialNeverRemapsFailureCautionOrRing` → rename `accentDialNeverRemapsFailureRimOrRing`;
  tokens `failure`, `rim`, `ring`; loop over `AccentStyle.allCases`.
- ADD `accentStyleStoredFollowSystemFallsBackToFullGold`: write the string `"systemAccent"` to key
  `"appearance.accentStyle"` on `isolatedDefaults`, expect `settings.accentStyle == .fullGold`.
- Audio/General pane tests: keep.

### OnboardingPermissionColorTests.swift
- File doc comment (:17-19): delete the NEW-1 / `.systemAccent` sentences — the clause "while
  `.systemAccent` leaves them at their authored Full-gold hues and STILL mutually distinct (NEW-1 …
  dial position)" goes; the sentence ends at "(Q5)".
- `goldOnRaisedClearsTheGlyphFloorInBothDialColumnsAndAppearances` doc comment (:219-220): delete
  the sentence "`.systemAccent` is excluded on the token's own terms: it resolves `gold` to the
  live user accent, whose contrast the OS owns." The test body is unchanged.
- `everyTokenIsMutuallyDistinctInFullGold`, `…InSubtle`,
  `contrastFloorClearsInBothDialColumnsBothAppearancesBothSurfaces`,
  `subtleActuallyChangesEveryTokenFromFullGold`, `goldOnRaisedClearsTheGlyphFloor…` (light 3.64,
  subtle light 3.95), `glyphTintIsPermanentAcrossEveryCardState`, `tileFillIsAlwaysTheNeutralRaisedWell`,
  `bluetoothCardCarriesTheSystemBluetoothGlyph`, `bluetoothBrandIsTheOfficialBlueAndClearsTheGlyphFloor`
  (light 3.60): keep.
- `systemAccentStaysAtFullGoldValuesAndStaysDistinct` (:184-212 + MARK): DELETE.
- `goldCTAClearsTheInkAndCanvasFloorsInBothAppearances` → rewrite as
  `goldFillTakesInkOnFillAndClearsTheCanvasFloorInBothAppearances`: fill = `Tokens.Color.gold`
  resolved per appearance; ink = `Tokens.Color.inkOnFill` resolved per appearance; assert ink ≥ 4.5
  (dark 10.18, light 4.94) and fill vs canvas ≥ 3.0 (10.73 / 3.64). Drop the `ProminentButton`
  construction and the white-ink assertion (the button adopts `inkOnFill` in the onboarding PR).
- `warningTextClearsTheBodyFloorInBothAppearances`: DELETE (token is `label2`, covered below).
- `inkSecondaryClearsTheBodyFloorInBothAppearances` → `label2ClearsTheBodyFloorInBothAppearances`
  on canvas/panel/raised (dark 8.81 / 7.99 / 7.02; light 5.97).
- `successClearsTheUIFloorInBothAppearances`: DELETE (the checkmark is `gold`; gold-on-raised is pinned).
- `raisedIsDistinctFromPanelInLight` → rewrite as `lightGroundIsOneFlatValue`: `canvas`, `panel`,
  `raised` resolve to the same sRGB under `.aqua` (the iOS flat-ground decision).

### RingRailToneLockTests.swift
- Line :180: `[.systemAccent, .subtle, .fullGold]` → `[.subtle, .fullGold]`. Everything else keep
  (test 3 compares against `Tokens.Color.ringConnected`, which now resolves `rim` on both sides).

### GroupsWindowTextColorLockTests.swift
- `warmTokens` (:85-107; the glow/dotSocket/faderThumb/faderRim entries are :102-105): remove `canvasHi`, `iconSeatFill`, `sidebarWarmTint`, `caution`,
  `faderThumb`, `faderRim`; rename `meterTrack`→`meter`, `ringConnected`→`rim`, `dotSocket`→`socket`;
  add `liveRow`, `liveRaised`. Do NOT add `labelCool`/`labelCool2`/`goldText`/`emberText`/`ring` —
  C5 supersedes this lock in the Groups PR.
- `stockSemantics` (:135-145; the two edited entries are :143-144): `Tokens.Color.secondaryLabel`
  → `label2`, `inkTertiary` → `label3`; update the two carve-out bullets in the comment (:120-130)
  to the new names; the numbers in the
  `inkTertiary` bullet become label3's: 5.60 g / 4.86 well light, 5.25 raised dark.
- All `@Test` bodies: keep unchanged.

### NoteBannerColorTests.swift
- All tests keep. Rewrite the file doc comment (:8-16): `Tokens.Color.warning` and `.info` are
  deprecated aliases of `failure` and `ring`; the tests guard the wiring and alphas.

### EQResponseCurveTests.swift, RailConnectPulseTests.swift, AppTetherColorTests.swift
- No change (see Verified facts; `AppTetherColorTests` measures against its own hardcoded old-ground
  literals at :316-317, not the tokens). Run them anyway.

### AccessibilitySignalSweepTests.swift
- `flattenedCanvasIsTheFlatOpaqueBaseColor`: keep the flattened half (top == bottom within 1/255);
  add an assertion that the flat top pixel equals `Tokens.Color.canvas` resolved under `.darkAqua`
  within 1/255 per channel; DELETE the graded half (:258-271) — it still passes, but only because
  the dark grain supplies the delta, so it no longer proves anything — and rewrite the comment
  (:233-241): the canvas is flat in both appearances now, so flattening is asserted by colour, not
  by the absence of a gradient. No "Circuit".
- `meterGradientSurvivesDisplayOptionsChange` (:293-312): keep; comment "(ember → gold → caution)"
  → "(ember → gold → gold)".
- Everything else keep.

### BrandMarkTests.swift
- ADD `wordmarkFallsBackToSystemBoldWithoutTheAppBundle`: `let font = Tokens.Font.wordmark(size: 32)`;
  `#expect(font.fontName == NSFont.boldSystemFont(ofSize: 32).fontName)` (resolves to
  `.AppleSystemUIFontBold` on this toolchain — compare against the live value, not the literal) and
  `#expect(font.pointSize == 32)`. Under `swift test` `Bundle.main` is the XCTest runner, so
  `Bundle.main.url(forResource:withExtension:)` is nil (verified with a `swiftc` probe: it printed
  `nil` outside an `.app`) and the fallback is the path under test. The real face is only
  checkable in an assembled `.app` (Verification, owed line).

### Untouched suites that reference deprecated names (compile through the alias, pass as measured)
NoTintOnRingsOrMetersGuardTests (`caution` stop == `gold`), RouteArmedSignalTests,
DeviceRowConnectionStateTests, DeviceRowConnectBrightenTests, BTRowsUITests,
ConnectionDiagnosisViewTests, OnboardingUITests, PopoverPanelHeaderTests, FeedColumnTests,
PopoverControllerTests, AppRowViewTests. Do not edit them.

## Verification (in this order; paste each command's output)

```bash
bash scripts/build.sh                      # exit 0; deprecation warnings expected
AUDIOUT_TEST_NO_CACHE=1 bash scripts/run-tests.sh --filter 'MembershipWellContrastTests|TokenContrastMatrixTests|AlignmentTokenContrastTests|PreviewPaletteTokenPinTests|SettingsAccentAndHintsTests|OnboardingPermissionColorTests|RailConnectPulseTests|GroupsWindowTextColorLockTests|NoteBannerColorTests|RingRailToneLockTests|EQResponseCurveTests|AppTetherColorTests|AccessibilitySignalSweepTests|NoTintOnRingsOrMetersGuardTests|RouteArmedSignalTests|BrandMarkTests'
#   expected: every suite passes; test count = 205 − 6 deleted + 3 added = 202 (report the real number)
AUDIOUT_TEST_NO_CACHE=1 bash scripts/run-tests.sh       # the FULL suite, once, green
grep -rn "Circuit\|Figma" --include='*.swift' AudioutCore/Sources AudioutCore/Tests | grep -v "ShortCircuit" | grep -v "BrandMark.swift:12"
#   expected: no output (BrandMark.swift:12 names the icon's Figma frame and stays)
grep -rn "systemAccent" --include='*.swift' AudioutCore/   # expected: no output

# Font path — NO dev build and NO livetest slot in PR 1. The script is proven in isolation:
bash -n scripts/make-app.sh scripts/fetch-wordmark-font.sh                       # exit 0
bash scripts/fetch-wordmark-font.sh "$TMPDIR/wm-dest" "$TMPDIR/wm-cache"
#   expected: "==> Fetching Clash Display …" then "==> ClashDisplay-Semibold.otf (e70dce86…2f60) -> …/wm-dest"
shasum -a 256 "$TMPDIR/wm-dest/ClashDisplay-Semibold.otf"                       # e70dce86ab1ba52063e2f85a536c21d70c3a9dee271f1fa453e58147be3c2f60
head -4 "$TMPDIR/wm-dest/ClashDisplay-FFL.txt"                                   # "ITF Free Font License (FFL)" heading
bash scripts/fetch-wordmark-font.sh "$TMPDIR/wm-dest" "$TMPDIR/wm-cache"          # second run: NO "Fetching" line (zip cache hit), same final line
AUDIOUT_WORDMARK_FONT="$TMPDIR/wm-cache/ClashDisplay-Semibold.otf" bash scripts/fetch-wordmark-font.sh "$TMPDIR/wm-dest2"   # override path: final line only, plus the licence WARNING
printf 'x' > "$TMPDIR/bad.otf"; AUDIOUT_WORDMARK_FONT="$TMPDIR/bad.otf" bash scripts/fetch-wordmark-font.sh "$TMPDIR/wm-dest3"; echo "exit=$?"
#   expected: "ERROR: ClashDisplay-Semibold.otf sha256 … != pinned …" and exit=1
git check-ignore -v AudioutCore/Sources/AudioutSharedUI/Resources/ClashDisplay-Semibold.otf build/font-cache/clash-display.zip
#   expected: ".gitignore:50:*.otf …" and ".gitignore:5:build/ …"
git status --short | grep -i "otf\|ClashDisplay\|font-cache"                    # expected: no output
# OWED to whoever builds the next .app (not this PR): after `APP_NAME="Audiout Dev" … bash scripts/make-app.sh`,
#   ls "build/Audiout Dev.app/Contents/Resources/ClashDisplay-Semibold.otf" && shasum -a 256 "build/Audiout Dev.app/Contents/Resources/ClashDisplay-Semibold.otf"
#   must print the e70dce86… hash, and the gate's "Welcome to Audiout" (once a later PR consumes wordmark) renders in Clash Display.
```

Then:

```bash
git add -A AudioutCore .gitignore scripts/make-app.sh scripts/fetch-wordmark-font.sh dev/notes/design-migration-scoping/PR1-tokens-work-order.md dev/notes/design-migration-scoping/PR1-pr-body.md
#   only these paths — the other untracked files in dev/notes/design-migration-scoping/ belong to the parent session
bash scripts/self-review.sh               # Guard 7; read the staged diff against docs/REVIEW-RUBRIC.md
git commit -m "Tokens: adopt the iPhone's cool ladders, alias the retired names, bundle the wordmark font

Re-values canvas/panel/raised/well/hairline/containerEdge to audiout-remote's
WarmSignal hexes in both appearances, adds rim/ring/labelCool/labelCool2/
goldText/emberText/liveRow/liveRaised/socket/meter/inkOnFill and
Tokens.Layout.Radius, and turns every retired or renamed token into a
deprecated alias so no surface changes in this commit. Deletes the
Follow-system accent position. ClashDisplay-Semibold is fetched by
scripts/make-app.sh at assembly (sha256-pinned, never in git — the ITF
licence forbids redistribution through a public repo) and read by
Tokens.Font.wordmark(size:) from Contents/Resources, with no consumer yet;
outside an .app it falls back to the system bold face. Every hex carries four variants and measured ratios; the contrast
suites are re-pinned to the new grounds.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
git push origin claude/macos-design-md-migration-059ffa
gh pr create --base main --head claude/macos-design-md-migration-059ffa \
  --title "Design migration PR 1: shared tokens + wordmark font" \
  --body-file dev/notes/design-migration-scoping/PR1-pr-body.md
```

Write `PR1-pr-body.md` (then commit it in the same commit, or amend before pushing) with: the
Goal paragraph, the "Interim visible effects" table verbatim, the Decisions D1–D10, the licence
note below, the verification output, and the footer
`🤖 Generated with [Claude Code](https://claude.com/claude-code)`. Do NOT merge the PR.

## Owed checks (do not block the PR; list them in the PR body)

- ClashDisplay licence. The font is the Indian Type Foundry's, "ITF Free Font License (FFL)
  Version 2.0 - 17 Aug 2026" (from Fontshare's own download package; the website page is
  JavaScript-only). What the public repo will contain is only `scripts/fetch-wordmark-font.sh`, a
  download script — permitted, since it distributes nothing of ITF's. The signed `.app` embeds the
  unmodified `.otf` — permitted by §01 ("You may embed the Font Software in mobile or desktop
  applications", personal or commercial use, free, worldwide); §02 forbids modification, subsetting
  or format conversion, none of which happens; §03's "cannot be extracted" clause is the one soft
  spot (a `.otf` inside `Contents/Resources` is copyable) — same posture as `audiout-remote`, which
  ships the identical file inside its `.ipa`. No credit is required (§01: "You may, but are not
  required to, identify or credit Indian Type Foundry or Fontshare"), but the `.otf`'s own name
  table (id 13) still reads "You agree to identify the ITF fonts by name and credit the ITF's
  ownership … in any design or production credits", so a "Clash Display by Indian Type Foundry"
  line in About is the safe reading — owned by the Settings PR. The licence text ships beside the
  font as `ClashDisplay-FFL.txt` regardless. Fontshare's API URL
  (`api.fontshare.com/v2/fonts/download/clash-display`) is not a published contract: the two
  sha256 pins are the guard (a re-packaged zip is tolerated, a changed `.otf` fails the build), and
  when the URL dies `AUDIOUT_WORDMARK_FONT=/path/to/ClashDisplay-Semibold.otf` (still checksummed)
  is the fallback. Alec to confirm (a)–(c): embed is permitted, public repo carries no font bytes,
  About credit line lands with Settings.
- The `emberText`/`goldText` Subtle light-IC coincidence (`#584C2E`) — Alec may want the
  emberText one pushed a step deeper.
- `inkOnFill` light-IC = white (D4) — a visible ink flip under Increase Contrast on paper.

## Hand-off to PR 3 (rows) and the other surface PRs

Assume these exist on `main` after PR 1: the Token table's new names (`rim`, `ring`, `labelCool`,
`labelCool2`, `goldText`, `emberText`, `liveRow`, `liveRaised`, `socket`, `meter`, `inkOnFill`,
`label2`, `label3`, `wireCore`, `party`, `partyRampDeep`), `Tokens.Layout.Radius.{control,row,panel}`,
`Tokens.Font.wordmark(size:)` (resolves the real face ONLY inside a `make-app.sh`-assembled `.app`;
`swift run`, `swift test` and every snapshot tool get the system bold fallback, so a wordmark
consumer is live-verified in a dev build, never by snapshot), and the deprecated aliases listed in
Step 1F. Each surface PR removes
the aliases it is the last consumer of (grep `Tokens.Color.<old>` across Sources AND Tests before
deleting an alias from Tokens.swift). `label` is still `.labelColor`; the rows PR decides where the
authored warm/cool ink lands. `WarmCanvasView` still contains dead gradient code and the dark grain —
the popover PR owns it. `WarmFaderCell` still draws the thumb from `faderThumb` (= `raised`) — PR 3
re-skins it with `raised` + `rim` per iOS `fader-track`/cap. The `hairline`-never-on-`raised` rule
is now measured; `GroupedSectionView`'s in-card dividers move to `containerEdge` in the Groups PR.
`ProminentButton` still measures white/black ink; the onboarding PR switches it to `inkOnFill`.
`AppTetherColor.neutralFallback` returns `rim` through the alias until C4 deletes the type;
`AppTetherColorTests.swift:316-317` still hardcodes the old `#16130F`/`#FBFBF9` grounds and
`AppTetherColor.swift:485-486` still says "`Tokens.Color.canvas` ≈ `#16130F`" — both stale on
purpose, C4 (PR 3) deletes the type and its suite.
