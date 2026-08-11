// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterSharedUI

/// A GROUPED-SECTION container (the macOS System Settings idiom) — a rounded
/// `Tokens.Color.well` fill with a `Tokens.Color.hairline` border, plus an
/// inset hairline divider between each pair of ADJACENT rows handed to it.
///
/// It started life (T5) as the membership checklist's recessed background:
/// before it, the checklist carried no surface of its own at all —
/// `MembershipRowView` paints nothing behind itself — so there was zero visual
/// separation either between rows or against the pane (measured on the real
/// post-fix tones: `panel` vs `canvas` ~1.06:1 dark / ~1.08:1 light,
/// effectively invisible). Measured floors for THIS view's own tokens (WCAG
/// relative luminance, both ≥ their required floor — see
/// `MembershipWellContrastTests`): `well` vs `panel` 1.109:1 dark / 1.182:1
/// light (floor 1.10:1); `hairline` vs `panel` 1.404:1 dark / 1.309:1 light
/// (floor 1.25:1, the same separator floor `Tokens.Color.hairline` itself
/// documents against `panel`).
///
/// It is now the Groups window's ONE section shape, used by BOTH content panes
/// — the group editor's header + membership list, and the device detail pane's
/// metadata + "In groups" sections (design review 2026-07-25). Two stacked
/// sections with the rail threading out of the list up into the header mirrors
/// the popover's own composition: bounded sections, tied together by the spine.
/// It lives in its own file (rather than `private` inside the editor) precisely
/// so the detail pane can share it instead of growing a second look-alike.
///
/// The geometry, all of it load-bearing:
///
/// - **Spans the full column width**, gutter included, so the rail's nodes sit
///   INSIDE the section rather than floating beside it. Content within is inset
///   past the gutter (`contentLeadingInset`) so the spine keeps a clear lane.
/// - **Padded** top/bottom (`verticalPadding`) so content breathes instead of
///   touching the container's edges.
/// - **Inset dividers** starting at `contentLeadingInset` — the standard
///   grouped-list separator treatment, never full-bleed under the corners. A
///   section holding fewer than two rows draws none, which is what lets this
///   same view serve as the plain header container.
/// - **A visible border** plus a radius large enough to read as a shape; the
///   first draft's 6 pt radius rendered visually square.
///
/// `draw(_:)`-based, not a frozen layer color — `DeviceIconWellView`'s pattern:
/// every token re-resolves per appearance/Increase-Contrast on each paint, and
/// `viewDidChangeEffectiveAppearance` just triggers a repaint. Non-interactive
/// (`hitTest` always `nil`, `MembershipBusView`'s pattern) — it sits BEHIND the
/// content it backs in z-order, so no row/checkbox/rail click target is ever
/// affected; the dead area beside a narrower row simply swallows a click with
/// no target, same as clicking blank pane background anywhere else.
final class GroupedSectionView: NSView {
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
        // Stroke sits ON the boundary, so inset by half its width to keep the
        // 1pt line crisp instead of straddling the pixel edge.
        let borderRect = bounds.insetBy(dx: Self.borderWidth / 2, dy: Self.borderWidth / 2)
        let shape = NSBezierPath(roundedRect: borderRect,
                                 xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
        Tokens.Color.well.setFill()
        shape.fill()
        Tokens.Color.hairline.setStroke()
        shape.lineWidth = Self.borderWidth
        shape.stroke()

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
