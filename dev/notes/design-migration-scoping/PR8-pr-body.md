## Goal

Magenta leaves the wizard (C1/R1): the reference light, its halo, its name stamp, its plate rim and its keycap chip ink move from `party`/`partyRampDeep` to `ring` (steel blue), fixed on the stage like the other stage tokens. The plates keep their tinted rims and chips (S5), now green and blue. The rung-promotion flash stops spending gold (S6): it flashes `stageInk`, so the stage carries no gold except its CTA plate. Radii collapse onto the iOS three (control 10 / row 16). The keycap chip stops drawing the word "SPACE" in a monospaced face (iOS One Case); the bare 15 pt plate title and both readouts get named `Tokens.Font` roles at the iOS readout weight. The deprecated aliases this slice is the last consumer of (`plateRim`, `inkOnGold`, `syncSignal`, `partySignal`, `partySignalDeep`) are deleted. The sync drawer gains a 1 pt `containerEdge` rim so the recess reads by edge on the flat light ground. Nothing else on these surfaces changes: the fixed dark stage plate, `fuseWhite`, the two hard half-bars, the plate bevels, the stock drawer buttons and every piece of geometry stay.

## Decisions recorded

- **D1 The stage's reference light is `ring`'s DARK hex in both appearances (`#7FB4C4`).** The stage is a fixed instrument (owner ruling §0 #1; `wireCore` and every other stage token pass one hex for both appearances). `ring` is themed (light `#2C6E86`), and measured on `stagePlate` `#100B07` the light hex is 3.43:1 — over the 3:1 floor but a dim light beside a 14.73:1 green. The dark hex measures 8.60:1 (dark-IC `#9FC7D3` 10.80:1). Mechanism: resolve `Tokens.Color.ring` under `NSAppearance(named: .darkAqua)` — the idiom `AlignmentPlateCell.primaryFillColor` already uses. No new token.
- **D2 The reference PLATE tint is plain `Tokens.Color.ring`** — dark = `#7FB4C4` at full alpha (6.93:1 on dark `raised`), light = `#2C6E86` at the existing `lightRimAlpha` 0.9 (composited on the flat light ground → `#417C92`, 4.45:1; on light `well` → `#3F7A90`, 3.97:1; the chip glyph draws it at full alpha, 5.47:1). `ring` already carries its own light hex, so no "Deep" companion exists or is added; the `isDarkAppearance ? electric : deep.withAlphaComponent(0.9)` shape stays for the TARGET and simplifies for the reference.
- **D3 The room spill's right wash is `Tokens.Color.ring`** in both branches. Light-mode spill is OFF (`peakOpacity` 0), so only the dark hex is ever visible; the appearance fork collapses to one token.
- **D4 The detent flash is `stageInk` on every dial position.** The `Tokens.accentStyle == .subtle ? ember : glow` fork goes; the stage no longer reads `glow`, `ember` or `accentStyle`. Its now-dead accent-dial observer and handler are deleted with it. **Amended after review:** the colour change alone is not visible — the shadow RESTS at `fuseWhite` and `stageInk` over it is 1.11:1, ΔE76 5.4, and slightly *darker* (the retired gold peak was ΔE76 42.2). So the detent now also doubles the span shadow's opacity, 0.35 → 0.7, which is the event the eye actually reads. `stageInk` stays, S6 holds, and the stage still spends no gold.
- **D5 The primary plate's INK is pinned the way its FILL is.** `inkOnFill` flips to WHITE under light Increase Contrast; the plate's fill is pinned to `gold`'s dark hex `#E8B84B`, and white on `#E8B84B` measures 1.84:1. So the plate resolves `inkOnFill` under `.darkAqua` too (`#171104`, 10.18:1) through a `primaryInkColor` static beside `primaryFillColor`, used for both the title and the chip ink.
- **D6 Radii.** Plates → `Tokens.Layout.Radius.control` (10): a plate is a button. Stage plate → `Tokens.Layout.Radius.row` (16): a 504×132 instrument strip is the same class as a row's clip shape or a Groups card; `panel` (26) is the Main Out deck alone. Keycap chip 6 → control (10). First-join note seat 7 → control.
- **D7 `Tokens.Font.keycap` becomes `.systemFont(ofSize: 11, weight: .semibold)`** — the micro-label weight at the chip's existing 11 pt. Measured: "SPACE" 36.58 pt (was 34.00 in the mono face) inside the 44 pt chip. The role keeps its name.
- **D8 The answer plates' 15 pt semibold title becomes `Tokens.Font.plateTitle`.** `heading` is 16 pt and `bodyEmphasized` is 13 pt; 15 is an owner ruling, so it gets a named role rather than a resize.
- **D9 Readouts.** The wizard's stage caption uses `Tokens.Font.readout` (PR 3's 11 pt semibold tabular) for BOTH the hero and the caption; `hero` keeps driving only the colour. The drawer's `Tokens.Font.syncReadout` is re-weighted IN PLACE to `.semibold`, keeping 12 pt; `SettingsForm.readoutWell` inherits the weight — PR 6's call.
- **D10 The drawer gets a drawn 1 pt edge**, because on the flat light ground its `well` fill is only 1.154:1 from the card — under the 1.25:1 edge floor, so the fill alone cannot carry the boundary. **Amended after review:** the four sides are not the same thing, and the design record ranks them. Sides and bottom bound the recess and take `containerEdge`, a container's own outer edge (light `#AEB3BB` 1.75:1 on `well`, 2.02:1 on the flat ground; dark `#3D4247` 2.01:1 on `well`). The top is the divider between this drawer and the device row above it — both rows inside one container — so it takes `hairline`, the rank below (1.31:1 on `well` light, 1.49:1 dark, both over the floor). This overrides the live-found "no drawn edge" note — an owed eye check.
- **D11 Ink aliases in this slice are renamed but NOT deleted**: `inkSecondary`/`secondaryLabel` → `label2`, `inkTertiary`/`tertiaryLabel` → `label3` at every site in the eight files. They stay in `Tokens.swift` (100+ other consumers).
- **D12 `party` leaves `AlignmentTokenContrastTests`.** Its on-plate case and `lightPartySignalDeepClearsTheFloorOnLightCanvasAndRaised` are deleted; PR 5 adds its own party measurement where the token is actually drawn. A `ring`-on-plate case and a light-composite case are added.
- **D13 wizard-snapshot has no goldens.** Rendered to the scratchpad and looked at; nothing compared, nothing committed.
- **D14 `AudioutPopoverUI/AGENTS.md` is already over the ≤300 word cap.** This PR amends ONE existing bullet in place and does not add a bullet; trimming the file is PR 9's.

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

