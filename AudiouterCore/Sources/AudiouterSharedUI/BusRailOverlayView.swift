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
    /// The collapsible section that HOLDS the origin (the Main Audio row) — the
    /// "System Audio" card. When it collapses, the Main Audio ring clips away and
    /// the rail's ORIGIN moves up to sit at this section's own header (a dot),
    /// per the collapse-reactive contract (behavior 2). `nil` when the origin is
    /// not inside a collapsible section (e.g. a host that never collapses it).
    public weak var originSection: RailSectionProviding?
    /// The collapsible section that holds the DEVICE rows — the "Output Devices"
    /// card. When it collapses (or is mid-collapse), the rail is CUT SHORT at this
    /// section's header with a terminus dot rather than drawn over now-hidden rows;
    /// its live clip frame drives the in-sync squeeze (behaviors 1 + 3).
    public weak var deviceSection: RailSectionProviding?

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

    /// How many times this overlay has actually been drawn. The rail's geometry is
    /// resolved from live frames AT DRAW TIME, so it is only ever as fresh as its
    /// last INVALIDATION — which makes "was it asked to redraw?" the whole
    /// correctness question, and one that `needsDisplay` can't answer for a test
    /// (AppKit ignores the flag on a windowless view, and won't let you clear it on
    /// a view it has already scheduled). Counting real draws is the observable that
    /// distinguishes an invalidated overlay from a stale one.
    public private(set) var test_drawCount = 0

    public override func draw(_ dirtyRect: NSRect) {
        test_drawCount += 1
        guard let plan = resolvePlan() else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            drawPlan(plan)
        }
    }

    // MARK: Geometry resolution (collapse-reactive; pure once converted)

    /// Read every live view frame (origin ring, device rows, section clips +
    /// headers) ONCE, convert them into the overlay's coordinate space, then hand
    /// the plain numbers to `RailPlan.resolve` — a pure function — so the drawn
    /// geometry is a deterministic function of the CURRENT layout. The collapse
    /// animation drives `bodyClip`'s height frame-by-frame; the host's card stack
    /// (`RailStackView.layout`) re-invalidates this overlay on every one of those
    /// layout passes, so calling
    /// `resolvePlan` each frame makes the rail squeeze/extend IN SYNC with the
    /// collapse (behavior 3) using the intermediate clip frame, never a before/
    /// after snap. `nil` when the origin anchor can't be resolved (no window / not
    /// laid out) — nothing to draw.
    func resolvePlan() -> RailPlan? {
        guard let mainOutRow, let anchor = mainOutRow.railHookAnchor(in: self) else { return nil }

        // In-span node stops (rows carrying a rail above them), top-to-bottom.
        // Bare nodes below the terminus (no rail above) contribute no line — their
        // disc is drawn per-row. `RailPlan.resolve` clips these to the device
        // section's live band; here we only gather the full unclipped set.
        var stops: [RailPlan.Stop] = []
        for row in deviceRows {
            guard let node = row.railNode, row.railHasSpine else { continue }
            let f = convert(row.railNodeBounds, from: row.railNodeView)
            stops.append(RailPlan.Stop(y: f.midY, node: node, below: row.railBelow, dimmed: row.railDimmed))
        }
        stops.sort { $0.y > $1.y }   // non-flipped: top = higher y

        let input = RailPlan.Input(
            gold: anchor.gold,
            ringCenterY: anchor.centerY,
            ringCenterX: anchor.ringCenterX,
            ringRadius: anchor.ringRadius,
            landingDrop: PopoverColumnGrid.railRingHookLandingDrop,
            originSectionCollapsed: originSection?.railSectionCollapsed ?? false,
            originClipBand: clipBand(of: originSection),
            originHeaderY: headerTerminusY(of: originSection),
            deviceSectionCollapsed: deviceSection?.railSectionCollapsed ?? false,
            deviceFloorY: clipBand(of: deviceSection)?.lowerBound,
            stops: stops)
        return RailPlan.resolve(input)
    }

    /// A collapsible section's body-clip frame as an overlay-space y-range
    /// (`minY...maxY`), or `nil` if the section has no mounted clip. Read LIVE, so
    /// during a collapse it shrinks frame-by-frame and the rail tracks it.
    private func clipBand(of section: RailSectionProviding?) -> ClosedRange<CGFloat>? {
        guard let section, let clipView = section.railSectionClipView else { return nil }
        let f = convert(section.railSectionClipBounds, from: clipView)
        guard f.height >= 0 else { return nil }
        return f.minY...f.maxY
    }

    /// A collapsible section header's rail-gutter terminus y (its centre-Y in
    /// overlay space) — where the rail's origin dot / terminus dot lands when that
    /// section is collapsed. `nil` if the section has no header row yet.
    private func headerTerminusY(of section: RailSectionProviding?) -> CGFloat? {
        guard let section, let headerView = section.railSectionHeaderView else { return nil }
        return convert(section.railSectionHeaderBounds, from: headerView).midY
    }

    // MARK: Plan drawing

    private func drawPlan(_ plan: RailPlan) {
        // Warm Signal v4.1 item 4 ("larger selected nodes"): the gap/arc math is
        // keyed off each STOP's OWN node radius so the rail meets a large member
        // node and a small detoured non-member node cleanly at their true edges.
        let lw = PopoverColumnGrid.busLineWidth
        let cx = PopoverColumnGrid.railGutterCenterX
        // The hook/terminus tone and the Main Audio ring's connected stroke come
        // from the SAME resolution (`Tokens.Color.spineTone`), so the curve and
        // the ring it lands on can never be two different colors — including
        // mid-flight through an accent-dial change.
        let originColor = Tokens.Color.spineTone(armed: plan.gold)

        switch plan.origin {
        case let .ring(ringCenterY, ringCenterX, ringRadius):
            // Terminus (Warm Signal nitpicks — "rail into the ring"): the rail
            // curves up from the gutter column and lands directly on the Main
            // Audio ring's own left edge, stroked at the SAME width the ring uses
            // while connected, so the two read as one continuous line.
            let ringLeftX = ringCenterX - ringRadius
            let hook = NSBezierPath()
            hook.lineWidth = lw
            hook.lineCapStyle = .round
            hook.lineJoinStyle = .round
            hook.move(to: NSPoint(x: ringLeftX, y: ringCenterY))
            hook.curve(to: NSPoint(x: cx, y: ringCenterY - PopoverColumnGrid.railRingHookLandingDrop),
                       controlPoint1: NSPoint(x: ringLeftX - PopoverColumnGrid.railRingHookBulge, y: ringCenterY),
                       controlPoint2: NSPoint(x: cx, y: ringCenterY - PopoverColumnGrid.railRingHookControlDrop))
            originColor.setStroke()
            hook.stroke()
        case let .headerDot(y):
            // The origin section (System Audio) is collapsed: the Main Audio ring
            // is hidden, so the rail simply BEGINS at that collapsed header with a
            // small gutter dot (behavior 2 — the origin moves up to the header).
            originColor.setFill()
            fillTerminusDot(atY: y, x: cx)
        }

        var currentY = plan.railTopY
        for stop in plan.stops {
            let onSpine = Self.onSpine(stop.node)
            let stopR = MembershipBusView.nodeRadius(for: stop.node)
            // Segment tone (Warm Signal v4 §Call-1 + v4.1 items 3/4/9):
            //   • member (connected)  → GOLD (the lit spine at rest),
            //   • pending / connecting → ember (the energize "coming online" sweep),
            //   • FAILED               → DIM (item 9 — the red node carries failure),
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
                // The rail runs THROUGH the node with a breathing gap above.
                let gap = stopR + PopoverColumnGrid.busNodeRailGap
                strokeVertical(from: currentY, to: stop.y + gap, x: cx, lineWidth: lw)
                // A natural terminus (`!below`) ends the rail — UNLESS a collapsed/
                // clipping device section cuts it first (`terminusDotY != nil`), in
                // which case the rail continues down to that cut and dots there.
                if !stop.below && plan.terminusDotY == nil { return }
                currentY = stop.y - gap
            } else {
                // Detour ARC around a bypassed non-member node.
                let arcR = stopR + PopoverColumnGrid.busDetourBulge
                strokeVertical(from: currentY, to: stop.y + arcR, x: cx, lineWidth: lw)
                let arc = NSBezierPath()
                arc.lineWidth = lw
                arc.appendArc(withCenter: NSPoint(x: cx, y: stop.y), radius: arcR,
                              startAngle: 90, endAngle: 270, clockwise: false)
                arc.stroke()
                if !stop.below && plan.terminusDotY == nil { return }
                currentY = stop.y - arcR
            }
        }

        // Collapsed / mid-collapse device section: the rail was cut short. Run the
        // line down to the cut (the section's header, or the shrinking clip floor
        // mid-animation) and mark the stop with a terminus dot (behavior 1).
        if let terminusY = plan.terminusDotY {
            originColor.setStroke()
            strokeVertical(from: currentY, to: terminusY, x: cx, lineWidth: lw)
            originColor.setFill()
            fillTerminusDot(atY: terminusY, x: cx)
        }
    }

    /// Fill the small round terminus/origin gutter dot centred at `(x, y)`.
    private func fillTerminusDot(atY y: CGFloat, x: CGFloat) {
        let r = PopoverColumnGrid.railCollapsedTerminusDotDiameter / 2
        NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: r * 2, height: r * 2)).fill()
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

    /// The rail geometry the overlay would draw from its CURRENT live frames —
    /// the same plan `draw` renders. Lets tests assert the collapse-reactive
    /// resolution (origin at header vs ring, the terminus dot, which stops are
    /// visible) against real laid-out frames without a graphics context.
    public func test_resolvePlan() -> RailPlan? { resolvePlan() }
}

