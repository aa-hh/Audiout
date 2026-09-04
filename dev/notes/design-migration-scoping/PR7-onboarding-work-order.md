# PR 7 work order: onboarding + the first-open licence gate

Executor: Opus, effort high. Every path is relative to the PR 7 worktree. All line numbers checked at HEAD `586bd8a2` (PR 1 committed) on 2026-09-03 and corrected by the spec check the same day; where PR 3 or PR 6 will have moved something, it says so. **Merge order: PR 3, then PR 6, then PR 7.** PR 6 owns `ProminentButton` wholesale (its move to `AudioutSharedUI`, its `gold` + `inkOnFill` ink, the removal of `picksInkFromFill`, and the argument drop at every call site); PR 7 does not touch that class.

## Goal

Bring `AudioutOnboardingUI` onto PR 1's token set: the licence gate's emitter field stops hand-blending its colour ramp and reads the shared `field.json` ramp; earned checkmarks go gold; the one filled-hue tile becomes a neutral tile like the other five; the folder's five corner radii collapse onto `Tokens.Layout.Radius.control`/`.row`; the two `goldCTA` reads become `gold` (the buttons themselves are PR 6's); the live setup row's fill becomes a gold wash; and the gate headline sets the product name in the wordmark face. Permission hues (C2), the six-step checklist (S3), the field's seven scenes (S4) and `DemoPaneView`'s shadows are kept deliberately.

## Scope fences — PR 7 must NOT touch

- No file outside `AudioutCore/Sources/AudioutOnboardingUI/`, `AudioutCore/Sources/AudioutSharedUI/Tokens.swift` (alias deletions only) and the test files named in the Test plan.
- `DemoPaneView.swift`: untouched. Its 27 radius literals and its shadows draw macOS's own windows (folder `AGENTS.md:23`, "an approved custom-drawn exception"); rounding them to our rungs would make the rehearsals stop looking like the dialogs they rehearse.
- `Tokens.Layout.groupedSectionCornerRadius` (Tokens.swift:1280) keeps its value and stays the default of `RoundedContainerView.init` — the Groups window's `GroupedSectionView` and `DemoPaneView.swift:1575` share it. Re-point call sites, never the token.
- Do not touch the permission hues, `permissionDynamic`, the checklist's structure or step count, the spine/hero geometry, row heights, insets, the window sizes, `LocalNetworkPrimer`, or any copy string.
- Do not edit `AudioutOnboardingUI/AGENTS.md` or `AGENTS-HISTORY.md` (PR 2/PR 9 own docs). List the stale lines in the PR body instead: `AGENTS-HISTORY.md:268` (`Tokens.Color.success`), `:653`, `:1093`, `:1272` (`warningText`), `:1054`, `:1057`, `:1059`, `:1061` (`goldCTA`, `picksInkFromFill`).
- Do not regenerate `dev/notes/window-snapshots`, `settings-snapshots`, `wizard-snapshots`, `popover-snapshots`.
- Do not add tracking/kerning to the gate headline, do not touch the browse-selection fill's `NSColor.selectedContentBackgroundColor`, do not touch the two status lines that already carry `Tokens.Color.failure` as TEXT (see Parked).
- `ProminentButton` (moved by PR 6 to `AudioutSharedUI`): untouched. `OnboardingChrome.swift:16`, `UsageStatsConsentCard.swift:42`, `SetupRibbonView.swift:490-493` and `LicenseGateViewController.swift:272-275` already have no `picksInkFromFill:` argument when this branch is cut (PR 6 dropped it); if the Pre-flight guard finds it, STOP.
- No cleanup, no abstractions, no error handling for impossible cases, no backwards-compat shims.

## Decisions recorded (do not re-open)

