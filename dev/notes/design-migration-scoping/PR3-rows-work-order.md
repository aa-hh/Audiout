# PR 3 work order: shared row components and instruments

Executor: Opus. Branch `claude/design-rows`, cut from `origin/main` AFTER PR 1 (`claude/macos-design-md-migration-059ffa`) has merged. Paths are relative to the new worktree. Line numbers cite the files as they are on `main` at `50bb0048`; PR 1 (committed at `586bd8a2`) touches none of the row files below except `Tokens.swift` (cited against that commit), two comment lines in `PopoverColumnGrid.swift` (:682, :759), two comment edits in `WarmFaderCell.swift` (:42-43, :118-119), one comment in `AppTetherColor.swift` (:475-478), and `AccessibilitySignalSweepTests.swift`, whose lines shifted by −8 (cited below at their post-PR-1 positions). If a cited line is off by a few lines because of those, find the quoted text; if the quoted text is absent, STOP.

Every ratio below is WCAG 2.x relative-luminance contrast, computed with `scratchpad/contrast.py` (PR 1's script) plus `pr3_ratios.py` during scoping. Ratios already in PR 1's Token table are quoted from it. The executor may cite any of them without recomputing.

## Goal

Move the shared row components and instruments in `AudioutSharedUI` onto the token foundation PR 1 laid down, so the rows say the iPhone companion's one sentence: warm ink and a gold wash mean "the Mac is sending sound here", cool ink and cool chrome mean it is not. Concretely: a gold 12 % wash behind a sounding row, cool names on silent rows, a semibold tabular readout in `goldText`/`emberText`, a steel-blue connecting ring and a cool `rim` at rest, a `raised`+`rim` fader, a two-stop `ember → gold` meter, flat instruments with no shadow blooms, FEED pills as `well`+`rim` capsules carrying text only, and the deletion of the per-app tether colour (`AppTetherColor`, `FeedChip`). Row geometry (42 pt, 30 pt halo, columns) does not move (S2). This PR is the gate for PRs 4–8: they assume the rows already read this way.

## Scope fences — PR 3 must NOT touch

- No row height, gap, column width, halo diameter, dot diameter, or any other geometry constant in `PopoverColumnGrid.swift`. Radius constants are re-pointed (Step 13) and dead chip/glow constants deleted; nothing else in that file changes value.
- No halo seat fill (Decision D4). No level arc. No row-as-fader. The real `NSSlider` under `WarmFaderCell` stays (root `AGENTS.md`:262/:284).
- `MainOutRowView.swift`, `GroupRowView.swift`, `PopoverPanelViewController.swift`, `CardView.swift`, every file under `AudioutWindowUI`, `AudioutOnboardingUI`, `AudioutSettingsUI`, `AudioutApp`: untouched. The ONLY edits outside `AudioutSharedUI` and `Tests` are in `AudioutPopoverUI/PopoverController.swift` (Step 15 — removing the tether plumbing and one init label) and `AudioutWindowUI` is not edited even though `WarmNameFieldCell`/`EQEditorView` are mounted there.
- `MembershipBusView.rimColor(for:)` (:308-314), `BusRailOverlayView.originColor(for:)` (:318-320) and the `.connecting` segment tone (:376-380): the gold/failure/ember and `railDormant` split stays as is. Only the dimmed seat token and the two blooms change in the rail files.
- `Tokens.swift`: only (a) delete the aliases Step 16 names, (b) re-value `railDormant`, (c) add `Tokens.Font.readout`, (d) the doc-comment edits Step 16 names. No other token moves. No new token beyond `Font.readout`.
- `WarmCanvasView`, `SidebarWarmSurfaceView`, `DeviceIconWellView`, `GroupedSectionView`, `EmitterFieldView`, `SetupCardView`: untouched (`iconSeatFill` and `accent` aliases stay for them).
- The SYNC chip (`SyncChipCell`, DeviceRowView.swift:3190-3232) keeps its `hairline` border, `syncChipCornerRadius` (5) and dash geometry; only its two `inkTertiary` reads are renamed to `label3` (Step 1.11).
- Icon tint stays `label2` on every device row (PopoverControllerTests:455/:465 pin "always neutral"); the iOS glyph-follows-name temperature is NOT adopted here.
- `MembershipRowView` (Groups window) keeps its `inkTertiary`; the Groups PR owns it (C5).
- `AlignmentPlateCell`, `alignPlateCornerRadius` (12): the wizard PR's.
- No regeneration of `dev/notes/window-snapshots/*.png`, `dev/notes/onboarding-snapshots/*.png`, or any settings/wizard PNG. `dev/notes/popover-snapshots/*.png` ARE regenerated (Step 19).
- No `make-app.sh`, no live-test slot, no dev build.
- No `.impeccable`, no `DESIGN.md`, no `PRODUCT.md`, no `docs/FIGMA-DESIGN-SYSTEM.md`, no `ROADMAP.jsonl` (both mention `AppTetherColor`; the documenter's PR 9 owns them — listed in Hand-off). `AGENTS-HISTORY.md` is archived and not maintained: do not edit it.
- No cleanup, no abstractions, no error handling for impossible cases, no backwards-compat shims. When a parameter or type loses its last consumer it is deleted, not kept "for compatibility".
- Do not edit any other file in `dev/notes/design-migration-scoping/`.

## Decisions recorded (the executor does not re-open these)

- **D1 "Live" on a device row is `isRouteArmed`** (DeviceRowView.swift:612-614: `mainMixArmed = activeMember && isConnected && !device.isMuted && !masterMuted; isRouteArmed = mainMixArmed || hasLiveFeeds`). It is the row's existing "audio is actually going there" predicate — it already drives the corner dot, the fader gold and the meter visibility. Selection (`isSelectedInSet`) is composition, not sound, and no longer paints a wash. On an app row "live" is the existing `faderCell.isRouteArmed` (AppRowView.swift:272: routed ∧ running).
- **D2 The device row's selection wash is deleted, together with `paintsSelectionBackground`.** Its only production caller passes `false` (PopoverController.swift:2581), the mixer window does not mount `DeviceRowView` (`MembershipRowView.swift:15` — "Deliberately NOT `DeviceRowView`"), so the wash has been dead since 2026-07-14 (DeviceRowView.swift:378-381). The live wash replaces it, ungated: gold 12 % behind an armed row in every non-menu host. Ten test call sites and one production call site drop the label (Step 15, Test plan).
- **D3 App row wash order: keyboard selection > live > hover.** `isSelected` on `AppRowView` is the host's single-selection/focus state (AppRowView.swift:210-217), which must stay visible over a live row; it keeps `engagedChrome` at `rowSelectionWashAlpha`. Live and hover are exclusive, as selection and hover are today.
- **D4 No halo seat.** The Mac ring draws nothing in `.off` (HaloRingView `.none`, DeviceRowView.swift:113); a permanent seat would put a shape on every idle row that carries no state, and the ring is not a tap target here. A fill inside the 30 pt circle would not change the footprint, but it is not asked for by S2's "colour pass" and is OUT.
- **D5 Readout font is a new `Tokens.Font.readout`**: `.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)`. `syncReadout` (Tokens.swift:1181-1183) is 12 pt medium for the drawer's editable field; the row's `%` must stay at the caption size so "100%" keeps fitting the 40 pt readout column (S2), and iOS's readout weight is 700 — semibold is the Mac's nearest cut (`microLabel` precedent). PR 1 added no readout role.
- **D6 Readout colour has three states:** `goldText` while live (D1); `emberText` while enabled and idle; `labelCool2` while the slider is disabled or the row is in the muted-unconnected treatment (`controlsMuted`) — the cool dim rung the brief's "unavailable rows keep their dim treatment on the cool family" prescribes.
- **D7 FEED pill text:** `goldText` when the value it names is sounding, else `label2`; `label3` while `controlsMuted` (replaces today's `tertiaryLabel` dim). The main-mix pill ("System"/group name) is sounding when `mainMixArmed` (D1's first term — store it); app pills are sounding when `hasLiveFeeds` (`feedAppNames` IS the confirmed live set then, DeviceRowView.swift:622). The "+N" pill is chrome: `label2`/`label3`. Error pills stay `failure`.
- **D8 FEED pill shape is a capsule** (`layer.cornerRadius = bounds.height / 2` in `layout()`), per iOS "the destination pill … a `well` + `rim` capsule" (DESIGN.md:585, :726-730) and brief item H. Brief item L's "feed pill 5 → 10" is superseded by H. `feedPillCornerRadius` is deleted.
- **D9 Selection/hover/live pill radius → `Tokens.Layout.Radius.control` (10).** A radius is not geometry (S2 concerns height/gap/columns). The constant is shared, so `GroupRowView` and `PopoverPanelViewController`'s hover pills follow without being edited. Mute pill 7 → control; title field 6 → control; fader trough → `faderTrackHeight / 2` (2.5, unchanged); fader thumb → `faderThumbWidth / 2` (5; was 4 — the cap becomes a capsule, iOS "22×34pt `raised` capsule cap with `rim`", DESIGN.md:661).
- **D10 Blooms.** Every `CALayer` shadow on an instrument goes: the dot's resting glow (RouteArmedDotView.swift:136-139, :142) and its bloom's `shadowOpacity` animation (:178-183); the ring's arrival pulse shadow (HaloRingView.swift:388-390, :394); the rail bead's shadow (BusRailOverlayView.swift:620-622, :626) and the header-dot bloom's shadow (:732-734, :738). What survives: the dot is a flat `gold` disc over `socket` (iOS: "the document's glow was a zero-offset coloured halo, which is decoration rather than depth", audiout-remote DeviceRowView.swift:672-674); the dot's `ember → gold` fill transition stays (a colour transition, not a bloom); the ring's arrival pulse stays as a `glow`-stroked circle that fades and contracts; the bead stays a `glow` stroke travelling the wire; the header-dot bloom stays a `glow` disc that swells and fades. All four transients are `glow`'s sanctioned use ("the touch-down flash", DESIGN.md:270-271) and remain gated by Reduce Motion exactly as today. `routeArmedGlowRadius`/`routeArmedGlowOpacity` are deleted; `routeArmedDotBoxSize` (18) stays (geometry).
- **D11 `railDormant` is re-valued to `rim`'s four hexes** (`#6B767D` / `#818B90` / `#66717A` / `#586269`). rows.md Option A names the re-tune ("ringConnected + railDormant → cool-neutral values"); PR 1's Token table kept the warm `#7D7466` and marked it "kept, re-measured", so the re-tune is still owed and lands here. The token keeps its name and its `static let` (BusRailOverlayView.swift:319, :377 consume it). A dormant rail, an idle connected ring and an unarmed fader fill are then one cool chrome tone.
- **D12 `NoTintOnRingsOrMetersGuardTests` is deleted.** Its reason to exist (the tether tint) is gone; every surviving assertion is duplicated: meter stops → `RouteArmedSignalTests.meterGradientIs…` (rewritten), failure-never-in-meter → `RouteArmedSignalTests.failureRedNeverAppearsInAMeter` + `AccessibilitySignalSweepTests.meterGradientSurvivesDisplayOptionsChange`, ring hue → `DeviceRowConnectionStateTests:118-133`, bus node enum → `MembershipBusTests`, `test_meterTarget >= 0` asserts nothing.
- **D13 Without chips, three short FEED pills fit.** Measured with `NSAttributedString.size()` at `Tokens.Font.caption` (11 pt regular) on this Mac: "System" 38.68, "Music" 30.99, "Safari" 30.26, "+1" 12.16. Pill width = text + 2×4 padding (`feedPillHorizontalPadding`), gap 3, budget `feedColumnWidth` = 136. Three bare pills = 129.93 ≤ 136 → "System · Music · Safari"; today the two 9 pt chips push it to 147.93 → "+1". `FeedColumnTests.manualMemberPlusTwoApps` and the chip test therefore change their expected string (Test plan). The margin (6 pt) is well over the per-run rounding drift the repo has seen.
- **D14 `WarmFaderCell`'s inner top shade (:93-101, `insetShadeAlpha`) stays.** It is a drawn 1 px band, not a `CALayer` shadow; the brief names only the trough/thumb tokens. The thumb's derived highlight and derived outline (:214-239) go: they derive from the `faderThumb` alias being deleted, and the iOS cap is `raised` body + `rim` edge and nothing else.
- **D15 `EQEditorView`'s divider sits on `raised`** (`eqWell = GroupedSectionView()` fills `Tokens.Color.raised`, DeviceDetailViewController.swift:83, GroupedSectionView.swift:92) → Rule 5 → `containerEdge`. The class and hook are renamed so the name does not lie.
- **D16 The name field's border is `containerEdge`** (its own fill is `raised`, WarmNameFieldCell.swift:107; Rule 5). On light paper the fill equals the ground (1.000) and the 2.02:1 edge is the whole field, which is the iOS light rule ("separation there is edge weight, not fill", DESIGN.md:195).
- **D17 `Tokens.Color.destructive` alias is deleted** if, after Step 2.6, `git grep -n "Color.destructive" AudioutCore` is empty (its one consumer is AppRowView.swift:727). `warning` stays (banners).

## Pre-flight (from the NEW worktree root)

```bash
git fetch
git worktree add .claude/worktrees/design-rows -b claude/design-rows origin/main
cd .claude/worktrees/design-rows
git push -u origin claude/design-rows
git config core.hooksPath .githooks
git log --oneline -1            # must be AT or AFTER the PR 1 merge commit; if PR 1 is not on origin/main, STOP
grep -n "static let labelCool2\|static var goldText\|enum Radius\|static var socket\|static var meter\b\|static var rim" AudioutCore/Sources/AudioutSharedUI/Tokens.swift   # all six must hit (`586bd8a2`: :402, :490, :1288, :653, :334, :318); else STOP (PR 1 not merged)
bash scripts/build.sh           # exit 0 (deprecation warnings expected: PR 1 left ~350)
AUDIOUT_TEST_NO_CACHE=1 bash scripts/run-tests.sh --filter 'RingRailToneLockTests|NoTintOnRingsOrMetersGuardTests|DeviceRowConnectionStateTests|WarmFaderCellTests|AppRowViewTests|FeedColumnTests|AppTetherColorTests|RouteArmedSignalTests|DeviceRowConnectBrightenTests|BTRowsUITests|MembershipBusTests|TokenContrastMatrixTests|AccessibilitySignalSweepTests|RailConnectPulseTests|GroupsWindowTextColorLockTests|MembershipWellContrastTests|GroupRowViewTests|EQEditorViewTests|EQResponseCurveTests|LevelMeterViewTests|PopoverControllerTests|RemovalUndoTests|CastVolumePendingTests|EnergizeTests|GroupRenameFieldTests|GroupsHeaderParityTests|SettingsAccentAndHintsTests|DeviceRowAirPlay1LiveTests'
#   record the printed "Test run with N tests in M suites" line — this is the baseline
```

Baseline note from scoping (2026-09-03): the scoping worktree was mid-PR-1 (another agent editing `Tokens.swift`), so PR 3's filtered baseline could not be run there. PR 1's scoping baseline at `50bb0048` was "205 tests in 17 suites passed" for ITS filter; PR 1's own Verification runs the full suite green before merge. The executor's pre-flight run above IS PR 3's baseline: it must be green (PR 1 already re-pointed `DeviceRowConnectionStateTests:544` and `AppRowViewTests:632/:681` to `== Tokens.Color.label3`, so nothing is expected red).

Never a bare `swift build`/`swift test`. `run-tests.sh` forwards `--filter` to `swift test` (regex alternation works).

## Verified facts (file:line, checked 2026-09-03 at `50bb0048`)

Row state model
- `isRouteArmed` is computed at DeviceRowView.swift:612-614 from `activeMember` (:610), `isConnected` (:611), `device.isMuted`, `masterMuted`, `hasLiveFeeds` (:609). `mainMixArmed` is a local (:613) and is not stored.
- `nameLabel.textColor = rowTextColor` is assigned at :586, BEFORE `isRouteArmed` is computed at :614. `rowTextColor` is at :2163-2168 (menu highlight → `inkTertiary` if unavailable → `label`/`secondaryLabel` by `isSelectedInSet`). `draw(_:)` re-stamps it in the menu host at :2929.
- `controlsMuted` is set at :634-637; the readout colour at :714-715 (`secondaryLabel`/`tertiaryLabel`); readout font/colour at build time :1500-1501 (`Tokens.Font.caption`, `secondaryLabel`); `readoutLabel.stringValue = VolumePercent.label(...)` at :695.
- The wash: `draw(_:)` :2915-2949; selection branch `isSelectedInSet && paintsSelectionBackground` at :2940-2942 (`engagedChrome` @ `rowSelectionWashAlpha`), hover at :2943-2945 (`engagedChrome` @ `rowHoverWashAlpha`), radius `selectionHighlightCornerRadius` at :2938-2939. `paintsSelectionBackground` is declared at :383, doc :378-382, init param :392, stored :397; `test_isShowingSelectedBackground` at :3015-3022. Callers passing it: PopoverController.swift:2581 (`false`); tests RemovalUndoTests.swift:28, CastVolumePendingTests.swift:29, MembershipBusTests.swift:30 and :86, EnergizeTests.swift:35, FeedColumnTests.swift:28, BTRowsUITests.swift:65, :354, :422, :486, :562 (all `false`). No caller passes `true`. Tests reading `test_isShowingSelectedBackground`: PopoverControllerTests.swift:453, :462 only.
- Flash layer: `Tokens.Color.accent` at :2967, doc :2961-2964, radius :2969.
- Sublabel colours: :1005 (`failure`), :1007 (`inkTertiary` "Unavailable"), :1018 (`secondaryLabel` routing), :1044-1046 and :1058-1065 (Muted, `secondaryLabel`), build-time :1434 (`secondaryLabel`). Icon tint :578 (`secondaryLabel`); mute tint :902 (`engagedChrome`/`secondaryLabel`); EQ tint :933 (`gold`/`secondaryLabel`); accessory buttons :1781 (`secondaryLabel`); removal-undo label :1468 (`secondaryLabel`), button :1474 (`gold`); SYNC chip title :1879-1883 (`engagedChrome`/`label`/`inkTertiary`), border :3230-3231 (`engagedChrome`/`inkTertiary`/`hairline`).
- `StatusKind.connected` doc says "the solid `ringConnected` ring" (:116).
- FEED: `appTintColors` stored :259 (doc :253-258), `apply` parameter :501 (doc :486-492), assignment :623; `updateFeedText()` :1111-1168 with `neutralColor` at :1150 (`tertiaryLabel`/`feedPillText`), app segment colour :1152-1156 via `appSegmentColor(for:)` :1193-1205 (falls back to `AppTetherColor.neutralFallback`), `feedMutedTintAlpha` :1177-1181; `FeedSegment` :1183-1191 (`text`, `color`, `hasChip`); `setFeedSegments` :1234-1300 with `chromeColor` :1243 and the chip attachment at :1247-1252, `pillWidth` :1260-1262; `renderFeedPills` :1308-1317; hooks `test_feedChipCount` :2356-2363, `test_feedNeutralColor` :2380-2386, `test_feedAppSegmentColor(for:)` :2420-2427.
- Hooks: `test_ringStrokeColor` :2294, `test_muteTintColor` :2455, `test_dotFillColor` :2486, `test_dotHasGlow` :2489, `test_readoutColor` :2526, `test_isFaderEngaged` :2532, `test_nameColor` :2737, `test_iconTint` (read by PopoverControllerTests:455/:465).
- `AppRowView`: `Configuration.tetherColor` :121-130 (doc), :133 (init param), :141; `chipPrefix` :296-304; name composition :305-339 (secondaryLabel :314, tertiaryLabel :321, label/secondaryLabel :331 and :337-338); readout :267 and :537-538; menu header `tertiaryLabel` :426; menu subtitle `secondaryLabel` :501; `destructive` :727; `currentHighlightColor` :644-660 (doc), draw :662-675; hooks `test_highlightAlpha` :809, `test_readoutTextColor` :813, `test_nameDisplayText` :827-829 (strips `FeedChip.objectReplacementCharacter`), `test_nameTextColor` :836-847 (skips attachment runs), `test_hasTetherChip` :853-857, `test_idleSuffixColor` :861-866, `test_isFaderEngaged` :1063. `isSelected` doc :210-217; `faderCell.isRouteArmed = !isNoRedirect && configuration.isRunning` :272.
- `PopoverController.swift`: `appTintColors: appTintColorsByName()` at :2704 and :2758; `makeAppRow` computes `tetherColor` :3440-3447 and passes `tetherColor: tetherColor` :3458; `appTintColor(for:)` :3656-3665; `appTintColorsByName()` :3667-3681.

Instruments
- `WarmFaderCell.swift`: trough fill `well` :90, shade :93-101, engaged gradient :116-163, unarmed fill `ringConnected` :168, trough rim `faderRim` :178, thumb radius :205, thumb body `faderThumb` :211, highlight :214-226 (`thumbHighlightFraction` :267), outline :228-239 (`thumbOutlineDarkenFraction` :269); header doc :14-45.
- `HaloRingView.swift`: `.connecting` → `ringConnected` :246; `.connected` → `spineTone` ?? `ringConnected` :250-251; `.failed` → `failure` :255; `.resting` → `ringConnected` :266; docs :121-132; pulse shadow :388-390, `bloom.shadowColor = glow` :394, doc :355-373; hooks :440-473 (`test_strokeColor` :448).
- `LevelMeterView.swift`: `meterTrack` :183; three stops :187-191 (`ember`, `gold`, `caution`); comment "(caution, trailing)" :114-115; doc :184-186; `test_gradientColors` doc :341-343; ballistics and display link untouched.
- `RouteArmedDotView.swift`: shadow stamps :136-139, `shadowOpacity = 0` :142, `dotSocket` :141, `bloomGlowKey` :40, glow animation :178-182, removals :92 and :114, `test_hasGlow` :212-214, header doc :13-16, :21-27, :65-66.
- `MembershipBusView.swift`: `dotSocket` :273 (doc :268-271). `BusRailOverlayView.swift`: `railDormant` :319, :377; bead shadow :620-622, :626 (doc :615-616); header-dot bloom shadow :732-734, :738.
- `FeedPillView.swift`: radius :51; `errorGlyph` tint `failure` :64; fill `feedPillFill` :138 (doc :126-135); `test_text` :154-157 (strips the chip char), `test_hasChip` :161-168; header doc :5-33 describes a fill-only pill.
- `FeedChip.swift` (59 lines) and `AppTetherColor.swift` (517 lines) have these consumers outside themselves: AppRowView.swift:121-141, :302-303, :828; DeviceRowView.swift:210-216, :253-259, :486-492, :501, :623, :1193-1205, :1251, :2420-2427; PopoverController.swift:2704, :2758, :3440-3458, :3656-3681; PopoverColumnGrid.swift:233-267 (`feedChipSize` :250, `feedChipGap` :261, `feedChipCornerRadius` :267 + docs); AppIconCache.swift:11, :48 (comments only — leave); Tokens.swift permission-block comments naming `AppTetherColor.ReservedBand`/`steer`/`AppTetherColorTests` (:769, :782, :788, :877) — comment only; tests: NoTintOnRingsOrMetersGuardTests (whole), FeedColumnTests.swift:210-258, AppRowViewTests.swift:648-682, AppTetherColorTests (whole), OnboardingPermissionColorTests.swift:23, :62, :72 (comments naming the helper's origin — leave), MembershipWellContrastTests.swift:24, :31 (comments — leave), AppIconCacheTests.swift:8 (comment — leave).
- `WarmNameFieldCell.swift`: fill `raised` :107, hover wash :113, border `hairline` :117, radius :104-105 and :177-178, doc :14-18. Host: GroupEditorViewController.swift:289-300 (untouched).
- `EQEditorView.swift`: `advancedHairline = HairlineView()` :118, layout :374-375, :416, hook `test_advancedHairlineFrame` :852, class `HairlineView` :897-916 (`hairline` :910). `EQEditorViewTests.swift:194-202` reads `test_advancedHairlineFrame`. `EQResponseCurveView.swift` "It never themes" doc :34-40.
- `PopoverColumnGrid.swift`: `feedChipSize` :250, `feedChipGap` :261, `feedChipCornerRadius` :267, chip doc :233-249; `feedPillCornerRadius` :288 (doc :285-287); `routeArmedGlowRadius` :420 (doc :418-419), `routeArmedGlowOpacity` :422 (doc :421), `routeArmedDotBoxSize` :429 (doc :427-428); `rowHoverWashAlpha` :554, `rowSelectionWashAlpha` :558 (doc :555-557); `mutePillCornerRadius` :573 (doc :571-572); `selectionHighlightCornerRadius` :589 (doc :588); `faderTrackHeight` :616, `faderTrackCornerRadius` :618, `faderThumbWidth` :623, `faderThumbCornerRadius` :627; `titleFieldCornerRadius` :656 (doc :652-655); `syncChipCornerRadius` :707 (untouched). Consumers of the re-pointed radii: `selectionHighlightCornerRadius` — DeviceRowView :2938-2939, :2969, AppRowView :670-671, GroupRowView :364-365, PopoverPanelViewController :1718-1719; `mutePillCornerRadius` — DeviceRowView :904, MainOutRowView :564; `titleFieldCornerRadius` — WarmNameFieldCell :104-105, :177-178; fader radii — WarmFaderCell :86, :205; `feedPillCornerRadius` — FeedPillView :51. No test reads any of these radii (grep).
- The popover's device rows sit on `panel` (`WarmPanelView.swift:29`); `CardView` fills nothing. The Groups detail card is `raised` (GroupedSectionView.swift:92).
- Snapshots: `popover-snapshot` writes `dev/notes/popover-snapshots/popover-*.png` (22 files, committed) and nothing compares them (`grep -rl "popover-snapshots\|\.png" AudioutCore/Tests` hits only AppIconCacheTests/AlignmentPlateCellTests/WarmFaderCellTests, none of which read a file). Modes: default (+meters), `connection-states`, `live-routing`, `dormant-group`, `local-mix-blocked`, `resting-ring`, `rail-depth`, `feed-composite`, `energize-mid-sequence`, `energize-reduce-motion-static` (popover-snapshot/main.swift:1061-1119). `window-snapshot` renders the real `MixerWindowController` (window-snapshot/main.swift:5, :533) into `dev/notes/window-snapshots/mixer-*.png` (14 files); these are the unreproducible goldens (memory: never regenerate). `DeviceRowView` does NOT mount there (`MembershipRowView.swift:15`); what this PR changes in that window is `WarmNameFieldCell`'s border (GroupEditor header), `MembershipBusView`'s dimmed seat (`socket`, already aliased by PR 1), the rail's dormant tone (D11) and `EQEditorView`'s divider — so the window PNGs diverge and are NOT regenerated (PR body states it).
- Tests: `WarmFaderCellTests` (16 tests, :54-210) assert no token colour — all keep. `RailConnectPulseTests` asserts no shadow property (grep `shadow` → 0 hits); it reads `test_isReceivingRailPulse`, `test_receivedRailPulses`, `test_receiveModelOpacity`, `test_pulseHandoffRuns` — all survive D10. `MembershipBusTests` has no `Tokens.Color` reference. `LevelMeterViewTests` has none. `GroupRenameFieldTests`/`GroupsHeaderParityTests` assert no border colour. `Device(id:name:kind:)` defaults `connectionState: .off` (Device.swift:176), `isAvailable: true` (:170), `isMuted: false` (:173).
- `RingRailToneLockTests.swift:195-208` (test 3) compares a device row's connected ring to `Tokens.Color.ringConnected`; `DeviceRowConnectionStateTests.swift:110-133` compare ring hues; `RouteArmedSignalTests.swift:134-148` assert `test_dotHasGlow`, `:145` `dotSocket`, `:308-315` three meter stops; `AccessibilitySignalSweepTests.swift:285-305` asserts `colors.count == 3` (:292; PR 1 already rewrote its comment to "(ember → gold → gold)" at :287); `DeviceRowConnectBrightenTests.swift:57, :64, :97, :107` assert `test_feedNeutralColor` against `tertiaryLabel`/`feedPillText`; `BTRowsUITests.swift:256-257` assert `inkTertiary`, `:448` `secondaryLabel`; `DeviceRowConnectionStateTests.swift:506-532` mute tint, `:537-554` readout, `:558-572` unavailable name (`inkTertiary`); `AppRowViewTests.swift:370-393` wash alphas, `:399-411` readout `secondaryLabel`, `:611, :619, :631-632, :643` name/suffix colours, `:648-682` tether tests; `FeedColumnTests.swift:66-86` `manualMemberPlusTwoApps` expects "System · Music · +1", `:210-258` tether/chip tests; `PopoverControllerTests.swift:453, :462` selected background.
- Alias consumers after Step 16 (grep of `Sources` + `Tests` at `50bb0048`, PR 1's test edits applied per its plan): `ringConnected`, `faderThumb`, `faderRim`, `caution`, `dotSocket`, `meterTrack`, `feedPillFill`, `feedPillText` have NO consumer once this PR's steps land (their remaining test readers are RingRailToneLockTests:205, DeviceRowConnectionStateTests:120, RouteArmedSignalTests:145/:314, DeviceRowConnectBrightenTests:64/:97, NoTint… (deleted), GroupsWindowTextColorLockTests + TokenContrastMatrixTests + SettingsAccentAndHintsTests (PR 1 already re-pointed)). `iconSeatFill` stays (DeviceIconWellView.swift:252, GroupsOverviewViewController.swift:806). `accent` stays (AppearanceSettingsViewController.swift:365, OnboardingChrome.swift:99). `inkTertiary`/`inkSecondary`/`secondaryLabel`/`tertiaryLabel` stay (dozens of consumers in other targets).
- iOS recipes: wash `gold.opacity(0.12)` (audiout-remote DeviceRowView.swift:597); name `isLive ? label : labelCool`, unavailable `labelCool2` (:816-817); sub-label ladder (:802-810); readout `.readout(16)` = bold + `.monospacedDigit()` (WarmSignal.swift:532-544), `goldText` live (:711-712) / `emberText` idle (AppRouteRowView.swift:365-366); destination pill `Capsule().fill(well)` + `strokeBorder(rim, 0.5)`, text `goldText`/`label2` (AppRouteRowView.swift:311-323); routed dot `gold`/`socket`, no glow (:672-681); connecting ring `ring`, failed `fail`, idle rim `containerEdge` (:647-665); Radius 10/16/26 (WarmSignal.swift:351-353); "never a bloom and never a shadow" (DESIGN.md:829-830, :1180); `lampWell` dark in both appearances (DESIGN.md:333-336); hairline never on raised (DESIGN.md:386-388).

## Step-by-step

Build stays green after every step except between Step 2 and Step 15 (the tether deletion spans SharedUI, PopoverController and tests — run `bash scripts/build.sh` after Step 15, then after every later step). Do Steps 1–14 in order; they are one file each.

### Step 1 — `AudioutCore/Sources/AudioutSharedUI/DeviceRowView.swift`

1.1 Store the main-mix half of the predicate. Next to `private var isRouteArmed = false` (:195) add `private var isMainMixArmed = false` with a one-line doc ("the main-mix term of the armed predicate, read by the FEED column's pill tint"). At :613 assign it: the local `mainMixArmed` is stored into `isMainMixArmed` before `isRouteArmed` is computed.

1.2 Name colour follows liveness. Rewrite `rowTextColor` (:2163-2168): menu highlight → `.selectedMenuItemTextColor` (unchanged); `!device.isAvailable` → `Tokens.Color.labelCool2`; then `isRouteArmed ? Tokens.Color.label : Tokens.Color.labelCool`. Rewrite its doc (:2160-2162): live (D1) reads warm `label`, silent reads cool `labelCool`, unavailable the cool dim `labelCool2` (iOS rule 1). MOVE the `nameLabel.textColor = rowTextColor` assignment from :586 to directly after `armedDotView.apply(armed: isRouteArmed)` (:614), so it sees the freshly computed predicate. Nothing else moves.

1.3 Sublabel colours. :1007 `inkTertiary` → `labelCool2`. :1018 `secondaryLabel` → `isRouteArmed ? Tokens.Color.label2 : Tokens.Color.labelCool2`. :1045, :1046, :1059, :1063, :1065 `secondaryLabel` → `label2` (a muted speaker "is still the Mac's output, so it stays warm", DESIGN.md:640). :1434 build-time `secondaryLabel` → `labelCool2`. :1005 stays `failure`.

1.4 Rename-only re-points (identity unchanged through PR 1's `static let`): :578 icon `secondaryLabel` → `label2`; :902 `secondaryLabel` → `label2`; :933 → `label2`; :1781 → `label2`; :1468 → `label2`; :1883 and :3231 `inkTertiary` → `label3`; :2967 `Tokens.Color.accent` → `Tokens.Color.gold` and rewrite the doc :2961-2964 ("the flash is an attention signal in `gold` — over in under a second, so it is not a resting gold" — no "accent").

1.5 Readout. :1500 `Tokens.Font.caption` → `Tokens.Font.readout`. :1501 `secondaryLabel` → `emberText`. Replace :714-715 with the three-state rule (D6): `if !slider.isEnabled || controlsMuted { labelCool2 } else if isRouteArmed { goldText } else { emberText }`, and rewrite the comment :711-713 accordingly (live = `goldText`, idle = `emberText`, not adjustable = `labelCool2`). `VolumePercent.label` (:695) is untouched.

1.6 Wash. Delete `paintsSelectionBackground`: doc :378-382, declaration :383, the init parameter and its default (:392), the assignment :397. In `draw(_:)` replace :2930-2946 so the non-menu branch reads: same `rect`/`path` (radius via the shared constant, which Step 13 re-points); `if isRouteArmed { Tokens.Color.gold.withAlphaComponent(PopoverColumnGrid.rowLiveWashAlpha).setFill(); path.fill() } else if isHovered { engagedChrome @ rowHoverWashAlpha (unchanged) }`. Rewrite the comment :2930-2935: a gold 12 % wash behind a sounding row (D1, iOS "Wash: gold at 12% behind a live row"), a neutral hover wash otherwise; both reset by `apply`. Replace the hook :3015-3022 with `public var test_isShowingLiveWash: Bool { !isInMenu && isRouteArmed }` and a two-line doc. Delete `test_isShowingSelectedBackground`.

1.7 Halo doc. :116 "the solid `ringConnected` ring" → "the solid `rim` ring".

1.8 FEED column (C4). Delete: the `appTintColors` property and doc (:253-259); the `apply` parameter `appTintColors: [String: NSColor] = [:]` (:501) and its doc lines (:486-492); the assignment :623; `feedMutedTintAlpha` (:1177-1181); `appSegmentColor(for:)` and doc (:1193-1205); `test_feedChipCount` (:2352-2363); `test_feedAppSegmentColor(for:)` (:2415-2427). `FeedSegment` (:1183-1191) loses `hasChip` — it becomes `text` + `color`. In `updateFeedText()` :1141-1157: `neutralColor` becomes the chrome tone `controlsMuted ? Tokens.Color.label3 : Tokens.Color.label2`; the main-mix pill's colour is `controlsMuted ? label3 : (isMainMixArmed ? goldText : label2)`; each app pill's colour is `controlsMuted ? label3 : (hasLiveFeeds ? goldText : label2)`. Rewrite the comment :1141-1149 to D7's rule (no "chip", no "tether"). In `setFeedSegments` :1243 `chromeColor` → `controlsMuted ? label3 : label2`; delete the chip append :1247-1252 so `attributed(_:)` returns the plain attributed text. Rewrite the doc blocks :208-226 and :1094-1110 to drop chip/tether/`AppTetherColor` sentences (pills carry text only; tint = D7). Rewrite `test_feedNeutralColor`'s doc :2380-2385 ("`label3` while `controlsMuted`, `goldText` while the main mix is sounding here, `label2` otherwise"). Delete the `test_dotHasGlow` hook (:2488-2489).

1.9 Search this file for the strings `tether`, `FeedChip`, `AppTetherColor`, `ringConnected`, `chip` (excluding the SYNC chip's own uses, which are a different chip), `paintsSelectionBackground`, `secondaryLabel`, `tertiaryLabel`, `inkTertiary` and `accent` — after 1.1–1.8 every hit must be gone except the SYNC-chip vocabulary. Comments that still describe the deleted mechanism are rewritten, not left.

### Step 2 — `AudioutCore/Sources/AudioutSharedUI/AppRowView.swift`

2.1 Delete `Configuration.tetherColor` (doc :121-129, `public let tetherColor` :130, the init parameter :133 and assignment :141).

2.2 Name composition :296-339: delete `chipPrefix` (:296-304), the orphaned `if let chipPrefix { composed.append(chipPrefix) }` line inside the idle-suffix branch (:310), and the `else if let chipPrefix` branch (:326-334). Two branches remain: idle suffix (composed) and plain. Colours: :314 `secondaryLabel` → `labelCool`; :321 `tertiaryLabel` → `labelCool2`; :337-338 → `(isRouted && isRunning) ? Tokens.Color.label : Tokens.Color.labelCool`. Rewrite the comment :274-295 to say the name is warm `label` while live, cool `labelCool` while not (iOS rule 1); the " (idle)" suffix is `labelCool2`.

2.3 Readout: :537 `Tokens.Font.caption` → `Tokens.Font.readout`; :538 → `emberText`; :267 → `faderCell.isRouteArmed ? Tokens.Color.goldText : Tokens.Color.emberText` — this line must come AFTER :272 (`faderCell.isRouteArmed = …`); move it there. Rewrite the comment :262-266 (live readout `goldText`, stored level `emberText`; iOS "The readout never hides").

2.4 :426 `tertiaryLabel` → `label3`; :501 `secondaryLabel` → `label2`; :727 `destructive` → `failure`.

2.5 `currentHighlightColor` (:653-660): `isSelected` → `engagedChrome @ rowSelectionWashAlpha` (unchanged); `else if faderCell.isRouteArmed` → `Tokens.Color.gold.withAlphaComponent(PopoverColumnGrid.rowLiveWashAlpha)`; `else if isHovered` → unchanged. Rewrite the doc :644-652 to D3's order.

2.6 Hooks: `test_nameDisplayText` (:827-829) → `nameLabel.stringValue`; `test_nameTextColor` (:831-847) → read the foreground colour of the attributed string at index 0 when it has length, else `nameLabel.textColor` (drop the attachment-skipping loop and the chip sentences in its doc); delete `test_hasTetherChip` (:849-857); `test_idleSuffixColor` doc :860 "`tertiaryLabel`" → "`labelCool2`".

2.7 Grep this file for `tether`, `FeedChip`, `chip`, `secondaryLabel`, `tertiaryLabel`, `destructive` — all gone.

### Step 3 — `AudioutCore/Sources/AudioutSharedUI/WarmFaderCell.swift`

3.1 :168 `ringConnected` → `rim`. :178 `faderRim` → `rim`. :211 `faderThumb` → `raised`. Delete the highlight block :214-226 and the outline block :228-239; in their place stroke the thumb path inset by half a hairline with `Tokens.Color.rim.withAlphaComponent(interiorAlpha)` at `Self.hairlineWidth` (the same inset/lineWidth idiom as the trough rim :179-183). Delete `thumbHighlightFraction` (:264-267) and `thumbOutlineDarkenFraction` (:268-269).

3.2 Rewrite the header doc :14-45 with the new recipe and ratios: trough `well` + `rim` (dark 4.38:1, light 4.15:1 on `well`), engaged gold gradient with the ember-blend dim end (dark 6.96:1 / light 3.97:1 on `well`), unarmed fill `rim` (4.38 / 4.15), thumb `raised` body (dark 1.29:1 on the trough, light = the flat ground) read by its `rim` edge (3.39:1 on the dark body, 4.78:1 on the light ground). Drop the "hue-neutral warm `ringConnected` grey" and "dedicated `faderThumb`" sentences and the accent-dial parenthetical PR 1 already trimmed. `armedDimEndGoldBlend`'s doc :270-273 gets the two new numbers (6.96 / 3.97).

### Step 4 — `AudioutCore/Sources/AudioutSharedUI/HaloRingView.swift`

4.1 :246 `ringConnected` → `ring`; :251 → `rim`; :266 → `rim`. Rewrite the docs :121-132 (`connectedSpineArmed`: "the shared `rim` token") and the `.resting` comment :257-265 ("the shared cool `rim`").

4.2 `receiveRailPulse()`: delete :388-390 (`shadowOffset`, `shadowRadius`, `shadowOpacity`) and :394 (`bloom.shadowColor = glow`); the `strokeColor = glow` line stays inside the `performAsCurrentDrawingAppearance` block. Rewrite the doc :355-373: a `glow`-toned copy of the ring that contracts onto the stroke as it fades — a stroke, never a shadow (iOS "never a bloom").

### Step 5 — `AudioutCore/Sources/AudioutSharedUI/LevelMeterView.swift`

:183 `meterTrack` → `meter`. :187-191 → two stops `[ember.cgColor, gold.cgColor]`. The gradient has three named positions too: delete `meterCautionStop` (:79) and `meterGoldStop` (:76) with their docs, and :116 becomes `fillLayer.locations = [0, 1]` (two colours, two stops; gold is the ceiling); comment :184-186 → "the warm ramp (C3): ember low end → gold ceiling. Never `failure` red." :114-115 "(caution, trailing)" → "(gold, trailing)". `test_gradientColors` doc :341-343 → "`ember → gold`". Ballistics, `redrawFill`, the display link: untouched.

### Step 6 — `AudioutCore/Sources/AudioutSharedUI/RouteArmedDotView.swift`

Delete :136-139 and :142 (all shadow stamping); :141 `dotSocket` → `socket`. Delete `bloomGlowKey` (:40), the glow animation (:178-182), and both `removeAnimation(forKey: Self.bloomGlowKey)` lines (:92, :114). Delete `test_hasGlow` and its doc (:211-214). Rewrite the header doc :13-16 (armed → a flat `gold` disc; not armed → the `socket` seat; no halo: "the gold fill against the unlit socket IS the signal") and :21-27 (the bloom is the `ember → gold` fill transition only). :65-66 comment "`fillColor`/`shadowColor`" → "`fillColor`".

### Step 7 — `AudioutCore/Sources/AudioutSharedUI/MembershipBusView.swift`

:273 `dotSocket` → `socket`; :270 comment "`dotSocket` seat" → "`socket` seat".

### Step 8 — `AudioutCore/Sources/AudioutSharedUI/BusRailOverlayView.swift`

Delete :620-622 and :626 (bead shadow) and :732-734 and :738 (header-dot bloom shadow); the `strokeColor`/`fillColor = glow` lines stay. Rewrite :615-616 ("Wider than the wire: a bright bead, drawn as a stroke — never a shadow") and the `runHeaderDotBloom` doc (:713-716) likewise. `originColor`, `railDormant`, the segment tones: untouched (the token itself is re-valued in Step 16).

### Step 9 — `AudioutCore/Sources/AudioutSharedUI/FeedPillView.swift`

9.1 :51 delete the `cornerRadius` line; add `override func layout() { super.layout(); layer?.cornerRadius = bounds.height / 2 }` (capsule, D8). In `init` after `wantsLayer = true` set `layer?.borderWidth = 1`. `updateAppearance()` (:136-140) stamps `layer?.backgroundColor = Tokens.Color.well.cgColor` and `layer?.borderColor = Tokens.Color.rim.cgColor`. Rewrite the doc :126-135 (well + rim, both static `CGColor`s re-stamped on appearance and IC change).

9.2 `test_text` (:150-157) → `label.attributedStringValue.string`; delete `test_hasChip` (:159-168). Rewrite the header doc :5-33: one `well`-filled, `rim`-edged capsule per feed value (iOS destination-pill recipe, DESIGN.md:726-730); text colour is the row's (D7); non-interactive. No "chip", no "fill alone — no border" sentence.

### Step 10 — delete `AudioutCore/Sources/AudioutSharedUI/FeedChip.swift` and `AudioutCore/Sources/AudioutSharedUI/AppTetherColor.swift` (`git rm`).

### Step 11 — `AudioutCore/Sources/AudioutSharedUI/WarmNameFieldCell.swift`

:117 `hairline` → `containerEdge`. Doc :17-18 → "**Border** `Tokens.Color.containerEdge` at `borderWidth` (1 pt) — the field's fill is `raised`, and `hairline` is never drawn on `raised` (1.154:1 dark); `containerEdge` measures 1.55:1 on it in dark and 2.02:1 on the flat light ground, where it is the whole field."

### Step 12 — `AudioutCore/Sources/AudioutSharedUI/EQEditorView.swift` and `EQResponseCurveView.swift`

12.1 Rename `HairlineView` (:897-916) to `ContainerEdgeView`; :910 `hairline` → `containerEdge`; doc :893-896 → "A one-token divider above the Advanced row. The editor sits in a `raised` card (`GroupedSectionView`), and `hairline` is never drawn on `raised` (1.154:1 dark) — `containerEdge` measures 1.55:1 dark / 2.02:1 light there." Rename `advancedHairline` (:118, :374, :375, :416) → `advancedDivider`; hook :852 `test_advancedHairlineFrame` → `test_advancedDividerFrame`.

12.2 `EQResponseCurveView.swift` doc :34-40: append one sentence — "The iPhone companion's `lampWell` (`#050507` dark / `#14120F` light, dark in both appearances so a lit thing has a dark surround to read against) is the same decision; this scope stays on `scopeGround` for the same reason." No code change.

### Step 13 — `AudioutCore/Sources/AudioutSharedUI/PopoverColumnGrid.swift`

13.1 Delete `feedChipSize`, `feedChipGap`, `feedChipCornerRadius` and their docs (:233-267). Delete `feedPillCornerRadius` and its doc (:285-288). Delete `routeArmedGlowRadius`, `routeArmedGlowOpacity` and their docs (:418-422); `routeArmedDotBoxSize` doc :427-428 → "big enough to contain the disc with a margin (unchanged from the halo era; geometry is not re-tuned in this pass)".

13.2 Add, directly after `rowSelectionWashAlpha` (:558): `public static let rowLiveWashAlpha: CGFloat = 0.12` with doc "Alpha of the gold wash behind a SOUNDING row (`DeviceRowView.isRouteArmed`, `AppRowView`'s routed ∧ running) — the iPhone's 12 % (`gold.opacity(0.12)`); measured 1.256:1 on dark `panel`, 1.140:1 on the light ground." Rewrite `rowSelectionWashAlpha`'s doc :555-557: "Shared by AppRowView's single-selection highlight and GroupRowView's selection pill" (DeviceRowView no longer paints a selection wash).

13.3 Re-point: `mutePillCornerRadius` :573 → `Tokens.Layout.Radius.control`, doc "the control radius (iOS Shapes)"; `selectionHighlightCornerRadius` :589 → `Tokens.Layout.Radius.control`, doc "the control radius — shared by the device/app rows' live+hover pills, GroupRowView and the panel header's hover pill"; `faderTrackCornerRadius` :618 → `faderTrackHeight / 2` (doc: capsule); `faderThumbCornerRadius` :627 → `faderThumbWidth / 2` (doc: "capsule cap, iOS fader"); `titleFieldCornerRadius` :656 → `Tokens.Layout.Radius.control`, and rewrite its doc :652-655 (drop the "deliberately NOT a capsule … would collide" argument; it is the control radius every field and button wears).

### Step 14 — `AudioutCore/Sources/AudioutSharedUI/AGENTS.md`

Add to `## Rules` after the "Instruments reconcile accessibility-display changes live…" bullet: "- Warm ink and the gold wash mean `isRouteArmed`; cool ink means silent. Instruments are flat fills and strokes — no `CALayer` shadow blooms." To stay under the file's 300-word cap, shorten the STABILITY bullet to "- Stability findings carry `STABILITY(id)` markers; sketches in [../../../dev/notes/stability-audit-2026-07-18.md](../../../dev/notes/stability-audit-2026-07-18.md)." Verify with `wc -w` ≤ 300.

### Step 15 — `AudioutCore/Sources/AudioutPopoverUI/PopoverController.swift`

Remove `paintsSelectionBackground: false,` from :2581. Remove the two `appTintColors: appTintColorsByName(),` arguments (:2704, :2758). In `makeAppRow` delete the tether comment and `tetherColor` computation (:3440-3447 — NOT :3436-3439, which are the doc tail, the signature, `let row = AppRowView(...)` and `row.delegate = self`) and the `tetherColor: tetherColor` argument (:3458, leaving `isRunning:` as the last argument). Delete `appTintColor(for:)` (:3656-3665) and `appTintColorsByName()` (:3667-3681). Grep the file for `AppTetherColor`, `tether`, `appTintColor` — all gone. Now `bash scripts/build.sh` — expect exit 0.

### Step 16 — `AudioutCore/Sources/AudioutSharedUI/Tokens.swift` (as committed at `586bd8a2`)

16.1 In `Tokens.Font` (`caption` is :1148) add `public static var readout: NSFont { .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold) }` directly after `caption`, with doc: "The row `%` readout (iOS Readout: bold, tabular digits) at the caption size so it keeps fitting the 40 pt readout column; semibold is the system face's cut nearest iOS's 700. `goldText` while sounding, `emberText` while idle, `labelCool2` while not adjustable."

16.2 `railDormant` (:416): replace its four hexes with `dark: 0x6B767D, darkHighContrast: 0x818B90, light: 0x66717A, lightHighContrast: 0x586269` and rewrite its doc: one cool tone for a dormant rail — the same values as `rim`, so a dormant wire, an idle connected ring and an unarmed fader fill are one chrome grey; measured dark canvas 4.25 / panel 3.86 / raised 3.39 (IC raised 4.53, well 5.85); light ground 4.78, well 4.15 (IC well 5.18, ground 5.98). Keep `static let`.

16.3 Delete from the `// MARK: Deprecated aliases (removed by the surface PRs)` block (:1036; `destructive` is :1086): `ringConnected`, `faderThumb`, `faderRim`, `caution`, `dotSocket`, `meterTrack`, `feedPillFill`, `feedPillText`; and `destructive` iff D17's grep is empty. Leave every other alias.

16.4 Doc comments: `glow`'s doc (:600) names "the route-armed dot's static halo and its arm-transition bloom" — rewrite to "the rail bead, the ring's arrival pulse and the header-dot bloom: transient strokes and fills, never a shadow (the armed dot carries no halo)". Grep the file for `AppTetherColor` (:769, :782, :788, :877), `FeedPillView`, `FEED pill`, `tether`, `dotSocket`, `ringConnected`, `caution`, `faderThumb`, `meterTrack` and rewrite each remaining comment sentence so it stands without the deleted name (the permission block's reserved-band rationale keeps its hue numbers; only the "`AppTetherColor.ReservedBand` applies the identical…" attribution goes).

### Step 17 — tests (Test plan below), one file at a time.

### Step 18 — `bash scripts/build.sh`, then the Verification commands.

### Step 19 — regenerate the popover snapshots (documentation images; nothing compares them)

```bash
for m in "" connection-states live-routing dormant-group local-mix-blocked resting-ring rail-depth feed-composite energize-mid-sequence energize-reduce-motion-static; do AIRPLAY_SNAPSHOT_MODE="$m" swift run --package-path AudioutCore popover-snapshot; done
git status --short dev/notes/popover-snapshots      # expect the 22 PNGs modified, no new files
git status --short dev/notes/window-snapshots dev/notes/onboarding-snapshots   # expect NO output
```
(`swift run` of a tool target is the documented way to run the snapshot tools — Package.swift:95; it is not the test/build path the wrapper rule covers.) Open `dev/notes/popover-snapshots/popover-live-routing-dark.png` and `-light.png` with the Read tool and confirm by eye: a warm wash behind the armed row, no halo around the dot, cool names on idle rows, a bordered capsule FEED pill. Report what you saw in one line.

## Ratio table (new to this PR; every other value is in PR 1's Token table)

Grounds: dark `panel` `#15171A` (the popover rows' ground), `canvas` `#0A0A0C`, `raised` `#1F232A`, `well` `#050507`; light ground `#FAFAFB`, `well` `#E9EAEC`. Wash = `gold` at 12 % composited in sRGB.

| pair | dark | light |
|---|---|---|
| live wash composite (Full dial) | `#2E2A20` on panel 1.256; `#251F14` on canvas 1.210 | `#F0EBE0` on ground 1.140 |
| live wash composite (Subtle) | `#292721` on panel 1.203 | `#EDEBE6` 1.142 |
| `label` (.labelColor) on wash | 14.30 | 17.66 |
| `label2` on wash (sub-label of a live row) | 6.37 (canvas-wash 7.28) | 5.24 |
| `goldText` on wash (live readout, live FEED pill text sits on `well`, see below) | 7.76 | 4.97 |
| `goldText` Subtle on wash | 5.36 | 4.57 |
| `gold` dot / fader on wash | 7.76 | 3.20 |
| `rim` ring on wash (connected + live) | 3.07 | 4.20 |
| `ring` on wash (never coincides: connecting is not live) | 6.29 | 4.80 |
| `failure` ring on wash (never coincides) | 3.66 | 5.27 |
| `meter` track on wash | 1.65 | 1.40 |
| `labelCool2`, `emberText` on wash | 4.16, 4.09 — BANNED on a live row (D6/D7 never put them there) | 4.65, 5.33 |
| hover wash composite (`engagedChrome` 10 %) | `#2C2E31` on panel 1.319 | `#E1E1E2` 1.253 |
| `labelCool` / `labelCool2` on panel (idle name / sub-label) | 8.43 / 5.23 | 6.79 / 5.30 (ground) |
| `emberText` on panel (idle readout) | 5.14 | 6.08 |
| `labelCool2` on panel (disabled readout) | 5.23 | 5.30 |
| FEED pill: `label2` / `goldText` / `label3` / `failure` on `well` | 9.07 / 11.04 / 6.78 / 5.22 | 5.17 / 4.90 / 4.86 / 5.21 |
| FEED pill: `rim` on `well` (its edge), `rim` on the row ground | 4.38, 3.86 | 4.15, 4.78 |
| FEED pill: `well` on the row ground | 1.134 | 1.154 |
| name field: `containerEdge` on `raised` (`hairline` would be 1.154 dark — banned) | 1.553 (IC 3.07) | 2.020 (IC 5.27) |
| EQ divider: `containerEdge` on `raised` | 1.553 | 2.020 |
| fader: `raised` thumb on `well` trough; `rim` thumb edge on `raised` | 1.292; 3.39 | 1.154; 4.78 |
| fader: `rim` trough edge / unarmed fill on `well` | 4.38 (was `ringConnected` 4.82) | 4.15 (was 2.60 — now clears 3:1) |
| fader: gold / ember-50 %-gold dim end on `well` | 11.04 / 6.96 | 3.16 / 3.97 |
| meter: `ember` → `gold` on `meter` track | 1.72 → 4.70 | 3.65 → 2.29 |
| meter track on panel / light ground | 2.07 | 1.59 |
| halo: `ring` / `rim` / `failure` on panel | 7.89 / 3.86 / 4.60 | 5.47 / 4.78 / 6.01 (ground) |
| `socket` seat on panel (unlit dot; a lit dot is gold) | 1.31 | 1.26 |
| `railDormant` (= `rim`) on canvas / panel / raised | 4.25 / 3.86 / 3.39 (IC raised 4.53) | 4.78 ground, 4.15 well |

Every text pair on its real ground clears 4.5:1 and every graphic pair clears 3.0:1 except the two pairs marked BANNED (which the rules never produce) and the recess/seat/track quiet-by-design pairs (`meter`, `socket`, `well`, wash composites), matching PR 1's floor-exempt list.

## Interim visible effects this PR finalises (from PR 1's table) and introduces

Finalised: `ringConnected→rim` (HaloRingView :246/:251/:266 now `ring`/`rim`/`rim` outright; WarmFaderCell :168 `rim`; AppTetherColor gone) · `caution→gold` (meter is a real two-stop ramp) · `faderThumb→raised`, `faderRim→rim` (fader re-skinned; the "thumb reads faint" interim ends because the `rim` edge now defines it) · `feedPillFill→well`, `feedPillText→label2` (pills are `well`+`rim` capsules with D7 tints) · `destructive→failure` (menu text re-pointed; alias deleted per D17) · `accent→gold` at DeviceRowView:2967 only (the other two sites stay on the alias for their PRs) · `dotSocket→socket`, `meterTrack→meter` (aliases deleted).

Introduced: gold 12 % wash behind every sounding device/app row in the popover (there was no wash there before — D2) · cool `labelCool`/`labelCool2` names and sub-labels on silent/unavailable rows · semibold tabular `%` readouts in `goldText`/`emberText`/`labelCool2` · steel-blue `ring` while connecting · no glow around the armed dot; no shadow on the rail bead, header bloom or ring pulse · FEED pills lose their colour chips and the App Routing row loses its name chip · dormant rail turns cool grey (D11) · 10 pt radius on the row pills, mute pill and the Groups rename field; capsule fader cap · `containerEdge` on the rename field and the EQ divider (both in the Groups window — the `mixer-*.png` window snapshots diverge and are NOT regenerated).

## Test plan (only these files; every expected value is in the tables above)

- **AppTetherColorTests.swift**: `git rm`.
- **NoTintOnRingsOrMetersGuardTests.swift**: `git rm` (D12).
- **RingRailToneLockTests.swift**: test 3 (:195-208) → compare against `Tokens.Color.rim`; rename `aDeviceRowRingStaysHueNeutralInEveryDialPosition` → `aDeviceRowRingStaysRimInEveryDialPosition`; doc :192-195 says `rim`. Tests 1–2 keep.
- **DeviceRowConnectionStateTests.swift**: :110-116 → `connectingRingIsRingAndConnectedRingIsRim`: connecting's `test_ringStrokeColor` same hue as `Tokens.Color.ring`, connected's same hue as `Tokens.Color.rim`, and the two differ (the connecting form now carries colour as well as dash). :118-122 → `connectedRingUsesRimToken` (rim). :124-133 → `failedRingUsesTheFailureHueNotRim` (failure; not same hue as `rim`). :92 MARK and :10 doc → `rim`/`ring`. :515, :522, :532 `secondaryLabel` → `label2`. :537-545 → `readoutDimsToLabelCool2WhenSliderDisabled` expecting `Tokens.Color.labelCool2`. :547-554 → `readoutIsEmberTextWhenEnabledAndIdle`: `assertSameHue(row.test_readoutColor, Tokens.Color.emberText, …)` (the device is `.off`, so not armed). `goldText`/`emberText` are computed `static var`s returning a fresh `NSColor` per call, so `==` is never used on them (Tokens.swift:101-104; the file's own `assertSameHue` :99-108 is the idiom). `labelCool2`/`label2`/`label` are `static let` and keep `==`. ADD `readoutIsGoldTextWhenLive`: `Device(... connectionState: .connected)`, `apply(selected: true, controllable: true)` → `assertSameHue(row.test_readoutColor, Tokens.Color.goldText, …)`. :558-572 → expect `Tokens.Color.labelCool2`; rewrite the comment (cool dim ink, iOS "Unavailable (`labelCool2`)"). ADD `liveRowNameIsLabelAndIdleRowNameIsLabelCool`: connected + selected → `test_nameColor == Tokens.Color.label`; `.off` + selected → `Tokens.Color.labelCool`.
- **WarmFaderCellTests.swift**: no change; run it.
- **AppRowViewTests.swift**: :399-411 → `readoutIsEmberTextWhenDestinationIsNoRedirect`, `readoutIsEmberTextWhenDestinationIsCurrentDevice` (both `emberText`), `readoutIsGoldTextWhenRedirectedAndRunning` (`goldText`) — all three compare `test_readoutTextColor` by resolved sRGB components (copy `assertSameHue` from DeviceRowConnectionStateTests:99-108 into this file), never `==`, because `goldText`/`emberText` are computed `static var`s. :619 → `labelCool`; :631 → `labelCool`; :632 → `Tokens.Color.labelCool2` (doc :625-628 "cool idle voice"). :611, :643 keep. Delete `makeThreeStateRow(selected:isRunning:tetherColor:)` (:648-655) and the four tether tests (:657-682); the other `makeThreeStateRow(selected:isRunning:)` overload stays. Wash tests :370-393 keep; ADD `liveWashUsesTheLiveAlphaWhenNeitherSelectedNorHovered` (`makeRow(selected: "device-1")` → `test_highlightAlpha == PopoverColumnGrid.rowLiveWashAlpha`) and `selectionWashOutranksLiveWash` (same row + `test_setSelected(true)` → `rowSelectionWashAlpha`).
- **FeedColumnTests.swift**: :28 drop `paintsSelectionBackground: false,`. `manualMemberPlusTwoApps` (:66-86) → expect `"System · Music · Safari"` and `!(row.test_feedHasOverflow)`; rewrite its comment to D13 (three bare pills measure ~130 pt of the 136 pt budget; the chips were what tipped it into "+1"); the tooltip line stays. Delete :210-258 (the FIVE tether/chip tests at :213, :222, :228, :244, :252 and the MARK). ADD, under a `// MARK: Pill tint (D7)` heading: `mainMixPillIsGoldTextWhileSoundingAndLabel2Otherwise` — connected + selected + controllable → `test_feedNeutralColor` same hue as `Tokens.Color.goldText`; `.off` + selected → same hue as `Tokens.Color.label2` (use the file's existing colour-compare idiom; if it has none, copy `assertSameHue` from DeviceRowConnectionStateTests:99-108). `manySegmentsOverflowToAStaticPlusN` keep.
- **DeviceRowConnectBrightenTests.swift**: :57 `tertiaryLabel` → `label3`; :64, :97, :107 `feedPillText` → `goldText` (the hosted row is connected + selected + controllable + unmuted → `isMainMixArmed`); messages updated.
- **RouteArmedSignalTests.swift**: :134-140 → `armedDotIsGoldWithNoHalo`: keep the gold assert and the no-bloom assert, delete the `test_dotHasGlow` line. :142-148 → `unarmedDotIsTheSocket`: `Tokens.Color.socket`, delete the glow line. :306-315 → `meterGradientIsEmberToGold`: `colors.count == 2`, first `ember`, last `gold`; MARK :306 updated. :197 `secondaryLabel` → `label2`. Everything else keep.
- **AccessibilitySignalSweepTests.swift**: :292 `colors.count == 2`; :287 comment → "(ember → gold) — two stops". (Still needed: PR 1 only changed the comment; the count assertion is 3.)
- **BTRowsUITests.swift**: drop `paintsSelectionBackground: false,` at :65, :354, :422, :486, :562; :256-257 `inkTertiary` → `label3`; :448 `secondaryLabel` → `label2`.
- **RemovalUndoTests.swift:28, CastVolumePendingTests.swift:29, MembershipBusTests.swift:30 and :86, EnergizeTests.swift:35**: drop `paintsSelectionBackground: false,`. Nothing else in those files.
- **PopoverControllerTests.swift**: :453 → `#expect(row.test_isShowingLiveWash == row.test_routeArmed, "the wash follows the armed predicate, not selection")` (tautological given the hook definition — it pins nothing beyond compiling; accepted); :462 → `#expect(!(row.test_isShowingLiveWash), "a deselected row is not armed, so no wash")`. :455, :465 keep (`secondaryLabel === label2`).
- **EQEditorViewTests.swift**: :196 `test_advancedHairlineFrame` → `test_advancedDividerFrame`; rename the test to `dividerSitsBetweenLoudnessAndAdvanced` and its doc (:191-193) to say `containerEdge`.
- **TokenContrastMatrixTests.swift** (PR 1 shape): no entry changes — `railDormant [canvas, panel, raised]` at 3.0 passes with the `rim` hexes (3.39 tightest). If PR 1 left a comment quoting `railDormant`'s old ratios, update it to 4.25 / 3.86 / 3.39. Run it.
- **GroupsWindowTextColorLockTests.swift**, **MembershipWellContrastTests.swift**, **SettingsAccentAndHintsTests.swift**, **GroupRowViewTests.swift**, **RailConnectPulseTests.swift**, **MembershipBusTests.swift** (beyond the label drops), **LevelMeterViewTests.swift**, **EQResponseCurveTests.swift**, **GroupRenameFieldTests.swift**, **GroupsHeaderParityTests.swift**, **DeviceRowAirPlay1LiveTests.swift**: no edits; they are in the filter to prove nothing regressed. If any references a deleted alias, that is a PR 1 discrepancy: STOP and report.

## Verification (in this order; paste each command's output)

```bash
bash scripts/build.sh        # exit 0
AUDIOUT_TEST_NO_CACHE=1 bash scripts/run-tests.sh --filter 'RingRailToneLockTests|DeviceRowConnectionStateTests|WarmFaderCellTests|AppRowViewTests|FeedColumnTests|RouteArmedSignalTests|DeviceRowConnectBrightenTests|BTRowsUITests|MembershipBusTests|TokenContrastMatrixTests|AccessibilitySignalSweepTests|RailConnectPulseTests|GroupsWindowTextColorLockTests|MembershipWellContrastTests|GroupRowViewTests|EQEditorViewTests|EQResponseCurveTests|LevelMeterViewTests|PopoverControllerTests|RemovalUndoTests|CastVolumePendingTests|EnergizeTests|GroupRenameFieldTests|GroupsHeaderParityTests|SettingsAccentAndHintsTests|DeviceRowAirPlay1LiveTests'
#   expected: every suite passes; count = baseline − (AppTetherColorTests + NoTintOnRingsOrMetersGuardTests + 4 AppRowView tether tests + 5 FeedColumn tether/chip tests) + 5 added (2 DeviceRowConnectionState, 2 AppRowView, 1 FeedColumn); report the real number
AUDIOUT_TEST_NO_CACHE=1 bash scripts/run-tests.sh      # the FULL suite, once, green
git grep -n "AppTetherColor\|FeedChip\|tetherColor\|appTintColors\|paintsSelectionBackground\|test_isShowingSelectedBackground\|test_dotHasGlow\|test_hasChip\|test_feedChipCount\|test_hasTetherChip" -- AudioutCore   # expected: no output
git grep -n "Color\.\(ringConnected\|faderThumb\|faderRim\|caution\|dotSocket\|meterTrack\|feedPillFill\|feedPillText\|destructive\)\b" -- AudioutCore   # expected: no output (if `destructive` still has a consumer, it was kept per D17 — say so)
git grep -n "shadowOpacity\|shadowRadius\|shadowColor" -- AudioutCore/Sources/AudioutSharedUI   # expected: no output
git grep -n "feedChip\|feedPillCornerRadius\|routeArmedGlow" -- AudioutCore   # expected: no output
wc -w AudioutCore/Sources/AudioutSharedUI/AGENTS.md    # ≤ 300
git status --short dev/notes/window-snapshots dev/notes/onboarding-snapshots dev/notes/settings-snapshots dev/notes/wizard-snapshots 2>/dev/null   # expected: no output
```

Then:

```bash
git add -A AudioutCore dev/notes/popover-snapshots dev/notes/design-migration-scoping/PR3-rows-work-order.md dev/notes/design-migration-scoping/PR3-pr-body.md
bash scripts/self-review.sh
git commit -m "Rows: live wash, cool ink, readout, flat instruments, FEED pills without tether colour

Device and app rows paint a gold 12 % wash while route-armed and read
silent rows in the cool ink family; the % readout is semibold tabular
goldText/emberText; the halo ring is ring while connecting and rim at
rest; the fader is raised + rim over a well trough; the meter ramps
ember → gold; every CALayer shadow bloom on the dot, ring, bead and
header dot is gone. FEED pills are well + rim capsules carrying text
only — AppTetherColor and FeedChip are deleted with their tests. The
rename field and EQ divider move to containerEdge, railDormant takes
rim's cool values, and the retired aliases leave Tokens.swift.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
git push origin claude/design-rows
gh pr create --base main --head claude/design-rows --title "Design migration PR 3: rows and instruments" --body-file dev/notes/design-migration-scoping/PR3-pr-body.md
```

`PR3-pr-body.md` carries: the Goal paragraph; Decisions D1–D17; the "Interim visible effects" section verbatim; the sentence "`dev/notes/window-snapshots/mixer-*.png` now diverge (rename-field border, EQ divider, dormant rail, dimmed seat) and were NOT regenerated — they are unreproducible goldens; `dev/notes/popover-snapshots/*.png` were regenerated"; the verification output; the footer `🤖 Generated with [Claude Code](https://claude.com/claude-code)`. Do NOT merge the PR.

## Owed checks (do not block the PR; list them in the PR body)

- Eye check in a dev build (`APP_NAME="Audiout Dev" BUNDLE_ID="com.audiout.Audiout.dev" bash scripts/make-app.sh` after `scripts/livetest.sh acquire`): the 12 % wash on a live row in both appearances; the capsule fader cap at 10×17 (a 5 pt radius on a 10 pt-wide cap); the `ring` steel-blue dash while a speaker connects; whether the flat gold dot still registers at 8 pt without its halo (the 2026-07-23 live note grew it 6 → 8 because it "kind of disappears" — the halo was part of what it was measured against).
- Whether the popover Applications card wants the app-row live wash at all (D3 gives it one; iOS's App Route Row has a `liveRow` card, so the wash is the nearest Mac reading).
- `D13`: if AppKit's rounding on another Mac tips "System · Music · Safari" over 136 pt, `manualMemberPlusTwoApps` flips back to "+1" — the 6 pt margin is the guard; report if the full suite ever shows it.

## Hand-off to PRs 4–8 (what they may assume about rows)

- Every `DeviceRowView`/`AppRowView` paints its own gold wash while armed via `PopoverColumnGrid.rowLiveWashAlpha`; hosts add no row wash of their own. The onboarding PR (R4) may reuse `rowLiveWashAlpha` for its live row.
- `paintsSelectionBackground` no longer exists; `DeviceRowView.init` is `(device:indented:showsToggle:showsMeter:showsBus:showsSyncControls:)`. `apply` has no `appTintColors:`. `AppRowView.Configuration` has no `tetherColor`.
- `AppTetherColor`, `FeedChip` are gone; `FeedPillView` is a `well`+`rim` capsule with D7 tints. `docs/FIGMA-DESIGN-SYSTEM.md` and `ROADMAP.jsonl` still name `AppTetherColor` — the documenter's PR 9.
- `HaloRingView`: `.connecting` = `ring`, `.connected`/`.resting` = `rim` (device rows), `spineTone` for Main Out (unchanged API). No seat.
- `RouteArmedDotView`: flat `gold`/`socket`, no shadow, `test_hasGlow` gone. `MainOutRowView` inherits all of it without edits; the popover PR owns the Main Out row's magenta chevron/seat glow (R2) and its readout font (still `caption` there).
- `LevelMeterView` ramps `ember → gold` (2 stops); `test_gradientColors.count == 2`.
- `Tokens.Font.readout` exists; `Tokens.Color.railDormant` = `rim`'s hexes; the aliases in Step 16.3 are gone. Still aliased for later PRs: `iconSeatFill`, `accent`, `warning`, `info`, `secondaryLabel`, `tertiaryLabel`, `inkSecondary`, `inkTertiary`, `canvasHi`, `sidebarWarmTint`, `success`, `warningText`, `goldCTA`, `inkOnGold`, `plateRim`, `syncSignal`, `partySignal`, `partySignalDeep`.
- `PopoverColumnGrid.selectionHighlightCornerRadius` and `mutePillCornerRadius` ARE `Tokens.Layout.Radius.control`; `GroupRowView`/`PopoverPanelViewController`/`MainOutRowView` already draw at 10 without edits. `syncChipCornerRadius` (5) and `alignPlateCornerRadius` (12) are untouched.
- The Groups window (`WarmNameFieldCell` border, EQ divider, dormant rail, dimmed seat) already reads on `containerEdge`/`socket`/`rim`; the Groups PR does not redo them. `MembershipRowView`'s `inkTertiary` and `DeviceIconWellView`'s `iconSeatFill` are the Groups PR's.
- Icon tint on device rows is `label2` in every state (not temperature-split) — a later ruling may change it; PopoverControllerTests:455/:465 pin it today.

## Execution plan

One track, SERIAL within itself, model **opus**, effort **high**: the tether deletion crosses SharedUI, PopoverController and eight test files with the build red in between, D1/D6/D7 need the row's state ordering held in the head, and the FEED overflow expectation change (D13) has to be reasoned, not guessed. No parallel tracks: every step shares `DeviceRowView.swift` or the same test files. The branch is cut from `origin/main` after PR 1 merges; there is no uncommitted work it depends on. Verification runs once at the end.

## Executor rules (copy verbatim into the handoff prompt)

> - Follow the steps in order. Do not add, merge, reorder, or skip steps.
> - Before editing in any folder, read the nearest AGENTS.md above it (and the root one) if the repo has them — folder rules and traps bind even when the work order doesn't repeat them.
> - If reality contradicts a Verified fact or a step is impossible as written, STOP and report the discrepancy. Do not improvise a workaround.
> - Before reporting progress, audit each claim against a tool result from this session. Only report work you can point to evidence for. If tests fail, say so with the output.
> - "Done" means the Verification commands were run in this session and passed. Paste their output.
> - Touch nothing in the Out-of-scope list.
> - Deliver what was asked, at the scope intended. If the spec seems mistaken or a better approach exists, say so in a sentence and continue as specified rather than quietly narrowing, widening, or transforming it.
