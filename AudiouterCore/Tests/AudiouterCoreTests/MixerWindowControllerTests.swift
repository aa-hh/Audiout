// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
import AppKit
@testable import AudiouterCore
@testable import AudiouterSharedUI
@testable import AudiouterWindowUI

/// Structural + integration coverage for the Groups SCREEN's content
/// controller (design revamp, SPEC §9; the standalone window was retired in
/// U6). The content isn't visible to CI, so these assert the *built*
/// structure and that interactions call through the model — the same
/// checks the `window-harness` executable runs, folded into `swift test`.
///
/// The screen is CONFIGURATION-ONLY under the revamp: viewing/editing groups
/// here never activates them or moves audio (activation lives in the app's
/// Mixer screen). Group creation is a standard macOS sheet
/// (`GroupCreationSheetController`), not an in-pane draft.
///
/// `MixerWindowController` is `@MainActor`; these cases are `@MainActor` so they
/// touch it (and the non-`Sendable` `GroupController`) on the main thread,
/// exactly as the app does.
@MainActor
@Suite final class MixerWindowControllerTests: IsolatedSuite {

    /// A MockBackend with the full demo fleet discovered, a GroupController, and
    /// a `MixerWindowController` with the devices pushed in.
    private func makeWindow() async throws -> (MixerWindowController, GroupController, MockBackend) {
        let backend = MockBackend(fleet: .demoFleet, staggerDiscovery: false,
                                  emitsLevels: false, simulatesDropouts: false)
        try await waitForFleet(backend, count: 7)
        let store = GroupStore(directory: tempDirectory())
        let controller = GroupController(backend: backend, store: store, loadPersisted: false)
        let window = MixerWindowController(groupController: controller)
        // Headless test seam: simulate the content being visible so update(devices:)
        // refreshes the UI tree (same pattern: PopoverController.test_isShownOverride / B8).
        window.test_isVisibleOverride = true
        window.update(devices: backend.devices)
        return (window, controller, backend)
    }

    /// Compose a two-AirPlay-device Selected Devices set and save it as a group
    /// ("Group 1"). Under the SPEC §9b model `saveCurrentSetupAsGroup` builds from
    /// the Selected Devices set, so tests that want a populated group compose it
    /// first via this helper.
    @discardableResult
    private func makeGroup1(_ controller: GroupController) throws -> Group {
        _ = controller.setDeviceSelected("sonos-move", true)
        _ = controller.setDeviceSelected("office", true)
        return try controller.saveCurrentSetupAsGroup(name: "Group 1").group
    }

