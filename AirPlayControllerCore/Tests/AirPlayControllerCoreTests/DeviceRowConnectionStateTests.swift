import XCTest
import AirPlayControllerCore
@testable import AirPlayControllerSharedUI

/// Row-focused tests for the connection-status slot + sublabel (brief §6):
/// the four `ConnectionState` renderings (`test_statusKind`/`test_statusText`),
/// the warning tap wiring (`test_tapWarning`), and that a repeated `apply` call
/// fully resets the slot rather than leaving a stale spinner running.
final class DeviceRowConnectionStateTests: XCTestCase {

    private func makeDevice(connectionState: ConnectionState = .off) -> Device {
        Device(id: "dev-1", name: "Test Speaker", kind: .homePod, connectionState: connectionState)
    }

    // MARK: Four states → four slot renderings

    func testOffShowsNoSlotAndNoSublabel() {
        let row = DeviceRowView(device: makeDevice(connectionState: .off))
        XCTAssertEqual(row.test_statusKind, .none)
        XCTAssertNil(row.test_statusText)
    }

    func testConnectingShowsSpinnerAndSublabel() {
        let row = DeviceRowView(device: makeDevice(connectionState: .connecting))
        XCTAssertEqual(row.test_statusKind, .spinner)
        XCTAssertEqual(row.test_statusText, "Connecting…")
    }

    func testReconnectingShowsSpinnerWithDistinctSublabel() {
        let row = DeviceRowView(device: makeDevice(connectionState: .reconnecting))
        XCTAssertEqual(row.test_statusKind, .spinner)
        XCTAssertEqual(row.test_statusText, "Reconnecting…")
    }

    func testConnectedShowsGreenDotAndSublabel() {
        let row = DeviceRowView(device: makeDevice(connectionState: .connected))
        XCTAssertEqual(row.test_statusKind, .connectedDot)
        XCTAssertEqual(row.test_statusText, "Connected")
    }

    func testFailedShowsWarningAndSublabel() {
        let row = DeviceRowView(device: makeDevice(connectionState: .failed(.init(cause: .notResponding))))
        XCTAssertEqual(row.test_statusKind, .warning)
        XCTAssertEqual(row.test_statusText, "Couldn't connect")
    }

    // MARK: Repeated `apply` fully resets the slot (no stale spinner)

    func testRepeatedApplyClearsStaleSpinnerWhenLeavingConnecting() {
        let row = DeviceRowView(device: makeDevice(connectionState: .connecting))
        XCTAssertEqual(row.test_statusKind, .spinner)

        row.apply(makeDevice(connectionState: .connected), selected: true)
        XCTAssertEqual(row.test_statusKind, .connectedDot)
        XCTAssertEqual(row.test_statusText, "Connected")
    }

    func testRepeatedApplyClearsSlotWhenReturningToOff() {
        let row = DeviceRowView(device: makeDevice(connectionState: .failed(.init(cause: .vanished))))
        XCTAssertEqual(row.test_statusKind, .warning)

        row.apply(makeDevice(connectionState: .off), selected: false)
        XCTAssertEqual(row.test_statusKind, .none)
        XCTAssertNil(row.test_statusText)
    }

    func testSameStateReappliedDoesNotDuplicateOrDropTheSlot() {
        // A re-render for an unrelated reason (e.g. a volume echo) while the
        // state is unchanged must not leave the slot in a half-updated state.
        let row = DeviceRowView(device: makeDevice(connectionState: .connecting))
        row.apply(makeDevice(connectionState: .connecting), selected: false)
        XCTAssertEqual(row.test_statusKind, .spinner)
        XCTAssertEqual(row.test_statusText, "Connecting…")
    }

    // MARK: Warning tap → delegate

    private final class RecordingDelegate: DeviceRowView.Delegate {
        var diagnosisRequestedFor: String?
        func deviceRow(_ row: DeviceRowView, didSetVolume volume: Int, for id: String) {}
        func deviceRow(_ row: DeviceRowView, didToggleMute muted: Bool, for id: String) {}
        func deviceRow(_ row: DeviceRowView, didToggleEnabled on: Bool, for id: String) {}
        func deviceRow(_ row: DeviceRowView, didRequestDiagnosisFor id: String) {
            diagnosisRequestedFor = id
        }
    }

    func testTapWarningFiresDelegateWithDeviceID() {
        let row = DeviceRowView(device: makeDevice(connectionState: .failed(.init(cause: .refusedOrBusy))))
        let delegate = RecordingDelegate()
        row.delegate = delegate

        row.test_tapWarning()

        XCTAssertEqual(delegate.diagnosisRequestedFor, "dev-1")
    }

    func testDefaultNoOpDelegateDoesNotCrashOnDiagnosisRequest() {
        // Mirrors the `didToggleEnabled` back-compat pattern: a conformer that
        // doesn't implement `didRequestDiagnosisFor` still compiles and no-ops.
        final class NarrowDelegate: DeviceRowView.Delegate {
            func deviceRow(_ row: DeviceRowView, didSetVolume volume: Int, for id: String) {}
            func deviceRow(_ row: DeviceRowView, didToggleMute muted: Bool, for id: String) {}
        }
        let row = DeviceRowView(device: makeDevice(connectionState: .failed(.init(cause: .unknown))))
        let narrowDelegate = NarrowDelegate()
        row.delegate = narrowDelegate
        row.test_tapWarning()   // should not crash
    }
}
