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

    @Test func speakerRowMenuOffersNewGroupFromSelection() {
        let sidebar = makeSidebar()
        #expect(sidebar.test_contextMenuItems(for: .device(id: "kitchen"))
                == ["New Group from Selection…"])
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
        sidebar.test_clickContextMenuItem("New Group from Selection…", for: .device(id: "patio"))

        #expect(created == ["office", "patio"], "a clicked row inside the selection keeps it")
    }

    @Test func rightClickOutsideTheSelectionActsOnThatRowAlone() {
        let sidebar = makeSidebar()
        var created: [String]?
        sidebar.onNewGroupFromSelection = { created = $0 }

        sidebar.test_selectDevices(["office", "patio"])
        sidebar.test_clickContextMenuItem("New Group from Selection…", for: .device(id: "kitchen"))

        #expect(created == ["kitchen"], "a clicked row outside the selection replaces it")
    }

    @Test func rightClickWithNothingSelectedActsOnTheClickedRow() {
        let sidebar = makeSidebar()
        var created: [String]?
        sidebar.onNewGroupFromSelection = { created = $0 }

        sidebar.test_clickContextMenuItem("New Group from Selection…", for: .device(id: "office"))

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
}
