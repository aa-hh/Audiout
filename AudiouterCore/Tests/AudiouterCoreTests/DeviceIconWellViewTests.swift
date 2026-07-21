// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
import AppKit
@testable import AudiouterWindowUI

/// Keyboard/VoiceOver operability coverage for `DeviceIconWellView`
/// (A11Y-GROUPS): a live test found the icon well — the one approved
/// custom-drawn element in the Groups window (`../../Sources/AudiouterWindowUI/AGENTS.md`)
/// — was mouse-only, with no keyboard or VoiceOver path to open the icon
/// picker. These cases assert the fix: the well opts into the key-view loop,
/// a real Space/Return `keyDown(with:)` activates it exactly like a click,
/// and the accessibility "press" action (what VoiceOver / Full Keyboard
/// Access call instead of a click) reaches the same callback.
final class DeviceIconWellViewTests: XCTestCase {

    func testAcceptsFirstResponderSoItJoinsTheKeyViewLoop() {
        let well = DeviceIconWellView()
        XCTAssertTrue(well.acceptsFirstResponder,
                       "must opt into the window's Tab key-view loop like a real NSButton")
    }

    func testSpaceKeyActivatesTheWellViaOnClick() {
        let well = DeviceIconWellView()
        var fired = false
        well.onClick = { fired = true }

        well.test_pressKey(" ")

        XCTAssertTrue(fired, "Space must activate the well, mirroring NSButton's keyboard behavior")
    }

    func testReturnKeyActivatesTheWellViaOnClick() {
        let well = DeviceIconWellView()
        var fired = false
        well.onClick = { fired = true }

        well.test_pressKey("\r")

        XCTAssertTrue(fired, "Return must activate the well, mirroring NSButton's keyboard behavior")
    }

    func testKeypadEnterActivatesTheWellViaOnClick() {
        let well = DeviceIconWellView()
        var fired = false
        well.onClick = { fired = true }

        well.test_pressKey("\u{3}")

        XCTAssertTrue(fired, "the numeric-keypad Enter must activate the well too")
    }

    func testUnrelatedKeyDoesNotActivateTheWell() {
        let well = DeviceIconWellView()
        var fired = false
        well.onClick = { fired = true }

        well.test_pressKey("a")

        XCTAssertFalse(fired, "only Space/Return/keypad-Enter should activate — not every keystroke")
    }

    func testAccessibilityPerformPressActivatesTheWell() {
        // The seam VoiceOver's "press" gesture and Full Keyboard Access call
        // instead of synthesizing a real click.
        let well = DeviceIconWellView()
        var fired = false
        well.onClick = { fired = true }

        let handled = well.accessibilityPerformPress()

        XCTAssertTrue(handled)
        XCTAssertTrue(fired, "VoiceOver's press action must reach the same callback a click fires")
    }

    func testAccessibilityRoleAndLabelAreSetForVoiceOver() {
        let well = DeviceIconWellView()
        XCTAssertTrue(well.isAccessibilityElement())
        XCTAssertEqual(well.accessibilityRole(), .button)
        XCTAssertEqual(well.accessibilityLabel(), "Edit icon")
    }

    func testBecomingFirstResponderStepsUpTheBadgeLikeHover() {
        // Keyboard focus should give the same "this is interactive" cue a
        // mouse hover gives, on top of the system focus ring.
        let well = DeviceIconWellView()
        well.setOverlayVisible(false)
        XCTAssertEqual(well.test_badgeAlpha, 0.7, accuracy: 0.001, "rest alpha before focus")

        XCTAssertTrue(well.becomeFirstResponder())
        XCTAssertEqual(well.test_badgeAlpha, 1.0, accuracy: 0.001,
                       "focus should step the badge up to hover alpha")

        XCTAssertTrue(well.resignFirstResponder())
        XCTAssertEqual(well.test_badgeAlpha, 0.7, accuracy: 0.001,
                       "losing focus should drop the badge back to rest alpha")
    }
}
