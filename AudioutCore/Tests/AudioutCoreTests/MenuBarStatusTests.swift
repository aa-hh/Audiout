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

    private func device(id: String = "dev-1",
                        connectionState: ConnectionState = .off,
                        isSelected: Bool = false) -> Device {
        Device(id: id, name: "Test Speaker", kind: .generic,
               isSelected: isSelected, connectionState: connectionState)
    }

    private var failure: ConnectionState {
        .failed(ConnectionFailure(cause: .notResponding))
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
        #expect(MenuBarStatus.symbolName(for: .idle) == "speaker.wave.3")
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
        #expect(MenuBarStatus.symbolName(for: .streaming) == "speaker.wave.3.fill")
    }

    @Test func symbolName_badged_whenFailure() {
        #expect(MenuBarStatus.symbolName(for: .failure) == "speaker.badge.exclamationmark")
    }

    // MARK: The three-state decision

    @Test func state_idle_whenNothingIsHappening() {
        #expect(MenuBarStatus.state(devices: [], liveRoutedAppNames: [:]) == .idle)
    }

    @Test func state_streaming_whenADeviceIsConnected() {
        let devices = [device(connectionState: .connected)]
        #expect(MenuBarStatus.state(devices: devices, liveRoutedAppNames: [:]) == .streaming)
    }

    @Test func state_failure_whenASelectedDeviceFailed() {
        let devices = [device(connectionState: failure, isSelected: true)]
        #expect(MenuBarStatus.state(devices: devices, liveRoutedAppNames: [:]) == .failure)
    }

    @Test func state_failure_outranksStreaming() {
        // A broken speaker must never look like a paused one: the badge wins
        // even while another device is happily streaming.
        let devices = [
            device(id: "dev-1", connectionState: .connected),
            device(id: "dev-2", connectionState: failure, isSelected: true),
        ]
        #expect(MenuBarStatus.state(devices: devices, liveRoutedAppNames: [:]) == .failure)
    }

    @Test func state_notFailure_whenTheFailedDeviceIsNotSelected() {
        // Deselecting a broken speaker clears the badge — an unselected failure
        // is no longer something the user asked for.
        let devices = [device(connectionState: failure, isSelected: false)]
        #expect(MenuBarStatus.state(devices: devices, liveRoutedAppNames: [:]) == .idle)
    }

    @Test func state_streaming_whenAnUnselectedFailureSitsBesideALiveRoute() {
        let devices = [device(connectionState: failure, isSelected: false)]
        #expect(
            MenuBarStatus.state(devices: devices, liveRoutedAppNames: ["dev-2": ["Music"]])
                == .streaming
        )
    }

    // MARK: Spoken description

    @Test func accessibilityDescription_failure_ignoresLevelAndMute() {
        #expect(
            MenuBarStatus.accessibilityDescription(
                state: .failure, masterVolumePercent: 80, isMuted: true)
                == "Audiout — speaker connection failed"
        )
    }

    @Test func accessibilityDescription_muted_whileStreaming() {
        #expect(
            MenuBarStatus.accessibilityDescription(
                state: .streaming, masterVolumePercent: 80, isMuted: true)
                == "Audiout — muted, streaming"
        )
    }

    @Test func accessibilityDescription_muted_whileIdle() {
        #expect(
            MenuBarStatus.accessibilityDescription(
                state: .idle, masterVolumePercent: 80, isMuted: true)
                == "Audiout — muted"
        )
    }

    @Test func accessibilityDescription_level_whileStreaming() {
        #expect(
            MenuBarStatus.accessibilityDescription(
                state: .streaming, masterVolumePercent: 80, isMuted: false)
                == "Audiout — 80%, streaming"
        )
    }

    @Test func accessibilityDescription_level_whileIdle() {
        #expect(
            MenuBarStatus.accessibilityDescription(
                state: .idle, masterVolumePercent: 80, isMuted: false)
                == "Audiout — 80%"
        )
    }
}
