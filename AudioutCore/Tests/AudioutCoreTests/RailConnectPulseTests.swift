// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import Testing
@testable import AudioutCore
@testable import AudioutSharedUI

/// The rail's CONNECT PULSE (Warm Signal v4.1 item 9): the HOST detects the
/// model transition — a device becoming a connected member of the active Main
/// Out target — and calls `playConnectPulse(joinedDeviceIDs:cameToLife:)`; the
/// overlay only renders the bead/bloom. These tests pin the overlay's render
/// contract (departure mapping, guards, settled model, Reduce Motion removal,
/// mid-flight cancel, burst coalescing) against a real windowed overlay with
/// stub providers — no graphics context, no PopoverController. The FIRING
/// decision itself is controller-side: `RailConnectPulseControllerTests`.
@MainActor
@Suite final class RailConnectPulseTests: IsolatedSuite {

    // MARK: Windowed overlay behavior

    private final class StubHook: RailHookProviding {
        var gold = false
        /// How many landed beads this hook was handed — the ring's bloom is the
        /// ring's own business, so the overlay's contract is exactly this call.
        var receivedPulses = 0
        func railHookAnchor(in view: NSView)
            -> (centerY: CGFloat, ringCenterX: CGFloat, ringRadius: CGFloat, gold: Bool)? {
            (centerY: 300, ringCenterX: 40, ringRadius: 15, gold: gold)
        }
        func receiveRailPulse() { receivedPulses += 1 }
    }

    private final class StubRow: RailNodeProviding {
        let view: NSView
        var node: MembershipBusView.Node?
        var railDeviceID: String?
        init(view: NSView, node: MembershipBusView.Node?) {
            self.view = view
            self.node = node
        }
        var railNode: MembershipBusView.Node? { node }
        var railNodeView: NSView { view }
        var railNodeBounds: NSRect { view.bounds }
    }

    /// Retains the window, the weak-referenced hook, and the rows.
    private struct Scene {
        let window: NSWindow
        let overlay: BusRailOverlayView
        let hook: StubHook
        let rows: [StubRow]
    }

