// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterCore
import AudiouterSharedUI

/// The alignment wizard's anchored panel (W4, PLAN-UNIVERSAL-SYNC "ALIGNMENT
/// WIZARD UX LOCKED"): expands under the Bluetooth row (`ConnectionDiagnosisView`
/// pattern) and renders whatever ``BTAlignmentWizardSession/Screen`` its
/// session is on — intro (one sentence + Start), the which-side question (two
/// big buttons named after the ACTUAL devices + "Can't tell" + a narrowing
/// progress bar), the receipt (the ms value as a receipt only, Keep / Try
/// again), and the graceful exit. The closing education line rides the two
/// terminal screens. This view owns the SESSION driving (start/answer/keep/
/// tryAgain) but not its lifetime — the HOST creates the session, mounts this
/// panel, and tears both down (`onFinished`) so the tick can never outlive
/// the surface.
final class BTAlignmentWizardView: NSView {

    // The locked copy.
    static let introCopy =
        "You'll hear ticks on both speakers — just say which one sounds first"
    static let questionCopy = "Which one ticked first?"
    static let cantTellTitle = "Can't tell"
    static let gracefulExitCopy =
        "These speakers are far apart — they're already as aligned as they need to be."
    static let educationCopy = "You can fine-tune anytime from the popover."

    /// The wizard finished (Keep, graceful-exit Done, or the ✕): the host
    /// removes the panel and disposes of the session.
    var onFinished: (() -> Void)?

    private let session: BTAlignmentWizardSession

    private static let horizontalInset: CGFloat = 10
    private static var leadingInset: CGFloat {
        PopoverColumnGrid.firstElementLeading(indented: false)
    }
    private static let verticalInset: CGFloat = 4
    private static let contentPadding: CGFloat = 10
    private static let backgroundCornerRadius: CGFloat = 7
    private static let rowSpacing: CGFloat = 8
    private static let dismissButtonInset: CGFloat = 6

    private let background = NSView()
    private let contentStack = NSStackView()
    private let dismissButton = NSButton()

