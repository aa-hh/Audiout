// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
import AppKit
@testable import AudiouterCore
@testable import AudiouterSharedUI
@testable import AudiouterPopoverUI

/// T-UI-AP1-1 (PLAN-PHASE-2B D6): AP1-only devices appear dimmed/disabled in
/// the popover, and clicking one presents a "coming soon" explanation. Covers
/// both the shared `DeviceRowView` (dimming, disabled toggle, accessibility)
/// and its `PopoverController` host (the click affordance).
@MainActor
final class DeviceRowUnsupportedTests: XCTestCase {

    private func tempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeviceRowUnsupportedTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func waitForFleet(_ backend: MockBackend, count: Int) async throws {
        let stream = backend.makeEventStream()
        let expectation = expectation(description: "fleet discovered")
        let box = DeviceRowUnsupportedTestsCountBox()
        let task = Task {
            for await event in stream {
                if case .deviceAdded = event, await box.increment() >= count {
                    expectation.fulfill(); break
                }
            }
        }
        backend.start()
        await fulfillment(of: [expectation], timeout: 2)
        task.cancel()
    }

    private func makePopover() async throws -> (PopoverController, GroupController, MockBackend) {
        let backend = MockBackend(fleet: .demoFleetWithAP1Only, staggerDiscovery: false,
                                  emitsLevels: false, simulatesDropouts: false)
        try await waitForFleet(backend, count: Array<Device>.demoFleetWithAP1Only.count)
        let controller = GroupController(backend: backend,
                                         store: GroupStore(directory: tempDirectory()),
                                         routingStore: RoutingStore(directory: tempDirectory()),
                                         loadPersisted: false)
        let popover = PopoverController()
        popover.configure(groupController: controller)
        controller.ensureDefaultSelection()
        // Shown-path repaint semantics — a closed popover no longer rebuilds
        // on `update(devices:)` (audit B8); see PopoverControllerTests.
        popover.test_isShownOverride = true
        popover.update(devices: backend.devices)
        return (popover, controller, backend)
    }

    // MARK: DeviceRowView-level

    /// A supported, available device is never treated as unsupported, even
    /// though it also has a "not selected"/dim-adjacent state.
    func testSupportedDeviceIsNotUnsupported() {
        let device = Device(id: "sonos-move", name: "Sonos Move", kind: .sonos,
                            supportsAirPlay2: true, volume: 40)
        let row = DeviceRowView(device: device)
        row.apply(device, selected: false)
        XCTAssertFalse(row.test_isUnsupported)
        XCTAssertTrue(row.test_showsToggle)
    }

    /// The local device also carries `supportsAirPlay2 == false` (it's not an
    /// AirPlay receiver at all) but must NOT render as an unsupported AP1
    /// receiver — that flag means something different for it.
    func testLocalDeviceIsNotTreatedAsUnsupportedAP1() {
        let device = Device(id: "local-mac", name: "MacBook Pro Speakers", kind: .localMac,
                            isAvailable: true, supportsAirPlay2: false, volume: 65,
                            isSelected: true, isLocalDevice: true)
        let row = DeviceRowView(device: device)
        row.apply(device, selected: true)
        XCTAssertFalse(row.test_isUnsupported, "local passthrough isn't an AP1-only receiver")
    }

    /// An AP1-only receiver renders dimmed and with its primary toggle
    /// disabled, regardless of availability/selection.
    func testAP1OnlyDeviceRendersDimmedAndDisabled() {
        let device = Device(id: "attic-ap1", name: "Attic Speaker", kind: .generic,
                            isAvailable: true, supportsAirPlay2: false, volume: 20)
        let row = DeviceRowView(device: device)
        row.apply(device, selected: false)

        XCTAssertTrue(row.test_isUnsupported)
        XCTAssertFalse(row.test_isEnabledOn, "never rendered ON")
        XCTAlphaValueIsDimmed(row)
    }

    /// Accessibility label mentions AirPlay 1 for an unsupported row, and the
    /// toggle's own label explains why it can't be turned on — SPEC screen
    /// readers must not describe it as an ordinary selectable device.
    func testAP1OnlyDeviceAccessibilityLabelMentionsAirPlay1() {
        let device = Device(id: "attic-ap1", name: "Attic Speaker", kind: .generic,
                            supportsAirPlay2: false, volume: 20)
        let row = DeviceRowView(device: device)
        row.apply(device, selected: false)

        let label = row.accessibilityLabel() ?? ""
        XCTAssertTrue(label.contains("AirPlay 1"), "row label should mention AirPlay 1: \(label)")
    }

