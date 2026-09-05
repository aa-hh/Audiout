// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudioutCore

@Suite struct AppRouteTargetEligibilityTests {

    @Test func localDeviceIsRefused() {
        let device = Device(id: "local-1", name: "This Mac", kind: .generic,
                             supportsAirPlay2: true, isLocalDevice: true)
        #expect(device.canBePerAppRouteTarget() == false)
    }

    @Test func localMacKindWithoutLocalDeviceFlagIsRefused() {
        // The two-term rule: `kind == .localMac` alone must refuse, even
        // when `isLocalDevice` itself is false.
        let device = Device(id: "local-2", name: "Odd This Mac", kind: .localMac,
                             supportsAirPlay2: true, isLocalDevice: false)
        #expect(device.canBePerAppRouteTarget() == false)
    }

    @Test func airPlay2DeviceQualifies() {
        let device = Device(id: "ap2-1", name: "HomePod", kind: .homePod, supportsAirPlay2: true)
        #expect(device.canBePerAppRouteTarget() == true)
    }

    @Test func unavailableAirPlay2DeviceStillQualifies() {
        // The predicate is a KIND question only — it must not read
        // `isAvailable`, because `resolveGroupTargets` deliberately keeps
        // unreachable group members (subtracted later inside the backend).
        let device = Device(id: "ap2-2", name: "Offline HomePod", kind: .homePod,
                             isAvailable: false, supportsAirPlay2: true)
        #expect(device.canBePerAppRouteTarget() == true)
    }

    @Test func airPlay1DeviceQualifies() {
        // An AP1 receiver streams through the same shared engine an AP2 one
        // does, so `supportsAirPlay2: false` is not a reason to refuse it.
        let device = Device(id: "ap1-1", name: "AirPort Express", kind: .airportExpress,
                             supportsAirPlay2: false)
        #expect(device.canBePerAppRouteTarget() == true)
    }

    @Test func bluetoothDeviceQualifies() {
        // Matches production (`NativeBackend.swift`): a Bluetooth row always
        // carries `supportsAirPlay2: false`. It qualifies on its own delivery
        // path — fed by UID through the sink manager, never the engine.
        let device = Device(id: "bt-1", name: "Bluetooth Speaker", kind: .bluetooth,
                             supportsAirPlay2: false)
        #expect(device.canBePerAppRouteTarget() == true)
    }

    @Test func castStaysExcluded() {
        // `supportsAirPlay2: true` here is deliberately unrealistic (Cast
        // rows always carry `false` in production) — it isolates that the
        // refusal comes from the `isCast` branch itself, not from an
        // incidental AP2 check. Cast is the one kind with no per-app
        // delivery path, so a route to one would be silently demoted.
        let cast = Device(id: "cast-1", name: "Chromecast", kind: .cast,
                           supportsAirPlay2: true)
        #expect(cast.canBePerAppRouteTarget() == false)
    }
}
