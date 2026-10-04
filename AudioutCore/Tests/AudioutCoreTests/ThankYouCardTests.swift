// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import AppKit
@testable import AudioutPopoverUI
@testable import AudioutSharedUI

/// The thank-you card's contract with the popover. No window is ever made.
@MainActor
@Suite struct ThankYouCardTests {

    /// Defect: the card grows or shrinks the popover by something other than
    /// its 112 pt, moving the footer by a different amount than designed.
    @Test func fittingHeightIs112AtPopoverWidth() {
        let card = ThankYouCardView(width: 625)
        card.layoutSubtreeIfNeeded()
        #expect(card.fittingSize.height == 112)
    }

    /// Defect: the labels drift from the approved copy.
    @Test func labelsCarryTheApprovedCopy() {
        let card = ThankYouCardView(width: 625)
        #expect(card.test_headlineText == "Thank you for buying Audiout.")
        #expect(card.test_bodyText == "You paid once, and it's yours for good. Every update is included. Your purchase pays for the work on the next ones, and that means a lot to one small team.")
    }

    /// Defect: Close is wired to nothing, so the card never goes and the shown
    /// flag is never written. Goes through the button's own target/action.
    @Test func closeButtonDrivesOnClose() {
        let card = ThankYouCardView(width: 625)
        var closed = 0
        card.onClose = { closed += 1 }
        card.test_closeButton.performClick(nil)
        #expect(closed == 1)
    }

    /// Defect: VoiceOver reads only the headline, or nothing, for the thanks.
    @Test func groupLabelIsHeadlinePlusBody() {
        let card = ThankYouCardView(width: 625)
        #expect(card.accessibilityRole() == .group)
        #expect(card.accessibilityLabel() == "Thank you for buying Audiout. You paid once, and it's yours for good. Every update is included. Your purchase pays for the work on the next ones, and that means a lot to one small team.")
    }

    /// Defect: VoiceOver reads the button as a bare "Close", which says
    /// nothing about what it closes once focus has left the card.
    @Test func closeButtonSaysWhatItCloses() {
        #expect(ThankYouCardView(width: 625).test_closeButton.accessibilityLabel() == "Close this message")
    }

    /// Defect: under Increase Contrast the card has no edge, or keeps one
    /// after the setting goes off.
    @Test func increaseContrastAddsAOnePointEdge() {
        let card = ThankYouCardView(width: 625)
        card.stampLayerColors(increaseContrast: true)
        #expect(card.layer?.borderWidth == 1)
        card.stampLayerColors(increaseContrast: false)
        #expect(card.layer?.borderWidth == 0)
    }

    /// Defect: the fill is a raw colour or the wrong token/alpha instead of
    /// the banner recipe with gold.
    @Test func fillIsGoldAtTwelvePercent() {
        let card = ThankYouCardView(width: 625)
        card.updateLayer()
        guard let a = card.test_backgroundColor?.usingColorSpace(.sRGB),
              let b = Tokens.Color.gold.withAlphaComponent(0.12).usingColorSpace(.sRGB) else {
            Issue.record("nil or non-convertible color")
            return
        }
        #expect(abs(a.redComponent - b.redComponent) <= 0.004)
        #expect(abs(a.greenComponent - b.greenComponent) <= 0.004)
        #expect(abs(a.blueComponent - b.blueComponent) <= 0.004)
        #expect(abs(a.alphaComponent - b.alphaComponent) <= 0.004)
    }
}