## Colour-blind separation (the headline risk in swapping magenta for blue)

Recomputed here with the Machado 2009 simulation matrices at full severity, ΔE76 in CIELAB. The review that prompted these fixes reported figures a few units apart (its deuteranope green-vs-blue was 56.1 to my 53.1); the matrices differ, the conclusion does not.

| pair, on `stagePlate` | deuteranope | protanope |
|---|---|---|
| `wireCore` green `#2BFF8F` vs `ring` blue `#7FB4C4` (the new pair) | 53.1 | 65.0 |
| `wireCore` green vs `party` magenta `#FF90E9` (what it replaces) | 58.1 | 88.8 |

Blue separates a little less than magenta did, with plenty of margin either way (ΔE76 ~2.3 is the just-noticeable step). Brightness backs it up on the stage: green measures 14.73:1 against the plate and blue 8.60:1, so the two lights differ 1.71:1 from each other in luminance alone — a viewer who sees no hue at all still reads which light is which.

**What the eye check should watch:** in LIGHT mode the two plate rims composite to `#238657` and `#407C91`, which are 1.02:1 apart. Hue carries the entire distinction there, with no luminance backup. Increase Contrast is the weakest cell (deuteranope ΔE76 29.9). Dark mode is not at risk.

## Renders

`dev/notes/wizard-v2-handoff/*.png` are pre-restyle reference images and were NOT regenerated (stale, by eye); wizard-snapshot renders were checked by eye in the scratchpad and not committed.

By eye across `3-question-closing-{dark,light}`, `3b-question-near-dark`, `1-intro-light` and `5-proposal-dark`: the right-hand light and its halo are steel blue with no pink anywhere; the right plate's rim and "→" chip are blue and the left plate's green in both appearances; "SPACE" is set in the plain face; the plates' corners are visibly tighter than the stage plate's; and the gold CTA plate carries dark ink.

## Verification

```
$ bash scripts/build.sh
Build complete! (7.06s)                              # exit 0

$ AUDIOUT_TEST_NO_CACHE=1 bash scripts/run-tests.sh --filter 'AlignmentPlateCellTests|AlignmentStageViewTests|AlignmentTokenContrastTests|BTSyncDrawerViewTests|PopoverBTAlignmentUITests'
Test run with 132 tests in 8 suites passed after 8.262 seconds.
# pre-flight baseline was 127; +6 added, −1 deleted (D12) = 132

$ AUDIOUT_TEST_NO_CACHE=1 bash scripts/run-tests.sh
Test run with 3460 tests in 198 suites passed after 155.042 seconds.
# CompanionEndToEndTests flaked on the first attempt (6 socket-timing issues,
# unrelated to this PR) and passed on the runner's retry.

$ git grep -n "Color\.\(plateRim\|inkOnGold\|syncSignal\|partySignal\|partySignalDeep\)\b" -- AudioutCore
AudioutCore/Sources/AudioutPopoverUI/AGENTS-HISTORY.md:55      # archived history, kept by design (PR 9)
# no Swift hit

$ git grep -n "Tokens\.Color\.glow\|Tokens\.Color\.ember\|accentStyle" -- AudioutCore/Sources/AudioutPopoverUI/AlignmentStageView.swift
# no output

$ git grep -n "inkSecondary\|secondaryLabel\|inkTertiary\|tertiaryLabel\|answerPlateFont\|monospacedSystemFont" -- <the eight wizard/drawer files>
# no output

$ git grep -n "cornerRadius: CGFloat = \(6\|7\|12\)$" -- <the wizard files + PopoverColumnGrid.swift>
# no output
```

## Owed checks (do not block this PR)

- Eye check in a dev build: the blue reference light beside the green one on the live stage, dark and light — and in LIGHT mode especially, where the two plate rims are 1.02:1 apart and hue is the only thing separating them.
- The fused ring's `×0.85` opacity over the green halo, tuned against magenta. The risk changed with the hue: composited over the green halo, blue moves toward the target's own colour, so what to look for is the reference ring reading teal and losing whose light it is.
- **The drawer's drawn edge, both appearances.** It overrides a live-observed "no drawn edge" finding (D10), and it now uses two weights: `containerEdge` on the sides and bottom that bound the recess, `hairline` across the top, which is a divider between two rows rather than a card edge. Worth confirming the top reads as lighter than the sides and that the whole thing still reads as a recess.
- The semibold 12 pt value field against the small stock buttons; the r 10 keycap chip at 22×22.
- The promotion detent now doubles the span shadow's opacity (0.35 → 0.7) rather than relying on the colour: confirm the notch is visible without reading as a flash.
- The room spill's right wash in dark mode is blue at 0.10 — whether it still reads as a wash and not a stain.
- Settings readout wells (`SettingsForm.readoutWell`) inherit the semibold weight: PR 6's call to keep or split.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
