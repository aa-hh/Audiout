// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import AudiouterCore
@testable import AudiouterSharedUI

/// Guards the menu-bar status item's idle-vs-streaming decision
/// (`MenuBarStatus`, AppKit-free by design — see its doc comment). "Actively
/// streaming" means ANY audio is currently leaving the Mac by ANY mechanism:
/// a `.connected` device in the main Audio Out (Main Out / Selected Devices)
/// OR a live per-app redirect (`liveRoutedAppNames`), per the resolved design
/// question ("anything counts," not just Main Out).
final class MenuBarStatusTests: IsolatedTestCase {

    private func device(id: String = "dev-1", connectionState: ConnectionState = .off) -> Device {
        Device(id: id, name: "Test Speaker", kind: .generic, connectionState: connectionState)
    }

    // MARK: Idle state

    func test_isStreaming_false_whenNoDevicesAndNoRoutedApps() {
        XCTAssertFalse(MenuBarStatus.isStreaming(devices: [], liveRoutedAppNames: [:]))
    }

    func test_isStreaming_false_whenDeviceIsOff() {
        let devices = [device(connectionState: .off)]
        XCTAssertFalse(MenuBarStatus.isStreaming(devices: devices, liveRoutedAppNames: [:]))
    }

    func test_isStreaming_false_whenDeviceIsConnectingOnly() {
        // .connecting is not yet .connected — the icon shouldn't light up on a
        // handshake that hasn't landed yet.
        let devices = [device(connectionState: .connecting)]
        XCTAssertFalse(MenuBarStatus.isStreaming(devices: devices, liveRoutedAppNames: [:]))
    }

    func test_isStreaming_false_whenRoutedAppsMapHasOnlyEmptyEntries() {
        // A device entry with an empty appNames array means "nothing confirmed
        // streaming there" (mirrors PopoverController's own bookkeeping, which
        // never persists an empty entry) — must not count as streaming.
        let devices = [device(connectionState: .off)]
        XCTAssertFalse(
            MenuBarStatus.isStreaming(devices: devices, liveRoutedAppNames: ["dev-1": []])
        )
    }

    func test_symbolName_outline_whenIdle() {
        XCTAssertEqual(MenuBarStatus.symbolName(isStreaming: false), "speaker.wave.3")
    }

    // MARK: Streaming via Main Out (whole-system output set)

    func test_isStreaming_true_whenAnyDeviceConnected() {
        let devices = [device(id: "dev-1", connectionState: .off), device(id: "dev-2", connectionState: .connected)]
        XCTAssertTrue(MenuBarStatus.isStreaming(devices: devices, liveRoutedAppNames: [:]))
    }

    func test_isStreaming_false_whenDeviceReconnectingButNotConnected() {
        // .reconnecting is a drop from .connected, not a live stream — the main
        // output set only counts an actually-`.connected` device.
        let devices = [device(connectionState: .reconnecting)]
        XCTAssertFalse(MenuBarStatus.isStreaming(devices: devices, liveRoutedAppNames: [:]))
    }

    // MARK: Streaming via a per-app redirect (independent of Main Out)

    func test_isStreaming_true_whenOnlyAPerAppRouteIsLive() {
        // The resolved design question: routing a SINGLE app to a speaker with
        // Main Out otherwise idle/passthrough must still light up the icon.
        let devices = [device(connectionState: .off)]
        XCTAssertTrue(
            MenuBarStatus.isStreaming(devices: devices, liveRoutedAppNames: ["dev-1": ["Music"]])
        )
    }

    func test_isStreaming_true_whenBothMainOutAndPerAppRouteAreLive() {
        let devices = [device(id: "dev-1", connectionState: .connected)]
        XCTAssertTrue(
            MenuBarStatus.isStreaming(devices: devices, liveRoutedAppNames: ["dev-2": ["Safari"]])
        )
    }

    func test_symbolName_filled_whenStreaming() {
        XCTAssertEqual(MenuBarStatus.symbolName(isStreaming: true), "speaker.wave.3.fill")
    }
}
