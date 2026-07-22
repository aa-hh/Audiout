// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
import AppKit
@testable import AudiouterCore
@testable import AudiouterSharedUI
@testable import AudiouterPopoverUI

/// Coverage for the **energize source-switch sequence** (Warm Signal v4.1 item
/// 9): the "press-play" beat that plays when Main Audio switches source
/// (Selected Devices ↔ a group).
///
/// The sequence is drawing/wiring-only — it never mutates the
/// membership/connection/routing model — so these tests assert two seams:
///
///  1. **Row level** (`DeviceRowView.energizePending`): a targeted member that
///     hasn't started connecting (`.off`) renders the ember-dashed PENDING node
///     the instant the switch fires, hands off to the live `.connecting` /
///     `.member` node as its real state advances, ships the spoken "connecting"
///     equivalent, and — under Reduce Motion — is REMOVED (the node snaps to its
///     resolved rendering), including on a live mid-flight Reduce Motion toggle.
///  2. **Controller level** (`PopoverController`): a real source switch raises
///     the beat over the selected `.off` members, posts the VoiceOver
///     transition announcement, prunes the beat as members leave `.off`, and
///     fires the one-shot settle announcement once the target stops moving —
///     with Reduce Motion removing the beat entirely (announcement still spoken).
final class EnergizeTests: IsolatedTestCase {

    // MARK: Row-level pending beat (DeviceRowView)

    private func makeBusRow() -> DeviceRowView {
        DeviceRowView(device: makeDevice(connectionState: .off), showsToggle: true,
                      paintsSelectionBackground: false, showsMeter: true, showsBus: true)
    }

    private func makeDevice(id: String = "en-dev",
                            connectionState: ConnectionState) -> Device {
        Device(id: id, name: "Energize Speaker", kind: .homePod,
               connectionState: connectionState)
    }

    func testOffMemberWithPendingBeatRendersDashedPendingNode() {
        let row = makeBusRow()
        row.test_reduceMotionOverride = false
        row.apply(makeDevice(connectionState: .off), selected: true,
                  controllable: true, energizePending: true)
        XCTAssertTrue(row.test_energizePending, "the host raised the beat")
        XCTAssertEqual(row.test_busNode, .pending,
                       "an .off member on the energize beat renders the ember dashed pending node")
    }

    func testConnectingStateSupersedesThePendingBeat() {
        let row = makeBusRow()
        row.test_reduceMotionOverride = false
        // The beat stays raised, but the real connection state has advanced —
        // the model node wins so the beat hands off cleanly to `.connecting`.
        row.apply(makeDevice(connectionState: .connecting), selected: true,
                  controllable: true, energizePending: true)
        XCTAssertEqual(row.test_busNode, .connecting,
                       "once the device is .connecting, that model node supersedes the pending beat")
    }

    func testReduceMotionRemovesThePendingBeatSnappingToResolved() {
        let row = makeBusRow()
        row.test_reduceMotionOverride = true
        row.apply(makeDevice(connectionState: .off), selected: true,
                  controllable: true, energizePending: true)
        XCTAssertEqual(row.test_busNode, .member,
                       "under Reduce Motion the beat is removed — the selected .off member snaps to its resolved filled node")
    }

    func testMidFlightReduceMotionToggleDropsThePendingBeatLive() {
        let row = makeBusRow()
        row.test_reduceMotionOverride = false
        row.apply(makeDevice(connectionState: .off), selected: true,
                  controllable: true, energizePending: true)
        XCTAssertEqual(row.test_busNode, .pending, "beat visible while motion is allowed")

        // Reduce Motion flips ON mid-sequence: the OS posts the display-options
        // notification; the row must re-derive its node off it (not wait for the
        // next apply) and snap to resolved.
        row.test_reduceMotionOverride = true
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        XCTAssertEqual(row.test_busNode, .member,
                       "a live Reduce Motion toggle drops the beat immediately")
    }

    func testPendingBeatShipsTheSpokenConnectingEquivalent() {
        let row = makeBusRow()
        row.test_reduceMotionOverride = false
        row.apply(makeDevice(connectionState: .off), selected: true,
                  controllable: true, energizePending: true)
        XCTAssertEqual(row.test_busNode, .pending)
        XCTAssertTrue(row.test_accessibilityLabel?.contains("connecting") ?? false,
                      "the new pending visual ships a VoiceOver equivalent: the row speaks 'connecting'")
    }

    func testPendingBeatIsSilentUnderReduceMotion() {
        let row = makeBusRow()
        row.test_reduceMotionOverride = true
        row.apply(makeDevice(connectionState: .off), selected: true,
                  controllable: true, energizePending: true)
        XCTAssertFalse(row.test_accessibilityLabel?.contains("connecting") ?? false,
                       "with the beat removed there is nothing to speak — a settled .off member is silent")
    }

    func testDefaultCallersNeverRaiseTheBeat() {
        let row = makeBusRow()
        row.test_reduceMotionOverride = false
        row.apply(makeDevice(connectionState: .off), selected: true, controllable: true)
        XCTAssertFalse(row.test_energizePending)
        XCTAssertEqual(row.test_busNode, .member,
                       "an ordinary selected .off member (no beat) renders its resolved filled node")
    }

