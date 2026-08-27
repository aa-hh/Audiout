// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
import AppKit
@testable import AudioutCore
@testable import AudioutWindowUI

/// The Groups sidebar's power-user actions: the row context menu, Cmd-N, and
/// double-click-to-rename (design critique 2026-08-12).
///
/// All three act on the CLICKED row rather than the selected one, so the
/// clicked-vs-selected arbitration is what most of these pin down. The sidebar
/// is built on its own here (no window, no split view, no `GroupController`) —
/// it needs none of them, and every action runs through its real
/// `NSMenu`/`NSMenuItem`/`NSEvent` path with only the clicked row injected.
@MainActor
@Suite final class SidebarActionsTests: IsolatedSuite {

    private func makeDevice(id: String, name: String) -> Device {
        Device(id: id, name: name, kind: .generic, isAvailable: true)
    }

    private func makeGroup(id: String, name: String) -> Group {
        Group(id: id, name: name, memberIDs: ["office"], memberVolumes: [:])
    }

    /// A loaded sidebar with two groups and three speakers.
    private func makeSidebar(groups: [Group]? = nil) -> SidebarViewController {
        let sidebar = SidebarViewController()
        _ = sidebar.view      // triggers `loadView`
        sidebar.reload(groups: groups ?? [makeGroup(id: "g1", name: "Downstairs"),
                                          makeGroup(id: "g2", name: "Upstairs")],
                       activeGroupID: nil,
                       devices: [makeDevice(id: "office", name: "Office"),
                                 makeDevice(id: "kitchen", name: "Kitchen"),
                                 makeDevice(id: "patio", name: "Patio")])
        return sidebar
    }

    // MARK: Menu contents per row kind

