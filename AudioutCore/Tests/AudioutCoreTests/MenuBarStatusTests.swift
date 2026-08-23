// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
@testable import AudioutCore
@testable import AudioutSharedUI

/// Guards the menu-bar status item's idle-vs-streaming decision
/// (`MenuBarStatus`, AppKit-free by design — see its doc comment). "Actively
/// streaming" means ANY audio is currently leaving the Mac by ANY mechanism:
/// a `.connected` device in the main Audio Out (Main Out / Selected Devices)
/// OR a live per-app redirect (`liveRoutedAppNames`), per the resolved design
/// question ("anything counts," not just Main Out).
@Suite final class MenuBarStatusTests: IsolatedSuite {

    private func device(id: String = "dev-1", connectionState: ConnectionState = .off) -> Device {
        Device(id: id, name: "Test Speaker", kind: .generic, connectionState: connectionState)
    }

    // MARK: Idle state

    @Test func isStreaming_false_whenNoDevicesAndNoRoutedApps() {
        #expect(!MenuBarStatus.isStreaming(devices: [], liveRoutedAppNames: [:]))
    }

    @Test func isStreaming_false_whenDeviceIsOff() {
        let devices = [device(connectionState: .off)]
        #expect(!MenuBarStatus.isStreaming(devices: devices, liveRoutedAppNames: [:]))
    }

    @Test func isStreaming_false_whenDeviceIsConnectingOnly() {
        // .connecting is not yet .connected — the icon shouldn't light up on a
        // handshake that hasn't landed yet.
        let devices = [device(connectionState: .connecting)]
        #expect(!MenuBarStatus.isStreaming(devices: devices, liveRoutedAppNames: [:]))
    }

    @Test func isStreaming_false_whenRoutedAppsMapHasOnlyEmptyEntries() {
        // A device entry with an empty appNames array means "nothing confirmed
        // streaming there" (mirrors PopoverController's own bookkeeping, which
        // never persists an empty entry) — must not count as streaming.
        let devices = [device(connectionState: .off)]
        #expect(
            !MenuBarStatus.isStreaming(devices: devices, liveRoutedAppNames: ["dev-1": []])
        )
    }

    @Test func symbolName_outline_whenIdle() {
        #expect(MenuBarStatus.symbolName(isStreaming: false) == "speaker.wave.3")
    }

    // MARK: Streaming via Main Out (whole-system output set)

    @Test func isStreaming_true_whenAnyDeviceConnected() {
        let devices = [device(id: "dev-1", connectionState: .off), device(id: "dev-2", connectionState: .connected)]
        #expect(MenuBarStatus.isStreaming(devices: devices, liveRoutedAppNames: [:]))
    }

    @Test func isStreaming_false_whenDeviceReconnectingButNotConnected() {
        // .reconnecting is a drop from .connected, not a live stream — the main
        // output set only counts an actually-`.connected` device.
        let devices = [device(connectionState: .reconnecting)]
        #expect(!MenuBarStatus.isStreaming(devices: devices, liveRoutedAppNames: [:]))
    }

    // MARK: Streaming via a per-app redirect (independent of Main Out)

    @Test func isStreaming_true_whenOnlyAPerAppRouteIsLive() {
        // The resolved design question: routing a SINGLE app to a speaker with
        // Main Out otherwise idle/passthrough must still light up the icon.
        let devices = [device(connectionState: .off)]
        #expect(
            MenuBarStatus.isStreaming(devices: devices, liveRoutedAppNames: ["dev-1": ["Music"]])
        )
    }

    @Test func isStreaming_true_whenBothMainOutAndPerAppRouteAreLive() {
        let devices = [device(id: "dev-1", connectionState: .connected)]
        #expect(
            MenuBarStatus.isStreaming(devices: devices, liveRoutedAppNames: ["dev-2": ["Safari"]])
        )
    }

    @Test func symbolName_filled_whenStreaming() {
        #expect(MenuBarStatus.symbolName(isStreaming: true) == "speaker.wave.3.fill")
    }
}