    private func waitForFleet(_ backend: MockBackend, count: Int) async throws {
        let stream = backend.makeEventStream()
        let box = WindowTestCountBox()
        try await confirmation("fleet discovered") { discovered in
            let task = Task {
                for await event in stream {
                    if case .deviceAdded = event, await box.increment() >= count {
                        discovered(); break
                    }
                }
            }
            defer { task.cancel() }
            backend.start()
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { _ = await task.value }
                group.addTask { try await Task.sleep(for: .seconds(2)) }
                try await group.next()
                group.cancelAll()
            }
        }
    }

    /// Like `makeWindow()`, but also constructs and injects a
    /// `DeviceIconController` (non-persisted, its own temp store) so a test
    /// can drive icon overrides and assert they reach a shared mixer row.
    private func makeWindowWithIconController() async throws
        -> (MixerWindowController, GroupController, MockBackend, DeviceIconController) {
        let backend = MockBackend(fleet: .demoFleet, staggerDiscovery: false,
                                  emitsLevels: false, simulatesDropouts: false)
        try await waitForFleet(backend, count: 7)
        let store = GroupStore(directory: tempDirectory())
        let controller = GroupController(backend: backend, store: store, loadPersisted: false)
        let iconController = DeviceIconController(store: DeviceIconStore(directory: tempDirectory()),
                                                   loadPersisted: false)
        let window = MixerWindowController(groupController: controller, deviceIconController: iconController)
        // Headless test seam: simulate the content being visible so update(devices:)
        // refreshes the UI tree (same pattern: PopoverController.test_isShownOverride / B8).
        window.test_isVisibleOverride = true
        window.update(devices: backend.devices)
        return (window, controller, backend, iconController)
    }

    private func tempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MixerWindowControllerTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Let queued MockBackend echoes drain before asserting on backend state.
    private func drain() async {
        try? await Task.sleep(nanoseconds: 150_000_000)
    }

    /// Hosted as the surface's Groups screen (U4) this controller owns no
    /// window, so `setHostVisible(_:)` is what tells it the
    /// user is looking at its content. Turning it on must CATCH UP on whatever
    /// arrived while it was hidden — otherwise every speaker discovered before
    /// the Groups tab was first opened would be missing from the sidebar for
    /// the rest of the session.
    @Test func hostVisibilityOpensTheRefreshGateAndCatchesUp() async throws {
        let backend = MockBackend(fleet: .demoFleet, staggerDiscovery: false,
                                  emitsLevels: false, simulatesDropouts: false)
        try await waitForFleet(backend, count: 7)
        let store = GroupStore(directory: tempDirectory())
        let controller = GroupController(backend: backend, store: store, loadPersisted: false)
        let window = MixerWindowController(groupController: controller)

        window.update(devices: backend.devices)
        #expect(window.test_sidebar.test_deviceRowCount == 0,
                "no host is showing the content, so the snapshot is only stored (B8)")

        window.setHostVisible(true)
        #expect(window.test_sidebar.test_deviceRowCount == 7,
                "becoming the visible screen refreshes from the stored snapshot")
    }

    // MARK: Sidebar structure (config-only revamp: always both sections)

    @Test func sidebarAlwaysShowsGroupsAndSpeakersSections() async throws {
        let (window, _, _) = try await makeWindow()
        #expect(window.test_sidebar.test_sectionTitles == ["System Audio", "Groups", "Speakers"])
        #expect(window.test_sidebar.test_hasGroupsEmptyStateRow, "zero saved groups shows the empty-state placeholder row")
        #expect(window.test_sidebar.test_deviceRowCount == 7)
        #expect(!(window.test_isShowingEditor))
    }

    /// The sidebar must survive every route to a collapse. A collapsed sidebar
    /// is unrecoverable — no toolbar sidebar toggle, no View menu, and this
    /// controller is reused for the process lifetime — and it is the ONLY way
    /// to change selection, so a collapse strands the user on one group's
    /// editor. `canCollapse` refuses the user's divider drag; the refresh
    /// re-assert covers AppKit's own narrow-layout auto-collapse.
    @Test func theSidebarCannotBeCollapsedAway() async throws {
        let (window, controller, backend) = try await makeWindow()
        let split = try #require(window.contentController as? NSSplitViewController)
        let sidebarItem = try #require(split.splitViewItems.first)
        #expect(!sidebarItem.canCollapse, "the user's divider drag cannot collapse it")

        // AppKit's own auto-collapse takes this route; recovery is on us.
        sidebarItem.isCollapsed = true
        _ = try makeGroup1(controller)
        window.update(devices: backend.devices)
        #expect(!sidebarItem.isCollapsed, "a refresh restores a collapsed sidebar")
        #expect(window.test_sidebar.test_sectionTitles == ["System Audio", "Groups", "Speakers"],
                "and it still lists both sections")
    }

    @Test func baselineContentIsEmptyStateAtZeroGroups() async throws {
        let (window, _, _) = try await makeWindow()
        #expect(window.test_isShowingEmptyState, "zero groups + no selection auto-lands on the 'No groups yet' pane")
    }

    @Test func emptyStateNewGroupButtonPresentsCreationSheet() async throws {
        let (window, _, _) = try await makeWindow()
        #expect(window.test_isShowingEmptyState)
        // The empty pane's call-to-action runs the same sheet as the sidebar "+".
        window.test_emptyState.test_tapNewGroup()
        #expect(window.test_isPresentingCreateSheet)
        window.test_createSheet?.test_cancel()
    }

    @Test func autoSelectLandsOnFirstGroupsEditor() async throws {
        let (window, controller, backend) = try await makeWindow()
        let saved = try makeGroup1(controller)
        window.update(devices: backend.devices)
        await drain()
        #expect(window.test_isShowingEditor, "with a saved group and no selection, the window auto-selects it")
        #expect(window.test_editor.editingGroupID == saved.id)
        #expect(window.test_sidebar.currentSelection == .group(id: saved.id))
        #expect(controller.activeGroupID == nil, "auto-select never activates")
    }

    @Test func savingGroupAddsFlatGroupRowClearsEmptyStateAndKeepsAllDevicesListed() async throws {
        let (window, controller, backend) = try await makeWindow()
        _ = try makeGroup1(controller)
        window.update(devices: backend.devices)

        #expect(window.test_sidebar.test_sectionTitles == ["System Audio", "Groups", "Speakers"])
        #expect(!(window.test_sidebar.test_hasGroupsEmptyStateRow))
        #expect(window.test_sidebar.test_groupRowCount == 1)
        #expect(window.test_sidebar.test_groupRowsAreFlat, "a group row is a flat leaf — no expandable member children (design review 2026-07-18)")
        #expect(window.test_sidebar.test_deviceRowCount == 7, "the Devices section lists every device, including a saved group's members, since membership is previewed in the editor now, not by sidebar expansion")
    }

    @Test func sidebarSupportsMultipleSelection() async throws {
        let (window, _, _) = try await makeWindow()
        #expect(window.test_sidebar.test_allowsMultipleSelection)
    }

    /// `update(devices:)` fires on every backend event for the app's whole
    /// lifetime — an EQ-only change touches nothing any sidebar cell renders,
    /// so it must not rebuild the sidebar's node tree. A change the sidebar
    /// DOES render (a rename) must still reload.
    @Test func sidebarReloadSkipsAnEQOnlyChangeButNotARename() async throws {
        let (window, _, backend) = try await makeWindow()
        let baseline = window.test_sidebarReloadCount
        #expect(baseline > 0, "the initial makeWindow() snapshot already reloaded once")

        var eqOnly = backend.devices
        eqOnly[0].eq = DeviceEQ(bassDB: 4)
        window.update(devices: eqOnly)
        #expect(window.test_sidebarReloadCount == baseline,
                "no sidebar cell shows a tone value, so this must be a no-op reload")

        var renamed = eqOnly
        renamed[0].name += " (renamed)"
        window.update(devices: renamed)
        #expect(window.test_sidebarReloadCount == baseline + 1,
                "a name change IS on a sidebar cell, so it must reload")
    }

    @Test func sidebarReloadDetectsAnIconOverrideOnlyChange() async throws {
        let (window, _, _, icons) = try await makeWindowWithIconController()
        let baseline = window.test_sidebarReloadCount
        #expect(baseline > 0, "the initial makeWindow() snapshot already reloaded once")

        icons.setSymbolName("sofa.fill", for: "office")
        #expect(window.test_sidebarReloadCount == baseline + 1,
                "an icon override IS the rendered sidebar icon, so a same-id/name/kind/isAvailable change must still reload")
    }

    // MARK: New Group — sheet (SPEC.md §9, design revamp)

    @Test func tapAddRoutesToCreationSheet() async throws {
        let (window, controller, _) = try await makeWindow()
        window.test_sidebar.test_tapAdd()
        await drain()

        #expect(window.test_createSheet != nil, "the '+' with no selection presents the New Group sheet")
        #expect(controller.groups.count == 0, "presenting the sheet creates nothing")
    }

    @Test func createSheetShowsATitleAndAnEditablePencilOnItsIconWell() async throws {
        let (window, _, _) = try await makeWindow()
        window.test_presentCreateSheet(preselected: [])
        await drain()
        let sheet = try #require(window.test_createSheet)

        #expect(sheet.test_titleText == "New Group", "the sheet names itself instead of opening as a bare form")
        #expect(sheet.test_iconWellShowsPencil, "bordered + pencil = editable — the icon well is editable, so it wears the same cue DeviceIconWellView does")
    }

    @Test func createSheetPrefillsPreselectedMembersChecked() async throws {
        let (window, _, _) = try await makeWindow()
        window.test_presentCreateSheet(preselected: ["office", "appletv-lr"])
        await drain()

        let sheet = try #require(window.test_createSheet)
        #expect(Set(sheet.test_checkedDeviceIDs) == ["office", "appletv-lr"], "the sheet is pre-populated with exactly the multi-selected speakers")
    }

    @Test func createSheetCreateDisabledAtZeroMembersEnabledAtOne() async throws {
        let (window, _, _) = try await makeWindow()
        window.test_presentCreateSheet(preselected: [])
        await drain()
        let sheet = try #require(window.test_createSheet)

        #expect(!(sheet.test_isCreateEnabled), "Create is disabled with zero members checked")

        sheet.test_setMembership(deviceID: "office", isChecked: true)
        #expect(sheet.test_isCreateEnabled, "Create enables once >= 1 member is checked")

        sheet.test_setMembership(deviceID: "office", isChecked: false)
        #expect(!(sheet.test_isCreateEnabled), "unchecking the only member disables Create again")
    }

    @Test func createSheetCommitCreatesExactlyCheckedMembers() async throws {
        let (window, controller, _) = try await makeWindow()
        window.test_presentCreateSheet(preselected: [])
        await drain()
        let sheet = try #require(window.test_createSheet)

        sheet.test_setName("Downstairs")
        sheet.test_setMembership(deviceID: "office", isChecked: true)
        sheet.test_setMembership(deviceID: "homepod-bed", isChecked: true)
        sheet.test_commit()
        await drain()

        #expect(controller.groups.count == 1)
        let group = try #require(controller.groups.first)
        #expect(group.name == "Downstairs")
        #expect(Set(group.memberIDs) == ["office", "homepod-bed"])
        #expect(Set(group.memberVolumes.keys) == Set(group.memberIDs), "each checked member gets a remembered volume")
    }

    @Test func createSheetCommitDoesNotActivate() async throws {
        let (window, controller, _) = try await makeWindow()
        #expect(controller.activeGroupID == nil)
        window.test_presentCreateSheet(preselected: [])
        await drain()
        let sheet = try #require(window.test_createSheet)

        sheet.test_setMembership(deviceID: "office", isChecked: true)
        sheet.test_commit()
        await drain()

        #expect(controller.groups.count == 1)
        #expect(controller.activeGroupID == nil, "creating a group never activates it — CONFIG-ONLY")
    }

    @Test func createSheetCommitAfterCreateSelectsAndOpensEditorWithoutActivating() async throws {
        let (window, controller, _) = try await makeWindow()
        window.test_presentCreateSheet(preselected: [])
        await drain()
        let sheet = try #require(window.test_createSheet)
        sheet.test_setMembership(deviceID: "office", isChecked: true)
        sheet.test_commit()
        await drain()

        let group = try #require(controller.groups.first)
        #expect(window.test_isShowingEditor, "creation opens the new group's editor")
        #expect(window.test_editor.editingGroupID == group.id)
        #expect(controller.activeGroupID == nil, "still not activated after opening the editor")
    }

    @Test func createSheetDedupsIdenticalMemberSetToExistingGroup() async throws {
        let (window, controller, _) = try await makeWindow()
        window.test_presentCreateSheet(preselected: ["office", "appletv-lr"])
        await drain()
        var sheet = try #require(window.test_createSheet)
        var completedResult: (group: Group, alreadyExisted: Bool)?
        sheet.onComplete = { completedResult = $0 }
        sheet.test_commit()
        await drain()
        #expect(controller.groups.count == 1)
        #expect(completedResult?.alreadyExisted == false)
        let firstID = controller.groups[0].id

        // Same member set again (order swapped) must resolve to the existing group.
        window.test_presentCreateSheet(preselected: ["appletv-lr", "office"])
        await drain()
        sheet = try #require(window.test_createSheet)
        completedResult = nil
        sheet.onComplete = { completedResult = $0 }
        sheet.test_commit()
        await drain()

        #expect(controller.groups.count == 1, "no duplicate group for an identical member set")
        #expect(completedResult?.group.id == firstID)
        #expect(completedResult?.alreadyExisted == true)
    }

    @Test func createSheetCandidatesExcludeUnavailableDevices() async throws {
        let (window, _, backend) = try await makeWindow()
        let unavailableID = "office"
        let devices = backend.devices.map { device -> Device in
            var d = device
            if d.id == unavailableID { d.isAvailable = false }
            return d
        }
        window.update(devices: devices)

        window.test_presentCreateSheet(preselected: [])
        await drain()
        let sheet = try #require(window.test_createSheet)

        #expect(!(sheet.test_candidateDeviceIDs.contains(unavailableID)), "a brand-new group never offers joining an unreachable speaker")
        #expect(sheet.test_candidateDeviceIDs.count == 6)
    }

    // MARK: Selecting a group → editor only, never activation

    @Test func selectingGroupShowsEditorAndDoesNotActivate() async throws {
        let (window, controller, backend) = try await makeWindow()
        let saved = try makeGroup1(controller)
        window.update(devices: backend.devices)
        #expect(controller.activeGroupID == nil)

        window.test_select(.group(id: saved.id))
        await drain()

        #expect(window.test_isShowingEditor)
        #expect(controller.activeGroupID == nil, "selecting a group in the sidebar never activates it")
        #expect(window.test_editor.editingGroupID == saved.id)
        #expect(Set(window.test_editor.test_checkedDeviceIDs) == Set(saved.memberIDs))
        #expect(window.test_editor.test_candidateDeviceIDs.count == 7)
    }

    // MARK: Editor candidates: unavailable devices stay only while a member

    @Test func editorCandidatesIncludeUnavailableDeviceOnlyIfMember() async throws {
        let (window, controller, backend) = try await makeWindow()
        let saved = try makeGroup1(controller)
        // "office" is a member of Group 1; mark it unavailable, and mark a
        // non-member ("appletv-lr") unavailable too, in the same push.
        let devices = backend.devices.map { device -> Device in
            var d = device
            if d.id == "office" || d.id == "appletv-lr" { d.isAvailable = false }
            return d
        }
        window.update(devices: devices)

        window.test_select(.group(id: saved.id))
        await drain()

        #expect(window.test_editor.test_candidateDeviceIDs.contains("office"), "an unavailable device stays offered while it remains a member")
        #expect(!(window.test_editor.test_candidateDeviceIDs.contains("appletv-lr")), "an unavailable non-member is not offered")
    }

    // MARK: Editor → GroupController

    @Test func renameInEditorCallsSaveGroup() async throws {
        let (window, controller, backend) = try await makeWindow()
        let saved = try makeGroup1(controller)
        window.update(devices: backend.devices)
        window.test_select(.group(id: saved.id))
        await drain()

        window.test_editor.test_rename(to: "Whole House")
        #expect(controller.groups.first { $0.id == saved.id }?.name == "Whole House")
    }

    @Test func membershipCheckboxUpdatesGroup() async throws {
        let (window, controller, backend) = try await makeWindow()
        let saved = try makeGroup1(controller)
        window.update(devices: backend.devices)
        window.test_select(.group(id: saved.id))
        await drain()

        let extra = try #require(backend.devices.first { !saved.memberIDs.contains($0.id) }?.id)
        let before = try #require(controller.groups.first { $0.id == saved.id }).memberIDs.count

        window.test_editor.test_setMembership(true, for: extra)
        #expect(controller.groups.first { $0.id == saved.id }?.memberIDs.count == before + 1)
        #expect(controller.groups.first { $0.id == saved.id }!.memberIDs.contains(extra))

        window.test_editor.test_setMembership(false, for: extra)
        #expect(controller.groups.first { $0.id == saved.id }?.memberIDs.count == before)
        #expect(!(controller.groups.first { $0.id == saved.id }!.memberIDs.contains(extra)))
    }

    @Test func cannotRemoveLastMemberOfGroupInEditor() async throws {
        let (window, controller, backend) = try await makeWindow()
        let saved = try makeGroup1(controller)   // 2 members: sonos-move, office
        window.update(devices: backend.devices)
        window.test_select(.group(id: saved.id))
        await drain()

        // Removing one of two members is allowed — the group drops to a single member.
        window.test_editor.test_setMembership(false, for: "office")
        #expect(controller.groups.first { $0.id == saved.id }?.memberIDs == ["sonos-move"], "one member removed, one remains")

        // The sole remaining member's checkbox is pinned (disabled) as the affordance.
        #expect(!(window.test_editor.test_isMembershipRowEnabled(for: "sonos-move")), "the last member's checkbox is disabled so it can't be unchecked")

        // Attempting to remove the last member is refused: the group keeps it and
        // the row reverts to checked (delete the group instead to remove it).
        window.test_editor.test_setMembership(false, for: "sonos-move")
        #expect(controller.groups.first { $0.id == saved.id }?.memberIDs == ["sonos-move"], "removing the last member must be refused — the group stays non-empty")
        #expect(window.test_editor.test_checkedDeviceIDs.contains("sonos-move"), "the reverted checkbox shows the member still belongs")
    }

    @Test func deleteInEditorCallsDeleteGroupAndReturnsToMixer() async throws {
        let (window, controller, backend) = try await makeWindow()
        let saved = try makeGroup1(controller)
        window.update(devices: backend.devices)
        window.test_select(.group(id: saved.id))
        await drain()
        #expect(window.test_isShowingEditor)

        window.test_editor.test_confirmDelete()
        await drain()

        #expect(controller.groups.count == 0)
        #expect(!(window.test_isShowingEditor))
        #expect(window.test_isShowingEmptyState, "deleting the last group falls back to the 'No groups yet' pane")
        #expect(window.test_sidebar.test_hasGroupsEmptyStateRow, "the Groups section stays but shows the empty state again")
    }

    // MARK: Selecting a device → detail pane (config-only, never activation)

    @Test func selectingDeviceShowsDetailPaneWithMetadataAndGroupMembership() async throws {
        let (window, controller, backend) = try await makeWindow()
        // Untouched by makeGroup1 below (which selects sonos-move + office,
        // actually connecting them) — a clean "Not connected" / "None" case.
        window.test_select(.device(id: "appletv-lr"))
        await drain()

        #expect(window.test_isShowingDetail)
        #expect(!(window.test_isShowingEditor))
        #expect(window.test_detail.test_shownDeviceID == "appletv-lr")
        #expect(window.test_detail.test_metadataStrings["volume"] == "60%")
        #expect(window.test_detail.test_metadataStrings["available"] == "Yes")
        #expect(window.test_detail.test_metadataStrings["status"] == "Not connected")
        #expect(window.test_detail.test_groupMembershipText == "None", "appletv-lr isn't a member of any saved group")

        let saved = try makeGroup1(controller)   // members: sonos-move, office
        window.update(devices: backend.devices)

        window.test_select(.device(id: "office"))
        await drain()

        #expect(window.test_isShowingDetail)
        #expect(window.test_detail.test_shownDeviceID == "office")
        #expect(window.test_detail.test_groupMembershipText == saved.name, "office is a Group 1 member")
    }

    @Test func deselectingDeviceAutoSelectsFirstGroupOrEmptyState() async throws {
        let (window, controller, backend) = try await makeWindow()
        window.test_select(.device(id: "office"))
        await drain()
        #expect(window.test_isShowingDetail)

        window.test_select(nil)
        await drain()
        #expect(!(window.test_isShowingDetail))
        #expect(window.test_isShowingEmptyState, "no groups: deselecting a device lands on the empty pane")

        let saved = try makeGroup1(controller)
        window.update(devices: backend.devices)
        window.test_select(.device(id: "office"))
        await drain()
        window.test_select(nil)
        await drain()
        #expect(window.test_isShowingEditor, "with a saved group, deselecting auto-selects its editor")
        #expect(window.test_editor.editingGroupID == saved.id)
    }

    @Test func selectingUnknownDeviceIDFallsBackToDefaultContent() async throws {
        let (window, _, _) = try await makeWindow()
        window.test_select(.device(id: "does-not-exist"))
        await drain()

        #expect(!(window.test_isShowingDetail))
        #expect(window.test_isShowingEmptyState)
        #expect(window.test_detail.test_shownDeviceID == nil, "the detail pane was never actually shown")
    }

    @Test func selectingDeviceNeverActivatesAGroup() async throws {
        let (window, controller, backend) = try await makeWindow()
        let saved = try makeGroup1(controller)
        window.update(devices: backend.devices)
        #expect(controller.activeGroupID == nil)

        window.test_select(.device(id: saved.memberIDs[0]))
        await drain()

        #expect(window.test_isShowingDetail)
        #expect(controller.activeGroupID == nil, "selecting a device in the sidebar never activates anything")
    }

    @Test func detailPaneRefreshesLiveWhenDeviceSnapshotChanges() async throws {
        let (window, _, backend) = try await makeWindow()
        window.test_select(.device(id: "office"))
        await drain()
        #expect(window.test_detail.test_metadataStrings["volume"] == "50%")

        let updated = backend.devices.map { device -> Device in
            var d = device
            if d.id == "office" { d.volume = 77 }
            return d
        }
        window.update(devices: updated)

        #expect(window.test_isShowingDetail, "still showing the detail pane, just re-rendered")
        #expect(window.test_detail.test_metadataStrings["volume"] == "77%", "refreshAll() re-renders the visible detail pane from the fresher snapshot")
    }

    @Test func refreshAllFallsBackWhenShownDeviceDisappears() async throws {
        let (window, _, backend) = try await makeWindow()
        window.test_select(.device(id: "office"))
        await drain()
        #expect(window.test_isShowingDetail)

        let devicesWithoutOffice = backend.devices.filter { $0.id != "office" }
        window.update(devices: devicesWithoutOffice)

        #expect(!(window.test_isShowingDetail), "refreshAll() falls back to the default content once the shown device vanishes")
        #expect(window.test_isShowingEmptyState, "no groups saved, so the fallback is the empty pane")
    }

    // MARK: Icon flows

    @Test func editorIconPickPersistsThroughSaveGroup() async throws {
        let (window, controller, backend) = try await makeWindow()
        let saved = try makeGroup1(controller)
        window.update(devices: backend.devices)
        window.test_select(.group(id: saved.id))
        await drain()
        #expect(controller.groups.first { $0.id == saved.id }?.iconSymbolName == nil)

        window.test_editor.test_pickIcon("airpods")

        #expect(controller.groups.first { $0.id == saved.id }?.iconSymbolName == "airpods", "the editor's icon pick persists group.iconSymbolName through saveGroup")
        #expect(window.test_editor.test_iconWellSymbolName == "airpods")
    }

    @Test func createSheetChosenIconLandsOnCreatedGroup() async throws {
        let (window, controller, _) = try await makeWindow()
        window.test_presentCreateSheet(preselected: [])
        await drain()
        let sheet = try #require(window.test_createSheet)

        sheet.test_setMembership(deviceID: "office", isChecked: true)
        sheet.test_pickIcon("airpods")
        sheet.test_commit()
        await drain()

        let group = try #require(controller.groups.first)
        #expect(group.iconSymbolName == "airpods", "the sheet's chosen icon lands on the created group")
    }

    @Test func createSheetDedupDoesNotOverwriteExistingGroupsIcon() async throws {
        let (window, controller, _) = try await makeWindow()
        window.test_presentCreateSheet(preselected: ["office", "appletv-lr"])
        await drain()
        var sheet = try #require(window.test_createSheet)
        sheet.test_pickIcon("airpods")
        sheet.test_commit()
        await drain()
        #expect(controller.groups.count == 1)
        let firstID = controller.groups[0].id
        #expect(controller.groups[0].iconSymbolName == "airpods")

        // Same member set again (order swapped), a DIFFERENT icon picked —
        // dedups onto the existing group, whose own icon must win
        // (`GroupController.createGroup`'s documented dedup rule).
        window.test_presentCreateSheet(preselected: ["appletv-lr", "office"])
        await drain()
        sheet = try #require(window.test_createSheet)
        sheet.test_pickIcon("homepod.fill")
        sheet.test_commit()
        await drain()

        #expect(controller.groups.count == 1, "no duplicate group for an identical member set")
        #expect(controller.groups.first { $0.id == firstID }?.iconSymbolName == "airpods", "dedup resolves to the existing group and does NOT overwrite its icon")
    }

    @Test func deviceIconControllerOverrideReachesEditorMembershipRow() async throws {
        let (window, controller, backend, icons) = try await makeWindowWithIconController()
        let saved = try makeGroup1(controller)   // members incl. office
        icons.setSymbolName("sofa.fill", for: "office")
        window.update(devices: backend.devices)
        window.test_select(.group(id: saved.id))
        await drain()
        // The mixer pane is gone (live-test feedback) — the shared override's
        // window-side rendering surface is the editor's membership rows.
        #expect(window.test_editor.test_candidateDeviceIDs.contains("office"))
        #expect(icons.symbolName(for: backend.devices.first { $0.id == "office" }!) == "sofa.fill", "the shared controller resolves the override the row renders")
    }

    // MARK: Keyboard focus (A11Y-GROUPS)
    //
    // Live-test finding: pressing Tab did nothing anywhere in the Groups
    // window, because nothing in its lifecycle ever calls
    // `NSWindow.makeFirstResponder(_:)` — so a freshly-shown window has no
    // real first responder to advance Tab FROM. `SidebarViewController`'s
    // `viewDidAppear()` override seeds the outline view as first responder
    // (see its doc comment for the full root-cause writeup); this asserts
    // that seed fires exactly the way a real hosting window appearing would
    // trigger it, without needing an actual on-screen window (never available
    // under `swift test`). The controller owns no window (U6), so the tests
    // stand a plain host window in for the surface's shell.

    @Test func contentHasNoFirstResponderBeforeItEverAppears() async throws {
        let (window, _, _) = try await makeWindow()
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 505),
                            styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        host.contentViewController = window.contentController
        // Before `viewDidAppear()` has ever run, the host's first responder
        // is itself — nothing has claimed it. This is the exact state a live
        // Tab press found: nothing to advance from.
        #expect(window.test_sidebar.view.window === host)
        #expect(!(window.test_sidebar.test_isOutlineViewFirstResponder))
    }

    @Test func sidebarViewDidAppearSeedsTheOutlineViewAsFirstResponder() async throws {
        let (window, _, _) = try await makeWindow()
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 505),
                            styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        host.contentViewController = window.contentController
        window.test_sidebar.test_simulateViewDidAppear()
        #expect(window.test_sidebar.test_isOutlineViewFirstResponder, "the sidebar's outline view must become first responder once the content appears, or Tab has nothing to advance from")
    }

    // MARK: Active-group marker (sidebar)

    @Test func sidebarMarksTheActiveGroupsRow() async throws {
        let (window, controller, backend) = try await makeWindow()
        let saved = try makeGroup1(controller)
        window.update(devices: backend.devices)
        #expect(!window.test_sidebar.test_groupRowShowsActiveMarker(id: saved.id),
                "no marker while the group isn't the active Main Out")

        controller.activateGroup(id: saved.id)
        window.update(devices: backend.devices)
        #expect(window.test_sidebar.test_groupRowShowsActiveMarker(id: saved.id),
                "the active group's row carries the gold playing marker")
    }

    // MARK: Add-button retitle (multi-select discoverability)

    @Test func addButtonRetitlesWhileSpeakersAreMultiSelected() async throws {
        let (window, _, _) = try await makeWindow()
        #expect(window.test_sidebar.test_addButtonTitle == "New Group…")

        window.test_sidebar.test_selectDevices(["office", "sonos-move", "sonos-move-2"])
        #expect(window.test_sidebar.test_addButtonTitle == "New Group from 3 Speakers…",
                "the button says what + will actually do while speakers are multi-selected")

        window.test_sidebar.test_selectDevices([])
        #expect(window.test_sidebar.test_addButtonTitle == "New Group…")
    }

    // MARK: Selection-seeded create-sheet name

    @Test func createSheetPrefillsNameFromTheSelectedSpeakers() async throws {
        let (window, _, _) = try await makeWindow()
        window.test_presentCreateSheet(preselected: ["office", "sonos-move"])
        let sheet = try #require(window.test_createSheet)
        let candidates = sheet.test_candidateDeviceIDs   // sanity: both offered
        #expect(candidates.contains("office") && candidates.contains("sonos-move"))
        #expect(sheet.test_nameFieldText == "Office + Sonos Move")
    }

    // MARK: Deep link from the popover ("Equalizer…")

    @Test func selectDeviceShowsItsDetailAndHighlightsTheSidebarRow() async throws {
        let (window, _, _) = try await makeWindow()

        window.select(.device(id: "office"))

        #expect(window.test_isShowingDetail)
        #expect(window.test_detail.test_shownDeviceID == "office")
        #expect(window.test_sidebar.currentSelection == .device(id: "office"),
                "the deep link highlights the row too — arriving on a pane whose sidebar shows nothing selected reads as a bug")
    }

    @Test func selectingAnUnknownDevicePendsUntilTheSnapshotCarriesIt() async throws {
        let (window, _, backend) = try await makeWindow()

        window.select(.device(id: "ghost"))
        #expect(!window.test_isShowingDetail,
                "a device this screen has never been told about doesn't fall back to the default pane")
        #expect(window.test_pendingSelection == .device(id: "ghost"))

        let ghost = Device(id: "ghost", name: "Ghost", kind: .generic, isAvailable: true)
        window.update(devices: backend.devices + [ghost])

        #expect(window.test_isShowingDetail)
        #expect(window.test_detail.test_shownDeviceID == "ghost")
        #expect(window.test_pendingSelection == nil, "the deep link is spent, not repeated")
    }

    @Test func selectMainAudioShowsTheWholeMixPage() async throws {
        let (window, _, _) = try await makeWindow()
        window.mainOutEQProvider = { DeviceEQ(bassDB: 2) }

        window.select(.mainOut)

        #expect(window.test_isShowingMainOut)
        #expect(window.test_mainOutDetail.test_eqEditor.currentEQ.bassDB == 2,
                "the page pulls the whole mix's current tone when it opens")
        #expect(window.test_mainOutDetail.test_noteText == "Applies to audio sent to speakers.")
        #expect(window.test_mainOutDetail.test_titleText == "Main Audio")
    }

    @Test func mainOutScrubSurvivesASnapshotAndTheEchoReleasesTheCache() async throws {
        let (window, _, _) = try await makeWindow()
        window.mainOutEQProvider = { .flat }
        window.select(.mainOut)

        let detail = window.test_mainOutDetail
        let editor = detail.test_eqEditor

        // Mid-drag: a snapshot carrying the OLD value must not rewind the slider.
        editor.test_committedGestureOverride = false
        editor.test_dragBass(to: 5)
        detail.show(eq: .flat)
        #expect(editor.currentEQ.bassDB == 5,
                "a snapshot arriving mid-gesture can't yank the slider out from under the pointer")

        // Committed: the entry awaits its own echo — a stale flat snapshot
        // already queued from before the commit must not replay the drag
        // backward.
        editor.test_committedGestureOverride = true
        editor.test_dragBass(to: 5)
        detail.show(eq: .flat)
        #expect(editor.currentEQ.bassDB == 5,
                "a stale snapshot queued before the commit must not replay the drag on the knob")

        // The committed value's own echo releases the cache.
        detail.show(eq: DeviceEQ(bassDB: 5))
        #expect(editor.currentEQ.bassDB == 5)

        // Proof the cache is gone: a LATER flat snapshot now renders flat.
        detail.show(eq: .flat)
        #expect(editor.currentEQ.bassDB == 0,
                "kept past the echo the cache lies forever — the page would show a shaped curve while the audio stayed flat")
    }

    // MARK: The two tone seams

    @Test func mainAudioEditsReportOnTheWholeMixSeam() async throws {
        let (window, _, _) = try await makeWindow()
        var reported: [(DeviceEQ, Bool)] = []
        window.onSetMainOutEQ = { eq, committed in reported.append((eq, committed)) }
        window.select(.mainOut)

        let editor = window.test_mainOutDetail.test_eqEditor
        editor.test_committedGestureOverride = false
        editor.test_dragTreble(to: -4)
        #expect(reported.last?.0.trebleDB == -4)
        #expect(reported.last?.1 == false, "a live scrub applies but must not persist")

        editor.test_committedGestureOverride = true
        editor.test_dragTreble(to: -4)
        #expect(reported.last?.1 == true, "the gesture that ends the drag persists")

        editor.test_fireResetClick()
        #expect(reported.last?.0 == .flat)
        #expect(reported.last?.1 == true, "Reset is one committed action")
    }

    @Test func deviceEditsReportWithTheDeviceID() async throws {
        let (window, _, _) = try await makeWindow()
        var reported: [(DeviceEQ, String, Bool)] = []
        window.onSetDeviceEQ = { eq, id, committed in reported.append((eq, id, committed)) }
        window.select(.device(id: "office"))

        let editor = window.test_detail.test_eqEditor
        editor.test_committedGestureOverride = true
        editor.test_dragBass(to: 3)

        #expect(reported.last?.0.bassDB == 3)
        #expect(reported.last?.1 == "office", "the whole point of the per-device seam is the id")
        #expect(reported.last?.2 == true)
    }

    @Test func autoSelectStillPicksTheFirstGroupWhenNothingIsSelected() async throws {
        let (window, controller, _) = try await makeWindow()
        let group = try makeGroup1(controller)

        window.test_select(nil)

        #expect(window.test_isShowingEditor)
        #expect(window.test_editor.editingGroupID == group.id,
                "the new System Audio row must not steal the empty selection's auto-select")
    }
}

private actor WindowTestCountBox {
    private var count = 0
    func increment() -> Int { count += 1; return count }
}
