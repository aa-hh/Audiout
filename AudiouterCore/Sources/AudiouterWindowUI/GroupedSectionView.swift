// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterSharedUI

/// The Groups screen's ONE container shape (the macOS System Settings grouped
/// idiom), in two modes.
///
/// - ``Style/card`` — the page's ONE INSTRUMENT: a rounded
///   `Tokens.Color.raised` fill with a 1 pt `Tokens.Color.hairline` edge. On
///   dark, `raised` against the pane's `panel` measures 1.07:1 — below the
///   surface floor — so the EDGE, not the fill, is what carries the
///   separation (`hairline` vs `raised`: 1.31:1 dark / 1.40:1 light,
///   `MembershipWellContrastTests`). Exactly one card per page: the Equalizer
///   on the two detail pages, the Speakers checklist in the group editor.
/// - ``Style/bare`` — a DIVIDER-ONLY list: no fill, no border, just the inset
///   hairlines between rows. The Settings-rows idiom, and what every other
///   list on these pages wears (Groups, About, and the header bands).
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
        /// The page's one instrument: `raised` fill + a `hairline` edge.
        case card
        /// A divider-only list: no fill, no border.
        case bare
    }

    /// Defaults to ``Style/card`` so a section is a card unless a page says
    /// otherwise — there is at most one per page, and it is the loud one.
    var style: Style = .card { didSet { needsDisplay = true } }

    /// Large enough to read as a rounded shape at this container's size — the
    /// 6 pt first draft rendered visually square. Same value as onboarding's
    /// `RoundedContainerView` (both model the System Settings grouped
    /// inset-list look), so it's sourced from `Tokens.Layout.groupedSectionCornerRadius`.
    static let cornerRadius: CGFloat = Tokens.Layout.groupedSectionCornerRadius
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
        if case .card = style {
            // Stroke sits ON the boundary, so inset by half its width to keep
            // the 1pt line crisp instead of straddling the pixel edge.
            let borderRect = bounds.insetBy(dx: Self.borderWidth / 2, dy: Self.borderWidth / 2)
            let shape = NSBezierPath(roundedRect: borderRect,
                                     xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
            Tokens.Color.raised.setFill()
            shape.fill()
            Tokens.Color.hairline.setStroke()
            shape.lineWidth = Self.borderWidth
            shape.stroke()
        }

        guard rows.count > 1 else { return }
        Tokens.Color.hairline.setFill()
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
