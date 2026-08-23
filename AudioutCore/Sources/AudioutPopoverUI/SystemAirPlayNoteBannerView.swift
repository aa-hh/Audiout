// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutSharedUI

/// The popover's single note-slot banner, originally the "double-path audio"
/// note (Wave 3 W3-T3, `BackendEvent.systemDefaultIsAirPlayActive`) — shown
/// when the macOS SYSTEM default output is itself an AirPlay device WHILE this
/// app is actively streaming a captured whole-system mix to AirPlay, which
/// risks the same audio going out twice (echo). A stock rounded inset card
/// with a glyph and a wrapping label, tinted per `Severity`: `.info`
/// (system-blue, the default) for this and the takeover strip, `.warning`
/// (system-orange, T-UI's routing-blocked-needs-default note) for the more
/// urgent tier — the same tint `SilenceFallbackBannerView` uses for "speakers
/// unreachable", reused here rather than forking a second banner class.
/// System colors only; no custom drawing beyond the layer-backed rounded rect.
final class SystemAirPlayNoteBannerView: NSView {

    /// An optional trailing call-to-action (T6, takeover status strip state 1:
    /// "needs permission" deep-links to Login Items & Extensions). A single
    /// parameter carrying title + accessibility label + handler together, so
    /// the init signature grows by exactly one optional argument rather than
    /// three.
    struct Action {
        let title: String
        let accessibilityLabel: String
        let handler: () -> Void
    }

    /// Tint tier (T-UI, routing-blocked-needs-default): the note slot is
    /// otherwise informational (`.info`, system-blue) — a routing-dead
    /// condition is urgent enough to reuse `SilenceFallbackBannerView`'s
    /// system-orange tier instead, without forking a second banner class.
    enum Severity {
        case info
        case warning

        var tintColor: NSColor {
            switch self {
            case .info: return Tokens.Color.info
            case .warning: return Tokens.Color.warning
            }
        }
        var backgroundAlpha: CGFloat {
            switch self {
            case .info: return 0.12
            case .warning: return 0.14
            }
        }
        var borderAlpha: CGFloat {
            switch self {
            case .info: return 0.35
            case .warning: return 0.40
            }
        }
        var symbolName: String {
            switch self {
            case .info: return "info.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            }
        }
        var accessibilityDescription: String {
            switch self {
            case .info: return "Note"
            case .warning: return "Warning"
            }
        }
    }

    /// The copy label, exposed so the panel can read it back for tests.
    let label: NSTextField
    private let actionButton: NSButton?
    private var actionHandler: (() -> Void)?
    private let severity: Severity

    init(text: String, maxTextWidth: CGFloat, action: Action? = nil, severity: Severity = .info) {
        self.severity = severity
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: severity.symbolName,
                             accessibilityDescription: severity.accessibilityDescription)
        icon.symbolConfiguration = .init(pointSize: 15, weight: .semibold)
        icon.contentTintColor = severity.tintColor
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
        layer?.backgroundColor = severity.tintColor.withAlphaComponent(severity.backgroundAlpha).cgColor
        layer?.borderColor = severity.tintColor.withAlphaComponent(severity.borderAlpha).cgColor

        var rowViews: [NSView] = [icon, text]
        if let button { rowViews.append(button) }
        let row = NSStackView(views: rowViews)
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

        button?.target = self
        button?.action = #selector(actionButtonTapped)

        setAccessibilityRole(.staticText)
        setAccessibilityLabel(text.stringValue)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func actionButtonTapped() { actionHandler?() }

    // MARK: Test-support hooks

    /// Whether this instance was built with an action button.
    var test_hasActionButton: Bool { actionButton != nil }
    /// The action button's accessibility label, or `nil` if there is none.
    var test_actionButtonAccessibilityLabel: String? { actionButton?.accessibilityLabel() }
    /// Simulate a click on the action button. No-op if there isn't one.
    func test_tapActionButton() { actionButtonTapped() }

    /// Keep the CGColor-backed fills correct across light/dark appearance switches
    /// (layer colors don't auto-resolve dynamic `NSColor`s).
    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = severity.tintColor.withAlphaComponent(severity.backgroundAlpha).cgColor
        layer?.borderColor = severity.tintColor.withAlphaComponent(severity.borderAlpha).cgColor
    }

    /// The layer's currently-stamped fill/border, read back as `NSColor` —
    /// asserts they resolve from `Tokens.Color.info`/`.warning`, not a raw
    /// `NSColor.systemBlue`/`.systemOrange` literal.
    var test_backgroundColor: NSColor? {
        guard let cgColor = layer?.backgroundColor else { return nil }
        return NSColor(cgColor: cgColor)
    }
    var test_borderColor: NSColor? {
        guard let cgColor = layer?.borderColor else { return nil }
        return NSColor(cgColor: cgColor)
    }
}
