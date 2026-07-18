// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterCore

/// The static identity of one permission row (the parts that never change).
struct PermissionRowContent {
    /// SF Symbol shown in the leading icon tile (white, over `tileColor`).
    let symbolName: String
    /// The tile fill — a system colour (System Settings-style category chip).
    let tileColor: NSColor
    let title: String
    /// The plain-language "why we need this," in the user's mental model.
    let detail: String
    /// Leading-edge call to action, e.g. "Allow…".
    let allowButtonTitle: String
}

/// One permission row in the onboarding window: a leading colour icon tile, a
/// title + wrapping "why" subtitle, and a trailing accessory that swaps with the
/// live ``PermissionStatus`` — an Allow button, a spinner while probing, a
/// green "Allowed", or a "Denied" + "Open System Settings" fallback.
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
                                tint: content.tileColor,
                                accessibility: content.title)
        iconTile.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.stringValue = content.title
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.stringValue = content.detail
        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .secondaryLabelColor
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
            accessory.addArrangedSubview(makeButton(title: content.allowButtonTitle,
                                                    prominent: true, action: #selector(allowTapped)))
        case .granted:
            accessory.addArrangedSubview(statusLabel("Allowed",
                                                     symbol: "checkmark.circle.fill",
                                                     tint: .systemGreen))
        case .requested:
            // Asked, but macOS won't confirm it (Local Network). Say so, and offer
            // System Settings as the way to check/fix if speakers don't appear.
            accessory.addArrangedSubview(statusLabel("Requested",
                                                     symbol: "checkmark.circle",
                                                     tint: .secondaryLabelColor))
            accessory.addArrangedSubview(makeButton(title: "Open Settings",
                                                    prominent: false, action: #selector(openSettingsTapped)))
        case .denied:
            accessory.addArrangedSubview(statusLabel("Denied",
                                                     symbol: "exclamationmark.triangle.fill",
                                                     tint: .systemOrange))
            accessory.addArrangedSubview(makeButton(title: "Open Settings",
                                                    prominent: false, action: #selector(openSettingsTapped)))
        case .unsupported:
            accessory.addArrangedSubview(statusLabel("Requires macOS 14.2 or later",
                                                     symbol: "xmark.circle",
                                                     tint: .secondaryLabelColor))
        }
    }

    // MARK: Accessory builders

    /// A trailing-accessory push button. `prominent` tints the bezel with the
    /// accent color (the "please do this" CTA) WITHOUT making it the window's
    /// Return-default — there are multiple Allow buttons, and a window may have
    /// only one keyboard default (that's Done). Non-prominent is a plain gray
    /// button for the secondary "Open Settings" fallback.
    private func makeButton(title: String, prominent: Bool, action: Selector) -> NSButton {
        if prominent {
            // ProminentButton self-manages its accent fill + a key-state-aware
            // title colour (see its doc comment for the white-on-white bug it fixes).
            return ProminentButton(title: title, target: self, action: action)
        }
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        // Secondary "Open Settings" shares the column with a status word, so
        // `.small` keeps the pair inside the fixed column width. A plain bordered
        // button, so AppKit's own inactive-window handling applies unchanged.
        button.controlSize = .small
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    private func statusLabel(_ text: String, symbol: String, tint: NSColor) -> NSView {
        let image = NSImageView()
        image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: text)
        image.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        image.contentTintColor = tint
        image.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = tint == .systemGreen || tint == .systemOrange ? .labelColor : .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [image, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
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
/// The bug this exists to fix (Alec, deselecting the setup window): AppKit drops
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
        bezelColor = .controlAccentColor
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
        let colour: NSColor = (window?.isKeyWindow ?? false) ? .white : .labelColor
        attributedTitle = NSAttributedString(
            string: plainTitle,
            attributes: [.foregroundColor: colour,
                         .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)])
    }
}

// MARK: - Appearance-adaptive rounded views

/// A small rounded, colour-filled tile holding a white SF Symbol — the System
/// Settings-style category icon chip. Layer-backed and repainted in
/// `updateLayer`, where the view's `effectiveAppearance` is the current drawing
/// appearance, so the system tile colour resolves correctly in light and dark.
final class IconTileView: NSView {

    private let tint: NSColor
    private let radius: CGFloat
    /// The row icon-chip side; the hero uses a larger explicit size.
    static let side: CGFloat = 30

    init(symbolName: String,
         tint: NSColor,
         accessibility: String,
         side: CGFloat = IconTileView.side,
         pointSize: CGFloat = 15,
         cornerRadius: CGFloat = 7) {
        self.tint = tint
        self.radius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        let image = NSImageView()
        image.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibility)
        image.symbolConfiguration = .init(pointSize: pointSize, weight: .semibold)
        image.contentTintColor = .white
        image.translatesAutoresizingMaskIntoConstraints = false
        addSubview(image)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: side),
            heightAnchor.constraint(equalToConstant: side),
            image.centerXAnchor.constraint(equalTo: centerXAnchor),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = tint.cgColor
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
    }
}

/// A rounded rectangle with an appearance-adaptive fill and hairline border —
/// the System Settings grouped inset-list container. Children (the permission
/// rows + hairline separators) are laid out by the caller.
final class RoundedContainerView: NSView {

    private let fill: NSColor
    private let border: NSColor
    private let radius: CGFloat

    init(fill: NSColor = .controlBackgroundColor,
         border: NSColor = .separatorColor,
         radius: CGFloat = 10) {
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
