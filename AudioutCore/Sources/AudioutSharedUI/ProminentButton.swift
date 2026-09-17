// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

// MARK: - Prominent (gold-filled) button

/// A gold-filled push button (`bezelColor`) whose title stays legible whether
/// or not its window is key.
///
/// One rule for the whole app, and not a per-call choice: every call to
/// action is the light brand gold with dark ink, in BOTH appearances — the
/// owner's "one gold everywhere" ruling (2026-08-24, restated 2026-09-13), the
/// same pin `AlignmentPlateCell.primaryFillColor` uses. ``fill`` and
/// ``ink`` are `Tokens.Color.gold` and `Tokens.Color.inkOnFill` resolved once
/// under `.darkAqua`: `#E8B84B` with `#171104`, 10.18:1. Light `gold` has been
/// the same hex since 2026-09-17, but its Increase Contrast value is still the
/// deep `#8A6614`, which the `.rounded` bezel shades down to a muddy olive that
/// dark ink cannot read on; a deepened gold with white ink is the retired
/// "dark mustard" and is NOT an official gold.
/// Both are still read from Tokens, so the accent dial and Increase Contrast
/// reach them.
///
/// The bug this exists to fix (ahh, deselecting the setup window): AppKit drops
/// a `bezelColor` fill to a plain bezel when the window resigns key — correct,
/// that's how macOS de-emphasises controls in inactive windows — but, UNLIKE a
/// true default button, it does NOT recolor the title to match. An ink authored
/// for the fill is not authored for the plain bezel: the pinned dark ink goes
/// dark-on-dark there in dark mode, so the button reads as an empty pill.
/// Being made the Return-default doesn't fix it either — the sequential flow
/// DOES make the one live Allow the default while Done is absent
/// (`SetupRibbonView`), and it still happens the moment the Setup window
/// resigns key to System Settings, which is exactly when the user is looking
/// at it.
///
/// Fix: track the window's key state and swap the title colour — ``ink`` over
/// the fill when key, `Tokens.Color.label` (appearance-adaptive, legible on the
/// plain bezel in both light and dark) when not.
public final class ProminentButton: NSButton {

    private let plainTitle: String
    /// The bezel fill (`bezelColor` carries it): `gold`'s dark value, pinned in
    /// both appearances — see the type doc. Public so a caller can prove the
    /// button is the gold one (`OnboardingViewController`'s CTA check).
    /// Resolved on every read, so an accent-dial change reaches a button already
    /// on screen (re-applied from `accentStyleDidChangeNotification`).
    public var fill: NSColor { Self.pinnedDark(Tokens.Color.gold) }
    /// The key-window title ink, pinned with the fill (`inkOnFill` goes white
    /// under light Increase Contrast, which reads 1.84:1 on `#E8B84B`).
    private var ink: NSColor { Self.pinnedDark(Tokens.Color.inkOnFill) }

    /// `color` resolved once under `.darkAqua`.
    private static func pinnedDark(_ color: NSColor) -> NSColor {
        var resolved = color
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? color
        }
        return resolved
    }
    /// The title's font. `Tokens.Font.body` for the everyday Allow buttons;
    /// the finale CTA passes the emphasized weight for more presence.
    private let titleFont: NSFont
    private var keyStateObservers: [NSObjectProtocol] = []

    public init(title: String, target: AnyObject?, action: Selector?,
                titleFont: NSFont = Tokens.Font.body) {
        self.plainTitle = title
        self.titleFont = titleFont
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        bezelStyle = .rounded
        controlSize = .regular
        setContentHuggingPriority(.required, for: .horizontal)
        applyColours()
        NotificationCenter.default.addObserver(
            self, selector: #selector(accentStyleChanged),
            name: Tokens.accentStyleDidChangeNotification, object: nil)
    }

    @objc private func accentStyleChanged() { applyColours() }

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
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func viewDidMoveToWindow() {
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

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColours()
    }

    deinit {
        keyStateObservers.forEach { NotificationCenter.default.removeObserver($0) }
        NotificationCenter.default.removeObserver(self)
    }

    /// Fill and title together, so Increase Contrast and the accent dial land
    /// on both at once.
    private func applyColours() {
        bezelColor = fill
        applyTitleColour()
    }

    private func applyTitleColour() {
        let isKey = window?.isKeyWindow ?? false
        attributedTitle = NSAttributedString(
            string: plainTitle,
            attributes: [.foregroundColor: isKey ? ink : Tokens.Color.label,
                         .font: titleFont])
    }
}
