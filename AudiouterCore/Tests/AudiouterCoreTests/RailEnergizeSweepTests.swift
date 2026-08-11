// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import Testing
@testable import AudiouterSharedUI

/// The rail's ENERGIZE SWEEP (Warm Signal v4.1 item 9 — "rail segment brightens
/// top-to-bottom"): when the wire GAINS gold reach, an ember film over the
/// settled wire retreats origin→terminus. These tests pin the firing decision
/// (pure) and the film's contract (settled model, Reduce Motion removal,
/// mid-flight cancel) against a real windowed overlay with stub providers — no
/// graphics context, no PopoverController.
@MainActor
@Suite final class RailEnergizeSweepTests: IsolatedSuite {

    // MARK: Pure firing decision

    private typealias Signature = BusRailOverlayView.EnergySignature

    @Test func theFirstDrawNeverFires() {
        #expect(!BusRailOverlayView.energizeSweepFires(
            previous: nil, current: Signature(gold: true, memberStops: 3)),
            "no baseline yet ⇒ the first render is settled (no transient fires on open)")
    }

    @Test func armingFires() {
        #expect(BusRailOverlayView.energizeSweepFires(
            previous: Signature(gold: false, memberStops: 1),
            current: Signature(gold: true, memberStops: 1)),
            "the spine arming is a gain in reach")
    }

    @Test func aNewMemberOnAnArmedSpineFires() {
        #expect(BusRailOverlayView.energizeSweepFires(
            previous: Signature(gold: true, memberStops: 1),
            current: Signature(gold: true, memberStops: 2)),
            "a new room going live on an armed spine is a gain in reach")
    }

    @Test func lossAndIdleGainsStayQuiet() {
        #expect(!BusRailOverlayView.energizeSweepFires(
            previous: Signature(gold: true, memberStops: 2),
            current: Signature(gold: true, memberStops: 1)),
            "a room leaving is not a surge")
        #expect(!BusRailOverlayView.energizeSweepFires(
            previous: Signature(gold: false, memberStops: 0),
            current: Signature(gold: false, memberStops: 1)),
            "a member added to an IDLE wire carries no signal yet")
        #expect(!BusRailOverlayView.energizeSweepFires(
            previous: Signature(gold: true, memberStops: 2),
            current: Signature(gold: true, memberStops: 2)),
            "no change, no sweep")
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
        func railHookAnchor(in view: NSView)
            -> (centerY: CGFloat, ringCenterX: CGFloat, ringRadius: CGFloat, gold: Bool)? {
            (centerY: 300, ringCenterX: 40, ringRadius: 15, gold: gold)
        }
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

    @Test func theRealDrawPathFiresTheSweep() {
        // Through `display()` → `draw(_:)`, not the `test_reconcileEnergize`
        // shortcut — the live app has no other route into the reconcile.
        let scene = makeScene(nodes: [.member])
        scene.overlay.needsDisplay = true
        scene.overlay.display()                       // baseline: idle
        scene.hook.gold = true
        scene.overlay.needsDisplay = true
        scene.overlay.display()
        drainMainQueue()
        #expect(scene.overlay.test_isEnergizeSweeping,
                "arming must fire through the real draw pass, not just the test seam")
    }

    @Test func theFilmPresentationActuallyAnimates() throws {
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
        try #require(scene.overlay.test_isEnergizeSweeping)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        let presented = scene.overlay.test_sweepPresentationStrokeStart
        #expect(presented != nil && presented! < 0.99,
                "mid-flight the PRESENTATION must differ from the retreated model — \(String(describing: presented))")
    }

    @Test func theFirstReconcileOnlyStampsTheBaseline() {
        let scene = makeScene(nodes: [.member])
        scene.hook.gold = true
        scene.overlay.test_reconcileEnergize()
        drainMainQueue()
        #expect(!scene.overlay.test_isEnergizeSweeping,
                "an armed wire on first render is settled state, not a transition")
    }

    @Test func armingMountsTheFilmWithASettledModel() {
        let scene = makeScene(nodes: [.member, .nonMember])
        scene.overlay.test_reconcileEnergize()          // baseline: idle
        scene.hook.gold = true
        scene.overlay.test_reconcileEnergize()
        drainMainQueue()
        #expect(scene.overlay.test_isEnergizeSweeping, "arming fires the sweep")
        #expect(scene.overlay.test_sweepModelStrokeStart == 1,
                "the film's MODEL stays fully retreated (invisible) — only the presentation animates, so cacheDisplay is deterministic mid-flight")
    }

    @Test func aNewMemberSegmentFiresOnALiveWire() {
        let scene = makeScene(nodes: [.member, .nonMember])
        scene.hook.gold = true
        scene.overlay.test_reconcileEnergize()          // baseline: armed, one member
        drainMainQueue()
        #expect(!scene.overlay.test_isEnergizeSweeping)

        scene.rows[1].node = .member
        scene.overlay.test_reconcileEnergize()
        drainMainQueue()
        #expect(scene.overlay.test_isEnergizeSweeping,
                "a second room going live surges the wire again")
    }

    @Test func reduceMotionRemovesTheSweepEntirely() {
        let scene = makeScene(nodes: [.member])
        scene.overlay.test_reduceMotionOverride = true
        scene.overlay.test_reconcileEnergize()          // baseline: idle
        scene.hook.gold = true
        scene.overlay.test_reconcileEnergize()
        drainMainQueue()
        #expect(!scene.overlay.test_isEnergizeSweeping,
                "Reduce Motion snaps to the settled wire — no travelling sweep")
    }

    @Test func aMidFlightReduceMotionToggleCancelsTheFilm() {
        let scene = makeScene(nodes: [.member])
        scene.overlay.test_reconcileEnergize()          // baseline: idle
        scene.hook.gold = true
        scene.overlay.test_reconcileEnergize()
        drainMainQueue()
        #expect(scene.overlay.test_isEnergizeSweeping)

        scene.overlay.test_reduceMotionOverride = true
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: NSWorkspace.shared)
        #expect(!scene.overlay.test_isEnergizeSweeping,
                "the in-flight film dies the instant the user asks for no motion")
    }

    @Test func anAccentDialChangeCancelsTheFilm() {
        let scene = makeScene(nodes: [.member])
        scene.overlay.test_reconcileEnergize()          // baseline: idle
        scene.hook.gold = true
        scene.overlay.test_reconcileEnergize()
        drainMainQueue()
        #expect(scene.overlay.test_isEnergizeSweeping)

        NotificationCenter.default.post(name: Tokens.accentStyleDidChangeNotification,
                                        object: nil)
        #expect(!scene.overlay.test_isEnergizeSweeping,
                "the film's stamped CGColor can't re-tint — it drops and the settled draw re-resolves")
    }

    @Test func aDormantWireNeverSweeps() {
        let scene = makeScene(nodes: [.member])
        scene.overlay.dormant = true
        scene.overlay.test_reconcileEnergize()          // baseline
        scene.hook.gold = true
        scene.overlay.test_reconcileEnergize()
        drainMainQueue()
        #expect(!scene.overlay.test_isEnergizeSweeping,
                "a dormant wire feeds nothing — there is no current to show arriving")
    }
}
