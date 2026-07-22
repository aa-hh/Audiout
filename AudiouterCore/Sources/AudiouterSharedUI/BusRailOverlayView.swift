// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

/// The **continuous membership-rail spine** (Warm Signal v4 §Call-1, Alec's
/// continuity correction): a single panel-level overlay that draws the rail as
/// ONE UNINTERRUPTED line down the left gutter — Main Audio's `.origin` hook →
/// the LOWEST SELECTED device node — passing STRAIGHT THROUGH any section-header
/// rows, subsection headers, and hairline dividers it crosses. Per-row bus
/// segments left a gap wherever a non-device row (a header or a divider) sat in
/// the span; drawing the rail as one continuous element here removes every such
/// gap. The overlay sits ON TOP of the cards + dividers (added last), so where
/// the rail crosses a hairline it reads unbroken. It is non-interactive
/// (`hitTest` returns `nil`).
///
/// **Division of labour:** this overlay draws the rail LINE, the detour ARCS
/// around bypassed non-member nodes, and the origin HOOK. The NODE discs/rings
/// stay per-row (`MembershipBusView` with `drawsRailLine == false`), centred on
/// each row's real checkbox, so they align exactly with the click target. The
/// overlay reads each row's live frame + node state at draw time, so it always
/// reflects the current layout (collapse/expand/resize) with no cached geometry.
///
/// The rail lives at `railGutterCenterX` (≈20 pt from the panel's left edge);
/// section-title text sits in the name column far to the right, so a continuous
/// vertical rail never collides with a title.
///
/// **Determinism:** steady drawing (no animation) computed from settled frames,
/// so `cacheDisplay` snapshots are byte-identical run-to-run.
public final class BusRailOverlayView: NSView {

    /// The Main Audio row supplying the origin-hook anchor (the meter's leading
    /// edge / centre-y) and whether the spine is armed (gold vs ember).
    public weak var mainOutRow: RailHookProviding?
    /// The device rows contributing nodes, in top-to-bottom display order. The
    /// overlay reads each one's live frame + rail state every draw.
    public var deviceRows: [RailNodeProviding] = []

    public init() {
        super.init(frame: .zero)
        wantsLayer = false
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Non-interactive: clicks fall through to the cards/rows beneath.
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let mainOutRow, let anchor = mainOutRow.railHookAnchor(in: self) else { return }

        // Warm Signal v4.1 item 4 ("larger selected nodes"): the gap/arc math
        // is keyed off each STOP's OWN node radius (`MembershipBusView.nodeRadius`)
        // rather than one fixed radius, so the rail still meets a large member
        // node and a small detoured non-member node cleanly at their true edges.
        let lw = PopoverColumnGrid.busLineWidth
        let cx = PopoverColumnGrid.railGutterCenterX

        // Gather the in-span node stops (those carrying a rail above them),
        // top-to-bottom, from the visible device rows. Bare nodes below the
        // terminus (no rail above) contribute no line — their disc is drawn
        // per-row. Rows in a collapsed card fall outside the overlay bounds and
        // are skipped.
        var stops: [(y: CGFloat, node: MembershipBusView.Node, below: Bool, dimmed: Bool)] = []
        for row in deviceRows {
            guard let node = row.railNode, row.railHasSpine else { continue }
            let f = convert(row.railNodeBounds, from: row.railNodeView)
            guard f.midY >= bounds.minY, f.midY <= bounds.maxY else { continue }
            stops.append((f.midY, node, row.railBelow, row.railDimmed))
        }
        stops.sort { $0.y > $1.y }   // non-flipped: top = higher y

        effectiveAppearance.performAsCurrentDrawingAppearance {
            // Origin point (Warm Signal v4.1 CORRECTIONS, item 2 — reworking
            // the earlier "hook into the meter" treatment): the rail simply
            // BEGINS here, at Main Audio's own gutter column. The master
            // meter moved under the Main Audio name (item 1), clear of the
            // gutter entirely, so there is no leading strip to jog into and
            // no junction to fuse — `anchor.leadingX` already equals `cx`
            // (both derive from `railGutterCenterX`); a defensive horizontal
            // segment is drawn only in case a future anchor ever diverges.
            let originColor = anchor.gold ? Tokens.Color.gold : Tokens.Color.ember
            if abs(anchor.leadingX - cx) > 0.01 {
                let jog = NSBezierPath()
                jog.lineWidth = lw
                jog.lineCapStyle = .round
                jog.lineJoinStyle = .round
                jog.move(to: NSPoint(x: anchor.leadingX, y: anchor.centerY))
                jog.line(to: NSPoint(x: cx, y: anchor.centerY))
                originColor.setStroke()
                jog.stroke()
            }

            // A small clean origin dot marks where the spine starts — never a
            // junction fused into anything else.
            let dotR = PopoverColumnGrid.busOriginDotDiameter / 2
            let dot = NSBezierPath(ovalIn: NSRect(x: cx - dotR, y: anchor.centerY - dotR,
                                                   width: dotR * 2, height: dotR * 2))
            originColor.setFill()
            dot.fill()

            var currentY = anchor.centerY
            for stop in stops {
                let onSpine = Self.onSpine(stop.node)
                let stopR = MembershipBusView.nodeRadius(for: stop.node)
                // Segment tone (Warm Signal v4 §Call-1 + v4.1 items 3/4/9):
                //   • member (connected)  → GOLD (the lit spine at rest),
                //   • pending / connecting → ember (the energize "coming online"
                //     sweep — brightens to gold top-to-bottom AS each fills),
                //   • FAILED               → DIM (item 9: "failed devices stay
                //     failure-red, their segment dim" — the red node/halo ring
                //     carries the failure; the rail into it recedes so a dead
                //     room never reads as a lit feed),
                //   • dormant-divergent    → DIM (the §4.7 tint the node uses).
                let segColor: NSColor
                if stop.dimmed || stop.node == .failed {
                    segColor = Tokens.Color.tertiaryLabel
                } else if stop.node == .member {
                    segColor = Tokens.Color.gold
                } else {
                    segColor = Tokens.Color.ember
                }
                segColor.setStroke()

                if onSpine {
                    // The rail runs THROUGH the node with a breathing gap above,
                    // sized off THIS node's own (larger, selected) radius.
                    let gap = stopR + PopoverColumnGrid.busNodeRailGap
                    let topApproach = stop.y + gap
                    strokeVertical(from: currentY, to: topApproach, x: cx, lineWidth: lw)
                    if !stop.below { break }              // terminus — nothing below
                    currentY = stop.y - gap
                } else {
                    // Detour ARC around a bypassed non-member node, sized off
                    // THIS node's own (smaller, unselected) radius.
                    let arcR = stopR + PopoverColumnGrid.busDetourBulge
                    let topApproach = stop.y + arcR
                    strokeVertical(from: currentY, to: topApproach, x: cx, lineWidth: lw)
                    let arc = NSBezierPath()
                    arc.lineWidth = lw
                    arc.appendArc(withCenter: NSPoint(x: cx, y: stop.y), radius: arcR,
                                  startAngle: 90, endAngle: 270, clockwise: false)
                    arc.stroke()
                    if !stop.below { break }
                    currentY = stop.y - arcR
                }
            }
        }
    }

