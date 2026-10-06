// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

/// The ground of an inset notice card: its tint at
/// `PopoverColumnGrid.insetCardTintAlpha` over whatever sits behind, on the
/// control radius, with no edge, except a 1 pt edge in the full tint under
/// Increase Contrast, where the 12 % fill alone barely separates the card from
/// the ground. Content goes in as subviews, or a card subclasses it.
///
/// Tints in use: `ring` for a note, `failure` for a warning or a failed
/// connection, `gold` for the thank-you card.
///
/// Layer colours are frozen `CGColor`s, so they are restamped under the view's
/// own appearance on every appearance change and on the Increase Contrast
/// toggle, which fires no appearance change.
open class TintedNoteBackgroundView: NSView {

    public var tint: NSColor {
        didSet { stampLayerColors() }
    }

    public init(tint: NSColor) {
        self.tint = tint
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Tokens.Layout.Radius.control
        layer?.cornerCurve = .continuous
        stampLayerColors()
        redrawOnAccessibilityDisplayChange()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Without it AppKit takes the `draw(_:)` path and `updateLayer()` never
    /// runs, so the restamp below would sit dead.
    open override var wantsUpdateLayer: Bool { true }

    open override func updateLayer() {
        super.updateLayer()
        stampLayerColors()
    }

    open override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        stampLayerColors()
    }

    /// The one place the tint is resolved and stamped.
    public func stampLayerColors(
        increaseContrast: Bool = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    ) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = tint.withAlphaComponent(PopoverColumnGrid.insetCardTintAlpha).cgColor
            layer?.borderColor = tint.cgColor
        }
        layer?.borderWidth = increaseContrast ? 1 : 0
    }

    /// The stamped fill, read back as `NSColor`.
    public var test_backgroundColor: NSColor? {
        guard let cgColor = layer?.backgroundColor else { return nil }
        return NSColor(cgColor: cgColor)
    }
}