    // MARK: Controller-level orchestration (PopoverController)

    private func makeControllerFleet() -> [Device] {
        [
            Device(id: "en-a", name: "Speaker A", kind: .homePod, connectionState: .off),
            Device(id: "en-b", name: "Speaker B", kind: .sonos, connectionState: .off),
            Device(id: "en-c", name: "Speaker C", kind: .appleTV, connectionState: .connected),
        ]
    }

    private func waitFleet(_ backend: MockBackend, count: Int) {
        let deadline = Date().addingTimeInterval(3)
        while backend.devices.count < count && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func makePopover(fleet: [Device]) -> (PopoverController, GroupController, MockBackend) {
        let backend = MockBackend(fleet: fleet, staggerDiscovery: false,
                                  emitsLevels: false, simulatesDropouts: false)
        backend.start()
        waitFleet(backend, count: fleet.count)
        let controller = GroupController(
            backend: backend,
            store: GroupStore(directory: scratchDir.appendingPathComponent("g")),
            routingStore: RoutingStore(directory: scratchDir.appendingPathComponent("r")),
            loadPersisted: false)
        let appRouting = AppRoutingController(
            store: AppRouteStore(directory: scratchDir.appendingPathComponent("a")),
            loadPersisted: false)
        let popover = PopoverController(appRouting: appRouting)
        popover.configure(groupController: controller)
        popover.test_isShownOverride = true
        return (popover, controller, backend)
    }

    func testSourceSwitchRaisesPendingBeatOnOffMembersAndAnnounces() {
        let fleet = makeControllerFleet()
        let (popover, _, _) = makePopover(fleet: fleet)
        for id in ["en-a", "en-b", "en-c"] { _ = popover.test_toggleDeviceEnabled(deviceID: id, on: true) }
        popover.update(devices: fleet)

        popover.test_reduceMotionOverride = false
        popover.test_switchMainOut(.selectedDevices)

        XCTAssertEqual(popover.test_energizePendingIDs, ["en-a", "en-b"],
                       "only the selected members that hadn't started connecting get the beat")
        XCTAssertTrue(popover.test_energizeActive)
        XCTAssertEqual(popover.test_deviceRow(for: "en-a")?.test_busNode, .pending)
        XCTAssertEqual(popover.test_deviceRow(for: "en-c")?.test_busNode, .member,
                       "an already-connected member never drops to pending")
        XCTAssertEqual(popover.test_lastEnergizeAnnouncement,
                       "Switching Main Audio to Selected Devices")
    }

    func testBeatPrunesAsMembersConnectThenSettles() {
        var fleet = makeControllerFleet()
        let (popover, _, _) = makePopover(fleet: fleet)
        for id in ["en-a", "en-b", "en-c"] { _ = popover.test_toggleDeviceEnabled(deviceID: id, on: true) }
        popover.update(devices: fleet)
        popover.test_reduceMotionOverride = false
        popover.test_switchMainOut(.selectedDevices)
        XCTAssertEqual(popover.test_energizePendingIDs, ["en-a", "en-b"])

        // en-a starts connecting → its beat prunes, the sequence is still active.
        fleet[0].connectionState = .connecting
        popover.update(devices: fleet)
        XCTAssertEqual(popover.test_energizePendingIDs, ["en-b"],
                       "a member that left .off drops the beat (its model node takes over)")
        XCTAssertTrue(popover.test_energizeActive)

        // Everything lands connected → the sequence settles, one-shot summary.
        fleet[0].connectionState = .connected
        fleet[1].connectionState = .connected
        popover.update(devices: fleet)
        XCTAssertTrue(popover.test_energizePendingIDs.isEmpty)
        XCTAssertFalse(popover.test_energizeActive, "the switch has stopped moving")
        XCTAssertEqual(popover.test_lastEnergizeAnnouncement,
                       "Selected Devices ready — 3 connected")
    }

    func testReduceMotionRemovesTheBeatButStillAnnounces() {
        let fleet = makeControllerFleet()
        let (popover, _, _) = makePopover(fleet: fleet)
        for id in ["en-a", "en-b", "en-c"] { _ = popover.test_toggleDeviceEnabled(deviceID: id, on: true) }
        popover.update(devices: fleet)

        popover.test_reduceMotionOverride = true
        popover.test_switchMainOut(.selectedDevices)

        XCTAssertTrue(popover.test_energizePendingIDs.isEmpty,
                      "Reduce Motion removes the sweep — no member drops to the pending beat")
        XCTAssertEqual(popover.test_deviceRow(for: "en-a")?.test_busNode, .member,
                       "the .off members snap straight to their resolved nodes")
        XCTAssertEqual(popover.test_lastEnergizeAnnouncement,
                       "Switching Main Audio to Selected Devices",
                       "the transition is still spoken — Reduce Motion drops the animation, not the announcement")
    }
}
