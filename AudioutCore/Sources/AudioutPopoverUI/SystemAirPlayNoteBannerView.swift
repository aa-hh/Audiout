// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutSharedUI

/// The popover's single note-slot banner, originally the "double-path audio"
/// note (Wave 3 W3-T3, `BackendEvent.systemDefaultIsAirPlayActive`) — shown
/// when the macOS SYSTEM default output is itself an AirPlay device WHILE this
/// app is actively streaming a captured whole-system mix to AirPlay, which
/// risks the same audio going out twice (echo). The iOS Status Banner recipe:
/// the tier's tint on a `TintedNoteBackgroundView`, a glyph and a wrapping label. `.info` (the
/// default) carries this note and the takeover strip; `.warning` carries
/// T-UI's routing-blocked-needs-default note, the urgent tier that reuses the
/// silence banner's own tint rather than forking a second banner class.
final class SystemAirPlayNoteBannerView: TintedNoteBackgroundView {

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

    /// Tint tier (T-UI, routing-blocked-needs-default). `.info` is a note the
    /// reader can act on later, so it wears `ring`; `.warning` is a real
    /// problem — routing is dead — so it wears `failure`. `.question` is an
    /// info note that asks the reader something (the expired-trial survey
    /// invite): `ring` like `.info`, with a speech bubble for its glyph.
    enum Severity {
        case info
        case warning
        case question

        var tintColor: NSColor {
            switch self {
            case .info, .question: return Tokens.Color.ring
            case .warning: return Tokens.Color.failure
            }
        }
        var symbolName: String {
            switch self {
            case .info: return "info.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .question: return "bubble.left.fill"
            }
        }
        var accessibilityDescription: String {
            switch self {
            case .info: return "Note"
            case .warning: return "Warning"
            case .question: return "Question"
            }
        }
    }

    /// The copy label, exposed so the panel can read it back for tests.
    let label: NSTextField
    private let actionButton: NSButton?
    private var actionHandler: (() -> Void)?
    private let textActionButton: NSButton?
    private let iconView: NSImageView
    private var textActionHandler: (() -> Void)?
    private let severity: Severity

