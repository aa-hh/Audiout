// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import AppKit
@testable import AudioutPopoverUI
@testable import AudioutSharedUI

/// Both banners wear the one Status Banner recipe: the tier's token at 12 %
/// on the control radius with no border — `Tokens.Color.failure` for a real
/// problem (the silence banner and the note banner's `.warning` tier),
/// `.ring` for a note (`.info`). These tests guard the WIRING (the right
/// token, the right alpha, per severity tier), not a particular hue.
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

    @Test func silenceBannerIsFailureAtTwelvePercent() {
        let banner = SilenceFallbackBannerView(text: "Playing on this Mac", maxTextWidth: 200)
        assertSameRGBA(banner.test_backgroundColor, Tokens.Color.failure.withAlphaComponent(0.12), "background")
    }

    // MARK: SystemAirPlayNoteBannerView (V12b)

    @Test func noteTierIsRingAtTwelvePercent() {
        let banner = SystemAirPlayNoteBannerView(text: "Also playing over AirPlay", maxTextWidth: 200, severity: .info)
        assertSameRGBA(banner.test_backgroundColor, Tokens.Color.ring.withAlphaComponent(0.12), "background")
    }

    @Test func warningTierIsFailureAtTwelvePercent() {
        let banner = SystemAirPlayNoteBannerView(text: "Routing is blocked", maxTextWidth: 200, severity: .warning)
        assertSameRGBA(banner.test_backgroundColor, Tokens.Color.failure.withAlphaComponent(0.12), "background")
    }

    /// A real, non-vacuous guard: the note tier (`ring`) and the problem tier
    /// (`failure`) must stay two genuinely distinct tints — this WOULD fail if
    /// the two severities ever collapsed onto one token.
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
        assertSameRGBA(banner.test_backgroundColor, Tokens.Color.failure.withAlphaComponent(0.12),
                       "background after updateLayer")
    }

    /// `wantsUpdateLayer` is what makes the re-stamp above run at all on a live
    /// appearance switch: without it AppKit takes the `draw(_:)` path and
    /// `updateLayer()` is never called, so the banner keeps its build-time
    /// colours through a light/dark flip.
    @Test func bothBannersOptIntoTheUpdateLayerPath() {
        #expect(SilenceFallbackBannerView(text: "Playing on this Mac", maxTextWidth: 200)
            .wantsUpdateLayer)
        #expect(SystemAirPlayNoteBannerView(text: "Note", maxTextWidth: 200).wantsUpdateLayer)
    }

    /// A banner is an inset CONTROL-sized rect, not a row or a panel, and it
    /// carries no border — the fill alone separates it from the canvas.
    @Test func bannersWearTheControlRadiusWithNoBorder() {
        let silence = SilenceFallbackBannerView(text: "Playing on this Mac", maxTextWidth: 200)
        let note = SystemAirPlayNoteBannerView(text: "Note", maxTextWidth: 200)
        #expect(silence.layer?.cornerRadius == Tokens.Layout.Radius.control)
        #expect(silence.layer?.borderWidth == 0)
        #expect(note.layer?.cornerRadius == Tokens.Layout.Radius.control)
        #expect(note.layer?.borderWidth == 0)
    }

    /// The silence banner is no longer a dead end: given an action it renders a
    /// real button and dispatches through it.
    @Test func theSilenceBannerRendersAndFiresItsAction() {
        let plain = SilenceFallbackBannerView(text: "Playing on this Mac", maxTextWidth: 200)
        #expect(!plain.test_hasActionButton, "no action, no button")

        var taps = 0
        let banner = SilenceFallbackBannerView(
            text: "Playing on this Mac",
            maxTextWidth: 200,
            action: .init(title: "Try again",
                          accessibilityLabel: "Try reconnecting to the unreachable speakers",
                          handler: { taps += 1 }))
        #expect(banner.test_hasActionButton)
        banner.test_tapActionButton()
        #expect(taps == 1)
    }
}
