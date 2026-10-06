// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore
import AudioutSharedUI

/// The inline **diagnosis panel** that expands under a failed device row
/// (`dev/notes/p1-connection-status-brief.md` §7.1): a one-line cause, a
/// one-line suggested action, and "Try again" / "Copy details" buttons.
///
/// This view is a pure renderer of a `ConnectionFailure` — it owns no backend
/// or pasteboard access. The host (`PopoverController`, T7) inserts/removes it
/// under the failed row (`PopoverPanelViewController.insertRow(_:after:animated:)`),
/// calls `apply(failure:deviceName:)` whenever the failure changes, and wires
/// `onRetry`/`onCopyDetails` to the real retry path and `NSPasteboard.general`
/// respectively — this view never writes the pasteboard itself (brief §7.3).
public final class ConnectionDiagnosisView: NSView {

    /// Leading/trailing inset of the panel's tinted background from the row's
    /// edges. Aligned with `PopoverColumnGrid.leadingInset` (14) so the panel's
    /// name-column edge lines up with the row above it, minus a few points so
    /// the tinted background reads as its own inset card rather than flush with
    /// the row (matches the mockup's "inset to align with the name column").
    private static let horizontalInset: CGFloat = 10
    /// LEADING inset, which is NOT symmetric with the trailing one (owner's call,
    /// live 2026-08-06): the panel used `horizontalInset` on both sides, so its
    /// card began inside the rail GUTTER — the column the membership spine owns —
    /// and read as belonging to the whole panel rather than to the row it is
    /// about. It now starts at the icon column (`firstElementLeading`), the same
    /// edge the device row's own leading element uses, so the card visibly hangs
    /// off the device it refers to and leaves the spine's column clear.
    private static var leadingInset: CGFloat {
        PopoverColumnGrid.firstElementLeading(indented: false)
    }
    /// Vertical inset of the tinted background from this view's top/bottom.
    private static let verticalInset: CGFloat = 4
    /// Padding between the tinted background's edge and its content.
    private static let contentPadding: CGFloat = 10
    /// Gap between the headline and the wrapping suggestion body.
    private static let headlineToSuggestion: CGFloat = 3
    /// Gap between the suggestion body and the buttons row.
    private static let suggestionToButtons: CGFloat = 8
    /// Gap between the two buttons.
    private static let buttonSpacing: CGFloat = 8

    /// Called when the user clicks "Try again". The host owns the actual retry
    /// (re-adding the device to the Selected Devices set — brief §7.3).
    public var onRetry: (() -> Void)?
    /// Called when the user clicks "Copy details". The host writes to
    /// `NSPasteboard.general`; this view never touches the pasteboard.
    public var onCopyDetails: (() -> Void)?
    /// Called when the user clicks the dismiss ("x") button. The host removes
    /// the panel (`PopoverPanelViewController`); this view owns no open/closed
    /// state of its own and never removes itself.
    public var onDismiss: (() -> Void)?
    /// Called instead of `onRetry` when the cause is `.authRequired`: the
    /// button reads "Enter Password…" and the host opens the password sheet.
    public var onEnterPassword: (() -> Void)?

    private var failure: ConnectionFailure
    private var deviceName: String

    /// `failure` on the shared inset-card ground (spec §5.6's warm inset card),
    /// the same recipe as the warning banner.
    private let background = TintedNoteBackgroundView(tint: Tokens.Color.failure)
    private let headlineLabel = NSTextField(labelWithString: "")
    private let suggestionLabel = NSTextField(wrappingLabelWithString: "")
    private let retryButton = NSButton()
    private let copyDetailsButton = NSButton()
    private lazy var dismissButton = NSButton.noticeDismissButton(
        target: self, action: #selector(dismissClicked(_:)))

    /// Pinned wrapping width for the suggestion label, kept in sync with the
    /// panel's own width in `layout()` so Auto Layout can self-size the row's
    /// height from the wrapped text (a fixed-width wrapping label is what makes
    /// `NSTextField` report an intrinsic height at all).
    private var suggestionWidthConstraint: NSLayoutConstraint?

    public init(failure: ConnectionFailure, deviceName: String) {
        self.failure = failure
        self.deviceName = deviceName
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 0))
        autoresizingMask = [.width]
        translatesAutoresizingMaskIntoConstraints = true
        buildSubviews()
        apply(failure: failure, deviceName: deviceName)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Model

