// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore
import AudioutSharedUI

/// Audiout's own Share / Don't Share card — the surface the Usage Statistics
/// step's ask raises, and the ONE definition of it.
///
/// It is built once and hosted twice: live, inside
/// ``UsageStatsConsentViewController`` as a sheet on the Setup window; and at
/// rest, inside ``DemoConsentCardMockView`` on the rehearsal stage. That is the
/// whole point of the type existing — every other stage in this window
/// rehearses a surface macOS draws, which we can only ever approximate, but
/// this one is OURS, so the rehearsal can be the same view rather than a
/// drawing of it. The two cannot drift, because there is nothing to keep in
/// step (owner: "why can't you make it look exactly like your mock-up").
///
/// It is Warm Signal rather than a system mimic — `Tokens`, the step's own
/// identity tile, and the same button pair the ribbon uses — because it is an
/// Audiout window, not a copy of one of macOS's.
final class UsageStatsConsentCard: NSView {

    /// Life size. The macOS privacy dialogs this sits beside in the flow are
    /// roughly this wide, and the stage (418 pt) has room for it unscaled —
    /// so the rehearsal shows the card at the size it will really appear,
    /// rather than a miniature of it.
    static let width: CGFloat = 380

    private static let padding: CGFloat = 22
    private static let tileSide: CGFloat = 56

    let shareButton: NSButton
    let declineButton: NSButton

    /// - Parameter target/action: `nil` builds the card INERT, for the stage.
    ///   The buttons are still real controls drawn by AppKit — that is what
    ///   makes the rehearsal accurate — they simply answer to nobody.
    init(target: AnyObject? = nil,
         shareAction: Selector? = nil,
         declineAction: Selector? = nil) {
        shareButton = ProminentButton(title: "Share", target: target, action: shareAction)
        declineButton = NSButton(title: "Don't Share", target: target, action: declineAction)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The card carries its OWN ground rather than borrowing its host's, so the
    /// stage copy and the sheet copy are the same picture — the stage sits on
    /// the preview frame's well, the sheet on a window.
    ///
    /// Painted in `updateLayer`, never stamped at init: a resolved `CGColor`
    /// freezes at whatever appearance was ambient when it was taken, and taking
    /// it in `init` — before the view has a window — froze this card WHITE in
    /// dark mode, with white text on it. SharedUI's layer-colour rule.
    ///
    /// The rim is `containerEdge`, the card's own edge: this is a card sitting
    /// on a panel, and without an edge of its own the two grounds run together.
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Tokens.Color.panel.cgColor
        layer?.borderColor = Tokens.Color.containerEdge.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = Tokens.Layout.Radius.row
        layer?.cornerCurve = .continuous
    }

    private func build() {
        // The step's identity tile, built exactly as its spine row builds one:
        // the NEUTRAL well every other step wears, with only the glyph carrying
        // the step's hue (Q3). A filled hue tile with white ink is retired
        // everywhere in this flow — no tile colours its own fill.
        let tile = IconTileView(symbolName: "chart.bar.xaxis",
                                accessibility: "Usage counts",
                                color: Tokens.Color.permissionUsageStats,
                                side: Self.tileSide,
                                pointSize: 26)

        let headline = NSTextField(wrappingLabelWithString: Self.headlineText)
        headline.font = .systemFont(ofSize: 15, weight: .semibold)
        headline.textColor = Tokens.Color.label
        headline.translatesAutoresizingMaskIntoConstraints = false

        // THE fence. It lives here rather than in the hero's why line, which
        // sits directly above this card on the stage — the same sentence twice,
        // once in each, read as a stutter.
        let body = NSTextField(wrappingLabelWithString: Self.bodyText)
        body.font = .systemFont(ofSize: 12.5)
        body.textColor = Tokens.Color.label2
        body.translatesAutoresizingMaskIntoConstraints = false

        declineButton.bezelStyle = .rounded
        declineButton.controlSize = .regular
        declineButton.translatesAutoresizingMaskIntoConstraints = false
        // Escape declines, Return shares: the two answers reachable without
        // the pointer, which is what makes this a real sheet rather than a
        // picture of one.
        declineButton.keyEquivalent = "\u{1b}"
        shareButton.keyEquivalent = "\r"

        // `fillEqually` only wins if nothing hugs harder than it — and
        // `ProminentButton` sets required horizontal hugging for the ribbon,
        // where it sizes to its title.
        shareButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        declineButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [declineButton, shareButton])
        buttons.orientation = .horizontal
        buttons.distribution = .fillEqually
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false

