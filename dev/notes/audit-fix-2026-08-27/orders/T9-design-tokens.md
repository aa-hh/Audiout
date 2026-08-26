# T9 — Design tokens: contrast, accent-dial observers, type governance

**Branch:** `claude/fix-design-tokens` (worktree under `.claude/worktrees/`, push to `origin/claude/fix-design-tokens` immediately). Repo root: `/Users/alechenderson/Projects/AirPlay Controller/.claude/worktrees/xenodochial-ardinghelli-fa348b` (path has a space — quote it). Working tree was CLEAN at scoping time.

**BINDING BUILD/TEST RULE:** every compile and test run goes through the wrapper scripts, which route to the remote test mule: `bash scripts/build.sh` and `bash scripts/run-tests.sh --filter <Suites>`. Bare SwiftPM build/test invocations (typing the toolchain commands directly) are FORBIDDEN — they opt out of the mule, the machine-wide concurrency cap, and the unchanged-sources cache, and pin work to the machine running many parallel agents. `AUDIOUT_BUILD_LOCAL=1` only if the mule is unreachable, and report that you used it. Never pipe `run-tests.sh` through `| tail` (it eats the exit code — read the full output). Never kill or abandon an in-flight remote test run (orphaned legs pin the build lock).

**T9-owned files (free edits):**
- `AudioutCore/Sources/AudioutSharedUI/Tokens.swift`
- `AudioutCore/Sources/AudioutSharedUI/LevelMeterView.swift`
- `AudioutCore/Sources/AudioutSharedUI/RouteArmedDotView.swift`
- `AudioutCore/Sources/AudioutSharedUI/AGENTS.md` (three wording fixes only)
- `docs/FIGMA-DESIGN-SYSTEM.md`
- New test file `AudioutCore/Tests/AudioutCoreTests/TokenContrastMatrixTests.swift`
- Existing test files listed in steps 12–13 (assertion updates only)

**CONFLICT-EXPECTED one-line swaps in files owned by parallel tracks (T3a/T3b/T8). Make EXACTLY the listed line edits, nothing else in these files:**
- `AudioutCore/Sources/AudioutSharedUI/DeviceRowView.swift` — lines 972, 1797, 3086 (step 4); no other edits
- `AudioutCore/Sources/AudioutSharedUI/MembershipBusView.swift` — lines 151, 157, 205 (step 4)
- `AudioutCore/Sources/AudioutSharedUI/BusRailOverlayView.swift` — lines 278, 332 (step 4)
- `AudioutCore/Sources/AudioutPopoverUI/PopoverPanelViewController.swift` — lines 1113, 1161, 1179, 1268 (steps 4, 10)
- `AudioutCore/Sources/AudioutPopoverUI/PopoverController.swift` — lines 2587, 2678, 2683 (step 4)
- `AudioutCore/Sources/AudioutPopoverUI/GroupRowView.swift` — line 99 (step 8)
- `AudioutCore/Sources/AudioutPopoverUI/BTAlignmentPromptView.swift` — line 59 (step 10)
- `AudioutCore/Sources/AudioutPopoverUI/ConnectionDiagnosisView.swift` — line 126 (step 10)
- `AudioutCore/Sources/AudioutPopoverUI/BTAlignmentWizardView.swift` — line 477 (step 10)
- `AudioutCore/Sources/AudioutSettingsUI/AudioSettingsViewController.swift` — line 592 (step 4)
- `AudioutCore/Sources/AudioutSettingsUI/AppearanceSettingsViewController.swift` — line 383 (step 10)
- `AudioutCore/Sources/AudioutOnboardingUI/SetupRibbonView.swift` — lines 91, 256 (step 10)
- `AudioutCore/Sources/AudioutOnboardingUI/OnboardingViewController.swift` — line 373 (step 10)
- `AudioutCore/Sources/AudioutOnboardingUI/DemoPaneView.swift` — line 1867 (step 10)
- `AudioutCore/Sources/AudioutApp/AppDelegate.swift` — line 1796 (step 10)
- `AudioutCore/Sources/AudioutOnboardingUI/AGENTS.md`, `AudioutCore/Sources/AudioutPopoverUI/AGENTS.md` — one appended ledger bullet each (step 10)

**DO NOT TOUCH:** `FeedPillView.swift` (T3b adds its IC observer), `IconPickerViewController.swift` (T5 adds its observers), the theme-tile accent ring at `AppearanceSettingsViewController.swift:366` (stays — open decision for Alec), any other line of the conflict-expected files, `WarmFaderCell.swift`, `HaloRingView.swift`, `dev/notes/warm-signal-v3.md`, checked-in snapshot PNGs (never regenerate goldens), `Tokens.Color.bluetoothBrand` (audit P3-1 is out of T9), `Tokens.Font.syncReadout` and `DeviceRowView:1396`/`1736` fonts (not in scope). No cleanup, no refactors, no new abstractions, no renames beyond what is written here.

---

## Goal

