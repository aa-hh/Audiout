# Speaker-sync surfaces (wizard + stage + drawer) — scoping report

## What exists today
- Wizard is a SHEET (presentAsSheet on the surface), 560pt, 28/20 insets, WarmCanvasView ground (AlignmentWizardViewController.swift:7-18). HANDOFF-wizard-v2.md is STALE (describes a floating window that no longer exists; sheet rehost merged PR #46 2026-08-26).
- Stage = fixed dark plate in BOTH appearances: stagePlate #100B07, stageRule #6A5F50, stageInk #EFE9DD, plateRim (Tokens.swift:1206-1247). 504x132, radius 12, plateRim border 0.35 dark / 0.9 light (AlignmentStageView.swift:352,365,1646-1651).
- Two lights: syncSignal #2BFF8F (target), partySignal #FF90E9 (reference), fixed; fuseWhite #FFF4E2 at .locked (:1670-1674). Span = two hard half-bars with crisp seam (:1657-1665).
- Halo = two-stop alpha falloff of one hue (color@0.9 → 0) (:1689-1704). Ring = 96-seg living polygon ±3% wobble.
- Rung-promotion detent flashes GOLD (glow / ember when subtle) — "the one gold left on the stage" (:1682-1684).
- Plates carry identity hues AS CHROME: syncSignal/partySignal on plate rim + keycap chip ink (BTAlignmentWizardView.swift:497-511; AlignmentPlateCell.swift:395-396). Plates 236x88 / 220x64 / 400x36 at radius 12; chip radius 6.
- One gold CTA per screen: gold + inkOnGold (AlignmentPlateCell.swift:254,328); disabled falls back to secondary skin.
- Type: bodyEmphasized title; readout monospacedDigit .semibold hero/.regular; keycap = monospacedSystemFont(11) drawing the WORD "SPACE"; one bare literal systemFont(15,.semibold) answerPlateFont (:262).
- Sync drawer: stock AppKit on well fill, NO edge (BTSyncDrawerView.swift:74-80,424). Four .rounded .small buttons, caption font, secondaryLabel tint. Value field .squareBezel small, syncReadout monospacedDigit .medium, "34 ms" at rest; SyncValueFieldEditor swaps to bare signed number on edit.
- Metronome/Align-by-ear on-state = engagedChrome (neutral ink) (:447).
- caution + success: ZERO hits in this slice. Bow-out screens carry no red/amber.
- NO settle countdown on the Mac (settleRemainingSeconds consumed only by CompanionSnapshotBuilder for the phone).

## Where it breaks iOS rules
- Rule 4 magenta never a control/stroke/chip/type: plate rims + chip ink wear partySignal. Same for green under Rule 3 / Don't #1 (sheet exception covers field + verdict rings, not buttons).
- Lamp falloff: iOS wireCore → wire @0.55 → wireEdge; Mac fades one hue to transparent (hue never deepens).
- Radii: 12, 12, 6, 7 vs 10/16/26.
- One Case "no monospaced design": keycap draws a WORD ("SPACE") in monospaced. Bare 15pt on a word.
- Light separates by fill: drawer well #E2DFD3 on canvas #FBFBF9 with no edge.
- Filter chip in-force = gold fill + inkOnFill; Mac's on-state is brighter neutral ink.
- Readout 700 weight tabular: Mac .medium (drawer) / .regular (wizard caption).
- Second gold job: detent flash is neither audio state nor CTA (though iOS glow = "touch-down flash").
- Not a violation: fixed dark plate has lampWell precedent (dark in both appearances) — licenses the principle, not the 504pt scale.

## Worth keeping
- Fixed dark stage plate (= lampWell scaled up; only way "green never on paper" holds on a 504pt instrument in light).
- fuseWhite (the Mac's arrival; phone gives it as haptic).
- Two hard half-bars, crisp seam (no accidental third value; seam disappearing IS the fusion).
- syncSignal #2BFF8F exactly = wireCore hex = Movie night ramp mid.
- Gold CTA plate (= GoldCTALabel already, minus radius).
- Drawer −/field/+ cluster as one bound box, buttons not scrub (live-found decisions; iOS drag is finger-driven).
- Bare numbers already ("34 ms").

## Options
### A: Contain identity hues, keep stage — RECOMMENDED, Effort M
- Drop targetTint/referenceTint from plate rims → neutral plateRim; chip ink → inkSecondary. Teaching job moves to stage name stamps (:793-808). Radii: plates 12→10, chip 6→10/capsule, stage plate 12→16. keycap stops being monospaced. Readouts → semibold.
- Light: drawer gains containerEdge hairline (edge not fill step). Stage keeps fixed dark plate.
- Risk: AlignmentPlateCellTests breaks ×4 (renderIsByteDeterministic, keycapChipSits…, rimKeepsTheHandedTintAlpha pixel probe, tintedCentroid). wizard-snapshot has NO goldens (eyeball PNGs).
- Deps: shared radius decision (does an AppKit .small control get 10pt at all).
### B: A + lamp-rule falloff + drawn drawer controls — viable, Effort L
- Add wire #21D477 + wireEdge #16A05C (syncSignal IS wireCore); magenta pair from partyRampDeep/Pale. haloImage → three-stop hue falloff in one helper (iOS wireFill(radius:) pattern). Align-by-ear on = gold fill + inkOnGold at control radius (drawn control; stock .rounded can't take a fill) + other 3 drawer buttons follow.
- Risk: AlignmentStageViewTests (lockedRingIsFuseWhite…, headlessDraws…), AlignmentTokenContrastTests +2 cases, BTSyncDrawerViewTests.theStepperButtonsCarryTheirOwnBezel + theValueFieldIsAStockBezeledField (both encode live-found failures: borderless glyphs dissolved into well).
- Falloff half cheap + clear win; drawn-controls half is the cost, could ship separately.
### C: Fold stage into ground ladder — NOT recommended, Effort L
- Green on #E2DFD3 ≈ 1.3:1 → needs Deep companions → two appearances stop being one instrument. Overturns owner ruling §0 #1 (wizard-stage-v2-spec.md:11-16). Breaks the iOS rule it serves (green on paper).

## Haptics → Mac
- Detent family (5ms steps) → drawer stepper: visual = brief warm lift (glow) on the committed readout value in tabular digits, back to label at rest (iOS "mid-drag readout's heat" + 16→22pt jump precedent). NSHapticFeedbackManager is Force Touch alignment-only.
- Mute-confirm rule already the drawer's contract; resetTapped exception (:528-540) has recorded reason, stays.
- Arrival = fuseWhite lock + room-spill flash (AlignmentWizardViewController.swift:301-323) — already exists, strongest thing in slice, no option weakens it.
- Settle countdown: phone-only; out of scope.

## Open questions
1. Rung-promotion detent stays gold (glow licenses "touch-down flash") or moves to stageInk (two-hue instrument, no gold)?
2. Plate rims lose identity tint (iOS Rule 4) or Mac takes exemption? Owner ruling §0b.4 (2026-08-23) approved full-strength electric rims after measuring 0.45 as "olive and mauve". DIRECT CONFLICT between rulings.

## Files touched
PopoverUI: AlignmentStageView, AlignmentWizardViewController, AlignmentPlateCell, AlignmentPlateButton, BTAlignmentWizardView, BTAlignmentNoteView, AGENTS.md. SharedUI: BTSyncDrawerView, SyncValueFieldEditor, Tokens, PopoverColumnGrid, AGENTS.md. Tests: AlignmentPlateCellTests, AlignmentStageViewTests, AlignmentTokenContrastTests, BTSyncDrawerViewTests, PopoverBTAlignmentUITests. wizard-snapshot/main.swift. dev/notes/wizard-stage-v2-spec.md.
