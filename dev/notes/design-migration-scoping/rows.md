# Shared row components + instruments (AudioutSharedUI) — scoping report

## What exists today
- Row height 42pt shared by device + app rows, no gap (PopoverColumnGrid.swift:550). Separation = inset pill 5x2 at 7pt radius inside the row.
- Row background NEUTRAL wash: engagedChrome 18% selected / 10% hover (DeviceRowView.swift:2917-2949). Nothing says warm-because-sounding.
- Fader = real NSSlider with drawing-only WarmFaderCell (drawBar/drawKnob only). Track 5pt/2.5 radius well fill + faderRim; thumb 10x17 at 4pt in faderThumb. Gold gradient only when route-armed; else ringConnected.
- Columns fixed, trailing-anchored (:200-213): icon 26, slider 150, readout 40, mute 24, EQ 24, gap 6, trailing 140.
- Readout: Font.caption 11pt regular secondaryLabel, PROPORTIONAL digits (DeviceRowView.swift:1500-1502), via VolumePercent NumberFormatter.
- HaloRingView: 30pt stroke, no seat/fill behind. ringConnected #8D7D5E is a WARM grey.
- RouteArmedDotView: 8pt gold disc bottom-right of icon, glow halo, dotSocket seat when unlit. Already the iOS routed dot in meaning.
- LevelMeterView: RMS bar 74x3 under name, ramp ember→gold→caution (LevelMeterView.swift:188-190). caution is the ceiling.
- FeedChip + FeedPillView + AppTetherColor = per-app colour identity from icon hue (~900 lines). FeedPill fill-only, no border.
- MembershipBusView + BusRailOverlayView: rail x=20, node 13pt, tone via spineTone(armed:) gold/ember (Tokens.swift:712), railDormant #7D7466 warm grey, dotSocket dimmed seat, failure, glow pulse.
- EQEditorView stock AppKit; EQResponseCurveView ALWAYS dark (draws inside .darkAqua on scopeGround #14110C) — even on paper.
- WarmNameFieldCell: raised fill + hairline border at 6pt radius.
- Premise corrections: `nodeUnavailableFill` DOES NOT EXIST; `syncSignal` not used by bus/rail (only by the wizard in PopoverUI).

## Where it breaks iOS rules
- Temperature Carries State: live wash is neutral engagedChrome; iOS puts gold 12% / warm liveRow behind sounding rows.
- Chrome half: ringConnected + railDormant are WARM greys carrying connection/dormancy; iOS chrome is always cool, uses cool `ring` #7FB4C4 for connecting.
- Gold rule: rail draws ember while idle — warm ink on a non-sounding thing.
- caution ban: iOS retired the amber (6.5° from gold); Mac meter ceiling is exactly that token.
- Readout voice: iOS 700 weight, tabular digits, goldText live / emberText idle; Mac 11pt regular grey proportional.
- Light flat ground: Mac keeps second rung raised #F2F0EA (name field fill); iOS light separation = edge weight.
- Shapes: Mac row slice uses 8 radii (7,7,6,5,4,2.5,1,12); iOS allows 10/16/26 + capsule faders.
- Row geometry: iOS 60/66pt, 8pt gap, 16pt radius, 44pt halo; Mac 42/42, no gap, 30pt halo.
- "No per-app hue": AppTetherColor + FeedChip are exactly the invented-data colour iOS ruled out.
- FeedPill wears a filled pill but is non-interactive ("a pill would promise a press").
- Dead-zone arc rule has no Mac counterpart (dot on icon corner, level 150pt away in slider column).

## Worth keeping
- Real NSSlider under WarmFaderCell — STRONGEST keep: keyboard, scroll wheel, focus ring, stock accessibility role free. Root AGENTS.md:262 + :284 make it a house rule. Row-as-fader is a touch adaptation.
- Under-name level meter as a Mac-only instrument (Mac is where audio originates; mixer shows several rooms; iOS `meter` token unused by its own admission). Self-stopping display link.
- EQResponseCurveView always-dark scope — same argument as iOS lampWell (dark in both appearances). Cite lampWell as its sanction.
- RouteArmedDotView unchanged in meaning; only token values are warm.
- Rail's armed/idle/dormant three-state structure (recolour, don't rethink).
- VolumePercent locale-aware formatter (better than iOS raw interpolation).

