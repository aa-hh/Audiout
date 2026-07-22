// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import AudiouterCore

/// The menu-bar routing dot's predicate (Warm Signal v3 §5.5): present = ≥1
/// live route (armed+connected remote device, or a confirmed per-app route),
/// absent = passthrough/idle. `StatusItemController` renders whatever this
/// answers, so the truth-table lives here.
final class StatusRoutingIndicatorTests: XCTestCase {

    private func device(
        id: String,
        isLocal: Bool = false,
        isSelected: Bool = false,
        connectionState: ConnectionState = .off
    ) -> Device {
        Device(
            id: id,
            name: id,
            kind: isLocal ? .localMac : .sonos,
            isSelected: isSelected,
            isLocalDevice: isLocal,
            connectionState: connectionState
        )
    }

    func test_idle_noSelection_dotAbsent() {
        let devices = [device(id: "mac", isLocal: true), device(id: "sonos")]
        XCTAssertFalse(StatusRoutingIndicator.isRoutingLive(devices: devices, hasLiveAppRoutes: false))
    }

    func test_passthrough_localOnlySelected_dotAbsent() {
        // Passthrough = the Mac alone; the local device never counts as a route,
        // whatever its connection state claims.
        let devices = [
            device(id: "mac", isLocal: true, isSelected: true, connectionState: .connected),
            device(id: "sonos"),
        ]
        XCTAssertFalse(StatusRoutingIndicator.isRoutingLive(devices: devices, hasLiveAppRoutes: false))
    }

    func test_remoteArmedAndConnected_dotPresent() {
        let devices = [
            device(id: "mac", isLocal: true),
            device(id: "sonos", isSelected: true, connectionState: .connected),
        ]
        XCTAssertTrue(StatusRoutingIndicator.isRoutingLive(devices: devices, hasLiveAppRoutes: false))
    }

    func test_remoteArmedButNotYetConnected_dotAbsent() {
        // Armed but still connecting / reconnecting / failed = not broadcasting.
        for state: ConnectionState in [.off, .connecting, .reconnecting, .failed(ConnectionFailure(cause: .timedOut))] {
            let devices = [device(id: "sonos", isSelected: true, connectionState: state)]
            XCTAssertFalse(
                StatusRoutingIndicator.isRoutingLive(devices: devices, hasLiveAppRoutes: false),
                "dot must be absent for \(state)"
            )
        }
    }

    func test_remoteConnectedButNotArmed_dotAbsent() {
        // A stale connected flag on an unarmed device is not a live route.
        let devices = [device(id: "sonos", isSelected: false, connectionState: .connected)]
        XCTAssertFalse(StatusRoutingIndicator.isRoutingLive(devices: devices, hasLiveAppRoutes: false))
    }

    func test_liveAppRoute_dotPresent_evenInPassthrough() {
        // A confirmed per-app stream is broadcasting even when Main Out is
        // passthrough (the app's audio travels the per-app capture path).
        let devices = [device(id: "mac", isLocal: true, isSelected: true)]
        XCTAssertTrue(StatusRoutingIndicator.isRoutingLive(devices: devices, hasLiveAppRoutes: true))
    }

    func test_emptyFleet_appRoutesStillCount() {
        XCTAssertTrue(StatusRoutingIndicator.isRoutingLive(devices: [], hasLiveAppRoutes: true))
        XCTAssertFalse(StatusRoutingIndicator.isRoutingLive(devices: [], hasLiveAppRoutes: false))
    }
}
