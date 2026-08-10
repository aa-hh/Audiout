// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterCore
import AudiouterSharedUI

/// The inline **diagnosis panel** that expands under a failed device row
/// (`dev/notes/p1-connection-status-brief.md` §7.1): a one-line cause, a
/// one-line suggested action, and "Try Again" / "Copy Details" buttons.
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
    /// LEADING inset, which is NOT symmetric with the trailing one (Alec, live
    /// 2026-08-06): the panel used `horizontalInset` on both sides, so its card
    /// began inside the rail GUTTER — the column the membership spine owns — and
    /// read as belonging to the whole panel rather than to the row it is about.
    /// It now starts at the icon column (`firstElementLeading`), the same edge the
    /// device row's own leading element uses, so the card visibly hangs off the
    /// device it refers to and leaves the spine's column clear.
    private static var leadingInset: CGFloat {
        PopoverColumnGrid.firstElementLeading(indented: false)
    }
    /// Vertical inset of the tinted background from this view's top/bottom.
    private static let verticalInset: CGFloat = 4
    /// Padding between the tinted background's edge and its content.
    private static let contentPadding: CGFloat = 10
    /// Corner radius of the failure-tinted background (spec §5.6's warm inset card).
    private static let backgroundCornerRadius: CGFloat = 7
    /// Gap between the headline and the wrapping suggestion body.
    private static let headlineToSuggestion: CGFloat = 3
    /// Gap between the suggestion body and the buttons row.
    private static let suggestionToButtons: CGFloat = 8
    /// Gap between the two buttons.
    private static let buttonSpacing: CGFloat = 8
    /// Inset of the dismiss button from the tinted background's top-trailing corner.
    private static let dismissButtonInset: CGFloat = 6
    /// The dismiss button's HIT-AREA side length — deliberately larger than
    /// the 9.5pt glyph it centers (design-critique finding, 2026-08-10): with
    /// no explicit size the button hugged the glyph, giving a target well
    /// under a comfortable click/tap size. `imageScaling = .scaleProportionallyDown`
    /// only ever scales the glyph DOWN to fit, never up, so widening the
    /// button's own frame grows the invisible padding around the glyph, not
    /// the glyph itself.
    private static let dismissButtonHitSize: CGFloat = 20

    /// Called when the user clicks "Try Again". The host owns the actual retry
    /// (re-adding the device to the Selected Devices set — brief §7.3).
    public var onRetry: (() -> Void)?
    /// Called when the user clicks "Copy Details". The host writes to
    /// `NSPasteboard.general`; this view never touches the pasteboard.
    public var onCopyDetails: (() -> Void)?
    /// Called when the user clicks the dismiss ("x") button. The host removes
    /// the panel (`PopoverPanelViewController`); this view owns no open/closed
    /// state of its own and never removes itself.
    public var onDismiss: (() -> Void)?

    private var failure: ConnectionFailure
    private var deviceName: String

    private let background = NSView()
    private let headlineLabel = NSTextField(labelWithString: "")
    private let suggestionLabel = NSTextField(wrappingLabelWithString: "")
    private let retryButton = NSButton()
    private let copyDetailsButton = NSButton()
    private let dismissButton = NSButton()

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

        configureAccessibility()
        needsLayout = true
    }

    // MARK: Build

    private func buildSubviews() {
        wantsLayer = true

        background.translatesAutoresizingMaskIntoConstraints = false
        background.wantsLayer = true
        background.layer?.cornerRadius = Self.backgroundCornerRadius
        background.layer?.cornerCurve = .continuous
        applyBackgroundTint()
        addSubview(background)

        headlineLabel.translatesAutoresizingMaskIntoConstraints = false
        headlineLabel.font = Tokens.Font.captionBold
        headlineLabel.lineBreakMode = .byTruncatingTail
        background.addSubview(headlineLabel)

        suggestionLabel.translatesAutoresizingMaskIntoConstraints = false
        suggestionLabel.font = Tokens.Font.caption
        suggestionLabel.textColor = Tokens.Color.secondaryLabel
        background.addSubview(suggestionLabel)

        configureSmallButton(retryButton, title: "Try Again", action: #selector(retryClicked(_:)))
        configureSmallButton(copyDetailsButton, title: "Copy Details", action: #selector(copyDetailsClicked(_:)))
        background.addSubview(retryButton)
        background.addSubview(copyDetailsButton)

        configureDismissButton()
        background.addSubview(dismissButton)

        let suggestionWidth = suggestionLabel.widthAnchor.constraint(equalToConstant: 300)
        suggestionWidthConstraint = suggestionWidth

        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: topAnchor, constant: Self.verticalInset),
            background.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.verticalInset),
            background.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leadingInset),
            background.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalInset),

            dismissButton.topAnchor.constraint(equalTo: background.topAnchor, constant: Self.dismissButtonInset),
            dismissButton.trailingAnchor.constraint(
                equalTo: background.trailingAnchor, constant: -Self.dismissButtonInset),
            dismissButton.widthAnchor.constraint(equalToConstant: Self.dismissButtonHitSize),
            dismissButton.heightAnchor.constraint(equalToConstant: Self.dismissButtonHitSize),

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

    /// The quiet dismiss ("x") control pinned to the tinted background's
    /// top-trailing corner: `bezelStyle = .accessoryBar` + `isBordered = false`
    /// (no box at rest, matching the popover's borderless icon-glyph
    /// convention — e.g. the card accessory buttons), a small bold glyph at
    /// `.secondaryLabelColor` — one contrast step up from the `.tertiaryLabelColor`
    /// this replaced (design-critique finding, 2026-08-10: tertiary read as
    /// too faint to notice at all) — so it stays low-key without competing
    /// with "Try Again"/"Copy Details". The glyph itself stays 9.5pt; only the
    /// button's own frame (`dismissButtonHitSize`) grows the click/tap target.
    /// The real accessibility label is set in `configureAccessibility()` (it
    /// needs `deviceName`); this one is just the image's own description, a
    /// harmless fallback for any AX path that reads the image directly.
    private func configureDismissButton() {
        dismissButton.translatesAutoresizingMaskIntoConstraints = false
        dismissButton.bezelStyle = .accessoryBar
        dismissButton.isBordered = false
        dismissButton.imagePosition = .imageOnly
        dismissButton.imageScaling = .scaleProportionallyDown
        dismissButton.contentTintColor = Tokens.Color.secondaryLabel
        dismissButton.target = self
        dismissButton.action = #selector(dismissClicked(_:))

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 9.5, weight: .bold)
        if let image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss")?
            .withSymbolConfiguration(symbolConfig) {
            dismissButton.image = image
        }
    }

    /// Fraction of the failure-exclusive red mixed into the panel seat —
    /// spec §5.6's "warm-tinted inset card (`failure` at ~12% alpha)".
    private static let failureTintFraction: CGFloat = 0.12

    /// Resolve the warm failure tint (spec §5.6) against the *current*
    /// effective appearance and stamp it onto the layer: the inset card sits
    /// on `Tokens.Color.panel` — one ladder-step lighter than the canvas the
    /// popover paints — washed with the FAILURE-EXCLUSIVE `Tokens.Color.failure`
    /// at ~12% (warm, not alarm-orange; house rule 8 keeps this red off every
    /// non-failure surface). Blending here is equivalent to compositing
    /// `failure` at 12% alpha over the opaque `panel` seat, but yields an
    /// opaque color so the tint reads identically regardless of what's behind
    /// the row. `CALayer.backgroundColor` is a static `CGColor` and both
    /// tokens are appearance-/Increase-Contrast-dynamic, so this must re-run
    /// on every appearance change, not just at build time.
    private func applyBackgroundTint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let seat = Tokens.Color.panel
            let tinted = seat.blended(withFraction: Self.failureTintFraction,
                                      of: Tokens.Color.failure) ?? seat
            background.layer?.backgroundColor = tinted.cgColor
        }
    }

    /// Re-resolve the appearance-dependent chrome on a live light/dark switch —
    /// the same pattern as `CardView`'s shadow/rim (the rest of this view is
    /// semantic `NSColor`s on views, which AppKit re-resolves itself).
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBackgroundTint()
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
        onRetry?()
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

        retryButton.setAccessibilityLabel("Try again connecting to \(deviceName)")
        copyDetailsButton.setAccessibilityLabel("Copy connection details for \(deviceName)")
        dismissButton.setAccessibilityLabel("Dismiss connection problem for \(deviceName)")
    }

    // MARK: Test-support hooks

    /// The rendered headline text (structural assertions).
    public var test_headlineText: String { headlineLabel.stringValue }
    /// The rendered suggestion body text.
    public var test_suggestionText: String { suggestionLabel.stringValue }
    /// Whether "Copy Details" is currently enabled (`failure.detail != nil`).
    public var test_copyDetailsEnabled: Bool { copyDetailsButton.isEnabled }
    /// The tinted background's current layer color (appearance-adaptivity asserts).
    public var test_backgroundTint: CGColor? { background.layer?.backgroundColor }

    /// Whether the dismiss button is present and has a resolved image (never blank).
    public var test_hasDismissButton: Bool { dismissButton.image != nil }
    /// The dismiss button's live VoiceOver label — must include the device
    /// name, mirroring "Try again connecting to X"/"Copy connection details
    /// for X" (design-critique finding, 2026-08-10).
    public var test_dismissButtonAccessibilityLabel: String? { dismissButton.accessibilityLabel() }
    /// The dismiss button's laid-out hit-area size — must be ≥20×20pt even
    /// though the glyph it centers stays 9.5pt (design-critique finding,
    /// 2026-08-10).
    public var test_dismissButtonHitSize: NSSize {
        layoutSubtreeIfNeeded()
        return dismissButton.frame.size
    }
    /// The dismiss glyph's tint — one contrast step up from `tertiaryLabel`
    /// (design-critique finding, 2026-08-10: tertiary read as too faint to
    /// notice).
    public var test_dismissButtonTintColor: NSColor? { dismissButton.contentTintColor }

    /// Simulate a "Try Again" click.
    public func test_tapRetry() { retryClicked(retryButton) }
    /// Simulate a "Copy Details" click.
    public func test_tapCopyDetails() { copyDetailsClicked(copyDetailsButton) }
    /// Simulate a dismiss ("x") click.
    public func test_tapDismiss() { dismissClicked(dismissButton) }
}
