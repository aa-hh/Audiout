// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import AppKit
import Foundation
@testable import AudiouterPopoverUI
@testable import AudiouterSharedUI

/// What `PopoverPanelViewController.insertRow`/`removeRow` PUBLISH, not just
/// what they lay out — the popover's whole height contract runs through
/// `preferredContentSize`, and the live "the sync drawer opens from the top of
/// the screen" bug lived entirely in that published number while the view tree
/// itself was always correct.
///
/// The case that broke, and that nothing covered: the BT sync drawer is ONE
/// reused `BTSyncDrawerView` (`PopoverController`, D2), and an animated
/// `removeRow` leaves the view `isHidden` when it detaches it. An
/// `NSStackView` gives a hidden arranged subview zero height, so on every
/// mount after the first the size was measured with the row counting for
/// nothing — the popover was told "no change" and the content grew underneath
/// it. Every existing drawer test drives the un-animated path
/// (`test_toggleSyncDrawer(animated: false)`), where `removeRow` never hides
/// anything, so all of them stayed green.
@MainActor
@Suite struct PopoverControllerRowRevealTests {

    /// A row of a known fixed height — the sync drawer's stand-in, so the
    /// assertions can name an exact delta instead of a measured one.
    private final class FixedRow: NSView {
        init(height: CGFloat) {
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            heightAnchor.constraint(equalToConstant: height).isActive = true
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }

    private static let drawerHeight: CGFloat = 72

    /// A settled panel holding one card with `rowCount` rows, plus the
    /// collapsed height every assertion below measures against.
    private func makePanel(rowCount: Int = 1, reduceMotion: Bool)
        -> (panel: PopoverPanelViewController, rows: [NSView], collapsedHeight: CGFloat) {
        let panel = PopoverPanelViewController()
        panel.test_reduceMotionOverride = reduceMotion
        _ = panel.view
        panel.beginCard(header: "Output Devices")
        let rows = (0..<rowCount).map { _ -> NSView in
            let row = FixedRow(height: 30)
            panel.addRow(row)
            return row
        }
        return (panel, rows, panel.fittingSizeSettled().height)
    }

    /// Let an `NSAnimationContext` group's implicit animations apply. Their
    /// COMPLETION handlers never fire for a view that is in no window, so
    /// nothing here may depend on `removeRow`'s deferred detach.
    private func runAnimations() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    }

    // MARK: The published height

    @Test func insertPublishesTheGrownHeightBeforeTheRowAnimatesIn() {
        let (panel, rows, collapsed) = makePanel(reduceMotion: false)
        let drawer = FixedRow(height: Self.drawerHeight)

        panel.insertRow(drawer, after: rows[0], animated: true)

        #expect(panel.preferredContentSize.height == collapsed + Self.drawerHeight,
                "the popover has to be told the FINAL height up front — it is what grows the window while the row unfolds into it")
        runAnimations()
        #expect(drawer.isHidden == false, "the row ends the animation visible")
        #expect(panel.fittingSizeSettled().height == panel.preferredContentSize.height,
                "content and published size agree once the animation settles")
    }

    /// THE regression. A drawer that has been opened, closed, and opened again
    /// arrives at its second `insertRow` still hidden from the animated
    /// removal that detached it.
    @Test func aReusedRowThatArrivesHiddenStillPublishesItsFullHeight() {
        let (panel, rows, collapsed) = makePanel(reduceMotion: false)
        let drawer = FixedRow(height: Self.drawerHeight)
        drawer.isHidden = true      // exactly what an animated `removeRow` leaves behind

        panel.insertRow(drawer, after: rows[0], animated: true)

        #expect(panel.preferredContentSize.height == collapsed + Self.drawerHeight,
                "a re-mounted row must publish its height like a fresh one; measuring it while hidden published \(collapsed) and let the content overflow the popover")
        runAnimations()
        #expect(drawer.isHidden == false)
    }

    @Test func removePublishesTheCollapsedHeightAgain() {
        let (panel, rows, collapsed) = makePanel(reduceMotion: false)
        let drawer = FixedRow(height: Self.drawerHeight)
        panel.insertRow(drawer, after: rows[0], animated: false)
        #expect(panel.preferredContentSize.height == collapsed + Self.drawerHeight)

        panel.removeRow(drawer, animated: false)

        #expect(drawer.superview == nil, "an un-animated removal detaches immediately")
        #expect(panel.preferredContentSize.height == collapsed,
                "the collapse returns to EXACTLY the pre-expand height, not approximately")
    }

    // MARK: Reduce Motion — both states resolve instantly

    @Test func reduceMotionMountsAndUnmountsWithNoAnimationPending() {
        let (panel, rows, collapsed) = makePanel(reduceMotion: true)
        let drawer = FixedRow(height: Self.drawerHeight)
        drawer.isHidden = true      // the reused-drawer state again

        panel.insertRow(drawer, after: rows[0], animated: true)

        // No run loop spin: with Reduce Motion on, the end state is the state.
        #expect(drawer.isHidden == false,
                "Reduce Motion returns before the reveal animation, so the row has to be visible ALREADY — a reused row left hidden here would mount invisible for good")
        #expect(panel.preferredContentSize.height == collapsed + Self.drawerHeight)

        panel.removeRow(drawer, animated: true)
        #expect(drawer.superview == nil, "Reduce Motion detaches immediately, no deferred completion")
        #expect(panel.preferredContentSize.height == collapsed)
    }

    // MARK: It expands out of its own row

    /// The drawer's whole point (PLAN-BT-SYNC-DRAWER D1): it opens DOWNWARD out
    /// of the row it belongs to and pushes the rows BELOW down. Everything above
    /// it — which, with the panel's content chain hanging from its top edge,
    /// means everything between it and the panel's top edge — must not move at
    /// all, and the collapse puts every one of them back.
    @Test func expandingOpensDownwardOutOfItsRowAndCollapsingReturns() {
        let (panel, rows, _) = makePanel(rowCount: 3, reduceMotion: true)
        let drawer = FixedRow(height: Self.drawerHeight)

        /// A view's distance from the panel's TOP edge, laid out at whatever
        /// height the panel has just published — the popover sizes its content
        /// view to exactly that, so this is the view's real on-screen offset
        /// from the fixed top of the surface.
        func topOffset(_ view: NSView) -> CGFloat {
            panel.view.frame.height - panel.view.convert(view.bounds, from: view).maxY
        }
        func settle() {
            panel.view.frame = NSRect(origin: .zero, size: panel.preferredContentSize)
            panel.view.layoutSubtreeIfNeeded()
        }
        func topOffsets() -> [CGFloat] { settle(); return rows.map(topOffset) }

        panel.panelContentDidChangeHeight(animated: false)
        let before = topOffsets()
        let beforeHeight = panel.preferredContentSize.height

        panel.insertRow(drawer, after: rows[1], animated: true)
        let after = topOffsets()

        #expect(after[0] == before[0], "the row above the drawer must not move")
        #expect(after[1] == before[1], "nor the row the drawer belongs to — it is the anchor the drawer opens out of")
        #expect(after[2] == before[2] + Self.drawerHeight,
                "the row below is pushed down by exactly the drawer's height")
        #expect(topOffset(drawer) == before[1] + 30,
                "the drawer sits directly under its own row (30pt tall), not somewhere else in the stack")
        #expect(panel.preferredContentSize.height == beforeHeight + Self.drawerHeight,
                "and the published height grew by exactly the same amount")

        panel.removeRow(drawer, animated: true)

        #expect(topOffsets() == before, "the collapse brings every row back to where it started")
        #expect(panel.preferredContentSize.height == beforeHeight)
    }
}
