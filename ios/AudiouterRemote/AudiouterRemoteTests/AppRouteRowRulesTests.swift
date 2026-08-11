// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
import SwiftUI
import AudiouterProtocol
@testable import AudiouterRemote

/// The Apps-tab rules that live on `AppRouteRowView`/`AppGlyph` rather than on
/// the wire: display order, the destination pill's text, and what VoiceOver
/// says for a row. `AppRouteState` carries no display order and no device
/// name — those are exactly what these statics resolve.
@Suite struct AppRouteRowRulesTests {

    // MARK: - Fixtures

    private func makeRoute(
        bundleID: String = "com.example.app",
        displayName: String = "Example",
        kind: String = "noRedirect",
        deviceID: String? = nil,
        volume: Int = 40,
        isRunning: Bool = true
    ) -> AppRouteState {
        AppRouteState(
            bundleID: bundleID,
            displayName: displayName,
            destinationKind: kind,
            deviceID: deviceID,
            volume: volume,
            isRunning: isRunning
        )
    }

    private func makeDevice(id: String = "d1", name: String = "Kitchen HomePod") -> DeviceState {
        DeviceState(
            id: id,
            name: name,
            kind: "generic",
            iconSymbolName: "hifispeaker.fill",
            isAvailable: true,
            supportsAirPlay2: true,
            isLocalDevice: false,
            volume: 50,
            isMuted: false,
            isSelected: false,
            isMainOutMember: false,
            connection: DeviceState.ConnectionInfo(state: "connected")
        )
    }

    // MARK: - Display order: running first, silent last, stable within each half

    @Test func runningAppsPrecedeNotRunningApps() {
        let routes = [
            makeRoute(bundleID: "a", isRunning: false),
            makeRoute(bundleID: "b", isRunning: true),
            makeRoute(bundleID: "c", isRunning: false),
            makeRoute(bundleID: "d", isRunning: true),
        ]
        let sorted = AppRouteRowView.sortedForDisplay(routes)
        #expect(sorted.map(\.bundleID) == ["b", "d", "a", "c"])
    }

    @Test func orderWithinEachHalfPreservesInputOrder() {
        // Two filter passes, not a comparator — a stable sort would agree,
        // but this is the property the implementation actually owes: nothing
        // reorders WITHIN a half.
        let routes = [
            makeRoute(bundleID: "run1", isRunning: true),
            makeRoute(bundleID: "silent1", isRunning: false),
            makeRoute(bundleID: "run2", isRunning: true),
            makeRoute(bundleID: "silent2", isRunning: false),
            makeRoute(bundleID: "run3", isRunning: true),
            makeRoute(bundleID: "silent3", isRunning: false),
        ]
        let sorted = AppRouteRowView.sortedForDisplay(routes)
        #expect(sorted.map(\.bundleID) == ["run1", "run2", "run3", "silent1", "silent2", "silent3"])
    }

    @Test func allRunningInputPassesThroughUnchanged() {
        let routes = [
            makeRoute(bundleID: "a", isRunning: true),
            makeRoute(bundleID: "b", isRunning: true),
            makeRoute(bundleID: "c", isRunning: true),
        ]
        #expect(AppRouteRowView.sortedForDisplay(routes).map(\.bundleID) == ["a", "b", "c"])
    }

    @Test func allSilentInputPassesThroughUnchanged() {
        let routes = [
            makeRoute(bundleID: "a", isRunning: false),
            makeRoute(bundleID: "b", isRunning: false),
            makeRoute(bundleID: "c", isRunning: false),
        ]
        #expect(AppRouteRowView.sortedForDisplay(routes).map(\.bundleID) == ["a", "b", "c"])
    }

    // MARK: - Destination title

    @Test func noRedirectReadsAsNoRedirect() {
        #expect(AppRouteRowView.destinationTitle(for: makeRoute(kind: "noRedirect"), devices: []) == "No Redirect")
    }

    @Test func currentDeviceReadsAsThisMac() {
        #expect(AppRouteRowView.destinationTitle(for: makeRoute(kind: "currentDevice"), devices: []) == "This Mac")
    }

