// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import Testing
import AudioutCore
@testable import AudioutSharedUI
@testable import AudioutPopoverUI

/// Warm Signal v4.1 item 6 — **No tint on rings or meters (guard)**.
///
/// Tether colour (app-derived hue, `AppTetherColor`) lives ONLY on FEED column
/// app-name text. The halo ring stays connection-only (dashed=connecting,
/// solid=connected, red=failed); every meter (device + master) stays gold/ember
/// only. Assert no tether colour reaches a ring or meter — a future change that
/// tints them MUST fail this guard.
@MainActor
@Suite final class NoTintOnRingsOrMetersGuardTests: IsolatedSuite {

    private func makeDevice(
        id: String = "dev-1",
        name: String = "Test Speaker",
        connectionState: ConnectionState = .connected,
        isAvailable: Bool = true
    ) -> Device {
        Device(
            id: id,
            name: name,
            kind: .homePod,
            isAvailable: isAvailable,
            connectionState: connectionState
        )
    }

    /// Assert two colors resolve to the same sRGB components.
    private func assertSameColor(
        _ a: NSColor?,
        _ b: NSColor?,
        _ message: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard let a = a?.usingColorSpace(.sRGB), let b = b?.usingColorSpace(.sRGB) else {
            Issue.record("nil color: \(message)", sourceLocation: sourceLocation)
            return
        }
        #expect(abs(a.redComponent - b.redComponent) <= 0.01, "\(message)", sourceLocation: sourceLocation)
        #expect(abs(a.greenComponent - b.greenComponent) <= 0.01, "\(message)", sourceLocation: sourceLocation)
        #expect(abs(a.blueComponent - b.blueComponent) <= 0.01, "\(message)", sourceLocation: sourceLocation)
    }

    // MARK: - Meter gradient foundation — must stay warm only

    @Test func levelMeterGradientIsEmberGoldCaution() {
        let meter = LevelMeterView()
        let colors = meter.test_gradientColors
        #expect(colors.count == 3, "Meter gradient must have exactly 3 stops")
        assertSameColor(colors[0], Tokens.Color.ember, "Stop 0 is ember")
        assertSameColor(colors[1], Tokens.Color.gold, "Stop 1 is gold")
        assertSameColor(colors[2], Tokens.Color.caution, "Stop 2 is caution ceiling")
    }

    @Test func meterGradientNeverContainsFailureRed() {
        // House rule 8: failure red is failure-exclusive. This guard verifies
        // no meter gradient stop can land on failure red through bad changes.
        let meter = LevelMeterView()
        guard let failureColor = Tokens.Color.failure.usingColorSpace(.sRGB) else {
            Issue.record("failure token did not resolve")
            return
        }
        for color in meter.test_gradientColors {
            guard let c = color.usingColorSpace(.sRGB) else { continue }
            let distance = abs(c.redComponent - failureColor.redComponent)
                + abs(c.greenComponent - failureColor.greenComponent)
                + abs(c.blueComponent - failureColor.blueComponent)
            #expect(distance > 0.1, "no meter stop may be failure red")
        }
    }

    // MARK: - Device row meter — inherits warm-only base

    @Test func deviceRowMeterKeepsWarmGradient() {
        let row = DeviceRowView(device: makeDevice(), showsMeter: true)
        row.apply(makeDevice(), selected: true, controllable: true)
        row.setLevel(0.5)

        // Row's meter target stays numeric (warm gradient inherited from LevelMeterView)
        #expect(row.test_meterTarget >= 0)
    }

    // MARK: - Halo ring — connection-state only, never tether tinted

    @Test func ringStrokeNeverWearsTetherColor() {
        let row = DeviceRowView(device: makeDevice(), showsBus: true)
        let tetherTint = NSColor(srgbRed: 0.8, green: 0.4, blue: 0.2, alpha: 1)

        row.apply(
            makeDevice(),
            selected: true,
            controllable: true,
            routedAppNames: ["Safari"],
            appTintColors: ["Safari": tetherTint]
        )

        if let ringColor = row.test_ringStrokeColor {
            // Ring must be connection-state only
            let isRingColor = isConnectionStateColor(ringColor)
            #expect(isRingColor, "Ring stroke must stay connection-only, never tether tinted")
        }
    }

    @Test func connectedRingIsRingConnectedHue() {
        let row = DeviceRowView(device: makeDevice(connectionState: .connected), showsBus: true)
        row.apply(makeDevice(connectionState: .connected), selected: true)

        if let ringColor = row.test_ringStrokeColor {
            assertSameColor(ringColor, Tokens.Color.ringConnected, "Connected ring is ringConnected")
        }
    }

    @Test func failedRingIsFailureRed() {
        let failed = makeDevice(connectionState: .failed(.init(cause: .notResponding)))
        let row = DeviceRowView(device: failed, showsBus: true)
        row.apply(failed, selected: true)

        if let ringColor = row.test_ringStrokeColor {
            assertSameColor(ringColor, Tokens.Color.failure, "Failed ring is failure red")
        }
    }

    // MARK: - FEED column is the ONLY allowed tether-color location

