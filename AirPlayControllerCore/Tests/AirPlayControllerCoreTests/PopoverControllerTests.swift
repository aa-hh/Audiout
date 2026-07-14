// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Alec Henderson and contributors.

import XCTest
import AppKit
@testable import AirPlayControllerCore
@testable import AirPlayControllerPopoverUI

/// Structural + integration coverage for the popover (SPEC §9 2026-07-14b —
/// SoundSource-inspired Main Out model). The popover isn't visible to CI, so
/// these assert the built panel structure and that interactions call through the
/// model — the same checks the `popover-harness` executable runs, folded into
/// `swift test`.
@MainActor
final class PopoverControllerTests: XCTestCase {

    private func makePopover() async throws -> (PopoverController, GroupController, MockBackend) {
        let backend = MockBackend(fleet: .demoFleet, staggerDiscovery: false,
                                  emitsLevels: false, simulatesDropouts: false)
        try await waitForFleet(backend, count: 7)
        let controller = GroupController(backend: backend,
                                         store: GroupStore(directory: tempDirectory()),
                                         routingStore: RoutingStore(directory: tempDirectory()),
                                         loadPersisted: false)
        let popover = PopoverController()
        popover.configure(groupController: controller)
        controller.ensureDefaultSelection()
        popover.update(devices: backend.devices)
        return (popover, controller, backend)
    }

    private func waitForFleet(_ backend: MockBackend, count: Int) async throws {
        let stream = backend.makeEventStream()
        let expectation = expectation(description: "fleet discovered")
        let box = PopoverTestCountBox()
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
            .appendingPathComponent("PopoverControllerTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func drain() async { try? await Task.sleep(nanoseconds: 200_000_000) }

    // MARK: Tests

    func testBaselineHasDeviceRowsAndDefaultPassthrough() async throws {
        let (popover, controller, _) = try await makePopover()
        XCTAssertEqual(popover.test_groupRowCount, 0)
        XCTAssertEqual(popover.test_deviceSectionRowCount, 7)
        XCTAssertTrue(controller.isSpeakerSelected("local-mac"), "current device selected by default")
        XCTAssertTrue(controller.isPassthrough, "default set == {local} ⇒ passthrough")
    }

    func testMainOutSelectorHasSelectedDevicesAndGroups() async throws {
        let (popover, controller, _) = try await makePopover()
        // Before any group: only Selected Devices is selectable.
        XCTAssertEqual(popover.test_mainOutRow.test_selectableTargets, [.selectedDevices])

        // After a group is saved, it appears as a second section.
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        popover.test_saveCurrentSetup(); await drain()
        let group = controller.groups[0]
        XCTAssertTrue(popover.test_mainOutRow.test_selectableTargets.contains(.group(id: group.id)),
                      "the saved group is a Main Out option")
        XCTAssertTrue(popover.test_mainOutRow.test_optionTitles.contains("Output Groups"),
                      "groups are under an Output Groups header")
    }

    func testToggleComposesSelectedDevicesWithoutRoutingWhenTargetIsGroup() async throws {
        let (popover, controller, backend) = try await makePopover()
        // Build a group, point Main Out at it.
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        popover.test_saveCurrentSetup(); await drain()
        let group = controller.groups[0]
        popover.test_selectMainOut(.group(id: group.id)); await drain()
        let before = Set(backend.devices.filter(\.isSelected).map(\.id))

        // Toggling composes the set but must not re-route (target is a group).
        _ = popover.test_toggleDeviceEnabled(deviceID: "homepod-bed", on: true); await drain()
        let after = Set(backend.devices.filter(\.isSelected).map(\.id))
        XCTAssertEqual(before, after, "composing the set didn't change the routed output")
        XCTAssertTrue(controller.isSpeakerSelected("homepod-bed"), "but the set was composed")
    }

    func testSelectingGroupRoutesToItsMembers() async throws {
        let (popover, controller, backend) = try await makePopover()
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        popover.test_saveCurrentSetup(); await drain()
        let group = controller.groups[0]
        popover.test_selectMainOut(.group(id: group.id)); await drain()
        XCTAssertEqual(controller.activeGroupID, group.id)
        XCTAssertEqual(Set(backend.devices.filter(\.isSelected).map(\.id)), Set(group.memberIDs))
    }

    func testSelectingSelectedDevicesRoutesTheAirPlayMembers() async throws {
        let (popover, controller, backend) = try await makePopover()
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        _ = popover.test_toggleDeviceEnabled(deviceID: "homepod-bed", on: true)
        popover.test_selectMainOut(.selectedDevices); await drain()
        let routed = Set(backend.devices.filter(\.isSelected).map(\.id))
        XCTAssertEqual(routed, ["office", "homepod-bed"],
                       "Selected Devices routes exactly its AirPlay members (local isn't a backend output)")
    }

    func testAutoSwapDropsLocalWhenItIsTheSoleMember() async throws {
        let (popover, controller, _) = try await makePopover()
        XCTAssertEqual(controller.selectedDeviceIDs, ["local-mac"])
        let result = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        XCTAssertTrue(result.autoSwappedCurrentDevice, "auto-swap fired")
        XCTAssertFalse(controller.isSpeakerSelected("local-mac"), "current device dropped")
        XCTAssertTrue(controller.isSpeakerSelected("office"))
    }

    func testAutoSwapDoesNotFireWhenLocalIsNotSoleMember() async throws {
        let (popover, controller, _) = try await makePopover()
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)   // drops local
        // Now local is not a member at all; a further AirPlay add must not "auto-swap".
        let result = popover.test_toggleDeviceEnabled(deviceID: "homepod-bed", on: true)
        XCTAssertFalse(result.autoSwappedCurrentDevice, "no auto-swap when local isn't the sole member")
    }

    func testLocalMixBlockRefusesAndSurfacesReason() async throws {
        let (popover, controller, _) = try await makePopover()
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)   // mixed AirPlay set, local out
        XCTAssertFalse(controller.canSelectLocalSpeaker("local-mac"))
        let result = popover.test_toggleDeviceEnabled(deviceID: "local-mac", on: true)
        XCTAssertFalse(result.applied, "adding local into a mixed set is refused")
        XCTAssertEqual(result.refusalReason, GroupController.localMixRefusalReason)
        XCTAssertFalse(controller.isSpeakerSelected("local-mac"))
        XCTAssertEqual(popover.test_lastRefusalReason, GroupController.localMixRefusalReason,
                       "the popover surfaced the refusal reason")
        // The local row's toggle is presented disabled (blocked) with the reason.
        let row = try XCTUnwrap(popover.test_deviceRow(for: "local-mac"))
        XCTAssertFalse(row.test_isEnabledOn)
    }