- **D1 REVERSED IN EXECUTION — the shared ramp is NOT used; the hand-authored ramp stays.** The decision as scoped was: `AudioutField.ramps["Chill out"]` carries one `lo`/`mid`/`peak` triple set and nothing appearance-specific, `paperLift` is the shared field's own answer to a light ground, so light mode stops inverting and the Mac authors no ramp at all. Step 1 was implemented that way and then reverted. Reason, from the adversarial review of the built branch (finding 1): this window never renders bright enough to reach the ramp's own stops. Re-implementing the fragment shader's mixes over 40 s of frames at this window's `stageScale` of 5 and the resting `.idle` scene gives a maximum light value of 0.34 in dark and 0.60 in light, against mixes that cross into `mid` at 0.4-0.8 and `peak` at 0.78-1.0. So the picture never gets past the `lo` stop. The shared dark `lo` (`#3E2F16`, luminance 0.035) is about 7x darker than the `ember` the hand-authored ramp starts from (`#A98341`, luminance 0.250), and dark ring-against-ground contrast measured 1.24:1 with the shared ramp against 2.76:1 with the authored one — the field effectively disappears. In light it never blooms gold at all: the rings run pale gold into near-black brown, with 1.5 % of the window above L 0.2. No test caught this, and no test could: the gate has no snapshot harness and `EmitterFieldTests` asserts geometry only. The Mac therefore keeps authoring this one ramp, and the shared file stays the source for every other number.
- **D2 REVERSED WITH D1 — the field still follows the accent dial.** The scoped decision was that the field stops following it, because the shared ramp is fixed hexes. With Step 1 reverted, `makeUniforms` reads `Tokens.Color.gold` again, so Subtle desaturates the field as it did before this PR, and `EmitterFieldView`'s `accentStyleDidChangeNotification` observer keeps doing real work.
- **D3 VOID WITH D1.** The scoped decision was that a missing `"Chill out"` key would be a `fatalError` in the shared package's idiom. With no ramp key read, there is nothing to trap.
- **D4 Wordmark run size = 25 pt** against the headline's 24 pt system bold. Method: `NSFont.capHeight` measured in this session with a `swiftc` probe over the real `.otf` (fetched read-only into the scratchpad by `scripts/fetch-wordmark-font.sh`): system bold cap-height ratio 0.70459, ClashDisplay-Semibold 0.670. System bold at 24 pt has cap 16.910 pt; 16.910 / 0.670 = 25.24 pt, so 25 pt gives cap 16.75 (0.16 pt / 1 % short) and 25.5 would give 17.09. 25 is the round number nearest the match. Consequence to accept: outside an assembled `.app`, `Tokens.Font.wordmark(size:)` returns `boldSystemFont(ofSize: 25)` (PR 1 hand-off), so under `swift run`, `swift test` and the snapshot tool "Audiout" renders 1 pt taller than "Welcome to". That is a dev-build-only artefact; the real face is only ever seen in a `make-app.sh` build.
- **D5 Two runs of one attributed string, not two labels.** The headline is centred and its two runs must sit on one baseline; a single `NSAttributedString` with a centred paragraph style gives that for free, where two labels would need their own baseline constraint. iOS sets the whole line in one face (`ConnectGateView.swift:723-725` in `audiout-remote`), so it has no recipe to copy here.
- **D6 The spine group's radius is the `row` rung (16).** Its corner IS the first and last row's corner (`SetupCardView.swift:186-188` says the group radius and the row focus ring are the same on purpose), so it rounds like a row, not like a floating panel.
- **D7 The preview well keeps 10, re-pointed to `Radius.control`.** It clips `DemoPaneView`'s mock macOS windows, which draw their own ~10 pt corners; a 16 pt frame around 10 pt content reads wrong, and 10 is a rung already.
- **D8 The status glyph's tint is derived in the view, not plumbed through the tuple.** `SetupRibbonView` already paints glyph and label from one colour (`:438`, `:443`); splitting the 4-tuple into a 5-tuple for one case is more surface than the rule needs. The rule instead: a status glyph is `failure` when its symbol is the alert triangle, and takes the line's own colour otherwise.
- **D9 The permission-lost header subtitle takes `label2` with no glyph** (`OnboardingViewController.swift:1715`). The header has no glyph slot and adding one is new construction; the headline swap ("Let's get your sound back") and the broken row's own red edge bar + `failure` triangle already carry the alarm.
- **D10 The skipped-row marker glyph takes `label2`.** A skipped step is a user's choice, not a problem, so it gets no `failure` tint.

## Verified facts

Baseline observed in this session (worktree at HEAD `586bd8a2`, clean tree):

```
bash scripts/build.sh                                    → "compiled clean on remote …", exit 0
AUDIOUT_TEST_NO_CACHE=1 bash scripts/run-tests.sh --filter 'OnboardingUITests|OnboardingPermissionColorTests|SetupUsageStatsTests|LicenseGateTests|EmitterFieldTests|BrandMarkTests'
                                                         → "Test run with 197 tests in 7 suites passed"
```

