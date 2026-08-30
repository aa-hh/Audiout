// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

/// One **bordered pill** in `DeviceRowView`'s FEED column (Warm Signal — the
/// product owner's ported-verbatim call: "each feed value gets its own
/// bordered pill, not one packed string joined by middle dots").
/// `DeviceRowView` hosts a left-aligned horizontal row of these, one per
/// visible feed segment (plus an optional trailing "+N" overflow pill and a
/// single error-override pill), inside a plain `NSStackView`.
///
/// A pill hosts a text label — optionally prefixed with the same
/// derived-colour `FeedChip` square a redirected app's tether wears elsewhere
/// — inside a filled rounded rect, so even a short value like "System" reads
/// as a small object instead of floating in empty space. The pill reads by
/// FILL ALONE — no border: a 1 px hairline outline measures 1.14:1 dark /
/// 1.00:1 light against the pill's own fill, decorative in both modes — and
/// an error pill signals via its failure-red TEXT (3.24:1 on the dark fill),
/// not an outline. The neutral main-mix segment (and the
/// failure-red "Couldn't connect"/"Unavailable" override, and the "+N"
/// overflow pill) carry NO chip — only a redirected app's own pill does.
///
/// Drawing/layout-only, non-interactive (`hitTest` returns `nil`, mirroring
/// `LevelMeterView`/`RouteArmedDotView`'s "small self-contained view" house
/// pattern) — nothing here ever routes a click. The fill is a static
/// `CGColor` on the backing layer (same idiom as
/// `DeviceRowView.updateMuteTint()`), re-stamped live off BOTH
/// `viewDidChangeEffectiveAppearance` (light/dark) and the
/// `accessibilityDisplayOptionsDidChangeNotification` (a mid-session
/// Increase-Contrast toggle, which fires neither of the other two), so both
/// track for free. Nothing animates, so a `cacheDisplay` snapshot is
/// byte-identical for a fixed input — the popover-snapshot determinism
/// contract.
final class FeedPillView: NSView {

