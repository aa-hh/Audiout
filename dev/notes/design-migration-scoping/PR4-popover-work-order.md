# PR 4 work order: the popover — banners, card chrome, Main Out row, splash, canvas

Executor: Opus. New worktree cut from `origin/main` AFTER PR 3 (rows) merges. Every path is
relative to the worktree root. Every ratio below was computed with the WCAG 2.x relative-luminance
formula (`scratchpad/contrast.py`, the same formula `MembershipWellContrastTests` carries) or is
quoted from PR 1's Token table / PR 3's ratio table; the executor cites them without recomputing.

## Goal

Move the popover's own chrome onto PR 1's tokens: the two note banners and the connection
diagnosis card become one family (`failure` / `ring` at 12 %, control radius, no border); the card
divider becomes `containerEdge` and a card's title reads `goldText` while anything in it is
sounding; the Main Out row gets the readout font/colours PR 3 gave the device rows plus the
magenta chevron and seat glow that mark "Main Out is pointed at a saved group" (R2); the splash
sets "Audiout" in the wordmark face; `WarmCanvasView` loses its dead gradient; `GroupRowView`
(no production consumer since 2026-07-16) is deleted. Sections, toolbar, status item, HUD and
every geometry constant stay as they are.

## Scope fences — PR 4 must NOT touch

- `DeviceRowView.swift`, `AppRowView.swift`, `PopoverColumnGrid.swift` (PR 3 owns them; see
  "Requests to PR 3"). One exception: the three comment-only `GroupRowView` rewrites in
  `DeviceRowView.swift` named in Step 12.4 — no code line changes there. `CardView.swift`, `SurfaceToolbar.swift`, `StatusItemController.swift`,
  `StatusItemIcon.swift`, `MenuBarStatus.swift`, `MenuTriggerImageView.swift`,
  `VolumeHUDPanel.swift`, `HaloRingView.swift`, `RouteArmedDotView.swift`, `WarmFaderCell.swift`,
  `LevelMeterView.swift`, `MembershipBusView.swift`, `BusRailOverlayView.swift`,
  `WarmPanelView.swift`, `ControlPanelBackingView.swift`: untouched.
- No file under `AudioutWindowUI`, `AudioutOnboardingUI`, `AudioutSettingsUI`, `AudioutApp`.
  `GeneralSettingsViewController.swift:231/:551` keep reading `Tokens.Color.warning` (D3).
- `PopoverController.swift`: only Step 6's additions (one method, three call sites). No change to
  `deviceSections()`, card order, subsection split, collapse policy, ingest or rail code (S1).
- `PopoverPanelViewController.swift`: only Steps 4 and 5. Header height 28, insets, chevron,
  hover wash, `HeaderHoverWashView`, the panel shell radius (`panelCornerRadius` 12): untouched.
- `MainOutRowView.swift`: no geometry (row height 44, column anchors, ring/dot boxes, pop-up
  width 140). No frosted deck, no material, no stroke, no shadow (R2: "no frosted deck").
- `Tokens.swift`: only (a) delete the `info`, `canvasHi` aliases and `Layout.bannerCornerRadius`,
  (b) the doc-comment edits Step 9 names. `Font.microLabel` stays 10 pt (Alec's no-reflow ruling).
  No new token. `warning`, `partySignal`, `partySignalDeep`, `iconSeatFill`, `accent`, `success`,
  `warningText`, `goldCTA`, `inkOnGold`, `plateRim`, `syncSignal`, `sidebarWarmTint`,
  `secondaryLabel`, `tertiaryLabel`, `inkSecondary`, `inkTertiary` aliases stay (other PRs own them).
- The alignment wizard files (`AlignmentStageView`, `AlignmentWizardViewController`,
  `BTAlignmentWizardView`) keep reading `partySignal`/`partySignalDeep` — the wizard PR's.
- No regeneration of `dev/notes/window-snapshots`, `onboarding-snapshots`, `settings-snapshots`,
  `wizard-snapshots`. `dev/notes/popover-snapshots/*.png` ARE regenerated (Step 12).
- No `make-app.sh`, no live-test slot, no dev build. The wordmark face is live-verified by Alec
  in a dev build later (Owed checks); under `swift test`/snapshots it is the system bold fallback.
- No `DESIGN.md`, `PRODUCT.md`, `docs/FIGMA-DESIGN-SYSTEM.md`, `docs/SPEC.md`, `docs/PROGRESS.md`,
  `ROADMAP.jsonl`, any `AGENTS-HISTORY.md` (archived), any other file in
  `dev/notes/design-migration-scoping/`. `AudioutPopoverUI/AGENTS-HISTORY.md:85` still names
  `GroupRowView` — archived, left as is.
- No cleanup, no abstractions beyond Step 7's one shared view, no error handling for impossible
  cases, no backwards-compat shims. A constant or class that loses its last consumer is deleted.

## Decisions recorded (the executor does not re-open these)

- **D1 "Live" for a card title is computed by `PopoverController` from its own model**, never
  read back from a row's `test_` hook and never re-derived inside the panel. The three predicates:
  - System Audio: `(case .connected = mainOutConnectionState(controller) && !controller.isMainOutMuted) || mainOutIsLocalOnlyArmed(controller)` — exactly `MainOutRowView.isSpineLive`
    (`armed || restingArmed`, MainOutRowView.swift:216) and the term `isLiveMainAudioRemoval`
    already spells out (PopoverController.swift:2427-2430).
  - Output Devices: any `id` in `deviceRowsByID.keys` with `device = devicesByID[id]` where
    `!(liveRoutedAppNames[id] ?? []).isEmpty` OR (`groupController` exists AND
    `controller.isMainOutMember(id)` AND `device.connectionState` is `.connected` AND
    `!(device.isMuted || controller.isMuted(id))` AND `!controller.isMainOutMuted`) — the same
    inputs `applySelectionState` feeds `DeviceRowView.apply` (PopoverController.swift:2723-2762),
    which computes `isRouteArmed = mainMixArmed || hasLiveFeeds` (DeviceRowView.swift:608-613).
  - App Routing: any route in `appRouting.appRoutes` with `!isAppExcluded(route.bundleID)` AND
    `route.destination != .noRedirect` AND `!offlineBundleIDs.contains(route.bundleID)` — the
    row's `faderCell.isRouteArmed = !isNoRedirect && configuration.isRunning`
    (AppRowView.swift:272; `isNoRedirect` is the standalone `noRedirectDestinationID` entry,
    AppRowView.swift:245-246, PopoverController.swift:752/:3512/:3612). The equivalence relies on
    `appDestinations` re-appending an offline `.device` target as an entry (:3557-3563), so a
    routed row's selected id is always in its list and `isNoRedirect`'s `?? true` never fires.
  A test pins each predicate to the rows' rendered state (`test_routeArmed`,
  `test_isFaderEngaged`).
  **Known exception (accepted, cosmetic):** the App Routing predicate reads the
  stored `route.destination`, while the row reads its own popup entry. If a
  routed speaker leaves discovery entirely, the row can fall back to the
  standalone entry (unarmed fader) while the stored destination is still a
  `.device`, so the title stays gold over a silent row. Title tint only —
  nothing audible, nothing else in the card moves.
