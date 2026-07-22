import XCTest
import AudiouterCore
@testable import AudiouterSharedUI

/// T10: AP1 rows are LIVE, not the retired "coming soon" gate
/// (`DeviceRowUnsupportedTests.swift`, deleted). An AP1 device
/// (`supportsAirPlay2 == false`), non-local, available, renders identically to
/// an AP2 row — full alpha, an enabled checkbox/slider/mute, and a normal
/// accessibility label with no "not yet supported" wording. `supportsAirPlay2`
/// is purely informational now (NativeBackend/T7 drives AP1 through the same
/// shared engine as AP2); `DeviceRowView` reads it for exactly ONE thing (v4.1
/// item 3): the monochrome "AP1" micro-tag prefixed to a bus row's FEED
/// column (`test_feedHasAP1Tag`) — never for anything gating alpha,
/// enablement, or wording, which is what THIS file covers.
final class DeviceRowAirPlay1LiveTests: XCTestCase {

    private func makeAP1Device(isSelected: Bool = false) -> Device {
        Device(id: "attic-ap1", name: "Attic Speaker", kind: .generic,
               supportsAirPlay2: false, volume: 20, isSelected: isSelected)
    }

    func testAP1RowRendersFullAlphaNotDimmed() {
        let device = makeAP1Device()
        let row = DeviceRowView(device: device)
        row.apply(device, selected: false, controllable: true)

        XCTAssertEqual(row.alphaValue, 1.0, "an AP1 row must render at full alpha, same as AP2 — not the retired dimmed gate")
        XCTAssertFalse(row.test_isSelectionDimmed, "AP1 alone must not dim the checkbox")
    }

    func testAP1RowCheckboxSliderMuteAreEnabled() {
        let device = makeAP1Device()
        let row = DeviceRowView(device: device)
        row.apply(device, selected: true, controllable: true)

        XCTAssertTrue(row.test_isEnabledOn, "an AP1 device can join Selected Devices like any AP2 device")
        XCTAssertTrue(row.test_isSliderEnabled, "an AP1 row's volume slider is drivable")
        // Mute mirrors the slider's enabled state (same `controllable` gate).
        row.test_toggleMute(true)
        XCTAssertEqual(row.test_muteTintColor, .controlAccentColor, "mute still works live on an AP1 row")
    }

    func testAP1RowCanBeToggledOnViaDelegate() {
        let device = makeAP1Device()
        let row = DeviceRowView(device: device)
        row.apply(device, selected: false, controllable: false)

        final class RecordingDelegate: DeviceRowView.Delegate {
            var toggledFor: String?
            var toggledOn: Bool?
            func deviceRow(_ row: DeviceRowView, didSetVolume volume: Int, for id: String) {}
            func deviceRow(_ row: DeviceRowView, didToggleMute muted: Bool, for id: String) {}
            func deviceRow(_ row: DeviceRowView, didToggleEnabled on: Bool, for id: String) {
                toggledFor = id
                toggledOn = on
            }
        }
        let delegate = RecordingDelegate()
        row.delegate = delegate

        row.test_clickName()

        XCTAssertEqual(delegate.toggledFor, device.id, "an AP1 row's name-click drives the same enable path as AP2")
        XCTAssertEqual(delegate.toggledOn, true)
    }

    func testAP1RowAccessibilityLabelHasNoUnsupportedWording() {
        let device = makeAP1Device(isSelected: true)
        let row = DeviceRowView(device: device)
        row.apply(device, selected: true, controllable: true)

        let label = row.accessibilityLabel() ?? ""
        XCTAssertFalse(label.lowercased().contains("not yet supported"), "the retired 'coming soon' wording must never appear on a live AP1 row")
        XCTAssertFalse(label.lowercased().contains("unsupported"), "AP1 rows carry no 'unsupported' language")
        XCTAssertTrue(label.contains(device.name), "the label still reads as a normal device row")
        XCTAssertTrue(label.contains("selected"), "the normal 'selected'/'not selected' membership phrasing, not a disabled explanation")
    }
}
