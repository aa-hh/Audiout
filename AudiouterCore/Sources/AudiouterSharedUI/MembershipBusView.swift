// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

/// The **membership bus** drawing (Warm Signal v3 §4, S-BUS): the DRAWING-ONLY
/// skin that replaces the "Selected Devices" checkbox's rendering with a bus —
/// a continuous vertical line down one fixed column, with a FILLED gold node on
/// the line for a member and a HOLLOW node the line visibly DETOURS around (a
/// wire-hop arc, the circuit-diagram idiom) for a non-member. Only the drawing
/// lives here; the real `NSButton` checkbox stays the control underneath, with
/// its action path, keyboard, and VoiceOver intact (spec §4.8). This view is
/// **non-interactive** — `hitTest` returns `nil`, so a click on the node area
/// falls straight through to the invisible checkbox behind it and every rail
/// click falls through to the row.
///
/// **Cross-row continuity is achieved per-row, not by a panel overlay** (the
/// design call the task left open, spec §4.2 "each row contributes its node +
/// its segment"): each row hosts one `MembershipBusView` sized to the FULL row
/// height and centered on the node column x (`trailingControlCenterFromTrailing`).
/// Every view draws a top-half and bottom-half rail segment, so stacked rows'
/// segments read as one continuous line with zero cross-view geometry to keep in
/// sync — deterministic by construction for the snapshot gate. The row tells it
/// whether to draw the rail above (`railAbove`) and below (`railBelow`) its node;
/// the last device row on the bus passes `railBelow: false` so the line
/// terminates at the last node (spec §4.1) rather than dangling below it. A short
/// cosmetic break appears at a subsection header row (which hosts no bus segment);
/// column alignment carries the eye across it.
///
/// Geometry comes entirely from `PopoverColumnGrid` named constants
/// (`busNodeDiameter`, `busLineWidth`, `busNodeRimWidth`, `busDetourBulge`,
/// `busColumnWidth`) so a future density setting swaps node + column sizing in one
/// place (spec §4.1 "constants promoted into PopoverColumnGrid").
///
/// Colors are the `gold`/`ember` accent tokens (spec §4.1/§4.2), resolved LIVE
/// against the effective appearance every draw (never a frozen `CGColor`) so a
/// light/dark or Increase-Contrast switch re-tints correctly. A dormant-divergent
/// row (§4.7) dims via `text-3` **tint**, never alpha — genuine divergence still
/// reads, it just recedes. A blocked local-mix node (§4.6) is a distinct greyed
/// hollow node.
///
/// **Determinism:** the node + rails are steady drawing (no animation), so
/// `cacheDisplay(in:to:)` captures them identically every run.
public final class MembershipBusView: NSView {

    /// What this row's bus node renders as. The line path follows from it: a
    /// member sits ON the line (straight run), a non-member/blocked node is
    /// DETOURED around (the hop arc).
    public enum Node: Equatable {
        /// In the mix set — a FILLED gold disc with an ember rim, the line running
        /// straight through it (spec §4.2/§4.3).
        case member
        /// Not in the mix set — a HOLLOW node the line bows around (spec §4.2/§4.4).
        case nonMember
        /// The local-mix **blocked** node (spec §4.6): a distinct greyed hollow
        /// node; the underlying checkbox is honestly disabled and a body-click
        /// surfaces the refusal note.
        case blocked
        /// The Main Out **origin** (spec §4.1): no node, a straight rail stub that
        /// launches the bus downward out of the destination dropdown's column.
        case origin
    }

    private var node: Node = .nonMember
    private var railAbove = true
    private var railBelow = true
    /// Dormant-divergent tint (spec §4.7): dim the node + line to `text-3` via
    /// tint (not alpha) when the Selected set genuinely diverges from the active
    /// group target.
    private var dimmed = false

