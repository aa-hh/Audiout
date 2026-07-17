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
        let title = "Selected Devices"
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
        let title = "Selected Devices"

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
        let title = "Selected Devices"
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
        let title = "Selected Devices"
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
        XCTAssertEqual(popover.test_isCardCollapsed(title: "Selected Devices"), false)
    }

    /// A manual toggle during one open is discarded on the NEXT open — defaults
    /// are recomputed rather than remembered (PLAN §B: "manual toggles never
    /// persist").
    func testManualToggleDiscardedOnReopen() async throws {
        let (popover, _, _) = try await makePopover()
        popover.test_simulateOpen()
        popover.test_toggleCard(title: "Selected Devices", animated: false)
        XCTAssertEqual(popover.test_isCardCollapsed(title: "Selected Devices"), true,
                       "manual toggle collapsed it this open")

        // Simulate close + reopen: defaults are recomputed, discarding the toggle.
        popover.test_simulateOpen()
        XCTAssertEqual(popover.test_isCardCollapsed(title: "Selected Devices"), false,
                       "reopening resets to the default — the manual toggle didn't persist")
    }

    /// A rebuild WITHIN one open (e.g. a backend device update) must preserve
    /// the current transient collapse state, not reset it back to the default.
    func testMidOpenRebuildPreservesTransientState() async throws {
        let (popover, _, backend) = try await makePopover()
        popover.test_simulateOpen()
        popover.test_toggleCard(title: "Selected Devices", animated: false)
        XCTAssertEqual(popover.test_isCardCollapsed(title: "Selected Devices"), true)

        // A mid-open rebuild triggered by a backend event (not a reopen).
        popover.update(devices: backend.devices)
        popover.rebuild()
        XCTAssertEqual(popover.test_isCardCollapsed(title: "Selected Devices"), true,
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
        XCTAssertEqual(appRouting.appRoutes.first?.destination, .currentDevice,
                       "a new route defaults to Current Device (decision 8 — no redirect)")
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
    /// `.currentDevice`/vol 100, then mutates), so tests can start with a route
    /// already redirected / at a chosen volume.
    private func seedRoute(_ appRouting: AppRoutingController, bundleID: String, displayName: String,
                           destination: AppRouteDestination = .currentDevice, volume: Int = 100) {
        appRouting.addRoute(bundleID: bundleID, displayName: displayName)
        if destination != .currentDevice { appRouting.setDestination(destination, for: bundleID) }
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

    /// A row's destination menu splits into a "Current Device" section (the local
    /// device) and an "AirPlay Devices" section (the available non-local fleet),
    /// with the sentinel current-device id selected for a `.currentDevice` route
    /// and the slider dimmed (decision 3).
    func testAppRowDestinationMenuStructureAndLocalDimming() async throws {
        let appRouting = tempAppRoutingController()
        appRouting.addRoute(bundleID: "com.example.music", displayName: "Music")
        let (popover, _, _) = try await makePopover(appRouting: appRouting,
                                                     runningAppsProvider: routedApps)

        let titles = try XCTUnwrap(popover.test_appRowDestinationTitles(for: "com.example.music"))
        XCTAssertEqual(titles.first, "CURRENT DEVICE",
                       "the menu leads with the Current Device section header")
        XCTAssertTrue(titles.contains("AIRPLAY DEVICES"),
                      "the menu has an AirPlay Devices section (decision 4 — no Groups)")
        XCTAssertTrue(titles.contains("MacBook Pro Speakers"),
                      "the Current Device entry carries the local device's name")
        XCTAssertTrue(titles.contains("Office"), "an available AirPlay device is offered")

        XCTAssertEqual(popover.test_appRowSelectedDestinationID(for: "com.example.music"),
                       PopoverController.currentDeviceDestinationID,
                       "a .currentDevice route selects the sentinel Current Device entry")
        XCTAssertEqual(popover.test_appRowSliderDimmed(for: "com.example.music"), true,
                       "decision 3 — the slider is dimmed while the app plays locally")
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

    /// Setting a row's volume calls through to `AppRoutingController.setVolume` and
    /// repaints.
    func testAppRowVolumeCallsThroughAndRepaints() async throws {
        let appRouting = tempAppRoutingController()
        seedRoute(appRouting, bundleID: "com.example.music", displayName: "Music",
                  destination: .device(id: "office"))
        let (popover, _, _) = try await makePopover(appRouting: appRouting,
                                                     runningAppsProvider: routedApps)

        let row = try XCTUnwrap(popover.test_appRow(for: "com.example.music"))
        row.test_setVolume(42)

        XCTAssertEqual(appRouting.appRoutes.first?.volume, 42,
                       "the volume change reached AppRoutingController")
        XCTAssertEqual(popover.test_appRow(for: "com.example.music")?.test_volume, 42,
                       "the repainted row shows the new volume")
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

    /// PLAN decision 7 (silent fallback): when a routed device drops out of the
    /// available fleet, the route resets to Current Device and the card repaints.
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

        XCTAssertEqual(appRouting.appRoutes.first?.destination, .currentDevice,
                       "decision 7 — the route silently fell back to Current Device")
        XCTAssertEqual(popover.test_appRowSelectedDestinationID(for: "com.example.music"),
                       PopoverController.currentDeviceDestinationID,
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

        XCTAssertEqual(appRouting.appRoutes.first?.destination, .currentDevice,
                       "an unavailable target falls back to Current Device")
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

    /// The Applications card's collapse default (extends the T-5 tests to the real
    /// card): expanded on open iff `routedAppCount > 0`.
    func testApplicationsCardExpandedOnOpenIffRedirected() async throws {
        // No redirected app ⇒ collapsed on open.
        let empty = tempAppRoutingController()
        empty.addRoute(bundleID: "com.example.music", displayName: "Music") // .currentDevice ⇒ not redirected
        let (popoverEmpty, _, _) = try await makePopover(appRouting: empty,
                                                          runningAppsProvider: routedApps)
        popoverEmpty.test_simulateOpen()
        XCTAssertEqual(popoverEmpty.test_isCardCollapsed(title: "Applications"), true,
                       "no redirected app (routedAppCount == 0) ⇒ Applications starts collapsed")

        // At least one redirected app ⇒ expanded on open.
        let redirected = tempAppRoutingController()
        seedRoute(redirected, bundleID: "com.example.music", displayName: "Music",
                  destination: .device(id: "office"))
        let (popover, _, _) = try await makePopover(appRouting: redirected,
                                                     runningAppsProvider: routedApps)
        popover.test_simulateOpen()
        XCTAssertEqual(popover.test_isCardCollapsed(title: "Applications"), false,
                       "≥1 redirected app (routedAppCount > 0) ⇒ Applications starts expanded")
    }
}

private actor PopoverTestCountBox {
    private var count = 0
    func increment() -> Int { count += 1; return count }
}