/// The drawable rail plan — resolved purely from geometry already converted into
/// the overlay's coordinate space (no view lookups), so it is deterministic and
/// unit-testable at any intermediate collapse height. `draw` renders exactly this.
public struct RailPlan: Equatable {
    /// One in-span device node the rail passes through / detours around.
    public struct Stop: Equatable {
        public var y: CGFloat
        public var node: MembershipBusView.Node
        /// Whether the rail continues below this node (false = natural terminus).
        public var below: Bool
        /// Whether the node (and the segment into it) renders dimmed.
        public var dimmed: Bool
    }

    /// How the rail begins at the top.
    public enum Origin: Equatable {
        /// Curve into the Main Audio ring (origin section expanded / ring visible).
        case ring(centerY: CGFloat, ringCenterX: CGFloat, ringRadius: CGFloat)
        /// A gutter dot at the collapsed origin section's header (behavior 2).
        case headerDot(y: CGFloat)
    }

    public var origin: Origin
    /// The y the vertical rail starts at, just below the origin hook/dot.
    public var railTopY: CGFloat
    /// The device stops to render, top-to-bottom, already CLIPPED to the visible
    /// device band (rows hidden inside a collapsing clip are dropped).
    public var stops: [Stop]
    /// When a collapsed / mid-collapse device section cuts the rail short, the y
    /// of the terminus dot (behaviors 1 + 3); `nil` when the rail ends naturally
    /// at its lowest selected node.
    public var terminusDotY: CGFloat?
    public var gold: Bool

