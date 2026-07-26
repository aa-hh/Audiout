// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
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
// `@MainActor` is load-bearing, not decoration: this suite builds and drives
// AppKit views, and every `NSView`-family API is main-actor-only. XCTest ran
// each test method on the main thread, so the annotation was never needed;
// swift-testing schedules non-isolated `@Test` bodies on the cooperative
// pool, where the same calls trip AppKit's "modifications to layout engine
// from a background thread" exception and take the whole process down
// (observed in `AppRowViewTests` during this migration). Do not remove it.
@MainActor
@Suite struct DeviceIconWellViewTests {

    @Test func acceptsFirstResponderSoItJoinsTheKeyViewLoop() {
        let well = DeviceIconWellView()
        #expect(well.acceptsFirstResponder,
                       "must opt into the window's Tab key-view loop like a real NSButton")
    }

    @Test func spaceKeyActivatesTheWellViaOnClick() {
        let well = DeviceIconWellView()
        var fired = false
        well.onClick = { fired = true }

        well.test_pressKey(" ")

        #expect(fired, "Space must activate the well, mirroring NSButton's keyboard behavior")
    }

    @Test func returnKeyActivatesTheWellViaOnClick() {
        let well = DeviceIconWellView()
        var fired = false
        well.onClick = { fired = true }

        well.test_pressKey("\r")

        #expect(fired, "Return must activate the well, mirroring NSButton's keyboard behavior")
    }

    @Test func keypadEnterActivatesTheWellViaOnClick() {
        let well = DeviceIconWellView()
        var fired = false
        well.onClick = { fired = true }

        well.test_pressKey("\u{3}")

        #expect(fired, "the numeric-keypad Enter must activate the well too")
    }

    @Test func unrelatedKeyDoesNotActivateTheWell() {
        let well = DeviceIconWellView()
        var fired = false
        well.onClick = { fired = true }

        well.test_pressKey("a")

        #expect(!fired, "only Space/Return/keypad-Enter should activate — not every keystroke")
    }

    @Test func accessibilityPerformPressActivatesTheWell() {
        // The seam VoiceOver's "press" gesture and Full Keyboard Access call
        // instead of synthesizing a real click.
        let well = DeviceIconWellView()
        var fired = false
        well.onClick = { fired = true }

        let handled = well.accessibilityPerformPress()

        #expect(handled)
        #expect(fired, "VoiceOver's press action must reach the same callback a click fires")
    }

    @Test func accessibilityRoleAndLabelAreSetForVoiceOver() {
        let well = DeviceIconWellView()
        #expect(well.isAccessibilityElement())
        #expect(well.accessibilityRole() == .button)
        #expect(well.accessibilityLabel() == "Edit icon")
    }

    @Test func becomingFirstResponderStepsUpTheBadgeLikeHover() {
        // Keyboard focus should give the same "this is interactive" cue a
        // mouse hover gives, on top of the system focus ring.
        let well = DeviceIconWellView()
        well.setOverlayVisible(false)
        #expect(abs(well.test_badgeAlpha - 0.7) <= 0.001, "rest alpha before focus")

        #expect(well.becomeFirstResponder())
        #expect(abs(well.test_badgeAlpha - 1.0) <= 0.001,
                       "focus should step the badge up to hover alpha")

        #expect(well.resignFirstResponder())
        #expect(abs(well.test_badgeAlpha - 0.7) <= 0.001,
                       "losing focus should drop the badge back to rest alpha")
    }
}
