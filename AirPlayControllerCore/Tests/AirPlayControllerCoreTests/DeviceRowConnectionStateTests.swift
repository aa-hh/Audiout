import XCTest
import AirPlayControllerCore
@testable import AirPlayControllerSharedUI

/// Row-focused tests for the on-icon connection-status dot + the failed-only
/// sublabel (2026-07-17 redesign): the four `ConnectionState` renderings
/// (`test_statusKind`/`test_statusText`), the name-click-toggles-enabled wiring
/// (`test_clickName`), and that a repeated `apply` cleanly re-derives the badge
/// rather than leaving a stale state.
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
        XCTAssertNil(row.test_statusText)
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

    // MARK: Name-click toggles the ENABLED switch (same delegate path)

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
        row.apply(device, selected: false)   // switch OFF, enabled
        let delegate = RecordingDelegate()
        row.delegate = delegate

        row.test_clickName()

        XCTAssertEqual(delegate.toggledFor, "dev-1")
        XCTAssertEqual(delegate.toggledOn, true, "OFF → click → ON via the switch's delegate path")
        XCTAssertTrue(row.test_isEnabledOn, "the switch flipped ON")
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
        // The Phase-1 local-mix block disables the switch; the name-click must be
        // a no-op then (same condition the switch's isEnabled uses).
        let device = Device(id: "local", name: "This Mac", kind: .localMac)
        let row = DeviceRowView(device: device)
        row.apply(device, selected: false, blocked: true, blockReason: "blocked")
        let delegate = RecordingDelegate()
        row.delegate = delegate

        row.test_clickName()

        XCTAssertNil(delegate.toggledFor, "name-click is a no-op when the toggle is disabled")
    }
}
