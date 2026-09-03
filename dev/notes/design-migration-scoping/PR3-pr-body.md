# Design migration PR 3: rows and instruments

## Goal

Move the shared row components and instruments in `AudioutSharedUI` onto the token foundation PR 1 laid down, so the rows say the iPhone companion's one sentence: warm ink and a gold wash mean "the Mac is sending sound here", cool ink and cool chrome mean it is not. Concretely: a gold 12 % wash behind a sounding row, cool names on silent rows, a semibold tabular readout in `goldText`/`emberText`, a steel-blue connecting ring and a cool `rim` at rest, a `raised`+`rim` fader, a two-stop `ember → gold` meter, flat instruments with no shadow blooms, FEED pills as `well`+`rim` capsules carrying text only, and the deletion of the per-app tether colour (`AppTetherColor`, `FeedChip`). Row geometry (42 pt, 30 pt halo, columns) does not move. This PR is the gate for PRs 4–8: they assume the rows already read this way.

## Decisions

- **D1 "Live" on a device row is `isRouteArmed`** — the row's existing "audio is actually going there" predicate, which already drives the corner dot, the fader gold and the meter visibility. Selection is composition, not sound, and no longer paints a wash. On an app row "live" is `faderCell.isRouteArmed` (routed ∧ running).
- **D2 The device row's selection wash is deleted, together with `paintsSelectionBackground`.** Its only production caller passed `false` and the mixer window does not mount `DeviceRowView`, so the wash has been dead since 2026-07-14. The live wash replaces it, ungated.
- **D3 App row wash order: keyboard selection > live > hover.** `isSelected` is the host's single-selection/focus state and must stay visible over a live row.
- **D4 No halo seat.** The ring draws nothing in `.off`; a permanent seat would put a shape on every idle row that carries no state.
- **D5 Readout font is a new `Tokens.Font.readout`**: monospaced digits at the caption size, semibold — the Mac's nearest cut to the iPhone's 700 weight, at the size that keeps "100%" fitting the 40 pt column.
- **D6 Readout colour has three states:** `goldText` while live, `emberText` while enabled and idle, `labelCool2` while the slider is disabled or the row is in the muted-unconnected treatment.
- **D7 FEED pill text:** `goldText` when the value it names is sounding, else `label2`; `label3` while the row is not adjustable. The "+N" pill is chrome; error pills stay `failure`.
- **D8 FEED pill shape is a capsule** (`cornerRadius = bounds.height / 2`), per the iPhone's destination-pill recipe. `feedPillCornerRadius` is deleted.
- **D9 Selection/hover/live pill radius → `Tokens.Layout.Radius.control` (10).** Mute pill 7 → control; title field 6 → control; fader trough → `faderTrackHeight / 2`; fader thumb → `faderThumbWidth / 2` (the cap becomes a capsule).
- **D10 Blooms.** Every `CALayer` shadow on an instrument goes: the dot's resting glow and its bloom's opacity animation, the ring's arrival-pulse shadow, the rail bead's shadow, the header-dot bloom's shadow. What survives: a flat `gold` disc over `socket`, the dot's `ember → gold` fill transition, the ring's pulse as a `glow`-stroked circle, the bead as a `glow` stroke, the header bloom as a `glow` disc — all still gated by Reduce Motion exactly as today.
- **D11 `railDormant` is re-valued to `rim`'s four hexes.** A dormant rail, an idle connected ring and an unarmed fader fill are then one cool chrome tone.
- **D12 `NoTintOnRingsOrMetersGuardTests` is deleted.** Its reason to exist (the tether tint) is gone and every surviving assertion is duplicated elsewhere.
- **D13 Without chips, three short FEED pills fit** — three bare pills measure ~130 pt of the 136 pt budget, so "System · Music · Safari" no longer collapses to "+1".
- **D14 `WarmFaderCell`'s inner top shade stays** (a drawn 1 px band, not a layer shadow). The thumb's derived highlight and outline go.
- **D15 `EQEditorView`'s divider sits on `raised`**, so it moves to `containerEdge`; the class and hook are renamed so the name does not lie.
- **D16 The name field's border is `containerEdge`** — its own fill is `raised`, where `hairline` measures 1.154:1.
- **D17 `Tokens.Color.destructive` is deleted** (its one consumer moved to `failure`). `warning` stays.

## Interim visible effects this PR finalises and introduces

Finalised: `ringConnected→rim` (HaloRingView now `ring`/`rim`/`rim` outright; WarmFaderCell `rim`; AppTetherColor gone) · `caution→gold` (meter is a real two-stop ramp) · `faderThumb→raised`, `faderRim→rim` (fader re-skinned; the "thumb reads faint" interim ends because the `rim` edge now defines it) · `feedPillFill→well`, `feedPillText→label2` (pills are `well`+`rim` capsules with D7 tints) · `destructive→failure` (menu text re-pointed; alias deleted per D17) · `accent→gold` at DeviceRowView's flash layer only (the other two sites stay on the alias for their PRs) · `dotSocket→socket`, `meterTrack→meter` (aliases deleted).

