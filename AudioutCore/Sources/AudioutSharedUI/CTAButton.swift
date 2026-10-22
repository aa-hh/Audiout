// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

/// The iPhone's `GoldCTALabel` face on the Mac: a flat 200 x 44 pt button on
/// the control radius, its title centred. `.primary` is the gold one, the
/// licence gate's "Buy Audiout"; `.secondary` is the raised one with a
/// `pendingGlow` edge, the gate's trial offer.
///
/// Only the paint is custom (``CTAButtonCell``): tracking, key equivalents,
/// `performClick` and VoiceOver are the stock `NSButton`'s. The fill is drawn
/// flat rather than set as `bezelColor`, so it does not drop to a plain bezel
/// when the window is not key, and every colour is resolved at draw time.
public final class CTAButton: NSButton {

    public enum Style: Sendable { case primary, secondary }

    public static let width: CGFloat = 200
    public static let height: CGFloat = 44

    public let style: Style

    public init(title: String, style: Style, target: AnyObject?, action: Selector?) {
        self.style = style
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height))
        cell = CTAButtonCell(style: style)
        setButtonType(.momentaryPushIn)
        self.title = title
        self.target = target
        self.action = action
        font = style == .primary ? Tokens.Font.heading : Tokens.Font.body
        focusRingType = .default
        for orientation in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            setContentHuggingPriority(.required, for: orientation)
            setContentCompressionResistancePriority(.required, for: orientation)
        }
        redrawOnAccessibilityDisplayChange()
        NotificationCenter.default.addObserver(
            self, selector: #selector(accentStyleChanged),
            name: Tokens.accentStyleDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func accentStyleChanged() { needsDisplay = true }

    public override var intrinsicContentSize: NSSize { NSSize(width: Self.width, height: Self.height) }

    /// The face fills the whole frame; a stock push button's bezel insets
    /// would make the laid-out frame bigger than the 200 x 44 the face draws.
    public override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    /// Act on the click that activates the app, as `ProminentButton` does.
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// ``CTAButton``'s paint. A drawing-only cell, as `CodeBoxCell` is: the
/// fill, the edge and the title change, nothing else does.
public final class CTAButtonCell: NSButtonCell {

    public static let edgeWidth: CGFloat = 1

    public let style: CTAButton.Style

    init(style: CTAButton.Style) {
        self.style = style
        super.init(textCell: "")
        isBordered = false
    }

    public required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The face's fill for the current state, resolved in the current drawing
    /// appearance. The primary's gold is `gold`'s dark value in both
    /// appearances (`ProminentButton.pinnedDark`); pressed blends it 12 %
    /// toward black. The secondary's `raised` blends 8 % toward `label`.
    public var fill: NSColor {
        switch style {
        case .primary:
            guard isEnabled else { return Tokens.Color.well }
            let gold = ProminentButton.pinnedDark(Tokens.Color.gold)
            return isHighlighted ? Self.mix(gold, .black, 0.12) : gold
        case .secondary:
            let raised = Tokens.Color.raised
            return isEnabled && isHighlighted ? Self.mix(raised, Tokens.Color.label, 0.08) : raised
        }
    }

    public var ink: NSColor {
        switch style {
        case .primary: return isEnabled ? ProminentButton.pinnedDark(Tokens.Color.inkOnFill) : Tokens.Color.labelCool2
        case .secondary: return isEnabled ? Tokens.Color.label : Tokens.Color.label3
        }
    }

    /// The 1 pt inside edge: the secondary's only.
    public var edge: NSColor? { style == .secondary ? Tokens.Color.pendingGlow : nil }

    private static func mix(_ base: NSColor, _ other: NSColor, _ fraction: CGFloat) -> NSColor {
        guard let a = base.usingColorSpace(.sRGB), let b = other.usingColorSpace(.sRGB) else { return base }
        return a.blended(withFraction: fraction, of: b) ?? a
    }

    private func facePath(_ frame: NSRect) -> NSBezierPath {
        let inset = edge == nil ? 0 : Self.edgeWidth / 2
        let radius = Tokens.Layout.Radius.control
        return NSBezierPath(roundedRect: frame.insetBy(dx: inset, dy: inset), xRadius: radius, yRadius: radius)
    }

    public override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        let path = facePath(cellFrame)
        fill.setFill()
        path.fill()
        if let edge {
            edge.setStroke()
            path.lineWidth = Self.edgeWidth
            path.stroke()
        }
        let text = NSAttributedString(string: title, attributes: [
            .font: font ?? Tokens.Font.body, .foregroundColor: ink])
        let size = text.size()
        text.draw(at: NSPoint(x: floor(cellFrame.midX - size.width / 2),
                              y: floor(cellFrame.midY - size.height / 2)))
    }

    public override func focusRingMaskBounds(forFrame cellFrame: NSRect, in controlView: NSView) -> NSRect {
        cellFrame
    }

    public override func drawFocusRingMask(withFrame cellFrame: NSRect, in controlView: NSView) {
        facePath(cellFrame).fill()
    }
}
