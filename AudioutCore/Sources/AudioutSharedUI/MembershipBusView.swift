// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import QuartzCore

/// The **membership bus — the LEFT SPINE** (Warm Signal v4 §Call-1, supersedes
/// the v3 trailing-column bus): the DRAWING-ONLY skin that renders the "Selected
/// Devices" checkbox as a node on a vertical rail running down the popover's
/// LEFT gutter. A FILLED gold node sits ON the line for a connected member; a
/// HOLLOW node the line visibly DETOURS around (a wide wire-hop arc) marks a
/// non-member. Only the drawing lives here — the real `NSButton` checkbox stays
/// the control underneath, with its action path, keyboard, and VoiceOver intact
/// (spec §4.8). The view is **non-interactive** (`hitTest` returns `nil`), so a
/// click on the node area falls through to the invisible checkbox re-anchored
/// behind it, and a rail click falls through to the row.
///
/// **Cross-row continuity is achieved by the panel-level ``BusRailOverlayView``**
/// (Alec's continuity correction): the overlay draws the rail line, detour
/// arcs, and origin hook as ONE continuous spine down a clear gutter; each row
/// hosts one `MembershipBusView` centred on `railGutterCenterX` that draws
/// ONLY its node disc/ring. The overlay reads each node's kind (via the host
/// row) to place the rail's gap (on-spine) or detour arc (off-spine).
///
/// **Node vocabulary (v4 §Call-1, the static states the energize agent drives):**
/// `.member` (filled gold — connected member), `.connecting` (gold dashed
/// hollow), `.failed` (failure-red ring), `.nonMember` (hollow, detoured).
/// The energize "pending" beat has NO node form of
/// its own — an ember dashed rim is indistinguishable from the gold dashed one
/// at node size, so the beat renders as `.connecting`. **Rail segment tone:**
/// GOLD through a connected member, `ember` otherwise — ember survives as a
/// SEGMENT tone only, which is where Call 3's energize sequence reads.
///
/// **Determinism:** at rest node + rails are steady drawing, so
/// `cacheDisplay(in:to:)` captures them identically every run. The ONE
/// transient is the hover resize below, and it only runs while the pointer is
/// on the row inside a live window — a snapshot fixture never hovers.
public final class MembershipBusView: NSView {

    /// What this row's bus node renders as. The line path follows from it: a
    /// connected member sits ON the line (straight run), an unselected/blocked
    /// node is DETOURED around (the hop arc) — wherever in the band it sits.
    public enum Node: Equatable {
        /// A connected member — a FILLED gold disc with a gold rim, the line
        /// running straight through it in gold (spec §Call-1 "member / connected
        /// = filled gold").
        case member
        /// A member whose session is establishing — a HOLLOW node with a GOLD
        /// DASHED rim (spec §Call-1 "connecting = gold dashed"). The controls
        /// render muted (not adjustable yet). The energize "press-play" beat
        /// (v4.1 item 9) also renders here: a host-raised
        /// `DeviceRowView.energizePending` on a still-`.off` member draws this
        /// node before the backend reports `.connecting`, then hands off to the
        /// real state. Reduce Motion removes the beat (the node renders its
        /// resolved form).
        case connecting
        /// A member that failed to connect — a HOLLOW node with a heavier
        /// FAILURE-RED solid ring (spec §Call-1 "failed = failure-red ring"). It
        /// keeps its place in the spine; the red ring says which room didn't make
        /// it. Never dimmed.
        case failed
        /// Not in the mix set — a HOLLOW node the line bows around (spec §4.4).
        case nonMember
        /// The Main Audio **origin** (spec §Call-1 "the rail hooks UP into the
        /// Main Audio row's meter"): draws nothing here — the panel-level
        /// ``BusRailOverlayView`` draws the L-shaped hook that rises at
        /// `railGutterCenterX` and turns into the meter. The host frames this
        /// view so its top-right corner sits at the meter's leading edge /
        /// centre-y.
        case origin
    }

