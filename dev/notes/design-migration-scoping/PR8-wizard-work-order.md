# PR 8 work order: the speaker-sync wizard, its stage and the sync drawer

Executor: Opus. New branch `claude/design-wizard` from `origin/main` AFTER PR 3 (rows) merges; worktree `.claude/worktrees/design-wizard`. Every path below is relative to that worktree. Every ratio below was computed with the WCAG 2.x relative-luminance formula by `scratchpad/contrast.py` during scoping (2026-09-03) or quoted from PR 1's Token table; the executor may cite them without recomputing. Line numbers were checked at HEAD `586bd8a2` (PR 1 committed); PR 3 does not touch any file in this slice, so they hold after it merges.

## Goal

Magenta leaves the wizard (C1/R1): the reference light, its halo, its name stamp, its plate rim and its keycap chip ink move from `party`/`partyRampDeep` to `ring` (steel blue), fixed on the stage like the other stage tokens. The plates keep their tinted rims and chips (S5), now green and blue. The rung-promotion flash stops spending gold (S6): it flashes `stageInk`, so the stage carries no gold except its CTA plate. Radii collapse onto the iOS three (control 10 / row 16). The keycap chip stops drawing the word "SPACE" in a monospaced face (iOS One Case); the bare 15 pt plate title and both readouts get named `Tokens.Font` roles at the iOS readout weight. The deprecated aliases this slice is the last consumer of (`plateRim`, `inkOnGold`, `syncSignal`, `partySignal`, `partySignalDeep`) are deleted. The sync drawer gains a 1 pt `containerEdge` rim so the recess reads by edge on the flat light ground. Nothing else on these surfaces changes: the fixed dark stage plate, `fuseWhite`, the two hard half-bars, the plate bevels, the stock drawer buttons and every piece of geometry stay.

## Scope fences — PR 8 must NOT touch

