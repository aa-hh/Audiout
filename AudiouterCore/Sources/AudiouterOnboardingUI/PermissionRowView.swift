// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterCore
import AudiouterSharedUI

/// The static identity of one permission row (the parts that never change).
struct PermissionRowContent {
    /// SF Symbol shown in the leading icon tile. Every tile shares the same
    /// neutral `raised` well + hairline rim (Q3 of the colour-return pass —
    /// the tile fill/rim are never coloured); the symbol's RESTING tint is
    /// this row's ``iconColor`` and warms to gold once granted (unchanged).
    let symbolName: String
    let title: String
    /// The plain-language "why we need this," in the user's mental model.
    let detail: String
    /// Leading-edge call to action, e.g. "Allow…".
    let allowButtonTitle: String
    /// This row's resting (ungranted) glyph tint — one of the four
    /// `Tokens.Color.permission*` hues (colour-return pass, decisions
    /// Q1/Q3). Passed straight to ``IconTileView``.
    let iconColor: NSColor
}

/// Shared trailing-accessory push button for onboarding rows (``PermissionRowView``,
/// ``PTPHelperRowView``). `prominent` tints the bezel with the accent color
/// (the "please do this" CTA) WITHOUT making it the window's Return-default —
/// a screen can have several such buttons, and a window has only one keyboard
/// default (Done). Non-prominent is a plain gray button for a secondary
/// "Open Settings…"/"Open Login Items…" fallback.
func onboardingRowActionButton(title: String, prominent: Bool,
                               target: AnyObject, action: Selector) -> NSButton {
    if prominent {
        // ProminentButton self-manages its accent fill + a key-state-aware
        // title colour (see its doc comment for the white-on-white bug it fixes).
        return ProminentButton(title: title, target: target, action: action)
    }
    let button = NSButton(title: title, target: target, action: action)
    button.bezelStyle = .rounded
    // Secondary buttons share the column with a status word, so `.small` keeps
    // the pair inside the fixed column width. A plain bordered button, so
    // AppKit's own inactive-window handling applies unchanged.
    button.controlSize = .small
    button.setContentHuggingPriority(.required, for: .horizontal)
    return button
}

/// Shared trailing-accessory status chip (symbol + text) for onboarding rows.
func onboardingRowStatusLabel(_ text: String, symbol: String, tint: NSColor) -> NSView {
    let image = NSImageView()
    image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: text)
    image.symbolConfiguration = .init(pointSize: 13, weight: .regular)
    image.contentTintColor = tint
    image.translatesAutoresizingMaskIntoConstraints = false

    let label = NSTextField(labelWithString: text)
    label.font = Tokens.Font.caption
    label.textColor = tint == .systemGreen || tint == .systemOrange ? Tokens.Color.label : Tokens.Color.secondaryLabel
    label.translatesAutoresizingMaskIntoConstraints = false

    let stack = NSStackView(views: [image, label])
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = 4
    stack.translatesAutoresizingMaskIntoConstraints = false
    return stack
}

/// One permission row in the onboarding window: a leading icon tile — a
/// neutral well holding a symbol tinted with this row's own
/// ``PermissionRowContent/iconColor`` (gold-lit once granted — see
/// ``IconTileView``) — a title + wrapping "why" subtitle, and a trailing
/// accessory that swaps with the live ``PermissionStatus`` — an Allow
/// button, a spinner while probing, a green "Allowed", or a "Denied" +
/// "Open System Settings" fallback.
///
/// Rows are designed to sit inside a grouped ``RoundedContainerView`` (the
/// System Settings inset-list look), so the row itself carries only its own
/// internal padding. Stock AppKit only (SF Symbols, `NSButton`,
/// `NSProgressIndicator`, system colours) per the repo UI house rules — the only
/// custom drawing is the rounded, appearance-adaptive icon tile / container,
/// which have no stock equivalent.
final class PermissionRowView: NSView {

