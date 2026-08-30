// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
import AppKit
import AudioutProtocol
@testable import AudioutCore
@testable import AudioutPopoverUI
@testable import AudioutSharedUI

/// Structural + integration coverage for the popover (SPEC §9 2026-07-14b —
/// SoundSource-inspired Main Out model). The popover isn't visible to CI, so
/// these assert the built panel structure and that interactions call through the
/// model — the same checks the `popover-harness` executable runs, folded into
/// `swift test`.
/// `.serialized`: this suite's connection-state tests (`makeScriptedPopover`)
/// drive `MockBackend` scripted timers with real wall-clock delays as short as
/// 0.05s. Under swift-testing's default in-process concurrency, all ~80 tests
/// in this suite (unlike XCTest's one-process-per-test-method isolation) run
/// as concurrent tasks competing for the same CPU, and that contention alone
/// was enough to blow through the scripted delays/timeouts — verified: the
/// same tests pass reliably individually or serially, and fail with a
/// different subset each time when run fully concurrently. Serializing this
/// suite restores the effective isolation XCTest gave it for free.
@MainActor
@Suite(.serialized) struct PopoverControllerTests {

    private func makePopover(
        appRouting: AppRoutingController? = nil,
        runningAppsProvider: (() -> [RunningAppInfo])? = nil
    ) async throws -> (PopoverController, GroupController, MockBackend) {
        let backend = MockBackend(fleet: .demoFleet, staggerDiscovery: false,
                                  emitsLevels: false, simulatesDropouts: false)
        try await waitForFleet(backend, count: 7)
        let controller = GroupController(backend: backend,
                                         store: GroupStore(directory: tempDirectory()),
                                         routingStore: RoutingStore(directory: tempDirectory()),
                                         loadPersisted: false)
        let popover: PopoverController
        switch (appRouting, runningAppsProvider) {
        case let (appRouting?, provider?):
            popover = PopoverController(appRouting: appRouting, runningAppsProvider: provider)
        case let (appRouting?, nil):
            popover = PopoverController(appRouting: appRouting)
        case let (nil, provider?):
            popover = PopoverController(runningAppsProvider: provider)
        case (nil, nil):
            popover = PopoverController()
        }
        popover.configure(groupController: controller)
        controller.ensureDefaultSelection()
        // A closed popover no longer rebuilds on `update(devices:)` (audit B8);
        // the view tree is this suite's rendering surface, so run every test
        // as if the popover were shown. Closed-state behavior has its own
        // dedicated tests below.
        popover.test_isShownOverride = true
        popover.update(devices: backend.devices)
        return (popover, controller, backend)
    }

    private func tempAppRoutingController() -> AppRoutingController {
        let store = AppRouteStore(directory: tempDirectory())
        return AppRoutingController(store: store, loadPersisted: false)
    }

    private func waitForFleet(_ backend: MockBackend, count: Int) async throws {
        // With `staggerDiscovery: false` every device is added synchronously
        // inside `start()`'s `queue.async` block (MockBackend.swift), so a
        // `test_settle()` barrier right after `start()` is a complete
        // discovery wait for this fixture — no event-stream/confirmation
        // machinery needed.
        backend.start()
        backend.test_settle()
        try #require(backend.devices.count >= count)
    }

    private func tempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PopoverControllerTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func drain(_ backend: MockBackend) async { backend.test_settle(); await Task.yield() }

    // MARK: Tests

    @Test func baselineHasDeviceRowsAndDefaultPassthrough() async throws {
        let (popover, controller, _) = try await makePopover()
        #expect(controller.groups.count == 0)
        #expect(popover.test_deviceSectionRowCount == 7)
        #expect(controller.isSpeakerSelected("local-mac"), "current device selected by default")
        #expect(controller.isPassthrough, "default set == {local} ⇒ passthrough")
    }

    @Test func mainOutSelectorHasSelectedDevicesAndGroups() async throws {
        let (popover, controller, backend) = try await makePopover()
        // Before any group: only Selected Devices is selectable.
        #expect(popover.test_mainOutRow.test_selectableTargets == [.selectedDevices])

        // After a group is saved, it appears as a second section.
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        popover.test_saveCurrentSetup(); await drain(backend)
        let group = controller.groups[0]
        #expect(popover.test_mainOutRow.test_selectableTargets.contains(.group(id: group.id)), "the saved group is a Main Out option")
        #expect(popover.test_mainOutRow.test_optionTitles.contains("Output Groups"), "groups are under an Output Groups header")
    }

    @Test func emptyGroupIsNotOfferedAsAMainOutOption() async throws {
        // A group left empty by an older build (persisted directly, bypassing the
        // current non-empty invariant) must not appear as a routing target.
        let store = GroupStore(directory: tempDirectory())
        try store.save([
            Group(id: "ghost", name: "Ghost", memberIDs: [], memberVolumes: [:]),
            Group(id: "real", name: "Kitchen", memberIDs: ["office"], memberVolumes: ["office": 50]),
        ])

        let backend = MockBackend(fleet: .demoFleet, staggerDiscovery: false,
                                  emitsLevels: false, simulatesDropouts: false)
        try await waitForFleet(backend, count: 7)
        let controller = GroupController(backend: backend, store: store,
                                         routingStore: RoutingStore(directory: tempDirectory()),
                                         loadPersisted: true)
        let popover = PopoverController()
        popover.configure(groupController: controller)
        controller.ensureDefaultSelection()
        popover.test_isShownOverride = true
        popover.update(devices: backend.devices)

        let targets = popover.test_mainOutRow.test_selectableTargets
        #expect(targets.contains(.group(id: "real")), "the non-empty group is offered")
        #expect(!(targets.contains(.group(id: "ghost"))), "the empty group must not be offered")
        #expect(!(popover.test_mainOutRow.test_optionTitles.contains("Ghost")), "the empty group's name must not appear in the menu")
    }

    @Test func toggleComposesSelectedDevicesWithoutRoutingWhenTargetIsGroup() async throws {
        let (popover, controller, backend) = try await makePopover()
        // Build a group, point Main Out at it.
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        popover.test_saveCurrentSetup(); await drain(backend)
        let group = controller.groups[0]
        popover.test_selectMainOut(.group(id: group.id)); await drain(backend)
        let before = Set(backend.devices.filter(\.isSelected).map(\.id))

        // Toggling composes the set but must not re-route (target is a group).
        _ = popover.test_toggleDeviceEnabled(deviceID: "homepod-bed", on: true); await drain(backend)
        let after = Set(backend.devices.filter(\.isSelected).map(\.id))
        #expect(before == after, "composing the set didn't change the routed output")
        #expect(controller.isSpeakerSelected("homepod-bed"), "but the set was composed")
    }

    @Test func selectingGroupRoutesToItsMembers() async throws {
        let (popover, controller, backend) = try await makePopover()
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        popover.test_saveCurrentSetup(); await drain(backend)
        let group = controller.groups[0]
        popover.test_selectMainOut(.group(id: group.id)); await drain(backend)
        #expect(controller.activeGroupID == group.id)
        #expect(Set(backend.devices.filter(\.isSelected).map(\.id)) == Set(group.memberIDs))
    }

