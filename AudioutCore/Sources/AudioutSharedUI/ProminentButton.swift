// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

// MARK: - Prominent (gold-filled) button

/// A gold-filled push button (`bezelColor`) whose title stays legible whether
/// or not its window is key.
///
/// One rule for the whole app: every call to action is `Tokens.Color.gold`
/// fill with `Tokens.Color.inkOnFill` ink.
///
/// The bug this exists to fix (ahh, deselecting the setup window): AppKit drops
/// a `bezelColor` fill to a plain bezel when the window resigns key — correct,
/// that's how macOS de-emphasises controls in inactive windows — but, UNLIKE a
/// true default button, it does NOT recolor the title to match. An ink authored
/// for the fill is not authored for the plain bezel: `inkOnFill` goes
/// dark-on-dark there in dark mode, and white-on-white in light Increase
/// Contrast where it flips to white, so the button reads as an empty pill.
/// Being made the Return-default doesn't fix it either — the sequential flow
/// DOES make the one live Allow the default while Done is absent
/// (`SetupRibbonView`), and it still happens the moment the Setup window
/// resigns key to System Settings, which is exactly when the user is looking
/// at it.
///
/// Fix: track the window's key state and swap the title colour — `inkOnFill`
/// over the fill when key, `Tokens.Color.label` (appearance-adaptive, legible
/// on the plain bezel in both light and dark) when not.
public final class ProminentButton: NSButton {

    private let plainTitle: String
    /// The bezel fill this button was built with (`bezelColor` carries it).
    public let fill: NSColor
    /// The title's font. `Tokens.Font.body` for the everyday Allow buttons;
    /// the finale CTA passes the emphasized weight for more presence.
    private let titleFont: NSFont
    private var keyStateObservers: [NSObjectProtocol] = []

    public init(title: String, target: AnyObject?, action: Selector?,
                fill: NSColor = Tokens.Color.gold,
                titleFont: NSFont = Tokens.Font.body) {
        self.plainTitle = title
        self.fill = fill
        self.titleFont = titleFont
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        bezelStyle = .rounded
        controlSize = .regular
        bezelColor = fill
        setContentHuggingPriority(.required, for: .horizontal)
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
        applyTitleColour()
    }

    deinit {
        keyStateObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func applyTitleColour() {
        let isKey = window?.isKeyWindow ?? false
        attributedTitle = NSAttributedString(
            string: plainTitle,
            attributes: [.foregroundColor: isKey ? Tokens.Color.inkOnFill : Tokens.Color.label,
                         .font: titleFont])
    }
}
