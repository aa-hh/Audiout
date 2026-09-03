# Onboarding + licence gate (AudioutOnboardingUI) — scoping report

## What exists today
- Setup window fixed 820x560, two columns: 288pt spine + hero pane; both RoundedContainerView(panel fill, hairline border), spine radius 9, hero 12 (OnboardingViewController.swift:53-62,282,378).
- Spine = one grouped-inset container, six full-bleed hairline-separated rows (:270-300). Row: 24pt icon tile, bodyEmphasized title, 16pt marker slot, 3pt leading edge bar (SetupCardView.swift:172-200).
- Row state = FILL never stroke (:505-530): live=raised; broken=panel→failure 8% + red bar; browsing=panel→selectedContentBackground 16%. Ember edge bar retired 2026-08-13 (said the same thing twice).
- Six identity hues, GLYPH ONLY: permissionSystemAudio ~208°, LocalNetwork ~271°, RemoteControl ~320°, SpeakerSync ~23°, UsageStats ~160°, bluetoothBrand #0082FC. IconTileView fill/rim stay neutral in every state (OnboardingChrome.swift:252-320).
- Gold spent on ONE button per screen: ribbon primary goldCTA .large; Skip .small plain (SetupRibbonView.swift:485-498). Owner decision 2026-08-12 (AGENTS-HISTORY:272).
- One step on screen at a time already ("the spine selects, the hero shows"). Hero: display 20pt bold headline → why line → well preview frame → status → bottom bar.
- Completion checkmark = success green #5FC27E/#2C7A46 (SetupCardView.swift:311). Sixth row checklist glyph = gold.
- UsageStatsConsentCard = the ONE filled hue tile (permissionUsageStats fill, WHITE glyph, radius 13) on a 380pt panel card radius 12 (UsageStatsConsentCard.swift:64-77).
- Licence gate 560x440, 320pt column, displayLarge 24pt bold, one gold Register/Email-my-key (mode-exclusive), quiet links, plain Buy/Quit (LicenseGateViewController.swift:80-201,271-277).
- Gate emitter field reads AudioutField.defaults but HAND-AUTHORS its ramp by blending Mac tokens (EmitterFieldView.swift:500-527); stageScale=5 deviation (:139). Field CARRIES STATE: seven Scene cases driven by verdict (:57-72).
- Shadows only inside DemoPaneView (drawings of macOS's own windows).
- ClashDisplay: NOT in repo in any form; Package.swift:210 declares exactly one resource (hero SVG).

## Where it breaks iOS rules
- Six identity hues vs closed inventory (gold, green, magenta, ring, fail). Three collide by hue: SpeakerSync ~23° = iOS ember (audio state); UsageStats ~160° green = Rule 3 lamp-only; RemoteControl ~320° = party's neighbourhood.
- Filled hue tile with white ink (UsageStatsConsentCard) — breaks Rule 3, inkOnFill, AND the Mac's own Q3 "tile never colours" rule.
- Green checkmark for completion — iOS uses GOLD checkmark for this (MacBand, group editor).
- Gate field reports state; iOS "field marks nothing and reports no state".
- Ramp hand-authored; field.json "Chill out" ramp mid = #E8B84B exactly the shared dark gold. Comment at :522-524 notes near-match and blends anyway.
- Light raised is a real step (#F2F0EA vs #FBFBF9) asserted by OnboardingPermissionColorTests:387; iOS light is flat.
- No wordmark face (display = system 20pt bold; header draws BrandMark picture instead).
- Radius sprawl: 7, 9, 10, 12, 13 vs iOS 10/16/26.

## Worth keeping
- Gold-on-one-button as implemented (Alec 2026-08-12) — nothing to migrate.
- raised as live-row fill + the light raised step that makes it possible (flat light would force the retired ember bar back).
- Neutral IconTileView fill + hairline rim (= iOS AppGlyph construction).
- Buy / Lost-key / Quit on the gate (App Store 3.1.3(f) ban doesn't port; Mac sells direct).
- DemoPaneView shadows/system colours (draws macOS's windows).
- permissionDynamic resolver (routing identities through accent collapses them).

## Options
### A: Rule compliance without touching hues — RECOMMENDED, Effort S
- Gate ramp → AudioutField.ramps["Chill out"] (delete blend block). Checkmark success→gold (SetupCardView:311, SetupCheckRowView). Consent tile → IconTileView (neutral raised + hairline, glyph tinted), card → containerEdge at 16pt. Collapse radii to 10/16.
- Light: hybrid — keep raised step; cool hues if token slice lands there.
- Risk: OnboardingPermissionColorTests.successClearsTheUIFloor:368 goes dead; EmitterFieldTests survive; 26 onboarding-snapshot fixtures re-render (no golden compare, no test break).
- Deps: gold/success decision; raised light step.
### B: A + reduce hue family — viable, NEEDS RULING, Effort M
- Four permission glyph tints → secondaryLabel; keep bluetoothBrand only (official mark). Delete permission* cases + permissionDynamic (~200 lines).
- RE-LITIGATES Alec's decision: commit 85c2052 retired hues to grey and the colour-return pass restored them on purpose (Tokens.swift:950-963). ~7 tests in OnboardingPermissionColorTests die.
### C: Rebuild setup as one junction at a time — NOT recommended, Effort XL
- Spine goes; each step full-window; ~4000 view lines + most of OnboardingUITests (2660) turn over. Spine browse path has no junction equivalent. A product change wearing a restyle's clothes.

## Open questions
1. Permission hues: keep all six (A) / bluetoothBrand only (B) / retire all? Mac arrived here by Alec reversing a grey pass.
2. Six-step checklist → one junction at a time (hide the sequence) or keep visible sequence with one live action (Mac already holds)? iOS junctions are alternatives; Mac steps are a sequence.
3. Buy a display face (ClashDisplay)? Recommendation HOLD — no Mac surface where the name stands alone; font licensing + Package.swift resource + ATSApplicationFontsPath for one label.
4. Gate field keeps its seven-scene engine? Code docs (LicenseGateViewController.swift:11-17): the field is the ONLY verdict channel beyond one gutter line. Keeping = Mac gate field is explicitly a different component.

## Files touched
OnboardingUI: OnboardingViewController, OnboardingWindowController, OnboardingChrome, SetupCardView, SetupCheckRowView, SetupRibbonView, UsageStatsConsentCard, LicenseGateViewController, EmitterFieldView, DemoPaneView, AGENTS.md, AGENTS-HISTORY.md. SharedUI/Tokens.swift. Tests: OnboardingPermissionColorTests, OnboardingUITests, SetupUsageStatsTests, LicenseGateTests, EmitterFieldTests. onboarding-snapshot/main.swift; dev/notes/onboarding-snapshots/ (26 PNG, re-render).
Executor note: licence gate has NO snapshot harness. Pinned geometry: LicenseGateTests:474, EmitterFieldTests:89,105,123,138.