    private var node: Node = .nonMember
    /// De-emphasis tint (spec §4.7 dormant-divergent, and an unavailable
    /// device): a tint, never alpha. It reaches the FILL only. The rim belongs
    /// to the rail — the node is still ON the wire, still in the group — so a
    /// dimmed `.member` keeps its rim in the spine's tone and fills its disc
    /// with `dotSocket` — the same unlit seat the route-armed dot rests in
    /// when nothing is armed: same seat, gold lifted out. A hollow node has no
    /// fill, so a dimmed `.nonMember` draws exactly like a live one — "not in
    /// the group" already has nothing to grey out. `.failed` is never dimmed
    /// (the red ring carries it); the whole-rail dormant tone is the overlay's
    /// own flag, not this one.
    ///
    /// The seat is NOT `railDormant`, which is the WIRE's dormancy tone and is
    /// pinned to a 3:1 floor against the surfaces. That floor is what parks it
    /// beside the rim it has to be told from: `railDormant` measures 1.09:1
    /// against dark `ember` and 1.09:1 against light `gold`, so on an idle
    /// dark rail — or an armed light one — the rim was a hue edge with no
    /// brightness behind it. A disc ringed by its own rim carries no ground
    /// floor (the rim does that job), so the seat is free to drop clear of
    /// both rim tones instead. Measured (WCAG luminance ratios): dark
    /// `#4A443B` sits 1.92:1 from `ember` and 5.22:1 from `gold`; light
    /// `#E0D8C6` sits 4.28:1 from `ember` and 2.92:1 from `gold`. Every dial
    /// column x appearance x Increase-Contrast cell is swept by
    /// `TokenContrastMatrixTests.dimmedNodeSeatSeparatesFromBothRimTones`.
    private var dimmed = false
    /// Whether the `.origin` hook draws GOLD (the Main Audio spine is armed —
    /// connected members are feeding it) vs the quiet `ember` idle tone (v4
    /// §Call-1 rail-segment tone). Ignored for every non-origin node.
    private var originGold = false
    /// Whether this row's rail is ARMED — audio is (or would be) flowing through
    /// it. Gold is the LIVE color everywhere in Audiout, so an idle context
    /// (the Groups editor showing a group that is NOT the active Main Out — pure
    /// configuration, no audio moving) renders its `.member` discs in the quiet
    /// `ember` idle tone instead, matching the wire's own armed/idle split
    /// (`Tokens.Color.spineTone`). Defaults to true: the popover's rows ARE the
    /// live signal path and keep their gold unchanged.
    private var armed = true
    /// Whether a dimmed `.member`'s rim draws at `busNodeDimmedRimWidth`
    /// instead of the standard `busNodeRimWidth`. Off by default — the
    /// popover's dimmed member is a CONFIGURATION divergence (a checked
    /// device outside the active Main Out target, still fully reachable), and
    /// doesn't need the extra weight. `MembershipRowView` (the Groups editor)
    /// turns this on: there, `dimmed` means the checked device is physically
    /// unavailable, and the thicker rim is what the row's own `Unavailable`
    /// label already says in text.
    public var emphasizesDimmedMemberRim = false
    /// Whether the pointer is over the row's bus-gutter region — the node
    /// RESIZES to ``postClickRadius(for:)``, the size it would rest at once the
    /// click lands, so the pointer previews the toggle instead of just admitting
    /// the node is clickable. The HOST row owns the tracking (this view stays
    /// non-interactive) and only reports a hover its checkbox can act on.
    private var hovered = false
    /// How far the node has travelled from its resting radius toward the hovered
    /// one: 0 = resting, 1 = fully at the post-click size. Animated by
    /// ``growthLink``; a hover that reverses mid-travel restarts from this live
    /// value, so the node never snaps back to re-run the tween.
    private var growth: CGFloat = 0
    /// Where `growth` stood when the current tween started, and when that was.
    private var growthOrigin: CGFloat = 0
    private var growthStartTime: CFTimeInterval = 0
    /// The tween's clock — the same vsync clock ``FoldAnimator`` and
    /// ``LevelMeterView`` run on, taken per-view (`NSView.displayLink`, which
    /// retains its target while active) because the value being animated is this
    /// view's own drawing, not a shared constraint. Nil at rest: nothing ticks
    /// once the node has arrived.
    private var growthLink: CADisplayLink?

