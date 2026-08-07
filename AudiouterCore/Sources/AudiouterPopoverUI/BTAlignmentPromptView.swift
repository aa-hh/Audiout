// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterSharedUI

/// The first-mix alignment card (W3, PLAN-UNIVERSAL-SYNC "ALIGNMENT WIZARD UX
/// LOCKED"): an anchored inset card under a just-held-silent Bluetooth row —
/// the `ConnectionDiagnosisView` pattern, minus the failure tint (this is an
/// offer, not an error). One locked sentence of copy and three actions; the
/// HOST (`PopoverController`) owns what each action does — this view renders
/// and forwards clicks, nothing more. Never a modal.
final class BTAlignmentPromptView: NSView {

    /// The locked one-sentence explanation.
    static let promptCopy =
        "Bluetooth speakers each run on their own delay — a quick alignment keeps everything in step"

    var onAlignWithMusic: (() -> Void)?
    var onAlignWithTicks: (() -> Void)?
    var onNotNow: (() -> Void)?

    private static let horizontalInset: CGFloat = 10
    private static var leadingInset: CGFloat {
        PopoverColumnGrid.firstElementLeading(indented: false)
    }
    private static let verticalInset: CGFloat = 4
    private static let contentPadding: CGFloat = 10
    private static let backgroundCornerRadius: CGFloat = 7
    private static let copyToButtons: CGFloat = 8
    private static let buttonSpacing: CGFloat = 8

    private let background = NSView()
    private let copyLabel = NSTextField(wrappingLabelWithString: BTAlignmentPromptView.promptCopy)
    private let musicButton = NSButton()
    private let ticksButton = NSButton()
    private let notNowButton = NSButton()
    private var copyWidthConstraint: NSLayoutConstraint?

    init(deviceName: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 0))
        autoresizingMask = [.width]
        translatesAutoresizingMaskIntoConstraints = true
        buildSubviews(deviceName: deviceName)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildSubviews(deviceName: String) {
        wantsLayer = true

        background.translatesAutoresizingMaskIntoConstraints = false
        background.wantsLayer = true
        background.layer?.cornerRadius = Self.backgroundCornerRadius
        background.layer?.cornerCurve = .continuous
        applyBackgroundTint()
        addSubview(background)

        copyLabel.translatesAutoresizingMaskIntoConstraints = false
        copyLabel.font = .systemFont(ofSize: 11)
        copyLabel.textColor = Tokens.Color.secondaryLabel
        background.addSubview(copyLabel)

        configureSmallButton(musicButton, title: "Align with your music",
                             action: #selector(musicClicked(_:)))
        configureSmallButton(ticksButton, title: "Align with ticks",
                             action: #selector(ticksClicked(_:)))
        configureSmallButton(notNowButton, title: "Not now",
                             action: #selector(notNowClicked(_:)))
        background.addSubview(musicButton)
        background.addSubview(ticksButton)
        background.addSubview(notNowButton)

        let copyWidth = copyLabel.widthAnchor.constraint(equalToConstant: 300)
        copyWidthConstraint = copyWidth

        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: topAnchor, constant: Self.verticalInset),
            background.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.verticalInset),
            background.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leadingInset),
            background.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalInset),

            copyLabel.topAnchor.constraint(equalTo: background.topAnchor, constant: Self.contentPadding),
            copyLabel.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: Self.contentPadding),
            copyWidth,

            musicButton.topAnchor.constraint(equalTo: copyLabel.bottomAnchor, constant: Self.copyToButtons),
            musicButton.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: Self.contentPadding),
            musicButton.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -Self.contentPadding),

            ticksButton.leadingAnchor.constraint(
                equalTo: musicButton.trailingAnchor, constant: Self.buttonSpacing),
            ticksButton.centerYAnchor.constraint(equalTo: musicButton.centerYAnchor),

            notNowButton.leadingAnchor.constraint(
                equalTo: ticksButton.trailingAnchor, constant: Self.buttonSpacing),
            notNowButton.centerYAnchor.constraint(equalTo: musicButton.centerYAnchor),
            notNowButton.trailingAnchor.constraint(
                lessThanOrEqualTo: background.trailingAnchor, constant: -Self.contentPadding),
        ])

        setAccessibilityElement(false)
        background.setAccessibilityElement(true)
        background.setAccessibilityRole(.group)
        background.setAccessibilityLabel("Align \(deviceName): \(Self.promptCopy)")
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

    /// The inset container seat — `well` fill + `hairline` rim (the
    /// `GroupedSectionView` pair), NO failure tint (house rule 8: the failure
    /// red stays failure-exclusive).
    private func applyBackgroundTint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            // Inset containers use the well + hairline pair, never bare `panel`:
            // panel vs canvas is ~1.06:1 dark / ~1.08:1 light — "effectively
            // invisible as a boundary" (`MembershipWellContrastTests`, and the
            // `GroupedSectionView` precedent this mirrors).
            background.layer?.backgroundColor = Tokens.Color.well.cgColor
            background.layer?.borderColor = Tokens.Color.hairline.cgColor
            background.layer?.borderWidth = 1
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBackgroundTint()
    }

    override func layout() {
        let available = bounds.width - Self.leadingInset - Self.horizontalInset - 2 * Self.contentPadding
        if available > 0, copyWidthConstraint?.constant != available {
            copyWidthConstraint?.constant = available
        }
        super.layout()
    }

    @objc private func musicClicked(_ sender: NSButton) { onAlignWithMusic?() }
    @objc private func ticksClicked(_ sender: NSButton) { onAlignWithTicks?() }
    @objc private func notNowClicked(_ sender: NSButton) { onNotNow?() }

    // MARK: Test-support hooks (real dispatch — `performClick` runs the same
    // target/action AppKit runs)

    var test_copyText: String { copyLabel.stringValue }
    var test_buttonTitles: [String] { [musicButton, ticksButton, notNowButton].map(\.title) }
    func test_clickAlignWithMusic() { musicButton.performClick(nil) }
    func test_clickAlignWithTicks() { ticksButton.performClick(nil) }
    func test_clickNotNow() { notNowButton.performClick(nil) }
}
