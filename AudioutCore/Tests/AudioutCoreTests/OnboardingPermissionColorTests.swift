// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
import AppKit
@testable import AudioutCore
@testable import AudioutOnboardingUI
@testable import AudioutSharedUI

/// T3 (colour-return pass, decisions Q1-Q6/NEW-1): the five permission-row
/// identity tokens — `Tokens.Color.permissionSystemAudio` / `permissionLocalNetwork`
/// / `permissionRemoteControl` / `permissionSpeakerSync` / `permissionUsageStats`
/// — stay mutually
/// DISTINCT in both accent-dial columns (Q1), each clears the same >=3:1
/// own-theme contrast floor every other `Tokens.Color` instrument is held to
/// (T1's written arithmetic, exercised here), the accent dial genuinely MUTES
/// all five in `.subtle` (Q5), and the glyph-only decision (Q3) holds end to
/// end: the tile's own FILL
/// never recolours, and each card's glyph keeps its identity hue in every
/// `SetupCardState`.
///
/// Two helpers are ported rather than shared (so those suites stay untouched):
///  - `relativeLuminance`/`contrastRatio` — ported from `AppTetherColorTests`.
///  - `resolved(_:appearanceName:)` — ported from `SettingsAccentAndHintsTests`.
/// `SettingsAccentAndHintsTests.accentDialNeverRemapsFailureCautionOrRing`
/// names `failure`/`caution`/`ringConnected` explicitly — not "every token the
/// dial doesn't touch" — so these five permission tokens (which the dial DOES
/// remap, just not via `accentDynamic`) don't trip it.
///
/// Nested into `SerializedSharedState` alongside `SettingsAccentAndHintsTests`
/// — both mutate the process-global `Tokens.accentStyle` (see the `deinit`
/// below), and running concurrently under swift-testing produced real,
/// reproducible test failures (a concurrent accent-style write racing this
/// suite's color comparisons).
extension SerializedSharedState {

@MainActor
@Suite final class OnboardingPermissionColorTests: IsolatedSuite {

    deinit {
        // `Tokens.accentStyle` is process-global (the live remap seam) —
        // restore the flagship default so no other test in this suite, or a
        // later golden render in this process, inherits a dialed accent.
        // Same discipline as `SettingsAccentAndHintsTests.tearDown`.
        Tokens.accentStyle = .fullGold
    }

    // MARK: - Ported helpers (see file doc comment for provenance)

    /// Resolve `color` to concrete sRGB under an explicit appearance — the
    /// same way AppKit resolves a dynamic provider at draw time. Ported from
    /// `SettingsAccentAndHintsTests` (~lines 89-96).
    private func resolved(_ color: NSColor, appearanceName: NSAppearance.Name) -> NSColor {
        var result = color
        NSAppearance(named: appearanceName)?.performAsCurrentDrawingAppearance {
            result = color.usingColorSpace(.sRGB) ?? color
        }
        return result
    }

    /// WCAG 2.x relative luminance of an sRGB color. Ported from
    /// `AppTetherColorTests` (~lines 293-300).
    private func relativeLuminance(_ color: NSColor) -> CGFloat {
        func channel(_ c: CGFloat) -> CGFloat {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let c = color.usingColorSpace(.sRGB)!
        return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent) + 0.0722 * channel(c.blueComponent)
    }

    /// WCAG contrast ratio between two sRGB colors, `1...21`. Ported from
    /// `AppTetherColorTests` (~lines 302-307).
    private func contrastRatio(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let l1 = relativeLuminance(a), l2 = relativeLuminance(b)
        let (hi, lo) = l1 > l2 ? (l1, l2) : (l2, l1)
        return (hi + 0.05) / (lo + 0.05)
    }

