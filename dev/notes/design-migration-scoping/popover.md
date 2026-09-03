# Popover + status item — scoping report

## What exists today
- Fixed-width 653pt panel (SurfaceLayout.swift:13), NO scroll view; height via preferredContentSize (PopoverPanelViewController.swift:25,277). Ground WarmCanvasView canvas (#16130F dark / #FBFBF9 light). Bubble ControlPanelBackingView radius 12, panel fill.
- Three cards by TRANSPORT not state: Main Audio → Output Devices → Applications (PopoverController.swift:1555,1603,1694); Output Devices split into Mac row + AirPlay / Cast / Bluetooth subsections (:1751-1754, 1949-1966).
- CardView draws nothing; only 1px hairline divider between cards (PopoverPanelViewController.swift:764-774,1654).
- Card header 28pt, chevron + captionEmphasized title in secondaryLabel, no state tint (:589,614,624).
- Main Out is a flat 44pt ROW (MainOutRowView.swift:64): name, 6pt meter, halo, gold routed dot, WarmFaderCell, caption readout, NSPopUpButton. No material, no radius, no shadow, partySignal never read.
- Tabs: three icon-only bordered NSToolbarItems in a .unified NSToolbar, AppKit selection (SurfaceToolbar.swift:83,139-145,252-271). Divergence from iOS documented on purpose (:118-124).
- Banners on SYSTEM colours: SilenceFallbackBannerView = warning (.systemOrange) 14%/40% border radius 11; SystemAirPlayNoteBannerView = info (.systemBlue) 12%/35% + warning tier. ConnectionDiagnosisView = failure ~12% over panel at radius 7.
- engagedChrome = label (neutral ink) for mute/hover/selection washes (Tokens.swift:135-151).
- Splash: 96pt brand mark + "Audiout" in 13pt bodyEmphasized on WarmPanelView (SurfaceSplashView.swift).
- Status item always template NSImage, 3 shapes, variableValue = volume (StatusItemIcon.swift:10-20). VolumeHUDPanel .hudWindow radius 12.
- GroupRowView has NO production consumer (removed 2026-07-16) — 421 dead lines.

## Where it breaks iOS rules
- Layout "Playing / Ready / Unavailable always present, membership off device state never transport" — Mac splits by transport.
- Main Out Deck: iOS = frosted 26pt panel, ultraThinMaterial + deckFill, 0.5pt stroke, the ONE shadowed surface, party edge when pointed at a group. Mac = flat row, partySignal unused.
- Don'ts: "no third status-banner hue; system orange and blue are out" / "no system colour anywhere" — both Mac banners are exactly those (Tokens.swift:177,191); ConnectionDiagnosisView adds a fourth radius.
- Status Banners: SF Symbol + footnote on 10pt rect at 12% — Mac radius 11 + 1px border, mixed 12/14%.
- Edges: card divider crosses bare canvas but draws hairline (should be containerEdge) (:1654). Invisible in dark (same hex), real half-step in light.
- Light chassis warm vs iOS cool — iOS file names the Mac values as the open gap.
- Gold rule: engagedChrome puts neutral ink on hover/selection; iOS solves mute with filled/outlined ember pair. Mac right on mute, open on hover/selection.
- Micro Label 11pt floor: Mac microLabel pinned at 10pt (Tokens.swift:1384).
- Section Header: iOS tints title goldText when Playing; Mac always secondaryLabel.
- Wordmark: splash uses system semibold; ClashDisplay not bundled.

## Worth keeping
- Icon-only NSToolbar tabs (AppKit selection satisfies "neutral tab bar" for free).
- Always-template status item (StatusItemIcon.swift:10-20 records a regression from tinting).
- engagedChrome for MUTE (same conclusion iOS reached).
- Card divider as only separation (closer to iOS "edges not shadows" than iOS's own cards); change token only.
- VolumeHUDPanel .hudWindow material (replaces system HUD).
- Window hasShadow (system chrome, not an authored shadow; One Shadow Rule doesn't reach it).

## Options
### A: Palette + banner conformance only — RECOMMENDED floor, Effort M
- Cool light hexes in Tokens.swift; banners drop system orange/blue for failure (real problem) + a new cool note tint matching iOS ring (#7FB4C4 / #2C6E86); drop 1px border, unify 12% fill, radius 11→10; divider hairline→containerEdge; ConnectionDiagnosisView radius 7→10.
- Conflicts head-on with PRODUCT.md:92 (Circuit light) — retire that line.
- Risk: NoteBannerColorTests.swift:33-78 asserts exact tokens/alphas (fails every case); MembershipWellContrastTests pins light gold vs well #E2DFD3; popover-snapshot PNGs stale (regenerable).
- Deps: whole-app light chassis decision; whether Mac gets iOS `ring` token by name.
### B: A + Main Out deck + stateful section headers — viable, Effort L
- MainOutRowView becomes a pinned overlay deck: 26pt NSVisualEffectView under deckFill tint, 0.5pt faderRim stroke; stroke + popup chevron → partySignal while target is .group. Card titles tint gold when live.
- No scroll view → deck pinned above a shorter stack; preferredContentSize arithmetic (:415-463) must subtract it.
- Risk: AppSurfaceControllerTests.swift:192,933-936 pin width/fit. MainOutRowRingTests survive.
- Deps: deckFill + ring tokens; ruling that partySignal may mark group identity on the Mixer (standing "secondary colours wizard-only" fence).
- Party edge = highest-value single item in this slice; frosted deck = expensive half, buys less.
### C: B + Playing/Ready/Unavailable restructure — NOT recommended in one pass, Effort XL
- deviceSections() (:1949-1966) keys on state; transport becomes filter chips. PopoverController.swift is 5309 lines; subsection identity threads through ingest, structural compare, rail cuts, collapse state, BT empty state.
- 76 test-site references across PopoverControllerTests, PopoverDeviceVisibilityTests, RowReveal*, PopoverPanelHeaderTests, MixerWindowControllerTests, CompanionCommandDispatcherTests; MembershipRailTests + RingRailToneLockTests depend on section order.
- Collides with no-scroll constraint (3 always-present headers + chip row add fixed height).
- Deserves its own scoped task, not a ride on a restyle.
### D: Delete GroupRowView — RECOMMENDED, orthogonal, Effort S
- Remove GroupRowView.swift (421 lines) + GroupRowViewTests; trim PopoverIconTests.swift:173-203, doc comments Tokens.swift:168,1339, PopoverColumnGrid.swift:8,580,814,855. Confirm readoutTrailing/sliderTrailing have no other consumer.

## Open questions
1. Does partySignal get to mark group identity on the Mixer (move the wizard-only fence by one surface)?
2. Splash: bundle ClashDisplay for the wordmark, or drop the text and let the mark stand alone?

## Files touched
SharedUI: Tokens, PopoverColumnGrid, WarmCanvasView. PopoverUI: SilenceFallbackBannerView, SystemAirPlayNoteBannerView, ConnectionDiagnosisView, PopoverPanelViewController, MainOutRowView, PopoverController, SurfaceSplashView, GroupRowView (delete). Tests: NoteBannerColorTests, GroupRowViewTests (delete), PopoverIconTests, AppSurfaceControllerTests, (C only) PopoverControllerTests, PopoverPanelHeaderTests, PopoverDeviceVisibilityTests, MembershipRailTests. PRODUCT.md:92.
NOT touched: SurfaceToolbar, StatusItemController, StatusItemIcon, MenuBarStatus, MenuTriggerImageView, VolumeHUDPanel, CardView.
