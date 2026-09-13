// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import Testing
@testable import AudioutSharedUI

/// The halo ring's permanent gap (ported from the iOS ring treatment): every
/// drawn form is a 290° open arc, not a full circle, so the gold route-armed
/// dot sits IN a break in the ring instead of nearly touching the stroke.
/// This pins the geometry against the actual stroked path — if the gap is
/// lost (a revert to `CGPath(ellipseIn:)`) or the arc direction flips (the
/// 70° stub gets drawn instead of the 290° long side), the dot merges back
/// into the ring and this fails.
@MainActor
@Suite final class HaloRingGapTests: IsolatedSuite {

    @Test func ringPathOpensAtTheDotAndStaysClosedElsewhere() {
        let ring = HaloRingView()
        ring.frame = NSRect(x: 0, y: 0, width: 42, height: 42)
        ring.apply(.connected)
        ring.layout()

        let path = try! #require(ring.test_ringPath)
        let stroked = path.copy(strokingWithWidth: 4, lineCap: .round,
                                 lineJoin: .round, miterLimit: 10)

        let center = CGPoint(x: ring.frame.midX, y: ring.frame.midY)
        let radius = PopoverColumnGrid.haloRingDiameter / 2

        // The gap seats the dot: its center (−45°, the icon's bottom-right
        // corner direction) falls outside the stroked ring.
        let dotAngle = PopoverColumnGrid.haloRingGapCenterAngle
        let dotPoint = CGPoint(x: center.x + radius * cos(dotAngle),
                                y: center.y + radius * sin(dotAngle))
        #expect(!stroked.contains(dotPoint), "the gap must seat the dot, not the stroke")

        // The long (290°) side is what actually got drawn — top (+90°)…
        let topPoint = CGPoint(x: center.x, y: center.y + radius)
        #expect(stroked.contains(topPoint), "the long side of the arc must be drawn, not the 70° stub")

        // …and left (180°, the rail's join on the Main Audio ring) stays on the arc.
        let leftPoint = CGPoint(x: center.x - radius, y: center.y)
        #expect(stroked.contains(leftPoint), "the rail's left-edge join must stay on the drawn arc")
    }
}