    /// `textAction` is an optional underlined text link drawn left of the
    /// action button ("I have a key" beside "Buy Audiout").
    init(text: String, maxTextWidth: CGFloat, action: Action? = nil,
         textAction: Action? = nil, severity: Severity = .info) {
        self.severity = severity
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: severity.symbolName,
                             accessibilityDescription: severity.accessibilityDescription)
        icon.symbolConfiguration = .init(pointSize: 15, weight: .semibold)
        icon.contentTintColor = severity.tintColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)
        self.iconView = icon

        // An info or question note's button is the gold call to action
        // (owner's call, 2026-10-19); a warning's stays the plain small bezel,
        // so gold never sits on the failure tint.
        var button: NSButton?
        if let action {
            let b: NSButton
            if severity == .warning {
                b = NSButton(title: action.title, target: nil, action: nil)
                b.bezelStyle = .rounded
                b.controlSize = .small
            } else {
                // Large draws a 24 pt bezel, the library's ProminentButton.
                b = ProminentButton(title: action.title, target: nil, action: nil)
                b.controlSize = .large
            }
            b.translatesAutoresizingMaskIntoConstraints = false
            b.setContentHuggingPriority(.required, for: .horizontal)
            b.setContentCompressionResistancePriority(.required, for: .horizontal)
            b.setAccessibilityLabel(action.accessibilityLabel)
            button = b
        }
        self.actionButton = button
        self.actionHandler = action?.handler

        let labelFont = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        var linkButton: NSButton?
        if let textAction {
            let b = TextLinkButton(title: textAction.title, size: .body)
            b.translatesAutoresizingMaskIntoConstraints = false
            b.setContentHuggingPriority(.required, for: .horizontal)
            b.setContentCompressionResistancePriority(.required, for: .horizontal)
            b.setAccessibilityLabel(textAction.accessibilityLabel)
            linkButton = b
        }
        self.textActionButton = linkButton
        self.textActionHandler = textAction?.handler

        // Reserve the buttons' fitted widths (plus their spacing) out of the
        // text's wrap width so a button doesn't force the whole banner wider
        // than `maxTextWidth` — computed from the real buttons, not a guess.
        let buttonReserve = (button.map { $0.fittingSize.width + 10 } ?? 0)
            + (linkButton.map { $0.fittingSize.width + 10 } ?? 0)

        let text = NSTextField(wrappingLabelWithString: text)
        text.font = labelFont
        text.textColor = Tokens.Color.label
        text.isSelectable = false
        text.translatesAutoresizingMaskIntoConstraints = false
        text.preferredMaxLayoutWidth = max(100, maxTextWidth - buttonReserve)
        self.label = text

        super.init(tint: severity.tintColor)
        translatesAutoresizingMaskIntoConstraints = false

        // The icon+text pair sits at its own natural (leading-hugging) width —
        // it does NOT stretch to fill the banner. The button is a SEPARATE
        // view pinned to the banner's trailing edge, not a third stack member:
        // an all-in-one-stack layout left the button hugging the text with
        // any leftover width stranded past it, against the banner's true
        // trailing edge, instead of where the eye expects a CTA to sit.
        // The icon centres on the text, and every control centres on the
        // banner, so glyph and controls share one line however far the text
        // wraps (owner's call, 2026-09-26).
        let leading = NSStackView(views: [icon, text])
        leading.orientation = .horizontal
        leading.alignment = .centerY
        leading.spacing = 10
        leading.translatesAutoresizingMaskIntoConstraints = false
        addSubview(leading)
        // The text keeps 10 pt above and below, but the banner also grows to
        // hold the button with 8 pt to spare, so a one-line note with the
        // gold button is 44 pt tall (the library's NoteBanner). The low
        // priority pins keep the banner as short as both allow.
        let hugTop = leading.topAnchor.constraint(equalTo: topAnchor, constant: 10)
        let hugBottom = leading.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10)
        hugTop.priority = .defaultLow
        hugBottom.priority = .defaultLow
        NSLayoutConstraint.activate([
            hugTop, hugBottom,
            leading.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 10),
            leading.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -10),
            leading.centerYAnchor.constraint(equalTo: centerYAnchor),
            leading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
        ])
        if let linkButton {
            addSubview(linkButton)
            var pins = [
                leading.trailingAnchor.constraint(lessThanOrEqualTo: linkButton.leadingAnchor, constant: -10),
                linkButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            ]
            if let button {
                addSubview(button)
                pins += [
                    linkButton.trailingAnchor.constraint(equalTo: button.leadingAnchor, constant: -10),
                    button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
                    button.centerYAnchor.constraint(equalTo: centerYAnchor),
                ]
            } else {
                pins.append(linkButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14))
            }
            NSLayoutConstraint.activate(pins)
        } else if let button {
            addSubview(button)
            NSLayoutConstraint.activate([
                leading.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -10),
                button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
                button.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        } else {
            leading.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14).isActive = true
        }

        if let button {
            NSLayoutConstraint.activate([
                button.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 8),
                button.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),
            ])
        }

        button?.target = self
        button?.action = #selector(actionButtonTapped)
        linkButton?.target = self
        linkButton?.action = #selector(textActionButtonTapped)

        // A GROUP, not one static string: the banner carries a label and — when
        // it has one — a real button, so VoiceOver must be able to step into it
        // and reach the action. `.staticText` swallowed the button entirely.
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(text.stringValue)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func actionButtonTapped() { actionHandler?() }
    @objc private func textActionButtonTapped() { textActionHandler?() }

    // MARK: Test-support hooks

    /// Whether this instance was built with an action button.
    var test_hasActionButton: Bool { actionButton != nil }
    /// The action button's accessibility label, or `nil` if there is none.
    var test_actionButtonAccessibilityLabel: String? { actionButton?.accessibilityLabel() }
    /// Simulate a click on the action button. No-op if there isn't one.
    func test_tapActionButton() { actionButtonTapped() }
    /// Whether this instance was built with an underlined text action.
    var test_hasTextAction: Bool { textActionButton != nil }
    /// Click the text action through the button's own target/action.
    func test_tapTextAction() {
        guard let b = textActionButton else { return }
        _ = b.target?.perform(b.action, with: b)
    }
    /// The two controls, for layout and styling assertions.
    var test_textActionButton: NSButton? { textActionButton }
    var test_actionButton: NSButton? { actionButton }
    var test_iconView: NSImageView { iconView }
}