    public init() {
        super.init(frame: .zero)
        // Reduce Motion turned on mid-travel lands the node on its target size
        // immediately — the same live-reconcile contract every other animated
        // instrument here honours (`RouteArmedDotView`, `HaloRingView`).
        // Selector-based observation needs no matching removal.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsDidChange),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil)
        // Non-layer-backed: the row it sits in is layer-backed, which promotes
        // this into the layer tree for compositing while this view's own `draw`
        // still runs (clipped to its bounds, which the hop-arc fits inside —
        // `busColumnWidth` reserves the room).
        wantsLayer = false
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Point the bus at a rendering. Idempotent — safe to re-apply on every row
    /// repaint.
    public func apply(node: Node, dimmed: Bool = false, originGold: Bool = false,
                      armed: Bool = true) {
        self.node = node
        self.dimmed = dimmed
        self.originGold = originGold
        self.armed = armed
        needsDisplay = true
    }

    /// Point the node at the pointer state the HOST row tracked. The node
    /// travels to ``postClickRadius(for:)`` and back — its CENTRE never moves,
    /// so the gutter stays still under the pointer and the click target is
    /// unchanged.
    ///
    /// Off-window or under Reduce Motion the size is taken instantly; otherwise
    /// the tween starts from wherever the node currently stands, so a hover-out
    /// mid-grow reverses smoothly instead of snapping or queueing.
    public func setHovered(_ hovered: Bool) {
        guard self.hovered != hovered else { return }
        self.hovered = hovered
        guard window != nil, !reduceMotion else { settleGrowth(); return }
        growthOrigin = growth
        growthStartTime = CACurrentMediaTime()
        startGrowthClock()
        needsDisplay = true
    }

    /// Land the node on its target size now and stop the clock (Reduce Motion,
    /// an off-screen row, or the tween arriving).
    private func settleGrowth() {
        growthLink?.invalidate()
        growthLink = nil
        growth = hovered ? 1 : 0
        needsDisplay = true
    }

    private func startGrowthClock() {
        guard growthLink == nil else { return }
        // `.common` mode: the pointer can cross the gutter with a button held
        // (a drag over the rows), and the affordance still has to travel.
        let link = displayLink(target: self, selector: #selector(growthTick))
        link.add(to: .main, forMode: .common)
        growthLink = link
    }

    /// One frame of the grow/shrink tween. Marked `@objc` for the
    /// selector-based `NSView.displayLink` callback.
    @objc private func growthTick() {
        let duration = PopoverColumnGrid.busNodeHoverGrowDuration
        let target: CGFloat = hovered ? 1 : 0
        let t: CGFloat = duration > 0
            ? min(1, max(0, CGFloat((CACurrentMediaTime() - growthStartTime) / duration)))
            : 1
        guard t < 1 else { settleGrowth(); return }
        // Ease-out cubic: the size is off the mark fastest at the start, so the
        // node answers the pointer immediately and settles rather than drifting.
        let eased = 1 - pow(1 - t, 3)
        growth = growthOrigin + (target - growthOrigin) * eased
        needsDisplay = true
    }

    /// A row leaving its window (a popover rebuild, a scroll recycle) has no
    /// travel left to make — settle, so nothing ticks off screen.
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { settleGrowth() }
    }

    @objc private func accessibilityDisplayOptionsDidChange() {
        if reduceMotion { settleGrowth() }
    }

    /// Test seam for Reduce Motion (`nil` = the live system setting), matching
    /// ``RouteArmedDotView``/``FoldAnimator``.
    public var test_reduceMotionOverride: Bool?

    private var reduceMotion: Bool {
        test_reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Non-interactive: never intercept clicks — the invisible checkbox behind
    /// the node (and the row behind the rail) must receive them (spec §4.8).
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        // The `.origin` carries no node — the continuous rail overlay draws the
        // Main Audio hook.
        guard node != .origin else { return }
        let r = drawnRadius

        effectiveAppearance.performAsCurrentDrawingAppearance {
            // NODE ONLY (Warm Signal v4 §Call-1, Alec's continuity correction):
            // the RAIL LINE + detour ARCS + origin HOOK are drawn by the
            // panel-level ``BusRailOverlayView`` so the spine is one continuous
            // line down a clear gutter. This view draws just the node disc/ring,
            // centred on the row's real checkbox so it aligns with the click
            // target. The overlay reads this node's kind (via the host row) to
            // place the rail's gap (on-spine) or detour arc (off-spine).
            let cx = bounds.midX
            let cy = bounds.midY
            let rect = NSRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)
            if node == .member {
                // Rim in the spine's own tone: gold on an armed rail, ember on
                // an idle one (same split the wire draws with). The fill is the
                // same tone, or the unlit `dotSocket` seat when dimmed — see
                // `dimmed`.
                let rim = Tokens.Color.spineTone(armed: armed)
                let fill = dimmed ? Tokens.Color.dotSocket : rim
                fill.setFill()
                NSBezierPath(ovalIn: rect).fill()
                strokeNodeRim(in: rect, color: rim, dashed: false)
            } else {
                // Hollow node: connecting = gold dashed, failed = heavier
                // failure-red ring, non-member/blocked = plain ember rim.
                // `dimmed` has nothing to reach here — there is no fill.
                strokeNodeRim(in: rect, color: rimColor(for: node),
                              dashed: isDashed(node))
            }
        }
    }

