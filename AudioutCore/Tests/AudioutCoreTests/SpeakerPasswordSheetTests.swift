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

        sheet.test_tapConnect()
        #expect(sheet.test_resultText == "Enter the code on the screen.")
    }

    static func textFields(in view: NSView) -> [NSTextField] {
        view.subviews.flatMap { sub -> [NSTextField] in
            ((sub as? NSTextField).map { [$0] } ?? []) + textFields(in: sub)
        }
    }
}
