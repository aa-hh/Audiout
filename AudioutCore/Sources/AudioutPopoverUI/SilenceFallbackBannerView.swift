// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutSharedUI

/// The popover's "Speakers unreachable — playing on this Mac" banner (Wave 2
/// W2-T2, R11). A stock system-orange rounded inset card with a warning glyph and
/// a wrapping label — the same grouped-container warning look the onboarding
/// permission-lost banner uses, rebuilt self-contained here so PopoverUI need not
/// depend on OnboardingUI. System colors only; no custom drawing beyond the
/// layer-backed rounded rect.
final class SilenceFallbackBannerView: NSView {

    /// The same title + accessibility label + handler triple the note banner
    /// carries — the two banners' actions are the same thing, so this is a
    /// straight alias rather than a second struct (or a shared base class).
    typealias Action = SystemAirPlayNoteBannerView.Action

    /// The copy label, exposed so the panel can read it back for tests.
    let label: NSTextField
    private let actionButton: NSButton?
    private var actionHandler: (() -> Void)?

    init(text: String, maxTextWidth: CGFloat, action: Action? = nil) {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                             accessibilityDescription: "Warning")
        icon.symbolConfiguration = .init(pointSize: 15, weight: .semibold)
        icon.contentTintColor = Tokens.Color.warning
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)

        var button: NSButton?
        if let action {
            let b = NSButton(title: action.title, target: nil, action: nil)
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.translatesAutoresizingMaskIntoConstraints = false
            b.setContentHuggingPriority(.required, for: .horizontal)
            b.setContentCompressionResistancePriority(.required, for: .horizontal)
            b.setAccessibilityLabel(action.accessibilityLabel)
            button = b
        }
        self.actionButton = button
        self.actionHandler = action?.handler

        // Reserve the button's fitted width (plus its stack spacing) out of the
        // text's wrap width so a button doesn't force the whole banner wider
        // than `maxTextWidth` — computed from the real button, not a guess.
        let buttonReserve = button.map { $0.fittingSize.width + 10 } ?? 0

        let text = NSTextField(wrappingLabelWithString: text)
        text.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        text.textColor = .labelColor
        text.isSelectable = false
        text.translatesAutoresizingMaskIntoConstraints = false
        text.preferredMaxLayoutWidth = max(100, maxTextWidth - buttonReserve)
        self.label = text

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Tokens.Layout.bannerCornerRadius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        stampLayerColors()

        // The icon+text pair sits at its own natural (leading-hugging) width;
        // the button is a SEPARATE view pinned to the banner's trailing edge,
        // not a third stack member — the note banner's layout, for the same
        // reason: in one stack the button hugs the text and strands the leftover
        // width past it, away from where the eye expects a CTA.
        let row = NSStackView(views: [icon, text])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
        ])
        if let button {
            addSubview(button)
            NSLayoutConstraint.activate([
                row.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -10),
                button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
                button.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            ])
        } else {
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14).isActive = true
        }

        button?.target = self
        button?.action = #selector(actionButtonTapped)

        // A GROUP, not one static string: with an action the banner carries a
        // real button, so VoiceOver must be able to step in and reach it.
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(text.stringValue)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func actionButtonTapped() { actionHandler?() }

    /// Keep the CGColor-backed fills correct across light/dark appearance
    /// switches (layer colors don't auto-resolve dynamic `NSColor`s).
    ///
    /// `wantsUpdateLayer` is what makes this run at all: without it AppKit takes
    /// the `draw(_:)` path and `updateLayer()` is never called, so the re-stamp
    /// below sat dead and the banner kept its build-time appearance across a
    /// live light/dark flip.
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        super.updateLayer()
        stampLayerColors()
    }

    /// The one place the tint is resolved and stamped — under the view's own
    /// effective appearance, the `ConnectionDiagnosisView.applyBackgroundTint`
    /// idiom, so a dynamic token resolves for the appearance actually on screen.
    private func stampLayerColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Tokens.Color.warning.withAlphaComponent(0.14).cgColor
            layer?.borderColor = Tokens.Color.warning.withAlphaComponent(0.40).cgColor
        }
    }

    // MARK: Test-support hooks

    /// Whether this instance was built with an action button.
    var test_hasActionButton: Bool { actionButton != nil }
    /// Simulate a click on the action button. No-op if there isn't one.
    func test_tapActionButton() { actionButtonTapped() }

    /// The layer's currently-stamped fill/border, read back as `NSColor` —
    /// asserts they resolve from `Tokens.Color.warning`, not a raw
    /// `NSColor.systemOrange` literal.
    var test_backgroundColor: NSColor? {
        guard let cgColor = layer?.backgroundColor else { return nil }
        return NSColor(cgColor: cgColor)
    }
    var test_borderColor: NSColor? {
        guard let cgColor = layer?.borderColor else { return nil }
        return NSColor(cgColor: cgColor)
    }
}