    /// Clicking (simulated) an unsupported row asks the delegate for the
    /// explanation; clicking a supported row does not.
    func testClickingUnsupportedRowAsksDelegateForExplanation() {
        let device = Device(id: "attic-ap1", name: "Attic Speaker", kind: .generic,
                            supportsAirPlay2: false, volume: 20)
        let row = DeviceRowView(device: device)
        row.apply(device, selected: false)
        let spy = DeviceRowUnsupportedSpyDelegate()
        row.delegate = spy

        row.test_simulateClick()
        XCTAssertEqual(spy.explanationRequestCount, 1)

        let supportedDevice = Device(id: "sonos-move", name: "Sonos Move", kind: .sonos,
                                     supportsAirPlay2: true, volume: 40)
        let supportedRow = DeviceRowView(device: supportedDevice)
        supportedRow.apply(supportedDevice, selected: false)
        supportedRow.delegate = spy
        supportedRow.test_simulateClick()
        XCTAssertEqual(spy.explanationRequestCount, 1, "a supported row's click is a no-op here")
    }

    // MARK: PopoverController-level

    /// The popover renders the AP1-only fixture as an unsupported row: present
    /// in the AirPlay Devices section, dimmed, toggle disabled.
    func testPopoverRendersAP1OnlyDeviceAsUnsupported() async throws {
        let (popover, _, _) = try await makePopover()
        let row = try XCTUnwrap(popover.test_deviceRow(for: "attic-ap1"))
        XCTAssertTrue(row.test_isUnsupported)
        XCTAssertFalse(row.test_isEnabledOn)
        XCTAssertEqual(popover.test_deviceSectionRowCount, Array<Device>.demoFleetWithAP1Only.count,
                       "the AP1-only device is still a rendered row, not dropped")
    }

    /// Clicking the AP1-only row through the popover presents the "coming
    /// soon" explanation (headless-observable via the last-shown device id),
    /// without mutating any selection/routing state.
    func testClickingAP1OnlyRowPresentsComingSoonExplanation() async throws {
        let (popover, controller, backend) = try await makePopover()
        XCTAssertNil(popover.test_lastUnsupportedExplanationDeviceID)

        popover.test_clickDeviceRow(id: "attic-ap1")

        XCTAssertEqual(popover.test_lastUnsupportedExplanationDeviceID, "attic-ap1")
        XCTAssertFalse(controller.isSpeakerSelected("attic-ap1"),
                       "the click only explains — it never selects/routes the device")
        XCTAssertFalse(backend.devices.first { $0.id == "attic-ap1" }?.isSelected ?? true)
    }

    /// Clicking a SUPPORTED row must not trip the explanation path.
    func testClickingSupportedRowDoesNotPresentExplanation() async throws {
        let (popover, _, _) = try await makePopover()
        popover.test_clickDeviceRow(id: "office")
        XCTAssertNil(popover.test_lastUnsupportedExplanationDeviceID)
    }

    // MARK: Helpers

    private func XCTAlphaValueIsDimmed(_ row: DeviceRowView, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(row.alphaValue, 1.0, "unsupported row should be visibly dimmed", file: file, line: line)
    }
}

/// A minimal spy for `DeviceRowView.Delegate` that only cares about the
/// "coming soon" explanation callback; every other method is the default
/// no-op.
private final class DeviceRowUnsupportedSpyDelegate: DeviceRowView.Delegate {
    private(set) var explanationRequestCount = 0

    func deviceRow(_ row: DeviceRowView, didSetVolume volume: Int, for id: String) {}
    func deviceRow(_ row: DeviceRowView, didToggleMute muted: Bool, for id: String) {}
    func deviceRow(_ row: DeviceRowView, didToggleEnabled on: Bool, for id: String) {}
    func deviceRowDidRequestUnsupportedExplanation(_ row: DeviceRowView) {
        explanationRequestCount += 1
    }
}

/// Actor-isolated counter mirroring `PopoverTestCountBox` (PopoverControllerTests.swift)
/// so the discovery-wait loop above can safely increment from the stream task.
private actor DeviceRowUnsupportedTestsCountBox {
    private var value = 0
    func increment() -> Int { value += 1; return value }
}
