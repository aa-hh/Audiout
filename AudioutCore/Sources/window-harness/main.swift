// SPDX-License-Identifier: GPL-2.0-or-later
//
// window-harness — programmatic verification for the Scenes SCREEN's content
// (design revamp, SPEC §9; the standalone Scenes window was retired in U6).
// The screen is CONFIGURATION-ONLY: viewing or editing a group here never
// activates it or moves audio — activation lives in the app's Mixer screen.
//
// The content isn't visible to an agent shell, so this instantiates the real
// `MixerWindowController` (the screen-content controller) with a
// MockBackend-backed `GroupController`, drives the same code paths the
// sidebar / editor / create-sheet actions call (via the `test_*` hooks), and
// asserts the built structure — see the numbered checks below. Prints
// PASS/FAIL per check; exits nonzero on any failure so it can gate CI
// alongside `swift test`.

import AppKit
import AudioutCore
import AudioutWindowUI

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
    // Never show a real window on the developer's screen while this headless
    // tool runs (`HeadlessRuntime` in AudioutCore) — set BEFORE touching
    // AppKit. Headless AppKit: an accessory app so NSImage(systemSymbolName:)
    // etc. work.
    setenv("AIRPLAY_HEADLESS", "1", 1)
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let checks = Checks()

    let backend = MockBackend(fleet: .demoFleet, staggerDiscovery: false,
                              emitsLevels: false, simulatesDropouts: false)
    let controller = GroupController(backend: backend, store: GroupStore(directory: tempDir()),
                                     loadPersisted: false)
    let window = MixerWindowController(groupController: controller)
    // The real host seam: the surface marks the Scenes screen visible, which
    // opens the B8 refresh gate — without it every `update(devices:)` below
    // only stores its snapshot and the sidebar renders empty.
    window.setHostVisible(true)

    backend.start()
    guard waitForFleet(backend, count: 7) else {
        print("SETUP FAIL: fleet did not fully discover"); return 2
    }
    window.update(devices: backend.devices)

    // --- 1. Baseline sidebar: the device fleet under the pinned Scenes row
    //        (direction C — saved groups are cards in the content pane now).
    print("\n[1] Baseline sidebar (zero groups)")
    checks.expectEqual(window.test_sidebar.test_sectionTitles,
                       ["System Audio", "Speakers"],
                       "'System Audio' and 'Speakers' are the only sections — groups left the sidebar")
    checks.expect(window.test_sidebar.test_hasGroupsRow,
                  "the pinned Scenes row is present")
    checks.expectEqual(window.test_sidebar.test_deviceRowCount, 7,
                       "all 7 devices listed (Speakers section lists every device, flat model)")
    checks.expect(!window.test_isShowingEditor, "no editor shows with zero groups")

    // --- 2. Baseline content: with zero groups the AUTO-SELECT rule lands on
    //        the overview, which draws its own zero-groups canvas.
    print("\n[2] Baseline content pane (the overview's empty canvas at zero groups)")
    checks.expect(window.test_isShowingOverview,
                  "the card overview shows when there is nothing selected")
    checks.expect(window.test_overview.test_isShowingEmptyCanvas,
                  "with zero groups the overview IS the empty state — no separate pane")

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
        checks.expect(window.test_sidebar.test_groupsRowIsSelected,
                      "the sidebar highlights the pinned Scenes row, not a row of its own")
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

    // --- 7. AUTO-SELECT: deselecting lands on the card overview (never a
    //        blank/no-op pane, and never one group's editor picked for the
    //        user). The window has no volume UI at all now — master math is
    //        exercised by the popover harness.
    print("\n[7] Auto-select: deselecting lands on the card overview")
    window.test_select(nil)
    drain()
    checks.expect(window.test_isShowingOverview,
                  "deselecting auto-selects the Scenes overview")
    checks.expect(!window.test_isShowingEditor, "and opens no group's editor on the user's behalf")
    checks.expectEqual(window.test_overview.test_cardGroupIDs, [saved.id],
                       "the saved group has a card")
    checks.expect(window.test_sidebar.test_groupsRowIsSelected,
                  "the sidebar reflects the auto-selection")
    checks.expectEqual(controller.activeGroupID, nil,
                       "auto-selection does NOT activate (config-only)")

    // --- 7b. A card opens its editor in place, with the Scenes row still
    //         selected (the fleet must not move under the pointer).
    print("\n[7b] Clicking a card pushes that group's editor")
    window.test_overview.test_clickCard(id: saved.id)
    drain()
    checks.expect(window.test_isShowingEditor, "the card opened the editor")
    checks.expectEqual(window.test_editor.editingGroupID, saved.id,
                       "the editor is editing the clicked card's group")
    checks.expect(window.test_sidebar.test_groupsRowIsSelected,
                  "the Scenes row stays selected throughout the push")
    window.test_editor.test_goBack()
    drain()
    checks.expect(window.test_isShowingOverview, "'‹ Scenes' pops back to the card field")

    // --- 8. Cancelling a presented create sheet clears it.
    print("\n[8] Cancelling the create sheet clears it")
    window.test_presentCreateSheet(preselected: [])
    checks.expect(window.test_isPresentingCreateSheet, "presenting wires a live create sheet")
    window.test_createSheet?.test_cancel()
    drain()
    checks.expect(!window.test_isPresentingCreateSheet, "cancelling clears the sheet")

    // --- 9. Select a device: the detail pane that describes and tunes it,
    //        membership text correct, `activeGroupID` untouched; deselecting
    //        returns the mixer pane.
    print("\n[9] Select a device shows the detail pane that describes and tunes it")
    checks.expectEqual(controller.activeGroupID, nil,
                       "sanity: no group active before selecting a device")
    window.test_select(.device(id: candidateA))
    drain()
    checks.expect(window.test_isShowingDetail, "selecting a device shows the detail pane")
    checks.expect(!window.test_isShowingEditor, "selecting a device does not show the editor")
    checks.expectEqual(window.test_detail.test_shownDeviceID, candidateA,
                       "detail pane is showing the selected device")
    checks.expectEqual(window.test_detail.test_groupMembershipText, "Whole House",
                       "detail pane's 'In groups' text names the device's saved group")
    checks.expectEqual(controller.activeGroupID, nil,
                       "selecting a device in the sidebar does NOT activate any group")
    window.test_select(nil)
    drain()
    checks.expect(!window.test_isShowingDetail, "deselecting clears the detail pane")
    checks.expect(window.test_isShowingOverview,
                  "deselecting auto-selects the card overview (never a blank pane)")

    // --- 10. Delete: removes the group, the overview returns as its own empty
    //        canvas, the pinned Scenes row stays.
    print("\n[10] Delete group → deleteGroup, the overview's empty canvas returns")
    window.test_select(.group(id: saved.id))
    drain()
    checks.expect(window.test_isShowingEditor, "editor shown before delete")
    window.test_editor.test_confirmDelete()
    drain()
    checks.expectEqual(controller.groups.count, 0, "deleteGroup removed the group")
    checks.expect(!window.test_isShowingEditor, "the editor clears after delete")
    checks.expect(window.test_isShowingOverview,
                  "with the last group gone, the overview returns")
    checks.expect(window.test_overview.test_isShowingEmptyCanvas,
                  "drawing its own zero-groups canvas")
    checks.expect(window.test_sidebar.test_hasGroupsRow,
                  "the pinned Scenes row stays (this screen is scenes-configuration only)")

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