    public init() {
        super.init(frame: .zero)
        // Non-layer-backed: the row it sits in is layer-backed, which promotes
        // this into the layer tree for compositing while this view's own `draw`
        // still runs (and stays clipped to its bounds, which the hop-arc fits
        // inside — `busColumnWidth` reserves the room).
        wantsLayer = false
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Point the bus at a rendering. `railAbove`/`railBelow` gate the vertical rail
    /// segments so the last device row can terminate the line at its node
    /// (`railBelow: false`, spec §4.1). Idempotent — safe to re-apply on every row
    /// repaint.
    public func apply(node: Node, railAbove: Bool = true, railBelow: Bool = true,
                      dimmed: Bool = false) {
        self.node = node
        self.railAbove = railAbove
        self.railBelow = railBelow
        self.dimmed = dimmed
        needsDisplay = true
    }

    /// Non-interactive: never intercept clicks — the invisible checkbox behind the
    /// node (and the row behind the rail) must receive them (spec §4.8).
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        let cx = bounds.midX
        let cy = bounds.midY
        let r = PopoverColumnGrid.busNodeDiameter / 2
        let lw = PopoverColumnGrid.busLineWidth
        let arcR = r + PopoverColumnGrid.busDetourBulge

        effectiveAppearance.performAsCurrentDrawingAppearance {
            let lineColor = dimmed ? Tokens.Color.tertiaryLabel : Tokens.Color.ember
            lineColor.setStroke()

            switch node {
            case .origin:
                // Straight rail stub, no node — the bus's launch point.
                let rail = NSBezierPath()
                rail.lineWidth = lw
                rail.move(to: NSPoint(x: cx, y: bounds.maxY))
                rail.line(to: NSPoint(x: cx, y: bounds.minY))
                rail.stroke()

            case .member:
                // The line runs STRAIGHT THROUGH a member node.
                let rail = NSBezierPath()
                rail.lineWidth = lw
                rail.move(to: NSPoint(x: cx, y: railAbove ? bounds.maxY : cy))
                rail.line(to: NSPoint(x: cx, y: railBelow ? bounds.minY : cy))
                rail.stroke()
                // Filled gold disc + ember rim on top of the line.
                let rect = NSRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)
                (dimmed ? Tokens.Color.tertiaryLabel : Tokens.Color.gold).setFill()
                NSBezierPath(ovalIn: rect).fill()
                let rim = NSBezierPath(ovalIn: rect.insetBy(dx: PopoverColumnGrid.busNodeRimWidth / 2,
                                                            dy: PopoverColumnGrid.busNodeRimWidth / 2))
                rim.lineWidth = PopoverColumnGrid.busNodeRimWidth
                lineColor.setStroke()
                rim.stroke()

            case .nonMember, .blocked:
                // The line DETOURS around a hollow node: straight rail up to / down
                // from the arc endpoints, plus a leading-side semicircular hop arc.
                let approachTop = NSPoint(x: cx, y: cy + arcR)
                let approachBot = NSPoint(x: cx, y: cy - arcR)
                let rail = NSBezierPath()
                rail.lineWidth = lw
                if railAbove {
                    rail.move(to: NSPoint(x: cx, y: bounds.maxY))
                    rail.line(to: approachTop)
                }
                if railBelow {
                    rail.move(to: approachBot)
                    rail.line(to: NSPoint(x: cx, y: bounds.minY))
                }
                rail.stroke()
                // Hop arc: a semicircle bowing to the LEADING (left) side, from the
                // top approach point down to the bottom one, clearing the node by
                // `busDetourBulge` (y-up coords: 90° = +y top, 270° = −y bottom,
                // counterclockwise passes through 180° = −x, the left bulge).
                let arc = NSBezierPath()
                arc.lineWidth = lw
                arc.appendArc(withCenter: NSPoint(x: cx, y: cy), radius: arcR,
                              startAngle: 90, endAngle: 270, clockwise: false)
                arc.stroke()
                // Hollow node: rim only (canvas shows through the center) — greyed
                // for a blocked node (§4.6), else ember (dim → text-3, §4.7).
                let rect = NSRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)
                let rimColor: NSColor = node == .blocked
                    ? Tokens.Color.tertiaryLabel
                    : lineColor
                let rim = NSBezierPath(ovalIn: rect.insetBy(dx: PopoverColumnGrid.busNodeRimWidth / 2,
                                                            dy: PopoverColumnGrid.busNodeRimWidth / 2))
                rim.lineWidth = PopoverColumnGrid.busNodeRimWidth
                rimColor.setStroke()
                rim.stroke()
            }
        }
    }

    // MARK: Test-support hooks

    /// The node rendering currently drawn (structural hook — the same `node` the
    /// drawing reads, so it can't drift from the pixels).
    public var test_node: Node { node }
    /// Whether the rail is drawn below the node (false only on the terminating
    /// last-row node, spec §4.1).
    public var test_railBelow: Bool { railBelow }
    /// Whether this row's node is rendered dimmed via the dormant-divergent tint
    /// (spec §4.7) — a tint, never alpha.
    public var test_dimmed: Bool { dimmed }
}
