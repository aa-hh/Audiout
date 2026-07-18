// SPDX-License-Identifier: GPL-2.0-or-later
//
// window-harness — programmatic verification for the "Groups" window
// (design revamp, SPEC §9). The window is CONFIGURATION-ONLY: viewing or
// editing a group here never activates it or moves audio — activation lives
// in the app's popover, not this window.
//
// The window isn't visible to an agent shell, so this instantiates the real
// `MixerWindowController` with a MockBackend-backed `GroupController`, drives
// the same code paths the toolbar / sidebar / editor / create-sheet actions
// call (via the `test_*` hooks), and asserts the built structure:
//   - chrome: the toolbar mounts ONLY the master item (no presets popup);
//     window.title == "Groups";
//   - baseline: the sidebar always shows "Groups" + "Devices" (even at zero
//     groups, via the empty-state row) and the mixer pane shows by default;
//   - create: the standard macOS sheet — enablement gating, member count,
//     commit creates a group WITHOUT activating it, sidebar selects it and
//     the editor shows it;
//   - dedup: committing the same member set again resolves to the existing
//     group instead of duplicating it;
//   - select != activate: selecting a group in the sidebar shows its editor
//     but never touches `activeGroupID`;
//   - editor: rename / membership edits go through `GroupController`, and the
//     candidate list excludes unavailable non-members;
//   - master: the toolbar's master drag still scales an ACTIVE group's
//     members proportionally (activated via the model directly, since the
//     window itself never activates);
//   - beginNewGroup(): presents the create sheet;
//   - delete: removes the group, the mixer pane returns, and the "Groups"
//     section itself stays (empty-state row comes back).
// Prints PASS/FAIL per check; exits nonzero on any failure so it can gate CI
// alongside `swift test`.

import AppKit
import AudioutedCore
import AudioutedWindowUI

// MARK: - Tiny assertion harness

final class Checks {
    private(set) var failures = 0
    private(set) var total = 0

    func expect(_ condition: Bool, _ message: String) {
        total += 1
        if condition {
            print("  PASS  \(message)")
        } else {
            failures += 1
            print("  FAIL  \(message)")
        }
    }

    func expectEqual<T: Equatable>(_ a: T, _ b: T, _ message: String) {
        expect(a == b, "\(message) (got \(a), expected \(b))")
    }
}

// MARK: - Backend readiness

@MainActor
func waitForFleet(_ backend: MockBackend, count: Int, timeout: TimeInterval = 3) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while backend.devices.count < count && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    return backend.devices.count >= count
}

@MainActor
func drain(_ interval: TimeInterval = 0.15) {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(interval))
}

func tempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("window-harness-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// MARK: - Run

@MainActor
func run() -> Int32 {
    // Headless AppKit: an accessory app so NSImage(systemSymbolName:) etc. work.
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let checks = Checks()

    let backend = MockBackend(fleet: .demoFleet, staggerDiscovery: false,
                              emitsLevels: false, simulatesDropouts: false)
    let controller = GroupController(backend: backend, store: GroupStore(directory: tempDir()),
                                     loadPersisted: false)
    let window = MixerWindowController(groupController: controller)

    backend.start()
    guard waitForFleet(backend, count: 7) else {
        print("SETUP FAIL: fleet did not fully discover"); return 2
    }
    window.update(devices: backend.devices)

    // --- 0. Window chrome: unified toolbar + full-size content view, master
    //        item mounted, presets popup GONE (config-only revamp), titled
    //        "Groups".
    print("\n[0] Window chrome (unified toolbar, full-size content, master-only toolbar)")
    checks.expectEqual(window.test_toolbarStyle, .unified,
                       "window.toolbarStyle is .unified (SPEC §9)")
    checks.expect(window.test_hasFullSizeContentView,
                  "styleMask includes .fullSizeContentView (SPEC §9)")
    checks.expect(window.test_toolbarItemIdentifiers.contains("master"),
                  "toolbar mounts the master-volume item")
    checks.expect(!window.test_toolbarItemIdentifiers.contains("presets"),
                  "toolbar does NOT mount a presets item (config-only revamp)")
    checks.expectEqual(window.window?.title, "Groups", "window title is 'Groups'")

    // --- 1. Baseline sidebar: zero groups still shows BOTH sections (the
    //        Groups section carries an empty-state row instead of vanishing).
    print("\n[1] Baseline sidebar (zero groups)")
    checks.expectEqual(window.test_sidebar.test_sectionTitles, ["Groups", "Devices"],
                       "'Groups' and 'Devices' sections both present even with zero groups")
    checks.expect(window.test_sidebar.test_hasGroupsEmptyStateRow,
                  "the Groups section shows its empty-state row at zero groups")
    checks.expectEqual(window.test_sidebar.test_ungroupedDeviceRowCount, 7,
                       "all 7 devices listed as ungrouped")
    checks.expect(!window.test_isShowingEditor, "the mixer pane shows by default (not the editor)")

    // --- 2. Baseline mixer: all 7 devices shown as rows.
    print("\n[2] Baseline mixer pane (all devices)")
    checks.expectEqual(window.test_mixer.test_rowDeviceIDs.count, 7,
                       "mixer shows a DeviceRowView per device (7)")

    // --- 3. Create sheet: enablement gating, member count, commit creates a
    //        group WITHOUT activating it.
    print("\n[3] Create sheet: gating, commit, no activation")
    window.test_presentCreateSheet(preselected: [])
    guard let sheet = window.test_createSheet else {
        checks.expect(false, "create sheet is wired after test_presentCreateSheet")
        print("\n----------------------------------------")
        print("FAIL: setup could not continue")
        return 1
    }
    checks.expect(window.test_isPresentingCreateSheet, "sheet controller is live")
    checks.expect(!sheet.test_isCreateEnabled, "Create is disabled at 0 checked devices")

    let candidateA = sheet.test_candidateDeviceIDs[0]
    let candidateB = sheet.test_candidateDeviceIDs[1]
    sheet.test_setMembership(deviceID: candidateA, isChecked: true)
    sheet.test_setMembership(deviceID: candidateB, isChecked: true)
    checks.expect(sheet.test_isCreateEnabled, "Create enables once >= 1 device is checked")
    checks.expectEqual(sheet.test_countText, "2 speakers selected",
                       "the live count label reflects the 2 checked devices")

    sheet.test_commit()
    drain()
    checks.expect(!window.test_isPresentingCreateSheet, "sheet clears after commit")
    let createdGroup = controller.groups.first { Set($0.memberIDs) == Set([candidateA, candidateB]) }
    checks.expect(createdGroup != nil, "a group with exactly the checked members was created")
    if let createdGroup {
        checks.expectEqual(Set(createdGroup.memberIDs), Set([candidateA, candidateB]),
                           "created group's members are exactly the ones checked")
        checks.expectEqual(window.test_sidebar.currentSelection, .group(id: createdGroup.id),
                           "sidebar selects the newly-created group")
        checks.expect(window.test_isShowingEditor, "editor shows the newly-created group")
        checks.expectEqual(window.test_editor.editingGroupID, createdGroup.id,
                           "editor is editing the created group")
    }
    checks.expectEqual(controller.activeGroupID, nil,
                       "creating a group does NOT activate it (config-only revamp)")

    // --- 4. Dedup: presenting again and checking the SAME member set resolves
    //        to the existing group instead of duplicating it.
    print("\n[4] Dedup: same member set resolves to the existing group")
    let groupCountBeforeDedup = controller.groups.count
    window.test_presentCreateSheet(preselected: [])
    if let dedupSheet = window.test_createSheet {
        dedupSheet.test_setMembership(deviceID: candidateA, isChecked: true)
        dedupSheet.test_setMembership(deviceID: candidateB, isChecked: true)
        dedupSheet.test_commit()
        drain()
        checks.expectEqual(controller.groups.count, groupCountBeforeDedup,
                           "no duplicate group was created for an identical member set")
    } else {
        checks.expect(false, "create sheet is wired for the dedup pass")
    }

    // --- 5. Select != activate: selecting a group in the sidebar shows its
    //        editor but never touches `activeGroupID`.
    print("\n[5] Select a group in the sidebar shows the editor, does NOT activate")
    guard let saved = createdGroup else {
        print("\n----------------------------------------")
        print("FAIL: no created group to continue from")
        return 1
    }
    controller.deactivateGroup()
    window.test_select(.group(id: saved.id))
    drain()
    checks.expect(window.test_isShowingEditor, "selecting a group shows the editor pane")
    checks.expectEqual(window.test_editor.editingGroupID, saved.id, "editor is editing that group")
    checks.expectEqual(controller.activeGroupID, nil,
                       "selecting a group in the sidebar does NOT activate it")

    // --- 6. Editor: rename, membership toggle, offline-member candidate rule.
    print("\n[6] Editor: rename, membership toggle, candidate rules")
    window.test_editor.test_rename(to: "Whole House")
    checks.expectEqual(controller.groups.first { $0.id == saved.id }?.name, "Whole House",
                       "rename persisted through GroupController.saveGroup")

    let extraDevice = backend.devices.first { !Set([candidateA, candidateB]).contains($0.id) }!.id
    let membersBefore = controller.groups.first { $0.id == saved.id }!.memberIDs.count
    window.test_editor.test_setMembership(true, for: extraDevice)
    checks.expectEqual(controller.groups.first { $0.id == saved.id }?.memberIDs.count,
                       membersBefore + 1,
                       "ticking a checkbox added the device to the group")
    checks.expect(controller.groups.first { $0.id == saved.id }!.memberIDs.contains(extraDevice),
                  "the newly-ticked device is now a member")
    window.test_editor.test_setMembership(false, for: extraDevice)
    checks.expectEqual(controller.groups.first { $0.id == saved.id }?.memberIDs.count,
                       membersBefore,
                       "unticking removes it again")

    // Offline-member rule: MockBackend has no deterministic hook to force a
    // specific device `isAvailable == false` (only a randomized/timed dropout
    // simulation, `simulatesDropouts`, unsuitable for a repeatable harness
    // check) — so instead of simulating an offline MEMBER, we assert the
    // general candidate rule the editor documents: every currently-available
    // non-member device is offered as a candidate (all demo-fleet devices are
    // available here, so this exercises the "available devices are always
    // offered" half of the rule).
    let availableNonMembers = backend.devices.filter { $0.isAvailable && !saved.memberIDs.contains($0.id) }
    checks.expect(availableNonMembers.allSatisfy { window.test_editor.test_candidateDeviceIDs.contains($0.id) },
                  "every available non-member device is offered as an editor candidate")

    // --- 7. Master drag scales an ACTIVE group's members proportionally.
    //        The window itself never activates, so activate via the model
    //        directly (mirrors what the popover would do).
    print("\n[7] Toolbar master drag scales an ACTIVE group's members proportionally")
    controller.activateGroup(id: saved.id)
    window.update(devices: backend.devices)
    let members = controller.groups.first { $0.id == saved.id }!.memberIDs
    let m0 = members[0], m1 = members[1]
    backend.setVolume(40, for: m0); backend.setVolume(80, for: m1); drain()
    window.update(devices: backend.devices)
    checks.expectEqual(controller.masterVolume, 60, "master echoes the members' average (60)")
    window.test_toolbar.test_dragMaster(to: 30)
    drain()
    checks.expectEqual(backend.devices.first { $0.id == m0 }?.volume, 20, "member0 40→20")
    checks.expectEqual(backend.devices.first { $0.id == m1 }?.volume, 40, "member1 80→40")
    controller.deactivateGroup()
    window.update(devices: backend.devices)

    // --- 8. beginNewGroup() presents the create sheet.
    print("\n[8] beginNewGroup() presents the create sheet")
    window.beginNewGroup()
    checks.expect(window.test_isPresentingCreateSheet, "beginNewGroup() wires a live create sheet")
    window.test_createSheet?.test_cancel()
    drain()
    checks.expect(!window.test_isPresentingCreateSheet, "cancelling clears the sheet")

    // --- 9. Select a device: read-only detail pane, membership text correct,
    //        `activeGroupID` untouched; deselecting returns the mixer pane.
    print("\n[9] Select a device shows the read-only detail pane")
    checks.expectEqual(controller.activeGroupID, nil,
                       "sanity: no group active before selecting a device")
    window.test_select(.device(id: candidateA))
    drain()
    checks.expect(window.test_isShowingDetail, "selecting a device shows the detail pane")
    checks.expect(!window.test_isShowingEditor, "selecting a device does not show the editor")
    checks.expectEqual(window.test_detail.test_shownDeviceID, candidateA,
                       "detail pane is showing the selected device")
    checks.expectEqual(window.test_detail.test_groupMembershipText, "Whole House",
                       "detail pane's 'In groups:' text names the device's saved group")
    checks.expectEqual(controller.activeGroupID, nil,
                       "selecting a device in the sidebar does NOT activate any group")
    window.test_select(nil)
    drain()
    checks.expect(!window.test_isShowingDetail, "deselecting clears the detail pane")
    checks.expect(!window.test_isShowingEditor, "deselecting does not show the editor")
    checks.expectEqual(window.test_mixer.test_rowDeviceIDs.count, 7,
                       "the mixer pane returns showing all devices")

    // --- 10. Delete: removes the group, mixer returns, "Groups" section stays
    //        (empty-state row comes back).
    print("\n[10] Delete group → deleteGroup, mixer pane returns, 'Groups' section stays")
    window.test_select(.group(id: saved.id))
    drain()
    checks.expect(window.test_isShowingEditor, "editor shown before delete")
    window.test_editor.test_confirmDelete()
    drain()
    checks.expectEqual(controller.groups.count, 0, "deleteGroup removed the group")
    checks.expect(!window.test_isShowingEditor, "mixer pane returns after delete")
    checks.expect(window.test_sidebar.test_sectionTitles.contains("Groups"),
                  "the 'Groups' section stays (config-only window always shows it)")
    checks.expect(window.test_sidebar.test_hasGroupsEmptyStateRow,
                  "the empty-state row returns once the group is gone")

    print("\n----------------------------------------")
    if checks.failures == 0 {
        print("PASS: all \(checks.total) window-structure checks passed")
        return 0
    } else {
        print("FAIL: \(checks.failures)/\(checks.total) window-structure checks failed")
        return 1
    }
}

exit(MainActor.assumeIsolated { run() })
