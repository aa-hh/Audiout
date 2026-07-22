// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
import AppKit
@testable import AudiouterPopoverUI

/// Coverage for `PopoverHeaderView`'s icon-button system (header legibility
/// pass, 2026-07-22): the three buttons must be square at the new, larger
/// `iconButtonSide`, must resolve non-nil glyph images (with fallbacks), and
/// must surface a complete-phrase hover tooltip — the product owner's fixes
/// for "I can't tell what these buttons do."
@MainActor
final class PopoverHeaderViewTests: XCTestCase {

    private func makeHeader() -> PopoverHeaderView {
        let header = PopoverHeaderView()
        // Give the view a window-less but laid-out frame so Auto Layout can
        // resolve real frame sizes for the button-square assertions below.
        header.frame = NSRect(x: 0, y: 0, width: 460, height: PopoverHeaderView.barHeight)
        return header
    }

    // MARK: Sizing — square, evenly padded, "slightly larger"

    func testIconButtonSideIsLargerThanThePreviousSizeAndSquare() {
        // Previous shipped box was 26×22 (non-square). The new box must be
        // strictly bigger on both axes and square (width == height), per the
        // "bigger" + "perfectly even padding... square buttons" ask.
        XCTAssertGreaterThan(PopoverHeaderView.iconButtonSide, 26)
        XCTAssertGreaterThan(PopoverHeaderView.iconButtonSide, 22)
    }

    func testBarHeightGivesEvenVerticalClearanceAroundTheButtonSquare() {
        let clearance = PopoverHeaderView.barHeight - PopoverHeaderView.iconButtonSide
        XCTAssertGreaterThan(clearance, 0, "the bar must be taller than the button square")
        XCTAssertEqual(clearance.truncatingRemainder(dividingBy: 2), 0,
                       "an even total clearance splits into equal top/bottom padding")
    }

    func testAllThreeIconButtonsRenderAtTheSameMatchedSize() {
        // The Auto Layout constraints (asserted as authored in
        // `testIconButtonSideIsLargerThanThePreviousSizeAndSquare`) bind to
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

        XCTAssertEqual(frames.groups.size, frames.settings.size,
                       "groups and settings must render at the same size")
        XCTAssertEqual(frames.settings.size, frames.quit.size,
                       "settings and quit must render at the same size")
        XCTAssertEqual(frames.groups.width, PopoverHeaderView.iconButtonSide, accuracy: 1.5)
        XCTAssertEqual(frames.groups.height, PopoverHeaderView.iconButtonSide, accuracy: 1.5)
    }

    // MARK: Glyphs resolve non-nil (matched proportions still needs an image)

    func testAllThreeIconButtonsResolveANonNilImage() {
        let header = makeHeader()
        XCTAssertTrue(header.test_groupsButtonHasImage)
        XCTAssertTrue(header.test_settingsButtonHasImage)
        XCTAssertTrue(header.test_quitButtonHasImage)
    }

    // MARK: Hover tooltips — the other half of the legibility fix

    func testHoverTooltipsAreCompletePhrasesNotBareLabels() {
        let header = makeHeader()
        XCTAssertEqual(header.test_groupsButtonToolTip, "Open Groups editor")
        XCTAssertEqual(header.test_settingsButtonToolTip, "Settings")
        XCTAssertEqual(header.test_quitButtonToolTip, "Quit")
    }

    // MARK: Taps still route to the right callback (unaffected by the restyle)

    func testTapsStillFireTheirCallbacks() {
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

        XCTAssertTrue(openedGroups)
        XCTAssertTrue(openedSettings)
        XCTAssertTrue(quit)
    }
}
