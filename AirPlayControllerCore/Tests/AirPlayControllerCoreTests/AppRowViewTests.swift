// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Alec Henderson and contributors.

import XCTest
import AppKit
@testable import AirPlayControllerSharedUI

/// Offscreen structural tests for `AppRowView` (PLAN-POPOVER-ROUTING.md task
/// T-6). Neither a headless process nor an offscreen view synthesizes the
/// mouse events a real slider drag / popup pick / button click needs, so —
/// exactly like `PopoverControllerTests` — these drive the `test_*` hooks that
/// call the same delegate methods the real controls call.
final class AppRowViewTests: XCTestCase {

    private final class RecordingDelegate: AppRowView.Delegate {
        var lastVolume: (appID: String, volume: Int)?
        var lastDestination: (appID: String, destinationID: String)?
        var removedAppID: String?

        func appRow(_ row: AppRowView, didSetVolume volume: Int, for appID: String) {
            lastVolume = (appID, volume)
        }
        func appRow(_ row: AppRowView, didSelectDestination destinationID: String, for appID: String) {
            lastDestination = (appID, destinationID)
        }
        func appRow(_ row: AppRowView, didRemoveFor appID: String) {
            removedAppID = appID
        }
    }

    private func makeDestinations() -> [AppRowView.Destination] {
        [
            AppRowView.Destination(id: "local", title: "Current Device", isLocal: true,
                                   symbolName: "laptopcomputer"),
            AppRowView.Destination(id: "device-1", title: "Living Room", isLocal: false,
                                   symbolName: "airplayaudio"),
            AppRowView.Destination(id: "device-2", title: "Kitchen", isLocal: false,
                                   symbolName: "airplayaudio"),
        ]
    }

    private func makeRow(selected: String = "local") -> (AppRowView, RecordingDelegate) {
        let row = AppRowView()
        let delegate = RecordingDelegate()
        row.delegate = delegate
        row.apply(AppRowView.Configuration(
            appID: "com.example.app",
            name: "Example App",
            icon: nil,
            volume: 42,
            selectedDestinationID: selected,
            destinations: makeDestinations()
        ))
        return (row, delegate)
    }

    // MARK: Menu structure (LOCKED DECISION 4 — two sections, no Groups)

    func testMenuHasExactlyTwoSections() {
        let (row, _) = makeRow()
        let titles = row.test_menuTitles
        XCTAssertTrue(titles.contains("CURRENT DEVICE"), "expected a 'Current Device' header, got \(titles)")
        XCTAssertTrue(titles.contains("AIRPLAY DEVICES"), "expected an 'AirPlay Devices' header, got \(titles)")
        // Exactly the two headers + three destination entries, no Groups section.
        XCTAssertEqual(titles.count, 5, "unexpected menu items: \(titles)")
        XCTAssertFalse(titles.contains { $0.uppercased().contains("GROUP") },
                       "Groups must not appear in the app row's destination menu (decision 4)")
    }

    func testMenuSectionOrderIsCurrentDeviceThenAirPlayDevices() {
        let (row, _) = makeRow()
        let titles = row.test_menuTitles
        let currentIndex = titles.firstIndex(of: "CURRENT DEVICE")
        let airplayIndex = titles.firstIndex(of: "AIRPLAY DEVICES")
        XCTAssertNotNil(currentIndex)
        XCTAssertNotNil(airplayIndex)
        XCTAssertLessThan(currentIndex!, airplayIndex!, "Current Device section must come first")
    }

    func testSelectedDestinationIsCheckmarked() {
        let (row, _) = makeRow(selected: "device-1")
        XCTAssertEqual(row.test_selectedDestinationID, "device-1")
    }

    // MARK: Delegate firing

    func testSelectingDestinationFiresDelegate() {
        let (row, delegate) = makeRow(selected: "local")
        row.test_selectDestination("device-2")
        XCTAssertEqual(delegate.lastDestination?.appID, "com.example.app")
        XCTAssertEqual(delegate.lastDestination?.destinationID, "device-2")
    }

    func testSettingVolumeFiresDelegate() {
        let (row, delegate) = makeRow()
        row.test_setVolume(77)
        XCTAssertEqual(delegate.lastVolume?.appID, "com.example.app")
        XCTAssertEqual(delegate.lastVolume?.volume, 77)
        XCTAssertEqual(row.test_volume, 42, "test_setVolume only fires the delegate; a real reapply drives the model")
    }

    func testRemoveFiresDelegate() {
        let (row, delegate) = makeRow()
        row.test_remove()
        XCTAssertEqual(delegate.removedAppID, "com.example.app")
    }

    // MARK: Slider dimming (LOCKED DECISION 3)

    func testSliderDimmedWhenDestinationIsCurrentDevice() {
        let (row, _) = makeRow(selected: "local")
        XCTAssertTrue(row.test_isSliderDimmed, "slider must dim while destination is Current Device")
    }

    func testSliderNotDimmedWhenRedirected() {
        let (row, _) = makeRow(selected: "device-1")
        XCTAssertFalse(row.test_isSliderDimmed, "slider must be enabled once redirected to an AirPlay device")
    }

    func testSliderAlwaysVisibleRegardlessOfDestination() {
        // LOCKED DECISION 3: the slider is ALWAYS visible, only dimmed — never
        // hidden. `AppRowView` has no isHidden toggle on the slider at all; this
        // asserts both states still report a live volume via the hook.
        let (localRow, _) = makeRow(selected: "local")
        XCTAssertEqual(localRow.test_volume, 42)
        let (redirectedRow, _) = makeRow(selected: "device-1")
        XCTAssertEqual(redirectedRow.test_volume, 42)
    }

    // MARK: Hover / remove affordance discipline (mirrors DeviceRowView, PLAN risk 2)

    func testRemoveButtonHiddenUntilHover() {
        let (row, _) = makeRow()
        XCTAssertFalse(row.test_isRemoveButtonVisible)
        row.test_simulateMouseEntered()
        XCTAssertTrue(row.test_isRemoveButtonVisible)
    }

    func testHoverReconcilesWhenPointerLeavesWithoutExitEvent() {
        let (row, _) = makeRow()
        row.test_simulateMouseEntered()
        XCTAssertTrue(row.test_isRemoveButtonVisible)
        // The dead-zone case: no `mouseExited:` delivered, only a reconcile.
        row.test_reconcileHover(pointerInside: false)
        XCTAssertFalse(row.test_isRemoveButtonVisible)
    }

    func testApplyClearsStaleHover() {
        let (row, _) = makeRow()
        row.test_simulateMouseEntered()
        XCTAssertTrue(row.test_isRemoveButtonVisible)
        row.apply(AppRowView.Configuration(
            appID: "com.example.app", name: "Example App", icon: nil, volume: 50,
            selectedDestinationID: "local", destinations: makeDestinations()
        ))
        XCTAssertFalse(row.test_isRemoveButtonVisible, "a model refresh must clear a transient hover (T-U8 fix)")
    }

    // MARK: AddApplicationRowView

    func testAddApplicationRowFiresCallback() {
        let row = AddApplicationRowView()
        var fired = false
        row.onAdd = { fired = true }
        row.test_tap()
        XCTAssertTrue(fired)
    }
}