    @Test func aMatchingDeviceRedirectReadsAsTheDevicesName() {
        let devices = [makeDevice(id: "d1", name: "Kitchen HomePod")]
        let route = makeRoute(kind: "device", deviceID: "d1")
        #expect(AppRouteRowView.destinationTitle(for: route, devices: devices) == "Kitchen HomePod")
    }

    @Test func aDeviceRedirectWithNoMatchingIDReadsAsUnavailableDevice() {
        let devices = [makeDevice(id: "d2", name: "Living Room")]
        let route = makeRoute(kind: "device", deviceID: "d1")
        #expect(AppRouteRowView.destinationTitle(for: route, devices: devices) == "Unavailable Device")
    }

    @Test func anUnknownKindFallsBackToItsRawValue() {
        let route = makeRoute(kind: "somethingNew")
        #expect(AppRouteRowView.destinationTitle(for: route, devices: []) == "somethingNew")
    }

    // MARK: - Which routes count as "redirected to a device" (the pill's gold)

    @Test func onlyDeviceKindIsRedirectedToADevice() {
        #expect(AppRouteRowView.isRedirectedToDevice(makeRoute(kind: "device", deviceID: "d1")))
        #expect(!AppRouteRowView.isRedirectedToDevice(makeRoute(kind: "noRedirect")))
        #expect(!AppRouteRowView.isRedirectedToDevice(makeRoute(kind: "currentDevice")))
    }

    // MARK: - Spoken value

    @Test func spokenValueForNoRedirect() {
        let route = makeRoute(kind: "noRedirect", isRunning: true)
        #expect(AppRouteRowView.spokenValue(for: route, displayVolume: 40, devices: []) == "40 percent, no redirect")
    }

    @Test func spokenValueForCurrentDevice() {
        let route = makeRoute(kind: "currentDevice", isRunning: true)
        #expect(AppRouteRowView.spokenValue(for: route, displayVolume: 40, devices: []) == "40 percent, this Mac")
    }

    @Test func spokenValueForADeviceRedirectNamesTheDevice() {
        let devices = [makeDevice(id: "d1", name: "Kitchen HomePod")]
        let route = makeRoute(kind: "device", deviceID: "d1", isRunning: true)
        #expect(AppRouteRowView.spokenValue(for: route, displayVolume: 40, devices: devices)
                == "40 percent, Kitchen HomePod")
    }

    @Test func spokenValueAppendsNotRunningOnlyWhenNotRunning() {
        let running = makeRoute(kind: "noRedirect", isRunning: true)
        #expect(AppRouteRowView.spokenValue(for: running, displayVolume: 40, devices: []) == "40 percent, no redirect")

        let notRunning = makeRoute(kind: "noRedirect", isRunning: false)
        #expect(AppRouteRowView.spokenValue(for: notRunning, displayVolume: 40, devices: [])
                == "40 percent, no redirect, not running")
    }

    // MARK: - AppGlyph.symbolName

    @Test func symbolNameMatchesOnBundleID() {
        #expect(AppGlyph.symbolName(bundleID: "com.spotify.client", displayName: "Spotify") == "music.note")
    }

    @Test func symbolNameFallsBackToDisplayNameWhenBundleIDIsUnrecognised() {
        #expect(AppGlyph.symbolName(bundleID: "com.example.mystery", displayName: "My Zoom Clone") == "video")
    }

    @Test func symbolNameIsNilForAnUnknownApp() {
        #expect(AppGlyph.symbolName(bundleID: "com.example.other", displayName: "Another App") == nil)
    }

    // MARK: - AppGlyph.initial

    @Test func initialIsTheFirstLetterUppercased() {
        #expect(AppGlyph.initial(for: "spotify") == "S")
        #expect(AppGlyph.initial(for: "Zoom") == "Z")
    }

    @Test func initialIsAQuestionMarkForEmptyOrWhitespaceNames() {
        #expect(AppGlyph.initial(for: "") == "?")
        #expect(AppGlyph.initial(for: "   ") == "?")
    }
}
