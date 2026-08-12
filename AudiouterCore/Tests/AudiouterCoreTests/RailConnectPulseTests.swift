// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import Testing
@testable import AudiouterCore
@testable import AudiouterSharedUI

/// The rail's CONNECT PULSE (Warm Signal v4.1 item 9, reshaped per Alec
/// 2026-08-12 — "a pulse along the rail towards the main out"): when the wire
/// GAINS gold reach, a bright `glow` window travels terminus→origin and is
/// absorbed into the Main Audio ring. These tests pin the firing decision
/// (pure) and the pulse's contract (settled model, Reduce Motion removal,
/// mid-flight cancel) against a real windowed overlay with stub providers — no
/// graphics context, no PopoverController.
@MainActor
@Suite final class RailConnectPulseTests: IsolatedSuite {

    // MARK: Pure firing decision

    private typealias Signature = BusRailOverlayView.EnergySignature

    @Test func theFirstDrawNeverFires() {
        #expect(!BusRailOverlayView.connectPulseFires(
            previous: nil, current: Signature(gold: true, memberStops: 3)),
            "no baseline yet ⇒ the first render is settled (no transient fires on open)")
    }

    @Test func armingFires() {
        #expect(BusRailOverlayView.connectPulseFires(
            previous: Signature(gold: false, memberStops: 1),
            current: Signature(gold: true, memberStops: 1)),
            "the spine arming is a gain in reach")
    }

    @Test func aNewMemberOnAnArmedSpineFires() {
        #expect(BusRailOverlayView.connectPulseFires(
            previous: Signature(gold: true, memberStops: 1),
            current: Signature(gold: true, memberStops: 2)),
            "a new room going live on an armed spine is a gain in reach")
    }

    @Test func lossAndIdleGainsStayQuiet() {
        #expect(!BusRailOverlayView.connectPulseFires(
            previous: Signature(gold: true, memberStops: 2),
            current: Signature(gold: true, memberStops: 1)),
            "a room leaving is not a surge")
        #expect(!BusRailOverlayView.connectPulseFires(
            previous: Signature(gold: false, memberStops: 0),
            current: Signature(gold: false, memberStops: 1)),
            "a member added to an IDLE wire carries no signal yet")
        #expect(!BusRailOverlayView.connectPulseFires(
            previous: Signature(gold: true, memberStops: 2),
            current: Signature(gold: true, memberStops: 2)),
            "no change, no pulse")
    }

    @Test func aDormantPlanReadsAsCarryingNothing() {
        let plan = RailPlan.resolve(RailPlan.Input(
            gold: true, ringCenterY: 300, ringCenterX: 40, ringRadius: 15,
            landingDrop: 16, originSectionCollapsed: false, originClipBand: nil,
            originHeaderY: nil, deviceSectionCollapsed: false, deviceFloorY: nil,
            dormant: true,
            stops: [.init(y: 200, node: .member)]))
        let signature = BusRailOverlayView.energizeSignature(of: plan)
        #expect(!signature.gold, "a dormant wire is not live, whatever `gold` says")
        #expect(signature.memberStops == 0, "…and reaches nothing")
    }

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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
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

    /// The reconcile defers its layer mutation out of the draw pass — spin the
    /// main run loop briefly so the deferred mount lands.
    private func drainMainQueue() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    @Test func theRealDrawPathFiresThePulse() {
        // Through `display()` → `draw(_:)`, not the `test_reconcileEnergize`
        // shortcut — the live app has no other route into the reconcile.
        let scene = makeScene(nodes: [.member])
        scene.overlay.needsDisplay = true
        scene.overlay.display()                       // baseline: idle
        scene.hook.gold = true
        scene.overlay.needsDisplay = true
        scene.overlay.display()
        drainMainQueue()
        #expect(scene.overlay.test_isConnectPulsing,
                "arming must fire through the real draw pass, not just the test seam")
    }

    @Test func thePulsePresentationActuallyAnimates() throws {
        // GUI-session only: headless runners have no render server, so the
        // presentation tree never commits there — skip rather than lie.
        try #require(NSScreen.main != nil, "needs a window server")
        let scene = makeScene(nodes: [.member])
        scene.window.orderFrontRegardless()
        scene.overlay.needsDisplay = true
        scene.overlay.display()                       // baseline: idle
        scene.hook.gold = true
        scene.overlay.needsDisplay = true
        scene.overlay.display()
        drainMainQueue()
        try #require(scene.overlay.test_isConnectPulsing)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        let presented = scene.overlay.test_pulsePresentationStrokeEnd
        #expect(presented != nil && presented! > 0.01,
                "mid-flight the PRESENTATION must differ from the absorbed model — \(String(describing: presented))")
    }

    @Test func aReopenNeverDiffsAgainstTheStalePreCloseBaseline() {
        // The popover reuses its view across open/close, so the overlay must
        // forget its baseline when the window orders out — otherwise a room
        // that joined WHILE CLOSED fires a pulse the instant the panel reopens,
        // an animation that follows nothing.
        let scene = makeScene(nodes: [.member, .nonMember])
        scene.hook.gold = true
        scene.overlay.test_reconcileEnergize()          // baseline: armed, 1 room
        drainMainQueue()

        // Popover closes (the window orders out)…
        NotificationCenter.default.post(
            name: NSWindow.didChangeOcclusionStateNotification, object: scene.window)
        // …a second room joins while closed, then the panel reopens and draws.
        scene.rows[1].node = .member
        scene.overlay.test_reconcileEnergize()
        drainMainQueue()
        #expect(!scene.overlay.test_isConnectPulsing,
                "the first draw after a reopen is settled — no pulse from a stale diff")

        // A join AFTER that settled draw is a live transition again.
        let extraRow = NSView(frame: NSRect(x: 10, y: 160, width: 20, height: 20))
        scene.window.contentView!.addSubview(extraRow)
        scene.overlay.deviceRows = scene.rows + [StubRow(view: extraRow, node: .member)]
        scene.overlay.test_reconcileEnergize()
        drainMainQueue()
        #expect(scene.overlay.test_isConnectPulsing,
                "…and pulses normally once the reopened panel is the baseline")
    }

    @Test func anOrderedOutWindowNeverPulses() {
        let scene = makeScene(nodes: [.member])
        scene.overlay.test_windowVisibleOverride = nil  // read the real window
        scene.overlay.test_reconcileEnergize()          // baseline: idle
        scene.hook.gold = true
        scene.overlay.test_reconcileEnergize()
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
        // Three rows; the MIDDLE one joins an armed spine — the pulse must
        // depart from its spot on the wire, not the wire's end.
        let scene = makeScene(nodes: [.member, .nonMember, .member])
        scene.hook.gold = true
        scene.overlay.test_reconcileEnergize()          // baseline: armed, rooms 0+2
        drainMainQueue()

        scene.rows[1].node = .member
        scene.overlay.test_reconcileEnergize()
        drainMainQueue()
        let departure = try #require(scene.overlay.test_lastPulseDeparture)
        #expect(departure < 0.95,
                "a mid-wire join departs from that node, not the terminus — got \(departure)")
        #expect(departure > 0.05, "…and not from the ring either")
    }

    @Test func armingDepartsFromTheTerminus() throws {
        let scene = makeScene(nodes: [.member, .member])
        scene.overlay.test_reconcileEnergize()          // baseline: idle
        scene.hook.gold = true
        scene.overlay.test_reconcileEnergize()
        drainMainQueue()
        let departure = try #require(scene.overlay.test_lastPulseDeparture)
        #expect(departure == 1,
                "arming lights every room at once — the pulse runs the whole wire")
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
        // On-glass window: an undisplayed window's layer tree never starts its
        // CA timeline, so the bead's completion (the bloom's trigger) would
        // never fire — same requirement as the presentation probe above.
        let scene = makeScene(nodes: [.member])
        scene.window.orderFrontRegardless()
        scene.overlay.test_reconcileEnergize()          // baseline: idle
        scene.hook.gold = true
        scene.overlay.test_reconcileEnergize()
        drainMainQueue()
        #expect(scene.overlay.test_isConnectPulsing)
        let received = polls(within: 2.5) { scene.hook.receivedPulses == 1 }
        #expect(received, "the landed bead is handed to the RING, which owns the bloom — handoffs fired: \(scene.overlay.test_pulseHandoffRuns), still pulsing: \(scene.overlay.test_isConnectPulsing)")
        #expect(scene.overlay.test_headerDotBloomRuns == 0,
                "an uncollapsed origin has a ring — the overlay draws no disc of its own")
    }

    @Test func aCancelledPulseNeverReachesTheRing() {
        let scene = makeScene(nodes: [.member])
        scene.overlay.test_reconcileEnergize()          // baseline: idle
        scene.hook.gold = true
        scene.overlay.test_reconcileEnergize()
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

    @Test func theFirstReconcileOnlyStampsTheBaseline() {
        let scene = makeScene(nodes: [.member])
        scene.hook.gold = true
        scene.overlay.test_reconcileEnergize()
        drainMainQueue()
        #expect(!scene.overlay.test_isConnectPulsing,
                "an armed wire on first render is settled state, not a transition")
    }

    @Test func armingMountsThePulseWithASettledModel() {
        let scene = makeScene(nodes: [.member, .nonMember])
        scene.overlay.test_reconcileEnergize()          // baseline: idle
        scene.hook.gold = true
        scene.overlay.test_reconcileEnergize()
        drainMainQueue()
        #expect(scene.overlay.test_isConnectPulsing, "arming fires the pulse")
        let model = scene.overlay.test_pulseModelStrokeWindow
        #expect(model?.start == 0 && model?.end == 0,
                "the pulse's MODEL stays fully absorbed (invisible) — only the presentation animates, so cacheDisplay is deterministic mid-flight")
    }

    @Test func aNewMemberSegmentFiresOnALiveWire() {
        let scene = makeScene(nodes: [.member, .nonMember])
        scene.hook.gold = true
        scene.overlay.test_reconcileEnergize()          // baseline: armed, one member
        drainMainQueue()
        #expect(!scene.overlay.test_isConnectPulsing)

        scene.rows[1].node = .member
        scene.overlay.test_reconcileEnergize()
        drainMainQueue()
        #expect(scene.overlay.test_isConnectPulsing,
                "a second room going live surges the wire again")
    }

    @Test func reduceMotionRemovesThePulseEntirely() {
        let scene = makeScene(nodes: [.member])
        scene.overlay.test_reduceMotionOverride = true
        scene.overlay.test_reconcileEnergize()          // baseline: idle
        scene.hook.gold = true
        scene.overlay.test_reconcileEnergize()
        drainMainQueue()
        #expect(!scene.overlay.test_isConnectPulsing,
                "Reduce Motion snaps to the settled wire — no travelling pulse")
    }

    @Test func aMidFlightReduceMotionToggleCancelsThePulse() {
        let scene = makeScene(nodes: [.member])
        scene.overlay.test_reconcileEnergize()          // baseline: idle
        scene.hook.gold = true
        scene.overlay.test_reconcileEnergize()
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
        scene.overlay.test_reconcileEnergize()          // baseline: idle
        scene.hook.gold = true
        scene.overlay.test_reconcileEnergize()
        drainMainQueue()
        #expect(scene.overlay.test_isConnectPulsing)

        NotificationCenter.default.post(name: Tokens.accentStyleDidChangeNotification,
                                        object: nil)
        #expect(!scene.overlay.test_isConnectPulsing,
                "the pulse's stamped CGColor can't re-tint — it drops and the settled draw re-resolves")
    }

    @Test func aDormantWireNeverPulses() {
        let scene = makeScene(nodes: [.member])
        scene.overlay.dormant = true
        scene.overlay.test_reconcileEnergize()          // baseline
        scene.hook.gold = true
        scene.overlay.test_reconcileEnergize()
        drainMainQueue()
        #expect(!scene.overlay.test_isConnectPulsing,
                "a dormant wire feeds nothing — there is no current to show arriving")
    }
}
