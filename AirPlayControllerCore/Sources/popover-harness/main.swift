// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Alec Henderson and contributors.
//
// popover-harness — programmatic verification for the popover (SPEC §9 2026-07-14b
// — SoundSource-inspired Main Out model).
//
// The popover isn't visible to an agent shell, so this instantiates the real
// `PopoverController` with a MockBackend-backed `GroupController`, drives the same
// code paths the row-view actions call (via the `test_*` hooks), and asserts:
// a Main Out selector with two sections (Selected Devices + groups); selecting a
// group routes (backend output set = members); toggles compose the Selected
// Devices set without routing when the target is a group; selecting Selected
// Devices applies the toggled set; the local-device auto-swap + mix block; the
// Main Out master = the current target's master. Prints PASS/FAIL; exits nonzero
// on failure so it can gate CI alongside `swift test`.

import AppKit
import AirPlayControllerCore
import AirPlayControllerPopoverUI

final class Checks {
    private(set) var failures = 0
    private(set) var total = 0
    func expect(_ condition: Bool, _ message: String) {
        total += 1
        if condition { print("  PASS  \(message)") }
        else { failures += 1; print("  FAIL  \(message)") }
    }
    func expectEqual<T: Equatable>(_ a: T, _ b: T, _ message: String) {
        expect(a == b, "\(message) (got \(a), expected \(b))")
    }
}

@MainActor
func waitForFleet(_ backend: MockBackend, count: Int, timeout: TimeInterval = 3) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while backend.devices.count < count && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    return backend.devices.count >= count
}

@MainActor
func drain(_ interval: TimeInterval = 0.2) {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(interval))
}

