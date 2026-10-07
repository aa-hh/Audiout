// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import Testing
@testable import AudioutSharedUI
@testable import AudioutWindowUI

@MainActor
@Suite final class ScenesSidebarViewControllerTests: IsolatedSuite {
    private func makeSidebar() -> ScenesSidebarViewController {
        let sidebar = ScenesSidebarViewController()
        sidebar.loadView()
        sidebar.view.frame = NSRect(x: 0, y: 0, width: 210, height: 400)
        return sidebar
    }

    private func rows() -> [ScenesSidebarViewController.SceneRow] {
        [.init(id: "k", name: "Kitchen", symbolName: "rectangle.3.group", memberCount: 2),
         .init(id: "a", name: "Attic", symbolName: "rectangle.3.group", memberCount: 1)]
    }

    // Removing name sorting or singular count formatting turns it red.
    @Test func rowsSortByNameAndCarryCounts() {
        let sidebar = makeSidebar()
        sidebar.reload(scenes: rows())
        #expect(sidebar.test_rowIDs == ["a", "k"])
        #expect(sidebar.test_rowCaption(id: "a") == "1 speaker")
        #expect(sidebar.test_rowCaption(id: "k") == "2 speakers")
    }

    // Removing the empty placeholder or retaining stale scene rows turns it red.
    @Test func emptyReloadShowsOnlyThePlaceholder() {
        let sidebar = makeSidebar()
        sidebar.reload(scenes: rows())
        sidebar.reload(scenes: [])
        #expect(sidebar.test_hasPlaceholderRow)
        #expect(sidebar.test_rowIDs.isEmpty)
        #expect(sidebar.test_filteredSelection(ofRows: IndexSet(integer: 1)).isEmpty)
    }

    // Dropping or duplicating the row selection callback turns it red.
    @Test func sceneSelectionReportsItsIDOnce() {
        let sidebar = makeSidebar()
        sidebar.reload(scenes: rows())
        var selected: [String] = []
        sidebar.onSelect = { selected.append($0) }
        sidebar.test_select(sceneID: "k")
        #expect(selected == ["k"])
        #expect(sidebar.selectedSceneID == "k")
    }

    // Allowing an empty selection or selecting the section header turns it red.
    @Test func selectionNeverClearsOrAdmitsTheHeader() {
        let sidebar = makeSidebar()
        sidebar.reload(scenes: rows())
        sidebar.test_select(sceneID: "a")
        #expect(sidebar.test_filteredSelection(ofRows: []) == IndexSet(integer: 1))
        #expect(!sidebar.test_filteredSelection(ofRows: IndexSet(integer: 0)).contains(0))
    }

    // Adding a menu action or offering a scene action on the header turns it red.
    @Test func theSceneMenuHasOnlyRenameAndDelete() {
        let sidebar = makeSidebar()
        sidebar.reload(scenes: rows())
        #expect(sidebar.test_contextMenuItems(for: "a") == ["Rename…", "Delete scene…"])
        #expect(sidebar.test_contextMenuItems(for: "no-scene").isEmpty)
    }

    // Disconnecting Command-N from the add callback turns it red.
    @Test func commandNCreatesAScene() {
        let sidebar = makeSidebar()
        var adds = 0
        sidebar.onAddScene = { adds += 1 }
        #expect(sidebar.test_performCmdN())
        #expect(adds == 1)
    }

    // Sending Command-Delete to a different scene or dropping it turns it red.
    @Test func commandDeleteRequestsTheSelectedScene() {
        let sidebar = makeSidebar()
        sidebar.reload(scenes: rows())
        sidebar.test_select(sceneID: "k")
        var deleted: [String] = []
        sidebar.onRequestDelete = { deleted.append($0) }
        sidebar.test_pressCommandDelete()
        #expect(deleted == ["k"])
    }

    // Dropping Return's rename callback or sending the first row instead turns it red.
    @Test func returnRequestsRenameForTheSelectedScene() {
        let sidebar = makeSidebar()
        sidebar.reload(scenes: rows())
        sidebar.test_select(sceneID: "k")
        var renamed: [String] = []
        sidebar.onRequestRename = { renamed.append($0) }
        sidebar.test_pressReturn()
        #expect(renamed == ["k"])
    }

    // Leaving the name, glyph or caption on resting ink under the selection pill turns it red.
    @Test func selectedRowInksFollowThePill() throws {
        let sidebar = makeSidebar()
        sidebar.reload(scenes: rows())
        sidebar.test_select(sceneID: "a")
        let cell = try #require(sidebar.test_rowCell(id: "a"))
        let row = try #require(sidebar.test_rowView(id: "a"))
        let inks = { [cell.nameLabel.textColor, cell.imageView?.contentTintColor, cell.statusLabel.textColor] }
        row.isEmphasized = true
        #expect(inks() == Array(repeating: NSColor.alternateSelectedControlTextColor, count: 3))
        row.isEmphasized = false
        #expect(inks() == Array(repeating: Tokens.Color.label, count: 3))
    }

    // Adding a group identity glow to a native sidebar row turns it red.
    @Test func sceneRowsHaveNoIdentityGlow() throws {
        let sidebar = makeSidebar()
        sidebar.reload(scenes: rows())
        let cell = try #require(sidebar.test_rowCell(id: "a"))
        #expect(!cell.subviews.contains { $0 is GroupIdentityGlowView })
    }

    // Rebuilding unchanged row IDs prevents their count animation and turns it red.
    @Test func aCountChangeKeepsTheExistingCell() throws {
        let sidebar = makeSidebar()
        sidebar.reload(scenes: rows())
        let cell = try #require(sidebar.test_rowCell(id: "a"))
        var changed = rows()
        changed[1] = .init(id: "a", name: "Attic", symbolName: "rectangle.3.group", memberCount: 3)
        sidebar.reload(scenes: changed)
        #expect(sidebar.test_rowCell(id: "a") === cell)
        #expect(sidebar.test_rowCaption(id: "a") == "3 speakers")
    }
}
