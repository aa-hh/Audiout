// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import Testing
@testable import AudioutCore
@testable import AudioutSharedUI
@testable import AudioutPopoverUI

/// Coverage for the **Cast pending glows** — a fixed-volume Cast receiver's
/// fader thumb glows white from a volume/mute gesture, and its sync drawer's
/// value field glows from an offset edit, until the measured stream lag has
/// elapsed, since there is no protocol ack for either.
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
                      showsMeter: true, showsBus: true)
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
        #expect(row.test_isFaderPending, "the host raised the pending flag, so the thumb glows")
        #expect(row.test_accessibilityValue?.contains("applying volume") == true,
                "the pending glow's spoken equivalent")

        row.apply(device, selected: true, controllable: true, inActiveTarget: true)
        #expect(!row.test_isFaderPending, "and it goes the moment the host stops offering it")
        #expect(row.test_accessibilityValue?.contains("applying volume") != true)
    }

    /// The slider rendered with Reduce Motion forced on, so the pending glow
    /// sits at full strength instead of mid-breath.
    private func sliderRep(_ row: DeviceRowView) -> NSBitmapImageRep? {
        let slider = row.test_slider
        (slider.cell as? WarmFaderCell)?.test_reduceMotionOverride = true
        guard slider.bounds.width > 10,
              let rep = slider.bitmapImageRepForCachingDisplay(in: slider.bounds)
        else { return nil }
        slider.cacheDisplay(in: slider.bounds, to: rep)
        return rep
    }

    /// The stock knob rect in the slider's points; the drawn thumb and its
    /// halo both sit inside it at the row's mid-range volume.
    private func knobRect(_ row: DeviceRowView) -> NSRect {
        let slider = row.test_slider
        return (slider.cell as? NSSliderCell)?.knobRect(flipped: slider.isFlipped) ?? .zero
    }

    /// Whole pixel columns from `fromX` to `toX` (points), so the check holds
    /// whichever way the slider is flipped.
    private func columns(_ rep: NSBitmapImageRep, from fromX: CGFloat, to toX: CGFloat,
                         in bounds: NSRect) -> [(Int, Int)] {
        let scale = CGFloat(rep.pixelsWide) / bounds.width
        let lo = max(0, Int((fromX * scale).rounded(.down)))
        let hi = min(rep.pixelsWide, Int((toX * scale).rounded(.up)))
        guard lo < hi else { return [] }
        return (lo..<hi).flatMap { x in (0..<rep.pixelsHigh).map { (x, $0) } }
    }

    private func channelDelta(_ a: NSColor?, _ b: NSColor?) -> CGFloat {
        guard let a, let b else { return 0 }
        return max(abs(a.redComponent - b.redComponent),
                   abs(a.greenComponent - b.greenComponent),
                   abs(a.blueComponent - b.blueComponent))
    }

    /// The pending glow lives on the thumb only: the thumb's pixels move and
    /// the gold fill left of it stays byte-for-byte the solid gradient. Turns
    /// red if `drawKnob` stops drawing the glow, or if `drawBar` brings back
    /// any pending treatment of the fill (the retired dashes included).
    @Test func pendingGlowChangesTheThumbAndLeavesTheFillSolid() throws {
        let device = makeCastDevice()
        let row = makeBusRow(device)
        row.appearance = NSAppearance(named: .darkAqua)
        row.frame = NSRect(x: 0, y: 0, width: 640, height: 64)
        row.apply(device, selected: true, controllable: true, inActiveTarget: true)
        row.layoutSubtreeIfNeeded()
        let gold = try #require(sliderRep(row), "the slider must render at all")

        row.apply(device, selected: true, controllable: true, inActiveTarget: true,
                  volumePendingApply: true)
        let pending = try #require(sliderRep(row))
        #expect(row.test_isFaderPending)
        #expect(gold.pixelsWide == pending.pixelsWide)

        let bounds = row.test_slider.bounds
        let knob = knobRect(row)
        #expect(knob.minX > 20, "the fixture needs a fill to the left of the thumb")

        let thumbPixels = columns(gold, from: knob.minX, to: knob.maxX, in: bounds)
        let thumbChanged = thumbPixels.filter {
            channelDelta(gold.colorAt(x: $0.0, y: $0.1), pending.colorAt(x: $0.0, y: $0.1)) > 30.0 / 255.0
        }.count
        #expect(thumbChanged > 0, "the pending glow never reached the thumb's pixels")

        let fillPixels = columns(gold, from: 0, to: knob.minX - 1, in: bounds)
        let fillChanged = fillPixels.filter {
            channelDelta(gold.colorAt(x: $0.0, y: $0.1), pending.colorAt(x: $0.0, y: $0.1)) > 0
        }.count
        #expect(fillChanged == 0, "\(fillChanged) fill pixels changed: the fill must stay solid gold while pending")
    }

    /// The glow is white, the colour the owner asked for, and it is absent
    /// from the settled thumb. Turns red if the glow is drawn in a token tint
    /// or at a strength that never reaches near-white on the dark thumb.
    @Test func pendingGlowPutsWhiteOnTheThumb() throws {
        let device = makeCastDevice()
        let row = makeBusRow(device)
        row.appearance = NSAppearance(named: .darkAqua)
        row.frame = NSRect(x: 0, y: 0, width: 640, height: 64)
        row.apply(device, selected: true, controllable: true, inActiveTarget: true)
        row.layoutSubtreeIfNeeded()
        let settled = try #require(sliderRep(row))
        row.apply(device, selected: true, controllable: true, inActiveTarget: true,
                  volumePendingApply: true)
        let pending = try #require(sliderRep(row))

        let knob = knobRect(row)
        let bounds = row.test_slider.bounds
        func whitePixels(_ rep: NSBitmapImageRep) -> Int {
            columns(rep, from: knob.minX, to: knob.maxX, in: bounds).filter {
                guard let c = rep.colorAt(x: $0.0, y: $0.1) else { return false }
                return min(c.redComponent, c.greenComponent, c.blueComponent) > 0.9
            }.count
        }
        #expect(whitePixels(settled) == 0, "a settled dark thumb carries no white")
        #expect(whitePixels(pending) > 20, "the pending thumb must glow white")
    }

    // MARK: Controller level

    private func waitFleet(_ backend: MockBackend, count: Int,
                          sourceLocation: SourceLocation = #_sourceLocation) {
        SuiteWait.untilOnRunLoop("the fleet has \(count) devices",
                                 sourceLocation: sourceLocation) {
            backend.devices.count >= count
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

    /// A Cast offset edit from the drawer holds the TRIM glow, not the
    /// volume one, and lights the drawer's field. Turns red if `applyBTTrim`
    /// stops raising `.trim` for a Cast device, raises it under `.volume`, or
    /// if the raise stops pushing the mounted drawer.
    @Test func aCastOffsetEditHoldsTheTrimGlowOnly() throws {
        let (popover, fleet) = makeLaggedCastPopover()
        let id = fleet[0].id
        popover.test_toggleSyncDrawer(deviceID: id)
        let drawer = try #require(popover.test_syncDrawer, "the Cast row's drawer never mounted")
        #expect(!drawer.test_isPendingGlowShown)

        drawer.test_firePlusClick()

        #expect(popover.test_castTrimPendingIDs == [id])
        #expect(popover.test_castVolumePendingIDs.isEmpty)
        #expect(drawer.test_isPendingGlowShown, "the drawer must glow on the first tick")
    }

    /// A Bluetooth trim is heard at once, so it holds nothing. Turns red if
    /// the trim raise moves outside `applyBTTrim`'s Cast branch.
    @Test func aBluetoothTrimEditHoldsNothing() throws {
        let bt = Device(id: "bt-a:output", name: "Speaker A", kind: .bluetooth,
                        isAvailable: true, supportsAirPlay2: false, connectionState: .connected)
        let popover = makePopover(fleet: [bt])
        _ = popover.test_toggleDeviceEnabled(deviceID: bt.id, on: true)
        popover.update(devices: [bt])
        popover.test_toggleSyncDrawer(deviceID: bt.id)
        let drawer = try #require(popover.test_syncDrawer)

        drawer.test_firePlusClick()

        #expect(popover.test_castTrimPendingIDs.isEmpty)
        #expect(!drawer.test_isPendingGlowShown)
    }
}
