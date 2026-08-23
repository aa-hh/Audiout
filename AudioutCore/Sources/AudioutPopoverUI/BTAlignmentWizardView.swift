// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore
import AudioutSharedUI

/// The alignment wizard's anchored panel (W4, PLAN-UNIVERSAL-SYNC "ALIGNMENT
/// WIZARD UX LOCKED"): expands under the Bluetooth row (`ConnectionDiagnosisView`
/// pattern) and renders whatever ``BTAlignmentWizardSession/Screen`` its
/// session is on — intro (one sentence + Start), the which-side question (two
/// big buttons named after the ACTUAL devices, "They sound together", a
/// confidence line, an elapsed-time caption and a narrowing progress bar), the
/// proposal (the one place a number is named, Sounds right / Still off), the
/// kept screen, and the two bow-outs. The closing education line rides the
/// terminal screens. This view owns the SESSION driving (start/answer/accept/
/// tryAgain) but not its lifetime — the HOST creates the session, mounts this
/// panel, and tears both down (`onFinished`) so the tick can never outlive
/// the surface.
final class BTAlignmentWizardView: NSView {

    /// One entry in the reference picker: another available speaker the target
    /// can be compared against.
    struct ReferenceOption: Equatable {
        let id: String
        let name: String
    }

    // The locked copy.
    static let introCopy =
        "You'll hear a click from each speaker. Tap the one you hear first."
    static let questionCopy = "Which speaker clicked first?"
    /// The old "Can't tell", renamed because it is no longer a shrug: a
    /// posterior treats "both at once" as evidence that the offset is inside
    /// the ear's fusion window, which is the direct answer to "it sounded
    /// perfect to me but I had no way of saying so".
    static let togetherTitle = "They sound together"
    /// Undo the last answer — a mis-click nudges the fit rather than derailing
    /// it, and this puts the trial straight back.
    static let backTitle = "Back"
    /// The way OUT, spelled out. The 9.5 pt ✕ was the only exit and the live
    /// run never found it ("no way to exit").
    static let stopTitle = "Stop"
    static let soundsRightTitle = "Sounds right"
    static let stillOffTitle = "Still off"
    static let setByHandTitle = "Set it by hand"
    static let tryAgainTitle = "Try again"
    static let unsettledCopy =
        "Your answers aren't settling on one value. "
        + "Moving closer to the speakers usually helps."
    /// The run reached the end of what this control can do. Prior trim back.
    static let unreachableCopy =
        "Couldn't find the alignment. Try moving closer to the speakers, "
        + "or set the delay by hand from the SYNC control."
    /// The third failure, and the one the run has to say out loud rather than
    /// round away: the answers put the speaker AHEAD of the Mac, which the Mac
    /// being the zero makes impossible. Nothing is stored.
    static let macIsLateCopy =
        "Couldn't get a clean reading — the Mac seems to be the late one here. "
        + "Try again, or set the delay by hand."
    /// How sure the run is, in the units the user is actually judging. A
    /// question count would be a lie here — the run's length is not fixed —
    /// and this narrowing IS the progress bar's story in words.
    static func confidenceCopy(_ intervalMs: ClosedRange<Double>) -> String {
        "Somewhere between \(Int(intervalMs.lowerBound.rounded())) "
        + "and \(Int(intervalMs.upperBound.rounded())) ms"
    }
    /// How long this has been going on — the honest replacement for a question
    /// number, and the thing a user actually wants to know mid-run.
    static func elapsedCopy(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    static func proposalCopy(valueMs: Int) -> String {
        "Here's the alignment — \(valueMs) ms. Listen: the clicks should land as one."
    }
    /// A Bluetooth run wrote a MEASURED LATENCY and zeroed the nudge it
    /// suspended, so the sentence has to say where the nudge went.
    static func keptLatencyCopy(target: String, valueMs: Int) -> String {
        "Kept. \(target) now plays \(valueMs) ms early to stay in step. "
        + "Its SYNC is back to 0 — nudge from there if you ever need to."
    }
    /// The Mac's own row has no second store: its trim IS the kept value, so
    /// there is no reset to claim.
    static let keptLocalCopy =
        "Kept. This Mac's timing is saved. Nudge from there if you ever need to."
    static let educationCopy = "You can fine-tune anytime from the popover."
    /// Shown in the reference line's place while no second speaker can be
    /// established — Start stays disabled until one is.
    static let noReferenceCopy = "Select another speaker to compare against"
    static func comparingCopy(target: String) -> String { "Comparing \(target) against" }

    /// The wizard finished (Done, Stop, or the ✕): the host removes the panel
    /// and disposes of the session.
    var onFinished: (() -> Void)?

    /// The unsettled screen's "Set it by hand", carrying the run's best guess
    /// so the host can open the row's SYNC drawer on it. Fired BEFORE
    /// ``onFinished``.
    var onSetByHand: ((Double) -> Void)?

    /// The user picked a different reference. The HOST owns the consequences —
    /// engaging the new speaker, releasing the old, and telling the session to
    /// restart — because only it can touch the selection.
    var onSelectReference: ((String) -> Void)?

    /// The picker's menu, pushed by the host on every reconcile so devices
    /// coming and going are reflected. Repaints only on a real change.
    var referenceOptions: [ReferenceOption] = [] {
        didSet {
            guard referenceOptions != oldValue else { return }
            render(session.screen)
        }
    }

    private let session: BTAlignmentWizardSession
    private weak var referencePopUp: NSPopUpButton?
    private weak var startButton: NSButton?
    private weak var elapsedLabel: NSTextField?
    /// The question screen's own clock. The SESSION owns no clocks by
    /// contract, so the elapsed caption is the view's to keep — and to stop:
    /// it is invalidated the moment the screen is anything else, and on
    /// unmount.
    private var elapsedTimer: Timer?
    private var runStart: Date?
    /// The unsettled screen's best guess, held for the "Set it by hand"
    /// button — a target/action selector carries no payload.
    private var pendingBestGuessMs: Double?

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

    deinit { elapsedTimer?.invalidate() }

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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The panel is gone: the clock must not outlive it.
        if window == nil { stopElapsedClock() }
    }

