// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import AppKit
@testable import AudioutCore
@testable import AudioutPopoverUI
@testable import AudioutSharedUI

/// The **Warm Signal fader skin** (`WarmFaderCell`, spec §5 "we redraw only
/// the slider track/knob look"): the drawing-only `NSSliderCell` swap on the
/// three row volume sliders. Covers (1) the skin is INSTALLED on all three
/// rows; (2) the engaged (gold-gradient) fill tracks the SAME route-armed
/// predicate the corner dot renders — device row (§3.3 truth table edges),
/// Main Out (connected ∧ !muted), app row (routed ∧ running); (3) NSSlider
/// BEHAVIOR stays stock after the cell swap — `isContinuous`, min/max, and
/// the target/action dispatch all survive; (4) the drawing is deterministic
/// under `cacheDisplay` (byte-identical double render, both appearances).
@MainActor
@Suite struct WarmFaderCellTests {

    // MARK: Helpers

    private func makeDevice(connectionState: ConnectionState = .connected,
                            isMuted: Bool = false,
                            isAvailable: Bool = true) -> Device {
        Device(id: "dev-1", name: "Test Speaker", kind: .homePod,
               isAvailable: isAvailable, isMuted: isMuted,
               connectionState: connectionState)
    }

    private func makeMainOutOptions() -> [MainOutRowView.Option] {
        [
            .init(title: "Destination", isHeader: true),
            .init(title: "Selected Devices", target: .selectedDevices, buttonTitle: "Selected"),
        ]
    }

    private func makeAppConfiguration(selected: String, isRunning: Bool = true)
        -> AppRowView.Configuration {
        AppRowView.Configuration(
            appID: "com.example.app", name: "Example App", icon: nil, volume: 42,
            selectedDestinationID: selected,
            destinations: [
                AppRowView.Destination(id: "no-redirect", title: "Follows main output",
                                       isLocal: true, symbolName: nil, isStandalone: true),
                AppRowView.Destination(id: "device-1", title: "Living Room", isLocal: false,
                                       symbolName: "airplayaudio"),
            ],
            isRunning: isRunning)
    }

    // MARK: Skin installed (structural)

    @Test func allThreeRowsWearTheWarmFaderSkin() {
        #expect(DeviceRowView(device: makeDevice()).test_hasWarmFaderSkin, "DeviceRowView's slider wears WarmFaderCell")
        #expect(MainOutRowView().test_hasWarmFaderSkin, "MainOutRowView's master slider wears WarmFaderCell")
        #expect(AppRowView().test_hasWarmFaderSkin, "AppRowView's slider wears WarmFaderCell")
    }

    // MARK: Device row — engaged fill tracks the §3.3 armed predicate