    /// Plain-number inputs read from live frames by `BusRailOverlayView`.
    public struct Input {
        public var gold: Bool
        public var ringCenterY: CGFloat
        public var ringCenterX: CGFloat
        public var ringRadius: CGFloat
        public var landingDrop: CGFloat
        public var originSectionCollapsed: Bool
        /// The origin section's live body-clip band (`minY...maxY`); `nil` if it
        /// has no collapsible body. The ring counts as visible while its centre is
        /// inside this band — once the collapse shrinks the band past the ring, the
        /// origin snaps to the header dot.
        public var originClipBand: ClosedRange<CGFloat>?
        /// The origin section header's terminus y (dot position when collapsed).
        public var originHeaderY: CGFloat?
        public var deviceSectionCollapsed: Bool
        /// The device section's live clip floor (its band's `lowerBound`): the
        /// lowest y the rail may reach. `nil` if the device section has no clip.
        public var deviceFloorY: CGFloat?
        /// Every in-span stop, unclipped, sorted top-to-bottom (highest y first).
        public var stops: [Stop]

        public init(gold: Bool, ringCenterY: CGFloat, ringCenterX: CGFloat, ringRadius: CGFloat,
                    landingDrop: CGFloat, originSectionCollapsed: Bool,
                    originClipBand: ClosedRange<CGFloat>?, originHeaderY: CGFloat?,
                    deviceSectionCollapsed: Bool, deviceFloorY: CGFloat?, stops: [Stop]) {
            self.gold = gold
            self.ringCenterY = ringCenterY
            self.ringCenterX = ringCenterX
            self.ringRadius = ringRadius
            self.landingDrop = landingDrop
            self.originSectionCollapsed = originSectionCollapsed
            self.originClipBand = originClipBand
            self.originHeaderY = originHeaderY
            self.deviceSectionCollapsed = deviceSectionCollapsed
            self.deviceFloorY = deviceFloorY
            self.stops = stops
        }
    }

