// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
import AppKit
@testable import AudioutCore
@testable import AudioutWindowUI

/// The Groups sidebar's power-user actions: the row context menu and Cmd-N
/// (design critique 2026-08-12). Both act on the CLICKED row rather than the
/// selected one, so the clicked-vs-selected arbitration is what most of these
/// pin down.
///
/// The group rows' Rename…/Delete Group… menu and double-click-to-rename are
/// NOT here any more: direction C moved the saved groups into the content
/// pane, and their menu went with them (`GroupsOverviewViewControllerTests`).
/// What stays is anchored to the device list.
///
/// The sidebar is built on its own here (no window, no split view, no
/// `GroupController`) — it needs none of them, and every action runs through
/// its real `NSMenu`/`NSMenuItem`/`NSEvent` path with only the clicked row
/// injected.
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

    @Test func groupsRowMenuOffersOnlyNewGroup() {
        let sidebar = makeSidebar()
        #expect(sidebar.test_contextMenuItems(for: .groupsOverview) == ["New Group…"])
    }

    @Test func theGroupsRowMenuRunsTheAddPath() {
        let sidebar = makeSidebar()
        var addCount = 0
        sidebar.onAddGroup = { addCount += 1 }

        sidebar.test_clickContextMenuItem("New Group…", for: .groupsOverview)

        #expect(addCount == 1)
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

    @Test func headerRowsHaveNoMenu() {
        let sidebar = makeSidebar(groups: [])
        // Section headers carry no identity to act on.
        #expect(sidebar.test_contextMenuItems(forRowTitled: "System Audio").isEmpty)
        #expect(sidebar.test_contextMenuItems(forRowTitled: "Speakers").isEmpty)
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

    // MARK: A group target lands on the pinned Groups row

    @Test func selectingAGroupHighlightsTheGroupsRow() {
        let sidebar = makeSidebar()
        sidebar.test_select(.group(id: "g2"))

        #expect(sidebar.currentSelection == .groupsOverview,
                "a group's editor is pushed INSIDE the content pane — the fleet list must not move")
        #expect(sidebar.test_groupsRowIsSelected)
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

    /// Under direction C a `.group` target remaps onto the always-present
    /// Groups row, so a DEVICE is the target that can genuinely vanish.
    @Test func selectingADeviceThatNoLongerExistsClearsTheHighlight() {
        let sidebar = makeSidebar()
        sidebar.test_select(.device(id: "office"))
        #expect(sidebar.currentSelection == .device(id: "office"))

        sidebar.reload(groups: [makeGroup(id: "g2", name: "Upstairs")],
                       activeGroupID: nil,
                       devices: [makeDevice(id: "kitchen", name: "Kitchen")])

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

        // "Playing now" moved with the groups (direction C): the pinned Groups
        // row is what carries the live marker, so it carries the spoken state.
        let activeCell = try #require(
            sidebar.outlineView(NSOutlineView(), viewFor: nil,
                                item: SidebarViewController.Node(.groupsOverview))
                as? NSTableCellView)
        #expect(activeCell.textField?.accessibilityLabel() == "Groups, playing now")

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

    // MARK: The Groups row's click action

    @Test func clickingTheAlreadySelectedGroupsRowReportsItAgain() {
        let sidebar = makeSidebar()
        var reported: [SidebarSelection?] = []
        sidebar.onSelect = { reported.append($0) }
        sidebar.test_select(.groupsOverview)
        #expect(reported == [.groupsOverview])

        sidebar.test_clickGroupsRow()

        #expect(reported == [.groupsOverview, .groupsOverview],
                "the selection delegate stays silent; the click action speaks")
    }

    @Test func theGroupsRowClickActionIgnoresAClickWhileAnotherRowIsSelected() {
        let sidebar = makeSidebar()
        var reported: [SidebarSelection?] = []
        sidebar.onSelect = { reported.append($0) }
        sidebar.test_select(.device(id: "kitchen"))

        sidebar.test_clickGroupsRow()

        #expect(reported == [.device(id: "kitchen")],
                "a click that moves the selection is the delegate's to report")
    }

    // Double-click-to-rename left this file with the group rows (direction C):
    // rename lives on the overview's cards now, covered by
    // `GroupsOverviewViewControllerTests`. A speaker row's first click already
    // opens its detail pane, so the sidebar keeps no `doubleAction` at all.
}
