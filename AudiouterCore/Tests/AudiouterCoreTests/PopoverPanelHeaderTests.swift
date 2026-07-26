// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import AppKit
@testable import AudiouterPopoverUI

/// Container-level coverage for `PopoverPanelViewController` (task T-PANEL,
/// 2026-07-18): the whole-header collapse click target (C4), the header
/// accessory's `isEnabled` plumbing (F1), and `addCardNote` (A1). Exercises the
/// panel directly (not through `PopoverController`/a backend) since these are
/// pure container-layout behaviors — see `PopoverControllerTests` for the
/// full-stack integration coverage this suite intentionally does not duplicate.
@MainActor
@Suite struct PopoverPanelHeaderTests {

    private func makePanel() -> PopoverPanelViewController {
        let panel = PopoverPanelViewController()
        _ = panel.view   // force `loadView()` so the stack/cards are mounted
        return panel
    }

    // MARK: C4 — whole-header click toggles collapse

    @Test func wholeHeaderClickTogglesCollapse() {
        let panel = makePanel()
        let title = "Devices"
        var toggleCount = 0
        panel.beginCard(header: title, collapsible: true, collapsed: false, onToggle: {
            toggleCount += 1
            panel.toggleCard(title: title, animated: false)
        })
        panel.addRow(NSView())   // give the card a body so collapse has something to clip

        #expect(panel.test_isCardCollapsed(title: title) == false)
        #expect(panel.test_fireHeaderClick(title: title),
                "a collapsible card's header row has a click target")
        #expect(toggleCount == 1,
                "a click on the header row (not a button) invokes onToggle exactly once")
        #expect(panel.test_isCardCollapsed(title: title) == true,
                "the header-row click drove the card to collapsed")

        #expect(panel.test_fireHeaderClick(title: title))
        #expect(toggleCount == 2, "a second header click toggles again")
        #expect(panel.test_isCardCollapsed(title: title) == false)
    }

    @Test func nonCollapsibleHeaderHasNoClickTarget() {
        let panel = makePanel()
        panel.beginCard(header: "System")   // collapsible defaults to false
        #expect(!panel.test_fireHeaderClick(title: "System"),
                "a non-collapsible card's header has no click gesture to fire")
    }

    // MARK: F1 — header accessory isEnabled + setAccessoryEnabled

    @Test func accessoryEnabledDefaultsTrueAndIsSettable() {
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

        #expect(panel.test_accessoryEnabled(title: title) == true,
                "HeaderAccessory.isEnabled defaults true for back-compat")

        panel.setAccessoryEnabled(title: title, enabled: false)
        #expect(panel.test_accessoryEnabled(title: title) == false)

        panel.setAccessoryEnabled(title: title, enabled: true)
        #expect(panel.test_accessoryEnabled(title: title) == true)
    }

    @Test func accessoryClickNeverTogglesCollapse() {
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

        #expect(panel.test_fireAccessoryAction(title: title))
        #expect(accessoryFired == 1, "the accessory's own action fires")
        #expect(toggleCount == 0,
                "a click on the accessory button must never toggle the card's collapse (C4 (b))")

        // The whole-header click still works independently of the accessory.
        #expect(panel.test_fireHeaderClick(title: title))
        #expect(toggleCount == 1)
    }

    @Test func headerAccessoryConstructedWithExplicitDisabled() {
        let panel = makePanel()
        let title = "Groups"
        panel.beginCard(header: title,
                        trailingAccessory: PopoverPanelViewController.HeaderAccessory(
                            symbol: "plus", label: "New group", action: {}, isEnabled: false))
        #expect(panel.test_accessoryEnabled(title: title) == false,
                "isEnabled: false at construction disables the button up front")
    }

    // MARK: A1 — addCardNote

    @Test func cardNoteRendersWithTertiaryColorAndText() {
        let panel = makePanel()
        let title = "Devices"
        let text = "Inactive — Audio Out is using 'Living Room'"
        panel.beginCard(header: title, collapsible: true, collapsed: false)
        panel.addCardNote(text)

        let notes = panel.test_cardNotes(title: title)
        #expect(notes.count == 1)
        #expect(notes.first?.stringValue == text)
        #expect(notes.first?.textColor == .tertiaryLabelColor)
    }

    @Test func cardNoteSurvivesBodyCollapse() {
        let panel = makePanel()
        let title = "Devices"
        panel.beginCard(header: title, collapsible: true, collapsed: false)
        panel.addCardNote("Inactive — Audio Out is using 'Living Room'")
        panel.addRow(NSView())   // give the card a collapsible body

        panel.test_toggleCard(title: title, animated: false)
        #expect(panel.test_isCardCollapsed(title: title) == true)

        // Original used `try? XCTUnwrap(...)` (not a throwing test), which
        // swallows the throw into a plain Optional — equivalent to just
        // taking `.first` directly.
        let note = panel.test_cardNotes(title: title).first
        #expect(note != nil)
        #expect(note?.isHidden == false,
                "a card note is a header row, so it stays visible when the body collapses")
        #expect(note?.superview != nil,
                "the note stays mounted above the collapsing body clip, not inside it")
    }

    @Test func addCardNoteNoopsWithoutACurrentCard() {
        let panel = makePanel()
        // No `beginCard` call yet — `currentCard` is nil.
        panel.addCardNote("should be dropped")
        #expect(panel.test_cardNotes(title: "anything") == [])
    }
}