## Options
### A: Instruments + tokens only, no geometry — RECOMMENDED floor, Effort M
- Selected/live wash → gold 12%, hover stays neutral. Meter ramp ember→gold (drop caution). ringConnected + railDormant → cool-neutral values. Readout → semibold monospacedDigit, goldText live / emberText idle (needs two new text tokens). Fader unarmed fill off ringConnected.
- Light: cool chrome tokens; Mac flat #FBFBF9 ground already matches iOS flat-ground; raised light rung survives (name field untouched).
- Risk: TokenContrastMatrixTests, MembershipWellContrastTests (13), RingRailToneLockTests (3, asserts ring hue), NoTintOnRingsOrMetersGuardTests (levelMeterGradientIsEmberGoldCaution, deviceRowMeterKeepsWarmGradient), DeviceRowConnectionStateTests. Popover snapshots change. CHECK whether any row token reaches window-snapshot target (unreproducible goldens) first.
- Deps: token slice decides cool replacements for ringConnected/railDormant; whether Mac gains goldText/emberText; whether caution retired app-wide or only from meters.
### B: A + row shape and rhythm — viable AFTER A lands + eye-check, Effort L
- bodyRowHeight 42→60 device, new 66 app; 8pt rowGap in hosting stacks; wash → full-bleed 16pt clip; halo 30→44 with a seat fill; radius set collapses to 10/16/26, faders capsule.
- Light: retire raised light rung; name field raised fill → edge; halo idle fill → edge in light.
- Row height drives whole vertical budget (haloBreathingRoomGap, busGutterWidth, rail node spacing/detour, collapse trajectory, 653pt column budget). PopoverColumnGrid ~54KB interlocked constants.
- Risk: AppRowViewTests.rowHeightMatchesUnifiedBodyRowHeight (premise dies), CardViewCollapseTrajectoryTests, MembershipBusTests (25), BusRailCollapseResolveTests, RowReveal tests, all popover goldens. HARD CONSTRAINT: if DeviceRowView mounts in window-snapshot at new height, unreproducible goldens break with no regen.
- Deps: does 653pt width survive 60pt rows; can window-snapshot goldens be retired.
### C: B + row-as-fader — NOT recommended, Effort XL
- Delete NSSlider column; row = drag target; 300° arc around 44pt halo with 60° dead zone. Needs hand-written NSAccessibilitySlider role, keyboard, scroll, focus ring; must coexist with 4 existing row gestures (name-click membership/BT connect, icon-click EQ menu, gutter checkbox, context menu). Overrides AGENTS.md:262/:284 + SPEC §9. WarmFaderCellTests (16) deleted. Silent VoiceOver risk.

## Open questions
1. Per-app tether colour: keep AppTetherColor/FeedChip as a documented Mac-only divergence (it links app row to device FEED column across one window), or delete ~900 lines and let FEED pills carry text alone?
2. Level meter: keep as Mac-only instrument (recommended)? If kept, drop caution (gold ceiling) or keep the banned amber?

## Files touched
SharedUI: Tokens, PopoverColumnGrid, DeviceRowView, AppRowView, WarmFaderCell, WarmNameFieldCell, HaloRingView, LevelMeterView, RouteArmedDotView, FeedChip, FeedPillView, AppTetherColor, MembershipBusView, BusRailOverlayView, EQEditorView, EQResponseCurveView, AGENTS.md, AGENTS-HISTORY.md. Tests: TokenContrastMatrixTests, MembershipWellContrastTests, RingRailToneLockTests, NoTintOnRingsOrMetersGuardTests, DeviceRowConnectionStateTests, WarmFaderCellTests, AppRowViewTests, MembershipBusTests, CardViewCollapseTrajectoryTests, BusRailCollapseResolveTests, FeedColumnTests, EQResponseCurveTests.
