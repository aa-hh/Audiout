// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

/// The **continuous membership-rail spine** (Warm Signal v4 §Call-1, Alec's
/// continuity correction): a single panel-level overlay that draws the rail as
/// ONE UNINTERRUPTED line down the left gutter, passing STRAIGHT THROUGH any
/// section-header rows, subsection headers, and hairline dividers it crosses.
/// Per-row bus segments left a gap wherever a non-device row (a header or a
/// divider) sat in the span; drawing the rail as one continuous element here
/// removes every such gap. The overlay sits ON TOP of the cards + dividers
/// (added last), so where the rail crosses a hairline it reads unbroken. It is
/// non-interactive (`hitTest` returns `nil`).
///
/// **One wire, one tone.** The rail is a single stroked line — no channel, no
/// pad, nothing under it: gold while the spine is armed, ember while it idles,
/// one quiet tone end to end while it is dormant. It runs from the origin hook
/// to its terminus, the LOWEST ON-SPINE node, detouring around every off-spine
/// node it passes on the way. Rows below the terminus draw their node disc and
/// no line.
///
/// **Division of labour:** this overlay draws the line, the detour ARCS around
/// bypassed non-member nodes, and the origin HOOK. The NODE discs/rings stay
/// per-row (`MembershipBusView`), centred on each row's real checkbox, so they
/// align exactly with the click target. The overlay reads each row's live frame
/// + node state at draw time, so it always reflects the current layout
/// (collapse/expand/resize) with no cached geometry.
///
/// The rail lives at `railGutterCenterX` (≈20 pt from the panel's left edge);
/// section-title text sits in the name column far to the right, so a continuous
/// vertical rail never collides with a title.
///
/// **Connect pulse (Warm Signal v4.1 item 9, reshaped 2026-08-12 — "a pulse
/// along the rail towards the main out"):** when the wire GAINS gold reach —
/// the spine arms, or a new member segment goes live on an armed spine — a
/// short bright `glow` window departs from the JOINING ROOM's own node (the
/// whole wire's terminus when the spine arms), travels up the wire at constant
/// speed, and is absorbed into the Main Audio ring: the room announcing itself
/// up the bus. It completes the connect story the row already tells — dashed
/// breathing node while the handshake runs (`.connecting`), then this pulse
/// the moment the node lands `.member`. (The first cut was a dim ember film
/// retreating downward; live it read as nothing on connect and a plain
/// dim-out on disconnect — inverted. A bright pulse over the gold wire is
/// unmissable on connect, and a loss animates nothing.) One-shot,
/// self-removing (nothing runs at rest), gone entirely under Reduce Motion,
/// and never fired by the first draw in a window (no transient fires on open,
/// spec §6).
///
/// **Determinism:** the settled wire is steady drawing computed from settled
/// frames, and the pulse follows the settled-model-layer contract
/// (`RouteArmedDotView` precedent): the pulse layer's MODEL is fully absorbed
/// (invisible) and only its presentation animates, so `cacheDisplay` snapshots
/// are byte-identical run-to-run at ANY capture instant.
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
    /// The dormant-divergent condition (spec §4.7): the checked set genuinely
    /// diverges from the active group target, so nothing on this rail is
    /// actually feeding audio. The host owns the condition; when it is set the
    /// WHOLE signal path draws in one quiet tone rather than a per-row patchwork.
    /// Node fills stay per-row; this is the wire's tone alone.
    public var dormant = false

    /// The transient connect pulse currently mid-flight, if any (test-visible
    /// through ``test_isConnectPulsing``; nothing survives the pulse).
    private var pulseLayer: CAShapeLayer?
    private static let pulseKey = "busRail.connectPulse"
    /// The bead's length ON GLASS, in points — fixed, so it reads as a bead of
    /// light on any wire. (A fraction-of-the-wire window became a long STRIP
    /// on a tall wire — Alec's live read of that cut.) Capped at 45% of a very
    /// short wire so the bead never IS the wire.
    private static let beadLength: CGFloat = 26
    /// How long the landed bubble takes to dissolve into the ring.
    private static let beadAbsorbDuration: CFTimeInterval = 0.12
    /// The arrival bloom's disc radius (its light halo doubles the visual
    /// footprint via the shadow).
    private static let arrivalBloomRadius: CGFloat = 5
    /// The transient header-dot bloom currently playing at a COLLAPSED origin,
    /// if any (mounted by the bead's completion; dies with any cancel). An
    /// uncollapsed origin has a real ring, which blooms itself.
    private var arrivalLayer: CAShapeLayer?
    /// The last VISIBLY drawn plan's energize signature. `nil` = no baseline
    /// yet, so the next on-screen draw stamps one WITHOUT firing — the first
    /// render the user can see is always settled (no transient fires on open,
    /// spec §6).
    private var lastEnergy: EnergySignature?
    /// The last drawn plan's member-stop y positions — diffed against the next
    /// draw's to name WHICH room just joined, so the pulse departs from its
    /// node rather than the wire's end.
    private var lastMemberYs: [CGFloat] = []

    public init() {
        super.init(frame: .zero)
        // Layer-backed so the one-shot connect pulse has a layer to ride;
        // `draw(_:)` still paints the settled wire into the backing layer.
        wantsLayer = true
        // Mid-session accessibility-display + accent-dial changes reconcile
        // LIVE (AGENTS.md rules — neither arrives through `apply` or an
        // appearance change). Selector-based observation needs no matching
        // removal (post-10.11 AppKit auto-unregisters).
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsDidChange),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(accentStyleDidChange),
            name: Tokens.accentStyleDidChangeNotification,
            object: nil)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Non-interactive: clicks fall through to the cards/rows beneath.
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// A (re)mount renders settled: the baseline resets so the first draw in a
    /// window can never read as a transition, and an in-flight pulse from the
    /// previous mount dies with it.
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        settleBaseline()
        // The popover REUSES this view across open/close — no remount, so this
        // method never re-fires on a reopen. Watch the window's own visibility
        // instead: ordering out (popover close) settles the baseline, so the
        // first draw after a reopen can never diff against a stale pre-close
        // plan and fire a pulse that follows nothing (spec §6).
        NotificationCenter.default.removeObserver(
            self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowOcclusionStateDidChange),
                name: NSWindow.didChangeOcclusionStateNotification,
                object: window)
        }
    }

    @objc private func windowOcclusionStateDidChange(_ note: Notification) {
        guard let window = note.object as? NSWindow,
              !window.occlusionState.contains(.visible) else { return }
        settleBaseline()
    }

    /// Forget the transition baseline and kill anything mid-flight: the next
    /// draw stamps a fresh baseline WITHOUT firing.
    private func settleBaseline() {
        lastEnergy = nil
        lastMemberYs = []
        cancelConnectPulse()
    }

    /// Reduce Motion turning ON strips an in-flight pulse so the wire lands on
    /// its settled state instantly instead of finishing a transition the user
    /// asked not to see.
    @objc private func accessibilityDisplayOptionsDidChange() {
        if reduceMotion { cancelConnectPulse() }
    }

    /// The pulse stamps a resolved `CGColor`, which a dial change can't re-tint
    /// mid-flight — drop it, and let the settled draw re-resolve its tokens.
    @objc private func accentStyleDidChange() {
        cancelConnectPulse()
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let plan = resolvePlan() else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            drawPlan(plan)
        }
        reconcileEnergize(with: plan)
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

        // EVERY device node is a stop, top-to-bottom — the channel runs the full
        // band and treats each node alike (on-spine = straight through, off-spine
        // = detour). `RailPlan.resolve` clips these to the device section's live
        // band; here we only gather the full unclipped set.
        var stops: [RailPlan.Stop] = []
        for row in deviceRows {
            guard let node = row.railNode else { continue }
            let f = convert(row.railNodeBounds, from: row.railNodeView)
            stops.append(RailPlan.Stop(y: f.midY, node: node))
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
            dormant: dormant,
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

    /// One stroked run of the wire — the origin hook, a straight segment, or a
    /// detour arc — with the tone it wears. `drawPlan` strokes exactly these
    /// (plus the fill dots), and the connect pulse joins their geometry, so the
    /// film always travels the same wire the settled draw painted.
    struct WireRun {
        var path: NSBezierPath
        var color: NSColor
    }

    private func drawPlan(_ plan: RailPlan) {
        let cx = PopoverColumnGrid.railGutterCenterX
        let originColor = Self.originColor(for: plan)

        if case let .headerDot(y) = plan.origin {
            // The origin section (System Audio) is collapsed: the Main Audio ring
            // is hidden, so the rail simply BEGINS at that collapsed header with a
            // small gutter dot (behavior 2 — the origin moves up to the header).
            originColor.setFill()
            fillTerminusDot(atY: y, x: cx)
        }
        for run in wireRuns(for: plan) {
            run.color.setStroke()
            run.path.stroke()
        }
        // Collapsed / mid-collapse device section: the rail was cut short at the
        // clip floor — mark the cut with a terminus dot (behavior 1).
        if let terminusY = plan.terminusDotY {
            originColor.setFill()
            fillTerminusDot(atY: terminusY, x: cx)
        }
    }

    /// The hook/terminus tone. The Main Audio ring's connected stroke comes from
    /// the SAME resolution (`Tokens.Color.spineTone`), so the curve and the ring
    /// it lands on can never be two different colors — including mid-flight
    /// through an accent-dial change. A DORMANT rail (spec §4.7) takes one quiet
    /// tone for its whole path — hook, every segment and the terminus dot —
    /// rather than the gold/grey patchwork per-stop tones drew on a wire that is
    /// feeding nothing.
    private static func originColor(for plan: RailPlan) -> NSColor {
        plan.dormant ? Tokens.Color.tertiaryLabel : Tokens.Color.spineTone(armed: plan.gold)
    }

    /// The wire's stroked runs in path order, origin → terminus. Warm Signal
    /// v4.1 item 4 ("larger selected nodes"): the gap/arc math is keyed off each
    /// STOP's OWN node radius so the rail meets a large member node and a small
    /// detoured non-member node cleanly at their true edges.
    func wireRuns(for plan: RailPlan) -> [WireRun] {
        let lw = PopoverColumnGrid.busLineWidth
        let cx = PopoverColumnGrid.railGutterCenterX
        let originColor = Self.originColor(for: plan)
        var runs: [WireRun] = []

        if case let .ring(ringCenterY, ringCenterX, ringRadius) = plan.origin {
            // Origin hook (Warm Signal nitpicks — "rail into the ring"): the rail
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
            runs.append(WireRun(path: hook, color: originColor))
        }

        // How far the line reaches: its natural terminus is the lowest on-spine
        // node — below that, nothing. A collapsed/clipping device section
        // overrides that, running the line down to the cut dot instead (what lies
        // below is hidden, not absent).
        var currentY = plan.railTopY
        for (index, stop) in plan.stops.enumerated() {
            if plan.terminusDotY == nil {
                guard let last = plan.signalTerminusIndex, index <= last else { break }
            }
            let onSpine = Self.onSpine(stop.node)
            let stopR = MembershipBusView.nodeRadius(for: stop.node)
            // Segment tone (Warm Signal v4 §Call-1 + v4.1 items 3/4/9):
            //   • member (connected)  → the SPINE TONE (`originColor`) — gold on
            //     an armed spine, ember on an idle one. It reuses the HOOK's own
            //     resolution rather than naming `gold` again, because the hook's
            //     corner and the line leaving it are one continuous stroke: a
            //     second call site here can pick a tone the corner didn't,
            //   • connecting          → ember (the energize "coming online" sweep
            //     — the segment, not the node, carries the ember tone),
            //   • FAILED               → DIM (item 9 — the red node carries failure).
            // A DORMANT rail skips the split entirely: `originColor` is already
            // the one quiet tone, so every segment inherits it.
            let segColor: NSColor
            if plan.dormant || stop.node == .failed {
                segColor = Tokens.Color.tertiaryLabel
            } else if stop.node == .member {
                segColor = originColor
            } else {
                segColor = Tokens.Color.ember
            }

            if onSpine {
                // The rail runs THROUGH the node with a breathing gap above.
                let gap = stopR + PopoverColumnGrid.busNodeRailGap
                appendVertical(from: currentY, to: stop.y + gap, x: cx,
                               lineWidth: lw, color: segColor, into: &runs)
                // The natural terminus ends the signal — UNLESS a collapsed/
                // clipping device section cuts it first (`terminusDotY != nil`), in
                // which case the line continues down to that cut and dots there.
                if index == plan.signalTerminusIndex && plan.terminusDotY == nil { return runs }
                currentY = stop.y - gap
            } else {
                // Detour ARC around a bypassed non-member node — keyed off that
                // node's OWN radius, so the bow clears a large node and a small
                // one by the same margin.
                let arcR = stopR + PopoverColumnGrid.busDetourBulge
                appendVertical(from: currentY, to: stop.y + arcR, x: cx,
                               lineWidth: lw, color: segColor, into: &runs)
                let arc = NSBezierPath()
                arc.lineWidth = lw
                arc.appendArc(withCenter: NSPoint(x: cx, y: stop.y), radius: arcR,
                              startAngle: 90, endAngle: 270, clockwise: false)
                runs.append(WireRun(path: arc, color: segColor))
                currentY = stop.y - arcR
            }
        }

        // Run the line down to the cut (the section's header, or the shrinking
        // clip floor mid-animation).
        if let terminusY = plan.terminusDotY {
            appendVertical(from: currentY, to: terminusY, x: cx,
                           lineWidth: lw, color: originColor, into: &runs)
        }
        return runs
    }

    /// Fill the small round terminus/origin gutter dot centred at `(x, y)`.
    private func fillTerminusDot(atY y: CGFloat, x: CGFloat) {
        let r = PopoverColumnGrid.railCollapsedTerminusDotDiameter / 2
        NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: r * 2, height: r * 2)).fill()
    }

    private func appendVertical(from: CGFloat, to: CGFloat, x: CGFloat, lineWidth: CGFloat,
                                color: NSColor, into runs: inout [WireRun]) {
        guard abs(from - to) > 0.01 else { return }
        let line = NSBezierPath()
        line.lineWidth = lineWidth
        line.lineCapStyle = .round
        line.move(to: NSPoint(x: x, y: from))
        line.line(to: NSPoint(x: x, y: to))
        runs.append(WireRun(path: line, color: color))
    }

    /// Whether a node sits ON the spine (rail runs through it) vs OFF it (the
    /// line detours around it). Members and members-in-transition are on-spine;
    /// genuine non-members and the blocked local node are detoured.
    static func onSpine(_ node: MembershipBusView.Node) -> Bool {
        switch node {
        case .member, .connecting, .failed, .origin: return true
        case .nonMember, .blocked:                   return false
        }
    }

    // MARK: Connect pulse (v4.1 item 9, reshaped)

    /// The wire's live-signal signature: whether the spine is carrying gold at
    /// all, and how many member segments it reaches. A dormant wire (spec §4.7)
    /// carries nothing, whatever its stops say.
    struct EnergySignature: Equatable {
        var gold: Bool
        var memberStops: Int
    }

    static func energizeSignature(of plan: RailPlan) -> EnergySignature {
        EnergySignature(
            gold: plan.gold && !plan.dormant,
            memberStops: plan.dormant ? 0 : plan.stops.filter { $0.node == .member }.count)
    }

    /// Pure firing decision: a pulse plays only when a LIVE wire GAINS reach —
    /// the spine arms, or a new member segment goes gold on an armed spine.
    /// Never on the first draw (`previous == nil`), never on an idle/dormant
    /// wire, never on loss (a room leaving is not a surge).
    static func connectPulseFires(previous: EnergySignature?, current: EnergySignature) -> Bool {
        guard let previous, current.gold else { return false }
        return !previous.gold || current.memberStops > previous.memberStops
    }

    private var reduceMotion: Bool {
        test_reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Compare this draw's plan against the last one and fire the pulse on a
    /// qualifying gain. The layer mutation is deferred out of the draw pass.
    private func reconcileEnergize(with plan: RailPlan) {
        // A draw nobody can see is never a baseline. An off-screen panel still
        // lays out and DRAWS: the reopen ritual rebuilds the whole row tree and
        // then resizes the window with `display:` while it is still ordered out
        // (`AppSurfaceController.mount` → `applyWindowContentSize`), so this ran
        // against a wire whose rows had not been laid out yet. Stamping THAT
        // left the first on-screen draw diffing against a wire that was never on
        // glass, and firing a pulse for the open itself. Settling instead makes
        // the first VISIBLE draw the baseline, so no intra-open diff can fire
        // (spec §6).
        guard windowIsVisible else { settleBaseline(); return }
        let signature = Self.energizeSignature(of: plan)
        let fires = Self.connectPulseFires(previous: lastEnergy, current: signature)
        let previousMemberYs = lastMemberYs
        lastEnergy = signature
        lastMemberYs = plan.dormant ? [] : plan.stops.filter { $0.node == .member }.map(\.y)
        guard fires, !reduceMotion else { return }
        let joined = NSBezierPath()
        for run in wireRuns(for: plan) { joined.append(run.path) }
        guard !joined.isEmpty else { return }
        // The pulse departs FROM THE ROOM THAT JUST JOINED (the member stop
        // with no counterpart in the previous draw — 2 pt tolerance absorbs
        // AppKit's per-run rounding). Arming has no new room — every member
        // goes live at once — so the pulse runs the whole wire from its
        // terminus. Lowest new room wins if several land in one draw.
        let newYs = lastMemberYs.filter { y in
            !previousMemberYs.contains { abs($0 - y) < 2 }
        }
        let departure = newYs
            .compactMap { Self.fraction(atY: $0, along: joined) }
            .max() ?? 1
        let path = joined.cgPath
        // Where the bead lands: the wire's own start — the Main Audio ring
        // (which blooms itself), or the collapsed-origin header dot.
        let arrival: Arrival
        switch plan.origin {
        case .ring:
            arrival = .ring
        case let .headerDot(y):
            arrival = .headerDot(NSPoint(x: PopoverColumnGrid.railGutterCenterX, y: y))
        }
        // A run-loop block, not `DispatchQueue.main.async`: it defers the layer
        // mutation out of the draw pass just the same, and a nested run-loop
        // spin (tests) can execute it, which the main dispatch queue's
        // non-reentrancy forbids.
        // The bead is a fixed LENGTH of light; convert it to this wire's
        // stroke-fraction space (capped so a very short wire still shows wire
        // around the bead).
        let window = min(Self.beadLength / max(Self.length(of: joined), 1), 0.45)
        RunLoop.main.perform { [weak self] in
            self?.runConnectPulse(along: path, from: departure, window: window, arrivingAt: arrival)
        }
    }

    /// Total flattened length of `path` in points (0 for an empty path).
    static func length(of path: NSBezierPath) -> CGFloat {
        let flat = path.flattened
        var points = [NSPoint](repeating: .zero, count: 3)
        var current: NSPoint?
        var total: CGFloat = 0
        for index in 0..<flat.elementCount {
            switch flat.element(at: index, associatedPoints: &points) {
            case .moveTo:
                current = points[0]
            case .lineTo:
                if let from = current {
                    total += hypot(points[0].x - from.x, points[0].y - from.y)
                }
                current = points[0]
            default:
                break
            }
        }
        return total
    }

    /// Where `targetY` sits along `path`, as a fraction of its total flattened
    /// length (0 = path start / origin, 1 = end / terminus). The wire's y is
    /// weakly decreasing along its whole run (hook, segments, detour arcs), so
    /// the first flattened segment that crosses `targetY` is THE crossing.
    /// `nil` when the path has no length.
    static func fraction(atY targetY: CGFloat, along path: NSBezierPath) -> CGFloat? {
        let flat = path.flattened
        var points = [NSPoint](repeating: .zero, count: 3)
        var current: NSPoint?
        var total: CGFloat = 0
        var crossing: CGFloat?
        for index in 0..<flat.elementCount {
            switch flat.element(at: index, associatedPoints: &points) {
            case .moveTo:
                current = points[0]
            case .lineTo:
                guard let from = current else { break }
                let to = points[0]
                let length = hypot(to.x - from.x, to.y - from.y)
                if crossing == nil, length > 0, to.y <= targetY {
                    let within = from.y > to.y
                        ? min(max((from.y - targetY) / (from.y - to.y), 0), 1)
                        : 1
                    crossing = total + length * within
                }
                total += length
                current = to
            default:
                // `flattened` emits moveTo/lineTo only; anything else has no
                // length to add.
                break
            }
        }
        guard total > 0 else { return nil }
        return min(max((crossing ?? total) / total, 0), 1)
    }

    /// Mount the glowing bead over the settled wire and play its travel from
    /// `departure` (the joining room's spot on the wire; 1 = terminus) up into
    /// the Main Audio ring, where an arrival bloom receives it.
    ///
    /// The bead has BODY (Alec's live read of the flat cut: "too subtle and
    /// invisible"): it strokes WIDER than the wire with a soft same-hue light
    /// emission, so it reads as a bead of signal riding ON the line rather
    /// than a recolored stretch of it — visibility comes from geometry and
    /// light, not from shouting with a hotter color. Travel time scales with
    /// the distance (constant speed — `railConnectPulseDuration` is the
    /// full-wire time), floored so a short hop still reads as motion.
    ///
    /// The bead's MODEL is fully absorbed (`strokeStart = strokeEnd = 0`,
    /// invisible) — only the presentation animates — so a `cacheDisplay` at any
    /// instant captures the settled wire, never the transient. Self-removing on
    /// completion: nothing runs, or exists, at rest. A fresh surge replaces an
    /// in-flight one (the newest room restarts the pulse from its own spot).
    /// Who receives the landed bead. The Main Audio ring owns its own
    /// acknowledgment (`RailHookProviding.receiveRailPulse`) — the bloom belongs
    /// to the ring, not to a disc floating at the contact point. Only the
    /// collapsed-origin case, where the wire ends at a bare gutter dot with no
    /// ring to bloom, still needs the overlay's local disc.
    enum Arrival {
        case ring
        case headerDot(NSPoint)
    }

    func runConnectPulse(along path: CGPath, from departure: CGFloat, window: CGFloat, arrivingAt arrival: Arrival) {
        guard window != nil, !reduceMotion, let hostLayer = layer else { return }
        test_lastPulseDeparture = departure
        cancelConnectPulse()
        let bead = CAShapeLayer()
        bead.frame = hostLayer.bounds
        bead.path = path
        bead.fillColor = nil
        // Wider than the wire + a soft zero-offset halo: light emission, the
        // physics of a bright bead, not a depth shadow.
        bead.lineWidth = PopoverColumnGrid.busLineWidth * 2
        bead.lineCap = .round
        bead.lineJoin = .round
        bead.shadowOffset = .zero
        bead.shadowRadius = 4
        bead.shadowOpacity = 0.85
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let glow = Tokens.Color.glow.cgColor
            bead.strokeColor = glow
            bead.shadowColor = glow
        }
        bead.strokeStart = 0
        bead.strokeEnd = 0
        hostLayer.addSublayer(bead)
        pulseLayer = bead

        // A self-contained bubble (Alec's brief): the window keeps its FULL
        // length for the entire climb — both edges slide by the same delta on
        // one clock — landing ON the hook curve, then fading out as it slips
        // into the ring. (The first cut shrank the window across the whole
        // flight so it would hit zero size exactly at the ring — which
        // extinguished it near the top of the wire before it ever reached the
        // curve, and the bloom then read as an unprovoked explosion.)
        let clampedWindow = min(window, departure)
        let travelDelta = departure - clampedWindow
        let travelTime = max(
            PopoverColumnGrid.railConnectPulseDuration * Double(travelDelta),
            PopoverColumnGrid.railConnectPulseDuration * 0.3)
        let absorbTime = Self.beadAbsorbDuration

        let leading = CABasicAnimation(keyPath: "strokeStart")
        leading.fromValue = travelDelta
        leading.toValue = 0
        let trailing = CABasicAnimation(keyPath: "strokeEnd")
        trailing.fromValue = departure
        trailing.toValue = clampedWindow
        for edge in [leading, trailing] {
            edge.duration = travelTime
            edge.timingFunction = CAMediaTimingFunction(name: .easeIn)
            edge.fillMode = .forwards
        }
        // Absorption: once parked over the hook, the bubble dissolves into the
        // ring while the bloom answers — no pop-off to the invisible model.
        let dissolve = CABasicAnimation(keyPath: "opacity")
        dissolve.fromValue = 1
        dissolve.toValue = 0
        dissolve.beginTime = travelTime
        dissolve.duration = absorbTime
        dissolve.fillMode = .forwards
        let flight = CAAnimationGroup()
        flight.animations = [leading, trailing, dissolve]
        flight.duration = travelTime + absorbTime
        bead.add(flight, forKey: Self.pulseKey)

        // Both handoffs ride OUR run-loop clock, not `CATransaction`
        // completions: CA only delivers those under an app-driven commit loop
        // (a test process never gets one — measured), and CA completions are
        // exactly the sharp edge the CATransition-key trap already documents.
        // Each timer runs a BEAT past its CA moment — CA's own clock starts a
        // frame or two after this line, and easeIn packs the landing into the
        // last frames, so an exact-time timer beheads the arrival (live bug:
        // the bead died at the hook curve). A cancel (RM, accent dial,
        // remount, replacement) nils/replaces `pulseLayer` first, so stale
        // timers no-op.
        Timer.scheduledTimer(withTimeInterval: travelTime + 0.06, repeats: false) { [weak self, weak bead] _ in
            MainActor.assumeIsolated {
                guard let self, let bead, self.pulseLayer === bead else { return }
                self.test_pulseHandoffRuns += 1
                switch arrival {
                case .ring:
                    // The RING blooms, not the overlay: the bead melts into it.
                    // The bead's own 0.12s dissolve already covers the contact
                    // point, so no residual disc is drawn here — a second glow
                    // at the join would just re-introduce the floating dot the
                    // ring bloom replaced.
                    self.mainOutRow?.receiveRailPulse()
                case let .headerDot(point):
                    self.runHeaderDotBloom(at: point)
                }
            }
        }
        Timer.scheduledTimer(withTimeInterval: flight.duration + 0.08, repeats: false) { [weak self, weak bead] _ in
            MainActor.assumeIsolated {
                guard let self, let bead, self.pulseLayer === bead else { return }
                bead.removeFromSuperlayer()
                self.pulseLayer = nil
            }
        }
    }

    /// The COLLAPSED-ORIGIN receiving end: a soft `glow` burst at the bare
    /// gutter dot the wire starts from when the origin section is collapsed —
    /// the desk acknowledging the room. The uncollapsed case has a real ring
    /// and blooms THAT instead (`RailHookProviding.receiveRailPulse`); the dot
    /// survives here because it is only `railCollapsedTerminusDotDiameter`
    /// across — dissolving the bead onto something that small, with no stroke
    /// of its own to swell, would read as the pulse simply vanishing.
    ///
    /// Same settled-model contract as the bead: model opacity 0, only the
    /// presentation plays, self-removing.
    func runHeaderDotBloom(at point: NSPoint) {
        guard window != nil, !reduceMotion, let hostLayer = layer else { return }
        test_headerDotBloomRuns += 1
        arrivalLayer?.removeFromSuperlayer()
        let radius = Self.arrivalBloomRadius
        let bloom = CAShapeLayer()
        // Disc-sized and centred on the landing point, so the swell scales
        // around the disc's own centre — a full-panel layer would scale (and
        // so TRANSLATE the disc) around the panel's centre instead.
        bloom.frame = CGRect(x: point.x - radius * 2, y: point.y - radius * 2,
                             width: radius * 4, height: radius * 4)
        bloom.path = CGPath(
            ellipseIn: CGRect(x: radius, y: radius,
                              width: radius * 2, height: radius * 2),
            transform: nil)
        bloom.shadowOffset = .zero
        bloom.shadowRadius = radius * 0.8
        bloom.shadowOpacity = 0.7
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let glow = Tokens.Color.glow.cgColor
            bloom.fillColor = glow
            bloom.shadowColor = glow
        }
        bloom.opacity = 0
        hostLayer.addSublayer(bloom)
        arrivalLayer = bloom

        // A received light, not an explosion (Alec's read of the 1.6x burst):
        // modest swell, gentler peak.
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.65
        fade.toValue = 0
        let swell = CABasicAnimation(keyPath: "transform.scale")
        swell.fromValue = 0.6
        swell.toValue = 1.2
        let burst = CAAnimationGroup()
        burst.animations = [fade, swell]
        burst.duration = PopoverColumnGrid.railConnectPulseArrivalDuration
        burst.timingFunction = CAMediaTimingFunction(name: .easeOut)
        bloom.add(burst, forKey: Self.pulseKey)
        // Same run-loop cleanup clock as the bead (see runConnectPulse): the
        // spent bloom's model is already invisible, this only frees the layer.
        Timer.scheduledTimer(withTimeInterval: burst.duration, repeats: false) { [weak self, weak bloom] _ in
            MainActor.assumeIsolated {
                bloom?.removeFromSuperlayer()
                if let self, self.arrivalLayer === bloom { self.arrivalLayer = nil }
            }
        }
    }

    private func cancelConnectPulse() {
        pulseLayer?.removeFromSuperlayer()
        pulseLayer = nil
        arrivalLayer?.removeFromSuperlayer()
        arrivalLayer = nil
    }

    // MARK: Test-support hooks

    /// The rail geometry the overlay would draw from its CURRENT live frames —
    /// the same plan `draw` renders. Lets tests assert the collapse-reactive
    /// resolution (origin at header vs ring, the terminus dot, which stops are
    /// visible) against real laid-out frames without a graphics context.
    public func test_resolvePlan() -> RailPlan? { resolvePlan() }

    /// Reduce Motion override seam — mirrors `RouteArmedDotView`/`HaloRingView`.
    /// `nil` (the default) reads the live workspace value; tests flip it and
    /// post the real `accessibilityDisplayOptionsDidChangeNotification`.
    public var test_reduceMotionOverride: Bool?

    /// Window-visibility override seam — headless test windows are never
    /// ordered front, so `NSWindow.isVisible` would veto every pulse there.
    /// `nil` (the default) reads the live window.
    public var test_windowVisibleOverride: Bool?

    private var windowIsVisible: Bool {
        test_windowVisibleOverride ?? (window?.isVisible ?? false)
    }

    /// Where the LAST pulse departed from (fraction of the wire; 1 = terminus,
    /// smaller = a mid-wire room's own node). `nil` until a pulse has run.
    public private(set) var test_lastPulseDeparture: CGFloat?

    /// Whether the connect pulse is currently mounted mid-flight (present the
    /// instant it's added — no run loop needed to assert it fired).
    public var test_isConnectPulsing: Bool { pulseLayer != nil }

    /// Whether the collapsed-origin header-dot bloom is currently playing.
    public var test_isHeaderDotBlooming: Bool { arrivalLayer != nil }

    /// How many header-dot blooms have PLAYED — a bead landing on a COLLAPSED
    /// origin increments this; one landing on the ring hands off to the ring
    /// instead, and a cancelled one never lands at all. Counts survive the
    /// bloom's own (fast, headless-timing-dependent) self-removal, so tests
    /// assert on this rather than racing the transient layer.
    public private(set) var test_headerDotBloomRuns = 0

    /// How many bead→bloom handoffs have FIRED (the travel-end timer found its
    /// bead still current) — a cancelled bead never hands off.
    public var test_pulseHandoffRuns = 0

    /// The header-dot bloom's MODEL opacity — the settled-model-layer contract
    /// says it is always 0 (invisible) while the presentation plays.
    public var test_headerDotBloomModelOpacity: Float? { arrivalLayer?.opacity }

    /// The pulse's MODEL stroke window — the settled-model-layer contract says
    /// it is always (0, 0) (fully absorbed / invisible) while the presentation
    /// plays.
    public var test_pulseModelStrokeWindow: (start: CGFloat, end: CGFloat)? {
        pulseLayer.map { ($0.strokeStart, $0.strokeEnd) }
    }

    /// The pulse's PRESENTATION stroke-end — what is actually on glass. `nil`
    /// until the render server has committed a presentation tree (headless
    /// runners never do).
    public var test_pulsePresentationStrokeEnd: CGFloat? {
        pulseLayer?.presentation()?.strokeEnd
    }

    /// Run the energize reconcile a qualifying draw would, against the current
    /// live plan (so tests can drive transitions without a graphics context).
    public func test_reconcileEnergize() {
        guard let plan = resolvePlan() else { return }
        reconcileEnergize(with: plan)
    }
}