    private let label = NSTextField(labelWithString: "")
    /// A small leading triangle glyph, mounted only on an ERROR pill (P2-6) —
    /// decorative (no accessibility description: the row's spoken state
    /// clause already says "couldn't connect"), so the pill carries a SHAPE
    /// as well as a colour.
    private let errorGlyph = NSImageView()
    /// The label's leading constraint — pinned to the pill's own leading edge
    /// by default, re-pointed at the glyph's trailing edge the one time
    /// `configure` installs the error layout (pills are freshly constructed
    /// per render, so this never needs to be undone).
    private var labelLeadingConstraint: NSLayoutConstraint?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = PopoverColumnGrid.feedPillCornerRadius

        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byClipping
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .vertical)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(label)

        errorGlyph.translatesAutoresizingMaskIntoConstraints = false
        errorGlyph.image = NSImage(
            systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold))
        errorGlyph.contentTintColor = Tokens.Color.failure
        errorGlyph.isHidden = true
        addSubview(errorGlyph)

        let labelLeading = label.leadingAnchor.constraint(
            equalTo: leadingAnchor, constant: PopoverColumnGrid.feedPillHorizontalPadding)
        labelLeadingConstraint = labelLeading

        NSLayoutConstraint.activate([
            labelLeading,
            label.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -PopoverColumnGrid.feedPillHorizontalPadding),
            label.topAnchor.constraint(
                equalTo: topAnchor, constant: PopoverColumnGrid.feedPillVerticalPadding),
            label.bottomAnchor.constraint(
                equalTo: bottomAnchor, constant: -PopoverColumnGrid.feedPillVerticalPadding),
            errorGlyph.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: PopoverColumnGrid.feedPillHorizontalPadding),
            errorGlyph.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        updateAppearance()
        // The fill is a static `CGColor`, so a mid-session Increase Contrast
        // toggle needs a manual re-stamp off the display-options notification
        // rather than trusting `viewDidChangeEffectiveAppearance` to fire for
        // it (design P2-5; same pattern as `LevelMeterView`).
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsDidChange),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil)
    }

    @objc private func accessibilityDisplayOptionsDidChange() {
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Non-interactive — a pill never routes a click; the row's own controls
    /// do all the interaction (mirrors `LevelMeterView`/`RouteArmedDotView`).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Push this pill's content. `attributedText` is pre-composed by the row
    /// (already carrying a leading `FeedChip` attachment when the segment is
    /// a redirected app, and/or the leading AP1 micro-tag prefix on the FIRST
    /// visible pill) — this view only draws the fill chrome around it. An
    /// error pill ALSO gets a leading triangle glyph (P2-6), so it reads by
    /// shape, not colour alone; the fill is one token for every pill.
    func configure(attributedText: NSAttributedString, isError: Bool) {
        label.attributedStringValue = attributedText
        if isError {
            errorGlyph.isHidden = false
            labelLeadingConstraint?.isActive = false
            let leading = label.leadingAnchor.constraint(
                equalTo: errorGlyph.trailingAnchor, constant: 3)
            leading.isActive = true
            labelLeadingConstraint = leading
        }
        updateAppearance()
    }

    /// The fill is a static `CGColor` on the layer, so a live light/dark or
    /// Increase-Contrast switch needs a manual re-stamp (same discipline as
    /// `DeviceRowView.updateMuteTint()`): light/dark arrives via
    /// `viewDidChangeEffectiveAppearance` below, and a mid-session
    /// Increase-Contrast-ONLY toggle — which fires neither `apply` nor that
    /// appearance callback — is covered by the `accessibilityDisplayOptionsDidChange`
    /// observer registered in `init` (design P2-5, mirrors `LevelMeterView`).
    /// `Tokens.Color.feedPillFill` is the pill's dedicated wash — a stock
    /// `quaternaryLabelColor` wash measures a near-invisible 1.31:1 dark /
    /// 1.21:1 light against the canvas.
    private func updateAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Tokens.Color.feedPillFill.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    // MARK: Test hooks — `DeviceRowView`'s `test_feed*` accessors read these
    // across every pill currently in its `feedStack`.

    /// This pill's plain-text content, with the chip attachment's object-
    /// replacement character stripped (mirrors the retired `feedLabel`'s own
    /// `test_feedText` stripping) so a test reading WORDS never has to know a
    /// chip exists.
    var test_text: String {
        label.attributedStringValue.string
            .replacingOccurrences(of: FeedChip.objectReplacementCharacter, with: "")
    }

    /// Whether this pill CURRENTLY hosts a derived-colour `FeedChip` — only a
    /// redirected app's pill does.
    var test_hasChip: Bool {
        let attr = label.attributedStringValue
        var found = false
        attr.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attr.length)) { value, _, _ in
            if value != nil { found = true }
        }
        return found
    }

    /// Whether this pill's leading run is CURRENTLY painted in the
    /// failure-red tone — reads what's actually painted (not just the
    /// `isError` flag `configure` was called with) so a test can't drift from
    /// the real drawn state, mirroring the retired `feedLabel`'s own
    /// `test_feedIsErrorColored`.
    var test_isErrorColored: Bool {
        guard let color = firstRunColor(),
              let resolved = color.usingColorSpace(.sRGB),
              let failure = Tokens.Color.failure.usingColorSpace(.sRGB) else { return false }
        return abs(resolved.redComponent - failure.redComponent) < 0.01
            && abs(resolved.greenComponent - failure.greenComponent) < 0.01
            && abs(resolved.blueComponent - failure.blueComponent) < 0.01
    }

    /// This pill's leading run's CURRENTLY-painted foreground color.
    var test_leadingRunColor: NSColor? { firstRunColor() }

    /// Whether this pill's error glyph is mounted and visible (P2-6) —
    /// same-module access for `DeviceRowView.test_feedErrorPillHasGlyph`.
    var test_hasErrorGlyph: Bool { !errorGlyph.isHidden }

    private func firstRunColor() -> NSColor? {
        let attr = label.attributedStringValue
        guard attr.length > 0 else { return nil }
        return attr.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    }
}