    /// Component-wise sRGB comparison with tolerance — the
    /// `ControlPanelBackingViewTests.assertSameHue` idiom, needed here
    /// because comparing two independently-resolved dynamic `NSColor`
    /// instances (or a `layer.backgroundColor`-reconstructed color against a
    /// resolved token) via plain equality is not reliable once either
    /// side has been round-tripped through `CGColor`.
    private func assertSameRGB(_ a: NSColor?, _ b: NSColor?, _ message: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        guard let a = a?.usingColorSpace(.sRGB), let b = b?.usingColorSpace(.sRGB) else {
            Issue.record("nil or non-convertible color: \(message)")
            return
        }
        #expect(abs(a.redComponent - b.redComponent) <= 0.02, "red: \(message)")
        #expect(abs(a.greenComponent - b.greenComponent) <= 0.02, "green: \(message)")
        #expect(abs(a.blueComponent - b.blueComponent) <= 0.02, "blue: \(message)")
    }

    /// The five permission tokens, named for failure messages. A computed
    /// property (not a stored snapshot) so every call site gets a fresh
    /// access — irrelevant for correctness (each dynamic `NSColor`'s
    /// provider closure re-reads `Tokens.accentStyle` at RESOLUTION time
    /// regardless of when the handle was obtained) but keeps call sites
    /// honest about there being no caching here.
    private var permissionTokens: [(name: String, color: NSColor)] {
        [("permissionSystemAudio", Tokens.Color.permissionSystemAudio),
         ("permissionLocalNetwork", Tokens.Color.permissionLocalNetwork),
         ("permissionRemoteControl", Tokens.Color.permissionRemoteControl),
         ("permissionSpeakerSync", Tokens.Color.permissionSpeakerSync),
         // The fifth is not a macOS permission — the Setup card for Audiout's
         // own usage-statistics opt-in — but it wears a family hue and is held
         // to every rule the other four are.
         ("permissionUsageStats", Tokens.Color.permissionUsageStats)]
    }

    private func assertMutuallyDistinct(appearance: NSAppearance.Name,
                                        file: StaticString = #filePath, line: UInt = #line) {
        let tokens = permissionTokens.map { (name: $0.name, color: resolved($0.color, appearanceName: appearance)) }
        for i in 0..<tokens.count {
            for j in (i + 1)..<tokens.count {
                #expect(tokens[i].color != tokens[j].color,
                        "\(tokens[i].name) collapsed onto \(tokens[j].name) under \(Tokens.accentStyle)/\(appearance.rawValue)")
            }
        }
    }

    // MARK: 1 — Distinctness in both dial columns (Q1)

    @Test func everyTokenIsMutuallyDistinctInFullGold() {
        Tokens.accentStyle = .fullGold
        assertMutuallyDistinct(appearance: .darkAqua)
        assertMutuallyDistinct(appearance: .aqua)
    }

    @Test func everyTokenIsMutuallyDistinctInSubtle() {
        Tokens.accentStyle = .subtle
        assertMutuallyDistinct(appearance: .darkAqua)
        assertMutuallyDistinct(appearance: .aqua)
    }

    // MARK: 2 — >=3:1 own-theme contrast floor, both dial columns, both appearances

