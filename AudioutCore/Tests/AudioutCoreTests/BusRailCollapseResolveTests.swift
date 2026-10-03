// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import Testing
@testable import AudioutSharedUI

/// Pure-geometry coverage for the **collapse-reactive rail** (`RailPlan.resolve`,
/// 2026-07-22). The overlay reads live view frames, converts them to overlay
/// space, and hands the plain numbers to `RailPlan.resolve`; asserting that pure
/// function directly lets us pin the four contracted behaviors deterministically
/// at ANY intermediate collapse height, with no view tree and no graphics context:
///
///   1. a collapsed header hiding a reached speaker carries a dot, and the rail
///      ends at the lower of that dot and the lowest visible reached node
///      (owner's ruling, 2026-10-04 — DESIGN.md "Membership rail extent"),
///   2. WHICH section collapses changes the shape (origin moves up vs end up),
///   3. the shape tracks the LIVE clip floor frame-by-frame (the in-sync squeeze),
///   4. re-expanding restores the exact prior geometry (resolve is a pure function
///      of its input — same input, same plan).
///
/// Coordinates are non-flipped (y-up): higher y = nearer the top of the panel, so
/// the origin (Main Audio) sits at a HIGHER y than the device stops below it.
@MainActor
@Suite final class BusRailCollapseResolveTests: IsolatedSuite {

    // A three-device band: two through-members, a member, then a NON-member below
    // them — all under the Main Audio ring. The list's visible band holds every
    // node.
    private func expandedInput() -> RailPlan.Input {
        RailPlan.Input(
            armed: true,
            ringCenterY: 500, ringCenterX: 20, ringRadius: 15, landingDrop: 16,
            originSectionCollapsed: false,
            originClipBand: 460...540,      // ring (500) sits inside → ring visible
            originHeaderY: 560,
            deviceSectionCollapsed: false,
            listBand: 260...440,            // holds every stop → no clip
            listHeaderDotY: 452,            // the card header's text line
            stops: [
                .init(y: 420, node: .member),
                .init(y: 380, node: .member),
                .init(y: 340, node: .member),      // the signal's natural terminus
                .init(y: 300, node: .nonMember),   // channel continues; signal does not
            ])
    }

    // MARK: Behavior 1 — collapsed device section terminates at its header dot