Introduced: gold 12 % wash behind every sounding device/app row in the popover (there was no wash there before — D2) · cool `labelCool`/`labelCool2` names and sub-labels on silent/unavailable rows · semibold tabular `%` readouts in `goldText`/`emberText`/`labelCool2` · steel-blue `ring` while connecting · no glow around the armed dot; no shadow on the rail bead, header bloom or ring pulse · FEED pills lose their colour chips and the App Routing row loses its name chip · dormant rail turns cool grey (D11) · 10 pt radius on the row pills, mute pill and the Groups rename field; capsule fader cap · `containerEdge` on the rename field and the EQ divider (both in the Groups window).

## Snapshots

`dev/notes/window-snapshots/mixer-*.png` now diverge (rename-field border, EQ divider, dormant rail, dimmed seat) and were NOT regenerated — they are unreproducible goldens; `dev/notes/popover-snapshots/*.png` were regenerated (22 files, no new files).

## Verification

```
$ bash scripts/build.sh
Build complete!

$ AUDIOUT_TEST_NO_CACHE=1 bash scripts/run-tests.sh --filter '<the 26-suite row filter>'
Test run with 651 tests in 29 suites passed after 111.367 seconds.
(baseline before this PR: 682 tests in 31 suites)

$ AUDIOUT_FULL_SUITE=1 AUDIOUT_TEST_NO_CACHE=1 bash scripts/run-tests.sh
Test run with 3455 tests in 198 suites passed after 145.027 seconds.

$ git grep -n "AppTetherColor\|FeedChip\|tetherColor\|appTintColors\|paintsSelectionBackground\|test_isShowingSelectedBackground\|test_dotHasGlow\|test_hasChip\|test_feedChipCount\|test_hasTetherChip" -- AudioutCore
(only comment references the scope explicitly keeps: AppIconCache.swift, AppIconCacheTests, MembershipWellContrastTests, OnboardingPermissionColorTests, and the archived AGENTS-HISTORY.md)

$ git grep -n "Color\.\(ringConnected\|faderThumb\|faderRim\|caution\|dotSocket\|meterTrack\|feedPillFill\|feedPillText\|destructive\)\b" -- AudioutCore
(no output)

$ git grep -n "shadowOpacity\|shadowRadius\|shadowColor" -- AudioutCore/Sources/AudioutSharedUI
(no output)

$ git grep -n "feedChip\|feedPillCornerRadius\|routeArmedGlow" -- AudioutCore
(no output)

$ wc -w AudioutCore/Sources/AudioutSharedUI/AGENTS.md
299

$ git status --short dev/notes/window-snapshots dev/notes/onboarding-snapshots dev/notes/settings-snapshots dev/notes/wizard-snapshots
(no output)
```

Eyeball on `popover-live-routing-dark.png` / `-light.png`: a warm gold wash sits behind the two armed rows and the live app row, the corner dots are flat gold with no halo, idle rows read in cool grey, and the FEED pills are bordered capsules carrying text only (gold on the sounding values).

## Departures from the work order

Three, all reported rather than papered over:

1. **AGENTS.md word cap.** The prescribed STABILITY-bullet shortening alone left the file at 310 words. Two more lines were trimmed (the AGENTS-HISTORY pointer and the Purpose sentence) to reach the stated ≤ 300; the file is now 299.
2. **`AccessibilitySignalSweepTests:196` also read the deleted `test_hasGlow` hook** — the work order's test plan named only the gradient-count change in that file. The one line asserting the resting glow survives Reduce Motion was deleted (D10 removes the glow entirely); `test_isLit` still carries the surviving claim.
3. **`readoutIsEmberTextWhenDestinationIsCurrentDevice` cannot hold.** An explicit "Current Device" pick is a non-standalone destination, so `AppRowView`'s existing routed ∧ running predicate — the one D1 says to reuse unchanged — makes that row live. The test is `readoutIsGoldTextWhenDestinationIsCurrentDevice`. For the same reason, two of the wash tests the plan said would keep (`noHighlightWhenNeitherSelectedNorHovered`, `hoverWashUsesUnifiedHoverAlpha`) were pointed at an unrouted fixture, since their default fixture row is now a sounding row.

## Owed checks (not blocking)

- Eye check in a dev build: the 12 % wash on a live row in both appearances; the capsule fader cap at 10×17; the `ring` steel-blue dash while a speaker connects; whether the flat gold dot still registers at 8 pt without its halo (the 2026-07-23 live note grew it 6 → 8 because it "kind of disappears" — the halo was part of what it was measured against).
- Whether the popover Applications card wants the app-row live wash at all.
- If AppKit's rounding on another Mac tips "System · Music · Safari" over 136 pt, `manualMemberPlusTwoApps` flips back to "+1" — the 6 pt margin is the guard.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
