// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

/// The **continuous membership-rail spine** (Warm Signal v4 §Call-1, the
/// owner's continuity correction): a single panel-level overlay that draws
/// the rail as ONE UNINTERRUPTED line down the left gutter, passing STRAIGHT
/// THROUGH any section-header rows, subsection headers, and hairline dividers
/// it crosses. Per-row bus segments left a gap wherever a non-device row (a
/// header or a divider) sat in the span; drawing the rail as one continuous
/// element here removes every such gap. The overlay sits ON TOP of the cards
/// + dividers (added last), so where the rail crosses a hairline it reads
/// unbroken. It is
/// non-interactive (`hitTest` returns `nil`).
///
/// **One wire, one tone.** The rail is a single stroked line — no channel, no
/// pad, nothing under it: gold, except where a host sets `unarmedLineTone` (the
/// Groups editor, `ember` for an inactive group), or one quiet tone end to end
/// while it is dormant. It runs from the origin hook
/// to its end, detouring around every off-spine node it passes on the way. Rows
/// below the end draw their node disc and no line — a FAILED room is one of
/// them, never reached. With nothing to reach there is no wire and no hook at
/// all. Where it ends is the owner's ruling of 2026-10-04 (DESIGN.md,
/// "Membership rail extent"): the lower of the lowest visible reached node and
/// the lowest collapsed header hiding a reached speaker, each such header
/// carrying a dot on its own text line, all clamped to the list's visible band.
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
/// along the rail towards the main out"):** the HOST detects the model
/// transition — a device becoming a connected member of the active Main Out
/// target (`PopoverController.update(devices:)`'s connected-member diff) — and
/// calls ``playConnectPulse(joinedDeviceIDs:cameToLife:)``. A short bright
/// `glow` window departs from the JOINING ROOM's own node (the whole wire's
/// terminus when the wire comes to life), travels up the wire at constant
/// speed, and is absorbed into the Main Audio ring: the room announcing itself
/// up the bus. The overlay only RENDERS the bead/bloom — it never infers the
/// firing from its own draws, so a layout-only change (open, rebuild,
/// collapse/expand) cannot fire it by construction. One-shot, self-removing
/// (nothing runs at rest), gone entirely under Reduce Motion.
///
/// **Determinism:** the settled wire is steady drawing computed from settled
/// frames, and the pulse follows the settled-model-layer contract
/// (`RouteArmedDotView` precedent): the pulse layer's MODEL is fully absorbed
/// (invisible) and only its presentation animates, so `cacheDisplay` snapshots
/// are byte-identical run-to-run at ANY capture instant.
public final class BusRailOverlayView: NSView {

    /// The Main Audio row supplying the origin-hook anchor (the meter's leading
    /// edge / centre-y) and whether the spine is armed (gates the connect pulse).
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
    /// The collapsed device SUBSECTIONS that each hide a speaker the rail
    /// reaches. The host decides which (`PopoverController.updateRailRows`) —
    /// a collapsed subsection hiding none is never listed. Held strongly, so a
    /// host-built adapter needs no other owner (the old `weak deviceSection`
    /// dropped one the instant nothing else retained it). Each gets a dot on
    /// its header's text line; the rail passes through every one and ends at
    /// the lowest end it has.
    public var foldedSections: [RailSectionProviding] = []
    /// The dormant-divergent condition (spec §4.7): the checked set genuinely
    /// diverges from the active group target, so nothing on this rail is
    /// actually feeding audio. The host owns the condition; when it is set the
    /// WHOLE signal path draws in one quiet tone rather than a per-row patchwork.
    /// Node fills stay per-row; this is the wire's tone alone.
    public var dormant = false
    /// The line's tone while the hook is NOT armed; `nil` keeps it `spineTone`
    /// in every state. The Mixer leaves it `nil` (its line is always gold);
    /// the Groups editor sets `ember`, so an inactive group's rail matches its
    /// ember member discs (owner's ruling, 2026-10-04).
    public var unarmedLineTone: NSColor?
    /// The section holding the whole device LIST (the "Output Speakers" card).
    /// Its clip is the scrolling viewport: the rail never draws above or below
    /// it. When the card itself collapses over a reached speaker, its header
    /// carries the end dot. A card collapse leaves its rows IN `deviceRows`
    /// (clipped by the fold), so whether it hides a reached speaker is judged
    /// from the clipped rows directly — which keeps a collapsing card from
    /// growing a tail past its lowest member into the non-member rows it is
    /// still hiding.
    public weak var deviceListSection: RailSectionProviding?

