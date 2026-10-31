// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

/// The keycap chip a button wears for its key equivalent: 22×22 at the
/// control radius for a single glyph ("←", "→", "⏎"), 44×20 for "SPACE", set
/// in `Tokens.Font.keycap`, no fill — a rim and a glyph over the button's own
/// face. A 2 pt inner bottom lip (`shadow` @ 0.25) drops to 1 pt and the
/// whole chip shifts down 1 pt while the button is pressed.
///
/// Drawn by the alignment wizard's plates (`AlignmentPlateCell`) and by
/// `CTAButton` when it is the window's Return default. The caller picks the
/// rect and the ink; the chip only paints.
///
/// **Coordinates are the flipped `NSButton` ones**: `NSButton.isFlipped` is
/// `true`, so the chip's visual bottom edge is `maxY` and a press moves it
/// toward `+y`.
public enum KeycapChip {

    /// The one wide keycap label; every other glyph draws at the narrow
    /// 22×22 size.
    public static let spaceGlyph = "SPACE"
    /// The chip's inset from the button's trailing edge in trailing placement.
    public static let trailingMargin: CGFloat = 14
    /// How far a press moves the chip down.
    public static let pressedShift: CGFloat = 1

    private static let narrowSide: CGFloat = 22
    private static let wideWidth: CGFloat = 44
    private static let wideHeight: CGFloat = 20
    /// The control radius, where iOS puts chips. On the 22×22 glyph chips that
    /// is a rounded square; on the 44×20 "SPACE" chip 10 is exactly half the
    /// height, so that one lands on a capsule. Left alone: it is the same
    /// radius, and the wide chip reading as a key is the point.
    private static let cornerRadius: CGFloat = Tokens.Layout.Radius.control
    /// 1 pt in points at 1x — the rim's width.
    private static let hairline: CGFloat = 1
    /// The rim's alpha over its glyph ink.
    private static let rimAlpha: CGFloat = 0.55
    private static let lipRestHeight: CGFloat = 2
    private static let lipPressedHeight: CGFloat = 1
    private static let lipAlpha: CGFloat = 0.25

    /// 44×20 for "SPACE", 22×22 for every other glyph.
    public static func size(for glyph: String) -> NSSize {
        glyph == spaceGlyph
            ? NSSize(width: wideWidth, height: wideHeight)
            : NSSize(width: narrowSide, height: narrowSide)
    }

    /// Trailing placement: `trailingMargin` in from the trailing edge,
    /// centred on the button's midline; a press shifts it visually DOWN
    /// (+y, flipped).
    public static func trailingRect(in frame: NSRect, size: NSSize, pressed: Bool) -> NSRect {
        var originY = frame.midY - size.height / 2
        if pressed { originY += pressedShift }
        return NSRect(x: (frame.maxX - trailingMargin - size.width).rounded(),
                      y: originY.rounded(), width: size.width, height: size.height)
    }

    /// Paints the lip, the rim (`ink` a step quieter) and `glyph` (`ink` at
    /// full strength) in `rect`, everything multiplied by `alpha`.
    public static func draw(_ glyph: String, in rect: NSRect, ink: NSColor, pressed: Bool, alpha: CGFloat) {
        let radius = cornerRadius
        let chipPath = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

        // Inner bottom lip (2 pt rest, 1 pt pressed) — the chip's own small
        // recess, drawn INSIDE the clip so it never bleeds past the corners.
        NSGraphicsContext.current?.saveGraphicsState()
        chipPath.addClip()
        let lipHeight = pressed ? lipPressedHeight : lipRestHeight
        Tokens.Color.shadow.withAlphaComponent(lipAlpha * alpha).setFill()
        // Flipped: the chip's visual bottom edge is `maxY`.
        NSRect(x: rect.minX, y: rect.maxY - lipHeight,
               width: rect.width, height: lipHeight).fill()
        NSGraphicsContext.current?.restoreGraphicsState()

        // Rim — the chip's ink, a step quieter than its glyph.
        ink.withAlphaComponent(rimAlpha * alpha).setStroke()
        let rimPath = NSBezierPath(
            roundedRect: rect.insetBy(dx: hairline / 2, dy: hairline / 2),
            xRadius: radius, yRadius: radius)
        rimPath.lineWidth = hairline
        rimPath.stroke()

        // Glyph — "electric on dark, Deep on light" (spec §2.1): the caller
        // resolved the tint; this is it at full strength.
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributed = NSAttributedString(string: glyph, attributes: [
            .font: Tokens.Font.keycap,
            .foregroundColor: ink.withAlphaComponent(alpha),
            .paragraphStyle: paragraph,
        ])
        let textSize = attributed.size()
        let textRect = NSRect(x: (rect.midX - textSize.width / 2).rounded(),
                              y: (rect.midY - textSize.height / 2).rounded(),
                              width: textSize.width, height: textSize.height)
        attributed.draw(in: textRect)
    }
}
