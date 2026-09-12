// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
import AppKit
@testable import AudioutCore
@testable import AudioutPopoverUI
@testable import AudioutSharedUI

/// The Main Out row's connection **halo ring** (Warm Signal v3 §3.2 Main Out
/// note / §6): it reflects the AGGREGATE connection state of the active Audio
/// Out target, showing the pending (dashed) ring during a destination-switch
/// handshake and the connected (solid) ring once the target is live, so the
/// multi-second gap never reads as dead/broken.
@MainActor
@Suite struct MainOutRowRingTests {

    /// Colours resolve through a dynamic provider, so compare components with a
    /// tolerance rather than by identity.
    private func sameInk(_ a: NSColor?, _ b: NSColor) -> Bool {
        guard let a = a?.usingColorSpace(.sRGB), let b = b.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) <= 0.02
            && abs(a.greenComponent - b.greenComponent) <= 0.02
            && abs(a.blueComponent - b.blueComponent) <= 0.02
    }

    private func makeOptions() -> [MainOutRowView.Option] {
        [
            .init(title: "Destination", isHeader: true),
            .init(title: "Selected Devices (1)", target: .selectedDevices, buttonTitle: "Selected (1)"),
        ]
    }

    @Test func noRingWhenTargetIdle() {
        let row = MainOutRowView()
        row.apply(options: makeOptions(), current: .selectedDevices, master: 50,
                  connectionState: .off)
        #expect(row.test_ringForm == .none, "an idle Main Out shows no ring")
    }

    @Test func pendingRingDuringHandshake() {
        let row = MainOutRowView()
        row.apply(options: makeOptions(), current: .selectedDevices, master: 50,
                  connectionState: .connecting)
        #expect(row.test_ringForm == .connecting,
                "a destination-switch handshake shows the pending (dashed) ring (spec §6)")
    }

    @Test func connectedRingWhenTargetLive() {
        let row = MainOutRowView()
        row.apply(options: makeOptions(), current: .selectedDevices, master: 50,
                  connectionState: .connected)
        #expect(row.test_ringForm == .connected, "a live Main Out target shows the connected ring")
    }

    @Test func defaultApplyLeavesNoRing() {
        // Back-compat: callers that omit `connectionState` (the pre-S1 signature)
        // render no ring, unchanged.
        let row = MainOutRowView()
        row.apply(options: makeOptions(), current: .selectedDevices, master: 50)
        #expect(row.test_ringForm == .none)
    }

    // MARK: Resting ring — the ring exists exactly while the rail does

    @Test func restingRingWhenLocalOnlyArmed() {
        let row = MainOutRowView()
        row.setRailLive(true)
        row.apply(options: makeOptions(), current: .selectedDevices, master: 50,
                  connectionState: .off, localOnlyArmed: true)
        #expect(row.test_ringForm == .resting,
                "local-only playback (a live rail, nothing connected) shows the quiet resting ring, not none")
        // The rail curving into this ring is gold here, so the ring is gold too:
        // a grey `rim` rimmed ring under a gold wire read as two unrelated
        // things touching.
        #expect(sameInk(row.test_ringStrokeColor, Tokens.Color.spineTone(armed: true)),
                "the resting ring wears the rail's own ink, never the grey rim")
    }

    /// A rail that exists but is not armed (speakers selected, none connected,
    /// nothing playing locally) rests in the wire's IDLE tone — still never the
    /// grey rim.
    @Test func restingRingWearsTheIdleToneWhenTheRailIsNotArmed() {
        let row = MainOutRowView()
        row.setRailLive(true)
        row.apply(options: makeOptions(), current: .selectedDevices, master: 50,
                  connectionState: .off)
        #expect(row.test_ringForm == .resting, "a live rail always has a ring to land on")
        #expect(sameInk(row.test_ringStrokeColor, Tokens.Color.spineTone(armed: false)),
                "an idle rail's ring is the idle spine tone")
    }

    @Test func noRingWhileThereIsNoRail() {
        // Nothing selected (or nothing but failed rooms): no wire, so no ring
        // for it to land on — and no bare ring floating with no wire under it.
        let row = MainOutRowView()
        row.apply(options: makeOptions(), current: .selectedDevices, master: 50,
                  connectionState: .off, localOnlyArmed: true)
        #expect(row.test_ringForm == .none,
                "no rail ⇒ no ring, whatever the tone bits say")
    }

    // MARK: Readout ink, group chevron and identity glow

    /// The readout agrees with the fader beside it: gold while the master is
    /// sounding, ember while it only holds a stored level.
    @Test func readoutIsGoldWhileArmedElseEmber() {
        let row = MainOutRowView()
        row.apply(options: [.init(title: "Selected Devices")], current: .selectedDevices,
                  master: 50, connectionState: .connected)
        #expect(row.test_masterReadoutColor == Tokens.Color.goldText)
        #expect(row.test_masterReadoutFont == Tokens.Font.readout)

        row.apply(options: [.init(title: "Selected Devices")], current: .selectedDevices,
                  master: 50, isMuted: true, connectionState: .connected)
        #expect(row.test_masterReadoutColor == Tokens.Color.emberText)
    }

    /// A saved-group target lights the identity glow behind the icon; going
    /// back to Selected Devices puts it out.
    @Test func groupTargetLightsTheGlow() {
        let row = MainOutRowView()
        let options: [MainOutRowView.Option] = [
            .init(title: "Selected Devices", target: .selectedDevices),
            .init(title: "Kitchen", target: .group(id: "g1"), buttonTitle: "→ Kitchen"),
        ]
        row.apply(options: options, current: .group(id: "g1"), master: 50)
        #expect(row.test_groupGlowVisible)

        row.apply(options: options, current: .selectedDevices, master: 50)
        #expect(!row.test_groupGlowVisible)
    }

    /// The display-only cell item surfaces the group's short button title, and
    /// its attributed string carries the tail-truncating paragraph style — an
    /// `attributedTitle` makes the cell ignore its own `lineBreakMode`, so a
    /// long group name would otherwise clip mid-word with no ellipsis.
    @Test func pickerTitleIsTheButtonTitleAndTruncatesByTail() {
        let row = MainOutRowView()
        let longName = "The Extremely Long Upstairs Bedroom Speaker Group"
        row.apply(options: [
            .init(title: "Selected Devices", target: .selectedDevices),
            .init(title: longName, target: .group(id: "g1"), buttonTitle: "→ \(longName)"),
        ], current: .group(id: "g1"), master: 50)
        #expect(row.test_buttonTitle == "→ \(longName)")

        let attributed = try? #require(row.test_buttonAttributedTitle)
        let style = attributed?.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
            as? NSParagraphStyle
        #expect(style?.lineBreakMode == .byTruncatingTail)
    }

    @Test func connectedRingIsUnaffectedByALiveRail() {
        // A genuine remote `.connected` state must render identically whether or
        // not the rail is live — `.resting` only ever fires for `.off`.
        let row = MainOutRowView()
        row.setRailLive(true)
        row.apply(options: makeOptions(), current: .selectedDevices, master: 50,
                  connectionState: .connected, localOnlyArmed: true)
        #expect(row.test_ringForm == .connected,
                "a real connected ring is untouched by restingArmed")
    }
}