    /// Stroke a node's rim (hollow node border, or the filled node's edge).
    private func strokeNodeRim(in rect: NSRect, color: NSColor, dashed: Bool) {
        let width: CGFloat
        if node == .failed {
            width = PopoverColumnGrid.haloRingFailedStroke
        } else if node == .member, dimmed, emphasizesDimmedMemberRim {
            width = PopoverColumnGrid.busNodeDimmedRimWidth
        } else {
            width = PopoverColumnGrid.busNodeRimWidth
        }
        let rim = NSBezierPath(ovalIn: rect.insetBy(dx: width / 2, dy: width / 2))
        rim.lineWidth = width
        if dashed {
            rim.setLineDash([PopoverColumnGrid.haloRingDashLength,
                             PopoverColumnGrid.haloRingDashGap], count: 2, phase: 0)
        }
        color.setStroke()
        rim.stroke()
    }

    /// The rim colour for a hollow node. Never dimmed: the rim is the rail's.
    private func rimColor(for node: Node) -> NSColor {
        switch node {
        case .connecting:              return Tokens.Color.gold
        case .failed:                  return Tokens.Color.failure
        case .nonMember, .member,
             .origin:                  return Tokens.Color.ember
        }
    }

    /// Whether a node's rim is dashed (the "incomplete" connecting form).
    private func isDashed(_ node: Node) -> Bool {
        node == .connecting
    }

    /// The drawn disc radius for a node kind (Warm Signal v4.1 item 4 "larger
    /// selected nodes"): size joins fill as a selection signal, so a node still
    /// IN the mix (on-spine — member/connecting/failed, the same set
    /// `BusRailOverlayView.onSpine` treats as "the rail runs through it") draws
    /// at `busNodeDiameterSelected`; a genuine non-member/blocked node (off-spine,
    /// detoured) draws at the visibly smaller `busNodeDiameterUnselected`. Reuses
    /// `onSpine` rather than re-deriving the split, so the node's size and the
    /// rail's straight-through-vs-detour choice can never disagree. Node CENTER
    /// is unaffected — only this radius, so click targets and layout hold.
    static func nodeRadius(for node: Node) -> CGFloat {
        BusRailOverlayView.onSpine(node)
            ? PopoverColumnGrid.busNodeDiameterSelected / 2
            : PopoverColumnGrid.busNodeDiameterUnselected / 2
    }

