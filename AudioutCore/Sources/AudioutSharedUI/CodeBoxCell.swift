// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

/// A code box's cell: a `well` fill inside a 1 pt `rim` edge on the control
/// radius, with the digit, caret and field editor centred vertically. A stock
/// single-line cell top-aligns its text, and a stock bezel's edge falls under
/// 3:1 against the sheet's own background. Used by the AirPlay code sheet's
/// four boxes and the licence gate's four key boxes.
public final class CodeBoxCell: NSTextFieldCell {
    public static let edgeWidth: CGFloat = 1

    /// The edge carries the box's 3:1 boundary; `rim` measures 4.38:1 on `well` in dark, 4.15:1 in light.
    public let drawsEdge = true

    public override init(textCell string: String) {
        super.init(textCell: string)
        isEditable = true
        isSelectable = true
        isBezeled = false
        isBordered = false
        drawsBackground = false
        alignment = .center
        usesSingleLineMode = true
        focusRingType = .default
    }

    public required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func centred(_ rect: NSRect) -> NSRect {
        guard let font else { return rect }
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        guard lineHeight < rect.height else { return rect }
        var r = rect
        r.origin.y += floor((rect.height - lineHeight) / 2)
        r.size.height = lineHeight
        return r
    }

    public override func drawingRect(forBounds rect: NSRect) -> NSRect {
        centred(super.drawingRect(forBounds: rect))
    }

    public override func titleRect(forBounds rect: NSRect) -> NSRect {
        centred(super.titleRect(forBounds: rect))
    }

    public override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
                       delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: centred(rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }

    public override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
                         delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: centred(rect), in: controlView, editor: textObj, delegate: delegate,
                     start: selStart, length: selLength)
    }

    private func boxPath(_ frame: NSRect) -> NSBezierPath {
        let inset = Self.edgeWidth / 2
        let radius = Tokens.Layout.Radius.control
        return NSBezierPath(roundedRect: frame.insetBy(dx: inset, dy: inset), xRadius: radius, yRadius: radius)
    }

    public override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        let path = boxPath(cellFrame)
        Tokens.Color.well.setFill()
        path.fill()
        Tokens.Color.rim.setStroke()
        path.lineWidth = Self.edgeWidth
        path.stroke()
        drawInterior(withFrame: cellFrame, in: controlView)
    }

    public override func focusRingMaskBounds(forFrame cellFrame: NSRect, in controlView: NSView) -> NSRect {
        cellFrame
    }

    public override func drawFocusRingMask(withFrame cellFrame: NSRect, in controlView: NSView) {
        boxPath(cellFrame).fill()
    }
}
