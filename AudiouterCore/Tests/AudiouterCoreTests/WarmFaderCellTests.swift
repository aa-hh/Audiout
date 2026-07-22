// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
import AppKit
@testable import AudiouterCore
@testable import AudiouterPopoverUI
@testable import AudiouterSharedUI

/// The **Warm Signal fader skin** (`WarmFaderCell`, spec §5 "we redraw only
/// the slider track/knob look"): the drawing-only `NSSliderCell` swap on the
/// three row volume sliders. Covers (1) the skin is INSTALLED on all three
/// rows; (2) the engaged (gold-gradient) fill tracks the SAME route-armed
/// predicate the corner dot renders — device row (§3.3 truth table edges),
/// Main Out (connected ∧ !muted), app row (routed ∧ running); (3) NSSlider
/// BEHAVIOR stays stock after the cell swap — `isContinuous`, min/max, and
/// the target/action dispatch all survive; (4) the drawing is deterministic
/// under `cacheDisplay` (byte-identical double render, both appearances).
final class WarmFaderCellTests: XCTestCase {

    // MARK: Helpers

    private func makeDevice(connectionState: ConnectionState = .connected,
                            isMuted: Bool = false,
                            isAvailable: Bool = true) -> Device {
        Device(id: "dev-1", name: "Test Speaker", kind: .homePod,
               isAvailable: isAvailable, isMuted: isMuted,
               connectionState: connectionState)
    }

    private func makeMainOutOptions() -> [MainOutRowView.Option] {
        [
            .init(title: "Destination", isHeader: true),
            .init(title: "Selected Devices", target: .selectedDevices, buttonTitle: "Selected"),
        ]
    }

    private func makeAppConfiguration(selected: String, isRunning: Bool = true)
        -> AppRowView.Configuration {
        AppRowView.Configuration(
            appID: "com.example.app", name: "Example App", icon: nil, volume: 42,
            selectedDestinationID: selected,
            destinations: [
                AppRowView.Destination(id: "no-redirect", title: "Follows main output",
                                       isLocal: true, symbolName: nil, isStandalone: true),
                AppRowView.Destination(id: "device-1", title: "Living Room", isLocal: false,
                                       symbolName: "airplayaudio"),
            ],
            isRunning: isRunning)
    }

    // MARK: Skin installed (structural)

    func testAllThreeRowsWearTheWarmFaderSkin() {
        XCTAssertTrue(DeviceRowView(device: makeDevice()).test_hasWarmFaderSkin,
                      "DeviceRowView's slider wears WarmFaderCell")
        XCTAssertTrue(MainOutRowView().test_hasWarmFaderSkin,
                      "MainOutRowView's master slider wears WarmFaderCell")
        XCTAssertTrue(AppRowView().test_hasWarmFaderSkin,
                      "AppRowView's slider wears WarmFaderCell")
    }

    // MARK: Device row — engaged fill tracks the §3.3 armed predicate

