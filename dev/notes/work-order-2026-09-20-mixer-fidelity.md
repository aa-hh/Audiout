# Work order v2: ground the Remotion Mixer panel in the app's real metrics

## Goal

Make the rebuilt Mixer panel in `marketing/video` reproduce the shipping app's panel measurably, by replacing guessed point metrics and invented instrument drawing with values read out of `PopoverColumnGrid.swift` / `Tokens.swift` and measured off a fresh `popover-snapshot` render. The panel goes to its real **653 pt** width and the camera is re-fitted so the whole panel stays in frame with no panning (**settled by the user**). The video's story, captions, beat timings and cursor choreography survive unchanged. Fidelity is proven by a structural-similarity number, not by eye.

---

## Verified facts

### The offscreen render works today

- `AudioutCore/Sources/popover-snapshot/main.swift` assembles the **real** `PopoverController` panel against `MockBackend`, headless, no TCC, no signed app: `setenv("AIRPLAY_HEADLESS", "1", 1)` and `.accessory` policy at `:1045-1047`; `MockBackend(fleet: .demoFleet, staggerDiscovery: false, emitsLevels: false, …)` at `:146-147`; temp-directory stores at `:149-155`.
- Output directory is `argv[1]`, defaulting to `dev/notes/popover-snapshots` (`:1049-1062`). **The argument is mandatory** — a bare run overwrites committed references.
- A default run writes **four** PNGs: `popover-{light,dark}.png` and `popover-meters-{light,dark}.png` (`:1125-1129`). Only `popover-dark.png` is used here.
- Backing scale pinned at 2 (`:84-90`).
- Ran this session: build 33.57 s, exit 0, `popover-dark.png` at **653 x 758 pt (1306 x 1516 px)**, current copy ("Output Speakers", "AirPlay Speakers", "Source", "Offset", "Selected Speakers", "App Routing").
- `dev/notes/popover-snapshots/popover-dark.png` (2026-09-04, commit `36571405`) and `docs/media/popover-dark.png` are both stale in copy. Neither is the reference.

### Determinism holds for this tool

The "goldens unreproducible" trap is **`window-snapshot` only** — its memory note states "`popover`, `settings` and `onboarding` snapshots reproduce byte-for-byte and are unaffected". Cause is `displayIgnoringOpacity` (`window-snapshot/main.swift:79`); `popover-snapshot` uses `cacheDisplay(in:to:)` (`popover-snapshot/main.swift:121`).

### Why captures cannot drive the video

1. **No state argument exists.** Every scenario is a hardcoded function selected by `AIRPLAY_SNAPSHOT_MODE` (`main.swift:1069-1123`); the fixture's selection, volumes and routes are literals (`:161-184`). Driving the video's states means editing `AudioutCore/Sources/popover-snapshot/main.swift` — forbidden.
2. **The panel animates on roughly 130 of 900 frames.** `armed()` ramps 14 frames on / 10 off / 16 on recall (`ScenesVideo.tsx:90-94`); the HomePod slider drags over 54 frames (`:96-101`); the hint fades over 14 (`:153`). A still carries none of it.
3. **CI is Node-only** — `runs-on: macos-latest` at `.github/workflows/marketing-video.yml:28`, then `setup-node` + `npm ci` (`:36-45`).

The capture is therefore the **reference and the measuring stick**, not a video asset.

### Measurement tooling — verified here

ImageMagick is **absent** (`magick`, `convert`, `compare`). ffmpeg is present at `/opt/homebrew/bin/ffmpeg`; its `ssim` filter prints nothing below `-loglevel info`. Calibration measured against the fresh render:

| Comparison | SSIM | SSIM after `boxblur=4:1` |
|---|---|---|
| Identical file | 1.000000 | — |
| Same panel, 16 days of UI change apart | 0.979490 | 0.983690 |
| Shifted 4 px (2 pt) | 0.906429 | 0.956134 |
| Shifted 8 px (4 pt) | 0.904485 | 0.925105 |
| Shifted 20 px (10 pt) | 0.880251 | 0.902406 |

Blurring erases text antialiasing and leaves layout: **blurred SSIM >= 0.95 means every column and row is within about 2 pt.**

`npx tsc --noEmit` in `marketing/video` exits 0 today. `npx remotion still Scenes <out> --frame=700 --log=error` ran in 4.65 s, 1080 x 1920.

### Horizontal geometry — `AudioutCore/Sources/AudioutSharedUI/PopoverColumnGrid.swift`

Panel width **653 pt** (`AudioutCore/Sources/AudioutSharedUI/SurfaceLayout.swift:13`), confirmed by the render's 1306 px at 2x.

| Constant | Value | Line |
|---|---|---|
| `leadingInset` / `indentedLeadingInset` / `trailingInset` | 14 / 30 / 14 | :37 / :40 / :42 |
| `busNodeClearance` | 12 | :61 |
| `railGutterCenterX` | 20 | :426 |
| `busNodeDiameter` / `Selected` / `Unselected` | 13 / **15** / **11** | :428 / :436 / :441 |
| `busLineWidth` / `busNodeRimWidth` | 2 / 1.5 | :443 / :445 |
| `busNodeRailGap` / `busDetourBulge` | **3** / **6.5** | :457 / :462 |
| `headerChevronWidth` / `headerChevronToTitle` | 16 / 4 | :77 / :79 |
| `iconWidth` / `iconGlyphPointSize` / `iconToName` | 26 / 18 / 9 | :202 / :287 / :802 |
| `nameToSlider` | 12 | :804 |
| `sliderWidth` | **150** | :205 |
| `sliderToReadout` / `readoutWidth` / `readoutToTrailingControl` | 6 / 40 / 6 | :809 / :207 / :813 |
| `muteWidth` / `eqButtonWidth` / `eqToMuteGap` / `muteToSlider` | 24 / 24 / 6 / 6 | :210 / :213 / :215 / :815 |
| `trailingControlWidth` | **140** | :226 |
| `bodyRowHeight` | **42** | :525 |
| `rowLiveWashAlpha` | **0.12** | :536 |
| `selectionHighlightInsetX` / `InsetY` / `CornerRadius` | 5 / 2 / `Radius.control` = **10** | :565 / :566 / :570, `Tokens.swift:1445` |
| `meterUnderNameWidth` / `Height` / `masterMeterThickness` | **74** / **3** / **6** | :124 / :126 / :140 |
| `haloRingDiameter` / `haloRingConnectedStroke` | **30** / 1.6 | :332 / :334 |
| `haloRingGapCenterAngle` / `GapWidth` | -pi/4 / 70 deg | :354 / :361 |
| `mainAudioRingDiameter` / `ConnectedStroke` | 34 / = `busLineWidth` = 2 | :164 / :172 |
| `railRingHookBulge` / `ControlDrop` / `LandingDrop` | 10 / 6 / 16 | :189 / :192 / :196 |
| `routeArmedDotDiameter` / `statusDotInset` / `statusDotBorderWidth` | **8** / 3 / 1.5 | :396 / :291 / :273 |
| `faderTrackHeight` / `faderThumbWidth` / `Height` | **5** / **10** / **17** | :597 / :603 / :605 |
| `feedPillHorizontalPadding` / `Vertical` / `Gap` | 4 / 2 / 3 | :248 / :251 / :255 |
| `syncChipWidth` / `Height` / `CornerRadius` / `BorderWidth` / `DashLength` / `DashGap` | 84 / 18 / 5 / 1 / 3 / 2 | :678 / :681 / :687 / :689 / :693 / :695 |

