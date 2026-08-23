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
/// absent (`SetupRibbonView`), and the white-on-white still happens the moment
/// the Setup window resigns key to System Settings, which is exactly when the
/// user is looking at it.
///
/// Fix: track the window's key state and swap the title colour — ink over the
/// fill when key (forced white for the accent fill; measured white-or-black
/// when `picksInkFromFill` is on), `labelColor` (appearance-adaptive, legible
/// on the plain bezel in both light and dark) when not.
final class ProminentButton: NSButton {

    private let plainTitle: String
    /// The bezel fill this button was built with (`bezelColor` carries it).
    let fill: NSColor
    /// Whether the key-window title ink is MEASURED against the resolved fill
    /// (white or black, whichever contrasts more) instead of forced white.
    ///
    /// Forced white stays the default: it is the platform's convention for the
    /// accent fill, and a measured pick would flip a blue-accent button's ink
    /// to black (black measures fractionally higher on system blue), which
    /// reads off-platform. The `goldCTA` fill opts in: its four authored
    /// variants all measure white ≥5.5:1 (the token's rationale), so the
    /// measure PROVES the ink per appearance and Increase Contrast rather
    /// than assuming it.
    private let picksInkFromFill: Bool
    /// The title's font. `Tokens.Font.body` for the everyday Allow buttons;
    /// the finale CTA passes the emphasized weight for more presence.
    private let titleFont: NSFont
    private var keyStateObservers: [NSObjectProtocol] = []

    init(title: String, target: AnyObject?, action: Selector?,
         fill: NSColor = Tokens.Color.accent,
         picksInkFromFill: Bool = false,
         titleFont: NSFont = Tokens.Font.body) {
        self.plainTitle = title
        self.fill = fill
        self.picksInkFromFill = picksInkFromFill
        self.titleFont = titleFont
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        bezelStyle = .rounded
        controlSize = .regular
        bezelColor = fill
        setContentHuggingPriority(.required, for: .horizontal)
        if picksInkFromFill {
            // A measured ink is a STAMPED decision: the accent dial and
            // Increase Contrast change what `fill` resolves to without touching
            // `effectiveAppearance`, so each needs its own re-stamp trigger
            // (the forced-white default never moves, and needs neither).
            NotificationCenter.default.addObserver(
                self, selector: #selector(resolvedFillChanged),
                name: Tokens.accentStyleDidChangeNotification, object: nil)
            NSWorkspace.shared.notificationCenter.addObserver(
                self, selector: #selector(resolvedFillChanged),
                name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        }
        applyTitleColour()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Act on the click that ACTIVATES the app (v4 live fix, "Start listening
    /// took two clicks"). The Setup window's whole design bounces the user to
    /// System Settings and back; the last grant is often detected by the poll
    /// while the user is still IN Settings, and macOS's cooperative activation
    /// may decline our poll-driven re-front while another app is frontmost —
    /// so the user returns to an app that is NOT active, and a stock NSButton
    /// spends their first click activating the window (`acceptsFirstMouse`
    /// defaults to false for push buttons) and only presses on the second.
    /// A window that deliberately sends you away SHOULD act on the returning
    /// click, so every prominent button (the CTA and the card Allows, which
    /// live the same bounce loop) accepts it. `shouldDelayWindowOrdering`
    /// keeps its false default — we WANT the click to front the window too.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTitleColour()
    }

    deinit {
        keyStateObservers.forEach { NotificationCenter.default.removeObserver($0) }
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func resolvedFillChanged() { applyTitleColour() }

    private func applyTitleColour() {
        let colour: NSColor
        if window?.isKeyWindow ?? false {
            colour = picksInkFromFill ? measuredKeyInk() : .white
        } else {
            colour = Tokens.Color.label
        }
        attributedTitle = NSAttributedString(
            string: plainTitle,
            attributes: [.foregroundColor: colour,
                         .font: titleFont])
    }

    /// White or black over the RESOLVED fill, by WCAG contrast — except under
    /// the `.systemAccent` dial, where `gold` resolves to the live accent (an
    /// arbitrary hue the user picked) and forced white is the platform's own
    /// filled-accent convention, matching every other prominent button here.
    private func measuredKeyInk() -> NSColor {
        guard Tokens.accentStyle != .systemAccent else { return .white }
        var resolved = fill
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = fill.usingColorSpace(.sRGB) ?? resolved
        }
        guard let srgb = resolved.usingColorSpace(.sRGB) else { return .white }
        func linear(_ component: CGFloat) -> CGFloat {
            component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(srgb.redComponent)
            + 0.7152 * linear(srgb.greenComponent)
            + 0.0722 * linear(srgb.blueComponent)
        let whiteContrast = 1.05 / (luminance + 0.05)
        let blackContrast = (luminance + 0.05) / 0.05
        return whiteContrast >= blackContrast ? .white : .black
    }

    // MARK: Test-support hooks

    /// The key-window ink the measured pick resolves right now.
    var test_measuredKeyInk: NSColor { picksInkFromFill ? measuredKeyInk() : .white }
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
