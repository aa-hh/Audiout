// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import AppKit
@testable import AudiouterPopoverUI

/// The expand's MOTION, not its end state (live report, 2026-08-08:
/// "collapsing: smooth. Expanding: abrupt").
///
/// `insertRow` has to measure the row's final height with the row VISIBLE, and
/// that measurement settles the whole panel at that height. Unless the collapsed
/// layout is handed back before the reveal runs, the stack has no distance left
/// to interpolate: the rows below arrive at their new places up front and the
/// only thing still moving is the popover's own frame animation. The end state
/// is identical either way, which is why every other row-reveal test stayed
/// green through it.
///
/// What this CANNOT cover: AppKit's interpolation itself. An
/// `NSAnimationContext` group's completion handler never fires for a view in no
/// window, and a windowless view runs no presentation layer — so the assertions
/// below pin the trajectory's two ENDPOINTS, where the reveal starts and where
/// the surface is told to finish. Whether the two read as one motion is a live
/// judgement.
@MainActor
@Suite struct PopoverControllerRowRevealMotionTests {

    /// A row of a known fixed height — the sync drawer's stand-in, so the
    /// assertions can name an exact height instead of a measured one.
    private final class FixedRow: NSView {
        init(height: CGFloat) {
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            heightAnchor.constraint(equalToConstant: height).isActive = true
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }

    private static let drawerHeight: CGFloat = 72

    /// A settled panel holding one card with one row, plus the height it settled
    /// at — the height an expand out of that row must start from.
    private func makePanel() -> (panel: PopoverPanelViewController, row: NSView, collapsedHeight: CGFloat) {
        let panel = PopoverPanelViewController()
        panel.test_reduceMotionOverride = false
        _ = panel.view
        panel.beginCard(header: "Output Devices")
        let row = FixedRow(height: 30)
        panel.addRow(row)
        return (panel, row, panel.fittingSizeSettled().height)
    }

    @Test func theRevealStartsCollapsedWhileTheSurfaceIsToldTheFullHeight() {
        let (panel, row, collapsed) = makePanel()
        let drawer = FixedRow(height: Self.drawerHeight)

        panel.insertRow(drawer, after: row, animated: true)

        #expect(panel.test_rowRevealStartHeight == collapsed,
                "the reveal has to begin at the height the panel had BEFORE the row: measuring the row settles the layout at the FINAL height, and an animation that starts already arrived leaves the popover's frame moving on its own")
        #expect(panel.preferredContentSize.height == collapsed + Self.drawerHeight,
                "and the surface is told the grown height in the same turn, so it travels WITH the row rather than ahead of it")
    }

    /// The reused drawer — the case the correctness fix exists for — takes the
    /// same trajectory: arriving hidden must not cost it its start state either.
    @Test func aRowThatArrivesHiddenTakesTheSameTrajectory() {
        let (panel, row, collapsed) = makePanel()
        let drawer = FixedRow(height: Self.drawerHeight)
        drawer.isHidden = true      // exactly what an animated `removeRow` leaves behind

        panel.insertRow(drawer, after: row, animated: true)

        #expect(panel.test_rowRevealStartHeight == collapsed)
        #expect(panel.preferredContentSize.height == collapsed + Self.drawerHeight)
    }
}
