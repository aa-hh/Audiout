// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

/// One **bordered pill** in `DeviceRowView`'s FEED column (Warm Signal — the
/// product owner's ported-verbatim call: "each feed value gets its own
/// bordered pill, not one packed string joined by middle dots"). Replaces the
/// retired single `feedLabel` composite: `DeviceRowView` now hosts a
/// left-aligned horizontal row of these, one per visible feed segment (plus
/// an optional trailing "+N" overflow pill and a single error-override pill),
/// inside a plain `NSStackView`.
///
/// A pill hosts a text label — optionally prefixed with the same
/// derived-colour `FeedChip` square a redirected app's tether wears elsewhere
/// — inside a rounded rect with a subtle border and a very slightly filled
/// background, so even a short value like "System" reads as a small object
/// instead of floating in empty space. The neutral main-mix segment (and the
/// failure-red "Couldn't connect"/"Unavailable" override, and the "+N"
/// overflow pill) carry NO chip — only a redirected app's own pill does.
///
/// Drawing/layout-only, non-interactive (`hitTest` returns `nil`, mirroring
/// `LevelMeterView`/`RouteArmedDotView`'s "small self-contained view" house
/// pattern) — nothing here ever routes a click. Colors resolve LIVE via
/// `viewDidChangeEffectiveAppearance` (the border/fill are static `CGColor`s
/// on the backing layer, same idiom as `DeviceRowView.updateMuteTint()`), so
/// light/dark and Increase Contrast track for free. Nothing animates, so a
/// `cacheDisplay` snapshot is byte-identical for a fixed input — the
/// popover-snapshot determinism contract.
final class FeedPillView: NSView {

    private let label = NSTextField(labelWithString: "")

    /// Whether this pill is CURRENTLY rendering the failure-red error
    /// override ("Couldn't connect" / "Unavailable") — drives the border
    /// tone. Set by ``configure(attributedText:isError:)``.
    private var isError = false

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = PopoverColumnGrid.feedPillCornerRadius
        layer?.borderWidth = PopoverColumnGrid.feedPillBorderWidth

        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byClipping
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .vertical)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: PopoverColumnGrid.feedPillHorizontalPadding),
            label.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -PopoverColumnGrid.feedPillHorizontalPadding),
            label.topAnchor.constraint(
                equalTo: topAnchor, constant: PopoverColumnGrid.feedPillVerticalPadding),
            label.bottomAnchor.constraint(
                equalTo: bottomAnchor, constant: -PopoverColumnGrid.feedPillVerticalPadding),
        ])

        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Non-interactive — a pill never routes a click; the row's own controls
    /// do all the interaction (mirrors `LevelMeterView`/`RouteArmedDotView`).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Push this pill's content. `attributedText` is pre-composed by the row
    /// (already carrying a leading `FeedChip` attachment when the segment is
    /// a redirected app, and/or the leading AP1 micro-tag prefix on the FIRST
    /// visible pill) — this view only draws the border/fill chrome around it.
    func configure(attributedText: NSAttributedString, isError: Bool) {
        label.attributedStringValue = attributedText
        self.isError = isError
        updateAppearance()
    }

    /// The border/fill are static `CGColor`s on the layer, so a live light/
    /// dark or Increase-Contrast switch needs a manual re-stamp (same
    /// discipline as `DeviceRowView.updateMuteTint()`). The fill uses the
    /// stock semantic `NSColor.quaternaryLabelColor` — AppKit's own "very
    /// subtle wash" token — rather than a bespoke alpha blend, per the house
    /// rule to reach for a stock semantic color before inventing one; the
    /// border uses the existing `Tokens.Color.hairline` token (already tuned
    /// for a subtle-but-legible divider in both themes) so the pill's outline
    /// reads as a sibling of the row's other hairline strokes. The failure-red
    /// override pill borders in a dimmed `Tokens.Color.failure` instead, so
    /// its outline still reads as an error without competing with the ring.
    private func updateAppearance() {
        let borderColor = isError
            ? Tokens.Color.failure.withAlphaComponent(0.5)
            : Tokens.Color.hairline
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = borderColor.cgColor
            layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
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

    private func firstRunColor() -> NSColor? {
        let attr = label.attributedStringValue
        guard attr.length > 0 else { return nil }
        return attr.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    }
}