    func testDeviceFaderEngagedWhenRouteArmed() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: true, controllable: true)
        XCTAssertTrue(row.test_routeArmed)
        XCTAssertTrue(row.test_isFaderEngaged,
                      "armed ∧ enabled ⇒ the gold gradient fill renders")
    }

    func testDeviceFaderNeutralWhenNotMember() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: false, controllable: true)
        XCTAssertFalse(row.test_isFaderEngaged,
                       "a non-member's fader keeps the neutral warm fill")
    }

    func testDeviceFaderNeutralWhenNotConnected() {
        let row = DeviceRowView(device: makeDevice(connectionState: .connecting))
        row.apply(makeDevice(connectionState: .connecting), selected: true, controllable: true)
        XCTAssertFalse(row.test_isFaderEngaged,
                       "not yet connected ⇒ no gold fill (same truth as the dot)")
    }

    func testDeviceFaderNeutralWhenRowMuted() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(isMuted: true), selected: true, controllable: true)
        XCTAssertFalse(row.test_isFaderEngaged, "row mute disarms the gold fill")
        XCTAssertTrue(row.test_isSliderEnabled,
                      "…but the slider stays live (A5 — mute ≠ frozen volume)")
    }

    func testDeviceFaderNeutralWhenMasterMuted() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: true, controllable: true, masterMuted: true)
        XCTAssertFalse(row.test_isFaderEngaged, "master mute drains every device fader")
    }

    func testDeviceFaderEngagedByLiveFeedEvenWhenMuted() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(isMuted: true), selected: false, controllable: true,
                  liveAppNames: ["Music"])
        XCTAssertTrue(row.test_routeArmed)
        XCTAssertTrue(row.test_isFaderEngaged,
                      "a confirmed live per-app feed arms the fader (redirects bypass the mutes)")
    }

    func testDeviceFaderNeverEngagedWhileSliderDisabled() {
        // A live-feed row that is NOT controllable: armed predicate true, but
        // the slider is disabled — the engaged gate requires BOTH.
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: true, controllable: false, liveAppNames: ["Music"])
        XCTAssertTrue(row.test_routeArmed)
        XCTAssertFalse(row.test_isSliderEnabled)
        XCTAssertFalse(row.test_isFaderEngaged,
                       "a disabled slider never renders the engaged fill")
    }

    // MARK: Main Out row — engaged = connected ∧ !muted (the dot's predicate)

    func testMainOutFaderEngagedWhenTargetLiveAndUnmuted() {
        let row = MainOutRowView()
        row.apply(options: makeMainOutOptions(), current: .selectedDevices, master: 50,
                  isMuted: false, connectionState: .connected)
        XCTAssertTrue(row.test_routeArmed)
        XCTAssertTrue(row.test_isFaderEngaged)
    }

    func testMainOutFaderNeutralWhenIdleOrMuted() {
        let idle = MainOutRowView()
        idle.apply(options: makeMainOutOptions(), current: .selectedDevices, master: 50,
                   connectionState: .off)
        XCTAssertFalse(idle.test_isFaderEngaged, "idle Main Out keeps the neutral fill")

        let muted = MainOutRowView()
        muted.apply(options: makeMainOutOptions(), current: .selectedDevices, master: 50,
                    isMuted: true, connectionState: .connected)
        XCTAssertFalse(muted.test_isFaderEngaged, "master mute disarms the master fader")
    }

    // MARK: App row — engaged = routed ∧ running (spec §5.1's app predicate)

    func testAppFaderEngagedWhenRoutedAndRunning() {
        let row = AppRowView()
        row.apply(makeAppConfiguration(selected: "device-1", isRunning: true))
        XCTAssertTrue(row.test_isFaderEngaged)
    }

    func testAppFaderNeutralWhenRoutedButIdle() {
        let row = AppRowView()
        row.apply(makeAppConfiguration(selected: "device-1", isRunning: false))
        XCTAssertFalse(row.test_isFaderEngaged,
                       "a routed-but-idle app keeps the neutral fill (calm, not live)")
    }

    func testAppFaderNeutralAndDisabledOnNoRedirect() {
        let row = AppRowView()
        row.apply(makeAppConfiguration(selected: "no-redirect", isRunning: true))
        XCTAssertTrue(row.test_isSliderDimmed)
        XCTAssertFalse(row.test_isFaderEngaged,
                       "the standalone follows-main-output state is never gold")
    }

    // MARK: Behavior stays stock after the cell swap

    private final class RecordingDeviceDelegate: DeviceRowView.Delegate {
        var lastVolume: (id: String, volume: Int)?
        func deviceRow(_ row: DeviceRowView, didSetVolume volume: Int, for id: String) {
            lastVolume = (id, volume)
        }
        func deviceRow(_ row: DeviceRowView, didToggleMute muted: Bool, for id: String) {}
    }

    func testSliderTargetActionSurvivesCellSwap() {
        // Fire the slider's OWN target/action with the slider as sender —
        // the same dispatch AppKit performs during a drag — proving the cell
        // swap preserved the control's wiring (the AppKit-dispatch seam the
        // MainOutRowMenuDispatchTests lesson calls for, not the delegate
        // shortcut `test_setVolume` takes).
        let row = DeviceRowView(device: makeDevice())
        let delegate = RecordingDeviceDelegate()
        row.delegate = delegate
        row.apply(makeDevice(), selected: true, controllable: true)
        row.test_fireSliderAction(settingValueTo: 73)
        XCTAssertEqual(delegate.lastVolume?.volume, 73,
                       "the slider's target/action still reaches the delegate after the cell swap")
        XCTAssertEqual(delegate.lastVolume?.id, "dev-1")
    }

    func testSliderConfigurationSurvivesCellSwap() {
        let config = DeviceRowView(device: makeDevice()).test_sliderConfiguration
        XCTAssertEqual(config.min, 0)
        XCTAssertEqual(config.max, 100)
        XCTAssertTrue(config.isContinuous,
                      "isContinuous survives (the drag fires throughout — brief §2)")
        XCTAssertEqual(config.type, .linear)
    }

    // MARK: Deterministic drawing (cacheDisplay double-render, both looks)

    func testFaderRenderIsByteDeterministic() throws {
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            for engaged in [false, true] {
                let row = DeviceRowView(device: makeDevice())
                row.apply(makeDevice(), selected: engaged, controllable: true)
                row.frame = NSRect(x: 0, y: 0, width: 320, height: DeviceRowView.rowHeight)
                row.appearance = NSAppearance(named: appearanceName)
                row.layoutSubtreeIfNeeded()

                func render() throws -> Data {
                    let rep = try XCTUnwrap(row.bitmapImageRepForCachingDisplay(in: row.bounds))
                    row.cacheDisplay(in: row.bounds, to: rep)
                    return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                }
                let first = try render()
                let second = try render()
                XCTAssertEqual(first, second,
                               "\(appearanceName.rawValue) engaged=\(engaged): fader drawing must be byte-deterministic under cacheDisplay")
            }
        }
    }
}
