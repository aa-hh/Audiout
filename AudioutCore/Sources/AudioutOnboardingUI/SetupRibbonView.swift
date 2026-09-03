// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore
import AudioutSharedUI

/// Everything the hero is saying right now, built by
/// ``OnboardingViewController`` and applied in one call. A plain description of
/// a state — it holds no logic and decides nothing.
///
/// It is split across two views: ``headline``/``why`` are the TOP block
/// (``SetupHeroHeadView``, above the rehearsal), and everything else belongs to
/// the ``SetupRibbonView`` under it.
struct RibbonContent {

    /// Which shape the one action button takes.
    ///
    /// Both kinds WEAR the same deep gold (owner decision 2026-08-12: gold
    /// appears on exactly one thing per screen, the button this step wants
    /// pressed). The distinction survives because the GATE contract is written
    /// in it — the CTA exists iff the final check passed, and
    /// `test_primaryIsCTA` is what pins that.
    enum PrimaryKind: Equatable {
        /// The everyday step button — Enable System Audio, Try Again, Open
        /// Settings….
        case prominent
        /// The finale's "Start listening" — the gate's CTA.
        case cta
    }

    /// The hero's headline: what pressing the button gets you. Owner-verbatim
    /// per step (``SetupCardContent/heroHeadline``).
    var headline: String?
    /// The one line under it: why Audiout needs this. On a first ask these
    /// two ARE the copy — there is no overline, no support line and no ask
    /// line under them.
    var why: String?

    /// The status line: what just happened, or what we are waiting for. `spins`
    /// swaps the glyph for a small spinner — a wait on screen always says what
    /// it is waiting for. It sits in the hero's LOWER region, between the
    /// preview frame and the bar, so a first ask (which has none) leaves the
    /// rehearsal all of that space.
    var status: (symbolName: String?, text: String, color: NSColor, spins: Bool)?
    /// The recovery paragraph — denied, permission-lost, a stuck dialog. A
    /// FIRST ask has none: the headline and the why line say it, and
    /// the rehearsal shows it. Attributed, because a few of these bold one word
    /// — the button that is the wrong answer, the app's own name in a Settings
    /// list.
    var body: NSAttributedString?
    var primary: (title: String, kind: PrimaryKind)?
    var showsSkip = false
    /// Override for ``SetupRibbonView/skipTitle``, for the one step whose skip
    /// is not a deferral. Usage Statistics is asked ONCE and never re-nagged
    /// (PRODUCT.md), so "Skip for now" would promise a second ask that never
    /// comes; its button says "No Thanks" instead. `nil` keeps the shared word.
    var skipTitle: String?
    /// A demoted text-button path offered BESIDE the primary, never instead of
    /// it (Local Network's retry keeps its own browse; a browsed row offers its
    /// pane).
    var quietLink: String?

    /// What the buttons currently are, as one comparable value: the action row
    /// is rebuilt only when this changes, so a repaint can't re-run the CTA's
    /// entrance or steal the keyboard focus back off it.
    var buttonSignature: String {
        [primary.map { "\($0.title)|\($0.kind)" } ?? "-",
         showsSkip ? "skip:\(skipTitle ?? "")" : "-",
         quietLink ?? "-"].joined(separator: "\u{1F}")
    }
}

/// The hero's TOP block: the headline over the why line, and nothing else
/// (owner-approved 2026-08-12 — this REPLACES the overline/ask/support stack the
/// ribbon used to carry under the stage, so read the history before adding a
/// third line back).
///
/// The order is the point. A user meets the promise, then the reason, then the
/// picture of what macOS is about to put in front of them, then one button.
/// Everything that used to sit between those — the "This is what macOS will ask
/// you next." ask line, the reassurance paragraph, the honesty line — was
/// deleted rather than moved: they were three more things to read before the
/// one thing to do.
final class SetupHeroHeadView: NSView {

    /// Air between the headline and the why line.
    private static let gap: CGFloat = 9

    private let headlineLabel = NSTextField(wrappingLabelWithString: "")
    private let whyLabel = NSTextField(wrappingLabelWithString: "")

