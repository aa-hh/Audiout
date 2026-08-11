// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

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
/// **Socket + plug.** Every node (except the `.origin`) sits in a SOCKET: a
/// recessed pad in the milled channel the overlay draws, painted here in the
/// same `well`/`faderRim` pair the fader troughs use. The socket is CONSTANT —
/// infrastructure that never dims and never changes size — so a small hollow
/// node reads as an empty socket and a large filled member disc reads as a plug
/// seated in it.
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
/// hollow), `.failed` (failure-red ring), `.nonMember` (hollow, detoured),
/// `.blocked` (greyed hollow). The energize "pending" beat has NO node form of
/// its own — an ember dashed rim is indistinguishable from the gold dashed one
/// at node size, so the beat renders as `.connecting`. **Rail segment tone:**
/// GOLD through a connected member, `ember` otherwise — ember survives as a
/// SEGMENT tone only, which is where Call 3's energize sequence reads.
///
/// **Determinism:** node + rails are steady drawing (no animation), so
/// `cacheDisplay(in:to:)` captures them identically every run.
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
        /// The local-mix **blocked** node (spec §4.6): a distinct greyed hollow
        /// node; the underlying checkbox is honestly disabled.
        case blocked
        /// The Main Audio **origin** (spec §Call-1 "the rail hooks UP into the
        /// Main Audio row's meter"): draws nothing here — the panel-level
        /// ``BusRailOverlayView`` draws the L-shaped hook that rises at
        /// `railGutterCenterX` and turns into the meter. The host frames this
        /// view so its top-right corner sits at the meter's leading edge /
        /// centre-y.
        case origin
    }

    private var node: Node = .nonMember
    /// Dormant-divergent tint (spec §4.7): dim the node + line to `text-3` via
    /// tint (not alpha) when the Selected set genuinely diverges from the active
    /// group target.
    private var dimmed = false
    /// Whether the `.origin` hook draws GOLD (the Main Audio spine is armed —
    /// connected members are feeding it) vs the quiet `ember` idle tone (v4
    /// §Call-1 rail-segment tone). Ignored for every non-origin node.
    private var originGold = false
    /// Whether the pointer is over the row's bus-gutter region — the socket rim
    /// brightens from `faderRim` to the node's own action tone so the node
    /// admits it is clickable. The HOST row owns the tracking (this view stays
    /// non-interactive) and only reports a hover its checkbox can act on.
    private var hovered = false

    public init() {
        super.init(frame: .zero)
        // Non-layer-backed: the row it sits in is layer-backed, which promotes
        // this into the layer tree for compositing while this view's own `draw`
        // still runs (clipped to its bounds, which the hop-arc fits inside —
        // `busColumnWidth` reserves the room).
        wantsLayer = false
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Point the bus at a rendering. Idempotent — safe to re-apply on every row
    /// repaint.
    public func apply(node: Node, dimmed: Bool = false, originGold: Bool = false) {
        self.node = node
        self.dimmed = dimmed
        self.originGold = originGold
        needsDisplay = true
    }

    /// Point the socket at the pointer state the HOST row tracked. Rim tone
    /// only — no size change, no glow — so the hover reads as the socket
    /// waking up rather than the node moving.
    public func setHovered(_ hovered: Bool) {
        guard self.hovered != hovered else { return }
        self.hovered = hovered
        needsDisplay = true
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
        let r = Self.nodeRadius(for: node)

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
            let ember = dimmed ? Tokens.Color.tertiaryLabel : Tokens.Color.ember
            drawSocket(centerX: cx, centerY: cy)
            let rect = NSRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)
            if node == .member {
                // Filled gold disc + gold rim.
                (dimmed ? Tokens.Color.tertiaryLabel : Tokens.Color.gold).setFill()
                NSBezierPath(ovalIn: rect).fill()
                strokeNodeRim(in: rect, color: dimmed ? Tokens.Color.tertiaryLabel : Tokens.Color.gold,
                              dashed: false)
            } else {
                // Hollow node: connecting = gold dashed, failed = heavier
                // failure-red ring, non-member/blocked = plain rim.
                strokeNodeRim(in: rect, color: rimColor(for: node, ember: ember),
                              dashed: isDashed(node))
            }
        }
    }

    /// The recessed SOCKET pad the node is seated in — the `well` fill + 1 pt
    /// `faderRim` rim `WarmFaderCell` gives its trough, so the rail's channel and
    /// the faders read as the same milled surface. Constant size for every node
    /// kind, and never dimmed: the socket is infrastructure, not signal.
    private func drawSocket(centerX: CGFloat, centerY: CGFloat) {
        let padR = PopoverColumnGrid.railSocketPadRadius
        let pad = NSRect(x: centerX - padR, y: centerY - padR, width: 2 * padR, height: 2 * padR)
        Tokens.Color.well.setFill()
        NSBezierPath(ovalIn: pad).fill()
        let rim = NSBezierPath(ovalIn: pad.insetBy(dx: 0.5, dy: 0.5))
        rim.lineWidth = 1
        socketRimColor.setStroke()
        rim.stroke()
    }

    /// The socket rim's tone: the resting `faderRim` normally, the node's own
    /// action tone (`gold`) while the pointer is over the gutter. A `.blocked`
    /// node keeps the resting rim in both states — its checkbox is honestly
    /// disabled, and a disabled control must not invite the click.
    private var socketRimColor: NSColor {
        (hovered && node != .blocked) ? Tokens.Color.gold : Tokens.Color.faderRim
    }

    /// Stroke a node's rim (hollow node border, or the filled node's edge).
    private func strokeNodeRim(in rect: NSRect, color: NSColor, dashed: Bool) {
        let width: CGFloat = node == .failed
            ? PopoverColumnGrid.haloRingFailedStroke
            : PopoverColumnGrid.busNodeRimWidth
        let rim = NSBezierPath(ovalIn: rect.insetBy(dx: width / 2, dy: width / 2))
        rim.lineWidth = width
        if dashed {
            rim.setLineDash([PopoverColumnGrid.haloRingDashLength,
                             PopoverColumnGrid.haloRingDashGap], count: 2, phase: 0)
        }
        color.setStroke()
        rim.stroke()
    }

    /// The rim colour for a hollow node.
    private func rimColor(for node: Node, ember: NSColor) -> NSColor {
        switch node {
        case .connecting:              return dimmed ? Tokens.Color.tertiaryLabel : Tokens.Color.gold
        case .failed:                  return Tokens.Color.failure  // never dimmed
        case .blocked:                 return Tokens.Color.tertiaryLabel
        case .nonMember, .member,
             .origin:                  return ember
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

    // MARK: Test-support hooks

    /// The node rendering currently drawn (structural hook — the same `node` the
    /// drawing reads, so it can't drift from the pixels).
    public var test_node: Node { node }
    /// Whether this row's node is rendered dimmed via the dormant-divergent tint
    /// (spec §4.7) — a tint, never alpha.
    public var test_dimmed: Bool { dimmed }
    /// The disc radius this row's node currently draws at (v4.1 item 4 — size
    /// joins fill as a selection signal). Structural hook, same value `draw`
    /// reads, so it can't drift from the pixels.
    public var test_nodeRadius: CGFloat { Self.nodeRadius(for: node) }
    /// Whether the host row is currently reporting a gutter hover.
    public var test_hovered: Bool { hovered }
    /// The socket rim tone this node currently draws (structural hook — the
    /// same value `drawSocket` strokes with, so it can't drift from the pixels).
    public var test_socketRimColor: NSColor { socketRimColor }
}
