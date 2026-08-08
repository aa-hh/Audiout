// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import Testing
import AudiouterCore
@testable import AudiouterSharedUI

/// T8 coverage (Warm Signal v4.1 item 8): the per-device "muted → brighten on
/// connect" beat. A connecting/reconnecting row sits in the Call-1
/// muted-unconnected treatment (desaturated fader/readout + — new here —
/// dimmed FEED text); a successful connect EDGE (connecting/reconnecting →
/// connected) fires a one-shot cross-fade back to full gold/normal; a failure
/// edge fires nothing (the FEED's red override alone carries it). Reduce
/// Motion removes the cross-fade entirely — the row snaps straight to its
/// already-settled resolved state, mirroring item 9's shared motion-gating
/// rule and the `RouteArmedDotView` bloom precedent.
@MainActor
@Suite final class DeviceRowConnectBrightenTests: IsolatedSuite {

    private func makeDevice(connectionState: ConnectionState = .connected,
                            isMuted: Bool = false,
                            isAvailable: Bool = true) -> Device {
        Device(id: "dev-1", name: "Test Speaker", kind: .homePod,
               isAvailable: isAvailable, isMuted: isMuted,
               connectionState: connectionState)
    }

    /// A row hosted in a real (offscreen) window — `brightenOnConnect()` and
    /// the arm bloom it mirrors both gate on `window != nil` (spec §6's "no
    /// transient fires on open" also requires being visible at all).
    private func makeHostedRow(connectionState: ConnectionState) -> (row: DeviceRowView, window: NSWindow) {
        let row = DeviceRowView(device: makeDevice(connectionState: connectionState), showsBus: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 44),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(row)
        return (row, window)
    }

    private func assertSameHue(_ a: NSColor?, _ b: NSColor?, _ message: String,
                               sourceLocation: SourceLocation = #_sourceLocation) {
        guard let a = a?.usingColorSpace(.sRGB), let b = b?.usingColorSpace(.sRGB) else {
            Issue.record("nil color: \(message)", sourceLocation: sourceLocation)
            return
        }
        #expect(abs(a.redComponent - b.redComponent) <= 0.01, "\(message)", sourceLocation: sourceLocation)
        #expect(abs(a.greenComponent - b.greenComponent) <= 0.01, "\(message)", sourceLocation: sourceLocation)
        #expect(abs(a.blueComponent - b.blueComponent) <= 0.01, "\(message)", sourceLocation: sourceLocation)
    }

    // MARK: Muted-unconnected treatment while connecting (Call 1 + item 8's FEED dim)

    @Test func connectingRowIsControlsMutedWithDimmedFeed() {
        let (row, _) = makeHostedRow(connectionState: .connecting)
        row.apply(makeDevice(connectionState: .connecting), selected: true, controllable: true)
        #expect(row.test_controlsMuted, "a connecting row sits in the muted-unconnected treatment")
        assertSameHue(row.test_feedNeutralColor, Tokens.Color.tertiaryLabel,
                      "the FEED's neutral segment dims while connecting (item 8 'muted feed text')")
    }

    @Test func connectedRowIsNotControlsMutedWithNormalFeed() {
        let (row, _) = makeHostedRow(connectionState: .connected)
        row.apply(makeDevice(connectionState: .connected), selected: true, controllable: true)
        #expect(!row.test_controlsMuted)
        assertSameHue(row.test_feedNeutralColor, Tokens.Color.secondaryLabel,
                      "a connected row's FEED reads at normal (full) tint")
    }

    // MARK: The connect edge fires the brighten, gated by Reduce Motion

