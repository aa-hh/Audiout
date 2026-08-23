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

    /// PIXEL truth for the pending fill — the flag flipping must actually
    /// change what the slider draws. Renders the row's slider to a bitmap in
    /// both states and requires the images to differ; a live run (2026-08-23)
    /// showed the flag raised while the pixels never moved.
    @Test func pendingFillActuallyChangesTheSliderPixels() {
        let device = makeCastDevice()
        let row = makeBusRow(device)
        row.frame = NSRect(x: 0, y: 0, width: 640, height: 64)
        row.layoutSubtreeIfNeeded()

        func sliderBitmap() -> Data? {
            let slider = row.test_slider
            let bounds = slider.bounds
            guard bounds.width > 10,
                  let rep = slider.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
            slider.cacheDisplay(in: bounds, to: rep)
            return rep.tiffRepresentation
        }

        row.apply(device, selected: true, controllable: true, inActiveTarget: true)
        row.layoutSubtreeIfNeeded()
        let gold = sliderBitmap()
        #expect(gold != nil, "the slider must render at all")

        row.apply(device, selected: true, controllable: true, inActiveTarget: true,
                  volumePendingApply: true)
        let pending = sliderBitmap()
        #expect(pending != nil)
        #expect(row.test_isFaderPending)
        #expect(gold != pending,
                "the pending fill must be VISIBLE — same bytes means the flag never reaches the pixels")
    }

    /// PERCEPTUAL truth for the pending fill — the level the 2026-08-23 live
    /// bug actually lived at. The raise → stamp → draw → composite chain was
    /// proven working on hardware (telemetry) and offline (a mock-window
    /// layer-capture probe) while the user still reported ZERO visible change,
    /// because the pending tone was the EXACT fill every unarmed fader
    /// already draws — a same-luminance warm tint swap on a 5 pt track. So
    /// byte inequality against the gold render (the test above) is not
    /// enough: the pending fill must be STRUCTURALLY distinct from the
    /// unarmed fill it was previously indistinguishable from. Sweeps the
    /// track midline and requires a material color break (>30/255 in some
    /// channel) on a meaningful share of pixels — a tint swap of warm
    /// same-luminance fills stays under it; the dashed gold/trough
    /// alternation clears it.
    @Test func pendingFillIsNotTheUnarmedFillInDisguise() {
        let device = makeCastDevice()
        let row = makeBusRow(device)
        row.appearance = NSAppearance(named: .darkAqua)
        row.frame = NSRect(x: 0, y: 0, width: 640, height: 64)
        row.layoutSubtreeIfNeeded()

        func sliderRep() -> NSBitmapImageRep? {
            let slider = row.test_slider
            guard slider.bounds.width > 10,
                  let rep = slider.bitmapImageRepForCachingDisplay(in: slider.bounds)
            else { return nil }
            slider.cacheDisplay(in: slider.bounds, to: rep)
            return rep
        }

        // The UNARMED-but-enabled render: the fill whose tone the original
        // pending implementation literally reused. Same device, same volume,
        // same enabled state — only armed-ness and the pending flag move.
        row.apply(device, selected: true, controllable: true, inActiveTarget: false)
        row.layoutSubtreeIfNeeded()
        guard let unarmed = sliderRep() else {
            Issue.record("the unarmed slider must render at all")
            return
        }

        row.apply(device, selected: true, controllable: true, inActiveTarget: true,
                  volumePendingApply: true)
        guard let pending = sliderRep() else {
            Issue.record("the pending slider must render at all")
            return
        }
        #expect(row.test_isFaderPending)
        #expect(unarmed.pixelsWide == pending.pixelsWide)

        let y = unarmed.pixelsHigh / 2
        var material = 0
        var sampled = 0
        for x in 0..<min(unarmed.pixelsWide, pending.pixelsWide) {
            guard let a = unarmed.colorAt(x: x, y: y),
                  let b = pending.colorAt(x: x, y: y) else { continue }
            sampled += 1
            let delta = max(abs(a.redComponent - b.redComponent),
                            abs(a.greenComponent - b.greenComponent),
                            abs(a.blueComponent - b.blueComponent))
            if delta > 30.0 / 255.0 { material += 1 }
        }
        #expect(sampled > 0)
        #expect(Double(material) >= 0.05 * Double(sampled),
                """
                the pending fill must be UNMISSABLE — only \(material) of \
                \(sampled) midline pixels differ materially from the ordinary \
                unarmed fill, which is exactly the live-invisible tint swap \
                the 2026-08-23 runs shipped
                """)
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