**Derived anchors** (pt from the panel's LEFT edge unless noted):

| Anchor | Value | Derivation |
|---|---|---|
| `busGutterWidth` | 20 + 6.5 + 12 - 14 = **24.5** | :66-68 |
| Icon column leading (`firstElementLeading(false)`) | **38.5** | :72-74 |
| `subsectionHeaderLeading` | 30 + 24.5 = **54.5** | :88-90 |
| `headerTitleLeading` | 38.5 + 16 + 4 = **58.5** | :96-98 |
| `nameColumnLeading` | 38.5 + 26 + 9 = **73.5** | :109-111 |
| Rail node centre x | **20** | :426 |
| `sliderTrailing` (from RIGHT) | 14 + 140 + 6 + 40 + 6 = **206** | :843-846 |
| Slider track | x **297 -> 447** | 653 - 206 - 150; **measured 594 / 894 px** |
| Readout column, right-aligned | x 453 -> **493** | 653 - (14+140+6+40) -> 653 - (14+140+6) |
| Trailing control column | x **499 -> 639** | `feedColumnLeadingFromTrailing` 14 + 140 = 154, :836-838; **measured pill left edge 499.0 pt** |

### Vertical rhythm — measured from the fresh render

Scanning pixel column x = 634 (inside the slider trough) for trough bands gives every row centre, in points:

| Row | Centre | Top |
|---|---|---|
| Main Audio | 71.75 | 50.75 |
| *hairline rule* | **108.0 -> 109.0** (1 pt, RGB **174,179,187**) | — |
| MacBook Pro Speakers | 171.75 | 150.75 |
| Bedroom HomePod | 235.75 | 214.75 |
| Living Room TV | 277.75 | 256.75 |
| Mixer | 319.75 | 298.75 |
| Move 2 | 361.75 | 340.75 |
| Office | 403.75 | 382.75 |
| Sonos Move | 445.75 | 424.75 (bottom **466.75**) |

Consequences, all arithmetic on that table plus one scan at x = 400:

- Row pitch is exactly **42 pt**.
- MacBook bottom 192.75 -> HomePod top 214.75 = **22 pt**, exactly the subsection header height (`PopoverPanelViewController.swift:1463`). Flush, no extra gap.
- Card header row height **28 pt** (`PopoverPanelViewController.swift:785`).
- Panel top inset before the first header = 50.75 - 28 = **22.75 pt**.
- **The rule is 1 pt tall and occupies pt 108.0-109.0.** Main Audio row bottom 92.75 -> rule top = **15.25 pt gap**; rule bottom 109.0 -> next card header top 122.75 = **13.75 pt gap**. (A zero-height rule assumption puts everything below it 1 pt low.)
- Live-row wash band measured **76 px = 38 pt**, i.e. 42 inset by 2 top and bottom — independently confirming `selectionHighlightInsetY = 2`.
- Panel bitmap pixel (0,0) = **#15171A**, the panel ground. The reference is **square-cornered, unbordered, unshadowed**.

### Instruments — measured, with the corrections

**Halo ring.** `connectedSpineArmed` is assigned in exactly one place, `AudioutCore/Sources/AudioutPopoverUI/MainOutRowView.swift:239`. `DeviceRowView` never sets it, so `HaloRingView.swift:254` falls through to `?? Tokens.Color.rim`. Measured at each row's ring left edge:
- Main Audio ring: **(232,184,75) = gold `#E8B84B`**, diameter 34, stroke 2.
- Bedroom HomePod / Office / Sonos Move: **(107,118,125) = `rim` `#6B767D`**, diameter 30 (left edge measured at pt 36.0-36.5 against an icon-box centre of 51.5 -> radius 15 OK), stroke 1.6.
- Living Room TV (idle): **no ring at all** — the `.off` case draws nothing (`HaloRingView.swift:243-246`).

So a device row's ring **appears and disappears** with connection, and its colour never changes. Nothing about it is gold.

**Rail.** `originColor` = `spineTone(armed:)` = gold when armed, ember when not (`BusRailOverlayView.swift:342`, `Tokens.swift:725`). Per-segment override: `railDormant` when dormant or the node failed, `ember` when connecting, else `originColor` (`BusRailOverlayView.swift:402-409`). Measured node spans at each row centre:
- Filled (selected) — HomePod, Office, Sonos Move: gold pt **12.5 -> 27.0** (approx 15 pt, `busNodeDiameterSelected`), centre 19.75, solid gold at the centre pixel.
- Hollow (unselected) — MacBook, Living Room TV, Mixer, Move 2: rim arcs at pt **14.5 -> 25.0** (approx 11 pt, `busNodeDiameterUnselected`), centre pixel = panel ground, **plus a detour arc whose leftmost stroke sits at pt 7.0-8.5** — exactly `20 - (5.5 + 6.5) = 8` for a 2 pt stroke.

Detour construction (`BusRailOverlayView.swift:425-432`): `appendArc(withCenter: (cx, nodeY), radius: nodeRadius + 6.5, startAngle: 90, endAngle: 270, clockwise: false)` — in AppKit's y-up space that sweeps through 180 deg, i.e. **bows LEFT**. Straight runs stop at `nodeY +/- (nodeRadius + 6.5)`. For an on-spine node the runs stop at `nodeY +/- (nodeRadius + 3)` (`:412-414`) — 3 pt clear of the node **edge**, not its centre.

Ring hook (`BusRailOverlayView.swift:369-372`): `move(ringLeftX, ringCenterY)` -> `curve(to: (cx, ringCenterY - 16), controlPoint1: (ringLeftX - 10, ringCenterY), controlPoint2: (cx, ringCenterY - 6))`, all in y-up.

**Level meters are EMPTY in the reference** (`emitsLevels: false`, `popover-snapshot/main.swift:147`). Measured track bands (colour `meter` `#464C55` = (70,76,85)), x span **147 -> 295 px = pt 73.5 -> 147.5**, i.e. `nameColumnLeading` for `meterUnderNameWidth` 74:

| Row | Band (pt) | Offset from row centre | Height |
|---|---|---|---|
| Bedroom HomePod / Office / Sonos Move | +7.75 -> +10.75 | **+7.75** | 3 pt |
| Main Audio | 78.00 -> 84.00 | **+6.25** | 6 pt |

Warm-pixel count inside each meter band: 2 (the capsule's antialiased caps). **Zero fill.**

**Fader thumb.** Measured centres at four known values: 25 % -> 335.75, 40 % -> 357.75, 50 % -> 371.75, 100 % -> 443.75. These fit **thumb centre (pt) = 299.75 + 1.44 x value** exactly at 25/50/100 and within 0.4 pt at 40 (pixel quantisation). AppKit's stock knob travel applies; `WarmFaderCell.swift:196-205` re-centres Y only. Track ends measured at px 594 and 894 = pt 297 and 447 OK.

**Source pills**, measured on the Office row (y = 808 px):
- Pill 1 "System": pt **499.0 -> 545.5**, border **(107,118,125) = `rim`**, interior `well` `#050507`, text **(232,184,75) = `goldText` `#E8B84B`**.
- Pill 2 "Music": pt **549.0 -> 587.5**, same border and interior, text **(183,172,149) = `label2` `#B7AC95`**.
- Gap 3.5 pt approx `feedPillGap` 3. Capsule radius = height / 2 (`FeedPillView.swift:150`), 1 pt border (`:51`), fills at `:141-142`.

**Destination popup**, measured at x = 1010 px: bezel spans pt **64.00 -> 79.50** (16 pt tall, centred on the 71.75 row centre), horizontally the full trailing column pt 499 -> 639. Fill is a **1 px top lip (115,116,118) = `#737476` over a flat body (80,81,83) = `#505153`**. It is a stock `NSPopUpButton`, `pullsDown = false`, `controlSize = .small` (`MainOutRowView.swift:156`, `:454`).

### Type and colour corrections

| Element | App value | Source | Current rebuild |
|---|---|---|---|
| Card header title | `Tokens.Font.captionEmphasized` = 11 pt semibold, `label2` `#B7AC95` | `PopoverPanelViewController.swift:735-736`, `Tokens.swift:1306-1308` | 13 pt / 600 / `label` (`mixer.tsx:599-603`) |
| Column legend ("Output", "Source", "Offset") | `makeColumnHeaderLabel` (`:795`) -> `makeLegendLabel(text, weight: .medium, color: Tokens.Color.secondaryLabel)` (`:1376`) = 11 pt medium, **`label2` `#B7AC95`** (`Tokens.swift:1232`) | | 10 pt / 600 / `labelCool2` |
| Subsection title | `Tokens.Font.captionMedium` 11 pt medium, `inkTertiary` = **`label3` `#9E947F`** | `PopoverPanelViewController.swift:1408-1409`, `Tokens.swift:1238` | 11 pt / 500 / `labelCool2` |
| Card note | `Tokens.Font.detail` 11 pt regular, `secondaryLabel` = **`label2`**, wrapper height **18 pt**, leading `headerTitleLeading` **58.5**, one line, truncating tail | `PopoverPanelViewController.swift:1518-1541`, `Tokens.swift:1352`, `:1232` | 11 pt, `labelCool2`, height 26, wrong leading |
| Note copy | `"Click a speaker's name to play your audio on it. Click it again to stop."` | `PopoverController.swift:2340` | second sentence dropped (`ScenesVideo.tsx:152`) |
| Device name | `Tokens.Font.menuItem` = `NSFont.menuFont(ofSize: 0)`; armed `Tokens.Color.label`, idle `labelCool` `#A9B3BB` | `DeviceRowView.swift:1556`, `:2338-2342` | **weight flips 400->600 on live — the app never changes weight** (`mixer.tsx:350-351`) |
| `%` readout | `Tokens.Font.readout` 11 pt semibold monospaced-digit; `goldText` armed / `emberText` idle | `DeviceRowView.swift:1632`, `:742-746` | correct |
| Device icon tint | `Tokens.Color.label2` `#B7AC95`, **constant** | `DeviceRowView.swift:603` | mixes `labelCool2`->`glow` (`mixer.tsx:135`) |
| Live row wash | `gold` at **0.12** alpha, rect inset (5, 2), radius **10** | `DeviceRowView.swift:2653-2659` | `rgba(46,37,24,0.55)`, full-bleed from `railGutter`, radius 16 |
| Fader trough | `well` `#050507`, height 5, capsule, one flat inset-shade hairline | `WarmFaderCell.swift:86-97` | `socket`, height 3 |
| Fader fill | ember->gold gradient armed; `rim` `#6B767D` unarmed | `WarmFaderCell.swift:108-136` | flat mix + `boxShadow` |
| Fader thumb | 10 x 17, capsule r 5, `raised` fill at interior alpha, `rim` stroke | `WarmFaderCell.swift:217-223` | 11 px circle + two shadows |
| Route-armed dot | 8 pt disc, centre 3 pt in from the icon box's bottom-right; `gold` armed / `socket` idle; 1.5 pt `underPageBackground` stroke | `RouteArmedDotView.swift:133-139` | 6 px disc + `boxShadow` |

**The glows are forbidden by the folder's own rule.** `AudioutCore/Sources/AudioutSharedUI/AGENTS.md`: "Instruments are flat, no `CALayer` blooms." `HaloRingView.swift:388`: "A stroke, never a shadow: the instruments carry no blooms."

### The reference fixture

`MockBackend.demoFleet` (`AudioutCore/Sources/AudioutCore/MockBackend.swift:644-658`) in **source order**: `local-mac` "MacBook Pro Speakers" `.localMac` 65 · `sonos-move` "Sonos Move" `.sonos` 40 · `sonos-move-2` "Move 2" `.sonos` 55 · `airport-mixer` "Mixer" `.airportExpress` 30 · `appletv-lr` "Living Room TV" `.appleTV` 60 · `homepod-bed` "Bedroom HomePod" `.homePod` 25 · `office` "Office" `.generic` 50. The panel renders them in the display order given by the vertical table above.

`isSelected: true` on `sonos-move` and `sonos-move-2` is a device-model flag the popover does **not** read for membership. Membership is `GroupController.selectedDeviceIDs`, seeded by `ensureDefaultSelection()` (`GroupController.swift:227-229`, which only acts on an empty set) and then by three explicit calls at `popover-snapshot/main.swift:181-183` (`office`, `homepod-bed`, `sonos-move`). That is why Move 2 draws an 11 pt hollow node.

SF Symbol per kind (`AudioutCore/Sources/AudioutCore/Device.swift:59-81`): `.localMac` -> `laptopcomputer`, `.homePod` -> `homepod.fill`, `.appleTV` -> `appletv.fill`, `.airportExpress` -> `wifi.router.fill`, `.sonos` / `.generic` -> `hifispeaker.fill`.

### The video's own fixture

`ScenesVideo.tsx:103-154`: five devices, `airplayFrom: 1`, `hint` **non-null for the whole video** — `mixer.tsx:105-113` advances y by `H.note` whenever `hint` is truthy and `hintOpacity` only fades the text, and `marketing/video/AGENTS.md:24-26` requires exactly that ("fades but keeps its slot… unmounting it reflows the whole panel mid-shot"). **The hint slot persists for all 900 frames, so one set of row centres holds throughout.**

### Two omissions, re-judged

- **Mute and equalizer controls: omitting them is correct.** The region between the name column and the slider in the fresh render is empty. The app draws neither at rest. `marketing/video/AGENTS.md:18-20` calls this a deliberate omission; it is in fact faithful.
- **App Routing card: still omitted.** It sits entirely below the gated crop, so it does not affect the number.

---

## Steps

### Track A — `tokens.ts` + `mixer.tsx` (one worktree; they cannot be split)

**A1. `tokens.ts` — metrics.** Replace the `metric` object with the app's grid. Delete `nameWidth`, the 70 pt `sliderWidth`, `trailingWidth`, `railGutter` and `rowRadius` — every one was a guess. Add, as literals with `PopoverColumnGrid.swift` line numbers in comments: `leadingInset 14`, `trailingInset 14`, `firstElementLeading 38.5`, `subsectionHeaderLeading 54.5`, `headerTitleLeading 58.5`, `nameColumnLeading 73.5`, `iconWidth 26`, `iconGlyphPointSize 18`, `sliderLeading 297`, `sliderWidth 150`, `sliderTrailingEdge 447`, `readoutTrailingEdge 493`, `readoutWidth 40`, `trailingColumnLeading 499`, `trailingColumnTrailing 639`, `trailingControlWidth 140`, `rowHeight 42`, `rowWashInsetX 5`, `rowWashInsetY 2`, `rowWashRadius 10`, `rowWashAlpha 0.12`, `railCenterX 20`, `railLineWidth 2`, `railNodeRadiusSelected 7.5`, `railNodeRadiusUnselected 5.5`, `railNodeRimWidth 1.5`, `railNodeGap 3`, `railDetourBulge 6.5`, `railHookBulge 10`, `railHookControlDrop 6`, `railHookLandingDrop 16`, `meterWidth 74`, `meterHeight 3`, `meterOffsetY 7.75`, `masterMeterHeight 6`, `masterMeterOffsetY 6.25`, `haloRingDiameter 30`, `haloRingStroke 1.6`, `haloRingGapCenterDeg 45`, `haloRingGapWidthDeg 70`, `mainAudioRingDiameter 34`, `mainAudioRingStroke 2`, `armedDotDiameter 8`, `armedDotInset 3`, `armedDotBorderWidth 1.5`, `faderTrackHeight 5`, `faderThumbWidth 10`, `faderThumbHeight 17`, `faderCenterBase 299.75`, `faderCenterPerPercent 1.44`, `feedPillPaddingX 4`, `feedPillPaddingY 2`, `feedPillGap 3`, `syncChipWidth 84`, `syncChipHeight 18`, `syncChipRadius 5`, `panelRadius 12`, `controlRadius 10`.

`haloRingGapCenterDeg` is **+45** because the app's -pi/4 is measured in a y-up layer and SVG is y-down; the gap still lands at the visual bottom-right where the armed dot sits.

**A2. `tokens.ts` — width.** Set `PANEL_WIDTH = 653` as a literal citing `SurfaceLayout.swift:13`. Delete the summing expression at `tokens.ts:49-61`; the real panel's width is not the sum of its columns.

**A3. `tokens.ts` — colours and header.** Add `ring: "#7FB4C4"`, `failure: "#D9564A"`, `rule: "rgb(174, 179, 187)"` (measured, not traced to a token), `popupLip: "#737476"`, `popupBody: "#505153"`. Do **not** add `railDormant` — the dormant, connecting and failed rail tones never occur in this video. Mark that as a deliberate ceiling with a `razor:` comment naming the upgrade path (read `Tokens.swift:554`, dark hex `0x6B767D`, if a future video shows a disconnected speaker). Correct the file header: metrics now come from `PopoverColumnGrid.swift` plus a measured render, not from `DESIGN.md`'s `spacing` block, which carries eight of the sixty-odd numbers.

**A4. `tokens.ts` — vertical rhythm.** Add a `vertical` object: `panelTopInset 22.75`, `cardHeaderHeight 28`, `subsectionHeight 22`, `cardNoteHeight 18`, `ruleGapAbove 15.25`, `ruleHeight 1`, `ruleGapBelow 13.75`. Comment that these were measured off a `popover-snapshot` render because the app's vertical rhythm is autolayout-driven.

**A5. `mixer.tsx` — layout.** Rewrite `H` and `layout()` from A4's values. The rule is a **1 pt band**, not a zero-height divider: advance 15.25, emit the rule, advance 1, advance 13.75. Keep `layout()`'s signature and its returned `{ items, height, mainY, plusY }` — `ScenesVideo.tsx` depends on it.

Verify by arithmetic that the **reference fixture** (7 devices, `hint: null`) yields row tops 50.75 / 150.75 / 214.75 / 256.75 / 298.75 / 340.75 / 382.75 / 424.75, and that the **video fixture** (5 devices, hint present) yields row centres:

| Row | Centre |
|---|---|
| Main Audio | 71.75 |
| MacBook Pro Speakers | 189.75 |
| Bedroom HomePod | 253.75 |
| Living Room TV | 295.75 |
| Office | 337.75 |
| Sonos Move | 379.75 |

**A6. `mixer.tsx` — row columns.** Absolutely position each element at its anchor instead of a flex strip: icon box at x 38.5 (26 wide), name text at x 73.5, slider track x 297 -> 447, readout right-aligned with its trailing edge at x 493, trailing control x 499 -> 639. The name column's trailing edge governs truncation only and no name in this video truncates — spend nothing on it.

**A7. `mixer.tsx` — row wash.** `gold` at `0.12 * live` alpha, on a rect inset 5 pt horizontally and 2 pt vertically from the row bounds, corner radius 10, spanning the full panel width (no `railGutter` offset).

**A8. `mixer.tsx` — halo ring.** Device rows: a stroked arc, diameter 30 centred on the icon box centre (x 51.5, row centre y), stroke width 1.6, stroke colour **constant `rim` `#6B767D`**, with a 70 deg gap centred at +45 deg in SVG's y-down space. Its **opacity** is `live`; nothing else about it changes, and it is absent at `live = 0`. Main Audio: diameter 34, stroke 2, colour gold `#E8B84B`, always present. **No `boxShadow` on either.**

**A9. `mixer.tsx` — armed dot.** An 8 pt disc centred 3 pt in from the icon box's bottom-right corner (centre at x 51.5 + 10, row centre + 10), fill interpolating `socket` -> `gold` on `live`, 1.5 pt stroke in the panel ground. **No `boxShadow`.**

**A10. `mixer.tsx` — fader.** Trough 5 pt tall, capsule, `well` `#050507`, with one flat 1-px darker band along its top edge. Filled portion a linear gradient `ember` -> `gold` when armed, flat `rim` `#6B767D` when not. Thumb 10 x 17, capsule radius 5, `raised` fill, `rim` stroke. **Thumb centre x = `faderCenterBase + faderCenterPerPercent * value` = 299.75 + 1.44 x value.** Sanity-check against the measured values 25 -> 335.75, 40 -> 357.75, 50 -> 371.75, 100 -> 443.75. **No `boxShadow`s.**

**A11. `mixer.tsx` — level meter.** Track only: x 73.5, width 74, height 3 (6 on Main Audio), radius = height / 2, colour `meter` `#464C55`, top edge at row centre + 7.75 (+ 6.25 on Main Audio). The fill is an `ember` -> `gold` gradient whose width is `meter x 74`, and **`meter` of 0 draws nothing**. Delete the `?? 0.35` default at `mixer.tsx:360` and the `Math.max(6, …)` 6 % floor at `:234` — zero must mean zero, because the reference's meters are empty. The video's own devices carry explicit `meter` values of 0.2-0.62 and are unaffected.

**A12. `mixer.tsx` — source pills.** Widen `DeviceModel.source` (`mixer.tsx:23`) from `string | null` to `string[] | null`, and change the fallback at `:380` from `"System"` to `["System"]`. `ScenesVideo.tsx` sets no `source` key on any device, so it keeps compiling untouched. Render the pills left-aligned from x 499 with a 3 pt gap: capsule (radius = height / 2), `well` background, 1 pt `rim` border, padding 4 pt horizontal and 2 pt vertical. **Text colour: index 0 -> `goldText` `#E8B84B`; index >= 1 -> `label2` `#B7AC95`** (measured).

**A13. `mixer.tsx` — rail.** Nodes at x 20; radius 7.5 filled gold when live, 5.5 drawn as a 1.5 pt rim when not; line width 2, gold. SVG path arithmetic, y-down:
- Through a live node: the run above stops at `nodeY - (7.5 + 3)` and the run below resumes at `nodeY + (7.5 + 3)`.
- Around an idle node, with `R = 5.5 + 6.5 = 12`: the run above stops at `nodeY - R`, then `A R R 0 0 0 20 (nodeY + R)` — **sweep-flag 0**, which in SVG's y-down space bows the arc **left**, matching the measured leftmost stroke at pt 7.0-8.5 for a 2 pt line centred on x 8. The run below resumes at `nodeY + R`.
- Ring hook at the Main Audio end, with `ringLeftX = 51.5 - 17 = 34.5` and `ringCenterY = 71.75`: `M 34.5 71.75 C 24.5 71.75, 20 77.75, 20 87.75`. The straight rail begins at y 87.75.

Interpolate node radius and fill on `live` so the video's arm/disarm transitions still animate.

**A14. `mixer.tsx` — icons.** Keep the hand-drawn SVG shapes. Correct their box to 26 x 26 pt at x 38.5, size the artwork to the app's 18 pt glyph point size, and set the stroke to a **constant `label2` `#B7AC95`** — no interpolation on `live`. Extend `IconKind` (`mixer.tsx:12`) from `"laptop" | "homepod" | "appletv" | "speaker"` to add `"router"`, and draw a router shape for it; the four existing literals in `ScenesVideo.tsx:103-143` stay valid and that file is not touched.

**Deliberate ceiling — mark it with a `razor:` comment.** Exact SF Symbol glyph shapes are out of scope: the icons are about 1.5 % of the gated crop's area and `boxblur=4:1` erases their internal detail, so they cannot move the number. Upgrade path if a future close-up needs them: render each glyph to PNG from the Mac's own SF Symbols and mask it.

**A15. `mixer.tsx` — destination control.** Reproduce the stock popup in CSS from measured values rather than an image: box x 499 -> 639, height 16 pt centred on the row, `background: linear-gradient(#737476 0 1px, #505153 1px)`, corner radius 5, title in 13 pt system font, and a hand-drawn double chevron at the right. Delete the current border and `raised` fill.

**A16. `mixer.tsx` — type.** Card header title 11 pt semibold `label2`; column legend 11 pt medium `label2`; subsection title 11 pt medium `label3` `#9E947F` at x 54.5; card note 11 pt regular `label2` at x 58.5 in an 18 pt slot, single line; device name at menu-font size with **no weight change on `live`**, colour interpolating `labelCool` -> `label`.

**A17. `mixer.tsx` — Offset column.** Add the "Offset" legend left-aligned at x 653 - (14 + 84) = **555**, and a dashed "Not set >" chip on the MacBook Pro Speakers row: 84 x 18, radius 5, 1 pt dashed border (3 on, 2 off), trailing edge at x 639. The app prints both whenever a sync-capable row is present, and this fleet has one.

**A18. `mixer.tsx` — panel chrome.** Remove the root element's `borderRadius`, `border` and `boxShadow` (`mixer.tsx:497-501`). The reference bitmap is square-cornered, unbordered and unshadowed — pixel (0,0) is the panel ground `#15171A`. The rounded shell belongs to the app's window, not to the panel, and Track C re-adds it as staging around the component.

**A19. `mixer.tsx` — the hairline rule.** Draw it 1 pt tall in the measured `rule` colour, spanning x `leadingInset` -> `653 - leadingInset`.

### Track B — the measuring harness (after A)

**B1.** Add `marketing/video/src/MixerStill.tsx`: renders `<Mixer model={…} />` with **exactly** the reference fixture — `destination: "Selected Speakers"`, `mainVolume: 100`, `hint: null`, `airplayFrom: 1`, and seven devices in display order: MacBook Pro Speakers (`laptop`, 65, live 0, meter 0), Bedroom HomePod (`homepod`, 25, live 1, meter 0, source `["System"]`), Living Room TV (`appletv`, 60, live 0, meter 0), Mixer (`router`, 30, live 0, meter 0), Move 2 (`speaker`, 55, live 0, meter 0), Office (`speaker`, 50, live 1, meter 0, source `["System", "Music"]`), Sonos Move (`speaker`, 40, live 1, meter 0, source `["System"]`). It adds nothing to the video's story.

**B2.** Register it in `marketing/video/src/Root.tsx` as `<Still id="MixerStill" component={MixerStill} width={653} height={758} />`. `Still` is exported by the installed Remotion. Leave the `Scenes` `<Composition>` untouched.

**B3.** Add `marketing/video/.gitignore` entries `reference/` and `out/` (the file already exists — add to it), so neither the rendered reference nor rendered video is ever committed.

**B4.** Add `marketing/video/scripts/fidelity.sh`. It renders the still with **`--scale=2`** to a temporary path, then prints two SSIM numbers against `reference/popover-dark.png`, cropping both to **1306 x 932 px** from the origin (panel top through pt 466, just inside the Sonos Move row's 466.75 bottom edge). The filter graphs are:

- plain: `[0:v]crop=1306:932:0:0[a];[1:v]crop=1306:932:0:0[b];[a][b]ssim`
- blurred: `[0:v]crop=1306:932:0:0,boxblur=4:1[a];[1:v]crop=1306:932:0:0,boxblur=4:1[b];[a][b]ssim`

ffmpeg needs `-hide_banner -loglevel info` or it prints no SSIM line. The script exits non-zero if the blurred number is below 0.95, and fails loudly if `reference/popover-dark.png` is missing rather than comparing against nothing.

### Track C — the video (after A, parallel with B)

**C1.** In `ScenesVideo.tsx`, wrap `<Mixer model={model} />` in a staging div carrying the shell look Track A removed: `borderRadius: metric.panelRadius`, `border: 1px solid ${color.hairline}`, `boxShadow: "0 24px 60px #000C, 0 2px 8px #0008"`, `overflow: "hidden"`, sized `PANEL_WIDTH x panel.height`.

**C2.** Replace the camera's output range at `ScenesVideo.tsx:164` with these literals — the approved push-in shape, refitted to the 653 pt panel:

```
[1.568, 1.646, 1.646, 1.646, 1.568, 1.615, 1.615, 1.646, 1.568, 1.568]
```

At the widest point 1.646 x 653 = 1074.8 px, inside the 1080 px frame with the same margin the old framing had. **Do not touch the input frame array at `:163`** — the camera's timing is approved.

**C3.** Re-aim `AT` (`ScenesVideo.tsx:53-63`) at the new geometry, using the video-fixture row centres from A5 and the fader formula from A10:

| Key | New value | Why |
|---|---|---|
| `homePodName` | `[110, 253.75]` | names start at x 73.5 |
| `officeName` | `[110, 337.75]` | |
| `sonosName` | `[110, 379.75]` | |
| `homePodKnob` | `[335.75, 253.75]` | 299.75 + 1.44 x 25 |
| `homePodKnobEnd` | `[364.55, 253.75]` | 299.75 + 1.44 x 45 |
| `destination` | `[569, 71.75]` | centre of the trailing column, 499 -> 639 |
| `plus` | centre of the plus button at its new position from `layout().plusY` | |
| `plusMenuItem` | first item of the plus menu at its new origin | |
| `destMenuScene` | the "Whole house" row of the destination menu at its new origin | |

**C4.** Move the two `<Menu>` origins (`ScenesVideo.tsx:317-318` and `:329-330`) to hang off the controls they belong to at the new anchors. Their `width`, `entries`, `reveal` and `highlight` expressions are unchanged.

**C5.** Restore the card note's full app copy at `ScenesVideo.tsx:152`: `"Click a speaker's name to play your audio on it. Click it again to stop."`

**C6.** Leave `BEAT`, every `<Sequence>`, every `CaptionCard`, `cursorFrames`, `clicks`, `pressed`, `dip`, `panelIn`, `outro`, the device list and the outro block exactly as they are.

### Track D — the folder's rules (parallel with everything)

**D1.** Correct `marketing/video/AGENTS.md`: the metrics authority is `AudioutCore/Sources/AudioutSharedUI/PopoverColumnGrid.swift` plus a `popover-snapshot` render, not `DESIGN.md`. Remove "no mute control" from the deliberate omissions — the app draws none at rest. Replace the "camera scales at 2.0x" rule with the refitted range and the fact that the panel is now its real 653 pt. Document the fidelity check and the two traps: `popover-snapshot` with no argument overwrites `dev/notes/popover-snapshots/`, and a default run writes four PNGs.

---

## Out of scope — do not touch

- **Anything under `AudioutCore/`, `AirPlayEngine/`, `scripts/`, `.github/`, `DESIGN.md`, `docs/`.** The video reads from the app; the app never bends to the video. If a metric seems missing, it is missing from this work order — stop and report; do not add a snapshot mode.
- `dev/notes/popover-snapshots/` and `docs/media/popover-dark.png` — read-only. Never regenerate into them.
- `marketing/video/remotion.config.ts` — a scale or image-format change there also changes the video render.
- `marketing/video/package.json`, `package-lock.json`, `node_modules/` — **no new dependency.** ffmpeg and Node cover the whole measurement.
- `marketing/video/src/chrome.tsx` — `Menu`, `Cursor`, `ClickRing` and `CaptionCard` keep their current drawing. Track C moves where the menus are placed, never how they look. `marketing/video/AGENTS.md:27-29` warns that tidying `CaptionCard` into tokens greys out every control in the Remotion Studio.
- `marketing/video/README.md`, `marketing/video/out/`.
- `.github/workflows/marketing-video.yml` — CI stays Node-only.
- The App Routing card, the Bluetooth subsection, "Connect a speaker", the +/- footers, the sync drawer, the equalizer and mute buttons, hover and selection washes, the collapse chevrons' interactivity, and every connection state other than connected and off.
- `BEAT`, caption text, caption `<Sequence>` boundaries, cursor frame timings, the click list, the time-cut, the outro.
- No cleanup, no abstractions, no error handling for impossible cases, no backwards-compat shims. Nothing is committed or pushed.

---

## Verification

All commands from `marketing/video` unless stated. Baselines observed this session are in the right column.

| Command | Expected | Baseline |
|---|---|---|
| `git status --porcelain` (repo root) | no entry under `AudioutCore/`, `scripts/`, `docs/`, `dev/`, `.github/` | clean at `0f3800e4` |
| `AUDIOUT_RUN_PRODUCT=popover-snapshot bash scripts/run-app.sh "$PWD/marketing/video/reference"` (repo root) | exit 0; four PNGs; `popover-dark.png` at 1306 x 1516 | exit 0, 33.57 s |
| `npx tsc --noEmit` | exit 0, no output | exit 0 |
| `bash scripts/fidelity.sh` | prints both numbers; **blurred SSIM >= 0.95** | — |
| `npx remotion render Scenes out/Scenes.mp4 --log=error` | exit 0, 900 frames, 1080 x 1920 | `still` ran in 4.65 s |

**The 0.95 floor is measured, not invented.** Against this same reference a uniform 2 pt shift scores 0.956 blurred and a 4 pt shift scores 0.925, so 0.95 means every column and row lands within about 2 pt. Report the plain SSIM alongside it; it will sit lower because Chrome and AppKit antialias text differently, and that gap is expected.

Record the blurred number once **before Track A's instrument work lands** (Track B's harness against the old drawing) so the improvement is a measured delta rather than a claim. Paste both numbers.

---

## Execution plan

The branch is clean at `0f3800e4`, so isolated worktrees fork with nothing missing.

**The tracks are file-disjoint but not independently runnable, so the order is forced.** Step A1 deletes `metric.nameWidth`, `sliderWidth`, `trailingWidth`, `railGutter` and `rowRadius`, all of which `mixer.tsx` reads at lines 332-343, 346, 464, 483, 504, 527, 558 and 567 — splitting tokens from the panel leaves the type-check red. Track B's fixture consumes the `source: string[]` shape Track A introduces. Track C consumes Track A's `PANEL_WIDTH` and `layout()` y values.

| Track | Files | Depends on | Model | Effort | Run |
|---|---|---|---|---|---|
| **A — tokens + panel** | `marketing/video/src/tokens.ts`, `marketing/video/src/mixer.tsx` | — | opus | high | first, alone |
| **B — harness** | `marketing/video/src/MixerStill.tsx`, `marketing/video/src/Root.tsx`, `marketing/video/scripts/fidelity.sh`, `marketing/video/.gitignore` | A's `MixerModel` shape | sonnet | medium | PARALLEL with C, after A |
| **C — video** | `marketing/video/src/ScenesVideo.tsx` | A's `PANEL_WIDTH` and `layout()` | opus | medium | PARALLEL with B, after A |
| **D — folder rules** | `marketing/video/AGENTS.md` | — | haiku | low | PARALLEL with everything |

B and C touch no shared file and both only read from A, so they run at the same time in separate worktrees after A merges. D is independent throughout.

**No per-track check passes in isolation** — `npx tsc --noEmit` only goes green once A, B and C are all in one tree. Verification runs once, on the combined result. Track A is the hard one: the rail's detour arcs and the ring hook are interlocked geometry with no second chance to be approximately right.

---

## Executor rules

- Follow the steps in order. Do not add, merge, reorder, or skip steps.
- Before editing in any folder, read the nearest AGENTS.md above it (and the root one) — folder rules and traps bind even when the work order doesn't repeat them.
- If reality contradicts a Verified fact or a step is impossible as written, STOP and report the discrepancy. Do not improvise a workaround.
- Before reporting progress, audit each claim against a tool result from this session. Only report work you can point to evidence for. If tests fail, say so with the output.
- "Done" means the Verification commands were run in this session and passed. Paste their output.
- Touch nothing in the Out-of-scope list.
- Deliver what was asked, at the scope intended. If the spec seems mistaken or a better approach exists, say so in a sentence and continue as specified rather than quietly narrowing, widening, or transforming it.
- Never run bare `swift build`, `swift test`, `swift run`, `xcodebuild` or `swift package` — a hook denies them. The only Swift command here is `AUDIOUT_RUN_PRODUCT=popover-snapshot bash scripts/run-app.sh <explicit output dir>`, and the output directory argument is mandatory.
- Add no npm dependency. ffmpeg and Node cover the whole measurement.
- Commit nothing and push nothing.

---

# APPENDIX — corrections, and the rule that outranks everything above

An adversarial re-check found the following. These OVERRIDE the steps above where they conflict.

## THE STANDING RULE

**Where this work order and the rendered reference disagree, the render wins.**

Two reviewers have already disagreed about individual constants in this document. `marketing/video/reference/popover-dark.png` is the app's own output and is the only authority. Before drawing any element whose value is described as "measured", measure it yourself in the reference and use what you measure. When your measurement differs from a number above, use yours and **name the discrepancy in your final report** — do not silently follow either one.

A worked example of doing this, which you can copy:

```python
from PIL import Image          # Pillow is available to python3 here
im = Image.open('marketing/video/reference/popover-dark.png').convert('RGB')
GROUND = (0x15, 0x17, 0x1A)    # the panel's own background
# every non-background pixel in row y, as points (the render is 2x)
xs = [x for x in range(im.size[0]) if im.getpixel((x, y)) != GROUND]
```

The SSIM gate is the real arbiter: a wrong constant shows up as a number below 0.95 regardless of who wrote it.

## A18 — the line range is off by one at BOTH ends

`mixer.tsx:497` is `height,` and `:499` is `backgroundColor: color.panel,`. **Keep both.** Remove only `borderRadius` (`:498`), `border` (`:500`) and `boxShadow` (`:501`). Move `overflow: "hidden"` (`:503`) off the panel and onto Track C's wrapper.

## A11 — replace the default, do not delete it

Main Audio's synthetic device (`mixer.tsx:80-90`) carries no `meter` key and `meter?` is optional, so deleting `?? 0.35` outright yields `undefined` and a type error. **Replace `?? 0.35` with `?? 0`**, and replace `Math.max(6, level * 100)` with `level * 100`. Zero then means zero and Main Audio still draws its 6 pt track.

## A19 — the divider: colour confirmed, span was wrong

I measured the reference directly at six x positions: the divider is **`rgb(174, 179, 187)`, 1 pt tall, at pt 108.0-109.0**. A3's colour stands. (The re-check argued it should be `containerEdge` `#3D4247` from `CardDividerView`; the render disagrees, and the render wins.)

**A19's span is wrong.** It does NOT run 14 -> 639. Measure the contiguous run of exactly `(174, 179, 187)` in row y = 216 px and use that. Beware: the gold rail crosses the same row near x = 40 px and is not part of the divider, so find the contiguous run, not the min and max of all non-background pixels.

## A10 — the fader thumb overhangs the track

`299.75 + 1.44 x value` gives a thumb left edge of 294.75 at value 0 and a right edge of 448.75 at value 100, against a track of 297 -> 447. A 10 pt thumb in a 150 pt track can only travel 140 pt, not 144. Main Audio sits at 100 in both fixtures, so this is visible in the gated image.

**Measure the thumb directly and derive the formula from what you find.** The thumb is `raised` fill with a `rim` stroke — COOL grey, not warm — so a warm-pixel scan finds the filled track, not the thumb. Find it by looking for the cool stroke. Measure at Main Audio (100), Office (50), Sonos Move (40), HomePod (25), then fit. Report the fitted formula and both endpoints.

## A16 / A17 — the two legends collide, and one font is unresolved

- Adding "Offset" at x 555 collides with "Source", which is right-aligned at x 639 today (`mixer.tsx:590-615`). **Measure both legends' actual x in the reference** and place them there.
- "device name at menu-font size" is not a number. Use **13 px** (the current `font.name`), unless the reference measures otherwise.

## C3 / C4 — no prose anchors

`plus`, `plusMenuItem`, `destMenuScene` and both `<Menu>` origins must be **literal numbers** in the final code. Compute them from `layout()`'s actual output and from `chrome.tsx`'s own row heights and padding (read them; do not guess), print the computed values in your report, and write the literals into `AT`. The cursor has to land on the highlighted menu row or the click rings read wrong.

## B1 — the still must sit flush at the origin

`B4` crops `1306x932` from `0,0` in both images, so `MixerStill` must render the panel with its top-left at the composition origin: no wrapper, no margin, no centering, no page padding. Any offset silently destroys the number the harness exists to produce.

## B3 — only `reference/` is new

`out` is already in `marketing/video/.gitignore`. Add `reference/` alone.

## C1 — wrap ONLY the Mixer

Wrap `<Mixer model={model} />` and nothing else. The two `<Menu>` elements are siblings of `<Mixer>` inside the scaled div, and the plus menu hangs BELOW the panel's bottom edge — wrapping the whole overlay group in an `overflow: hidden` div would clip it.

## Execution plan — one claim corrected

"No per-track check passes in isolation" is wrong. `ScenesVideo.tsx:18` imports only `color`, `font` and `PANEL_WIDTH`, all of which survive A1/A2, so **`npx tsc --noEmit` goes green after Track A alone.** Track A must type-check before it hands off.
