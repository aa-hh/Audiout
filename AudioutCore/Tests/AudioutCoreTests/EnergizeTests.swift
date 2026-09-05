// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import Testing
@testable import AudioutCore
@testable import AudioutSharedUI
@testable import AudioutPopoverUI

/// Coverage for the **energize source-switch sequence** (Warm Signal v4.1 item
/// 9): the "press-play" beat that plays when Main Audio switches source
/// (Selected Devices ↔ a group).
///
/// The sequence is drawing/wiring-only — it never mutates the
/// membership/connection/routing model — so these tests assert two seams:
///
///  1. **Row level** (`DeviceRowView.energizePending`): a targeted member that
///     hasn't started connecting (`.off`) renders the gold-dashed `.connecting`
///     node the instant the switch fires (the beat has no node form of its own),
///     holds it as its real state advances to `.connecting` then `.member`, ships
///     the spoken "connecting" equivalent, and — under Reduce Motion — is REMOVED
///     (the node snaps to its resolved rendering), including on a live mid-flight
///     Reduce Motion toggle.
///  2. **Controller level** (`PopoverController`): a real source switch raises
///     the beat over the selected `.off` members, posts the VoiceOver
///     transition announcement, prunes the beat as members leave `.off`, and
///     fires the one-shot settle announcement once the target stops moving —
///     with Reduce Motion removing the beat entirely (announcement still spoken).
@MainActor
@Suite final class EnergizeTests: IsolatedSuite {

    // MARK: Row-level pending beat (DeviceRowView)

    private func makeBusRow() -> DeviceRowView {
        DeviceRowView(device: makeDevice(connectionState: .off), showsToggle: true,
                      showsMeter: true, showsBus: true)
    }

    private func makeDevice(id: String = "en-dev",
                            connectionState: ConnectionState) -> Device {
        Device(id: id, name: "Energize Speaker", kind: .homePod,
               connectionState: connectionState)
    }

