// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Alec Henderson and contributors.

import XCTest
import AppKit
@testable import AirPlayControllerCore
@testable import AirPlayControllerWindowUI

/// Structural + integration coverage for the T-U4 mixer window (SPEC §9). The
/// window isn't visible to CI, so these assert the *built* window structure and
/// that interactions call through the model — the same checks the
/// `window-harness` executable runs, folded into `swift test`.
///
/// `MixerWindowController` is `@MainActor`; these cases are `@MainActor` so they
/// touch it (and the non-`Sendable` `GroupController`) on the main thread,
/// exactly as the app does.
@MainActor
final class MixerWindowControllerTests: XCTestCase {

    /// A MockBackend with the full demo fleet discovered, a GroupController, and
    /// a `MixerWindowController` with the devices pushed in.
    private func makeWindow() async throws -> (MixerWindowController, GroupController, MockBackend) {
        let backend = MockBackend(fleet: .demoFleet, staggerDiscovery: false,
                                  emitsLevels: false, simulatesDropouts: false)
        try await waitForFleet(backend, count: 7)
        let store = GroupStore(directory: tempDirectory())
        let controller = GroupController(backend: backend, store: store, loadPersisted: false)
        let window = MixerWindowController(groupController: controller)
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
        let expectation = expectation(description: "fleet discovered")
        let box = WindowTestCountBox()
        let task = Task {
            for await event in stream {
                if case .deviceAdded = event, await box.increment() >= count {
                    expectation.fulfill(); break
                }
            }
        }
        backend.start()
        await fulfillment(of: [expectation], timeout: 2)
        task.cancel()
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

    // MARK: Window chrome (SPEC §9 "Full window")

    func testWindowChromeIsUnifiedWithFullSizeContentAndToolbarItems() async throws {
        let (window, _, _) = try await makeWindow()
        XCTAssertEqual(window.test_toolbarStyle, .unified)
        XCTAssertTrue(window.test_hasFullSizeContentView)
        XCTAssertTrue(window.test_toolbarItemIdentifiers.contains("master"),
                      "toolbar mounts the master-volume item")
        XCTAssertTrue(window.test_toolbarItemIdentifiers.contains("presets"),
                      "toolbar mounts the presets item")
    }

    // MARK: Sidebar structure

    func testBaselineSidebarHasOnlyDevicesSection() async throws {
        let (window, _, _) = try await makeWindow()
        XCTAssertEqual(window.test_sidebar.test_sectionTitles, ["Devices"])
        XCTAssertEqual(window.test_sidebar.test_ungroupedDeviceRowCount, 7)
        XCTAssertFalse(window.test_isShowingEditor)
    }

    func testBaselineMixerShowsAllDeviceRows() async throws {
        let (window, _, _) = try await makeWindow()
        XCTAssertEqual(window.test_mixer.test_rowDeviceIDs.count, 7)
    }

    func testSavingGroupAddsGroupsSectionWithMembers() async throws {
        let (window, controller, backend) = try await makeWindow()
        let saved = try makeGroup1(controller)
        window.update(devices: backend.devices)

        XCTAssertTrue(window.test_sidebar.test_sectionTitles.contains("Groups"))
        XCTAssertEqual(window.test_sidebar.test_groupRowCount, 1)
        XCTAssertEqual(Set(window.test_sidebar.test_memberIDs(underGroup: saved.id)),
                       Set(saved.memberIDs))
    }

    // MARK: New Group — manual creation (SPEC.md §9)

    func testSidebarSupportsMultipleSelection() async throws {
        let (window, _, _) = try await makeWindow()
        XCTAssertTrue(window.test_sidebar.test_allowsMultipleSelection)
    }

    func testTapAddOpensEmptyDraftEditor() async throws {
        let (window, controller, _) = try await makeWindow()
        window.test_tapAddGroup()
        await drain()

        XCTAssertTrue(window.test_isShowingDraft, "the '+' opens an unsaved draft")
        XCTAssertTrue(window.test_editor.test_draftButtonsVisible, "Save/Cancel shown in create mode")
        XCTAssertFalse(window.test_editor.test_deleteButtonVisible, "no Delete in create mode")
        XCTAssertNil(window.test_editor.editingGroupID, "a draft has no persisted id yet")
        // All discovered devices are offered as candidates; none checked by default.
        XCTAssertEqual(window.test_editor.test_candidateDeviceIDs.count, 7)
        XCTAssertTrue(window.test_editor.test_checkedDeviceIDs.isEmpty)
        XCTAssertEqual(controller.groups.count, 0, "opening the draft creates nothing")
    }

    func testDraftSaveCreatesGroupFromCheckedMembers() async throws {
        let (window, controller, _) = try await makeWindow()
        window.test_tapAddGroup()
        await drain()

        window.test_editor.test_setDraftName("Downstairs")
        window.test_editor.test_setMembership(true, for: "office")
        window.test_editor.test_setMembership(true, for: "homepod-bed")
        window.test_editor.test_commitDraft()
        await drain()

        XCTAssertEqual(controller.groups.count, 1)
        let group = try XCTUnwrap(controller.groups.first)
        XCTAssertEqual(group.name, "Downstairs")
        XCTAssertEqual(Set(group.memberIDs), ["office", "homepod-bed"])
        XCTAssertEqual(controller.activeGroupID, group.id, "the new group is activated")
    }

    func testDraftCancelCreatesNothing() async throws {
        let (window, controller, _) = try await makeWindow()
        window.test_tapAddGroup()
        await drain()
        window.test_editor.test_setMembership(true, for: "office")

        window.test_editor.test_cancelDraft()
        await drain()

        XCTAssertEqual(controller.groups.count, 0, "Cancel discards the draft")
        XCTAssertFalse(window.test_isShowingDraft)
    }

    func testNewGroupFromMultiSelectionPrepopulatesMembers() async throws {
        let (window, controller, _) = try await makeWindow()
        // Multi-select two devices then hit "+" → draft seeded with exactly them.
        window.test_newGroupFromSelection(["office", "appletv-lr"])
        await drain()

        XCTAssertTrue(window.test_isShowingDraft)
        XCTAssertEqual(Set(window.test_editor.test_checkedDeviceIDs), ["office", "appletv-lr"],
                       "the draft is pre-populated with exactly the multi-selected speakers")

        window.test_editor.test_commitDraft()
        await drain()
        XCTAssertEqual(controller.groups.count, 1)
        XCTAssertEqual(Set(controller.groups[0].memberIDs), ["office", "appletv-lr"])
    }

    func testNewGroupFromSelectionDedupsToExistingGroup() async throws {
        let (window, controller, _) = try await makeWindow()
        // First create the group.
        window.test_newGroupFromSelection(["office", "appletv-lr"])
        await drain()
        window.test_editor.test_commitDraft()
        await drain()
        XCTAssertEqual(controller.groups.count, 1)
        let firstID = controller.groups[0].id

        // Same member set again (order swapped) must resolve to the existing group.
        window.test_newGroupFromSelection(["appletv-lr", "office"])
        await drain()
        window.test_editor.test_commitDraft()
        await drain()
        XCTAssertEqual(controller.groups.count, 1, "no duplicate group for an identical member set")
        XCTAssertEqual(controller.activeGroupID, firstID, "resolves to and activates the existing group")
    }

    // MARK: Selecting a group → editor + activation

    func testSelectingGroupShowsEditorAndActivates() async throws {
        let (window, controller, backend) = try await makeWindow()
        let saved = try makeGroup1(controller)
        window.update(devices: backend.devices)

        window.test_select(.group(id: saved.id))
        await drain()

        XCTAssertTrue(window.test_isShowingEditor)
        XCTAssertEqual(controller.activeGroupID, saved.id)
        XCTAssertEqual(window.test_editor.editingGroupID, saved.id)
        XCTAssertEqual(Set(window.test_editor.test_checkedDeviceIDs), Set(saved.memberIDs))
        XCTAssertEqual(window.test_editor.test_candidateDeviceIDs.count, 7)
    }

    // MARK: Editor → GroupController

    func testRenameInEditorCallsSaveGroup() async throws {
        let (window, controller, backend) = try await makeWindow()
        let saved = try makeGroup1(controller)
        window.update(devices: backend.devices)
        window.test_select(.group(id: saved.id))
        await drain()

        window.test_editor.test_rename(to: "Whole House")
        XCTAssertEqual(controller.groups.first { $0.id == saved.id }?.name, "Whole House")
    }

    func testMembershipCheckboxUpdatesGroup() async throws {
        let (window, controller, backend) = try await makeWindow()
        let saved = try makeGroup1(controller)
        window.update(devices: backend.devices)
        window.test_select(.group(id: saved.id))
        await drain()

        let extra = try XCTUnwrap(backend.devices.first { !saved.memberIDs.contains($0.id) }?.id)
        let before = try XCTUnwrap(controller.groups.first { $0.id == saved.id }).memberIDs.count

        window.test_editor.test_setMembership(true, for: extra)
        XCTAssertEqual(controller.groups.first { $0.id == saved.id }?.memberIDs.count, before + 1)
        XCTAssertTrue(controller.groups.first { $0.id == saved.id }!.memberIDs.contains(extra))

        window.test_editor.test_setMembership(false, for: extra)
        XCTAssertEqual(controller.groups.first { $0.id == saved.id }?.memberIDs.count, before)
        XCTAssertFalse(controller.groups.first { $0.id == saved.id }!.memberIDs.contains(extra))
    }

    func testDeleteInEditorCallsDeleteGroupAndReturnsToMixer() async throws {
        let (window, controller, backend) = try await makeWindow()
        let saved = try makeGroup1(controller)
        window.update(devices: backend.devices)
        window.test_select(.group(id: saved.id))
        await drain()
        XCTAssertTrue(window.test_isShowingEditor)

        window.test_editor.test_confirmDelete()
        await drain()

        XCTAssertEqual(controller.groups.count, 0)
        XCTAssertFalse(window.test_isShowingEditor)
        XCTAssertFalse(window.test_sidebar.test_sectionTitles.contains("Groups"))
    }

    // MARK: Mixer rows drive the backend

    func testMixerRowSliderDrivesBackend() async throws {
        let (window, controller, backend) = try await makeWindow()
        let saved = try makeGroup1(controller)
        window.update(devices: backend.devices)

        let target = saved.memberIDs[0]
        let row = try XCTUnwrap(window.test_mixer.test_row(for: target))
        row.test_setVolume(15)
        await drain()
        XCTAssertEqual(backend.devices.first { $0.id == target }?.volume, 15)
    }

    // MARK: Toolbar presets + master

    func testToolbarPresetsListGroupsAndActivate() async throws {
        let (window, controller, backend) = try await makeWindow()
        let saved = try makeGroup1(controller)
        window.update(devices: backend.devices)

        XCTAssertTrue(window.test_toolbar.test_presetTitles.contains("No group"))
        XCTAssertTrue(window.test_toolbar.test_presetTitles.contains("Group 1"))

        window.test_toolbar.test_selectPreset(groupID: saved.id)
        await drain()
        XCTAssertEqual(controller.activeGroupID, saved.id)
    }

    func testToolbarMasterDragScalesMembersProportionally() async throws {
        let (window, controller, backend) = try await makeWindow()
        let saved = try makeGroup1(controller)
        window.update(devices: backend.devices)
        window.test_selectPreset(groupID: saved.id)   // activate via preset
        await drain()

        let m0 = saved.memberIDs[0], m1 = saved.memberIDs[1]
        backend.setVolume(40, for: m0)
        backend.setVolume(80, for: m1)
        await drain()
        window.update(devices: backend.devices)
        XCTAssertEqual(controller.masterVolume, 60)

        window.test_toolbar.test_dragMaster(to: 30)
        await drain()
        XCTAssertEqual(backend.devices.first { $0.id == m0 }?.volume, 20)
        XCTAssertEqual(backend.devices.first { $0.id == m1 }?.volume, 40)
    }
}

private actor WindowTestCountBox {
    private var count = 0
    func increment() -> Int { count += 1; return count }
}