    @Test func groupRowMenuOffersRenameAndDelete() {
        let sidebar = makeSidebar()
        #expect(sidebar.test_contextMenuItems(for: .group(id: "g1"))
                == ["Rename…", "Delete Group…"])
    }

    /// The item NAMES what it will act on. "New Group from Selection…" named
    /// nothing at all, on the one menu whose target changes with where you
    /// clicked.
    @Test func speakerRowMenuNamesTheClickedSpeaker() {
        let sidebar = makeSidebar()
        #expect(sidebar.test_contextMenuItems(for: .device(id: "kitchen"))
                == ["New Group from \u{201C}Kitchen\u{201D}…"])
    }

    @Test func speakerRowMenuCountsAMultiSelection() {
        let sidebar = makeSidebar()
        sidebar.test_selectDevices(["office", "patio"])
        #expect(sidebar.test_contextMenuItems(for: .device(id: "patio"))
                == ["New Group from 2 Speakers…"],
                "the same wording the bottom bar retitles itself to")
    }

    @Test func mainAudioRowHasNoMenu() {
        let sidebar = makeSidebar()
        #expect(sidebar.test_contextMenuItems(for: .mainOut).isEmpty)
    }

    @Test func headerAndPlaceholderRowsHaveNoMenu() {
        let sidebar = makeSidebar(groups: [])
        // Section headers carry no identity to act on…
        #expect(sidebar.test_contextMenuItems(forRowTitled: "Groups").isEmpty)
        #expect(sidebar.test_contextMenuItems(forRowTitled: "Speakers").isEmpty)
        // …and neither does the "no groups yet" placeholder row.
        #expect(sidebar.test_hasGroupsEmptyStateRow)
        #expect(sidebar.test_contextMenuItems(forRowTitled: "No groups yet").isEmpty)
    }

    // MARK: Clicked-vs-selected arbitration

    @Test func rightClickInsideTheSelectionActsOnTheWholeSelection() {
        let sidebar = makeSidebar()
        var created: [String]?
        sidebar.onNewGroupFromSelection = { created = $0 }

        sidebar.test_selectDevices(["office", "patio"])
        sidebar.test_clickContextMenuItem("New Group from 2 Speakers…", for: .device(id: "patio"))

        #expect(created == ["office", "patio"], "a clicked row inside the selection keeps it")
    }

    @Test func rightClickOutsideTheSelectionActsOnThatRowAlone() {
        let sidebar = makeSidebar()
        var created: [String]?
        sidebar.onNewGroupFromSelection = { created = $0 }

        sidebar.test_selectDevices(["office", "patio"])
        sidebar.test_clickContextMenuItem("New Group from \u{201C}Kitchen\u{201D}…",
                                          for: .device(id: "kitchen"))

        #expect(created == ["kitchen"], "a clicked row outside the selection replaces it")
    }

    @Test func rightClickWithNothingSelectedActsOnTheClickedRow() {
        let sidebar = makeSidebar()
        var created: [String]?
        sidebar.onNewGroupFromSelection = { created = $0 }

        sidebar.test_clickContextMenuItem("New Group from \u{201C}Office\u{201D}…",
                                          for: .device(id: "office"))

        #expect(created == ["office"])
    }

    // MARK: Group items

    @Test func renameSelectsTheGroupBeforeAskingForTheRenameField() {
        let sidebar = makeSidebar()
        var order: [String] = []
        var selected: SidebarSelection?
        sidebar.onSelect = { selected = $0; order.append("select") }
        sidebar.onRequestRename = { _ in order.append("rename") }

        sidebar.test_clickContextMenuItem("Rename…", for: .group(id: "g2"))

        #expect(order == ["select", "rename"],
                "the group is selected FIRST — the rename field only exists in its editor")
        #expect(selected == .group(id: "g2"))
        #expect(sidebar.currentSelection == .group(id: "g2"))
    }

    @Test func deleteReportsTheClickedGroupAndNothingElse() {
        let sidebar = makeSidebar()
        var deleted: [String] = []
        sidebar.onRequestDelete = { deleted.append($0) }

        sidebar.test_clickContextMenuItem("Delete Group…", for: .group(id: "g1"))

        #expect(deleted == ["g1"])
    }

    @Test func aGroupsMenuActsOnTheClickedGroupNotTheSelectedOne() {
        let sidebar = makeSidebar()
        var renamed: [String] = []
        sidebar.onRequestRename = { renamed.append($0) }

        sidebar.test_select(.group(id: "g1"))
        sidebar.test_clickContextMenuItem("Rename…", for: .group(id: "g2"))

        #expect(renamed == ["g2"])
    }

    // MARK: Cmd-N

    @Test func cmdNWithNothingSelectedCreatesAnEmptyGroup() {
        let sidebar = makeSidebar()
        var addCount = 0
        var fromSelection: [String]?
        sidebar.onAddGroup = { addCount += 1 }
        sidebar.onNewGroupFromSelection = { fromSelection = $0 }

        #expect(sidebar.test_performCmdN(), "the sidebar claims the key equivalent")
        #expect(addCount == 1)
        #expect(fromSelection == nil)
    }

    @Test func cmdNWithSpeakersSelectedCreatesFromThatSelection() {
        let sidebar = makeSidebar()
        var addCount = 0
        var fromSelection: [String]?
        sidebar.onAddGroup = { addCount += 1 }
        sidebar.onNewGroupFromSelection = { fromSelection = $0 }

        sidebar.test_selectDevices(["kitchen", "patio"])
        #expect(sidebar.test_performCmdN())

        #expect(fromSelection == ["kitchen", "patio"], "Cmd-N routes exactly like the + button")
        #expect(addCount == 0)
    }

    @Test func cmdNAndThePlusButtonShareOnePath() {
        let sidebar = makeSidebar()
        var calls: [[String]] = []
        sidebar.onNewGroupFromSelection = { calls.append($0) }

        sidebar.test_selectDevices(["office"])
        sidebar.test_tapAdd()
        #expect(sidebar.test_performCmdN())

        #expect(calls == [["office"], ["office"]])
    }

    /// ⌘N is dispatched down the VIEW TREE, before the responder chain sees
    /// the key — so the sidebar was claiming it out from under a text field
    /// the user was typing in.
    @Test func cmdNYieldsToAFieldEditor() {
        let sidebar = makeSidebar()
        var fired = 0
        sidebar.onAddGroup = { fired += 1 }
        sidebar.onNewGroupFromSelection = { _ in fired += 1 }

        // Never ordered front — tests stay invisible.
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                            styleMask: [.titled], backing: .buffered, defer: true)
        let field = NSTextField(string: "typing")
        field.isEditable = true
        field.frame = NSRect(x: 0, y: 260, width: 400, height: 24)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        sidebar.view.frame = NSRect(x: 0, y: 0, width: 240, height: 260)
        container.addSubview(sidebar.view)
        container.addSubview(field)
        host.contentView = container
        guard host.makeFirstResponder(field),
              field.currentEditor() != nil else {
            return   // no field editor in this environment (see GroupRenameFieldTests' note)
        }

        #expect(!sidebar.test_performCmdN(), "the field editor keeps the key")
        #expect(fired == 0)
    }

    // MARK: A selection whose target is gone

    @Test func selectingAGroupThatNoLongerExistsClearsTheHighlight() {
        let sidebar = makeSidebar()
        sidebar.test_select(.group(id: "g1"))
        #expect(sidebar.currentSelection == .group(id: "g1"))

        sidebar.reload(groups: [makeGroup(id: "g2", name: "Upstairs")],
                       activeGroupID: nil,
                       devices: [makeDevice(id: "office", name: "Office")])

        #expect(sidebar.currentSelection == nil,
                "the row it named is gone — the list must not keep drawing it as selected")
    }

    // MARK: VoiceOver state on a row (P1-8 / P3-6)

    /// Unavailable and "playing now" were COLOUR/GLYPH ONLY. The spoken label
    /// carries them in the same words the visible UI uses — and, because cells
    /// are reused, an ordinary row must never inherit the last one's suffix.
    @Test func rowLabelsSpeakUnavailableAndPlayingNow() throws {
        let sidebar = SidebarViewController()
        _ = sidebar.view
        let group = makeGroup(id: "g1", name: "Downstairs")
        sidebar.reload(groups: [group], activeGroupID: "g1",
                       devices: [makeDevice(id: "office", name: "Office"),
                                 makeDevice(id: "patio", name: "Patio")])

        let offline = Device(id: "patio", name: "Patio", kind: .generic, isAvailable: false)
        let offlineCell = try #require(
            sidebar.outlineView(NSOutlineView(), viewFor: nil,
                                item: SidebarViewController.Node(.device(offline)))
                as? NSTableCellView)
        #expect(offlineCell.textField?.accessibilityLabel() == "Patio, unavailable")

        let activeCell = try #require(
            sidebar.outlineView(NSOutlineView(), viewFor: nil,
                                item: SidebarViewController.Node(.group(group)))
                as? NSTableCellView)
        #expect(activeCell.textField?.accessibilityLabel() == "Downstairs, playing now")

        let ordinaryCell = try #require(
            sidebar.outlineView(NSOutlineView(), viewFor: nil,
                                item: SidebarViewController.Node(
                                    .device(makeDevice(id: "office", name: "Office"))))
                as? NSTableCellView)
        #expect(ordinaryCell.textField?.accessibilityLabel() == "Office",
                "a reused cell must not keep the previous row's suffix")
        // The glyph is DECORATIVE: it must not repeat the row, which is what
        // VoiceOver read twice before. Note it cannot be made description-LESS
        // — passing nil to `NSImage(systemSymbolName:accessibilityDescription:)`
        // leaves the SYMBOL's own built-in name ("HiFi Speaker"), which says
        // nothing about this row and is what the platform speaks for every
        // undescribed symbol. Not being the row's name is the whole fix.
        #expect(ordinaryCell.imageView?.image?.accessibilityDescription != "Office",
                "the glyph never carries the row's own name")
    }

    // MARK: Double-click

    @Test func doubleClickingAGroupRowAsksForRename() {
        let sidebar = makeSidebar()
        var renamed: [String] = []
        sidebar.onRequestRename = { renamed.append($0) }

        sidebar.test_doubleClick(.group(id: "g1"))

        #expect(renamed == ["g1"])
    }

    @Test func doubleClickingASpeakerRowDoesNothing() {
        let sidebar = makeSidebar()
        var renamed: [String] = []
        var deleted: [String] = []
        sidebar.onRequestRename = { renamed.append($0) }
        sidebar.onRequestDelete = { deleted.append($0) }

        sidebar.test_doubleClick(.device(id: "office"))

        #expect(renamed.isEmpty, "the detail pane already opened on the first click")
        #expect(deleted.isEmpty)
    }
}
