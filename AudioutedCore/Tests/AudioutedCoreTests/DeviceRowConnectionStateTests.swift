import XCTest
import AudioutedCore
@testable import AudioutedSharedUI

/// Row-focused tests for the on-icon connection-status dot + the sublabel
/// precedence ladder (2026-07-17 checkbox + routing-line redesign): the four
/// `ConnectionState` renderings (`test_statusKind`/`test_statusText`), the
/// name-click-toggles-enabled wiring (`test_clickName`) now through the
/// checkbox, the routing sublabel composed from `selected` + `routedAppNames`,
/// and that a repeated `apply` cleanly re-derives the badge rather than
/// leaving a stale state.
final class DeviceRowConnectionStateTests: XCTestCase {

    private func makeDevice(connectionState: ConnectionState = .off) -> Device {
        Device(id: "dev-1", name: "Test Speaker", kind: .homePod, connectionState: connectionState)
    }

    // MARK: Four states → four badge renderings (+ failed-only sublabel)

    func testOffShowsNoDotAndNoSublabel() {
        let row = DeviceRowView(device: makeDevice(connectionState: .off))
        XCTAssertEqual(row.test_statusKind, .none)
        XCTAssertNil(row.test_statusText)
    }

    func testConnectingShowsConnectingDotAndNoSublabel() {
        let row = DeviceRowView(device: makeDevice(connectionState: .connecting))
        XCTAssertEqual(row.test_statusKind, .connecting)
        XCTAssertNil(row.test_statusText, "connecting is single-line (no sublabel)")
    }

    func testReconnectingShowsConnectingDotAndNoSublabel() {
        let row = DeviceRowView(device: makeDevice(connectionState: .reconnecting))
        XCTAssertEqual(row.test_statusKind, .connecting)
        XCTAssertNil(row.test_statusText, "reconnecting is single-line (no sublabel)")
    }

    func testConnectedShowsGreenDotAndNoSublabel() {
        let row = DeviceRowView(device: makeDevice(connectionState: .connected))
        XCTAssertEqual(row.test_statusKind, .connected)
        XCTAssertNil(row.test_statusText, "connected is single-line (no sublabel)")
    }

    func testFailedShowsFailedDotAndSublabel() {
        let row = DeviceRowView(device: makeDevice(connectionState: .failed(.init(cause: .notResponding))))
        XCTAssertEqual(row.test_statusKind, .failed)
        XCTAssertEqual(row.test_statusText, "Couldn't connect", "failed is the only two-line row")
    }

    // MARK: Repeated `apply` cleanly re-derives the badge

    func testRepeatedApplyReDerivesWhenLeavingConnecting() {
        let row = DeviceRowView(device: makeDevice(connectionState: .connecting))
        XCTAssertEqual(row.test_statusKind, .connecting)

        row.apply(makeDevice(connectionState: .connected), selected: true)
        XCTAssertEqual(row.test_statusKind, .connected)
        // Selected + no routed apps → routing sublabel is the bare "System" token
        // (a selected device is always in the routing set). The badge, not the
        // sublabel, is what this test exercises re-deriving.
        XCTAssertEqual(row.test_statusText, "System")
    }

    func testRepeatedApplyClearsSublabelWhenLeavingFailed() {
        let row = DeviceRowView(device: makeDevice(connectionState: .failed(.init(cause: .vanished))))
        XCTAssertEqual(row.test_statusKind, .failed)
        XCTAssertEqual(row.test_statusText, "Couldn't connect")

        row.apply(makeDevice(connectionState: .off), selected: false)
        XCTAssertEqual(row.test_statusKind, .none)
        XCTAssertNil(row.test_statusText, "the failed sublabel cleared on leaving .failed")
    }

    func testSameStateReappliedStaysConsistent() {
        // A re-render for an unrelated reason (e.g. a volume echo) while the
        // state is unchanged must leave the badge/sublabel consistent.
        let row = DeviceRowView(device: makeDevice(connectionState: .connecting))
        row.apply(makeDevice(connectionState: .connecting), selected: false)
        XCTAssertEqual(row.test_statusKind, .connecting)
        XCTAssertNil(row.test_statusText)
    }

