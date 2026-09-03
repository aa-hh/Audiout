# Settings (AudioutSettingsUI) — scoping report

Premise correction: Settings is NOT a standalone window. It is a screen inside the one surface (AppSurfaceController), sharing the Groups screen's sidebar geometry (210pt sidebar, 443pt pane). Only About keeps its own window.

## What exists today
- Only Warm Signal chrome = two fills: WarmPanelView (panel) at SettingsRootViewController.swift:168, SidebarWarmSurfaceView (sidebarWarmTint) at SettingsSidebarViewController.swift:45.
- Everything else stock AppKit (.rounded bezels, NSSwitch, NSSlider, NSPopUpButton, radios). No gold in panes (AGENTS.md rule).
- Two hand-drawn: ReadoutWellView (well fill, 5pt radius) SettingsForm.swift:86-105; BorderedListView (separator stroke, 6pt) AudioSettingsViewController.swift:1110-1119.
- Appearance pane: three 100x84 ThemeTileButtons drawn from ABSOLUTE sRGB literals mirroring warm palette (AppearanceSettingsViewController.swift:305-350), + accent dial radios Full/Subtle/System (:88-125).
- About: standalone 460pt window, NSVisualEffectView; BrandMark.image 32x32 + app name in Tokens.Font.heading (AboutView.swift:156-189).
- Licence sheet: 320pt stock controls; Register is plain .rounded bezel (LicenseSheetViewController.swift:121).
- Mac ships NO font asset (zero .otf/.ttf). ClashDisplay lives only in audiout-remote.

## Where it breaks iOS rules
- iOS Layout: "Settings is stock grouped List, no Warm Signal" (DESIGN.md:527-531, Don't :1190) — violated by the two fills. BUT the iOS rule's reason ("no decision left on that tab") does not transfer: Mac Settings carries login item, telemetry, licence, excluded apps, buffer, theme, accent.
- iOS light flat ground #FAFAFB / well #E9EAEC vs Mac warm 0xFBFBF9 / 0xE2DFD3 / sidebarWarmTint 0xF5F4ED — lands in exactly three fills here.
- Name Only Rule: product name ClashDisplay 22pt on About; Mac About uses system heading.
- iOS "follows the system with nothing stored"; Mac stores theme + accentStyle.
- GoldCTALabel: licence sheet Register is plain bezel while the licence gate already uses ProminentButton + goldCTA (LicenseGateViewController.swift:271-273). Same action, two treatments.

## Worth keeping
- Warm panel + warm sidebar wash: structural, since Settings shares the surface with Groups. Going stock leaves one screen unlike its sibling behind a shared window edge.
- ReadoutWellView, BorderedListView (no stock equivalent; already aligned with iOS well/hairline idiom).
- Stock controls everywhere (already the iOS doctrine).
- Theme tiles' absolute-sRGB rule (a tile depicts an appearance; live tokens would lie). Literals re-derive when light moves.

## Options
### A: Keep surface treatment, re-tone light only — RECOMMENDED, Effort S
- Zero UI edits; light shift arrives via token agent (panel, well, sidebarWarmTint). Only follow-on: WarmPreviewPalette.light literals (AppearanceSettingsViewController.swift:339-350), forced by PreviewPaletteTokenPinTests.
- sidebarWarmTint needs a cool Mac-only derivation (iOS has no sidebar) — token agent's call.
- Risk: PreviewPaletteTokenPinTests fires; settings-snapshot goldens change in light, NOT regenerated on macOS 27 — inspect by eye.
### B: Go stock (iOS doctrine) — NOT recommended, Effort M
- Replace WarmPanelView with NSVisualEffectView/windowBackground; drop SidebarWarmSurfaceView. Re-opens a documented dark-mode illegibility regression (AGENTS.md). Kills SettingsRootViewControllerTests.backgroundIsTheUnifiedWarmPanelCanvas (:90), orphans SidebarWarmSurfaceTests.
### C: Stock panes on warm sidebar (hybrid) — viable but weaker, Effort S
- Adds a visible seam at the split divider in light mode.

## Appearance tab per accent-dial outcome
- Dial survives: unchanged; only gold/ember light literals re-derive.
- Dial dropped: delete makeAccentSection (:88-125) + accentOrder/accentRadios/applyAccentSelection/accentTapped/onAccentChanged + 3 test_ hooks (:219-243). Cascade OUTSIDE this slice is the bulk: AccentStyle (AppSettings.swift:26-29), Tokens.accentStyle + remap switches (Tokens.swift:50-73,1585,1649), accentStyleDidChangeNotification, SerializedSharedState. Tests: SettingsAccentAndHintsTests (10), PreviewPaletteTokenPinTests justification. Effort L, mostly outside Settings.
- Theme choice also goes (full iOS parity): Appearance pane empty → delete ThemeTileButton (~200 lines), AppSettings.theme, AppearanceTheme, sidebar row, 2 of 6 snapshot PNGs. RECOMMEND AGAINST; flag as fork — appearance override is a normal macOS affordance (doc comment cites System Settings › Appearance and SoundSource).

## About: display face
- Hybrid: keep Tokens.Font.heading unless ClashDisplay is bundled for another Mac surface anyway (licence gate / onboarding). Then adopt in the same pass, one line at AboutView.swift:172. BrandMark.swift:28-55 documents the Bundle.module trap for resources.

## Licence sheet
- GoldCTALabel: ADOPT — make sheet's Register the ProminentButton+goldCTA. Effort S. Executor must be told the "no gold in panes" AGENTS.md rule is being read narrowly (a sheet is not a pane; gate precedent exists).
- Locked State copy rules ("no price, no URL, no button"): DO NOT adopt — justified by App Store Guideline 3.1.3(f); Mac is direct-sale via Paddle and must sell. Buy buttons stay. CONFLICT named, not resolved.

## Tests
- PreviewPaletteTokenPinTests.swift:61-83 (fires on any light move)
- SettingsRootViewControllerTests.swift:90 (B/C only), :461-537 geometry (no option moves it), :623-671 theme tiles (die with tiles)
- SettingsAccentAndHintsTests.swift:38-139 (die with dial)
- SidebarWarmSurfaceTests (B orphans)
- AboutSectionTests.swift:94,177
- settings-snapshot: six PNGs in dev/notes/settings-snapshots/, three change in light; inspect by eye, never re-baseline.

## Open questions
1. If accent dial goes, does the THEME picker go too (full parity) or does Mac keep an appearance override?
2. Is ClashDisplay being bundled for the Mac at all? If yes (gate/onboarding), About adopts in the same pass.

## Files touched
AudioutSettingsUI/{SettingsRootViewController,SettingsSidebarViewController,AppearanceSettingsViewController,AboutView,LicenseSheetViewController,SettingsForm,AudioSettingsViewController}.swift, AudioutSettingsUI/AGENTS.md, AudioutSharedUI/{Tokens,WarmPanelView,SidebarWarmSurfaceView}.swift, AudioutCore/AppSettings.swift, tests above, dev/notes/settings-snapshots/ (inspect only).