    /// Render a (possibly replaced) failure — e.g. the backend's immediate
    /// best-guess, later swapped for the diagnosed cause once
    /// `ConnectionDiagnosing` returns (brief §3 "Failure flow"). Re-applying is
    /// safe and idempotent; the host calls this on every `deviceUpdated` for the
    /// failed id, not just once.
    public func apply(failure: ConnectionFailure, deviceName: String) {
        self.failure = failure
        self.deviceName = deviceName

        headlineLabel.stringValue = failure.headline
        suggestionLabel.stringValue = failure.suggestion
        copyDetailsButton.isEnabled = failure.detail != nil
        copyDetailsButton.isHidden = failure.detail == nil
        retryButton.title = failure.cause == .authRequired ? "Enter Password…" : "Try again"

        configureAccessibility()
        needsLayout = true
    }

    // MARK: Build

    private func buildSubviews() {
        wantsLayer = true

        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)

        headlineLabel.translatesAutoresizingMaskIntoConstraints = false
        headlineLabel.font = .boldSystemFont(ofSize: 11)
        headlineLabel.lineBreakMode = .byTruncatingTail
        background.addSubview(headlineLabel)

        suggestionLabel.translatesAutoresizingMaskIntoConstraints = false
        suggestionLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        suggestionLabel.textColor = Tokens.Color.label2
        background.addSubview(suggestionLabel)