    private func strokeVertical(from: CGFloat, to: CGFloat, x: CGFloat, lineWidth: CGFloat) {
        guard abs(from - to) > 0.01 else { return }
        let line = NSBezierPath()
        line.lineWidth = lineWidth
        line.lineCapStyle = .round
        line.move(to: NSPoint(x: x, y: from))
        line.line(to: NSPoint(x: x, y: to))
        line.stroke()
    }

    /// Whether a node sits ON the spine (rail runs through it) vs OFF it (the
    /// line detours around it). Members and members-in-transition are on-spine;
    /// genuine non-members and the blocked local node are detoured.
    static func onSpine(_ node: MembershipBusView.Node) -> Bool {
        switch node {
        case .member, .connecting, .pending, .failed, .origin: return true
        case .nonMember, .blocked:                             return false
        }
    }
}

/// A device row's contribution to the continuous rail (Warm Signal v4 §Call-1):
/// its node kind, rail extent, dimming, and the view + bounds whose centre the
/// node sits on (so the overlay can place the rail exactly on the row).
public protocol RailNodeProviding: AnyObject {
    /// The node this row renders, or `nil` if the row carries no bus node.
    var railNode: MembershipBusView.Node? { get }
    /// Whether the row is within the rail span (has a rail above it) — false on
    /// a bare node below the terminus.
    var railHasSpine: Bool { get }
    /// Whether the rail continues below this node (false on the terminus).
    var railBelow: Bool { get }
    /// Whether the node renders dimmed (dormant-divergent tint).
    var railDimmed: Bool { get }
    /// The view whose coordinate space `railNodeBounds` is in.
    var railNodeView: NSView { get }
    /// The bounds whose `midY` is the node's centre (in `railNodeView` coords).
    var railNodeBounds: NSRect { get }
}

/// The Main Audio row's origin-hook anchor for the continuous rail.
public protocol RailHookProviding: AnyObject {
    /// The hook target (the meter's leading edge x + centre y) converted into
    /// `view`'s coordinates, plus whether the spine is armed (gold vs ember).
    /// `nil` if the anchor can't be resolved (no window / not laid out).
    func railHookAnchor(in view: NSView) -> (leadingX: CGFloat, centerY: CGFloat, gold: Bool)?
}