    /// Resolve the plan (pure). Two independent collapse behaviors:
    ///
    /// **Origin (behavior 2).** If the origin section is collapsed AND the Main
    /// Audio ring has fallen outside the section's live clip band (it clipped
    /// away), the rail begins at that section's header with a dot; otherwise it
    /// curves into the ring as normal. Keying "at header" off the live band (not
    /// just the collapsed flag) makes the origin RIDE UP with the shrinking clip
    /// rather than snap the instant the toggle flips (behavior 3).
    ///
    /// **Terminus (behaviors 1 + 3).** The device section's live clip floor caps
    /// how far down the rail reaches. Stops at/below the floor are dropped
    /// (they're clipped/hidden); if any stop is dropped — or the section is
    /// collapsed outright — the rail is CUT with a terminus dot at the floor,
    /// which lands at the section header once fully collapsed. When the section is
    /// expanded the floor sits below every node, so nothing is dropped and the
    /// rail ends naturally at its lowest selected node exactly as before (the
    /// expanded render is byte-for-byte unchanged).
    public static func resolve(_ input: Input) -> RailPlan {
        // Origin resolution.
        let originAtHeader: Bool = {
            guard input.originSectionCollapsed, input.originHeaderY != nil else { return false }
            if let band = input.originClipBand, band.contains(input.ringCenterY) { return false }
            return true
        }()
        let origin: Origin
        let railTopY: CGFloat
        if originAtHeader, let headerY = input.originHeaderY {
            origin = .headerDot(y: headerY)
            railTopY = headerY
        } else {
            origin = .ring(centerY: input.ringCenterY, ringCenterX: input.ringCenterX,
                           ringRadius: input.ringRadius)
            railTopY = input.ringCenterY - input.landingDrop
        }

        // Terminus resolution against the device clip floor.
        var drawnStops: [Stop] = []
        var terminusDotY: CGFloat?
        if let floorY = input.deviceFloorY {
            for stop in input.stops {
                if stop.y <= floorY { break }   // this stop (and all below) are clipped away
                drawnStops.append(stop)
            }
            let cut = drawnStops.count < input.stops.count || input.deviceSectionCollapsed
            if cut {
                // Never let the cut ride ABOVE where the rail started (a degenerate
                // fully-collapsed panel) — clamp so the dot sits at/below railTop.
                terminusDotY = min(floorY, railTopY)
            }
        } else {
            drawnStops = input.stops
        }

        return RailPlan(origin: origin, railTopY: railTopY, stops: drawnStops,
                        terminusDotY: terminusDotY, gold: input.gold)
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

/// The Main Audio row's origin-hook anchor for the continuous rail (Warm
/// Signal nitpicks — "rail into the ring"): the rail's terminus is now the
/// Main Audio ring itself, not a bare gutter dot, so the anchor describes the
/// ring's own geometry (centre + radius) rather than a single leading point.
public protocol RailHookProviding: AnyObject {
    /// The ring's centre-Y and centre-X (both converted into `view`'s
    /// coordinates) plus its radius, and whether the spine is armed (gold vs
    /// ember). `nil` if the anchor can't be resolved (no window / not laid
    /// out). The overlay curves the rail from the gutter column up to this
    /// ring's left edge (`ringCenterX - ringRadius`, `centerY`).
    func railHookAnchor(in view: NSView) -> (centerY: CGFloat, ringCenterX: CGFloat, ringRadius: CGFloat, gold: Bool)?
}

/// A collapsible section the rail passes through (the origin's "System Audio"
/// card, or the device rows' "Output Devices" card), so `BusRailOverlayView` can
/// react to its collapse (collapse-reactive rail, 2026-07-22):
///
/// - `railSectionCollapsed` — the section's target collapsed state.
/// - the HEADER row (always visible) supplies the terminus/origin dot anchor.
/// - the BODY CLIP's LIVE frame bounds the visible rows; the overlay reads it
///   every draw so the rail squeezes IN SYNC with the animating clip height
///   rather than snapping to the settled state (behavior 3). `nil` for a section
///   whose body hasn't mounted yet.
public protocol RailSectionProviding: AnyObject {
    /// The section's (target) collapsed state.
    var railSectionCollapsed: Bool { get }
    /// The always-visible header row whose gutter point anchors the collapsed
    /// origin/terminus dot; `nil` if the section has no rows yet.
    var railSectionHeaderView: NSView? { get }
    /// The header row's bounds (in `railSectionHeaderView`'s coordinates).
    var railSectionHeaderBounds: NSRect { get }
    /// The body-clip view whose LIVE frame bounds the visible rows; `nil` until a
    /// body row mounts it.
    var railSectionClipView: NSView? { get }
    /// The body-clip's bounds (in `railSectionClipView`'s coordinates).
    var railSectionClipBounds: NSRect { get }
}
