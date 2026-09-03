// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

/// The **inline rename field's skin** — a DRAWING-ONLY `NSTextFieldCell`
/// subclass installed on the Groups window's group-name field, exactly the way
/// `WarmFaderCell` skins the row sliders and `InvisibleSwitchCell` skins the
/// membership checkbox: the host swaps the cell in FIRST and then configures
/// the field, so every behaviour — first responder, Return/Escape, the field
/// editor, selection, VoiceOver, target/action — stays stock `NSTextField`.
/// Nothing here touches editing; it only paints.
///
/// What it draws:
/// - **Fill** `Tokens.Color.raised` — the same surface the icon well beside it
///   is filled with, so the two halves of the header band read as one pair of
///   controls rather than a control and a bare string.
/// - **Border** `Tokens.Color.containerEdge` at `borderWidth` (1 pt) — the
///   field's fill is `raised`, and `hairline` is never drawn on `raised`
///   (1.154:1 dark); `containerEdge` measures 1.55:1 on it in dark and 2.02:1
///   on the flat light ground, where it is the whole field.
/// - **Hover wash** `Tokens.Color.label` at
///   `PopoverColumnGrid.rowHoverWashAlpha` — byte-identical to the icon well's
///   highlighted state (spec §4.8: hover is a neutral wash, never gold, and
///   never moves geometry — R7).
/// - **A trailing `pencil` SF Symbol** at `PopoverColumnGrid
///   .editAffordanceRestAlpha`, stepping to `editAffordanceHoverAlpha` under
///   the pointer — the same two alphas the icon well's corner badge uses, so
///   the header's two edit cues can't drift. It is HIDDEN while the field is
///   being edited: the caret is the affordance then, and at the end of a long
///   name the glyph and the caret collide.
///
/// The TEXT is untouched — no colour, no font, no alignment is set here; the
/// host owns those and the Groups window's text colours are frozen to stock
/// AppKit semantics (`AudioutWindowUI/AGENTS.md`). Only the box around the
/// text is ours.
///
/// Everything resolves inside `draw(withFrame:in:)`, never a frozen layer
/// colour, so light/dark and Increase Contrast re-resolve on every paint
/// (`WarmFaderCell`/`DeviceIconWellView`'s pattern). The drawing is steady
/// state — no animation, no layers — so `cacheDisplay` snapshots stay
/// byte-deterministic.
public final class WarmNameFieldCell: NSTextFieldCell {

    // MARK: Geometry

    /// Inset from the field's leading edge to the first glyph of the name.
    public static let textInsetLeading: CGFloat = 8
    /// Inset from the field's trailing edge to the last glyph of the name —
    /// wide enough to clear the pencil (its own `pencilTrailingInset` plus the
    /// glyph plus a gap), so a long name truncates BEFORE it reaches the
    /// affordance instead of running under it.
    public static let textInsetTrailing: CGFloat = 26
    /// Inset from the field's trailing edge to the pencil's trailing edge.
    public static let pencilTrailingInset: CGFloat = 8
    /// SF-Symbol point size of the trailing pencil.
    public static let pencilPointSize: CGFloat = 11
    /// Width of the field's border — matches `DeviceIconWellView`'s resting
    /// hairline edge, so the two header controls are edged identically.
    public static let borderWidth: CGFloat = 1

    // MARK: Host-driven state

    /// True while the pointer is over the field. Set by the HOST (the field is
    /// a stock `NSTextField` and owns no tracking area of its own); drives the
    /// neutral hover wash and the pencil's alpha step-up. Drawing-only — it
    /// changes no geometry, so hover never reflows the header (R7).
    public var isHovered: Bool = false

    // MARK: Text insets
    //
    // `drawingRect(forBounds:)` is the single seam AppKit routes BOTH the drawn
    // text and the field editor's frame through, so insetting here indents the
    // resting string and the caret identically — no separate `select`/`edit`
    // override (which would inset a second time on top of this one).

