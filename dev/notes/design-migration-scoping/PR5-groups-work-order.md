# PR 5 work order: the Groups window

Executor: Opus. Branch `claude/design-groups`, cut from `origin/main` AFTER BOTH PR 3 (`claude/design-rows`) AND PR 4 (the popover PR, which creates `GroupIdentityGlowView`) have merged. Paths are relative to the new worktree. Line numbers cite the files as they are at `586bd8a2` (PR 1 committed); PR 3 touches none of the files below except `Tokens.swift` (its alias block shrinks, so alias-block lines shift up) and `PopoverColumnGrid.swift` (adds `rowLiveWashAlpha`). If a cited line is off by a few lines, find the quoted text; if the quoted text is absent, STOP.

Every ratio below is WCAG 2.x relative-luminance contrast computed with `scratchpad/pr5_ratios.py` during scoping, or quoted from PR 1's Token table. Cite them without recomputing.

## Goal

Move the Groups window (`AudioutWindowUI`, plus the shared sidebar wash it and Settings share) onto the iPhone companion's grammar: a cool chassis (the warm sidebar wash goes, on both screens), every card bounded by `containerEdge` at one of three radii, a raised icon seat on each group card with a gold ring and a gold 12 % wash while that group is the live Main Out, ink that carries temperature (cool names on idle groups and speakers, warm on live), a binary icon picker (solid gold selected cell, recessed unselected cell), a glyph tile on the editor's member rows, the detail panes' fact lists as stroked `panel` cards, and PR 4's static magenta identity glow (`GroupIdentityGlowView`) mounted behind every group icon seat. Geometry (S2) does not move: no row heights, card sizes, insets or grid columns change. The window-snapshot PNGs are not regenerated.

## Scope fences — PR 5 must NOT touch