        for view in [tile, headline, body, buttons] { addSubview(view) }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),

            tile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding),
            tile.topAnchor.constraint(equalTo: topAnchor, constant: Self.padding),

            headline.leadingAnchor.constraint(equalTo: tile.leadingAnchor),
            headline.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.padding),
            headline.topAnchor.constraint(equalTo: tile.bottomAnchor, constant: 16),

            body.leadingAnchor.constraint(equalTo: headline.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: headline.trailingAnchor),
            body.topAnchor.constraint(equalTo: headline.bottomAnchor, constant: 8),

            buttons.leadingAnchor.constraint(equalTo: headline.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: headline.trailingAnchor),
            buttons.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 22),
            buttons.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.padding),
        ])
    }

    static let headlineText = "Share anonymous usage counts?"
    /// The promise, in the user's words, and the ONLY place the app makes it in
    /// full. Keep it in step with what is actually sent — audited against a
    /// real ingested event on 2026-08-29, not against intent.
    ///
    /// The failure half was added 2026-09-05 with `Analytics.captureError`.
    /// The SDK had been reporting unhandled crashes since the first analytics
    /// commit (`errorTrackingConfig.autoCapture`) without this string ever
    /// saying so; the handled failures joined them, and now it does. Both
    /// carry a stack trace of Audiout's own code and nothing the user typed.
    ///
    /// It leads with the thing that makes this not tracking (the owner's call):
    /// there is no identity to attach anything to. Then it is specific, because
    /// the autocaptured payload is wider than an earlier draft claimed — that
    /// draft promised "never your network" and "never your licence key" while
    /// the SDK was sending both, which is the failure mode this string exists
    /// to prevent. "City" rather than "region" is deliberate too: PostHog's
    /// location enrichment resolves to postal-code precision.
    static let bodyText = "No account, no name. Just a random ID for this copy of "
        + "Audiout. It counts which features get used, reports crashes and failures like "
        + "audio stopping, and notes your Mac, macOS version, city, and whether Audiout is "
        + "licensed. What you play, and what your speakers are called, never leave this Mac."

    /// The stage's copy: out of the accessibility tree, and inert.
    ///
    /// It is NOT disabled. A disabled button greys its own title however the
    /// view's alpha is set, and this card's whole job on the stage is to look
    /// exactly like the one that is about to appear. It is inert because it was
    /// built with no target and no action, and because its host refuses hit
    /// testing — so there is nothing to press rather than something visibly
    /// unpressable.
    func makeDecorative() {
        for view in [self] + subviewsRecursively {
            view.setAccessibilityElement(false)
            view.setAccessibilityChildren([])
        }
    }
}

/// The live sheet: ``UsageStatsConsentCard`` on a Warm Signal panel, presented
/// on the Setup window. Nothing here but the card and the answer it reports —
/// the card owns every pixel, so the rehearsal on the stage is the same view
/// with its buttons switched off.
final class UsageStatsConsentViewController: NSViewController {

    private let onAnswer: (Bool) -> Void
    private var card: UsageStatsConsentCard!

    init(onAnswer: @escaping (Bool) -> Void) {
        self.onAnswer = onAnswer
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let panel = RoundedContainerView(fill: Tokens.Color.panel, border: .clear, radius: 0)
        panel.translatesAutoresizingMaskIntoConstraints = false
        card = UsageStatsConsentCard(target: self,
                                     shareAction: #selector(shareTapped),
                                     declineAction: #selector(declineTapped))
        panel.addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            card.topAnchor.constraint(equalTo: panel.topAnchor),
            card.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
        ])
        view = panel
    }

    @objc private func shareTapped() { finish(true) }
    @objc private func declineTapped() { finish(false) }

    private func finish(_ granted: Bool) {
        presentingViewController?.dismiss(self)
        onAnswer(granted)
    }

    // MARK: Test-support hooks

    func test_tapShare() { _ = view; shareTapped() }
    func test_tapDecline() { _ = view; declineTapped() }
}
