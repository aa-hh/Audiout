// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
import AppKit
@testable import AudiouterCore
@testable import AudiouterPopoverUI

/// Structural + integration coverage for the popover (SPEC §9 2026-07-14b —
/// SoundSource-inspired Main Out model). The popover isn't visible to CI, so
/// these assert the built panel structure and that interactions call through the
/// model — the same checks the `popover-harness` executable runs, folded into
/// `swift test`.
@MainActor
final class PopoverControllerTests: XCTestCase {

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

    func testEmptyGroupIsNotOfferedAsAMainOutOption() async throws {
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
        XCTAssertTrue(targets.contains(.group(id: "real")), "the non-empty group is offered")
        XCTAssertFalse(targets.contains(.group(id: "ghost")), "the empty group must not be offered")
        XCTAssertFalse(popover.test_mainOutRow.test_optionTitles.contains("Ghost"),
                       "the empty group's name must not appear in the menu")
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
    /// paints a selected-background pill at all (2026-07-14 — ahh: removed the
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

    /// Task A — the header bar shows the "Audiouter" title and two icon
    /// buttons that resolve system SF Symbols; the Groups-editor button opens the
    /// mixer path.
    func testHeaderTitleAndIconButtons() async throws {
        let (popover, _, _) = try await makePopover()
        XCTAssertEqual(popover.test_headerTitle, "Audiouter")
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
        // A2: the Selected Devices option now carries a live count (here {office}
        // after the auto-swap dropped the local device ⇒ 1).
        XCTAssertEqual(popover.test_mainOutRow.test_selectedTitle, "Selected Devices (1)",
                       "the named dropdown shows the current target with its live count")
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
        // The retried device is a selected member with no routed apps, so its
        // routing sublabel is the bare "System" token (selected ⇒ in the set).
        XCTAssertEqual(row.test_statusText, "System", "selected device shows the System routing token")
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
                // Retry connects after a comfortable delay so the transient
                // `.connecting` state is observable after `update()` (which now
                // rebuilds the Applications card too, taking longer wall-clock).
                .connect(after: 0.5),
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

    /// T-3 — exact-fit sizing: the popover is exactly its visible content height,
    /// with no `NSScrollView` and no clipping. The resize primitive publishes the
    /// panel's settled `fittingSize` through `preferredContentSize` (the documented
    /// `NSPopover` size channel), so after a rebuild the two must be equal and the
    /// height must cover the full stack (header + both cards). No scroller can
    /// appear because the panel contains no scroll view at all.
    func testExactFitSizeMatchesContentNoScroll() async throws {
        let (popover, _, _) = try await makePopover()

        // No NSScrollView anywhere in the panel view tree ⇒ no scroller chrome ever.
        func containsScrollView(_ v: NSView) -> Bool {
            if v is NSScrollView { return true }
            return v.subviews.contains(where: containsScrollView)
        }
        XCTAssertFalse(containsScrollView(popover.test_panelView),
                       "the popover panel contains no NSScrollView (exact-fit, no scrollbar ever)")

        // Publish the exact-fit size, then the tracked content size must equal the
        // panel's settled fitting size — no clipping, nothing cut off.
        popover.test_applyExactFitSize()
        let fitting = popover.test_panelFittingSize
        XCTAssertEqual(popover.test_preferredContentSize, fitting,
                       "preferredContentSize equals the panel's settled fittingSize")

        // Sanity: the fitting height must actually cover the assembled content —
        // the whole panel view is at least as tall as its arranged content (the
        // empty-popover collapse trap would show up as a near-zero height here).
        XCTAssertGreaterThan(fitting.height, 100,
                             "the panel sizes to real content (cards did not collapse to zero)")
        XCTAssertEqual(popover.test_panelView.fittingSize.height, fitting.height,
                       "the panel's own fittingSize matches the published exact-fit height")
    }

    // MARK: Collapsible cards (T-4, PLAN decision 5 + §E risk 1)

    /// A collapsed card reports a header-only height: its body clip collapses to
    /// height 0, while an expanded card's body clip equals the body's fitting
    /// height. Toggling flips between the two.
    func testCollapseReportsHeaderOnlyBodyHeight() async throws {
        let (popover, _, _) = try await makePopover()

        // Both cards are collapsible and open EXPANDED (T-4 wires the affordance;
        // the collapse-default policy is a later task).
        let title = "Devices"
        XCTAssertEqual(popover.test_isCardCollapsed(title: title), false, "opens expanded")
        let fitting = try XCTUnwrap(popover.test_cardBodyFittingHeight(title: title))
        XCTAssertGreaterThan(fitting, 0, "an expanded card has a non-zero body")
        XCTAssertEqual(try XCTUnwrap(popover.test_cardBodyClipHeight(title: title)), fitting, accuracy: 0.5,
                       "expanded: the body clip is the body's full fitting height")

        // Collapse → the body clip reports height 0 (header only).
        XCTAssertEqual(popover.test_toggleCard(title: title), true, "toggle collapses")
        XCTAssertEqual(popover.test_isCardCollapsed(title: title), true)
        XCTAssertEqual(try XCTUnwrap(popover.test_cardBodyClipHeight(title: title)), 0, accuracy: 0.5,
                       "collapsed: the body clip is 0 (header-only height)")

        // Expand again → back to the full body height.
        XCTAssertEqual(popover.test_toggleCard(title: title), false, "toggle expands")
        XCTAssertEqual(try XCTUnwrap(popover.test_cardBodyClipHeight(title: title)), fitting, accuracy: 0.5,
                       "re-expanded: the body clip returns to the full fitting height")
    }

    /// Toggling a card flips its disclosure chevron symbol (`chevron.down`
    /// expanded ⇄ `chevron.right` collapsed — GroupRowView precedent).
    func testToggleFlipsChevronSymbol() async throws {
        let (popover, _, _) = try await makePopover()
        let title = "System"
        XCTAssertEqual(popover.test_cardChevronSymbolName(title: title), "chevron.down",
                       "expanded card shows the down chevron")
        popover.test_toggleCard(title: title)
        XCTAssertEqual(popover.test_cardChevronSymbolName(title: title), "chevron.right",
                       "collapsed card shows the right chevron")
        popover.test_toggleCard(title: title)
        XCTAssertEqual(popover.test_cardChevronSymbolName(title: title), "chevron.down",
                       "re-expanded card shows the down chevron again")
    }

    /// The exact-fit popover height shrinks by exactly the collapsed card's body
    /// height and grows back on expand — the panel and popover track (PLAN §E
    /// risk 1). Uses the non-animated path (== the Reduce Motion path), which
    /// applies the end state synchronously so `fittingSize` is exact immediately.
    func testPanelHeightShrinksAndGrowsByBodyHeight() async throws {
        let (popover, _, _) = try await makePopover()
        let title = "Devices"

        popover.test_applyExactFitSize()
        let expandedHeight = popover.test_panelFittingSize.height
        let body = try XCTUnwrap(popover.test_cardBodyFittingHeight(title: title))

        // Collapse (non-animated == Reduce Motion): the panel shrinks by the body.
        popover.test_toggleCard(title: title)
        popover.test_applyExactFitSize()
        let collapsedHeight = popover.test_panelFittingSize.height
        XCTAssertEqual(expandedHeight - collapsedHeight, body, accuracy: 1.0,
                       "collapsing shrinks the panel by exactly the card body height")
        XCTAssertEqual(popover.test_preferredContentSize.height, collapsedHeight, accuracy: 0.5,
                       "preferredContentSize tracks the collapsed fitting height (no scrollbar)")

        // Expand back → the panel returns to its full height.
        popover.test_toggleCard(title: title)
        popover.test_applyExactFitSize()
        XCTAssertEqual(popover.test_panelFittingSize.height, expandedHeight, accuracy: 1.0,
                       "expanding restores the full panel height")
    }

    /// The non-animated collapse path (Reduce Motion + initial build) applies its
    /// end state SYNCHRONOUSLY — after a `test_toggleCard` returns, the collapse
    /// state and the body clip height are already final (no pending animation).
    func testReduceMotionPathAppliesEndStateSynchronously() async throws {
        let (popover, _, _) = try await makePopover()
        let title = "Devices"
        // `animated: false` is the exact code path Reduce Motion takes.
        popover.test_toggleCard(title: title, animated: false)
        XCTAssertEqual(popover.test_isCardCollapsed(title: title), true, "collapsed immediately")
        XCTAssertEqual(try XCTUnwrap(popover.test_cardBodyClipHeight(title: title)), 0, accuracy: 0.5,
                       "body clip already at its end state (0) — no pending animation")
    }

    /// Rapid toggles retarget cleanly and end in a consistent state (the animator
    /// proxies must not queue or fight). Fire several toggles in a row; the final
    /// state matches the parity of the toggle count.
    func testRapidTogglesEndConsistent() async throws {
        let (popover, _, _) = try await makePopover()
        let title = "Devices"
        // 5 toggles from expanded ⇒ collapsed (odd count).
        for _ in 0..<5 { popover.test_toggleCard(title: title, animated: true) }
        XCTAssertEqual(popover.test_isCardCollapsed(title: title), true,
                       "odd number of rapid toggles ends collapsed")
        // One more ⇒ expanded.
        popover.test_toggleCard(title: title, animated: true)
        XCTAssertEqual(popover.test_isCardCollapsed(title: title), false,
                       "the extra toggle ends expanded")
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

    // MARK: T-5 — collapse-default policy (PLAN §B)

    /// Opening the popover applies fresh defaults: System + Selected Devices
    /// both start expanded.
    func testCollapseDefaultsAppliedOnOpen() async throws {
        let (popover, _, _) = try await makePopover()
        popover.test_simulateOpen()
        XCTAssertEqual(popover.test_isCardCollapsed(title: "System"), false)
        XCTAssertEqual(popover.test_isCardCollapsed(title: "Devices"), false)
    }

    /// A manual toggle during one open is discarded on the NEXT open — defaults
    /// are recomputed rather than remembered (PLAN §B: "manual toggles never
    /// persist").
    func testManualToggleDiscardedOnReopen() async throws {
        let (popover, _, _) = try await makePopover()
        popover.test_simulateOpen()
        popover.test_toggleCard(title: "Devices", animated: false)
        XCTAssertEqual(popover.test_isCardCollapsed(title: "Devices"), true,
                       "manual toggle collapsed it this open")

        // Simulate close + reopen: defaults are recomputed, discarding the toggle.
        popover.test_simulateOpen()
        XCTAssertEqual(popover.test_isCardCollapsed(title: "Devices"), false,
                       "reopening resets to the default — the manual toggle didn't persist")
    }

    /// A rebuild WITHIN one open (e.g. a backend device update) must preserve
    /// the current transient collapse state, not reset it back to the default.
    func testMidOpenRebuildPreservesTransientState() async throws {
        let (popover, _, backend) = try await makePopover()
        popover.test_simulateOpen()
        popover.test_toggleCard(title: "Devices", animated: false)
        XCTAssertEqual(popover.test_isCardCollapsed(title: "Devices"), true)

        // A mid-open rebuild triggered by a backend event (not a reopen).
        popover.update(devices: backend.devices)
        popover.rebuild()
        XCTAssertEqual(popover.test_isCardCollapsed(title: "Devices"), true,
                       "a mid-open rebuild preserves the transient toggle instead of resetting it")
    }

    // MARK: Device set changes drive a full row rebuild (not just a repaint)

    /// `update(devices:)` must detect a device ADDED to the fleet and grow the
    /// device-row set to match — not just repaint the rows that already exist.
    /// Regression coverage for the fix at `PopoverController.update(devices:)`
    /// (~line 208): a device-ID-set diff now forces `rebuild()` instead of the
    /// narrower `refreshDeviceRows()`, which only repaints EXISTING rows and
    /// would otherwise leave a newly-discovered device with no row at all.
    func testUpdateWithAddedDeviceGetsARow() async throws {
        let (popover, _, backend) = try await makePopover()
        let baselineCount = popover.test_deviceSectionRowCount
        XCTAssertNil(popover.test_deviceRow(for: "new-speaker"), "not present before the add")

        var devices = backend.devices
        devices.append(Device(id: "new-speaker", name: "New Speaker", kind: .generic))
        popover.update(devices: devices)

        XCTAssertEqual(popover.test_deviceSectionRowCount, baselineCount + 1,
                       "the added device grew the row count")
        XCTAssertNotNil(popover.test_deviceRow(for: "new-speaker"),
                        "the newly added device has a row after update(devices:)")
    }

    /// The inverse: a device REMOVED from the fleet must drop its row, not leave
    /// a stale one behind.
    func testUpdateWithRemovedDeviceDropsItsRow() async throws {
        let (popover, _, backend) = try await makePopover()
        let baselineCount = popover.test_deviceSectionRowCount
        XCTAssertNotNil(popover.test_deviceRow(for: "office"), "present before the removal")

        let devices = backend.devices.filter { $0.id != "office" }
        popover.update(devices: devices)

        XCTAssertEqual(popover.test_deviceSectionRowCount, baselineCount - 1,
                       "the removed device shrank the row count")
        XCTAssertNil(popover.test_deviceRow(for: "office"),
                     "the removed device's row is gone after update(devices:)")
    }

    /// A device set change must be detected and rebuilt even while the popover is
    /// mid-open (`test_simulateOpen`), which is when the original bug manifested:
    /// a plain repaint of existing rows silently dropped added/removed devices.
    func testUpdateWithDeviceSetChangeRebuildsWhileOpen() async throws {
        let (popover, _, backend) = try await makePopover()
        popover.test_simulateOpen()

        var devices = backend.devices
        devices.append(Device(id: "another-speaker", name: "Another Speaker", kind: .generic))
        popover.update(devices: devices)

        XCTAssertNotNil(popover.test_deviceRow(for: "another-speaker"),
                        "device added while the popover is open still gets a row")
    }

    // MARK: Audit B8 — no rebuild while the popover is closed

    /// While the popover is CLOSED, `update(devices:)` must not rebuild the
    /// panel — under volume-key repeat while streaming, every backend event
    /// echoing through here was a hidden full rebuild on the main thread.
    func testUpdateWhileClosedDoesNotRebuild() async throws {
        let (popover, _, backend) = try await makePopover()
        popover.test_isShownOverride = false   // back to real closed-state semantics

        let baseline = popover.test_rebuildCount
        for _ in 0..<20 { popover.update(devices: backend.devices) }
        XCTAssertEqual(popover.test_rebuildCount, baseline,
                       "a closed popover ingests snapshots without rebuilding the view tree")
    }

    /// State ingested while closed must still render correctly on the next
    /// open — `rebuildForOpen()` rebuilds from current state, so nothing is
    /// lost by skipping the closed-state rebuilds.
    func testStateIngestedWhileClosedRendersOnNextOpen() async throws {
        let (popover, _, backend) = try await makePopover()
        let baselineCount = popover.test_deviceSectionRowCount
        popover.test_isShownOverride = false

        var devices = backend.devices
        devices.append(Device(id: "closed-add", name: "Closed Add", kind: .generic))
        popover.update(devices: devices)
        XCTAssertNil(popover.test_deviceRow(for: "closed-add"),
                     "no row is built while closed")

        popover.test_simulateOpen()
        XCTAssertNotNil(popover.test_deviceRow(for: "closed-add"),
                        "the device ingested while closed has a row on the next open")
        XCTAssertEqual(popover.test_deviceSectionRowCount, baselineCount + 1,
                       "the open rebuild reflects the full closed-state snapshot")
    }

    // MARK: T-7 — running-app picker (PLAN decision 6)

    /// The picker excludes apps that already have a route, and only offers
    /// `.regular`-policy apps from the injected fake provider (never touching
    /// the real `NSWorkspace`).
    func testPickerExcludesAlreadyRoutedApps() async throws {
        let appRouting = tempAppRoutingController()
        let fakeApps = [
            RunningAppInfo(bundleID: "com.example.music", displayName: "Music", icon: nil),
            RunningAppInfo(bundleID: "com.example.podcasts", displayName: "Podcasts", icon: nil),
        ]
        let (popover, _, _) = try await makePopover(appRouting: appRouting,
                                                     runningAppsProvider: { fakeApps })

        XCTAssertEqual(Set(popover.test_availableAppsForPicker().map(\.bundleID)),
                       ["com.example.music", "com.example.podcasts"],
                       "both fake apps are offered before either has a route")

        appRouting.addRoute(bundleID: "com.example.music", displayName: "Music")
        XCTAssertEqual(popover.test_availableAppsForPicker().map(\.bundleID), ["com.example.podcasts"],
                       "an already-routed app is excluded from the picker")
    }

    /// Picking an app adds a route via `AppRoutingController` and triggers a
    /// rebuild (asserted indirectly: the route now exists and the routed count
    /// reflects it once redirected).
    func testPickingAppAddsRouteAndRebuilds() async throws {
        let appRouting = tempAppRoutingController()
        let fakeApps = [RunningAppInfo(bundleID: "com.example.music", displayName: "Music", icon: nil)]
        let (popover, _, _) = try await makePopover(appRouting: appRouting,
                                                     runningAppsProvider: { fakeApps })

        XCTAssertTrue(appRouting.appRoutes.isEmpty, "no route before picking")
        popover.test_pickApp(bundleID: "com.example.music")

        XCTAssertEqual(appRouting.appRoutes.map(\.bundleID), ["com.example.music"],
                       "picking the app created a route via AppRoutingController")
        XCTAssertEqual(appRouting.appRoutes.first?.destination, .noRedirect,
                       "a new route defaults to No Redirect, the neutral/unset state")
        XCTAssertTrue(popover.test_availableAppsForPicker().isEmpty,
                      "the picker excludes it now that it's routed (proves the rebuild/state refreshed)")
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
    func testApplicationsCardRendersRoutesThenAddRow() async throws {
        let appRouting = tempAppRoutingController()
        appRouting.addRoute(bundleID: "com.example.music", displayName: "Music")
        appRouting.addRoute(bundleID: "com.example.safari", displayName: "Safari")
        let (popover, _, _) = try await makePopover(appRouting: appRouting,
                                                     runningAppsProvider: routedApps)

        XCTAssertEqual(popover.test_appRowCount, 2, "one AppRowView per route")
        XCTAssertEqual(popover.test_appRowBundleIDs(), ["com.example.music", "com.example.safari"],
                       "rows render in stable appRoutes order")
        // The card exists and is the LAST card (after System + Selected Devices).
        XCTAssertNotNil(popover.test_isCardCollapsed(title: "Applications"),
                        "the Applications card is present")
    }

    /// Empty state: no routes ⇒ the card is still present with zero app rows (just
    /// the Add row).
    func testApplicationsCardEmptyStateIsJustAddRow() async throws {
        let appRouting = tempAppRoutingController()
        let (popover, _, _) = try await makePopover(appRouting: appRouting,
                                                     runningAppsProvider: routedApps)
        XCTAssertEqual(popover.test_appRowCount, 0, "no routes ⇒ no app rows")
        XCTAssertNotNil(popover.test_isCardCollapsed(title: "Applications"),
                        "the card is still present as the empty state (Add row only)")
    }

    /// A row's destination menu leads with the standalone "No Redirect" entry
    /// (no header — the new default/neutral choice), then splits into a
    /// "Current Device" section (the local device) and an "AirPlay Devices"
    /// section (the available non-local fleet). A freshly-added route selects
    /// the "No Redirect" sentinel and dims the slider; an explicit "Current
    /// Device" pick keeps the slider LIVE (Bug T2 — it's its own local stream),
    /// so only "No Redirect" dims.
    func testAppRowDestinationMenuStructureAndLocalDimming() async throws {
        let appRouting = tempAppRoutingController()
        appRouting.addRoute(bundleID: "com.example.music", displayName: "Music")
        let (popover, _, _) = try await makePopover(appRouting: appRouting,
                                                     runningAppsProvider: routedApps)

        let titles = try XCTUnwrap(popover.test_appRowDestinationTitles(for: "com.example.music"))
        XCTAssertEqual(titles.first, "No Redirect",
                       "the menu leads with the standalone No Redirect entry")
        let noRedirectIndex = titles.firstIndex(of: "No Redirect")
        let currentDeviceHeaderIndex = titles.firstIndex(of: "CURRENT DEVICE")
        let airplayHeaderIndex = titles.firstIndex(of: "AIRPLAY DEVICES")
        XCTAssertNotNil(currentDeviceHeaderIndex, "the menu has a Current Device section")
        XCTAssertNotNil(airplayHeaderIndex,
                        "the menu has an AirPlay Devices section (decision 4 — no Groups)")
        XCTAssertLessThan(noRedirectIndex!, currentDeviceHeaderIndex!,
                          "No Redirect must come before the Current Device section")
        XCTAssertLessThan(currentDeviceHeaderIndex!, airplayHeaderIndex!,
                          "Current Device section must come before AirPlay Devices")
        XCTAssertTrue(titles.contains("MacBook Pro Speakers"),
                      "the Current Device entry carries the local device's name")
        XCTAssertTrue(titles.contains("Office"), "an available AirPlay device is offered")

        // A freshly-added (never-touched) route defaults to No Redirect.
        XCTAssertEqual(popover.test_appRowSelectedDestinationID(for: "com.example.music"),
                       PopoverController.noRedirectDestinationID,
                       "a fresh route selects the sentinel No Redirect entry")
        XCTAssertEqual(popover.test_appRowSliderDimmed(for: "com.example.music"), true,
                       "the slider is dimmed on No Redirect (no independent stream to level)")

        // Bug T2: explicitly picking Current Device gives the app its OWN local
        // stream (played on the Mac's built-in speakers), so its slider is LIVE —
        // only No Redirect stays dimmed.
        let row = try XCTUnwrap(popover.test_appRow(for: "com.example.music"))
        row.test_selectDestination(PopoverController.currentDeviceDestinationID)
        XCTAssertEqual(popover.test_appRowSelectedDestinationID(for: "com.example.music"),
                       PopoverController.currentDeviceDestinationID,
                       "an explicit Current Device pick selects its own sentinel entry")
        XCTAssertEqual(popover.test_appRowSliderDimmed(for: "com.example.music"), false,
                       "Bug T2 — the slider is live for the explicit Current Device pick (its own stream)")
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
    func testAppRowDestinationMenuExcludesAirPlay1OnlyDevices() async throws {
        let appRouting = tempAppRoutingController()
        appRouting.addRoute(bundleID: "com.example.music", displayName: "Music")
        let (popover, _, _) = try await makePopover(appRouting: appRouting,
                                                     runningAppsProvider: routedApps)

        let titles = try XCTUnwrap(popover.test_appRowDestinationTitles(for: "com.example.music"))
        XCTAssertFalse(titles.contains("Mixer"),
                       "an AirPlay-1-only device (supportsAirPlay2 == false) must never be offered "
                       + "as a per-app routing target")
        XCTAssertTrue(titles.contains("Office"),
                     "an AirPlay-2 device is still offered normally")
    }

    /// Selecting an AirPlay destination on a row calls through to
    /// `AppRoutingController.setDestination` and repaints: the route is redirected,
    /// the row's selected id updates, and the slider un-dims.
    func testAppRowDestinationChangeCallsThroughAndRepaints() async throws {
        let appRouting = tempAppRoutingController()
        appRouting.addRoute(bundleID: "com.example.music", displayName: "Music")
        let (popover, _, _) = try await makePopover(appRouting: appRouting,
                                                     runningAppsProvider: routedApps)

        let row = try XCTUnwrap(popover.test_appRow(for: "com.example.music"))
        row.test_selectDestination("office")

        XCTAssertEqual(appRouting.appRoutes.first?.destination, .device(id: "office"),
                       "the destination change reached AppRoutingController")
        XCTAssertEqual(popover.test_appRowSelectedDestinationID(for: "com.example.music"), "office",
                       "the repainted row shows the new destination")
        XCTAssertEqual(popover.test_appRowSliderDimmed(for: "com.example.music"), false,
                       "redirected ⇒ the slider is enabled (decision 3)")
    }

    /// Setting a row's volume calls through to `AppRoutingController.setVolume`
    /// (persisted). The handler deliberately does NOT `rebuild()`: a rebuild would
    /// replace the `AppRowView` mid-drag and break the live NSSlider tracking loop
    /// (the visible value tracks the slider directly during a drag). So this
    /// asserts the model call-through, not a repaint.
    func testAppRowVolumeCallsThrough() async throws {
        let appRouting = tempAppRoutingController()
        seedRoute(appRouting, bundleID: "com.example.music", displayName: "Music",
                  destination: .device(id: "office"))
        let (popover, _, _) = try await makePopover(appRouting: appRouting,
                                                     runningAppsProvider: routedApps)

        let row = try XCTUnwrap(popover.test_appRow(for: "com.example.music"))
        row.test_setVolume(42)

        XCTAssertEqual(appRouting.appRoutes.first?.volume, 42,
                       "the volume change reached AppRoutingController")
    }

    /// Removing a row calls through to `AppRoutingController.removeRoute` and
    /// repaints the card down to the empty state.
    func testAppRowRemoveCallsThroughAndRepaints() async throws {
        let appRouting = tempAppRoutingController()
        appRouting.addRoute(bundleID: "com.example.music", displayName: "Music")
        let (popover, _, _) = try await makePopover(appRouting: appRouting,
                                                     runningAppsProvider: routedApps)
        XCTAssertEqual(popover.test_appRowCount, 1)

        let row = try XCTUnwrap(popover.test_appRow(for: "com.example.music"))
        row.test_remove()

        XCTAssertTrue(appRouting.appRoutes.isEmpty, "the remove reached AppRoutingController")
        XCTAssertEqual(popover.test_appRowCount, 0, "the card repainted to the empty state")
        XCTAssertNil(popover.test_appRow(for: "com.example.music"),
                     "the removed app's row is gone")
    }

    // MARK: T3 — ± footer + single selection (LOCKED DECISION)

    /// The "−" segment starts disabled when nothing is selected.
    func testApplicationsFooterRemoveDisabledWithNoSelection() async throws {
        let appRouting = tempAppRoutingController()
        appRouting.addRoute(bundleID: "com.example.music", displayName: "Music")
        let (popover, _, _) = try await makePopover(appRouting: appRouting,
                                                     runningAppsProvider: routedApps)

        XCTAssertNil(popover.test_selectedAppBundleID, "nothing selected on a fresh build")
        XCTAssertFalse(popover.test_applicationsFooterRemoveEnabled,
                       "the − segment is disabled with no selection")
    }

    /// Selecting a row (the T1 `didRequestSelect` path) sets the host's
    /// selection, renders the row's highlight, and enables the − segment.
    func testSelectingRowEnablesFooterRemove() async throws {
        let appRouting = tempAppRoutingController()
        appRouting.addRoute(bundleID: "com.example.music", displayName: "Music")
        let (popover, _, _) = try await makePopover(appRouting: appRouting,
                                                     runningAppsProvider: routedApps)

        popover.test_selectAppRow(bundleID: "com.example.music")

        XCTAssertEqual(popover.test_selectedAppBundleID, "com.example.music")
        XCTAssertEqual(popover.test_appRowIsSelected(for: "com.example.music"), true,
                       "the selected row renders the highlight")
        XCTAssertTrue(popover.test_applicationsFooterRemoveEnabled,
                      "the − segment enables once something is selected")
    }

    /// Selection survives `rebuild()` (a device update, volume change, etc. all
    /// recreate every row) — the host re-pushes `isSelected` into the
    /// recreated row rather than losing it.
    func testSelectionSurvivesRebuild() async throws {
        let appRouting = tempAppRoutingController()
        appRouting.addRoute(bundleID: "com.example.music", displayName: "Music")
        let (popover, _, backend) = try await makePopover(appRouting: appRouting,
                                                           runningAppsProvider: routedApps)
        popover.test_selectAppRow(bundleID: "com.example.music")
        XCTAssertEqual(popover.test_selectedAppBundleID, "com.example.music")

        // Force a full rebuild via a volume change on the row (goes through
        // `appRow(_:didSetVolume:for:)` → `rebuild()`, recreating every row).
        let row = try XCTUnwrap(popover.test_appRow(for: "com.example.music"))
        row.test_setVolume(55)

        XCTAssertEqual(popover.test_selectedAppBundleID, "com.example.music",
                       "selection state on the controller survives the rebuild")
        XCTAssertEqual(popover.test_appRowIsSelected(for: "com.example.music"), true,
                       "the RECREATED row is re-pushed isSelected == true")

        // Also survives a device-driven rebuild path (`update(devices:)`).
        popover.update(devices: backend.devices)
        XCTAssertEqual(popover.test_selectedAppBundleID, "com.example.music")
        XCTAssertEqual(popover.test_appRowIsSelected(for: "com.example.music"), true)
    }

    /// Removing the selected app via the footer's "−" segment calls through to
    /// `AppRoutingController.removeRoute` and advances selection to the
    /// neighbor (LOCKED DECISION).
    func testFooterRemoveCallsRemoveRouteAndAdvancesSelection() async throws {
        let appRouting = tempAppRoutingController()
        appRouting.addRoute(bundleID: "com.example.music", displayName: "Music")
        appRouting.addRoute(bundleID: "com.example.safari", displayName: "Safari")
        let (popover, _, _) = try await makePopover(appRouting: appRouting,
                                                     runningAppsProvider: routedApps)
        popover.test_selectAppRow(bundleID: "com.example.music")

        popover.test_tapApplicationsFooterRemove()

        XCTAssertEqual(appRouting.appRoutes.map(\.bundleID), ["com.example.safari"],
                       "the − segment reached AppRoutingController.removeRoute")
        XCTAssertEqual(popover.test_selectedAppBundleID, "com.example.safari",
                       "selection advances to the neighbor that slid into the removed row's slot")
        XCTAssertEqual(popover.test_appRowIsSelected(for: "com.example.safari"), true)
        XCTAssertTrue(popover.test_applicationsFooterRemoveEnabled,
                      "still enabled — the neighbor is now selected")
    }

    /// Removing the last remaining app clears selection and disables the −
    /// segment again.
    func testFooterRemoveLastAppClearsSelection() async throws {
        let appRouting = tempAppRoutingController()
        appRouting.addRoute(bundleID: "com.example.music", displayName: "Music")
        let (popover, _, _) = try await makePopover(appRouting: appRouting,
                                                     runningAppsProvider: routedApps)
        popover.test_selectAppRow(bundleID: "com.example.music")

        popover.test_tapApplicationsFooterRemove()

        XCTAssertTrue(appRouting.appRoutes.isEmpty)
        XCTAssertNil(popover.test_selectedAppBundleID, "no neighbor left ⇒ selection clears")
        XCTAssertFalse(popover.test_applicationsFooterRemoveEnabled)
    }

    /// The − segment is a no-op (does not call `removeRoute`) when nothing is
    /// selected, matching the real disabled-segment behavior.
    func testFooterRemoveNoopWithoutSelection() async throws {
        let appRouting = tempAppRoutingController()
        appRouting.addRoute(bundleID: "com.example.music", displayName: "Music")
        let (popover, _, _) = try await makePopover(appRouting: appRouting,
                                                     runningAppsProvider: routedApps)

        popover.test_tapApplicationsFooterRemove()

        XCTAssertEqual(appRouting.appRoutes.map(\.bundleID), ["com.example.music"],
                       "nothing removed — no selection to act on")
    }

    /// The context-menu "Remove from list" path and Delete/Backspace both
    /// funnel through the SAME `removeApp` neighbor-advance logic as the
    /// footer's − segment (LOCKED DECISION — one remove API, three triggers).
    func testContextMenuRemoveAlsoAdvancesSelection() async throws {
        let appRouting = tempAppRoutingController()
        appRouting.addRoute(bundleID: "com.example.music", displayName: "Music")
        appRouting.addRoute(bundleID: "com.example.safari", displayName: "Safari")
        let (popover, _, _) = try await makePopover(appRouting: appRouting,
                                                     runningAppsProvider: routedApps)
        popover.test_selectAppRow(bundleID: "com.example.safari")

        let row = try XCTUnwrap(popover.test_appRow(for: "com.example.safari"))
        row.test_selectRemoveFromListMenuItem()

        XCTAssertEqual(appRouting.appRoutes.map(\.bundleID), ["com.example.music"])
        XCTAssertEqual(popover.test_selectedAppBundleID, "com.example.music",
                       "no next neighbor ⇒ falls back to the previous one")
    }

    /// The footer's "+" segment is wired to the SAME running-app picker the
    /// header would use — `presentAddApplicationPicker`, unchanged, so its
    /// candidate list (already covered by `testPickerExcludesAlreadyRoutedApps`)
    /// applies identically regardless of which affordance triggered it. A live
    /// `NSMenu.popUp(...)` can't be synthesized headlessly (it needs a real
    /// window), so this only proves the candidate-list plumbing the footer's
    /// picker call reuses, not the actual popup — `test_pickApp` (T-7) already
    /// covers "a pick reaches `AppRoutingController.addRoute`".
    func testFooterAddSharesPickerCandidatesWithHeaderPath() async throws {
        let appRouting = tempAppRoutingController()
        let (popover, _, _) = try await makePopover(appRouting: appRouting,
                                                     runningAppsProvider: routedApps)

        XCTAssertEqual(popover.test_availableAppsForPicker().map(\.bundleID).sorted(),
                       ["com.example.music", "com.example.safari"])
        popover.test_pickApp(bundleID: "com.example.music")
        XCTAssertEqual(appRouting.appRoutes.map(\.bundleID), ["com.example.music"],
                       "picking from the (footer-triggered) picker still reaches AppRoutingController")
    }

    /// PLAN decision 7 (silent fallback): when a routed device drops out of the
    /// available fleet, the route resets to No Redirect (the neutral/unset
    /// state — losing a device isn't a deliberate "play on this Mac" choice)
    /// and the card repaints.
    func testDeviceDropResetsMatchingRouteSilently() async throws {
        let appRouting = tempAppRoutingController()
        seedRoute(appRouting, bundleID: "com.example.music", displayName: "Music",
                  destination: .device(id: "office"))
        let (popover, _, backend) = try await makePopover(appRouting: appRouting,
                                                           runningAppsProvider: routedApps)
        XCTAssertEqual(appRouting.appRoutes.first?.destination, .device(id: "office"),
                       "route starts pointed at office")

        // Drop the routed device from the snapshot entirely (== a deviceRemoved).
        let remaining = backend.devices.filter { $0.id != "office" }
        popover.update(devices: remaining)

        XCTAssertEqual(appRouting.appRoutes.first?.destination, .noRedirect,
                       "decision 7 (revised) — the route silently fell back to No Redirect, not Current Device")
        XCTAssertEqual(popover.test_appRowSelectedDestinationID(for: "com.example.music"),
                       PopoverController.noRedirectDestinationID,
                       "the repainted row reflects the fallback")
    }

    /// A device merely going UNAVAILABLE (still present, `isAvailable == false`)
    /// also triggers the silent fallback — it is no longer a valid redirect target.
    func testDeviceUnavailableResetsMatchingRoute() async throws {
        let appRouting = tempAppRoutingController()
        seedRoute(appRouting, bundleID: "com.example.music", displayName: "Music",
                  destination: .device(id: "office"))
        let (popover, _, backend) = try await makePopover(appRouting: appRouting,
                                                           runningAppsProvider: routedApps)

        var devices = backend.devices
        if let i = devices.firstIndex(where: { $0.id == "office" }) {
            devices[i].isAvailable = false
        }
        popover.update(devices: devices)

        XCTAssertEqual(appRouting.appRoutes.first?.destination, .noRedirect,
                       "an unavailable target falls back to No Redirect, not Current Device")
    }

    /// A device update that doesn't touch any routed target leaves routes alone
    /// (the diff must not over-fire).
    func testUnrelatedDeviceUpdateLeavesRoutesAlone() async throws {
        let appRouting = tempAppRoutingController()
        seedRoute(appRouting, bundleID: "com.example.music", displayName: "Music",
                  destination: .device(id: "office"))
        let (popover, _, backend) = try await makePopover(appRouting: appRouting,
                                                           runningAppsProvider: routedApps)

        // Drop a DIFFERENT device; the office route must survive.
        let remaining = backend.devices.filter { $0.id != "homepod-bed" }
        popover.update(devices: remaining)
        XCTAssertEqual(appRouting.appRoutes.first?.destination, .device(id: "office"),
                       "dropping an unrelated device leaves the route untouched")
    }

    /// The Applications card's collapse default (C5, updated from the old
    /// "redirected app" rule): expanded on open iff ANY app route exists — even a
    /// route still on the neutral "No Redirect" default counts (the user added it
    /// on purpose). Only a truly empty route list starts collapsed.
    func testApplicationsCardExpandedOnOpenIffAnyRouteExists() async throws {
        // No routes at all ⇒ collapsed on open.
        let none = tempAppRoutingController()
        let (popoverNone, _, _) = try await makePopover(appRouting: none,
                                                        runningAppsProvider: routedApps)
        popoverNone.test_simulateOpen()
        XCTAssertEqual(popoverNone.test_isCardCollapsed(title: "Applications"), true,
                       "no routes ⇒ Applications starts collapsed")

        // A route on the neutral "No Redirect" default ⇒ NOW expanded (C5 change).
        let neutral = tempAppRoutingController()
        neutral.addRoute(bundleID: "com.example.music", displayName: "Music") // .noRedirect
        let (popoverNeutral, _, _) = try await makePopover(appRouting: neutral,
                                                           runningAppsProvider: routedApps)
        popoverNeutral.test_simulateOpen()
        XCTAssertEqual(popoverNeutral.test_isCardCollapsed(title: "Applications"), false,
                       "any route (even .noRedirect) ⇒ Applications starts expanded (C5)")

        // A redirected app ⇒ expanded on open (unchanged).
        let redirected = tempAppRoutingController()
        seedRoute(redirected, bundleID: "com.example.music", displayName: "Music",
                  destination: .device(id: "office"))
        let (popover, _, _) = try await makePopover(appRouting: redirected,
                                                     runningAppsProvider: routedApps)
        popover.test_simulateOpen()
        XCTAssertEqual(popover.test_isCardCollapsed(title: "Applications"), false,
                       "≥1 redirected app ⇒ Applications starts expanded")
    }

    // MARK: Live level dispatch (task T8, extends the T5 meter wiring)

    /// `test_pushLevel` (the `isShown`-gate-free twin of `updateLevel`) reaches
    /// the target device row's meter — asserted via `DeviceRowView.test_meterLevel`,
    /// the headless read-back the shared symbol contract adds for exactly this.
    func testPushLevelUpdatesTargetRowMeter() async throws {
        let (popover, _, _) = try await makePopover()
        popover.test_pushLevel(0.55, for: "local-mac")
        XCTAssertEqual(popover.test_deviceRow(for: "local-mac")?.test_meterLevel(), 0.55)
    }

    /// `popoverDidClose` zeroes every device row's meter (the reopen-never-shows-
    /// a-stale-bar discipline documented at the call site).
    func testPopoverDidCloseZeroesAllDeviceRowMeters() async throws {
        let (popover, _, _) = try await makePopover()
        popover.test_pushLevel(0.7, for: "local-mac")
        XCTAssertEqual(popover.test_deviceRow(for: "local-mac")?.test_meterLevel(), 0.7)

        popover.popoverDidClose(Notification(name: Notification.Name("test")))
        XCTAssertEqual(popover.test_deviceRow(for: "local-mac")?.test_meterLevel(), 0,
                       "closing the popover must reset every row's meter, not just the one just pushed to")
    }

    // MARK: Live level dispatch (task T5, Applications-row meters)

    /// `test_pushAppLevel` (the `isShown`-gate-free twin of `updateAppLevel`)
    /// reaches the target app row's meter — asserted via `AppRowView.test_meterLevel`,
    /// mirroring the device-row coverage above.
    func testPushAppLevelUpdatesTargetRowMeter() async throws {
        let appRouting = tempAppRoutingController()
        appRouting.addRoute(bundleID: "com.example.music", displayName: "Music")
        let (popover, _, _) = try await makePopover(appRouting: appRouting,
                                                     runningAppsProvider: routedApps)

        popover.test_pushAppLevel(0.55, for: "com.example.music")
        XCTAssertEqual(popover.test_appRow(for: "com.example.music")?.test_meterLevel(), 0.55)
    }

    /// `popoverDidClose` zeroes every app row's meter too (not just device rows
    /// and Main Out), so a reopen never shows a stale app-row bar either.
    func testPopoverDidCloseZeroesAllAppRowMeters() async throws {
        let appRouting = tempAppRoutingController()
        appRouting.addRoute(bundleID: "com.example.music", displayName: "Music")
        let (popover, _, _) = try await makePopover(appRouting: appRouting,
                                                     runningAppsProvider: routedApps)

        popover.test_pushAppLevel(0.7, for: "com.example.music")
        XCTAssertEqual(popover.test_appRow(for: "com.example.music")?.test_meterLevel(), 0.7)

        popover.popoverDidClose(Notification(name: Notification.Name("test")))
        XCTAssertEqual(popover.test_appRow(for: "com.example.music")?.test_meterLevel(), 0,
                       "closing the popover must reset every app row's meter, not just the one just pushed to")
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
    func testApplyRoutedAppsOverridesIntentLabelWhenNonEmpty() async throws {
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
        XCTAssertEqual(popover.test_deviceRow(for: "office")?.test_statusText, "Music",
                       "intent-based label before any live signal arrives")

        // A confirmed live signal takes over, even though it carries a
        // different string, to make the precedence unambiguous in the assertion.
        popover.applyRoutedApps(deviceID: "office", appNames: ["Music (confirmed)"])
        popover.update(devices: backend.devices)
        XCTAssertEqual(popover.test_deviceRow(for: "office")?.test_statusText, "Music (confirmed)",
                       "the confirmed live set takes precedence over the intent-based label")
    }

    /// An empty `appNames` (mapping cleared) reverts the row to the
    /// intent-based label rather than leaving it blank.
    func testApplyRoutedAppsWithEmptyListRevertsToIntentLabel() async throws {
        let appRouting = tempAppRoutingController()
        seedRoute(appRouting, bundleID: "com.example.music", displayName: "Music",
                  destination: .device(id: "office"))
        let (popover, _, backend) = try await makePopover(appRouting: appRouting,
                                                           runningAppsProvider: routedApps)

        // Re-fetch the row after every `update(devices:)` — see the note in
        // `testApplyRoutedAppsOverridesIntentLabelWhenNonEmpty` above.
        popover.applyRoutedApps(deviceID: "office", appNames: ["Music (confirmed)"])
        popover.update(devices: backend.devices)
        XCTAssertEqual(popover.test_deviceRow(for: "office")?.test_statusText, "Music (confirmed)")

        // The live mapping clears (capture stopped, or the route left this
        // device) — falls back to the intent-based label, not a blank row.
        popover.applyRoutedApps(deviceID: "office", appNames: [])
        popover.update(devices: backend.devices)
        XCTAssertEqual(popover.test_deviceRow(for: "office")?.test_statusText, "Music",
                       "an empty live mapping reverts to the intent-based label")
    }

    /// A device that drops out of the snapshot entirely and later reappears
    /// under the same id must NOT resurface a stale confirmed name from
    /// before it left (the live map isn't tied to `Device`, so it needs its
    /// own cleanup on removal).
    func testApplyRoutedAppsClearsOnDeviceRemoval() async throws {
        let (popover, _, backend) = try await makePopover()
        popover.applyRoutedApps(deviceID: "office", appNames: ["Music"])
        popover.update(devices: backend.devices)
        XCTAssertEqual(popover.test_deviceRow(for: "office")?.test_statusText, "Music")

        // The device drops off the network entirely.
        popover.update(devices: backend.devices.filter { $0.id != "office" })
        XCTAssertNil(popover.test_deviceRow(for: "office"))

        // It reappears with no route and no fresh live signal — must show
        // nothing, not the stale "Music" from before it left.
        popover.update(devices: backend.devices)
        XCTAssertNil(popover.test_deviceRow(for: "office")?.test_statusText,
                     "a stale live mapping must not resurface after the device left and returned")
    }

    /// The `MockBackend` offline fixture (`test_emitRoutedApps`) round-trips
    /// through the real `BackendEvent` channel exactly the way `AppDelegate`
    /// would consume it in production, ending with the row rendering the live
    /// label — proving `popover-harness`/`popover-snapshot` can demonstrate T9
    /// without a real per-app-routing backend.
    func testMockBackendFixtureRoundTripsToDeviceRowLabel() async throws {
        let (popover, _, backend) = try await makePopover()

        let stream = backend.makeEventStream()
        let expectation = expectation(description: "routedApps event observed")
        let task = Task {
            for await event in stream {
                if case .routedApps(let deviceID, let appNames) = event {
                    await popover.applyRoutedApps(deviceID: deviceID, appNames: appNames)
                    expectation.fulfill()
                    break
                }
            }
        }
        backend.test_emitRoutedApps(deviceID: "office", appNames: ["Music"])
        await fulfillment(of: [expectation], timeout: 2)
        task.cancel()

        popover.update(devices: backend.devices)
        XCTAssertEqual(popover.test_deviceRow(for: "office")?.test_statusText, "Music",
                       "the fixture's event reached the row via the same plumbing AppDelegate uses")
    }

    // MARK: V2 — Devices card empty-state placeholder

    /// With no devices discovered, the Devices card still builds and shows the
    /// "Looking for devices…" placeholder; once devices arrive it disappears.
    func testDevicesCardEmptyStatePlaceholder() async throws {
        let (popover, _, backend) = try await makePopover()
        // Devices present initially ⇒ no placeholder, card exists.
        XCTAssertFalse(popover.test_devicesPlaceholderShown, "devices present ⇒ no placeholder")
        XCTAssertNotNil(popover.test_isCardCollapsed(title: "Devices"), "the Devices card exists")

        // Clear the fleet ⇒ card still present, placeholder shown.
        popover.update(devices: [])
        XCTAssertNotNil(popover.test_isCardCollapsed(title: "Devices"),
                        "the Devices card is still built when empty (V2)")
        XCTAssertTrue(popover.test_devicesPlaceholderShown, "no devices ⇒ placeholder shown")
        XCTAssertEqual(popover.test_deviceSectionRowCount, 0, "no interactive device rows")

        // Devices arrive again ⇒ placeholder gone.
        popover.update(devices: backend.devices)
        XCTAssertFalse(popover.test_devicesPlaceholderShown, "devices arrived ⇒ placeholder gone")
        XCTAssertEqual(popover.test_deviceSectionRowCount, 7, "device rows restored")
    }

    // MARK: V11 — Applications card empty-state placeholder

    /// With no rendered app routes the Applications card shows the "No apps
    /// routed…" placeholder; adding a route removes it.
    func testApplicationsCardEmptyStatePlaceholder() async throws {
        let appRouting = tempAppRoutingController()
        let (popover, _, _) = try await makePopover(appRouting: appRouting,
                                                    runningAppsProvider: routedApps)
        XCTAssertTrue(popover.test_applicationsPlaceholderShown, "no routes ⇒ placeholder shown")
        XCTAssertEqual(popover.test_appRowCount, 0, "no app rows")

        popover.test_pickApp(bundleID: "com.example.music")
        XCTAssertFalse(popover.test_applicationsPlaceholderShown, "a route exists ⇒ placeholder gone")
        XCTAssertEqual(popover.test_appRowCount, 1, "one app row now")
    }

    // MARK: C6 — Add-application picker empty state

    /// When no unrouted running apps remain, the picker shows a single disabled
    /// "No applications available" item rather than a blank menu.
    func testAddApplicationPickerShowsDisabledItemWhenEmpty() async throws {
        let appRouting = tempAppRoutingController()
        // Route BOTH provider apps so the picker's candidate list is empty.
        appRouting.addRoute(bundleID: "com.example.music", displayName: "Music")
        appRouting.addRoute(bundleID: "com.example.safari", displayName: "Safari")
        let (popover, _, _) = try await makePopover(appRouting: appRouting,
                                                    runningAppsProvider: routedApps)
        XCTAssertEqual(popover.test_addApplicationPickerTitles(), ["No applications available"],
                       "empty candidate list ⇒ one disabled placeholder item")

        // Remove one route ⇒ that app becomes available again.
        popover.test_selectAppRow(bundleID: "com.example.music")
        popover.test_tapApplicationsFooterRemove()
        XCTAssertEqual(popover.test_addApplicationPickerTitles(), ["Music"],
                       "a freed-up app reappears as a selectable item")
    }

    // MARK: A1 — dormant Devices card (group target)

    /// Under a saved-group Main Out target the Devices card is DORMANT: it shows
    /// the "Inactive — Audio Out is using '<group>'" note and dims every
    /// membership checkbox (still clickable). Switching back to Selected Devices
    /// clears both live.
    func testDormantDevicesCardNoteAndDimming() async throws {
        let (popover, controller, _) = try await makePopover()
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        popover.test_saveCurrentSetup(); await drain()
        let group = controller.groups[0]

        // Point Main Out at the group ⇒ dormant.
        popover.test_selectMainOut(.group(id: group.id)); await drain()
        XCTAssertEqual(popover.test_cardNoteTexts(title: "Devices"),
                       ["Inactive — Audio Out is using '\(group.name)'"],
                       "dormant card carries the group's name in its note")
        XCTAssertEqual(popover.test_deviceRowSelectionDimmed(id: "office"), true,
                       "a device checkbox dims under a group target")
        XCTAssertEqual(popover.test_deviceRow(for: "office")?.test_isEnabledOn ?? false, true,
                       "office is still a member — dim is cosmetic, the checkbox stays interactive")

        // Back to Selected Devices ⇒ no note, no dim.
        popover.test_selectMainOut(.selectedDevices); await drain()
        XCTAssertEqual(popover.test_cardNoteTexts(title: "Devices"), [],
                       "no dormancy note under Selected Devices")
        XCTAssertEqual(popover.test_deviceRowSelectionDimmed(id: "office"), false,
                       "checkboxes undim under Selected Devices")
    }

    // MARK: A2 — live Selected Devices count

    /// The "Selected Devices (n)" title tracks the count of checked rows and
    /// updates as toggles change it — visible on both the dropdown item and the
    /// popup's collapsed title.
    func testSelectedDevicesCountUpdatesOnToggle() async throws {
        let (popover, _, _) = try await makePopover()
        // Default selection is {local-mac} ⇒ 1.
        XCTAssertEqual(popover.test_mainOutRow.test_selectedTitle, "Selected Devices (1)")

        // Toggle office on (auto-swap drops local) ⇒ {office} still 1.
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        XCTAssertEqual(popover.test_mainOutRow.test_selectedTitle, "Selected Devices (1)",
                       "auto-swap kept the count at 1")

        // Add a second AirPlay device ⇒ {office, homepod-bed} = 2.
        _ = popover.test_toggleDeviceEnabled(deviceID: "homepod-bed", on: true)
        XCTAssertEqual(popover.test_mainOutRow.test_selectedTitle, "Selected Devices (2)",
                       "the count rose to 2 on the toggle")
        // The full count lives in the menu title; the collapsed button shows the
        // shorter "Selected (n)" so the count survives the fixed trailing width.
        XCTAssertEqual(popover.test_mainOutRow.test_buttonTitle, "Selected (2)",
                       "the collapsed button shows the count in the short form")

        // Remove one ⇒ back to 1.
        _ = popover.test_toggleDeviceEnabled(deviceID: "homepod-bed", on: false)
        XCTAssertEqual(popover.test_mainOutRow.test_selectedTitle, "Selected Devices (1)",
                       "the count fell to 1 on the untoggle")
    }

    // MARK: A4 — auto-swap flashes the local row

    /// Turning an AirPlay device ON while the Mac is the sole selected member
    /// auto-unchecks the Mac; the local row flashes once (a no-op under Reduce
    /// Motion, per the same mapping `DeviceRowConnectionStateTests` uses).
    func testAutoSwapFlashesLocalRow() async throws {
        let (popover, _, _) = try await makePopover()
        XCTAssertEqual(popover.test_deviceRowFlashing(id: "local-mac"), false,
                       "no flash before the swap")

        let result = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        XCTAssertTrue(result.autoSwappedCurrentDevice, "the toggle auto-swapped the local device")
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        XCTAssertEqual(popover.test_deviceRowFlashing(id: "local-mac"), !reduceMotion,
                       "the auto-unchecked local row flashes (unless Reduce Motion)")
    }

    // MARK: B2 — dismissible diagnosis panel + episode semantics

    /// The ✕ tears the panel down.
    func testDismissRemovesDiagnosisPanel() async throws {
        let (popover, _, backend) = try await makeScriptedPopover(scripts: [
            "office": ConnectScript(attempts: [.fail(after: 0.05, ConnectionFailure(cause: .timedOut))]),
        ])
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        try await waitForConnectionState(backend, id: "office", isFailed)
        popover.update(devices: backend.devices)
        let panel = try XCTUnwrap(popover.test_diagnosisPanel(for: "office"), "auto-expanded")
        panel.test_tapDismiss()
        XCTAssertNil(popover.test_diagnosisPanel(for: "office"), "the ✕ removed the panel")
    }

    /// A dismissed panel is NOT resurrected by a mid-episode repaint/update while
    /// the device stays `.failed`.
    func testDismissedPanelSurvivesRepaint() async throws {
        let (popover, _, backend) = try await makeScriptedPopover(scripts: [
            "office": ConnectScript(attempts: [.fail(after: 0.05, ConnectionFailure(cause: .notResponding))]),
        ])
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        try await waitForConnectionState(backend, id: "office", isFailed)
        popover.update(devices: backend.devices)
        try XCTUnwrap(popover.test_diagnosisPanel(for: "office")).test_tapDismiss()
        XCTAssertNil(popover.test_diagnosisPanel(for: "office"))

        // A plain repaint (still .failed) and a diagnosis-replacement update must
        // both leave it dismissed.
        popover.update(devices: backend.devices)
        XCTAssertNil(popover.test_diagnosisPanel(for: "office"), "repaint didn't resurrect it")
        var replaced = backend.devices
        for i in replaced.indices where replaced[i].id == "office" {
            replaced[i].connectionState = .failed(ConnectionFailure(cause: .vanished))
        }
        popover.update(devices: replaced)
        XCTAssertNil(popover.test_diagnosisPanel(for: "office"),
                     "an in-episode diagnosis replacement didn't resurrect a dismissed panel")
    }

    /// Leaving `.failed` (→ `.connected`) ends the episode and clears the
    /// dismissal, so a genuinely NEW failure episode re-expands the panel even
    /// though the prior one was dismissed.
    func testLeavingFailedClearsDismissalAndNewEpisodeReExpands() async throws {
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
        try XCTUnwrap(popover.test_diagnosisPanel(for: "office")).test_tapDismiss()
        XCTAssertNil(popover.test_diagnosisPanel(for: "office"))

        // Retry by re-adding to Selected Devices (the panel is dismissed, so its
        // "Try again" button is gone — re-toggling IS the retry path). Connects
        // ⇒ leaves .failed ⇒ clears the dismissal.
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        try await waitForConnectionState(backend, id: "office") { $0 == .connected }
        popover.update(devices: backend.devices)

        // Episode 2: a fresh toggle-on fails again ⇒ re-expands.
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: false)
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        try await waitForConnectionState(backend, id: "office", isFailed)
        popover.update(devices: backend.devices)
        XCTAssertNotNil(popover.test_diagnosisPanel(for: "office"),
                        "a NEW failure episode re-expands despite the earlier dismissal")
    }

    /// "Try again → fails again" (`.failed → .connecting → .failed` in one
    /// gesture) counts as a new episode and re-surfaces a dismissed panel.
    func testRetryThatFailsAgainReExpandsDismissedPanel() async throws {
        let (popover, _, backend) = try await makeScriptedPopover(scripts: [
            "office": ConnectScript(attempts: [
                .fail(after: 0.05, ConnectionFailure(cause: .notResponding)),
                .fail(after: 0.5, ConnectionFailure(cause: .timedOut)),
            ]),
        ])
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        try await waitForConnectionState(backend, id: "office", isFailed)
        popover.update(devices: backend.devices)
        try XCTUnwrap(popover.test_diagnosisPanel(for: "office")).test_tapDismiss()
        XCTAssertNil(popover.test_diagnosisPanel(for: "office"))

        // Retry by re-adding to Selected Devices (the dismissed panel's "Try
        // again" is gone — re-toggling IS the retry path). Record the
        // intermediate .connecting so the next .failed reads as a fresh edge (a
        // NEW episode), then let it fail again.
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        try await waitForConnectionState(backend, id: "office") {
            if case .connecting = $0 { return true }; return false
        }
        popover.update(devices: backend.devices)
        XCTAssertNil(popover.test_diagnosisPanel(for: "office"),
                     "still dismissed while the retry is in flight")
        try await waitForConnectionState(backend, id: "office", isFailed)
        popover.update(devices: backend.devices)
        XCTAssertNotNil(popover.test_diagnosisPanel(for: "office"),
                        "the retry failing again re-surfaces the panel")
    }

    // MARK: F1 — Devices "Save as group" header accessory

    /// The Devices card's accessory saves the current selection as a group; firing
    /// it never collapses the card, and its enabled state tracks
    /// `canSaveCurrentSetup`.
    func testDevicesSaveGroupAccessoryCreatesGroupWithoutCollapsing() async throws {
        let (popover, controller, _) = try await makePopover()
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        XCTAssertEqual(popover.test_cardAccessoryEnabled(title: "Devices"), true,
                       "a non-empty, not-yet-saved selection ⇒ accessory enabled")
        let wasCollapsed = popover.test_isCardCollapsed(title: "Devices")

        XCTAssertTrue(popover.test_fireCardAccessory(title: "Devices"), "the accessory fired")
        XCTAssertEqual(controller.groups.count, 1, "firing the accessory created a group")
        XCTAssertEqual(popover.test_isCardCollapsed(title: "Devices"), wasCollapsed,
                       "the accessory click did NOT collapse the card")
        // The just-saved selection now equals a group ⇒ accessory disables (dedup).
        XCTAssertEqual(popover.test_cardAccessoryEnabled(title: "Devices"), false,
                       "selection already saved as a group ⇒ accessory disables in place")
    }

    // MARK: V14 — keyboard selection movement (host half)

    /// ↑/↓ move the app-row selection through `appRoutes` order, clamped at the
    /// ends; the selection survives the repaint and the ± footer's remove stays
    /// enabled throughout.
    func testMoveAppSelectionUpDownWithClamping() async throws {
        let appRouting = tempAppRoutingController()
        appRouting.addRoute(bundleID: "com.example.music", displayName: "Music")
        appRouting.addRoute(bundleID: "com.example.safari", displayName: "Safari")
        let (popover, _, _) = try await makePopover(appRouting: appRouting,
                                                    runningAppsProvider: routedApps)
        popover.test_selectAppRow(bundleID: "com.example.music")
        XCTAssertTrue(popover.test_applicationsFooterRemoveEnabled, "remove enabled with a selection")

        // Down ⇒ next route.
        popover.test_appRow(for: "com.example.music")?.test_pressDownArrow()
        XCTAssertEqual(popover.test_selectedAppBundleID, "com.example.safari", "moved down to Safari")
        XCTAssertEqual(popover.test_appRowIsSelected(for: "com.example.safari"), true,
                       "selection survived the repaint on the new row")
        XCTAssertTrue(popover.test_applicationsFooterRemoveEnabled, "remove stays enabled")

        // Down again at the end ⇒ clamps (no wrap).
        popover.test_appRow(for: "com.example.safari")?.test_pressDownArrow()
        XCTAssertEqual(popover.test_selectedAppBundleID, "com.example.safari", "clamped at the last row")

        // Up ⇒ previous route.
        popover.test_appRow(for: "com.example.safari")?.test_pressUpArrow()
        XCTAssertEqual(popover.test_selectedAppBundleID, "com.example.music", "moved up to Music")

        // Up again at the start ⇒ clamps.
        popover.test_appRow(for: "com.example.music")?.test_pressUpArrow()
        XCTAssertEqual(popover.test_selectedAppBundleID, "com.example.music", "clamped at the first row")
        XCTAssertTrue(popover.test_applicationsFooterRemoveEnabled, "remove enabled after all moves")
    }

    // MARK: A3 — destination microcopy subtitles

    /// The "No Redirect" and "Current Device" destination entries carry tooltip
    /// subtitles; AirPlay device entries get none.
    func testDestinationEntriesCarrySubtitleTooltips() async throws {
        let appRouting = tempAppRoutingController()
        appRouting.addRoute(bundleID: "com.example.music", displayName: "Music")
        let (popover, _, _) = try await makePopover(appRouting: appRouting,
                                                    runningAppsProvider: routedApps)
        let row = try XCTUnwrap(popover.test_appRow(for: "com.example.music"))

        let noRedirect = try XCTUnwrap(
            row.test_destinationPopUpMenuItem(forDestinationID: PopoverController.noRedirectDestinationID))
        XCTAssertEqual(noRedirect.toolTip, "Follows the system audio output",
                       "No Redirect carries its clarifying tooltip")
        let currentDevice = try XCTUnwrap(
            row.test_destinationPopUpMenuItem(forDestinationID: PopoverController.currentDeviceDestinationID))
        XCTAssertEqual(currentDevice.toolTip, "Plays locally with its own volume",
                       "Current Device carries its clarifying tooltip")
        // An AirPlay device entry has no subtitle.
        let airplay = try XCTUnwrap(row.test_destinationPopUpMenuItem(forDestinationID: "office"))
        XCTAssertNil(airplay.toolTip, "AirPlay device entries carry no subtitle tooltip")
    }
}

private actor PopoverTestCountBox {
    private var count = 0
    func increment() -> Int { count += 1; return count }
}