- Files: only `AudioutCore/Sources/AudioutPopoverUI/{AlignmentStageView,AlignmentWizardViewController,AlignmentPlateCell,AlignmentPlateButton,BTAlignmentWizardView,BTAlignmentNoteView}.swift`, `AudioutCore/Sources/AudioutPopoverUI/AGENTS.md`, `AudioutCore/Sources/AudioutSharedUI/{BTSyncDrawerView,Tokens,PopoverColumnGrid}.swift`, the five test files in the Test plan, and `dev/notes/design-migration-scoping/PR8-*.md`. `AlignmentPlateButton.swift` gets ONE doc-comment edit (Step 6.6); `SyncValueFieldEditor.swift` needs no edit (zero `Tokens.` hits) — leave it.
- `PopoverColumnGrid.swift`: ONE constant (`alignPlateCornerRadius`, Step 1). PR 3's fences release it to this PR ("`alignPlateCornerRadius` (12): the wizard PR's", PR3-rows-work-order.md:22). No other constant in that file.
- `Tokens.swift`: only (a) `Font.keycap`'s face, (b) `Font.syncReadout`'s weight, (c) add `Font.plateTitle`, (d) delete the five aliases Step 9 names, (e) the doc-comment edits Steps 2 and 9 name. `party`, `partyRampDeep`, `syncSignalDeep`, `wireCore` keep their values (PR 5 consumes `party`).
- Geometry (S2): no plate sizes (236×88 / 220×64 / 400×36 / 160), no chip sizes (22×22, 44×20), no stage height (132), no drawer insets, no `stageHeight`/`horizontalInset`/halo sizes. A radius is not geometry.
- The stage's span shadow (`spanLayer.shadowColor`/`shadowOpacity`/`shadowRadius`, AlignmentStageView.swift:1666-1667 and the `look.spanShadowRadius` table :208-281) STAYS. It is the "two hard half-bars with a low fuseWhite glow" the brief keeps; lamp falloff and every stage-glow question are PARKED with it. Only the detent's peak COLOUR changes (Step 3.4).
- `haloImage(color:)` (:1689-1704) keeps its two-stop alpha falloff — lamp falloff is parked.
- The fused ring's `×0.85` opacity (AlignmentStageView.swift:1076-1081) keeps its value; only its comment changes (Step 3.6).
- `primaryFillColor`'s pinning idiom, the bevels, the hover wash, `faderDisabledAlpha` dimming, `primaryRimColor` (AlignmentPlateCell.swift:233-259): unchanged.
- Drawer buttons stay STOCK (`.rounded` bezels, `Tokens.Font.caption`, `label`/`label2` tints); drawn drawer controls are parked. Align-by-ear on-state stays `engagedChrome` (BTSyncDrawerView.swift:447, :535).
- No `make-app.sh`, no livetest slot, no dev build. No regeneration of any PNG under `dev/notes/` (`dev/notes/wizard-v2-handoff/*.png` are the wizard's only committed images and are never regenerated).
- No `.impeccable`, no `DESIGN.md`, no `PRODUCT.md`, no `docs/`, no `ROADMAP.jsonl`, no `dev/notes/wizard-stage-v2-spec.md`, no `HANDOFF-wizard-v2.md` (stale by design), no `AGENTS-HISTORY.md` (archived). PR 9 owns docs — see Hand-off.
- `DeviceRowView.swift:922` names `partySignal` in a comment (the Mixer EQ mark) — PR 5's/PR 9's, not this PR's.
- No cleanup, no abstractions, no error handling for impossible cases, no backwards-compat shims. A token or parameter that loses its last consumer is deleted, not kept.
- Do not edit any other file in `dev/notes/design-migration-scoping/`.

## Decisions recorded (the executor does not re-open these)

- **D1 The stage's reference light is `ring`'s DARK hex in both appearances (`#7FB4C4`).** The stage is a fixed instrument (owner ruling §0 #1; `wireCore` and every other stage token pass one hex for both appearances, Tokens.swift:938-951). `ring` is themed (Tokens.swift:367-370: light `#2C6E86`), and measured on `stagePlate` `#100B07` the light hex is 3.43:1 — over the 3:1 floor but a dim light beside a 14.73:1 green. The dark hex measures 8.60:1 (dark-IC `#9FC7D3` 10.80:1). Mechanism: resolve `Tokens.Color.ring` under `NSAppearance(named: .darkAqua)` — the idiom `AlignmentPlateCell.primaryFillColor` already uses (AlignmentPlateCell.swift:253-259) and `AlignmentTokenContrastTests.resolved` measures with. No new token.
- **D2 The reference PLATE tint is plain `Tokens.Color.ring`** — dark = `#7FB4C4` at full alpha (6.93:1 on dark `raised`), light = `#2C6E86` at the existing `lightRimAlpha` 0.9 (composited on the flat light ground → `#417C92`, 4.45:1; on light `well` → `#3F7A90`, 3.97:1; the chip glyph draws it at full alpha, 5.47:1). `ring` already carries its own light hex, so no "Deep" companion exists or is added; the `isDarkAppearance ? electric : deep.withAlphaComponent(0.9)` shape stays for the TARGET (`wireCore` / `syncSignalDeep`, 4.31:1 at 0.9 on the light ground) and simplifies for the reference to `ring` / `ring.withAlphaComponent(0.9)`.
- **D3 The room spill's right wash is `Tokens.Color.ring`** in both branches. Light-mode spill is OFF (`peakOpacity` 0, AlignmentWizardViewController.swift:250), so only the dark hex is ever visible; the `isDarkAppearance ? party : partyRampDeep` fork collapses to one token.
- **D4 The detent flash is `stageInk` on every dial position.** S6. The `Tokens.accentStyle == .subtle ? ember : glow` fork (AlignmentStageView.swift:1682-1683) goes; the stage no longer reads `glow`, `ember` or `accentStyle`. `stageInk` `#EFE9DD` is 16.19:1 on the plate and 1.11:1 from `fuseWhite` — the detent is a brightness pulse in the instrument's own ink, not a hue.
- **D5 The primary plate's INK is pinned the way its FILL is.** PR 1's `inkOnFill` flips to WHITE under light Increase Contrast (Tokens.swift:627-630); the plate's fill is pinned to `gold`'s dark hex `#E8B84B` (`primaryFillColor`), and white on `#E8B84B` measures 1.84:1. So the plate resolves `inkOnFill` under `.darkAqua` too (`#171104`, 10.18:1) through a `primaryInkColor` static beside `primaryFillColor`, used for both the title (:328) and the chip ink (:395). This is the `inkOnGold → inkOnFill` re-point the brief orders, done so it cannot regress; `AlignmentTokenContrastTests.inkOnFillClears…` already measures exactly this pinned pair.
- **D6 Radii.** Plates → `Tokens.Layout.Radius.control` (10): a plate is a button — iOS Shapes puts CTA buttons at the control radius (`/Users/alechenderson/Projects/audiout-remote/DESIGN.md:579-580`). Stage plate → `Tokens.Layout.Radius.row` (16): a 504×132 instrument strip is the same class as a row's clip shape or a Groups card (that file :580-581); `panel` (26) is the Main Out deck alone. Keycap chip 6 → control (10): iOS "Speakers filter chips … sit at the control radius"; capsules are reserved for faders, the destination pill, the Demo badge and the lamp (that file :584-587). (On the 44×20 "SPACE" chip r 10 happens to equal a capsule; the 22×22 chips stay rounded squares.) First-join note seat 7 → control: a ~28 pt-tall inset seat is control-sized; `row` would make it a capsule.
- **D7 `Tokens.Font.keycap` becomes `.systemFont(ofSize: 11, weight: .semibold)`** — the micro-label weight at the chip's existing 11 pt. Measured on this Mac with `NSAttributedString.size()`: "SPACE" 36.58 pt (was 34.00 in the mono face) inside the 44 pt chip; "←"/"→" 10.29, "⏎" 11.61 inside 22. The role keeps its name (it is a role, not a face).
- **D8 The answer plates' 15 pt semibold title becomes `Tokens.Font.plateTitle`** = `.systemFont(ofSize: 15, weight: .semibold)`. `heading` is `systemFontSize + 3` = 16 pt and `bodyEmphasized` is 13 pt (Tokens.swift:1122-1134); 15 is an owner ruling (wizard-stage-v2-spec §0b.1), so it gets a named role rather than a resize.
- **D9 Readouts.** The wizard's stage caption (`styleReadout`, BTAlignmentWizardView.swift:933-935) uses `Tokens.Font.readout` (PR 3's 11 pt semibold tabular) for BOTH the hero and the caption; `hero` keeps driving only the colour (`label` vs `label2`). The drawer's `Tokens.Font.syncReadout` is re-weighted IN PLACE to `.semibold`, keeping 12 pt (two live findings sized it, Tokens.swift:1173-1182); `SettingsForm.readoutWell` (SettingsForm.swift:91) declares it "the app's ONE readout voice" and inherits the weight — listed under Interim effects for PR 6 (Settings + About).
- **D10 The drawer's edge is a full 1 pt `containerEdge` stroke on all four sides**, drawn in `draw(_:)` on `bounds.insetBy(dx: 0.5, dy: 0.5)`. The drawer is a full-width row clip in the card stack (PopoverPanelViewController.swift:1029-1053: leading/trailing pinned to the stack), so its sides are flush with the card and its top meets the device row: the recess needs a lip on every side. Ratios: light `#AEB3BB` 1.75:1 on `well`, 2.02:1 on the flat ground (well vs ground is only 1.154); dark `#3D4247` 2.01:1 on `well`, 1.77:1 on `panel`. Rule 5 holds (the drawer's fill is `well`, not `raised`). This overrides the live-found "no drawn edge" note (BTSyncDrawerView.swift:76-80) — an owed eye check.
- **D11 Ink aliases in this slice are renamed but NOT deleted**: `inkSecondary`/`secondaryLabel` → `label2`, `inkTertiary`/`tertiaryLabel` → `label3` at every site in the eight files (list in Verified facts). They stay in `Tokens.swift` (100+ other consumers).
- **D12 `party` leaves `AlignmentTokenContrastTests`.** Its on-plate case and `lightPartySignalDeepClearsTheFloorOnLightCanvasAndRaised` are deleted; PR 5 (popover, R2) adds its own party measurement where the token is actually drawn. `ring`-on-plate cases are added.
- **D13 wizard-snapshot has no goldens.** The executor renders to the scratchpad and looks; nothing is compared, nothing is committed.
- **D14 `AudioutPopoverUI/AGENTS.md` is already 359 words against the root's ≤300 cap** (root AGENTS.md:19). This PR amends ONE existing bullet in place (+11 words → 370) and does not add a bullet; trimming the file is PR 9's.

## Pre-flight (from the NEW worktree root)

