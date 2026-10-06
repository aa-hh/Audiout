// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutSharedUI

/// The first-join alignment note (W3): an anchored inset note under a
/// never-aligned Bluetooth row that is already playing, a little behind the
/// rest. One wrapping sentence whose tail is the invitation, plus a ✕ that
/// hides it for the session. The HOST (`PopoverController`) owns what each
/// action does — this view renders and forwards clicks, nothing more. Never a
/// modal, and it never silences anything.
final class BTAlignmentNoteView: NSView {

    // MARK: Locked copy

    /// The explanation half — everything before the invitation.
    static func noteLead(name: String) -> String {
        "\(name) plays a little behind the other speakers until it’s aligned. "
    }

    /// The invitation half, drawn in gold: the clickable end of the sentence.
    static let noteAlignCall = "Align it now."

    /// The whole sentence, as it reads on screen.
    static func noteCopy(name: String) -> String {
        noteLead(name: name) + noteAlignCall
    }

    var onAlign: (() -> Void)?
    var onHide: (() -> Void)?

    private static let horizontalInset: CGFloat = 10
    private static var leadingInset: CGFloat {
        PopoverColumnGrid.firstElementLeading(indented: false)
    }
    private static let verticalInset: CGFloat = 4
    private static let contentPadding: CGFloat = 10
    private static let backgroundCornerRadius: CGFloat = Tokens.Layout.Radius.control
    /// Sized with the ✕'s 24 pt hit area and 6 pt inset so the sentence keeps
    /// the wrap width it had beside the old 16 pt ✕.
    private static let copyToHideGap: CGFloat = 4
    private static let hideButtonSize: CGFloat = 24

