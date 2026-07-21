// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
import AppKit
@testable import AudiouterCore
@testable import AudiouterSharedUI
@testable import AudiouterWindowUI

/// Structural + integration coverage for the "Groups" window (design revamp,
/// SPEC §9). The window isn't visible to CI, so these assert the *built*
/// window structure and that interactions call through the model — the same
/// checks the `window-harness` executable runs, folded into `swift test`.
///
/// The window is CONFIGURATION-ONLY under the revamp: viewing/editing groups
/// here never activates them or moves audio (activation lives in the app's
/// popover). Group creation is a standard macOS sheet
/// (`GroupCreationSheetController`), not an in-pane draft.
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

    // MARK: Window frame persistence (R2: reconciling the audit vs. the live test)
    //
    // `MixerWindowController` restores its frame via
    // `NSWindow.setFrameAutosaveName("MixerWindow")`, which — per AppKit — finds
    // and SYNCHRONOUSLY applies any previously-saved frame the instant it's
    // called, before `init()` does anything else. A prior version of this
    // controller unconditionally called `setContentSize`/`center()` right after
    // that, silently discarding the restore on every construction. That bug was
    // invisible to a live "move it, close it, reopen it" smoke test because
    // `AppDelegate` builds this controller once per process and reuses it — a
    // same-session close/reopen never re-runs `init()` at all. It only shows up
    // across a genuine app relaunch, which is exactly when frame autosave is
    // supposed to matter. These tests construct a fresh `MixerWindowController`
    // under the REAL "MixerWindow" autosave name, standing in for "a fresh
    // launch after a previous session saved a frame" — the case the live smoke
    // test never actually exercised.

    private static let mixerWindowAutosaveName = NSWindow.FrameAutosaveName("MixerWindow")
    private static let mixerWindowFrameDefaultsKey = "NSWindow Frame MixerWindow"

    /// Simulate "a previous session left the window here": build a throwaway
    /// window under the SAME "MixerWindow" autosave name `MixerWindowController`
    /// itself uses, move it, and force-persist that frame — exactly what AppKit
    /// does automatically as the user drags a real, autosave-named window.
    private func seedSavedMixerWindowFrame(_ frame: NSRect) {
        let seed = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
                            styleMask: [.titled, .closable, .miniaturizable, .resizable],
                            backing: .buffered, defer: false)
        seed.setFrameAutosaveName(Self.mixerWindowAutosaveName)
        seed.setFrame(frame, display: false)
        seed.saveFrame(usingName: Self.mixerWindowAutosaveName)
    }

    /// Clear any saved "MixerWindow" frame so this test's seed can never leak
    /// into another test in the same process (all `swift test` cases share one
    /// `UserDefaults.standard` domain) and a stale seed from an earlier failed
    /// run can never leak into this one.
    private func clearSavedMixerWindowFrame() {
        UserDefaults.standard.removeObject(forKey: Self.mixerWindowFrameDefaultsKey)
    }

    func testWindowRestoresPreviouslySavedFrameInsteadOfRecentering() async throws {
        clearSavedMixerWindowFrame()
        defer { clearSavedMixerWindowFrame() }
        let saved = NSRect(x: 133, y: 222, width: 900, height: 600)
        seedSavedMixerWindowFrame(saved)

        let (window, _, _) = try await makeWindow()

        XCTAssertEqual(window.window?.frame, saved,
                       "a frame saved by a previous session must be restored as-is on the next " +
                       "construction, not overwritten by the default-size/center() fallback — " +
                       "regression coverage for the R2 audit/live-test contradiction")
    }

    func testFreshWindowWithNoSavedFrameFallsBackToDefaultSizeCentered() async throws {
        clearSavedMixerWindowFrame()
        defer { clearSavedMixerWindowFrame() }

        let (window, _, _) = try await makeWindow()
        let frame = try XCTUnwrap(window.window?.frame)
        XCTAssertEqual(frame.width, 720, accuracy: 0.5)
        XCTAssertEqual(frame.height, 460, accuracy: 0.5,
                       "460 = the exact content size — .fullSizeContentView means content fills the " +
                       "whole frame, no separate title-bar addition")

        // AppKit's `center()` isn't the screen's exact geometric midpoint (it's
        // nudged for visual balance), so compare against a same-size probe that
        // also just calls `center()`, rather than hard-coding that offset.
        let probe = NSWindow(contentRect: NSRect(origin: .zero, size: frame.size),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
        probe.center()
        XCTAssertEqual(frame.origin, probe.frame.origin,
                       "with nothing saved yet, the window must still fall back to center() as before")
    }

    // MARK: Window chrome (SPEC §9 "Full window")

    func testWindowChromeHasFullSizeContentAndNoToolbar() async throws {
        let (window, _, _) = try await makeWindow()
        XCTAssertTrue(window.test_hasFullSizeContentView)
        XCTAssertTrue(window.test_hasNoToolbar,
                      "the window mounts no toolbar (live-test feedback: no volume UI in a config-only window)")
    }

    func testWindowTitleIsGroups() async throws {
        let (window, _, _) = try await makeWindow()
        XCTAssertEqual(window.window?.title, "Groups")
    }

    // MARK: Sidebar structure (config-only revamp: always both sections)

    func testSidebarAlwaysShowsGroupsAndDevicesSections() async throws {
        let (window, _, _) = try await makeWindow()
        XCTAssertEqual(window.test_sidebar.test_sectionTitles, ["Groups", "Devices"])
        XCTAssertTrue(window.test_sidebar.test_hasGroupsEmptyStateRow,
                      "zero saved groups shows the empty-state placeholder row")
        XCTAssertEqual(window.test_sidebar.test_deviceRowCount, 7)
        XCTAssertFalse(window.test_isShowingEditor)
    }

    func testBaselineContentIsEmptyStateAtZeroGroups() async throws {
        let (window, _, _) = try await makeWindow()
        XCTAssertTrue(window.test_isShowingEmptyState,
                      "zero groups + no selection auto-lands on the 'No groups yet' pane")
    }

    func testEmptyStateNewGroupButtonPresentsCreationSheet() async throws {
        let (window, _, _) = try await makeWindow()
        XCTAssertTrue(window.test_isShowingEmptyState)
        // The empty pane's call-to-action runs the same sheet as the sidebar "+".
        window.test_emptyState.test_tapNewGroup()
        XCTAssertTrue(window.test_isPresentingCreateSheet)
        window.test_createSheet?.test_cancel()
    }

    func testAutoSelectLandsOnFirstGroupsEditor() async throws {
        let (window, controller, backend) = try await makeWindow()
        let saved = try makeGroup1(controller)
        window.update(devices: backend.devices)
        await drain()
        XCTAssertTrue(window.test_isShowingEditor,
                      "with a saved group and no selection, the window auto-selects it")
        XCTAssertEqual(window.test_editor.editingGroupID, saved.id)
        XCTAssertEqual(window.test_sidebar.currentSelection, .group(id: saved.id))
        XCTAssertNil(controller.activeGroupID, "auto-select never activates")
    }

    func testSavingGroupAddsFlatGroupRowClearsEmptyStateAndKeepsAllDevicesListed() async throws {
        let (window, controller, backend) = try await makeWindow()
        _ = try makeGroup1(controller)
        window.update(devices: backend.devices)

        XCTAssertEqual(window.test_sidebar.test_sectionTitles, ["Groups", "Devices"])
        XCTAssertFalse(window.test_sidebar.test_hasGroupsEmptyStateRow)
        XCTAssertEqual(window.test_sidebar.test_groupRowCount, 1)
        XCTAssertTrue(window.test_sidebar.test_groupRowsAreFlat,
                      "a group row is a flat leaf — no expandable member children (design review 2026-07-18)")
        XCTAssertEqual(window.test_sidebar.test_deviceRowCount, 7,
                       "the Devices section lists every device, including a saved group's members, " +
                       "since membership is previewed in the editor now, not by sidebar expansion")
    }

    func testSidebarSupportsMultipleSelection() async throws {
        let (window, _, _) = try await makeWindow()
        XCTAssertTrue(window.test_sidebar.test_allowsMultipleSelection)
    }

    // MARK: New Group — sheet (SPEC.md §9, design revamp)

    func testTapAddRoutesToCreationSheet() async throws {
        let (window, controller, _) = try await makeWindow()
        window.test_sidebar.test_tapAdd()
        await drain()

        XCTAssertNotNil(window.test_createSheet, "the '+' with no selection presents the New Group sheet")
        XCTAssertEqual(controller.groups.count, 0, "presenting the sheet creates nothing")
    }

    func testBeginNewGroupPresentsCreationSheet() async throws {
        let (window, _, _) = try await makeWindow()
        window.beginNewGroup()
        await drain()

        XCTAssertTrue(window.test_isPresentingCreateSheet,
                      "the popover's beginNewGroup() opens the same creation sheet")
    }

    func testCreateSheetPrefillsPreselectedMembersChecked() async throws {
        let (window, _, _) = try await makeWindow()
        window.test_presentCreateSheet(preselected: ["office", "appletv-lr"])
        await drain()

        let sheet = try XCTUnwrap(window.test_createSheet)
        XCTAssertEqual(Set(sheet.test_checkedDeviceIDs), ["office", "appletv-lr"],
                       "the sheet is pre-populated with exactly the multi-selected speakers")
    }

    func testCreateSheetCreateDisabledAtZeroMembersEnabledAtOne() async throws {
        let (window, _, _) = try await makeWindow()
        window.test_presentCreateSheet(preselected: [])
        await drain()
        let sheet = try XCTUnwrap(window.test_createSheet)

        XCTAssertFalse(sheet.test_isCreateEnabled, "Create is disabled with zero members checked")

        sheet.test_setMembership(deviceID: "office", isChecked: true)
        XCTAssertTrue(sheet.test_isCreateEnabled, "Create enables once >= 1 member is checked")

        sheet.test_setMembership(deviceID: "office", isChecked: false)
        XCTAssertFalse(sheet.test_isCreateEnabled, "unchecking the only member disables Create again")
    }

    func testCreateSheetCommitCreatesExactlyCheckedMembers() async throws {
        let (window, controller, _) = try await makeWindow()
        window.test_presentCreateSheet(preselected: [])
        await drain()
        let sheet = try XCTUnwrap(window.test_createSheet)

        sheet.test_setName("Downstairs")
        sheet.test_setMembership(deviceID: "office", isChecked: true)
        sheet.test_setMembership(deviceID: "homepod-bed", isChecked: true)
        sheet.test_commit()
        await drain()

        XCTAssertEqual(controller.groups.count, 1)
        let group = try XCTUnwrap(controller.groups.first)
        XCTAssertEqual(group.name, "Downstairs")
        XCTAssertEqual(Set(group.memberIDs), ["office", "homepod-bed"])
        XCTAssertEqual(Set(group.memberVolumes.keys), Set(group.memberIDs),
                       "each checked member gets a remembered volume")
    }

    func testCreateSheetCommitDoesNotActivate() async throws {
        let (window, controller, _) = try await makeWindow()
        XCTAssertNil(controller.activeGroupID)
        window.test_presentCreateSheet(preselected: [])
        await drain()
        let sheet = try XCTUnwrap(window.test_createSheet)

        sheet.test_setMembership(deviceID: "office", isChecked: true)
        sheet.test_commit()
        await drain()

        XCTAssertEqual(controller.groups.count, 1)
        XCTAssertNil(controller.activeGroupID, "creating a group never activates it — CONFIG-ONLY")
    }

    func testCreateSheetCommitAfterCreateSelectsAndOpensEditorWithoutActivating() async throws {
        let (window, controller, _) = try await makeWindow()
        window.test_presentCreateSheet(preselected: [])
        await drain()
        let sheet = try XCTUnwrap(window.test_createSheet)
        sheet.test_setMembership(deviceID: "office", isChecked: true)
        sheet.test_commit()
        await drain()

        let group = try XCTUnwrap(controller.groups.first)
        XCTAssertTrue(window.test_isShowingEditor, "creation opens the new group's editor")
        XCTAssertEqual(window.test_editor.editingGroupID, group.id)
        XCTAssertNil(controller.activeGroupID, "still not activated after opening the editor")
    }

    func testCreateSheetDedupsIdenticalMemberSetToExistingGroup() async throws {
        let (window, controller, _) = try await makeWindow()
        window.test_presentCreateSheet(preselected: ["office", "appletv-lr"])
        await drain()
        var sheet = try XCTUnwrap(window.test_createSheet)
        var completedResult: (group: Group, alreadyExisted: Bool)?
        sheet.onComplete = { completedResult = $0 }
        sheet.test_commit()
        await drain()
        XCTAssertEqual(controller.groups.count, 1)
        XCTAssertEqual(completedResult?.alreadyExisted, false)
        let firstID = controller.groups[0].id

        // Same member set again (order swapped) must resolve to the existing group.
        window.test_presentCreateSheet(preselected: ["appletv-lr", "office"])
        await drain()
        sheet = try XCTUnwrap(window.test_createSheet)
        completedResult = nil
        sheet.onComplete = { completedResult = $0 }
        sheet.test_commit()
        await drain()

        XCTAssertEqual(controller.groups.count, 1, "no duplicate group for an identical member set")
        XCTAssertEqual(completedResult?.group.id, firstID)
        XCTAssertEqual(completedResult?.alreadyExisted, true)
    }

    func testCreateSheetCandidatesExcludeUnavailableDevices() async throws {
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
        let sheet = try XCTUnwrap(window.test_createSheet)

        XCTAssertFalse(sheet.test_candidateDeviceIDs.contains(unavailableID),
                       "a brand-new group never offers joining an unreachable speaker")
        XCTAssertEqual(sheet.test_candidateDeviceIDs.count, 6)
    }

    // MARK: Selecting a group → editor only, never activation

    func testSelectingGroupShowsEditorAndDoesNotActivate() async throws {
        let (window, controller, backend) = try await makeWindow()
        let saved = try makeGroup1(controller)
        window.update(devices: backend.devices)
        XCTAssertNil(controller.activeGroupID)

        window.test_select(.group(id: saved.id))
        await drain()

        XCTAssertTrue(window.test_isShowingEditor)
        XCTAssertNil(controller.activeGroupID, "selecting a group in the sidebar never activates it")
        XCTAssertEqual(window.test_editor.editingGroupID, saved.id)
        XCTAssertEqual(Set(window.test_editor.test_checkedDeviceIDs), Set(saved.memberIDs))
        XCTAssertEqual(window.test_editor.test_candidateDeviceIDs.count, 7)
    }

    // MARK: Editor candidates: unavailable devices stay only while a member

    func testEditorCandidatesIncludeUnavailableDeviceOnlyIfMember() async throws {
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

        XCTAssertTrue(window.test_editor.test_candidateDeviceIDs.contains("office"),
                      "an unavailable device stays offered while it remains a member")
        XCTAssertFalse(window.test_editor.test_candidateDeviceIDs.contains("appletv-lr"),
                       "an unavailable non-member is not offered")
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

    func testCannotRemoveLastMemberOfGroupInEditor() async throws {
        let (window, controller, backend) = try await makeWindow()
        let saved = try makeGroup1(controller)   // 2 members: sonos-move, office
        window.update(devices: backend.devices)
        window.test_select(.group(id: saved.id))
        await drain()

        // Removing one of two members is allowed — the group drops to a single member.
        window.test_editor.test_setMembership(false, for: "office")
        XCTAssertEqual(controller.groups.first { $0.id == saved.id }?.memberIDs, ["sonos-move"],
                       "one member removed, one remains")

        // The sole remaining member's checkbox is pinned (disabled) as the affordance.
        XCTAssertFalse(window.test_editor.test_isMembershipRowEnabled(for: "sonos-move"),
                       "the last member's checkbox is disabled so it can't be unchecked")

        // Attempting to remove the last member is refused: the group keeps it and
        // the row reverts to checked (delete the group instead to remove it).
        window.test_editor.test_setMembership(false, for: "sonos-move")
        XCTAssertEqual(controller.groups.first { $0.id == saved.id }?.memberIDs, ["sonos-move"],
                       "removing the last member must be refused — the group stays non-empty")
        XCTAssertTrue(window.test_editor.test_checkedDeviceIDs.contains("sonos-move"),
                      "the reverted checkbox shows the member still belongs")
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
        XCTAssertTrue(window.test_isShowingEmptyState,
                      "deleting the last group falls back to the 'No groups yet' pane")
        XCTAssertTrue(window.test_sidebar.test_hasGroupsEmptyStateRow,
                      "the Groups section stays but shows the empty state again")
    }

    // MARK: Selecting a device → detail pane (config-only, never activation)

    func testSelectingDeviceShowsDetailPaneWithMetadataAndGroupMembership() async throws {
        let (window, controller, backend) = try await makeWindow()
        // Untouched by makeGroup1 below (which selects sonos-move + office,
        // actually connecting them) — a clean "Not connected" / "None" case.
        window.test_select(.device(id: "appletv-lr"))
        await drain()

        XCTAssertTrue(window.test_isShowingDetail)
        XCTAssertFalse(window.test_isShowingEditor)
        XCTAssertEqual(window.test_detail.test_shownDeviceID, "appletv-lr")
        XCTAssertEqual(window.test_detail.test_metadataStrings["volume"], "60%")
        XCTAssertEqual(window.test_detail.test_metadataStrings["available"], "Yes")
        XCTAssertEqual(window.test_detail.test_metadataStrings["status"], "Not connected")
        XCTAssertEqual(window.test_detail.test_groupMembershipText, "None",
                       "appletv-lr isn't a member of any saved group")

        let saved = try makeGroup1(controller)   // members: sonos-move, office
        window.update(devices: backend.devices)

        window.test_select(.device(id: "office"))
        await drain()

        XCTAssertTrue(window.test_isShowingDetail)
        XCTAssertEqual(window.test_detail.test_shownDeviceID, "office")
        XCTAssertEqual(window.test_detail.test_groupMembershipText, saved.name,
                       "office is a Group 1 member")
    }

    func testDeselectingDeviceAutoSelectsFirstGroupOrEmptyState() async throws {
        let (window, controller, backend) = try await makeWindow()
        window.test_select(.device(id: "office"))
        await drain()
        XCTAssertTrue(window.test_isShowingDetail)

        window.test_select(nil)
        await drain()
        XCTAssertFalse(window.test_isShowingDetail)
        XCTAssertTrue(window.test_isShowingEmptyState,
                      "no groups: deselecting a device lands on the empty pane")

        let saved = try makeGroup1(controller)
        window.update(devices: backend.devices)
        window.test_select(.device(id: "office"))
        await drain()
        window.test_select(nil)
        await drain()
        XCTAssertTrue(window.test_isShowingEditor,
                      "with a saved group, deselecting auto-selects its editor")
        XCTAssertEqual(window.test_editor.editingGroupID, saved.id)
    }

    func testSelectingUnknownDeviceIDFallsBackToDefaultContent() async throws {
        let (window, _, _) = try await makeWindow()
        window.test_select(.device(id: "does-not-exist"))
        await drain()

        XCTAssertFalse(window.test_isShowingDetail)
        XCTAssertTrue(window.test_isShowingEmptyState)
        XCTAssertNil(window.test_detail.test_shownDeviceID, "the detail pane was never actually shown")
    }

    func testSelectingDeviceNeverActivatesAGroup() async throws {
        let (window, controller, backend) = try await makeWindow()
        let saved = try makeGroup1(controller)
        window.update(devices: backend.devices)
        XCTAssertNil(controller.activeGroupID)

        window.test_select(.device(id: saved.memberIDs[0]))
        await drain()

        XCTAssertTrue(window.test_isShowingDetail)
        XCTAssertNil(controller.activeGroupID, "selecting a device in the sidebar never activates anything")
    }

    func testDetailPaneRefreshesLiveWhenDeviceSnapshotChanges() async throws {
        let (window, _, backend) = try await makeWindow()
        window.test_select(.device(id: "office"))
        await drain()
        XCTAssertEqual(window.test_detail.test_metadataStrings["volume"], "50%")

        let updated = backend.devices.map { device -> Device in
            var d = device
            if d.id == "office" { d.volume = 77 }
            return d
        }
        window.update(devices: updated)

        XCTAssertTrue(window.test_isShowingDetail, "still showing the detail pane, just re-rendered")
        XCTAssertEqual(window.test_detail.test_metadataStrings["volume"], "77%",
                       "refreshAll() re-renders the visible detail pane from the fresher snapshot")
    }

    func testRefreshAllFallsBackWhenShownDeviceDisappears() async throws {
        let (window, _, backend) = try await makeWindow()
        window.test_select(.device(id: "office"))
        await drain()
        XCTAssertTrue(window.test_isShowingDetail)

        let devicesWithoutOffice = backend.devices.filter { $0.id != "office" }
        window.update(devices: devicesWithoutOffice)

        XCTAssertFalse(window.test_isShowingDetail,
                       "refreshAll() falls back to the default content once the shown device vanishes")
        XCTAssertTrue(window.test_isShowingEmptyState, "no groups saved, so the fallback is the empty pane")
    }

    // MARK: Icon flows

    func testEditorIconPickPersistsThroughSaveGroup() async throws {
        let (window, controller, backend) = try await makeWindow()
        let saved = try makeGroup1(controller)
        window.update(devices: backend.devices)
        window.test_select(.group(id: saved.id))
        await drain()
        XCTAssertNil(controller.groups.first { $0.id == saved.id }?.iconSymbolName)

        window.test_editor.test_pickIcon("airpods")

        XCTAssertEqual(controller.groups.first { $0.id == saved.id }?.iconSymbolName, "airpods",
                       "the editor's icon pick persists group.iconSymbolName through saveGroup")
        XCTAssertEqual(window.test_editor.test_iconWellSymbolName, "airpods")
    }

    func testCreateSheetChosenIconLandsOnCreatedGroup() async throws {
        let (window, controller, _) = try await makeWindow()
        window.test_presentCreateSheet(preselected: [])
        await drain()
        let sheet = try XCTUnwrap(window.test_createSheet)

        sheet.test_setMembership(deviceID: "office", isChecked: true)
        sheet.test_pickIcon("airpods")
        sheet.test_commit()
        await drain()

        let group = try XCTUnwrap(controller.groups.first)
        XCTAssertEqual(group.iconSymbolName, "airpods", "the sheet's chosen icon lands on the created group")
    }

    func testCreateSheetDedupDoesNotOverwriteExistingGroupsIcon() async throws {
        let (window, controller, _) = try await makeWindow()
        window.test_presentCreateSheet(preselected: ["office", "appletv-lr"])
        await drain()
        var sheet = try XCTUnwrap(window.test_createSheet)
        sheet.test_pickIcon("airpods")
        sheet.test_commit()
        await drain()
        XCTAssertEqual(controller.groups.count, 1)
        let firstID = controller.groups[0].id
        XCTAssertEqual(controller.groups[0].iconSymbolName, "airpods")

        // Same member set again (order swapped), a DIFFERENT icon picked —
        // dedups onto the existing group, whose own icon must win
        // (`GroupController.createGroup`'s documented dedup rule).
        window.test_presentCreateSheet(preselected: ["appletv-lr", "office"])
        await drain()
        sheet = try XCTUnwrap(window.test_createSheet)
        sheet.test_pickIcon("homepod.fill")
        sheet.test_commit()
        await drain()

        XCTAssertEqual(controller.groups.count, 1, "no duplicate group for an identical member set")
        XCTAssertEqual(controller.groups.first { $0.id == firstID }?.iconSymbolName, "airpods",
                       "dedup resolves to the existing group and does NOT overwrite its icon")
    }

    func testDeviceIconControllerOverrideReachesEditorMembershipRow() async throws {
        let (window, controller, backend, icons) = try await makeWindowWithIconController()
        let saved = try makeGroup1(controller)   // members incl. office
        icons.setSymbolName("sofa.fill", for: "office")
        window.update(devices: backend.devices)
        window.test_select(.group(id: saved.id))
        await drain()
        // The mixer pane is gone (live-test feedback) — the shared override's
        // window-side rendering surface is the editor's membership rows.
        XCTAssertTrue(window.test_editor.test_candidateDeviceIDs.contains("office"))
        XCTAssertEqual(icons.symbolName(for: backend.devices.first { $0.id == "office" }!),
                       "sofa.fill",
                       "the shared controller resolves the override the row renders")
    }

    // MARK: Keyboard focus (A11Y-GROUPS)
    //
    // Live-test finding: pressing Tab did nothing anywhere in the Groups
    // window, because nothing in its lifecycle ever calls
    // `NSWindow.makeFirstResponder(_:)` — so a freshly-shown window has no
    // real first responder to advance Tab FROM. `SidebarViewController`'s
    // `viewDidAppear()` override seeds the outline view as first responder
    // (see its doc comment for the full root-cause writeup); this asserts
    // that seed fires exactly the way a real window appearing would trigger
    // it, without needing an actual on-screen window (never available under
    // `swift test`).

    func testWindowHasNoFirstResponderBeforeItEverAppears() async throws {
        let (window, _, _) = try await makeWindow()
        // Before `viewDidAppear()` has ever run, the window's first responder
        // is itself — nothing has claimed it. This is the exact state a live
        // Tab press found: nothing to advance from.
        XCTAssertTrue(window.test_sidebar.view.window === window.window)
        XCTAssertFalse(window.test_sidebar.test_isOutlineViewFirstResponder)
    }

    func testSidebarViewDidAppearSeedsTheOutlineViewAsFirstResponder() async throws {
        let (window, _, _) = try await makeWindow()
        window.test_sidebar.test_simulateViewDidAppear()
        XCTAssertTrue(window.test_sidebar.test_isOutlineViewFirstResponder,
                      "the sidebar's outline view must become first responder once the window appears, or Tab has nothing to advance from")
    }
}

private actor WindowTestCountBox {
    private var count = 0
    func increment() -> Int { count += 1; return count }
}
