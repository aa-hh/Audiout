// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
import AppKit
@testable import AudioutCore
@testable import AudioutSharedUI
@testable import AudioutWindowUI

/// Direction C's card overview: the Groups screen's saved groups moved out of
/// the sidebar and into the content pane as a grid of cards, with the old empty
/// pane absorbed as this screen's zero-groups canvas.
///
/// Structural assertions only — no window, no synthesized clicks, and no
/// absolute widths (auto layout's rounding grid varies between runs).
@MainActor
@Suite final class GroupsOverviewViewControllerTests: IsolatedSuite {

    private func tempDirectory() -> URL {
        let dir = scratchDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeGroupController() -> GroupController {
        GroupController(backend: MockBackend(fleet: []),
                        store: GroupStore(directory: tempDirectory()),
                        loadPersisted: false)
    }

    private func makeDevice(_ id: String) -> Device {
        Device(id: id, name: id.capitalized, kind: .generic, isAvailable: true)
    }

    /// The overview over `groups`, with its view loaded and the fleet handed in
    /// — exactly the order the host drives it.
    private func makeOverview(groups: [Group],
                              activate: String? = nil,
                              devices: [Device] = []) throws
        -> (GroupsOverviewViewController, GroupController) {
        let groupController = makeGroupController()
        for group in groups { _ = try groupController.saveGroup(group) }
        if let activate { groupController.activateGroup(id: activate) }

        let overview = GroupsOverviewViewController(groupController: groupController)
        _ = overview.view
        overview.reload(devices: devices)
        return (overview, groupController)
    }

    private func group(_ id: String, _ name: String, members: [String]) -> Group {
        Group(id: id, name: name, memberIDs: members, memberVolumes: [:])
    }

    // MARK: The grid follows the model

    @Test func cardsFollowTheSavedGroupsInOrder() throws {
        let (overview, _) = try makeOverview(groups: [
            group("g1", "Downstairs", members: ["office"]),
            group("g2", "Whole House", members: ["office", "kitchen"]),
            group("g3", "Bedroom", members: ["bed"]),
        ])

        #expect(overview.test_cardGroupIDs == ["g1", "g2", "g3"],
                "one card per saved group, in the model's order")
        #expect(!overview.test_isShowingEmptyCanvas, "with groups saved the grid is the canvas")
    }

