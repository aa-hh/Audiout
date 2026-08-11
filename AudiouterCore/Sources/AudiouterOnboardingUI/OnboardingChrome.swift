// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterCore
import AudiouterSharedUI

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

// MARK: - Prominent (accent-filled) button

/// An accent-filled push button (`bezelColor`) whose title stays legible whether
/// or not its window is key.
///
/// The bug this exists to fix (ahh, deselecting the setup window): AppKit drops
/// a `bezelColor` fill to a plain bezel when the window resigns key — correct,
/// that's how macOS de-emphasises controls in inactive windows — but, UNLIKE a
/// true default button, it does NOT recolor the title to match. So a
/// forced-white title (needed for contrast over the accent fill while active)
/// turns white-on-white the moment the window loses key, and the button reads as
/// an empty pill. Being made the Return-default doesn't fix it either — the
/// sequential flow DOES make the one live Allow the default while Done is
/// absent (`SetupCardView`), and the white-on-white still happens the moment
/// the Setup window resigns key to System Settings, which is exactly when the
/// user is looking at it.
///
/// Fix: track the window's key state and swap the title colour — white over the
/// accent fill when key, `labelColor` (appearance-adaptive, legible on the plain
/// bezel in both light and dark) when not.
final class ProminentButton: NSButton {

    private let plainTitle: String
    private var keyStateObservers: [NSObjectProtocol] = []

    init(title: String, target: AnyObject?, action: Selector?) {
        self.plainTitle = title
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        bezelStyle = .rounded
        controlSize = .regular
        bezelColor = Tokens.Color.accent
        setContentHuggingPriority(.required, for: .horizontal)
        applyTitleColour()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        keyStateObservers.forEach { NotificationCenter.default.removeObserver($0) }
        keyStateObservers.removeAll()
        if let window = window {
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                keyStateObservers.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main) { [weak self] _ in
                    self?.applyTitleColour()
                })
            }
        }
        applyTitleColour()
    }

    deinit { keyStateObservers.forEach { NotificationCenter.default.removeObserver($0) } }

    private func applyTitleColour() {
        let colour: NSColor = (window?.isKeyWindow ?? false) ? .white : Tokens.Color.label
        attributedTitle = NSAttributedString(
            string: plainTitle,
            attributes: [.foregroundColor: colour,
                         .font: Tokens.Font.body])
    }
}

// MARK: - Appearance-adaptive rounded views

/// A small rounded tile holding an SF Symbol. Every tile rests on the same
/// neutral `Tokens.Color.raised` well with a hairline rim (Q3 of the
/// colour-return pass — the FILL/RIM are never coloured, only the glyph);
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

    init(symbolName: String,
         accessibility: String,
         color: NSColor = Tokens.Color.secondaryLabel,
         side: CGFloat = IconTileView.side,
         pointSize: CGFloat = 15,
         cornerRadius: CGFloat = 7) {
        self.radius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        symbolImage.image = NSImage(systemSymbolName: symbolName,
                                    accessibilityDescription: accessibility)
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
        layer?.borderColor = Tokens.Color.hairline.cgColor
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
/// card reads as a warm card on the warm canvas. Children (the permission
/// rows + hairline separators) are laid out by the caller.
/// The fill/border are settable rather than fixed at init: a permission card
/// re-tints its own surface to mark which step is the live one (see
/// `SetupCardView.applySurface`), so this has to be re-stampable after the fact.
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