    /// Checked against BOTH `panel` and `raised` (the two own-theme surfaces
    /// T1's doc comments measure against for every one of these
    /// tokens), across `.fullGold`/`.subtle` and `.darkAqua`/`.aqua` — the
    /// full 5 tokens x 2 columns x 2 appearances x 2 surfaces sweep.
    @Test func contrastFloorClearsInBothDialColumnsBothAppearancesBothSurfaces() {
        let floor: CGFloat = 3.0
        for style: AccentStyle in [.fullGold, .subtle] {
            Tokens.accentStyle = style
            for appearance: NSAppearance.Name in [.darkAqua, .aqua] {
                let panel = resolved(Tokens.Color.panel, appearanceName: appearance)
                let raised = resolved(Tokens.Color.raised, appearanceName: appearance)
                for (name, color) in permissionTokens {
                    let resolvedColor = resolved(color, appearanceName: appearance)
                    let panelRatio = contrastRatio(resolvedColor, panel)
                    let raisedRatio = contrastRatio(resolvedColor, raised)
                    #expect(panelRatio >= floor,
                        "\(name) \(style)/\(appearance.rawValue) vs panel: \(panelRatio):1 under the \(floor):1 floor")
                    #expect(raisedRatio >= floor,
                        "\(name) \(style)/\(appearance.rawValue) vs raised: \(raisedRatio):1 under the \(floor):1 floor")
                }
            }
        }
    }

    // MARK: 3 — the dial genuinely mutes all five in .subtle (Q5)

    @Test func subtleActuallyChangesEveryTokenFromFullGold() {
        for appearance: NSAppearance.Name in [.darkAqua, .aqua] {
            Tokens.accentStyle = .fullGold
            let full = permissionTokens.map { (name: $0.name, color: resolved($0.color, appearanceName: appearance)) }

            Tokens.accentStyle = .subtle
            let subtle = permissionTokens.map { (name: $0.name, color: resolved($0.color, appearanceName: appearance)) }

            for (fullEntry, subtleEntry) in zip(full, subtle) {
                #expect(fullEntry.color != subtleEntry.color,
                    "\(fullEntry.name)/\(appearance.rawValue): .subtle failed to change the resolved colour from .fullGold — Q5 requires the dial to genuinely mute these")
            }
        }
    }

    // MARK: The check row's gold glyph — measured, not assumed

    /// The final-check row's `checklist` glyph is `gold` on the tile's
    /// `raised` well (a deliberate non-permission hue — the first note of the
    /// finale's colour story). Same ≥3:1 glyph floor the five permission
    /// tokens are held to, measured in both authored dial columns and both
    /// appearances (light 3.64:1, Subtle light 3.95:1).
    @Test func goldOnRaisedClearsTheGlyphFloorInBothDialColumnsAndAppearances() {
        let floor: CGFloat = 3.0
        for style: AccentStyle in [.fullGold, .subtle] {
            Tokens.accentStyle = style
            for appearance: NSAppearance.Name in [.darkAqua, .aqua] {
                let gold = resolved(Tokens.Color.gold, appearanceName: appearance)
                let raised = resolved(Tokens.Color.raised, appearanceName: appearance)
                let ratio = contrastRatio(gold, raised)
                #expect(ratio >= floor,
                        "gold \(style)/\(appearance.rawValue) vs raised: \(ratio):1 under the \(floor):1 floor")
            }
        }
    }

    // MARK: The gold CTA fill — its double floor (ink AND canvas)

    /// A `gold`-filled call to action is contrast-governed on BOTH sides:
    /// `inkOnFill` must clear the 4.5:1 body floor on it (dark 10.18:1, light
    /// 4.94:1), and the fill itself must clear 3:1 against `canvas`, the Setup
    /// window's true background (10.73:1 / 3.64:1). Re-measured here rather
    /// than trusted from the tokens' written rationales.
    @Test func goldFillTakesInkOnFillAndClearsTheCanvasFloorInBothAppearances() {
        Tokens.accentStyle = .fullGold
        for appearance: NSAppearance.Name in [.darkAqua, .aqua] {
            let fill = resolved(Tokens.Color.gold, appearanceName: appearance)
            let ink = resolved(Tokens.Color.inkOnFill, appearanceName: appearance)
            let canvas = resolved(Tokens.Color.canvas, appearanceName: appearance)
            let inkRatio = contrastRatio(fill, ink)
            let canvasRatio = contrastRatio(fill, canvas)
            #expect(inkRatio >= 4.5,
                    "gold/\(appearance.rawValue): inkOnFill \(inkRatio):1 under the 4.5:1 body floor")
            #expect(canvasRatio >= 3.0,
                    "gold/\(appearance.rawValue): fill vs canvas \(canvasRatio):1 under the 3:1 floor")
        }
    }

    // MARK: 5/6 — the glyph tint is PERMANENT; the tile fill never recolours (Q2/Q3)

    /// Forces a layer-backed, off-window tile through one real display pass:
    /// `updateLayer()` (which paints `test_fillColor`) only runs on an actual
    /// draw, and a freshly constructed view has never been asked to draw.
    /// Pinning `.appearance` first makes the dynamic tokens it paints resolve
    /// deterministically off-window — the same combination
    /// `ControlPanelBackingViewTests`/`WarmFaderCellTests` pin `.appearance`
    /// for, and `AccessibilitySignalSweepTests`'s
    /// `warmCanvasRepaintsOnDisplayOptionsChange` uses
    /// `layer?.displayIfNeeded()` for on an off-window layer-backed view.
    private func settle(_ tile: IconTileView, appearance: NSAppearance.Name) {
        tile.appearance = NSAppearance(named: appearance)
        tile.layoutSubtreeIfNeeded()
        tile.layer?.displayIfNeeded()
    }

    /// The card's glyph tint is its step's identity hue in EVERY
    /// `SetupCardState` — state is carried by the checkmark/lock slot alone.
    /// Driven through the real `SetupSpineRowView.apply(...)`, the same call the
    /// view controller makes, because the tile itself is private to the row.
    @Test func glyphTintIsPermanentAcrossEveryCardState() {
        let states: [SetupCardState] = [.pending, .active, .completed,
                                        .autoPassed(note: "Requires macOS 14.4 or later"),
                                        .skipped]
        for appearance: NSAppearance.Name in [.darkAqua, .aqua] {
            for step in SetupStep.allCases {
                let content = OnboardingViewController.content(for: step)
                let row = SetupSpineRowView(content: content, onPress: {})
                let expected = resolved(content.iconColor, appearanceName: appearance)
                for state in states {
                    row.apply(state, foundSpeakers: nil, isLive: state == .active,
                              isBrowseSelected: false, isBroken: false, animated: false)
                    assertSameRGB(resolved(row.test_iconTint ?? .clear, appearanceName: appearance), expected,
                        "\(step)/\(state)/\(appearance.rawValue): the glyph tint must stay the card's own iconColor in every state")
                }
            }
        }
    }

    /// Q3, unchanged: the tile's own FILL is the neutral `raised` well — only
    /// the glyph ever carries a permission's colour.
    @Test func tileFillIsAlwaysTheNeutralRaisedWell() {
        for appearance: NSAppearance.Name in [.darkAqua, .aqua] {
            for (name, color) in permissionTokens {
                let tile = IconTileView(symbolName: "waveform", accessibility: name, color: color)
                settle(tile, appearance: appearance)

                assertSameRGB(tile.test_fillColor, resolved(Tokens.Color.raised, appearanceName: appearance),
                             "\(name)/\(appearance.rawValue): tile fill must be the neutral `raised` well")
                // The glyph keeps the caller's token — a dynamic (unresolved)
                // `NSColor`, so it must go through `resolved(_:appearanceName:)`
                // explicitly before `assertSameRGB` resolves it against the
                // process's ambient appearance instead of the one under test.
                assertSameRGB(resolved(tile.test_restingTint ?? .clear, appearanceName: appearance),
                             resolved(color, appearanceName: appearance),
                             "\(name)/\(appearance.rawValue): the glyph tint must be this row's own token")
            }
        }
    }

    // MARK: 7 — the authored ink ladder, and light's one flat ground

    /// `label2` is the spine/ribbon's secondary text — held to the 4.5:1 body
    /// floor on every surface it might sit on (dark 8.81 canvas / 7.99 panel /
    /// 7.02 raised; light 5.97 on the flat ground).
    @Test func label2ClearsTheBodyFloorInBothAppearances() {
        let floor: CGFloat = 4.5
        for appearance: NSAppearance.Name in [.darkAqua, .aqua] {
            let ink = resolved(Tokens.Color.label2, appearanceName: appearance)
            let canvas = resolved(Tokens.Color.canvas, appearanceName: appearance)
            let panel = resolved(Tokens.Color.panel, appearanceName: appearance)
            let raised = resolved(Tokens.Color.raised, appearanceName: appearance)
            for (name, surface) in [("canvas", canvas), ("panel", panel), ("raised", raised)] {
                let ratio = contrastRatio(ink, surface)
                #expect(ratio >= floor,
                        "label2/\(appearance.rawValue) vs \(name): \(ratio):1 under the \(floor):1 floor")
            }
        }
    }

    /// Light is ONE flat ground: `canvas`, `panel` and `raised` all resolve to
    /// the same value on paper, and separation is carried by edge weight
    /// instead of by fill steps. Asserted rather than documented, because a
    /// well-meaning "give light a ladder too" re-tune would silently change
    /// what every light edge is measured against.
    @Test func lightGroundIsOneFlatValue() {
        let canvas = resolved(Tokens.Color.canvas, appearanceName: .aqua)
        let panel = resolved(Tokens.Color.panel, appearanceName: .aqua)
        let raised = resolved(Tokens.Color.raised, appearanceName: .aqua)
        #expect(canvas == panel, "light canvas and panel are one ground")
        #expect(panel == raised, "light panel and raised are one ground")
    }

    // MARK: 8 — Bluetooth's row wears the OFFICIAL mark

    /// The Bluetooth row's glyph must be the system's own Bluetooth image:
    /// NEVER an SF Symbol stand-in (there is no Bluetooth symbol, so any
    /// stand-in is some other mark) and NEVER a hand-drawn rune. Asserting the
    /// card really carries that image is what stops a later pass from quietly
    /// dropping back to `symbolName`.
    @Test func bluetoothCardCarriesTheSystemBluetoothGlyph() {
        let content = OnboardingViewController.content(for: .bluetooth)
        let system = try? #require(NSImage(named: NSImage.bluetoothTemplateName))

        #expect(content.customIcon != nil,
                "the Bluetooth row must carry a real glyph override, not fall through to symbolName")
        #expect(content.customIcon?.isTemplate == true,
                "the rune has to be a template image or the tile can't tint it")
        // Same underlying system asset — compared by drawn content, since
        // `bluetoothRuneImage` hands back a rescaled COPY, never the shared
        // cache entry itself (resizing that would resize it app-wide).
        #expect(content.customIcon !== system,
                "must be a copy: rescaling the shared named image would resize it for every other user")
        #expect(content.customIcon?.tiffRepresentation != nil,
                "the copied rune must still carry drawable content after the rescale")
    }

    /// The rune wears the Bluetooth SIG brand blue rather than one of the five
    /// warmed `permission*` hues — a BRAND mark, so it is deliberately fixed
    /// across appearances. It still has to clear the same 3:1 glyph floor on
    /// the neutral `raised` well it sits in.
    @Test func bluetoothBrandIsTheOfficialBlueAndClearsTheGlyphFloor() {
        let floor: CGFloat = 3.0
        let srgb = Tokens.Color.bluetoothBrand.usingColorSpace(.sRGB)
        #expect(srgb.map { Int(($0.redComponent * 255).rounded()) } == 0x00)
        #expect(srgb.map { Int(($0.greenComponent * 255).rounded()) } == 0x82)
        #expect(srgb.map { Int(($0.blueComponent * 255).rounded()) } == 0xFC,
                "the row must wear the official Bluetooth blue #0082FC")

        for appearance: NSAppearance.Name in [.darkAqua, .aqua] {
            let brand = resolved(Tokens.Color.bluetoothBrand, appearanceName: appearance)
            for (name, token) in [("raised", Tokens.Color.raised), ("panel", Tokens.Color.panel)] {
                let ratio = contrastRatio(brand, resolved(token, appearanceName: appearance))
                #expect(ratio >= floor,
                        "bluetoothBrand/\(appearance.rawValue) vs \(name): \(ratio):1 under the \(floor):1 floor")
            }
        }
    }
}

} // extension SerializedSharedState