    @Test func aSavedGroupAddedLaterAppearsOnTheNextReload() throws {
        let (overview, groupController) = try makeOverview(groups: [
            group("g1", "Downstairs", members: ["office"]),
        ])
        #expect(overview.test_cardGroupIDs == ["g1"])

        _ = try groupController.saveGroup(group("g2", "Bedroom", members: ["bed"]))
        overview.reload(devices: [])

        #expect(overview.test_cardGroupIDs == ["g1", "g2"],
                "the overview re-reads the shared GroupController on every reload")
    }

    // MARK: Gold means LIVE

    @Test func onlyTheActiveGroupsCardWearsTheLiveMarker() throws {
        let (overview, groupController) = try makeOverview(
            groups: [group("g1", "Downstairs", members: ["office"]),
                     group("g2", "Bedroom", members: ["bed"])],
            activate: "g2")

        #expect(groupController.activeGroupID == "g2", "fixture precondition")
        #expect(overview.test_cardShowsLive(id: "g2"), "the active Main Out group's card is live")
        #expect(!overview.test_cardShowsLive(id: "g1"), "every other card stays quiet")
    }

    @Test func noCardIsLiveWhenNoGroupIsActive() throws {
        let (overview, _) = try makeOverview(groups: [
            group("g1", "Downstairs", members: ["office"]),
        ])
        #expect(!overview.test_cardShowsLive(id: "g1"))
    }

    // MARK: Member chips

    @Test func memberChipsStopAtFourAndTheRestBecomeAnOverflowChip() throws {
        let members = ["a", "b", "c", "d", "e", "f"]
        let (overview, _) = try makeOverview(
            groups: [group("g1", "Whole House", members: members)],
            devices: members.map(makeDevice))

        #expect(overview.test_chipCount(forCard: "g1") == 4, "at most four member chips")
        #expect(overview.test_overflowChipText(forCard: "g1") == "+2",
                "the members past the fourth collapse into one dashed chip")
    }

    @Test func aSmallGroupDrawsAChipPerMemberAndNoOverflow() throws {
        let members = ["a", "b"]
        let (overview, _) = try makeOverview(
            groups: [group("g1", "Pair", members: members)],
            devices: members.map(makeDevice))

        #expect(overview.test_chipCount(forCard: "g1") == 2)
        #expect(overview.test_overflowChipText(forCard: "g1") == nil,
                "no overflow chip when every member already has one")
    }

    @Test func exactlyFourMembersDrawFourChipsAndNoOverflow() throws {
        let members = ["a", "b", "c", "d"]
        let (overview, _) = try makeOverview(
            groups: [group("g1", "Four", members: members)],
            devices: members.map(makeDevice))

        #expect(overview.test_chipCount(forCard: "g1") == 4)
        #expect(overview.test_overflowChipText(forCard: "g1") == nil, "four is the cap, not the trigger")
    }

    // MARK: Opening a card

    @Test func clickingACardOpensThatGroup() throws {
        let (overview, _) = try makeOverview(groups: [
            group("g1", "Downstairs", members: ["office"]),
            group("g2", "Bedroom", members: ["bed"]),
        ])
        var opened: [String] = []
        overview.onOpenGroup = { opened.append($0) }

        overview.test_clickCard(id: "g2")

        #expect(opened == ["g2"], "the card reports its own group, once")
    }

    @Test func returnOnTheSelectedCardOpensIt() throws {
        let (overview, _) = try makeOverview(groups: [
            group("g1", "Downstairs", members: ["office"]),
            group("g2", "Bedroom", members: ["bed"]),
        ])
        var opened: [String] = []
        overview.onOpenGroup = { opened.append($0) }

        overview.test_selectCard(id: "g1")
        #expect(opened.isEmpty, "selection alone never opens — arrow keys only move")

        overview.test_openSelectedCard()
        #expect(opened == ["g1"], "Return opens whatever the grid has selected")
    }

    @Test func openingACardNeverActivatesIt() throws {
        let (overview, groupController) = try makeOverview(groups: [
            group("g1", "Downstairs", members: ["office"]),
        ])
        overview.test_clickCard(id: "g1")

        #expect(groupController.activeGroupID == nil,
                "the Groups screen is CONFIGURATION-ONLY — opening an editor never routes audio")
    }

    // MARK: New Group

    @Test func theNewTileFiresTheCreationCallback() throws {
        let (overview, _) = try makeOverview(groups: [
            group("g1", "Downstairs", members: ["office"]),
        ])
        var newGroupCount = 0
        overview.onNewGroup = { newGroupCount += 1 }

        overview.test_tapNewGroup()

        #expect(newGroupCount == 1)
    }

    // MARK: Context menu (relocated from the sidebar's group rows)

    @Test func aCardsContextMenuIsRenameAndDelete() throws {
        let (overview, _) = try makeOverview(groups: [
            group("g1", "Downstairs", members: ["office"]),
        ])

        #expect(overview.test_contextMenuItems(forCard: "g1") == ["Rename…", "Delete Group…"],
                "the sidebar's old group-row titles, verbatim")
    }

    @Test func theContextMenuItemsReportTheClickedCardsGroup() throws {
        let (overview, _) = try makeOverview(groups: [
            group("g1", "Downstairs", members: ["office"]),
            group("g2", "Bedroom", members: ["bed"]),
        ])
        var renamed: [String] = []
        var deleted: [String] = []
        overview.onRequestRename = { renamed.append($0) }
        overview.onRequestDelete = { deleted.append($0) }

        overview.test_clickContextMenuItem("Rename…", forCard: "g2")
        overview.test_clickContextMenuItem("Delete Group…", forCard: "g1")

        #expect(renamed == ["g2"])
        #expect(deleted == ["g1"])
    }

    // MARK: The empty canvas (absorbed from GroupsEmptyStateViewController)

    @Test func zeroGroupsShowsTheEmptyCanvasWithItsLockedCopy() throws {
        let (overview, _) = try makeOverview(groups: [])

        #expect(overview.test_cardGroupIDs.isEmpty)
        #expect(overview.test_isShowingEmptyCanvas,
                "with nothing saved the overview IS the empty state — there is no separate pane")
        #expect(overview.test_emptyMessageText == "Group your speakers")
        #expect(overview.test_emptySubtitleText ==
                "Save a set of speakers as a group, then switch to it in two clicks from the menu bar.")
    }

    @Test func theEmptyCanvasTileRunsTheSameCreationPath() throws {
        let (overview, _) = try makeOverview(groups: [])
        var newGroupCount = 0
        overview.onNewGroup = { newGroupCount += 1 }

        overview.test_tapNewGroup()

        #expect(newGroupCount == 1, "both doors — grid tile and empty canvas — are one sheet")
    }

    // MARK: The empty canvas's tile is operable without a mouse

    @Test func theEmptyCanvasTileTakesKeyboardFocusAndOpensOnSpaceOrReturn() throws {
        let (overview, _) = try makeOverview(groups: [])
        var newGroupCount = 0
        overview.onNewGroup = { newGroupCount += 1 }

        #expect(overview.test_emptyTileAcceptsFocus,
                "the stock NSButton this canvas replaced was a Tab stop — so is the tile")

        overview.test_pressKeyOnEmptyTile(" ")
        overview.test_pressKeyOnEmptyTile("\r")

        #expect(newGroupCount == 2, "Space and Return both press the tile")
    }

    @Test func theEmptyCanvasTileRespondsToAVoiceOverPress() throws {
        let (overview, _) = try makeOverview(groups: [])
        var newGroupCount = 0
        overview.onNewGroup = { newGroupCount += 1 }

        #expect(overview.test_accessibilityPressEmptyTile(),
                "it wears the button role, so it must honour the press")
        #expect(newGroupCount == 1, "the press runs the same creation path a click does")
    }

    @Test func theEmptyCanvasTileIgnoresKeysItHasNoOpinionOn() throws {
        let (overview, _) = try makeOverview(groups: [])
        var newGroupCount = 0
        overview.onNewGroup = { newGroupCount += 1 }

        overview.test_pressKeyOnEmptyTile("a")

        #expect(newGroupCount == 0, "only Space/Return/keypad Enter are a press")
    }

    // MARK: Selection never survives a rebuild

    @Test func reloadingClearsTheGridsSelection() throws {
        let (overview, _) = try makeOverview(groups: [
            group("g1", "Downstairs", members: ["office"]),
            group("g2", "Bedroom", members: ["bed"]),
        ])
        var opened: [String] = []
        overview.onOpenGroup = { opened.append($0) }

        overview.test_selectCard(id: "g1")
        #expect(overview.test_hasSelectedCard, "fixture precondition")

        overview.reload(devices: [])

        #expect(!overview.test_hasSelectedCard,
                "a rebuild drops the collection view's own selection — the mirror follows it")
        overview.test_openSelectedCard()
        #expect(opened.isEmpty, "with nothing selected, Return opens nothing")
    }

    @Test func deletingTheSelectedGroupNeverLeavesReturnPointingAtAnotherCard() throws {
        let (overview, groupController) = try makeOverview(groups: [
            group("g1", "Downstairs", members: ["office"]),
            group("g2", "Bedroom", members: ["bed"]),
        ])
        var opened: [String] = []
        overview.onOpenGroup = { opened.append($0) }

        overview.test_selectCard(id: "g1")
        try groupController.deleteGroup(id: "g1")
        overview.reload(devices: [])

        #expect(overview.test_cardGroupIDs == ["g2"], "fixture precondition")
        overview.test_openSelectedCard()
        #expect(opened.isEmpty,
                "index 0 now belongs to a DIFFERENT group — a stale mirror would open it")
    }

    @Test func savingTheFirstGroupRetiresTheEmptyCanvas() throws {
        let (overview, groupController) = try makeOverview(groups: [])
        #expect(overview.test_isShowingEmptyCanvas)

        _ = try groupController.saveGroup(group("g1", "Downstairs", members: ["office"]))
        overview.reload(devices: [])

        #expect(!overview.test_isShowingEmptyCanvas, "the grid takes the canvas back")
        #expect(overview.test_cardGroupIDs == ["g1"])
    }
}