- **D2 The title is retinted by re-setting its attributed string.** `makeLegendLabel` builds the
  label with `labelWithAttributedString` and a `.foregroundColor` attribute
  (PopoverPanelViewController.swift:1184-1187); an attribute wins over `textColor`, so the setter
  rebuilds the attributed string with the same text and font and the new colour. Idle colour is
  `label2` (today's `secondaryLabel`, PR 1 alias).
- **D3 `warning` alias stays; `info` retires.** `info`'s last consumers are
  `SystemAirPlayNoteBannerView.swift:40` and `NoteBannerColorTests` — both re-pointed here.
  `warning` is still read by `GeneralSettingsViewController.swift:231` and `:551` (Settings notes);
  the Settings PR (PR 6) owns that file and retires the alias. `SystemAirPlayNoteBannerView.Severity`
  keeps its case names `.info`/`.warning` (12 call sites in `PopoverController`/tests use them as
  tiers, not colours); only what each case returns changes.
- **D4 Banner recipe (iOS "Status Banners"):** fill = tint at 12 % (`failure` for the silence
  banner and the note banner's `.warning` tier; `ring` for `.info`), no border
  (`borderWidth` 0, `borderColor` unset), radius `Tokens.Layout.Radius.control` (10) — a banner is
  an inset control-sized rect, not a row or a panel. `Tokens.Layout.bannerCornerRadius` (11) loses
  both consumers and is deleted. Glyph tint = the same token at full strength; text stays `label`.
- **D5 `ConnectionDiagnosisView.backgroundCornerRadius` 7 → `Tokens.Layout.Radius.control`** so
  the three inset cards share one corner. Its 12 % `failure` blend over `panel` is already the
  recipe (ConnectionDiagnosisView.swift:221-240) and is untouched.
- **D6 REVERTED during review (2026-09-04) — the pop-up stays bordered and the arrow keeps its
  neutral tint.** A borderless `NSButton` silently discards `drawFocusRingMask` (openradar
  29465363), so keyboard focus on this control would be invisible — the trap this repo already
  documents at `AlignmentPlateButton.swift:38`, on a popover that does take key focus
  (`ControlPanelWindowController.swift:187`). The regenerated snapshot also showed ~75 pt of bare
  ground between title and arrow, so the borderless button stopped reading as one control. The
  group's magenta is carried on this row by `GroupIdentityGlowView` and the "→ <group>" title
  instead. What survives from the original D6: the display-only cell item with an attributed
  title in `Tokens.Color.label`, now also carrying a tail-truncating paragraph style (an
  attributed title makes the cell ignore its own `lineBreakMode`). The original reasoning follows,
  kept because it is the record of why the borderless route looked right first.
- **D6 (original, superseded) The destination pop-up goes borderless; the chevron carries the tint.** Probe (this
  session, `scratchpad/popup_probe*.swift`, rendered under `.darkAqua`): on a bordered
  `NSPopUpButton` `contentTintColor` changes nothing — the arrow is bezel-drawn; on a borderless
  one it tints title AND arrow; with the display-only cell item carrying an attributed title in
  `label`, the title stays `label` and only the arrow takes the tint. So: `isBordered = false`
  permanently (a state-dependent bezel would jump; iOS's `MainOutPicker` is a bezel-less `Menu`
  with a text label), `usesItemFromMenu = false` in BOTH `apply` branches with the display item's
  `attributedTitle` in `Tokens.Font.caption` + `Tokens.Color.label`, and `contentTintColor` =
  `Tokens.Color.partyRampDeep` while `current` is `.group`, else `Tokens.Color.label2` (the
  icon's own neutral tint). `partyRampDeep`, not `party`: `party` is `#FF90E9` in BOTH
  appearances (Tokens.swift:1011-1014) and measures 1.93:1 on the light ground — under the 3.0
  graphic floor; `partyRampDeep` is the same `#FF90E9` in dark (8.91:1 on `panel`) and `#752C68`
  in light (8.69:1 on the ground, PR 1's table) — how iOS puts magenta on paper. A magenta TITLE
  would break iOS's "never text" rule (`/Users/alechenderson/Projects/audiout-remote/DESIGN.md:339-341`),
  which is why the attributed title exists.
- **D7 The seat glow is one shared view, `GroupIdentityGlowView`, in `AudioutSharedUI`** (new
  file), the Mac mirror of iOS `GroupIdentityGlow` (audiout-remote GroupsView.swift:205-228):
  a 60×60 view whose `CAGradientLayer` is `type = .radial`, `startPoint (0.5, 0.5)`,
  `endPoint (1, 1)`, colours `[partyRampDeep at 0.22 (dark) / 0.10 (light), .clear]`,
  locations `[0, 1]` — the core clears to nothing by 30 pt. Re-stamped in
  `viewDidChangeEffectiveAppearance` under `performAsCurrentDrawingAppearance` (the
  `stampLayerColors` idiom); `hitTest` returns nil; `setAccessibilityElement(false)`;
  `intrinsicContentSize` 60×60. In `MainOutRowView` it is the FIRST subview (behind
  `busOriginView`), centred on `iconView`, `isHidden` unless `current` is `.group`. The row is
  44 pt tall, so the row's layer clips 8 pt top and bottom — accepted; the leak reads sideways.
  The Mac Main Out icon has no opaque seat (there is no `DeviceIconWellView` in this row —
  verified MainOutRowView.swift:330-460), so the glow's core sits behind the bare glyph; `label2`
  `#B7AC95` on the dark core `#483248` measures 5.12:1, the glyph stays legible. PR 5 mounts the
  same view behind every `DeviceIconWellView` group seat (opaque, so there it leaks as iOS
  intends) and does not redraw the recipe. Core composites: dark 22 % on `panel` `#483248`
  (1.561:1), on `canvas` `#40273D` (1.484:1); light 10 % on the ground `#EDE5EC` (1.183:1).
- **D8 Main Out readout:** `Tokens.Font.readout` (PR 3 Step 16.1) with `goldText` while `armed`
  (the fader's own gold predicate, MainOutRowView.swift:215-227 — connected ∧ unmuted; NOT
  `isSpineLive`, so the number and the fader fill on the same row always agree) else
  `emberText`. The master slider is always enabled and never `controlsMuted`, so PR 3 D6's
  `labelCool2` rung has no case here. Restamped in `apply` only (`masterChanged` writes the
  string, not the colour). `goldText` Full dark on `panel` 9.74:1, light on the ground 5.66:1;
  `emberText` from PR 1's table.
- **D9 Splash wordmark size 31 pt.** iOS sets the wordmark at 32 pt beside a 100 pt mark
  (`/Users/alechenderson/Projects/audiout-remote/AudioutRemote/UI/Connect/ConnectGateView.swift:669/:712` — ratio 0.32); the Mac mark is 96 pt (`markSide`,
  SurfaceSplashView.swift:45) → 30.72, rounded to a whole point. Colour stays `label`; stack
  spacing 10 stays. `Tokens.Font.wordmark(size:)` already falls back to system bold outside a
  `.app` (Tokens.swift:1221-1231) — no guard in the view.
- **D10 `WarmCanvasView`:** the gradient branch (`canvasHi` → `canvas`) is dead since PR 1 aliased
  `canvasHi == canvas`; delete the `CGGradient` block and its `else`, fill flat `canvas`, keep the
  dark-only grain and the flatten branch exactly as they are. `canvasHi` alias retires (last
  consumer). The doc comment stops describing a gradient.
- **D11 The card divider class is renamed `CardDividerView`** and stamps `containerEdge`: it
  crosses bare canvas and is the section's own boundary (iOS Section Header,
  `/Users/alechenderson/Projects/audiout-remote/DESIGN.md:666-671`; Rule 5). `containerEdge` on dark `canvas` 1.95:1, light 2.02:1 (PR 1 table). Name changes because
  "HairlineView" would lie about the token. Private class, 3 references in one file.
- **D12 `GroupRowView` deletion is a `git rm`** of `AudioutPopoverUI/GroupRowView.swift` (421
  lines, in PopoverUI — NOT SharedUI as the scoping report's "Files touched" line implies) and
  `Tests/AudioutCoreTests/GroupRowViewTests.swift` (110 lines). `PopoverIconTests` loses its three
  group-row tests and `expectedGroupIcon`; its doc comment and `findImageView`'s comment drop the
  `GroupRowView` clauses. `PopoverColumnGrid.readoutTrailing` then has NO consumer and
  `sliderTrailing` still has four (MainOutRowView:520, AppRowView:616, DeviceRowView:1617,
  PopoverColumnGrid:859/:868) — `sliderTrailing` stays; `readoutTrailing` is a Request to PR 3
  (below), not deleted here.
- **D13 Tests that only compile through an alias are edited to the new name** where this PR
  deletes the alias (`NoteBannerColorTests` → `failure`/`ring`). No other test is swept.

## Pre-flight (from the NEW worktree root)

```bash
git worktree add .claude/worktrees/pr4-popover -b claude/pr4-popover origin/main
cd .claude/worktrees/pr4-popover && git push -u origin claude/pr4-popover && git config core.hooksPath .githooks
# PR 3's hand-off symbols must exist (every line must print a hit):
git grep -n "public static var readout: NSFont" -- AudioutCore/Sources/AudioutSharedUI/Tokens.swift
git grep -n "rowLiveWashAlpha" -- AudioutCore/Sources/AudioutSharedUI/PopoverColumnGrid.swift
git grep -nE "public static (let|var) (goldText|emberText|label2|ring|party|partyRampDeep|containerEdge)\b" -- AudioutCore/Sources/AudioutSharedUI/Tokens.swift   # 7 hits; label2 is `let` (:113), the rest `var`
git grep -n "enum Radius" -A 3 -- AudioutCore/Sources/AudioutSharedUI/Tokens.swift
# These must be EMPTY (PR 3 removed them); a hit means PR 3 has not merged — STOP:
git grep -n "AppTetherColor\|paintsSelectionBackground" -- AudioutCore/Sources
bash scripts/build.sh                                   # exit 0
bash scripts/run-tests.sh --filter 'NoteBannerColorTests|ConnectionDiagnosisViewTests|MainOutRowRingTests|MainOutRowMenuDispatchTests|AppSurfaceControllerTests|PopoverPanelHeaderTests|PopoverIconTests|GroupRowViewTests|AccessibilitySignalSweepTests|BrandMarkTests|MembershipWellContrastTests|PopoverControllerTests'
```
Record the baseline test count (at HEAD `586bd8a2` without `PopoverControllerTests` it was
134 tests in 11 suites, all passed).

## Verified facts (file:line, checked 2026-09-03 at `586bd8a2`; PR 3 does not touch these files unless noted)

- `SilenceFallbackBannerView.swift`: `icon.contentTintColor = Tokens.Color.warning` :29; radius
  `Tokens.Layout.bannerCornerRadius` :64; `borderWidth = 1` :65; `stampLayerColors()` :128-133
  stamps `warning` at 0.14 fill / 0.40 border; `test_backgroundColor`/`test_borderColor`
  :145-152; doc comment :6-11 says "system-orange".
- `SystemAirPlayNoteBannerView.swift`: `Severity` :36-70 (`tintColor` :39-44 → `info`/`warning`;
  `backgroundAlpha` 0.12/0.14 :45-50; `borderAlpha` 0.35/0.40 :51-56); radius :117; `borderWidth`
  :118; `stampLayerColors()` :187-194; hooks :199-212; doc comment :6-16 says system-blue/orange.
- `ConnectionDiagnosisView.swift`: `backgroundCornerRadius: CGFloat = 7` :40, applied :116;
  `failureTintFraction = 0.12` :219; `applyBackgroundTint()` :233-239 blends `failure` into `panel`.
- `PopoverPanelViewController.swift`: `headerTitleLabelsByHeader` :76 (card AND subsection
  titles); `beginCard` :560-790; title built :589-593 via `makeLegendLabel(_, weight: .semibold,
  color: Tokens.Color.secondaryLabel)`; `makeLegendLabel` :1178-1189 (attributed string, font
  `captionEmphasized` for `.semibold`); divider inserted :763-776 as `HairlineView`;
  `HairlineView` :1645-1666 (class line :1650) stamps `Tokens.Color.hairline` at :1654 and :1663; test hooks
  :1540-1546 (`test_headerTitleAXRole(title:)` shape).
- `PopoverController.swift`: `rebuild()` :1487; cards built :1555 (System Audio), :1603 (Output
  Devices), :1694 (App Routing); title constants :2141-2142, :2157; `refreshMainOutRow()`
  :2248 (called at :1560 inside `rebuild`, :2673, :4267, :4277, :4998); `refreshDeviceRows()`
  :3003-3015; `mainOutConnectionState` :2514; `mainOutIsLocalOnlyArmed` used :2279/:2431;
  `isLiveMainAudioRemoval` :2425-2432; `applySelectionState` :2688; `liveRoutedAppNames`,
  `offlineBundleIDs`, `isAppExcluded`, `deviceRowsByID`, `devicesByID`, `appRouting` are existing
  members; `noRedirectDestinationID` :752; `test_deviceRow(for:)` :3852, `test_appRow(for:)`
  :3884, `test_mainOutRow` :4009, `test_toggleDeviceEnabled` :4187, `test_toggleMute` :4197.
  PR 3 Step 15 edits :2581, :2704, :2758, :3436-3458, :3656-3681 — line numbers below those
  shift by a few lines after PR 3.
- `MainOutRowView.swift`: `apply(options:current:master:isMuted:connectionState:restingArmed:busOriginDimmed:)`
  :199-202; `armed` :215, `isSpineLive` :216, `faderCell.isRouteArmed = armed` :227;
  `isGroupTarget` :248-249; display-only cell item :292-299 (`usesItemFromMenu` false only when
  `buttonTitle` is set); `readoutLabel.font = Tokens.Font.caption`, `.textColor = secondaryLabel`
  :400-401; pop-up config :411-412 (`controlSize .small`, `font caption`, no `isBordered` write
  → bordered by default); subviews added :438-442 (`busOriginView` first); `iconView` box 26
  (`PopoverColumnGrid.iconWidth` :200); `test_masterReadout` :648; `test_buttonTitle` :663-667
  reads `cell.menuItem?.title` when `usesItemFromMenu` is false. `MainOutTarget` is
  `.selectedDevices | .group(id:)` (RoutingStore.swift:15-18). The host passes
  `buttonTitle: "→ \(group.name)"` for groups (PopoverController.swift:2271-2272).
- `SurfaceSplashView.swift`: `markSide = 96` :45; wordmark label :124-127 (font at :125) (`Tokens.Font.bodyEmphasized`,
  `Tokens.Color.label`); nothing in Tests asserts its font (`git grep bodyEmphasized -- Tests` empty).
- `WarmCanvasView.swift`: gradient block :85-101 reads `Tokens.Color.canvasHi` :85; flatten branch
  :77-83; grain :103-111; doc :19-33 describes the gradient. `canvasHi` has no other consumer.
- `Tokens.swift`: `info` alias :1087-1088; `canvasHi` alias :1059-1060; `warning` alias
  :1083-1084 (stays, D3); `bannerCornerRadius` :1271-1274; `Radius` :1288-1295; `party`
  :1011-1014; `partyRampDeep` :1023-1026; `wordmark(size:)` :1221-1225; `GroupRowView` named in
  doc comments :166 and :1126. PR 3 Step 16 edits :1036-1101 (alias block) — lines shift.
- `PopoverColumnGrid.swift` (PR 3's file): `GroupRowView` named :8, :580, :813, :854;
  `readoutTrailing` :858-860 (sole consumer `GroupRowView.swift:218`); `sliderTrailing` :849
  has four other consumers.
- `GroupRowView.swift` is at `AudioutCore/Sources/AudioutPopoverUI/GroupRowView.swift` (421
  lines); consumers: `GroupRowViewTests.swift` (whole file) and `PopoverIconTests.swift`
  :13, :20, :82, :108-112 (`expectedGroupIcon`), :171-207 (three tests). No `Sources` consumer.
- `NoteBannerColorTests.swift`: seven tests; asserts `warning` 0.14/0.40 and `info` 0.12/0.35
  (:33-34, :41-42, :47-48, :75-76); `infoAndWarningTiersRenderDifferentBackgrounds` :55-69.
- `AccessibilitySignalSweepTests.flattenedCanvasIsTheFlatOpaqueBaseColor` :233-265 asserts the
  flatten branch's pixel equals `Tokens.Color.canvas` under `.darkAqua`; it does not exercise the
  gradient branch. `WarmCanvasView.test_flattenOverride` :64-66 stays.
- `BrandMarkTests.wordmarkFallsBackToSystemBoldWithoutTheAppBundle` :24-28 pins the fallback.
- `PopoverPanelHeaderTests` :17-21 `makePanel()`; `cardNoteIsReadableStateTextNotDimmedChrome`
  :122-133 asserts `textColor == Tokens.Color.secondaryLabel` on a NOTE (not a title) — unaffected.
- `AppSurfaceControllerTests` :189-192 and :933-936 pin `SurfaceLayout.width` and fit; nothing
  here changes width.
- `popover-snapshot` (`AudioutCore/Sources/popover-snapshot/main.swift`): mode switch :1061-1090;
  `dormant-group` mode sets `controller.setMainOut(.group(id:))` :738 — the magenta chevron and
  glow render there. 22 PNGs in `dev/notes/popover-snapshots/`. The splash is never rendered
  headless (SurfaceSplashView.swift:69-70, `HeadlessRuntime.isActive`).
- The baseline filtered run (Pre-flight command minus `PopoverControllerTests`) at `586bd8a2`
  passed: 134 tests in 11 suites, on the remote Mac.

## Step-by-step

### Step 1 — `AudioutCore/Sources/AudioutPopoverUI/SilenceFallbackBannerView.swift`
1.1 :29 `Tokens.Color.warning` → `Tokens.Color.failure`.
1.2 :64 `Tokens.Layout.bannerCornerRadius` → `Tokens.Layout.Radius.control`. Delete :65
    (`layer?.borderWidth = 1`).
1.3 `stampLayerColors()`: fill = `Tokens.Color.failure.withAlphaComponent(0.12).cgColor`; delete
    the `borderColor` line.
1.4 Delete `test_borderColor` (:149-152). Keep `test_backgroundColor`; its doc: "resolves from
    `Tokens.Color.failure`".
1.5 Doc comment :6-11: the banner is `failure` at 12 % on the control radius, no border, the
    iOS Status Banner recipe; drop "system-orange", "1 px border", "System colors only".

### Step 2 — `AudioutCore/Sources/AudioutPopoverUI/SystemAirPlayNoteBannerView.swift`
2.1 `Severity.tintColor`: `.info` → `Tokens.Color.ring`, `.warning` → `Tokens.Color.failure`.
2.2 Delete `backgroundAlpha` and `borderAlpha` (:45-56); the fill alpha is the literal `0.12`
    in `stampLayerColors()` for both tiers. Delete the `borderColor` stamp.
2.3 :117 radius → `Tokens.Layout.Radius.control`; delete :118 (`borderWidth = 1`).
2.4 Delete `test_borderColor`. Keep `test_backgroundColor`; doc → "`Tokens.Color.ring` /
    `.failure` per tier".
2.5 Rewrite the type doc (:6-16) and the `Severity` doc (:33-35): `.info` = `ring` (a note),
    `.warning` = `failure` (a real problem); both 12 %, control radius, no border. Drop every
    "system-blue/orange" mention.

### Step 3 — `AudioutCore/Sources/AudioutPopoverUI/ConnectionDiagnosisView.swift`
3.1 :40 `backgroundCornerRadius` → `Tokens.Layout.Radius.control`; its doc (if any) says it is the
    control radius the two banners share.

### Step 4 — `AudioutCore/Sources/AudioutPopoverUI/PopoverPanelViewController.swift` — divider
4.1 Rename `HairlineView` (:1650) → `CardDividerView`; both `Tokens.Color.hairline` stamps
    (:1654, :1663) → `Tokens.Color.containerEdge`; rewrite its doc (:1645-1648): the 1 px
    divider between de-nested cards crosses bare canvas, so it is `containerEdge` (Rule 5:
    `hairline` never divides on the canvas), measured 1.95:1 dark / 2.02:1 light. Update the
    local `let hairline = HairlineView()` :764 and the comment :759-762 ("1px hairline divider"
    → "1 px `containerEdge` divider") and :18, :259, :267, :509 wherever the word "hairline"
    names this divider (leave `hairline` mentions that mean the token elsewhere).

### Step 5 — `PopoverPanelViewController.swift` — live card title
5.1 Add `func setCardHeaderLive(title: String, live: Bool)`: look up
    `headerTitleLabelsByHeader[title]`; if nil, return. Rebuild its `attributedStringValue` from
    the label's current string with attributes `[.font: Tokens.Font.captionEmphasized,
    .foregroundColor: live ? Tokens.Color.goldText : Tokens.Color.label2]`. (Only card titles
    are ever passed by Step 6; subsection titles share the dictionary but are plain
    `labelWithString` labels and are never named by a caller.) Doc: the iOS Section Header
    rule — title `goldText` while the section is sounding, `label2` otherwise; the host decides
    "sounding" (D1).
5.2 :589 `color: Tokens.Color.secondaryLabel` → `Tokens.Color.label2` (the idle rung, same hex).
5.3 Add hook `func test_headerTitleColor(title: String) -> NSColor?` returning the
    `.foregroundColor` attribute at index 0 of the title label's `attributedStringValue`
    (nil when no such header). Place it beside `test_headerTitleAXRole`.

### Step 6 — `AudioutCore/Sources/AudioutPopoverUI/PopoverController.swift`
6.1 Add `private func refreshCardHeaderLiveness()` computing the three D1 predicates (name the
    locals after the cards) and calling `panel.setCardHeaderLive(title:live:)` for
    `Self.mainAudioCardTitle`, `Self.outputDevicesCardTitle`, `Self.applicationsCardTitle`.
    With `groupController == nil` the main-mix terms are false (the no-controller branch of
    `applySelectionState` passes no `masterMuted`/`inActiveTarget`, so only live feeds arm).
6.2 Call it (a) as the LAST statement of `rebuild()`'s card build — after the App Routing card
    and its footer are added, before the diagnosis-panel restore; (b) at the end of
    `refreshDeviceRows()` after `updateRailRows()`; (c) at the end of `refreshMainOutRow()`,
    AFTER its `guard let controller` (:2249) — without a controller it returns early and (a)
    carries the initial paint. Inside `rebuild()` the call at (c) runs before the other two cards
    exist — `setCardHeaderLive` no-ops on a missing title, so it is harmless; do not guard it.

### Step 7 — new `AudioutCore/Sources/AudioutSharedUI/GroupIdentityGlowView.swift`
7.1 `public final class GroupIdentityGlowView: NSView` per D7: `wantsLayer`, `layer` is a
    `CAGradientLayer` (override `makeBackingLayer()`), `type = .radial`, `startPoint (0.5,0.5)`,
    `endPoint (1,1)`, `locations [0,1]`; `stamp()` resolves the appearance
    (`effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua`) and sets `colors =
    [Tokens.Color.partyRampDeep.withAlphaComponent(isDark ? 0.22 : 0.10).cgColor,
    NSColor.clear.cgColor]` inside `performAsCurrentDrawingAppearance`; called from `init` and
    `viewDidChangeEffectiveAppearance`. `intrinsicContentSize` = 60×60 (`public static let side: CGFloat = 60`). Because the gradient
    layer IS the backing layer (`makeBackingLayer`), `endPoint (1,1)` is in unit coordinates and
    the falloff scales with whatever size the host constrains — PR 5 mounts it at 60 behind the
    28 pt card seat and at 80 behind the 64 pt editor well without a second recipe. `hitTest` → nil. `setAccessibilityElement(false)`. Doc: the iOS
    `GroupIdentityGlow` recipe (audiout-remote GroupsView.swift:205-228) — identity is light the
    group gives off, never chrome; sits BEHIND a seat; shared by the Main Out row (PR 4) and the
    Groups seats (PR 5). Hook: `public var test_coreAlpha: CGFloat?` — alpha of `colors.first`.
7.2 `AudioutSharedUI/AGENTS.md` (take the post-PR-3 file as input; the checker counts it near
    300 already): add to `## Map` "- `GroupIdentityGlowView` → magenta identity light behind a
    group seat." (9 words) and pay for it by rewriting, in this order until `wc -w` ≤ 300:
    the AGENTS-HISTORY bullet → "- Traps, decisions, changelog: [AGENTS-HISTORY.md](AGENTS-HISTORY.md);
    grep it before debugging."; the `setContent` bullet → "- `setContent`'s `defaultSize:` seeds
    only a content controller's first mount."; the `CATransition` bullet → "- TRAP: `CATransition`
    ignores custom animation keys, filing under \"transition\"."; the Purpose paragraph's second
    sentence → "Pure UI: controls route through a delegate, never a backend, store, or
    `GroupController`." Stop at the first rewrite that brings the count to ≤ 300; leave the rest.

### Step 8 — `AudioutCore/Sources/AudioutPopoverUI/MainOutRowView.swift`
8.1 Add `private let groupGlowView = GroupIdentityGlowView()`; `translatesAutoresizingMaskIntoConstraints
    = false`; `addSubview` it FIRST (before `busOriginView`, :438); constraints: width/height =
    `GroupIdentityGlowView.side`, centerX/centerY = `iconView`'s. Start `isHidden = true`.
8.2 In `apply`, right after `isGroupTarget` (:249): `groupGlowView.isHidden = !isGroupTarget`;
    `destinationPopUp.contentTintColor = isGroupTarget ? Tokens.Color.partyRampDeep : Tokens.Color.label2`.
8.3 Pop-up (:411-412): add `destinationPopUp.isBordered = false`. Replace the cell block
    :292-299 so BOTH branches set `cell.usesItemFromMenu = false` and
    `cell.menuItem = NSMenuItem(title: shownTitle, …)` with `attributedTitle =
    NSAttributedString(string: shownTitle, attributes: [.font: Tokens.Font.caption,
    .foregroundColor: Tokens.Color.label])` where `shownTitle = currentButtonTitle ?? selectedTitle
    ?? ""`. Rewrite the comment :293-297 (the display item now exists so the title can stay
    `label` while the arrow carries `partyRampDeep`/`label2` through `contentTintColor` — D6 probe).
    `test_buttonTitle` keeps working through `cell.menuItem?.title` (plain `title` is still set).
8.4 Readout (:400-401): `font = Tokens.Font.readout`; `textColor = Tokens.Color.emberText`. In
    `apply`, after `faderCell.isRouteArmed = armed` (:227): `readoutLabel.textColor = armed ?
    Tokens.Color.goldText : Tokens.Color.emberText`.
8.5 Hooks, beside `test_masterReadout`: `public var test_masterReadoutColor: NSColor?`
    (`readoutLabel.textColor`), `public var test_masterReadoutFont: NSFont?`,
    `public var test_destinationChevronTint: NSColor?` (`destinationPopUp.contentTintColor`),
    `public var test_groupGlowVisible: Bool` (`!groupGlowView.isHidden`).
8.6 Doc comment on the type (:7-27): add one sentence — while the target is a saved group the
    picker's arrow is `partyRampDeep` and `GroupIdentityGlowView` lights behind the icon (R2, iOS "party
    edge"); the row still paints no fill of its own.

### Step 9 — `AudioutCore/Sources/AudioutSharedUI/Tokens.swift`
9.1 Delete the `info` alias (2 lines) and the `canvasHi` alias (2 lines) from the deprecated
    block. Leave `warning`.
9.2 Delete `Layout.bannerCornerRadius` and its doc (:1271-1274).
9.3 Doc comments: :166-168 `selectedContentBackground` — drop "`GroupRowView`, " from the
    list; :1125-1126 `bodyBold` — "used for an active/selected row name (`GroupRowView`)" →
    "bold body text, currently without a consumer". `ring`'s doc, if it lists consumers, names
    `SystemAirPlayNoteBannerView`'s note tier; `failure`'s doc names both banners' problem
    tier. Grep the file for `bannerCornerRadius`, `canvasHi`, `GroupRowView`, `Color.info` — all
    gone.

### Step 10 — `AudioutCore/Sources/AudioutSharedUI/WarmCanvasView.swift`
10.1 Delete :85-101 (the `CGGradient` block and its `else`); in its place
     `Tokens.Color.canvas.setFill(); bounds.fill()`. Keep :77-83 (flatten) and :103-111 (grain)
     unchanged. `ctx` is still needed by the grain — keep the `guard let ctx`.
10.2 Doc :19-33: the canvas is the flat `canvas` colour in both appearances, dark adds the
     deterministic grain; flatten (Reduce Transparency / Increase Contrast) drops the grain.
     Remove "gradient ladder", "`canvasHi`". Comment :51 "gradient+grain ↔ flat" → "grain ↔ flat".

### Step 11 — `AudioutCore/Sources/AudioutPopoverUI/SurfaceSplashView.swift`
11.1 :125 `wordmark.font = Tokens.Font.wordmark(size: 31)`. Add
     `static let wordmarkSize: CGFloat = 31` beside `markSide` with doc: iOS sets 32 pt beside a
     100 pt mark; 96 × 0.32 = 30.72 → 31. Use the constant at :125.
11.2 Doc :29-30 "Composed of stock pieces" → add "the name in the wordmark face
     (`Tokens.Font.wordmark`), system bold outside an assembled `.app`".

### Step 12 — delete `GroupRowView`
12.1 `git rm AudioutCore/Sources/AudioutPopoverUI/GroupRowView.swift AudioutCore/Tests/AudioutCoreTests/GroupRowViewTests.swift`.
12.2 `PopoverIconTests.swift`: delete `expectedGroupIcon` (:106-112) and the three tests under
     `// MARK: Group row` (:169-207); doc comment :10-21 → drop the `GroupRowView` sentence and
     "neither `DeviceRowView` nor `GroupRowView`" → "`DeviceRowView` does not"; `findImageView`
     doc :81-83 → "a device row mounts exactly one".
12.3 `PopoverPanelViewController.swift` :528 and :996 mention "per `GroupRowView`'s precedent" —
     rewrite to "(`chevron.down` expanded / `chevron.right` collapsed)".
12.4 Comment-only rewrites dropping the dead name (each is a doc comment in a file PR 3 has
     already merged, so no conflict): `AudioutSharedUI/DeviceRowView.swift:309` ("the mixer window
     and `GroupRowView` leave it out" → "the mixer window leaves it out"), `:1336` ("the mixer
     window/`GroupRowView` never call this" → "the mixer window never calls this"), `:1516`
     ("mixer window/GroupRowView never pass `true`" → "the mixer window never passes `true`");
     `Tests/DeviceRowConnectionStateTests.swift:659` ("(the mixer window/`GroupRowView` default)"
     → "(the mixer window default)"); `Tests/PopoverControllerTests.swift:1071` ("— GroupRowView
     precedent)" → ")"). Line numbers are HEAD's; PR 3 shifts DeviceRowView's — grep the string.
12.5 `git grep -n GroupRowView -- AudioutCore/Sources AudioutCore/Tests` must return ONLY
     `PopoverColumnGrid.swift` (PR 3's file, Requests below) and `AGENTS-HISTORY.md` hits.

### Step 13 — tests (Test plan), one file at a time.

### Step 14 — `bash scripts/build.sh`, then Verification.

### Step 15 — regenerate the popover snapshots (documentation images; nothing compares them)
```bash
for m in "" connection-states live-routing dormant-group local-mix-blocked resting-ring rail-depth feed-composite energize-mid-sequence energize-reduce-motion-static; do AIRPLAY_SNAPSHOT_MODE="$m" swift run --package-path AudioutCore popover-snapshot; done
git status --short dev/notes/popover-snapshots      # expect the 22 PNGs modified, no new files
git status --short dev/notes/window-snapshots dev/notes/onboarding-snapshots dev/notes/settings-snapshots   # expect NO output
```
Open `dev/notes/popover-snapshots/popover-dormant-group-dark.png` and `-light.png` with the
Read tool: magenta arrow on the Main Out picker, a soft magenta halo behind its icon, no bezel
on the picker, gold "System Audio"/"Output Devices" titles if a member is connected in that
scenario. Open `popover-connection-dark.png`: the diagnosis card and any banner share one
corner radius. Report what you saw in one line each.

## Ratio table (new to this PR)

Grounds: dark `panel` `#15171A`, `canvas` `#0A0A0C`; light ground `#FAFAFB`.

| pair | dark | light |
|---|---|---|
| `failure` 12 % fill on panel / ground | `#2D1F20` 1.136 | `#F1E2E2` 1.204 |
| `failure` glyph on its own fill | 4.05 | 4.99 |
| `ring` 12 % fill on panel / ground | `#222A2E` 1.230 | `#E1E9ED` 1.179 |
| `ring` glyph on its own fill | 6.41 | 4.64 |
| banner text on the failure fill / ring fill (measured with iOS's authored ink `#F5EFE4` / `#201D1A`; the Mac's `label` is `.labelColor`, near-white/near-black, and measures higher) | 13.81 / 12.75 | 13.35 / 13.64 |
| `partyRampDeep` chevron on panel / ground | `#FF90E9` 8.91 | `#752C68` 8.69 |
| glow core (`partyRampDeep` 22 % / 10 %) on panel, canvas / ground | 1.561, 1.484 | 1.183 |
| `label2` glyph on the dark glow core `#483248` | 5.12 | — |
| `goldText` title on panel / ground | 9.74 | 5.66 |
| `containerEdge` divider on canvas | 1.95 | 2.02 |

## Interim visible effects this PR finalises (from PR 1's table) and introduces

| alias / item | finalised as |
|---|---|
| `warning→failure` (banners) | Silence banner and the note banner's warning tier: `failure` 12 %, no border, radius 10. (GeneralSettings' two notes stay on the alias — Settings PR.) |
| `info→ring` | Note tier: `ring` 12 %, no border, radius 10. Alias deleted. |
| `canvasHi→canvas` | Gradient code gone; flat `canvas` + dark grain. Alias deleted. |
| NEW | Card divider `containerEdge`; card titles `goldText` while sounding; Main Out readout in `Font.readout` gold/ember; borderless picker with `label2`/`partyRampDeep` arrow; magenta glow behind the Main Out icon on a group target; splash wordmark 31 pt (system bold until a dev build). |

## Test plan (only these files)

- **`NoteBannerColorTests.swift`** — rewrite the doc (:8-16): the banners are `failure`/`ring`
  at 12 %, no border. `silenceBannerUsesWarningTokenAtTheDocumentedAlphas` → rename
  `silenceBannerIsFailureAtTwelvePercent`: `test_backgroundColor` == `failure` at 0.12; no
  border assertion. `infoTierUsesTheNewInfoTokenAtTheDocumentedAlphas` → `noteTierIsRingAtTwelvePercent`
  (`ring` at 0.12). `warningTierUsesTheWarningTokenAtTheDocumentedAlphas` →
  `warningTierIsFailureAtTwelvePercent`. `infoAndWarningTiersRenderDifferentBackgrounds`: keep,
  doc now says `ring` vs `failure`. `updateLayerReStampsFromTheSameToken`: `failure` at 0.12,
  background only. Add `bannersWearTheControlRadiusWithNoBorder`: both banners'
  `layer?.cornerRadius == Tokens.Layout.Radius.control` and `layer?.borderWidth == 0`. Keep the
  last two tests.
- **`ConnectionDiagnosisViewTests.swift`** — add `cardWearsTheControlRadius`: build a view,
  `apply` any failure, assert the background layer's `cornerRadius == Tokens.Layout.Radius.control`
  (add a `test_backgroundCornerRadius: CGFloat?` hook on the view if no subview walk reaches it).
- **`PopoverPanelHeaderTests.swift`** — add `cardTitleTintFollowsLiveness`: `beginCard(header:
  "Devices")`, `test_headerTitleColor` equals `Tokens.Color.label2`; `setCardHeaderLive(title:
  "Devices", live: true)` → `goldText`; `live: false` → `label2`; `setCardHeaderLive(title:
  "nope", live: true)` does not throw and changes nothing. Compare colours by sRGB components
  (the `NoteBannerColorTests.assertSameRGBA` idiom).
- **`PopoverControllerTests.swift`** — add `cardTitlesTintGoldWhileTheirRowsSound` (async, the
  `makePopover` harness :28): fresh popover → all three `test_panelView`-hosted titles `label2`
  (reach them through a new `PopoverController.test_cardHeaderTitleColor(title:)` forwarding to
  the panel hook, beside `test_cardNotes`). `test_toggleDeviceEnabled(deviceID: "office", on:
  true)`, `waitForConnectionState(backend, id: "office") { $0 == .connected }`,
  `popover.update(devices: backend.devices)` → System Audio and Output Devices titles
  `goldText`, App Routing `label2`; pin `popover.test_deviceRow(for: "office")?.test_routeArmed
  == true` and `popover.test_mainOutRow.test_routeArmed == true`. Then
  `popover.mainOutRow(popover.test_mainOutRow, didSetMuted: true)` → both titles `label2`,
  `test_routeArmed` false on both. Add `appRoutingTitleTintsGoldForARunningRedirect`: an
  externally added route does NOT trigger a rebuild (PopoverController.swift:917-925, :997), so
  seed the route BEFORE `makePopover`, the existing pattern: `let appRouting =
  tempAppRoutingController()`; `seedRoute(appRouting, bundleID: "com.example.music", displayName:
  "Music", destination: .device(id: "office"))` (PopoverControllerTests.swift:1525-1533;
  `AppRouteDestination.device(id:)`, AppRouteStore.swift:22-26); then `makePopover(appRouting:
  appRouting, runningAppsProvider: { [RunningAppInfo(bundleID: "com.example.music", displayName:
  "Music", icon: nil)] })` → App Routing title `goldText` and
  `popover.test_appRow(for: "com.example.music")?.test_isFaderEngaged == true`; then
  `popover.applyRoutedAppRunning(bundleID: "com.example.music", isRunning: false)` → `label2`.
- **`MainOutRowRingTests.swift`** — add `readoutIsGoldWhileArmedElseEmber`: `apply(options:
  [.init(title: "Selected Devices")], current: .selectedDevices, master: 50, connectionState:
  .connected)` → `test_masterReadoutColor` == `goldText`, `test_masterReadoutFont ==
  Tokens.Font.readout`; `isMuted: true` → `emberText`. Add `groupTargetLightsTheChevronAndGlow`:
  `current: .group(id: "g1")` with a matching option → `test_destinationChevronTint == partyRampDeep`,
  `test_groupGlowVisible`; `current: .selectedDevices` → `label2`, glow hidden. Add
  `pickerTitleStaysLabelInkOnAGroupTarget`: `test_buttonTitle == "→ Kitchen"` when the option
  carries `buttonTitle: "→ Kitchen"` (proves `usesItemFromMenu = false` still surfaces the
  display title).
- **`MainOutRowMenuDispatchTests.swift`** — keep; run.
- **`PopoverIconTests.swift`** — Step 12.2 deletions; 5 tests remain.
- **`GroupRowViewTests.swift`** — deleted (Step 12.1).
- **`AccessibilitySignalSweepTests.swift`** — no edit; `flattenedCanvasIsTheFlatOpaqueBaseColor`
  must stay green (the flatten branch is untouched). Add nothing.
- **`BrandMarkTests.swift`** — keep; run.
- **`AppSurfaceControllerTests.swift`** — no edit; run (width/fit pins).
- New file **`GroupIdentityGlowViewTests.swift`** — `coreAlphaIsTwentyTwoDarkTenLight`: set
  `view.appearance` to `.darkAqua` → `test_coreAlpha == 0.22` (±0.004); `.aqua` → `0.10`;
  `glowIsNeitherHittableNorSpoken`: `hitTest` nil at its centre, `isAccessibilityElement()` false;
  `gradientFollowsTheMountedSize`: constrain the view to 80×80 in a host, `layoutSubtreeIfNeeded`,
  assert `view.layer?.bounds.size == CGSize(width: 80, height: 80)` and `view.layer is CAGradientLayer`.

## Verification (in this order; paste each command's output)

```bash
bash scripts/build.sh                                    # exit 0
git grep -n "Color\.info\b\|Color\.canvasHi\|bannerCornerRadius\|GroupRowView" -- AudioutCore/Sources AudioutCore/Tests   # expect ONLY PopoverColumnGrid.swift (PR 3's, Requests) + AGENTS-HISTORY.md hits
wc -w AudioutCore/Sources/AudioutSharedUI/AGENTS.md                                           # ≤ 300
git grep -n "systemOrange\|systemBlue" -- AudioutCore/Sources/AudioutPopoverUI                  # expect no output
git grep -n "hairline" -- AudioutCore/Sources/AudioutPopoverUI/PopoverPanelViewController.swift  # expect no output
AUDIOUT_TEST_NO_CACHE=1 bash scripts/run-tests.sh --filter 'NoteBannerColorTests|ConnectionDiagnosisViewTests|MainOutRowRingTests|MainOutRowMenuDispatchTests|AppSurfaceControllerTests|PopoverPanelHeaderTests|PopoverIconTests|AccessibilitySignalSweepTests|BrandMarkTests|MembershipWellContrastTests|PopoverControllerTests|GroupIdentityGlowViewTests'
```
Expected: every suite passes; `GroupRowViewTests` no longer exists; `PopoverIconTests` reports
5 tests; the new tests named above appear as passed. Then Step 15's snapshot commands and
their `git status` checks. Then `git status --short` must list exactly: the modified
Sources/Tests files named in Steps 1-12, the two deletions, the new
`GroupIdentityGlowView.swift` + its test file, `AudioutSharedUI/AGENTS.md`, and the 22 PNGs.
Guard 4 runs the full suite on commit; Guard 7 needs `bash scripts/self-review.sh` on the
staged bytes — run it, do not surface its chatter.

## Owed checks (Alec, dev build; do not block the PR)

- Wordmark: "Audiout" on the splash renders in Clash Display at 31 pt under `make-app.sh`
  (`APP_NAME="Audiout Dev" BUNDLE_ID="com.audiout.Audiout.dev"`); size against the 96 pt mark.
- The borderless picker: does the Main Out row still read as a control without the bezel?
  (D6 is the only AppKit way to a tinted arrow; the tint is `partyRampDeep`, magenta in dark and deep plum in light; if Alec wants the bezel back, R2's chevron needs
  a drawn arrow instead.)
- The magenta glow behind the bare Main Out glyph (no opaque seat on the Mac, D7): too much
  core behind the icon, or right?
- Gold card titles when only a live app feed arms a row (D1's `hasLiveFeeds` branch).
- Banners at 12 % with no border on the light ground (1.20 / 1.18:1 — edge-less by design).

## Requests to PR 3 (owner of `PopoverColumnGrid.swift`)

- After PR 4 merges (NOT before — `GroupRowView.swift:218` still compiles against it until
  then): delete `readoutTrailing` (:853-860) and drop the `GroupRowView` clauses from the doc
  comments at :8, :580, :812-814 — AND the two mentions PR 3 itself writes (PR 3 Step 13.2's
  "GroupRowView's selection pill" on `rowSelectionWashAlpha`, Step 13.3's "shared by … GroupRowView"
  on `selectionHighlightCornerRadius`). `sliderTrailing` stays (four consumers). If PR 3's owner would
  rather PR 4 do it, PR 4 may edit only those lines.

## Hand-off to PRs 5-8 and the documenter (PR 9)

- `GroupIdentityGlowView` (SharedUI) is the one recipe; mounted at `side` (60) here; PR 5 mounts it
  behind every group seat (`DeviceIconWellView` / `GroupsOverviewViewController` seats) at 60 on
  the card seat and 80 on the editor well, centred, first subview — the backing gradient layer
  scales with the mounted size; no second gradient.
- `PopoverPanelViewController.setCardHeaderLive(title:live:)` exists; `label2` idle, `goldText`
  live; the host owns "live".
- Aliases still present after PR 4: `warning` (Settings PR: GeneralSettingsViewController
  :231/:551), `partySignal`/`partySignalDeep` (wizard PR), `iconSeatFill` (Groups PR),
  `accent`, `success`, `warningText`, `goldCTA`, `inkOnGold` (onboarding PR), `plateRim`,
  `syncSignal` (wizard PR), `sidebarWarmTint` (Groups PR, C6), `secondaryLabel`,
  `tertiaryLabel`, `inkSecondary`, `inkTertiary` (whoever sweeps last).
- Documenter: `docs/FIGMA-DESIGN-SYSTEM.md:50/:138/:330` and `docs/SPEC.md:393` still name
  `canvasHi` / `GroupRowView`; `AudioutPopoverUI/AGENTS-HISTORY.md:85` (archived) too.
- `Tokens.Layout.bannerCornerRadius` no longer exists; banners and the diagnosis card use
  `Radius.control`.

## Execution plan

One track, model **opus**, effort **medium**: every step is a named line edit with a verified
recipe; the only reasoning is D1's three predicates and the two new controller tests, both
spelled out. No parallel tracks — Steps 4-6 and 8 share `PopoverPanelViewController` /
`PopoverController` / `MainOutRowView` with their tests, and Step 12's deletion must precede the
grep guard. The branch is cut from `origin/main` after PR 3 merges; no uncommitted work is
depended on. Verification runs once at the end.

## Executor rules (copy verbatim into the handoff prompt)

> - Follow the steps in order. Do not add, merge, reorder, or skip steps.
> - Before editing in any folder, read the nearest AGENTS.md above it (and the root one) if the repo has them — folder rules and traps bind even when the work order doesn't repeat them.
> - If reality contradicts a Verified fact or a step is impossible as written, STOP and report the discrepancy. Do not improvise a workaround.
> - Before reporting progress, audit each claim against a tool result from this session. Only report work you can point to evidence for. If tests fail, say so with the output.
> - "Done" means the Verification commands were run in this session and passed. Paste their output.
> - Touch nothing in the Out-of-scope list.
> - Deliver what was asked, at the scope intended. If the spec seems mistaken or a better approach exists, say so in a sentence and continue as specified rather than quietly narrowing, widening, or transforming it.
