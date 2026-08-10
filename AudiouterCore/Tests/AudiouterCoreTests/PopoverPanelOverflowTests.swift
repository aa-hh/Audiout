// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import AppKit
import Foundation
@testable import AudiouterPopoverUI

/// The height-overflow rule (owner-approved 2026-08-10): the Mixer panel is
/// exact-fit while its content fits the screen, and caps itself at a
/// host-supplied budget — scrolling only the card stack — once it does not.
///
/// The whole rule is expressed by two constraints on ONE scroll view, so these
/// tests pin the two halves separately and, above all, the boundary between
/// them: with no budget pushed (the headless default — `swift test`,
/// `popover-harness`, `popover-snapshot`) NOTHING may change, or every checked-in
/// snapshot PNG and every existing sizing assertion is a false positive waiting
/// to happen.
@MainActor
@Suite final class PopoverPanelOverflowTests {

    /// A row of a known fixed height, so every assertion can name an exact
    /// number instead of a measured one.
    private final class FixedRow: NSView {
        init(height: CGFloat) {
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            heightAnchor.constraint(equalToConstant: height).isActive = true
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }

    private static let rowHeight: CGFloat = 30

    /// Windows are retained for the suite's lifetime so nothing deallocs a view
    /// that is mid-layout (borderless test windows are never ordered on screen).
    private var windows: [NSWindow] = []

    /// A settled panel holding one card with `rowCount` rows. Reduce Motion is
    /// forced ON: nothing here is testing an animation, and the instant paths
    /// make every assertion read the settled end state.
    private func makePanel(rowCount: Int) -> (panel: PopoverPanelViewController, rows: [NSView]) {
        let panel = PopoverPanelViewController()
        panel.test_reduceMotionOverride = true
        _ = panel.view
        panel.beginCard(header: "Output Devices")
        let rows = (0..<rowCount).map { _ -> NSView in
            let row = FixedRow(height: Self.rowHeight)
            panel.addRow(row)
            return row
        }
        panel.panelContentDidChangeHeight(animated: false)
        return (panel, rows)
    }

    /// Give the panel a real frame in a real window — `fittingSize` is
    /// frame-independent, but a clip view's scroll offset is not.
    private func host(_ panel: PopoverPanelViewController) {
        let size = panel.preferredContentSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        // The wrapper is normally sized by the window it is the content view of;
        // here it is a plain subview, so hand it the frame directly (the
        // `popover-snapshot` tool hosts it exactly this way).
        panel.view.translatesAutoresizingMaskIntoConstraints = true
        panel.view.frame = NSRect(origin: .zero, size: size)
        window.contentView?.addSubview(panel.view)
        window.layoutIfNeeded()
        panel.view.layoutSubtreeIfNeeded()
        windows.append(window)
    }

    // MARK: The fitting case — nothing may change

    @Test func withNoBudgetThePanelIsExactFitAndMountsNoScroller() {
        let (panel, _) = makePanel(rowCount: 4)

        #expect(panel.test_maxContentHeight == nil,
                "a panel nobody has pushed a budget into is UNCAPPED — that is what every headless render sees")
        #expect(panel.preferredContentSize.height == panel.fittingSizeSettled().height,
                "exact fit: the published height IS the content height")
        #expect(panel.isContentOverflowing == false)
        #expect(panel.test_hasVerticalScroller == false,
                "no scroller chrome may exist while the content fits")
    }

    @Test func aBudgetTallerThanTheContentChangesNothing() {
        let (panel, _) = makePanel(rowCount: 4)
        let natural = panel.fittingSizeSettled().height

        panel.setMaxContentHeight(natural + 400)
        panel.panelContentDidChangeHeight(animated: false)

        #expect(panel.preferredContentSize.height == natural,
                "a budget the content fits inside must leave the exact fit alone")
        #expect(panel.isContentOverflowing == false)
        #expect(panel.test_hasVerticalScroller == false)
    }

    // MARK: The capped case

    @Test func contentTallerThanTheBudgetPublishesTheBudgetAndScrolls() {
        let (panel, _) = makePanel(rowCount: 24)
        let natural = panel.fittingSizeSettled().height
        let budget = natural - 200

        panel.setMaxContentHeight(budget)
        panel.panelContentDidChangeHeight(animated: false)

        #expect(panel.preferredContentSize.height == budget,
                "the published height is the BUDGET once the content outgrows it — the whole point of the cap")
        #expect(panel.isContentOverflowing)
        #expect(panel.test_hasVerticalScroller,
                "the scroller is the only affordance saying the rest of the fleet is down there")
        #expect(panel.test_documentNaturalHeight > budget,
                "the DOCUMENT keeps its full natural height — capping it instead would squeeze the rows and break every reveal target")
    }

    @Test func clearingTheBudgetRestoresTheExactFit() {
        let (panel, _) = makePanel(rowCount: 24)
        let natural = panel.fittingSizeSettled().height

        panel.setMaxContentHeight(natural - 200)
        panel.panelContentDidChangeHeight(animated: false)
        #expect(panel.test_hasVerticalScroller)

        panel.setMaxContentHeight(nil)
        panel.panelContentDidChangeHeight(animated: false)

        #expect(panel.preferredContentSize.height == natural)
        #expect(panel.isContentOverflowing == false)
        #expect(panel.test_hasVerticalScroller == false,
                "dropping the budget has to un-mount the scroller, not leave dead chrome behind")
    }

    /// The budget is a WINDOW-CONTENT height, but the cap it drives lives on the
    /// scrollable region — so the panel has to subtract its own top inset (which
    /// the surface's toolbar strip inflates) and bottom margin. If it forgot,
    /// a Mixer seated below a 52pt toolbar would publish 52pt past the screen.
    @Test func theToolbarChromeInsetComesOutOfTheScrollableRegion() {
        let (panel, _) = makePanel(rowCount: 24)
        let budget = panel.fittingSizeSettled().height - 200

        panel.setMaxContentHeight(budget)
        panel.setContentTopInset(52)
        panel.panelContentDidChangeHeight(animated: false)

        #expect(panel.preferredContentSize.height == budget,
                "the published height stays the budget whatever the chrome inset is — the inset eats into the SCROLLABLE band, not past the screen edge")
        #expect(panel.isContentOverflowing)
    }

    // MARK: Scroll position

    @Test func scrollContentToTopResetsAScrolledPanel() {
        let (panel, _) = makePanel(rowCount: 24)
        panel.setMaxContentHeight(panel.fittingSizeSettled().height - 200)
        panel.panelContentDidChangeHeight(animated: false)
        host(panel)

        panel.test_scrollContent(toY: 80)
        #expect(panel.test_scrollOffsetY > 0,
                "precondition: the capped panel really does scroll")

        panel.scrollContentToTop()

        #expect(panel.test_scrollOffsetY == 0,
                "every open starts at the top of the fleet (AppSurfaceController.mount runs this after the open ritual)")
    }

    /// A fitting panel must not move under a flick — the scroll view is there,
    /// but off-overflow it has nothing to scroll and no elasticity to fake it.
    @Test func aFittingPanelHasNothingToScroll() {
        let (panel, _) = makePanel(rowCount: 4)
        host(panel)

        panel.test_scrollContent(toY: 80)

        #expect(panel.test_scrollOffsetY == 0,
                "an uncapped, fitting panel is pinned at the top — a clip view clamps to a document it already shows whole")
    }
}
