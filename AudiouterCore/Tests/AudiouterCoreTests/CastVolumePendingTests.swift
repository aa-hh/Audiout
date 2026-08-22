// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import Testing
@testable import AudiouterCore
@testable import AudiouterSharedUI
@testable import AudiouterPopoverUI

/// Coverage for the **Cast feed-gain pending fader fill** — the fixed-volume
/// Cast receiver's fader holds the engaged fill's ember-blend "not yet gold"
/// tone from a volume/mute gesture until the measured stream lag has elapsed,
/// since there is no protocol ack for feed-gain volume.
///
/// Two seams, mirroring `RemovalUndoTests`:
///
///  1. **Row level** (`DeviceRowView`/`WarmFaderCell`'s `volumePendingApply` /
///     `isPendingApply`): the pending fill renders only when the host raises
///     it, and speaks its own VoiceOver equivalent.
///  2. **Controller level** (`PopoverController`): raising the pending id off
///     a real volume/mute gesture (only for a connected Cast device carrying
///     a `castVolumeLagSeconds`), and the timer retiring it.
@MainActor
@Suite final class CastVolumePendingTests: IsolatedSuite {

    // MARK: Row level

    private func makeBusRow(_ device: Device) -> DeviceRowView {
        DeviceRowView(device: device, showsToggle: true,
                      paintsSelectionBackground: false, showsMeter: true, showsBus: true)
    }

    private func makeCastDevice(id: String = "cast-dev",
                                connectionState: ConnectionState = .connected,
                                castVolumeLagSeconds: Int? = 6) -> Device {
        Device(id: id, name: "Living Room TV", kind: .cast, supportsAirPlay2: false,
               connectionState: connectionState, castVolumeLagSeconds: castVolumeLagSeconds)
    }

    @Test func rowShowsThePendingFillOnlyWhenTheHostRaisesIt() {
        let device = makeCastDevice()
        let row = makeBusRow(device)
        row.apply(device, selected: true, controllable: true, inActiveTarget: true)
        #expect(!row.test_isFaderPending, "no pending fill by default — a plain apply gets nothing")

        row.apply(device, selected: true, controllable: true, inActiveTarget: true,
                  volumePendingApply: true)
        #expect(row.test_isFaderPending, "the host raised the pending flag, so the fader holds the flat tone")
        #expect(row.test_accessibilityValue?.contains("applying volume") == true,
                "the pending fill's spoken equivalent")

        row.apply(device, selected: true, controllable: true, inActiveTarget: true)
        #expect(!row.test_isFaderPending, "and it goes the moment the host stops offering it")
        #expect(row.test_accessibilityValue?.contains("applying volume") != true)
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

    /// One connected, lagged Cast member, selected — the case the pending fill
    /// is built for.
    private func makeLaggedCastPopover() -> (PopoverController, [Device]) {
        let fleet = [makeCastDevice()]
        let popover = makePopover(fleet: fleet)
        _ = popover.test_toggleDeviceEnabled(deviceID: fleet[0].id, on: true)
        popover.update(devices: fleet)
        return (popover, fleet)
    }

    @Test func draggingTheSliderRaisesThePendingFillOnALaggedCastRow() {
        let (popover, fleet) = makeLaggedCastPopover()
        let id = fleet[0].id

        popover.test_deviceRow(for: id)?.test_fireSliderAction(settingValueTo: 30)

        #expect(popover.test_castVolumePendingIDs.contains(id))
        #expect(popover.test_deviceRow(for: id)?.test_isFaderPending == true)

        popover.test_expireCastVolumePending(for: id)

        #expect(!popover.test_castVolumePendingIDs.contains(id))
        #expect(popover.test_deviceRow(for: id)?.test_isFaderPending == false)
    }

    @Test func onlyALaggedCastRowRaisesThePendingFill() {
        let attenuationCast = makeCastDevice(id: "cast-attenuation", castVolumeLagSeconds: nil)
        let homePod = Device(id: "hp-a", name: "Kitchen", kind: .homePod, connectionState: .connected)
        let fleet = [attenuationCast, homePod]
        let popover = makePopover(fleet: fleet)
        _ = popover.test_toggleDeviceEnabled(deviceID: attenuationCast.id, on: true)
        _ = popover.test_toggleDeviceEnabled(deviceID: homePod.id, on: true)
        popover.update(devices: fleet)

        popover.test_deviceRow(for: attenuationCast.id)?.test_fireSliderAction(settingValueTo: 30)
        popover.test_deviceRow(for: homePod.id)?.test_fireSliderAction(settingValueTo: 30)

        #expect(popover.test_castVolumePendingIDs.isEmpty,
                "an attenuation Cast receiver and a non-Cast device raise nothing")
    }

    @Test func mutingALaggedCastRowRaisesThePendingIDToo() {
        let (popover, fleet) = makeLaggedCastPopover()
        let id = fleet[0].id

        // Muting also un-arms the row (the mute pill takes over the visual
        // channel), so this asserts only the pending SET the mute gesture
        // raises — the same set a volume drag raises — not the fader fill,
        // which a muted row never shows regardless.
        popover.test_deviceRow(for: id)?.test_toggleMute(true)

        #expect(popover.test_castVolumePendingIDs.contains(id))
    }
}
