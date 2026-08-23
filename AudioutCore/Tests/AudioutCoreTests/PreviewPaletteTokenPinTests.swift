// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import AppKit
@testable import AudioutCore
@testable import AudioutSettingsUI
@testable import AudioutSharedUI

/// V5 (raw-color elimination pass): the Appearance pane's theme-preview
/// tiles (`ThemeTileButton.WarmPreviewPalette`) paint a FIXED, non-adaptive
/// palette on purpose — a "Dark" tile must render dark even while the app
/// itself is in light mode (the type's own doc comment), so it can't simply
/// read the live, appearance-resolving `Tokens.Color` cases at draw time. It
/// keeps its own literal mirrors instead.
///
/// That split already drifted once, silently: the dark `well` literal
/// (`0x2B2620`) was the pre-fader-legibility-retune spec hex, while
/// `Tokens.Color.well`'s dark case had since moved to `0x100D0A` — the tile
/// depicted a superseded product state with no warning. This suite pins
/// every preview literal that has a real `Tokens.Color` counterpart
/// (`canvas`/`well`/`gold`/`ember`) against that token's own resolved value,
/// in both appearances, so the next re-tune fails a test instead of aging
/// silently. `name`/`nameDim`/`chrome`/`stroke` have no token counterpart
/// (mock window chrome, or the spec's unaliased `text`/`text-3`) and stay
/// out of scope.
///
/// Nested in `SerializedSharedState` for the same reason
/// `OnboardingPermissionColorTests`/`RingRailToneLockTests` are: `gold`/
/// `ember` are accent-dial-remapped (`Tokens.accentStyle`, process-global),
/// and a concurrent dial write from another suite would race these reads.
extension SerializedSharedState {

@MainActor
@Suite final class PreviewPaletteTokenPinTests {

    init() { Tokens.accentStyle = .fullGold }
    deinit { Tokens.accentStyle = .fullGold }

    /// Force-resolves a dynamic `Tokens.Color` under a specific appearance —
    /// the pattern `OnboardingPermissionColorTests`/`MembershipWellContrastTests`
    /// already use for this token module.
    private func resolved(_ color: NSColor, appearanceName: NSAppearance.Name) -> NSColor {
        var result = color
        NSAppearance(named: appearanceName)?.performAsCurrentDrawingAppearance {
            result = color.usingColorSpace(.sRGB) ?? color
        }
        return result
    }

    private func assertSameRGB(_ a: NSColor, _ b: NSColor, _ message: String) {
        guard let a = a.usingColorSpace(.sRGB), let b = b.usingColorSpace(.sRGB) else {
            Issue.record("non-convertible color: \(message)")
            return
        }
        #expect(abs(a.redComponent - b.redComponent) <= 0.02, "red: \(message)")
        #expect(abs(a.greenComponent - b.greenComponent) <= 0.02, "green: \(message)")
        #expect(abs(a.blueComponent - b.blueComponent) <= 0.02, "blue: \(message)")
    }

    @Test func darkPreviewLiteralsMatchTheirTokens() {
        let appearance: NSAppearance.Name = .darkAqua
        assertSameRGB(ThemeTileButton.test_previewPaletteColor(dark: true, field: .canvas),
                     resolved(Tokens.Color.canvas, appearanceName: appearance), "canvas (dark)")
        assertSameRGB(ThemeTileButton.test_previewPaletteColor(dark: true, field: .well),
                     resolved(Tokens.Color.well, appearanceName: appearance), "well (dark) — the exact drift this suite guards")
        assertSameRGB(ThemeTileButton.test_previewPaletteColor(dark: true, field: .gold),
                     resolved(Tokens.Color.gold, appearanceName: appearance), "gold (dark)")
        assertSameRGB(ThemeTileButton.test_previewPaletteColor(dark: true, field: .ember),
                     resolved(Tokens.Color.ember, appearanceName: appearance), "ember (dark)")
    }

    @Test func lightPreviewLiteralsMatchTheirTokens() {
        let appearance: NSAppearance.Name = .aqua
        assertSameRGB(ThemeTileButton.test_previewPaletteColor(dark: false, field: .canvas),
                     resolved(Tokens.Color.canvas, appearanceName: appearance), "canvas (light)")
        assertSameRGB(ThemeTileButton.test_previewPaletteColor(dark: false, field: .well),
                     resolved(Tokens.Color.well, appearanceName: appearance), "well (light)")
        assertSameRGB(ThemeTileButton.test_previewPaletteColor(dark: false, field: .gold),
                     resolved(Tokens.Color.gold, appearanceName: appearance), "gold (light)")
        assertSameRGB(ThemeTileButton.test_previewPaletteColor(dark: false, field: .ember),
                     resolved(Tokens.Color.ember, appearanceName: appearance), "ember (light)")
    }
}

} // extension SerializedSharedState
