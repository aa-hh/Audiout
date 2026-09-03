## Goal

Magenta leaves the wizard (C1/R1): the reference light, its halo, its name stamp, its plate rim and its keycap chip ink move from `party`/`partyRampDeep` to `ring` (steel blue), fixed on the stage like the other stage tokens. The plates keep their tinted rims and chips (S5), now green and blue. The rung-promotion flash stops spending gold (S6): it flashes `stageInk`, so the stage carries no gold except its CTA plate. Radii collapse onto the iOS three (control 10 / row 16). The keycap chip stops drawing the word "SPACE" in a monospaced face (iOS One Case); the bare 15 pt plate title and both readouts get named `Tokens.Font` roles at the iOS readout weight. The deprecated aliases this slice is the last consumer of (`plateRim`, `inkOnGold`, `syncSignal`, `partySignal`, `partySignalDeep`) are deleted. The sync drawer gains a 1 pt `containerEdge` rim so the recess reads by edge on the flat light ground. Nothing else on these surfaces changes: the fixed dark stage plate, `fuseWhite`, the two hard half-bars, the plate bevels, the stock drawer buttons and every piece of geometry stay.

## Decisions recorded

- **D1 The stage's reference light is `ring`'s DARK hex in both appearances (`#7FB4C4`).** The stage is a fixed instrument (owner ruling §0 #1; `wireCore` and every other stage token pass one hex for both appearances). `ring` is themed (light `#2C6E86`), and measured on `stagePlate` `#100B07` the light hex is 3.43:1 — over the 3:1 floor but a dim light beside a 14.73:1 green. The dark hex measures 8.60:1 (dark-IC `#9FC7D3` 10.80:1). Mechanism: resolve `Tokens.Color.ring` under `NSAppearance(named: .darkAqua)` — the idiom `AlignmentPlateCell.primaryFillColor` already uses. No new token.
- **D2 The reference PLATE tint is plain `Tokens.Color.ring`** — dark = `#7FB4C4` at full alpha (6.93:1 on dark `raised`), light = `#2C6E86` at the existing `lightRimAlpha` 0.9 (composited on the flat light ground → `#417C92`, 4.45:1; on light `well` → `#3F7A90`, 3.97:1; the chip glyph draws it at full alpha, 5.47:1). `ring` already carries its own light hex, so no "Deep" companion exists or is added; the `isDarkAppearance ? electric : deep.withAlphaComponent(0.9)` shape stays for the TARGET and simplifies for the reference.
- **D3 The room spill's right wash is `Tokens.Color.ring`** in both branches. Light-mode spill is OFF (`peakOpacity` 0), so only the dark hex is ever visible; the appearance fork collapses to one token.
- **D4 The detent flash is `stageInk` on every dial position.** The `Tokens.accentStyle == .subtle ? ember : glow` fork goes; the stage no longer reads `glow`, `ember` or `accentStyle`. `stageInk` `#EFE9DD` is 16.19:1 on the plate and 1.11:1 from `fuseWhite` — the detent is a brightness pulse in the instrument's own ink, not a hue. Its now-dead accent-dial observer and handler are deleted with it.
- **D5 The primary plate's INK is pinned the way its FILL is.** `inkOnFill` flips to WHITE under light Increase Contrast; the plate's fill is pinned to `gold`'s dark hex `#E8B84B`, and white on `#E8B84B` measures 1.84:1. So the plate resolves `inkOnFill` under `.darkAqua` too (`#171104`, 10.18:1) through a `primaryInkColor` static beside `primaryFillColor`, used for both the title and the chip ink.
- **D6 Radii.** Plates → `Tokens.Layout.Radius.control` (10): a plate is a button. Stage plate → `Tokens.Layout.Radius.row` (16): a 504×132 instrument strip is the same class as a row's clip shape or a Groups card; `panel` (26) is the Main Out deck alone. Keycap chip 6 → control (10). First-join note seat 7 → control.
- **D7 `Tokens.Font.keycap` becomes `.systemFont(ofSize: 11, weight: .semibold)`** — the micro-label weight at the chip's existing 11 pt. Measured: "SPACE" 36.58 pt (was 34.00 in the mono face) inside the 44 pt chip. The role keeps its name.
- **D8 The answer plates' 15 pt semibold title becomes `Tokens.Font.plateTitle`.** `heading` is 16 pt and `bodyEmphasized` is 13 pt; 15 is an owner ruling, so it gets a named role rather than a resize.
- **D9 Readouts.** The wizard's stage caption uses `Tokens.Font.readout` (PR 3's 11 pt semibold tabular) for BOTH the hero and the caption; `hero` keeps driving only the colour. The drawer's `Tokens.Font.syncReadout` is re-weighted IN PLACE to `.semibold`, keeping 12 pt; `SettingsForm.readoutWell` inherits the weight — PR 6's call.
- **D10 The drawer's edge is a full 1 pt `containerEdge` stroke on all four sides**, drawn in `draw(_:)` on `bounds.insetBy(dx: 0.5, dy: 0.5)`. The drawer is a full-width row clip in the card stack, so its sides are flush with the card and its top meets the device row. Ratios: light `#AEB3BB` 1.75:1 on `well`, 2.02:1 on the flat ground; dark `#3D4247` 2.01:1 on `well`, 1.77:1 on `panel`. This overrides the live-found "no drawn edge" note — an owed eye check.
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

## Renders

`dev/notes/wizard-v2-handoff/*.png` are pre-restyle reference images and were NOT regenerated (stale, by eye); wizard-snapshot renders were checked by eye in the scratchpad and not committed.

By eye across `3-question-closing-{dark,light}`, `3b-question-near-dark`, `1-intro-light` and `5-proposal-dark`: the right-hand light and its halo are steel blue with no pink anywhere; the right plate's rim and "→" chip are blue and the left plate's green in both appearances; "SPACE" is set in the plain face; the plates' corners are visibly tighter than the stage plate's; and the gold CTA plate carries dark ink.

## Verification

```
$ bash scripts/build.sh
Build complete! (1.53s)                              # exit 0

$ AUDIOUT_TEST_NO_CACHE=1 bash scripts/run-tests.sh --filter 'AlignmentPlateCellTests|AlignmentStageViewTests|AlignmentTokenContrastTests|BTSyncDrawerViewTests|PopoverBTAlignmentUITests'
Test run with 132 tests in 8 suites passed after 10.688 seconds.
# pre-flight baseline was 127; +6 added, −1 deleted (D12) = 132

$ AUDIOUT_TEST_NO_CACHE=1 bash scripts/run-tests.sh
Test run with 3460 tests in 198 suites passed after 194.446 seconds.
# PermissionStateObserverTests flaked on the first attempt (4 timing issues,
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

- Eye check in a dev build: the blue reference light beside the green one on the live stage, dark and light; the fused ring's `×0.85` opacity over the green halo, which was tuned against magenta; the drawer's new rim in light mode — the "no edge" note it overrides was a live finding (D10); the semibold 12 pt value field against the small stock buttons; the r 10 keycap chip at 22×22.
- The room spill's right wash in dark mode is blue at 0.10 — whether it still reads as a wash and not a stain.
- Settings readout wells (`SettingsForm.readoutWell`) inherit the semibold weight: PR 6's call to keep or split.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
