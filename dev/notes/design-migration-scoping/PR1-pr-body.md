PR 1 of the Mac design migration (decisions: `dev/notes/design-migration-scoping/01-decisions.md`). Foundation only: no surface changes its code; PRs 3–8 build on this.

## Goal

Re-value `Tokens.Color` to the iPhone companion's cool ladders (dark and light), add the iOS
instrument/ink tokens the surface PRs will consume, retire or rename the Mac-only tokens through
deprecated aliases so every surface still compiles, delete the Follow-system accent position, and
bundle ClashDisplay-Semibold as `Tokens.Font.wordmark(size:)`. No surface changes its code;
PRs 3–8 do that on top of this foundation.


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


## Interim visible effects (between PR 1 merge and the owning surface PR)

| alias | live surface (file:line) | what the owner will see until the surface PR |
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
  is the fallback. The owner to confirm (a)–(c): embed is permitted, public repo carries no font bytes,
  About credit line lands with Settings.
- The `emberText`/`goldText` Subtle light-IC coincidence (`#584C2E`) — the owner may want the
  emberText one pushed a step deeper.
- `inkOnFill` light-IC = white (D4) — a visible ink flip under Increase Contrast on paper.


## Corrections to the work order, found during execution

- `AppRowViewTests.swift:632/:681` and `DeviceRowConnectionStateTests.swift:544` pinned a live row's tertiary colour to the raw `.tertiaryLabelColor`; the work order re-points `tertiaryLabel` to the authored `label3` and listed those suites as "do not edit". They now compare to `Tokens.Color.label3`.
- The final `grep systemAccent` check has two expected hits: the string literal and doc line inside `accentStyleStoredFollowSystemFallsBackToFullGold`, which exists precisely to prove the stored value falls back. No `.systemAccent` enum reference remains.
- `AUDIOUT_FULL_SUITE=1` exists (a hook names it as the escape hatch for wide refactors); the Verified fact saying it did not was wrong.
- `CompanionServerTests.disconnectReportsTheSameClientIDCommandsCarried` flaked once in a full run and passes in isolation; unrelated to this change.

## Verification

- `bash scripts/build.sh` — exit 0, compiled clean on the remote (deprecation warnings expected: the retired names are aliases now).
- Filtered run of the 18 affected suites: **325 tests in 19 suites passed**.
- Full suite (`AUDIOUT_FULL_SUITE=1`): 3486 tests; the three failures were the `tertiaryLabel` pins above, since fixed. Guard 4 re-runs the full suite at commit.
- Font path: `bash -n` on both scripts; `scripts/fetch-wordmark-font.sh` fetched from Fontshare (sha256 `e70dce86…3c2f60`), hit its cache on the second run, honoured `AUDIOUT_WORDMARK_FONT`, and rejected a corrupt file with exit 1. `.gitignore:52` ignores `ClashDisplay-*`; no font bytes are in this PR.
- `grep -rn "Circuit\|Figma"` over Swift sources and tests: no output (the icon's Figma frame reference in `BrandMark.swift:12` stays by design).

🤖 Generated with [Claude Code](https://claude.com/claude-code)