    @Test func brightenFiresOnConnectEdgeWithReduceMotionOff() {
        let (row, _) = makeHostedRow(connectionState: .connecting)
        row.test_reduceMotionOverride = false
        row.apply(makeDevice(connectionState: .connecting), selected: true, controllable: true)
        #expect(!row.test_isBrightening, "no transition on the settled connecting state itself")

        row.apply(makeDevice(connectionState: .connected), selected: true, controllable: true)
        #expect(row.test_isBrightening,
                      "connecting → connected is the exact edge item 8 brightens on")
        #expect(!row.test_controlsMuted, "model state settles to bright regardless of the transition")
    }

    @Test func reconnectingToConnectedAlsoBrightens() {
        let (row, _) = makeHostedRow(connectionState: .reconnecting)
        row.test_reduceMotionOverride = false
        row.apply(makeDevice(connectionState: .reconnecting), selected: true, controllable: true)
        row.apply(makeDevice(connectionState: .connected), selected: true, controllable: true)
        #expect(row.test_isBrightening, "reconnecting → connected brightens exactly like connecting → connected")
    }

    @Test func reduceMotionSnapsInsteadOfBrightening() {
        let (row, _) = makeHostedRow(connectionState: .connecting)
        row.test_reduceMotionOverride = true
        row.apply(makeDevice(connectionState: .connecting), selected: true, controllable: true)
        row.apply(makeDevice(connectionState: .connected), selected: true, controllable: true)
        #expect(!row.test_isBrightening, "Reduce Motion removes the transition entirely")
        #expect(!row.test_controlsMuted, "the row still lands on the resolved bright state — just instantly")
        assertSameHue(row.test_feedNeutralColor, Tokens.Color.secondaryLabel,
                      "the settled FEED tint is unaffected by Reduce Motion — only the transition is")
    }

    // MARK: A mid-session Reduce Motion toggle cancels an in-flight brighten

    @Test func midSessionReduceMotionCancelsInFlightBrighten() {
        let (row, _) = makeHostedRow(connectionState: .connecting)
        row.test_reduceMotionOverride = false
        row.apply(makeDevice(connectionState: .connecting), selected: true, controllable: true)
        row.apply(makeDevice(connectionState: .connected), selected: true, controllable: true)
        #expect(row.test_isBrightening, "precondition: the cross-fade is mid-flight")

        row.test_reduceMotionOverride = true
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        #expect(!row.test_isBrightening,
                       "toggling Reduce Motion ON mid-flight strips the transition immediately")
    }

    // MARK: No transient on the row's own first render (spec §6 "no transient fires on open")

    @Test func noBrightenOnFirstApplyEvenWhenAlreadyConnected() {
        let row = DeviceRowView(device: makeDevice(connectionState: .connected), showsBus: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 44),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(row)
        row.test_reduceMotionOverride = false
        row.apply(makeDevice(connectionState: .connected), selected: true, controllable: true)
        #expect(!row.test_isBrightening, "a freshly-open row on an already-connected device never brightens")
    }

    @Test func noBrightenOffScreen() {
        // No window attached: `brightenOnConnect()`'s `window != nil` gate
        // must hold even though the connecting → connected edge is real —
        // matches `RouteArmedDotView`'s bloom, which gates the same way.
        let row = DeviceRowView(device: makeDevice(connectionState: .connecting), showsBus: true)
        row.test_reduceMotionOverride = false
        row.apply(makeDevice(connectionState: .connecting), selected: true, controllable: true)
        row.apply(makeDevice(connectionState: .connected), selected: true, controllable: true)
        #expect(!row.test_isBrightening, "no window ⇒ no transient, even on a genuine connect edge")
    }

    // MARK: Failure stays muted — no brighten, red FEED override

    @Test func failureEdgeFiresNoBrightenAndShowsRedFeed() {
        let (row, _) = makeHostedRow(connectionState: .connecting)
        row.test_reduceMotionOverride = false
        row.apply(makeDevice(connectionState: .connecting), selected: true, controllable: true)

        let failed = makeDevice(connectionState: .failed(.init(cause: .notResponding)))
        row.apply(failed, selected: true, controllable: true)
        #expect(!row.test_isBrightening, "a failure edge never brightens — it stays muted")
        #expect(row.test_controlsMuted, "failed rows stay in the muted-unconnected treatment")
        #expect(row.test_feedIsErrorColored, "the FEED shows the red error, not a dimmed composite")
        #expect(row.test_feedText == "Didn't respond")
    }

    @Test func connectedToFailedNeverBrightens() {
        // A regression the naive `controlsMuted`-flip trigger would have
        // fired on (false → true is not a brighten, but guard the OTHER
        // direction too): a previously-connected row that fails must not
        // brighten either.
        let (row, _) = makeHostedRow(connectionState: .connected)
        row.test_reduceMotionOverride = false
        row.apply(makeDevice(connectionState: .connected), selected: true, controllable: true)

        let failed = makeDevice(connectionState: .failed(.init(cause: .notResponding)))
        row.apply(failed, selected: true, controllable: true)
        #expect(!row.test_isBrightening)
    }
}
