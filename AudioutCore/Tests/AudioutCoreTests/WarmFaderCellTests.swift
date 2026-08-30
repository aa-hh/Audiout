// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import AppKit
@testable import AudioutCore
@testable import AudioutPopoverUI
@testable import AudioutSharedUI

/// The **Warm Signal fader skin** (`WarmFaderCell`, spec §5 "we redraw only
/// the slider track/knob look"): the drawing-only `NSSliderCell` swap on the
/// three row volume sliders. Covers (1) the skin is INSTALLED on all three
/// rows; (2) the engaged (gold-gradient) fill tracks the SAME route-armed
/// predicate the corner dot renders — device row (§3.3 truth table edges),
/// Main Out (connected ∧ !muted), app row (routed ∧ running); (3) NSSlider
/// BEHAVIOR stays stock after the cell swap — `isContinuous`, min/max, and
/// the target/action dispatch all survive; (4) the drawing is deterministic
/// under `cacheDisplay` (byte-identical double render, both appearances).
@MainActor
@Suite struct WarmFaderCellTests {

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

    @Test func allThreeRowsWearTheWarmFaderSkin() {
        #expect(DeviceRowView(device: makeDevice()).test_hasWarmFaderSkin, "DeviceRowView's slider wears WarmFaderCell")
        #expect(MainOutRowView().test_hasWarmFaderSkin, "MainOutRowView's master slider wears WarmFaderCell")
        #expect(AppRowView().test_hasWarmFaderSkin, "AppRowView's slider wears WarmFaderCell")
    }

    // MARK: Device row — engaged fill tracks the §3.3 armed predicate