/// The drawable rail plan — resolved purely from geometry already converted into
/// the overlay's coordinate space (no view lookups), so it is deterministic and
/// unit-testable at any intermediate collapse height. `draw` renders exactly this.
public struct RailPlan: Equatable {
    /// One device node the rail passes through / detours around. EVERY device
    /// row in the band is a stop — the rail has no third "bare node" rendering.
    public struct Stop: Equatable {
        public var y: CGFloat
        public var node: MembershipBusView.Node

        public init(y: CGFloat, node: MembershipBusView.Node) {
            self.y = y
            self.node = node
        }
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
    /// Index into `stops` of the line's natural terminus — the lowest on-spine
    /// node, the last place the wire reaches. `nil` when no on-spine node is
    /// visible, i.e. no line is drawn through the band at all.
    public var signalTerminusIndex: Int?
    /// The dormant-divergent condition (spec §4.7), resolved ONCE for the whole
    /// rail so the wire takes one tone end to end instead of a per-stop patchwork.
    public var dormant: Bool
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
        /// The host-resolved dormant-divergent condition (spec §4.7).
        public var dormant: Bool
        /// Every device stop, unclipped, sorted top-to-bottom (highest y first).
        public var stops: [Stop]

        public init(gold: Bool, ringCenterY: CGFloat, ringCenterX: CGFloat, ringRadius: CGFloat,
                    landingDrop: CGFloat, originSectionCollapsed: Bool,
                    originClipBand: ClosedRange<CGFloat>?, originHeaderY: CGFloat?,
                    deviceSectionCollapsed: Bool, deviceFloorY: CGFloat?,
                    dormant: Bool = false, stops: [Stop]) {
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
            self.dormant = dormant
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
    /// line ends where it naturally would.
    ///
    /// The line's own end is `signalTerminusIndex`, the lowest ON-SPINE node,
    /// because that is how far the audio actually reaches. A cut overrides it: the
    /// line runs down to the dot, since what lies below is hidden, not absent.
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

        let signalTerminusIndex = drawnStops.lastIndex { BusRailOverlayView.onSpine($0.node) }

        return RailPlan(origin: origin, railTopY: railTopY, stops: drawnStops,
                        terminusDotY: terminusDotY, signalTerminusIndex: signalTerminusIndex,
                        dormant: input.dormant, gold: input.gold)
    }
}

/// A device row's contribution to the continuous rail (Warm Signal v4 §Call-1):
/// its node kind, and the view + bounds whose centre the node sits on (so the
/// overlay can place the rail exactly on the row). The row states no extent —
/// the rail spans the whole band and the overlay derives both ends from the node
/// kinds and their order.
public protocol RailNodeProviding: AnyObject {
    /// The node this row renders, or `nil` if the row carries no bus node.
    var railNode: MembershipBusView.Node? { get }
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

    /// The connect pulse's bead has landed on this hook: bloom the RING ITSELF
    /// (`HaloRingView.receiveRailPulse`), so the acknowledgment visibly belongs
    /// to the thing the bead melted into rather than to a disc floating at the
    /// contact point. Reduce Motion, on-screen-ness and the settled-model
    /// contract are the ring's own business — the overlay only reports the
    /// arrival. A hook with no ring to bloom implements this as a no-op.
    func receiveRailPulse()
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
