// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutSharedUI

/// The Groups screen's ONE container shape (the macOS System Settings grouped
/// idiom), in three modes.
///
/// - ``Style/card`` — the page's ONE INSTRUMENT: a rounded
///   `Tokens.Color.raised` fill with a 1 pt `Tokens.Color.containerEdge` edge,
///   at the panel radius. On dark, `raised` against the pane's `panel`
///   measures 1.07:1 — below the surface floor — so the EDGE, not the fill, is
///   what carries the separation (`containerEdge` vs `raised`: 1.553:1 dark /
///   2.020:1 light). Its interior rules are `containerEdge` too: `hairline` on
///   `raised` is 1.154:1 dark, under any floor. Exactly one card per page: the
///   Equalizer on the two detail pages, the Speakers checklist in the group
///   editor.
/// - ``Style/panel`` — a stroked-panel row list (the iPhone companion's
///   PanelRow): `panel` fill, 1 pt `containerEdge` edge at the row radius,
///   `hairline` dividers. The pane ground is `panel` too, so the stroke is the
///   card. The fact lists on the detail pages wear it.
/// - ``Style/bare`` — a DIVIDER-ONLY list: no fill, no border, just the inset
///   hairlines between rows. What the header bands wear.
///
/// A box is earned by holding a different instrument, never by length.
///
/// The geometry, all of it load-bearing:
///
/// - **Spans the full column width**, gutter included, so the rail's nodes sit
///   INSIDE the section rather than floating beside it. Content within is inset
///   past the gutter (`contentLeadingInset`) so the spine keeps a clear lane.
/// - **Padded** top/bottom (`verticalPadding`) so content breathes instead of
///   touching the container's edges. A `.card` host may use
///   `GroupsPaneLayout.cardContentInset` instead when its content is an
///   instrument rather than a stack of text rows.
/// - **Inset dividers** starting at `contentLeadingInset` — the standard
///   grouped-list separator treatment, never full-bleed under the corners. A
///   section holding fewer than two rows draws none, which is what lets this
///   same view serve as a plain header band.
/// - **A radius large enough to read as a shape** in `.card`; the first
///   draft's 6 pt radius rendered visually square.
///
/// `draw(_:)`-based, not a frozen layer color — `DeviceIconWellView`'s pattern:
/// every token re-resolves per appearance/Increase-Contrast on each paint, and
/// `viewDidChangeEffectiveAppearance` just triggers a repaint. Non-interactive
/// (`hitTest` always `nil`, `MembershipBusView`'s pattern) — it sits BEHIND the
/// content it backs in z-order, so no row/checkbox/rail click target is ever
/// affected; the dead area beside a narrower row simply swallows a click with
/// no target, same as clicking blank pane background anywhere else.
final class GroupedSectionView: NSView {
    /// How this container draws itself — see the type's doc comment.
    enum Style {
        /// The page's one instrument: `raised` fill + a `containerEdge` edge.
        case card
        /// A stroked-panel row list (iOS PanelRow): `panel` fill, 1 pt
        /// `containerEdge` edge at the row radius, `hairline` dividers. The
        /// pane ground is `panel` too, so the stroke is the card.
        case panel
        /// A divider-only list: no fill, no border.
        case bare
    }

    /// Defaults to ``Style/card`` so a section is a card unless a page says
    /// otherwise — there is at most one per page, and it is the loud one.
    var style: Style = .card { didSet { needsDisplay = true } }

    /// The card is a grouped stack, so it takes the panel rung; a `.panel`
    /// list is a row, so it takes the row rung. `.bare` draws no shape, so its
    /// value is never read.
    private var cornerRadius: CGFloat {
        switch style {
        case .card: return Tokens.Layout.Radius.panel
        case .panel: return Tokens.Layout.Radius.row
        case .bare: return 0
        }
    }
    /// Breathing room above the first row and below the last, so rows never
    /// touch the container's edges.
    static let verticalPadding: CGFloat = 6
    private static let hairlineThickness: CGFloat = 1
    private static let borderWidth: CGFloat = 1

    /// Where the row's ICON starts, measured from this view's own leading edge
    /// — the inset dividers align to it. Set by the controller so it stays
    /// derived from the shared grid rather than re-typed here.
    var contentLeadingInset: CGFloat = 0 { didSet { needsDisplay = true } }

    /// The rows currently laid out over this view, in top-to-bottom order —
    /// read for LIVE frames on every draw, exactly like
    /// `BusRailOverlayView.deviceRows` (no cached geometry: a rebuild can
    /// add/drop rows when an unchecked unavailable device disappears).
    var rows: [NSView] = [] { didSet { needsDisplay = true } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        switch style {
        case .card, .panel:
            // Stroke sits ON the boundary, so inset by half its width to keep
            // the 1pt line crisp instead of straddling the pixel edge.
            let borderRect = bounds.insetBy(dx: Self.borderWidth / 2, dy: Self.borderWidth / 2)
            let radius = cornerRadius
            let shape = NSBezierPath(roundedRect: borderRect,
                                     xRadius: radius, yRadius: radius)
            (style == .card ? Tokens.Color.raised : Tokens.Color.panel).setFill()
            shape.fill()
            Tokens.Color.containerEdge.setStroke()
            shape.lineWidth = Self.borderWidth
            shape.stroke()
        case .bare:
            break
        }

        guard rows.count > 1 else { return }
        // `hairline` on `raised` measures 1.154:1 dark — invisible — so the
        // card rules its interior with `containerEdge` too. On `panel` and on
        // the bare ground `hairline` is 1.314:1 dark / 1.512:1 light and
        // stands, so the lighter weight stays where it reads.
        (style == .card ? Tokens.Color.containerEdge : Tokens.Color.hairline).setFill()
        for (a, b) in zip(rows, rows.dropFirst()) {
            guard let aSuper = a.superview, let bSuper = b.superview else { continue }
            let aFrame = convert(a.frame, from: aSuper)
            let bFrame = convert(b.frame, from: bSuper)
            // Robust to either coordinate flip: two non-overlapping adjacent
            // rows' gap is bounded by the two INNER edges of the four
            // (min/max of each frame) — sorting picks them out without this
            // view needing to know which axis direction is "down".
            let ys = [aFrame.minY, aFrame.maxY, bFrame.minY, bFrame.maxY].sorted()
            let midY = (ys[1] + ys[2]) / 2
            // INSET to the icon's leading edge (grouped-list separator
            // treatment) — a full-bleed line would run under the container's
            // rounded corners and read as a slab, not a list.
            let lineRect = NSRect(x: bounds.minX + contentLeadingInset,
                                  y: midY - Self.hairlineThickness / 2,
                                  width: bounds.width - contentLeadingInset,
                                  height: Self.hairlineThickness)
            NSBezierPath(rect: lineRect).fill()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
