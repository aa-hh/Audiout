// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

/// The ONE approved custom-drawn element in the control-panel shell (T11,
/// documented exception — see `AGENTS.md`): draws the rounded bubble +
/// downward-pointing "beak" triangle that visually ties the panel to the
/// menu-bar status item. NSPanel has no built-in arrow, so this view fills a
/// separate, purely decorative window sitting BEHIND the real content panel
/// (see `ControlPanelWindowController.makeBackingWindow`) rather than living
/// inside the hosted content's own view hierarchy — the shell never draws
/// into content it doesn't own.
///
/// Coordinate model: this view's own bounds are taller than the visible
/// "bubble body" by `beakHeight` — the bottom `bounds.height - beakHeight`
/// is the rounded-rect bubble (exactly the size/position of the real content
/// panel sitting on top of it), and the top `beakHeight` strip is where the
/// beak triangle pokes up toward the status item. `beakFraction` places the
/// tip horizontally; the owning window controller keeps it in sync with the
/// anchor on every `show(anchorRect:)`.
@MainActor
public final class ControlPanelBackingView: NSView {

    /// Height of the triangular "beak" reserved at the top of this view.
    public static let beakHeight: CGFloat = 9
    /// Width of the beak's base.
    public static let beakWidth: CGFloat = 18
    /// Corner radius of the bubble body — kept in sync with the corner mask
    /// `ControlPanelWindowController` applies to the hosted content's layer
    /// so the two windows read as one continuous shape.
    public static let cornerRadius: CGFloat = 12

    /// Fraction (0...1) along the bubble's top edge where the beak tip sits.
    /// Clamped by the setter so the tip never lands inside a rounded corner.
    var beakFraction: CGFloat = 0.85 {
        didSet { needsDisplay = true }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override var isOpaque: Bool { false }

    /// The bubble body's rect within this view's own bounds (excludes the
    /// beak strip). Shared by `draw(_:)` and `bubblePath(in:)` so the fill
    /// and the hit-test/shadow path never drift apart.
    private var bubbleRect: NSRect {
        NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - Self.beakHeight))
    }

    /// The single combined path (rounded bubble + beak triangle) used for
    /// both fill and hit-testing.
    private func bubblePath() -> NSBezierPath {
        let rect = bubbleRect
        let path = NSBezierPath(roundedRect: rect, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)

        let minFraction = Self.cornerRadius / max(bounds.width, 1)
        let clamped = min(max(beakFraction, minFraction), 1 - minFraction)
        let tipX = bounds.width * clamped
        let halfBase = Self.beakWidth / 2
        path.move(to: NSPoint(x: tipX - halfBase, y: rect.maxY))
        path.line(to: NSPoint(x: tipX, y: bounds.height))
        path.line(to: NSPoint(x: tipX + halfBase, y: rect.maxY))
        path.close()
        return path
    }

    public override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bubblePath().fill()
    }

    /// Repaint on a light/dark flip. This bubble's `windowBackgroundColor` fill
    /// is now the LIVE source of the shell's content-pane background too — the
    /// hosted content is left transparent so this shows through it (see
    /// `ControlPanelWindowController.configureContentAppearance`). A custom
    /// `draw(_:)` isn't re-invoked automatically on an appearance change, so
    /// without this a mid-session theme flip would leave a stale fill behind
    /// both the bubble and the content pane.
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// This view (and the window it lives in) is purely decorative — see
    /// `ControlPanelWindowController.makeBackingWindow`, which also sets
    /// `ignoresMouseEvents = true` on the whole window so hosted content in
    /// the real panel in front is never shadowed by this one. The override
    /// here is defense in depth in case this view is ever reused somewhere
    /// that does receive events.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bubblePath().contains(local) ? super.hitTest(point) : nil
    }
}