    @Test func expandedRailEndsAtLowestNodeNoTerminusDot() {
        let plan = RailPlan.resolve(expandedInput())
        #expect(plan.origin == .ring(centerY: 500, ringCenterX: 20, ringRadius: 15),
                       "expanded origin curves into the Main Audio ring")
        #expect(plan.stops.count == 4, "every node in the band is drawn when expanded")
        #expect(plan.terminusDotY == nil,
                     "expanded: the rail ends naturally at its lowest node — no cut dot")
    }

    // MARK: Where the line ends

    @Test func theLineEndsAtTheLowestMemberNotTheLowestNode() {
        let plan = RailPlan.resolve(expandedInput())
        #expect(plan.signalTerminusIndex == 2,
                "the wire stops at the lowest MEMBER; the non-member below it draws a node only")
        #expect(plan.stops.count == 4,
                "every device is still a stop — extent is the plan's call, not the row's")
    }

    @Test func aBandWithNoMembersDrawsNoLineAtAll() {
        var input = expandedInput()
        input.stops = input.stops.map { .init(y: $0.y, node: .nonMember) }
        let plan = RailPlan.resolve(input)
        #expect(plan.signalTerminusIndex == nil, "no member ⇒ no wire to draw")
        #expect(plan.stops.count == 4, "…but every node is still there to click")
        #expect(!plan.isLive, "no member ⇒ no rail at all")
        // The hook used to be drawn whenever the Main Audio card was expanded,
        // leaving a gold stub curving out of the ring with nothing under it.
        #expect(BusRailOverlayView().wireRuns(for: plan).isEmpty,
                "nothing to reach ⇒ not even the origin hook is stroked")
    }

    /// Same emptiness with the origin at a COLLAPSED section's header: the small
    /// gutter dot is the hook's stand-in, so it goes when the hook does.
    @Test func aCollapsedOriginWithNoMembersDrawsNoDotEither() {
        var input = expandedInput()
        input.stops = input.stops.map { .init(y: $0.y, node: .nonMember) }
        input.originSectionCollapsed = true
        input.originClipBand = 558...560          // ring clipped away → header dot
        let plan = RailPlan.resolve(input)
        #expect(plan.origin == .headerDot(y: 560), "the fixture must be the header-dot origin")
        #expect(!plan.isLive, "no member ⇒ no rail, whichever end it would start from")
        #expect(BusRailOverlayView().wireRuns(for: plan).isEmpty,
                "a header-dot origin with nothing under it draws no line")
    }

    /// A FAILED room is not reached: the wire stops at the member above it, and
    /// the failed row gets no run of its own. Its red node and red gutter rim
    /// are what state the failure — a line running down to it said the signal
    /// arrives there, which is the one thing that is not happening.
    @Test func theWireStopsAboveAFailedRoom() {
        let plan = RailPlan.resolve(toneInput(armed: true, nodes: [.member, .failed]))
        #expect(plan.signalTerminusIndex == 0, "the lowest room the wire REACHES is the member")
        let runs = BusRailOverlayView().wireRuns(for: plan)
        #expect(runs.count == 2, "hook + the one segment into the member; nothing below it")
        // The failed stop sits at y = 380; no run may be stroked down to it.
        let lowest = runs.flatMap { run -> [CGFloat] in
            (0..<run.path.elementCount).map { i -> CGFloat in
                var points = [NSPoint](repeating: .zero, count: 3)
                run.path.element(at: i, associatedPoints: &points)
                return points[0].y
            }
        }.min() ?? .greatestFiniteMagnitude
        #expect(lowest > 390, "no ink reaches the failed row's node at y = 380")
    }

    /// A band whose ONLY on-spine room has failed has no rail at all — the
    /// failed node keeps its own red rim, and nothing curves out of Main Audio.
    @Test func aBandOfNothingButAFailedRoomHasNoRail() {
        let plan = RailPlan.resolve(toneInput(armed: true, nodes: [.nonMember, .failed]))
        #expect(plan.signalTerminusIndex == nil, "a failed room is never the wire's terminus")
        #expect(BusRailOverlayView().wireRuns(for: plan).isEmpty, "nothing reached ⇒ no rail")
    }

    // MARK: Dormancy is ONE flag for the whole path

    @Test func dormancyIsCarriedOnceForTheWholeRail() {
        var input = expandedInput()
        input.dormant = true
        let plan = RailPlan.resolve(input)
        #expect(plan.dormant, "the §4.7 condition rides the plan, not the individual stops")
        #expect(RailPlan.resolve(expandedInput()).dormant == false)
        #expect(plan.stops == RailPlan.resolve(expandedInput()).stops,
                "dormancy changes the ink, never the geometry")
    }

    @Test func collapsedDeviceCardEndsOnItsHeaderDotAndDropsAllNodes() throws {
        var input = expandedInput()
        // Card body collapsed: clip height 0 at y = 444, under a header whose
        // text line is y = 452.
        input.deviceSectionCollapsed = true
        input.listBand = 444...444
        let plan = RailPlan.resolve(input)

        #expect(plan.stops.count == 0,
                       "a collapsed device card draws NONE of its now-hidden nodes")
        let terminusDotY = try #require(plan.terminusDotY)
        #expect(abs(terminusDotY - 452) <= 0.001,
                       "the rail ends on a dot on the card header's text line")
        #expect(plan.origin == .ring(centerY: 500, ringCenterX: 20, ringRadius: 15),
                       "the ORIGIN is untouched — only the far end collapsed (behavior 2 contrast)")
    }

    // MARK: Behavior 2 — the origin moves up when the ORIGIN section collapses

    @Test func collapsedOriginSectionMovesOriginToHeaderDot() {
        var input = expandedInput()
        // Origin (System Audio) body collapsed: clip shrank past the ring, so the
        // ring is no longer inside the band → origin snaps to the header dot.
        input.originSectionCollapsed = true
        input.originClipBand = 558...560          // ring (500) now BELOW the band
        let plan = RailPlan.resolve(input)

        #expect(plan.origin == .headerDot(y: 560),
                       "a collapsed origin section begins the rail at its own header dot")
        #expect(abs(plan.railTopY - 560) <= 0.001,
                       "the vertical rail now starts at the header, not the ring landing")
        #expect(plan.stops.count == 4,
                       "the device section is still expanded, so all its nodes still draw")
        #expect(plan.lineEndY == nil, "device end unaffected by the origin collapsing")
    }

    @Test func originStillRidesTheRingWhileItRemainsInsideTheShrinkingBand() {
        var input = expandedInput()
        // Mid-collapse of the origin section: the flag is already set, but the clip
        // band still contains the ring — the origin must NOT snap early (behavior 3).
        input.originSectionCollapsed = true
        input.originClipBand = 470...520          // ring (500) still inside
        let plan = RailPlan.resolve(input)
        #expect(plan.origin == .ring(centerY: 500, ringCenterX: 20, ringRadius: 15),
                       "while the ring is still within the clip band the origin stays on the ring")
    }

    // MARK: Behavior 3 — the end tracks the live clip floor frame-by-frame

    /// The card collapsing: the overlay hands in the card dot riding a fixed
    /// distance above the shrinking floor (`headerDotY(of:)`), here 8 pt.
    private func collapsing(floor: CGFloat) -> RailPlan.Input {
        var input = expandedInput()
        input.deviceSectionCollapsed = true
        input.listBand = floor...max(floor, 440)
        input.listHeaderDotY = floor + 8
        return input
    }

    @Test func theEndSqueezesContinuouslyWithTheClipHeight() throws {
        // Sweep the card's clip floor UP through the node ys; the drawn stops
        // and the dot must track it monotonically — proof the rail squeezes in
        // sync with the live (animating) clip, not a before/after snap.
        var plan = RailPlan.resolve(collapsing(floor: 360))
        #expect(plan.stops.map(\.y) == [420, 380], "floor at 360 clips the lower two nodes")
        #expect(plan.terminusDotY == 368, "the hidden member puts the card dot 8 pt above the floor")

        plan = RailPlan.resolve(collapsing(floor: 400))
        #expect(plan.stops.map(\.y) == [420], "floor at 400 clips the lower three nodes")
        #expect(plan.terminusDotY == 408)

        plan = RailPlan.resolve(collapsing(floor: 432))
        #expect(plan.stops.isEmpty, "floor above all nodes clips them all")
        #expect(plan.terminusDotY == 440, "the dot follows the floor exactly as it rises")
    }

    // MARK: The card's dot represents hidden SIGNAL, not any hidden row

    @Test func clippingOnlyANonMemberEndsAtTheMemberWithNoTail() throws {
        // THE SECTION-TOGGLE BUG (live repro 2026-08-22). As a section collapses,
        // the clip floor rises through the NON-member rows sitting below the lowest
        // member FIRST. Hiding a non-member hides no signal, so the rail must still
        // end at the lowest member — not grow a tail down to the floor through
        // the non-member area ("the rail expanding into areas where it wasn't
        // before" on a rapid toggle). Only a hidden MEMBER dots the card.
        // Floor between the non-member (300) and lowest member (340).
        let plan = RailPlan.resolve(collapsing(floor: 320))
        #expect(plan.stops.map(\.y) == [420, 380, 340],
                "the non-member below the floor is clipped; every member stays drawn")
        #expect(plan.signalTerminusIndex == 2, "the wire still ends at the lowest member")
        #expect(plan.lineEndY == nil && plan.headerDotYs.isEmpty,
                "no member is hidden ⇒ no dot: the rail ends at the member, no tail down to the floor")
    }

    @Test func clippingTheLowestMemberRunsTheRailToTheCardDot() throws {
        // The mirror of the above: once the floor rises past the lowest MEMBER, a
        // real signal IS hidden below the fold, so the card's dot returns.
        let plan = RailPlan.resolve(collapsing(floor: 350))   // above the lowest member (340)
        #expect(plan.stops.map(\.y) == [420, 380], "the lowest member is now clipped")
        #expect(plan.terminusDotY == 358,
                "a hidden member is hidden signal — the rail runs on to the card's dot")
    }

    // MARK: Behavior 4 — re-expand restores the exact prior geometry

    @Test func resolveIsPureSoReexpandRestoresIdenticalGeometry() {
        let before = RailPlan.resolve(expandedInput())

        // Collapse (any intermediate + fully-collapsed state) …
        _ = RailPlan.resolve(collapsing(floor: 440))

        // … then expand again with the SAME expanded input: identical plan back.
        let after = RailPlan.resolve(expandedInput())
        #expect(before == after,
                       "resolve carries no hidden state — re-expanding restores the exact rail")
    }

    // MARK: Guard — a degenerate collapse never puts the dot above the rail start

    @Test func terminusDotIsClampedNotAboveRailTop() throws {
        // Pathological: device floor risen ABOVE the ring landing (panel squashed).
        let plan = RailPlan.resolve(collapsing(floor: 900))
        let terminusDotY = try #require(plan.terminusDotY)
        #expect(abs(terminusDotY - plan.railTopY) <= 0.001,
                       "the end dot is clamped to railTop so it never draws above the origin")
    }

    // MARK: Segment tone — the wire is ONE line

    /// Resolve a dynamic token under an explicit appearance, the way AppKit
    /// resolves it at draw time (token objects compare by identity, not ink).
    private func resolved(_ color: NSColor, _ appearanceName: NSAppearance.Name) -> NSColor {
        var out = color
        NSAppearance(named: appearanceName)?.performAsCurrentDrawingAppearance {
            out = color.usingColorSpace(.sRGB) ?? color
        }
        return out
    }

    private func sameInk(_ a: NSColor, _ b: NSColor) -> Bool {
        let a = resolved(a, .darkAqua), b = resolved(b, .darkAqua)
        return abs(a.redComponent - b.redComponent) <= 0.005
            && abs(a.greenComponent - b.greenComponent) <= 0.005
            && abs(a.blueComponent - b.blueComponent) <= 0.005
    }

    private func toneInput(armed: Bool, nodes: [MembershipBusView.Node]) -> RailPlan.Input {
        var input = expandedInput()
        input.armed = armed
        input.stops = zip([420, 380, 340, 300], nodes).map { .init(y: $0, node: $1) }
        return input
    }

    /// A segment that detours PAST a non-member keeps the spine's tone: the
    /// line carries the same signal past that node as it does into the member
    /// below, so nothing on the wire changes colour between hook and terminus.
    /// Armed or not, that tone is gold (owner's ruling, 2026-10-04: there is
    /// no idle line).
    @Test func detourPastNonMembersKeepsTheWireGoldArmedOrNot() {
        for armed in [true, false] {
            let plan = RailPlan.resolve(toneInput(armed: armed, nodes: [.nonMember, .nonMember, .member]))
            let runs = BusRailOverlayView().wireRuns(for: plan)
            #expect(runs.count > 1, "hook plus at least one segment")
            #expect(runs.allSatisfy { sameInk($0.color, Tokens.Color.gold) },
                    "every run is gold (armed=\(armed))")
        }
    }

    /// A speaker's state lives in its node and glyph ring, never in the line:
    /// segments feeding a connecting node and a failed node wear the same
    /// spine tone as the rest of the wire (owner's ruling, 2026-10-03).
    @Test func connectingAndFailedMembersLeaveTheWireOneColour() {
        let plan = RailPlan.resolve(toneInput(armed: true, nodes: [.connecting, .failed, .member]))
        let runs = BusRailOverlayView().wireRuns(for: plan)
        #expect(runs.count == 4, "hook + three on-spine runs")
        #expect(runs.allSatisfy { sameInk($0.color, Tokens.Color.spineTone) }, "every run wears the spine tone")
    }

    // MARK: Folded subsections (owner's ruling, 2026-10-04)

    /// S6: a collapsed subsection hiding a member ABOVE a visible member gets
    /// its dot, and the line passes straight through it to the member below.
    @Test func aFoldAboveAVisibleMemberIsDottedAndTheLineRunsThrough() throws {
        var input = expandedInput()
        input.stops = [.init(y: 420, node: .member), .init(y: 340, node: .member)]
        input.folds = [.init(dotY: 380, headerSpan: 372...388)]
        let plan = RailPlan.resolve(input)
        #expect(plan.headerDotYs == [380], "the fold hiding a member carries a dot")
        #expect(plan.signalTerminusIndex == 1, "the rail ends on the visible member below it")
        #expect(plan.lineEndY == nil)
        #expect(lowestInk(BusRailOverlayView().wireRuns(for: plan)) < 380,
                "the line continues past the dot")
    }

    /// S5: two folds each hiding a member, nothing reached visible below them:
    /// two dots, and the rail ends on the lower one.
    @Test func twoFoldsHidingMembersGetTwoDotsAndTheRailEndsAtTheLower() throws {
        var input = expandedInput()
        input.stops = [.init(y: 420, node: .member), .init(y: 340, node: .nonMember)]
        input.folds = [.init(dotY: 380, headerSpan: 372...388),
                       .init(dotY: 300, headerSpan: 292...308)]
        let plan = RailPlan.resolve(input)
        #expect(plan.headerDotYs == [380, 300], "a dot on every fold hiding a member")
        #expect(plan.terminusDotY == 300, "the rail ends on the lower dot")
        let runs = BusRailOverlayView().wireRuns(for: plan)
        #expect(abs(lowestInk(runs) - 300) < 0.01, "…and draws nothing below it")
    }

    private func lowestInk(_ runs: [BusRailOverlayView.WireRun]) -> CGFloat {
        runs.flatMap { run -> [CGFloat] in
            let b = run.path.bounds
            return [b.minY]
        }.min() ?? .greatestFiniteMagnitude
    }

    // MARK: A collapsed SUBSECTION low in the list must not erase the rows above it

    /// Fixed geometry standing in for a card's or subsection's clip + header.
    private final class FakeRailSection: NSView, RailSectionProviding {
        var collapsed = false
        let clip = NSView()
        let headerRow = NSView()
        var railSectionCollapsed: Bool { collapsed }
        var railSectionHeaderView: NSView? { headerRow }
        var railSectionHeaderBounds: NSRect { headerRow.bounds }
        var railSectionClipView: NSView? { clip }
        var railSectionClipBounds: NSRect { clip.bounds }

        /// The clip and header must live IN the hierarchy: the overlay converts
        /// their bounds through it.
        func mount(clip clipFrame: NSRect, header headerFrame: NSRect) {
            clip.frame = clipFrame
            headerRow.frame = headerFrame
            addSubview(clip)
            addSubview(headerRow)
        }
    }

    private final class FakeStopRow: NSView, RailNodeProviding {
        var node: MembershipBusView.Node = .member
        var railNode: MembershipBusView.Node? { node }
        var railDeviceID: String? { nil }
        var railNodeView: NSView { self }
        var railNodeBounds: NSRect { bounds }
    }

    private final class FakeHook: NSView, RailHookProviding {
        func railHookAnchor(in view: NSView) -> (centerY: CGFloat, ringCenterX: CGFloat, ringRadius: CGFloat, armed: Bool)? {
            let f = view.convert(bounds, from: self)
            return (f.midY, 20, 8, true)
        }
        func receiveRailPulse() {}
    }

    /// The panel the overlay tests run in: a hook up top, the device card's
    /// clip from y = 40 to 320 under a header at 320...344.
    private func mountedOverlay(rows rowSpecs: [(y: CGFloat, node: MembershipBusView.Node)],
                                folds foldSections: [FakeRailSection] = [])
        -> (BusRailOverlayView, NSView)
    {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 400))
        let hook = FakeHook(frame: NSRect(x: 0, y: 360, width: 360, height: 28))
        container.addSubview(hook)
        let card = FakeRailSection(frame: container.bounds)
        card.mount(clip: NSRect(x: 0, y: 40, width: 360, height: 280),
                   header: NSRect(x: 0, y: 320, width: 360, height: 24))
        container.addSubview(card)
        let rows = rowSpecs.map { spec -> FakeStopRow in
            let row = FakeStopRow(frame: NSRect(x: 0, y: spec.y, width: 360, height: 28))
            row.node = spec.node
            container.addSubview(row)
            return row
        }
        for fold in foldSections { container.addSubview(fold) }
        let overlay = BusRailOverlayView()
        overlay.frame = container.bounds
        container.addSubview(overlay)
        overlay.mainOutRow = hook
        overlay.deviceRows = rows
        overlay.deviceListSection = card
        overlay.foldedSections = foldSections
        container.layoutSubtreeIfNeeded()
        return (overlay, container)
    }

    /// A collapsed subsection: header at `headerY...headerY + 24`, a zero-height
    /// clip directly under it.
    private func collapsedSubsection(headerY: CGFloat) -> FakeRailSection {
        let subsection = FakeRailSection(frame: NSRect(x: 0, y: 0, width: 360, height: 400))
        subsection.collapsed = true
        subsection.mount(clip: NSRect(x: 0, y: headerY, width: 360, height: 0),
                         header: NSRect(x: 0, y: headerY, width: 360, height: 24))
        return subsection
    }

    /// S4/S8 and the old regression together. The dot sits on the collapsed
    /// header's vertical centre (y = 132 for a header at 120...144), not its
    /// bottom edge (y = 120, where the old single cut put it). And the rows
    /// above the fold stay on the rail: the old code read the stop ceiling off
    /// the cut subsection's clip, which sits below every visible row, and
    /// dropped the whole visible band.
    @Test func aFoldedHeaderDotSitsOnTheHeaderCentreAndTheRowsAboveStay() throws {
        let (overlay, _) = mountedOverlay(
            rows: [(280, .member), (240, .nonMember), (200, .member)],
            folds: [collapsedSubsection(headerY: 120)])
        let plan = try #require(overlay.test_resolvePlan())
        #expect(plan.stops.count == 3, "the rows above the collapsed subsection stay on the rail")
        #expect(plan.terminusDotY == 132,
                "the rail ends on a dot on the header's centre line, not its bottom edge (120)")
    }

    /// S16/S18: a reached speaker (and a dotted header) scrolled below the
    /// list's visible edge. The rail ends on the lowest FULLY visible on-spine
    /// row with no dot, and no ink — line or detour arc — lands below the
    /// list's bottom edge (y = 40), where the old code ran the line and arcs
    /// over whatever card sat below.
    @Test func aMemberScrolledBelowTheListEndsTheRailOnTheLowestVisibleNode() throws {
        let (overlay, _) = mountedOverlay(
            rows: [(280, .member), (240, .nonMember), (200, .member),
                   (30, .nonMember),     // straddles the bottom edge
                   (-20, .member)],      // scrolled out of view, still in the mix
            folds: [collapsedSubsection(headerY: -60)])
        let plan = try #require(overlay.test_resolvePlan())
        let end = try #require(plan.signalTerminusIndex)
        #expect(plan.stops[end].y == 214, "the rail ends on the row at 200...228, the lowest fully visible member")
        #expect(plan.lineEndY == nil && plan.headerDotYs.isEmpty,
                "no end dot, and the off-screen fold's dot is not drawn")
        #expect(lowestInk(overlay.wireRuns(for: plan)) >= 40, "nothing draws below the list's bottom edge")
    }
}