    private let content: PermissionRowContent
    private let onAllow: () -> Void
    private let onOpenSettings: () -> Void

    private var iconTile: IconTileView!
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    /// The swappable trailing area (button / spinner / status).
    private let accessory = NSStackView()
    private let spinner = NSProgressIndicator()

    /// Horizontal inset from the enclosing card edge to the row content.
    static let horizontalInset: CGFloat = 14
    /// Vertical padding above/below the row content inside the card.
    static let verticalInset: CGFloat = 12
    /// Fixed width of the trailing status+action column. The whole point of
    /// pinning this is that the text column's right edge — and therefore its wrap
    /// width — is IDENTICAL in every state, so switching Allow… → Requested +
    /// Open Settings can't reflow the description (no layout shift). Sized to hold
    /// the widest content: a status word + the (small) Open Settings button.
    static let accessoryColumnWidth: CGFloat = 184
    /// Gap between the text column's right edge and the accessory column.
    static let accessoryGap: CGFloat = 12

    init(content: PermissionRowContent,
         onAllow: @escaping () -> Void,
         onOpenSettings: @escaping () -> Void) {
        self.content = content
        self.onAllow = onAllow
        self.onOpenSettings = onOpenSettings
        super.init(frame: .zero)
        build()
        update(status: .unknown, isProbing: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Build

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false

        iconTile = IconTileView(symbolName: content.symbolName,
                                accessibility: content.title,
                                color: content.iconColor)
        iconTile.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.stringValue = content.title
        titleLabel.font = Tokens.Font.bodyEmphasized
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.stringValue = content.detail
        detailLabel.font = Tokens.Font.caption
        detailLabel.textColor = Tokens.Color.secondaryLabel
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.maximumNumberOfLines = 0
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        accessory.orientation = .horizontal
        accessory.alignment = .centerY
        accessory.spacing = 8
        accessory.translatesAutoresizingMaskIntoConstraints = false
        accessory.setContentHuggingPriority(.required, for: .horizontal)
        accessory.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(iconTile)
        addSubview(titleLabel)
        addSubview(detailLabel)
        addSubview(accessory)

        // A zero-size spacer spanning the full title+detail text block, purely so
        // the icon tile and accessory can center on ITS centerY. Centering them on
        // `titleLabel` (the old approach) put them near the top the moment
        // `detailLabel` wrapped past one line — they need to track the whole
        // two-line block's center, which only exists as the span between two views.
        let textBlockCenter = NSLayoutGuide()
        addLayoutGuide(textBlockCenter)

        let inset = Self.horizontalInset
        let vInset = Self.verticalInset
        // The text column's right edge is a FIXED distance from the row's trailing
        // edge — inset + the accessory column + the gap — so it never depends on
        // what the accessory currently holds. This is what kills the layout shift.
        let textTrailingInset = inset + Self.accessoryColumnWidth + Self.accessoryGap
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: iconTile.trailingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: vInset),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -textTrailingInset),