- `DeviceRowView.swift`, `AppRowView.swift`, `PopoverColumnGrid.swift`, `WarmFaderCell.swift`, `HaloRingView.swift`, `MembershipBusView.swift`, `BusRailOverlayView.swift`, `WarmNameFieldCell.swift`, `EQEditorView.swift`, `EQResponseCurveView.swift`, `WarmCanvasView.swift`, `WarmPanelView.swift`, `ControlPanelBackingView.swift`, `ControlPanelWindowController.swift`: untouched (PR 3 / PR 4 own them). If this PR needs a change there, list it under "Requests to PR 3" and do not make it.
- `AudioutSettingsUI`: ONLY `SettingsSidebarViewController.swift` (Step 2), and in it ONLY the wash removal. No other Settings file. PR 6 does not touch this file (its work order says so at PR6-settings-work-order.md:25-27 and :490-491).
- `AudioutPopoverUI`, `AudioutOnboardingUI`, `AudioutApp`: untouched. `AudioutSharedUI/GroupIdentityGlowView.swift` is PR 4's file: this PR MOUNTS it and does not edit it (D4).
- `Tokens.swift`: only (a) delete the `sidebarWarmTint` and `iconSeatFill` aliases, (b) the two doc-comment edits in Step 12. No hex moves, no new token. `partyRampDeep` keeps PR 1's four values (D5 below).
- `GroupsPaneLayout.swift`, `GroupsOverviewLayout` (the enum in `GroupsOverviewViewController.swift:488-499`), `SurfaceLayout`, `DeviceIconWellView.size` (64), `MembershipRowView.rowHeight` (32), `PlateRowView.rowHeight` (36), `GroupsOverviewLayout.cardWidth/cardHeight/cardPadding/chipSize/gridInset/gridGutter`: no value changes. Radii and colours are not geometry; the one internal card re-flow D3 names is the only layout change.
- Empty state: copy unchanged (`"Group your speakers"` / `"Save a set of speakers as a group, then switch to it in two clicks from the menu bar."`, locked by `GroupsOverviewViewControllerTests:225-234`); no emitter field (parked, R3); the tile changes only its stroke token and radius.
- `GroupCreationSheetController.swift`: only the mechanical alias renames of Step 11.3 (its icon well is a stock bordered `NSButton` on a system sheet — no seat, no glow, no gold).
- No `CALayer` shadow anywhere. No `.systemOrange/.systemBlue/.controlAccentColor`. No `hairline` drawn on `raised`.
- No regeneration of `dev/notes/window-snapshots/*.png` (14 files) or any other snapshot PNG; do not run `window-snapshot`. No `make-app.sh`, no live-test slot, no dev build.
- No `.impeccable`, `DESIGN.md`, `PRODUCT.md`, `docs/FIGMA-DESIGN-SYSTEM.md`, `ROADMAP.jsonl`, and no `AGENTS-HISTORY.md` edits (archived; its `SidebarWarmSurfaceView` mentions stay — PR 9's).
- No cleanup, no new helper views (the glow view is PR 4's), no error handling for impossible cases, no backwards-compat shims. When a parameter or hook loses its last consumer it is deleted.
- Do not edit any other file in `dev/notes/design-migration-scoping/`.

## Decisions recorded (the executor does not re-open these)

- **D1 The sidebars sit on the surface's `panel` backing; nothing replaces the wash.** The prompt's "so the system sidebar material stands" cannot happen: both screens' split items are PLAIN (`MixerWindowController.swift:140-152`, `SettingsSidebarViewController.swift:41-44`), so there is no `.sidebar` material behind either outline view — `SidebarWarmSurfaceView` was drawing an OPAQUE `sidebarWarmTint` backing (`rendersOnGlass: false` on every OS, `SidebarViewController.swift:107-116`). Deleting it leaves the transparent `.sourceList` outline view (`scrollView.drawsBackground = false`, `:213`) on the surface's own opaque `panel` ground (`ControlPanelBackingView.swift:82`, `ControlPanelWindowController.swift:277`; Settings root `WarmPanelView`, `SettingsRootViewController.swift:168`). Sidebar and content pane then share one ground in both appearances, divided by the split divider and the content pane's title-bar seam. The Reduce Transparency opaque path the view carried (`effectiveAlpha`, `SidebarWarmSurfaceView.swift:53-69`) is moot: nothing translucent remains, so no `ReduceTransparencyFallbackView` is needed. The considered alternative — an `NSVisualEffectView(material: .sidebar)` plus the A1 fallback view — was rejected: it adds two views to delete one, and the design wants a flat cool chassis. `SidebarViewController.init(rendersOnSystemSidebarMaterial:)` loses its parameter (its only non-test caller is `MixerWindowController.swift:125`, which passes nothing). Owed eye check, both appearances.
- **D2 Sidebar ink stays the stock semantic.** AppKit re-inks a source-list row's text over the emphasized selection pill only when the colour is a system semantic (`labelColor` et al.) — this is AppKit behaviour as documented for `NSTableCellView.backgroundStyle`, NOT a fact recorded in this repo, and no headless test can see it; an authored `labelCool` would then sit grey on the accent pill of a selected row. So `IconLabelCellView` names stay `Tokens.Color.label`, dimmed rows and the chevron move `inkTertiary` → `label3` (alias rename only), headers `secondaryLabel` → `label2`. The temperature rule (C5) applies to the CONTENT pane, where no selection pill exists. The pinned Groups row has no icon seat (its cell is built through `makeIconLabel` at `SidebarViewController.swift:894-896`, a plain `IconLabelCellView` image), so it gets no glow.
- **D3 The group card's seat is 28 pt, not 44, filled `well`.** Card height is 118 with 12 pt padding (`GroupsOverviewLayout`); the stack is glyph → name (+7, 16 pt tall at `bodyEmphasized`) → meta (+3, 14 pt tall at `caption`) → chips (24 pt, bottom-pinned at y 82). A seat of side S puts the meta line's bottom at S + 52, so S ≤ 30 is the fit; 44 needs the iOS side-by-side re-flow, which S2 forbids. 28 leaves 2 pt above the chips. The 17 pt glyph image view stays 17 pt, centred in the seat; the name and meta lines move down 11 pt with it. Card size, grid and chip row are unchanged. The seat fills `well`, not iOS's `raised`: the card itself is `raised`, so a `raised` seat would be stroke-only in both appearances (1.000:1); `well` measures 1.292:1 on the dark card and 1.154:1 on the light one, `containerEdge` on `well` 2.006:1 dark / 1.751:1 light, the gold ring 11.04 / 3.16, `labelCool` on `well` 9.55 / 5.88. (Label heights measured with `NSTextField(labelWithString:)` at the two fonts: 16.0 and 14.0.)
- **D4 The glow is PR 4's `GroupIdentityGlowView`, mounted at two sizes.** PR 4 creates `AudioutCore/Sources/AudioutSharedUI/GroupIdentityGlowView.swift`: `public final class GroupIdentityGlowView: NSView`, `public static let side: CGFloat = 60`, a radial `CAGradientLayer` from `Tokens.Color.partyRampDeep` at 0.22 (dark) / 0.10 (light) to clear at the view's edge, re-stamped on appearance change, `hitTest` nil, not an accessibility element, hook `test_coreAlpha` (PR4-popover-work-order.md D7, Step 7). This PR defines NO glow of its own; the ONE rule is that PR 5 branches after PR 4 has merged (Pre-flight STOPs otherwise). Because the gradient is relative to the layer's bounds (`endPoint (1, 1)`), the view draws whatever size it is mounted at: behind the card's 28 pt seat it is mounted at 48 (24 pt radius, 10 pt of leak) — `side` (60) would overhang the 118×182 card by 4 pt at the top and left (seat centre at 26,26), and `GroupCardView` is not layer-backed (no `wantsLayer`/`masksToBounds` anywhere in the file except the tile's plus-ring, :861), so whether the overflow shows depends on the collection item's clipping, which this PR does not want to rely on; behind the editor's 64 pt well at `DeviceIconWellView.size + 16` = 80 (40 pt radius, 8 pt of leak — the iPhone's 44-seat/30-radius proportion). A 60 pt glow behind a 64 pt opaque well would be invisible. The sidebar has no seat (D2), so nothing mounts there.
- **D5 The glow draws `Tokens.Color.partyRampDeep` as PR 1 left it** (dark `#FF90E9`, light `#752C68`, D5 of PR 1) at 22 % dark / 10 % light — PR 4's view, PR 8's order keeps the token's hexes (PR8-wizard-work-order.md:13). Measured core composite on dark `raised`: `#503B54`, 1.572:1 vs `raised`, 1.791:1 vs `panel` — visibly pink, stronger than the iPhone's `#752C68`-based 1.094:1. Light: `#EDE5EC`, 1.183:1 on the flat ground. No contrast floor applies (a floor-exempt halo, like `glow`). Owed eye check; the only lever is a token re-value of the dark hex to `#752C68`, which is nobody's PR today.
- **D6 Radii.** Group card and New Group tile 10 → `Radius.row` (16; iOS Group Row "a `panel` card at row radius"). Card seat, member chip (6), picker cell (7), picker preview tile (6), `DeviceIconWellView` (12), member-row glyph tile (new), sidebar plate (8) → `Radius.control` (10; controls and chips). `GroupedSectionView.card` 10 → `Radius.panel` (26; iOS "panel radius for a grouped stack", ~/Projects/audiout-remote/DESIGN.md:784-785); the new `.panel` fact-row style → `Radius.row` (16; iOS PanelRow, ~/Projects/audiout-remote/DESIGN.md:900-902). The New Group tile's 28 pt plus-ring keeps `cornerRadius = 14` because it is a circle (28 / 2), same reading as PR 3's capsules. `Tokens.Layout.groupedSectionCornerRadius` stays for onboarding's `RoundedContainerView` (its only remaining consumer).
- **D7 `GroupedSectionView` gets a third style, `.panel`,** and its `.card` dividers move to `containerEdge` (rule 5: `hairline` on `raised` is 1.154:1 dark, banned; PR 1 hand-off assigned this move here). `.panel` = `panel` fill, 1 pt `containerEdge` stroke, `Radius.row`, `hairline` dividers (1.314:1 dark / 1.512:1 light on `panel`, legal). The pane ground is `panel` too, so a `.panel` card is stroke-only in both appearances — the iOS light rule ("that stroke is the only pixel separating a row from the screen") applied to both. `.bare` stays for the three header bands (`headerWell` in editor, device detail, Main Out) — their geometry is pinned by `GroupsHeaderParityTests` and a box around a header is not asked for. Only `DeviceDetailViewController`'s `groupsWell` and `aboutWell` become `.panel`.
- **D8 Ink map (C5).** Group card: name `labelCool` idle / `label` live; glyph `labelCool` idle / `label` live; meta `labelCool2` idle; live meta = `label2` with the "Playing now" range in `goldText`; "+N" chip `labelCool2`; member-chip glyph stays `label` (`GroupsOverviewViewControllerTests:127` pins it; chip is `raised`+`containerEdge`). Member row (`.warmPane`): live = `railArmed && checked`; name `label` live / `labelCool` idle; glyph `label2` live / `labelCool2` idle; unavailable = `labelCool2` on name, glyph AND the "Unavailable" word. Member row (`.systemSheet`): stock, name `label` / `label3` unavailable, glyph `label2` / `label3` unavailable (alias rename only — "do NOT warm the Apple sheet", `MembershipRowView.swift:31-40`). `DeviceIconWellView` glyph: `label` while `isActiveGroup`, else `labelCool`; the well owns this (hosts stop setting it) so the detail pane's and Main Audio's wells read `labelCool`. Page titles stay `label` (device name, "Main Audio", the editor's name field — an editable field, not a list row). Captions/section titles/sub-labels are `label2`, counts and tertiary text `label3`, everywhere in `AudioutWindowUI`, by mechanical alias rename. Picker: unselected glyph `labelCool`, selected `inkOnFill`, preview glyph and "No matches" `label2`.
- **D9 Member row checkbox.** On `.warmPane` the checkbox already wears `InvisibleSwitchCell` and its visible skin is `MembershipBusView`'s gold `.member` node (`MembershipRowView.swift:135-142`, `:236-256`) — checked already reads gold; nothing changes. On `.systemSheet` the stock `NSButton` stays stock: `NSButton.contentTintColor` does not recolour a `.switch` checkbox's checked fill reliably, and the sheet is Apple's. The 24 pt glyph tile is drawn on `.warmPane` only.
- **D10 Icon picker cells are all layer-stamped now** (selected: `gold` fill; unselected: `well` fill + 1 pt `hairline` border), so the one re-stamp pass covers every cell. `test_ringRefreshCount` becomes `test_cellRestampCount`, incremented ONCE per pass (not per button); the test keeps its "+2 after the two notifications" shape under a new name. `test_currentRingSymbolName` becomes `test_selectedCellSymbolName`.
- **D11 `GroupsWindowTextColorLockTests` is deleted and replaced by `GroupsInkTemperatureTests`** (Test plan). Its two POSITIVE sampling tests survive inside the new suite with `containerEdge` as the divider.
- **D12 Aliases.** `sidebarWarmTint` (last consumer: the deleted view) and `iconSeatFill` (last consumers: `DeviceIconWellView.swift:252`, `GroupsOverviewViewController.swift:806`) are deleted from `Tokens.swift`. `secondaryLabel`, `inkTertiary`, `tertiaryLabel` STAY (popover, onboarding, settings and shared consumers) but no file under `AudioutWindowUI` names them after this PR.

## Pre-flight (from the NEW worktree root)

```bash
git fetch
git worktree add .claude/worktrees/design-groups -b claude/design-groups origin/main
cd .claude/worktrees/design-groups
git push -u origin claude/design-groups
git config core.hooksPath .githooks
git log --oneline -1            # must be AT or AFTER the PR 3 merge; if PR 3 is not on origin/main, STOP
grep -n "static let rowLiveWashAlpha" AudioutCore/Sources/AudioutSharedUI/PopoverColumnGrid.swift      # must hit (PR 3)
grep -n "static let labelCool2\|static var goldText\|enum Radius\|static var partyRampDeep\|static var inkOnFill" AudioutCore/Sources/AudioutSharedUI/Tokens.swift   # all five must hit (PR 1)
grep -n "sidebarWarmTint\|iconSeatFill" AudioutCore/Sources/AudioutSharedUI/Tokens.swift   # both aliases must still exist (PR 4 leaves them for this PR)
grep -n "public static let side\|test_coreAlpha\|CAGradientLayer" AudioutCore/Sources/AudioutSharedUI/GroupIdentityGlowView.swift   # all three must hit; if the file is missing, PR 4 has not merged: STOP
bash scripts/build.sh           # exit 0
AUDIOUT_TEST_NO_CACHE=1 bash scripts/run-tests.sh --filter 'SidebarWarmSurfaceTests|GroupsWindowTextColorLockTests|MembershipWellContrastTests|IconPickerTests|GroupsOverviewViewControllerTests|GroupsHeaderParityTests|MembershipRailTests|AppSurfaceControllerTests|DeviceIconWellViewTests|DeviceDetailViewTests|MixerWindowControllerTests|SidebarActionsTests|GroupRenameFieldTests|EQEditorViewTests|SettingsRootViewControllerTests|TokenContrastMatrixTests|MembershipBusTests'
#   record the "Test run with N tests in M suites" line — this is the baseline
```

Baseline observed during scoping (2026-09-03, worktree at `586bd8a2`, before PR 3 and PR 4): `bash scripts/build.sh` → "compiled clean on remote", exit 0; the filter above → **"Test run with 454 tests in 18 suites passed"**. PR 3 may change the count; the executor's own run is the baseline and must be green.

Never a bare `swift build`/`swift test`.

## Verified facts (file:line, checked 2026-09-03 at `586bd8a2`)

Sidebar wash
- `SidebarWarmSurfaceView.swift` (112 lines, `AudioutSharedUI`): `rendersOnGlass` :36, `tintAlpha` :49, `test_reduceTransparencyOverride` :53-55, `effectiveAlpha` :62-66, `draw` :105-111 reads `Tokens.Color.sidebarWarmTint`. Its ONLY consumers: `SidebarViewController.swift:92` (stored), `:115` (init), `:625/:630/:636/:641-644` (four test hooks), `SettingsSidebarViewController.swift:45` (stored), `:85-92` (added + four constraints), and `SidebarWarmSurfaceTests.swift` (5 tests, whole file). Comments naming it: `SettingsSidebarViewController.swift:10`, `:41-44`; `SidebarViewController.swift:107-113`, `:240-246`; `MixerWindowController.swift:149-152`; the two `AGENTS-HISTORY.md` files (untouched).
- `SidebarViewController` container build: `warmSurfaceView` added first at `:248`, constraints `:253-256`, comment `:240-246`. `init(rendersOnSystemSidebarMaterial: Bool = false)` :114-117. Test callers of that parameter: `SidebarWarmSurfaceTests.swift:29, :40, :54, :66` only. `MixerWindowController.swift:125` calls `SidebarViewController()`.
- `PlateRowView` :729-758: `radius = Tokens.Layout.groupedSectionCornerRadius - 2` (:739), `raised` fill :749, `hairline` stroke :751. `IconLabelCellView` tints: marker `gold` :668, chevron `inkTertiary` :683; cell ink :1006 (`inkTertiary`/`label` glyph), :1008 (name); header :966 (`secondaryLabel`). `test_groupsRowShowsLiveMarker` :498.
- `Tokens.Color.sidebarWarmTint` alias at Tokens.swift:1066 (its two banned-array entries in `GroupsWindowTextColorLockTests` and `MembershipWellContrastTests` were ALREADY removed by PR 1 — `git grep sidebarWarmTint AudioutCore/Tests` is empty).

Overview
- `GroupsOverviewViewController.swift`: header tints :92 (`titleGlyph.contentTintColor`, `secondaryLabel`; the page title at :96 is `label` and stays), :100 (`inkTertiary`); empty labels :134 (`secondaryLabel`), :138 (`inkTertiary`). `GroupCardView` :577-744: glyph tint :600 (`secondaryLabel`), live marker `gold` :607, name `label` :614, meta `inkTertiary` :620, glyph 17×17 at `(pad, pad)` :634-637, name top = glyph.bottom + 7 :642, meta top = name.bottom + 3 :646, chips bottom-pinned :650-651; `metaAttributedString` :690-700 (`inkTertiary` + `gold` on "Playing now"); `draw` :702-720: radius `groupedSectionCornerRadius`, `raised` fill, stroke `gold` if live else `hairline` (:708), focus ring `radius - 1` :715. `MemberChipView` :747-822: glyph `label` :764, overflow text `inkTertiary` :783, `draw` :806-818 (`iconSeatFill` fill, `containerEdge` stroke, radius `chipCornerRadius` = 6; overflow dashed `hairline`). `NewGroupTileView` :834-957: plus tint `secondaryLabel` :856, ring `cornerRadius = 14` + `hairline` border :860-862, caption `inkTertiary` :868, `draw` :892-900 (dashed `hairline`, radius `groupedSectionCornerRadius`), focus mask :930-933, appearance restamp :954-957. `test_memberChipGlyphTint` :361. `GroupsOverviewLayout` :488-499 (`cardWidth` 182, `cardHeight` 118, `cardPadding` 12, `chipSize` 24, `chipCornerRadius` 6). `CardPlan.isLive` :522. `MemberChipView` :740-820, `NewGroupTileView` from :832.
- `GroupsOverviewViewControllerTests.swift:126-129` pins the chip glyph tint `=== Tokens.Color.label`; `:225-234` pins the empty-state copy. Neither reads a card view (cells are never realized headlessly — `GroupsOverviewViewController.swift:360` and `:411-413` say so; the seams below build a card directly).

Icon well and editor
- `DeviceIconWellView.swift`: `wellCornerRadius = 12` :66, ring widths :74-75, `draw` :240-280 (`iconSeatFill` fill :252, edge `gold`/`ember`/`containerEdge` :270-278), focus mask :371-374, WARM SIGNAL doc :42-60, `iconImageView` internal `let` :88. Hosts set the glyph tint to `label`: `DeviceDetailViewController.swift:834`, `GroupEditorViewController.swift:855`, `MainOutDetailViewController.swift:91`. `isActiveGroup` :114-116 (set by the editor at `GroupEditorViewController.swift:762`), `isRailOrigin` :130-132 (editor sets true at :280). `DeviceIconWellViewTests` reads only the badge/keyboard hooks (no seat colour, no glyph tint).
- `GroupEditorViewController.swift`: `iconWell` :116 laid out at :556-563 inside `column`; `headerWell.style = .bare` :424; view list added at :425; `membershipWell` `.card` (default) :125, rows :895/:936; "Speakers" label `secondaryLabel` :341; playing badge caption `secondaryLabel` :694, glyph `gold` :686; name field `label` :311; `test_membershipWellRowCount` :1582. Its rows are built at :913 with `surface: .warmPane` and `railArmed` from `railArmed(for:memberSet:isActiveGroup:)` :841-842 (false unless the group is active).
- `MembershipRowView.swift`: `iconView` 26 pt (`PopoverColumnGrid.iconWidth`, :183-184), tint :154 and :296 (`secondaryLabel`/`inkTertiary`), name :295 (`label`/`inkTertiary`), unavailable label :164 (`secondaryLabel`), :297 (`inkTertiary`); `railArmed` :52-54; `checked` private; `surface` private; no `draw(_:)` override today; hit-test :356-360 collapses every hit onto the row.
- `GroupedSectionView.swift`: `Style` :51-56, `cornerRadius = groupedSectionCornerRadius` :63, `draw` :84-121 (`.card`: `raised` + `containerEdge` at :90-100; dividers `hairline` :104 for every style). Consumers: `DeviceDetailViewController.swift:75-83` (`headerWell`, `groupsWell`, `aboutWell` `.bare` at :261-263, `eqWell` `.card`), `:1039-1049` `test_cardFrames` counts `.card` only; `GroupEditorViewController.swift:125/:130` (`membershipWell` `.card`, `headerWell` `.bare` :424); `MainOutDetailViewController.swift:44-45` (`headerWell` `.bare` :125, `eqWell` `.card`). `DeviceDetailViewTests:593/:625/:628` assert `test_cardFrames.count` is 1 / 1 / 0 — unaffected by a `.panel` style that is not `.card`.
- `DeviceDetailViewController.swift`: fact-row caption `secondaryLabel` :478; group-row chevron `secondaryLabel` :778; no-groups label `secondaryLabel` :793; section title :226.
- `MainOutDetailViewController.swift`: `secondaryLabel` :104, :129; `iconWell.isEditable = false` :85.
- `IconPickerViewController.swift`: `makeCuratedButton` :237-270 (ring: `wantsLayer`, `cornerRadius = 7`, `borderWidth = 1.5` :258-261; glyph tint `secondaryLabel` :266); `refreshSelectionRingColor` :287-296 (`test_ringRefreshCount += 1`); observers :98-116; `ringTokensDidChange` :427; preview tint :135, :358; "No matches" :158; per-button restamp call :271; `test_currentRingSymbolName` :497; `test_ringRefreshCount` :505; `WarmPreviewTileView` :525-533 (`canvas` fill, `hairline` stroke, radius 6). `IconPickerTests.swift:139-151` asserts `test_ringRefreshCount == baseline + 2`; `test_currentRingSymbolName` is read at `IconPickerTests.swift:144` (grep for any other reader before renaming).
- `GroupCreationSheetController.swift`: `secondaryLabel` :184, :204, :309 (empty-checklist label), :416 (`iconWellButton.contentTintColor`); mounts `MembershipRowView(... surface: .systemSheet)`; icon well is a stock bordered `NSButton` :158-167.
- `MixerWindowController.swift:794` footer `secondaryLabel`.

Tokens (HEAD)
- `labelCool` :386 (`static let`), `labelCool2` :402 (`static let`), `label2` :113, `label3` :129 (both `static let`), `goldText` :490, `inkOnFill` :627, `partyRampDeep` :1023, `containerEdge` :302, `hairline` :277, `panel` :218, `raised` :225, `well` :235, `gold` :471. Alias block :1036-1101; `iconSeatFill` :1062, `sidebarWarmTint` :1066. `Tokens.Layout.groupedSectionCornerRadius` :1280 (doc :1275-1279 names `GroupedSectionView`); `Radius` :1288-1295. `groupedSectionCornerRadius` consumers outside this PR: `OnboardingChrome.swift` (1) — it stays.
- iOS recipes: Group Row and glow ~/Projects/audiout-remote/DESIGN.md:854-888, `GroupsView.swift:205-226` (glow: `RadialGradient` `partyRampDeep` at 0.22 dark / 0.10 light, `endRadius: 30`, 60×60 frame, hit-testing off, accessibility hidden); PanelRow ~/Projects/audiout-remote/DESIGN.md:900-916; editor member row and picker ~/Projects/audiout-remote/DESIGN.md:929-957, `GroupEditorView.swift:198-240`.
- Snapshot tools: `Sources/window-snapshot/main.swift` and `Sources/settings-snapshot/main.swift` reference none of the deleted symbols (grep empty).
- `AudioutWindowUI/AGENTS.md:23` is the rule "Text colors are frozen: contrast lifts from surfaces, never hue." (387 words, no cap stated). `AudioutSharedUI/AGENTS.md` has a 300-word cap (PR 3 Step 14); 295 words at HEAD.
- PR 4's `GroupIdentityGlowView` (PR4-popover-work-order.md:105-117, :301-313, :474-476): 60×60 by `side`, radial `CAGradientLayer` with `endPoint (1, 1)` (bounds-relative), colours `partyRampDeep` at 0.22/0.10 → clear, `hitTest` nil, not an accessibility element, `test_coreAlpha`; PR 4 adds its `AudioutSharedUI/AGENTS.md` Map bullet and `GroupIdentityGlowViewTests`. PR 4 mounts it "as the FIRST subview behind the seat, centred on it" at `side`. PR 4 leaves `iconSeatFill` and `sidebarWarmTint` for this PR.

## Step-by-step

Build stays green after every step except between Steps 2 and 3 (deleting the view before its two hosts are edited); run `bash scripts/build.sh` after Step 3 and after every later step.

### Step 1 — confirm the glow view scales with its mount size (no edit)

Read `AudioutCore/Sources/AudioutSharedUI/GroupIdentityGlowView.swift` as PR 4 landed it. The editor mounts it at 80×80 (D4), so the gradient must follow the view's bounds: either the `CAGradientLayer` IS the backing layer (`makeBackingLayer`), or a `layout()`/`resize` path re-frames a sublayer to `bounds`. If neither is true (a sublayer with a frame fixed at 60×60), STOP and report — the fix belongs in PR 4's file, not here. Record which mechanism you found in the PR body.

### Step 2 — delete `AudioutCore/Sources/AudioutSharedUI/SidebarWarmSurfaceView.swift` and `AudioutCore/Tests/AudioutCoreTests/SidebarWarmSurfaceTests.swift` (`git rm` both)

### Step 3 — `AudioutCore/Sources/AudioutWindowUI/SidebarViewController.swift` and `AudioutCore/Sources/AudioutSettingsUI/SettingsSidebarViewController.swift`

3.1 Sidebar: delete the stored property :92, the doc :107-113 and the init parameter — `init(rendersOnSystemSidebarMaterial:)` :114-117 becomes `public init()` calling `super.init(nibName: nil, bundle: nil)`; delete the comment :240-246, the `addSubview(warmSurfaceView)` :248 and its four constraints :253-256; delete the `// MARK: Test-support hooks (T7 …)` block :618-645 (four hooks). Rewrite the class doc's parenthetical about the plate at :29-30 ("drawn as a raised PLATE with a hairline edge") → "with a `containerEdge` edge".
3.2 Settings sidebar: delete :41-45 (doc + property), :85-88 (comment + `addSubview`), :90-93 (its constraints); rewrite the class doc :9-11 so it ends "the same icon/label cell geometry — so the two arrangement screens read as one surface rather than two different sidebars." (no wash mention).
3.3 `MixerWindowController.swift:149-152`: "What the constructor did supply is the system sidebar material, and the sidebar's own `SidebarWarmSurfaceView` draws its opaque backing instead (the branch that already shipped to everyone below macOS 26)." → "What the constructor did supply is the system sidebar material; the sidebar sits on the surface's own `panel` backing instead (C6, 2026-09-03: no wash on either screen)."
Now `bash scripts/build.sh` — exit 0.

### Step 4 — `SidebarViewController.swift`, the plate and the cell ink

`PlateRowView.platePath` :739: radius → `Tokens.Layout.Radius.control`; `drawBackground` :751: `Tokens.Color.hairline` → `Tokens.Color.containerEdge`; rewrite the type doc :711-713 ("a raised plate with a hairline edge") → "a `raised` plate with a `containerEdge` edge (rule 5: `hairline` never sits on `raised`)". Ink (D2): :683 `inkTertiary` → `label3`; :966 `secondaryLabel` → `label2`; :1006 and :1008 `inkTertiary` → `label3` (`label` stays). Doc at :1004 unchanged.

### Step 5 — `AudioutCore/Sources/AudioutWindowUI/GroupedSectionView.swift`

Add `case panel` to `Style` :51-56 with doc "A stroked-panel row list (iOS PanelRow): `panel` fill, 1 pt `containerEdge` edge at the row radius, `hairline` dividers. The pane ground is `panel` too, so the stroke is the card." Replace `static let cornerRadius` :63 with a computed `private var cornerRadius: CGFloat` returning `Tokens.Layout.Radius.panel` for `.card`, `Tokens.Layout.Radius.row` for `.panel`, `0` for `.bare` (unused). In `draw`: the fill/stroke branch runs for `.card` (fill `raised`) and `.panel` (fill `panel`), both stroked `containerEdge` at `borderWidth`; the divider colour becomes `Tokens.Color.containerEdge` for `.card` and `Tokens.Color.hairline` otherwise (rule 5 — write the 1.154:1 dark measurement in the comment). Rewrite the type doc :6-26 for three modes; the `.card` bullet's "`containerEdge` vs `raised`: 1.31:1 dark / 1.60:1 light" → "1.553:1 dark / 2.020:1 light" and its "rules its interior" sentence → the interior rules are `containerEdge` too. Update `AGENTS-HISTORY`? No (archived).

### Step 6 — `AudioutCore/Sources/AudioutWindowUI/DeviceDetailViewController.swift`, `MainOutDetailViewController.swift`

6.1 Device detail :262-263: `groupsWell.style = .bare` → `.panel`, `aboutWell.style = .bare` → `.panel`; `headerWell` stays `.bare`. Rewrite the comment :258-260 ("ONE card per page … everything else is a bare list") → the header band is bare; the two fact lists are stroked `panel` rows (iOS PanelRow); the Equalizer is the one `raised` card. Delete :834 (`iconWell.iconImageView.contentTintColor = Tokens.Color.label`) — the well owns its glyph tint (Step 8). Aliases: :226, :478, :778, :793 `secondaryLabel` → `label2`.
6.2 Main Out: delete :91 (the tint line); :104, :129 `secondaryLabel` → `label2`.

### Step 7 — `AudioutCore/Sources/AudioutWindowUI/GroupsOverviewViewController.swift`

7.1 `GroupCardView` (:577-744). Add a private nested seat view class in this file, `IconSeatView: NSView` (hit-test nil), side `GroupsOverviewLayout.cardSeatSize` — add `static let cardSeatSize: CGFloat = 28` to `GroupsOverviewLayout` with the D3 arithmetic in its doc — that draws in `draw(_:)`: `well` fill at `Radius.control` (D3), then a stroke of `containerEdge` at 1 pt, or `gold` at 1.5 pt while `isLive` (a stored `var isLive: Bool { didSet { needsDisplay = true } }`), inset by half the stroke; `viewDidChangeEffectiveAppearance` → `needsDisplay`. The card's `glyphView` moves INTO the seat (centred, still 17×17); the seat replaces the glyph at `(pad, pad)` with width/height `cardSeatSize`; `liveMarkerView.centerY` follows the seat's centre; `nameLabel.top = seat.bottom + 7` (the constant unchanged). Add a `GroupIdentityGlowView()` subview added BEFORE the seat (so it sits under it), centred on the seat, width and height constrained to `GroupsOverviewLayout.cardGlowSide` — add `static let cardGlowSide: CGFloat = 48` with the D4 sentence as its doc (24 pt radius, 10 pt of leak, fully inside the card). Subview order: glow, seat, marker, labels, chips. Ink (D8): glyph tint and name colour set in `applyPlan` from `plan.isLive` (`label`/`labelCool`); meta via `metaAttributedString`: idle → `labelCool2`; live → `label2` with the "Playing now" range in `goldText` (was `gold`); `MemberChipView` overflow text :783 → `labelCool2`. `draw` :702-720: radius `Tokens.Layout.Radius.row`; `raised` fill; if live, fill again with `Tokens.Color.gold.withAlphaComponent(PopoverColumnGrid.rowLiveWashAlpha)` (the whole card, iOS "flat gold 12 % wash over the card"); stroke ALWAYS `containerEdge` at 1 pt (the gold border goes; the seat ring carries live); focus ring radius `Radius.row - 1`. Rewrite the type doc :569-572: `raised` + `containerEdge` at the row radius; live = gold 12 % wash + 1.5 pt gold ring on the seat + the wave marker + "Playing now" in `goldText`; the seat is a `well` recess (D3) and its glyph is identity (`labelCool` idle, `label` live) and the seat carries `GroupIdentityGlowView` behind it active or not (rule 4). Update the "THREE gold sites" comment :686-689 → the wash, the seat ring, the marker and the meta text.
7.2 `MemberChipView.draw` :806-818: `iconSeatFill` → `raised`; radius → `Tokens.Layout.Radius.control`; the overflow dash stays `hairline` (no fill under it). Doc :747-749 "a `well` fill in a hairline edge" → "a `raised` fill in a `containerEdge` edge at the control radius".
7.3 `NewGroupTileView`: `draw` :892-900 radius → `Radius.row`, `hairline` → `containerEdge`; focus mask :930-933 radius → `Radius.row`; the 28 pt ring keeps `cornerRadius = 14` and its `hairline` border (no fill beneath it; D6). Aliases: :856 → `label2`, :868 → `label3`.
7.4 Header/empty aliases: :92 (`titleGlyph.contentTintColor`) → `label2`, :100 → `label3`, :134 → `label2`, :138 → `label3`.
7.5 Test seams (next to `test_memberChipGlyphTint` :361), all `public static`, each building a `GroupCardView` with a `CardPlan` (`groupID: "g"`, `name: "Test"`, `symbolName: Group.defaultIconSymbolName`, `memberCount: 2`, `isLive:` as given, no chips): `test_cardNameColor(isLive:) -> NSColor?`, `test_cardGlyphTint(isLive:) -> NSColor?`, `test_cardMetaAttributedString(isLive:) -> NSAttributedString`, `test_cardSeatStroke(isLive:) -> (color: NSColor, width: CGFloat)` (read from the seat's own stored decision — give `IconSeatView` a `var strokeSpec: (NSColor, CGFloat)` computed from `isLive` that `draw` also uses), `test_cardHasIdentityGlow: Bool` (a `GroupIdentityGlowView` is among the card's subviews and precedes the seat in `subviews`).

### Step 8 — `AudioutCore/Sources/AudioutWindowUI/DeviceIconWellView.swift`

`wellCornerRadius` :66 → `Tokens.Layout.Radius.control` (keep the name; doc: the control radius). `draw` :252 `iconSeatFill` → `raised`. Glyph tint owned here: in `init` set `iconImageView.contentTintColor = Tokens.Color.labelCool`; in `isActiveGroup`'s `didSet` :114-116 also set `iconImageView.contentTintColor = isActiveGroup ? Tokens.Color.label : Tokens.Color.labelCool` (rule 1: the glyph is identity, cool until the group sounds). Rewrite the WARM SIGNAL doc :42-60: `raised` seat (light = flat ground, only the edge draws it), `containerEdge` edge, gold 1.5 pt ring while active, glyph `labelCool`/`label`. Nothing else (hover wash, badge, keyboard) changes.

### Step 9 — `AudioutCore/Sources/AudioutWindowUI/GroupEditorViewController.swift`

Add a stored `private let iconGlow = GroupIdentityGlowView()`; in `loadView` add it to `column` BEFORE `iconWell` in the `for v in [...]` at :425 (so it is under the well), `translatesAutoresizingMaskIntoConstraints = false`, centred on `iconWell` (centerX/centerY equal), width and height constrained to `DeviceIconWellView.size + 16` (80 — D4: a 60 pt glow would sit wholly under the 64 pt opaque well). Add `static let iconGlowSide: CGFloat = DeviceIconWellView.size + 16` on the controller with that sentence as its doc. Delete :855 (the glyph tint line). Aliases: :185, :341, :694 → `label2`. Add `public var test_hasIdentityGlow: Bool` = `iconGlow.superview === iconWell.superview` and the glow's index in `superview.subviews` is lower than the well's. Doc :23-30 (the header section) gains one sentence: the well carries `GroupIdentityGlowView` behind it, the same light its overview card shows.

### Step 10 — `AudioutCore/Sources/AudioutWindowUI/MembershipRowView.swift`

10.1 Tile (`.warmPane` only): override `draw(_:)`: when `surface == .warmPane`, compute a 24 pt square centred on `iconView.frame` (`iconView` is 26 pt; the tile sits 1 pt inside it on each side — no layout change), fill `Tokens.Color.well`, stroke 1 pt `Tokens.Color.hairline` at `Radius.control`, inset by 0.5. Add `viewDidChangeEffectiveAppearance` → `needsDisplay`. Doc comment: iOS editor member row (~/Projects/audiout-remote/DESIGN.md:940-943); `hairline` on `well` measures 1.491:1 dark / 1.310:1 light — legal, and `well` vs `raised` (the card under it) 1.292:1 dark / 1.154:1 light.
10.2 Ink (D8). Replace :154, :164 build-time tints and the block :294-297 with one private `func applyInk()` called from `apply(device:checked:iconSymbolName:)` and from `railArmed`'s and `isChecked`'s setters: let `live = surface == .warmPane && railArmed && checked`. `.warmPane`: unavailable → name, glyph, unavailable-label all `labelCool2`; else name `live ? label : labelCool`, glyph `live ? label2 : labelCool2`. `.systemSheet`: name `device.isAvailable ? label : label3`, glyph `device.isAvailable ? label2 : label3` (today's :296 branch), unavailable label `label3` (exactly today's colours through the new names). Rewrite the comment :277-292 (keep the "ONE unavailable tone" argument; the tone is `labelCool2`, 4.59:1 on dark `raised`, 5.30:1 on the light ground; drop the `.disabledControlTextColor` paragraph's numbers only if they no longer read true — they still do, keep it).
10.3 Hooks: `public var test_nameColor: NSColor?`, `test_glyphTint: NSColor?`, `test_unavailableLabelColor: NSColor?`, `test_drawsGlyphTile: Bool { surface == .warmPane }`.

### Step 11 — `AudioutCore/Sources/AudioutWindowUI/IconPickerViewController.swift`

11.1 Every curated button is layer-backed (`wantsLayer = true`, `layer?.cornerRadius = Tokens.Layout.Radius.control`, `layer?.masksToBounds = true`). Selected (`isCurrent`): `contentTintColor = Tokens.Color.inkOnFill`, and in the restamp pass `layer.backgroundColor = gold.cgColor`, `borderWidth = 0`. Unselected: `contentTintColor = Tokens.Color.labelCool`, restamp `layer.backgroundColor = well.cgColor`, `borderWidth = 1`, `borderColor = hairline.cgColor`. Keep the ", current icon" VoiceOver suffix. Replace `selectionRingButton` with `private var curatedButtons: [NSButton]` (rebuilt in `buildGridRows`) and `selectedButton: NSButton?`; rename `refreshSelectionRingColor` → `restampCellColors()`: increments `test_cellRestampCount` once, then stamps every button under `performAsCurrentDrawingAppearance` as above. Call it at the end of `buildGridRows` (once, not per button — delete the per-button call at :271) and from the existing observers (:98-116, :427, rename `ringTokensDidChange` → `cellTokensDidChange`). Rename `test_ringRefreshCount` → `test_cellRestampCount`, `test_currentRingSymbolName` → `test_selectedCellSymbolName`. Add `public func test_cellGlyphTint(for name: String) -> NSColor?` and `public func test_cellFillColor(for name: String) -> NSColor?` (`NSColor(cgColor:)` of the layer background, converted with `usingColorSpace(.sRGB)` before any comparison). Rewrite the ring comments (the observer block :98-116 and the `isCurrent` block in `makeCuratedButton`) (a binary, not a ring: one `gold` surface with `inkOnFill`, or the chassis's own `well` recess with a `labelCool` glyph — ~/Projects/audiout-remote/DESIGN.md:950-953).
11.2 `WarmPreviewTileView.draw` (:525-533): radius → `Radius.control`, `hairline` → `containerEdge`; its doc updated. Aliases: :135, :158, :358 → `label2`.
11.3 `GroupCreationSheetController.swift` :184, :204, :309, :416 → `label2` (mechanical; the sheet's look does not change). `MixerWindowController.swift:794` → `label2`.

### Step 12 — `AudioutCore/Sources/AudioutSharedUI/Tokens.swift` (PR 3 shape)

Delete the `sidebarWarmTint` and `iconSeatFill` aliases (and their `@available` lines). `groupedSectionCornerRadius` doc: drop "and the Groups window's `GroupedSectionView`"; it is onboarding's `RoundedContainerView` radius now. `Radius` doc: replace "NO consumer is re-pointed at them in the commit that adds them — each surface PR adopts the rung it needs" with "The rows PR and the Groups PR adopted them (D6 of PR 5: card/tile = row, seats/chips/plate/picker = control, the Equalizer and checklist card = panel)." Grep the file for `SidebarWarmSurfaceView`, `sidebarWarmTint`, `iconSeatFill`, `icon seat` and rewrite any remaining comment sentence so it stands without the name.

### Step 13 — `AudioutCore/Sources/AudioutWindowUI/AGENTS.md`

Replace line :23 with "- Ink carries temperature (C5, 2026-09-03): `labelCool` on idle names and glyphs, `label` on the live one; chrome and the sidebar stay stock. `GroupsInkTemperatureTests` pins it." Replace the "Gold means LIVE, per row; it is never decoration here." bullet's neighbour? No — keep it. Add after it: "- Magenta is identity, never state: `GroupIdentityGlowView` sits behind every group seat, active or not." Map: `GroupsOverviewViewController` line → "the group list: card grid with seats, absorbed empty state."

### Step 14 — tests (Test plan), one file at a time. Then `bash scripts/build.sh` and Verification.

## Ratio table (new to this PR)

Grounds: dark `raised` `#1F232A`, `panel` `#15171A`, `well` `#050507`; light flat ground `#FAFAFB`, `well` `#E9EAEC`.

| pair | dark | light |
|---|---|---|
| gold 12 % wash composited on `raised` | `#37352E`: 1.285 vs raised, 1.463 vs panel | `#F0EBE0`: 1.140 vs ground |
| `labelCool` / `label2` / `labelCool2` on that wash | 5.76 / 5.46 / 3.57 (labelCool2 BANNED on a live card — D8 uses label2 there) | 5.95 / 5.24 / 4.65 |
| `gold` ring vs `raised` / vs wash | 8.55 / 6.66 | 3.64 / 3.20 |
| `containerEdge` vs `raised` / `panel` | 1.553 / 1.769 | 2.020 / 2.020 |
| `hairline` vs `panel` / `well` / `raised` | 1.314 / 1.491 / 1.154 (BANNED) | 1.512 / 1.310 / 1.512 |
| `well` vs `raised` (member tile on the checklist card) | 1.292 | 1.154 |
| glow core (`partyRampDeep` @ 0.22 / 0.10) on `raised` | `#503B54`: 1.572 vs raised, 1.013 vs containerEdge | `#EDE5EC`: 1.183 vs ground |
| the same with iOS's `#752C68` (after the wizard PR re-values the token) | 1.094 vs raised | unchanged |
| `labelCool` / `labelCool2` on `raised` / `panel` / `well` | 7.40 · 4.59 / 8.43 · 5.23 / 9.55 · 5.93 | 6.79 · 5.30 / 6.79 · 5.30 / 5.88 · 4.60 |
| `inkOnFill` on `gold` (picker selected cell) | 10.18 | 4.94 |

## Interim visible effects this PR finalises (from PR 1's table) and introduces

| row | finalised as |
|---|---|
| `sidebarWarmTint → panel` (PR 1: "Groups sidebar wash goes cool (panel at ~0.30 alpha)") | wash deleted on both screens; sidebars sit on the surface's `panel` ground |
| `iconSeatFill → raised` (DeviceIconWellView, member chips) | consumers name `raised`; alias deleted |

Introduced: group cards `raised` + `containerEdge` at 16 pt with a 28 pt seat, gold wash + gold seat ring + `goldText` "Playing now" when live, cool ink when idle, a magenta glow behind every seat (D5 strength); the editor well and detail-pane wells at 10 pt with `labelCool` glyphs (warm only on the active group's editor); the editor well glows; member rows carry a 24 pt `well` tile and cool ink unless armed; the detail panes' Groups and About lists become stroked `panel` rows at 16 pt; the Equalizer and checklist cards round to 26 pt with `containerEdge` dividers; picker cells become gold-filled / well-recessed; the New Group tile and the sidebar plate stroke `containerEdge`. No shadows anywhere.

## Test plan (only these files)

- **`SidebarWarmSurfaceTests.swift`**: DELETE (Step 2).
- **`GroupsWindowTextColorLockTests.swift`**: DELETE. Replace with **new `GroupsInkTemperatureTests.swift`** (`@MainActor @Suite final class GroupsInkTemperatureTests: IsolatedSuite`, copying the deleted file's `resolved(_:appearanceName:)`, `sameColor`, `makeDevice`, `makeGroupController`, `makeEditor`, `membershipWellView(of:)`, `sampledColumnColors` helpers verbatim; "same colour" = both appearances, sRGB, 0.01 tolerance). Tests:
  1. `idleCardInkIsCool`: `test_cardNameColor(isLive: false)` same as `labelCool`; `test_cardGlyphTint(isLive: false)` same as `labelCool`; `test_cardMetaAttributedString(isLive: false)` foreground at index 0 same as `labelCool2`.
  2. `liveCardInkIsWarmWithGoldTextPlayingNow`: name and glyph same as `label`; meta foreground at index 0 same as `label2`; foreground at the start of the "Playing now" range same as `goldText`.
  3. `liveCardRingsTheSeatGoldAndIdleCardEdgesItCool`: `test_cardSeatStroke(isLive: true)` = (`gold`, 1.5); `(isLive: false)` = (`containerEdge`, 1).
  4. `everyGroupCardCarriesTheIdentityGlow`: `test_cardHasIdentityGlow` true for both plans (PR 4's `GroupIdentityGlowViewTests` covers the alphas; nothing is re-asserted here).
  5. `memberRowInkFollowsArmedMembership`: `MembershipRowView(device:checked: true, surface: .warmPane)` with `railArmed = true` → `test_nameColor` same as `label`, `test_glyphTint` same as `label2`; `railArmed = false` → `labelCool` / `labelCool2`; `isChecked = false` with `railArmed = true` → `labelCool`.
  6. `unavailableMemberRowIsOneCoolTone`: unavailable device on `.warmPane` → name, glyph and `test_unavailableLabelColor` all same as `labelCool2`; `test_drawsGlyphTile` true.
  7. `systemSheetRowKeepsStockInk`: `.systemSheet` available → name same as `label`, glyph `label2`; unavailable → name, glyph and unavailable label all same as `label3`; `test_drawsGlyphTile` false.
  8. `iconWellGlyphIsCoolUntilTheGroupIsActive`: `DeviceIconWellView()` → `iconImageView.contentTintColor` same as `labelCool`; `isActiveGroup = true` → same as `label`; back to false → `labelCool`.
  9. `editorHeaderWellCarriesTheIdentityGlowAtEightyPoints`: `makeEditor().test_hasIdentityGlow`; add `public var test_identityGlowSide: CGFloat` (the glow view's laid-out `frame.width` after `layoutSubtreeIfNeeded`) and assert it equals `GroupEditorViewController.iconGlowSide` (80) — the size the gradient scales to, per Step 1.
  10. `sidebarCellsKeepStockInk`: the body of the deleted suite's `sidebarOutlineCellsStayStock` (GroupsWindowTextColorLockTests.swift:252) — copy its `assertFrozenToStock` helper too, or rewrite the body against `sameColor` — asserting name colours same as `label` for header-less rows, the header cell same as `label2`, the unavailable device cell same as `label3`.
  11. `membershipCardFillIsRaisedAndDividerIsContainerEdgeBothAppearances`: the deleted suite's two sampling tests merged: a `raised` pixel and a `containerEdge` pixel both found in the sampled column, both appearances.
  12. `coolInksClearTheTextFloorOnEveryGroupsGround`: `labelCool`, `labelCool2` ≥ 4.5 on `raised`, `panel`, `well`, both appearances (WCAG math copied from `MembershipWellContrastTests`); tightest 4.59 (dark labelCool2 on raised), 4.60 (light labelCool2 on well).
  13. `pickerSelectedCellIsGoldWithInkOnFillAndUnselectedIsCool`: `IconPickerViewController()`, `configure(currentSymbolName: "airpods", defaultSymbolName: "hifispeaker.fill")`, `_ = picker.view`; `test_cellGlyphTint(for: "airpods")` same as `inkOnFill`, `test_cellFillColor(for: "airpods")` same as `gold`; `"hifispeaker.fill"` → `labelCool` / `well`.
- **`IconPickerTests.swift`**: `:139-151` → rename to `curatedCellsRestampOnAccentAndAccessibilityNotifications`, read `test_cellRestampCount`, `test_selectedCellSymbolName`; expectation stays `baseline + 2`. Grep the Tests folder for `test_currentRingSymbolName` / `test_ringRefreshCount` and rename every reader.
- **`MembershipWellContrastTests.swift`**: doc comment :19-22 ("Locked constraint (owner's call): text colors stay frozen everywhere — separation must come entirely from surfaces … never a text-color change.") → "Ink carries temperature since C5 (2026-09-03) — `GroupsInkTemperatureTests` pins that; these tests measure the surfaces." `:12-14` "ruled inside by `hairline`" → "ruled inside by `containerEdge` (rule 5)". Test bodies unchanged.
- **`GroupsOverviewViewControllerTests.swift`**, **`GroupsHeaderParityTests.swift`**, **`MembershipRailTests.swift`**, **`AppSurfaceControllerTests.swift`**, **`DeviceIconWellViewTests.swift`**, **`DeviceDetailViewTests.swift`**, **`MixerWindowControllerTests.swift`**, **`SettingsRootViewControllerTests.swift`**, **`SidebarActionsTests.swift`**: no edits; run them (Verification). They read no colour this PR moves except `memberChipGlyphIsTintedLabel` (kept `label`).

## Verification (in this order; paste each command's output)

```bash
bash scripts/build.sh                      # exit 0
AUDIOUT_TEST_NO_CACHE=1 bash scripts/run-tests.sh --filter 'GroupsInkTemperatureTests|MembershipWellContrastTests|IconPickerTests|GroupsOverviewViewControllerTests|GroupsHeaderParityTests|MembershipRailTests|AppSurfaceControllerTests|DeviceIconWellViewTests|DeviceDetailViewTests|MixerWindowControllerTests|SidebarActionsTests|GroupRenameFieldTests|EQEditorViewTests|SettingsRootViewControllerTests|TokenContrastMatrixTests|MembershipBusTests'
#   expected: every suite passes; count = baseline − 5 (SidebarWarmSurfaceTests) − 10 (lock suite) + 13 (new suite) — report the real number
AUDIOUT_TEST_NO_CACHE=1 bash scripts/run-tests.sh       # the FULL suite, once, green
git grep -n "SidebarWarmSurface\|sidebarWarmTint\|iconSeatFill\|rendersOnSystemSidebarMaterial\|test_ringRefreshCount\|test_currentRingSymbolName" -- AudioutCore ':!*AGENTS-HISTORY.md'
#   expected: no output
git grep -n "Color\.\(secondaryLabel\|inkTertiary\|tertiaryLabel\|inkSecondary\)\b" -- AudioutCore/Sources/AudioutWindowUI
#   expected: no output
git grep -n "Color\.hairline" -- AudioutCore/Sources/AudioutWindowUI
#   expected: exactly GroupedSectionView.swift (the non-card divider), GroupsOverviewViewController.swift (MemberChipView overflow dash + NewGroupTileView ring border), MembershipRowView.swift (the tile), IconPickerViewController.swift (unselected cell border), MixerWindowController.swift:751 (`HairlineView.draw`, the title-bar seam on `panel` — legal, untouched) — nothing else
git grep -n "shadowOpacity\|shadowRadius\|NSShadow" -- AudioutCore/Sources/AudioutWindowUI
#   expected: no output
git grep -n "groupedSectionCornerRadius" -- AudioutCore/Sources
#   expected: Tokens.swift (the declaration) and OnboardingChrome.swift only
git status --short dev/notes/window-snapshots dev/notes/settings-snapshots   # expected: no output (never regenerated)
```

Then, from the worktree root:

```bash
git add -A AudioutCore dev/notes/design-migration-scoping/PR5-groups-work-order.md
bash scripts/self-review.sh               # Guard 7
git commit -m "Groups window: cool chassis, icon seats, temperature ink, identity glow

Deletes the sidebar warm wash on both screens (C6), strokes every card
with containerEdge at the three iOS radii, gives each group card a raised
28 pt seat with a gold ring and a gold 12 % wash while it is the live
Main Out, moves names and glyphs onto the cool/warm ink rule (C5), turns
the icon picker into a gold-filled / well-recessed binary, tiles the
editor's member rows, draws the detail panes' fact lists as stroked panel
rows, and adds GroupIdentityGlowView behind every group seat (R3). Window
snapshots are stale by design and not regenerated.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
git push origin claude/design-groups
gh pr create --base main --head claude/design-groups --title "Design migration PR 5: the Groups window" --body-file <a body you write: Goal, D1–D12, the Interim table, the Owed checks, the pasted Verification output, "dev/notes/window-snapshots is stale, by eye", and the footer "🤖 Generated with [Claude Code](https://claude.com/claude-code)">
```

Do NOT merge the PR.

## Owed checks (do not block the PR; list them in the PR body)

- Both sidebars on the bare `panel` ground with no material, dark and light (D1) — does the split divider alone carry the sidebar/pane split, or does the owner want the `NSVisualEffectView` sidebar material back?
- The dark identity glow at the Mac's electric `partyRampDeep` (1.57:1 on the card, D5) versus the iPhone's quieter deep magenta; the wizard PR's re-value dims it automatically.
- A selected sidebar row in both appearances: the stock-ink decision (D2) rests on AppKit's re-inking of semantic colours over the selection pill — confirm the selected row's name reads white/black on the pill as before.
- The 28 pt seat on a 118 pt card (D3) — read against the iPhone's 44.
- Stroke-only `panel` rows in the detail panes in dark (the pane ground is `panel`).
- 26 pt corners on the Equalizer and checklist cards.
- `dev/notes/window-snapshots/*.png` are stale (14 files); the owner's eye is the only verification of this window.

## Requests to PR 3

None. `PopoverColumnGrid.rowLiveWashAlpha` is consumed as-is; no row file changes.

## Hand-off to the remaining PRs

- **PR 4 (popover):** owns `GroupIdentityGlowView`; this PR only mounts it (at 48 behind the card seat, at 80 behind the editor well). The one ordering rule: PR 5 branches AFTER PR 4 merges; Pre-flight STOPs if the file is absent. If PR 4's class cannot scale with its mount (Step 1), the fix goes into PR 4's file by a follow-up, never a second glow here.
- **PR 6 (settings):** `SettingsSidebarViewController.swift` is edited HERE (Step 3.2) and only here; PR 6's order already fences it (PR6-settings-work-order.md:25-27, :490-491). Both sidebars now sit on `panel`.
- **PR 8 (wizard):** keeps `party`/`partyRampDeep` hexes (its fence :13) and moves the wizard's magenta to `ring`. Its hand-off asks for a contrast test where `partyRampDeep` is drawn: none applies — the glow is a floor-exempt halo (D5), and PR 4's `GroupIdentityGlowViewTests` pins the alphas.
- **PR 9 (docs):** `AudioutSharedUI/AGENTS-HISTORY.md:53, :98` and `AudioutSettingsUI/AGENTS-HISTORY.md:25` still describe `SidebarWarmSurfaceView`; `AudioutWindowUI/AGENTS-HISTORY.md:249` describes two `GroupedSectionView` styles. a Mac DESIGN.md does not exist at HEAD; PR 9 records D1–D12 wherever it lands the Mac design record.
- Still aliased after this PR: `secondaryLabel`, `tertiaryLabel`, `inkSecondary`, `inkTertiary`, `canvasHi`, `accent`, `warning`, `info`, `success`, `warningText`, `goldCTA`, `inkOnGold`, `plateRim`, `syncSignal`, `partySignal`, `partySignalDeep` (PR 3 may have removed more; grep before assuming).

## Execution plan

One track, SERIAL, model **opus**, effort **high**: Steps 2–3 hold the build red across three targets, the card re-flow (Step 7) and the member-row ink function (Step 10) each carry state ordering that must be reasoned, and the replacement suite has thirteen assertions against seams this PR itself introduces. No parallel tracks: the test suite and `Tokens.swift` are shared by every step. The branch is cut from `origin/main` after PR 3 and PR 4 merge; there is no uncommitted work it depends on. Verification runs once at the end.

## Executor rules (copy verbatim into the handoff prompt)

> - Follow the steps in order. Do not add, merge, reorder, or skip steps.
> - Before editing in any folder, read the nearest AGENTS.md above it (and the root one) if the repo has them — folder rules and traps bind even when the work order doesn't repeat them.
> - If reality contradicts a Verified fact or a step is impossible as written, STOP and report the discrepancy. Do not improvise a workaround.
> - Before reporting progress, audit each claim against a tool result from this session. Only report work you can point to evidence for. If tests fail, say so with the output.
> - "Done" means the Verification commands were run in this session and passed. Paste their output.
> - Touch nothing in the Out-of-scope list.
> - Deliver what was asked, at the scope intended. If the spec seems mistaken or a better approach exists, say so in a sentence and continue as specified rather than quietly narrowing, widening, or transforming it.
