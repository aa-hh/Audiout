# Shared foundation tokens — scoping report (Fable)

## What exists today
- Tokens.swift 1667 lines, ~62 Tokens.Color cases + spineTone(armed:). Each resolves via NSColor(name:dynamicProvider:) (warmDynamic :1521) against appearance AND Increase Contrast → FOUR hexes per token. No asset catalogue. App-wide light/dark override via NSApp.appearance (AppDelegate.swift:2142-2144, AppearanceTheme). iOS has neither override nor IC.
- Dark ladder WARM: canvas #16130F, canvasHi #1B1712 (WarmCanvasView gradient), panel #1D1915, raised #241F1A, well #100D0A; hairline = containerEdge #3A332B.
- Light "Circuit": canvas=canvasHi=panel #FBFBF9, raised #F2F0EA, well #E2DFD3, hairline #D0CDC3, containerEdge #C4C0B4, sidebarWarmTint #F5F4ED.
- Ink: one warm family + system aliases; no cool family, no live/idle split.
- Gold family + dial (Full/Subtle/System via accentDynamic :1578); Tokens.accentStyle read in 14 files. goldCTA #815E0E deepened gold for WHITE ink; inkOnGold = .black.
- Mac-only instruments: ringConnected, failure, caution, success, warningText, railDormant, faderThumb, faderRim, meterTrack, dotSocket, feedPill*, scope×3, iconWellBadge×2, permission×5 + bluetoothBrand, stage×9. System aliases: accent, warning(.systemOrange), info(.systemBlue), destructive(.systemRed), engagedChrome(=label), separator etc.
- Type: 16 Tokens.Font cases, all SF 10–24pt; keycap monospaced; microLabel 10pt. No ClashDisplay. 10 bare systemFont(ofSize:) literals outside Tokens.swift.
- Shapes: TWELVE distinct radii (Tokens.Layout 12/11/10 + PopoverColumnGrid 1/2.5/4/5/5/6/7/7/12 + view literals).
- Spacing: leadingInset 14, bodyRowHeight 42, width 653, sidebar 210. No hit-target token.
- Depth: flat + hairlines, BUT five files draw CALayer shadow BLOOMS: RouteArmedDotView:137, HaloRingView:389, BusRailOverlayView:621/733, AlignmentStageView:1666, DemoPaneView:2422.

## Token map (Mac → iOS) — abbreviated; counts = src/tests
- canvas 10/11 → adopt #0A0A0C/#FAFAFB. canvasHi 1/1 → RETIRE (flat). panel 19/23, raised 14/24, well 7/10 → adopt. iconSeatFill 3/3 → raised. hairline 25/8 → adopt (+Rule 5 never on raised). containerEdge 5/3 → adopt, dark gets OWN value #3D4247. ADD rim #6B767D/#66717A. sidebarWarmTint 2/2 → RETIRE → panel.
- label 42/3 → adopt authored warm #F5EFE4/#201D1A (conflicts GroupsWindowTextColorLockTests). secondaryLabel 104/21 + inkSecondary 18/3 → label2. tertiaryLabel 18/1 + inkTertiary 18/7 → label3. ADD labelCool/labelCool2, liveRow/liveRaised.
- gold 28/23 adopt; ADD goldText, emberText. ember, glow adopt. goldCTA 3/2 → OPEN. inkOnGold → inkOnFill #171104.
- ringConnected 7/8 → RETIRE; ADD ring #7FB4C4/#2C6E86. failure → fail hex. caution 2/6 → RETIRE (gold ceiling). success 2/2 → RETIRE (gold checkmark). warningText 8/3 → label2 + fail glyph. warning/info/destructive/accent → RETIRE (system colour ban).
- engagedChrome 18/7 KEEP. railDormant KEEP retune cool. faderThumb/faderRim → raised/rim. meterTrack → meter. dotSocket → socket. feedPillFill/Text → RETIRE. scope×3, iconWellBadge, permission×5+BT, stage, fuseWhite KEEP. syncSignal → wireCore rename. partySignal → party; partySignalDeep → partyRampDeep (identical hex). plateRim → rim. AppKit chrome aliases keep.

## Where it breaks iOS rules
- Rule 1 temperature: BOTH ladders warm so warm means nothing; no cool ink.
- Light flat ground: Mac light stepped (raised, well, iconSeatFill, sidebarWarmTint).
- Rule 5 hairline-never-on-raised: MembershipWellContrastTests:188-202 asserts the OPPOSITE (≥1.25 on raised); iOS dark pair fails by design (1.154).
- Text/Graphic Gold Split: one gold used as text in 28 sites; no goldText/emberText.
- System colour ban: accent/warning/info/destructive.
- No third banner hue: caution = the amber iOS removed.
- Green rule: success on checkmarks.
- cta-gold: iOS gold fill + #171104 ink; Mac deep gold + white.
- One Shadow / never a bloom: three instrument views draw blooms.
- Three radii: Mac has 12.
- One Case "no monospaced design": keycap font.
- Words Scale: 10 bare size literals set words.
- Micro Label 11pt floor: Mac 10pt (Alec §3.5 no-reflow ruling).
- Rule 2: Follow-system dial paints audio state in macOS accent (blue can own "carrying audio").

