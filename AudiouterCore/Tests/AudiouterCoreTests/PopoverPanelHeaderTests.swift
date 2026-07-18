// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
import AppKit
@testable import AudiouterPopoverUI

/// Container-level coverage for `PopoverPanelViewController` (task T-PANEL,
/// 2026-07-18): the whole-header collapse click target (C4), the header
/// accessory's `isEnabled` plumbing (F1), and `addCardNote` (A1). Exercises the
/// panel directly (not through `PopoverController`/a backend) since these are
/// pure container-layout behaviors — see `PopoverControllerTests` for the
/// full-stack integration coverage this suite intentionally does not duplicate.
@MainActor
final class PopoverPanelHeaderTests: XCTestCase {

    private func makePanel() -> PopoverPanelViewController {
        let panel = PopoverPanelViewController()
        _ = panel.view   // force `loadView()` so the stack/cards are mounted
        return panel
    }

    // MARK: C4 — whole-header click toggles collapse

    func testWholeHeaderClickTogglesCollapse() {
        let panel = makePanel()
        let title = "Devices"
        var toggleCount = 0
        panel.beginCard(header: title, collapsible: true, collapsed: false, onToggle: {
            toggleCount += 1
            panel.toggleCard(title: title, animated: false)
        })
        panel.addRow(NSView())   // give the card a body so collapse has something to clip

        XCTAssertEqual(panel.test_isCardCollapsed(title: title), false)
        XCTAssertTrue(panel.test_fireHeaderClick(title: title),
                      "a collapsible card's header row has a click target")
        XCTAssertEqual(toggleCount, 1,
                       "a click on the header row (not a button) invokes onToggle exactly once")
        XCTAssertEqual(panel.test_isCardCollapsed(title: title), true,
                       "the header-row click drove the card to collapsed")

        XCTAssertTrue(panel.test_fireHeaderClick(title: title))
        XCTAssertEqual(toggleCount, 2, "a second header click toggles again")
        XCTAssertEqual(panel.test_isCardCollapsed(title: title), false)
    }

    func testNonCollapsibleHeaderHasNoClickTarget() {
        let panel = makePanel()
        panel.beginCard(header: "System")   // collapsible defaults to false
        XCTAssertFalse(panel.test_fireHeaderClick(title: "System"),
                       "a non-collapsible card's header has no click gesture to fire")
    }

    // MARK: F1 — header accessory isEnabled + setAccessoryEnabled

    func testAccessoryEnabledDefaultsTrueAndIsSettable() {
        let panel = makePanel()
        let title = "Groups"
        var accessoryFired = 0
        var toggleCount = 0
        panel.beginCard(header: title,
                        trailingAccessory: .init(symbol: "plus", label: "New group", action: {
                            accessoryFired += 1
                        }),
                        collapsible: true, collapsed: false,
                        onToggle: { toggleCount += 1 })

        XCTAssertEqual(panel.test_accessoryEnabled(title: title), true,
                       "HeaderAccessory.isEnabled defaults true for back-compat")

        panel.setAccessoryEnabled(title: title, enabled: false)
        XCTAssertEqual(panel.test_accessoryEnabled(title: title), false)

        panel.setAccessoryEnabled(title: title, enabled: true)
        XCTAssertEqual(panel.test_accessoryEnabled(title: title), true)
    }

    func testAccessoryClickNeverTogglesCollapse() {
        let panel = makePanel()
        let title = "Groups"
        var accessoryFired = 0
        var toggleCount = 0
        panel.beginCard(header: title,
                        trailingAccessory: .init(symbol: "plus", label: "New group", action: {
                            accessoryFired += 1
                        }),
                        collapsible: true, collapsed: false,
                        onToggle: { toggleCount += 1 })

        XCTAssertTrue(panel.test_fireAccessoryAction(title: title))
        XCTAssertEqual(accessoryFired, 1, "the accessory's own action fires")
        XCTAssertEqual(toggleCount, 0,
                       "a click on the accessory button must never toggle the card's collapse (C4 (b))")

        // The whole-header click still works independently of the accessory.
        XCTAssertTrue(panel.test_fireHeaderClick(title: title))
        XCTAssertEqual(toggleCount, 1)
    }

    func testHeaderAccessoryConstructedWithExplicitDisabled() {
        let panel = makePanel()
        let title = "Groups"
        panel.beginCard(header: title,
                        trailingAccessory: PopoverPanelViewController.HeaderAccessory(
                            symbol: "plus", label: "New group", action: {}, isEnabled: false))
        XCTAssertEqual(panel.test_accessoryEnabled(title: title), false,
                       "isEnabled: false at construction disables the button up front")
    }

    // MARK: A1 — addCardNote

    func testCardNoteRendersWithTertiaryColorAndText() {
        let panel = makePanel()
        let title = "Devices"
        let text = "Inactive — Audio Out is using 'Living Room'"
        panel.beginCard(header: title, collapsible: true, collapsed: false)
        panel.addCardNote(text)

        let notes = panel.test_cardNotes(title: title)
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes.first?.stringValue, text)
        XCTAssertEqual(notes.first?.textColor, .tertiaryLabelColor)
    }

    func testCardNoteSurvivesBodyCollapse() {
        let panel = makePanel()
        let title = "Devices"
        panel.beginCard(header: title, collapsible: true, collapsed: false)
        panel.addCardNote("Inactive — Audio Out is using 'Living Room'")
        panel.addRow(NSView())   // give the card a collapsible body

        panel.test_toggleCard(title: title, animated: false)
        XCTAssertEqual(panel.test_isCardCollapsed(title: title), true)

        let note = try? XCTUnwrap(panel.test_cardNotes(title: title).first)
        XCTAssertNotNil(note)
        XCTAssertEqual(note?.isHidden, false,
                       "a card note is a header row, so it stays visible when the body collapses")
        XCTAssertNotNil(note?.superview,
                        "the note stays mounted above the collapsing body clip, not inside it")
    }

    func testAddCardNoteNoopsWithoutACurrentCard() {
        let panel = makePanel()
        // No `beginCard` call yet — `currentCard` is nil.
        panel.addCardNote("should be dropped")
        XCTAssertEqual(panel.test_cardNotes(title: "anything"), [])
    }
}