**The shared field**
- `AudioutField.ramps` is `public static let ramps: [String: FieldRamp]` (`AudioutCore/.build/checkouts/audiout-shared/Sources/AudioutField/Field.swift:56`); `FieldRamp` is `public struct FieldRamp: Decodable, Sendable` with `public let lo: [Double]`, `mid`, `peak` (`:39-43`) — RGB triples in 0…1, not colours.
- `field.json` (`…/Sources/AudioutField/field.json`, schema 1) carries exactly three ramps: `"Movie night"`, `"Chill out"`, `"Dinner party"`. `"Chill out"` = lo `[0.243, 0.184, 0.086]`, mid `[0.91, 0.722, 0.294]`, peak `[1.0, 0.851, 0.478]` — i.e. `#3E2F16`, `#E8B84B`, `#FFD97A`. Its mid is byte-identical to PR 1's Full dark `gold` and its peak to dark `glow` (PR 1 Token table).
- `EmitterFieldView.swift` already `import AudioutField` (`:5`). The hand-blend is `makeUniforms` (function `:498-547`; the `performAsCurrentDrawingAppearance` block `:504-527`): `let accent = Tokens.Color.gold` (`:508`), `bg` from `canvas` (`:509`), `lo` from `ember` or a 0.6-white blend, `mid` = gold, `peak` a 0.25-white or 0.55-black blend. `components(of:)` at `:559-564` converts an `NSColor` to `SIMD3<Float>`.
- The ramp reaches the shader as four uniforms `bg`/`lo`/`mid`/`peak` (`:492-495`, MSL struct `:610-613`, mixed at `:692-695`). No shader change is needed.
- `stageScale = 5` at `:139`; `Scene` enum at `:58-73`; both stay (S4).
- No test asserts the ramp or a scene: `EmitterFieldTests` has 10 tests, all over `AudioutField.defaults` and the composition (`:35, :41, :47, :53, :59, :70, :89, :105, :123, :138`). The four pinned-geometry ones named in the brief are `noSourceReachesTheMiddleOfTheStage` (`:89`), `everySourceStaysOutsideTheFrameAcrossItsOrbit` (`:105`), `everyFanReachesWellInsideTheFrame` (`:123`), `theCalmZoneCoversTheWholeButtonRow` (`:138`) — none touches colour.

**Tokens available (PR 1, at HEAD)**
- `label2` `Tokens.swift:113` (`static let`), `gold` `:471`, `inkOnFill` `:627`, `Radius.control/row/panel` `:1288-1294`, `groupedSectionCornerRadius = 10` `:1280`, `panelCornerRadius = 12` `:1270`.
- Deprecated aliases in play: `success → gold` and `goldCTA → gold` (`Tokens.swift:1082` for `goldCTA`), `warningText → label2` (`:1052`), `accent → gold`.
- `PopoverColumnGrid.rowLiveWashAlpha` does NOT exist at HEAD — PR 3 adds it as `public static let rowLiveWashAlpha: CGFloat = 0.12` (PR 3 order, step 13.2), measured 1.256:1 on dark `panel` and 1.140:1 on the light ground. PR 3's hand-off explicitly licenses PR 7 to reuse it.

