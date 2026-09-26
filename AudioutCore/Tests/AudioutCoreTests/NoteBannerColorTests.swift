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

    // MARK: Silence banner (warning tier) (V12a)

    @Test func silenceBannerIsFailureAtTwelvePercent() {
        let banner = SystemAirPlayNoteBannerView(text: "Playing on this Mac", maxTextWidth: 200, severity: .warning)
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
        let banner = SystemAirPlayNoteBannerView(text: "Playing on this Mac", maxTextWidth: 200, severity: .warning)
        banner.updateLayer()
        assertSameRGBA(banner.test_backgroundColor, Tokens.Color.failure.withAlphaComponent(0.12),
                       "background after updateLayer")
    }

    /// `wantsUpdateLayer` is what makes the re-stamp above run at all on a live
    /// appearance switch: without it AppKit takes the `draw(_:)` path and
    /// `updateLayer()` is never called, so the banner keeps its build-time
    /// colours through a light/dark flip.
    @Test func bothSeveritiesOptIntoTheUpdateLayerPath() {
        #expect(SystemAirPlayNoteBannerView(text: "Playing on this Mac", maxTextWidth: 200, severity: .warning)
            .wantsUpdateLayer)
        #expect(SystemAirPlayNoteBannerView(text: "Note", maxTextWidth: 200).wantsUpdateLayer)
    }

    /// A banner is an inset CONTROL-sized rect, not a row or a panel, and it
    /// carries no border — the fill alone separates it from the canvas. Checked
    /// at both severities: the tier changes the tint, never the shape.
    @Test func bothSeveritiesWearTheControlRadiusWithNoBorder() {
        let warning = SystemAirPlayNoteBannerView(text: "Playing on this Mac", maxTextWidth: 200, severity: .warning)
        let note = SystemAirPlayNoteBannerView(text: "Note", maxTextWidth: 200)
        #expect(warning.layer?.cornerRadius == Tokens.Layout.Radius.control)
        #expect(warning.layer?.borderWidth == 0)
        #expect(note.layer?.cornerRadius == Tokens.Layout.Radius.control)
        #expect(note.layer?.borderWidth == 0)
    }

    /// The silence banner is no longer a dead end: given an action it renders a
    /// real button and dispatches through it.
    @Test func theSilenceBannerRendersAndFiresItsAction() {
        let plain = SystemAirPlayNoteBannerView(text: "Playing on this Mac", maxTextWidth: 200, severity: .warning)
        #expect(!plain.test_hasActionButton, "no action, no button")

        var taps = 0
        let banner = SystemAirPlayNoteBannerView(
            text: "Playing on this Mac",
            maxTextWidth: 200,
            action: .init(title: "Try again",
                          accessibilityLabel: "Try reconnecting to the unreachable speakers",
                          handler: { taps += 1 }),
            severity: .warning)
        #expect(banner.test_hasActionButton)
        banner.test_tapActionButton()
        #expect(taps == 1)
    }

    /// Red if "I have a key" lost its underline (it would read as a label, not
    /// a link) or if the two controls stopped sharing the banner's centre line
    /// (they would sit at different heights on a wrapped note).
    @Test func aTextActionIsUnderlinedAndSharesTheBannersCentre() {
        var taps = 0
        let banner = SystemAirPlayNoteBannerView(
            text: "Your trial has ended. Audiout plays on one speaker at a time until you buy.",
            maxTextWidth: 400,
            action: .init(title: "Buy Audiout", accessibilityLabel: "Buy an Audiout license", handler: {}),
            textAction: .init(title: "I have a key", accessibilityLabel: "Enter a license key",
                              handler: { taps += 1 }))
        #expect(banner.test_hasTextAction)
        guard let link = banner.test_textActionButton, let button = banner.test_actionButton else {
            Issue.record("expected both controls")
            return
        }
        let underline = link.attributedTitle.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int
        #expect(underline == NSUnderlineStyle.single.rawValue, "the text action is underlined")

        banner.frame = NSRect(x: 0, y: 0, width: 600, height: 80)
        banner.layoutSubtreeIfNeeded()
        #expect(abs(link.frame.midY - banner.bounds.midY) <= 0.5, "text action centred on the banner")
        #expect(abs(button.frame.midY - banner.bounds.midY) <= 0.5, "button centred on the banner")
        #expect(link.frame.maxX <= button.frame.minX - 9.5, "the text action sits left of the button")

        banner.test_tapTextAction()
        #expect(taps == 1, "the text action dispatches its handler")
    }

    /// Red if the glyph went back to the label's first line (or any other
    /// line of its own) instead of the controls' centre: on a wrapped note the
    /// icon would sit above the buttons.
    @Test(arguments: [("Trial · 9 days left", false),
                      ("Your trial has ended. Audiout plays on one speaker at a time until you buy.", true)])
    func theIconSharesTheControlsCentre(text: String, wraps: Bool) {
        let banner = SystemAirPlayNoteBannerView(
            text: text,
            maxTextWidth: 360,
            action: .init(title: "Buy Audiout", accessibilityLabel: "Buy an Audiout license", handler: {}),
            textAction: .init(title: "I have a key", accessibilityLabel: "Enter a license key", handler: {}))
        guard let link = banner.test_textActionButton, let button = banner.test_actionButton else {
            Issue.record("expected both controls")
            return
        }
        banner.frame = NSRect(x: 0, y: 0, width: 400, height: banner.fittingSize.height)
        banner.layoutSubtreeIfNeeded()
        let lineHeight = banner.label.font.map { ceil($0.ascender - $0.descender + $0.leading) } ?? 16
        let labelHeight = banner.convert(banner.label.bounds, from: banner.label).height
        #expect((labelHeight > lineHeight * 1.5) == wraps, "the label wraps only in the long case")
        // Alignment rects: the visible glyph and bezel, not the padding
        // AppKit adds around a symbol image, which is uneven top and bottom.
        func visibleMidY(_ view: NSView) -> CGFloat {
            banner.convert(view.alignmentRect(forFrame: view.frame), from: view.superview).midY
        }
        let iconMidY = visibleMidY(banner.test_iconView)
        #expect(abs(iconMidY - visibleMidY(button)) <= 0.5, "icon and button share one centre")
        #expect(abs(iconMidY - visibleMidY(link)) <= 0.5, "icon and text action share one centre")
    }
}