    public override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let band = super.drawingRect(forBounds: Self.textRect(in: rect))
        // VERTICALLY CENTRE the text in the box. `NSTextFieldCell` lays a
        // single line out at the TOP of whatever rect it's handed, so the name
        // sat ~4pt high in its own 28pt field — visibly off against the icon
        // well beside it (design review 2026-07-25). Insetting symmetrically
        // is flip-agnostic, so this holds whichever way the host view's
        // coordinate system runs.
        guard let font else { return band }
        let line = NSLayoutManager().defaultLineHeight(for: font)
        guard band.height > line else { return band }
        return band.insetBy(dx: 0, dy: ((band.height - line) / 2).rounded(.down))
    }

    /// The horizontal band the text lives in, inside the drawn box.
    static func textRect(in rect: NSRect) -> NSRect {
        NSRect(x: rect.minX + textInsetLeading,
               y: rect.minY,
               width: max(0, rect.width - textInsetLeading - textInsetTrailing),
               height: rect.height)
    }

    // MARK: Drawing

    public override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        // Stroke sits ON the boundary, so inset by half its width to keep the
        // 1 pt line crisp rather than straddling the pixel edge
        // (`GroupedSectionView`/`DeviceIconWellView`'s idiom).
        let boxRect = cellFrame.insetBy(dx: Self.borderWidth / 2, dy: Self.borderWidth / 2)
        let box = NSBezierPath(roundedRect: boxRect,
                               xRadius: PopoverColumnGrid.titleFieldCornerRadius,
                               yRadius: PopoverColumnGrid.titleFieldCornerRadius)

        Tokens.Color.raised.setFill()
        box.fill()

        if isHovered {
            // Neutral wash only, never gold (§4.8) — the exact fill
            // `DeviceIconWellView` paints while highlighted.
            Tokens.Color.label.withAlphaComponent(PopoverColumnGrid.rowHoverWashAlpha).setFill()
            box.fill()
        }

        Tokens.Color.containerEdge.setStroke()
        box.lineWidth = Self.borderWidth
        box.stroke()

        // The text (and, while editing, nothing — the field editor draws it).
        super.draw(withFrame: cellFrame, in: controlView)

        if Self.showsPencil(in: controlView) {
            drawPencil(in: cellFrame, controlView: controlView)
        }
    }

    /// The pencil is the REST-state affordance: it says "this name is
    /// editable" the way the icon well's corner badge says "this icon is."
    /// While the field is actually being edited the caret carries that meaning
    /// instead, and the glyph would collide with it at the end of a long name.
    static func showsPencil(in controlView: NSView) -> Bool {
        (controlView as? NSControl)?.currentEditor() == nil
    }

    private func drawPencil(in cellFrame: NSRect, controlView: NSView) {
        guard let pencil = Self.pencilImage else { return }
        let size = pencil.size
        let rect = NSRect(x: cellFrame.maxX - Self.pencilTrailingInset - size.width,
                          y: (cellFrame.midY - size.height / 2).rounded(),
                          width: size.width,
                          height: size.height)
        // Tint by compositing INSIDE an offscreen image: a `sourceAtop` fill
        // straight onto this context would also repaint the opaque `raised`
        // fill we just drew. The handler runs synchronously inside this draw,
        // so `secondaryLabel` still resolves under the live appearance.
        let tint = Tokens.Color.secondaryLabel
        let tinted = NSImage(size: size, flipped: false) { bounds in
            pencil.draw(in: bounds)
            tint.setFill()
            bounds.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: rect, from: .zero, operation: .sourceOver,
                    fraction: isHovered ? PopoverColumnGrid.editAffordanceHoverAlpha
                                        : PopoverColumnGrid.editAffordanceRestAlpha,
                    respectFlipped: true, hints: nil)
    }

    /// The stock `pencil` SF Symbol at `pencilPointSize`, as a template so the
    /// tint above is the only colour it ever carries.
    private static let pencilImage: NSImage? = {
        let image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: pencilPointSize, weight: .regular))
        image?.isTemplate = true
        return image
    }()

    /// Trace the drawn box so AppKit's own focus ring hugs the visible field
    /// instead of the bare text (this cell is bezel-less — without a mask
    /// AppKit has no shape to ring). The ring itself is still entirely
    /// AppKit's: nothing here draws it.
    public override func drawFocusRingMask(withFrame cellFrame: NSRect, in controlView: NSView) {
        NSBezierPath(roundedRect: cellFrame,
                     xRadius: PopoverColumnGrid.titleFieldCornerRadius,
                     yRadius: PopoverColumnGrid.titleFieldCornerRadius).fill()
    }

    // MARK: Test-support hooks

    /// Whether the trailing pencil would be painted right now for `controlView`
    /// — the exact gate `draw(withFrame:in:)` uses, so a test can't drift from
    /// the pixels.
    public func test_showsPencil(in controlView: NSView) -> Bool {
        Self.showsPencil(in: controlView)
    }
}
