// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterSharedUI

/// The popover's "Speakers unreachable — playing on this Mac" banner (Wave 2
/// W2-T2, R11). A stock system-orange rounded inset card with a warning glyph and
/// a wrapping label — the same grouped-container warning look the onboarding
/// permission-lost banner uses, rebuilt self-contained here so PopoverUI need not
/// depend on OnboardingUI. System colors only; no custom drawing beyond the
/// layer-backed rounded rect.
final class SilenceFallbackBannerView: NSView {

    /// The copy label, exposed so the panel can read it back for tests.
    let label: NSTextField

    init(text: String, maxTextWidth: CGFloat) {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                             accessibilityDescription: "Warning")
        icon.symbolConfiguration = .init(pointSize: 15, weight: .semibold)
        icon.contentTintColor = .systemOrange
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)

        let text = NSTextField(wrappingLabelWithString: text)
        text.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        text.textColor = .labelColor
        text.isSelectable = false
        text.translatesAutoresizingMaskIntoConstraints = false
        text.preferredMaxLayoutWidth = max(100, maxTextWidth)
        self.label = text

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Tokens.Layout.bannerCornerRadius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.14).cgColor
        layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.40).cgColor

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
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
        ])

        setAccessibilityRole(.staticText)
        setAccessibilityLabel(text.stringValue)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Keep the CGColor-backed fills correct across light/dark appearance switches
    /// (layer colors don't auto-resolve dynamic `NSColor`s).
    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.14).cgColor
        layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.40).cgColor
    }
}