    @Test func offMemberWithPendingBeatRendersDashedPendingNode() {
        let row = makeBusRow()
        row.test_reduceMotionOverride = false
        row.apply(makeDevice(connectionState: .off), selected: true,
                  controllable: true, energizePending: true)
        #expect(row.test_energizePending, "the host raised the beat")
        #expect(row.test_busNode == .connecting,
                       "an .off member on the energize beat renders the gold dashed connecting node")
    }

    @Test func connectingStateSupersedesThePendingBeat() {
        let row = makeBusRow()
        row.test_reduceMotionOverride = false
        // The beat stays raised, but the real connection state has advanced —
        // the model node wins so the beat hands off cleanly to `.connecting`.
        row.apply(makeDevice(connectionState: .connecting), selected: true,
                  controllable: true, energizePending: true)
        #expect(row.test_busNode == .connecting,
                       "once the device is .connecting, that model node supersedes the pending beat")
    }

    @Test func reduceMotionRemovesThePendingBeatSnappingToResolved() {
        let row = makeBusRow()
        row.test_reduceMotionOverride = true
        row.apply(makeDevice(connectionState: .off), selected: true,
                  controllable: true, energizePending: true)
        #expect(row.test_busNode == .member,
                       "under Reduce Motion the beat is removed — the selected .off member snaps to its resolved filled node")
    }

    @Test func midFlightReduceMotionToggleDropsThePendingBeatLive() {
        let row = makeBusRow()
        row.test_reduceMotionOverride = false
        row.apply(makeDevice(connectionState: .off), selected: true,
                  controllable: true, energizePending: true)
        #expect(row.test_busNode == .connecting, "beat visible while motion is allowed")

        // Reduce Motion flips ON mid-sequence: the OS posts the display-options
        // notification; the row must re-derive its node off it (not wait for the
        // next apply) and snap to resolved.
        row.test_reduceMotionOverride = true
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        #expect(row.test_busNode == .member,
                       "a live Reduce Motion toggle drops the beat immediately")
    }

    @Test func pendingBeatShipsTheSpokenConnectingEquivalent() {
        let row = makeBusRow()
        row.test_reduceMotionOverride = false
        row.apply(makeDevice(connectionState: .off), selected: true,
                  controllable: true, energizePending: true)
        #expect(row.test_busNode == .connecting)
        #expect(row.test_accessibilityLabel?.contains("connecting") ?? false,
                      "the new pending visual ships a VoiceOver equivalent: the row speaks 'connecting'")
    }

    @Test func pendingBeatIsSilentUnderReduceMotion() {
        let row = makeBusRow()
        row.test_reduceMotionOverride = true
        row.apply(makeDevice(connectionState: .off), selected: true,
                  controllable: true, energizePending: true)
        #expect(!(row.test_accessibilityLabel?.contains("connecting") ?? false),
                       "with the beat removed there is nothing to speak — a settled .off member is silent")
    }

    @Test func defaultCallersNeverRaiseTheBeat() {
        let row = makeBusRow()
        row.test_reduceMotionOverride = false
        row.apply(makeDevice(connectionState: .off), selected: true, controllable: true)
        #expect(!row.test_energizePending)
        #expect(row.test_busNode == .member,
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

    @Test func sourceSwitchRaisesPendingBeatOnOffMembersAndAnnounces() {
        let fleet = makeControllerFleet()
        let (popover, _, _) = makePopover(fleet: fleet)
        for id in ["en-a", "en-b", "en-c"] { _ = popover.test_toggleDeviceEnabled(deviceID: id, on: true) }
        popover.update(devices: fleet)

        popover.test_reduceMotionOverride = false
        popover.test_switchMainOut(.selectedDevices)

        #expect(popover.test_energizePendingIDs == ["en-a", "en-b"],
                       "only the selected members that hadn't started connecting get the beat")
        #expect(popover.test_energizeActive)
        #expect(popover.test_deviceRow(for: "en-a")?.test_busNode == .connecting)
        #expect(popover.test_deviceRow(for: "en-c")?.test_busNode == .member,
                       "an already-connected member never drops to the beat's connecting node")
        #expect(popover.test_lastEnergizeAnnouncement ==
                       "Switching Main Audio to Selected Speakers")
    }

    @Test func beatPrunesAsMembersConnectThenSettles() {
        var fleet = makeControllerFleet()
        let (popover, _, _) = makePopover(fleet: fleet)
        for id in ["en-a", "en-b", "en-c"] { _ = popover.test_toggleDeviceEnabled(deviceID: id, on: true) }
        popover.update(devices: fleet)
        popover.test_reduceMotionOverride = false
        popover.test_switchMainOut(.selectedDevices)
        #expect(popover.test_energizePendingIDs == ["en-a", "en-b"])

        // en-a starts connecting → its beat prunes, the sequence is still active.
        fleet[0].connectionState = .connecting
        popover.update(devices: fleet)
        #expect(popover.test_energizePendingIDs == ["en-b"],
                       "a member that left .off drops the beat (its model node takes over)")
        #expect(popover.test_energizeActive)

        // Everything lands connected → the sequence settles, one-shot summary.
        fleet[0].connectionState = .connected
        fleet[1].connectionState = .connected
        popover.update(devices: fleet)
        #expect(popover.test_energizePendingIDs.isEmpty)
        #expect(!popover.test_energizeActive, "the switch has stopped moving")
        #expect(popover.test_lastEnergizeAnnouncement ==
                       "Selected Speakers ready, 3 connected")
    }

    @Test func reduceMotionRemovesTheBeatButStillAnnounces() {
        let fleet = makeControllerFleet()
        let (popover, _, _) = makePopover(fleet: fleet)
        for id in ["en-a", "en-b", "en-c"] { _ = popover.test_toggleDeviceEnabled(deviceID: id, on: true) }
        popover.update(devices: fleet)

        popover.test_reduceMotionOverride = true
        popover.test_switchMainOut(.selectedDevices)

        #expect(popover.test_energizePendingIDs.isEmpty,
                      "Reduce Motion removes the sweep — no member drops to the pending beat")
        #expect(popover.test_deviceRow(for: "en-a")?.test_busNode == .member,
                       "the .off members snap straight to their resolved nodes")
        #expect(popover.test_lastEnergizeAnnouncement ==
                       "Switching Main Audio to Selected Speakers",
                       "the transition is still spoken — Reduce Motion drops the animation, not the announcement")
    }
}
