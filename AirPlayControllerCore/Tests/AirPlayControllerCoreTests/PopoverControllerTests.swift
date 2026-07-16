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
        XCTAssertEqual(controller.groups.count, 0)
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

    func testSaveActionDisabledWhenSetEqualsGroup() async throws {
        let (popover, controller, _) = try await makePopover()
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        popover.test_saveCurrentSetup(); await drain()
        popover.rebuild()
        XCTAssertFalse(popover.test_saveCurrentSetupEnabled,
                       "disabled: the Selected Devices set already IS a saved group")
    }

    /// T-U8 Part 1 — a deselected device row returns to a fully unselected
    /// appearance (the stale-highlight bug). After toggling a device OFF the row's
    /// model membership AND every visual property that encodes "selected/highlight"
    /// (icon accent tint, transient hover) must reset. The popover row never
    /// paints a selected-background pill at all (2026-07-14 — Alec: removed the
    /// accent wash so multiple selected devices no longer highlight at once;
    /// the mixer window still paints it, covered by its own tests).
    func testDeselectResetsRowHighlight() async throws {
        let (popover, _, _) = try await makePopover()

        // Toggle an AirPlay device ON — it becomes a selected member (auto-swap
        // drops local; that's fine, we only inspect `office`).
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        let row = try XCTUnwrap(popover.test_deviceRow(for: "office"))
        XCTAssertTrue(row.isSelectedInSet, "selected after ON")
        XCTAssertFalse(row.test_isShowingSelectedBackground,
                       "popover row paints no selected-background pill, even when selected")
        XCTAssertTrue(row.test_isEnabledOn, "switch is ON")
        // The icon is neutral in BOTH states now (2026-07-17 redesign): identity
        // only, no accent-when-selected fill. Selection reads from the switch.
        XCTAssertEqual(row.test_iconTint, .secondaryLabelColor, "icon is always neutral")

        // Toggle it OFF — the row must return to the unselected appearance.
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: false)
        XCTAssertFalse(row.isSelectedInSet, "not selected after OFF")
        XCTAssertFalse(row.test_isShowingSelectedBackground,
                       "deselected row paints NO selected background (no stale highlight)")
        XCTAssertFalse(row.test_isHovered, "no stale hover wash after deselect")
        XCTAssertFalse(row.test_isEnabledOn, "switch returned to OFF")
        XCTAssertEqual(row.test_iconTint, .secondaryLabelColor,
                       "icon tint stays neutral (always secondary)")
    }

    /// T-U9a — the last-row sticky-highlight bug. A row hovered by the pointer
    /// must drop its hover wash even when the pointer leaves WITHOUT AppKit
    /// delivering a `mouseExited:` — the bottom-most row's case, where the region
    /// directly below it (card padding, inter-card gap, footer) has no tracking
    /// area to trigger the exit. The fix reconciles hover against the real pointer
    /// position via an app-local mouse-moved monitor; here we drive that reconcile
    /// with the pointer reported OUTSIDE and assert the highlight clears. Written
    /// against EVERY device row so it's general, not a last-row special-case.
    func testHoverClearsWhenPointerLeavesWithoutExitEvent() async throws {
        let (popover, _, backend) = try await makePopover()

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

    /// A Selected-Devices row for a device shows its on/off toggle.
    func testSelectedDevicesRowShowsTheToggle() async throws {
        let (popover, _, _) = try await makePopover()
        let ungrouped = try XCTUnwrap(popover.test_deviceRow(for: "airport-mixer"))
        XCTAssertTrue(ungrouped.test_showsToggle,
                      "a Selected-Devices row shows its toggle")
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
        XCTFail("timed out waiting for \(id)'s connection state")
    }

    private func isFailed(_ state: ConnectionState) -> Bool {
        if case .failed = state { return true }
        return false
    }

    /// → `.failed` (with the popover closed — the rebuild path): the honest
    /// toggle bounces OFF (membership removed), the row shows the warning, and
    /// the diagnosis panel auto-expands with the failure's copy.
    func testFailedTransitionBouncesToggleAndShowsPanel() async throws {
        let failure = ConnectionFailure(cause: .notResponding, detail: "raw engine log line")
        let (popover, controller, backend) = try await makeScriptedPopover(scripts: [
            "office": ConnectScript(attempts: [.fail(after: 0.05, failure)]),
        ])

        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        XCTAssertTrue(controller.isSpeakerSelected("office"), "membership composed on toggle")
        try await waitForConnectionState(backend, id: "office", isFailed)
        popover.update(devices: backend.devices)

        XCTAssertFalse(controller.isSpeakerSelected("office"),
                       "honest toggle: failure removed Selected-Devices membership")
        let row = try XCTUnwrap(popover.test_deviceRow(for: "office"))
        XCTAssertFalse(row.test_isEnabledOn, "the switch bounced back OFF")
        XCTAssertEqual(row.test_statusKind, .failed, "on-icon dot shows the failed (amber) state")
        let panel = try XCTUnwrap(popover.test_diagnosisPanel(for: "office"),
                                  "the diagnosis panel auto-expanded")
        XCTAssertEqual(panel.test_headlineText, failure.headline)
        XCTAssertEqual(panel.test_suggestionText, failure.suggestion)
        XCTAssertTrue(panel.test_copyDetailsEnabled, "detail present ⇒ Copy details enabled")
    }

    /// Sticky-failed (§1): the honest-toggle cleanup triggers a `setOutputSet`
    /// without the failed id, and the warning must survive that cleanup.
    func testStickyWarningSurvivesCleanupSetOutputSet() async throws {
        let (popover, controller, backend) = try await makeScriptedPopover(scripts: [
            "office": ConnectScript(attempts: [.fail(after: 0.05, ConnectionFailure(cause: .timedOut))]),
        ])

        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        try await waitForConnectionState(backend, id: "office", isFailed)
        popover.update(devices: backend.devices)   // runs the membership cleanup
        XCTAssertFalse(controller.isSpeakerSelected("office"))

        // Let the cleanup `setOutputSet` land in the backend, then re-render.
        await drain()
        popover.update(devices: backend.devices)
        let device = try XCTUnwrap(backend.devices.first { $0.id == "office" })
        XCTAssertTrue(isFailed(device.connectionState),
                      "backend kept .failed sticky through the cleanup setOutputSet")
        let row = try XCTUnwrap(popover.test_deviceRow(for: "office"))
        XCTAssertEqual(row.test_statusKind, .failed, "failed dot survived the cleanup")
        XCTAssertNotNil(popover.test_diagnosisPanel(for: "office"), "panel survived too")
    }

    /// The panel auto-expands once on `.failed`, and an in-episode update (the
    /// diagnosis replacing the backend's first guess) refreshes the still-open
    /// panel's copy rather than tearing it down. The manual warning-button toggle
    /// was retired 2026-07-17 (status moved onto the icon) — the panel is now
    /// purely auto-driven off the connection-state transitions.
    func testPanelAutoExpandsAndRefreshesCopyInEpisode() async throws {
        let (popover, _, backend) = try await makeScriptedPopover(scripts: [
            "office": ConnectScript(attempts: [.fail(after: 0.05, ConnectionFailure(cause: .unknown))]),
        ])

        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        try await waitForConnectionState(backend, id: "office", isFailed)
        popover.update(devices: backend.devices)
        let firstPanel = try XCTUnwrap(popover.test_diagnosisPanel(for: "office"),
                                       "auto-expanded once")
        XCTAssertEqual(firstPanel.test_headlineText, ConnectionFailure(cause: .unknown).headline)

        // In-episode update: the diagnosis replaced the guess (still .failed,
        // different cause). The open panel refreshes its copy in place.
        var replaced = backend.devices
        for i in replaced.indices where replaced[i].id == "office" {
            replaced[i].connectionState = .failed(ConnectionFailure(cause: .vanished))
        }
        popover.update(devices: replaced)
        let panel = try XCTUnwrap(popover.test_diagnosisPanel(for: "office"),
                                  "panel stays open through the diagnosis replacement")
        XCTAssertEqual(panel.test_headlineText, ConnectionFailure(cause: .vanished).headline,
                       "the panel re-rendered the replaced failure's copy")
    }

    /// "Try again" re-adds membership (the toggle-on path IS the retry path):
    /// the id re-enters `setOutputSet` → `.connecting`, and on `.connected` the
    /// panel clears and the row rests ON with the green dot.
    func testRetryReconnectsClearsPanelAndRestoresMembership() async throws {
        let (popover, controller, backend) = try await makeScriptedPopover(scripts: [
            "office": ConnectScript(attempts: [
                .fail(after: 0.05, ConnectionFailure(cause: .notResponding)),
                .connect(after: 0.05),
            ]),
        ])

        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        try await waitForConnectionState(backend, id: "office", isFailed)
        popover.update(devices: backend.devices)
        XCTAssertNotNil(popover.test_diagnosisPanel(for: "office"))

        popover.test_tapRetry(for: "office")
        XCTAssertTrue(controller.isSpeakerSelected("office"), "retry re-added membership")
        try await waitForConnectionState(backend, id: "office") { $0 == .connected }
        popover.update(devices: backend.devices)

        XCTAssertNil(popover.test_diagnosisPanel(for: "office"), "connected cleared the panel")
        let row = try XCTUnwrap(popover.test_deviceRow(for: "office"))
        XCTAssertEqual(row.test_statusKind, .connected)
        XCTAssertNil(row.test_statusText, "connected is single-line (no sublabel)")
        XCTAssertTrue(row.test_isEnabledOn, "the honest toggle now rests ON")
    }

    /// A device that disappears entirely while `.failed` (`deviceRemoved`, §1
    /// `.failed → .off`) takes its panel and tracking down with it.
    func testDeviceRemovedWhileFailedTearsDownPanel() async throws {
        let (popover, _, backend) = try await makeScriptedPopover(scripts: [
            "office": ConnectScript(attempts: [.fail(after: 0.05, ConnectionFailure(cause: .vanished))]),
        ])

        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        try await waitForConnectionState(backend, id: "office", isFailed)
        popover.update(devices: backend.devices)
        XCTAssertNotNil(popover.test_diagnosisPanel(for: "office"))

        // The app layer prunes a removed device from the snapshot it pushes.
        popover.update(devices: backend.devices.filter { $0.id != "office" })
        XCTAssertNil(popover.test_diagnosisPanel(for: "office"), "panel torn down on removal")
        XCTAssertNil(popover.test_deviceRow(for: "office"), "row gone with the device")
    }

    /// A retry while a SECOND device is still connecting: the retry must not
    /// disturb the in-flight device, and both resolve independently.
    func testRetryWhileSecondDeviceConnecting() async throws {
        let (popover, controller, backend) = try await makeScriptedPopover(scripts: [
            "office": ConnectScript(attempts: [
                .fail(after: 0.05, ConnectionFailure(cause: .refusedOrBusy)),
                .connect(after: 0.05),
            ]),
            "homepod-bed": ConnectScript(attempts: [.connect(after: 1.0)]),
        ])

        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        _ = popover.test_toggleDeviceEnabled(deviceID: "homepod-bed", on: true)
        try await waitForConnectionState(backend, id: "office", isFailed)
        popover.update(devices: backend.devices)

        // office failed while homepod-bed is still connecting.
        let homepodRow = try XCTUnwrap(popover.test_deviceRow(for: "homepod-bed"))
        XCTAssertEqual(homepodRow.test_statusKind, .connecting, "second device still connecting")
        XCTAssertTrue(controller.isSpeakerSelected("homepod-bed"),
                      "the failure cleanup only removed the FAILED device's membership")

        popover.test_tapRetry(for: "office")
        popover.update(devices: backend.devices)
        let officeDevice = try XCTUnwrap(backend.devices.first { $0.id == "office" })
        XCTAssertEqual(officeDevice.connectionState, .connecting, "retry restarted office")
        let homepodDevice = try XCTUnwrap(backend.devices.first { $0.id == "homepod-bed" })
        XCTAssertEqual(homepodDevice.connectionState, .connecting,
                       "the in-flight device was not disturbed by the retry's setOutputSet")

        try await waitForConnectionState(backend, id: "office") { $0 == .connected }
        try await waitForConnectionState(backend, id: "homepod-bed") { $0 == .connected }
        popover.update(devices: backend.devices)
        XCTAssertEqual(popover.test_deviceRow(for: "office")?.test_statusKind, .connected)
        XCTAssertEqual(popover.test_deviceRow(for: "homepod-bed")?.test_statusKind, .connected)
        XCTAssertNil(popover.test_diagnosisPanel(for: "office"))
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
