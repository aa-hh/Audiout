// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore
import AudioutSharedUI

/// Shared action button for the Setup window's cards. `prominent` tints the
/// bezel with the accent color (the "please do this" CTA — see
/// ``ProminentButton`` for the AppKit bug that class exists to fix); plain is
/// the quieter secondary button (Skip). Only ONE card is expanded at a time
/// now, so the prominent Allow IS the window's Return-default while Done
/// doesn't exist yet — the caller sets `keyEquivalent`, not this helper.
func onboardingActionButton(title: String, prominent: Bool,
                            target: AnyObject, action: Selector) -> NSButton {
    if prominent {
        let button = ProminentButton(title: title, target: target, action: action)
        // The card's Allow slot constrains the button directly (it is not inside
        // a stack view, which would turn this off for us) — left on, AutoLayout
        // synthesises width/height from the zero frame and the button renders as
        // nothing at all.
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }
    let button = NSButton(title: title, target: target, action: action)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.bezelStyle = .rounded
    // Plain bordered, `.small`: Skip sits beside a regular-size Allow and must
    // stay visibly the quieter of the two. AppKit's own inactive-window
    // handling applies unchanged.
    button.controlSize = .small
    button.setContentHuggingPriority(.required, for: .horizontal)
    return button
}

/// Blend two colours WITHOUT flattening either of them to one appearance.
///
/// `NSColor.blended(withFraction:of:)` resolves both operands immediately, so
/// calling it on a dynamic token outside a drawing appearance freezes whichever
/// appearance happened to be current — which is how the active row's rim came
/// out at 1.13:1 in dark (`Tokens.Color.label.withAlphaComponent(0.18)`, the
/// critique's measured P1). Wrapping the blend in a dynamic provider defers it:
/// each appearance blends its OWN resolved operands when it draws.
///
/// **Rule for this folder: never call `withAlphaComponent` or `blended` on a
/// dynamic colour outside a drawing appearance.** Route it through here.
func dynamicBlend(_ base: NSColor, fraction: CGFloat, of other: NSColor) -> NSColor {
    NSColor(name: nil) { appearance in
        var blended = base
        appearance.performAsCurrentDrawingAppearance {
            blended = base.blended(withFraction: fraction, of: other) ?? base
        }
        return blended
    }
}

/// The official Bluetooth rune, from stock AppKit
/// (`NSImage.bluetoothTemplateName` — SF Symbols carries no Bluetooth glyph;
/// this named template is the system's own mark). Template, so an
/// `NSImageView`'s `contentTintColor` tints it like a symbol.
///
/// Returns a COPY rescaled to `height` (the original is 16 × 21 pt):
/// `NSImage(named:)` hands back the SHARED cache entry, so resizing it in
/// place would resize it for every other user of the name.
///
/// Optional rather than force-unwrapped even though this name has shipped
/// since 10.5: a named system asset going missing on some future macOS would
/// otherwise crash the FIRST screen a new user sees. Both call sites already
/// degrade — the setup row falls back to its `symbolName`, the demo mock to a
/// bare tile.
func bluetoothRuneImage(height: CGFloat) -> NSImage? {
    guard let rune = NSImage(named: NSImage.bluetoothTemplateName)?.copy() as? NSImage,
          rune.size.height > 0 else { return nil }
    rune.size = NSSize(width: rune.size.width * height / rune.size.height,
                       height: height)
    return rune
}

// MARK: - Appearance-adaptive rounded views

/// A small rounded tile holding an SF Symbol. Every onboarding tile rests on
/// the same neutral `Tokens.Color.raised` well with a `containerEdge` rim (Q3
/// of the colour-return pass — the FILL/RIM are never coloured, only the
/// glyph). A tile's own edge is always `containerEdge`; `hairline` is never
/// drawn on `raised`, where it measures 1.154:1 and disappears. The Groups
/// window's device seats (`MemberChipView`,
/// `DeviceIconWellView`) draw that same edge on the same well, tuned for a
/// `label` glyph rather than a permission hue;
/// the SYMBOL's tint is caller-supplied (`color`, one of the four
/// `Tokens.Color.permission*` hues for the onboarding rows) and PERMANENT —
/// granting never recolours it (Alec, 2026-08-11: the retired
/// grant-goes-gold crossfade duplicated the "Allowed"/checkmark status the
/// row already shows, which alone carries the state).
///
/// Layer-backed and repainted in `updateLayer`, where the view's
/// `effectiveAppearance` is the current drawing appearance, so the warm
/// tokens resolve correctly in light and dark (and Increase Contrast).
final class IconTileView: NSView {