        configureSmallButton(retryButton, title: "Try again", action: #selector(retryClicked(_:)))
        configureSmallButton(copyDetailsButton, title: "Copy details", action: #selector(copyDetailsClicked(_:)))
        // The default button ("Try again", or "Enter Password…" for a password
        // demand) is the default action (P1-6): Return fires it without a
        // click, the stock `.rounded` bezel renders the default treatment on
        // its own.
        retryButton.keyEquivalent = "\r"
        background.addSubview(retryButton)
        background.addSubview(copyDetailsButton)

        background.addSubview(dismissButton)

        let suggestionWidth = suggestionLabel.widthAnchor.constraint(equalToConstant: 300)
        suggestionWidthConstraint = suggestionWidth

        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: topAnchor, constant: Self.verticalInset),
            background.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.verticalInset),
            background.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leadingInset),
            background.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalInset),

            dismissButton.topAnchor.constraint(
                equalTo: background.topAnchor, constant: NSButton.noticeDismissInset),
            dismissButton.trailingAnchor.constraint(
                equalTo: background.trailingAnchor, constant: -NSButton.noticeDismissInset),

            headlineLabel.topAnchor.constraint(equalTo: background.topAnchor, constant: Self.contentPadding),
            headlineLabel.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: Self.contentPadding),
            headlineLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: dismissButton.leadingAnchor, constant: -Self.contentPadding),

            suggestionLabel.topAnchor.constraint(
                equalTo: headlineLabel.bottomAnchor, constant: Self.headlineToSuggestion),
            suggestionLabel.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: Self.contentPadding),
            suggestionWidth,

            retryButton.topAnchor.constraint(
                equalTo: suggestionLabel.bottomAnchor, constant: Self.suggestionToButtons),
            retryButton.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: Self.contentPadding),
            retryButton.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -Self.contentPadding),

            copyDetailsButton.leadingAnchor.constraint(
                equalTo: retryButton.trailingAnchor, constant: Self.buttonSpacing),
            copyDetailsButton.centerYAnchor.constraint(equalTo: retryButton.centerYAnchor),
            copyDetailsButton.bottomAnchor.constraint(
                lessThanOrEqualTo: background.bottomAnchor, constant: -Self.contentPadding),
        ])
    }

    private func configureSmallButton(_ button: NSButton, title: String, action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.title = title
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = Tokens.Font.caption
        button.target = self
        button.action = action
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    // MARK: Layout — keep the wrapping label's pinned width equal to the
    // background's available content width so Auto Layout can compute the
    // wrapped height (a wrapping `NSTextField` needs a fixed width to report an
    // intrinsic content size at all).

    public override func layout() {
        // Leading and trailing insets are NOT symmetric (see `leadingInset`), so
        // this sums the two rather than doubling one — getting it wrong overstates
        // the wrap width and the suggestion text clips.
        let available = bounds.width - Self.leadingInset - Self.horizontalInset - 2 * Self.contentPadding
        if available > 0, suggestionWidthConstraint?.constant != available {
            suggestionWidthConstraint?.constant = available
        }
        super.layout()
    }

    // MARK: Actions

    @objc private func retryClicked(_ sender: NSButton) {
        if failure.cause == .authRequired, let onEnterPassword {
            onEnterPassword()
        } else {
            onRetry?()
        }
    }

    @objc private func copyDetailsClicked(_ sender: NSButton) {
        onCopyDetails?()
    }

    @objc private func dismissClicked(_ sender: NSButton) {
        onDismiss?()
    }

    // MARK: Accessibility

    private func configureAccessibility() {
        setAccessibilityElement(false)
        background.setAccessibilityElement(true)
        background.setAccessibilityRole(.group)
        background.setAccessibilityLabel("Connection problem for \(deviceName): \(failure.headline). \(failure.suggestion)")

        retryButton.setAccessibilityLabel(failure.cause == .authRequired
            ? "Enter the password for \(deviceName)"
            : "Try again connecting to \(deviceName)")
        copyDetailsButton.setAccessibilityLabel("Copy connection details for \(deviceName)")
        dismissButton.setAccessibilityLabel("Dismiss")
    }

    // MARK: Test-support hooks

    /// The rendered headline text (structural assertions).
    public var test_headlineText: String { headlineLabel.stringValue }
    /// The rendered suggestion body text.
    public var test_suggestionText: String { suggestionLabel.stringValue }
    /// Whether "Copy details" is currently enabled (`failure.detail != nil`).
    public var test_copyDetailsEnabled: Bool { copyDetailsButton.isEnabled }
    /// Whether "Copy details" is currently hidden (`failure.detail == nil`,
    /// P3-1 — hidden, not just disabled, when there's nothing to copy).
    public var test_copyDetailsHidden: Bool { copyDetailsButton.isHidden }
    /// The tinted background's current layer color (appearance-adaptivity asserts).
    public var test_backgroundTint: CGColor? { background.layer?.backgroundColor }
    /// The tinted background's corner radius — the inset card's own corner.
    public var test_backgroundCornerRadius: CGFloat? { background.layer?.cornerRadius }

    /// Whether the dismiss button is present and has a resolved image (never blank).
    public var test_hasDismissButton: Bool { dismissButton.image != nil }
    /// "Try again"'s key equivalent — the default-button treatment (P1-6).
    public var test_retryKeyEquivalent: String { retryButton.keyEquivalent }
    /// The dismiss button's key equivalent — Escape (P1-6).
    public var test_dismissKeyEquivalent: String { dismissButton.keyEquivalent }

    /// The retry button's current title ("Try again" or "Enter Password…").
    public var test_retryButtonTitle: String { retryButton.title }

    /// Simulate a "Try again" click.
    public func test_tapRetry() { retryClicked(retryButton) }
    /// Simulate a "Copy details" click.
    public func test_tapCopyDetails() { copyDetailsClicked(copyDetailsButton) }
    /// Simulate a dismiss ("x") click.
    public func test_tapDismiss() { dismissClicked(dismissButton) }
}

extension NSButton {

    /// Inset of a notice's ✕ from its card's top-trailing corner.
    static let noticeDismissInset: CGFloat = 6

    /// The ✕ that closes a dismissible Mixer notice (the diagnosis card, the
    /// alignment note): borderless `.accessoryBar`, the `xmark` glyph at 12 pt
    /// bold in `label2`, a hit area of at least 24×24 pt (P1-6), and Escape as
    /// its key equivalent so the notice closes without a click.
    static func noticeDismissButton(target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .accessoryBar
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = Tokens.Color.label2
        button.target = target
        button.action = action
        button.keyEquivalent = "\u{1b}"
        button.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .bold))
        button.setAccessibilityLabel("Dismiss")
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 24),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 24),
        ])
        return button
    }
}
