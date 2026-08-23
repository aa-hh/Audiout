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
///   1. a collapsed section cuts the rail with a terminus dot at its header,
///   2. WHICH section collapses changes the shape (origin moves up vs terminus up),
///   3. the shape tracks the LIVE clip floor frame-by-frame (the in-sync squeeze),
///   4. re-expanding restores the exact prior geometry (resolve is a pure function
///      of its input — same input, same plan).
///
/// Coordinates are non-flipped (y-up): higher y = nearer the top of the panel, so
/// the origin (Main Audio) sits at a HIGHER y than the device stops below it.
@MainActor
@Suite final class BusRailCollapseResolveTests: IsolatedSuite {

    // A three-device band: two through-members, a member, then a NON-member below
    // them — all under the Main Audio ring. Device clip fully expanded (floor
    // below every node).
    private func expandedInput() -> RailPlan.Input {
        RailPlan.Input(
            gold: true,
            ringCenterY: 500, ringCenterX: 20, ringRadius: 15, landingDrop: 16,
            originSectionCollapsed: false,
            originClipBand: 460...540,      // ring (500) sits inside → ring visible
            originHeaderY: 560,
            deviceSectionCollapsed: false,
            deviceFloorY: 260,              // below every stop → no clip
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

    @Test func collapsedDeviceSectionCutsRailWithHeaderDotAndDropsAllNodes() throws {
        var input = expandedInput()
        // Device body collapsed: clip height 0, floor risen to just under the
        // device header (say y = 452, header at ~455).
        input.deviceSectionCollapsed = true
        input.deviceFloorY = 452
        let plan = RailPlan.resolve(input)

        #expect(plan.stops.count == 0,
                       "a collapsed device section draws NONE of its now-hidden nodes")
        let terminusDotY = try #require(plan.terminusDotY)
        #expect(abs(terminusDotY - 452) <= 0.001,
                       "the rail is cut with a terminus dot at the collapsed section floor (its header)")
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
        #expect(plan.terminusDotY == nil, "device end unaffected by the origin collapsing")
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

    // MARK: Behavior 3 — the terminus tracks the live clip floor frame-by-frame

    @Test func terminusFloorSqueezesContinuouslyWithTheClipHeight() throws {
        // Sweep the device clip floor UP through the three node ys; the number of
        // drawn stops and the cut position must track it monotonically — proof the
        // rail squeezes in sync with the live (animating) clip, not a before/after
        // snap.
        var input = expandedInput()

        // Floor just above the lowest two nodes: they are clipped, two remain.
        input.deviceFloorY = 360
        var plan = RailPlan.resolve(input)
        #expect(plan.stops.map(\.y) == [420, 380],
                       "floor at 360 clips the lower two nodes")
        var terminusDotY = try #require(plan.terminusDotY)
        #expect(abs(terminusDotY - 360) <= 0.001)

        // Floor risen further (above 380): only the top node remains.
        input.deviceFloorY = 400
        plan = RailPlan.resolve(input)
        #expect(plan.stops.map(\.y) == [420], "floor at 400 clips the lower three nodes")
        terminusDotY = try #require(plan.terminusDotY)
        #expect(abs(terminusDotY - 400) <= 0.001)

        // Floor above every node: the rail is a bare stub to the floor, no nodes.
        input.deviceFloorY = 450
        plan = RailPlan.resolve(input)
        #expect(plan.stops.isEmpty, "floor above all nodes clips them all")
        terminusDotY = try #require(plan.terminusDotY)
        #expect(abs(terminusDotY - 450) <= 0.001,
                       "the cut dot follows the floor exactly as it rises")
    }

    // MARK: The cut represents hidden SIGNAL, not any hidden row

    @Test func clippingOnlyANonMemberEndsAtTheMemberWithNoTail() throws {
        // THE SECTION-TOGGLE BUG (live repro 2026-08-22). As a section collapses,
        // the clip floor rises through the NON-member rows sitting below the lowest
        // member FIRST. Hiding a non-member hides no signal, so the rail must still
        // end at the lowest member — not grow a tail down to the cut floor through
        // the non-member area ("the rail expanding into areas where it wasn't
        // before" on a rapid toggle). Only a hidden MEMBER cuts the rail.
        var input = expandedInput()
        input.deviceFloorY = 320          // between the non-member (300) and lowest member (340)
        let plan = RailPlan.resolve(input)
        #expect(plan.stops.map(\.y) == [420, 380, 340],
                "the non-member below the floor is clipped; every member stays drawn")
        #expect(plan.signalTerminusIndex == 2, "the wire still ends at the lowest member")
        #expect(plan.terminusDotY == nil,
                "no member is hidden ⇒ no cut: the rail ends at the member, no tail down to the floor")
    }

    @Test func clippingTheLowestMemberDoesCutTheRail() throws {
        // The mirror of the above: once the floor rises past the lowest MEMBER, a
        // real signal IS hidden below the fold, so the cut returns.
        var input = expandedInput()
        input.deviceFloorY = 350          // now above the lowest member (340)
        let plan = RailPlan.resolve(input)
        #expect(plan.stops.map(\.y) == [420, 380], "the lowest member is now clipped")
        let terminusDotY = try #require(plan.terminusDotY,
                "a hidden member is hidden signal — the rail cuts to the floor")
        #expect(abs(terminusDotY - 350) <= 0.001)
    }

    // MARK: Behavior 4 — re-expand restores the exact prior geometry

    @Test func resolveIsPureSoReexpandRestoresIdenticalGeometry() {
        let before = RailPlan.resolve(expandedInput())

        // Collapse (any intermediate + fully-collapsed state) …
        var collapsing = expandedInput()
        collapsing.deviceSectionCollapsed = true
        collapsing.deviceFloorY = 452
        _ = RailPlan.resolve(collapsing)

        // … then expand again with the SAME expanded input: identical plan back.
        let after = RailPlan.resolve(expandedInput())
        #expect(before == after,
                       "resolve carries no hidden state — re-expanding restores the exact rail")
    }

    // MARK: Guard — a degenerate collapse never puts the dot above the rail start

    @Test func terminusDotIsClampedNotAboveRailTop() throws {
        var input = expandedInput()
        // Pathological: device floor risen ABOVE the ring landing (panel squashed).
        input.deviceSectionCollapsed = true
        input.deviceFloorY = 900
        let plan = RailPlan.resolve(input)
        let terminusDotY = try #require(plan.terminusDotY)
        #expect(abs(terminusDotY - plan.railTopY) <= 0.001,
                       "the cut dot is clamped to railTop so it never draws above the origin")
    }
}