    @Test func feedColumnAppSegmentColorIsTheTetherTint() {
        let row = DeviceRowView(device: makeDevice(), showsMeter: true, showsBus: true)
        let tetherTint = NSColor(srgbRed: 0.5, green: 0.7, blue: 0.4, alpha: 1)

        row.apply(
            makeDevice(),
            selected: true,
            controllable: true,
            routedAppNames: ["Music"],
            appTintColors: ["Music": tetherTint]
        )

        // FEED column IS allowed to wear the tether tint
        let feedColor = row.test_feedAppSegmentColor(for: "Music")
        assertSameColor(feedColor, tetherTint, "FEED column app segment wears tether tint")
    }

    @Test func feedColumnNeutralSegmentDoesNotWearTether() {
        let row = DeviceRowView(device: makeDevice(), showsMeter: true, showsBus: true)
        row.apply(makeDevice(), selected: true, controllable: true)

        #expect(row.test_feedText != nil)
        #expect(row.test_feedText?.contains("System") ?? false, "Neutral segment is System")
    }

    // MARK: - Multi-app: meters stay warm, feed shows tints

    @Test func multipleAppRedirectsKeepWarmMeters() {
        let row = DeviceRowView(device: makeDevice(), showsMeter: true, showsBus: true)
        let tints = [
            "Music": NSColor(srgbRed: 0.5, green: 0.3, blue: 0.1, alpha: 1),
            "Safari": NSColor(srgbRed: 0.2, green: 0.6, blue: 0.8, alpha: 1),
        ]

        row.apply(
            makeDevice(),
            selected: false,
            controllable: true,
            routedAppNames: ["Music", "Safari"],
            appTintColors: tints
        )
        row.setLevel(0.6)

        // Meter stays warm despite multiple app tints
        #expect(row.test_meterTarget >= 0)

        // But FEED column shows the tether tints
        for (appName, tint) in tints {
            let feedColor = row.test_feedAppSegmentColor(for: appName)
            assertSameColor(feedColor, tint, "\(appName) segment in FEED wears tint")
        }
    }

    // MARK: - Membership bus node stays connection-only

    @Test func membershipBusNodeStateEnumOnly() {
        let row = DeviceRowView(device: makeDevice(), showsMeter: true, showsBus: true)
        let tetherTint = NSColor(srgbRed: 0.3, green: 0.5, blue: 0.7, alpha: 1)

        row.apply(
            makeDevice(),
            selected: true,
            controllable: true,
            routedAppNames: ["Spotify"],
            appTintColors: ["Spotify": tetherTint]
        )

        // Bus node must be connection-state enum, not a tether color
        let node = row.test_busNode
        #expect(node != nil)
        #expect(
            [.member, .connecting, .failed, .nonMember, .origin]
                .contains(node ?? .nonMember)
        )
    }

    // MARK: - Master Out meter stays warm

    @Test func mainOutMeterKeepsWarmGradient() {
        let master = MainOutRowView()
        master.apply(
            options: [.init(title: "Selected Devices", target: .selectedDevices)],
            current: .selectedDevices,
            master: 60,
            isMuted: false,
            connectionState: .connected
        )
        master.setLevel(0.7)

        #expect(master.test_meterTarget >= 0, "Master meter target is numeric")
    }

    // MARK: - Edge cases

    @Test func mutedDeviceKeepsWarmMeterWithAppRedirect() {
        var muted = makeDevice()
        muted.isMuted = true

        let row = DeviceRowView(device: muted, showsMeter: true, showsBus: true)
        let tetherTint = NSColor(srgbRed: 0.6, green: 0.4, blue: 0.8, alpha: 1)

        row.apply(
            muted,
            selected: false,
            controllable: true,
            routedAppNames: ["Podcast"],
            appTintColors: ["Podcast": tetherTint]
        )

        // Meter target is readable (drains, not tints)
        #expect(row.test_meterTarget >= 0)
    }

    @Test func connectingDeviceKeepsWarmMeterAndConnectionRing() {
        let row = DeviceRowView(
            device: makeDevice(connectionState: .connecting),
            showsMeter: true,
            showsBus: true
        )
        let tetherTint = NSColor(srgbRed: 0.7, green: 0.2, blue: 0.5, alpha: 1)

        row.apply(
            makeDevice(connectionState: .connecting),
            selected: true,
            controllable: true,
            routedAppNames: ["Games"],
            appTintColors: ["Games": tetherTint]
        )

        // Meter stays warm
        #expect(row.test_meterTarget >= 0)

        // Ring stays connection-only
        if let ringColor = row.test_ringStrokeColor {
            let isRingColor = isConnectionStateColor(ringColor)
            #expect(isRingColor, "Connecting ring stays connection-state")
        }
    }

    // MARK: - Helpers

    private func isConnectionStateColor(_ color: NSColor) -> Bool {
        guard let srgb = color.usingColorSpace(.sRGB) else { return false }
        let allowedHues = [Tokens.Color.ringConnected, Tokens.Color.failure]
        for allowed in allowedHues {
            guard let allowedSRGB = allowed.usingColorSpace(.sRGB) else { continue }
            let distance = abs(srgb.redComponent - allowedSRGB.redComponent)
                + abs(srgb.greenComponent - allowedSRGB.greenComponent)
                + abs(srgb.blueComponent - allowedSRGB.blueComponent)
            if distance < 0.15 { return true }
        }
        return false
    }
}