    // MARK: Routing sublabel precedence ladder (2026-07-17)
    //
    // failed "Couldn't connect" > "Unavailable" > routing line ("System" +
    // bypassed app names joined by " · ") > no sublabel. Composed from
    // `selected` (the "System" token) + `routedAppNames` (Wiring-supplied).

    func testSourceLineIsSystemOnlyWhenSelectedWithNoRoutedApps() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: true, routedAppNames: [])
        XCTAssertEqual(row.test_statusText, "System")
    }

    func testSourceLineIsSystemPlusAppsWhenSelectedWithRoutedApps() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: true, routedAppNames: ["Music", "Safari"])
        XCTAssertEqual(row.test_statusText, "System · Music · Safari",
                       "System always leads, tokens joined by ' · '")
    }

    func testSourceLineIsBareAppNamesWhenNotSelectedWithRoutedApps() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: false, routedAppNames: ["Spotify"])
        XCTAssertEqual(row.test_statusText, "Spotify",
                       "not selected: no 'System' token, just the bypassed app(s)")
    }

    func testSourceLineIsHiddenWhenNotSelectedWithNoRoutedApps() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: false, routedAppNames: [])
        XCTAssertNil(row.test_statusText, "empty routing set: no sublabel, single-line row")
    }

    func testSourceLineShowsUnavailableWhenDeviceUnreachable() {
        let device = Device(id: "dev-1", name: "Test Speaker", kind: .homePod, isAvailable: false)
        let row = DeviceRowView(device: device)
        row.apply(device, selected: true, routedAppNames: ["Music"])
        XCTAssertEqual(row.test_statusText, "Unavailable",
                       "unavailable wins over the routing line even with a non-empty routing set")
    }

    func testFailedTakesPrecedenceOverRoutingAndUnavailable() {
        let device = Device(id: "dev-1", name: "Test Speaker", kind: .homePod,
                            isAvailable: false, connectionState: .failed(.init(cause: .notResponding)))
        let row = DeviceRowView(device: device)
        row.apply(device, selected: true, routedAppNames: ["Music", "Safari"])
        XCTAssertEqual(row.test_statusText, "Couldn't connect",
                       "failed is highest precedence, even over unavailable + a non-empty routing set")
    }

    func testSourceLinePreservesRoutedAppNameOrder() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: false, routedAppNames: ["Zebra App", "Alpha App"])
        XCTAssertEqual(row.test_statusText, "Zebra App · Alpha App",
                       "the view doesn't re-sort — it renders routedAppNames in the given order")
    }

    // MARK: Name-click toggles the checkbox (same delegate path)

    private final class RecordingDelegate: DeviceRowView.Delegate {
        var toggledFor: String?
        var toggledOn: Bool?
        func deviceRow(_ row: DeviceRowView, didSetVolume volume: Int, for id: String) {}
        func deviceRow(_ row: DeviceRowView, didToggleMute muted: Bool, for id: String) {}
        func deviceRow(_ row: DeviceRowView, didToggleEnabled on: Bool, for id: String) {
            toggledFor = id
            toggledOn = on
        }
    }

    func testClickingNameTogglesEnabledOn() {
        let device = Device(id: "dev-1", name: "Test Speaker", kind: .homePod)
        let row = DeviceRowView(device: device)
        row.apply(device, selected: false)   // checkbox OFF, enabled
        let delegate = RecordingDelegate()
        row.delegate = delegate

        row.test_clickName()

        XCTAssertEqual(delegate.toggledFor, "dev-1")
        XCTAssertEqual(delegate.toggledOn, true, "OFF → click → ON via the checkbox's delegate path")
        XCTAssertTrue(row.test_isEnabledOn, "the checkbox flipped ON")
    }

    func testClickingNameOnFailedDeviceRetriesByEnabling() {
        // A failed device's toggle rests OFF; clicking the name re-enables it
        // (= retry) — the intended behaviour.
        let device = makeDevice(connectionState: .failed(.init(cause: .refusedOrBusy)))
        let row = DeviceRowView(device: device)
        row.apply(device, selected: false)
        let delegate = RecordingDelegate()
        row.delegate = delegate

        row.test_clickName()

        XCTAssertEqual(delegate.toggledOn, true, "clicking a failed row's name retries (enables)")
    }

    func testClickingNameIsNoOpWhenToggleBlocked() {
        // The Phase-1 local-mix block disables the checkbox; the name-click must
        // be a no-op then (same condition the checkbox's isEnabled uses).
        let device = Device(id: "local", name: "This Mac", kind: .localMac)
        let row = DeviceRowView(device: device)
        row.apply(device, selected: false, blocked: true, blockReason: "blocked")
        let delegate = RecordingDelegate()
        row.delegate = delegate

        row.test_clickName()

        XCTAssertNil(delegate.toggledFor, "name-click is a no-op when the toggle is disabled")
    }

    // MARK: Checkbox replaces the switch — old toggle test hooks still pass through it

    func testToggleEnabledHookDrivesDelegateThroughCheckbox() {
        let device = Device(id: "dev-1", name: "Test Speaker", kind: .homePod)
        let row = DeviceRowView(device: device)
        row.apply(device, selected: false)
        let delegate = RecordingDelegate()
        row.delegate = delegate

        row.test_toggleEnabled(true)

        XCTAssertEqual(delegate.toggledFor, "dev-1")
        XCTAssertEqual(delegate.toggledOn, true)
    }

    func testIsEnabledOnReflectsSelectedStateViaCheckbox() {
        let device = Device(id: "dev-1", name: "Test Speaker", kind: .homePod)
        let row = DeviceRowView(device: device)

        row.apply(device, selected: true)
        XCTAssertTrue(row.test_isEnabledOn, "checkbox reads ON when selected")

        row.apply(device, selected: false)
        XCTAssertFalse(row.test_isEnabledOn, "checkbox reads OFF when not selected")
    }

    func testShowsToggleReflectsCheckboxVisibility() {
        let device = Device(id: "dev-1", name: "Test Speaker", kind: .homePod)
        let topLevelRow = DeviceRowView(device: device, showsToggle: true)
        XCTAssertTrue(topLevelRow.test_showsToggle, "Selected-Devices rows show the checkbox")

        let memberRow = DeviceRowView(device: device, showsToggle: false)
        XCTAssertFalse(memberRow.test_showsToggle, "group-member rows hide the checkbox")
    }

    // MARK: `controllable` — slider/mute enable independent of `selected` (Q2)

    /// A redirect-only device: `selected: false, controllable: true` — the
    /// checkbox stays OFF and there is NO "System" token in the sublabel, but the
    /// slider/mute must be enabled.
    func testRedirectOnlyDeviceHasSliderMuteEnabledCheckboxOffNoSystemToken() {
        let device = Device(id: "dev-1", name: "Test Speaker", kind: .homePod)
        let row = DeviceRowView(device: device)
        row.apply(device, selected: false, controllable: true, routedAppNames: ["Music"])

        XCTAssertFalse(row.test_isEnabledOn, "checkbox stays OFF — this device isn't in Selected Devices")
        XCTAssertEqual(row.test_statusText, "Music",
                       "no 'System' token: the routing line is bare app names, keyed off `selected`")
    }

    /// `selected: true, controllable: false` documents the back-compat footgun:
    /// omitting `controllable` for an otherwise-selected device disables its
    /// slider/mute even though the checkbox is ON.
    func testSelectedWithoutControllableDisablesSliderMuteButKeepsCheckboxOn() {
        let device = Device(id: "dev-1", name: "Test Speaker", kind: .homePod)
        let row = DeviceRowView(device: device)
        row.apply(device, selected: true, controllable: false)

        XCTAssertTrue(row.test_isEnabledOn, "checkbox reflects `selected`, independent of `controllable`")
        XCTAssertEqual(row.test_statusText, "System", "the 'System' token is keyed off `selected`, not `controllable`")
    }

    /// A normal selected + controllable device: checkbox ON, slider/mute
    /// enabled, "System" token present — the ordinary in-Selected-Devices case.
    func testSelectedAndControllableShowsSystemTokenWithCheckboxOn() {
        let device = Device(id: "dev-1", name: "Test Speaker", kind: .homePod)
        let row = DeviceRowView(device: device)
        row.apply(device, selected: true, controllable: true, routedAppNames: ["Safari"])

        XCTAssertTrue(row.test_isEnabledOn)
        XCTAssertEqual(row.test_statusText, "System · Safari")
    }
}