    func testMainOutMasterReflectsCurrentTarget() async throws {
        let (popover, controller, backend) = try await makePopover()
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)   // set = {office}
        popover.test_selectMainOut(.selectedDevices); await drain()
        backend.setVolume(50, for: "office"); await drain()
        popover.update(devices: backend.devices)
        XCTAssertEqual(controller.mainOutMasterVolume, 50)
        XCTAssertEqual(popover.test_mainOutRow.test_masterValue, 50,
                       "the Main Out slider shows the current target's master")
    }

    func testMainOutMasterDragScalesMembersProportionally() async throws {
        let (popover, controller, backend) = try await makePopover()
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        _ = popover.test_toggleDeviceEnabled(deviceID: "homepod-bed", on: true)
        popover.test_selectMainOut(.selectedDevices); await drain()
        backend.setVolume(40, for: "office"); backend.setVolume(80, for: "homepod-bed"); await drain()
        XCTAssertEqual(controller.mainOutMasterVolume, 60)
        popover.test_dragMainOutMaster(to: 30); await drain()
        XCTAssertEqual(backend.devices.first { $0.id == "office" }?.volume, 20)
        XCTAssertEqual(backend.devices.first { $0.id == "homepod-bed" }?.volume, 40)
    }

    func testSaveSelectedDevicesCreatesGroupWithVisibleMaster() async throws {
        let (popover, controller, _) = try await makePopover()
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)   // non-local set
        popover.test_saveCurrentSetup(); await drain()
        XCTAssertEqual(controller.groups.count, 1)
        let group = controller.groups[0]
        XCTAssertEqual(popover.test_groupRowCount, 1)
        let row = try XCTUnwrap(popover.test_groupRow(for: group.id))
        XCTAssertTrue(row.test_masterSliderVisible, "the group's master slider is visible")
    }

    func testSaveActionDisabledWhenSetEqualsGroup() async throws {
        let (popover, controller, _) = try await makePopover()
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        popover.test_saveCurrentSetup(); await drain()
        popover.rebuild()
        XCTAssertFalse(popover.test_saveCurrentSetupEnabled,
                       "disabled: the Selected Devices set already IS a saved group")
    }

    func testExpansionAnimatesMemberRowsInAndOut() async throws {
        let (popover, controller, _) = try await makePopover()
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        _ = popover.test_toggleDeviceEnabled(deviceID: "homepod-bed", on: true)
        popover.test_saveCurrentSetup(); await drain()
        let group = controller.groups[0]

        XCTAssertEqual(popover.test_memberRowCount(groupID: group.id), group.memberIDs.count)
        XCTAssertEqual(popover.test_visibleMemberRowCount(groupID: group.id), 0)

        popover.test_toggleExpansion(groupID: group.id)
        XCTAssertTrue(popover.test_expandedGroupIDs.contains(group.id))
        XCTAssertTrue(popover.test_lastAnimatedExpansion)
        await drain()
        XCTAssertEqual(popover.test_visibleMemberRowCount(groupID: group.id), group.memberIDs.count)

        popover.test_toggleExpansion(groupID: group.id)
        await drain()
        XCTAssertEqual(popover.test_visibleMemberRowCount(groupID: group.id), 0)
    }

    /// T-U8 Part 1 — a deselected device row returns to a fully unselected
    /// appearance (the stale-highlight bug). After toggling a device OFF the row's
    /// model membership AND every visual property that encodes "selected/highlight"
    /// (icon accent tint, selected-background pill, transient hover) must reset.
    func testDeselectResetsRowHighlight() async throws {
        let (popover, _, _) = try await makePopover()

        // Toggle an AirPlay device ON — it becomes a selected member (auto-swap
        // drops local; that's fine, we only inspect `office`).
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        let row = try XCTUnwrap(popover.test_deviceRow(for: "office"))
        XCTAssertTrue(row.isSelectedInSet, "selected after ON")
        XCTAssertTrue(row.test_isShowingSelectedBackground, "selected row paints its pill")
        XCTAssertTrue(row.test_isEnabledOn, "switch is ON")
        XCTAssertEqual(row.test_iconTint, .controlAccentColor, "selected row is accent-tinted")

        // Toggle it OFF — the row must return to the unselected appearance.
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: false)
        XCTAssertFalse(row.isSelectedInSet, "not selected after OFF")
        XCTAssertFalse(row.test_isShowingSelectedBackground,
                       "deselected row paints NO selected background (no stale highlight)")
        XCTAssertFalse(row.test_isHovered, "no stale hover wash after deselect")
        XCTAssertFalse(row.test_isEnabledOn, "switch returned to OFF")
        XCTAssertEqual(row.test_iconTint, .secondaryLabelColor,
                       "icon tint reverted to secondary (unselected)")
    }

    /// T-U9a — the last-row sticky-highlight bug. A row hovered by the pointer
    /// must drop its hover wash even when the pointer leaves WITHOUT AppKit
    /// delivering a `mouseExited:` — the bottom-most row's case, where the region
    /// directly below it (card padding, inter-card gap, footer) has no tracking
    /// area to trigger the exit. The fix reconciles hover against the real pointer
    /// position via an app-local mouse-moved monitor; here we drive that reconcile
    /// with the pointer reported OUTSIDE and assert the highlight clears. Written
    /// against EVERY device row (and a group row) so it's general, not a last-row
    /// special-case.
    func testHoverClearsWhenPointerLeavesWithoutExitEvent() async throws {
        let (popover, controller, backend) = try await makePopover()

        // Every device row: enter hover, then a pointer-leave reconcile with NO
        // `mouseExited:` must still clear the hover wash.
        for device in backend.devices {
            guard let row = popover.test_deviceRow(for: device.id) else { continue }
            row.test_simulateMouseEntered()
            XCTAssertTrue(row.test_isHovered, "\(device.id): hover set on enter")
            // Pointer moved away; AppKit delivered no exit (dead zone below row).
            row.test_reconcileHover(pointerInside: false)
            XCTAssertFalse(row.test_isHovered,
                           "\(device.id): hover cleared on pointer-leave without an exit event")
        }

        // Same guarantee for a group header row (the last row before the footer).
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        popover.test_saveCurrentSetup(); await drain()
        let group = controller.groups[0]
        let groupRow = try XCTUnwrap(popover.test_groupRow(for: group.id))
        groupRow.test_simulateMouseEntered()
        XCTAssertTrue(groupRow.test_isHovered, "group row: hover set on enter")
        groupRow.test_reconcileHover(pointerInside: false)
        XCTAssertFalse(groupRow.test_isHovered,
                       "group row: hover cleared on pointer-leave without an exit event")
    }

    // MARK: Layout overhaul (header / columns / member toggle / groups "+")

    /// Task A — the header bar shows the "AudioControl" title and two icon
    /// buttons that resolve system SF Symbols; the Groups-editor button opens the
    /// mixer path.
    func testHeaderTitleAndIconButtons() async throws {
        let (popover, _, _) = try await makePopover()
        XCTAssertEqual(popover.test_headerTitle, "AudioControl")
        XCTAssertTrue(popover.test_headerGroupsButtonHasImage,
                      "Open-Groups-editor button resolved a system SF Symbol")
        XCTAssertTrue(popover.test_headerSettingsButtonHasImage,
                      "Settings button resolved a system SF Symbol")

        var openedMixer = false
        popover.onOpenMixer = { openedMixer = true }
        popover.test_tapHeaderGroupsEditor()
        XCTAssertTrue(openedMixer, "the header Groups-editor button opens the mixer path")
    }

    /// Task C — an expanded group's member rows hide the on/off toggle, while the
    /// Selected-Devices row for a non-member device keeps it.
    func testGroupMemberRowsHideTheToggle() async throws {
        let (popover, controller, _) = try await makePopover()
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        _ = popover.test_toggleDeviceEnabled(deviceID: "homepod-bed", on: true)
        popover.test_saveCurrentSetup(); await drain()
        let group = controller.groups[0]

        for mid in group.memberIDs {
            let row = try XCTUnwrap(popover.test_memberRow(groupID: group.id, deviceID: mid))
            XCTAssertFalse(row.test_showsToggle,
                           "group member \(mid) hides its on/off toggle (task C)")
        }
        // A Selected-Devices row for a device that is NOT grouped keeps its toggle.
        let ungrouped = try XCTUnwrap(popover.test_deviceRow(for: "airport-mixer"))
        XCTAssertTrue(ungrouped.test_showsToggle,
                      "a Selected-Devices row still shows its toggle")
    }

    /// Task D — the Groups "+" invokes the new-group callback.
    func testGroupsPlusTriggersNewGroup() async throws {
        let (popover, controller, _) = try await makePopover()
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        popover.test_saveCurrentSetup(); await drain()
        _ = controller

        var triggered = false
        popover.onNewGroup = { triggered = true }
        popover.test_tapNewGroup()
        XCTAssertTrue(triggered, "the Groups '+' invoked the new-group callback")
    }

    /// Task B — the Main Out named dropdown shows the CURRENT target's title and
    /// updates when the target changes (the `test_selectedTitle` hook semantics
    /// are preserved).
    func testMainOutDropdownShowsCurrentTargetTitle() async throws {
        let (popover, controller, _) = try await makePopover()
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        popover.test_saveCurrentSetup(); await drain()
        let group = controller.groups[0]

        popover.test_selectMainOut(.selectedDevices); await drain()
        XCTAssertEqual(popover.test_mainOutRow.test_selectedTitle, "Selected Devices",
                       "the named dropdown shows the current target")
        popover.test_selectMainOut(.group(id: group.id)); await drain()
        XCTAssertEqual(popover.test_mainOutRow.test_selectedTitle, group.name,
                       "selecting a group updates the named dropdown")
    }

    func testMuteDrivesVolumeToZeroAndRestores() async throws {
        let (popover, controller, backend) = try await makePopover()
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        popover.test_saveCurrentSetup(); await drain()
        let target = controller.groups[0].memberIDs.first { id in
            backend.devices.first { $0.id == id }?.isLocalDevice == false
        }!
        let prior = try XCTUnwrap(backend.devices.first { $0.id == target }?.volume)
        XCTAssertGreaterThan(prior, 0)
        popover.test_toggleMute(deviceID: target, muted: true); await drain()
        XCTAssertEqual(backend.devices.first { $0.id == target }?.volume, 0)
        popover.test_toggleMute(deviceID: target, muted: false); await drain()
        XCTAssertEqual(backend.devices.first { $0.id == target }?.volume, prior)
    }
}

private actor PopoverTestCountBox {
    private var count = 0
    func increment() -> Int { count += 1; return count }
}