    /// Live-caught: PLAYING is what Main Out actually SENDS to, not the dormant
    /// Selected set. A member of the group Main Out targets is audible right now,
    /// so its volume and mute must stay live even with its Selected checkbox
    /// cleared.
    @Test func aGroupMemberIsAdjustableWhileItsGroupIsMainOut() async throws {
        let (popover, controller, backend) = try await makePopover(appRouting: tempAppRoutingController())
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        popover.test_saveCurrentSetup(); await drain(backend)
        let group = controller.groups[0]
        popover.test_selectMainOut(.group(id: group.id)); await drain(backend)
        // Saving leaves "office" checked as well, which the OLD selected-set-only
        // predicate would have ridden; clear it so ONLY group membership can be
        // keeping the row live.
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: false); await drain(backend)
        #expect(!(controller.isSpeakerSelected("office")), "the dormant Selected set no longer holds it")
        #expect(controller.isMainOutMember("office"), "but the group Main Out targets still does")
        #expect(popover.test_deviceRow(for: "office")?.test_isSliderEnabled == true,
                "a playing group member stays adjustable (mute rides the same value)")
    }

    /// The deliberate other direction of the same field: selected but outside the
    /// active group means Main Out sends it nothing, so it must NOT be adjustable.
    @Test func aDeviceStrandedInTheDormantSelectedSetIsNotAdjustable() async throws {
        let (popover, controller, backend) = try await makePopover(appRouting: tempAppRoutingController())
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        popover.test_saveCurrentSetup(); await drain(backend)
        let group = controller.groups[0]
        _ = popover.test_toggleDeviceEnabled(deviceID: "homepod-bed", on: true)
        popover.test_selectMainOut(.group(id: group.id)); await drain(backend)
        #expect(controller.isSpeakerSelected("homepod-bed"), "in the dormant Selected set")
        #expect(!(controller.isMainOutMember("homepod-bed")), "but not in the group that's playing")
        #expect(popover.test_deviceRow(for: "homepod-bed")?.test_isSliderEnabled == false,
                "a silent device must not be adjustable")
    }

    @Test func selectingSelectedDevicesRoutesTheAirPlayMembers() async throws {
        let (popover, controller, backend) = try await makePopover()
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        _ = popover.test_toggleDeviceEnabled(deviceID: "homepod-bed", on: true)
        popover.test_selectMainOut(.selectedDevices); await drain(backend)
        let routed = Set(backend.devices.filter(\.isSelected).map(\.id))
        #expect(routed == ["office", "homepod-bed"], "Selected Devices routes exactly its AirPlay members (local isn't a backend output)")
    }

    @Test func autoSwapDropsLocalWhenItIsTheSoleMember() async throws {
        let (popover, controller, _) = try await makePopover()
        #expect(controller.selectedDeviceIDs == ["local-mac"])
        let result = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        #expect(result.autoSwappedCurrentDevice, "auto-swap fired")
        #expect(!(controller.isSpeakerSelected("local-mac")), "current device dropped")
        #expect(controller.isSpeakerSelected("office"))
    }

    @Test func autoSwapDoesNotFireWhenLocalIsNotSoleMember() async throws {
        let (popover, controller, _) = try await makePopover()
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)   // drops local
        // Now local is not a member at all; a further AirPlay add must not "auto-swap".
        let result = popover.test_toggleDeviceEnabled(deviceID: "homepod-bed", on: true)
        #expect(!(result.autoSwappedCurrentDevice), "no auto-swap when local isn't the sole member")
    }

    @Test func addingLocalIntoAMixedSetIsAllowed() async throws {
        // T-GROUPCTL (Q5): the synced local sink lifted the old pre-engine
        // local-mix block. The Mac may now join a mixed Selected Devices set.
        let (popover, controller, _) = try await makePopover()
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)   // mixed AirPlay set, local out
        let result = popover.test_toggleDeviceEnabled(deviceID: "local-mac", on: true)
        #expect(result.applied, "adding local into a mixed set is now allowed")
        #expect(result.refusalReason == nil)
        #expect(controller.isSpeakerSelected("local-mac"))
        #expect(controller.isSpeakerSelected("office"), "AirPlay member stays — Mac joins, nothing drops")
        // The local row's toggle is presented enabled (not blocked).
        let row = try #require(popover.test_deviceRow(for: "local-mac"))
        #expect(row.test_isEnabledOn)
    }

    /// T-UI-ALLOW: the sibling of `testAddingLocalIntoAMixedSetIsAllowed` above,
    /// but driven through the row's REAL AppKit dispatch path
    /// (`enableCheckbox.performClick(_:)` via `test_performEnableClick()`)
    /// instead of `test_toggleDeviceEnabled`, which calls
    /// `GroupController.setDeviceSelected` directly and never touches the
    /// checkbox or its target/action wiring at all. Per the repo's own
    /// documented lesson (row selection tests bypassing AppKit dispatch let a
    /// real `MainOutRowView` regression through green tests), a delegate
    /// shortcut can't catch a checkbox that's actually left disabled/greyed —
    /// `performClick` is a no-op on a disabled `NSControl`, so if the local row
    /// were still blocked (a T-GROUPCTL/T-UI-ALLOW regression) this test would
    /// fail because the click would silently do nothing.
    @Test func clickingTheLocalRowCheckboxThroughRealDispatchJoinsAMixedSet() async throws {
        let (popover, controller, _) = try await makePopover()
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)   // mixed AirPlay set, local out
        #expect(!(controller.isSpeakerSelected("local-mac")), "starts out of the set")

        let row = try #require(popover.test_deviceRow(for: "local-mac"))
        row.test_performEnableClick()   // real enableCheckbox.performClick(_:) dispatch

        #expect(row.test_isEnabledOn, "the checkbox itself flips ON via its own action")
        #expect(controller.isSpeakerSelected("local-mac"), "a real click joins the Mac into the mixed Selected Devices set")
        #expect(controller.isSpeakerSelected("office"), "the AirPlay member stays selected — nothing drops when the Mac joins")

        // Click again (real dispatch) to remove it — same path, both directions.
        row.test_performEnableClick()
        #expect(!(row.test_isEnabledOn))
        #expect(!(controller.isSpeakerSelected("local-mac")), "a second real click removes it again")
        #expect(controller.isSpeakerSelected("office"), "removing local never touches the AirPlay member")
    }

    /// The Main Out row shows MAIN'S OWN value. It used to show the members'
    /// average, so setting a member's level moved the readout; now a member move
    /// must leave the row exactly where it was.
    @Test func mainOutRowShowsMainsOwnValueNotTheMembersAverage() async throws {
        let (popover, controller, backend) = try await makePopover()
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)   // set = {office}
        popover.test_selectMainOut(.selectedDevices); await drain(backend)
        popover.test_dragMainOutMaster(to: 70); await drain(backend)

        backend.setVolume(50, for: "office"); await drain(backend)
        popover.update(devices: backend.devices)
        #expect(controller.mainOutMasterVolume == 70,
                       "a member's own level does not move Main")
        #expect(popover.test_mainOutRow.test_masterValue == 70,
                       "the Main Out slider shows Main's own value, not the members' average")
    }

    @Test func mainOutMasterIsIndependentOfMemberVolumes() async throws {
        let (popover, controller, backend) = try await makePopover()
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        _ = popover.test_toggleDeviceEnabled(deviceID: "homepod-bed", on: true)
        popover.test_selectMainOut(.selectedDevices); await drain(backend)
        backend.setVolume(40, for: "office"); backend.setVolume(80, for: "homepod-bed"); await drain(backend)
        popover.test_dragMainOutMaster(to: 30); await drain(backend)
        #expect(controller.mainOutMasterVolume == 30, "master volume is the dragged value")
        #expect(backend.devices.first { $0.id == "office" }?.volume == 40, "member volumes remain unchanged")
        #expect(backend.devices.first { $0.id == "homepod-bed" }?.volume == 80, "member volumes remain unchanged")
    }

    // MARK: A master move from OFF this Mac (the phone)

    /// A phone's `setMainOutMasterVolume` produces NO `BackendEvent`, so nothing
    /// calls `update(devices:)` and the popover's normal repaint tail never runs
    /// for it. `GroupController.onStateDidChange` is the only announcement, and
    /// `AppDelegate` chains `refreshMainOutMaster()` onto it. Without that pair
    /// the Mac's slider sat frozen at its old value until some unrelated device
    /// event happened to arrive. The hook is wired here the way
    /// `AppDelegate.wireCompanionServer()` wires it (that file isn't reachable
    /// from tests), and the move is driven through the REAL dispatcher.
    @Test func aPhoneMasterMoveRepaintsTheMainOutRowWithNoBackendEvent() async throws {
        let (popover, controller, backend) = try await makePopover()
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)   // a real output — not the passthrough case
        popover.test_selectMainOut(.selectedDevices); await drain(backend)
        popover.test_dragMainOutMaster(to: 20); await drain(backend)
        #expect(popover.test_mainOutRow.test_masterValue == 20, "precondition: the row starts where the Mac left it")

        controller.onStateDidChange = { popover.refreshMainOutMaster() }
        let dispatcher = CompanionCommandDispatcher(
            groupController: controller,
            appRouting: tempAppRoutingController(),
            settings: AppSettings(),
            isExcluded: { _ in false },
            setLocalPlaybackVolume: { _, _ in },
            applyStartBuffer: { _ in })

        #expect(dispatcher.execute(.setMainOutMasterVolume(volume: 73)).applied)
        await drain(backend)

        #expect(controller.mainOutMasterVolume == 73, "precondition: the model took the phone's value")
        #expect(popover.test_mainOutRow.test_masterValue == 73,
                       "the Main Out slider follows a phone-originated master move with no backend event behind it")
        // The READOUT, not `statusMasterVolume` — that reads the controller
        // straight through (see its doc), so asserting it here would pass against
        // a popover that never repainted at all. The label is a real painted
        // surface and moves only if the repaint ran.
        #expect(popover.test_mainOutRow.test_masterReadout == VolumePercent.label(73),
                       "and the readout beside it, not just the thumb")
    }

    /// The passthrough half of the same repaint: with nothing but the Mac
    /// selected, the Mac's DEVICE row slider reads Main, so a phone-driven master
    /// move has to move that row too — not just the Main Out row.
    @Test func aPhoneMasterMoveRepaintsTheMacRowInPassthrough() async throws {
        let (popover, controller, backend) = try await makePopover()
        popover.test_selectMainOut(.selectedDevices); await drain(backend)
        #expect(controller.localRowDrivesMain, "precondition: nothing but the Mac is selected")
        // A known starting master, so the move below is a real change edge — the
        // seed comes from `AppSettings`' persisted value, which this suite doesn't
        // isolate and so can't assume.
        popover.test_dragMainOutMaster(to: 12); await drain(backend)

        controller.onStateDidChange = { popover.refreshMainOutMaster() }
        controller.setMainOutMasterVolume(44); await drain(backend)

        #expect(popover.test_deviceRow(for: "local-mac")?.test_sliderValue == 44,
                       "the Mac's row follows Main while it is the thing driving Main")
    }

    /// The narrowed repaint's other half: with a real output in the target the
    /// Mac's row is an ordinary member reading its OWN fader, so a master move
    /// must leave it alone (`refreshMainOutMaster` skips the device sweep there).
    @Test func aMasterMoveLeavesTheMacRowAloneWhenItIsAnOrdinaryMember() async throws {
        let (popover, controller, backend) = try await makePopover()
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        _ = popover.test_toggleDeviceEnabled(deviceID: "local-mac", on: true)   // mixed set — the Mac is just a member
        popover.test_selectMainOut(.selectedDevices); await drain(backend)
        let macFader = try #require(backend.devices.first { $0.id == "local-mac" }?.volume)

        controller.onStateDidChange = { popover.refreshMainOutMaster() }
        controller.setMainOutMasterVolume(macFader == 44 ? 45 : 44); await drain(backend)

        #expect(popover.test_deviceRow(for: "local-mac")?.test_sliderValue == macFader,
                       "the Mac's own stored fader is what its row shows once it shares the mix")
    }

    /// A master move from the phone must not land under a finger already dragging
    /// the Mac's own master. The thumb was guarded; the readout beside it was not,
    /// so the phone's number appeared next to the user's own position.
    @Test func aPhoneMasterMoveLeavesBothThumbAndReadoutAloneMidDrag() async throws {
        let (popover, controller, backend) = try await makePopover()
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        popover.test_selectMainOut(.selectedDevices); await drain(backend)
        popover.test_dragMainOutMaster(to: 20); await drain(backend)

        popover.test_mainOutRow.test_isDraggingMaster = true
        controller.onStateDidChange = { popover.refreshMainOutMaster() }
        controller.setMainOutMasterVolume(73); await drain(backend)

        #expect(popover.test_mainOutRow.test_masterValue == 20, "the thumb stays under the finger")
        #expect(popover.test_mainOutRow.test_masterReadout == VolumePercent.label(20), "and so does the number beside it")
    }

    // MARK: The passthrough exception — the Mac's row IS Main

    /// With no real output in the target, the Mac's row and Main are physically one
    /// control (the Mac's audible level IS the system volume). The row therefore
    /// has to READ Main, not the Mac's own stored fader — otherwise the slider
    /// shows one number while dragging it moves another, and the thumb jumps on the
    /// first repaint.
    @Test func inPassthroughTheMacRowDisplaysMain() async throws {
        let (popover, controller, backend) = try await makePopover()
        popover.test_selectMainOut(.selectedDevices); await drain(backend)
        #expect(controller.localRowDrivesMain, "precondition: nothing but the Mac is selected")

        popover.test_dragMainOutMaster(to: 35); await drain(backend)
        popover.rebuild()
        #expect(popover.test_deviceRow(for: "local-mac")?.test_sliderValue == 35,
                       "the Mac's row follows Main while it is the thing driving Main")
    }

    /// …and once a real output joins, the row goes back to showing the Mac's OWN
    /// fader, which was remembered untouched underneath the whole time. This is the
    /// half that would silently regress: the overlay must be conditional, not a
    /// permanent aliasing of the two values.
    @Test func armingRestoresTheMacRowToItsOwnRememberedFader() async throws {
        let (popover, controller, backend) = try await makePopover()
        popover.test_selectMainOut(.selectedDevices); await drain(backend)
        backend.setVolume(62, for: "local-mac"); await drain(backend)   // the Mac's own trim

        popover.test_dragMainOutMaster(to: 35); await drain(backend)
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true); await drain(backend)
        #expect(!controller.localRowDrivesMain, "a real output is live now")

        popover.update(devices: backend.devices)   // the row reads a device value, so refresh the snapshot
        popover.rebuild()
        #expect(backend.devices.first { $0.id == "local-mac" }?.volume == 62,
                       "precondition: the Mac's stored fader really is 62")
        #expect(popover.test_deviceRow(for: "local-mac")?.test_sliderValue == 62,
                       "the Mac's own fader was remembered under the overlay, not overwritten by Main")
    }

    @Test func saveActionDisabledWhenSetEqualsGroup() async throws {
        let (popover, controller, backend) = try await makePopover()
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        popover.test_saveCurrentSetup(); await drain(backend)
        popover.rebuild()
        #expect(!(popover.test_saveCurrentSetupEnabled), "disabled: the Selected Devices set already IS a saved group")
    }

    /// T-U8 Part 1 — a deselected device row returns to a fully unselected
    /// appearance (the stale-highlight bug). After toggling a device OFF the row's
    /// model membership AND every visual property that encodes "selected/highlight"
    /// (icon accent tint, transient hover) must reset. The popover row never
    /// paints a selected-background pill at all (2026-07-14 — ahh: removed the
    /// accent wash so multiple selected devices no longer highlight at once;
    /// the mixer window still paints it, covered by its own tests).
    @Test func deselectResetsRowHighlight() async throws {
        let (popover, _, _) = try await makePopover()

        // Toggle an AirPlay device ON — it becomes a selected member (auto-swap
        // drops local; that's fine, we only inspect `office`).
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        let row = try #require(popover.test_deviceRow(for: "office"))
        #expect(row.isSelectedInSet, "selected after ON")
        #expect(!(row.test_isShowingSelectedBackground), "popover row paints no selected-background pill, even when selected")
        #expect(row.test_isEnabledOn, "switch is ON")
        // The icon is neutral in BOTH states now (2026-07-17 redesign): identity
        // only, no accent-when-selected fill. Selection reads from the switch.
        #expect(row.test_iconTint == Tokens.Color.secondaryLabel, "icon is always neutral")

        // Toggle it OFF — the row must return to the unselected appearance.
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: false)
        #expect(!(row.isSelectedInSet), "not selected after OFF")
        #expect(!(row.test_isShowingSelectedBackground), "deselected row paints NO selected background (no stale highlight)")
        #expect(!(row.test_isHovered), "no stale hover wash after deselect")
        #expect(!(row.test_isEnabledOn), "switch returned to OFF")
        #expect(row.test_iconTint == Tokens.Color.secondaryLabel, "icon tint stays neutral (always secondary)")
    }

    /// T-U9a — the last-row sticky-highlight bug. A row hovered by the pointer
    /// must drop its hover wash even when the pointer leaves WITHOUT AppKit
    /// delivering a `mouseExited:` — the bottom-most row's case, where the region
    /// directly below it (card padding, inter-card gap, footer) has no tracking
    /// area to trigger the exit. The fix reconciles hover against the real pointer
    /// position via an app-local mouse-moved monitor; here we drive that reconcile
    /// with the pointer reported OUTSIDE and assert the highlight clears. Written
    /// against EVERY device row so it's general, not a last-row special-case.
    @Test func hoverClearsWhenPointerLeavesWithoutExitEvent() async throws {
        let (popover, _, backend) = try await makePopover()

        // Every device row: enter hover, then a pointer-leave reconcile with NO
        // `mouseExited:` must still clear the hover wash.
        for device in backend.devices {
            guard let row = popover.test_deviceRow(for: device.id) else { continue }
            row.test_simulateMouseEntered()
            #expect(row.test_isHovered, "\(device.id): hover set on enter")
            // Pointer moved away; AppKit delivered no exit (dead zone below row).
            row.test_reconcileHover(pointerInside: false)
            #expect(!(row.test_isHovered), "\(device.id): hover cleared on pointer-leave without an exit event")
        }
    }

    // MARK: Layout overhaul (columns / member toggle / groups "+")

    /// Live-review D1 — the switcher moved to the surface window's native
    /// toolbar, so the panel is pure content that a surface seats below the
    /// toolbar strip via `setContentTopInset`. The inset must ride the
    /// exact-fit measure (it is part of the required content chain), or a
    /// seated panel would publish a size one strip too short and the last
    /// card would clip.
    @Test func surfaceContentInsetRidesTheExactFitMeasure() async throws {
        let (popover, _, _) = try await makePopover()
        let panel = popover.claimPanelForSurfaceHosting()
        #expect(popover.test_panelContentTopInset == 0, "unclaimed resting state carries no inset")
        let restingHeight = panel.fittingSizeSettled().height

        panel.setContentTopInset(52)

        #expect(popover.test_panelContentTopInset == 52)
        #expect(panel.fittingSizeSettled().height == restingHeight + 52,
                "the seated inset grows the exact-fit height by exactly itself")

        panel.setContentTopInset(0)
        #expect(panel.fittingSizeSettled().height == restingHeight, "and it is fully reversible")
    }

    /// A Selected-Devices row for a device shows its on/off toggle.
    @Test func selectedDevicesRowShowsTheToggle() async throws {
        let (popover, _, _) = try await makePopover()
        let ungrouped = try #require(popover.test_deviceRow(for: "airport-mixer"))
        #expect(ungrouped.test_showsToggle, "a Selected-Devices row shows its toggle")
    }

    /// Task B — the Main Out named dropdown shows the CURRENT target's title and
    /// updates when the target changes (the `test_selectedTitle` hook semantics
    /// are preserved).
    @Test func mainOutDropdownShowsCurrentTargetTitle() async throws {
        let (popover, controller, backend) = try await makePopover()
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        popover.test_saveCurrentSetup(); await drain(backend)
        let group = controller.groups[0]

        popover.test_selectMainOut(.selectedDevices); await drain(backend)
        // Warm Signal decision m: the title is CLEAN — no live "(n)" count.
        #expect(popover.test_mainOutRow.test_selectedTitle == "Selected Devices", "the named dropdown shows the current target, count-free")
        popover.test_selectMainOut(.group(id: group.id)); await drain(backend)
        #expect(popover.test_mainOutRow.test_selectedTitle == group.name, "selecting a group updates the named dropdown")
    }

    // MARK: Connection status + diagnosis panel (brief §7.3)

    /// Build a popover on a MockBackend with per-device `ConnectScript`s, so the
    /// connection state machine actually runs (fail/retry/drop choreography).
    private func makeScriptedPopover(
        scripts: [String: ConnectScript]
    ) async throws -> (PopoverController, GroupController, MockBackend) {
        let backend = MockBackend(fleet: .demoFleet, staggerDiscovery: false,
                                  emitsLevels: false, simulatesDropouts: false,
                                  connectScripts: scripts)
        try await waitForFleet(backend, count: 7)
        let controller = GroupController(backend: backend,
                                         store: GroupStore(directory: tempDirectory()),
                                         routingStore: RoutingStore(directory: tempDirectory()),
                                         loadPersisted: false)
        let popover = PopoverController()
        popover.configure(groupController: controller)
        controller.ensureDefaultSelection()
        // A closed popover no longer rebuilds on `update(devices:)` (audit B8);
        // the view tree is this suite's rendering surface, so run every test
        // as if the popover were shown. Closed-state behavior has its own
        // dedicated tests below.
        popover.test_isShownOverride = true
        popover.update(devices: backend.devices)
        return (popover, controller, backend)
    }

    /// Poll the backend until `id`'s connection state satisfies `predicate`
    /// (the scripted choreography runs on the mock's own queue).
    private func waitForConnectionState(
        _ backend: MockBackend, id: String, timeout: TimeInterval = 3,
        _ predicate: (ConnectionState) -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let device = backend.devices.first(where: { $0.id == id }),
               predicate(device.connectionState) { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        Issue.record("timed out waiting for \(id)'s connection state")
    }

    private func isFailed(_ state: ConnectionState) -> Bool {
        if case .failed = state { return true }
        return false
    }

    /// → `.failed` (with the popover closed — the rebuild path): membership is
    /// KEPT (R12, W2-T3 — no auto-unselect), the row shows the warning, and the
    /// diagnosis panel auto-expands with the failure's copy.
    @Test func failedTransitionKeepsMembershipAndShowsPanel() async throws {
        let failure = ConnectionFailure(cause: .notResponding, detail: "raw engine log line")
        let (popover, controller, backend) = try await makeScriptedPopover(scripts: [
            "office": ConnectScript(attempts: [.fail(after: 0.05, failure)]),
        ])

        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        #expect(controller.isSpeakerSelected("office"), "membership composed on toggle")
        try await waitForConnectionState(backend, id: "office", isFailed)
        popover.update(devices: backend.devices)

        #expect(controller.isSpeakerSelected("office"),
                "R12: a failed reconnect must NOT erase Selected-Devices intent")
        let row = try #require(popover.test_deviceRow(for: "office"))
        #expect(row.test_statusKind == .failed, "on-icon dot shows the failed (amber) state")
        let panel = try #require(popover.test_diagnosisPanel(for: "office"),
                                 "the diagnosis panel auto-expanded")
        #expect(panel.test_headlineText == failure.headline)
        #expect(panel.test_suggestionText == failure.suggestion)
        #expect(panel.test_copyDetailsEnabled, "detail present ⇒ Copy details enabled")
    }

    /// Sticky-failed (§1): membership survives the `.failed` transition (R12),
    /// and so does the warning across a subsequent repaint.
    @Test func stickyWarningSurvivesRepaintWithMembershipIntact() async throws {
        let (popover, controller, backend) = try await makeScriptedPopover(scripts: [
            "office": ConnectScript(attempts: [.fail(after: 0.05, ConnectionFailure(cause: .timedOut))]),
        ])

        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        try await waitForConnectionState(backend, id: "office", isFailed)
        popover.update(devices: backend.devices)
        #expect(controller.isSpeakerSelected("office"), "R12: intent kept through .failed")

        // Re-render again; nothing should re-touch membership or drop the warning.
        await drain(backend)
        popover.update(devices: backend.devices)
        #expect(controller.isSpeakerSelected("office"))
        let device = try #require(backend.devices.first { $0.id == "office" })
        #expect(isFailed(device.connectionState),
                "backend kept .failed sticky across the repaint")
        let row = try #require(popover.test_deviceRow(for: "office"))
        #expect(row.test_statusKind == .failed, "failed dot survived the repaint")
        #expect(popover.test_diagnosisPanel(for: "office") != nil, "panel survived too")
    }

    /// The panel auto-expands once on `.failed`, and an in-episode update (the
    /// diagnosis replacing the backend's first guess) refreshes the still-open
    /// panel's copy rather than tearing it down. The manual warning-button toggle
    /// was retired 2026-07-17 (status moved onto the icon) — the panel is now
    /// purely auto-driven off the connection-state transitions.
    @Test func panelAutoExpandsAndRefreshesCopyInEpisode() async throws {
        let (popover, _, backend) = try await makeScriptedPopover(scripts: [
            "office": ConnectScript(attempts: [.fail(after: 0.05, ConnectionFailure(cause: .unknown))]),
        ])

        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        try await waitForConnectionState(backend, id: "office", isFailed)
        popover.update(devices: backend.devices)
        let firstPanel = try #require(popover.test_diagnosisPanel(for: "office"),
                                       "auto-expanded once")
        #expect(firstPanel.test_headlineText == ConnectionFailure(cause: .unknown).headline)

        // In-episode update: the diagnosis replaced the guess (still .failed,
        // different cause). The open panel refreshes its copy in place.
        var replaced = backend.devices
        for i in replaced.indices where replaced[i].id == "office" {
            replaced[i].connectionState = .failed(ConnectionFailure(cause: .vanished))
        }
        popover.update(devices: replaced)
        let panel = try #require(popover.test_diagnosisPanel(for: "office"),
                                  "panel stays open through the diagnosis replacement")
        #expect(panel.test_headlineText == ConnectionFailure(cause: .vanished).headline, "the panel re-rendered the replaced failure's copy")
    }

    /// "Try again" re-asserts membership (a no-op under R12 since `.failed`
    /// never dropped it): the id re-enters `setOutputSet` → `.connecting`, and
    /// on `.connected` the panel clears and the row rests ON with the green dot.
    @Test func retryReconnectsClearsPanelAndRestoresMembership() async throws {
        let (popover, controller, backend) = try await makeScriptedPopover(scripts: [
            "office": ConnectScript(attempts: [
                .fail(after: 0.05, ConnectionFailure(cause: .notResponding)),
                .connect(after: 0.05),
            ]),
        ])

        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        try await waitForConnectionState(backend, id: "office", isFailed)
        popover.update(devices: backend.devices)
        #expect(popover.test_diagnosisPanel(for: "office") != nil)

        popover.test_tapRetry(for: "office")
        #expect(controller.isSpeakerSelected("office"), "retry re-added membership")
        try await waitForConnectionState(backend, id: "office") { $0 == .connected }
        popover.update(devices: backend.devices)

        #expect(popover.test_diagnosisPanel(for: "office") == nil, "connected cleared the panel")
        let row = try #require(popover.test_deviceRow(for: "office"))
        #expect(row.test_statusKind == .connected)
        // The retried device is a selected member with no routed apps, so its
        // FEED column is the bare "System" token (selected ⇒ in the set; v4.1
        // item 3 moved this off the sublabel).
        #expect(row.test_feedText == "System", "selected device shows the System FEED token")
        #expect(row.test_isEnabledOn, "the honest toggle now rests ON")
    }

    /// A device that disappears entirely while `.failed` (`deviceRemoved`, §1
    /// `.failed → .off`) takes its panel and tracking down with it.
    @Test func deviceRemovedWhileFailedTearsDownPanel() async throws {
        let (popover, _, backend) = try await makeScriptedPopover(scripts: [
            "office": ConnectScript(attempts: [.fail(after: 0.05, ConnectionFailure(cause: .vanished))]),
        ])

        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        try await waitForConnectionState(backend, id: "office", isFailed)
        popover.update(devices: backend.devices)
        #expect(popover.test_diagnosisPanel(for: "office") != nil)

        // The app layer prunes a removed device from the snapshot it pushes.
        popover.update(devices: backend.devices.filter { $0.id != "office" })
        #expect(popover.test_diagnosisPanel(for: "office") == nil, "panel torn down on removal")
        #expect(popover.test_deviceRow(for: "office") == nil, "row gone with the device")
    }

    /// C1 regression: the auto-expanded panel must actually be attached in the
    /// live view tree, directly under its failed device's row — not merely
    /// recorded in `diagnosisPanelsByID`. `test_diagnosisPanel(for:)` alone can't
    /// catch this: the dictionary is populated in `mountDiagnosisPanel` BEFORE
    /// `panel.insertRow(_:after:animated:)` runs, so it stayed non-nil even while
    /// `insertRow` silently no-op'd (it searched `CardView.contentStack` for the
    /// sibling device row, but device rows live one level deeper in `bodyStack` —
    /// the lookup could never match, so the panel was never actually mounted).
    /// This test walks the real `NSStackView` hierarchy instead.
    @Test func diagnosisPanelViewIsActuallyMountedInViewTree() async throws {
        let failure = ConnectionFailure(cause: .notResponding, detail: "raw engine log line")
        let (popover, _, backend) = try await makeScriptedPopover(scripts: [
            "office": ConnectScript(attempts: [
                .fail(after: 0.05, failure),
                .connect(after: 0.05),
            ]),
        ])

        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        try await waitForConnectionState(backend, id: "office", isFailed)
        popover.update(devices: backend.devices)

        let row = try #require(popover.test_deviceRow(for: "office"))
        let panel = try #require(popover.test_diagnosisPanel(for: "office"))

        let stack = try #require(row.superview as? NSStackView,
                                  "the device row itself must be mounted in a stack")
        // An inserted row is mounted inside its own reveal clip (`RowClipView`),
        // the view whose height the downward reveal animates; the clip is what
        // lands in the stack.
        let clip = try #require(panel.superview as? RowClipView,
                                 "the diagnosis panel's VIEW must actually be attached, inside its reveal clip, not just recorded in diagnosisPanelsByID")
        #expect(clip.superview === stack, "the panel's clip mounts in the SAME stack as its device row")
        let rowIndex = try #require(stack.arrangedSubviews.firstIndex(of: row))
        let panelIndex = try #require(stack.arrangedSubviews.firstIndex(of: clip))
        #expect(panelIndex == rowIndex + 1, "the panel sits directly UNDER its failed device row")

        // Reconnecting must detach the VIEW from the tree too, not just clear the
        // dictionary entry. `removeRow` runs its detach inside an
        // `NSAnimationContext` completion handler (unless Reduce Motion is on),
        // so give the ~0.22s slide-out animation a chance to actually finish
        // before asserting the terminal, detached state.
        popover.test_tapRetry(for: "office")
        try await waitForConnectionState(backend, id: "office") { $0 == .connected }
        popover.update(devices: backend.devices)
        #expect(popover.test_diagnosisPanel(for: "office") == nil)
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(panel.superview == nil, "the panel view is detached from the tree on removal, not just forgotten")
    }

    /// A retry while a SECOND device is still connecting: the retry must not
    /// disturb the in-flight device, and both resolve independently.
    ///
    /// The `.connecting` checks below read `backend.devices`/the row
    /// synchronously right after a `tapRetry`/`update()` call — there's no
    /// event to wait on for "hasn't transitioned yet", so the only lever is
    /// giving the intervening test/AppKit work (NOT wall-clock bounded — an
    /// `update()` rebuilds the whole popover, Applications card included) a
    /// wide margin before each device's scripted timer fires. A prior 0.5s/1.0s
    /// margin (comfortable for a lone `swift test` run) flaked intermittently
    /// under `swift test --parallel`'s CPU contention (every other suite is a
    /// concurrent sibling process) — 2026-07-24: both "connected" observed
    /// where "connecting" was asserted, on different runs, never in isolation.
    /// Widening these delays doesn't weaken what's being tested (still-in-
    /// flight vs. disturbed), only the wall-clock tolerance of the checkpoint.
    @Test func retryWhileSecondDeviceConnecting() async throws {
        let (popover, controller, backend) = try await makeScriptedPopover(scripts: [
            "office": ConnectScript(attempts: [
                .fail(after: 0.05, ConnectionFailure(cause: .refusedOrBusy)),
                // Retry connects after a wide margin so the transient
                // `.connecting` state stays observable after `update()` even
                // under `--parallel` contention (see the doc comment above).
                .connect(after: 3.0),
            ]),
            "homepod-bed": ConnectScript(attempts: [.connect(after: 6.0)]),
        ])

        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        _ = popover.test_toggleDeviceEnabled(deviceID: "homepod-bed", on: true)
        try await waitForConnectionState(backend, id: "office", isFailed)
        popover.update(devices: backend.devices)

        // office failed while homepod-bed is still connecting.
        let homepodRow = try #require(popover.test_deviceRow(for: "homepod-bed"))
        #expect(homepodRow.test_statusKind == .connecting, "second device still connecting")
        #expect(controller.isSpeakerSelected("homepod-bed"),
                "the failure never touches OTHER devices' membership")
        #expect(controller.isSpeakerSelected("office"),
                "R12: office's own membership is kept too, despite the failure")

        popover.test_tapRetry(for: "office")
        popover.update(devices: backend.devices)
        let officeDevice = try #require(backend.devices.first { $0.id == "office" })
        #expect(officeDevice.connectionState == .connecting, "retry restarted office")
        let homepodDevice = try #require(backend.devices.first { $0.id == "homepod-bed" })
        #expect(homepodDevice.connectionState == .connecting, "the in-flight device was not disturbed by the retry's setOutputSet")

        // Timeouts widened to stay above the new 3.0s/6.0s scripted delays
        // (plus contention headroom) — these calls poll every 20ms until the
        // predicate holds, so a bigger ceiling is free in the fast path.
        try await waitForConnectionState(backend, id: "office", timeout: 8) { $0 == .connected }
        try await waitForConnectionState(backend, id: "homepod-bed", timeout: 12) { $0 == .connected }
        popover.update(devices: backend.devices)
        #expect(popover.test_deviceRow(for: "office")?.test_statusKind == .connected)
        #expect(popover.test_deviceRow(for: "homepod-bed")?.test_statusKind == .connected)
        #expect(popover.test_diagnosisPanel(for: "office") == nil)
    }

    // MARK: Main Out halo ring — aggregate over the active target (spec §3.2 note)

    /// The Main Out ring reflects the AGGREGATE of the active Selected-Devices
    /// target: any live member ⇒ connected ring; else any connecting member ⇒
    /// pending ring; else no ring.
    @Test func mainOutRingAggregatesActiveTargetConnection() async throws {
        let (popover, _, backend) = try await makePopover()
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        _ = popover.test_toggleDeviceEnabled(deviceID: "homepod-bed", on: true)

        // Both members still connecting → the Main Out ring is the pending ring.
        var devices = backend.devices
        for id in ["office", "homepod-bed"] {
            if let i = devices.firstIndex(where: { $0.id == id }) {
                devices[i].connectionState = .connecting
            }
        }
        popover.update(devices: devices)
        #expect(popover.test_mainOutRow.test_ringForm == .connecting, "all members connecting ⇒ the Main Out pending ring")

        // One member connects → the aggregate promotes to the connected ring.
        if let i = devices.firstIndex(where: { $0.id == "office" }) {
            devices[i].connectionState = .connected
        }
        popover.update(devices: devices)
        #expect(popover.test_mainOutRow.test_ringForm == .connected, "≥1 live member ⇒ the Main Out connected ring, even while another is still connecting")
    }

    /// No selected member is connecting/connected ⇒ the Main Out shows no ring.
    @Test func mainOutRingIsNoneWhenTargetIdle() async throws {
        let (popover, _, backend) = try await makePopover()
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        var devices = backend.devices
        if let i = devices.firstIndex(where: { $0.id == "office" }) {
            devices[i].connectionState = .off
        }
        popover.update(devices: devices)
        #expect(popover.test_mainOutRow.test_ringForm == .none, "an idle target leaves the Main Out ring off")
    }

    // MARK: Main Out halo ring — resting form (ring-resting-state task)

    /// The default {local device} passthrough target — audio genuinely playing
    /// through the Mac, unmuted, with no remote AirPlay handshake for
    /// `mainOutConnectionState` to report — shows the RESTING ring (not `.none`,
    /// not `.connected`), so the rail's curve into the ring always lands on
    /// something. `mainOutConnectionState` itself still correctly resolves `.off`
    /// for this target (untouched by this task).
    @Test func mainOutRingIsRestingForLocalOnlyPassthrough() async throws {
        let (popover, controller, _) = try await makePopover()
        #expect(controller.isPassthrough, "default set == {local} ⇒ passthrough")
        #expect(popover.test_mainOutRow.test_ringForm == .resting, "local-only armed playback shows the quiet resting ring")
    }

    /// Muting the local-only target drops `restingArmed` (the predicate requires
    /// unmuted) — the ring falls back to no ring, exactly like any other idle
    /// target.
    @Test func mainOutRingIsNoneWhenLocalOnlyTargetMuted() async throws {
        let (popover, controller, backend) = try await makePopover()
        controller.setMainOutMuted(true)
        popover.update(devices: backend.devices)
        #expect(popover.test_mainOutRow.test_ringForm == .none, "a muted local-only target is not 'armed' — no resting ring")
    }

    /// An idle NON-local target (a selected AirPlay device that hasn't connected
    /// yet) must still show `.none`, never `.resting` — the resting form is
    /// reserved for a target whose members are ALL the local device.
    @Test func mainOutRingStaysNoneForIdleNonLocalTarget() async throws {
        let (popover, _, backend) = try await makePopover()
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        var devices = backend.devices
        if let i = devices.firstIndex(where: { $0.id == "office" }) {
            devices[i].connectionState = .off
        }
        popover.update(devices: devices)
        #expect(popover.test_mainOutRow.test_ringForm == .none, "an idle non-local target shows no ring, not the local-only resting form")
    }

    // MARK: Membership bus — popover-level wiring (spec §4, S-BUS)

    /// The bus originates at the Main Audio row (the `.origin` hook). Its CHANNEL
    /// runs the whole device band — every device row is a stop, member or not —
    /// while the SIGNAL inside it ends at the LOWEST MEMBER (v4 §Call-1), so the
    /// gold's length still reads as "how far down the mix reaches". Under the
    /// default {current device} selection the local row (rendered first) is that
    /// last member, and the AirPlay rows below it are sockets on empty channel.
    @Test func busRunsFromMainAudioAndTheSignalEndsAtTheLowestMember() async throws {
        let (popover, _, backend) = try await makePopover()
        popover.test_applyExactFitSize()
        #expect(popover.test_mainOutRow.test_busOriginNode == .origin, "the Main Audio row launches the bus (the origin hook)")
        #expect(!(popover.test_mainOutRow.test_busOriginDimmed), "the origin renders at full ink under a Selected Devices target")
        // Every device row carries a node…
        let nodes = backend.devices.compactMap { popover.test_deviceRow(for: $0.id)?.test_busNode }
        #expect(nodes.count == backend.devices.count, "every device row carries a bus node")
        // …and every one of them is a stop on the channel.
        let plan = try #require(popover.test_railPlan())
        #expect(plan.stops.count == nodes.count, "the channel spans the full device band")
        // The signal ends on the local row: the last member, with none below it.
        let terminus = try #require(plan.signalTerminusIndex)
        #expect(plan.stops[terminus].node == .member)
        #expect(!plan.stops.dropFirst(terminus + 1).contains { $0.node == .member },
                "nothing below the signal's end is in the mix")
        #expect(popover.test_deviceRow(for: "local-mac")?.test_busNode == .member,
                "the local row is that last member under the default selection")
        #expect(popover.test_deviceRow(for: "office")?.test_busNode == .nonMember,
                "an AirPlay row below it keeps its socket on the empty channel")
        #expect(!plan.dormant, "a Selected Devices target is never dormant")
    }

    /// Node rendering across a real popover: members filled, non-members hollow
    /// — and the node column x is identical on every row (one fixed column,
    /// §4.1/R7). The Mac is a plain non-member here (auto-dropped by the
    /// sole-member auto-swap when "office" was added, then never re-selected) —
    /// NOT the distinct "blocked" node §4.6 originally described: T-GROUPCTL/Q5
    /// (synced local sink) lifted the local-mix block, so the Mac can freely
    /// rejoin a mixed set at will (see `testAddingLocalIntoAMixedSetIsAllowed`);
    /// it just isn't re-added in THIS test.
    @Test func busNodesReflectMembershipAndShareOneColumn() async throws {
        let (popover, _, backend) = try await makePopover()
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        _ = popover.test_toggleDeviceEnabled(deviceID: "homepod-bed", on: true)
        await drain(backend)
        #expect(popover.test_deviceRow(for: "office")?.test_busNode == .member)
        #expect(popover.test_deviceRow(for: "homepod-bed")?.test_busNode == .member)
        #expect(popover.test_deviceRow(for: "airport-mixer")?.test_busNode == .nonMember, "an untapped device's node is hollow — the line detours it")
        #expect(popover.test_deviceRow(for: "local-mac")?.test_busNode == .nonMember, "the Mac auto-dropped via the sole-member auto-swap — a plain non-member, not blocked (the local-mix block is retired)")

        // One fixed column: every node's center x is identical across rows AND
        // unchanged when a membership toggles (zero layout shift, R7).
        let officeX = popover.test_deviceRow(for: "office")?.test_busNodeCenterX()
        let mixerX = popover.test_deviceRow(for: "airport-mixer")?.test_busNodeCenterX()
        #expect(officeX != nil)
        #expect(abs((officeX ?? -1) - (mixerX ?? -2)) < 0.001,
                "member and non-member nodes share one column x")
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: false)
        await drain(backend)
        #expect(popover.test_deviceRow(for: "office")?.test_busNode == .nonMember)
        #expect(abs((popover.test_deviceRow(for: "office")?.test_busNodeCenterX() ?? -1)
                    - (officeX ?? -2)) < 0.001,
                "toggling out moved nothing — only fill and line path change")
    }

    /// A FAILED group member renders at FULL emphasis (failure outranks
    /// configuration — R2, §4.7): its node never tints, its diagnosis panel
    /// attaches normally, and neither the failure nor a retry interaction ever
    /// silently edits the saved group.
    ///
    /// This test used to assert that the `.failed` edge AUTO-DESELECTED the
    /// member, diverging the card into an "Inactive — Main Audio is using …"
    /// note. `ea83e48` (W2-T3, closes R12) deliberately ended that: failure now
    /// KEEPS the user's intent, so no divergence and no note. The assertions
    /// below were flipped to lock in the new semantics rather than deleted —
    /// "a failure must not rewrite what the user chose" is exactly the property
    /// worth regression-locking.
    @Test func failedGroupMemberKeepsFullEmphasisAndNeverEditsTheSavedGroup() async throws {
        let (popover, controller, backend) = try await makePopover()
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        popover.test_saveCurrentSetup(); await drain(backend)
        let group = controller.groups[0]
        popover.test_selectMainOut(.group(id: group.id)); await drain(backend)

        var devices = backend.devices
        let idx = try #require(devices.firstIndex { $0.id == "office" })
        devices[idx].connectionState = .failed(.init(cause: .timedOut))
        popover.update(devices: devices)

        #expect(popover.test_cardNoteTexts(title: "Output Devices") == [], "R12: a failure keeps intent, so the checked set never diverged and there is no dormancy note to show")
        #expect(popover.test_deviceRow(for: "office")?.test_busNodeDimmed == false, "the FAILED member never tints — failure outranks configuration (R2)")
        #expect(popover.test_deviceRow(for: "office")?.test_feedText == "Took too long", "the failure FEED override renders the failure's own headline at full emphasis")
        #expect(popover.test_diagnosisPanel(for: "office") != nil, "the diagnosis panel attaches normally")
        #expect(controller.selectedDeviceIDs.contains("office"), "R12: the failed device stays SELECTED — the failure must not rewrite what the user chose")

        // Interacting with the failed member (toggle-on = the retry path)
        // composes the CHECKED set only — the saved group is never edited.
        popover.test_deviceRow(for: "office")?.test_toggleEnabled(true)
        await drain(backend)
        #expect(controller.groups.first?.memberIDs == group.memberIDs, "the retry edited the Selected set, never the saved group")
        #expect(popover.test_cardNoteTexts(title: "Output Devices") == [], "…and the card is still undiverged afterwards")
    }

    // MARK: S4 (spec §4.6) — blocked row's in-place refusal note [RETIRED]
    //
    // `testBlockedRowBodyClickTogglesRefusalNote` and
    // `testBlockedRowNameClickSurfacesRefusalNote` lived here, covering the
    // local-mix-blocked row's in-place refusal note (a click surfaces
    // `GroupController.localMixRefusalReason` under the row). T-GROUPCTL/Q5
    // (synced local sink, pulled in by the ring-resting-state x main merge,
    // 2026-07-24) lifted the local-mix block entirely — the Mac can freely join
    // a mixed set now, so this row state is never reached and both tests failed
    // asserting a `.blocked` node the real popover no longer produces. Dropped
    // rather than kept red; the superseding "Mac joins freely" behavior is
    // covered by `testAddingLocalIntoAMixedSetIsAllowed` and
    // `testClickingTheLocalRowCheckboxThroughRealDispatchJoinsAMixedSet` above.

    /// T-3 — exact-fit sizing: the popover is exactly its visible content height,
    /// with no `NSScrollView` and no clipping. The resize primitive publishes the
    /// panel's settled `fittingSize` through `preferredContentSize` (the documented
    /// `NSPopover` size channel), so after a rebuild the two must be equal and the
    /// height must cover the full stack (header + both cards). No scroller can
    /// appear because the panel contains no scroll view at all.
    @Test func exactFitSizeMatchesContentNoScroll() async throws {
        let (popover, _, _) = try await makePopover()

        // No NSScrollView anywhere in the panel view tree ⇒ no scroller chrome ever.
        func containsScrollView(_ v: NSView) -> Bool {
            if v is NSScrollView { return true }
            return v.subviews.contains(where: containsScrollView)
        }
        #expect(!(containsScrollView(popover.test_panelView)), "the popover panel contains no NSScrollView (exact-fit, no scrollbar ever)")

        // Publish the exact-fit size, then the tracked content size must equal the
        // panel's settled fitting size — no clipping, nothing cut off.
        popover.test_applyExactFitSize()
        let fitting = popover.test_panelFittingSize
        #expect(popover.test_preferredContentSize == fitting, "preferredContentSize equals the panel's settled fittingSize")

        // Sanity: the fitting height must actually cover the assembled content —
        // the whole panel view is at least as tall as its arranged content (the
        // empty-popover collapse trap would show up as a near-zero height here).
        #expect(fitting.height > 100, "the panel sizes to real content (cards did not collapse to zero)")
        #expect(popover.test_panelView.fittingSize.height == fitting.height, "the panel's own fittingSize matches the published exact-fit height")
    }

    // MARK: Collapsible cards (T-4, PLAN decision 5 + §E risk 1)

    /// A collapsed card reports a header-only height: its body clip collapses to
    /// height 0, while an expanded card's body clip equals the body's fitting
    /// height. Toggling flips between the two.
    @Test func collapseReportsHeaderOnlyBodyHeight() async throws {
        let (popover, _, _) = try await makePopover()

        // Both cards are collapsible and open EXPANDED (T-4 wires the affordance;
        // the collapse-default policy is a later task).
        let title = "Output Devices"
        #expect(popover.test_isCardCollapsed(title: title) == false, "opens expanded")
        let fitting = try #require(popover.test_cardBodyFittingHeight(title: title))
        #expect(fitting > 0, "an expanded card has a non-zero body")
        #expect(abs(try #require(popover.test_cardBodyClipHeight(title: title)) - fitting) < 0.5,
                "expanded: the body clip is the body's full fitting height")

        // Collapse → the body clip reports height 0 (header only).
        #expect(popover.test_toggleCard(title: title) == true, "toggle collapses")
        #expect(popover.test_isCardCollapsed(title: title) == true)
        #expect(abs(try #require(popover.test_cardBodyClipHeight(title: title)) - 0) <= 0.5, "collapsed: the body clip is 0 (header-only height)")

        // Expand again → back to the full body height.
        #expect(popover.test_toggleCard(title: title) == false, "toggle expands")
        #expect(abs(try #require(popover.test_cardBodyClipHeight(title: title)) - fitting) <= 0.5, "re-expanded: the body clip returns to the full fitting height")
    }

    /// Toggling a card flips its disclosure chevron symbol (`chevron.down`
    /// expanded ⇄ `chevron.right` collapsed — GroupRowView precedent).
    @Test func toggleFlipsChevronSymbol() async throws {
        let (popover, _, _) = try await makePopover()
        let title = "System Audio"
        #expect(popover.test_cardChevronSymbolName(title: title) == "chevron.down", "expanded card shows the down chevron")
        popover.test_toggleCard(title: title)
        #expect(popover.test_cardChevronSymbolName(title: title) == "chevron.right", "collapsed card shows the right chevron")
        popover.test_toggleCard(title: title)
        #expect(popover.test_cardChevronSymbolName(title: title) == "chevron.down", "re-expanded card shows the down chevron again")
    }

    /// The exact-fit popover height shrinks by exactly the collapsed card's body
    /// height and grows back on expand — the panel and popover track (PLAN §E
    /// risk 1). Uses the non-animated path (== the Reduce Motion path), which
    /// applies the end state synchronously so `fittingSize` is exact immediately.
    @Test func panelHeightShrinksAndGrowsByBodyHeight() async throws {
        let (popover, _, _) = try await makePopover()
        let title = "Output Devices"

        popover.test_applyExactFitSize()
        let expandedHeight = popover.test_panelFittingSize.height
        let body = try #require(popover.test_cardBodyFittingHeight(title: title))

        // Collapse (non-animated == Reduce Motion): the panel shrinks by the body.
        popover.test_toggleCard(title: title)
        popover.test_applyExactFitSize()
        let collapsedHeight = popover.test_panelFittingSize.height
        #expect(abs(expandedHeight - collapsedHeight - body) <= 1.0, "collapsing shrinks the panel by exactly the card body height")
        #expect(abs(popover.test_preferredContentSize.height - collapsedHeight) <= 0.5, "preferredContentSize tracks the collapsed fitting height (no scrollbar)")

        // Expand back → the panel returns to its full height.
        popover.test_toggleCard(title: title)
        popover.test_applyExactFitSize()
        #expect(abs(popover.test_panelFittingSize.height - expandedHeight) <= 1.0, "expanding restores the full panel height")
    }

    /// The non-animated collapse path (Reduce Motion + initial build) applies its
    /// end state SYNCHRONOUSLY — after a `test_toggleCard` returns, the collapse
    /// state and the body clip height are already final (no pending animation).
    @Test func reduceMotionPathAppliesEndStateSynchronously() async throws {
        let (popover, _, _) = try await makePopover()
        let title = "Output Devices"
        // `animated: false` is the exact code path Reduce Motion takes.
        popover.test_toggleCard(title: title, animated: false)
        #expect(popover.test_isCardCollapsed(title: title) == true, "collapsed immediately")
        #expect(abs(try #require(popover.test_cardBodyClipHeight(title: title)) - 0) <= 0.5, "body clip already at its end state (0) — no pending animation")
    }

    /// Rapid toggles retarget cleanly and end in a consistent state (the animator
    /// proxies must not queue or fight). Fire several toggles in a row; the final
    /// state matches the parity of the toggle count.
    @Test func rapidTogglesEndConsistent() async throws {
        let (popover, _, _) = try await makePopover()
        let title = "Output Devices"
        // 5 toggles from expanded ⇒ collapsed (odd count).
        for _ in 0..<5 { popover.test_toggleCard(title: title, animated: true) }
        #expect(popover.test_isCardCollapsed(title: title) == true, "odd number of rapid toggles ends collapsed")
        // One more ⇒ expanded.
        popover.test_toggleCard(title: title, animated: true)
        #expect(popover.test_isCardCollapsed(title: title) == false, "the extra toggle ends expanded")
    }

    // MARK: Collapse-reactive rail (2026-07-22)

    /// Behavior 1 + 2 (far end): collapsing the DEVICE card ("Output Devices")
    /// cuts the rail with a terminus dot and stops drawing its now-hidden device
    /// nodes, while the origin stays on the Main Audio ring (only the far end
    /// resolved to the collapsed header).
    @Test func collapsingDeviceCardCutsRailAtHeaderDot() async throws {
        let (popover, _, _) = try await makePopover()
        popover.test_applyExactFitSize()

        let expanded = try #require(popover.test_railPlan())
        #expect(!(expanded.stops.isEmpty), "expanded: the rail draws its device nodes")
        #expect(expanded.terminusDotY == nil, "expanded: no collapsed-terminus dot")
        guard case .ring = expanded.origin else {
            Issue.record("expanded origin should curve into the Main Audio ring")
            return
        }

        popover.test_toggleCard(title: "Output Devices", animated: false)
        popover.test_applyExactFitSize()

        let collapsed = try #require(popover.test_railPlan())
        #expect(collapsed.stops.isEmpty, "collapsed device card: none of its hidden nodes are drawn")
        #expect(collapsed.terminusDotY != nil, "collapsed device card: the rail terminates with a dot at its header")
        guard case .ring = collapsed.origin else {
            Issue.record("collapsing the DEVICE card must not move the origin off the ring")
            return
        }
    }

    /// Behavior 2 (origin end): collapsing the ORIGIN card ("System Audio") hides
    /// the Main Audio ring, so the rail's origin moves UP to that card's header
    /// dot — a different resolution than collapsing the device card.
    @Test func collapsingOriginCardMovesOriginToHeaderDot() async throws {
        let (popover, _, _) = try await makePopover()
        popover.test_applyExactFitSize()

        guard case .ring = try #require(popover.test_railPlan()).origin else {
            Issue.record("expanded origin should be the ring")
            return
        }

        popover.test_toggleCard(title: "System Audio", animated: false)
        popover.test_applyExactFitSize()

        let collapsed = try #require(popover.test_railPlan())
        guard case .headerDot = collapsed.origin else {
            Issue.record("collapsing the origin card moves the origin to its header dot")
            return
        }
    }

    /// Behavior 4: re-expanding a collapsed section restores the EXACT rail
    /// geometry it had before — the overlay carries no transient state across a
    /// collapse→expand cycle. Uses a specific device selection so the restored
    /// plan is a non-trivial shape (real member nodes), not an empty default.
    @Test func reExpandRestoresExactRailGeometry() async throws {
        let (popover, _, _) = try await makePopover()
        // A specific selection so the rail has real member nodes to restore.
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        popover.test_applyExactFitSize()

        let before = try #require(popover.test_railPlan())
        #expect(!(before.stops.isEmpty), "the pre-collapse rail has device nodes")

        // Collapse then expand the device card (non-animated == the settled path).
        popover.test_toggleCard(title: "Output Devices", animated: false)
        popover.test_applyExactFitSize()
        popover.test_toggleCard(title: "Output Devices", animated: false)
        popover.test_applyExactFitSize()

        let after = try #require(popover.test_railPlan())
        #expect(after == before, "re-expanding restores the identical rail (same origin, stops, terminus)")
    }

    /// Behavior 3 + Reduce Motion: the non-animated (Reduce Motion) collapse path
    /// resolves the collapsed rail SYNCHRONOUSLY — after `animated: false`, the
    /// plan is already the fully-collapsed shape, no pending animation to settle.
    @Test func reduceMotionCollapseResolvesRailInstantly() async throws {
        let (popover, _, _) = try await makePopover()
        popover.test_toggleCard(title: "Output Devices", animated: false)
        popover.test_applyExactFitSize()

        let plan = try #require(popover.test_railPlan())
        #expect(plan.stops.isEmpty, "Reduce Motion path lands the collapsed rail at once")
        #expect(plan.terminusDotY != nil, "…terminus dot already resolved, no animation tail")
    }

    @Test func muteDrivesVolumeToZeroAndRestores() async throws {
        let (popover, controller, backend) = try await makePopover()
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        popover.test_saveCurrentSetup(); await drain(backend)
        let target = controller.groups[0].memberIDs.first { id in
            backend.devices.first { $0.id == id }?.isLocalDevice == false
        }!
        let prior = try #require(backend.devices.first { $0.id == target }?.volume)
        #expect(prior > 0)
        popover.test_toggleMute(deviceID: target, muted: true); await drain(backend)
        #expect(backend.devices.first { $0.id == target }?.volume == 0)
        popover.test_toggleMute(deviceID: target, muted: false); await drain(backend)
        #expect(backend.devices.first { $0.id == target }?.volume == prior)
    }

    // MARK: T-5 — collapse-default policy (PLAN §B)

    /// Opening the popover applies fresh defaults: System + Selected Devices
    /// both start expanded.
    @Test func collapseDefaultsAppliedOnOpen() async throws {
        let (popover, _, _) = try await makePopover()
        popover.test_simulateOpen()
        #expect(popover.test_isCardCollapsed(title: "System Audio") == false)
        #expect(popover.test_isCardCollapsed(title: "Output Devices") == false)
    }

    /// A manual toggle during one open is discarded on the NEXT open — defaults
    /// are recomputed rather than remembered (PLAN §B: "manual toggles never
    /// persist").
    @Test func manualToggleDiscardedOnReopen() async throws {
        let (popover, _, _) = try await makePopover()
        popover.test_simulateOpen()
        popover.test_toggleCard(title: "Output Devices", animated: false)
        #expect(popover.test_isCardCollapsed(title: "Output Devices") == true, "manual toggle collapsed it this open")

        // Simulate close + reopen: defaults are recomputed, discarding the toggle.
        popover.test_simulateOpen()
        #expect(popover.test_isCardCollapsed(title: "Output Devices") == false, "reopening resets to the default — the manual toggle didn't persist")
    }

    /// A rebuild WITHIN one open (e.g. a backend device update) must preserve
    /// the current transient collapse state, not reset it back to the default.
    @Test func midOpenRebuildPreservesTransientState() async throws {
        let (popover, _, backend) = try await makePopover()
        popover.test_simulateOpen()
        popover.test_toggleCard(title: "Output Devices", animated: false)
        #expect(popover.test_isCardCollapsed(title: "Output Devices") == true)

        // A mid-open rebuild triggered by a backend event (not a reopen).
        popover.update(devices: backend.devices)
        popover.rebuild()
        #expect(popover.test_isCardCollapsed(title: "Output Devices") == true, "a mid-open rebuild preserves the transient toggle instead of resetting it")
    }

    // MARK: Device set changes drive a full row rebuild (not just a repaint)

    /// `update(devices:)` must detect a device ADDED to the fleet and grow the
    /// device-row set to match — not just repaint the rows that already exist.
    /// Regression coverage for the fix at `PopoverController.update(devices:)`
    /// (~line 208): a device-ID-set diff now forces `rebuild()` instead of the
    /// narrower `refreshDeviceRows()`, which only repaints EXISTING rows and
    /// would otherwise leave a newly-discovered device with no row at all.
    @Test func updateWithAddedDeviceGetsARow() async throws {
        let (popover, _, backend) = try await makePopover()
        let baselineCount = popover.test_deviceSectionRowCount
        #expect(popover.test_deviceRow(for: "new-speaker") == nil, "not present before the add")

        var devices = backend.devices
        devices.append(Device(id: "new-speaker", name: "New Speaker", kind: .generic))
        popover.update(devices: devices)

        #expect(popover.test_deviceSectionRowCount == baselineCount + 1, "the added device grew the row count")
        #expect(popover.test_deviceRow(for: "new-speaker") != nil, "the newly added device has a row after update(devices:)")
    }

    /// The inverse: a device REMOVED from the fleet must drop its row, not leave
    /// a stale one behind.
    @Test func updateWithRemovedDeviceDropsItsRow() async throws {
        let (popover, _, backend) = try await makePopover()
        let baselineCount = popover.test_deviceSectionRowCount
        #expect(popover.test_deviceRow(for: "office") != nil, "present before the removal")

        let devices = backend.devices.filter { $0.id != "office" }
        popover.update(devices: devices)

        #expect(popover.test_deviceSectionRowCount == baselineCount - 1, "the removed device shrank the row count")
        #expect(popover.test_deviceRow(for: "office") == nil, "the removed device's row is gone after update(devices:)")
    }

    /// A device set change must be detected and rebuilt even while the popover is
    /// mid-open (`test_simulateOpen`), which is when the original bug manifested:
    /// a plain repaint of existing rows silently dropped added/removed devices.
    @Test func updateWithDeviceSetChangeRebuildsWhileOpen() async throws {
        let (popover, _, backend) = try await makePopover()
        popover.test_simulateOpen()

        var devices = backend.devices
        devices.append(Device(id: "another-speaker", name: "Another Speaker", kind: .generic))
        popover.update(devices: devices)

        #expect(popover.test_deviceRow(for: "another-speaker") != nil, "device added while the popover is open still gets a row")
    }

    // MARK: Audit B8 — no rebuild while the popover is closed

    /// While the popover is CLOSED, `update(devices:)` must not rebuild the
    /// panel — under volume-key repeat while streaming, every backend event
    /// echoing through here was a hidden full rebuild on the main thread.
    @Test func updateWhileClosedDoesNotRebuild() async throws {
        let (popover, _, backend) = try await makePopover()
        popover.test_isShownOverride = false   // back to real closed-state semantics

        let baseline = popover.test_rebuildCount
        for _ in 0..<20 { popover.update(devices: backend.devices) }
        #expect(popover.test_rebuildCount == baseline, "a closed popover ingests snapshots without rebuilding the view tree")
    }

    /// State ingested while closed must still render correctly on the next
    /// open — `rebuildForOpen()` rebuilds from current state, so nothing is
    /// lost by skipping the closed-state rebuilds.
    @Test func stateIngestedWhileClosedRendersOnNextOpen() async throws {
        let (popover, _, backend) = try await makePopover()
        let baselineCount = popover.test_deviceSectionRowCount
        popover.test_isShownOverride = false

        var devices = backend.devices
        devices.append(Device(id: "closed-add", name: "Closed Add", kind: .generic))
        popover.update(devices: devices)
        #expect(popover.test_deviceRow(for: "closed-add") == nil, "no row is built while closed")

        popover.test_simulateOpen()
        #expect(popover.test_deviceRow(for: "closed-add") != nil, "the device ingested while closed has a row on the next open")
        #expect(popover.test_deviceSectionRowCount == baselineCount + 1, "the open rebuild reflects the full closed-state snapshot")
    }

    // MARK: T-7 — running-app picker (PLAN decision 6)

    /// The picker excludes apps that already have a route, and only offers
    /// `.regular`-policy apps from the injected fake provider (never touching
    /// the real `NSWorkspace`).
    @Test func pickerExcludesAlreadyRoutedApps() async throws {
        let appRouting = tempAppRoutingController()
        let fakeApps = [
            RunningAppInfo(bundleID: "com.example.music", displayName: "Music", icon: nil),
            RunningAppInfo(bundleID: "com.example.podcasts", displayName: "Podcasts", icon: nil),
        ]
        let (popover, _, _) = try await makePopover(appRouting: appRouting,
                                                     runningAppsProvider: { fakeApps })

        #expect(Set(popover.test_availableAppsForPicker().map(\.bundleID)) == ["com.example.music", "com.example.podcasts"], "both fake apps are offered before either has a route")

        appRouting.addRoute(bundleID: "com.example.music", displayName: "Music")
        #expect(popover.test_availableAppsForPicker().map(\.bundleID) == ["com.example.podcasts"], "an already-routed app is excluded from the picker")
    }

    /// Picking an app adds a route via `AppRoutingController` and triggers a
    /// rebuild (asserted indirectly: the route now exists and the routed count
    /// reflects it once redirected).
    @Test func pickingAppAddsRouteAndRebuilds() async throws {
        let appRouting = tempAppRoutingController()
        let fakeApps = [RunningAppInfo(bundleID: "com.example.music", displayName: "Music", icon: nil)]
        let (popover, _, _) = try await makePopover(appRouting: appRouting,
                                                     runningAppsProvider: { fakeApps })

        #expect(appRouting.appRoutes.isEmpty, "no route before picking")
        popover.test_pickApp(bundleID: "com.example.music")

        #expect(appRouting.appRoutes.map(\.bundleID) == ["com.example.music"], "picking the app created a route via AppRoutingController")
        #expect(appRouting.appRoutes.first?.destination == .noRedirect, "a new route defaults to No Redirect, the neutral/unset state")
        #expect(popover.test_availableAppsForPicker().isEmpty, "the picker excludes it now that it's routed (proves the rebuild/state refreshed)")
    }

    /// A route added WITHOUT going through the popover — the phone's path,
    /// which reaches `AppRoutingController` through the companion dispatcher —
    /// must repaint the open card. It used to update the model and the backend
    /// while the Applications card kept painting the old list until the next
    /// open re-ingested it (reported live: "it only shows up if I open and
    /// close the popover").
    ///
    /// These four tests drive `refreshAppRoutes()` through a hand-wired
    /// `onRoutesDidChange`, because `AppDelegate` — which owns the real
    /// assignment — lives in an executable target this test target can't
    /// import (`Package.swift`), the same reason `CompanionEndToEndTests`
    /// stands up its own AppDelegate-shaped wiring. What they prove is the
    /// SEAM's behavior; that AppDelegate still calls it is not automatable
    /// here.
    @Test func aRouteAddedOutsideThePopoverRepaintsTheOpenCard() async throws {
        let appRouting = tempAppRoutingController()
        let fakeApps = [RunningAppInfo(bundleID: "com.example.music", displayName: "Music", icon: nil)]
        let (popover, _, _) = try await makePopover(appRouting: appRouting,
                                                     runningAppsProvider: { fakeApps })
        appRouting.onRoutesDidChange = { popover.refreshAppRoutes() }

        #expect(popover.test_appRow(for: "com.example.music") == nil, "no row before the route exists")
        appRouting.addRoute(bundleID: "com.example.music", displayName: "Music")

        // The rendered row, not a rebuild counter and not the model: only
        // `makeAppRow` — which runs solely inside `rebuild()` — populates this.
        #expect(popover.test_appRow(for: "com.example.music") != nil,
                "the Applications card must have built a row for the new route")
    }

    /// The mirror case: a route REMOVED from the phone must take its row with
    /// it, rather than leaving a row for a route that no longer exists.
    @Test func aRouteRemovedOutsideThePopoverDropsItsRow() async throws {
        let appRouting = tempAppRoutingController()
        let fakeApps = [RunningAppInfo(bundleID: "com.example.music", displayName: "Music", icon: nil)]
        let (popover, _, _) = try await makePopover(appRouting: appRouting,
                                                     runningAppsProvider: { fakeApps })
        appRouting.onRoutesDidChange = { popover.refreshAppRoutes() }
        appRouting.addRoute(bundleID: "com.example.music", displayName: "Music")
        try #require(popover.test_appRow(for: "com.example.music") != nil)

        appRouting.removeRoute(bundleID: "com.example.music")

        #expect(popover.test_appRow(for: "com.example.music") == nil,
                "the removed route's row must be gone from the card")
    }

    /// THE REGRESSION GUARD for this repaint hook. A volume write must NEVER
    /// rebuild the open popover: `AppRowView`'s slider is `isContinuous`, so
    /// the Mac's own drag fires `onRoutesDidChange` on every tick, and a
    /// rebuild there replaces the row under the mouse and breaks the
    /// NSSlider tracking loop (the invariant `appRow(_:didSetVolume:for:)`
    /// documents). Driven through `test_setVolume`, which is the row's real
    /// delegate path — the same one a live drag takes.
    @Test func aVolumeDragNeverRebuildsTheOpenPopover() async throws {
        let appRouting = tempAppRoutingController()
        let fakeApps = [RunningAppInfo(bundleID: "com.example.music", displayName: "Music", icon: nil)]
        let (popover, _, _) = try await makePopover(appRouting: appRouting,
                                                     runningAppsProvider: { fakeApps })
        appRouting.onRoutesDidChange = { popover.refreshAppRoutes() }
        appRouting.addRoute(bundleID: "com.example.music", displayName: "Music")
        let row = try #require(popover.test_appRow(for: "com.example.music"))

        let baseline = popover.test_rebuildCount
        for volume in 1...25 { row.test_setVolume(volume) }

        #expect(popover.test_rebuildCount == baseline,
                "a drag's per-tick volume writes must not rebuild the tree under the slider")
        #expect(popover.test_appRow(for: "com.example.music") === row,
                "the row under the mouse must be the same object throughout the drag")
    }

    /// A speaker toggled from the PHONE while a GROUP carries Main Out reaches
    /// the model with no `BackendEvent` behind it — `setDeviceSelected` only
    /// calls `applyRouting()` under a Selected-Devices target — so the row's
    /// checkbox had nothing on the way to correct it and stayed stale until
    /// the popover was reopened.
    @Test func refreshDeviceMembershipRepaintsACheckboxChangedWithoutABackendEvent() async throws {
        let (popover, controller, backend) = try await makePopover()
        let device = try #require(backend.devices.first { !$0.isLocalDevice })
        popover.update(devices: backend.devices)
        let row = try #require(popover.test_deviceRow(for: device.id))
        let before = row.test_isEnabledOn

        // Straight at the controller, the way the companion dispatcher does it
        // — deliberately NOT through the row's own click.
        _ = controller.setDeviceSelected(device.id, !before)
        #expect(row.test_isEnabledOn == before, "nothing has repainted the row yet")

        popover.refreshDeviceMembership()

        #expect(row.test_isEnabledOn == !before, "the checkbox must follow the model")
    }

    /// The same call while CLOSED must not sweep the rows — the sweep re-runs
    /// the energize reconcile and the rail extents, which is why
    /// `refreshMainOutMaster` refuses to ride every state change.
    @Test func refreshDeviceMembershipWhileClosedDoesNothing() async throws {
        let (popover, _, backend) = try await makePopover()
        popover.update(devices: backend.devices)
        popover.test_isShownOverride = false

        let baseline = popover.test_rebuildCount
        popover.refreshDeviceMembership()

        #expect(popover.test_rebuildCount == baseline)
    }

    /// The same mutation while CLOSED must NOT rebuild — audit B8's rule.
    @Test func aRouteAddedWhileClosedDoesNotRebuild() async throws {
        let appRouting = tempAppRoutingController()
        let (popover, _, _) = try await makePopover(appRouting: appRouting)
        popover.test_isShownOverride = false
        appRouting.onRoutesDidChange = { popover.refreshAppRoutes() }

        let baseline = popover.test_rebuildCount
        appRouting.addRoute(bundleID: "com.example.music", displayName: "Music")

        #expect(popover.test_rebuildCount == baseline, "a closed popover ingests the change without rebuilding; the next open re-reads it")
    }

    // MARK: T-8 — Applications card wiring (PLAN §C decisions 3/4/6/7/8)

    /// Two fake running apps + one seeded route, so tests can inspect the card's
    /// rows and destinations against the demo fleet.
    private func routedApps() -> [RunningAppInfo] {
        [
            RunningAppInfo(bundleID: "com.example.music", displayName: "Music", icon: nil),
            RunningAppInfo(bundleID: "com.example.safari", displayName: "Safari", icon: nil),
        ]
    }

    /// Seed one route (`AppRoutingController` builds every new route at
    /// `.noRedirect`/vol 100, then mutates), so tests can start with a route
    /// already redirected / at a chosen volume.
    private func seedRoute(_ appRouting: AppRoutingController, bundleID: String, displayName: String,
                           destination: AppRouteDestination = .noRedirect, volume: Int = 100) {
        appRouting.addRoute(bundleID: bundleID, displayName: displayName)
        if destination != .noRedirect { appRouting.setDestination(destination, for: bundleID) }
        if volume != 100 { appRouting.setVolume(volume, for: bundleID) }
    }

    /// The Applications card renders LAST (below Selected Devices): one `AppRowView`
    /// per route in stable order, then the "+ Add application…" row. The card is
    /// always present (the Add row doubles as the empty state).
    @Test func applicationsCardRendersRoutesThenAddRow() async throws {
        let appRouting = tempAppRoutingController()
        appRouting.addRoute(bundleID: "com.example.music", displayName: "Music")
        appRouting.addRoute(bundleID: "com.example.safari", displayName: "Safari")
        let (popover, _, _) = try await makePopover(appRouting: appRouting,
                                                     runningAppsProvider: routedApps)

        #expect(popover.test_appRowCount == 2, "one AppRowView per route")
        #expect(popover.test_appRowBundleIDs() == ["com.example.music", "com.example.safari"], "rows render in stable appRoutes order")
        // The card exists and is the LAST card (after System + Selected Devices).
        #expect(popover.test_isCardCollapsed(title: "App Exceptions") != nil, "the Applications card is present")
    }

    /// Empty state: no routes ⇒ the card is still present with zero app rows (just
    /// the Add row).
    @Test func applicationsCardEmptyStateIsJustAddRow() async throws {
        let appRouting = tempAppRoutingController()
        let (popover, _, _) = try await makePopover(appRouting: appRouting,
                                                     runningAppsProvider: routedApps)
        #expect(popover.test_appRowCount == 0, "no routes ⇒ no app rows")
        #expect(popover.test_isCardCollapsed(title: "App Exceptions") != nil, "the card is still present as the empty state (Add row only)")
    }

    /// A row's destination menu leads with the standalone "No Redirect" entry
    /// (no header — the new default/neutral choice), then splits into a
    /// "Current Device" section (the local device) and an "AirPlay Devices"
    /// section (the available non-local fleet). A freshly-added route selects
    /// the "No Redirect" sentinel; every destination — that one included — keeps
    /// the slider LIVE, since an un-redirected app below 100 is levelled inside
    /// the whole-system mix.
    @Test func appRowDestinationMenuStructureAndSliderStaysLive() async throws {
        let appRouting = tempAppRoutingController()
        appRouting.addRoute(bundleID: "com.example.music", displayName: "Music")
        let (popover, _, _) = try await makePopover(appRouting: appRouting,
                                                     runningAppsProvider: routedApps)

        let titles = try #require(popover.test_appRowDestinationTitles(for: "com.example.music"))
        // The standalone sentinel's HOST-supplied title IS the bridge phrase
        // "Follows main output" (Warm Signal S6, spec §5.1 decision 3 —
        // host-supplies-copy doctrine; the view renders titles verbatim).
        #expect(titles.first == "Follows main output", "the menu leads with the standalone entry, displayed as the bridge phrase")
        let noRedirectIndex = titles.firstIndex(of: "Follows main output")
        let currentDeviceHeaderIndex = titles.firstIndex(of: "Current Device")
        let airplayHeaderIndex = titles.firstIndex(of: "AirPlay Devices")
        #expect(currentDeviceHeaderIndex != nil, "the menu has a Current Device section")
        #expect(airplayHeaderIndex != nil, "the menu has an AirPlay Devices section (decision 4 — no Groups)")
        #expect(noRedirectIndex! < currentDeviceHeaderIndex!, "No Redirect must come before the Current Device section")
        #expect(currentDeviceHeaderIndex! < airplayHeaderIndex!, "Current Device section must come before AirPlay Devices")
        #expect(titles.contains("MacBook Pro Speakers"), "the Current Device entry carries the local device's name")
        #expect(titles.contains("Office"), "an available AirPlay device is offered")

        // A freshly-added (never-touched) route defaults to No Redirect.
        #expect(popover.test_appRowSelectedDestinationID(for: "com.example.music") == PopoverController.noRedirectDestinationID, "a fresh route selects the sentinel No Redirect entry")
        #expect(popover.test_appRowSliderDimmed(for: "com.example.music") == false, "the slider is live on No Redirect — below 100 the app is levelled inside the mix")

        // Bug T2: explicitly picking Current Device gives the app its OWN local
        // stream (played on the Mac's built-in speakers), and its slider is LIVE
        // too.
        let row = try #require(popover.test_appRow(for: "com.example.music"))
        row.test_selectDestination(PopoverController.currentDeviceDestinationID)
        #expect(popover.test_appRowSelectedDestinationID(for: "com.example.music") == PopoverController.currentDeviceDestinationID, "an explicit Current Device pick selects its own sentinel entry")
        #expect(popover.test_appRowSliderDimmed(for: "com.example.music") == false, "Bug T2 — the slider is live for the explicit Current Device pick (its own stream)")
    }

    /// T4b (a deliberate product call, not a bug): an AirPlay-1-only (RAOP)
    /// device must never appear as a per-app routing target — a per-app rebind
    /// (`NativeBackend.performBindOp`'s `.rebind`, fired on a route change)
    /// re-anchors an AP1 device's clock (no shared timing protocol with AP2),
    /// drifting it out of sync with the rest of a group, and some classic
    /// receivers briefly reject the RTSP reconnect. `demoFleet`'s "Mixer"
    /// (`airport-mixer`) is `supportsAirPlay2 == false` — it must be excluded
    /// from the destination menu even though it's a perfectly normal, selectable
    /// Selected-Devices row (AP1 devices are still fine for whole-fleet output,
    /// just not per-app redirect targets).
    @Test func appRowDestinationMenuExcludesAirPlay1OnlyDevices() async throws {
        let appRouting = tempAppRoutingController()
        appRouting.addRoute(bundleID: "com.example.music", displayName: "Music")
        let (popover, _, _) = try await makePopover(appRouting: appRouting,
                                                     runningAppsProvider: routedApps)

        let titles = try #require(popover.test_appRowDestinationTitles(for: "com.example.music"))
        #expect(!(titles.contains("Mixer")),
                "an AirPlay-1-only device (supportsAirPlay2 == false) must never be offered as a per-app routing target")
        #expect(titles.contains("Office"), "an AirPlay-2 device is still offered normally")
    }

    /// One role per speaker: a device currently in Main Out (Selected Devices,
    /// or the active group) is carrying the whole-system mix, so it must not be
    /// offered as a per-app redirect target — a receiver holds ONE AirPlay
    /// session. It reappears once it leaves Main Out. This is the "you can't
    /// build the overlap from the redirect side" half; the reverse (selecting a
    /// speaker that already has a redirect) is `AppRoutingController.clearRoutes`.
    @Test func appRowDestinationMenuExcludesMainOutMembers() async throws {
        let appRouting = tempAppRoutingController()
        appRouting.addRoute(bundleID: "com.example.music", displayName: "Music")
        let (popover, controller, backend) = try await makePopover(
            appRouting: appRouting, runningAppsProvider: routedApps)

        // Baseline: "Office" is offered while it's not in Main Out.
        #expect(try #require(popover.test_appRowDestinationTitles(for: "com.example.music")).contains("Office"))

        // Select "Office" into Main Out (Selected Devices target) → it's carrying
        // the mix and drops out of the redirect menu.
        controller.setMainOut(.selectedDevices)
        _ = controller.setDeviceSelected("office", true)
        popover.update(devices: backend.devices)
        let titlesSelected = try #require(popover.test_appRowDestinationTitles(for: "com.example.music"))
        #expect(!titlesSelected.contains("Office"),
                "a Main Out member must not be offered as a redirect target (one role per speaker)")
        #expect(titlesSelected.contains("Living Room TV"),
                "other, unselected AirPlay devices are still offered")

        // Deselect it → it's a valid redirect target again.
        _ = controller.setDeviceSelected("office", false)
        popover.update(devices: backend.devices)
        #expect(try #require(popover.test_appRowDestinationTitles(for: "com.example.music")).contains("Office"),
                "leaving Main Out makes the speaker offerable again")
    }

    /// Selecting an AirPlay destination on a row calls through to
    /// `AppRoutingController.setDestination` and repaints: the route is redirected
    /// and the row's selected id updates.
    @Test func appRowDestinationChangeCallsThroughAndRepaints() async throws {
        let appRouting = tempAppRoutingController()
        appRouting.addRoute(bundleID: "com.example.music", displayName: "Music")
        let (popover, _, _) = try await makePopover(appRouting: appRouting,
                                                     runningAppsProvider: routedApps)

        let row = try #require(popover.test_appRow(for: "com.example.music"))
        row.test_selectDestination("office")

        #expect(appRouting.appRoutes.first?.destination == .device(id: "office"), "the destination change reached AppRoutingController")
        #expect(popover.test_appRowSelectedDestinationID(for: "com.example.music") == "office", "the repainted row shows the new destination")
        #expect(popover.test_appRowSliderDimmed(for: "com.example.music") == false, "redirected ⇒ the slider is enabled (decision 3)")
    }

    /// Setting a row's volume calls through to `AppRoutingController.setVolume`
    /// (persisted). The handler deliberately does NOT `rebuild()`: a rebuild would
    /// replace the `AppRowView` mid-drag and break the live NSSlider tracking loop
    /// (the visible value tracks the slider directly during a drag). So this
    /// asserts the model call-through, not a repaint.
    @Test func appRowVolumeCallsThrough() async throws {
        let appRouting = tempAppRoutingController()
        seedRoute(appRouting, bundleID: "com.example.music", displayName: "Music",
                  destination: .device(id: "office"))
        let (popover, _, _) = try await makePopover(appRouting: appRouting,
                                                     runningAppsProvider: routedApps)

        let row = try #require(popover.test_appRow(for: "com.example.music"))
        row.test_setVolume(42)

        #expect(appRouting.appRoutes.first?.volume == 42, "the volume change reached AppRoutingController")
    }

    /// Removing a row calls through to `AppRoutingController.removeRoute` and
    /// repaints the card down to the empty state.
    @Test func appRowRemoveCallsThroughAndRepaints() async throws {
        let appRouting = tempAppRoutingController()
        appRouting.addRoute(bundleID: "com.example.music", displayName: "Music")
        let (popover, _, _) = try await makePopover(appRouting: appRouting,
                                                     runningAppsProvider: routedApps)
        #expect(popover.test_appRowCount == 1)

        let row = try #require(popover.test_appRow(for: "com.example.music"))
        row.test_remove()

        #expect(appRouting.appRoutes.isEmpty, "the remove reached AppRoutingController")
        #expect(popover.test_appRowCount == 0, "the card repainted to the empty state")
        #expect(popover.test_appRow(for: "com.example.music") == nil, "the removed app's row is gone")
    }

    // MARK: T3 — ± footer + single selection (LOCKED DECISION)

    /// The "−" segment starts disabled when nothing is selected.
    @Test func applicationsFooterRemoveDisabledWithNoSelection() async throws {
        let appRouting = tempAppRoutingController()
        appRouting.addRoute(bundleID: "com.example.music", displayName: "Music")
        let (popover, _, _) = try await makePopover(appRouting: appRouting,
                                                     runningAppsProvider: routedApps)

        #expect(popover.test_selectedAppBundleID == nil, "nothing selected on a fresh build")
        #expect(!(popover.test_applicationsFooterRemoveEnabled), "the − segment is disabled with no selection")
    }

    /// Selecting a row (the T1 `didRequestSelect` path) sets the host's
    /// selection, renders the row's highlight, and enables the − segment.
    @Test func selectingRowEnablesFooterRemove() async throws {
        let appRouting = tempAppRoutingController()
        appRouting.addRoute(bundleID: "com.example.music", displayName: "Music")
        let (popover, _, _) = try await makePopover(appRouting: appRouting,
                                                     runningAppsProvider: routedApps)

        popover.test_selectAppRow(bundleID: "com.example.music")

        #expect(popover.test_selectedAppBundleID == "com.example.music")
        #expect(popover.test_appRowIsSelected(for: "com.example.music") == true, "the selected row renders the highlight")
        #expect(popover.test_applicationsFooterRemoveEnabled, "the − segment enables once something is selected")
    }

    /// Selection survives `rebuild()` (a device update, volume change, etc. all
    /// recreate every row) — the host re-pushes `isSelected` into the
    /// recreated row rather than losing it.
    @Test func selectionSurvivesRebuild() async throws {
        let appRouting = tempAppRoutingController()
        appRouting.addRoute(bundleID: "com.example.music", displayName: "Music")
        let (popover, _, backend) = try await makePopover(appRouting: appRouting,
                                                           runningAppsProvider: routedApps)
        popover.test_selectAppRow(bundleID: "com.example.music")
        #expect(popover.test_selectedAppBundleID == "com.example.music")

        // Force a full rebuild via a volume change on the row (goes through
        // `appRow(_:didSetVolume:for:)` → `rebuild()`, recreating every row).
        let row = try #require(popover.test_appRow(for: "com.example.music"))
        row.test_setVolume(55)

        #expect(popover.test_selectedAppBundleID == "com.example.music", "selection state on the controller survives the rebuild")
        #expect(popover.test_appRowIsSelected(for: "com.example.music") == true, "the RECREATED row is re-pushed isSelected == true")

        // Also survives a device-driven rebuild path (`update(devices:)`).
        popover.update(devices: backend.devices)
        #expect(popover.test_selectedAppBundleID == "com.example.music")
        #expect(popover.test_appRowIsSelected(for: "com.example.music") == true)
    }

    /// Removing the selected app via the footer's "−" segment calls through to
    /// `AppRoutingController.removeRoute` and advances selection to the
    /// neighbor (LOCKED DECISION).
    @Test func footerRemoveCallsRemoveRouteAndAdvancesSelection() async throws {
        let appRouting = tempAppRoutingController()
        appRouting.addRoute(bundleID: "com.example.music", displayName: "Music")
        appRouting.addRoute(bundleID: "com.example.safari", displayName: "Safari")
        let (popover, _, _) = try await makePopover(appRouting: appRouting,
                                                     runningAppsProvider: routedApps)
        popover.test_selectAppRow(bundleID: "com.example.music")

        popover.test_tapApplicationsFooterRemove()

        #expect(appRouting.appRoutes.map(\.bundleID) == ["com.example.safari"], "the − segment reached AppRoutingController.removeRoute")
        #expect(popover.test_selectedAppBundleID == "com.example.safari", "selection advances to the neighbor that slid into the removed row's slot")
        #expect(popover.test_appRowIsSelected(for: "com.example.safari") == true)
        #expect(popover.test_applicationsFooterRemoveEnabled, "still enabled — the neighbor is now selected")
    }

    /// Removing the last remaining app clears selection and disables the −
    /// segment again.
    @Test func footerRemoveLastAppClearsSelection() async throws {
        let appRouting = tempAppRoutingController()
        appRouting.addRoute(bundleID: "com.example.music", displayName: "Music")
        let (popover, _, _) = try await makePopover(appRouting: appRouting,
                                                     runningAppsProvider: routedApps)
        popover.test_selectAppRow(bundleID: "com.example.music")

        popover.test_tapApplicationsFooterRemove()

        #expect(appRouting.appRoutes.isEmpty)
        #expect(popover.test_selectedAppBundleID == nil, "no neighbor left ⇒ selection clears")
        #expect(!(popover.test_applicationsFooterRemoveEnabled))
    }

    /// The − segment is a no-op (does not call `removeRoute`) when nothing is
    /// selected, matching the real disabled-segment behavior.
    @Test func footerRemoveNoopWithoutSelection() async throws {
        let appRouting = tempAppRoutingController()
        appRouting.addRoute(bundleID: "com.example.music", displayName: "Music")
        let (popover, _, _) = try await makePopover(appRouting: appRouting,
                                                     runningAppsProvider: routedApps)

        popover.test_tapApplicationsFooterRemove()

        #expect(appRouting.appRoutes.map(\.bundleID) == ["com.example.music"], "nothing removed — no selection to act on")
    }

    /// The context-menu "Remove from list" path and Delete/Backspace both
    /// funnel through the SAME `removeApp` neighbor-advance logic as the
    /// footer's − segment (LOCKED DECISION — one remove API, three triggers).
    @Test func contextMenuRemoveAlsoAdvancesSelection() async throws {
        let appRouting = tempAppRoutingController()
        appRouting.addRoute(bundleID: "com.example.music", displayName: "Music")
        appRouting.addRoute(bundleID: "com.example.safari", displayName: "Safari")
        let (popover, _, _) = try await makePopover(appRouting: appRouting,
                                                     runningAppsProvider: routedApps)
        popover.test_selectAppRow(bundleID: "com.example.safari")

        let row = try #require(popover.test_appRow(for: "com.example.safari"))
        row.test_selectRemoveFromListMenuItem()

        #expect(appRouting.appRoutes.map(\.bundleID) == ["com.example.music"])
        #expect(popover.test_selectedAppBundleID == "com.example.music", "no next neighbor ⇒ falls back to the previous one")
    }

    /// The footer's "+" segment is wired to the SAME running-app picker the
    /// header would use — `presentAddApplicationPicker`, unchanged, so its
    /// candidate list (already covered by `testPickerExcludesAlreadyRoutedApps`)
    /// applies identically regardless of which affordance triggered it. A live
    /// `NSMenu.popUp(...)` can't be synthesized headlessly (it needs a real
    /// window), so this only proves the candidate-list plumbing the footer's
    /// picker call reuses, not the actual popup — `test_pickApp` (T-7) already
    /// covers "a pick reaches `AppRoutingController.addRoute`".
    @Test func footerAddSharesPickerCandidatesWithHeaderPath() async throws {
        let appRouting = tempAppRoutingController()
        let (popover, _, _) = try await makePopover(appRouting: appRouting,
                                                     runningAppsProvider: routedApps)

        #expect(popover.test_availableAppsForPicker().map(\.bundleID).sorted() == ["com.example.music", "com.example.safari"])
        popover.test_pickApp(bundleID: "com.example.music")
        #expect(appRouting.appRoutes.map(\.bundleID) == ["com.example.music"], "picking from the (footer-triggered) picker still reaches AppRoutingController")
    }

    /// PLAN decision 7 (silent fallback): when a routed device drops out of the
    /// available fleet, the route resets to No Redirect (the neutral/unset
    /// state — losing a device isn't a deliberate "play on this Mac" choice)
    /// and the card repaints.
    @Test func deviceDropResetsMatchingRouteSilently() async throws {
        let appRouting = tempAppRoutingController()
        seedRoute(appRouting, bundleID: "com.example.music", displayName: "Music",
                  destination: .device(id: "office"))
        let (popover, _, backend) = try await makePopover(appRouting: appRouting,
                                                           runningAppsProvider: routedApps)
        #expect(appRouting.appRoutes.first?.destination == .device(id: "office"), "route starts pointed at office")

        // Drop the routed device from the snapshot entirely (== a deviceRemoved).
        let remaining = backend.devices.filter { $0.id != "office" }
        popover.update(devices: remaining)

        #expect(appRouting.appRoutes.first?.destination == .noRedirect, "decision 7 (revised) — the route silently fell back to No Redirect, not Current Device")
        #expect(popover.test_appRowSelectedDestinationID(for: "com.example.music") == PopoverController.noRedirectDestinationID, "the repainted row reflects the fallback")
    }

    /// R5: a device merely going UNAVAILABLE (still present in the snapshot,
    /// `isAvailable == false`) must NOT reset the route. This used to assert the
    /// opposite — a receiver going quiet for a moment silently and permanently
    /// discarded the user's redirect. The route is now KEPT, and because the target
    /// is no longer in `availableAirPlayDestinations` the row's popup has to be
    /// given an entry for it anyway, or `selectedDestinationID` matches nothing and
    /// `AppRowView.apply`'s `?? true` fallback renders the row as an unset "No
    /// Redirect" — a lie about a route that is perfectly intact.
    @Test func deviceUnavailableKeepsRouteAndOffersItAsAnOfflineDestination() async throws {
        let appRouting = tempAppRoutingController()
        seedRoute(appRouting, bundleID: "com.example.music", displayName: "Music",
                  destination: .device(id: "office"))
        // A second app routed to a DIFFERENT, still-reachable device: nothing about
        // the office outage may touch it.
        seedRoute(appRouting, bundleID: "com.example.safari", displayName: "Safari",
                  destination: .device(id: "homepod-bed"))
        let (popover, _, backend) = try await makePopover(appRouting: appRouting,
                                                           runningAppsProvider: routedApps)

        var devices = backend.devices
        let officeIndex = try #require(devices.firstIndex(where: { $0.id == "office" }))
        devices[officeIndex].isAvailable = false
        popover.update(devices: devices)

        #expect(appRouting.appRoutes.first?.destination == .device(id: "office"),
                Comment(rawValue: "an unavailable-but-still-discovered target KEEPS the route (R5) — the user's intent survives a receiver going quiet"))
        #expect(popover.test_appRowSelectedDestinationID(for: "com.example.music") == "office",
                "the row still selects the kept target, not the No Redirect sentinel")
        #expect(popover.test_appRowSliderDimmed(for: "com.example.music") == false,
                "the row keeps a live slider for its kept target")

        let titles = try #require(popover.test_appRowDestinationTitles(for: "com.example.music"))
        #expect(titles.contains("Office"),
                "the kept-but-offline target is injected into its own row's menu")
        let officeItem = try #require(
           popover.test_appRow(for: "com.example.music")?
               .test_destinationPopUpMenuItem(forDestinationID: "office"))
        #expect(officeItem.toolTip == PopoverController.offlineDestinationSubtitle,
                "the injected entry says what is actually happening to the audio meanwhile")

        // The other app is untouched: same route, and it is NOT handed an entry for
        // a device it doesn't target (the injection is per-row, not global).
        #expect(appRouting.appRoutes.last?.destination == .device(id: "homepod-bed"),
                "an app routed elsewhere is untouched by another device's outage")
        let safariTitles = try #require(popover.test_appRowDestinationTitles(for: "com.example.safari"))
        #expect(!safariTitles.contains("Office"),
                "the offline entry is injected only into the row that actually targets it")
    }

    /// R3 stopgap: a device that already carries a DIFFERENT app's redirect must
    /// show an honest heads-up on its OWN destination entry — the real mixing fix
    /// is a separate follow-up; this only stops the surprise. Comparing by
    /// bundleID (not display name) means the row that ALREADY targets the device
    /// must never warn about itself, and a still-unrouted-elsewhere device must
    /// stay silent.
    @Test func airPlayDeviceShowsQualityWarningWhenAnotherAppAlreadyRoutedThere() async throws {
        let appRouting = tempAppRoutingController()
        seedRoute(appRouting, bundleID: "com.example.music", displayName: "Music",
                  destination: .device(id: "office"))
        seedRoute(appRouting, bundleID: "com.example.safari", displayName: "Safari",
                  destination: .noRedirect)
        let (popover, _, _) = try await makePopover(appRouting: appRouting,
                                                     runningAppsProvider: routedApps)

        // Safari's OWN destination list: the office entry (already carrying
        // Music's redirect) must warn.
        let officeFromSafari = try #require(
           popover.test_appRow(for: "com.example.safari")?
               .test_destinationPopUpMenuItem(forDestinationID: "office"))
        #expect(officeFromSafari.toolTip == PopoverController.sameSpeakerQualitySubtitle,
                "a device already routed by a DIFFERENT app must warn before doubling up")

        // Music's OWN destination list: its OWN office entry must NOT warn about
        // itself — there is only one app there from Music's point of view.
        let officeFromMusic = try #require(
           popover.test_appRow(for: "com.example.music")?
               .test_destinationPopUpMenuItem(forDestinationID: "office"))
        #expect(officeFromMusic.toolTip == nil,
                "a row must never warn about its own existing route to a device")

        // A device nothing is routed to yet must stay silent for everyone.
        let bedFromSafari = try #require(
           popover.test_appRow(for: "com.example.safari")?
               .test_destinationPopUpMenuItem(forDestinationID: "homepod-bed"))
        #expect(bedFromSafari.toolTip == nil,
                "an unrouted device must not carry the quality warning")
    }

    /// R5 recovery, UI half: the target coming back needs no route-table edit at
    /// all — the route was never reset, so the row simply stops carrying the offline
    /// subtitle and the device is a normal available entry again.
    @Test func deviceAvailableAgainLeavesKeptRouteAndDropsOfflineSubtitle() async throws {
        let appRouting = tempAppRoutingController()
        seedRoute(appRouting, bundleID: "com.example.music", displayName: "Music",
                  destination: .device(id: "office"))
        let (popover, _, backend) = try await makePopover(appRouting: appRouting,
                                                           runningAppsProvider: routedApps)

        var devices = backend.devices
        let officeIndex = try #require(devices.firstIndex(where: { $0.id == "office" }))
        devices[officeIndex].isAvailable = false
        popover.update(devices: devices)
        devices[officeIndex].isAvailable = true
        popover.update(devices: devices)

        #expect(appRouting.appRoutes.first?.destination == .device(id: "office"),
                "the route was never reset, so there is nothing to restore")
        #expect(popover.test_appRowSelectedDestinationID(for: "com.example.music") == "office")
        let officeItem = try #require(
           popover.test_appRow(for: "com.example.music")?
               .test_destinationPopUpMenuItem(forDestinationID: "office"))
        #expect(officeItem.toolTip == nil,
                "back to a plain available entry — no lingering \"Offline\" copy")
    }

    /// A device update that doesn't touch any routed target leaves routes alone
    /// (the diff must not over-fire).
    @Test func unrelatedDeviceUpdateLeavesRoutesAlone() async throws {
        let appRouting = tempAppRoutingController()
        seedRoute(appRouting, bundleID: "com.example.music", displayName: "Music",
                  destination: .device(id: "office"))
        let (popover, _, backend) = try await makePopover(appRouting: appRouting,
                                                           runningAppsProvider: routedApps)

        // Drop a DIFFERENT device; the office route must survive.
        let remaining = backend.devices.filter { $0.id != "homepod-bed" }
        popover.update(devices: remaining)
        #expect(appRouting.appRoutes.first?.destination == .device(id: "office"), "dropping an unrelated device leaves the route untouched")
    }

    // MARK: "Resume → <device>" destination entry
    //
    // When an app quits, `AppRoutingController.resetDeviceRoute` clears its
    // `.device(id:)` route back to `.noRedirect` (deliberate, 2026-07-22 product
    // decision — unchanged) but now also remembers the cleared target in-memory
    // (`clearedDeviceRouteMemory`). These tests pin the popover-side offer built
    // on top of that memory: a one-click "Resume → <device>" entry when the
    // remembered target is currently available, wired through the exact same
    // `setDestination(.device(id:), for:)` path an ordinary pick takes.

    /// The core offer: a route reset by `resetDeviceRoute` (simulating the
    /// routed app quitting) gets a "Resume → <device name>" entry prepended to
    /// its destination popup, carrying the documented subtitle, as long as the
    /// remembered target device is still present + reachable.
    @Test func resumeEntryOfferedWhenClearedTargetIsAvailable() async throws {
        let appRouting = tempAppRoutingController()
        seedRoute(appRouting, bundleID: "com.example.music", displayName: "Music",
                  destination: .device(id: "office"))
        appRouting.resetDeviceRoute(bundleID: "com.example.music") // simulates the app quitting

        let (popover, _, _) = try await makePopover(appRouting: appRouting,
                                                     runningAppsProvider: routedApps)

        #expect(appRouting.appRoutes.first?.destination == .noRedirect,
                "the quit-clear itself is unaffected — still reverts to No Redirect")
        let titles = try #require(popover.test_appRowDestinationTitles(for: "com.example.music"))
        #expect(titles.contains("Resume → Office"),
                "an available remembered target is offered as a one-click resume")

        let resumeID = PopoverController.resumeDestinationID(forDeviceID: "office")
        let resumeItem = try #require(
           popover.test_appRow(for: "com.example.music")?
               .test_destinationPopUpMenuItem(forDestinationID: resumeID))
        #expect(resumeItem.toolTip == "Return to where this app was playing")
    }

    /// No memory, no offer — an app that just has an ordinary `.noRedirect`
    /// route (never quit-reset) must not see a stray "Resume" entry.
    @Test func noResumeEntryWithoutClearedDeviceRouteMemory() async throws {
        let appRouting = tempAppRoutingController()
        appRouting.addRoute(bundleID: "com.example.music", displayName: "Music") // plain .noRedirect

        let (popover, _, _) = try await makePopover(appRouting: appRouting,
                                                     runningAppsProvider: routedApps)

        let titles = try #require(popover.test_appRowDestinationTitles(for: "com.example.music"))
        #expect(!(titles.contains(where: { $0.hasPrefix("Resume") })),
                "no cleared-route memory ⇒ no resume offer")
    }

    /// The remembered target going unreachable (still discovered, but
    /// `isAvailable == false`) must hide the resume offer too — same
    /// "available" set (`availableAirPlayDestinations`) the plain device list
    /// and R5's kept-route injection both key off.
    @Test func resumeEntryHiddenWhenClearedTargetIsUnavailable() async throws {
        let appRouting = tempAppRoutingController()
        seedRoute(appRouting, bundleID: "com.example.music", displayName: "Music",
                  destination: .device(id: "office"))
        appRouting.resetDeviceRoute(bundleID: "com.example.music")

        let (popover, _, backend) = try await makePopover(appRouting: appRouting,
                                                           runningAppsProvider: routedApps)
        var devices = backend.devices
        let officeIndex = try #require(devices.firstIndex(where: { $0.id == "office" }))
        devices[officeIndex].isAvailable = false
        popover.update(devices: devices)

        let titles = try #require(popover.test_appRowDestinationTitles(for: "com.example.music"))
        #expect(!(titles.contains(where: { $0.hasPrefix("Resume") })),
                "an unreachable remembered target must not be offered as a resume pick")
    }

    /// Picking the "Resume" entry reaches the SAME `setDestination` call the
    /// destination popup always uses (no new code path) and consumes the
    /// memory it was built from.
    @Test func pickingResumeEntrySetsDestinationAndConsumesMemory() async throws {
        let appRouting = tempAppRoutingController()
        seedRoute(appRouting, bundleID: "com.example.music", displayName: "Music",
                  destination: .device(id: "office"))
        appRouting.resetDeviceRoute(bundleID: "com.example.music")

        let (popover, _, _) = try await makePopover(appRouting: appRouting,
                                                     runningAppsProvider: routedApps)
        let row = try #require(popover.test_appRow(for: "com.example.music"))

        row.test_selectDestination(PopoverController.resumeDestinationID(forDeviceID: "office"))

        #expect(appRouting.appRoutes.first?.destination == .device(id: "office"),
                "picking Resume redirects the app back to the remembered device")
        #expect(appRouting.clearedDeviceRouteTarget(for: "com.example.music") == nil,
               "the memory is consumed once acted on")
        // The resume entry is gone on the next render — the route is active again.
        let titlesAfter = try #require(popover.test_appRowDestinationTitles(for: "com.example.music"))
        #expect(!(titlesAfter.contains(where: { $0.hasPrefix("Resume") })))
    }

    /// Picking a DIFFERENT destination (not the resume offer) while a resume
    /// memory exists also clears it — it's stale/moot either way once the user
    /// has made a fresh, deliberate pick.
    @Test func pickingADifferentDestinationAlsoClearsResumeMemory() async throws {
        let appRouting = tempAppRoutingController()
        seedRoute(appRouting, bundleID: "com.example.music", displayName: "Music",
                  destination: .device(id: "office"))
        appRouting.resetDeviceRoute(bundleID: "com.example.music")

        let (popover, _, _) = try await makePopover(appRouting: appRouting,
                                                     runningAppsProvider: routedApps)
        let row = try #require(popover.test_appRow(for: "com.example.music"))

        row.test_selectDestination("homepod-bed") // an ordinary device pick, not the resume offer

        #expect(appRouting.appRoutes.first?.destination == .device(id: "homepod-bed"))
        #expect(appRouting.clearedDeviceRouteTarget(for: "com.example.music") == nil,
               "a fresh pick moots the remembered target even though it wasn't the one chosen")
    }

    /// Removing the app row entirely also drops any resume memory (wired via
    /// `AppRoutingController.removeRoute`, exercised here end-to-end through the
    /// popover's own removal path).
    @Test func removingAppRowClearsResumeMemory() async throws {
        let appRouting = tempAppRoutingController()
        seedRoute(appRouting, bundleID: "com.example.music", displayName: "Music",
                  destination: .device(id: "office"))
        appRouting.resetDeviceRoute(bundleID: "com.example.music")
        #expect(appRouting.clearedDeviceRouteTarget(for: "com.example.music") == "office")

        let (popover, _, _) = try await makePopover(appRouting: appRouting,
                                                     runningAppsProvider: routedApps)
        let row = try #require(popover.test_appRow(for: "com.example.music"))
        row.test_remove()

        #expect(appRouting.clearedDeviceRouteTarget(for: "com.example.music") == nil)
    }

    /// The Applications card's collapse default (C5, updated from the old
    /// "redirected app" rule): expanded on open iff ANY app route exists — even a
    /// route still on the neutral "No Redirect" default counts (the user added it
    /// on purpose). Only a truly empty route list starts collapsed.
    @Test func applicationsCardExpandedOnOpenIffAnyRouteExists() async throws {
        // No routes at all ⇒ collapsed on open.
        let none = tempAppRoutingController()
        let (popoverNone, _, _) = try await makePopover(appRouting: none,
                                                        runningAppsProvider: routedApps)
        popoverNone.test_simulateOpen()
        #expect(popoverNone.test_isCardCollapsed(title: "App Exceptions") == true, "no routes ⇒ Applications starts collapsed")

        // A route on the neutral "No Redirect" default ⇒ NOW expanded (C5 change).
        let neutral = tempAppRoutingController()
        neutral.addRoute(bundleID: "com.example.music", displayName: "Music") // .noRedirect
        let (popoverNeutral, _, _) = try await makePopover(appRouting: neutral,
                                                           runningAppsProvider: routedApps)
        popoverNeutral.test_simulateOpen()
        #expect(popoverNeutral.test_isCardCollapsed(title: "App Exceptions") == false, "any route (even .noRedirect) ⇒ Applications starts expanded (C5)")

        // A redirected app ⇒ expanded on open (unchanged).
        let redirected = tempAppRoutingController()
        seedRoute(redirected, bundleID: "com.example.music", displayName: "Music",
                  destination: .device(id: "office"))
        let (popover, _, _) = try await makePopover(appRouting: redirected,
                                                     runningAppsProvider: routedApps)
        popover.test_simulateOpen()
        #expect(popover.test_isCardCollapsed(title: "App Exceptions") == false, "≥1 redirected app ⇒ Applications starts expanded")
    }

    // MARK: Live level dispatch (task T8, extends the T5 meter wiring)

    /// `test_pushLevel` (the `isShown`-gate-free twin of `updateLevel`) reaches
    /// the target device row's meter — asserted via `DeviceRowView.test_meterLevel`,
    /// the headless read-back the shared symbol contract adds for exactly this.
    @Test func pushLevelUpdatesTargetRowMeter() async throws {
        let (popover, _, _) = try await makePopover()
        popover.test_pushLevel(0.55, for: "local-mac")
        #expect(popover.test_deviceRow(for: "local-mac")?.test_meterLevel() == 0.55)
    }

    /// `surfaceDidHide` zeroes every device row's meter (the reopen-never-shows-
    /// a-stale-bar discipline documented at the call site).
    @Test func popoverDidCloseZeroesAllDeviceRowMeters() async throws {
        let (popover, _, _) = try await makePopover()
        popover.test_pushLevel(0.7, for: "local-mac")
        #expect(popover.test_deviceRow(for: "local-mac")?.test_meterLevel() == 0.7)

        popover.surfaceDidHide()
        #expect(popover.test_deviceRow(for: "local-mac")?.test_meterLevel() == 0, "closing the popover must reset every row's meter, not just the one just pushed to")
    }

    // MARK: Live level dispatch (task T5, Applications-row meters)

    /// `test_pushAppLevel` (the `isShown`-gate-free twin of `updateAppLevel`)
    /// reaches the target app row's meter — asserted via `AppRowView.test_meterLevel`,
    /// mirroring the device-row coverage above.
    @Test func pushAppLevelUpdatesTargetRowMeter() async throws {
        let appRouting = tempAppRoutingController()
        appRouting.addRoute(bundleID: "com.example.music", displayName: "Music")
        let (popover, _, _) = try await makePopover(appRouting: appRouting,
                                                     runningAppsProvider: routedApps)

        popover.test_pushAppLevel(0.55, for: "com.example.music")
        #expect(popover.test_appRow(for: "com.example.music")?.test_meterLevel() == 0.55)
    }

    /// `surfaceDidHide` zeroes every app row's meter too (not just device rows
    /// and Main Out), so a reopen never shows a stale app-row bar either.
    @Test func popoverDidCloseZeroesAllAppRowMeters() async throws {
        let appRouting = tempAppRoutingController()
        appRouting.addRoute(bundleID: "com.example.music", displayName: "Music")
        let (popover, _, _) = try await makePopover(appRouting: appRouting,
                                                     runningAppsProvider: routedApps)

        popover.test_pushAppLevel(0.7, for: "com.example.music")
        #expect(popover.test_appRow(for: "com.example.music")?.test_meterLevel() == 0.7)

        popover.surfaceDidHide()
        #expect(popover.test_appRow(for: "com.example.music")?.test_meterLevel() == 0, "closing the popover must reset every app row's meter, not just the one just pushed to")
    }

    // MARK: T9 — live per-device streaming indicator (`BackendEvent.routedApps`)
    //
    // `applyRoutedApps` stores the CONFIRMED live map that `AppDelegate` feeds
    // from `BackendEvent.routedApps`; `DeviceRowView`'s routing sublabel prefers
    // it over the intent-based `AppRoutingController.routedAppNames(for:)`
    // label whenever it's non-empty, falling back to intent when the live map
    // goes back to empty (see `DeviceRowView.apply`'s `liveAppNames` doc for the
    // full precedence rule this exercises end-to-end).

    /// A non-empty `.routedApps` event overrides the intent-based label with
    /// the confirmed live set.
    @Test func applyRoutedAppsOverridesIntentLabelWhenNonEmpty() async throws {
        let appRouting = tempAppRoutingController()
        seedRoute(appRouting, bundleID: "com.example.music", displayName: "Music",
                  destination: .device(id: "office"))
        let (popover, _, backend) = try await makePopover(appRouting: appRouting,
                                                           runningAppsProvider: routedApps)

        // Intent alone (no live signal yet): the row shows the configured app name.
        // `update(devices:)` can fully rebuild the row set (route or device-set
        // change under the shown-path semantics these tests run with), so each
        // check below re-fetches the row rather than holding a reference across
        // a call — a held reference would go stale the moment rebuild() swaps
        // in a fresh `DeviceRowView` instance.
        #expect(popover.test_deviceRow(for: "office")?.test_feedText == "Music", "intent-based label before any live signal arrives")

        // A confirmed live signal takes over, even though it carries a
        // different string, to make the precedence unambiguous in the assertion.
        popover.applyRoutedApps(deviceID: "office", appNames: ["Music (confirmed)"])
        popover.update(devices: backend.devices)
        #expect(popover.test_deviceRow(for: "office")?.test_feedText == "Music (confirmed)", "the confirmed live set takes precedence over the intent-based label")
    }

    /// An empty `appNames` (mapping cleared) reverts the row to the
    /// intent-based label rather than leaving it blank.
    @Test func applyRoutedAppsWithEmptyListRevertsToIntentLabel() async throws {
        let appRouting = tempAppRoutingController()
        seedRoute(appRouting, bundleID: "com.example.music", displayName: "Music",
                  destination: .device(id: "office"))
        let (popover, _, backend) = try await makePopover(appRouting: appRouting,
                                                           runningAppsProvider: routedApps)

        // Re-fetch the row after every `update(devices:)` — see the note in
        // `testApplyRoutedAppsOverridesIntentLabelWhenNonEmpty` above.
        popover.applyRoutedApps(deviceID: "office", appNames: ["Music (confirmed)"])
        popover.update(devices: backend.devices)
        #expect(popover.test_deviceRow(for: "office")?.test_feedText == "Music (confirmed)")

        // The live mapping clears (capture stopped, or the route left this
        // device) — falls back to the intent-based label, not a blank row.
        popover.applyRoutedApps(deviceID: "office", appNames: [])
        popover.update(devices: backend.devices)
        #expect(popover.test_deviceRow(for: "office")?.test_feedText == "Music", "an empty live mapping reverts to the intent-based label")
    }

    /// A device that drops out of the snapshot entirely and later reappears
    /// under the same id must NOT resurface a stale confirmed name from
    /// before it left (the live map isn't tied to `Device`, so it needs its
    /// own cleanup on removal).
    @Test func applyRoutedAppsClearsOnDeviceRemoval() async throws {
        let (popover, _, backend) = try await makePopover()
        popover.applyRoutedApps(deviceID: "office", appNames: ["Music"])
        popover.update(devices: backend.devices)
        #expect(popover.test_deviceRow(for: "office")?.test_feedText == "Music")

        // The device drops off the network entirely.
        popover.update(devices: backend.devices.filter { $0.id != "office" })
        #expect(popover.test_deviceRow(for: "office") == nil)

        // It reappears with no route and no fresh live signal — must show
        // nothing, not the stale "Music" from before it left.
        popover.update(devices: backend.devices)
        #expect(popover.test_deviceRow(for: "office")?.test_feedText == nil, "a stale live mapping must not resurface after the device left and returned")
    }

    /// The `MockBackend` offline fixture (`test_emitRoutedApps`) round-trips
    /// through the real `BackendEvent` channel exactly the way `AppDelegate`
    /// would consume it in production, ending with the row rendering the live
    /// label — proving `popover-harness`/`popover-snapshot` can demonstrate T9
    /// without a real per-app-routing backend.
    @Test func mockBackendFixtureRoundTripsToDeviceRowLabel() async throws {
        let (popover, _, backend) = try await makePopover()

        let stream = backend.makeEventStream()
        try await confirmation("routedApps event observed") { received in
            let task = Task {
                for await event in stream {
                    if case .routedApps(let deviceID, let appNames) = event {
                        await popover.applyRoutedApps(deviceID: deviceID, appNames: appNames)
                        received()
                        break
                    }
                }
            }
            defer { task.cancel() }
            backend.test_emitRoutedApps(deviceID: "office", appNames: ["Music"])
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { _ = await task.value }
                group.addTask { try await Task.sleep(for: .seconds(2)) }
                try await group.next()
                group.cancelAll()
            }
        }

        popover.update(devices: backend.devices)
        #expect(popover.test_deviceRow(for: "office")?.test_feedText == "Music", "the fixture's event reached the row via the same plumbing AppDelegate uses")
    }

    // MARK: V11 — Applications card empty-state placeholder

    /// With no rendered app routes the Applications card shows the §5.9
    /// "Route one app somewhere else…" placeholder; adding a route removes it.
    @Test func applicationsCardEmptyStatePlaceholder() async throws {
        let appRouting = tempAppRoutingController()
        let (popover, _, _) = try await makePopover(appRouting: appRouting,
                                                    runningAppsProvider: routedApps)
        #expect(popover.test_applicationsPlaceholderShown, "no routes ⇒ placeholder shown")
        #expect(popover.test_appRowCount == 0, "no app rows")
        #expect(PopoverController.test_applicationsPlaceholderText ==
                "Route one app somewhere else — music to the house, calls on your Mac. Use + to pick an app.",
                "pins the §5.9 locked copy")

        popover.test_pickApp(bundleID: "com.example.music")
        #expect(!(popover.test_applicationsPlaceholderShown), "a route exists ⇒ placeholder gone")
        #expect(popover.test_appRowCount == 1, "one app row now")
    }

    // MARK: C6 — Add-application picker empty state

    /// When no unrouted running apps remain, the picker shows a single disabled
    /// "No applications available" item rather than a blank menu.
    @Test func addApplicationPickerShowsDisabledItemWhenEmpty() async throws {
        let appRouting = tempAppRoutingController()
        // Route BOTH provider apps so the picker's candidate list is empty.
        appRouting.addRoute(bundleID: "com.example.music", displayName: "Music")
        appRouting.addRoute(bundleID: "com.example.safari", displayName: "Safari")
        let (popover, _, _) = try await makePopover(appRouting: appRouting,
                                                    runningAppsProvider: routedApps)
        #expect(popover.test_addApplicationPickerTitles() == ["No applications available"], "empty candidate list ⇒ one disabled placeholder item")

        // Remove one route ⇒ that app becomes available again.
        popover.test_selectAppRow(bundleID: "com.example.music")
        popover.test_tapApplicationsFooterRemove()
        #expect(popover.test_addApplicationPickerTitles() == ["Music"], "a freed-up app reappears as a selectable item")
    }

    // MARK: §4.7 FINAL (S5) — derived vs genuinely-diverging dormancy

    /// FINAL dormant/derived-group semantics (spec §3.4/§4.7, S5 — replaces the
    /// transitional "any group target dims everything + always posts the note"):
    ///
    /// - **Derived-equal** (checked set == active group's members): NO
    ///   "Inactive" note, member rows at FULL emphasis — the Audio Out dropdown
    ///   title carries the group identity.
    /// - **Genuine divergence**: the note appears, and ONLY rows OUTSIDE the
    ///   active target de-emphasize — via the bus-node TINT (checkbox at full
    ///   alpha and interactive), never whole-row alpha.
    @Test func dormantDevicesCardNoteAndDimming() async throws {
        let (popover, controller, backend) = try await makePopover()
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        popover.test_saveCurrentSetup(); await drain(backend)
        let group = controller.groups[0]

        // Point Main Out at the group; checked == members ⇒ DERIVED case.
        popover.test_selectMainOut(.group(id: group.id)); await drain(backend)
        #expect(popover.test_cardNoteTexts(title: "Output Devices") == [], "derived-equal (checked set == group members) posts NO note (§4.7)")
        #expect(popover.test_deviceRow(for: "office")?.test_busNode == .member, "the derived member keeps its filled node")
        #expect(popover.test_deviceRow(for: "office")?.test_busNodeDimmed == false, "…at full gold emphasis — no dormant tint")
        #expect(popover.test_deviceRow(for: "airport-mixer")?.test_busNodeDimmed == false, "non-members keep full ink too in the derived case")
        #expect(!(popover.test_mainOutRow.test_busOriginDimmed), "the bus origin keeps full ink in the derived case")

        // Diverge: check a device the group doesn't hold ⇒ note + scoped tint.
        _ = popover.test_toggleDeviceEnabled(deviceID: "homepod-bed", on: true); await drain(backend)
        #expect(popover.test_cardNoteTexts(title: "Output Devices") == ["Inactive — Main Audio is using '\(group.name)'"], "genuine divergence posts the note with the group's name")
        #expect(popover.test_deviceRow(for: "office")?.test_busNodeDimmed == false, "a row INSIDE the active target keeps full emphasis")
        #expect(popover.test_deviceRow(for: "homepod-bed")?.test_busNodeDimmed == true, "a checked row OUTSIDE the target de-emphasizes via node tint")
        #expect(popover.test_deviceRow(for: "homepod-bed")?.test_busNode == .member, "…keeping its membership fill — the dim is a tint, never a state change")
        #expect(popover.test_deviceRow(for: "airport-mixer")?.test_busNodeDimmed == true, "an unchecked row outside the target recedes too")
        #expect(popover.test_mainOutRow.test_busOriginDimmed, "the origin stub dims only under genuine divergence")
        #expect(popover.test_deviceRow(for: "homepod-bed")?.test_isEnabledOn == true, "the tinted row's checkbox stays fully interactive (tint, never alpha)")

        // Un-diverge (checked set returns to the group's members) ⇒ derived
        // again: the note unmounts LIVE off the membership toggle.
        _ = popover.test_toggleDeviceEnabled(deviceID: "homepod-bed", on: false); await drain(backend)
        #expect(popover.test_cardNoteTexts(title: "Output Devices") == [], "returning to the derived set removes the note live")
        #expect(popover.test_deviceRow(for: "airport-mixer")?.test_busNodeDimmed == false, "…and releases every tint")

        // Back to Selected Devices ⇒ no dormancy machinery at all.
        popover.test_selectMainOut(.selectedDevices); await drain(backend)
        #expect(popover.test_cardNoteTexts(title: "Output Devices") == [], "no dormancy note under Selected Devices")
        #expect(popover.test_deviceRowSelectionDimmed(id: "office") == false, "no dim under Selected Devices")
    }

    // MARK: Decision m — count-free "Selected Devices" title

    /// The "Selected Devices" title is CLEAN (Warm Signal §5.1, decision m —
    /// the old A2 live "(n)" count is gone) and stays stable as toggles change
    /// the checked set; the collapsed button shows the same full title (no
    /// short-form `buttonTitle` — the trailing column is sized to fit it).
    @Test func selectedDevicesTitleStaysCountFree() async throws {
        let (popover, _, _) = try await makePopover()
        // Default selection is {local-mac}.
        #expect(popover.test_mainOutRow.test_selectedTitle == "Selected Devices")

        // Toggling devices in and out never adds a count to the title.
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        _ = popover.test_toggleDeviceEnabled(deviceID: "homepod-bed", on: true)
        #expect(popover.test_mainOutRow.test_selectedTitle == "Selected Devices", "the title stays count-free as the checked set grows")
        #expect(popover.test_mainOutRow.test_buttonTitle == "Selected Devices", "the collapsed button shows the same full, count-free title")

        _ = popover.test_toggleDeviceEnabled(deviceID: "homepod-bed", on: false)
        #expect(popover.test_mainOutRow.test_selectedTitle == "Selected Devices", "…and as it shrinks")
    }

    /// A saved GROUP as the active Main Out target names the GROUP ITSELF on the
    /// collapsed button ("→ Kitchen"), not its member device(s) — shorter, never
    /// truncates, and matches exactly what the user picked from the dropdown.
    /// (Kept through the count-free Main Out decision: that decision removed the
    /// `buttonTitle` short form for "Selected Devices" only; the GROUP branch
    /// still sets one.)
    @Test func collapsedButtonNamesGroupItselfNotMembers() async throws {
        let (popover, controller, backend) = try await makePopover()
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        popover.test_saveCurrentSetup(); await drain(backend)
        let group = controller.groups[0]

        popover.test_selectMainOut(.group(id: group.id)); await drain(backend)
        #expect(popover.test_mainOutRow.test_selectedTitle == group.name,
                "the open menu still shows the bare group name")
        #expect(popover.test_mainOutRow.test_buttonTitle == "→ \(group.name)",
                "the collapsed button names the group itself, not 'office'")
    }

    // MARK: A4 — auto-swap flashes the local row

    /// Turning an AirPlay device ON while the Mac is the sole selected member
    /// auto-unchecks the Mac; the local row flashes once (a no-op under Reduce
    /// Motion, per the same mapping `DeviceRowConnectionStateTests` uses).
    @Test func autoSwapFlashesLocalRow() async throws {
        let (popover, _, _) = try await makePopover()
        #expect(popover.test_deviceRowFlashing(id: "local-mac") == false, "no flash before the swap")

        let result = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        #expect(result.autoSwappedCurrentDevice, "the toggle auto-swapped the local device")
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #expect(popover.test_deviceRowFlashing(id: "local-mac") == !reduceMotion, "the auto-unchecked local row flashes (unless Reduce Motion)")
    }

    // MARK: Surplus container height must not deform the content

    /// Alec's call, 2026-08-06 — resilience, not a root fix. The live report's
    /// banner ballooned into a tall empty box because the card stack's bottom pin
    /// was a single REQUIRED `==`: a container taller than its content was
    /// unsatisfiable, so Auto Layout deformed the content instead and the surplus
    /// landed in the one view with nothing pinning its height. The pin is now
    /// `<=` required (anti-collapse) plus `==` at 999 (hug), so surplus falls to
    /// blank space at the bottom and every row keeps its geometry — which is also
    /// what keeps the rail anchored to its rows through such a mismatch.
    @Test func aContainerTallerThanItsContentLeavesRowGeometryUntouched() async throws {
        let (popover, _, _) = try await makePopover()
        popover.test_simulateOpen()
        popover.setLocalFallbackActive(true)   // mount the banner from the report
        let root = popover.test_panelView
        root.layoutSubtreeIfNeeded()

        func firstDescendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let hit = view as? T { return hit }
            for sub in view.subviews {
                if let hit = firstDescendant(type, in: sub) { return hit }
            }
            return nil
        }
        let banner = try #require(firstDescendant(SilenceFallbackBannerView.self, in: root),
                                  "the fallback banner is mounted")
        let anyRow = try #require(popover.test_deviceRow(for: "office"))

        let naturalFit = popover.test_panelFittingSize.height
        let bannerHeight = banner.frame.height
        // Content is TOP-anchored (header → container top, stack → header bottom),
        // so the invariant is the row's distance from the TOP. Surplus appearing as
        // blank space at the bottom is the intended outcome, not a regression.
        func rowInsetFromTop() -> CGFloat {
            root.frame.height - root.convert(anyRow.bounds, from: anyRow).maxY
        }
        let rowFromTop = rowInsetFromTop()

        // Impose a container 200pt taller than its content — the exact pathology.
        let stretch = root.heightAnchor.constraint(equalToConstant: naturalFit + 200)
        stretch.isActive = true
        root.layoutSubtreeIfNeeded()
        defer { stretch.isActive = false }

        #expect(root.frame.height == naturalFit + 200, "the container really is over-tall")
        #expect(banner.frame.height == bannerHeight,
                "the banner kept its natural height instead of absorbing the surplus")
        #expect(rowInsetFromTop() == rowFromTop,
                "the device rows held their position under the header, so the surplus became blank space at the bottom rather than displacing content")
    }

    // MARK: The rail's invalidation hangs off the view that moves the rows

    /// Live bug, 2026-08-06: the whole rail — origin hook, spine and both detour
    /// arcs — rendered displaced from the rows by a rigid offset. `resolvePlan`
    /// reads live frames at DRAW time, so the resolved geometry was never wrong;
    /// the overlay was simply never told to redraw. The invalidation hung off the
    /// panel's top-level CONTAINER, whose `layout()` does not run when only its
    /// descendants re-lay out inside an unchanged container frame — exactly the
    /// state a too-tall popover produces (constant container, swelling banner,
    /// every card below it sliding). It now hangs off the card stack
    /// (`RailStackView`), which re-lays out in both cases.
    ///
    /// SCOPE — read before trusting this: it guards the WIRING, not the redraw.
    /// The behavioral assertion is not written here because neither shape works in
    /// this process, both established the hard way: a snapshot can't catch it
    /// (`cacheDisplay` forces a full repaint, so the PNG is correct by
    /// construction however stale the invalidation is), `needsDisplay` assertions
    /// pass vacuously (AppKit drops the flag on a windowless view and won't let
    /// you clear one it has already scheduled), and `BusRailOverlayView`'s
    /// `test_drawCount` never moves because a non-GUI test process runs no display
    /// cycle at all — `display()` is a no-op even for an ordered-front window.
    /// The mechanism was proven with standalone on-screen probes instead (four
    /// scenarios; only a container-frame change fired the container's `layout()`,
    /// while the stack's fired in all four). What this test does catch is the
    /// realistic regression: the hook being deleted, or left unwired.
    @Test func theRailOverlayIsInvalidatedByTheCardStack() async throws {
        let (popover, _, _) = try await makePopover()
        popover.test_simulateOpen()
        let root = popover.test_panelView
        root.layoutSubtreeIfNeeded()

        func firstDescendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let hit = view as? T { return hit }
            for sub in view.subviews {
                if let hit = firstDescendant(type, in: sub) { return hit }
            }
            return nil
        }
        let overlay = try #require(firstDescendant(BusRailOverlayView.self, in: root),
                                   "the rail overlay is mounted in the panel")
        let stack = try #require(firstDescendant(RailStackView.self, in: root),
                                 "the CARD STACK carries the invalidation hook — not the container, whose layout() misses descendant-only relayouts")
        #expect(stack.railOverlay === overlay,
                "the stack's hook points at the mounted overlay; unwired, the rail silently goes stale again")
        #expect(stack.arrangedSubviews.contains { $0 is CardView },
                "and it really is the stack holding the cards, i.e. the view whose layout pass moves the rows")
    }

    // MARK: Deselecting a failed device retires its panel (live bug, 2026-08-06)

    /// Reported live: clicking a stuck-unreachable device's radio on and off left
    /// the "Couldn't connect" panel mounted under a row the user had explicitly
    /// UNSELECTED, and the popover kept the height that extra row needed.
    ///
    /// The trap is that `.failed` is STICKY (§1): deselecting doesn't move the
    /// device out of `.failed`, so there is no `→ .off` edge for
    /// `handleConnectionTransitions` to clear the open intent on. The intent has to
    /// be pruned against MEMBERSHIP, not against a connection-state edge. This is
    /// the mirror of R12, not a breach of it — R12 stops a FAILURE from dropping
    /// the user's selection; here the USER drops the selection, so the failure
    /// report goes with it.
    @Test func deselectingAFailedDeviceRetiresItsDiagnosisPanel() async throws {
        let fail = ConnectScript.Attempt.fail(after: 0.05, ConnectionFailure(cause: .notResponding))
        let (popover, controller, backend) = try await makeScriptedPopover(scripts: [
            "office": ConnectScript(attempts: [fail, fail, fail, fail]),
        ])

        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        try await waitForConnectionState(backend, id: "office", isFailed)
        popover.update(devices: backend.devices)
        let mounted = try #require(popover.test_diagnosisPanel(for: "office"),
                                   "the panel auto-expanded on the failure")

        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: false)
        popover.update(devices: backend.devices)

        #expect(!controller.isSpeakerSelected("office"), "the user's deselect took effect")
        #expect(isFailed(try #require(backend.devices.first { $0.id == "office" }).connectionState),
                "the backend still reports .failed — this is the sticky case, not a state change")
        #expect(popover.test_diagnosisPanel(for: "office") == nil,
                "the panel must not outlive the selection that justified it")
        // The VIEW has to leave the tree too, not just the dictionary entry.
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(mounted.superview == nil, "the panel view detached from the row's stack")
    }

    /// The same gesture repeated: no row and no height may accumulate. This is the
    /// half the user actually saw — the popover kept growing, and the slack landed
    /// in the pinned banner, which ballooned into a tall empty box.
    @Test func repeatedSelectDeselectOnAFailedDeviceAccumulatesNothing() async throws {
        let fail = ConnectScript.Attempt.fail(after: 0.05, ConnectionFailure(cause: .notResponding))
        let (popover, _, backend) = try await makeScriptedPopover(scripts: [
            "office": ConnectScript(attempts: [fail, fail, fail, fail, fail, fail, fail, fail]),
        ])
        popover.test_simulateOpen()
        popover.test_applyExactFitSize()

        func mountedRowCount() -> Int {
            guard let row = popover.test_deviceRow(for: "office"),
                  let stack = row.superview as? NSStackView else { return -1 }
            return stack.arrangedSubviews.count
        }
        let baselineRows = mountedRowCount()
        let baselineHeight = popover.test_panelFittingSize.height

        for _ in 1...4 {
            _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
            try await waitForConnectionState(backend, id: "office", isFailed)
            popover.update(devices: backend.devices)
            _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: false)
            popover.update(devices: backend.devices)
            try await Task.sleep(nanoseconds: 350_000_000)   // let the animated detach land
        }

        #expect(mountedRowCount() == baselineRows,
                "the device card ended with the rows it started with — one row per device")
        #expect(popover.test_panelFittingSize.height == baselineHeight,
                "the panel returned to its original content height")
        #expect(popover.test_preferredContentSize.height == popover.test_panelFittingSize.height,
                "the published popover height still agrees with the content — a divergence here is what stretches the banner")
    }

    /// The size primitive belongs to the row primitives: mounting a diagnosis panel
    /// must republish the popover's height by itself, with no help from the caller.
    /// Before this, `reconcileDiagnosisPanels` (the in-place repaint path and the ✕)
    /// mounted and unmounted real rows while the popover kept its old size.
    @Test func mountingAndRemovingADiagnosisPanelRepublishesTheSize() async throws {
        let (popover, _, backend) = try await makeScriptedPopover(scripts: [
            "office": ConnectScript(attempts: [.fail(after: 0.05, ConnectionFailure(cause: .timedOut))]),
        ])
        popover.test_simulateOpen()
        popover.test_applyExactFitSize()
        let bare = popover.test_preferredContentSize.height

        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        try await waitForConnectionState(backend, id: "office", isFailed)
        popover.update(devices: backend.devices)
        try #require(popover.test_diagnosisPanel(for: "office"), "panel mounted")
        #expect(popover.test_preferredContentSize.height > bare,
                "mounting the panel grew the published height")
        #expect(popover.test_preferredContentSize.height == popover.test_panelFittingSize.height,
                "published height == content height while the panel is up")

        // The ✕ path: a removal whose detach is deferred into an animation
        // completion. The size must be republished AFTER the row actually leaves.
        try #require(popover.test_diagnosisPanel(for: "office")).test_tapDismiss()
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(popover.test_preferredContentSize.height == popover.test_panelFittingSize.height,
                "published height == content height once the row has detached")
    }

    // MARK: B2 — dismissible diagnosis panel + episode semantics

    /// The ✕ tears the panel down.
    @Test func dismissRemovesDiagnosisPanel() async throws {
        let (popover, _, backend) = try await makeScriptedPopover(scripts: [
            "office": ConnectScript(attempts: [.fail(after: 0.05, ConnectionFailure(cause: .timedOut))]),
        ])
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        try await waitForConnectionState(backend, id: "office", isFailed)
        popover.update(devices: backend.devices)
        let panel = try #require(popover.test_diagnosisPanel(for: "office"), "auto-expanded")
        panel.test_tapDismiss()
        #expect(popover.test_diagnosisPanel(for: "office") == nil, "the ✕ removed the panel")
    }

    /// A dismissed panel is NOT resurrected by a mid-episode repaint/update while
    /// the device stays `.failed`.
    @Test func dismissedPanelSurvivesRepaint() async throws {
        let (popover, _, backend) = try await makeScriptedPopover(scripts: [
            "office": ConnectScript(attempts: [.fail(after: 0.05, ConnectionFailure(cause: .notResponding))]),
        ])
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        try await waitForConnectionState(backend, id: "office", isFailed)
        popover.update(devices: backend.devices)
        try #require(popover.test_diagnosisPanel(for: "office")).test_tapDismiss()
        #expect(popover.test_diagnosisPanel(for: "office") == nil)

        // A plain repaint (still .failed) and a diagnosis-replacement update must
        // both leave it dismissed.
        popover.update(devices: backend.devices)
        #expect(popover.test_diagnosisPanel(for: "office") == nil, "repaint didn't resurrect it")
        var replaced = backend.devices
        for i in replaced.indices where replaced[i].id == "office" {
            replaced[i].connectionState = .failed(ConnectionFailure(cause: .vanished))
        }
        popover.update(devices: replaced)
        #expect(popover.test_diagnosisPanel(for: "office") == nil, "an in-episode diagnosis replacement didn't resurrect a dismissed panel")
    }

    /// Leaving `.failed` (→ `.connected`) ends the episode and clears the
    /// dismissal, so a genuinely NEW failure episode re-expands the panel even
    /// though the prior one was dismissed.
    @Test func leavingFailedClearsDismissalAndNewEpisodeReExpands() async throws {
        let (popover, _, backend) = try await makeScriptedPopover(scripts: [
            "office": ConnectScript(attempts: [
                .fail(after: 0.05, ConnectionFailure(cause: .notResponding)),
                .connect(after: 0.05),
                .fail(after: 0.05, ConnectionFailure(cause: .timedOut)),
            ]),
        ])
        // Episode 1: fail, then dismiss.
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        try await waitForConnectionState(backend, id: "office", isFailed)
        popover.update(devices: backend.devices)
        try #require(popover.test_diagnosisPanel(for: "office")).test_tapDismiss()
        #expect(popover.test_diagnosisPanel(for: "office") == nil)

        // Retry by cycling the honest toggle off then on (the panel is
        // dismissed, so its "Try again" button is gone). R12/W2-T3: `.failed`
        // no longer bounces the toggle back OFF on its own — membership (and
        // so the toggle's ON state) survives the failure — so unlike before
        // R12, a single `on: true` here would be a same-state no-op; the OFF
        // step is now a real, deliberate user gesture that's required to
        // reach the backend again. Connects ⇒ leaves .failed ⇒ clears the
        // dismissal.
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: false)
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        try await waitForConnectionState(backend, id: "office") { $0 == .connected }
        popover.update(devices: backend.devices)

        // Episode 2: a fresh toggle-on fails again ⇒ re-expands.
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: false)
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        try await waitForConnectionState(backend, id: "office", isFailed)
        popover.update(devices: backend.devices)
        #expect(popover.test_diagnosisPanel(for: "office") != nil, "a NEW failure episode re-expands despite the earlier dismissal")
    }

    /// "Try again → fails again" (`.failed → .connecting → .failed` in one
    /// gesture) counts as a new episode and re-surfaces a dismissed panel.
    @Test func retryThatFailsAgainReExpandsDismissedPanel() async throws {
        let (popover, _, backend) = try await makeScriptedPopover(scripts: [
            "office": ConnectScript(attempts: [
                .fail(after: 0.05, ConnectionFailure(cause: .notResponding)),
                .fail(after: 0.5, ConnectionFailure(cause: .timedOut)),
            ]),
        ])
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        try await waitForConnectionState(backend, id: "office", isFailed)
        popover.update(devices: backend.devices)
        try #require(popover.test_diagnosisPanel(for: "office")).test_tapDismiss()
        #expect(popover.test_diagnosisPanel(for: "office") == nil)

        // Retry by cycling the honest toggle off then on (the dismissed
        // panel's "Try again" is gone). R12/W2-T3: membership — and so the
        // toggle's ON state — survives a `.failed` transition now, so a bare
        // `on: true` here would be a same-state no-op; the explicit OFF step
        // is the real user gesture needed to reach the backend again. Record
        // the intermediate .connecting so the next .failed reads as a fresh
        // edge (a NEW episode), then let it fail again.
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: false)
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        try await waitForConnectionState(backend, id: "office") {
            if case .connecting = $0 { return true }; return false
        }
        popover.update(devices: backend.devices)
        #expect(popover.test_diagnosisPanel(for: "office") == nil, "still dismissed while the retry is in flight")
        try await waitForConnectionState(backend, id: "office", isFailed)
        popover.update(devices: backend.devices)
        #expect(popover.test_diagnosisPanel(for: "office") != nil, "the retry failing again re-surfaces the panel")
    }

    // MARK: F1 — Devices "+" footer strip (a menu since BT-UI)

    /// The "+" lives in the card's BOTTOM footer strip, not the header row
    /// (2026-08-08): no header accessory exists, and the strip is the last row
    /// of the card — below every subsection.
    @Test func devicesPlusIsTheCardsLastRowNotAHeaderAccessory() async throws {
        let (popover, _, _) = try await makePopover()
        #expect(popover.test_cardAccessoryEnabled(title: "Output Devices") == nil,
                "the header row carries no accessory any more")
        #expect(popover.test_devicesFooterIsLastCardRow,
                "the + strip is the last row of the Output Devices card")
        popover.test_tapDevicesFooterAdd()   // headless: the popUp itself is gated
    }

    /// The Devices card's "+" fronts a MENU: its save item creates a group
    /// through real `NSMenu` dispatch, never collapses the card, and the item's
    /// enabled state tracks `canSaveCurrentSetup` (the "+" itself never
    /// disables, so "Pair a Bluetooth speaker…" is always reachable).
    @Test func devicesSaveGroupAccessoryCreatesGroupWithoutCollapsing() async throws {
        let (popover, controller, _) = try await makePopover()
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        var menu = popover.test_outputDevicesPlusMenu()
        #expect(menu.items.first?.isEnabled == true, "a non-empty, not-yet-saved selection ⇒ save item enabled")
        let wasCollapsed = popover.test_isCardCollapsed(title: "Output Devices")

        menu.performActionForItem(at: 0)   // real AppKit menu dispatch
        #expect(controller.groups.count == 1, "the save item created a group")
        #expect(popover.test_isCardCollapsed(title: "Output Devices") == wasCollapsed, "the menu action did NOT collapse the card")
        // The just-saved selection now equals a group ⇒ the save ITEM disables.
        menu = popover.test_outputDevicesPlusMenu()
        #expect(menu.items.first?.isEnabled == false, "selection already saved as a group ⇒ save item disables")
    }

    // MARK: V14 — keyboard selection movement (host half)

    /// ↑/↓ move the app-row selection through `appRoutes` order, clamped at the
    /// ends; the selection survives the repaint and the ± footer's remove stays
    /// enabled throughout.
    @Test func moveAppSelectionUpDownWithClamping() async throws {
        let appRouting = tempAppRoutingController()
        appRouting.addRoute(bundleID: "com.example.music", displayName: "Music")
        appRouting.addRoute(bundleID: "com.example.safari", displayName: "Safari")
        let (popover, _, _) = try await makePopover(appRouting: appRouting,
                                                    runningAppsProvider: routedApps)
        popover.test_selectAppRow(bundleID: "com.example.music")
        #expect(popover.test_applicationsFooterRemoveEnabled, "remove enabled with a selection")

        // Down ⇒ next route.
        popover.test_appRow(for: "com.example.music")?.test_pressDownArrow()
        #expect(popover.test_selectedAppBundleID == "com.example.safari", "moved down to Safari")
        #expect(popover.test_appRowIsSelected(for: "com.example.safari") == true, "selection survived the repaint on the new row")
        #expect(popover.test_applicationsFooterRemoveEnabled, "remove stays enabled")

        // Down again at the end ⇒ clamps (no wrap).
        popover.test_appRow(for: "com.example.safari")?.test_pressDownArrow()
        #expect(popover.test_selectedAppBundleID == "com.example.safari", "clamped at the last row")

        // Up ⇒ previous route.
        popover.test_appRow(for: "com.example.safari")?.test_pressUpArrow()
        #expect(popover.test_selectedAppBundleID == "com.example.music", "moved up to Music")

        // Up again at the start ⇒ clamps.
        popover.test_appRow(for: "com.example.music")?.test_pressUpArrow()
        #expect(popover.test_selectedAppBundleID == "com.example.music", "clamped at the first row")
        #expect(popover.test_applicationsFooterRemoveEnabled, "remove enabled after all moves")
    }

    // MARK: A3 — destination microcopy subtitles

    /// The "No Redirect" and "Current Device" destination entries carry tooltip
    /// subtitles; AirPlay device entries get none.
    @Test func destinationEntriesCarrySubtitleTooltips() async throws {
        let appRouting = tempAppRoutingController()
        appRouting.addRoute(bundleID: "com.example.music", displayName: "Music")
        let (popover, _, _) = try await makePopover(appRouting: appRouting,
                                                    runningAppsProvider: routedApps)
        let row = try #require(popover.test_appRow(for: "com.example.music"))

        let noRedirect = try #require(
            row.test_destinationPopUpMenuItem(forDestinationID: PopoverController.noRedirectDestinationID))
        #expect(noRedirect.toolTip == "Plays in the main mix", "the unrouted entry carries its clarifying tooltip")
        let currentDevice = try #require(row.test_destinationPopUpMenuItem(forDestinationID: PopoverController.currentDeviceDestinationID))
        #expect(currentDevice.toolTip == "Plays locally with its own volume", "Current Device carries its clarifying tooltip")
        // An AirPlay device entry has no subtitle.
        let airplay = try #require(row.test_destinationPopUpMenuItem(forDestinationID: "office"))
        #expect(airplay.toolTip == nil, "AirPlay device entries carry no subtitle tooltip")
    }

    // MARK: Silence-fallback banner (Wave 2 W2-T2, R11)

    /// `setLocalFallbackActive(true)` shows the "Speakers unreachable" banner with
    /// the exact plan copy; `false` clears it. The banner also survives a rebuild
    /// (it's re-pinned above the cards each `rebuild()`).
    @Test func localFallbackBannerShowsAndClears() async throws {
        let (popover, _, backend) = try await makePopover()

        #expect(popover.test_localFallbackBannerText == nil, "no banner by default")

        popover.setLocalFallbackActive(true)
        #expect(popover.test_localFallbackBannerText == "Speakers unreachable — playing on this Mac. Will resume automatically.",
                "the banner shows the verbatim plan copy")

        // A rebuild (e.g. a device-set change) must keep the banner pinned.
        popover.update(devices: backend.devices)
        #expect(popover.test_localFallbackBannerText == "Speakers unreachable — playing on this Mac. Will resume automatically.",
                "the banner survives a rebuild while the fallback is active")

        popover.setLocalFallbackActive(false)
        #expect(popover.test_localFallbackBannerText == nil, "reconnect clears the banner")
    }

    /// P2-8: the banner states a problem, so it must offer a way out of it.
    /// "Try again" re-kicks every Main-Out member that isn't up, one at a time
    /// through `requestReconnect` — never a broad routing re-apply.
    @Test func theSilenceBannerOffersARetryThatReKicksFailedMembers() async throws {
        let (popover, controller, backend) = try await makeScriptedPopover(scripts: [
            // First attempt fails; the retry's fresh attempt connects.
            "office": ConnectScript(attempts: [
                .fail(after: 0.05, ConnectionFailure(cause: .notResponding)),
                .connect(after: 0.05),
            ]),
        ])
        _ = controller.setDeviceSelected("office", true)
        try await waitForConnectionState(backend, id: "office") { self.isFailed($0) }
        popover.update(devices: backend.devices)
        #expect(controller.isMainOutMember("office"), "R12: a failure never drops the selection")

        popover.setLocalFallbackActive(true)
        #expect(popover.test_bannerHasActionButton, "the banner carries its Try again button")

        popover.test_tapBannerAction()
        try await waitForConnectionState(backend, id: "office") { $0 == .connected }
    }

    // MARK: Structural rebuild vs. a live slider drag (STABILITY D4)

    /// A rebuild tears out and recreates every row, so one landing mid-drag
    /// detaches the slider the mouse is tracking. While a drag is live the
    /// structural change is DEFERRED (the repaint path runs instead) and paid
    /// off by the next update once the drag ends.
    @Test func aStructuralRebuildIsDeferredWhileASliderDragIsLive() async throws {
        let (popover, _, backend) = try await makePopover()
        let before = popover.test_rebuildCount
        #expect(!popover.test_structuralRebuildDeferred, "nothing owed to start with")

        popover.test_setLiveSliderDrag(true)
        // A device leaving the fleet is a structural change.
        popover.update(devices: backend.devices.filter { $0.id != "office" })
        #expect(popover.test_rebuildCount == before,
                "no rebuild may run under the user's finger")
        #expect(popover.test_structuralRebuildDeferred, "the rebuild is owed")

        popover.test_setLiveSliderDrag(false)
        // Even a no-change update pays the debt — a drag always produces
        // further backend echoes, so no timer is needed.
        popover.update(devices: backend.devices.filter { $0.id != "office" })
        #expect(popover.test_rebuildCount > before, "the deferred rebuild ran")
        #expect(!popover.test_structuralRebuildDeferred, "and the debt cleared")
    }

    // MARK: "Save Selected Devices as group" reports its failures (hardening 11)

    /// The success path stays exactly as it was, and reports no failure.
    @Test func savingSelectedDevicesAsAGroupSucceedsQuietly() async throws {
        let (popover, controller, _) = try await makePopover()
        _ = controller.setDeviceSelected("office", true)
        #expect(!popover.test_saveGroupFailureReported, "nothing has failed yet")

        let menu = popover.test_outputDevicesPlusMenu()
        let index = try #require(menu.items.firstIndex {
            $0.title == "Save Selected Devices as group"
        })
        menu.performActionForItem(at: index)

        #expect(controller.groups.count == 1, "the group was saved")
        #expect(!popover.test_saveGroupFailureReported)
    }

    /// A save that CANNOT persist must not look like it worked. The store here
    /// is pointed at a path whose parent is a regular file, so creating its
    /// directory throws — a real `save` failure, no store mocking.
    @Test func savingSelectedDevicesAsAGroupReportsAPersistenceFailure() async throws {
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("PopoverSaveBlocker-\(UUID().uuidString)")
        try Data().write(to: blocker)
        // The blocker is a FILE in the shared temp dir, not a `tempDirectory()`
        // the fixture cleans up — remove it here or every run leaks one.
        defer { try? FileManager.default.removeItem(at: blocker) }
        let unwritable = blocker.appendingPathComponent("groups", isDirectory: true)

        let backend = MockBackend(fleet: .demoFleet, staggerDiscovery: false,
                                  emitsLevels: false, simulatesDropouts: false)
        try await waitForFleet(backend, count: 7)
        let controller = GroupController(backend: backend,
                                         store: GroupStore(directory: unwritable),
                                         routingStore: RoutingStore(directory: tempDirectory()),
                                         loadPersisted: false)
        let popover = PopoverController()
        popover.configure(groupController: controller)
        controller.ensureDefaultSelection()
        popover.test_isShownOverride = true
        popover.update(devices: backend.devices)
        _ = controller.setDeviceSelected("office", true)

        let menu = popover.test_outputDevicesPlusMenu()
        let index = try #require(menu.items.firstIndex {
            $0.title == "Save Selected Devices as group"
        })
        menu.performActionForItem(at: index)

        #expect(popover.test_saveGroupFailureReported,
                "a save that never persisted is reported, not swallowed")
    }

    // MARK: The AirPlay section's empty state says what is going on (P1-1)

    /// A popover over an ARBITRARY fleet — the shared fixture is pinned to the
    /// 7-device demo fleet, and these tests are about what an EMPTY one says.
    private func makeFleetPopover(_ devices: [Device]) -> (PopoverController, GroupController) {
        let backend = MockBackend(fleet: [], staggerDiscovery: false,
                                  emitsLevels: false, simulatesDropouts: false)
        let controller = GroupController(backend: backend,
                                         store: GroupStore(directory: tempDirectory()),
                                         routingStore: RoutingStore(directory: tempDirectory()),
                                         loadPersisted: false)
        let popover = PopoverController()
        popover.configure(groupController: controller)
        popover.test_isShownOverride = true
        popover.update(devices: devices)
        return (popover, controller)
    }

    private func localMac() -> Device {
        Device(id: "mac", name: "This Mac", kind: .localMac, isLocalDevice: true)
    }

    /// An empty card used to point at Bluetooth and say nothing about the
    /// speakers the user actually came for. It now says it is looking — WITHOUT
    /// taking the Bluetooth Connect affordance away, because the two lines are
    /// about different sections and never contradict.
    @Test func anEmptyFleetSaysItIsLookingForSpeakers() {
        let (popover, _) = makeFleetPopover([localMac()])
        popover.rebuildForOpen()
        #expect(popover.test_speakerSearchStateText == "Looking for speakers…")
        #expect(popover.test_bluetoothConnectRowShown(),
                "the Bluetooth affordance still stands beside it")
        #expect(popover.test_subsectionTitles().contains("AirPlay Devices"),
                "the state line is grouped under the header that names it")
    }

    /// Once the grace elapses, "looking" becomes an honest verdict plus the
    /// thing the user can actually check.
    @Test func afterTheGraceAnEmptyFleetSaysNoneWereFound() {
        let (popover, _) = makeFleetPopover([localMac()])
        popover.rebuildForOpen()
        popover.test_fireSpeakerSearchGrace()
        #expect(popover.test_speakerSearchStateText
                == "No AirPlay speakers found on this network.")
    }

    /// A speaker arriving retires the state line entirely — nothing to explain
    /// once the list has something in it.
    @Test func anArrivingSpeakerRetiresTheStateLine() {
        let (popover, _) = makeFleetPopover([localMac()])
        popover.rebuildForOpen()
        #expect(popover.test_speakerSearchStateText != nil)

        popover.update(devices: [localMac(), Device(id: "office", name: "Office", kind: .homePod)])
        #expect(popover.test_speakerSearchStateText == nil)
        #expect(popover.test_subsectionTitles().contains("AirPlay Devices"))
    }

    /// When the host knows macOS denied Local Network access, an empty list is
    /// not a search result — it is a permission problem, and saying "looking"
    /// forever would be a lie. Dormant until a host wires the provider.
    @Test func aDeniedLocalNetworkPermissionIsNamedInsteadOfSearching() {
        let (popover, _) = makeFleetPopover([localMac()])
        popover.localNetworkDeniedProvider = { true }
        popover.rebuildForOpen()
        #expect(popover.test_speakerSearchStateText
                == "Audiout doesn’t have permission to see devices on this network.")
    }

    /// A fleet that HAS a speaker never renders a state line, and the AirPlay
    /// header keeps its normal has-rows meaning.
    @Test func aFleetWithASpeakerRendersNoStateLine() {
        let (popover, _) = makeFleetPopover([
            localMac(), Device(id: "office", name: "Office", kind: .homePod),
        ])
        popover.rebuildForOpen()
        #expect(popover.test_speakerSearchStateText == nil)
        #expect(popover.test_subsectionTitles()
                == ["AirPlay Devices", "Bluetooth Devices"],
                "no empty AirPlay header, no missing one (the Mac row is pinned above the subsections)")
    }

    // MARK: System-AirPlay guard note (Wave 3 W3-T3)

    /// `setSystemAirPlayNoteActive(true)` shows the "double-path audio" note with
    /// the exact plan copy; `false` clears it. Mirrors
    /// `testLocalFallbackBannerShowsAndClears` — the note also survives a rebuild
    /// (it's re-pinned above the cards each `rebuild()`), and is independent of
    /// the silence-fallback banner (each has its own pinned slot).
    @Test func systemAirPlayNoteShowsAndClears() async throws {
        let (popover, _, backend) = try await makePopover()

        #expect(popover.test_systemAirPlayNoteText == nil, "no note by default")

        popover.setSystemAirPlayNoteActive(true)
        #expect(popover.test_systemAirPlayNoteText == "Your Mac's system output is also set to AirPlay — audio may play twice. Switch it back to avoid an echo.",
                "the note shows the verbatim plan copy")

        // A rebuild (e.g. a device-set change) must keep the note pinned.
        popover.update(devices: backend.devices)
        #expect(popover.test_systemAirPlayNoteText == "Your Mac's system output is also set to AirPlay — audio may play twice. Switch it back to avoid an echo.",
                "the note survives a rebuild while the guard is active")

        popover.setSystemAirPlayNoteActive(false)
        #expect(popover.test_systemAirPlayNoteText == nil, "the note clears once the guard ends")
    }

    /// The unregistered-build note sits at the BOTTOM of the one note slot: it
    /// is a standing condition, so anything actually happening right now takes
    /// the slot away from it and hands it back afterwards. Its "Buy…" button is
    /// the only remedy it can offer, and it routes out to the host.
    @Test func unregisteredNoteShowsOffersBuyAndYieldsTheSlot() async throws {
        let (popover, _, _) = try await makePopover()
        var buyTaps = 0
        popover.onBuyAudiout = { buyTaps += 1 }

        #expect(popover.test_systemAirPlayNoteText == nil, "no note by default")

        popover.setUnregisteredNoteActive(true)
        #expect(popover.test_systemAirPlayNoteText == "Audiout is unregistered. Buying a license keeps it updated and funds the work of improving it.")
        #expect(popover.test_systemAirPlayNoteHasActionButton, "the note offers Buy…")
        popover.test_tapSystemAirPlayNoteAction()
        #expect(buyTaps == 1, "Buy… routes out to the host, which owns the URL")

        // Lowest precedence: the double-path guard takes the slot…
        popover.setSystemAirPlayNoteActive(true)
        #expect(popover.test_systemAirPlayNoteText == PopoverController.systemAirPlayNoteText,
                "something happening now outranks a standing condition")

        // …and hands it straight back when it clears.
        popover.setSystemAirPlayNoteActive(false)
        #expect(popover.test_systemAirPlayNoteText == "Audiout is unregistered. Buying a license keeps it updated and funds the work of improving it.")

        popover.setUnregisteredNoteActive(false)
        #expect(popover.test_systemAirPlayNoteText == nil, "the note clears once a key is in place")
    }

    /// The money-back reminder sits below everything, including the
    /// unregistered note, and carries no button — the refund goes through
    /// Paddle from the receipt email, which the app has no link to. It must
    /// never read as an expiry: the buyer owns the app either way.
    @Test func refundWindowNoteSitsLowestAndOffersNoButton() async throws {
        let (popover, _, _) = try await makePopover()

        popover.setRefundWindowDaysRemaining(2)
        #expect(popover.test_systemAirPlayNoteText
                    == "2 days left to request a refund on Audiout, if it isn’t for you.")
        #expect(!popover.test_systemAirPlayNoteHasActionButton)

        popover.setRefundWindowDaysRemaining(1)
        #expect(popover.test_systemAirPlayNoteText
                    == "Today is the last day to request a refund on Audiout, if it isn’t for you.")

        // Anything else at all takes the slot away from it…
        popover.setUnregisteredNoteActive(true)
        #expect(popover.test_systemAirPlayNoteText == PopoverController.unregisteredNoteText)

        // …and hands it back.
        popover.setUnregisteredNoteActive(false)
        #expect(popover.test_systemAirPlayNoteText
                    == "Today is the last day to request a refund on Audiout, if it isn’t for you.")

        popover.setRefundWindowDaysRemaining(nil)
        #expect(popover.test_systemAirPlayNoteText == nil,
                "the window closing ends the note; there is no zero-day state")
    }

    // MARK: Routing-blocked warning (Wave 3 T-UI)

    /// The "Audiout isn't your output device" warning: shows the verbatim copy
    /// with a "Use Audiout" action button, OUTRANKS an active takeover status (it
    /// sits at the top of the single note slot), fires `onReselectAudiout` when the
    /// button is tapped, and — once cleared — lets the lower-precedence note show
    /// through. Guards the whole T-UI feature (adversarial review #3): a refactor
    /// that inverts the precedence or unhooks the button now fails here.
    @Test func routingBlockedWarningShowsOutranksTakeoverFiresReselectAndClears() async throws {
        let (popover, _, _) = try await makePopover()
        #expect(popover.test_systemAirPlayNoteText == nil, "no note by default")

        popover.setRoutingBlockedNeedsDefault(true)
        #expect(popover.test_systemAirPlayNoteText == "Audiout isn't your Mac's output device — audio won't play until you switch back.",
                "shows the verbatim warning copy")
        #expect(popover.test_systemAirPlayNoteHasActionButton, "the warning offers the 'Use Audiout' remedy")

        // Precedence: even with a takeover status active, routing-blocked wins the slot.
        popover.setTakeoverStatus(.takingOver)
        #expect(popover.test_systemAirPlayNoteText == "Audiout isn't your Mac's output device — audio won't play until you switch back.",
                "routing-blocked outranks an active takeover status")

        // Tapping "Use Audiout" fires the user-initiated re-select callback.
        var reselectFired = false
        popover.onReselectAudiout = { reselectFired = true }
        popover.test_tapSystemAirPlayNoteAction()
        #expect(reselectFired, "the action button invokes onReselectAudiout")

        // Clearing routing-blocked reveals the still-set (lower-precedence) takeover note.
        popover.setRoutingBlockedNeedsDefault(false)
        #expect(popover.test_systemAirPlayNoteText == "Taking audio back from macOS…",
                "with routing-blocked cleared, the takeover status shows through")

        popover.setTakeoverStatus(nil)
        #expect(popover.test_systemAirPlayNoteText == nil, "clearing both empties the slot")
    }

    /// A dead capture tap means every speaker is silent while its row still
    /// says "Connected" — nothing else the note slot carries is worse, so it
    /// takes the slot from everything, including the routing-blocked warning.
    @Test func captureFailureNoteOutranksRoutingBlockedAndClearsBackToIt() async throws {
        let (popover, _, _) = try await makePopover()
        #expect(popover.test_systemAirPlayNoteText == nil, "no note by default")

        popover.setCaptureFailureMessage("Audiout lost access to system audio.")
        #expect(popover.test_systemAirPlayNoteText == "Audiout lost access to system audio.",
                "the capture error's own message renders verbatim")
        #expect(!popover.test_systemAirPlayNoteHasActionButton,
                "the message names its own remedy in prose — there is no button to add")

        // A repeat of the same message changes nothing.
        popover.setCaptureFailureMessage("Audiout lost access to system audio.")
        #expect(popover.test_systemAirPlayNoteText == "Audiout lost access to system audio.")

        // Precedence: even the routing-blocked warning loses to it.
        popover.setRoutingBlockedNeedsDefault(true)
        #expect(popover.test_systemAirPlayNoteText == "Audiout lost access to system audio.",
                "capture-failed outranks routing-blocked")

        // Clearing it reveals the still-set, lower-precedence warning.
        popover.setCaptureFailureMessage(nil)
        #expect(popover.test_systemAirPlayNoteText == "Audiout isn't your Mac's output device — audio won't play until you switch back.",
                "with capture recovered, the routing-blocked warning shows through")

        popover.setRoutingBlockedNeedsDefault(false)
        #expect(popover.test_systemAirPlayNoteText == nil, "clearing both empties the slot")
    }

    // MARK: Takeover status strip (T6, PLAN-AIRPLAY-COEXISTENCE.md)

    /// All four takeover states render their own copy, and the action button
    /// is present ONLY for states 1 (`.needsApproval`) and 4 (`.timedOut`) —
    /// states 2/3 have no remedy this button could offer (state 2's own doc
    /// says approval UX can't fix a missing bundle component, 3 is
    /// transient). State 4 is a genuine failure (WARNING severity, not the
    /// other three states' info tier) and offers "Try Again" rather than the
    /// old copy's unkept promise to retry on its own.
    @Test func takeoverStripRendersEachStateWithButtonForStates1And4() async throws {
        let (popover, _, _) = try await makePopover()

        #expect(popover.test_systemAirPlayNoteText == nil, "no strip by default")

        popover.setTakeoverStatus(.needsApproval(.requiresApproval))
        #expect(popover.test_systemAirPlayNoteText == "Speaker Sync needs permission to run. Open Login Items to approve it.")
        #expect(popover.test_systemAirPlayNoteHasActionButton, "state 1 is the one state with a real remedy")

        popover.setTakeoverStatus(.helperMissing)
        #expect(popover.test_systemAirPlayNoteText == "Speaker Sync is missing from this copy of Audiout. Reinstall Audiout to fix it.")
        #expect(!popover.test_systemAirPlayNoteHasActionButton, "a packaging bug has no approval-UX remedy")

        popover.setTakeoverStatus(.takingOver)
        #expect(popover.test_systemAirPlayNoteText == "Taking audio back from macOS…")
        #expect(!popover.test_systemAirPlayNoteHasActionButton, "the transient state has nothing to tap")

        popover.setTakeoverStatus(.timedOut)
        #expect(popover.test_systemAirPlayNoteText == "Speaker Sync couldn't get the speakers' clocks in step, so this connection couldn't complete.",
                "honest about the outcome — the wait ran out and the connection genuinely failed")
        #expect(popover.test_systemAirPlayNoteHasActionButton, "a failed connection offers Try Again")

        popover.setTakeoverStatus(nil)
        #expect(popover.test_systemAirPlayNoteText == nil, "clearing the status clears the strip")
    }

    /// Tapping state 4's action button invokes `onRetryTakeover`, wired by the
    /// host (`AppDelegate`) to the same single-device re-kick the "Speakers
    /// unreachable" fallback banner's own "Try again" already drives.
    @Test func takeoverTimedOutActionButtonInvokesRetryCallback() async throws {
        let (popover, _, _) = try await makePopover()

        var retried = false
        popover.onRetryTakeover = { retried = true }
        popover.setTakeoverStatus(.timedOut)
        popover.test_tapSystemAirPlayNoteAction()

        #expect(retried, "tapping state 4's button must call onRetryTakeover")
    }

    /// Tapping state 1's action button invokes `onOpenPTPHelperLoginItems`,
    /// wired by the host (`AppDelegate`) to the PTP helper's real
    /// `openSystemSettingsLoginItems()` deep link.
    @Test func takeoverStripActionButtonInvokesLoginItemsCallback() async throws {
        let (popover, _, _) = try await makePopover()

        var opened = false
        popover.onOpenPTPHelperLoginItems = { opened = true }
        popover.setTakeoverStatus(.needsApproval(.notRegistered))
        popover.test_tapSystemAirPlayNoteAction()

        #expect(opened, "tapping state 1's button must call onOpenPTPHelperLoginItems")
    }

    /// PRECEDENCE (T6): a takeover status outranks the double-path guard note —
    /// there is one physical slot, never two stacked notes — and the double-path
    /// note reappears underneath the instant the takeover status clears.
    @Test func takeoverStatusOutranksDoublePathNoteAndDoublePathReturnsWhenCleared() async throws {
        let (popover, _, _) = try await makePopover()

        popover.setSystemAirPlayNoteActive(true)
        #expect(popover.test_systemAirPlayNoteText == PopoverController.systemAirPlayNoteText,
                "with no takeover in progress, the double-path note owns the slot")

        popover.setTakeoverStatus(.takingOver)
        #expect(popover.test_systemAirPlayNoteText == "Taking audio back from macOS…",
                "a takeover status must outrank the double-path note in the shared slot")

        popover.setTakeoverStatus(nil)
        #expect(popover.test_systemAirPlayNoteText == PopoverController.systemAirPlayNoteText,
                "the double-path note must reappear once the takeover status clears")

        popover.setSystemAirPlayNoteActive(false)
        #expect(popover.test_systemAirPlayNoteText == nil, "both conditions ended — the slot is empty")
    }
}