    @Test func deviceFaderEngagedWhenRouteArmed() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: true, controllable: true)
        #expect(row.test_routeArmed)
        #expect(row.test_isFaderEngaged, "armed ∧ enabled ⇒ the gold gradient fill renders")
    }

    @Test func deviceFaderNeutralWhenNotMember() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: false, controllable: true)
        #expect(!(row.test_isFaderEngaged), "a non-member's fader keeps the neutral warm fill")
    }

    @Test func deviceFaderNeutralWhenNotConnected() {
        let row = DeviceRowView(device: makeDevice(connectionState: .connecting))
        row.apply(makeDevice(connectionState: .connecting), selected: true, controllable: true)
        #expect(!(row.test_isFaderEngaged), "not yet connected ⇒ no gold fill (same truth as the dot)")
    }

    @Test func deviceFaderNeutralWhenRowMuted() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(isMuted: true), selected: true, controllable: true)
        #expect(!(row.test_isFaderEngaged), "row mute disarms the gold fill")
        #expect(row.test_isSliderEnabled, "…but the slider stays live (A5 — mute ≠ frozen volume)")
    }

    @Test func deviceFaderNeutralWhenMasterMuted() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: true, controllable: true, masterMuted: true)
        #expect(!(row.test_isFaderEngaged), "master mute drains every device fader")
    }

    @Test func deviceFaderEngagedByLiveFeedEvenWhenMuted() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(isMuted: true), selected: false, controllable: true,
                  liveAppNames: ["Music"])
        #expect(row.test_routeArmed)
        #expect(row.test_isFaderEngaged, "a confirmed live per-app feed arms the fader (redirects bypass the mutes)")
    }

    @Test func deviceFaderNeverEngagedWhileSliderDisabled() {
        // A live-feed row that is NOT controllable: armed predicate true, but
        // the slider is disabled — the engaged gate requires BOTH.
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: true, controllable: false, liveAppNames: ["Music"])
        #expect(row.test_routeArmed)
        #expect(!(row.test_isSliderEnabled))
        #expect(!(row.test_isFaderEngaged), "a disabled slider never renders the engaged fill")
    }

    // MARK: Main Out row — engaged = connected ∧ !muted (the dot's predicate)

    @Test func mainOutFaderEngagedWhenTargetLiveAndUnmuted() {
        let row = MainOutRowView()
        row.apply(options: makeMainOutOptions(), current: .selectedDevices, master: 50,
                  isMuted: false, connectionState: .connected)
        #expect(row.test_routeArmed)
        #expect(row.test_isFaderEngaged)
    }

    @Test func mainOutFaderNeutralWhenIdleOrMuted() {
        let idle = MainOutRowView()
        idle.apply(options: makeMainOutOptions(), current: .selectedDevices, master: 50,
                   connectionState: .off)
        #expect(!(idle.test_isFaderEngaged), "idle Main Out keeps the neutral fill")

        let muted = MainOutRowView()
        muted.apply(options: makeMainOutOptions(), current: .selectedDevices, master: 50,
                    isMuted: true, connectionState: .connected)
        #expect(!(muted.test_isFaderEngaged), "master mute disarms the master fader")
    }

    // MARK: App row — engaged = routed ∧ running (spec §5.1's app predicate)

    @Test func appFaderEngagedWhenRoutedAndRunning() {
        let row = AppRowView()
        row.apply(makeAppConfiguration(selected: "device-1", isRunning: true))
        #expect(row.test_isFaderEngaged)
    }

    @Test func appFaderNeutralWhenRoutedButIdle() {
        let row = AppRowView()
        row.apply(makeAppConfiguration(selected: "device-1", isRunning: false))
        #expect(!(row.test_isFaderEngaged), "a routed-but-idle app keeps the neutral fill (calm, not live)")
    }

    @Test func appFaderNeutralButLiveOnNoRedirect() {
        let row = AppRowView()
        row.apply(makeAppConfiguration(selected: "no-redirect", isRunning: true))
        #expect(!row.test_isSliderDimmed,
                "the slider levels an un-redirected app inside the mix, so it stays live")
        #expect(!(row.test_isFaderEngaged), "the standalone follows-main-output state is never gold")
    }

    // MARK: Behavior stays stock after the cell swap

    private final class RecordingDeviceDelegate: DeviceRowView.Delegate {
        var lastVolume: (id: String, volume: Int)?
        func deviceRow(_ row: DeviceRowView, didSetVolume volume: Int, for id: String) {
            lastVolume = (id, volume)
        }
        func deviceRow(_ row: DeviceRowView, didToggleMute muted: Bool, for id: String) {}
    }

    @Test func sliderTargetActionSurvivesCellSwap() {
        // Fire the slider's OWN target/action with the slider as sender —
        // the same dispatch AppKit performs during a drag — proving the cell
        // swap preserved the control's wiring (the AppKit-dispatch seam the
        // MainOutRowMenuDispatchTests lesson calls for, not the delegate
        // shortcut `test_setVolume` takes).
        let row = DeviceRowView(device: makeDevice())
        let delegate = RecordingDeviceDelegate()
        row.delegate = delegate
        row.apply(makeDevice(), selected: true, controllable: true)
        row.test_fireSliderAction(settingValueTo: 73)
        #expect(delegate.lastVolume?.volume == 73, "the slider's target/action still reaches the delegate after the cell swap")
        #expect(delegate.lastVolume?.id == "dev-1")
    }

    @Test func sliderConfigurationSurvivesCellSwap() {
        let config = DeviceRowView(device: makeDevice()).test_sliderConfiguration
        #expect(config.min == 0)
        #expect(config.max == 100)
        #expect(config.isContinuous, "isContinuous survives (the drag fires throughout — brief §2)")
        #expect(config.type == .linear)
    }

    // MARK: Fill geometry reaches the track's real ends

    @Test func fillReachesTrackEndsAtExtremes() {
        // Stock NSSliderCell insets the knob's travel by half the knob width
        // at each end, so anchoring the fill to the knob's center left it
        // short of the trough at 100% (and painted a phantom fill at 0%).
        // The fill must derive from the VALUE instead, reaching the track's
        // actual ends.
        let cell = WarmFaderCell()
        cell.minValue = 0
        cell.maxValue = 100
        let track = NSRect(x: 0, y: 0, width: 150, height: 5)

        cell.doubleValue = 0
        #expect(cell.test_fillRect(track: track).width == 0,
                "at the minimum value the fill has zero width")

        cell.doubleValue = 100
        let fullFill = cell.test_fillRect(track: track)
        #expect(fullFill.width == track.width,
                "at the maximum value the fill spans the whole track")
        #expect(fullFill.maxX == track.maxX,
                "at the maximum value the fill reaches the track's real end, not the knob's inset center")
    }

    /// The same claim, on the PIXELS `drawBar` paints. The arithmetic above
    /// runs through `test_fillRect`, so it would stay green if `drawBar` were
    /// wired back to the knob's centre — which is the regression it exists to
    /// prevent. Probed near each end of the track, clear of the 10 pt thumb.
    @Test func theDrawnBarFillsToTheTrackEndsToo() throws {
        let slider = NSSlider()
        slider.cell = WarmFaderCell()
        slider.minValue = 0
        slider.maxValue = 100
        slider.frame = NSRect(x: 0, y: 0, width: 150, height: 24)
        slider.appearance = NSAppearance(named: .darkAqua)

        /// The colour at `x` on the track's centre line, in the slider's own
        /// points, taken from a real render of the control.
        func pixel(atX x: CGFloat, value: Double) throws -> NSColor {
            slider.doubleValue = value
            let rep = try #require(slider.bitmapImageRepForCachingDisplay(in: slider.bounds))
            slider.cacheDisplay(in: slider.bounds, to: rep)
            let scale = CGFloat(rep.pixelsWide) / slider.bounds.width
            let px = min(rep.pixelsWide - 1, max(0, Int(x * scale)))
            let py = min(rep.pixelsHigh - 1, max(0, Int(slider.bounds.midY * scale)))
            return try #require(rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB))
        }

        // 15 pt in from each end: inside the fill at full, and clear of the
        // 10 pt thumb, which parks against the track's end at each extreme.
        // The last 10 pt — the thumb's own footprint — is what
        // `theDrawnHandleReachesTheTrackEnds` below covers.
        let trailingAtFull = try pixel(atX: slider.bounds.maxX - 15, value: 100)
        let trailingAtZero = try pixel(atX: slider.bounds.maxX - 15, value: 0)
        let leadingAtZero = try pixel(atX: 15, value: 0)
        let leadingAtFull = try pixel(atX: 15, value: 100)

        func brightness(_ color: NSColor) -> CGFloat { color.brightnessComponent }
        #expect(brightness(trailingAtFull) > brightness(trailingAtZero) + 0.05,
                "at 100% the drawn fill reaches the track's trailing end — \(trailingAtFull) vs empty \(trailingAtZero)")
        #expect(brightness(leadingAtZero) < brightness(leadingAtFull) - 0.05,
                "…and at 0% it paints no phantom stub at the leading end — \(leadingAtZero) vs filled \(leadingAtFull)")
    }

    /// The handle's own geometry, measured on the PIXELS at 0 / 50 / 100: at
    /// the maximum nothing is painted past the handle, at the minimum nothing
    /// before it, and in between it sits centred on the value. Both spans come
    /// out of a real render — the geometry helpers can agree with each other
    /// while what `drawBar`/`drawKnob` actually paint disagrees with both.
    @Test func theDrawnHandleReachesTheTrackEnds() throws {
        let slider = NSSlider()
        slider.cell = WarmFaderCell()
        slider.minValue = 0
        slider.maxValue = 100
        slider.frame = NSRect(x: 0, y: 0, width: PopoverColumnGrid.sliderWidth, height: 24)
        slider.appearance = NSAppearance(named: .darkAqua)

        /// The horizontal span of everything drawn in a band of pixel rows, in
        /// the slider's own points. A pixel counts as drawn when it differs
        /// from the untouched top corner. `rowsFromCentre` is measured from the
        /// track's centre line in points, symmetric, so it needs no knowledge
        /// of which way the bitmap's rows run.
        func drawnSpan(value: Double, rowsFromCentre: ClosedRange<CGFloat>) throws
            -> (minX: CGFloat, maxX: CGFloat) {
            slider.doubleValue = value
            let rep = try #require(slider.bitmapImageRepForCachingDisplay(in: slider.bounds))
            slider.cacheDisplay(in: slider.bounds, to: rep)
            let scale = CGFloat(rep.pixelsWide) / slider.bounds.width
            let background = try #require(rep.colorAt(x: 1, y: 1)?.usingColorSpace(.sRGB))
            let midRow = CGFloat(rep.pixelsHigh) / 2

            var minX = CGFloat.greatestFiniteMagnitude
            var maxX = -CGFloat.greatestFiniteMagnitude
            for row in 0..<rep.pixelsHigh {
                let distance = abs((CGFloat(row) + 0.5 - midRow)) / scale
                guard rowsFromCentre.contains(distance) else { continue }
                for column in 0..<rep.pixelsWide {
                    guard let pixel = rep.colorAt(x: column, y: row)?.usingColorSpace(.sRGB),
                          !isSameColor(pixel, background) else { continue }
                    minX = min(minX, CGFloat(column) / scale)
                    maxX = max(maxX, CGFloat(column + 1) / scale)
                }
            }
            return (minX, maxX)
        }

        // The track's centre line carries the trough (5 pt tall) AND the thumb.
        // Rows 3…8 pt out from that centre clear the trough entirely, so they
        // carry the 17 pt thumb alone — its true span, taken as the union over
        // the band so the capsule's rounded ends can't understate it.
        let trackBand: ClosedRange<CGFloat> = 0...1
        let thumbBand: ClosedRange<CGFloat> = 3...8
        let thumbWidth = PopoverColumnGrid.faderThumbWidth

        let handleAtFull = try drawnSpan(value: 100, rowsFromCentre: thumbBand)
        let trackAtFull = try drawnSpan(value: 100, rowsFromCentre: trackBand)
        #expect(handleAtFull.maxX >= trackAtFull.maxX - 0.5,
                "at 100% nothing is drawn past the handle — handle ends at \(handleAtFull.maxX), track at \(trackAtFull.maxX)")
        #expect(abs(handleAtFull.maxX - slider.bounds.maxX) <= 0.5,
                "…and the handle's trailing edge lands on the track's end (\(handleAtFull.maxX))")

        let handleAtZero = try drawnSpan(value: 0, rowsFromCentre: thumbBand)
        let trackAtZero = try drawnSpan(value: 0, rowsFromCentre: trackBand)
        #expect(handleAtZero.minX <= trackAtZero.minX + 0.5,
                "at 0% nothing is drawn before the handle — handle starts at \(handleAtZero.minX), track at \(trackAtZero.minX)")
        #expect(abs(handleAtZero.minX - slider.bounds.minX) <= 0.5,
                "…and the handle's leading edge lands on the track's start (\(handleAtZero.minX))")

        let handleAtHalf = try drawnSpan(value: 50, rowsFromCentre: thumbBand)
        #expect(abs((handleAtHalf.minX + handleAtHalf.maxX) / 2 - slider.bounds.midX) <= 0.5,
                "at 50% the handle is centred on the value's position (\(handleAtHalf))")

        for (label, span) in [("0%", handleAtZero), ("50%", handleAtHalf), ("100%", handleAtFull)] {
            #expect(abs((span.maxX - span.minX) - thumbWidth) <= 0.5,
                    "\(label): the handle keeps its \(thumbWidth) pt width — measured \(span.maxX - span.minX)")
        }
    }

    private func isSameColor(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        abs(lhs.redComponent - rhs.redComponent) < 0.01
            && abs(lhs.greenComponent - rhs.greenComponent) < 0.01
            && abs(lhs.blueComponent - rhs.blueComponent) < 0.01
            && abs(lhs.alphaComponent - rhs.alphaComponent) < 0.01
    }

    // MARK: Tracking is untouched by where the thumb is painted

    /// The contract the thumb's repositioning had to keep: `WarmFaderCell`
    /// changes PAINT only, so a click and a drag must land where they always
    /// did. Drives the real `NSSliderCell` tracking calls — the ones a live
    /// mouse drives — and pins the properties a user would notice breaking.
    @Test func clickAndDragStillLandOnTheValuesTheyAimAt() {
        let slider = NSSlider()
        slider.cell = WarmFaderCell()
        slider.minValue = 0
        slider.maxValue = 100
        slider.frame = NSRect(x: 0, y: 0, width: PopoverColumnGrid.sliderWidth, height: 24)

        /// Runs one press-drag-release and returns the value it settled on.
        func drag(from startX: CGFloat, to endX: CGFloat, startingAt value: Double) -> Double {
            let cell = slider.cell as! NSSliderCell
            cell.doubleValue = value
            let start = NSPoint(x: startX, y: slider.bounds.midY)
            let end = NSPoint(x: endX, y: slider.bounds.midY)
            _ = cell.startTracking(at: start, in: slider)
            _ = cell.continueTracking(last: start, current: end, in: slider)
            cell.stopTracking(last: start, current: end, in: slider, mouseIsUp: true)
            return cell.doubleValue
        }

        // Both far ends of the track are reachable, from a click and from a
        // drag that STARTS ON THE KNOB — the two gestures the repositioning
        // could plausibly have disturbed.
        #expect(drag(from: slider.bounds.maxX, to: slider.bounds.maxX, startingAt: 50) == 100,
                "clicking the trailing end lands on the maximum")
        #expect(drag(from: slider.bounds.minX, to: slider.bounds.minX, startingAt: 50) == 0,
                "clicking the leading end lands on the minimum")
        #expect(drag(from: 75, to: slider.bounds.maxX, startingAt: 50) == 100,
                "dragging the knob to the trailing end lands on the maximum")
        #expect(drag(from: 75, to: slider.bounds.minX, startingAt: 50) == 0,
                "dragging the knob to the leading end lands on the minimum")

        // Pressing the knob without moving leaves the value alone (no jump to
        // the press point), and the mapping never runs backwards.
        #expect(drag(from: 75, to: 75, startingAt: 50) == 50,
                "pressing the knob and not moving keeps the value")
        var previous = -1.0
        for x in stride(from: CGFloat(0), through: PopoverColumnGrid.sliderWidth, by: 5) {
            let landed = drag(from: x, to: x, startingAt: 0)
            #expect(landed >= previous, "x=\(x) landed on \(landed), below the previous \(previous)")
            previous = landed
        }
    }

    // MARK: Deterministic drawing (cacheDisplay double-render, both looks)

    @Test func faderRenderIsByteDeterministic() throws {
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            for engaged in [false, true] {
                let row = DeviceRowView(device: makeDevice())
                row.apply(makeDevice(), selected: engaged, controllable: true)
                row.frame = NSRect(x: 0, y: 0, width: 320, height: DeviceRowView.rowHeight)
                row.appearance = NSAppearance(named: appearanceName)
                row.layoutSubtreeIfNeeded()

                func render() throws -> Data {
                    let rep = try #require(row.bitmapImageRepForCachingDisplay(in: row.bounds))
                    row.cacheDisplay(in: row.bounds, to: rep)
                    return try #require(rep.representation(using: .png, properties: [:]))
                }
                let first = try render()
                let second = try render()
                #expect(first == second, "\(appearanceName.rawValue) engaged=\(engaged): fader drawing must be byte-deterministic under cacheDisplay")
            }
        }
    }
}
