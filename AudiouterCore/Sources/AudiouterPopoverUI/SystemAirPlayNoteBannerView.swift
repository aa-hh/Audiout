// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

/// The popover's "double-path audio" note (Wave 3 W3-T3,
/// `BackendEvent.systemDefaultIsAirPlayActive`) — shown when the macOS SYSTEM
/// default output is itself an AirPlay device WHILE this app is actively
/// streaming a captured whole-system mix to AirPlay, which risks the same
/// audio going out twice (echo). A stock system-blue rounded inset card with
/// an info glyph and a wrapping label — the informational-severity sibling of
/// `SilenceFallbackBannerView` (which uses system-orange for the more urgent
/// "speakers unreachable" condition). System colors only; no custom drawing
/// beyond the layer-backed rounded rect.
final class SystemAirPlayNoteBannerView: NSView {

    /// The copy label, exposed so the panel can read it back for tests.
    let label: NSTextField

    init(text: String, maxTextWidth: CGFloat) {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "info.circle.fill",
                             accessibilityDescription: "Note")
        icon.symbolConfiguration = .init(pointSize: 15, weight: .semibold)
        icon.contentTintColor = .systemBlue
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
        layer?.cornerRadius = 11
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.12).cgColor
        layer?.borderColor = NSColor.systemBlue.withAlphaComponent(0.35).cgColor

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
        layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.12).cgColor
        layer?.borderColor = NSColor.systemBlue.withAlphaComponent(0.35).cgColor
    }
}
