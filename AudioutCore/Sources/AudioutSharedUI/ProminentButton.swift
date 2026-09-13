// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

// MARK: - Prominent (gold-filled) button

/// A gold-filled push button (`bezelColor`) whose title stays legible whether
/// or not its window is key.
///
/// One rule for the whole app, and not a per-call choice: every call to
/// action is `Tokens.Color.goldText` fill (the deep-gold CTA fill) with
/// `Tokens.Color.goldCTAInk` ink. The ink is authored for that one fill, so a
/// settable fill could only ever put the CTA's ink on some other colour.
///
/// The fill deepened from `Tokens.Color.gold` to its `goldText` values so a
/// WHITE ink clears the 4.5:1 body floor with real margin (5.90:1 light,
/// 10.19:1 dark). The former `gold` + dark `inkOnFill` pairing was a nominal
/// 4.94:1 that the `.rounded` bezel's shading gradient pushed under the floor
/// in practice — a fill that gets DARKER when rendered only helps white ink,
/// which is why the ink flips to white on the deepened light fill. See
/// `goldCTAInk`.
///
/// The bug this exists to fix (ahh, deselecting the setup window): AppKit drops
/// a `bezelColor` fill to a plain bezel when the window resigns key — correct,
/// that's how macOS de-emphasises controls in inactive windows — but, UNLIKE a
/// true default button, it does NOT recolor the title to match. An ink authored
/// for the fill is not authored for the plain bezel: `goldCTAInk` goes
/// dark-on-dark there in dark mode, and white-on-white in light (it is white
/// over the deep fill), so the button reads as an empty pill.
/// Being made the Return-default doesn't fix it either — the sequential flow
/// DOES make the one live Allow the default while Done is absent
/// (`SetupRibbonView`), and it still happens the moment the Setup window
/// resigns key to System Settings, which is exactly when the user is looking
/// at it.
///
/// Fix: track the window's key state and swap the title colour — `goldCTAInk`
/// over the fill when key, `Tokens.Color.label` (appearance-adaptive, legible
/// on the plain bezel in both light and dark) when not.
public final class ProminentButton: NSButton {

    private let plainTitle: String
    /// The bezel fill (`bezelColor` carries it). Public so a caller can prove
    /// the button is the gold one (`OnboardingViewController`'s CTA check). The
    /// deep-gold CTA fill (`goldText`'s values), not `gold` — see the type doc.
    public let fill = Tokens.Color.goldText
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
            attributes: [.foregroundColor: isKey ? Tokens.Color.goldCTAInk : Tokens.Color.label,
                         .font: titleFont])
    }
}
