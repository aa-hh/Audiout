// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import AppKit
@testable import AudioutPopoverUI

/// The AirPlay password sheet, driven headless through its `test_` hooks: the
/// controller is never presented, so nothing reaches the screen.
@MainActor
@Suite struct SpeakerPasswordSheetTests {

    // Showing the result line before a submit, or calling `onSubmit` with an empty field, turns it red.
    @Test func emptyConnectAsksForThePasswordAndSubmitsNothing() {
        let sheet = SpeakerPasswordSheetViewController(deviceName: "Kitchen")
        var submitted: [String] = []
        sheet.onSubmit = { submitted.append($0) }
        #expect(sheet.test_resultText == nil)

        sheet.test_setPasswordText("   ")
        sheet.test_tapConnect()
        #expect(sheet.test_resultText == "Enter the speaker's password.")
        #expect(submitted.isEmpty)
        #expect(sheet.test_connectButton.isEnabled)
    }

    // Dropping the trim, or `showResult` leaving Connect disabled, turns it red.
    @Test func connectSubmitsTrimmedTextAndShowResultReEnables() {
        let sheet = SpeakerPasswordSheetViewController(deviceName: "Kitchen")
        var submitted: [String] = []
        sheet.onSubmit = { submitted.append($0) }

        sheet.test_setPasswordText("  secret\n")
        sheet.test_tapConnect()
        #expect(submitted == ["secret"])
        #expect(!sheet.test_connectButton.isEnabled)
        #expect(sheet.test_resultText == "Connecting…")

        sheet.showResult("That password didn't work. Check it and try again.")
        #expect(sheet.test_connectButton.isEnabled)
        #expect(sheet.test_resultText == "That password didn't work. Check it and try again.")
    }

    // Turns red if the `.onScreenCode` sheet keeps the password heading or the password empty-submit line.
    @Test func codeSheetAsksForTheCodeShownOnTheScreen() {
        let sheet = SpeakerPasswordSheetViewController(deviceName: "Kitchen", kind: .onScreenCode)
        let labels = Self.textFields(in: sheet.view).map(\.stringValue)
        #expect(labels.contains("Enter the code shown on “Kitchen”"))
        #expect(!labels.contains("Enter the password for “Kitchen”"))

        let fields = Self.textFields(in: sheet.view)
        #expect(fields.allSatisfy { ($0.placeholderString ?? "").isEmpty })
        let boxLabels = fields.compactMap { $0.accessibilityLabel() }
        for i in 1...4 { #expect(boxLabels.contains("digit \(i) of 4")) }

        sheet.test_tapConnect()
        #expect(sheet.test_resultText == "Enter the code on the screen.")
    }

    // Turns red if the fourth digit stops submitting or focus stops advancing.
    @Test func fourthDigitSubmitsTheCodeAndFocusAdvances() {
        let sheet = SpeakerPasswordSheetViewController(deviceName: "Kitchen", kind: .onScreenCode)
        var submitted: [String] = []
        sheet.onSubmit = { submitted.append($0) }
        var focus: [Int] = []
        for digit in ["1", "2", "3", "4"] {
            sheet.test_typeIntoBox(sheet.test_focusedBoxIndex, digit)
            focus.append(sheet.test_focusedBoxIndex)
        }
        #expect(focus == [1, 2, 3, 3])
        #expect(submitted == ["1234"])
        #expect(!sheet.test_connectButton.isEnabled)
        #expect(sheet.test_resultText == "Connecting…")
    }

    // Turns red if paste stops spreading across the boxes or non-digits reach a box.
    @Test func pasteSpreadsDigitsAcrossTheBoxes() {
        let sheet = SpeakerPasswordSheetViewController(deviceName: "Kitchen", kind: .onScreenCode)
        var submitted: [String] = []
        sheet.onSubmit = { submitted.append($0) }
        sheet.test_typeIntoBox(0, "12 34")
        #expect(sheet.test_codeDigits == "1234")
        #expect(submitted == ["1234"])

        let fresh = SpeakerPasswordSheetViewController(deviceName: "Kitchen", kind: .onScreenCode)
        var freshSubmitted: [String] = []
        fresh.onSubmit = { freshSubmitted.append($0) }
        fresh.test_typeIntoBox(0, "ab12")
        #expect(fresh.test_codeDigits == "12")
        #expect(fresh.test_focusedBoxIndex == 2)
        #expect(freshSubmitted.isEmpty)
    }

    // Turns red if backspace stops moving back or Connect sends a short code.
    @Test func backspaceOnAnEmptyBoxStepsBackAndShortCodeIsNotSent() {
        let sheet = SpeakerPasswordSheetViewController(deviceName: "Kitchen", kind: .onScreenCode)
        var submitted: [String] = []
        sheet.onSubmit = { submitted.append($0) }
        sheet.test_typeIntoBox(0, "1")
        sheet.test_typeIntoBox(1, "2")
        sheet.test_backspace()
        #expect(sheet.test_codeDigits == "1")
        #expect(sheet.test_focusedBoxIndex == 1)

        sheet.test_tapConnect()
        #expect(sheet.test_resultText == "Enter the code on the screen.")
        #expect(submitted.isEmpty)
    }

    // Turns red if `controlTextDidChange` stops treating two digits in a box that held one as a typed-over digit and spreads them instead.
    @Test func typingOverAFilledBoxReplacesItsDigit() {
        for typed in ["15", "51"] {
            let sheet = SpeakerPasswordSheetViewController(deviceName: "Kitchen", kind: .onScreenCode)
            sheet.test_typeIntoBox(0, "1")
            sheet.test_typeIntoBox(1, "2")
            sheet.test_typeIntoBox(0, typed)
            #expect(sheet.test_codeDigits == "52")
            #expect(sheet.test_focusedBoxIndex == 1)
        }
        let pasted = SpeakerPasswordSheetViewController(deviceName: "Kitchen", kind: .onScreenCode)
        var submitted: [String] = []
        pasted.onSubmit = { submitted.append($0) }
        pasted.test_typeIntoBox(0, "1234")
        #expect(submitted == ["1234"])
    }

    // Turns red if a refusal stops clearing the boxes.
    @Test func refusedCodeClearsTheBoxesAndRefocusesTheFirst() {
        let sheet = SpeakerPasswordSheetViewController(deviceName: "Kitchen", kind: .onScreenCode)
        sheet.test_typeIntoBox(0, "1234")
        sheet.showResult("That code didn't work. Check the screen and try again.")
        #expect(sheet.test_codeDigits == "")
        #expect(sheet.test_focusedBoxIndex == 0)
        #expect(sheet.test_connectButton.isEnabled)
        #expect(sheet.test_resultText == "That code didn't work. Check the screen and try again.")
    }

    static func textFields(in view: NSView) -> [NSTextField] {
        view.subviews.flatMap { sub -> [NSTextField] in
            ((sub as? NSTextField).map { [$0] } ?? []) + textFields(in: sub)
        }
    }
}
