// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterCore
import AudiouterSharedUI

/// Everything the ribbon is showing right now, built by
/// ``OnboardingViewController`` and applied in one call. A plain description of
/// a state — it holds no logic and decides nothing.
struct RibbonContent {

    /// Which shape the one action button takes.
    enum PrimaryKind: Equatable {
        /// The everyday accent-filled Allow / Try Again / Open Settings….
        case prominent
        /// The finale's gold "Start listening" — the gate's CTA.
        case cta
    }

    /// The status line: what just happened, or what we are waiting for. `spins`
    /// swaps the glyph for a small spinner — a wait on screen always says what
    /// it is waiting for.
    var status: (symbolName: String?, text: String, color: NSColor, spins: Bool)?
    /// The one-line ask above the copy ("This is what macOS will ask you next.").
    var ask: String?
    /// The reassurance paragraph. Attributed, because a few of these bold one
    /// word — the button that is the wrong answer, the app's own name in a
    /// Settings list.
    var body: NSAttributedString?
    /// The quieter honesty line under the copy ("macOS won't tell us when you
    /// do…").
    var honesty: String?
    var primary: (title: String, kind: PrimaryKind)?
    var showsSkip = false
    /// A demoted text-button path offered BESIDE the primary, never instead of
    /// it (Local Network's retry keeps its own browse; a browsed row offers its
    /// pane).
    var quietLink: String?

    /// What the buttons currently are, as one comparable value: the action row
    /// is rebuilt only when this changes, so a repaint can't re-run the CTA's
    /// entrance or steal the keyboard focus back off it.
    var buttonSignature: String {
        [primary.map { "\($0.title)|\($0.kind)" } ?? "-",
         showsSkip ? "skip" : "-",
         quietLink ?? "-"].joined(separator: "\u{1F}")
    }
}

/// The REAL UI under the rehearsal: the ask, the reassurance, the honesty line
/// and the buttons — all of it relocated out of the old left-column card so the
/// drawn mock above it can take the stage (Direction 04, owner-chosen).
///
/// It lives INSIDE the hero pane but OUTSIDE ``DemoPaneView``, which is what
/// makes it accessible by construction: the demo's accessibility opt-out walks
/// the mock subtree only, so it can never reach this. Everything the user is
/// told is here, in stock controls VoiceOver reads, while the pane above is
/// decorative.
///
/// **The action row never leaves the layout.** It is a fixed reserved band, so
/// the moment a click sends the answer over to macOS — the beat where the
/// buttons go away and the stage dims — nothing above it moves.
final class SetupRibbonView: NSView {

    /// The wrapping width every paragraph in here is measured at: the hero
    /// pane's interior, which is also the stage's width.
    static let textWidth: CGFloat = DemoPaneView.surfaceSize.width
    /// The reserved height of the action row.
    static let actionRowHeight: CGFloat = 24
    /// The status line's leading glyph/spinner column.
    private static let statusGlyphSide: CGFloat = 13
    private static let statusGap: CGFloat = 6
    /// The honesty line is the quietest thing here — a shade under the body it
    /// qualifies, without inventing a fifth ink.
    private static let honestyAlpha: CGFloat = 0.85