@MainActor
func run() -> Int32 {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let checks = Checks()

    let backend = MockBackend(fleet: .demoFleet, staggerDiscovery: false,
                              emitsLevels: false, simulatesDropouts: false)
    let controller = GroupController(backend: backend, store: GroupStore(directory: tempDir()),
                                     routingStore: RoutingStore(directory: tempDir()),
                                     loadPersisted: false)
    let popover = PopoverController()

    backend.start()
    guard waitForFleet(backend, count: 7) else {
        print("SETUP FAIL: fleet did not fully discover"); return 2
    }
    popover.configure(groupController: controller)
    controller.ensureDefaultSelection()          // default: current device selected
    popover.update(devices: backend.devices)

    // --- 1. Baseline: Main Out row present; device rows for all 7; default passthrough.
    print("\n[1] Baseline — Main Out row + Selected Devices section + default passthrough")
    checks.expectEqual(popover.test_deviceSectionRowCount, 7, "all 7 devices get a row")
    checks.expect(controller.isSpeakerSelected("local-mac"), "default: current device selected")
    checks.expect(controller.isPassthrough, "default state is passthrough (set == {local})")
    checks.expectEqual(controller.groups.count, 0, "no groups yet")

    // --- 2. Main Out selector: two sections (Selected Devices + groups after save).
    print("\n[2] Main Out selector sections")
    checks.expect(popover.test_mainOutRow.test_selectableTargets.contains(.selectedDevices),
                  "selector offers Selected Devices")
    checks.expect(popover.test_mainOutRow.test_optionTitles.contains("Selected Devices"),
                  "selector has a Selected Devices entry")

    // --- 3. Auto-swap: toggling an AirPlay device ON while local is sole member drops local.
    print("\n[3] Auto-swap (AirPlay ON while current device is sole member)")
    let swap = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
    drain()
    checks.expect(swap.autoSwappedCurrentDevice, "auto-swap fired")
    checks.expect(!controller.isSpeakerSelected("local-mac"), "current device auto-untoggled")
    checks.expect(controller.isSpeakerSelected("office"), "AirPlay device now selected")
    checks.expect(!controller.isPassthrough, "no longer passthrough")

    // --- 4. Auto-swap does NOT fire when local is not the sole member.
    print("\n[4] Auto-swap does not fire otherwise")
    let noSwap = popover.test_toggleDeviceEnabled(deviceID: "homepod-bed", on: true)
    drain()
    checks.expect(!noSwap.autoSwappedCurrentDevice, "no auto-swap (local wasn't a member)")
    checks.expect(controller.isSpeakerSelected("office") && controller.isSpeakerSelected("homepod-bed"),
                  "both AirPlay devices selected")

    // --- 5. Local-mix block: re-adding the current device into a mixed set is refused.
    print("\n[5] Local-mix block")
    checks.expect(!controller.canSelectLocalSpeaker("local-mac"),
                  "local can't currently join the mixed set")
    let refusal = popover.test_toggleDeviceEnabled(deviceID: "local-mac", on: true)
    drain()
    checks.expect(!refusal.applied, "adding local to a mixed set is refused")
    checks.expectEqual(refusal.refusalReason, GroupController.localMixRefusalReason,
                       "refusal carries the reason")
    checks.expect(!controller.isSpeakerSelected("local-mac"), "local stayed out")
    checks.expect(popover.test_lastRefusalReason == GroupController.localMixRefusalReason,
                  "the popover surfaced the refusal reason")

    // --- 6. Toggles compose the set WITHOUT routing when target is a group.
    print("\n[6] Toggles compose without routing when Main Out targets a group")
    // Save the current Selected Devices as a group, point Main Out at it.
    popover.test_saveCurrentSetup(); drain()
    checks.expectEqual(controller.groups.count, 1, "one group saved from Selected Devices")
    let group = controller.groups[0]
    popover.test_selectMainOut(.group(id: group.id)); drain()
    let outputBefore = Set(backend.devices.filter(\.isSelected).map(\.id))
    // Toggle a new device into Selected Devices — must NOT change the routed set.
    _ = popover.test_toggleDeviceEnabled(deviceID: "sonos-move-2", on: true); drain()
    let outputAfter = Set(backend.devices.filter(\.isSelected).map(\.id))
    checks.expectEqual(outputBefore, outputAfter,
                       "composing the set didn't re-route (target is a group)")
    checks.expect(controller.isSpeakerSelected("sonos-move-2"), "but the set was composed")

    // --- 7. Selecting a group routes: backend output set == members.
    print("\n[7] Selecting a group routes to its members")
    checks.expectEqual(Set(backend.devices.filter(\.isSelected).map(\.id)), Set(group.memberIDs),
                       "output set equals the group's members")
    checks.expectEqual(controller.activeGroupID, group.id, "group is the active target")

    // --- 8. Selecting Selected Devices applies the composed set.
    print("\n[8] Selecting Selected Devices applies the composed set")
    popover.test_selectMainOut(.selectedDevices); drain()
    let routed = Set(backend.devices.filter(\.isSelected).map(\.id))
    // Local device is never a backend output; expected routed = AirPlay members of the set.
    let expectedRouted = Set(controller.selectedDeviceIDs.filter { id in
        backend.devices.first { $0.id == id }?.isLocalDevice == false
    })
    checks.expectEqual(routed, expectedRouted, "Selected Devices routes its AirPlay members")

    // --- 9. Main Out master == current target's proportional master.
    print("\n[9] Main Out master reflects the current target")
    checks.expectEqual(popover.test_mainOutRow.test_masterValue, controller.mainOutMasterVolume,
                       "Main Out slider shows the target's master")
    // Drag the Main Out master and confirm members scale proportionally.
    let members = Array(controller.selectedDeviceIDs).filter { id in
        backend.devices.first { $0.id == id }?.isLocalDevice == false
    }
    if members.count >= 1 {
        backend.setVolume(40, for: members[0]); drain()
        popover.test_dragMainOutMaster(to: 80); drain()
        // members[0] had ratio 40/master; after master→80 it scales up.
        checks.expect((backend.devices.first { $0.id == members[0] }?.volume ?? 0) > 40,
                      "dragging Main Out master scaled a member up")
    }

    // --- 10. Mute (secondary) drives volume to 0 and restores.
    print("\n[10] Mute (secondary)")
    let target = group.memberIDs.first { id in
        backend.devices.first { $0.id == id }?.isLocalDevice == false
    } ?? group.memberIDs[0]
    let volBefore = backend.devices.first { $0.id == target }?.volume ?? -1
    if volBefore > 0 {
        popover.test_toggleMute(deviceID: target, muted: true); drain()
        checks.expectEqual(backend.devices.first { $0.id == target }?.volume, 0, "mute → volume 0")
        popover.test_toggleMute(deviceID: target, muted: false); drain()
        checks.expectEqual(backend.devices.first { $0.id == target }?.volume, volBefore, "unmute restores")
    }

    // --- 11. Header bar (task A): title + two system-symbol icon buttons.
    print("\n[11] Header bar")
    checks.expectEqual(popover.test_headerTitle, "AudioControl", "header title is AudioControl")
    checks.expect(popover.test_headerGroupsButtonHasImage,
                  "Open-Groups-editor button resolved a system SF Symbol")
    checks.expect(popover.test_headerSettingsButtonHasImage,
                  "Settings button resolved a system SF Symbol")
    var openedMixer = false
    popover.onOpenMixer = { openedMixer = true }
    popover.test_tapHeaderGroupsEditor()
    checks.expect(openedMixer, "header Groups-editor button opens the mixer path")

    // --- 12. A Selected-Devices row shows its on/off toggle. "airport-mixer" is
    // discovered but never grouped here.
    print("\n[12] Selected-Devices row shows its toggle")
    if let selRow = popover.test_deviceRow(for: "airport-mixer") {
        checks.expect(selRow.test_showsToggle, "a Selected-Devices row shows its toggle")
    } else {
        checks.expect(false, "the Selected-Devices row for airport-mixer exists")
    }

    // --- 13. Main Out named dropdown reflects the current target's title (task B).
    print("\n[13] Main Out named dropdown")
    popover.test_selectMainOut(.selectedDevices); drain()
    checks.expectEqual(popover.test_mainOutRow.test_selectedTitle, "Selected Devices",
                       "the Main Out dropdown shows the current target's name")
    popover.test_selectMainOut(.group(id: group.id)); drain()
    checks.expectEqual(popover.test_mainOutRow.test_selectedTitle, group.name,
                       "selecting a group updates the named dropdown to the group name")

    // --- 14. Connection-status flow (brief §7.3), on a scripted MockBackend:
    // fail → toggle bounced + warning + auto-expanded panel; sticky warning
    // survives the cleanup setOutputSet; "Try again" → connected + panel gone.
    print("\n[14] Connection-status flow (scripted MockBackend)")
    runConnectionStatusChecks(checks)

    print("\n----------------------------------------")
    if checks.failures == 0 {
        print("PASS: all \(checks.total) popover-structure checks passed")
        return 0
    } else {
        print("FAIL: \(checks.failures)/\(checks.total) popover-structure checks failed")
        return 1
    }
}

