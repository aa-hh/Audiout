// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import Testing
@testable import AudioutCore
@testable import AudioutSharedUI
@testable import AudioutPopoverUI

/// Coverage for the **live-removal undo** — the transient "Removed — Undo"
/// offer raised when unchecking a device silences a room that is audible right
/// now (the app's highest-stakes click).
///
/// Two seams:
///
///  1. **Row level** (`DeviceRowView.removalUndoOffered`): the offer renders
///     only when the host raises it, speaks its own Undo label, and drives the
///     delegate through real `NSButton` dispatch.
///  2. **Controller level** (`PopoverController`): the live/idle gate, the
///     announcement, the undo re-adding membership through the checkbox's own
///     path, and the timer retiring the offer.
@MainActor
@Suite final class RemovalUndoTests: IsolatedSuite {

    // MARK: Row level

    private func makeBusRow(_ device: Device) -> DeviceRowView {
        DeviceRowView(device: device, showsToggle: true,
                      paintsSelectionBackground: false, showsMeter: true, showsBus: true)
    }

    private func makeDevice(id: String = "undo-dev",
                            connectionState: ConnectionState = .connected) -> Device {
        Device(id: id, name: "Kitchen", kind: .homePod, connectionState: connectionState)
    }

    @Test func rowShowsTheOfferOnlyWhenTheHostRaisesIt() {
        let row = makeBusRow(makeDevice())
        row.apply(makeDevice(), selected: false)
        #expect(!row.test_removalUndoOffered, "no offer by default — an ordinary deselect gets nothing")

        row.apply(makeDevice(), selected: false, removalUndoOffered: true)
        #expect(row.test_removalUndoOffered, "the host raised the offer, so the row mounts it")

        row.apply(makeDevice(), selected: false)
        #expect(!row.test_removalUndoOffered, "and it goes the moment the host stops offering it")
    }

    @Test func undoButtonSpeaksWhatItUndoes() {
        let row = makeBusRow(makeDevice())
        row.apply(makeDevice(), selected: false, removalUndoOffered: true)
        #expect(row.test_removalUndoAXLabel == "Undo removing Kitchen from Main Audio")
    }

    @Test func undoClickDrivesTheDelegate() {
        final class Spy: DeviceRowView.Delegate {
            var undoRequests = 0
            func deviceRow(_ row: DeviceRowView, didSetVolume volume: Int, for id: String) {}
            func deviceRow(_ row: DeviceRowView, didToggleMute muted: Bool, for id: String) {}
            func deviceRowDidRequestUndoRemoval(_ row: DeviceRowView) { undoRequests += 1 }
        }
        let row = makeBusRow(makeDevice())
        let spy = Spy()
        row.delegate = spy
        row.apply(makeDevice(), selected: false, removalUndoOffered: true)
        row.test_clickUndoRemoval()
        #expect(spy.undoRequests == 1, "the real NSButton click reaches the delegate")
    }

    // MARK: Controller level

    private func waitFleet(_ backend: MockBackend, count: Int) {
        let deadline = Date().addingTimeInterval(3)
        while backend.devices.count < count && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func makePopover(fleet: [Device]) -> PopoverController {
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
        return popover
    }

    /// One connected member, Main Audio armed: unchecking it silences a room.
    private func makeLivePopover(state: ConnectionState = .connected) -> (PopoverController, [Device]) {
        let fleet = [Device(id: "rm-a", name: "Kitchen", kind: .homePod, connectionState: state)]
        let popover = makePopover(fleet: fleet)
        _ = popover.test_toggleDeviceEnabled(deviceID: "rm-a", on: true)
        popover.update(devices: fleet)
        return (popover, fleet)
    }

    /// Uncheck through the row's REAL checkbox action dispatch.
    private func uncheck(_ popover: PopoverController, _ id: String) {
        popover.test_deviceRow(for: id)?.test_fireCheckboxAction(settingStateTo: false)
    }

    @Test func removingALiveRoomOffersTheUndoAndAnnouncesIt() {
        let (popover, _) = makeLivePopover()
        uncheck(popover, "rm-a")

        #expect(popover.test_removalUndoDeviceID == "rm-a")
        #expect(popover.test_deviceRow(for: "rm-a")?.test_removalUndoOffered == true,
                "the row that lost its membership carries the offer")
        #expect(popover.test_lastEnergizeAnnouncement == "Removed Kitchen from Main Audio",
                "the pill ships its spoken equivalent on the Main-Audio announcement channel")
    }

    @Test func removingAnIdleDeviceOffersNothing() {
        let (popover, _) = makeLivePopover(state: .off)
        uncheck(popover, "rm-a")

        #expect(popover.test_removalUndoDeviceID == nil,
                "an idle removal silences nothing, so there is nothing to undo")
        #expect(popover.test_deviceRow(for: "rm-a")?.test_removalUndoOffered == false)
        #expect(popover.test_lastEnergizeAnnouncement == nil, "…and nothing to announce")
    }

    @Test func undoRestoresMembershipThroughTheCheckboxPath() {
        let (popover, _) = makeLivePopover()
        uncheck(popover, "rm-a")
        #expect(!popover.test_isSpeakerSelected("rm-a"))

        popover.test_deviceRow(for: "rm-a")?.test_clickUndoRemoval()

        #expect(popover.test_isSpeakerSelected("rm-a"),
                "Undo re-adds through the same membership path a re-check takes")
        #expect(popover.test_removalUndoDeviceID == nil, "and the offer retires with the click")
        #expect(popover.test_deviceRow(for: "rm-a")?.test_removalUndoOffered == false)
    }

    @Test func theOfferRetiresOnItsTimer() {
        let (popover, _) = makeLivePopover()
        uncheck(popover, "rm-a")
        #expect(popover.test_removalUndoDeviceID == "rm-a")

        popover.test_expireRemovalUndo()

        #expect(popover.test_removalUndoDeviceID == nil)
        #expect(popover.test_deviceRow(for: "rm-a")?.test_removalUndoOffered == false,
                "the row repaints without the pill when the window closes")
        #expect(!popover.test_isSpeakerSelected("rm-a"),
                "letting the offer lapse leaves the removal standing")
    }

    @Test func closingTheSurfaceDropsTheOffer() {
        let (popover, _) = makeLivePopover()
        uncheck(popover, "rm-a")
        popover.surfaceDidHide()
        #expect(popover.test_removalUndoDeviceID == nil,
                "the offer never outlives the surface it was made on")
    }
}