    private func makeScene(nodes: [MembershipBusView.Node]) -> Scene {
        // Parked far outside every screen: the two tests below need a real
        // render-server-backed layer tree (an ordered-in window), and a test
        // must never put anything on the developer's actual screen.
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 300, height: 400),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let content = window.contentView!
        var rows: [StubRow] = []
        for (index, node) in nodes.enumerated() {
            let rowView = NSView(frame: NSRect(x: 10, y: 240 - CGFloat(index) * 40,
                                               width: 20, height: 20))
            content.addSubview(rowView)
            rows.append(StubRow(view: rowView, node: node))
        }
        let overlay = BusRailOverlayView()
        // Pin the seam so the host machine's real Reduce Motion setting can't
        // skew a result either way; the RM tests flip it explicitly.
        overlay.test_reduceMotionOverride = false
        // Headless test windows are never ordered front; pin the visibility
        // seam so the ordered-out-window veto can't skew a result either way.
        overlay.test_windowVisibleOverride = true
        overlay.frame = content.bounds
        content.addSubview(overlay)
        let hook = StubHook()
        overlay.mainOutRow = hook
        overlay.deviceRows = rows
        return Scene(window: window, overlay: overlay, hook: hook, rows: rows)
    }

    /// `playConnectPulse` defers its whole body out of the calling turn — spin
    /// the main run loop briefly so the deferred mount lands.
    private func drainMainQueue() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    @Test func thePulsePresentationActuallyAnimates() throws {
        // GUI-session only: headless runners have no render server, so the
        // presentation tree never commits there — skip rather than lie.
        try #require(NSScreen.main != nil, "needs a window server")
        let scene = makeScene(nodes: [.member])
        scene.window.orderFrontRegardless()          // off-screen; see `makeScene`
        defer { scene.window.orderOut(nil) }
        scene.hook.gold = true
        scene.overlay.playConnectPulse(joinedDeviceIDs: [], cameToLife: true)
        drainMainQueue()
        try #require(scene.overlay.test_isConnectPulsing)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        let presented = scene.overlay.test_pulsePresentationStrokeEnd
        #expect(presented != nil && presented! > 0.01,
                "mid-flight the PRESENTATION must differ from the absorbed model — \(String(describing: presented))")
    }

    @Test func anOrderedOutWindowNeverPulses() {
        let scene = makeScene(nodes: [.member])
        scene.overlay.test_windowVisibleOverride = nil  // read the real, never-ordered-in window
        scene.hook.gold = true
        scene.overlay.playConnectPulse(joinedDeviceIDs: [], cameToLife: true)
        drainMainQueue()
        #expect(!scene.overlay.test_isConnectPulsing,
                "a window that is not on screen has nothing to animate")
    }

    // MARK: Departure point (the pulse leaves from the room that joined)

    @Test func fractionMapsAYPositionOntoTheWire() throws {
        let wire = NSBezierPath()
        wire.move(to: NSPoint(x: 20, y: 300))
        wire.line(to: NSPoint(x: 20, y: 100))
        let mid = try #require(BusRailOverlayView.fraction(atY: 200, along: wire))
        #expect(abs(mid - 0.5) < 0.001, "y 200 sits halfway down a 300→100 wire")
        let above = try #require(BusRailOverlayView.fraction(atY: 350, along: wire))
        #expect(above == 0, "a y above the wire clamps to the origin")
        let below = try #require(BusRailOverlayView.fraction(atY: 50, along: wire))
        #expect(below == 1, "a y below the wire clamps to the terminus")
        #expect(BusRailOverlayView.fraction(atY: 200, along: NSBezierPath()) == nil,
                "an empty path has no fractions to give")
    }

    @Test func aJoiningRoomDepartsFromItsOwnNode() throws {
        // Three member rows; the MIDDLE one joined — the pulse must depart from
        // its spot on the wire (mapped via `railDeviceID`), not the wire's end.
        let scene = makeScene(nodes: [.member, .member, .member])
        scene.rows[0].railDeviceID = "top"
        scene.rows[1].railDeviceID = "middle"
        scene.rows[2].railDeviceID = "bottom"
        scene.hook.gold = true
        scene.overlay.playConnectPulse(joinedDeviceIDs: ["middle"], cameToLife: false)
        drainMainQueue()
        let departure = try #require(scene.overlay.test_lastPulseDeparture)
        #expect(departure < 0.95,
                "a mid-wire join departs from that node, not the terminus — got \(departure)")
        #expect(departure > 0.05, "…and not from the ring either")
    }

    @Test func comingToLifeDepartsFromTheTerminus() throws {
        let scene = makeScene(nodes: [.member, .member])
        scene.hook.gold = true
        scene.overlay.playConnectPulse(joinedDeviceIDs: [], cameToLife: true)
        drainMainQueue()
        let departure = try #require(scene.overlay.test_lastPulseDeparture)
        #expect(departure == 1,
                "the wire coming to life lights every room at once — the pulse runs the whole wire")
    }

    @Test func anUnmappedJoinFallsBackToTheTerminus() throws {
        // No row carries this id (`StubRow.railDeviceID` defaults to `nil`) —
        // the departure falls back to the whole wire (`.max() ?? 1`).
        let scene = makeScene(nodes: [.member, .member])
        scene.hook.gold = true
        scene.overlay.playConnectPulse(joinedDeviceIDs: ["never-mounted"], cameToLife: false)
        drainMainQueue()
        let departure = try #require(scene.overlay.test_lastPulseDeparture)
        #expect(departure == 1, "an id with no matching row departs from the terminus")
    }

    // MARK: Arrival (the ring receives the bead)

    /// Spin the main run loop in small steps until `condition` holds or
    /// `deadline` passes — headless runners play CA timelines on their own
    /// clock, so transient states are caught by polling, never a fixed sleep.
    private func polls(within deadline: TimeInterval, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(deadline)
        while Date() < end {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    @Test func theHeaderDotBloomMountsWithASettledModel() {
        // Synchronous contract check — the layer is inspectable the instant
        // `runHeaderDotBloom` returns, before any timeline can remove it.
        let scene = makeScene(nodes: [.member])
        scene.overlay.runHeaderDotBloom(at: NSPoint(x: 25, y: 300))
        #expect(scene.overlay.test_isHeaderDotBlooming)
        #expect(scene.overlay.test_headerDotBloomModelOpacity == 0,
                "the bloom's MODEL stays invisible — only the presentation plays")
    }

    @Test func aCompletedPulseHandsOffToTheRing() {
        // Ordered-in window: an undisplayed window's layer tree never starts its
        // CA timeline, so the bead's completion (the bloom's trigger) would
        // never fire — same requirement as the presentation probe above.
        let scene = makeScene(nodes: [.member])
        scene.window.orderFrontRegardless()          // off-screen; see `makeScene`
        defer { scene.window.orderOut(nil) }
        scene.hook.gold = true
        scene.overlay.playConnectPulse(joinedDeviceIDs: [], cameToLife: true)
        drainMainQueue()
        #expect(scene.overlay.test_isConnectPulsing)
        let received = polls(within: 2.5) { scene.hook.receivedPulses == 1 }
        #expect(received, "the landed bead is handed to the RING, which owns the bloom — handoffs fired: \(scene.overlay.test_pulseHandoffRuns), still pulsing: \(scene.overlay.test_isConnectPulsing)")
        #expect(scene.overlay.test_headerDotBloomRuns == 0,
                "an uncollapsed origin has a ring — the overlay draws no disc of its own")
    }

    @Test func aCancelledPulseNeverReachesTheRing() {
        let scene = makeScene(nodes: [.member])
        scene.hook.gold = true
        scene.overlay.playConnectPulse(joinedDeviceIDs: [], cameToLife: true)
        drainMainQueue()
        #expect(scene.overlay.test_isConnectPulsing)

        scene.overlay.test_reduceMotionOverride = true
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: NSWorkspace.shared)
        #expect(!scene.overlay.test_isConnectPulsing)
        let received = polls(within: 1.6) { scene.hook.receivedPulses > 0 }
        #expect(!received, "a bead that never landed has nothing to hand the ring")
    }

    // MARK: The ring's own bloom (`HaloRingView` receives the bead)

    /// A windowed ring, connected, at the Main Audio ring's own geometry.
    private func makeRing() -> (window: NSWindow, ring: HaloRingView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let ring = HaloRingView()
        ring.test_reduceMotionOverride = false
        ring.frame = NSRect(x: 20, y: 20, width: 40, height: 40)
        window.contentView!.addSubview(ring)
        ring.apply(.connected)
        ring.layoutSubtreeIfNeeded()
        return (window, ring)
    }

    @Test func theRingBloomMountsWithASettledModel() {
        let scene = makeRing()
        scene.ring.receiveRailPulse()
        #expect(scene.ring.test_isReceivingRailPulse, "the ring itself acknowledges the bead")
        #expect(scene.ring.test_receivedRailPulses == 1)
        #expect(scene.ring.test_receiveModelOpacity == 0,
                "the bloom's MODEL stays invisible — only the presentation plays, so cacheDisplay is deterministic mid-flight")
    }

    @Test func reduceMotionRemovesTheRingBloom() {
        let scene = makeRing()
        scene.ring.test_reduceMotionOverride = true
        scene.ring.receiveRailPulse()
        #expect(!scene.ring.test_isReceivingRailPulse,
                "Reduce Motion means no bloom at all — the ring stays on its settled stroke")
        #expect(scene.ring.test_receivedRailPulses == 0)
    }

    @Test func aMidFlightReduceMotionToggleCancelsTheRingBloom() {
        let scene = makeRing()
        scene.ring.receiveRailPulse()
        #expect(scene.ring.test_isReceivingRailPulse)

        scene.ring.test_reduceMotionOverride = true
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: NSWorkspace.shared)
        #expect(!scene.ring.test_isReceivingRailPulse,
                "the in-flight bloom dies the instant the user asks for no motion")
    }

    @Test func anAccentDialChangeCancelsTheRingBloom() {
        let scene = makeRing()
        scene.ring.receiveRailPulse()
        #expect(scene.ring.test_isReceivingRailPulse)

        NotificationCenter.default.post(name: Tokens.accentStyleDidChangeNotification,
                                        object: nil)
        #expect(!scene.ring.test_isReceivingRailPulse,
                "the bloom's stamped `glow` can't re-tint mid-flight — it drops")
    }

    @Test func anOffScreenRingNeverBlooms() {
        let ring = HaloRingView()
        ring.test_reduceMotionOverride = false
        ring.frame = NSRect(x: 0, y: 0, width: 40, height: 40)
        ring.apply(.connected)
        ring.receiveRailPulse()
        #expect(!ring.test_isReceivingRailPulse, "no window, nothing to acknowledge")
    }

    // MARK: The bead's contract

    @Test func armingMountsThePulseWithASettledModel() {
        let scene = makeScene(nodes: [.member, .nonMember])
        scene.hook.gold = true
        scene.overlay.playConnectPulse(joinedDeviceIDs: [], cameToLife: true)
        drainMainQueue()
        #expect(scene.overlay.test_isConnectPulsing, "the connect fires the pulse")
        let model = scene.overlay.test_pulseModelStrokeWindow
        #expect(model?.start == 0 && model?.end == 0,
                "the pulse's MODEL stays fully absorbed (invisible) — only the presentation animates, so cacheDisplay is deterministic mid-flight")
    }

    @Test func aSingleJoinMountsTheBead() {
        let scene = makeScene(nodes: [.member, .member])
        scene.rows[1].railDeviceID = "joined"
        scene.hook.gold = true
        scene.overlay.playConnectPulse(joinedDeviceIDs: ["joined"], cameToLife: false)
        drainMainQueue()
        #expect(scene.overlay.test_isConnectPulsing,
                "a room going live on an armed spine mounts the bead")
    }

    @Test func aStagedMultiRoomConnectCoalescesIntoOnePulse() {
        // A fresh build's first connect lands its rooms across several updates
        // as the handshake settles. A gain that arrives while a bead is already
        // in flight is coalesced: ONE pulse travels, not one restart per room.
        let scene = makeScene(nodes: [.member, .member])
        scene.rows[0].railDeviceID = "room1"
        scene.rows[1].railDeviceID = "room2"
        scene.hook.gold = true
        scene.overlay.playConnectPulse(joinedDeviceIDs: ["room1"], cameToLife: true)
        drainMainQueue()
        #expect(scene.overlay.test_isConnectPulsing, "the connect fires a pulse")
        #expect(scene.overlay.test_pulsesStarted == 1)
        #expect(scene.overlay.test_lastPulseDeparture == 1,
                "the wire coming to life runs end to end from the terminus, not from one room's node")

        scene.overlay.playConnectPulse(joinedDeviceIDs: ["room2"], cameToLife: false)
        drainMainQueue()
        #expect(scene.overlay.test_pulsesStarted == 1,
                "the second room landing mid-flight does NOT restart the pulse — one coalesced pulse, no stutter")
    }

    @Test func reduceMotionRemovesThePulseEntirely() {
        let scene = makeScene(nodes: [.member])
        scene.overlay.test_reduceMotionOverride = true
        scene.hook.gold = true
        scene.overlay.playConnectPulse(joinedDeviceIDs: [], cameToLife: true)
        drainMainQueue()
        #expect(!scene.overlay.test_isConnectPulsing,
                "Reduce Motion snaps to the settled wire — no travelling pulse")
    }

    @Test func aMidFlightReduceMotionToggleCancelsThePulse() {
        let scene = makeScene(nodes: [.member])
        scene.hook.gold = true
        scene.overlay.playConnectPulse(joinedDeviceIDs: [], cameToLife: true)
        drainMainQueue()
        #expect(scene.overlay.test_isConnectPulsing)

        scene.overlay.test_reduceMotionOverride = true
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: NSWorkspace.shared)
        #expect(!scene.overlay.test_isConnectPulsing,
                "the in-flight pulse dies the instant the user asks for no motion")
    }

    @Test func anAccentDialChangeCancelsThePulse() {
        let scene = makeScene(nodes: [.member])
        scene.hook.gold = true
        scene.overlay.playConnectPulse(joinedDeviceIDs: [], cameToLife: true)
        drainMainQueue()
        #expect(scene.overlay.test_isConnectPulsing)

        NotificationCenter.default.post(name: Tokens.accentStyleDidChangeNotification,
                                        object: nil)
        #expect(!scene.overlay.test_isConnectPulsing,
                "the pulse's stamped CGColor can't re-tint — it drops and the settled draw re-resolves")
    }

    @Test func aMidFlightResizeCancelsThePulse() {
        let scene = makeScene(nodes: [.member])
        scene.hook.gold = true
        scene.overlay.playConnectPulse(joinedDeviceIDs: [], cameToLife: true)
        drainMainQueue()
        #expect(scene.overlay.test_isConnectPulsing)

        scene.overlay.setFrameSize(NSSize(width: scene.overlay.frame.width,
                                          height: scene.overlay.frame.height + 40))
        #expect(!scene.overlay.test_isConnectPulsing,
                "a reflow mid-flight slides the wire out from under the bead — it drops rather than flying a stale path")
    }

    @Test func aSameSizeLayoutPassNeverCancelsThePulse() {
        let scene = makeScene(nodes: [.member])
        scene.hook.gold = true
        scene.overlay.playConnectPulse(joinedDeviceIDs: [], cameToLife: true)
        drainMainQueue()
        #expect(scene.overlay.test_isConnectPulsing)

        scene.overlay.setFrameSize(scene.overlay.frame.size)
        #expect(scene.overlay.test_isConnectPulsing,
                "layout passes re-set an unchanged frame constantly — only a real size change cancels")
    }

    @Test func aDormantWireNeverPulses() {
        let scene = makeScene(nodes: [.member])
        scene.overlay.dormant = true
        scene.hook.gold = true
        scene.overlay.playConnectPulse(joinedDeviceIDs: [], cameToLife: true)
        drainMainQueue()
        #expect(!scene.overlay.test_isConnectPulsing,
                "a dormant wire feeds nothing — there is no current to show arriving")
    }

    @Test func anIdleWireNeverPulses() {
        let scene = makeScene(nodes: [.member])
        scene.hook.gold = false
        scene.overlay.playConnectPulse(joinedDeviceIDs: [], cameToLife: true)
        drainMainQueue()
        #expect(!scene.overlay.test_isConnectPulsing,
                "an idle (un-armed) wire carries nothing — no pulse")
    }

    // MARK: Redraw skip (a layout pass that moved nothing)

    /// Render once so the overlay records the input its committed contents were
    /// drawn from. `dataWithPDF` runs a real `draw(_:)` without needing an
    /// on-screen window, so the memo is primed deterministically.
    ///
    /// The observable afterwards is `test_redrawRequestCount`, not `needsDisplay`:
    /// this view is layer-backed, and a layer-backed view's dirty flag stays set
    /// once AppKit has set it, so reading the flag back can never show a skip.
    private func prime(_ overlay: BusRailOverlayView) {
        _ = overlay.dataWithPDF(inside: overlay.bounds)
    }

    @Test func anUnchangedLayoutPassSkipsTheRedraw() {
        let scene = makeScene(nodes: [.member, .member])
        prime(scene.overlay)
        let baseline = scene.overlay.test_redrawRequestCount

        scene.overlay.needsDisplay = true
        #expect(scene.overlay.test_redrawRequestCount == baseline,
                "same geometry ⇒ same figure: nothing to re-resolve or re-stroke")

        scene.overlay.dormant = true
        scene.overlay.needsDisplay = true
        #expect(scene.overlay.test_redrawRequestCount == baseline + 1,
                "a changed input is a different figure and must redraw")
    }

    @Test func anAccentChangeForcesTheRedrawThrough() {
        let scene = makeScene(nodes: [.member, .member])
        prime(scene.overlay)
        let baseline = scene.overlay.test_redrawRequestCount

        NotificationCenter.default.post(name: Tokens.accentStyleDidChangeNotification, object: nil)
        #expect(scene.overlay.test_redrawRequestCount == baseline + 1,
                "the geometry is unchanged but the TONES are not — the skip must not swallow it")
    }
}