    @Test func deviceFaderEngagedWhenRouteArmed() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: true, controllable: true)
        #expect(row.test_routeArmed)
        #expect(row.test_isFaderEngaged, "armed ∧ enabled ⇒ the gold gradient fill renders")
    }

    @Test func deviceFaderNeutralWhenNotMember() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: false, controllable: true)
        #expect(!(row.test_isFaderEngaged), "a non-member's fader keeps the neutral warm fill")
    }

    @Test func deviceFaderNeutralWhenNotConnected() {
        let row = DeviceRowView(device: makeDevice(connectionState: .connecting))
        row.apply(makeDevice(connectionState: .connecting), selected: true, controllable: true)
        #expect(!(row.test_isFaderEngaged), "not yet connected ⇒ no gold fill (same truth as the dot)")
    }

    @Test func deviceFaderNeutralWhenRowMuted() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(isMuted: true), selected: true, controllable: true)
        #expect(!(row.test_isFaderEngaged), "row mute disarms the gold fill")
        #expect(row.test_isSliderEnabled, "…but the slider stays live (A5 — mute ≠ frozen volume)")
    }

    @Test func deviceFaderNeutralWhenMasterMuted() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: true, controllable: true, masterMuted: true)
        #expect(!(row.test_isFaderEngaged), "master mute drains every device fader")
    }

    @Test func deviceFaderEngagedByLiveFeedEvenWhenMuted() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(isMuted: true), selected: false, controllable: true,
                  liveAppNames: ["Music"])
        #expect(row.test_routeArmed)
        #expect(row.test_isFaderEngaged, "a confirmed live per-app feed arms the fader (redirects bypass the mutes)")
    }

    @Test func deviceFaderNeverEngagedWhileSliderDisabled() {
        // A live-feed row that is NOT controllable: armed predicate true, but
        // the slider is disabled — the engaged gate requires BOTH.
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: true, controllable: false, liveAppNames: ["Music"])
        #expect(row.test_routeArmed)
        #expect(!(row.test_isSliderEnabled))
        #expect(!(row.test_isFaderEngaged), "a disabled slider never renders the engaged fill")
    }

    // MARK: Main Out row — engaged = connected ∧ !muted (the dot's predicate)

    @Test func mainOutFaderEngagedWhenTargetLiveAndUnmuted() {
        let row = MainOutRowView()
        row.apply(options: makeMainOutOptions(), current: .selectedDevices, master: 50,
                  isMuted: false, connectionState: .connected)
        #expect(row.test_routeArmed)
        #expect(row.test_isFaderEngaged)
    }

    @Test func mainOutFaderNeutralWhenIdleOrMuted() {
        let idle = MainOutRowView()
        idle.apply(options: makeMainOutOptions(), current: .selectedDevices, master: 50,
                   connectionState: .off)
        #expect(!(idle.test_isFaderEngaged), "idle Main Out keeps the neutral fill")

        let muted = MainOutRowView()
        muted.apply(options: makeMainOutOptions(), current: .selectedDevices, master: 50,
                    isMuted: true, connectionState: .connected)
        #expect(!(muted.test_isFaderEngaged), "master mute disarms the master fader")
    }

    // MARK: App row — engaged = routed ∧ running (spec §5.1's app predicate)

    @Test func appFaderEngagedWhenRoutedAndRunning() {
        let row = AppRowView()
        row.apply(makeAppConfiguration(selected: "device-1", isRunning: true))
        #expect(row.test_isFaderEngaged)
    }

    @Test func appFaderNeutralWhenRoutedButIdle() {
        let row = AppRowView()
        row.apply(makeAppConfiguration(selected: "device-1", isRunning: false))
        #expect(!(row.test_isFaderEngaged), "a routed-but-idle app keeps the neutral fill (calm, not live)")
    }

    @Test func appFaderNeutralButLiveOnNoRedirect() {
        let row = AppRowView()
        row.apply(makeAppConfiguration(selected: "no-redirect", isRunning: true))
        #expect(!row.test_isSliderDimmed,
                "the slider levels an un-redirected app inside the mix, so it stays live")
        #expect(!(row.test_isFaderEngaged), "the standalone follows-main-output state is never gold")
    }

    // MARK: Behavior stays stock after the cell swap

    private final class RecordingDeviceDelegate: DeviceRowView.Delegate {
        var lastVolume: (id: String, volume: Int)?
        func deviceRow(_ row: DeviceRowView, didSetVolume volume: Int, for id: String) {
            lastVolume = (id, volume)
        }
        func deviceRow(_ row: DeviceRowView, didToggleMute muted: Bool, for id: String) {}
    }

    @Test func sliderTargetActionSurvivesCellSwap() {
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
        #expect(delegate.lastVolume?.volume == 73, "the slider's target/action still reaches the delegate after the cell swap")
        #expect(delegate.lastVolume?.id == "dev-1")
    }

    @Test func sliderConfigurationSurvivesCellSwap() {
        let config = DeviceRowView(device: makeDevice()).test_sliderConfiguration
        #expect(config.min == 0)
        #expect(config.max == 100)
        #expect(config.isContinuous, "isContinuous survives (the drag fires throughout — brief §2)")
        #expect(config.type == .linear)
    }

    // MARK: Deterministic drawing (cacheDisplay double-render, both looks)

    @Test func faderRenderIsByteDeterministic() throws {
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            for engaged in [false, true] {
                let row = DeviceRowView(device: makeDevice())
                row.apply(makeDevice(), selected: engaged, controllable: true)
                row.frame = NSRect(x: 0, y: 0, width: 320, height: DeviceRowView.rowHeight)
                row.appearance = NSAppearance(named: appearanceName)
                row.layoutSubtreeIfNeeded()

                func render() throws -> Data {
                    let rep = try #require(row.bitmapImageRepForCachingDisplay(in: row.bounds))
                    row.cacheDisplay(in: row.bounds, to: rep)
                    return try #require(rep.representation(using: .png, properties: [:]))
                }
                let first = try render()
                let second = try render()
                #expect(first == second, "\(appearanceName.rawValue) engaged=\(engaged): fader drawing must be byte-deterministic under cacheDisplay")
            }
        }
    }
}