    init(session: BTAlignmentWizardSession) {
        self.session = session
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 0))
        autoresizingMask = [.width]
        translatesAutoresizingMaskIntoConstraints = true
        buildChrome()
        session.onScreenChange = { [weak self] screen in self?.render(screen) }
        render(session.screen)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Chrome

    private func buildChrome() {
        wantsLayer = true
        background.translatesAutoresizingMaskIntoConstraints = false
        background.wantsLayer = true
        background.layer?.cornerRadius = Self.backgroundCornerRadius
        background.layer?.cornerCurve = .continuous
        applyBackgroundTint()
        addSubview(background)

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = Self.rowSpacing
        background.addSubview(contentStack)

        dismissButton.translatesAutoresizingMaskIntoConstraints = false
        dismissButton.bezelStyle = .accessoryBar
        dismissButton.isBordered = false
        dismissButton.imagePosition = .imageOnly
        dismissButton.contentTintColor = Tokens.Color.tertiaryLabel
        dismissButton.target = self
        dismissButton.action = #selector(dismissClicked(_:))
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 9.5, weight: .bold)
        dismissButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss")?
            .withSymbolConfiguration(symbolConfig)
        dismissButton.setAccessibilityLabel("Dismiss")
        background.addSubview(dismissButton)

        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: topAnchor, constant: Self.verticalInset),
            background.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.verticalInset),
            background.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leadingInset),
            background.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalInset),

            dismissButton.topAnchor.constraint(
                equalTo: background.topAnchor, constant: Self.dismissButtonInset),
            dismissButton.trailingAnchor.constraint(
                equalTo: background.trailingAnchor, constant: -Self.dismissButtonInset),

            contentStack.topAnchor.constraint(
                equalTo: background.topAnchor, constant: Self.contentPadding),
            contentStack.leadingAnchor.constraint(
                equalTo: background.leadingAnchor, constant: Self.contentPadding),
            contentStack.trailingAnchor.constraint(
                lessThanOrEqualTo: background.trailingAnchor, constant: -Self.contentPadding),
            contentStack.bottomAnchor.constraint(
                equalTo: background.bottomAnchor, constant: -Self.contentPadding),
        ])

        setAccessibilityElement(false)
        background.setAccessibilityElement(true)
        background.setAccessibilityRole(.group)
    }

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

    // MARK: Screen rendering

    private func render(_ screen: BTAlignmentWizardSession.Screen) {
        for view in contentStack.arrangedSubviews {
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        switch screen {
        case .intro:
            addBody(Self.introCopy)
            addButtonRow([makeButton("Start", prominent: true, #selector(startClicked(_:)))])
            background.setAccessibilityLabel("Align \(session.targetName): \(Self.introCopy)")
        case .question(let progress, _):
            addBody(Self.questionCopy)
            addButtonRow([
                makeButton(session.targetName, prominent: true, #selector(targetClicked(_:))),
                makeButton(session.referenceName, prominent: true, #selector(referenceClicked(_:))),
                makeButton(Self.cantTellTitle, prominent: false, #selector(cantTellClicked(_:))),
            ])
            addProgress(progress)
            background.setAccessibilityLabel(
                "Which speaker ticked first: \(session.targetName) or \(session.referenceName)?")
        case .receipt(let trimMs):
            let wholeMs = Int(BTSyncTrim.quantise(trimMs))
            addBody("Aligned — \(wholeMs) ms")
            addButtonRow([
                makeButton("Keep", prominent: true, #selector(keepClicked(_:))),
                makeButton("Try again", prominent: false, #selector(tryAgainClicked(_:))),
            ])
            addEducationLine()
            background.setAccessibilityLabel("Aligned at \(wholeMs) milliseconds")
        case .gracefulExit:
            addBody(Self.gracefulExitCopy)
            addButtonRow([makeButton("Done", prominent: true, #selector(doneClicked(_:)))])
            addEducationLine()
            background.setAccessibilityLabel(Self.gracefulExitCopy)
        }
        needsLayout = true
        // The stack changed height — the host panel re-measures via the same
        // autoresizing chain the diagnosis panel uses; nothing to call here.
        invalidateIntrinsicContentSize()
    }

    private func addBody(_ text: String) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.preferredMaxLayoutWidth = 260
        contentStack.addArrangedSubview(label)
    }

    private func addEducationLine() {
        let label = NSTextField(wrappingLabelWithString: Self.educationCopy)
        label.font = .systemFont(ofSize: 11)
        label.textColor = Tokens.Color.secondaryLabel
        label.preferredMaxLayoutWidth = 260
        contentStack.addArrangedSubview(label)
    }

    private func addButtonRow(_ buttons: [NSButton]) {
        let row = NSStackView(views: buttons)
        row.orientation = .horizontal
        row.spacing = 8
        contentStack.addArrangedSubview(row)
    }

    private func addProgress(_ progress: Double) {
        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.doubleValue = progress
        bar.controlSize = .small
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.widthAnchor.constraint(equalToConstant: 180).isActive = true
        bar.setAccessibilityLabel("Narrowing in")
        contentStack.addArrangedSubview(bar)
    }

    private func makeButton(_ title: String, prominent: Bool, _ action: Selector) -> NSButton {
        let button = NSButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.title = title
        button.bezelStyle = .rounded
        button.controlSize = prominent ? .regular : .small
        button.font = prominent ? .systemFont(ofSize: 12) : Tokens.Font.caption
        button.target = self
        button.action = action
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    // MARK: Actions (all real target/action dispatch)

    @objc private func startClicked(_ sender: NSButton) { session.start() }
    @objc private func targetClicked(_ sender: NSButton) { session.answer(.target) }
    @objc private func referenceClicked(_ sender: NSButton) { session.answer(.reference) }
    @objc private func cantTellClicked(_ sender: NSButton) { session.answer(.cantTell) }
    @objc private func keepClicked(_ sender: NSButton) {
        session.keep()
        onFinished?()
    }
    @objc private func tryAgainClicked(_ sender: NSButton) { session.tryAgain() }
    @objc private func doneClicked(_ sender: NSButton) {
        // Graceful exit already restored; cancel is a harmless close here.
        session.cancel()
        onFinished?()
    }
    @objc private func dismissClicked(_ sender: NSButton) {
        session.cancel()
        onFinished?()
    }

    // MARK: Test-support hooks (performClick = real dispatch)

    var test_screen: BTAlignmentWizardSession.Screen { session.screen }
    var test_bodyText: String? {
        (contentStack.arrangedSubviews.first as? NSTextField)?.stringValue
    }
    var test_buttonTitles: [String] {
        contentStack.arrangedSubviews
            .compactMap { $0 as? NSStackView }
            .flatMap { $0.arrangedSubviews.compactMap { ($0 as? NSButton)?.title } }
    }
    var test_progressValue: Double? {
        contentStack.arrangedSubviews
            .compactMap { $0 as? NSProgressIndicator }.first?.doubleValue
    }
    var test_showsEducationLine: Bool {
        contentStack.arrangedSubviews
            .compactMap { ($0 as? NSTextField)?.stringValue }
            .contains(Self.educationCopy)
    }
    private func clickButton(titled title: String) {
        for case let row as NSStackView in contentStack.arrangedSubviews {
            for case let button as NSButton in row.arrangedSubviews where button.title == title {
                button.performClick(nil)
                return
            }
        }
    }
    func test_clickButton(titled title: String) { clickButton(titled: title) }
    func test_clickDismiss() { dismissButton.performClick(nil) }
}
