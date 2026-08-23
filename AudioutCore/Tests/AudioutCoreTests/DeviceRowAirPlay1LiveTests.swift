import Testing
import AudioutCore
@testable import AudioutSharedUI

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
// `@MainActor` is load-bearing, not decoration: this suite builds and drives
// AppKit views, and every `NSView`-family API is main-actor-only. XCTest ran
// each test method on the main thread, so the annotation was never needed;
// swift-testing schedules non-isolated `@Test` bodies on the cooperative
// pool, where the same calls trip AppKit's "modifications to layout engine
// from a background thread" exception and take the whole process down
// (observed in `AppRowViewTests` during this migration). Do not remove it.
@MainActor
@Suite struct DeviceRowAirPlay1LiveTests {

    private func makeAP1Device(isSelected: Bool = false) -> Device {
        Device(id: "attic-ap1", name: "Attic Speaker", kind: .generic,
               supportsAirPlay2: false, volume: 20, isSelected: isSelected)
    }

    @Test func ap1RowRendersFullAlphaNotDimmed() {
        let device = makeAP1Device()
        let row = DeviceRowView(device: device)
        row.apply(device, selected: false, controllable: true)

        #expect(row.alphaValue == 1.0, "an AP1 row must render at full alpha, same as AP2 — not the retired dimmed gate")
        #expect(!row.test_isSelectionDimmed, "AP1 alone must not dim the checkbox")
    }

    @Test func ap1RowCheckboxSliderMuteAreEnabled() {
        let device = makeAP1Device()
        let row = DeviceRowView(device: device)
        row.apply(device, selected: true, controllable: true)

        #expect(row.test_isEnabledOn, "an AP1 device can join Selected Devices like any AP2 device")
        #expect(row.test_isSliderEnabled, "an AP1 row's volume slider is drivable")
        // Mute mirrors the slider's enabled state (same `controllable` gate).
        row.test_toggleMute(true)
        #expect(row.test_muteTintColor == Tokens.Color.engagedChrome,
                "mute still works live on an AP1 row")
    }

    @Test func ap1RowCanBeToggledOnViaDelegate() {
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

        #expect(delegate.toggledFor == device.id, "an AP1 row's name-click drives the same enable path as AP2")
        #expect(delegate.toggledOn == true)
    }

    @Test func ap1RowAccessibilityLabelHasNoUnsupportedWording() {
        let device = makeAP1Device(isSelected: true)
        let row = DeviceRowView(device: device)
        row.apply(device, selected: true, controllable: true)

        let label = row.accessibilityLabel() ?? ""
        #expect(!label.lowercased().contains("not yet supported"), "the retired 'coming soon' wording must never appear on a live AP1 row")
        #expect(!label.lowercased().contains("unsupported"), "AP1 rows carry no 'unsupported' language")
        #expect(label.contains(device.name), "the label still reads as a normal device row")
        #expect(label.contains("selected"), "the normal 'selected'/'not selected' membership phrasing, not a disabled explanation")
    }
}