    init(width: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        headlineLabel.font = Tokens.Font.display
        headlineLabel.textColor = Tokens.Color.label
        headlineLabel.maximumNumberOfLines = 2
        // The hero's heading, findable in VoiceOver's rotor. The raw AX string,
        // not `NSAccessibilityHeadingRole`: that constant is macOS 26+ and this
        // app installs on 14.2.
        headlineLabel.setAccessibilityRole(NSAccessibility.Role(rawValue: "AXHeading"))

        // Primary ink, not secondary: this is the sentence the whole step rests
        // on, and it is the only body copy a first ask has.
        whyLabel.font = .systemFont(ofSize: 14.5, weight: .medium)
        whyLabel.textColor = Tokens.Color.label
        whyLabel.maximumNumberOfLines = 3

        for label in [headlineLabel, whyLabel] {
            label.preferredMaxLayoutWidth = width
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor),
                label.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            headlineLabel.topAnchor.constraint(equalTo: topAnchor),
            whyLabel.topAnchor.constraint(equalTo: headlineLabel.bottomAnchor, constant: Self.gap),
            whyLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(_ content: RibbonContent) {
        headlineLabel.stringValue = content.headline ?? ""
        headlineLabel.isHidden = content.headline == nil
        whyLabel.stringValue = content.why ?? ""
        whyLabel.isHidden = content.why == nil
    }

    // MARK: Test-support hooks

    var test_headline: String? { headlineLabel.isHidden ? nil : headlineLabel.stringValue }
    var test_why: String? { whyLabel.isHidden ? nil : whyLabel.stringValue }
    /// The headline's accessibility role — the rotor's heading contract.
    var test_headlineAccessibilityRole: NSAccessibility.Role? { headlineLabel.accessibilityRole() }
}

/// The LABELLED frame the rehearsal plays inside: a warm well with a caption
/// band along its top edge saying whose surface this is.
///
/// The label is the whole reason the frame exists (owner-approved 2026-08-12).
/// The mock is a drawing of somebody else's window sitting inside ours, and
/// without a boundary and a caption a user has no way to know which of the two
/// things on screen macOS will actually show them — the earlier layout answered
/// that with a sentence ("This is what macOS will ask you next."), which cost a
/// line of reading for something a frame says for free.
///
/// The frame is FLEXIBLE and its content is CLIPPED: the hero is a fixed
/// 462 × 508 inside a fixed window, so the frame takes whatever the head block
/// and the bar leave, and whatever plays inside it has to fit that.
final class SetupPreviewFrameView: NSView {

    /// Height of the caption band.
    static let labelBandHeight: CGFloat = 24
    /// Air around the surface playing inside the frame.
    static let bodyPadding: CGFloat = 8
    private static let cornerRadius: CGFloat = 10
    private static let labelInset: CGFloat = 12

    /// Where the caller installs whatever plays in here (the demo pane). Its
    /// contents are centred and clipped, never resized — the pane owns its own
    /// size.
    let body = NSView()

    private let well: RoundedContainerView
    private let labelBand = NSView()
    private let captionLabel = NSTextField(labelWithString: "")
    private let bandRule = RoundedContainerView(fill: Tokens.Color.hairline,
                                                border: .clear, radius: 0)
    private var bandHeight: NSLayoutConstraint!