## Worth keeping
- Four-hex Increase Contrast resolution (AGENTS.md house rule 3).
- engagedChrome + graded alphas (pointer states).
- Permission hues + bluetoothBrand (measured ≥3.85:1 on every iOS ground).
- Scope/stage/icon-badge fixed-dark blocks (= lampWell principle).
- Accent dial Full/Subtle (iOS DEFERRED it, not rejected; WarmSignal.swift:60). Follow-system does NOT survive.
- microLabel 10pt (platform; 11pt reflows every row).
- SurfaceLayout/PopoverColumnGrid geometry (42pt pointer rows).
- spineTone.

## Options
### A: Full adoption — viable, NOT recommended, Effort XL
- Re-author to iOS name set; retire ~19 tokens (~210 call sites); delete dial entirely (14 files, 8 suites ≈90 tests) + Appearance accent section + AppSettings.accentStyle; WarmCanvasView flat; radii → 3 (proposed Mac 6/10/12 + capsules); remove blooms.
- Spends a lot deleting dial + goldCTA before Alec has ruled.
### B: iOS base + Mac extension block, dial kept whole — viable, Effort L
- Same base; "Mac extension" MARK block keeps permission hues, engagedChrome, scope/stage/badge, spineTone, 3-column dial untouched.
- Ships a known breach: Follow-system paints audio in controlAccentColor.
### C: iOS base + Mac extension, dial reduced to Full/Subtle — RECOMMENDED, Effort L
- B + delete .systemAccent case (AccentStyle, systemAccentColor(in:scale:) :1602, branches :1591/:1650, one radio). Subtle columns stay. Merge ink pairs into label2/label3; add labelCool/labelCool2 + liveRow/liveRaised. Retire substitutable tokens except goldCTA (open).
- Migration: users on Follow-system fall back to .fullGold in AppSettings.accentStyle getter.
- Light ladder (all options): canvas=panel=raised #FAFAFB, well #E9EAEC, hairline #CBCED4, containerEdge #AEB3BB, rim #66717A. Dark: #0A0A0C/#15171A/#1F232A/#050507, hairline #2A2E33, containerEdge #3D4247, rim #6B767D. ~40 IC hexes to author.
- Measured: Mac light gold #9E761D on iOS well 3.45:1 ok; ringConnected 2.71 FAIL; faderRim 2.69 FAIL; dark faderRim on iOS raised 2.53 FAIL; dark goldCTA on raised 2.66 FAIL. iOS well vs light ground 1.154 clears Mac's 1.15 control floor by 0.004.

## Open questions
1. Gold CTA ink: adopt iOS gold + #171104, or keep goldCTA deep-gold + white (Alec rejected mid-gold+black live 2026-08-11, Tokens.swift:766)?
2. Does DARK go cool too (#0A0A0C)? Rule 1 needs it or warm live row means nothing. PRODUCT.md:90 commits "warm near-black ground".
3. Accent dial: Full/Subtle (C), whole (B), gone (A).
4. ClashDisplay on Mac for "Welcome to Audiout" on gate?
5. Increase Contrast: author ~40 IC hexes (assume keep) or drop IC to match iOS?

## Tests (certain break)
MembershipWellContrastTests(13), TokenContrastMatrixTests(5), OnboardingPermissionColorTests(15), PreviewPaletteTokenPinTests(2; + 7 raw NSColor literals in AppearanceSettingsViewController:329-347), SettingsAccentAndHintsTests(15), RingRailToneLockTests(3), RailConnectPulseTests(26, accentStyle), GroupsWindowTextColorLockTests(11), NoteBannerColorTests(7), AlignmentTokenContrastTests(7), EQResponseCurveTests(18, 1 ref), AppTetherColorTests.
Rename-only: ~18 more suites. window-snapshot goldens diverge, must not regenerate.

## Files touched
Tokens.swift, PopoverColumnGrid, WarmCanvasView, SidebarWarmSurfaceView, SharedUI/AGENTS.md, AppSettings.swift, AppDelegate.swift, AppearanceSettingsViewController, 11 SharedUI views, 3 PopoverUI, 6 OnboardingUI, 4 WindowUI, every retired-token consumer, tests above, root AGENTS.md:283-287, PRODUCT.md:90-95, docs/FIGMA-DESIGN-SYSTEM.md.