/// Drive the full §7.3 failure → retry flow against a fresh popover whose
/// MockBackend scripts `office` to fail once (not responding, with a raw
/// detail line) and connect on the second attempt. The harness stands in for
/// AppDelegate's event loop by pushing `backend.devices` snapshots into
/// `popover.update` after each choreography step.
@MainActor
func runConnectionStatusChecks(_ checks: Checks) {
    let backend = MockBackend(
        fleet: .demoFleet, staggerDiscovery: false,
        emitsLevels: false, simulatesDropouts: false,
        connectScripts: [
            "office": ConnectScript(attempts: [
                .fail(after: 0.2, ConnectionFailure(cause: .notResponding, detail: "raw engine log line")),
                .connect(after: 0.2),
            ]),
        ])
    let controller = GroupController(backend: backend, store: GroupStore(directory: tempDir()),
                                     routingStore: RoutingStore(directory: tempDir()),
                                     loadPersisted: false)
    let popover = PopoverController()

    backend.start()
    guard waitForFleet(backend, count: 7) else {
        checks.expect(false, "scripted fleet discovered"); return
    }
    popover.configure(groupController: controller)
    controller.ensureDefaultSelection()
    popover.update(devices: backend.devices)

    /// Poll `office`'s connection state until `predicate` holds (bounded).
    func waitForOffice(_ what: String, timeout: TimeInterval = 3,
                       _ predicate: (ConnectionState) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let device = backend.devices.first(where: { $0.id == "office" }),
               predicate(device.connectionState) { return true }
            drain(0.02)
        }
        checks.expect(false, "office reached \(what) in time")
        return false
    }
    func officeIsFailed(_ state: ConnectionState) -> Bool {
        if case .failed = state { return true }
        return false
    }

    // Enable → scripted first attempt fails.
    _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
    checks.expect(controller.isSpeakerSelected("office"), "toggle composed membership")
    guard waitForOffice(".failed", officeIsFailed) else { return }
    popover.update(devices: backend.devices)

    checks.expect(!controller.isSpeakerSelected("office"),
                  "failure bounced the toggle (membership removed)")
    checks.expect(popover.test_deviceRow(for: "office")?.test_isEnabledOn == false,
                  "row switch rests OFF after the bounce")
    checks.expect(popover.test_deviceRow(for: "office")?.test_statusKind == .failed,
                  "on-icon status dot shows the failed (amber) state")
    let panel = popover.test_diagnosisPanel(for: "office")
    checks.expect(panel != nil, "diagnosis panel auto-expanded on failure")
    checks.expectEqual(panel?.test_headlineText ?? "", "Didn't respond",
                       "panel renders the failure headline")
    checks.expect(panel?.test_copyDetailsEnabled == true,
                  "Copy details enabled (detail present)")

    // Sticky warning: the bounce triggered a cleanup setOutputSet without the
    // id; the backend keeps .failed and the popover keeps the warning + panel.
    drain(0.3)
    popover.update(devices: backend.devices)
    checks.expect(officeIsFailed(backend.devices.first { $0.id == "office" }?.connectionState ?? .off),
                  "backend kept .failed sticky through the cleanup setOutputSet")
    checks.expect(popover.test_deviceRow(for: "office")?.test_statusKind == .failed,
                  "failed dot survived the cleanup setOutputSet")
    checks.expect(popover.test_diagnosisPanel(for: "office") != nil,
                  "panel survived the cleanup setOutputSet")

    // "Try again" → second scripted attempt connects.
    popover.test_tapRetry(for: "office")
    checks.expect(controller.isSpeakerSelected("office"), "retry re-added membership")
    guard waitForOffice(".connected", { $0 == .connected }) else { return }
    popover.update(devices: backend.devices)

    checks.expect(popover.test_deviceRow(for: "office")?.test_statusKind == .connected,
                  "retry succeeded: green connected dot")
    checks.expect(popover.test_deviceRow(for: "office")?.test_isEnabledOn == true,
                  "the honest toggle now rests ON")
    checks.expect(popover.test_diagnosisPanel(for: "office") == nil,
                  "connected cleared the diagnosis panel")
}

func tempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("popover-harness-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

exit(MainActor.assumeIsolated { run() })
