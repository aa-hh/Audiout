// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import AppKit
@testable import AudiouterPopoverUI
@testable import AudiouterSharedUI

/// V12 (raw-color elimination pass): `SilenceFallbackBannerView` and
/// `SystemAirPlayNoteBannerView` used to stamp `NSColor.systemOrange`/
/// `.systemBlue` directly instead of going through `Tokens.Color`. Both are
/// now `Tokens.Color.warning`/`.info` — semantic aliases of the same system
/// colors (declared like `Tokens.Color.warning`/`.destructive` immediately
/// above them in `Tokens.swift`, not the custom warm-palette hex literals),
/// so the RESOLVED pixel is unchanged by construction; these tests guard the
/// wiring (the right token, the right alpha, per severity tier) rather than
/// a colour delta that can't exist between an alias and the value it aliases.
@MainActor
@Suite struct NoteBannerColorTests {

    private func assertSameRGBA(_ a: NSColor?, _ b: NSColor, _ message: String) {
        guard let a = a?.usingColorSpace(.sRGB), let b = b.usingColorSpace(.sRGB) else {
            Issue.record("nil or non-convertible color: \(message)")
            return
        }
        #expect(abs(a.redComponent - b.redComponent) <= 0.004, "red: \(message)")
        #expect(abs(a.greenComponent - b.greenComponent) <= 0.004, "green: \(message)")
        #expect(abs(a.blueComponent - b.blueComponent) <= 0.004, "blue: \(message)")
        #expect(abs(a.alphaComponent - b.alphaComponent) <= 0.004, "alpha: \(message)")
    }

    // MARK: SilenceFallbackBannerView (V12a)

    @Test func silenceBannerUsesWarningTokenAtTheDocumentedAlphas() {
        let banner = SilenceFallbackBannerView(text: "Playing on this Mac", maxTextWidth: 200)
        assertSameRGBA(banner.test_backgroundColor, Tokens.Color.warning.withAlphaComponent(0.14), "background")
        assertSameRGBA(banner.test_borderColor, Tokens.Color.warning.withAlphaComponent(0.40), "border")
    }

    // MARK: SystemAirPlayNoteBannerView (V12b)

    @Test func infoTierUsesTheNewInfoTokenAtTheDocumentedAlphas() {
        let banner = SystemAirPlayNoteBannerView(text: "Also playing over AirPlay", maxTextWidth: 200, severity: .info)
        assertSameRGBA(banner.test_backgroundColor, Tokens.Color.info.withAlphaComponent(0.12), "background")
        assertSameRGBA(banner.test_borderColor, Tokens.Color.info.withAlphaComponent(0.35), "border")
    }

    @Test func warningTierUsesTheWarningTokenAtTheDocumentedAlphas() {
        let banner = SystemAirPlayNoteBannerView(text: "Routing is blocked", maxTextWidth: 200, severity: .warning)
        assertSameRGBA(banner.test_backgroundColor, Tokens.Color.warning.withAlphaComponent(0.14), "background")
        assertSameRGBA(banner.test_borderColor, Tokens.Color.warning.withAlphaComponent(0.40), "border")
    }

    /// A real, non-vacuous guard the alias approach still needs: `.info` and
    /// `.warning` must stay two genuinely distinct tints (this WOULD fail if
    /// `Tokens.Color.info` were ever accidentally declared to forward to
    /// `.warning`, or the two severities collapsed onto the same alpha pair).
    @Test func infoAndWarningTiersRenderDifferentBackgrounds() {
        let info = SystemAirPlayNoteBannerView(text: "Note", maxTextWidth: 200, severity: .info)
        let warning = SystemAirPlayNoteBannerView(text: "Note", maxTextWidth: 200, severity: .warning)
        guard let infoColor = info.test_backgroundColor?.usingColorSpace(.sRGB),
              let warningColor = warning.test_backgroundColor?.usingColorSpace(.sRGB) else {
            Issue.record("nil or non-convertible background color")
            return
        }
        let differs = abs(infoColor.redComponent - warningColor.redComponent) > 0.02
            || abs(infoColor.greenComponent - warningColor.greenComponent) > 0.02
            || abs(infoColor.blueComponent - warningColor.blueComponent) > 0.02
        #expect(differs, "the info and warning tiers must render visibly different backgrounds")
    }

    /// `updateLayer()` must re-stamp from the SAME live token, not a value
    /// captured only at init — construction alone already exercises `init`'s
    /// stamp, so this drives the update path explicitly to prove it agrees.
    @Test func updateLayerReStampsFromTheSameToken() {
        let banner = SilenceFallbackBannerView(text: "Playing on this Mac", maxTextWidth: 200)
        banner.updateLayer()
        assertSameRGBA(banner.test_backgroundColor, Tokens.Color.warning.withAlphaComponent(0.14), "background after updateLayer")
        assertSameRGBA(banner.test_borderColor, Tokens.Color.warning.withAlphaComponent(0.40), "border after updateLayer")
    }
}