```bash
git fetch origin && git worktree add .claude/worktrees/design-wizard -b claude/design-wizard origin/main
cd .claude/worktrees/design-wizard && git push -u origin claude/design-wizard && git config core.hooksPath .githooks
git log --oneline -1                                  # must be at or after the PR 3 merge commit
git grep -n "rowLiveWashAlpha\|static var readout" -- AudioutCore/Sources/AudioutSharedUI   # PR 3's hand-off symbols: expect PopoverColumnGrid.swift + Tokens.swift hits; if empty, STOP — PR 3 has not merged
git grep -n "static let alignPlateCornerRadius: CGFloat = 12" -- AudioutCore/Sources/AudioutSharedUI/PopoverColumnGrid.swift   # expect one hit (PR 3 left it)
bash scripts/build.sh                                 # exit 0
AUDIOUT_TEST_NO_CACHE=1 bash scripts/run-tests.sh --filter 'AlignmentPlateCellTests|AlignmentStageViewTests|AlignmentTokenContrastTests|BTSyncDrawerViewTests|PopoverBTAlignmentUITests'
```

Baseline observed during scoping at `586bd8a2` (2026-09-03): `Test run with 127 tests in 8 suites passed` (the regex also catches `BTSyncDrawerLayoutTests`, `WizardDoorAnalyticsTests`, `SerializedSharedState`). Your pre-flight number after PR 3 may differ by PR 3's own additions; it must be green. Never a bare `swift build`/`swift test`.

## Verified facts (file:line, checked at `586bd8a2`)

Tokens (`AudioutCore/Sources/AudioutSharedUI/Tokens.swift`):
- `ring` :367-370 (`#7FB4C4` / IC `#9FC7D3` / light `#2C6E86` / light-IC `#265E73`); `rim` :318-321; `containerEdge` :302-305; `inkOnFill` :627-630 (`#171104` ×3, light-IC `#FFFFFF`); `engagedChrome` :149 (= `label`); `glow` :600-605 (Subtle = `.clear`).
- Stage block :936-1034: `stagePlate` :958-961, `stageRule` :967-970, `stageInk` :975-978, `wireCore` :986-989 (`#2BFF8F` ×4), `syncSignalDeep` :1002-1005 (light `#0B7A45`), `party` :1012-1015, `partyRampDeep` :1024-1027, `fuseWhite` :1032-1035. Block comment :938-951 still says "eight tokens … `partyRampDeep` … plate rim/keycap tint".
- Deprecated aliases block :1036-1101: `plateRim` :1073-1074, `inkOnGold` :1089-1090, `syncSignal` :1095-1096, `partySignal` :1097-1098, `partySignalDeep` :1099-1100. (`secondaryLabel` :1047-1048, `inkSecondary` :1049-1050, `tertiaryLabel` :1055-1056, `inkTertiary` :1057-1058 stay.)
- Fonts: `bodyEmphasized` :1122-1124 (13 pt), `heading` :1131-1133 (16 pt), `microLabel` :1171-1173 (10 semibold), `syncReadout` :1181-1183 (12 pt `.medium` monospacedDigit), `keycap` :1186-1188 (`.monospacedSystemFont(ofSize: 11, weight: .medium)`), `detail` :1192. PR 3 inserts `readout` after `caption` (:1148) — line numbers below `caption` shift by its doc + body.
- `Tokens.Layout.Radius.{control,row,panel}` :1288-1295 = 10 / 16 / 26.

Grid: `PopoverColumnGrid.alignPlateCornerRadius: CGFloat = 12` at PopoverColumnGrid.swift:638 (doc :637). Consumers: AlignmentPlateCell.swift:131, :351-352 only.

