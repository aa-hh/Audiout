// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
import AppKit
@testable import AudiouterSharedUI

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
final class BusRailCollapseResolveTests: IsolatedTestCase {

    // A three-device span: two through-members then a terminus member, all under
    // the Main Audio ring. Device clip fully expanded (floor below every node).
    private func expandedInput() -> RailPlan.Input {
        RailPlan.Input(
            gold: true,
            ringCenterY: 500, ringCenterX: 20, ringRadius: 15, landingDrop: 16,
            originSectionCollapsed: false,
            originClipBand: 460...540,      // ring (500) sits inside → ring visible
            originHeaderY: 560,
            deviceSectionCollapsed: false,
            deviceFloorY: 300,              // below every stop → no clip
            stops: [
                .init(y: 420, node: .member, below: true, dimmed: false),
                .init(y: 380, node: .member, below: true, dimmed: false),
                .init(y: 340, node: .member, below: false, dimmed: false),  // natural terminus
            ])
    }

    // MARK: Behavior 1 — collapsed device section terminates at its header dot

    func testExpandedRailEndsAtLowestNodeNoTerminusDot() {
        let plan = RailPlan.resolve(expandedInput())
        XCTAssertEqual(plan.origin, .ring(centerY: 500, ringCenterX: 20, ringRadius: 15),
                       "expanded origin curves into the Main Audio ring")
        XCTAssertEqual(plan.stops.count, 3, "every in-span node is drawn when expanded")
        XCTAssertNil(plan.terminusDotY,
                     "expanded: the rail ends naturally at its lowest node — no cut dot")
    }

    func testCollapsedDeviceSectionCutsRailWithHeaderDotAndDropsAllNodes() {
        var input = expandedInput()
        // Device body collapsed: clip height 0, floor risen to just under the
        // device header (say y = 452, header at ~455).
        input.deviceSectionCollapsed = true
        input.deviceFloorY = 452
        let plan = RailPlan.resolve(input)

        XCTAssertEqual(plan.stops.count, 0,
                       "a collapsed device section draws NONE of its now-hidden nodes")
        XCTAssertEqual(try XCTUnwrap(plan.terminusDotY), 452, accuracy: 0.001,
                       "the rail is cut with a terminus dot at the collapsed section floor (its header)")
        XCTAssertEqual(plan.origin, .ring(centerY: 500, ringCenterX: 20, ringRadius: 15),
                       "the ORIGIN is untouched — only the far end collapsed (behavior 2 contrast)")
    }

    // MARK: Behavior 2 — the origin moves up when the ORIGIN section collapses

    func testCollapsedOriginSectionMovesOriginToHeaderDot() {
        var input = expandedInput()
        // Origin (System Audio) body collapsed: clip shrank past the ring, so the
        // ring is no longer inside the band → origin snaps to the header dot.
        input.originSectionCollapsed = true
        input.originClipBand = 558...560          // ring (500) now BELOW the band
        let plan = RailPlan.resolve(input)

        XCTAssertEqual(plan.origin, .headerDot(y: 560),
                       "a collapsed origin section begins the rail at its own header dot")
        XCTAssertEqual(plan.railTopY, 560, accuracy: 0.001,
                       "the vertical rail now starts at the header, not the ring landing")
        XCTAssertEqual(plan.stops.count, 3,
                       "the device section is still expanded, so all its nodes still draw")
        XCTAssertNil(plan.terminusDotY, "device end unaffected by the origin collapsing")
    }

    func testOriginStillRidesTheRingWhileItRemainsInsideTheShrinkingBand() {
        var input = expandedInput()
        // Mid-collapse of the origin section: the flag is already set, but the clip
        // band still contains the ring — the origin must NOT snap early (behavior 3).
        input.originSectionCollapsed = true
        input.originClipBand = 470...520          // ring (500) still inside
        let plan = RailPlan.resolve(input)
        XCTAssertEqual(plan.origin, .ring(centerY: 500, ringCenterX: 20, ringRadius: 15),
                       "while the ring is still within the clip band the origin stays on the ring")
    }

    // MARK: Behavior 3 — the terminus tracks the live clip floor frame-by-frame

    func testTerminusFloorSqueezesContinuouslyWithTheClipHeight() {
        // Sweep the device clip floor UP through the three node ys; the number of
        // drawn stops and the cut position must track it monotonically — proof the
        // rail squeezes in sync with the live (animating) clip, not a before/after
        // snap.
        var input = expandedInput()

        // Floor just above the lowest node (340): that node is clipped, two remain.
        input.deviceFloorY = 360
        var plan = RailPlan.resolve(input)
        XCTAssertEqual(plan.stops.map(\.y), [420, 380],
                       "floor at 360 clips only the lowest node")
        XCTAssertEqual(try XCTUnwrap(plan.terminusDotY), 360, accuracy: 0.001)

        // Floor risen further (above 380): only the top node remains.
        input.deviceFloorY = 400
        plan = RailPlan.resolve(input)
        XCTAssertEqual(plan.stops.map(\.y), [420], "floor at 400 clips the lower two nodes")
        XCTAssertEqual(try XCTUnwrap(plan.terminusDotY), 400, accuracy: 0.001)

        // Floor above every node: the rail is a bare stub to the floor, no nodes.
        input.deviceFloorY = 450
        plan = RailPlan.resolve(input)
        XCTAssertTrue(plan.stops.isEmpty, "floor above all nodes clips them all")
        XCTAssertEqual(try XCTUnwrap(plan.terminusDotY), 450, accuracy: 0.001,
                       "the cut dot follows the floor exactly as it rises")
    }

    // MARK: Behavior 4 — re-expand restores the exact prior geometry

    func testResolveIsPureSoReexpandRestoresIdenticalGeometry() {
        let before = RailPlan.resolve(expandedInput())

        // Collapse (any intermediate + fully-collapsed state) …
        var collapsing = expandedInput()
        collapsing.deviceSectionCollapsed = true
        collapsing.deviceFloorY = 452
        _ = RailPlan.resolve(collapsing)

        // … then expand again with the SAME expanded input: identical plan back.
        let after = RailPlan.resolve(expandedInput())
        XCTAssertEqual(before, after,
                       "resolve carries no hidden state — re-expanding restores the exact rail")
    }

    // MARK: Guard — a degenerate collapse never puts the dot above the rail start

    func testTerminusDotIsClampedNotAboveRailTop() {
        var input = expandedInput()
        // Pathological: device floor risen ABOVE the ring landing (panel squashed).
        input.deviceSectionCollapsed = true
        input.deviceFloorY = 900
        let plan = RailPlan.resolve(input)
        XCTAssertEqual(try XCTUnwrap(plan.terminusDotY), plan.railTopY, accuracy: 0.001,
                       "the cut dot is clamped to railTop so it never draws above the origin")
    }
}