    /// The transient connect pulse currently mid-flight, if any (test-visible
    /// through ``test_isConnectPulsing``; nothing survives the pulse).
    private var pulseLayer: CAShapeLayer?
    private static let pulseKey = "busRail.connectPulse"
    /// The bead's length ON GLASS, in points — fixed, so it reads as a bead of
    /// light on any wire. (A fraction-of-the-wire window became a long STRIP
    /// on a tall wire — the owner's live read of that cut.) Capped at 45% of
    /// a very short wire so the bead never IS the wire.
    private static let beadLength: CGFloat = 26
    /// How long the landed bubble takes to dissolve into the ring.
    private static let beadAbsorbDuration: CFTimeInterval = 0.12
    /// The arrival bloom's disc radius; the swell carries it outward from
    /// there.
    private static let arrivalBloomRadius: CGFloat = 5
    /// The transient header-dot bloom currently playing at a COLLAPSED origin,
    /// if any (mounted by the bead's completion; dies with any cancel). An
    /// uncollapsed origin has a real ring, which blooms itself.
    private var arrivalLayer: CAShapeLayer?

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
        // Not input-driven: the geometry is identical, the TONES are not. Drop
        // the memo so the skip below can't swallow this invalidation.
        lastDrawnInput = nil
        needsDisplay = true
    }

    /// A remount kills an in-flight pulse from the previous mount (the
    /// `HaloRingView` contract's remount-cancel sibling).
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        cancelConnectPulse()
    }

    /// A bead's path and layer frame are captured at mount, so a resize slides
    /// the settled wire out from under it — drop the bead rather than let it fly
    /// a stale path (the RM / accent-dial cancels' sibling).
    public override func setFrameSize(_ newSize: NSSize) {
        let sizeChanged = newSize != frame.size
        super.setFrameSize(newSize)
        if sizeChanged, pulseLayer != nil || arrivalLayer != nil { cancelConnectPulse() }
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
        // Same as the appearance change: unchanged geometry, new tones.
        lastDrawnInput = nil
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let input = gatherInput() else { return }
        lastDrawnInput = input
        effectiveAppearance.performAsCurrentDrawingAppearance {
            drawPlan(RailPlan.resolve(input))
        }
    }

    /// The input the currently-committed contents were drawn from.
    private var lastDrawnInput: RailPlan.Input?

    /// How many invalidations actually reached AppKit — every one the skip below
    /// drops is a whole wire not re-resolved and not re-stroked. This is the
    /// observable, rather than reading `needsDisplay` back, because this view is
    /// layer-backed and a layer-backed view's dirty flag cannot be cleared once
    /// set (verified in this suite), so the flag can never show a skip.
    public private(set) var test_redrawRequestCount = 0

    public override var needsDisplay: Bool {
        get { super.needsDisplay }
        set {
            // A layout pass that moved nothing must not re-resolve and re-stroke
            // the whole wire. `RailPlan.resolve` is pure, so an input equal to
            // the last drawn one yields an identical figure and the committed
            // contents already show it. During a collapse the input changes
            // every frame, so the documented per-frame resolve is untouched.
            //
            // Only THIS property is intercepted: AppKit's own rect-based
            // dirtying (a resize, say) bypasses it and still redraws, which errs
            // the safe way.
            if newValue, let last = lastDrawnInput, gatherInput() == last { return }
            if newValue { test_redrawRequestCount += 1 }
            super.needsDisplay = newValue
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
        gatherInput().map(RailPlan.resolve)
    }

    /// The gather half of `resolvePlan`: read the live frames, return the plain
    /// numbers. Split out so the redraw skip can compare inputs without
    /// resolving, and so `draw` gathers exactly once per pass.
    private func gatherInput() -> RailPlan.Input? {
        guard let mainOutRow, let anchor = mainOutRow.railHookAnchor(in: self) else { return nil }

        // EVERY device node is a stop, top-to-bottom — the line treats each node
        // alike (on-spine = straight through, off-spine = detour). The stops
        // are gathered unclipped; `RailPlan.resolve` clips them to the list's
        // visible band, so a speaker scrolled off either edge still counts as
        // reached. The row's own height rides along: rule 7 ends the rail on a
        // FULLY visible row.
        var stops: [RailPlan.Stop] = []
        for row in deviceRows {
            guard let node = row.railNode else { continue }
            let f = convert(row.railNodeBounds, from: row.railNodeView)
            stops.append(RailPlan.Stop(y: f.midY, node: node, halfHeight: f.height / 2))
        }
        stops.sort { $0.y > $1.y }   // non-flipped: top = higher y

        let input = RailPlan.Input(
            armed: anchor.armed,
            ringCenterY: anchor.centerY,
            ringCenterX: anchor.ringCenterX,
            ringRadius: anchor.ringRadius,
            landingDrop: PopoverColumnGrid.railRingHookLandingDrop,
            originSectionCollapsed: originSection?.railSectionCollapsed ?? false,
            originClipBand: clipBand(of: originSection),
            originHeaderY: headerTerminusY(of: originSection),
            deviceSectionCollapsed: deviceListSection?.railSectionCollapsed ?? false,
            listBand: clipBand(of: deviceListSection),
            listHeaderDotY: deviceListSection.flatMap(headerDotY(of:)),
            folds: foldedSections.compactMap(fold(of:)),
            dormant: dormant,
            unarmedLineTone: unarmedLineTone,
            stops: stops)
        return input
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

    /// A collapsible section header's frame in overlay space, or `nil` if the
    /// section has no header row yet.
    private func headerFrame(of section: RailSectionProviding?) -> NSRect? {
        guard let section, let headerView = section.railSectionHeaderView else { return nil }
        return convert(section.railSectionHeaderBounds, from: headerView)
    }

    /// A collapsible section header's rail-gutter terminus y: its centre-Y in
    /// overlay space, the header's own text line. Where the origin dot lands
    /// when the origin section is collapsed.
    private func headerTerminusY(of section: RailSectionProviding?) -> CGFloat? {
        headerFrame(of: section)?.midY
    }

    /// Where a collapsing section's dot sits: on its header's text line once the
    /// body is shut. While the body is still closing, the dot rides the same
    /// distance above the shrinking clip floor that the header's centre sits
    /// above the clip's (fixed) top edge, so it arrives on the centre exactly as
    /// the clip reaches zero height and never runs ahead of the rows still
    /// showing.
    private func headerDotY(of section: RailSectionProviding) -> CGFloat? {
        guard let mid = headerTerminusY(of: section) else { return nil }
        guard let band = clipBand(of: section) else { return mid }
        return band.lowerBound + (mid - band.upperBound)
    }

    /// A folded subsection as plain numbers: its dot and its header row's span.
    private func fold(of section: RailSectionProviding) -> RailPlan.Fold? {
        guard let header = headerFrame(of: section), let dotY = headerDotY(of: section)
        else { return nil }
        return RailPlan.Fold(dotY: dotY, headerSpan: header.minY...header.maxY)
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

        if case let .headerDot(y) = plan.origin, plan.isLive {
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
        // Every collapsed header hiding a reached speaker carries a dot on its
        // own text line; the line passes through the upper ones and ends on the
        // lowest when nothing visible sits lower.
        if plan.isLive {
            originColor.setFill()
            for y in plan.headerDotYs { fillTerminusDot(atY: y, x: cx) }
        }
    }

    /// The hook/terminus tone. The Main Audio ring's connected stroke comes from
    /// the SAME resolution (`Tokens.Color.spineTone`), so the curve and the ring
    /// it lands on can never be two different colors — including mid-flight
    /// through an accent-dial change. A DORMANT rail (spec §4.7) takes one quiet
    /// tone for its whole path — hook, every segment and the terminus dot —
    /// rather than the gold/grey patchwork per-stop tones drew on a wire that is
    /// feeding nothing. An unarmed hook takes the host's `unarmedLineTone` when
    /// it set one (the Groups editor); the Mixer sets none, so stays gold.
    private static func originColor(for plan: RailPlan) -> NSColor {
        if plan.dormant { return Tokens.Color.railDormant }
        if !plan.armed, let tone = plan.unarmedLineTone { return tone }
        return Tokens.Color.spineTone
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
        // Nothing selected, or nothing left but failed rooms: there is no rail,
        // so there is no hook either — a hook with no line under it reads as a
        // gold stub curving out of the ring into nothing.
        guard plan.isLive else { return runs }

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

        // How far the line reaches: either a stop (`signalTerminusIndex`, the
        // line ends above that node like any terminus) or a y with no node
        // there (`lineEndY`: a dotted header, or the list's edge). Below the
        // end, nothing.
        var currentY = plan.railTopY
        for (index, stop) in plan.stops.enumerated() {
            if let endY = plan.lineEndY {
                guard stop.y > endY else { break }
            } else {
                guard let last = plan.signalTerminusIndex, index <= last else { break }
            }
            let onSpine = Self.onSpine(stop.node)
            let stopR = MembershipBusView.nodeRadius(for: stop.node)
            // Segment tone (owner's ruling, 2026-10-03): the wire is ONE line
            // from the hook to the terminus, so every segment wears
            // `originColor` — the spine tone, the host's unarmed tone, or
            // `railDormant` when the whole rail is dormant.
            // A segment feeding a connecting or failed node does NOT step: the
            // speaker's state lives in its node and its glyph ring, never in
            // the line. Reusing the hook's own resolution rather than naming a
            // tone here keeps the hook's corner and the line leaving it one
            // continuous stroke.
            let segColor = originColor

            if onSpine {
                // The rail runs THROUGH the node with a breathing gap above.
                let gap = stopR + PopoverColumnGrid.busNodeRailGap
                appendVertical(from: currentY, to: stop.y + gap, x: cx,
                               lineWidth: lw, color: segColor, into: &runs)
                if index == plan.signalTerminusIndex { return runs }
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

        // Run the line down to an end that has no node: a dotted header, or the
        // list's edge.
        if let endY = plan.lineEndY, currentY > endY {
            appendVertical(from: currentY, to: endY, x: cx,
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
    /// genuine non-members are detoured.
    ///
    /// This is also `MembershipBusView`'s node-SIZE and hover rule, so it is not
    /// the test for how far the wire travels — see ``railReaches(_:)``.
    static func onSpine(_ node: MembershipBusView.Node) -> Bool {
        switch node {
        case .member, .connecting, .failed, .origin: return true
        case .nonMember:                             return false
        }
    }

    /// Whether the wire REACHES a node — the one rule for "is there a rail at
    /// all", and the only place it is written down. A stop reaches when it is a
    /// member the signal can run to; a FAILED speaker is not reached (the red
    /// node and its red gutter rim carry the failure, and the wire stops above
    /// it), and a non-member is passed by, never reached.
    ///
    /// Two readers, one rule, so the wire and the Main Audio ring can never
    /// disagree about whether the rail exists: ``RailPlan/resolve(_:)`` applies
    /// it to the stops it draws (giving `signalTerminusIndex` and
    /// ``RailPlan/isLive``), and the HOST applies it to the same rows' nodes to
    /// decide whether the ring is drawn at all (`PopoverController.updateRailRows`).
    /// Deliberately NOT ``onSpine(_:)``: that one also sizes the node discs and
    /// drives their hover, so a failed node must keep answering `true` there.
    public static func railReaches(_ node: MembershipBusView.Node) -> Bool {
        switch node {
        case .member, .connecting, .origin: return true
        case .failed, .nonMember:           return false
        }
    }

    // MARK: Connect pulse (v4.1 item 9, reshaped)

    private var reduceMotion: Bool {
        test_reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Play the connect pulse for a MODEL event the host detected: the devices
    /// in `joinedDeviceIDs` became connected members of the active Main Out
    /// target. `cameToLife` means the previous member set was empty — the whole
    /// bus lights up, so the pulse runs end to end from the terminus; otherwise
    /// it departs from the lowest joined room's own node.
    public func playConnectPulse(joinedDeviceIDs: Set<String>, cameToLife: Bool) {
        // The WHOLE body is deferred in one run-loop block — not
        // `DispatchQueue.main.async`: a run-loop block defers the geometry read
        // past the current turn's rebuild/refresh + exact-fit layout so the
        // plan resolves against settled frames, and a nested run-loop spin
        // (tests) can execute it, which the main dispatch queue's
        // non-reentrancy forbids.
        RunLoop.main.perform { [weak self] in
            guard let self,
                  self.windowIsVisible,
                  !self.reduceMotion,
                  let plan = self.resolvePlan(),
                  // A dormant wire, or one whose Main Audio is not armed
                  // (muted, or no member connected), carries nothing — no pulse.
                  plan.armed, !plan.dormant else { return }
            let joined = NSBezierPath()
            for run in self.wireRuns(for: plan) { joined.append(run.path) }
            guard !joined.isEmpty else { return }
            // Where the pulse departs. Coming to life runs the whole wire from
            // the terminus; a join on a live wire departs from its own node —
            // lowest new room wins, and an unmounted/unmapped id drops out
            // (fallback: the terminus).
            let departure: CGFloat
            if cameToLife {
                departure = 1
            } else {
                departure = joinedDeviceIDs
                    .compactMap { id -> CGFloat? in
                        guard let row = self.deviceRows.first(where: { $0.railDeviceID == id })
                        else { return nil }
                        let y = self.convert(row.railNodeBounds, from: row.railNodeView).midY
                        return Self.fraction(atY: y, along: joined)
                    }
                    .max() ?? 1
            }
            // Where the bead lands: the wire's own start — the Main Audio ring
            // (which blooms itself), or the collapsed-origin header dot.
            let arrival: Arrival
            switch plan.origin {
            case .ring:
                arrival = .ring
            case let .headerDot(y):
                arrival = .headerDot(NSPoint(x: PopoverColumnGrid.railGutterCenterX, y: y))
            }
            // The bead is a fixed LENGTH of light; convert it to this wire's
            // stroke-fraction space (capped so a very short wire still shows
            // wire around the bead).
            let strokeWindow = min(Self.beadLength / max(Self.length(of: joined), 1), 0.45)
            self.runConnectPulse(along: joined.cgPath, from: departure,
                                 strokeWindow: strokeWindow, arrivingAt: arrival)
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
    /// The bead has BODY (the owner's live read of the flat cut: "too subtle
    /// and invisible"): it strokes WIDER than the wire with a soft same-hue
    /// light emission, so it reads as a bead of signal riding ON the line
    /// rather than a recolored stretch of it — visibility comes from geometry
    /// and light, not from shouting with a hotter color. Travel time scales
    /// with the distance (constant speed — `railConnectPulseDuration` is the
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

    func runConnectPulse(along path: CGPath, from departure: CGFloat, strokeWindow: CGFloat, arrivingAt arrival: Arrival) {
        // `window` here is the VIEW's own (`self.window`) — bail if we've left
        // the window between scheduling this deferred mount and running it. The
        // guard was dead while the stroke-window arg was ALSO named `window` and
        // shadowed the property, so `window != nil` compared a CGFloat to nil.
        guard window != nil, !reduceMotion, let hostLayer = layer else { return }
        // Coalesce a burst into ONE pulse: while a bead is already travelling, a
        // further gain — the next room of a multi-room connect landing a draw or
        // two later, as a fresh build's first handshake settles room by room —
        // does NOT cancel and restart it. That cancel-and-restart WAS the stutter
        // on a fresh build's first connect: the bead running "up half the way",
        // twice, before one finally ran out. The one in flight finishes; a
        // genuinely later connect pulses fresh on its own gain, once this lands.
        guard pulseLayer == nil else { return }
        test_lastPulseDeparture = departure
        test_pulsesStarted += 1
        let bead = CAShapeLayer()
        bead.frame = hostLayer.bounds
        bead.path = path
        bead.fillColor = nil
        // Wider than the wire: a bright bead, drawn as a stroke — never a
        // shadow.
        bead.lineWidth = PopoverColumnGrid.busLineWidth * 2
        bead.lineCap = .round
        bead.lineJoin = .round
        effectiveAppearance.performAsCurrentDrawingAppearance {
            bead.strokeColor = Tokens.Color.glow.cgColor
        }
        bead.strokeStart = 0
        bead.strokeEnd = 0
        hostLayer.addSublayer(bead)
        pulseLayer = bead

        // A self-contained bubble (the owner's brief): the window keeps its FULL
        // length for the entire climb — both edges slide by the same delta on
        // one clock — landing ON the hook curve, then fading out as it slips
        // into the ring. (The first cut shrank the window across the whole
        // flight so it would hit zero size exactly at the ring — which
        // extinguished it near the top of the wire before it ever reached the
        // curve, and the bloom then read as an unprovoked explosion.)
        let clampedWindow = min(strokeWindow, departure)
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

    /// The COLLAPSED-ORIGIN receiving end: a `glow` disc that swells and fades
    /// at the bare gutter dot the wire starts from when the origin section is
    /// collapsed — a fill, never a shadow — the desk acknowledging the room.
    /// The uncollapsed case has a real ring
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
        effectiveAppearance.performAsCurrentDrawingAppearance {
            bloom.fillColor = Tokens.Color.glow.cgColor
        }
        bloom.opacity = 0
        hostLayer.addSublayer(bloom)
        arrivalLayer = bloom

        // A received light, not an explosion (the owner's read of the 1.6x
        // burst): modest swell, gentler peak.
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

    /// How many pulses have actually STARTED travelling. A burst coalesces into
    /// one — a gain arriving while a bead is in flight is skipped, not restarted
    /// — so a fresh build's staged first connect counts as 1, not one-per-room.
    public private(set) var test_pulsesStarted = 0

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
        /// Half the row's height, so `resolve` can tell a fully visible row from
        /// one the list's edge cuts through. 0 treats the row as its centre.
        public var halfHeight: CGFloat

        public init(y: CGFloat, node: MembershipBusView.Node, halfHeight: CGFloat = 0) {
            self.y = y
            self.node = node
            self.halfHeight = halfHeight
        }
    }

    /// A collapsed subsection that hides a speaker the rail reaches.
    public struct Fold: Equatable {
        /// Where its dot sits: the header's text line once the body is shut.
        public var dotY: CGFloat
        /// The header row's y-range; the dot shows only while all of it is
        /// inside the list's visible band.
        public var headerSpan: ClosedRange<CGFloat>

        public init(dotY: CGFloat, headerSpan: ClosedRange<CGFloat>) {
            self.dotY = dotY
            self.headerSpan = headerSpan
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
    /// The device stops whose centres sit inside the list's visible band,
    /// top-to-bottom. Rows below the end are here too: they draw their node
    /// and no line.
    public var stops: [Stop]
    /// Index into `stops` of the node the line ends on, when it ends on a node:
    /// the lowest node the wire REACHES (``BusRailOverlayView/railReaches(_:)``),
    /// or, when a reached speaker is scrolled below the list's edge, the lowest
    /// fully visible reached row. `nil` when the line ends at `lineEndY`.
    public var signalTerminusIndex: Int?
    /// The y the line runs down to when it ends where there is no node: the
    /// lowest dotted header, or the list's edge when no visible node can end
    /// it. `nil` when it ends on `stops[signalTerminusIndex]`.
    public var lineEndY: CGFloat?
    /// Every dot drawn on a collapsed header that hides a reached speaker —
    /// each subsection's and the Output Speakers card's — top to bottom.
    public var headerDotYs: [CGFloat]
    /// The dormant-divergent condition (spec §4.7), resolved ONCE for the whole
    /// rail so the wire takes one tone end to end instead of a per-stop patchwork.
    public var dormant: Bool
    /// Whether the Main Audio spine is armed. It gates the connect pulse
    /// (`playConnectPulse`), and picks `unarmedLineTone` when the host set one.
    public var armed: Bool
    /// The host's line tone while unarmed; `nil` (the Mixer) keeps it gold.
    public var unarmedLineTone: NSColor?

    /// The rail's end when it lands on a dotted header; `nil` when it ends on a
    /// node or at the list's edge.
    public var terminusDotY: CGFloat? {
        guard let lineEndY, headerDotYs.contains(lineEndY) else { return nil }
        return lineEndY
    }

    /// Whether there is a rail at all: some listed speaker is reached, visible
    /// or folded away. Nothing is drawn when this is false — no hook out of the
    /// Main Audio ring, no origin dot, no segments. A hook with nothing under it
    /// was the whole reason the Main Audio ring had to render a resting form;
    /// the ring now follows the same rule (``BusRailOverlayView/railReaches(_:)``),
    /// so the two appear and vanish together.
    public var isLive: Bool { signalTerminusIndex != nil || lineEndY != nil }

    /// Plain-number inputs read from live frames by `BusRailOverlayView`.
    ///
    /// `Equatable` is load-bearing, not incidental: `RailPlan.resolve` is pure,
    /// so an input equal to the last drawn one resolves to the same figure and
    /// the overlay can skip the redraw entirely (`needsDisplay`'s setter).
    public struct Input: Equatable {
        public var armed: Bool
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
        /// The Output Speakers card's (target) collapsed state.
        public var deviceSectionCollapsed: Bool
        /// The device list's live visible band (the card's body clip, which is
        /// the scroll viewport). Nothing is drawn outside it. `nil` for a host
        /// with no list clip: every stop is visible.
        public var listBand: ClosedRange<CGFloat>?
        /// Where the card's dot sits while it is collapsing or collapsed.
        public var listHeaderDotY: CGFloat?
        /// Collapsed subsections that hide a reached speaker.
        public var folds: [Fold]
        /// The host-resolved dormant-divergent condition (spec §4.7).
        public var dormant: Bool
        /// ``BusRailOverlayView/unarmedLineTone``.
        public var unarmedLineTone: NSColor?
        /// Every device stop, unclipped, sorted top-to-bottom (highest y first).
        public var stops: [Stop]

        public init(armed: Bool, ringCenterY: CGFloat, ringCenterX: CGFloat, ringRadius: CGFloat,
                    landingDrop: CGFloat, originSectionCollapsed: Bool,
                    originClipBand: ClosedRange<CGFloat>?, originHeaderY: CGFloat?,
                    deviceSectionCollapsed: Bool, listBand: ClosedRange<CGFloat>?,
                    listHeaderDotY: CGFloat? = nil, folds: [Fold] = [],
                    dormant: Bool = false, unarmedLineTone: NSColor? = nil, stops: [Stop]) {
            self.armed = armed
            self.ringCenterY = ringCenterY
            self.ringCenterX = ringCenterX
            self.ringRadius = ringRadius
            self.landingDrop = landingDrop
            self.originSectionCollapsed = originSectionCollapsed
            self.originClipBand = originClipBand
            self.originHeaderY = originHeaderY
            self.deviceSectionCollapsed = deviceSectionCollapsed
            self.listBand = listBand
            self.listHeaderDotY = listHeaderDotY
            self.folds = folds
            self.dormant = dormant
            self.unarmedLineTone = unarmedLineTone
            self.stops = stops
        }
    }

    /// Rounding slack for "fully inside the band": AppKit lays rows out on a
    /// pixel grid, so an edge-to-edge row can miss the band by a fraction.
    private static let edgeTolerance: CGFloat = 0.5

    /// Resolve the plan (pure).
    ///
    /// **Origin.** If the origin section is collapsed AND the Main Audio ring has
    /// fallen outside the section's live clip band (it clipped away), the rail
    /// begins at that section's header with a dot; otherwise it curves into the
    /// ring. Keying "at header" off the live band (not just the collapsed flag)
    /// makes the origin RIDE UP with the shrinking clip rather than snap the
    /// instant the toggle flips.
    ///
    /// **End** (owner's ruling, 2026-10-04 — DESIGN.md "Membership rail
    /// extent"). Every collapsed header hiding a reached speaker gets a dot on
    /// its own text line: each folded subsection whose header is fully visible,
    /// and the Output Speakers card while it is collapsing over one. The rail
    /// ends at the lower of the lowest visible reached node and the lowest dot,
    /// passing straight through any dot above that. When a reached speaker or a
    /// folded header lies below the list's visible edge and the card is NOT
    /// collapsing, the rail ends on the lowest fully visible reached row
    /// instead — its own node is the end, no dot. Nothing is drawn outside the
    /// list's band.
    ///
    /// The card's dot needs a reached speaker actually clipped away, not just
    /// the collapsed flag: while a collapse is still only hiding the NON-member
    /// rows below the lowest member, the rail keeps ending at that member. The
    /// flag is set for the WHOLE animation, so keying the dot off it grew a line
    /// down through those non-members to the shrinking floor — "the rail
    /// expanding into areas where it wasn't before" on a section toggle.
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

        let band = input.listBand
        let tolerance = edgeTolerance
        // Stops whose centre is inside the band are drawn; a row scrolled off
        // the top has its node disc hidden behind the clip, so its detour arc
        // would land on the fixed card header above the list.
        let stops = input.stops.filter { stop in
            guard let band else { return true }
            return stop.y <= band.upperBound && stop.y > band.lowerBound
        }
        func fullyVisible(_ stop: Stop) -> Bool {
            guard let band else { return true }
            return stop.y - stop.halfHeight >= band.lowerBound - tolerance
                && stop.y + stop.halfHeight <= band.upperBound + tolerance
        }
        // Something reached lies below the list's visible bottom edge. A
        // collapsing card hides a row once its centre passes the floor (the
        // complement of the `stops` filter); a scrolled list counts a row the
        // edge cuts.
        let reachedBelowEdge: Bool = {
            guard let band else { return false }
            return input.stops.contains {
                BusRailOverlayView.railReaches($0.node)
                    && (input.deviceSectionCollapsed
                        ? $0.y <= band.lowerBound
                        : $0.y - $0.halfHeight < band.lowerBound - tolerance)
            } || input.folds.contains { $0.headerSpan.lowerBound < band.lowerBound - tolerance }
        }()
        // Something reached lies above the list's visible top edge, scrolled up
        // out of view. A collapsing card hides it as surely as one below.
        let reachedAboveEdge: Bool = {
            guard let band else { return false }
            return input.stops.contains {
                BusRailOverlayView.railReaches($0.node)
                    && $0.y + $0.halfHeight > band.upperBound + tolerance
            } || input.folds.contains { $0.headerSpan.upperBound > band.upperBound + tolerance }
        }()
        let anyReached = !input.folds.isEmpty
            || input.stops.contains { BusRailOverlayView.railReaches($0.node) }

        var dots = input.folds.filter { fold in
            guard let band else { return true }
            return fold.headerSpan.lowerBound >= band.lowerBound - tolerance
                && fold.headerSpan.upperBound <= band.upperBound + tolerance
        }.map(\.dotY)
        let cardCollapsing = input.deviceSectionCollapsed && (reachedBelowEdge || reachedAboveEdge)
        if cardCollapsing, let cardDot = input.listHeaderDotY {
            dots.append(cardDot)
        }
        dots.sort(by: >)

        // Which nodes may end the rail. Scrolled (not collapsing) with a reached
        // speaker below the edge: the lowest fully visible reached row, since
        // the line runs on past the edge. Otherwise the lowest visible reached
        // node — visible meaning its centre is in the band, as every entry of
        // `stops` already is, so a reached row the top edge cuts through still
        // gets its line.
        let scrolledPast = reachedBelowEdge && !cardCollapsing
        let endStop = stops.lastIndex { stop in
            scrolledPast
                ? fullyVisible(stop) && BusRailOverlayView.railReaches(stop.node)
                : BusRailOverlayView.railReaches(stop.node)
        }

        var signalTerminusIndex: Int?
        var lineEndY: CGFloat?
        if let lowestDot = dots.last, endStop.map({ stops[$0].y > lowestDot }) ?? true {
            lineEndY = lowestDot
        } else if let endStop {
            signalTerminusIndex = endStop
        } else if anyReached, let band {
            // Reached speakers exist but none is visible and no dot shows: run
            // to the edge they lie past, with no dot.
            lineEndY = scrolledPast ? band.lowerBound : band.upperBound
        }
        // Never let the end ride ABOVE where the rail started (a degenerate
        // fully-collapsed panel).
        lineEndY = lineEndY.map { min($0, railTopY) }

        return RailPlan(origin: origin, railTopY: railTopY, stops: stops,
                        signalTerminusIndex: signalTerminusIndex, lineEndY: lineEndY,
                        headerDotYs: dots.map { min($0, railTopY) },
                        dormant: input.dormant, armed: input.armed,
                        unarmedLineTone: input.unarmedLineTone)
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
    /// The device id the host uses to map a joined device to its stop for the
    /// connect pulse's departure; `nil` for a row that represents no device.
    var railDeviceID: String? { get }
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
    /// coordinates) plus its radius, and whether the spine is armed (gates the
    /// connect pulse, and the line's `unarmedLineTone` when the host set one). `nil` if the anchor
    /// can't be resolved (no window / not laid out). The overlay curves the rail from the gutter column up to this
    /// ring's left edge (`ringCenterX - ringRadius`, `centerY`).
    func railHookAnchor(in view: NSView) -> (centerY: CGFloat, ringCenterX: CGFloat, ringRadius: CGFloat, armed: Bool)?

    /// The connect pulse's bead has landed on this hook: bloom the RING ITSELF
    /// (`HaloRingView.receiveRailPulse`), so the acknowledgment visibly belongs
    /// to the thing the bead melted into rather than to a disc floating at the
    /// contact point. Reduce Motion, on-screen-ness and the settled-model
    /// contract are the ring's own business — the overlay only reports the
    /// arrival. A hook with no ring to bloom implements this as a no-op.
    func receiveRailPulse()
}

/// A collapsible section the rail passes through (the origin's "System Audio"
/// card, the device rows' "Output Speakers" card, or a device subsection), so
/// `BusRailOverlayView` can react to its collapse (collapse-reactive rail,
/// 2026-07-22):
///
/// - `railSectionCollapsed` — the section's target collapsed state.
/// - the HEADER row (always visible) supplies the dot anchor: its vertical
///   centre, the header's own text line.
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
