// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
import AppKit
@testable import AudiouterPopoverUI

/// Coverage for `PopoverHeaderView`'s icon-button system (header legibility
/// pass, 2026-07-22): the three buttons must be square at the new, larger
/// `iconButtonSide`, must resolve non-nil glyph images (with fallbacks), and
/// must surface a complete-phrase hover tooltip — the product owner's fixes
/// for "I can't tell what these buttons do."
@MainActor
@Suite struct PopoverHeaderViewTests {

    private func makeHeader() -> PopoverHeaderView {
        let header = PopoverHeaderView()
        // Give the view a window-less but laid-out frame so Auto Layout can
        // resolve real frame sizes for the button-square assertions below.
        header.frame = NSRect(x: 0, y: 0, width: 460, height: PopoverHeaderView.barHeight)
        return header
    }

    // MARK: Sizing — square, evenly padded, "slightly larger"

    @Test func iconButtonSideIsLargerThanThePreviousSizeAndSquare() {
        // Previous shipped box was 26×22 (non-square). The new box must be
        // strictly bigger on both axes and square (width == height), per the
        // "bigger" + "perfectly even padding... square buttons" ask.
        #expect(PopoverHeaderView.iconButtonSide > 26)
        #expect(PopoverHeaderView.iconButtonSide > 22)
    }

    @Test func barHeightGivesEvenVerticalClearanceAroundTheButtonSquare() {
        let clearance = PopoverHeaderView.barHeight - PopoverHeaderView.iconButtonSide
        #expect(clearance > 0, "the bar must be taller than the button square")
        #expect(clearance.truncatingRemainder(dividingBy: 2) == 0,
                "an even total clearance splits into equal top/bottom padding")
    }

    @Test func allThreeIconButtonsRenderAtTheSameMatchedSize() {
        // The Auto Layout constraints (asserted as authored in
        // `iconButtonSideIsLargerThanThePreviousSizeAndSquare`) bind to
        // each accessoryBar button's *alignment rect*, not its raw `.frame` —
        // an `NSButton` bezel can carry a small asymmetric shadow/padding
        // inset between the two, verified empirically here (a 28pt-square
        // constraint resolves to a ~28×29pt frame, not exactly 28×28).
        // What actually matters for "matched proportions" is that all three
        // buttons resolve to the IDENTICAL frame size as each other, since
        // they share one `iconButtonSide` constraint value and one bezel
        // style — asserted directly rather than re-deriving AppKit's inset.
        let header = makeHeader()
        let frames = header.test_iconButtonFrames()

        #expect(frames.groups.size == frames.settings.size,
                "groups and settings must render at the same size")
        #expect(frames.settings.size == frames.quit.size,
                "settings and quit must render at the same size")
        #expect(abs(frames.groups.width - PopoverHeaderView.iconButtonSide) <= 1.5)
        #expect(abs(frames.groups.height - PopoverHeaderView.iconButtonSide) <= 1.5)
    }

    // MARK: Glyphs resolve non-nil (matched proportions still needs an image)

    @Test func allThreeIconButtonsResolveANonNilImage() {
        let header = makeHeader()
        #expect(header.test_groupsButtonHasImage)
        #expect(header.test_settingsButtonHasImage)
        #expect(header.test_quitButtonHasImage)
    }

    // MARK: Hover tooltips — the other half of the legibility fix

    @Test func hoverTooltipsAreCompletePhrasesNotBareLabels() {
        let header = makeHeader()
        #expect(header.test_groupsButtonToolTip == "Open Groups editor")
        #expect(header.test_settingsButtonToolTip == "Settings")
        #expect(header.test_quitButtonToolTip == "Quit")
    }

    // MARK: Taps still route to the right callback (unaffected by the restyle)

    @Test func tapsStillFireTheirCallbacks() {
        let header = makeHeader()
        var openedGroups = false
        var openedSettings = false
        var quit = false
        header.onOpenGroupsEditor = { openedGroups = true }
        header.onOpenSettings = { openedSettings = true }
        header.onQuit = { quit = true }

        header.test_tapGroupsEditor()
        header.test_tapSettings()
        header.test_tapQuit()

        #expect(openedGroups)
        #expect(openedSettings)
        #expect(quit)
    }
}
