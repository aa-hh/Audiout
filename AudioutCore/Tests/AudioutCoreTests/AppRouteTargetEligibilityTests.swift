// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudioutCore

// PerAppRouting.allOutputsEnabled is a `static let` that reads the
// environment once per process, so it cannot be toggled per test. Every case
// below calls `canBePerAppRouteTarget(allOutputs:)` directly with both
// `true` and `false` instead of setting `AUDIOUT_PER_APP_ALL_OUTPUTS`.
// Running this whole suite with `AUDIOUT_PER_APP_ALL_OUTPUTS=1` set in the
// environment would red three tests elsewhere by design: the flag ships
// off, and other suites assert that off behavior.
@Suite struct AppRouteTargetEligibilityTests {

    @Test func localDeviceIsRefusedEitherWay() {
        let device = Device(id: "local-1", name: "This Mac", kind: .generic,
                             supportsAirPlay2: true, isLocalDevice: true)
        #expect(device.canBePerAppRouteTarget(allOutputs: false) == false)
        #expect(device.canBePerAppRouteTarget(allOutputs: true) == false)
    }

    @Test func localMacKindWithoutLocalDeviceFlagIsRefusedEitherWay() {
        // The two-term rule: `kind == .localMac` alone must refuse, even
        // when `isLocalDevice` itself is false.
        let device = Device(id: "local-2", name: "Odd This Mac", kind: .localMac,
                             supportsAirPlay2: true, isLocalDevice: false)
        #expect(device.canBePerAppRouteTarget(allOutputs: false) == false)
        #expect(device.canBePerAppRouteTarget(allOutputs: true) == false)
    }

    @Test func airPlay2DeviceQualifiesEitherWay() {
        let device = Device(id: "ap2-1", name: "HomePod", kind: .homePod, supportsAirPlay2: true)
        #expect(device.canBePerAppRouteTarget(allOutputs: false) == true)
        #expect(device.canBePerAppRouteTarget(allOutputs: true) == true)
    }

    @Test func unavailableAirPlay2DeviceStillQualifies() {
        // The predicate is a KIND question only — it must not read
        // `isAvailable`, because `resolveGroupTargets` deliberately keeps
        // unreachable group members (subtracted later inside the backend).
        let device = Device(id: "ap2-2", name: "Offline HomePod", kind: .homePod,
                             isAvailable: false, supportsAirPlay2: true)
        #expect(device.canBePerAppRouteTarget(allOutputs: false) == true)
        #expect(device.canBePerAppRouteTarget(allOutputs: true) == true)
    }

    @Test func airPlay1DeviceRequiresAllOutputsFlag() {
        let device = Device(id: "ap1-1", name: "AirPort Express", kind: .airportExpress,
                             supportsAirPlay2: false)
        #expect(device.canBePerAppRouteTarget(allOutputs: false) == false)
        #expect(device.canBePerAppRouteTarget(allOutputs: true) == true)
    }

    @Test func bluetoothAndCastStayExcludedEvenWithAllOutputs() {
        // The ceiling `canBePerAppRouteTarget` enforces even with the flag
        // on: Bluetooth and Cast are refused by their own
        // `isBluetooth`/`isCast` branches. `supportsAirPlay2: true` here is
        // deliberately unrealistic (BT/Cast rows always carry `false` in
        // production) — it isolates that the refusal comes from the kind
        // exclusion itself, not from an incidental AP2 check.
        let bluetooth = Device(id: "bt-1", name: "Bluetooth Speaker", kind: .bluetooth,
                                supportsAirPlay2: true)
        let cast = Device(id: "cast-1", name: "Chromecast", kind: .cast,
                           supportsAirPlay2: true)
        #expect(bluetooth.canBePerAppRouteTarget(allOutputs: true) == false)
        #expect(cast.canBePerAppRouteTarget(allOutputs: true) == false)
        #expect(bluetooth.canBePerAppRouteTarget(allOutputs: false) == false)
        #expect(cast.canBePerAppRouteTarget(allOutputs: false) == false)
    }
}