**Alias consumers (grep of `AudioutCore/Sources` + `AudioutCore/Tests`, this session)**
- `Tokens.Color.success`: `SetupCardView.swift:311`, `SetupCheckRowView.swift:66`. Both are PR 7's → **the alias retires here.** No test names it (PR 1 deleted `successClearsTheUIFloorInBothAppearances`).
- `Tokens.Color.warningText`: `OnboardingViewController.swift:1380, 1390, 1414, 1438, 1459, 1715`, `SetupCardView.swift:323` (PR 7's), **and `AudioutSettingsUI/AudioSettingsViewController.swift:639`** (PR 6 re-points it). Rule: whichever of PR 6 / PR 7 merges SECOND deletes the alias, after a grep proves zero code consumers (Step 9).
- `Tokens.Color.goldCTA`: `LicenseGateViewController.swift:273`, `SetupRibbonView.swift:492`, **and `OnboardingViewController.swift:2253`** (the `test_doneIsGoldProminent` hook — a third code consumer PR 6's grep missed, also PR 7's). Non-code mentions after PR 7: doc comments at `OnboardingChrome.swift:88`, `SetupRibbonView.swift:485`, and in `AudioutPopoverUI` (`AlignmentPlateButton.swift:75`, `AlignmentPlateCell.swift:99, 180, 201, 242, 468, 470, 474`) plus `AlignmentPlateCellTests.swift:56`. So all three CODE consumers are PR 7's and **the alias retires here** — confirming PR 6's finding.
- `Tokens.Color.accent`: `OnboardingChrome.swift:99` (`ProminentButton`'s default fill — PR 6's now, since PR 6 owns the class), `AppearanceSettingsViewController.swift:365` (PR 6's), `DeviceRowView.swift:2967` (PR 3's, in `AudioutSharedUI`), `BTRowsUITests.swift:278`, plus comments at `EmitterFieldView.swift:505` (deleted by Step 1.3). → **PR 7 has no `accent` consumer; the alias is deleted by whichever of PR 3 / PR 6 merges second.**

**Files being edited**
- `ProminentButton` is PR 6's (see header). At HEAD it is at `OnboardingChrome.swift:77-208`; after PR 6 it lives in `AudioutSharedUI` with `gold` fill + `inkOnFill` ink and no `picksInkFromFill`. PR 7 only re-points the two `goldCTA` fill arguments (Steps 5.1, 8.1) and the `test_doneIsGoldProminent` hook (6.4).
- `IconTileView` `OnboardingChrome.swift:248` (init `:261-267`): `cornerRadius: CGFloat = 7` (`:267`), `updateLayer` (`:297-303`) paints `raised` fill (`:298`) + **`hairline`** border (`:299`); the class doc `:235` says "with a hairline rim" and `:237-238` contrasts it with Groups' `containerEdge`. PR 1 measured `hairline` on `raised` at 1.154:1 and banned it; `containerEdge` is the card-edge token. Three call sites: `SetupCheckRowView.swift:27`, `SetupCardView.swift:293`, `OnboardingPermissionColorTests.swift:269`. iOS's equivalent (`audiout-remote` `AudioutRemote/UI/Apps/AppGlyph.swift:51, 55, 59`) rounds at `WarmSignal.Radius.control`.
- `SetupCardView.swift`: `cornerRadius = 9` (`:188`), used at `OnboardingViewController.swift:284` and `SetupCardView.swift:662`; checkmark tint `:311`; skip marker tint `:323`; `applySurface()` `:504-530` with the live arm `fill = Tokens.Color.raised` (`:510`; `:512` is the browse-selection arm) and `dynamicBlend` (declared `OnboardingChrome.swift:46`) used for the broken and browse arms.
- `UsageStatsConsentCard.swift`: `layer?.cornerRadius = 12` (`:64`); the filled tile `RoundedContainerView(fill: permissionUsageStats, border: .clear, radius: 13)` + a separate white-tinted `NSImageView` glyph at pointSize 26 (`:71-78`), constrained at `:117-122` (four constraints: tile w/h at `tileSide = 56`, glyph centre x/y); card fill `panel` with NO border today (`:64-65`).
- `SetupRibbonView.swift`: primary button `:485-493`; `SetupPreviewFrameView.cornerRadius = 10` (`:162`) used for the `well` container at `:178-180`; status render `:435-446`.
- `LicenseGateViewController.swift`: headline `:121-124` (`NSTextField(labelWithString: "Welcome to Audiout")`, `Tokens.Font.displayLarge` = `.systemFont(ofSize: 24, weight: .bold)`, `Tokens.swift:1203`; `textColor = Tokens.Color.label`; `.center`; AXHeading subrole at `:125-126`); `goldButton` `:271-277`. `LicenseGateTests.swift:474` is `theContentColumnClearsTheBottomButtonRow`, which lays the gate out at its fixed 560 × 440 and asserts the centred column clears the bottom button row — the one test the headline's metrics can move.
- `OnboardingViewController.swift:378-380`: hero pane `RoundedContainerView(… radius: 12)`. `alertSymbol = "exclamationmark.triangle.fill"` at `:1312`. The usage-stats step's `spineAskTitle` is `"Usage statistics"` (`:810`).
- Snapshot harness: `AudioutCore/Sources/onboarding-snapshot/main.swift`, run as `swift run onboarding-snapshot [output-dir]` (`main.swift:35`). It mounts the Setup window only — grep for `LicenseGate`/`EmitterField` in it returns nothing, so **the gate has no snapshot harness**. `dev/notes/onboarding-snapshots/` holds **28** PNGs (the scoping report's "26" is wrong), including `…-step6-usagestats` renders that show the consent card on the rehearsal stage (`main.swift:376`).

## Steps

Run `bash scripts/build.sh` after Step 3, Step 6 and Step 9.

### Step 1 — `EmitterFieldView.swift`: the shared ramp

1.1 Add a private static stored constant holding the `"Chill out"` `FieldRamp`, resolved once from `AudioutField.ramps` in an immediately-applied closure that `fatalError`s when the key is absent, with a message in the shared package's voice (naming the key and saying the shared field package is broken). Place it beside `baseGain` (`:143`), which is the other value read straight from the shared file.

1.2 Add a private static function converting a `FieldRamp` stop (`[Double]`, three elements) to `SIMD3<Float>`, next to `components(of:)` (`:559`). It indexes 0/1/2 — the shared type guarantees three (`Field.swift:40-42`); do not add a count guard.

1.3 In `makeUniforms` (block `:504-527`) delete the `let accent` line (`:508`), the whole `effectiveAppearance.performAsCurrentDrawingAppearance` block's four blend expressions and the three explanatory comments at `:505-507`, `:510-513`, `:518-523` (NOT `:524`, which is the `peak =` code line). `bg` still comes from `Tokens.Color.canvas` resolved inside `performAsCurrentDrawingAppearance` (it is the only appearance-dependent value left); `lo`, `mid`, `peak` come from the ramp constant through 1.2 and need no appearance block. Keep `isLight`, which still feeds `lightMode` (`:540`).

1.4 Rewrite the type doc comment's ramp sentences (`:13-16` and `:24-26`): the ramp is no longer per-surface and no longer authored — the field now reads `lo`/`mid`/`peak` from the shared `"Chill out"` ramp in both appearances, the only appearance-dependent value is `bg` (`canvas`), and light is handled by the shared `paperLift` rather than by inverting the stops. `stageScale` is still the ONE declared deviation; say so unchanged. Add one sentence recording D2: the field no longer follows the accent dial.

### Step 2 — `SetupCardView.swift`

2.1 `:311` checkmark tint `Tokens.Color.success` → `Tokens.Color.gold`.

2.2 `:323` skip-marker tint `Tokens.Color.warningText` → `Tokens.Color.label2` (D10).

2.3 `:188` `static let cornerRadius: CGFloat = 9` → `Tokens.Layout.Radius.row`, and extend the existing doc comment with D6's one-line reason.

2.4 R4, `applySurface()` `:510`: the live arm's `fill = Tokens.Color.raised` becomes `dynamicBlend(Tokens.Color.panel, fraction: PopoverColumnGrid.rowLiveWashAlpha, of: Tokens.Color.gold)`. `dynamicBlend`, not a direct blend, for the reason the method's own doc gives (`:501-503`). Rewrite the doc paragraph at `:488-498`: the live row is a gold wash at the app's shared live alpha (12 %, the same one every sounding device row paints, PR 3 D1), measured 1.256:1 on dark `panel` and 1.140:1 on the light ground; the broken row still overrides with the failure tint; the retired ember edge bar does not come back. The 2026-08-12 "ember, not gold" ruling is superseded by F4/R4 — say that in the comment rather than deleting the history.

### Step 3 — `SetupCheckRowView.swift`

`:66` `Tokens.Color.success` → `Tokens.Color.gold`. Its file doc (`:20-24`) already says gold is the finale's colour; add nothing.

### Step 4 — `OnboardingChrome.swift`

4.1 `IconTileView.updateLayer` `:299`: `Tokens.Color.hairline` → `Tokens.Color.containerEdge`. REWRITE the class doc sentence at `:235` ("with a hairline rim" → "with a `containerEdge` rim") and the contrast at `:237-238` so it no longer opposes Groups' `containerEdge`; add the rule in one line: a tile's own edge is `containerEdge`; `hairline` is never drawn on `raised` (1.154:1, PR 1).

4.2 `IconTileView.init` `:267`: `cornerRadius: CGFloat = 7` → `Tokens.Layout.Radius.control`, and update the parameter's doc to cite the iOS glyph tile (`AppGlyph.swift:51`).

4.3 (Removed — PR 6 owns `ProminentButton`.) Do not edit the class or its former location. If `grep -rn picksInkFromFill AudioutCore/Sources` returns anything at branch time, PR 6 has not merged: STOP.

### Step 5 — `SetupRibbonView.swift`

5.1 **(Done by PR 6 — verify only.)** PR 6 deleted `ProminentButton`'s `fill:` parameter entirely, so this call site no longer passes `goldCTA` or any fill. Confirm with `grep -n 'goldCTA\|picksInkFromFill' AudioutCore/Sources/AudioutOnboardingUI/SetupRibbonView.swift` — expect no output. If either appears, PR 6 has not merged: STOP. Rewrite the comment `:485-489` only if it still names `goldCTA` or a measured ink.

5.2 `SetupPreviewFrameView.cornerRadius` `:162` → `Tokens.Layout.Radius.control`, with D7's reason as a one-line comment.

5.3 Status glyph tint, `:440-444`: the glyph's `contentTintColor` becomes `Tokens.Color.failure` when `symbolName` is the alert triangle and `status.color` otherwise (D8). Compare against a private constant in this file holding the literal `"exclamationmark.triangle.fill"` — do not import `OnboardingViewController`'s. Add a two-line comment: the triangle is the problem mark and always carries the problem hue, while the line's own text is ordinary secondary ink because `failure` is barred from body text (PR 1 D2: 4.04:1 on dark `raised`).

### Step 6 — `OnboardingViewController.swift`

6.1 `:1380`, `:1390`, `:1414`, `:1438`, `:1459`: `Tokens.Color.warningText` → `Tokens.Color.label2`. (`:1390` has no glyph — it is the spinner line — and `:1459` carries `"slash.circle"`, so both read as plain secondary text; the other three carry the alert triangle and get the red glyph from 5.3.)

6.2 `:1715` → `Tokens.Color.label2` (D9).

6.3 `:380` hero pane `radius: 12` → `Tokens.Layout.Radius.row`.

6.4 `:2253` `Tokens.Color.goldCTA` → `Tokens.Color.gold`; the doc at `:2242-2246` (the name is at `:2243`) loses the `goldCTA` name.

### Step 7 — `UsageStatsConsentCard.swift`

7.1 `:64` `layer?.cornerRadius = 12` → `Tokens.Layout.Radius.row`. Add a `layer?.borderColor = Tokens.Color.containerEdge.cgColor` and `layer?.borderWidth = 1` in the same `updateLayer` (the card is a card on a panel and needs its own edge; Rule 5). Extend the method's existing doc (`:53-60`) with one sentence naming `containerEdge` as the card's own edge.

7.2 `:71-78`: delete the `RoundedContainerView` tile and the separate `glyph` image view; build one `IconTileView(symbolName: "chart.bar.xaxis", accessibility: "Usage statistics", color: Tokens.Color.permissionUsageStats, side: Self.tileSide, pointSize: 26)` — the accessibility string is the step's own `spineAskTitle` (`OnboardingViewController.swift:810`), the tile is the same construction as the spine row's (`SetupCardView.swift:293-298`). Delete the four constraints at `:119-122` (`IconTileView` constrains its own side and centres its glyph, `OnboardingChrome.swift:286-291`); keep the leading/top constraints at `:117-118` and every constraint that references `tile` afterwards. Rewrite the comment at `:69-70`: the tile is the neutral one every other step wears — only the glyph carries the identity hue (Q3), and the filled hue tile with white ink is retired.

### Step 8 — `LicenseGateViewController.swift`

8.1 **(Done by PR 6 — verify only.)** PR 6 deleted the `fill:` parameter, so this call site no longer passes it. Confirm with `grep -n 'goldCTA\|picksInkFromFill' AudioutCore/Sources/AudioutOnboardingUI/LicenseGateViewController.swift` — expect no output; if either appears, PR 6 has not merged: STOP.

8.2 Headline `:121-124` (F6, the Name Only Rule): keep the `NSTextField(labelWithString:)` and its AX role/subrole lines, but set `attributedStringValue` to a two-run attributed string instead of `.font` — "Welcome to " in `Tokens.Font.displayLarge`, "Audiout" in `Tokens.Font.wordmark(size: 25)`, both with `.foregroundColor: Tokens.Color.label` and a shared centred paragraph style (`alignment = .center`) applied over the whole range. Leave `headline.alignment = .center` where it is; DELETE the `.font` and `.textColor` assignments at `:122-123` (an `attributedStringValue` supersedes both; keeping them would be dead code). Add a doc comment recording D4 and D5: only the product name is set in the wordmark, at 25 pt so its cap height matches the 24 pt system bold run (0.670 vs 0.70459 cap ratio, measured), and outside an assembled `.app` the face falls back to system bold at that size.

### Step 9 — `Tokens.swift`: retire two aliases

Delete the `success` and `goldCTA` entries from the deprecated block (find them by name — PR 3 and PR 6 both shrank the block, so the line numbers have moved). NOTE: after PR 6, `goldCTA` has exactly ONE code consumer left — `OnboardingViewController.swift:2253` — which Step 6.4 re-points; PR 6 removed the other two by deleting the `fill:` parameter. Before deleting each, run `grep -rn "Tokens.Color.success\|Tokens.Color.goldCTA" AudioutCore/Sources AudioutCore/Tests` and confirm the only remaining hits are doc-comment prose in `AudioutPopoverUI` and `AlignmentPlateCellTests.swift:56`. **If any code hit remains, STOP and report.** Then `grep -rn "Tokens.Color.warningText" AudioutCore/Sources AudioutCore/Tests`: if it returns nothing (PR 6 already re-pointed `AudioSettingsViewController.swift:639`), delete the `warningText` alias (`:1052`) too; if it returns that one line, leave the alias and say so in the PR body. Leave `accent` (`:1080`) in place (PR 3 / PR 6 own its consumers).

## Ratio table (nothing new is authored)

| what | value | source |
|---|---|---|
| live setup row wash | `gold` @ 0.12 over `panel` — 1.256:1 dark, 1.140:1 light | PR 3 order §13.2 |
| gold checkmark on `raised` | 8.55:1 dark, 3.64:1 light (Subtle 5.91 / 3.95) | PR 1 Token table; pinned by `OnboardingPermissionColorTests.goldOnRaisedClearsTheGlyphFloor…` |
| `inkOnFill` on `gold` | 10.18 dark, 4.94 light, 5.26 light-IC (white) | PR 1 Token table |
| `containerEdge` on `raised` (tile rim) | 1.55:1 dark, 2.02:1 light | PR 1 Token table |
| `label2` status text on `panel` | 7.99:1 dark, 5.97:1 light | PR 1 Token table |
| ramp stops | `#3E2F16` / `#E8B84B` / `#FFD97A` | `field.json`, measured this session |

## Interim visible effects this PR finalises

From PR 1's table: `success→gold` (`SetupCheckRowView.swift:66`, `SetupCardView.swift:311`) — closed, checkmarks are gold by name now. `goldCTA→gold` (`LicenseGateViewController.swift:273`, `SetupRibbonView.swift:492`, `OnboardingViewController.swift:2253`) — closed (the ink itself was closed by PR 6). `warningText→label2` — closed for this folder; `AudioSettingsViewController.swift:639` is PR 6's.

Introduced: the gate field's colours no longer move with the accent dial (D2); the light gate field stops inverting (D1).

## Test plan

- **`EmitterFieldTests`** — no edit. All ten tests are over `defaults` and the composition; none reads a colour. They are the guard that Step 1 did not disturb `stageScale` or the geometry.
- **`OnboardingPermissionColorTests`** — no edit needed for correctness (nothing asserts a tile BORDER; `tileFillIsAlwaysTheNeutralRaisedWell` at `:264-273` asserts the fill only, which is unchanged). Optional and recommended: extend that test's doc comment (`:264-266`) with one clause naming `containerEdge` as the rim. Do not add an assertion — PR 1 already pins `containerEdge` vs `raised` in `MembershipWellContrastTests`.
- **`OnboardingUITests`** — no edit expected. `:1430` builds a `ProminentButton` with defaults and only checks `acceptsFirstMouse` (PR 6 already dropped any `picksInkFromFill:` argument there); `:2600` checks the broken row's edge bar is `failure`, which R4 does not touch. Run it: it is the suite that would catch a live-row regression.
- **`SetupUsageStatsTests`** — no edit; it names no colour, tile or radius. Run it: it is the guard that Step 7's constraint deletion did not break the card's layout or its buttons.
- **`LicenseGateTests`** — no edit. `theContentColumnClearsTheBottomButtonRow` (`:474`) is the one test the headline change can move (the wordmark run's fallback is 1 pt taller than the rest of the line under `swift test`). If it fails, that is a real overlap — STOP and report rather than relaxing the assertion.
- **`BrandMarkTests`** — no edit; run it for `Tokens.Font.wordmark`'s fallback pin added by PR 1.
- Snapshots: re-render all 28 `dev/notes/onboarding-snapshots/*.png`; there is no golden compare, so nothing can fail. Commit them.

## Verification

```bash
bash scripts/build.sh
#   expected: exit 0, "compiled clean"; deprecation warnings for warningText/accent only
AUDIOUT_TEST_NO_CACHE=1 bash scripts/run-tests.sh --filter 'OnboardingUITests|OnboardingPermissionColorTests|SetupUsageStatsTests|LicenseGateTests|EmitterFieldTests|BrandMarkTests'
#   expected: 197 tests in 7 suites pass (the pre-change baseline; this PR adds and deletes none)
AUDIOUT_TEST_NO_CACHE=1 bash scripts/run-tests.sh        # full suite, green
grep -rn "Tokens.Color.success\|Tokens.Color.goldCTA" AudioutCore/Sources AudioutCore/Tests
#   expected: only doc-comment prose in AudioutPopoverUI + AlignmentPlateCellTests.swift:56
grep -rn "picksInkFromFill\|measuredKeyInk" AudioutCore/Sources AudioutCore/Tests
#   expected: no output (PR 6 removed both; a hit means this branch was cut before PR 6 merged)
grep -rn "Tokens.Color.warningText" AudioutCore/Sources
#   expected: no output, OR exactly AudioSettingsViewController.swift:639 if PR 6 has not merged (then the alias stays; see Step 9)
grep -rn "cornerRadius: CGFloat = 7\|cornerRadius: CGFloat = 9\|cornerRadius = 12\|radius: 12\|radius: 13" AudioutCore/Sources/AudioutOnboardingUI --include='*.swift' | grep -v DemoPaneView
#   expected: no output (the pattern deliberately excludes the `iconGap`/`gap = 9` spacing constants, which are not radii)
swift run --package-path AudioutCore onboarding-snapshot dev/notes/onboarding-snapshots
git status --short dev/notes/onboarding-snapshots        # expected: 28 modified PNGs
git status --short dev/notes/window-snapshots dev/notes/settings-snapshots dev/notes/wizard-snapshots dev/notes/popover-snapshots
#   expected: no output
```

Done = every command above run in the executor's session with the stated output pasted.

## Owed checks (Alec, in a `make-app.sh` build — this PR needs no dev build or live-test slot)

1. **The light-mode gate field** (D1) — the shared ramp now runs on white ground: crests read dark warm before blooming gold. This is the change most likely to be rejected by eye.
2. The dark gate field, which should be indistinguishable from today at the Full-gold dial and slightly warmer at Subtle (D2).
3. **The gate headline in the real face** — "Welcome to Audiout" with only the name in Clash Display at 25 pt. This cannot be checked by snapshot or by `swift run`; both get the system-bold fallback.
4. The live setup row's gold wash at 12 % against the browsing and broken rows in both appearances.
5. The consent card's tile: neutral raised with a `containerEdge` rim and a green-tinted glyph, beside the five spine tiles.

## Parked (tempting, deliberately not in this PR)

- The two status lines that set `Tokens.Color.failure` as TEXT (`OnboardingViewController.swift:1397`, `:1423`). PR 1 D2 records that `failure` is never body text (4.04:1 on dark `raised`), so after this PR the ribbon carries two grammars: some problem lines are grey text with a red triangle, others are red text with a red triangle. One sentence for the parent: I think those two should move to `label2` with the same red glyph, but the prompt's list names only `warningText` consumers, so I scoped what was asked.
- `NSColor.selectedContentBackgroundColor` in the browse-selection and hover blends (`SetupCardView.swift:511-517`) — a system colour the popover replaced with `engagedChrome`.
- `inkSecondary`/`secondaryLabel`/`tertiaryLabel` call sites in this folder (they compile through aliases with 100+ consumers repo-wide).
- Tracking on the wordmark run (iOS uses −0.7 at 32 pt); the `AGENTS-HISTORY.md` lines listed under Scope fences.

## Coordination with PR 6 (`ProminentButton`) — merge order PR 6 then PR 7

PR 6 owns `ProminentButton` wholesale: it moves the class to `AudioutSharedUI`, makes its fill `gold` and its key ink `inkOnFill`, deletes `picksInkFromFill`/`measuredKeyInk` and their observers, and drops the argument at all four onboarding call sites plus `OnboardingUITests.swift:1430`. PR 7 branches AFTER PR 6 merges. Pre-flight guard (add to the worktree steps):

```bash
grep -rn "final class ProminentButton" AudioutCore/Sources/AudioutSharedUI   # must hit
grep -rn "picksInkFromFill" AudioutCore/Sources AudioutCore/Tests               # must be empty; else PR 6 not merged → STOP
```

- `goldCTA`'s three code consumers are all PR 7's (see Verified facts), so Step 9 deletes the alias; PR 6 does not.
- `warningText`: PR 6 re-points `AudioSettingsViewController.swift:639`; PR 7 re-points the seven onboarding lines; the second to merge deletes the alias (Step 9).

## Requests to PR 3

None beyond consuming `PopoverColumnGrid.rowLiveWashAlpha`, which PR 3's hand-off already licenses. Pre-flight guard: `grep -n "rowLiveWashAlpha" AudioutCore/Sources/AudioutSharedUI/PopoverColumnGrid.swift` must return a hit before Step 2.4 — if it does not, PR 3 has not merged and this branch was cut too early. STOP.

## Hand-off to the remaining PRs

- `accent` alias survives PR 7 (PR 3 / PR 6 own its consumers). `warningText` is deleted here if PR 6 has already re-pointed `AudioSettingsViewController.swift:639`, else it survives for PR 6 to delete.
- `goldCTA` is gone as a symbol. Doc-comment prose still names it in `AudioutPopoverUI` (`AlignmentPlateButton.swift:75`, `AlignmentPlateCell.swift:99, 180, 201, 242, 468, 470, 474`) and `AlignmentPlateCellTests.swift:56` — the wizard/popover PR rewords them.
- `ProminentButton` (PR 6's) already gives any prominent button `gold` + `inkOnFill` from its defaults; PR 7 adds no button.
- `IconTileView` now rims in `containerEdge` at `Radius.control` for all four call sites.
- PR 9's DESIGN.md should record: the Mac gate field reads the shared `"Chill out"` ramp verbatim in both appearances and is the one surface with no dial-aware colour; the gate headline is the Mac's only wordmark consumer today.

## Execution plan

**One track, SERIAL after PR 3 AND PR 6 merge** (Step 2.4 consumes `PopoverColumnGrid.rowLiveWashAlpha` from PR 3; Steps 5.1/8.1 assume PR 6 already dropped the `picksInkFromFill:` argument). Files: the nine listed under Scope, all inside `AudioutOnboardingUI` plus two alias deletions in `Tokens.swift` and 28 snapshot PNGs — disjoint from every other surface PR except the `Tokens.swift` deprecated block, where each surface PR deletes only the rows it owns (a merge-time textual conflict at worst, resolved by union).

- **Model: opus. Effort: high.** Not because any single edit is hard, but because two of the nine steps are judgement under a rule the compiler cannot check: Step 1 rewires a Metal uniform path where a wrong stop order silently produces a plausible-but-wrong picture nothing tests; Step 8.2 replaces a plain label with a two-run attributed string under a layout test that measures the resulting column height. A cheaper model will pass the suite on either while getting the picture wrong.
- No dev build, no live-test slot, no `make-app.sh`.
- The branch carries no uncommitted work the track depends on; cut the worktree from `origin/main` after PR 3 and PR 6 merge: `git worktree add .claude/worktrees/<slug> -b claude/<slug> origin/main && git push -u origin claude/<slug> && git config core.hooksPath .githooks`.

## Executor rules (copy verbatim into the handoff prompt)

> - Follow the steps in order. Do not add, merge, reorder, or skip steps.
> - Before editing in any folder, read the nearest AGENTS.md above it (and the root one) if the repo has them — folder rules and traps bind even when the work order doesn't repeat them.
> - If reality contradicts a Verified fact or a step is impossible as written, STOP and report the discrepancy. Do not improvise a workaround.
> - Before reporting progress, audit each claim against a tool result from this session. Only report work you can point to evidence for. If tests fail, say so with the output.
> - "Done" means the Verification commands were run in this session and passed. Paste their output.
> - Touch nothing in the Out-of-scope list.
> - Deliver what was asked, at the scope intended. If the spec seems mistaken or a better approach exists, say so in a sentence and continue as specified rather than quietly narrowing, widening, or transforming it.