    init() {
        well = RoundedContainerView(fill: Tokens.Color.well,
                                    border: Tokens.Color.hairline,
                                    radius: Self.cornerRadius)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        // The well clips: a rehearsal larger than the frame is cropped by it
        // rather than spilling over the bar below.
        well.wantsLayer = true
        well.layer?.masksToBounds = true
        addSubview(well)

        captionLabel.textColor = Tokens.Color.tertiaryLabel
        captionLabel.translatesAutoresizingMaskIntoConstraints = false
        bandRule.borderWidth = 0
        labelBand.translatesAutoresizingMaskIntoConstraints = false
        labelBand.addSubview(captionLabel)
        labelBand.addSubview(bandRule)
        body.translatesAutoresizingMaskIntoConstraints = false
        well.addSubview(labelBand)
        well.addSubview(body)

        bandHeight = labelBand.heightAnchor.constraint(equalToConstant: Self.labelBandHeight)
        NSLayoutConstraint.activate([
            well.leadingAnchor.constraint(equalTo: leadingAnchor),
            well.trailingAnchor.constraint(equalTo: trailingAnchor),
            well.topAnchor.constraint(equalTo: topAnchor),
            well.bottomAnchor.constraint(equalTo: bottomAnchor),

            labelBand.leadingAnchor.constraint(equalTo: well.leadingAnchor),
            labelBand.trailingAnchor.constraint(equalTo: well.trailingAnchor),
            labelBand.topAnchor.constraint(equalTo: well.topAnchor),
            bandHeight,

            captionLabel.leadingAnchor.constraint(equalTo: labelBand.leadingAnchor,
                                                  constant: Self.labelInset),
            captionLabel.centerYAnchor.constraint(equalTo: labelBand.centerYAnchor),

            bandRule.leadingAnchor.constraint(equalTo: labelBand.leadingAnchor),
            bandRule.trailingAnchor.constraint(equalTo: labelBand.trailingAnchor),
            bandRule.bottomAnchor.constraint(equalTo: labelBand.bottomAnchor),
            bandRule.heightAnchor.constraint(equalToConstant: 1),

            body.leadingAnchor.constraint(equalTo: well.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: well.trailingAnchor),
            body.topAnchor.constraint(equalTo: labelBand.bottomAnchor,
                                      constant: Self.bodyPadding),
            body.bottomAnchor.constraint(equalTo: well.bottomAnchor,
                                         constant: -Self.bodyPadding),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The band's words — nil takes the whole band away, for the one surface
    /// that is NOT macOS's: the finale card is ours, and captioning it "You'll
    /// see this from macOS" would be a lie.
    var caption: String? {
        didSet {
            guard caption != oldValue else { return }
            captionLabel.attributedStringValue = Self.captionText(caption ?? "")
            labelBand.isHidden = caption == nil
            bandHeight.constant = caption == nil ? 0 : Self.labelBandHeight
        }
    }

    /// What VoiceOver reads for the caption band INSTEAD of its visible words.
    ///
    /// The band is small and quiet on purpose, and the picture it labels is
    /// deliberately invisible to VoiceOver (the demo's accessibility opt-out) —
    /// so for the one step whose rehearsal carries an instruction the drawing
    /// alone conveys, the caption is where that instruction can be spoken
    /// without putting a fourth line of copy on screen. `nil` puts the visible
    /// text back.
    var spokenCaption: String? {
        didSet {
            guard spokenCaption != oldValue else { return }
            captionLabel.setAccessibilityLabel(spokenCaption)
        }
    }

    /// Take the frame's VISUAL chrome away — well fill, rim and clip — leaving
    /// the geometry exactly where it is.
    ///
    /// For the finale only (owner-approved 2026-08-12): that card is ours, so
    /// a frame around it boxes in the one moment that should feel like the
    /// window opening up, and its clip crops the gold ripple at the rim. A
    /// permission step keeps the framed look — there the boundary is the whole
    /// point, because the picture inside it is somebody else's window.
    var isChromeless: Bool = false {
        didSet {
            guard isChromeless != oldValue else { return }
            well.fill = isChromeless ? .clear : Tokens.Color.well
            well.border = isChromeless ? .clear : Tokens.Color.hairline
            well.borderWidth = isChromeless ? 0 : 1
            well.layer?.masksToBounds = !isChromeless
        }
    }

    /// Small and quiet — a frame label, deliberately not a heading: it names
    /// the picture without competing with the headline above it. Rendered as
    /// authored, never uppercased (One Case rule).
    private static func captionText(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: Tokens.Font.microLabel,
            .foregroundColor: Tokens.Color.tertiaryLabel,
        ])
    }

    // MARK: Test-support hooks

    /// The caption as drawn (uppercased), or nil when the band is away.
    var test_caption: String? {
        labelBand.isHidden ? nil : captionLabel.attributedStringValue.string
    }

    /// What VoiceOver reads for the caption band.
    var test_captionAccessibilityLabel: String? { captionLabel.accessibilityLabel() }

    /// Whether the well is actually drawing chrome (fill, rim, clip).
    var test_drawsChrome: Bool {
        well.fill != .clear && well.border != .clear && well.borderWidth > 0
    }
}

/// The hero's lower half: the recovery copy (a status line and, where a state
/// has one, its paragraph) over a BARE BOTTOM BAR — a hairline, then the
/// buttons, trailing-aligned, and nothing else.
///
/// It lives INSIDE the hero pane but OUTSIDE ``DemoPaneView``, which is what
/// makes it accessible by construction: the demo's accessibility opt-out walks
/// the mock subtree only, so it can never reach this. Everything the user is
/// told is here or in ``SetupHeroHeadView``, in stock controls VoiceOver reads,
/// while the pane between them is decorative.
///
/// **The action row never leaves the layout.** It is a fixed reserved band, so
/// the moment a click sends the answer over to macOS — the beat where the
/// buttons go away and the stage dims — nothing above it moves.
final class SetupRibbonView: NSView {

    /// The wrapping width every paragraph in here is measured at: the hero
    /// pane's interior, which is also the preview frame's width.
    static let textWidth: CGFloat = DemoPaneView.surfaceSize.width
    /// The reserved height of the action row — the `.large` gold button's own
    /// height, so the bar is the same band whether it holds one button or none.
    static let actionRowHeight: CGFloat = 32
    /// Air between the bar's hairline and the buttons under it.
    static let barTopPadding: CGFloat = 12
    /// The status line's leading glyph/spinner column.
    private static let statusGlyphSide: CGFloat = 13
    private static let statusGap: CGFloat = 6
    /// Gap between the buttons in the bar.
    private static let buttonGap: CGFloat = 8

    private let stack = NSStackView()
    private let statusRow = NSStackView()
    private let statusGlyph = NSImageView()
    private let statusSpinner = NSProgressIndicator()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let barRule = RoundedContainerView(fill: Tokens.Color.hairline,
                                               border: .clear, radius: 0)
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

        bodyLabel.font = Tokens.Font.caption
        bodyLabel.textColor = Tokens.Color.inkSecondary
        bodyLabel.maximumNumberOfLines = 0
        bodyLabel.preferredMaxLayoutWidth = Self.textWidth
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false