            // Detail's trailing is pinned to the FIXED text-column boundary (not to
            // the variable accessory), so its width is constant across states —
            // `layout()` then feeds that width to `preferredMaxLayoutWidth` so the
            // wrap height is correct (a `.leading` stack kept intrinsic width and
            // clipped when compressed).
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -textTrailingInset),
            detailLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -vInset),

            textBlockCenter.topAnchor.constraint(equalTo: titleLabel.topAnchor),
            textBlockCenter.bottomAnchor.constraint(equalTo: detailLabel.bottomAnchor),

            iconTile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            iconTile.centerYAnchor.constraint(equalTo: textBlockCenter.centerYAnchor),

            // Accessory right-aligns against the trailing inset and occupies the
            // fixed column; the `>=` keeps it from ever crossing into the text gap
            // even if a future status string is unexpectedly wide.
            accessory.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            accessory.centerYAnchor.constraint(equalTo: textBlockCenter.centerYAnchor),
            accessory.leadingAnchor.constraint(greaterThanOrEqualTo: detailLabel.trailingAnchor,
                                               constant: Self.accessoryGap),
        ])
    }

    override func layout() {
        super.layout()
        // Feed the detail label its real, constraint-resolved width so its
        // multiline height is computed for the width it actually occupies — this is
        // what keeps a squeezed row (wide trailing accessory) from clipping its last
        // line. Guarded so the induced re-layout converges instead of looping.
        let width = detailLabel.frame.width
        if width > 0, abs(detailLabel.preferredMaxLayoutWidth - width) > 0.5 {
            detailLabel.preferredMaxLayoutWidth = width
            detailLabel.invalidateIntrinsicContentSize()
        }
    }

    // MARK: State

    /// Repaint the trailing accessory for the current permission status.
    func update(status: PermissionStatus, isProbing: Bool) {
        lastStatus = status
        lastProbing = isProbing

        // Granting "lights" the row's icon gold (spec §5.8 — the one onboarding
        // choreography; ≤300 ms, skipped under Reduce Motion, see
        // `IconTileView.setLit`). The VoiceOver-visible equivalent is the
        // "Allowed" status chip below — the gold is redundant reinforcement.
        iconTile.setLit(status == .granted)

        // Clear the accessory.
        for v in accessory.arrangedSubviews { accessory.removeArrangedSubview(v); v.removeFromSuperview() }

        if isProbing {
            spinner.startAnimation(nil)
            accessory.addArrangedSubview(spinner)
            return
        }
        spinner.stopAnimation(nil)

        switch status {
        case .unknown:
            accessory.addArrangedSubview(onboardingRowActionButton(
                title: content.allowButtonTitle, prominent: true,
                target: self, action: #selector(allowTapped)))
        case .granted:
            accessory.addArrangedSubview(onboardingRowStatusLabel("Allowed",
                                                     symbol: "checkmark.circle.fill",
                                                     tint: .systemGreen))
        case .requested:
            // Asked, but macOS won't confirm it (Local Network). Say so, and offer
            // System Settings as the way to check/fix if speakers don't appear.
            accessory.addArrangedSubview(onboardingRowStatusLabel("Requested",
                                                     symbol: "checkmark.circle",
                                                     tint: .secondaryLabelColor))
            accessory.addArrangedSubview(onboardingRowActionButton(
                title: "Open Settings…", prominent: false,
                target: self, action: #selector(openSettingsTapped)))
        case .denied:
            accessory.addArrangedSubview(onboardingRowStatusLabel("Denied",
                                                     symbol: "exclamationmark.triangle.fill",
                                                     tint: .systemOrange))
            accessory.addArrangedSubview(onboardingRowActionButton(
                title: "Open Settings…", prominent: false,
                target: self, action: #selector(openSettingsTapped)))
        case .unsupported:
            accessory.addArrangedSubview(onboardingRowStatusLabel("Requires macOS 14.2 or later",
                                                     symbol: "xmark.circle",
                                                     tint: .secondaryLabelColor))
        }
    }

    // MARK: Actions

    @objc private func allowTapped() { onAllow() }
    @objc private func openSettingsTapped() { onOpenSettings() }

    // MARK: Test-support hooks

    private(set) var lastStatus: PermissionStatus = .unknown
    private(set) var lastProbing = false

    /// The titles of any buttons currently in the trailing accessory (so a test
    /// can assert "unknown shows Allow…", "denied shows Open Settings").
    var test_buttonTitles: [String] {
        accessory.arrangedSubviews.compactMap { ($0 as? NSButton)?.title }
    }

    /// Invoke the primary (Allow) action as if the button were clicked.
    func test_tapAllow() { allowTapped() }

    /// Invoke the "Open System Settings" action.
    func test_tapOpenSettings() { openSettingsTapped() }
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
/// an empty pill. We can't just make these true default buttons: there are
/// several Allow… buttons and a window has only one Return-default.
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
/// the SYMBOL's resting tint is caller-supplied (`color`, one of the four
/// `Tokens.Color.permission*` hues for the onboarding rows) and "warms to
/// gold" once its permission is granted — the one place gold marks success
/// outside the instruments (house rule 1's flagged onboarding exception,
/// spec §10).
///
/// The gold-lit swap is the only onboarding choreography: a ≤300 ms crossfade
/// between two stacked symbol image views, skipped entirely under Reduce
/// Motion and whenever the tile isn't on a visible window (first render,
/// headless tests, the snapshot harness — steady states render settled).
///
/// Layer-backed and repainted in `updateLayer`, where the view's
/// `effectiveAppearance` is the current drawing appearance, so the warm
/// tokens resolve correctly in light and dark (and Increase Contrast).
final class IconTileView: NSView {

    private let radius: CGFloat
    /// The row icon-chip side. `git grep IconTileView` shows both call sites
    /// (`PermissionRowView`, `PTPHelperRowView`) use this default.
    static let side: CGFloat = 30

    /// The resting (warm-neutral) symbol and its gold-lit twin, stacked.
    /// `setLit` crossfades their alphas rather than mutating one image view's
    /// `contentTintColor` (which is not animatable).
    private let restingImage = NSImageView()
    private let litImage = NSImageView()
    /// Whether the symbol is currently gold-lit (granted).
    private(set) var isLit = false

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

        restingImage.image = NSImage(systemSymbolName: symbolName,
                                     accessibilityDescription: accessibility)
        restingImage.symbolConfiguration = .init(pointSize: pointSize, weight: .semibold)
        restingImage.contentTintColor = color
        restingImage.translatesAutoresizingMaskIntoConstraints = false
        addSubview(restingImage)

        // Decorative twin: VoiceOver reads the resting image (and the row's
        // status chip carries the granted/denied state in words), so the gold
        // layer is not its own accessibility element.
        litImage.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        litImage.symbolConfiguration = .init(pointSize: pointSize, weight: .semibold)
        litImage.contentTintColor = Tokens.Color.gold
        litImage.alphaValue = 0
        litImage.setAccessibilityElement(false)
        litImage.translatesAutoresizingMaskIntoConstraints = false
        addSubview(litImage)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: side),
            heightAnchor.constraint(equalToConstant: side),
            restingImage.centerXAnchor.constraint(equalTo: centerXAnchor),
            restingImage.centerYAnchor.constraint(equalTo: centerYAnchor),
            litImage.centerXAnchor.constraint(equalTo: centerXAnchor),
            litImage.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Light (or un-light) the symbol gold. Animated only when the state
    /// actually changes on a visible window AND Reduce Motion is off —
    /// everywhere else (first render, snapshots, headless tests, Reduce
    /// Motion) it's an instant swap, so steady states always render settled.
    func setLit(_ lit: Bool) {
        guard lit != isLit else { return }
        isLit = lit
        let litAlpha: CGFloat = lit ? 1 : 0
        let restingAlpha: CGFloat = lit ? 0 : 1
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard !reduceMotion, window?.isVisible == true else {
            litImage.alphaValue = litAlpha
            restingImage.alphaValue = restingAlpha
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25   // ≤300 ms, spec §5.8
            context.allowsImplicitAnimation = true
            litImage.animator().alphaValue = litAlpha
            restingImage.animator().alphaValue = restingAlpha
        }
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Tokens.Color.raised.cgColor
        layer?.borderColor = Tokens.Color.hairline.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
    }

    // MARK: Test-support hooks

    /// The resting (ungranted) glyph tint — the row's `iconColor` (Q1/Q3).
    var test_restingTint: NSColor? { restingImage.contentTintColor }

    /// The lit (granted) glyph tint — always `Tokens.Color.gold` (Q2, unchanged).
    var test_litTint: NSColor? { litImage.contentTintColor }

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
final class RoundedContainerView: NSView {

    private let fill: NSColor
    private let border: NSColor
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
        layer?.borderWidth = 1
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
    }
}
