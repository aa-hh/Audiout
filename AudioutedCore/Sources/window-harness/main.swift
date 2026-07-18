// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Alec Henderson and contributors.
//
// window-harness — programmatic verification for the T-U4 mixer window (SPEC §9).
//
// The mixer window isn't visible to an agent shell, so this instantiates the
// real `MixerWindowController` with a MockBackend-backed `GroupController`,
// drives the same code paths the toolbar / sidebar / editor actions call (via
// the `test_*` hooks), and asserts the built window structure:
//   - the sidebar has the "Groups" / "Devices" sections with the right counts;
//   - selecting a group shows the editor pane populated with its members and
//     activates it (output set = members);
//   - the mixer pane shows a `DeviceRowView` per scoped device, and dragging a
//     row's slider drives the backend;
//   - renaming in the editor calls `GroupController.saveGroup`;
//   - toggling a membership checkbox updates the group's members;
//   - deleting calls `GroupController.deleteGroup`;
//   - the toolbar presets popup lists the groups and selecting one activates it.
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

    // --- 0. Window chrome: unified toolbar + full-size content view + mounted
    //        toolbar items (SPEC §9 "Full window").
    print("\n[0] Window chrome (unified toolbar, full-size content, toolbar items)")
    checks.expectEqual(window.test_toolbarStyle, .unified,
                       "window.toolbarStyle is .unified (SPEC §9)")
    checks.expect(window.test_hasFullSizeContentView,
                  "styleMask includes .fullSizeContentView (SPEC §9)")
    checks.expect(window.test_toolbarItemIdentifiers.contains("master"),
                  "toolbar mounts the master-volume item")
    checks.expect(window.test_toolbarItemIdentifiers.contains("presets"),
                  "toolbar mounts the presets item")

    // --- 1. Baseline sidebar: no groups yet → just the "Devices" section, 6 rows.
    print("\n[1] Baseline sidebar (no groups)")
    checks.expectEqual(window.test_sidebar.test_sectionTitles, ["Devices"],
                       "only the 'Devices' section before any group is saved")
    checks.expectEqual(window.test_sidebar.test_ungroupedDeviceRowCount, 7,
                       "all 7 devices listed as ungrouped")
    checks.expect(!window.test_isShowingEditor, "the mixer pane shows by default (not the editor)")

    // --- 2. Baseline mixer: all 7 devices shown as rows.
    print("\n[2] Baseline mixer pane (all devices)")
    checks.expectEqual(window.test_mixer.test_rowDeviceIDs.count, 7,
                       "mixer shows a DeviceRowView per device (7)")

    // --- 3. Quick-create a group (compose the Selected Devices set, then save),
    // sidebar gains a Groups section. (SPEC §9b: save = save Selected Devices.)
    print("\n[3] Save a group → sidebar Groups section appears")
    _ = controller.setDeviceSelected("sonos-move", true)
    _ = controller.setDeviceSelected("office", true)
    checks.expectEqual(controller.selectedDeviceIDs.count, 2, "two devices composed into the set")
    let saved = try! controller.saveCurrentSetupAsGroup(name: "Group 1").group
    window.update(devices: backend.devices)
    checks.expect(window.test_sidebar.test_sectionTitles.contains("Groups"),
                  "sidebar now has a 'Groups' section")
    checks.expectEqual(window.test_sidebar.test_groupRowCount, 1, "one group row")
    checks.expectEqual(Set(window.test_sidebar.test_memberIDs(underGroup: saved.id)),
                       Set(saved.memberIDs),
                       "the group node lists exactly its member devices")

    // --- 4. Selecting the group shows the editor + activates it + scopes rows.
    print("\n[4] Select group → editor pane, activated, members in editor")
    window.test_select(.group(id: saved.id))
    drain()
    checks.expect(window.test_isShowingEditor, "selecting a group shows the editor pane")
    checks.expectEqual(controller.activeGroupID, saved.id, "selecting a group activates it")
    checks.expectEqual(window.test_editor.editingGroupID, saved.id, "editor is editing that group")
    checks.expectEqual(Set(window.test_editor.test_checkedDeviceIDs), Set(saved.memberIDs),
                       "editor's checked checkboxes equal the group's members")
    checks.expectEqual(window.test_editor.test_candidateDeviceIDs.count, 7,
                       "editor offers every device as a membership candidate")

    // --- 5. Rename in the editor → GroupController.saveGroup persists the name.
    print("\n[5] Rename in editor → saveGroup")
    window.test_editor.test_rename(to: "Whole House")
    checks.expectEqual(controller.groups.first { $0.id == saved.id }?.name, "Whole House",
                       "rename persisted through GroupController.saveGroup")
    checks.expectEqual(window.test_sidebar.test_memberIDs(underGroup: saved.id).isEmpty, false,
                       "group still present after rename")

    // --- 6. Toggle a membership checkbox → group membership updates.
    print("\n[6] Toggle membership checkbox → group members update")
    let extraDevice = backend.devices.first { !saved.memberIDs.contains($0.id) }!.id
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

    // --- 7. Mixer row drives the backend (drag a member's slider).
    print("\n[7] Mixer row slider drives the backend")
    window.test_select(nil)   // back to the all-devices mixer
    drain()
    let target = saved.memberIDs[0]
    if let row = window.test_mixer.test_row(for: target) {
        row.test_setVolume(15)
        drain()
        checks.expectEqual(backend.devices.first { $0.id == target }?.volume, 15,
                           "dragging a mixer row's slider set the backend volume")
    } else {
        checks.expect(false, "mixer has a row for the target device")
    }

    // --- 8. Toolbar presets popup lists the group; selecting it activates.
    print("\n[8] Toolbar presets popup")
    checks.expect(window.test_toolbar.test_presetTitles.contains("No group"),
                  "presets popup has a 'No group' sentinel first")
    checks.expect(window.test_toolbar.test_presetTitles.contains("Whole House"),
                  "presets popup lists the group by (renamed) name")
    controller.deactivateGroup()
    window.update(devices: backend.devices)
    window.test_toolbar.test_selectPreset(groupID: saved.id)
    drain()
    checks.expectEqual(controller.activeGroupID, saved.id,
                       "selecting a preset activates that group")

    // --- 9. Master drag through the toolbar scales members proportionally.
    print("\n[9] Toolbar master drag scales members proportionally")
    let m0 = saved.memberIDs[0], m1 = saved.memberIDs[1]
    backend.setVolume(40, for: m0); backend.setVolume(80, for: m1); drain()
    window.update(devices: backend.devices)
    checks.expectEqual(controller.masterVolume, 60, "master echoes the members' average (60)")
    window.test_toolbar.test_dragMaster(to: 30)
    drain()
    checks.expectEqual(backend.devices.first { $0.id == m0 }?.volume, 20, "member0 40→20")
    checks.expectEqual(backend.devices.first { $0.id == m1 }?.volume, 40, "member1 80→40")

    // --- 10. Delete the group → GroupController.deleteGroup + back to the mixer.
    print("\n[10] Delete group → deleteGroup, mixer pane returns")
    window.test_select(.group(id: saved.id))
    drain()
    checks.expect(window.test_isShowingEditor, "editor shown before delete")
    window.test_editor.test_confirmDelete()
    drain()
    checks.expectEqual(controller.groups.count, 0, "deleteGroup removed the group")
    checks.expect(!window.test_isShowingEditor, "mixer pane returns after delete")
    checks.expect(!window.test_sidebar.test_sectionTitles.contains("Groups"),
                  "the 'Groups' section is gone")

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
