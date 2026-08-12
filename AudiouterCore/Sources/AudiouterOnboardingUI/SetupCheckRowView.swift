// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterCore
import AudiouterSharedUI

/// The sixth row in the Setup column: the automatic final check, made visible.
/// A STATUS row, not a card — never expandable, no body, no Allow/Skip — but
/// in the column's visual grammar: the same surface, icon tile, title, and
/// trailing accessory slot every collapsed strip uses. Driven by
/// ``SetupFinalCheckState``:
///
/// - `pending` is dormant like a locked card's dimming but with NO padlock —
///   the row isn't permission-locked, it's waiting its turn.
/// - `running` shows the small spinner in the trailing slot (the same "a wait
///   on screen says what it is waiting for" rule the cards follow: the title
///   itself names the wait).
/// - `passed` earns the same green checkmark a completed card gets.
///
/// The glyph is `Tokens.Color.gold` ON PURPOSE, not a permission hue: this
/// row is the first note of the finale's colour story (gold ripple, gold
/// CTA). Like every tile the tint is PERMANENT and only the glyph carries it;
/// `OnboardingPermissionColorTests` measures gold ≥3:1 on `raised` in both
/// appearances.
final class SetupCheckRowView: NSView {

    private let iconTile = IconTileView(symbolName: "checklist",
                                        accessibility: "Setup check",
                                        color: Tokens.Color.gold,
                                        side: SetupSpineRowView.iconSide,
                                        pointSize: 11)
    private let titleLabel = NSTextField(labelWithString: "")
    private let checkmark = NSImageView()
    private let spinner = NSProgressIndicator()
    private var surface: RoundedContainerView!

    private(set) var state: SetupFinalCheckState = .pending

    init() {
        super.init(frame: .zero)
        build()
        apply(.pending)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false

        // No radius, no border: the sixth row is a full-bleed strip inside the
        // spine's one shared grouped container, same as every permission row
        // above it (`SetupSpineRowView`) — see that file's Direction 04
        // grouped-inset note. The group's own rounding + hairline separators
        // do the work a per-row card used to.
        surface = RoundedContainerView(fill: Tokens.Color.panel, border: .clear, radius: 0)
        addSubview(surface)

        titleLabel.font = Tokens.Font.bodyEmphasized
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        checkmark.image = NSImage(systemSymbolName: "checkmark.circle.fill",
                                  accessibilityDescription: "Ready")
        checkmark.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        checkmark.contentTintColor = Tokens.Color.success
        checkmark.translatesAutoresizingMaskIntoConstraints = false

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        surface.addSubview(iconTile)
        surface.addSubview(titleLabel)
        surface.addSubview(checkmark)
        surface.addSubview(spinner)

        let inset = SetupSpineRowView.horizontalInset
        let vInset = SetupSpineRowView.headerVerticalInset
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            surface.heightAnchor.constraint(greaterThanOrEqualToConstant: SetupSpineRowView.minHeight),

            iconTile.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: inset),
            iconTile.topAnchor.constraint(equalTo: surface.topAnchor, constant: vInset),
            iconTile.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -vInset),

            titleLabel.leadingAnchor.constraint(equalTo: surface.leadingAnchor,
                                                constant: inset + SetupSpineRowView.iconSide + SetupSpineRowView.iconGap),
            titleLabel.centerYAnchor.constraint(equalTo: iconTile.centerYAnchor),

            // Checkmark and spinner share the cards' one trailing slot.
            checkmark.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -inset),
            checkmark.centerYAnchor.constraint(equalTo: iconTile.centerYAnchor),
            spinner.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -inset),
            spinner.centerYAnchor.constraint(equalTo: iconTile.centerYAnchor),

            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: checkmark.leadingAnchor, constant: -8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: spinner.leadingAnchor, constant: -8),
        ])
    }

    func apply(_ state: SetupFinalCheckState) {
        self.state = state
        titleLabel.stringValue = Self.title(for: state)
        titleLabel.textColor = state == .pending ? Tokens.Color.tertiaryLabel
                                                 : Tokens.Color.secondaryLabel
        // The tile's only state role is the dormant dimming — the glyph tint
        // itself never changes (the no-flash rule).
        iconTile.alphaValue = state == .pending ? SetupSpineRowView.lockedTileAlpha : 1
        checkmark.isHidden = state != .passed
        if state == .running { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        applyAccessibility()
    }

    /// The row's whole voice — the title carries the state, so VoiceOver and
    /// the pixels can never disagree.
    static func title(for state: SetupFinalCheckState) -> String {
        switch state {
        case .pending: return "One last check"
        case .running: return "Making sure everything's ready\u{2026}"
        case .passed:  return "Everything's ready"
        }
    }

    /// Real UI, unlike the decorative demo pane: one element whose label is
    /// the state-carrying title (a group, like a non-live card — there is no
    /// action to offer).
    private func applyAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(titleLabel.stringValue)
    }

    // MARK: Test-support hooks

    var test_title: String { titleLabel.stringValue }
    var test_hasCheckmark: Bool { !checkmark.isHidden }
    var test_isSpinning: Bool { state == .running }
    var test_tileAlpha: CGFloat { iconTile.alphaValue }
    var test_iconTint: NSColor? { iconTile.test_restingTint }
    var test_accessibilityLabel: String? { accessibilityLabel() }
}