    /// The radius this node would REST at once its checkbox's click has landed
    /// — the hover's whole target (Alec 2026-08-28: "it should only grow to the
    /// size it would eventually be if it's clicked"). The checkbox toggles
    /// membership, so the click moves an off-spine node ON to the spine and an
    /// on-spine one OFF it: this is exactly ``nodeRadius(for:)`` with the spine
    /// test inverted, reusing `onSpine` for the same reason that one does. A
    /// non-member therefore GROWS 5.5 → 7.5 and a member SHRINKS 7.5 → 5.5 —
    /// the direction of travel is what tells the user which way the click goes.
    /// The earlier fixed 10 pt hover radius was REJECTED: it was bigger than any
    /// size a node legitimately rests at, so the hover promised a state that
    /// does not exist.
    static func postClickRadius(for node: Node) -> CGFloat {
        BusRailOverlayView.onSpine(node)
            ? PopoverColumnGrid.busNodeDiameterUnselected / 2
            : PopoverColumnGrid.busNodeDiameterSelected / 2
    }

    /// The radius the node is TRAVELLING toward: its resting size, or its
    /// post-click size while the host reports an invitation. The resolved state
    /// — what a test asserts, and where an instant (Reduce Motion, off-screen)
    /// change lands.
    private var targetRadius: CGFloat {
        hovered ? Self.postClickRadius(for: node) : Self.nodeRadius(for: node)
    }

    /// The radius drawn THIS frame — resting to post-click, interpolated by the
    /// tween. Resolves through the SAME ``postClickRadius(for:)`` the target
    /// does, so the interpolation can never travel somewhere the target isn't.
    /// The node's centre is untouched, so nothing reflows and the click target
    /// never moves.
    private var drawnRadius: CGFloat {
        let resting = Self.nodeRadius(for: node)
        return resting + (Self.postClickRadius(for: node) - resting) * growth
    }

    // MARK: Test-support hooks

    /// The node rendering currently drawn (structural hook — the same `node` the
    /// drawing reads, so it can't drift from the pixels).
    public var test_node: Node { node }
    /// Whether this row's node FILL is the de-emphasis tint (`dotSocket`) —
    /// a tint, never alpha. The rim is never dimmed, and a hollow node has no
    /// fill, so on a `.nonMember` this flag changes no pixel (see `dimmed`).
    public var test_dimmed: Bool { dimmed }
    /// The disc radius this row's node draws at THIS frame — mid-tween while a
    /// hover is travelling. Structural hook, same value `draw` reads, so it
    /// can't drift from the pixels. Tests assert ``test_nodeTargetRadius``
    /// instead: a frame-accurate value is not deterministic under load.
    public var test_nodeRadius: CGFloat { drawnRadius }
    /// The radius the node is settling ON — resting, or its post-click size.
    /// The resolved state, so it is deterministic whatever the clock has done.
    public var test_nodeTargetRadius: CGFloat { targetRadius }
    /// Whether the host row is currently reporting a hover the node resizes for.
    public var test_hovered: Bool { hovered }
    /// Whether the node currently renders in the armed (gold) tone vs the quiet
    /// ember idle tone — the same flag `draw` reads for `.member`'s fill.
    public var test_armed: Bool { armed }
    /// Whether the node is settling on its POST-CLICK size rather than its
    /// resting one — true for a growing non-member and a shrinking member alike
    /// (structural hook — derived from the RADII the drawing resolves, never
    /// from a separate flag, so it can't claim a resize the pixels don't show).
    public var test_nodePreviewsClick: Bool { targetRadius != Self.nodeRadius(for: node) }
}