    private let stack = NSStackView()
    private let statusRow = NSStackView()
    private let statusGlyph = NSImageView()
    private let statusSpinner = NSProgressIndicator()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let askLabel = NSTextField(wrappingLabelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let honestyLabel = NSTextField(wrappingLabelWithString: "")
    private let actionRow = NSView()

    /// The one action button, whatever shape it is taking. The view controller
    /// reads it for the gate hooks and hands it the keyboard focus.
    private(set) var primaryButton: NSButton?
    private var skipButton: NSButton?
    private var quietLinkButton: NSButton?
    private var appliedButtonSignature: String?
    private var primaryKind: RibbonContent.PrimaryKind?

    var onPrimary: () -> Void = {}
    var onSkip: () -> Void = {}
    var onQuietLink: () -> Void = {}

    init() {
        super.init(frame: .zero)
        build()
        apply(RibbonContent())
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Build

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false

        statusGlyph.symbolConfiguration = .init(pointSize: Self.statusGlyphSide, weight: .semibold)
        statusGlyph.translatesAutoresizingMaskIntoConstraints = false
        statusGlyph.setContentHuggingPriority(.required, for: .horizontal)

        statusSpinner.style = .spinning
        statusSpinner.controlSize = .small
        statusSpinner.isDisplayedWhenStopped = false
        statusSpinner.translatesAutoresizingMaskIntoConstraints = false
        statusSpinner.setContentHuggingPriority(.required, for: .horizontal)

        statusLabel.font = .systemFont(ofSize: 11.5, weight: .semibold)
        statusLabel.maximumNumberOfLines = 0
        statusLabel.preferredMaxLayoutWidth =
            Self.textWidth - Self.statusGlyphSide - Self.statusGap
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        statusRow.orientation = .horizontal
        // Centre, not baseline: a progress indicator has no baseline to align
        // text to, and AppKit resolves that by not aligning anything.
        statusRow.alignment = .centerY
        statusRow.spacing = Self.statusGap
        statusRow.translatesAutoresizingMaskIntoConstraints = false
        statusRow.addArrangedSubview(statusGlyph)
        statusRow.addArrangedSubview(statusSpinner)
        statusRow.addArrangedSubview(statusLabel)

        askLabel.font = Tokens.Font.bodyEmphasized
        askLabel.textColor = Tokens.Color.label
        askLabel.maximumNumberOfLines = 0
        askLabel.preferredMaxLayoutWidth = Self.textWidth
        askLabel.translatesAutoresizingMaskIntoConstraints = false

        bodyLabel.font = Tokens.Font.caption
        bodyLabel.textColor = Tokens.Color.inkSecondary
        bodyLabel.maximumNumberOfLines = 0
        bodyLabel.preferredMaxLayoutWidth = Self.textWidth
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false

        honestyLabel.font = Tokens.Font.caption
        honestyLabel.textColor = Tokens.Color.inkSecondary
        honestyLabel.alphaValue = Self.honestyAlpha
        honestyLabel.maximumNumberOfLines = 0
        honestyLabel.preferredMaxLayoutWidth = Self.textWidth
        honestyLabel.translatesAutoresizingMaskIntoConstraints = false

        actionRow.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [statusRow, askLabel, bodyLabel, honestyLabel, actionRow] {
            stack.addArrangedSubview(view)
        }
        stack.setCustomSpacing(14, after: honestyLabel)
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),

            actionRow.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            actionRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            // RESERVED: the row keeps its height whether or not it holds a
            // button, so a wait — which takes every button away — cannot move
            // the stage above it. A `.large` CTA is taller than the band and is
            // allowed to overflow it, exactly as the old fixed primary slot let
            // its widest button overflow.
            actionRow.heightAnchor.constraint(equalToConstant: Self.actionRowHeight),
        ])
    }

    // MARK: State

    func apply(_ content: RibbonContent) {
        if let status = content.status {
            statusRow.isHidden = false
            statusLabel.stringValue = status.text
            statusLabel.textColor = status.color
            statusGlyph.isHidden = status.spins || status.symbolName == nil
            if let symbolName = status.symbolName, !status.spins {
                statusGlyph.image = NSImage(systemSymbolName: symbolName,
                                            accessibilityDescription: nil)
                statusGlyph.contentTintColor = status.color
            }
            statusSpinner.isHidden = !status.spins
            if status.spins { statusSpinner.startAnimation(nil) } else { statusSpinner.stopAnimation(nil) }
        } else {
            statusRow.isHidden = true
            statusSpinner.stopAnimation(nil)
        }

        askLabel.stringValue = content.ask ?? ""
        askLabel.isHidden = content.ask == nil

        if let body = content.body {
            bodyLabel.attributedStringValue = body
            bodyLabel.isHidden = false
        } else {
            bodyLabel.stringValue = ""
            bodyLabel.isHidden = true
        }

        honestyLabel.stringValue = content.honesty ?? ""
        honestyLabel.isHidden = content.honesty == nil

        rebuildActionsIfNeeded(content)
    }

    /// Rebuild the action row — but only when the buttons themselves changed.
    /// A repaint that changes nothing must not re-run the CTA's entrance, and
    /// must not take the keyboard focus back off a button the user is on.
    private func rebuildActionsIfNeeded(_ content: RibbonContent) {
        let signature = content.buttonSignature
        guard signature != appliedButtonSignature else { return }
        let hadCTA = primaryKind == .cta
        appliedButtonSignature = signature

        actionRow.subviews.forEach { $0.removeFromSuperview() }
        primaryButton = nil
        skipButton = nil
        quietLinkButton = nil
        primaryKind = content.primary?.kind

        var leading: NSLayoutXAxisAnchor = actionRow.leadingAnchor
        var spacing: CGFloat = 0

        if let primary = content.primary {
            let button: NSButton
            switch primary.kind {
            case .cta:
                // The finale CTA (owner copy 2026-08-11): closing setup is what
                // starts the deferred audio engine, so the button names that —
                // and it wears the DEEP gold authored for white ink (`goldCTA`,
                // measured rationale on the token) where the everyday Allow
                // wears the system accent. Ink is measured off the resolved
                // fill (see `ProminentButton.picksInkFromFill`).
                let cta = ProminentButton(title: primary.title, target: self,
                                          action: #selector(primaryTapped),
                                          fill: Tokens.Color.goldCTA, picksInkFromFill: true,
                                          titleFont: Tokens.Font.bodyEmphasized)
                // Constrained directly (no stack view to do it for us): left
                // on, AutoLayout synthesises size from the zero frame and the
                // button renders as nothing at all.
                cta.translatesAutoresizingMaskIntoConstraints = false
                cta.controlSize = .large
                button = cta
            case .prominent:
                button = onboardingActionButton(title: primary.title, prominent: true,
                                                target: self, action: #selector(primaryTapped))
            }
            // Whatever the primary is, it owns Return — and when the gate opens
            // the CTA IS the primary, so the old "Done takes Return from the
            // live Allow" contract holds with nothing left to hand over.
            button.keyEquivalent = "\r"
            primaryButton = button
            actionRow.addSubview(button)
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: leading),
                button.centerYAnchor.constraint(equalTo: actionRow.centerYAnchor),
            ])
            leading = button.trailingAnchor
            spacing = 8
        }

        if content.showsSkip {
            let skip = onboardingActionButton(title: "Skip", prominent: false,
                                              target: self, action: #selector(skipTapped))
            skipButton = skip
            actionRow.addSubview(skip)
            NSLayoutConstraint.activate([
                skip.leadingAnchor.constraint(equalTo: leading, constant: spacing),
                skip.centerYAnchor.constraint(equalTo: actionRow.centerYAnchor),
            ])
            leading = skip.trailingAnchor
            spacing = 8
        }

        if let title = content.quietLink {
            let link = onboardingActionButton(title: title, prominent: false,
                                              target: self, action: #selector(quietLinkTapped))
            quietLinkButton = link
            actionRow.addSubview(link)
            NSLayoutConstraint.activate([
                link.leadingAnchor.constraint(equalTo: leading, constant: spacing),
                link.centerYAnchor.constraint(equalTo: actionRow.centerYAnchor),
            ])
        }

        if primaryKind == .cta, !hadCTA, canAnimate, let cta = primaryButton {
            cta.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                cta.animator().alphaValue = 1
            }
        }
    }

    /// Whether the CTA's entrance may animate: a real, on-screen window with
    /// Reduce Motion off. Everywhere else it simply exists — steady states must
    /// render settled or snapshots stop being deterministic.
    private var canAnimate: Bool {
        guard !HeadlessRuntime.isActive,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let window = window, window.isVisible else { return false }
        return window.occlusionState.contains(.visible)
    }

    // MARK: Actions

    @objc private func primaryTapped() { onPrimary() }
    @objc private func skipTapped() { onSkip() }
    @objc private func quietLinkTapped() { onQuietLink() }

    // MARK: Test-support hooks

    var test_askText: String? { askLabel.isHidden ? nil : askLabel.stringValue }
    var test_statusText: String? { statusRow.isHidden ? nil : statusLabel.stringValue }
    var test_bodyText: String? { bodyLabel.isHidden ? nil : bodyLabel.stringValue }
    var test_honestyText: String? { honestyLabel.isHidden ? nil : honestyLabel.stringValue }
    /// Whether a wait is on screen (the spinner beat).
    var test_isWaiting: Bool { !statusRow.isHidden && !statusSpinner.isHidden }
    /// The titles of the buttons the ribbon currently offers, in order.
    var test_buttonTitles: [String] {
        [primaryButton, skipButton, quietLinkButton].compactMap { $0?.title }
    }
    /// Whether the primary is the gate's gold CTA rather than an everyday Allow.
    var test_primaryIsCTA: Bool { primaryKind == .cta }
    func test_tapPrimary() { primaryTapped() }
    func test_tapSkip() { skipTapped() }
    func test_tapQuietLink() { quietLinkTapped() }
    /// Whether the ribbon's controls are still real, reachable AppKit controls
    /// — it sits inside the hero pane beside a demo that is deliberately
    /// invisible to VoiceOver, and must never be swept up in that.
    var test_isAccessible: Bool {
        let controls = [primaryButton, skipButton, quietLinkButton].compactMap { $0 }
        guard !controls.isEmpty else { return false }
        return controls.allSatisfy {
            $0.accessibilityChildren()?.isEmpty == false && $0.accessibilityLabel() == $0.title
        }
    }
}