    private let radius: CGFloat
    /// Default chip side. Both real call sites pass their own smaller one (a
    /// permission card, and the Settings mock's app row), so this is the size a
    /// caller gets when it doesn't care.
    static let side: CGFloat = 30

    private let symbolImage = NSImageView()

    /// `customImage` overrides the symbol lookup for glyphs SF Symbols doesn't
    /// ship (Bluetooth's rune). Must be a template image — the tile tints it
    /// with `color` exactly like a symbol.
    ///
    /// `cornerRadius` defaults to the control rung, which is what the iPhone
    /// companion rounds its own glyph tile at (`AppGlyph.swift:51` in
    /// audiout-remote), so the two apps' tiles are the same shape.
    init(symbolName: String,
         customImage: NSImage? = nil,
         accessibility: String,
         color: NSColor = Tokens.Color.label2,
         side: CGFloat = IconTileView.side,
         pointSize: CGFloat = 15,
         cornerRadius: CGFloat = Tokens.Layout.Radius.control) {
        self.radius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        if let customImage {
            customImage.accessibilityDescription = accessibility
            symbolImage.image = customImage
        } else {
            symbolImage.image = NSImage(systemSymbolName: symbolName,
                                        accessibilityDescription: accessibility)
        }
        symbolImage.symbolConfiguration = .init(pointSize: pointSize, weight: .semibold)
        symbolImage.contentTintColor = color
        symbolImage.translatesAutoresizingMaskIntoConstraints = false
        addSubview(symbolImage)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: side),
            heightAnchor.constraint(equalToConstant: side),
            symbolImage.centerXAnchor.constraint(equalTo: centerXAnchor),
            symbolImage.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Tokens.Color.raised.cgColor
        layer?.borderColor = Tokens.Color.containerEdge.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
    }

    // MARK: Test-support hooks

    /// The glyph tint — the row's `iconColor` (Q1/Q3), permanent across
    /// every card state.
    var test_restingTint: NSColor? { symbolImage.contentTintColor }

    /// The tile's own FILL colour — asserted elsewhere to confirm Q3 (the
    /// tile fill/rim never colour, only the glyph does) held across this wave.
    var test_fillColor: NSColor? {
        guard let cg = layer?.backgroundColor else { return nil }
        return NSColor(cgColor: cg)
    }
}

/// A rounded rectangle with an appearance-adaptive fill and hairline border —
/// the System Settings grouped inset-list container, defaulting to the Warm
/// Signal `panel` card fill + `hairline` rim (spec §1/§5.8) so the permission
/// card reads as the app's own themed card, not the system's plain one.
/// Children (the permission rows + hairline separators) are laid out by the caller.
/// The fill/border are settable rather than fixed at init: a permission card
/// re-tints its own surface to mark which step is the live one (see
/// `SetupSpineRowView.applySurface`), so this has to be re-stampable after the fact.
final class RoundedContainerView: NSView {

    var fill: NSColor { didSet { needsDisplay = true } }
    var border: NSColor { didSet { needsDisplay = true } }
    var borderWidth: CGFloat = 1 { didSet { needsDisplay = true } }
    private let radius: CGFloat

    init(fill: NSColor = Tokens.Color.panel,
         border: NSColor = Tokens.Color.hairline,
         radius: CGFloat = Tokens.Layout.groupedSectionCornerRadius) {
        self.fill = fill
        self.border = border
        self.radius = radius
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = fill.cgColor
        layer?.borderColor = border.cgColor
        layer?.borderWidth = borderWidth
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
    }
}