    /// The sentence is drawn by a label but CLICKED as a button: passing the
    /// hit test through is what lets the wrapping label keep its own width
    /// logic while the whole sentence stays one control.
    private final class PassThroughLabel: NSTextField {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    private let background = NSView()
    private let sentenceButton = NSButton()
    private let copyLabel = PassThroughLabel(labelWithString: "")
    private lazy var hideButton = NSButton.noticeDismissButton(
        target: self, action: #selector(hideClicked(_:)))
    private var copyWidthConstraint: NSLayoutConstraint?
    private let deviceName: String

    init(deviceName: String) {
        self.deviceName = deviceName
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 0))
        autoresizingMask = [.width]
        translatesAutoresizingMaskIntoConstraints = true
        buildSubviews()
        redrawOnAccessibilityDisplayChange()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildSubviews() {
        wantsLayer = true

        background.translatesAutoresizingMaskIntoConstraints = false
        background.wantsLayer = true
        background.layer?.cornerRadius = Self.backgroundCornerRadius
        background.layer?.cornerCurve = .continuous
        applyBackgroundTint()
        addSubview(background)

        sentenceButton.translatesAutoresizingMaskIntoConstraints = false
        sentenceButton.isBordered = false
        sentenceButton.title = ""
        sentenceButton.target = self
        sentenceButton.action = #selector(alignClicked(_:))
        // The button's label is the visible clickable text — the sentence,
        // not the device name. The parent group already carries the device
        // name in its own label (see `background.setAccessibilityLabel`
        // below), and the tooltip keeps the full sentence.
        sentenceButton.setAccessibilityLabel(Self.noteAlignCall)
        sentenceButton.toolTip = Self.noteCopy(name: deviceName)
        background.addSubview(sentenceButton)

        copyLabel.translatesAutoresizingMaskIntoConstraints = false
        copyLabel.maximumNumberOfLines = 0
        copyLabel.lineBreakMode = .byWordWrapping
        copyLabel.attributedStringValue = Self.attributedCopy(name: deviceName)
        copyLabel.setAccessibilityElement(false)
        sentenceButton.addSubview(copyLabel)

        background.addSubview(hideButton)

        let copyWidth = copyLabel.widthAnchor.constraint(equalToConstant: 300)
        copyWidthConstraint = copyWidth

        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: topAnchor, constant: Self.verticalInset),
            background.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.verticalInset),
            background.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leadingInset),
            background.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalInset),

            sentenceButton.topAnchor.constraint(equalTo: background.topAnchor,
                                                constant: Self.contentPadding),
            sentenceButton.leadingAnchor.constraint(equalTo: background.leadingAnchor,
                                                    constant: Self.contentPadding),
            sentenceButton.bottomAnchor.constraint(equalTo: background.bottomAnchor,
                                                   constant: -Self.contentPadding),

            copyLabel.topAnchor.constraint(equalTo: sentenceButton.topAnchor),
            copyLabel.leadingAnchor.constraint(equalTo: sentenceButton.leadingAnchor),
            copyLabel.trailingAnchor.constraint(equalTo: sentenceButton.trailingAnchor),
            copyLabel.bottomAnchor.constraint(equalTo: sentenceButton.bottomAnchor),
            copyWidth,

            hideButton.leadingAnchor.constraint(equalTo: sentenceButton.trailingAnchor,
                                                constant: Self.copyToHideGap),
            hideButton.trailingAnchor.constraint(equalTo: background.trailingAnchor,
                                                 constant: -NSButton.noticeDismissInset),
            hideButton.topAnchor.constraint(equalTo: background.topAnchor,
                                            constant: NSButton.noticeDismissInset),
            hideButton.widthAnchor.constraint(equalToConstant: Self.hideButtonSize),
            hideButton.heightAnchor.constraint(equalToConstant: Self.hideButtonSize),
        ])

        setAccessibilityElement(false)
        background.setAccessibilityElement(true)
        background.setAccessibilityRole(.group)
        background.setAccessibilityLabel(Self.noteCopy(name: deviceName))
    }

    /// The sentence: explanation in the compact secondary voice, invitation in
    /// `goldText` semibold (`gold` is a fill, too faint as light-mode text) — one string so it wraps as one paragraph.
    private static func attributedCopy(name: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let text = NSMutableAttributedString(
            string: noteLead(name: name),
            attributes: [.font: Tokens.Font.detail,
                         .foregroundColor: Tokens.Color.label2,
                         .paragraphStyle: paragraph])
        text.append(NSAttributedString(
            string: noteAlignCall,
            attributes: [.font: NSFont.systemFont(ofSize: Tokens.Font.detail.pointSize,
                                                  weight: .semibold),
                         .foregroundColor: Tokens.Color.goldText,
                         .paragraphStyle: paragraph]))
        return text
    }

    /// The inset container seat — `well` fill + `containerEdge` rim (the
    /// `GroupedSectionView` pair), NO failure tint (house rule 8: the failure
    /// red stays failure-exclusive).
    private func applyBackgroundTint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            // Inset containers use the well + containerEdge pair, never bare
            // `panel`: panel vs canvas is 1.060:1 dark / 1.000:1 light —
            // "effectively invisible as a boundary" (`MembershipWellContrastTests`,
            // and the `GroupedSectionView` precedent this mirrors). This seat's
            // outer rim is a container edge, so it takes the heavier weight;
            // `hairline` stays for rules drawn inside a container.
            background.layer?.backgroundColor = Tokens.Color.well.cgColor
            background.layer?.borderColor = Tokens.Color.containerEdge.cgColor
            background.layer?.borderWidth = 1
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBackgroundTint()
        copyLabel.attributedStringValue = Self.attributedCopy(name: deviceName)
    }

    /// The Increase Contrast toggle changes no appearance; its redraw request
    /// lands here, where the frozen layer colours are restamped.
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        super.updateLayer()
        applyBackgroundTint()
        copyLabel.needsDisplay = true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(sentenceButton.convert(sentenceButton.bounds, to: self),
                      cursor: .pointingHand)
    }

    override func layout() {
        let available = bounds.width - Self.leadingInset - Self.horizontalInset
            - Self.contentPadding - Self.copyToHideGap - Self.hideButtonSize - NSButton.noticeDismissInset
        if available > 0, copyWidthConstraint?.constant != available {
            copyWidthConstraint?.constant = available
        }
        super.layout()
    }

    @objc private func alignClicked(_ sender: NSButton) { onAlign?() }
    @objc private func hideClicked(_ sender: NSButton) { onHide?() }

    // MARK: Test-support hooks (real dispatch — `performClick` runs the same
    // target/action AppKit runs)

    var test_copyText: String { copyLabel.attributedStringValue.string }
    func test_clickAlign() { sentenceButton.performClick(nil) }
    func test_clickHide() { hideButton.performClick(nil) }
}