Bring the token layer up to the app's committed contrast floors (PRODUCT.md:109 — WCAG 4.5:1 text / 3:1 non-text, BOTH appearances), wire the two instruments that miss the accent-dial broadcast, restore type governance at the exact-duplicate font sites, correct stale rationale prose, and add a generalized contrast-matrix test so the "token passed its own test, the composition was never measured" failure class (audit design-system.md, findings P1-1..P1-4, P2-1..P2-4, P2-6, P2-7, P3-2, P3-3) cannot recur silently. Everything is minimal-diff: token-level fixes over call-site sweeps.

## Verified facts (all checked in this session)

- `Tokens.Color.secondaryLabel` is a bare alias of `.secondaryLabelColor` — `Tokens.swift:86`. 93 call sites reach it (grep count); ALL non-text consumers are `contentTintColor` glyph tints (re-derived by grep; e.g. `AudioSettingsViewController.swift:750` minus-circle remove button, `GroupRowView.swift:136/160`, `DeviceRowView.swift:574`, `WarmNameFieldCell.swift:148` pencil at its own alphas). The light replacement `#5C574C` is DARKER than the system value, so every glyph tint only gains contrast in light; dark is unchanged. **No consumer needs the old light value.**
- `inkSecondary` = `warmDynamic(dark: 0xB4ADA0, light: 0x5C574C)` — `Tokens.swift:413-415`; exactly 7 consumer sites, all in `AudioutOnboardingUI` (grep). Its dark hex is AUTHORED (≠ system secondary dark), so retiring it onto the token would visibly change onboarding — keep it (smaller diff: zero consumer edits).
- `feedPillText` — `Tokens.swift:956-961` — resolves `.secondaryLabelColor` dark / `.labelColor` light. Folding it into secondaryLabel would drop light pill text from 13.2:1 (label-on-fill) to 4.52:1 — do NOT fold.
- `warmDynamic`/`scrimDynamic`/`accentDynamic`/`permissionDynamic` read `NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast` at `Tokens.swift:1155, 1177, 1213, 1277`. Tests cannot force that flag (stated in `MembershipWellContrastTests.swift:125-127`).
- `LevelMeterView.swift` — init registers ONLY the workspace a11y observer (`:126-131`); `updateLayerColors()` (`:166-181`) stamps `ember`/`gold`/`caution` CGColors; hook `test_gradientColors` at `:332`. No `accentStyleDidChangeNotification` observer (grep confirms the only observers are BusRailOverlayView:122, EQResponseCurveView:216, HaloRingView:163, OnboardingChrome:121, DemoPaneView:1914).
- `RouteArmedDotView.swift` — init registers only the a11y observer (~`:59-65`); `updateLayerAppearance()` (`:117-133`) stamps `gold`/`glow`/`dotSocket`; `apply(armed:)` at `:88`; hooks `test_fillColor:185`, `test_hasGlow:199`. First `apply` renders settled, no bloom.
- Pattern to copy: `HaloRingView.swift:160-167` — `NotificationCenter.default.addObserver(self, selector: #selector(accentStyleDidChange), name: Tokens.accentStyleDidChangeNotification, object: nil)`, selector at `:169`.
- tertiaryLabel state-bearing sites verified: `DeviceRowView.swift:972` ("Unavailable" sublabel), `:1797` (sync chip "Not set" title color, untuned branch), `:3086` (untuned chip border), `MembershipBusView.swift:151/157/205` (dimmed rail inks; `:207` `.blocked` is a genuinely disabled affordance — stays), `BusRailOverlayView.swift:278/332` (dormant tone), `PopoverPanelViewController.swift:1161` (subsection header) `/1179` (its chevron), `PopoverController.swift:2587` (placeholder row), `:2678/2683` (refusal-note icon+label — one row, one tone; 2678 included so icon and text don't diverge).
- `AudioSettingsViewController.swift:592` — `note.textColor = Tokens.Color.warning` (env-override buffer note; the comment below at `:596-597` names `.warning`). `warningText` exists at `Tokens.swift:401-403`.
- Subtle ember columns — `Tokens.swift:518-519`: `subtle: WarmVariants(dark: 0x6D5B34, darkHighContrast: 0x877146, light: 0xAE9668, lightHighContrast: 0x8A744C)`. Light `#AE9668` measures 2.14:1 on light `well` `#E2DFD3` (recomputed) — the P2-2 failure.
- Font duplicate sites verified: `SetupRibbonView.swift:256` = `NSFont.systemFont(ofSize: 10, weight: .semibold)` ≡ `Tokens.Font.microLabel` (`Tokens.swift:1028-1030`); `AppDelegate.swift:1796` and `DemoPaneView.swift:1867` = `.systemFont(ofSize: NSFont.systemFontSize)` ≡ `Font.body`; `AppearanceSettingsViewController.swift:383` = smallSystemFontSize at `.medium`/`.regular` ≡ `Font.captionMedium`/`Font.caption`; `PopoverPanelViewController.swift:1113` = smallSystemFontSize with a `weight:` parameter — callers pass only `.semibold` (`:558`) and `.medium` (`:1125`), matching `Font.captionEmphasized`/`Font.captionMedium`.
- 11 pt REGULAR sites (exact-match set for the new `detail` case): `BTAlignmentPromptView.swift:59`, `ConnectionDiagnosisView.swift:126`, `PopoverPanelViewController.swift:1268`, `BTAlignmentWizardView.swift:477`. 20 pt BOLD sites (for `display`): `OnboardingViewController.swift:373`, `SetupRibbonView.swift:91`. Non-matching orphans (ledger only): `ConnectionDiagnosisView:121` (11 bold), `BTAlignmentWizardView:416` (11 semibold), `:511` (12), `DemoPaneView:2336` (12), `:2696` (9.5), `:1863` (24 bold), `SetupRibbonView:97` (14.5 medium), `:348` (11.5 semibold).
- `GroupRowView.swift:99`: `activateButton.contentTintColor = isActive ? Tokens.Color.accent : Tokens.Color.secondaryLabel`. No test pins this tint (grep).
- Dead tokens confirmed zero consumers by grep: `Tokens.Color.tertiarySystemFill` (`Tokens.swift:137-139`; only a prose mention in `LevelMeterView.swift:169`, which stays) and `Tokens.Material.sidebar` (`Tokens.swift:1132-1136`; only `Material.popover`/`.windowBackground` are consumed — `AppDelegate.swift:1781`, `AboutView.swift:219`).
- `GroupsWindowTextColorLockTests.swift` FREEZES every Groups-window label to stock semantics (`:100-109` allowed list, `:143-150` negative warm-token loop) and its own failure text says a legitimate change "is a design decision for Alec". The P2-1 token change makes light labels resolve `#5C574C` → the `matchesStock` half fails without step 12c. `inkSecondary` is NOT in its `warmTokens` list (`:74-94`) — do not add the new tokens to that list, or every legitimate secondary label would "match a warm token" in light.
- Identity-equality test assertions that break when `secondaryLabel` stops being the system singleton (all verified fed by `Tokens.Color.secondaryLabel` through `DeviceRowView:574/710/898/2038`, `AppRowView:341`, panel card notes): `AppRowViewTests.swift:404,409,617,629`; `DeviceRowConnectionStateTests.swift:539,546,556,577,590`; `PopoverControllerTests.swift:364,372`; `PopoverPanelHeaderTests.swift:105`; `RouteArmedSignalTests.swift:197`. Also `BTRowsUITests.swift:249,250` assert `== Tokens.Color.tertiaryLabel` on the chip title/border being moved to `inkTertiary`. `OnboardingPermissionColorTests.swift:81-96` documents that plain `==` between two independently-created dynamic NSColors is unreliable — hence the stored-singleton requirement in steps 2–3.
- `DeviceRowConnectBrightenTests` (`:56,64,97`) compares by resolved components (`assertSameHue`) against the same token instance the row stores — unaffected. `EQResponseCurveTests:207-213` resolves `secondaryLabel` under DARK appearances only — unaffected (dark half stays the system color).
- Test-side accent-dial mutation must live in the `SerializedSharedState` extension (`OnboardingPermissionColorTests.swift:32-37` documents real races otherwise).
- No test pins any font at the swapped sites, and no golden-PNG byte comparison exists in the test suite (`popover-snapshot` is a dev tool executable, not a test).
- Baseline (this session): `bash scripts/run-tests.sh --filter "MembershipWellContrastTests|OnboardingPermissionColorTests|GroupsWindowTextColorLockTests|BTRowsUITests|LevelMeterViewTests"` → **"Test run with 84 tests in 8 suites passed after 5.101 seconds."**

### Computed WCAG ratios (relative-luminance formula; grounds: dark canvas #16130F, panel #1D1915, raised #241F1A, well #100D0A; light canvas/panel #FBFBF9, raised #F2F0EA, well #E2DFD3, feedPillFill #D0CDC3)

Every new/changed hex, with its floor:

| Token / hex | vs canvas | vs panel | vs raised | vs well | floor |
|---|---|---|---|---|---|
| secondaryLabel light `#5C574C` | 6.93 | 6.93 | 6.30 | 5.38 | 4.5 |
| secondaryLabel light-IC `#453F35` | 10.06 | 10.06 | 9.14 | 7.80 | 4.5 |
| inkTertiary dark `#969083` | 5.83 | 5.50 | 5.14 | 6.10 | 4.5 |
| inkTertiary dark-IC `#AFA79A` | — | 7.33 | 6.86 | — | 4.5 |
| inkTertiary light `#665F4C` | 6.13 | 6.13 | 5.57 | 4.76 | 4.5 |
| inkTertiary light-IC `#4A443A` | 9.30 | 9.30 | — | 7.22 | 4.5 |
| railDormant dark `#7D7466` | 4.02 | 3.79 | 3.55 | — | 3.0 |
| railDormant dark-IC `#948C7C` | 5.56 | 5.24 | 4.90 | — | 3.0 |
| railDormant light `#8A8272` | 3.67 | 3.67 | 3.34 | (2.85 — not a rail ground) | 3.0 |
| railDormant light-IC `#7A7263` | 4.59 | 4.59 | 4.17 | — | 3.0 |
| Subtle ember light `#877750` (was #AE9668 @ 2.14 on well) | — | 4.24 | — | 3.29 | 3.0 |
| Subtle ember light-IC `#8A744C` (kept; lum 0.1842 < base 0.1892 — strictly darker) | — | 4.33 | — | 3.36 | 3.0 |
| warningText dark-IC `#E09A55` | — | 7.42 | — | — | 4.5 |
| warningText light-IC `#8F4E1D` | — | 6.19 | — | — | 4.5 |
| inkSecondary dark-IC `#C6C0B4` | — | 9.65 | 9.02 | — | 4.5 |
| inkSecondary light-IC `#453F35` | 10.06 | 10.06 | 9.14 | 7.80 | 4.5 |
| success dark-IC `#7BD495` | — | 9.73 | 9.09 | — | 3.0 |
| success light-IC `#246B3C` | — | 6.25 | 5.68 | — | 3.0 |

Recomputed shipped values for the rationale rewrites (step 7): sidebarWarmTint light `#F5F4ED` = 1.06 vs canvas/panel `#FBFBF9`; light-IC `#E8E6DC` = 1.21 vs canvas/panel. meterTrack light `#CBBEA1` = 1.77 vs canvas (IC `#BEAF90` = 2.08). caution light `#B3701C` = 3.86 vs panel/canvas (IC `#8F5A12` = 5.57). faderThumb light `#8A7A62` = 4.02 vs canvas / 3.12 vs well (well number already correct). faderRim light `#9E8D6B` = 2.43 vs well / 3.13 vs canvas (IC `#8A7550` = 3.32 vs well). ringConnected light `#A08C66` = 3.15 vs panel/canvas, 2.86 vs raised, 2.44 vs well; dark `#8D7D5E` = 4.35 panel / 4.07 raised / 4.82 well.

---

## Steps

Steps 1–11 are source; 12–13 tests; 14 docs. Compile-check with `bash scripts/build.sh` after step 11.

**1. Tokens.swift — Increase-Contrast test seam.** Add to the `Tokens` enum (near `accentStyle`, `Tokens.swift:50`): `static var test_increaseContrastOverride: Bool?` — internal (not public), doc comment: test-only override for the live `NSWorkspace` Increase-Contrast flag, `nil` = live value, same seam idea as the views' `test_reduceMotionOverride`; tests must restore `nil`. At the four flag-read sites (`:1155`, `:1177`, `:1213`, `:1277`) change the read to `Tokens.test_increaseContrastOverride ?? NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast`.

**2. Tokens.swift — P2-1, mode-aware `secondaryLabel`.** Replace the alias at `:84-86` with a stored singleton so identity comparisons keep working (`static let`, not a computed var — the doc comment must say why: call sites and tests compare this token by instance identity, and two independently-created dynamic NSColors are not reliably `==`):
dark → `.secondaryLabelColor` (system, unchanged; the system color handles its own IC); light → `NSColor(warmSignalHex:)` `0x5C574C` base, `0x453F35` under Increase Contrast (read the flag with the step-1 seam, same expression as `warmDynamic:1155`). Provider shape copied from `feedPillText` (`:957-961`): `NSColor(name:)` + `bestMatch(from: [.aqua, .darkAqua])`. Write the contrast rationale with the table's numbers, note the light value IS `inkSecondary`'s light hex (one authored light secondary voice), and note the non-text-consumer verification (all glyph tints; light only gains contrast; dark unchanged). Do NOT change `feedPillText` or any `inkSecondary` consumer.

**3. Tokens.swift — P1-3, add `inkTertiary` and `railDormant`.** Two new cases next to `inkSecondary`, both **`static let` singletons** (same identity reason — BTRowsUITests compares the chip colors by `==`), both via `warmDynamic`:
- `inkTertiary`: `warmDynamic(name: "inkTertiary", dark: 0x969083, darkHighContrast: 0xAFA79A, light: 0x665F4C, lightHighContrast: 0x4A443A)`. Rationale: authored tertiary TEXT for state-bearing de-emphasis ("Unavailable", "Not set", subsection headers, empty-state placeholders) — the system `tertiaryLabelColor` alias measures 1.85–2.26:1 on the warm grounds, under every floor; ≥4.5:1 vs canvas/panel/well in both appearances (table numbers); the ≥4.5-on-well constraint necessarily narrows the light gap to `inkSecondary` (6.13 vs 6.93 on canvas) — hierarchy there is carried by size/weight as well as ink. Decorative dimming (readouts, idle suffixes, disabled chrome, decorative chevrons) stays on the `tertiaryLabel` alias.
- `railDormant`: `warmDynamic(name: "railDormant", dark: 0x7D7466, darkHighContrast: 0x948C7C, light: 0x8A8272, lightHighContrast: 0x7A7263)`. Rationale: the membership rail's ONE dormancy tone (§4.7 — dormancy is one flag, one tone), a hue-neutral warm grey ≥3:1 vs canvas/panel/raised in both appearances (table); replaces `tertiaryLabel` (≈2.2:1) on a graphical object with a 3:1 floor; state the guaranteed grounds explicitly — canvas, panel, raised; NOT light `well` (2.85:1) — the rail never draws on `well` (AGENTS.md rule 46 retired `.well` from Groups surfaces).

**4. Consumer one-liners (CONFLICT-EXPECTED; exact swaps, nothing else).**
- `DeviceRowView.swift:972` `Tokens.Color.tertiaryLabel` → `Tokens.Color.inkTertiary`
- `DeviceRowView.swift:1797` (untuned chip title branch `color = Tokens.Color.tertiaryLabel`) → `.inkTertiary`
- `DeviceRowView.swift:3086` (`isUntuned ? Tokens.Color.tertiaryLabel : ...hairline`) → `.inkTertiary`
- `MembershipBusView.swift:151, 157, 205` — the `dimmed ? Tokens.Color.tertiaryLabel :` arm at each → `Tokens.Color.railDormant`. Line 207 (`.blocked`) STAYS `tertiaryLabel`.
- `BusRailOverlayView.swift:278` (`plan.dormant ? Tokens.Color.tertiaryLabel :`) and `:332` (`segColor = Tokens.Color.tertiaryLabel`) → `.railDormant`
- `PopoverPanelViewController.swift:1161` and `:1179` → `.inkTertiary`
- `PopoverController.swift:2587, 2678, 2683` → `.inkTertiary` (2678 is the refusal row's info glyph — same tone as its own label)
- `AudioSettingsViewController.swift:592` `Tokens.Color.warning` → `Tokens.Color.warningText`; update the stale comment right below (`:596`) that names `.warning`.

**5. Tokens.swift — P3-2, IC variants.** `warningText` (`:401-403`): add `darkHighContrast: 0xE09A55, lightHighContrast: 0x8F4E1D`. `inkSecondary` (`:413-415`): add `darkHighContrast: 0xC6C0B4, lightHighContrast: 0x453F35`. `success` (`:424-426`): add `darkHighContrast: 0x7BD495, lightHighContrast: 0x246B3C`. Extend each rationale with the table's IC numbers (house rule 3: every case ships IC variants).

**6. Tokens.swift — P2-2, Subtle light ember.** In `ember`'s subtle column (`:518-519`) change `light: 0xAE9668` → `light: 0x877750` (keep `lightHighContrast: 0x8A744C` — still strictly darker, 3.36 vs 3.29 on well). Extend the doc comment: the previous value measured 2.14:1 on light `well` `#E2DFD3` (the Subtle column was never re-measured after the Direction-04 well deepening); new value 3.29:1 well / 4.24:1 panel, hue 42.5°, saturation 0.41 vs Subtle gold's 0.48 — still the muted, duller companion.

**7. Tokens.swift — P2-3/P2-4, rationale-prose corrections (comments only, no value changes).**
- `sidebarWarmTint` (`:328-343`): rewrite the LIGHT half against the shipped hexes — light `#F5F4ED` = 1.06:1 vs Circuit canvas/panel `#FBFBF9`; light-IC `#E8E6DC` = 1.21:1 vs canvas/panel. Delete the stale `#F2EBDC`/`#E9DFC9`/warm-paper-ground numbers.
- `meterTrack` (`:302-308`): light measured line becomes `#CBBEA1` ≈ 1.77:1 vs canvas `#FBFBF9` (IC `#BEAF90` 2.08:1).
- `caution` (`:551-555`): light `#B3701C` = 3.86:1 vs panel `#FBFBF9` (IC `#8F5A12` 5.57:1).
- `faderThumb` (`:622-628`): light vs canvas becomes 4.02:1 vs `#FBFBF9` (well number 3.12 already correct).
- `faderRim` (`:634-642`): the stated "2.59:1 vs well" becomes 2.43:1 vs the current `#E2DFD3` (still the deliberate just-under-3 rim choice; IC 3.32:1 clears) and "2.83:1 vs canvas" becomes 3.13:1 vs `#FBFBF9`.
- `ringConnected` (`:360-371`): update the light panel number to 3.15:1 vs `#FBFBF9`, and ADD an explicit guaranteed-grounds sentence: guaranteed ≥3:1 vs dark panel/raised/well and vs light panel/canvas; NOT guaranteed on light `raised` (2.86:1) or light `well` (2.44:1) — no ring draws on those today (AGENTS.md rule 46); a future consumer putting a ring on them must re-tune first.

**8. P2-6 — engagedChrome consolidation.**
- `GroupRowView.swift:99`: `isActive ? Tokens.Color.accent :` → `isActive ? Tokens.Color.engagedChrome :`.
- `AudioutSharedUI/AGENTS.md`: in the SYNC-chip bullet (file line 33), fix the drawer-open recipe wording: "the mute pill's engaged recipe: translucent `accent` fill at `mutePillFillAlpha` + accent glyph" → "…translucent `engagedChrome` fill at `mutePillFillAlpha` + `engagedChrome` glyph" (matches shipped `BTSyncDrawerView.swift:412/511`, `DeviceRowView.swift:898`, chip fill `DeviceRowView.swift:3078`).
- Same file: rule bullets 27 and 30 — replace "`tertiaryLabel`" with "`railDormant`" in the two dormancy sentences.
- Do NOT touch the theme-tile accent ring (`AppearanceSettingsViewController.swift:366`) or the icon-picker gold ring — both deliberate, flagged for Alec (Open decisions).

**9. P1-1/P1-2 — accent-dial observers.** In `LevelMeterView.init` (immediately after the workspace observer registration ending `:131`) and in `RouteArmedDotView.init` (after its registration ending ~`:65`), add the `HaloRingView:160-167` observer, same shape:
```swift
NotificationCenter.default.addObserver(self, selector: #selector(accentStyleDidChange),
                                       name: Tokens.accentStyleDidChangeNotification, object: nil)
```
plus an `@objc private func accentStyleDidChange()` calling `updateLayerColors()` (meter) / `updateLayerAppearance()` (dot). Short comment on each: layer-color instrument, AGENTS.md rule 36 / `Tokens.swift:58-71`. Selector-based observation needs no removal (same note as the existing registrations).

**10. P1-4 — type governance.**
- Exact-duplicate swaps: `SetupRibbonView:256` → `Tokens.Font.microLabel`; `AppDelegate:1796` and `DemoPaneView:1867` → `Tokens.Font.body`; `AppearanceSettingsViewController:383` → `isSelectedTile ? Tokens.Font.captionMedium : Tokens.Font.caption`; `PopoverPanelViewController:1113` → `let font = weight == .semibold ? Tokens.Font.captionEmphasized : Tokens.Font.captionMedium` (only `.semibold`/`.medium` are ever passed — `:558`, `:1125`; say so in a one-line comment).
- New `Tokens.Font` cases (doc comments naming their consumers): `detail` = `.systemFont(ofSize: 11)` (the compact explanatory voice: alignment prompt/wizard copy, diagnosis suggestion, popover footer detail) and `display` = `.systemFont(ofSize: 20, weight: .bold)` (the Setup window's display headline). Migrate ONLY the exact-match sites: `detail` → `BTAlignmentPromptView:59`, `ConnectionDiagnosisView:126`, `PopoverPanelViewController:1268`, `BTAlignmentWizardView:477`; `display` → `OnboardingViewController:373`, `SetupRibbonView:91`.
- Update the `Tokens.Font` header comment (`Tokens.swift:966-971`): the "verified via git grep" claim is stale — reword to say the aliases mirror shipped usage as of this pass, and the remaining off-scale sizes are ledgered in the owning folders' AGENTS.md.
- Ledger bullets (append one bullet to each rules list): `AudioutOnboardingUI/AGENTS.md` — "The Setup window runs its own display scale at five ledgered off-token sizes (9.5 pt `DemoPaneView:2696`, 11.5 pt `SetupRibbonView:348`, 12 pt `DemoPaneView:2336`, 14.5 pt `SetupRibbonView:97`, 24 pt `DemoPaneView:1863`) — deliberate, same ledger idea as `DemoSystemColor`; do not tokenise without a type-scale decision." `AudioutPopoverUI/AGENTS.md` — "Three off-token type sites are ledgered, not stray: 11 pt bold `ConnectionDiagnosisView:121`, 11 pt semibold `BTAlignmentWizardView:416`, 12 pt `BTAlignmentWizardView:511`; `Tokens.Font.detail` covers the 11 pt regular voice." (Re-derive the line numbers after your own edits shift them.)

**11. P3-3 — delete dead tokens.** Remove `Tokens.Color.tertiarySystemFill` (`Tokens.swift:137-139`) and `Tokens.Material.sidebar` (`:1132-1136`). Grep-verify zero references before deleting (expect only the LevelMeterView prose comment, which stays).

**12. Existing-test updates (mechanical, identity swaps only).**
- (a) Replace `== .secondaryLabelColor` with `== Tokens.Color.secondaryLabel` at: `AppRowViewTests.swift:404, 409, 617, 629`; `DeviceRowConnectionStateTests.swift:539, 546, 556, 577, 590`; `PopoverControllerTests.swift:364, 372`; `PopoverPanelHeaderTests.swift:105`; `RouteArmedSignalTests.swift:197`. (Works because step 2 makes the token a stored singleton and the sources store that same instance.)
- (b) `BTRowsUITests.swift:249, 250`: `Tokens.Color.tertiaryLabel` → `Tokens.Color.inkTertiary` (both lines; update the message on 250 if it names the old token).
- (c) `GroupsWindowTextColorLockTests.swift`: add `("Tokens.Color.secondaryLabel (mode-aware token)", Tokens.Color.secondaryLabel)` to the `stockSemantics` array (`:100-109`) and update the suite doc comment (`:10-31`): the 2026-07-25 accepted debt on SECONDARY text is superseded by the token-level fix (design-token audit, 2026-08-27) — the lock's real invariant is unchanged and still enforced: no per-label repoint to a warm token; text reaches color only through the sanctioned semantic tokens. Do NOT add `inkSecondary`/`inkTertiary`/`railDormant` to the `warmTokens` negative list (light `secondaryLabel` now equals `inkSecondary`'s light value by design — adding it would fail every legitimate label).

**13. New file `AudioutCore/Tests/AudioutCoreTests/TokenContrastMatrixTests.swift`** — suite `TokenContrastMatrixTests`, `@MainActor`, nested in `extension SerializedSharedState { ... }` exactly like `OnboardingPermissionColorTests.swift:37/435` (it mutates the process-global `Tokens.accentStyle` AND the step-1 IC seam), on `IsolatedSuite`, with a `deinit` restoring `Tokens.accentStyle = .fullGold` and `Tokens.test_increaseContrastOverride = nil`. Port `relativeLuminance`/`contrastRatio`/`resolved(_:appearanceName:)` from `OnboardingPermissionColorTests.swift:55-79` (ported-not-shared is that file's stated convention). Add one helper the ported set lacks: `composited(_ fg: NSColor, over bg: NSColor) -> NSColor` — alpha-composite when `fg.alphaComponent < 1` (the dark system `secondaryLabelColor` is translucent; measure the composite, not the raw components).
- **Test A — the matrix.** Data-driven: entries `(name, token, grounds: [(String, NSColor)], floor: CGFloat)`, swept over appearance `[.aqua, .darkAqua]` × IC `[false, true]` (via `Tokens.test_increaseContrastOverride`), with `Tokens.accentStyle = .fullGold` pinned first. Entries — TEXT, floor 4.5: `secondaryLabel` on canvas/panel/raised/well; `inkSecondary` on canvas/panel/raised; `inkTertiary` on canvas/panel/well; `warningText` on canvas/panel; `feedPillText` on feedPillFill. NON-TEXT, floor 3.0: `success` on panel/raised; `failure` on panel/raised; `caution` on canvas/panel; `gold` on panel/raised/well; `ember` on panel/raised/well; `ringConnected` on panel/raised in DARK, panel only in LIGHT (encode as an appearance-scoped ground list); `faderThumb` on canvas/well; `faderRim` on well; `railDormant` on canvas/panel/raised; `scopeFlatLine` and `scopeBypassLine` on scopeGround. Known-exceptions list keyed `(token, ground, appearance, icOn)` with a reason string — exactly one entry: `("faderRim", "well", light, ic=false)`, reason: deliberate just-under-3:1 rim ("reads as a rim, not a stripe", Tokens rationale; the IC variant clears 3.32:1). Assertion logic per pair: not listed → `#expect(ratio >= floor, "<name> vs <ground> <appearance> ic=<ic>: <measured>:1 under <floor>:1")`; listed → `#expect(ratio < floor, "listed exception now PASSES (<measured>:1) — remove it from the exceptions list")` (the list self-cleans). Every message prints the measured ratio. The suite doc comment names the deliberate exclusions and why: permission hues, `bluetoothBrand`, `goldCTA`, gold-on-raised (swept by `OnboardingPermissionColorTests`); surface-separation floors (`MembershipWellContrastTests`); `glow`/`dotSocket`/`meterTrack`/`sidebarWarmTint`/surface ladder (floor-exempt quiet backdrops per their rationales); the `warning`/`destructive`/`info` system aliases (OS-owned values — KNOWN failure: bare `warning` measures ≈2.1:1 as a light glyph; its text consumer moved to `warningText` in this pass, the remaining glyph consumers belong to other tracks' findings; pinning an OS-owned hex would be brittle).
- **Test B — Subtle-column pin (P2-2).** With `Tokens.accentStyle = .subtle`: light `ember` ≥3.0 vs well AND panel; light `gold` ≥3.0 vs well AND panel (expected 3.29/4.24 and 3.08/3.97). Restore the dial after. Doc note: this is the audit's "extend MembershipWellContrastTests to the Subtle column", placed here because dial mutation requires the serialized suite (`OnboardingPermissionColorTests.swift:32-36`).
- **Test C — accent-dial re-stamp (P1-1/P1-2 regression).** (i) `Tokens.accentStyle = .fullGold`; `let meter = LevelMeterView()`; capture `meter.test_gradientColors`; set `.subtle`; expect the first gradient color's resolved sRGB components changed (tolerance compare, NOT `==`). (ii) `let dot = RouteArmedDotView()`; `dot.apply(armed: true)`; capture `dot.test_fillColor`; set `.subtle`; expect the fill's resolved components changed. Restore `.fullGold`.

**14. docs/FIGMA-DESIGN-SYSTEM.md — P2-7 (three untruths) + bookkeeping.**
- (a) Replace the "**Figma light is AHEAD of code.**" paragraph (`:357-360`): the Circuit pull LANDED (PRODUCT.md:84 dates it 2026-08-11); code ships light canvas `#FBFBF9` (`Tokens.swift:210`); Figma and code now describe the same light state.
- (b) Rewrite the "**Two NEW tokens the code does not have yet**" intro (`:342-348`) in past tense: both landed — `feedPillFill` `Tokens.swift:942`, `feedPillText` `:956`.
- (c) Mapping table (`:321-329`): record the shipped departures with measured reasons: `well` → Circuit `bg/highlight`, then re-tuned off-sheet to `#E2DFD3` (`bg/subtle` measured 1.06:1 vs the flat Circuit panel, under the 1.10:1 surface floor; then the deepening for the 1.15:1 raised-vs-well floor — `Tokens.swift:246-256`); `hairline` → `border/normal` `#D0CDC3` (`border/divider` measured 1.21:1, under the 1.25:1 separator floor — `Tokens.swift:280-284`); `separator` stays as mapped; `sidebarWarmTint` light is `#F5F4ED` (off-sheet, near `bg/normal`).
- (d) Remove `tertiarySystemFill` from the `:327` table row and the `:300-301` approximations bullet (deleted in step 11).
- (e) Append a short "Owed to Figma (wrap-up)" list at the end of the Light-mode section: variables to add — `secondaryLabel` (now mode-aware: light `#5C574C`/HC `#453F35`), `inkTertiary`, `railDormant`, Subtle-ember light `#877750`, IC variants for `warningText`/`inkSecondary`/`success`, `Tokens.Font.detail` (11 pt) + `display` (20 pt bold) text styles; variables to delete — `tertiarySystemFill` (and drop the sidebar material note). Root AGENTS.md's "Figma mirrors the UI code" rule — the Figma edit itself is NOT this track's job; this list is the handoff.

---

## Verification

Baseline observed BEFORE any change (this session): filtered run of the five closest suites → `Test run with 84 tests in 8 suites passed after 5.101 seconds.`

Run, in order, and paste the output:
1. `bash scripts/build.sh` → builds clean.
2. `bash scripts/run-tests.sh --filter "TokenContrastMatrixTests|MembershipWellContrastTests|OnboardingPermissionColorTests|GroupsWindowTextColorLockTests|BTRowsUITests|LevelMeterViewTests|PopoverControllerTests|DeviceRowConnectionStateTests|AppRowViewTests|RouteArmedSignalTests|PopoverPanelHeaderTests|DeviceRowConnectBrightenTests|EQResponseCurveTests|FeedColumnTests|SettingsAccentAndHintsTests|WarmFaderCellTests|RingRailToneLockTests|MembershipBusTests|MembershipRailTests|BTSyncDrawerViewTests|GroupRowViewTests"` → all pass.
3. `AUDIOUT_FULL_SUITE=1 bash scripts/run-tests.sh` → full suite passes. (Known context: the full suite can be flaky under machine load — rerun a failed unrelated suite once before reporting it.)

Done = all three commands run in your session and pass, output pasted. A report without pasted output is not done.

## Acceptance checklist

- [ ] Every hex in the computed-ratios table is in `Tokens.swift` exactly as written, and its doc comment carries the table's numbers.
- [ ] `Tokens.Color.secondaryLabel`, `inkTertiary`, `railDormant` are stored singletons (`static let`) — required by the identity-equality tests in step 12.
- [ ] All consumer swap lines (steps 4, 8, 10) done; `git diff --stat` shows NO conflict-expected file with changes beyond its listed lines (plus the two AGENTS ledger bullets).
- [ ] Grep for `Tokens.Color.tertiarySystemFill` / `Tokens.Material.sidebar` returns nothing in Swift sources.
- [ ] The matrix test prints measured ratios in failure messages and carries exactly one exceptions entry (faderRim/well/light/base) plus the doc-comment exclusion list.
- [ ] `MembershipBusView:207` (`.blocked`) still reads `tertiaryLabel`; the muted feed dim (`DeviceRowConnectBrightenTests` path) untouched.
- [ ] `FeedPillView.swift` and `IconPickerViewController.swift` have zero diff.
- [ ] AGENTS.md edits: sync-chip recipe wording, rules 27/30 railDormant, two ledger bullets — nothing else.

## Open decisions (already made — flag in the PR, don't act)

1. **GroupsWindowTextColorLock supersession (step 12c).** The 2026-07-25 "text stays stock" debt is overridden by PRODUCT.md:109's committed floors via a token-level fix (the freeze's own rationale — simplicity, no per-label repoints — is preserved). Proceed as specified; the PR description must name this supersession explicitly so Alec can veto it.
2. **Theme-tile accent ring** (`AppearanceSettingsViewController:366`) and **icon-picker gold ring** (`IconPickerViewController:277`) deliberately KEEP their non-engagedChrome selection colors — P2-6 leftovers needing Alec's call (standing rule: secondary-colour changes need an ask). List both in the PR under "asks for Alec".
3. **Orphan font sizes**: promoted `detail` (11 regular) + `display` (20 bold) only; the remaining seven sites are ledgered, not tokenised (step 10). A full type-scale pass is a separate task.
4. **inkSecondary kept, feedPillText kept** (smaller diff, no visual change) — recorded in step 2's rationale.

## Executor rules (verbatim)

> - Follow the steps in order. Do not add, merge, reorder, or skip steps.
> - If reality contradicts a Verified fact or a step is impossible as written, STOP and report the discrepancy. Do not improvise a workaround.
> - Before reporting progress, audit each claim against a tool result from this session. Only report work you can point to evidence for. If tests fail, say so with the output.
> - "Done" means the Verification commands were run in this session and passed. Paste their output.
> - Touch nothing in the Out-of-scope / do-not-touch list.
> - Deliver what was asked, at the scope intended. If the spec seems mistaken or a better approach exists, say so in a sentence and continue as specified rather than quietly narrowing, widening, or transforming it.