    // MARK: The elapsed clock

    /// Runs only while a question is on screen, and only one of it. The
    /// PROPOSAL keeps the accumulated time (a rejected proposal returns to the
    /// same run); every other screen ends the run, so the next question starts
    /// a fresh clock.
    private func updateElapsedClock(for screen: BTAlignmentWizardSession.Screen) {
        guard case .question = screen else {
            if case .proposal = screen { stopElapsedClock(keepingStart: true) }
            else { stopElapsedClock() }
            return
        }
        if runStart == nil { runStart = Date() }
        guard elapsedTimer == nil else { return }
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.elapsedLabel?.stringValue = self.elapsedText()
        }
    }

    private func stopElapsedClock(keepingStart: Bool = false) {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        if !keepingStart { runStart = nil }
    }

    private func elapsedText() -> String {
        Self.elapsedCopy(Int(Date().timeIntervalSince(runStart ?? Date())))
    }

    // MARK: Keyboard (question + proposal)

    /// The keys the locked map calls for: ← target, → reference, Space "They
    /// sound together", ⌘Z Back, Esc Stop. Return is NOT handled here — it
    /// falls through to AppKit's own dispatch, which finds the proposal's
    /// default button.
    ///
    /// A key equivalent runs BEFORE the responder chain sees the keystroke,
    /// which is what puts Esc ahead of the shell panel's "close the whole
    /// surface" handling. It is also what makes the field-editor guard
    /// load-bearing: with the SYNC drawer's value field being typed into, Esc
    /// and Space belong to that edit, not to this panel.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder as? NSText == nil else {
            return super.performKeyEquivalent(with: event)
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "z" {
            guard isAnswering else { return super.performKeyEquivalent(with: event) }
            session.back()
            return true
        }
        guard modifiers.isEmpty else { return super.performKeyEquivalent(with: event) }
        switch event.keyCode {
        case Self.escapeKeyCode:
            session.cancel()
            onFinished?()
            return true
        case Self.leftArrowKeyCode where isAnswering:
            session.answer(.target)
            return true
        case Self.rightArrowKeyCode where isAnswering:
            session.answer(.reference)
            return true
        case Self.spaceKeyCode where isAnswering:
            session.answer(.together)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    /// Whether a which-side answer is what the panel is asking for right now.
    private var isAnswering: Bool {
        if case .question = session.screen { return true }
        return false
    }

    private static let escapeKeyCode: UInt16 = 53
    private static let leftArrowKeyCode: UInt16 = 123
    private static let rightArrowKeyCode: UInt16 = 124
    private static let spaceKeyCode: UInt16 = 49

    // MARK: Screen rendering

    private func render(_ screen: BTAlignmentWizardSession.Screen) {
        for view in contentStack.arrangedSubviews {
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        elapsedLabel = nil
        pendingBestGuessMs = nil
        updateElapsedClock(for: screen)
        switch screen {
        case .intro:
            addBody(Self.introCopy)
            addReferenceRow()
            let start = makeButton("Start", prominent: true, #selector(startClicked(_:)))
            start.isEnabled = session.reference != nil
            startButton = start
            addButtonRow([start])
            background.setAccessibilityLabel("Align \(session.targetName): \(Self.introCopy)")
        case .question(let progress, let intervalMs, let answersSoFar):
            let referenceName = session.reference?.name ?? ""
            addBody(Self.questionCopy)
            addCaption(Self.confidenceCopy(intervalMs))
            addReferenceRow()
            let back = makeButton(Self.backTitle, prominent: false, #selector(backClicked(_:)))
            back.isEnabled = answersSoFar > 0
            // TWO rows, deliberately: the which-side buttons carry real device
            // names ("Sony WH-1000XM3 Wireless Headphones"), and four of these
            // in one row inside a ~276 pt panel used to overrun a required
            // constraint rather than merely look cramped.
            addButtonRow([
                makeButton(session.targetName, prominent: true,
                           #selector(targetClicked(_:)), shrinkable: true),
                makeButton(referenceName, prominent: true,
                           #selector(referenceClicked(_:)), shrinkable: true),
            ])
            addButtonRow([
                makeButton(Self.togetherTitle, prominent: false, #selector(togetherClicked(_:))),
                back,
                makeButton(Self.stopTitle, prominent: false, #selector(stopClicked(_:))),
            ])
            elapsedLabel = addCaption(elapsedText())
            addProgress(progress)
            background.setAccessibilityLabel(
                "Which speaker ticked first: \(session.targetName) or \(referenceName)?")
        case .proposal(let valueMs):
            // Rounded, NOT `BTSyncTrim.quantise`: a Bluetooth run's result is
            // the speaker's measured latency, which routinely runs past the
            // trim's ±500 ms and would be clamped into a lie.
            let wholeMs = Int(valueMs.rounded())
            addBody(Self.proposalCopy(valueMs: wholeMs))
            addButtonRow([
                makeButton(Self.soundsRightTitle, prominent: true,
                           #selector(acceptClicked(_:)), isDefault: true),
                makeButton(Self.stillOffTitle, prominent: false, #selector(rejectClicked(_:))),
            ])
            background.setAccessibilityLabel(
                "Aligned at \(wholeMs) milliseconds. Does it sound right?")
        case .kept(let valueMs):
            let copy = session.measuresLatency
                ? Self.keptLatencyCopy(target: session.targetName,
                                       valueMs: Int(valueMs.rounded()))
                : Self.keptLocalCopy
            addBody(copy)
            addButtonRow([makeButton("Done", prominent: true, #selector(keptDoneClicked(_:)))])
            addEducationLine()
            background.setAccessibilityLabel(copy)
        case .unsettled(let bestGuessMs):
            addBody(Self.unsettledCopy)
            addButtonRow([
                makeButton(Self.setByHandTitle, prominent: true,
                           #selector(setByHandClicked(_:))),
                makeButton(Self.tryAgainTitle, prominent: false,
                           #selector(tryAgainClicked(_:))),
                makeButton("Done", prominent: false, #selector(doneClicked(_:))),
            ])
            addEducationLine()
            pendingBestGuessMs = bestGuessMs
            background.setAccessibilityLabel(Self.unsettledCopy)
        case .unreachable:
            addBody(Self.unreachableCopy)
            addButtonRow([makeButton("Done", prominent: true, #selector(doneClicked(_:)))])
            addEducationLine()
            background.setAccessibilityLabel(Self.unreachableCopy)
        case .macIsLate:
            addBody(Self.macIsLateCopy)
            addButtonRow([makeButton("Done", prominent: true, #selector(doneClicked(_:)))])
            addEducationLine()
            background.setAccessibilityLabel(Self.macIsLateCopy)
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

    /// "Comparing <target> against [<reference> ▾]" — the second speaker is a
    /// stock pop-up so the user can compare against something else. With no
    /// reference established the line says so instead, and Start stays off.
    private func addReferenceRow() {
        let label = NSTextField(labelWithString:
            session.reference == nil ? Self.noReferenceCopy
                                     : Self.comparingCopy(target: session.targetName))
        label.font = Tokens.Font.caption
        label.textColor = Tokens.Color.secondaryLabel
        // Carries the target's name, so it gives way for the same reason the
        // which-side buttons do.
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
        popUp.translatesAutoresizingMaskIntoConstraints = false
        popUp.controlSize = .small
        popUp.font = Tokens.Font.caption
        // Each item carries its own target/action + id, the idiom real menu
        // tracking dispatches through (`MainOutRowMenuDispatchTests`): a
        // pop-up-wide action would arrive with the wrong sender type.
        for option in referenceOptions {
            let item = NSMenuItem(title: option.name,
                                  action: #selector(referencePicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.id
            popUp.menu?.addItem(item)
        }
        popUp.isEnabled = !referenceOptions.isEmpty
        if let id = session.reference?.id,
           let index = referenceOptions.firstIndex(where: { $0.id == id }) {
            popUp.selectItem(at: index)
        }
        popUp.setAccessibilityLabel("Compare against")
        referencePopUp = popUp

        let row = NSStackView(views: [label, popUp])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 6
        contentStack.addArrangedSubview(row)
    }

    /// A secondary line under the question — the confidence interval above the
    /// buttons, the elapsed clock below them.
    @discardableResult
    private func addCaption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = Tokens.Font.caption
        label.textColor = Tokens.Color.secondaryLabel
        contentStack.addArrangedSubview(label)
        return label
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

    private func makeButton(_ title: String, prominent: Bool, _ action: Selector,
                            shrinkable: Bool = false, isDefault: Bool = false) -> NSButton {
        let button = NSButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.title = title
        button.bezelStyle = .rounded
        button.controlSize = prominent ? .regular : .small
        button.font = prominent ? .systemFont(ofSize: 12) : Tokens.Font.caption
        button.target = self
        button.action = action
        // Return reaches this one through AppKit's own key-equivalent
        // dispatch, which `performKeyEquivalent(with:)` below deliberately
        // falls through to.
        if isDefault { button.keyEquivalent = "\r" }
        button.setContentHuggingPriority(.required, for: .horizontal)
        // A button carrying a DEVICE NAME must give way rather than force the
        // content wider than the panel: the panel pins its content inside the
        // background with a REQUIRED `<=`, so an unshrinkable long name is a
        // broken constraint, not a wide button. Everything else keeps its
        // natural width — the titles are ours and they are short.
        button.setContentCompressionResistancePriority(
            shrinkable ? .defaultLow : .required, for: .horizontal)
        if shrinkable {
            button.cell?.lineBreakMode = .byTruncatingTail
            button.cell?.usesSingleLineMode = true
        }
        return button
    }

    // MARK: Actions (all real target/action dispatch)

    @objc private func startClicked(_ sender: NSButton) { session.start() }
    @objc private func targetClicked(_ sender: NSButton) { session.answer(.target) }
    @objc private func referenceClicked(_ sender: NSButton) { session.answer(.reference) }
    @objc private func togetherClicked(_ sender: NSButton) { session.answer(.together) }
    @objc private func backClicked(_ sender: NSButton) { session.back() }
    @objc private func stopClicked(_ sender: NSButton) {
        session.cancel()
        onFinished?()
    }
    @objc private func acceptClicked(_ sender: NSButton) { session.acceptProposal() }
    @objc private func rejectClicked(_ sender: NSButton) { session.rejectProposal() }
    @objc private func tryAgainClicked(_ sender: NSButton) { session.tryAgain() }
    /// The kept screen's Done. The run committed on Accept, so this is a close
    /// and nothing else — `cancel()` would be inert here anyway, but saying
    /// "done" is what actually happened.
    @objc private func keptDoneClicked(_ sender: NSButton) {
        session.done()
        onFinished?()
    }
    @objc private func setByHandClicked(_ sender: NSButton) {
        if let pendingBestGuessMs { onSetByHand?(pendingBestGuessMs) }
        onFinished?()
    }
    @objc private func doneClicked(_ sender: NSButton) {
        // Every screen behind this button is a BOW-OUT: the session already put
        // the tick off and the prior value back, and marked itself ended — so
        // `cancel()` is inert here, and deliberately so. It used to fire a
        // second tick-off edge, which the backend pays for as a re-anchor of
        // every sink. Kept as the one unconditional close call.
        session.cancel()
        onFinished?()
    }
    @objc private func dismissClicked(_ sender: NSButton) {
        session.cancel()
        onFinished?()
    }
    @objc private func referencePicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onSelectReference?(id)
    }

    // MARK: Test-support hooks (performClick = real dispatch)

    var test_screen: BTAlignmentWizardSession.Screen { session.screen }
    var test_bodyText: String? {
        (contentStack.arrangedSubviews.first as? NSTextField)?.stringValue
    }
    var test_buttonTitles: [String] { actionButtons.map(\.title) }
    var test_referenceOptionTitles: [String] {
        referencePopUp?.menu?.items.map(\.title) ?? []
    }
    var test_selectedReferenceTitle: String? { referencePopUp?.selectedItem?.title }
    var test_referencePickerIsEnabled: Bool { referencePopUp?.isEnabled ?? false }
    var test_startIsEnabled: Bool { startButton?.isEnabled ?? false }
    var test_buttonIsEnabled: (String) -> Bool {
        { [weak self] title in
            self?.actionButtons.first { $0.title == title }?.isEnabled ?? false
        }
    }
    var test_referenceLineText: String? {
        contentStack.arrangedSubviews
            .compactMap { $0 as? NSStackView }
            .first { $0.arrangedSubviews.contains { $0 is NSPopUpButton } }?
            .arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue }.first
    }
    /// The screens' own buttons — an `NSPopUpButton` is an `NSButton` too, so
    /// the reference picker has to be excluded or it answers to a device name.
    private var actionButtons: [NSButton] {
        contentStack.arrangedSubviews
            .compactMap { $0 as? NSStackView }
            .flatMap { $0.arrangedSubviews }
            .compactMap { $0 as? NSButton }
            .filter { !($0 is NSPopUpButton) }
    }
    var test_progressValue: Double? {
        contentStack.arrangedSubviews
            .compactMap { $0 as? NSProgressIndicator }.first?.doubleValue
    }
    /// The secondary lines: the confidence interval and the elapsed clock.
    var test_captionTexts: [String] {
        contentStack.arrangedSubviews
            .compactMap { $0 as? NSTextField }
            .dropFirst()   // the body label
            .map(\.stringValue)
    }
    var test_elapsedClockIsRunning: Bool { elapsedTimer != nil }
    /// A real key event through the real key-equivalent seam — the same call
    /// `NSWindow.sendEvent` makes before the responder chain sees the key.
    @discardableResult
    func test_sendKey(keyCode: UInt16, characters: String = "",
                      modifiers: NSEvent.ModifierFlags = []) -> Bool {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: window?.windowNumber ?? 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode) else { return false }
        return performKeyEquivalent(with: event)
    }
    var test_showsEducationLine: Bool {
        contentStack.arrangedSubviews
            .compactMap { ($0 as? NSTextField)?.stringValue }
            .contains(Self.educationCopy)
    }
    /// Does the mounted content fit the width it was given? A long device name
    /// used to make `contentStack.trailing <= background.trailing` — required —
    /// unsatisfiable; nothing here asserts an absolute width, only that the
    /// content still fits whatever the host handed out.
    var test_contentFitsItsWidth: Bool {
        layoutSubtreeIfNeeded()
        let available = background.bounds.width - 2 * Self.contentPadding
        // The ROWS — the buttons and the reference line, the parts that carry
        // device names. A wrapping body label sizes itself and is not what a
        // long name breaks.
        return contentStack.arrangedSubviews
            .compactMap { $0 as? NSStackView }
            .allSatisfy { $0.fittingSize.width <= available }
    }
    private func clickButton(titled title: String) {
        actionButtons.first { $0.title == title }?.performClick(nil)
    }
    func test_clickButton(titled title: String) { clickButton(titled: title) }
    func test_clickDismiss() { dismissButton.performClick(nil) }
    /// Real menu dispatch: the item's OWN action on its OWN target, sender =
    /// the item — exactly what AppKit menu tracking sends.
    func test_selectReference(titled title: String) {
        guard let item = referencePopUp?.menu?.items.first(where: { $0.title == title }),
              let action = item.action, let target = item.target as? NSObject else { return }
        _ = target.perform(action, with: item)
    }
}