Stage (`AudioutCore/Sources/AudioutPopoverUI/AlignmentStageView.swift`, 1764 lines):
- Header doc :10-18 names `syncSignal`/`partySignal`; wire doc :474-477 "magenta from the right"; span doc :484-485 "`syncSignal → partySignal` bar"; :1076-1081 "dusty mauve, not magenta"; :1409 "magenta from the right"; :1657-1660 "magenta from the reference's".
- `plateCornerRadius` :365 (= 12), used :798-799 (name-stamp clamp) and wherever `plateLayer.cornerRadius` is set.
- Name stamps :787-808: `stageInk.withAlphaComponent(0.6)` :796 (already `stageInk`; NOT a party consumer — the prompt's "name stamp" moves nothing here).
- `fireDetent` :1275-1291 pulses `spanLayer.shadowColor` to `resolvedDetentAccent` :1284.
- Lock cross :1383-1386 uses `Self.haloImage(color: Tokens.Color.syncSignal)` :1385.
- `fireGatherBars` :1416-1419 uses `resolvedTargetLight`/`resolvedReferenceLight`.
- `stampColors()` :1630-1685: `target = syncSignal` :1639, `reference = partySignal` :1640, `plateLayer.borderColor = plateRim.withAlphaComponent(isDark ? 0.35 : 0.9)` :1648-1649, half-bars :1661-1663, `spanLayer.shadowColor = fuse` :1666, `resolvedReferenceLight = reference.cgColor` :1678, detent fork :1679-1683.
- Test hooks :1743-1761; `test_targetRingColor` :1760. Accent-dial observer: registration :564-566, handler `accentStyleDidChange` :1729-1734 (its only job is `stampColors()` + a re-apply).

Wizard VC (`AlignmentWizardViewController.swift`): doc :29-32 "magenta (party/reference)"; :112-114 "magenta behind the right third"; `peakOpacity` :250 (light = 0); `leftTint` :252-254 (`syncSignal`/`syncSignalDeep`); `rightTint` :256-258 (`partySignal`/`partySignalDeep`); lock flash `fuseWhite` :308.

Wizard view (`BTAlignmentWizardView.swift`, 1395 lines): header :19-24 names `syncSignal`/`partySignal`; `answerPlateFont` :262 (`NSFont.systemFont(ofSize: 15, weight: .semibold)`), applied :684; `clickCountLabel.textColor = inkSecondary` :335; `targetTint` :499-503, `referenceTint` :505-509, `lightRimAlpha = 0.9` :511; `inkSecondary` at :881, :907, :935, :978, :1057, :1179-1180; `styleReadout` :932-936 (doc :929-931); test hooks :1282-1393 (`actionButtons` :1325 finds plates by title; `test_buttonIsEnabled` :1303-1306 is the pattern).

Plate cell (`AlignmentPlateCell.swift`, 494 lines): doc :45-58 ("22×22 r6", "`Tokens.Font.keycap`") and :66-72 (names the four old tokens); `identityTint` doc :120-123 ("neutral `Tokens.Color.plateRim`"); `drawBezel` radius :131; rim :162 (`identityTint ?? Tokens.Color.plateRim`); `primaryFillColor` :253-259; `titleColor` :327-331 (`inkOnGold` :328, `inkSecondary` :329); focus mask :349-353; `chipInk` :394-397 (`inkOnGold` :395, `inkSecondary` :396); `drawKeycapChip` :399-449 (`Self.chipCornerRadius` :413, `Tokens.Font.keycap` :441); `chipCornerRadius: CGFloat = 6` :483.

Note view (`BTAlignmentNoteView.swift`): `backgroundCornerRadius: CGFloat = 7` :38, used :71; `inkTertiary` :99; `secondaryLabel` :151; `containerEdge` border already :174.

Drawer (`BTSyncDrawerView.swift`, 681 lines): header :74-80 ("No drawn edge or border (live feedback)"); `valueField.font = syncReadout` :224; `secondaryLabel` :288, :308, :447, :535; `tertiaryLabel` :336; `draw(_:)` :420-425 (fills `well`, "no border"); hooks :621-672 (`test_valueFieldIsBezeled` :650, `test_stepperButtonsAreBezeled` :651-653).

Mount: `PopoverController.swift:2904` `panel.insertRow(syncDrawer, after: row, animated:)`; `PopoverPanelViewController.insertRow` :1029-1053 wraps the drawer in a `RowClipView` pinned to the stack's leading/trailing anchors.

Tests (`AudioutCore/Tests/AudioutCoreTests/`): `AlignmentPlateCellTests.swift` (9 tests; rim probe `rimKeepsTheHandedTintAlpha` :200-215 samples pixel (0, mid) under `.darkAqua` with a magenta PROBE tint, `redComponent < 0.8` :212 — its mechanics are token-independent; doc :201 says "0.45 electric on dark", stale; message :56 says "goldCTA-filled"). `AlignmentStageViewTests.swift` (21; `lockedRingIsFuseWhiteNotTheTargetsGreen` :72-85 asserts the QUESTION ring is green and the LOCKED ring is fuseWhite — unaffected; `headlessDrawsThePinnedRingAtTheRungsOwnOpacity` :328-353 — geometry only, unaffected; NO flash-colour assertion exists). `AlignmentTokenContrastTests.swift` (7; `syncPartyAndFuseSignalsClear…` :69-86; `inkOnFillClears…` :111-119; `lightPartySignalDeep…` :134-142; helper `resolved(_:appearanceName:)` :34-40). `BTSyncDrawerViewTests.swift` (30; bezel tests :192-205; `makeDrawer()` helper). `PopoverBTAlignmentUITests.swift` (60; `openWizard` :271-275; question-screen plate titles are `"Move 2"` (target) and `"This Mac"` (reference) :404-406).

Snapshot tool: `swift run --package-path AudioutCore wizard-snapshot [output-dir]` (Package.swift:105-107; main.swift:18, :129), writes `<name>-dark.png` and, for some screens, `-light.png` (:139-145). Default output dir is cwd-relative `wizard-snapshots/` — NOT in the repo; write to the scratchpad.

Measured this session (`scratchpad/contrast.py`): ring dark on stagePlate 8.60; ring dark-IC on stagePlate 10.80; ring light on stagePlate 3.43; ring light on light ground 5.47 / well 4.74; ring light @0.9 over light ground → `#417C92` 4.45, over light well → `#3F7A90` 3.97; syncSignalDeep light @0.9 over light ground → `#238757` 4.31; ring dark on dark raised 6.93, canvas 8.69; wireCore vs ring dark 1.71 (hue-distinct, green vs blue); white on pinned gold `#E8B84B` 1.84; `#171104` on pinned gold 10.18; stageInk on stagePlate 16.19; stageInk vs fuseWhite 1.11; containerEdge dark on well 2.01 / panel 1.77; containerEdge light on well 1.75 / ground 2.02. Keycap widths: D7.

## Step-by-step

### Step 1 — `AudioutCore/Sources/AudioutSharedUI/PopoverColumnGrid.swift`

:638 `public static let alignPlateCornerRadius: CGFloat = 12` → `= Tokens.Layout.Radius.control`; doc :637 → "Corner radius of the alignment-wizard plate button — the control radius (iOS Shapes: a plate is a button)." Build stays green.

### Step 2 — `AudioutCore/Sources/AudioutSharedUI/Tokens.swift` (fonts only; aliases wait for Step 9)

2.1 `syncReadout` (:1181-1183): weight `.medium` → `.semibold`; append to its doc: "Semibold is the system face's cut nearest the iOS Readout's 700 (PR 3's `readout` precedent); the size stays 12 pt for the two live findings above." Keep `.monospacedDigitSystemFont` and `NSFont.smallSystemFontSize + 1`.
2.2 `keycap` (:1186-1188): body → `.systemFont(ofSize: 11, weight: .semibold)`; doc → "The alignment-wizard plate keycap glyph voice ("←"/"→"/"SPACE"/"⏎" chips on `AlignmentPlateButton`): the plain system face at the micro-label weight. Not monospaced — the chip draws the WORD "SPACE" and iOS's One Case rule has no monospaced design; measured 36.58 pt in the 44 pt wide chip."
2.3 Add directly after `keycap`: `public static var plateTitle: NSFont { .systemFont(ofSize: 15, weight: .semibold) }` with doc: "The wizard's two ANSWER plates' title (owner ruling 2026-08-23: 236×88 hero plates with a 15 pt semibold title). Neither `bodyEmphasized` (13) nor `heading` (16) is that size; only `BTAlignmentWizardView` consumes it."

### Step 3 — `AudioutCore/Sources/AudioutPopoverUI/AlignmentStageView.swift`

3.1 :365 `plateCornerRadius: CGFloat = 12` → `= Tokens.Layout.Radius.row`; doc :364 → "The stage IS the plate: a `stagePlate` ground at the row radius (iOS Shapes: a strip-sized card, not the Main Out deck's panel radius) under it all."
3.2 `stampColors()` :1639 `Tokens.Color.syncSignal` → `Tokens.Color.wireCore`. :1640: replace `Tokens.Color.partySignal` with `ring` resolved under `.darkAqua` (D1) — the `primaryFillColor` idiom from AlignmentPlateCell.swift:253-259, i.e. a `var resolved = Tokens.Color.ring; NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance { resolved = Tokens.Color.ring.usingColorSpace(.sRGB) ?? resolved }` shape, inline or as a private static `referenceLight`. Add the comment: "Pinned to `ring`'s dark hex in BOTH appearances, like every other stage token: the stage is a fixed instrument, and the themed light hex measures 3.43:1 on the plate against the green's 14.73:1 (dark hex 8.60:1)."
3.3 :1648 `Tokens.Color.plateRim` → `Tokens.Color.rim` (alphas 0.35 / 0.9 unchanged).
3.4 :1679-1683: `resolvedDetentAccent = Tokens.Color.stageInk.cgColor`; comment → "The detent is the instrument acknowledging banked progress in its OWN ink (S6, 2026-09-03): a brightness pulse, never gold — the CTA plate is the only gold on this sheet."
3.4b The accent-dial observer is now dead (nothing in `stampColors()` reads the dial): delete the `NotificationCenter.default.addObserver(self, selector: #selector(accentStyleDidChange), name: Tokens.accentStyleDidChangeNotification, object: nil)` registration (:564-566) and the `@objc private func accentStyleDidChange()` handler (:1729-1734). Keep the other observer registrations around it. After this, `git grep -n "Tokens\.Color\.glow\|Tokens\.Color\.ember\|accentStyle" -- AudioutCore/Sources/AudioutPopoverUI/AlignmentStageView.swift` → no output. (The WORD "glow" survives in halo prose — see 3.6.)
3.5 :1385 `Tokens.Color.syncSignal` → `Tokens.Color.wireCore`.
3.6 Comments: :10-18 → the target light is `wireCore`, the reference `ring` (pinned dark), fusing to `fuseWhite`; :474-477 and :1409 "magenta" → "steel blue"; :484-485 → "`wireCore → ring` bar"; :1657-1660 → "green from the target's end, blue from the reference's"; the word "glow" as a stage COLOUR goes from :245 ("or the glow stops being a glow" → "or the halo stops reading as light"), :346 ("stopped reading as glow" → "stopped reading as a halo"), :485 ("with a low `fuseWhite` glow" → "with a low `fuseWhite` bloom (the span's shadow)"), :1275 ("The span's glow swells and takes the instrument's own gold voice" → "The span's bloom swells and brightens to `stageInk`"); :1076-1081 → keep `0.85`, comment: "×0.85, not the table's ×0.55: measured against the magenta-era ring over the green halo (dusty mauve at 0.55); not re-measured for `ring` — owed eye check (PR 8)."
3.7 Test hooks: beside `test_targetRingColor` (:1760) add `var test_referenceRingColor: NSColor? { referenceRing.strokeColor.map(NSColor.init(cgColor:)) ?? nil }` and `var test_detentAccent: NSColor? { NSColor(cgColor: resolvedDetentAccent) }`.

### Step 4 — `AudioutCore/Sources/AudioutPopoverUI/AlignmentWizardViewController.swift`

4.1 `leftTint` :252-254: `syncSignal` → `wireCore` (keep `syncSignalDeep` for light). `rightTint` :256-258 → `Tokens.Color.ring` (no appearance fork; D3), comment: "`ring`'s dark hex is the only one ever seen — light spill is off (`peakOpacity`)."
4.2 Comments :29-32 and :112-114: "magenta (party/reference)" → "steel blue (`ring`, the reference)".

### Step 5 — `AudioutCore/Sources/AudioutPopoverUI/BTAlignmentWizardView.swift`

5.1 :262 delete `answerPlateFont`; :684 `plate.font = Tokens.Font.plateTitle`.
5.2 `targetTint` :499-503: `syncSignal` → `wireCore`. `referenceTint` :505-509 → `isDarkAppearance ? Tokens.Color.ring : Tokens.Color.ring.withAlphaComponent(Self.lightRimAlpha)`. Rewrite the doc :494-498: dark = the light's own hex at full strength (owner ruling 2026-08-23), light = the token's own light hex at 0.9 (`ring` carries its light hex itself; the target still uses `syncSignalDeep`). Cite: light reference rim composited 4.45:1 on the flat ground, chip glyph 5.47:1.
5.3 `styleReadout` :933-935: `readout.font = Tokens.Font.readout` (drop the `hero ? .semibold : .regular` weight fork); `hero` still picks `label` vs `label2`. Doc :929-931 → "caption-size semibold tabular digits (iOS Readout weight) in `label2`; the proposal's hero readout differs by ink, not weight."
5.4 Rename `Tokens.Color.inkSecondary` → `Tokens.Color.label2` at :335, :881, :907, :935, :978, :1057, :1179, :1180; and in the doc comments at :900 ("at `inkSecondary`" → "at `label2`") and :972 (same).
5.5 Header :19-24: "wears `wireCore`, the reference plate `ring` (the target's Deep companion / `ring`'s own light hex at 0.9 in light mode)".
5.6 Test hook beside `test_buttonIsEnabled` (:1303): `var test_plateIdentityTint: (String) -> NSColor? { { [weak self] title in (self?.actionButtons.first { $0.title == title } as? AlignmentPlateButton)?.test_identityTint } }` (same closure shape as `test_buttonIsEnabled`; `AlignmentPlateButton.test_identityTint` exists, AlignmentPlateButton.swift:110).

### Step 6 — `AudioutCore/Sources/AudioutPopoverUI/AlignmentPlateCell.swift`

6.1 :162 `Tokens.Color.plateRim` → `Tokens.Color.rim`; doc :123 likewise.
6.2 Add after `primaryFillColor` (:259) a `private static var primaryInkColor: NSColor` that resolves `Tokens.Color.inkOnFill` under `.darkAqua` with the identical idiom; doc: "Pinned with the fill: `inkOnFill` goes white under light Increase Contrast, and white on the pinned `#E8B84B` measures 1.84:1 — the ink has to be resolved under the same appearance the fill is (10.18:1)." :328 and :395 → `Self.primaryInkColor`.
6.3 :329 and :396 `inkSecondary` → `label2`; doc comments :55, :326 and :393 rename `inkSecondary` → `label2` too.
6.4 :483 `chipCornerRadius: CGFloat = 6` → `= Tokens.Layout.Radius.control`; doc: "the control radius — iOS puts chips at the control radius, not a capsule".
6.5 Comments: :45 "22×22 r6" → "22×22 at the control radius"; :56-57 "and white on a primary — a gold face never carries a dark chip" → "and the pinned `inkOnFill` on a primary — the chip shares the title's ink"; :66-72 → the caller passes `wireCore`/`syncSignalDeep` (target) or `ring` (reference); `nil` → `rim`; :35, :53-56 wherever `inkOnGold`/`plateRim` are named → `inkOnFill` (pinned) / `rim`. `git grep -n "inkOnGold\|plateRim\|partySignal\|syncSignal\b\|goldCTA" -- AudioutCore/Sources/AudioutPopoverUI/AlignmentPlateCell.swift` must be empty.
6.6 `goldCTA` prose (the alias itself is PR 7's to delete): reword every doc-comment mention to "the pinned gold" / "`gold`" — AlignmentPlateCell.swift:99, :180, :201, :242 (the "Not ``Tokens/Color/goldCTA``" bullet becomes one sentence: the fill is `gold`'s dark hex, never the retired deepened CTA gold), :468, :470, :474; and AlignmentPlateButton.swift:75 ("(`goldCTA`) plate" → "(`gold`-filled) plate").

### Step 7 — `AudioutCore/Sources/AudioutPopoverUI/BTAlignmentNoteView.swift`

:38 `backgroundCornerRadius: CGFloat = 7` → `= Tokens.Layout.Radius.control`; :99 `inkTertiary` → `label3`; :151 `secondaryLabel` → `label2`.

### Step 8 — `AudioutCore/Sources/AudioutSharedUI/BTSyncDrawerView.swift`

8.1 `draw(_:)` :422-425: after the `well` fill, stroke `bounds.insetBy(dx: 0.5, dy: 0.5)` with `Tokens.Color.containerEdge` at line width 1 (`NSBezierPath(rect:)`, `.setStroke()`, `.stroke()`). MARK :420 → "Drawing — well fill + containerEdge rim".
8.2 Header :74-80: replace the "No drawn edge or border (live feedback)" sentences with (and :79 "the exact accent/secondaryLabel treatment" → "the exact `engagedChrome`/`label2` treatment"): the fill is `well`; the recess is bounded by a 1 pt `containerEdge` rim on all four sides (2026-09-03) because on the flat light ground the well is only 1.154:1 from the card and iOS separates by edge weight there (containerEdge 1.75:1 on `well` light, 2.01:1 dark); a card's own edge is `containerEdge`, never `hairline`.
8.3 `secondaryLabel` → `label2` at :288, :308, :447, :535; `tertiaryLabel` → `label3` at :336.

### Step 9 — `AudioutCore/Sources/AudioutSharedUI/Tokens.swift` (aliases + comments)

9.1 `git grep -n "Color\.\(plateRim\|inkOnGold\|syncSignal\|partySignal\|partySignalDeep\)\b" -- AudioutCore` → must list ONLY the alias definitions in Tokens.swift. (No test consumes any of the five at HEAD: AlignmentTokenContrastTests only carries them in a test NAME at :88 and AlignmentPlateCellTests in a message at :56, neither a `Tokens.Color.` read.) Delete the five alias properties and their `@available` lines (:1073-1074, :1089-1090, :1095-1100).
9.2 Stage block comment :938-951: "Eight tokens" and the `partyRampDeep` … "plate rim/keycap tint" sentence → the wizard's reference light and rim are `ring` (pinned dark on the stage, themed on the plates); `party`/`partyRampDeep` are group identity (C1) and are not drawn on this sheet. `party` doc :1007-1011 and `partyRampDeep` doc :1017-1023: drop "Reference light — the speaker being compared against" / "used the same way as `syncSignalDeep`"; say they are consumed by the popover/Groups (PR 5). `syncSignalDeep` doc :991-1001 stays.

### Step 10 — `AudioutCore/Sources/AudioutPopoverUI/AGENTS.md`

Replace the bullet "The alignment wizard is a sheet the popover cannot close under." with "The alignment wizard is a sheet the popover cannot close under; its lights are green and steel blue (`wireCore`/`ring`), never magenta (C1)." No other change (D14).

### Step 11 — tests (Test plan), one file at a time.

### Step 12 — `bash scripts/build.sh`, then Verification.

## Ratio table (new to this PR)

| pair | ratio |
|---|---|
| `ring` dark `#7FB4C4` on `stagePlate` (reference light, ring, halo core) | 8.60 (IC `#9FC7D3` 10.80) |
| `ring` dark on dark `raised` (reference plate rim/chip, dark) | 6.93 |
| `ring` light `#2C6E86` @0.9 over light ground → `#417C92` (reference rim, light) | 4.45 |
| `ring` light @0.9 over light `well` → `#3F7A90` | 3.97 |
| `ring` light at full alpha on light ground (chip glyph) | 5.47 |
| `syncSignalDeep` light @0.9 over light ground → `#238757` (target rim, light) | 4.31 |
| `wireCore` vs `ring` dark (the two lights) | 1.71, hue-distinct |
| `stageInk` on `stagePlate` (detent peak) | 16.19 |
| `#171104` on pinned gold `#E8B84B` (plate ink, every appearance) | 10.18 (white would be 1.84) |
| `containerEdge` on `well`: dark / light | 2.01 / 1.75 |
| `containerEdge` on the light flat ground | 2.02 |

## Interim visible effects this PR finalises / introduces

Finalised from PR 1's table: `plateRim→rim` (neutral plate rims and the stage bezel are `rim`), `inkOnGold→inkOnFill` (plate ink `#171104`, now pinned so light-IC cannot flip it white).

Introduced: the reference light, halo, gather bar, half-bar and plate rim/chip are steel blue (`ring`) instead of magenta · the rung-promotion detent flashes `stageInk` (no gold on the stage) · plates and keycap chips at r 10, the stage plate at r 16, the first-join note at r 10 · "SPACE"/arrow keycaps in the plain semibold face · the answer plates' 15 pt title unchanged in size, now a named role · the wizard caption readout is semibold tabular · the drawer's value field is 12 pt SEMIBOLD, and so are the Settings readout wells (`SettingsForm.readoutWell`) — PR 6 (Settings + About) decides whether they keep it · a 1 pt `containerEdge` rim around the sync drawer in both appearances.

## Test plan (only these files; every expected value is in the tables above)

- **AlignmentPlateCellTests.swift**: all 9 keep. `rimKeepsTheHandedTintAlpha` doc :201-204 → "(0.9 Deep / `ring` on light)"; message :56 "the goldCTA-filled primary plate" → "the gold-filled primary plate". ADD `referenceRimInRingIsBlueNotMagenta`: `makeButton(keycap: nil, identityTint: Tokens.Color.ring)`, `.darkAqua`, same (0, mid) pixel read as `rimKeepsTheHandedTintAlpha` → `blueComponent > redComponent + 0.15` and `greenComponent > redComponent` (`#7FB4C4`: r 0.50, g 0.71, b 0.77 over the dark `raised` fill).
- **AlignmentStageViewTests.swift**: all 21 keep unchanged. ADD `referenceRingIsRingsDarkHexInBothAppearances`: for `.aqua` and `.darkAqua`, `stage.appearance = NSAppearance(named:)`, `apply(.question(intervalMs: 30...50, range:), animated: false)`, `test_referenceRingColor?.usingColorSpace(.sRGB)` within 0.02 per channel of `Tokens.Color.ring` resolved under `.darkAqua` (use the same `NSAppearance(named:).performAsCurrentDrawingAppearance` idiom as `AlignmentTokenContrastTests.resolved`). ADD `detentFlashIsStageInkNotGold`: after the same apply, `test_detentAccent` within 0.02 of `Tokens.Color.stageInk` (sRGB), and `redComponent - blueComponent < 0.1` (gold `#FFD97A` would be 0.52 apart).
- **AlignmentTokenContrastTests.swift**: `syncPartyAndFuseSignalsClear…` → rename `wireCoreRingAndFuseWhiteClearTheNonTextFloorOnThePlateBothAppearances`: keep the `wireCore` and `fuseWhite` loops; replace the `party` line with `ring` resolved under `.darkAqua` (outside the appearance loop — the stage pins it) ≥ 3.0 (8.60). ADD `lightRingAtTheRimAlphaClearsTheFloorOnTheLightGround`: composite `ring` (`.aqua`) at 0.9 over `canvas` (`.aqua`) with `NSColor.blended(withFraction:of:)` — `ring.blended(withFraction: 0.1, of: canvas)` — and expect ≥ 3.0 vs `canvas` (4.45) and vs `well` (3.97). DELETE `lightPartySignalDeepClearsTheFloorOnLightCanvasAndRaised` (D12). `inkOnFillClears…` (:111) keeps; doc :105-110 add "the cell pins the ink with `primaryInkColor` for the same reason". Suite doc :8 "eight new instruments" → "the stage instruments".
- **BTSyncDrawerViewTests.swift**: all 30 keep, `theStepperButtonsCarryTheirOwnBezel` and `theValueFieldIsAStockBezeledField` untouched. ADD `theRecessIsBoundedByAContainerEdge`: `makeDrawer()`, `appearance = .aqua`, pin `widthAnchor` to `SurfaceLayout.width` exactly as `aRealLayoutPassGivesEverySubviewRealHeight` does (BTSyncDrawerViewTests.swift:340), `layoutSubtreeIfNeeded`, then `setFrameSize` to `fittingSize` so `bounds` is non-empty, `bitmapImageRepForCachingDisplay` + `cacheDisplay`, pixel (0, mid) within 0.03 per channel of `Tokens.Color.containerEdge` resolved `.aqua` (`#AEB3BB`), and pixel (3·scale, mid) within 0.03 of `well` `.aqua` (`#E9EAEC`).
- **PopoverBTAlignmentUITests.swift**: all 60 keep. ADD, beside the question-screen test at :396-421, `theAnswerPlatesWearGreenAndSteelBlueNeverMagenta`: `openWizard`, start, reach the question screen the way :396-404 does, then `wizard?.test_plateIdentityTint("Move 2")?.usingColorSpace(.sRGB)` → `greenComponent > blueComponent && blueComponent > redComponent`; `("This Mac")` → `blueComponent > redComponent + 0.15 && greenComponent > redComponent` (holds for `#7FB4C4` and `#2C6E86`; magenta `#FF90E9` has r 1.0).
- Expected count: baseline + 6.

## Verification (in this order; paste each command's output)

```bash
bash scripts/build.sh        # exit 0
AUDIOUT_TEST_NO_CACHE=1 bash scripts/run-tests.sh --filter 'AlignmentPlateCellTests|AlignmentStageViewTests|AlignmentTokenContrastTests|BTSyncDrawerViewTests|PopoverBTAlignmentUITests'
#   expected: every suite passes; count = pre-flight count + 6 (127 + 6 = 133 at the scoping baseline; report the real number)
AUDIOUT_TEST_NO_CACHE=1 bash scripts/run-tests.sh      # the FULL suite, once, green
git grep -n "Color\.\(plateRim\|inkOnGold\|syncSignal\|partySignal\|partySignalDeep\)\b" -- AudioutCore   # expected: no output
git grep -n -i "party\|magenta" -- AudioutCore/Sources/AudioutPopoverUI AudioutCore/Sources/AudioutSharedUI/BTSyncDrawerView.swift AudioutCore/Sources/AudioutSharedUI/SyncValueFieldEditor.swift   # expected: only AudioutPopoverUI/AGENTS.md's new bullet and AGENTS-HISTORY.md — NO hit in any Alignment*/BTAlignment* file or BTSyncDrawerView.swift (AudioutSharedUI/DeviceRowView.swift:922 is outside this grep and stays)
git grep -n "Tokens\.Color\.glow\|Tokens\.Color\.ember\|accentStyle" -- AudioutCore/Sources/AudioutPopoverUI/AlignmentStageView.swift   # expected: no output (the observer and its handler are gone with Step 3.4b)
git grep -n "inkSecondary\|secondaryLabel\|inkTertiary\|tertiaryLabel\|answerPlateFont\|monospacedSystemFont" -- AudioutCore/Sources/AudioutPopoverUI/Alignment*.swift AudioutCore/Sources/AudioutPopoverUI/BTAlignment*.swift AudioutCore/Sources/AudioutSharedUI/BTSyncDrawerView.swift   # expected: no output
git grep -n "cornerRadius: CGFloat = \(6\|7\|12\)$" -- AudioutCore/Sources/AudioutPopoverUI/Alignment*.swift AudioutCore/Sources/AudioutPopoverUI/BTAlignment*.swift AudioutCore/Sources/AudioutSharedUI/PopoverColumnGrid.swift   # expected: no output
git status --short dev/notes   # expected: only dev/notes/design-migration-scoping/PR8-*.md
```

Then render and LOOK (nothing compares these; nothing is committed):

```bash
swift run --package-path AudioutCore wizard-snapshot "$SCRATCHPAD/wizard-snapshots"
```
(`swift run` of a tool target is the documented way to run the snapshot tools — Package.swift:106; it is not the test/build path the wrapper rule covers.) Open `3-question-closing-dark.png`, `3-question-closing-light.png`, `3b-question-near-dark.png`, `1-intro-light.png` and `5-proposal-dark.png` with the Read tool and confirm by eye: the right-hand light and its halo are steel blue, not pink; the right answer plate's rim and "→" chip are blue and the left plate's green in both appearances; "SPACE" on the together bar is in the plain face; plate corners are visibly tighter than the stage plate's; the gold CTA plate carries dark ink. Report what you saw in one line. Do not copy PNGs into the repo.

Then:

```bash
git add -A AudioutCore dev/notes/design-migration-scoping/PR8-wizard-work-order.md dev/notes/design-migration-scoping/PR8-pr-body.md
bash scripts/self-review.sh
git commit -m "Wizard: steel-blue reference light, stageInk detent, control radii, plain keycaps, drawer edge

The alignment wizard's reference light, halo, half-bar, plate rim and
keycap chip move from party magenta to ring (pinned to its dark hex on
the fixed stage, themed on the plates); magenta is group identity now
(C1). The rung-promotion detent flashes stageInk, so the only gold on
the sheet is the CTA plate. Plates, chips and the first-join note sit
at the control radius, the stage plate at the row radius. The keycap
chip draws in the plain semibold face, the answer plates' title is a
named role, and both readouts are semibold tabular. The primary plate's
ink is pinned with its fill. The sync drawer gains a 1 pt containerEdge
rim. plateRim, inkOnGold, syncSignal, partySignal and partySignalDeep
leave Tokens.swift.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
git push origin claude/design-wizard
gh pr create --base main --head claude/design-wizard --title "Design migration PR 8: speaker-sync wizard, stage and drawer" --body-file dev/notes/design-migration-scoping/PR8-pr-body.md
```

`PR8-pr-body.md` carries: the Goal paragraph; Decisions D1–D14; the Interim effects section verbatim; the sentence "`dev/notes/wizard-v2-handoff/*.png` are pre-restyle reference images and were NOT regenerated (stale, by eye); wizard-snapshot renders were checked by eye in the scratchpad and not committed"; the verification output; the footer `🤖 Generated with [Claude Code](https://claude.com/claude-code)`. Do NOT merge the PR.

## Owed checks (do not block the PR; list them in the PR body)

- Eye check in a dev build (`APP_NAME="Audiout Dev" BUNDLE_ID="com.audiout.Audiout.dev" bash scripts/make-app.sh` after `scripts/livetest.sh acquire`): the blue reference light beside the green one on the live stage, dark and light; the fused ring's `×0.85` opacity over the green halo, which was tuned against magenta (D6/3.6); the drawer's new rim in light mode — the "no edge" note it overrides was a live finding (D10); the semibold 12 pt value field against the small stock buttons; the r 10 keycap chip at 22×22.
- The room spill's right wash in dark mode is blue at 0.10 — whether it still reads as a wash and not a stain.
- Settings readout wells (`SettingsForm.readoutWell`) inherit the semibold weight: PR 6's call to keep or split.

## Requests to PR 3

None. PR 3's fences already release `alignPlateCornerRadius` to this PR; nothing else in `PopoverColumnGrid`, `DeviceRowView` or `AppRowView` is needed.

## Hand-off to the remaining PRs

- PR 5 (popover, R2): `party`/`partyRampDeep` keep their hexes and now have NO contrast test (D12) — add one where the chevron/seat glow draws them. `DeviceRowView.swift:922`'s comment still says "not `partySignal`".
- PR 6 (Settings + About): `Tokens.Font.syncReadout` is 12 pt semibold; `SettingsForm.readoutWell` inherits it.
- PR 7 (onboarding): deletes the `goldCTA` alias with its three code consumers; PR 8 only rewords the prose mentions in its own files (Step 6.6).
- PR 9 (docs): `dev/notes/wizard-stage-v2-spec.md` §0 #1/§0b.4 (magenta as the reference), §3 (r 6 chip, `keycap` monospaced, radius 12) and `HANDOFF-wizard-v2.md` (still describes a floating window) are stale; `AudioutPopoverUI/AGENTS.md` is 370 words after Step 10 and needs trimming to the 300 cap; `AGENTS-HISTORY.md` hits stay as history.
- Still aliased after this PR: `iconSeatFill`, `accent`, `warning`, `info`, `secondaryLabel`, `tertiaryLabel`, `inkSecondary`, `inkTertiary`, `canvasHi`, `sidebarWarmTint`, `success`, `warningText`. `goldCTA` is deleted by PR 7 (PR 8 rewords its prose mentions).

## Parked (tempting, OUT)

Lamp-rule three-stop halo falloff; the span's CALayer shadow and detent shadow-radius pulse; drawn (gold-filled) drawer controls; a haptic-style warm lift on the drawer's committed value; the fused ring's `×0.85` re-measure; the wizard's `WarmCanvasView` ground (popover PR); the light-mode room spill.

## Execution plan

One track, SERIAL within itself, model **opus**, effort **high**. Why: the stage's colour pinning (D1) and the plate ink pinning (D5) both depend on reading an appearance-resolution idiom correctly and reproducing it inside code that already runs under `performAsCurrentDrawingAppearance`; six new tests probe rendered pixels and dynamic colours across two appearances, where a wrong colour space or an un-set `appearance` gives a plausible-but-wrong pass; and the alias deletion (Step 9) has to be sequenced after every Source AND Test consumer is gone or the build goes red mid-task. No parallel tracks: Steps 3–6 share the identity-tint contract across four files and the tests share the Tokens edits. The branch is cut from `origin/main` after PR 3 merges; there is no uncommitted work it depends on. Verification runs once at the end.

## Executor rules (copy verbatim into the handoff prompt)

> - Follow the steps in order. Do not add, merge, reorder, or skip steps.
> - Before editing in any folder, read the nearest AGENTS.md above it (and the root one) if the repo has them — folder rules and traps bind even when the work order doesn't repeat them.
> - If reality contradicts a Verified fact or a step is impossible as written, STOP and report the discrepancy. Do not improvise a workaround.
> - Before reporting progress, audit each claim against a tool result from this session. Only report work you can point to evidence for. If tests fail, say so with the output.
> - "Done" means the Verification commands were run in this session and passed. Paste their output.
> - Touch nothing in the Out-of-scope list.
> - Deliver what was asked, at the scope intended. If the spec seems mistaken or a better approach exists, say so in a sentence and continue as specified rather than quietly narrowing, widening, or transforming it.