        barRule.borderWidth = 0
        barRule.translatesAutoresizingMaskIntoConstraints = false
        actionRow.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [statusRow, bodyLabel, barRule, actionRow] {
            stack.addArrangedSubview(view)
        }
        stack.setCustomSpacing(Self.barTopPadding, after: barRule)
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),

            barRule.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            barRule.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            barRule.heightAnchor.constraint(equalToConstant: 1),

            actionRow.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            actionRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            // RESERVED: the row keeps its height whether or not it holds a
            // button, so a wait — which takes every button away — cannot move
            // the preview frame above it.
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

        if let body = content.body {
            bodyLabel.attributedStringValue = body
            bodyLabel.isHidden = false
        } else {
            bodyLabel.stringValue = ""
            bodyLabel.isHidden = true
        }

        rebuildActionsIfNeeded(content)
    }

    /// Rebuild the action row — but only when the buttons themselves changed.
    /// A repaint that changes nothing must not re-run the CTA's entrance, and
    /// must not take the keyboard focus back off a button the user is on.
    ///
    /// The bar is TRAILING-aligned and reads right to left: the primary sits at
    /// the trailing edge, Skip and any quiet link fall to its left.
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

        var trailing: NSLayoutXAxisAnchor = actionRow.trailingAnchor
        var spacing: CGFloat = 0

        if let primary = content.primary {
            // Both kinds wear the CTA gold — the everyday step button and the
            // finale's CTA alike, because there is only ever one of them on
            // screen and it is always the thing to press. The ink is
            // `inkOnFill`, which `ProminentButton` stamps for every fill.
            let button = ProminentButton(title: primary.title, target: self,
                                         action: #selector(primaryTapped),
                                         fill: Tokens.Color.goldCTA,
                                         titleFont: Tokens.Font.bodyEmphasized)
            // Constrained directly (no stack view to do it for us): left on,
            // AutoLayout synthesises size from the zero frame and the button
            // renders as nothing at all.
            button.translatesAutoresizingMaskIntoConstraints = false
            button.controlSize = .large
            // Whatever the primary is, it owns Return — and when the gate opens
            // the CTA IS the primary, so the old "Done takes Return from the
            // live Allow" contract holds with nothing left to hand over.
            button.keyEquivalent = "\r"
            primaryButton = button
            actionRow.addSubview(button)
            NSLayoutConstraint.activate([
                button.trailingAnchor.constraint(equalTo: trailing),
                button.centerYAnchor.constraint(equalTo: actionRow.centerYAnchor),
            ])
            trailing = button.leadingAnchor
            spacing = Self.buttonGap
        }

        if content.showsSkip {
            // Borderless and quiet: skipping is a real answer, but it is not
            // the one the step is asking for.
            let skip = onboardingActionButton(title: content.skipTitle ?? Self.skipTitle,
                                              prominent: false,
                                              target: self, action: #selector(skipTapped))
            skip.isBordered = false
            skip.controlSize = .regular
            skipButton = skip
            actionRow.addSubview(skip)
            NSLayoutConstraint.activate([
                skip.trailingAnchor.constraint(equalTo: trailing, constant: -spacing),
                skip.centerYAnchor.constraint(equalTo: actionRow.centerYAnchor),
            ])
            trailing = skip.leadingAnchor
            spacing = Self.buttonGap
        }

        if let title = content.quietLink {
            let link = onboardingActionButton(title: title, prominent: false,
                                              target: self, action: #selector(quietLinkTapped))
            link.isBordered = false
            link.controlSize = .regular
            quietLinkButton = link
            actionRow.addSubview(link)
            NSLayoutConstraint.activate([
                link.trailingAnchor.constraint(equalTo: trailing, constant: -spacing),
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

    /// Skip's own words (owner copy deck): "for now" is the honest half —
    /// a skipped step is re-armed by clicking its row, and nothing is spent.
    static let skipTitle = "Skip for now"

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

    var test_statusText: String? { statusRow.isHidden ? nil : statusLabel.stringValue }
    var test_bodyText: String? { bodyLabel.isHidden ? nil : bodyLabel.stringValue }
    /// Whether a wait is on screen (the spinner beat).
    var test_isWaiting: Bool { !statusRow.isHidden && !statusSpinner.isHidden }
    /// The titles of the buttons the ribbon currently offers, in the order they
    /// read on screen (leading to trailing, so the primary is LAST).
    var test_buttonTitles: [String] {
        [quietLinkButton, skipButton, primaryButton].compactMap { $0?.title }
    }
    /// Whether the primary is the gate's CTA rather than an everyday step
    /// button. Both wear the same gold, so this is the only thing that can tell
    /// them apart — and the gate contract is written in it.
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
