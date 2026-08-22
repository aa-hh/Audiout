// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterCore

/// Reports every gesture out of a ``BTSyncDrawerView`` (PLAN-BT-SYNC-DRAWER
/// T5) back to its host.
public protocol BTSyncDrawerViewDelegate: AnyObject {
    /// A committed trim change — a stepper click, a typed field commit, or
    /// Revert. Apply AND persist. (There is no longer a live-scrub /
    /// don't-persist case: the scrubbing ruler that needed it was cut. Every
    /// change the drawer now makes is a discrete, complete gesture, so
    /// `committed` is always true — the parameter stays for the host's
    /// existing wiring and in case a live control returns later.)
    func syncDrawer(_ d: BTSyncDrawerView, didChangeTrimMs ms: Double, committed: Bool)
    /// The align-by-ear (metronome) toggle, moved off the row into the
    /// drawer (D9).
    func syncDrawer(_ d: BTSyncDrawerView, didToggleAlignTick active: Bool)
    /// Escape, pressed anywhere in the drawer OTHER than the value field
    /// (the field's own Escape reverts an in-progress edit instead —
    /// consumed inside `SyncValueFieldEditor`, never reaching here). This
    /// drawer has no visible close affordance of its own (T6's row chip
    /// owns opening/closing); the host decides how — or whether — to react.
    func syncDrawerDidRequestClose(_ d: BTSyncDrawerView)
    /// ⌥-click on the align-by-ear (metronome) button: the guided alignment
    /// wizard instead of the manual tick (W4 relaunch — the first-mix card's
    /// "Not now" is final, so this stays reachable forever). The row's
    /// "Align speaker…" context-menu item is the discoverable twin.
    func syncDrawerDidRequestAlignmentWizard(_ d: BTSyncDrawerView)
}

public extension BTSyncDrawerViewDelegate {
    /// Default no-op — only the popover hosts the alignment wizard.
    func syncDrawerDidRequestAlignmentWizard(_ d: BTSyncDrawerView) {}
}

/// The **BT sync drawer** (PLAN-BT-SYNC-DRAWER §3 T5): the panel that opens
/// underneath a Bluetooth row when its SYNC value chip (T6) is clicked. ONE
/// horizontal band:
///
///     [♪ Align by ear] [Revert]      hold ⇧ for 10 ms   [ − | −414 ms | + ]
///
/// **Why the two halves sit at opposite ends.** Align-by-ear and Revert lead
/// the band; the value cluster hugs the trailing edge so it lands directly
/// beneath the chip that opened the drawer. Revert is destructive-ish and its
/// natural moment comes *after* a run of stepper clicks, so it is parked as
/// far from the steppers as the band allows — a Revert adjacent to `−` is one
/// slipped click away from discarding the adjustment in progress.
///
/// **Why the value cluster is one bound box.** A stepper has to read as
/// attached to the number it changes (Apple's own steppers are welded to their
/// field). The version this replaces spread four loose `[−10] [−1] value [+1]
/// [+10]` pills across the band, and nothing said which pill drove which
/// number. Here `−`, the field and `+` sit adjacent, each on its own stock
/// bezel — fusing them inside one flat outline was tried and read as a single
/// dead slab with the buttons dissolved into it (live-found). The ±10 pills are
/// gone entirely: ⇧ makes the same two buttons step ten, announced by the quiet
/// hint beside them. Every element of the band shares one height and is
/// vertically centred, sized to sit WITH the row's controls rather than above
/// them — the field included, so the box and the buttons match.
///
/// **Why buttons and not a scrubber** (live-found, and the reason the ±10
/// pills existed at all): a drag-to-scrub ruler draft failed the one test that
/// matters — a first-time user dragged it and couldn't tell they had to cover
/// ~400 ms coarsely before the fine end mattered. Auto-repeating buttons cover
/// that distance with no hidden gesture, which is what lets ⇧ absorb the
/// coarse step now. Whole ms is enough resolution: the ear can't resolve a
/// flam below ~4 ms, so `BTSyncTrim.resolutionMs` is 1.
///
/// **Colour:** the background is ``Tokens/Color/well`` — the recessed/inset
/// fill already used behind slider troughs, darker than the row card in BOTH
/// themes, which is what "opens downward" needs to read. No drawn edge or
/// border (live feedback): the well fill alone reads as a recess belonging to
/// the row above. The align-by-ear button keeps the exact
/// accent/secondaryLabel treatment it has on the row today
/// (`DeviceRowView.alignTapped`). The background is drawn in `draw(_:)`, not
/// stamped into a `CALayer`, so it re-resolves live on every pass with no
/// `viewDidChangeEffectiveAppearance` observer needed. Every control in the
/// band carries its own STOCK bezel, so AppKit re-resolves all of that chrome
/// per appearance too.
public final class BTSyncDrawerView: NSView {

    // MARK: Auto-repeat timing
    //
    // Timing, not geometry: `PopoverColumnGrid` is the Figma contract's mirror
    // and holds METRICS, so these live with the control they time. Matched to
    // the platform's own key-repeat feel — long enough that a deliberate
    // single click never repeats, fast enough that holding covers the ±500 ms
    // range (with ⇧, ~7 s end to end) without becoming a drag race.

    /// How long `−`/`+` must be held before the value starts stepping on its
    /// own. `Float` seconds — the unit `NSButtonCell.setPeriodicDelay` takes.
    private static let stepperRepeatDelay: Float = 0.4
    /// The interval between steps once auto-repeat has started.
    private static let stepperRepeatInterval: Float = 0.06
    /// SF-Symbol point size of the `−`/`+` glyphs.
    private static let stepperGlyphPointSize: CGFloat = 10

    // MARK: Subviews

    private let alignButton = NSButton()
    private let revertButton = NSButton()
    private let hintLabel = NSTextField(labelWithString: "")
    private let minusButton = NSButton()
    private let plusButton = NSButton()
    private let valueField = NSTextField()

    private lazy var valueFieldEditor = SyncValueFieldEditor(field: valueField, initialValue: 0)

    public weak var delegate: BTSyncDrawerViewDelegate?

    // MARK: State — pushed by `configure`; `noteOpened` separately seeds the
    // Revert baseline (D8), since `configure` alone can't tell a fresh open
    // from a routine refresh of an already-open drawer (T7 reuses one
    // instance across devices rather than creating one per row).

    private var deviceName = ""
    private var trimMs: Double = 0
    private var isSet = false
    private var openTimeMs: Double = 0
    private var usableRangeMs: ClosedRange<Double> = -BTSyncTrim.rangeMs...BTSyncTrim.rangeMs
    /// The direction-spelled value last pushed to the field's accessibility
    /// value (D7). Mirrored here because `NSTextField.accessibilityValue()`
    /// does not reliably read back what `setAccessibilityValue` wrote in a
    /// headless test — this is the source of truth the hook reads.
    private var spokenValue = ""

    public init() {
        super.init(frame: .zero)
        commonInit()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Setup

    private func commonInit() {
        translatesAutoresizingMaskIntoConstraints = false
        // Trap #6 (PLAN-BT-SYNC-DRAWER §4): the popover derives its size from
        // Auto Layout fitting size, and an ambiguous drawer height silently
        // COLLAPSES the popover instead of erroring — a definite height
        // constraint is load-bearing, not decoration.
        heightAnchor.constraint(equalToConstant: PopoverColumnGrid.syncDrawerHeight).isActive = true

        configureValueField()
        configureButtons()
        configureLabels()
        for subview in [minusButton, plusButton, valueField,
                        alignButton, revertButton, hintLabel] as [NSView] {
            // ONE place, unskippable, for every present and future subview.
            // Live-found: labels that missed this flag kept their translated
            // mask constraints (position 0,0), which fought the explicit chain
            // — Auto Layout settled the conflict by collapsing views to ZERO
            // height, an empty drawer with no error anywhere.
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        installConstraints()

        valueFieldEditor.delegate = self
        // Reads `usableRangeMs` LIVE on every call (closes over `self`, not a
        // snapshot) — T3's trap: the range moves when AirPlay devices join or
        // leave the group, and `configure` can arrive mid-edit.
        valueFieldEditor.clamp = { [weak self] ms in
            guard let self else { return ms }
            return self.clampToUsableRange(ms)
        }

        refreshDisplay()
    }


    /// The value field is a stock bezeled `NSTextField`
    /// treatment (raised fill, hairline border, trailing pencil) already used
    /// by the Groups window's rename field. A bare number on the drawer's
    /// background gave no hint it could be typed into; this one looks like a
    /// box you click.
    private func configureValueField() {
        // STOCK bezeled field, deliberately not a custom drawing cell. An
        // earlier version wore `WarmNameFieldCell` (the Groups rename field's
        // treatment) for its "click to type" pencil, and every one of that
        // cell's traits turned out wrong here (all live-found):
        //   · the pencil fades in on hover and RESERVES trailing width, so the
        //     number visibly jumped sideways as the pointer crossed the field;
        //   · that reserved gutter pushed the "ms" suffix away from the digits
        //     it belongs to, leaving it stranded beside the pencil;
        //   · the cell centres text horizontally but not VERTICALLY, so the
        //     digits sat high in the box;
        //   · a flat custom fill on a flat drawer read as one dead slab.
        // A stock bezel fixes all four for free: AppKit centres the text in
        // the bezel, the field is visibly inset against the drawer's `well`
        // background, and there is no hover chrome to shift anything. It is
        // also the plainest possible "this is a text field" signal, which was
        // the original goal.
        valueField.isEditable = true
        valueField.isSelectable = true
        valueField.isBezeled = true
        valueField.controlSize = .small
        valueField.bezelStyle = .squareBezel
        valueField.usesSingleLineMode = true
        valueField.font = Tokens.Font.syncReadout
        valueField.textColor = Tokens.Color.label
        valueField.alignment = .center
        valueField.toolTip = "Click to type an exact value in whole milliseconds"
        valueField.setAccessibilityLabel("Sync offset")
    }

    private func configureButtons() {
        // `−` and `+`, one step each, ten while ⇧ is held. SF Symbols, not
        // text titles: the amounts moved off the buttons and onto the modifier,
        // so each one now says only its direction — which is exactly what a
        // glyph says best. (The four labelled `[−10] [−1] [+1] [+10]` pills
        // this replaces had to spell their amounts out, and that is what made
        // them too wide to bind to the value.)
        let steppers: [(button: NSButton, symbol: String, fallback: String, label: String)] = [
            (minusButton, "minus", "\u{2212}", "Decrease sync offset"),
            (plusButton, "plus", "+", "Increase sync offset"),
        ]
        for (button, symbol, fallback, label) in steppers {
            // BEZELED, not borderless (live-found): borderless glyphs on the
            // drawer's flat `well` fill had no edge of their own and simply
            // dissolved into the background — they did not read as buttons at
            // all. The stock bezel gives them the same raised, hit-me presence
            // the align/revert buttons beside them already have.
            button.bezelStyle = .rounded
            button.controlSize = .small
            if let image = Self.stepperImage(symbol) {
                button.image = image
                button.imagePosition = .imageOnly
            } else {
                button.font = Tokens.Font.caption
                button.title = fallback
            }
            button.contentTintColor = Tokens.Color.label
            button.setAccessibilityLabel(label)
            let help = "\(label) by 1 millisecond. Hold Shift to step 10."
            button.setAccessibilityHelp(help)
            button.toolTip = help
            // Press-and-hold auto-repeats, so covering the ±500 ms range never
            // needs 500 clicks — the job the cut coarse buttons used to do.
            button.isContinuous = true
            (button.cell as? NSButtonCell)?.setPeriodicDelay(Self.stepperRepeatDelay,
                                                             interval: Self.stepperRepeatInterval)
            button.target = self
        }
        minusButton.action = #selector(minusTapped)
        plusButton.action = #selector(plusTapped)

        alignButton.bezelStyle = .rounded
        alignButton.controlSize = .small
        alignButton.font = Tokens.Font.caption
        alignButton.setButtonType(.pushOnPushOff)
        alignButton.imagePosition = .imageLeading
        alignButton.title = "Align by ear"
        // `metronome.fill` verified AppKit-resolvable; `metronome` stays as
        // the defensive fallback — mirrors `DeviceRowView.configureSyncControls`
        // exactly (same locked spec contingency, D9's one glyph choice).
        for name in ["metronome.fill", "metronome"] {
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)) {
                alignButton.image = image
                break
            }
        }
        alignButton.contentTintColor = Tokens.Color.secondaryLabel
        // `DeviceRowView.alignTooltip` — one string, shared across its module
        // (both types live in `AudiouterSharedUI`), not re-authored here.
        alignButton.toolTip = DeviceRowView.alignTooltip
        alignButton.setAccessibilityLabel("Align by ear")
        alignButton.setAccessibilityHelp(DeviceRowView.alignTooltip)
        alignButton.target = self
        alignButton.action = #selector(alignTapped(_:))

        revertButton.bezelStyle = .rounded
        revertButton.controlSize = .small
        revertButton.font = Tokens.Font.caption
        revertButton.title = "Revert"
        revertButton.setAccessibilityLabel("Revert to the value when this drawer opened")
        revertButton.target = self
        revertButton.action = #selector(revertTapped(_:))
    }

    private func configureLabels() {
        // The ⇧ hint sits next to the buttons it modifies, not in a tooltip:
        // a coarse step is the second thing anyone needs here, and a modifier
        // nobody is told about does not exist.
        hintLabel.stringValue = "hold \u{21E7} for 10 ms"
        hintLabel.font = Tokens.Font.caption
        hintLabel.textColor = Tokens.Color.tertiaryLabel

    }

    private static func stepperImage(_ symbolName: String) -> NSImage? {
        NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: stepperGlyphPointSize, weight: .medium))
    }

    private func installConstraints() {
        let inset = PopoverColumnGrid.syncDrawerHorizontalInset
        let controlH = PopoverColumnGrid.syncDrawerControlHeight
        let stepperW = PopoverColumnGrid.syncDrawerStepperButtonWidth

        NSLayoutConstraint.activate([
            // LEADING half: the align/revert pair, together, as far from the
            // steppers as the band allows (see the type's header comment).
            alignButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            alignButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            alignButton.widthAnchor.constraint(equalToConstant: PopoverColumnGrid.syncDrawerAlignButtonWidth),
            alignButton.heightAnchor.constraint(equalToConstant: controlH),

            revertButton.leadingAnchor.constraint(equalTo: alignButton.trailingAnchor,
                                                  constant: PopoverColumnGrid.syncDrawerButtonGap),
            revertButton.centerYAnchor.constraint(equalTo: alignButton.centerYAnchor),
            revertButton.widthAnchor.constraint(equalToConstant: PopoverColumnGrid.syncDrawerRevertButtonWidth),
            revertButton.heightAnchor.constraint(equalToConstant: controlH),

            // TRAILING half, laid out trailing→leading so it lands directly
            // beneath the SYNC chip that opened the drawer: `+`, the unit, the
            // typeable box, `−`. Each control carries its OWN stock bezel — an
            // earlier version fused all three inside one hairline `NSBox`, and
            // on the drawer's flat fill that read as a single dead slab with
            // the buttons dissolved into it (live-found). Separate bezels give
            // each control its own edge, which is what makes them look
            // pressable; adjacency alone still binds them to the number.
            plusButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            plusButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            plusButton.widthAnchor.constraint(equalToConstant: stepperW),
            plusButton.heightAnchor.constraint(equalToConstant: controlH),

            valueField.trailingAnchor.constraint(equalTo: plusButton.leadingAnchor,
                                                 constant: -PopoverColumnGrid.syncDrawerStepperToValueGap),
            valueField.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueField.widthAnchor.constraint(equalToConstant: PopoverColumnGrid.syncDrawerValueFieldWidth),
            valueField.heightAnchor.constraint(equalToConstant: controlH),

            minusButton.trailingAnchor.constraint(equalTo: valueField.leadingAnchor,
                                                  constant: -PopoverColumnGrid.syncDrawerStepperToValueGap),
            minusButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            minusButton.widthAnchor.constraint(equalToConstant: stepperW),
            minusButton.heightAnchor.constraint(equalToConstant: controlH),

            hintLabel.trailingAnchor.constraint(equalTo: minusButton.leadingAnchor,
                                                constant: -PopoverColumnGrid.syncDrawerHintToClusterGap),
            hintLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    // MARK: Drawing — background only, no border (see header comment)

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        Tokens.Color.well.setFill()
        bounds.fill()
    }


    // MARK: Public API (T7)

    /// Push a fresh model snapshot. Guards the value field's DISPLAYED text
    /// against an in-progress edit exactly as `DeviceRowView.configure`
    /// guards `syncField` (`SyncValueFieldEditor.setCommittedValue`'s own
    /// `currentEditor() == nil` check) — the internal state updates either
    /// way, only the on-screen text is protected.
    public func configure(deviceName: String, trimMs: Double, isSet: Bool,
                          usableRangeMs: ClosedRange<Double>, alignTickActive: Bool) {
        self.deviceName = deviceName
        self.trimMs = trimMs
        self.isSet = isSet
        self.usableRangeMs = usableRangeMs
        alignButton.state = alignTickActive ? .on : .off
        alignButton.contentTintColor = alignTickActive
            ? Tokens.Color.engagedChrome : Tokens.Color.secondaryLabel
        refreshDisplay()
    }

    /// Captures `trimMs` as the value Revert restores (D8). Call this exactly
    /// once, right when the drawer opens for a device — `configure` alone
    /// can't tell a fresh open from a routine refresh of an already-open
    /// drawer.
    /// Whether the value field currently owns a live editing session — i.e.
    /// the user is typing in it right now. The host reads this before a
    /// structural repaint detaches this view, because detaching mid-edit ends
    /// the session and drops first responder (see `PopoverController.rebuild`).
    public var isEditingValue: Bool { valueField.currentEditor() != nil }

    /// Hand the value field its editing session back after the host re-mounts
    /// this view. Paired with ``isEditingValue`` across a repaint so a
    /// background device snapshot cannot silently steal focus from someone
    /// mid-type.
    /// Commit whatever is typed and end the editing session, leaving the field
    /// with no field editor. The host calls this when something tries to close
    /// the surface mid-edit: the value lands, the session ends, and the next
    /// close request goes through unimpeded. Ending editing by moving first
    /// responder is what fires `controlTextDidEndEditing`, which is the
    /// commit — so the value is applied by the same path a click-away uses,
    /// not by a second, divergent copy of the commit logic.
    public func commitAndEndEditing() {
        guard let window, valueField.currentEditor() != nil else { return }
        window.makeFirstResponder(window)
    }

    public func focusValueField() {
        guard let window, window.firstResponder !== valueField.currentEditor() else { return }
        window.makeFirstResponder(valueField)
    }

    public func noteOpened(trimMs: Double) {
        openTimeMs = trimMs
        refreshDisplay()
    }

    /// A trim written by something OUTSIDE the drawer while it stands open —
    /// the alignment wizard's Keep, which zeroes the nudge its run suspended.
    ///
    /// Not `configure`: that is a background model push, and it deliberately
    /// refuses to yank text out from under an in-progress edit — so the field
    /// would go on SHOWING the pre-run value and commit it straight back over
    /// the measurement on its way out (live defect, 2026-08-22). This is a
    /// gesture in its own right, so it wins over a live edit exactly as the
    /// steppers do, and it moves the Revert baseline with it: a nudge the run
    /// just measured away is not a value to go back to.
    public func noteExternalTrimChange(_ ms: Double) {
        trimMs = ms
        isSet = true
        openTimeMs = ms
        refreshDisplay()
        valueFieldEditor.overrideEditedValue(ms)
    }

    // MARK: Actions

    @objc private func minusTapped() { stepTrim(by: -stepAmountMs) }
    @objc private func plusTapped() { stepTrim(by: stepAmountMs) }

    /// One millisecond, or ten while ⇧ is held — the coarse/fine pair the two
    /// cut `±10` buttons used to carry.
    private var stepAmountMs: Double {
        shiftIsHeld ? BTSyncTrim.coarseStepMs : BTSyncTrim.fineStepMs
    }

    private func stepTrim(by deltaMs: Double) {
        applyCommit(clampToUsableRange(BTSyncTrim.quantise(trimMs + deltaMs)))
    }

    @objc private func alignTapped(_ sender: NSButton) {
        if optionIsHeld {
            // ⌥-click asks for the guided wizard instead of the manual tick —
            // undo the `pushOnPushOff` flip so the toggle never moves.
            sender.state = sender.state == .on ? .off : .on
            delegate?.syncDrawerDidRequestAlignmentWizard(self)
            return
        }
        // `pushOnPushOff` has already flipped the state; land the tint now
        // so the toggle reads immediately, before the host's re-apply echoes
        // it — mirrors `DeviceRowView.alignTapped` exactly.
        alignButton.contentTintColor = sender.state == .on
            ? Tokens.Color.engagedChrome : Tokens.Color.secondaryLabel
        delegate?.syncDrawer(self, didToggleAlignTick: sender.state == .on)
    }

    @objc private func revertTapped(_ sender: NSButton) {
        applyCommit(clampToUsableRange(openTimeMs))
    }

    /// Escape, anywhere in the drawer other than an in-progress field edit
    /// (which `SyncValueFieldEditor` consumes for its own revert — see its
    /// header comment). Standard AppKit key-binding translation: an unhandled
    /// Escape is delivered up the responder chain as this action message.
    public override func cancelOperation(_ sender: Any?) {
        delegate?.syncDrawerDidRequestClose(self)
    }

    // MARK: Commit plumbing

    private func clampToUsableRange(_ ms: Double) -> Double {
        Swift.min(usableRangeMs.upperBound, Swift.max(usableRangeMs.lowerBound, ms))
    }

    /// A discrete, complete gesture (stepper click, typed commit, Revert):
    /// apply AND persist.
    ///
    /// `fromField` marks the typed-Return / focus-loss path, which arrives via
    /// the field editor's own commit and has already written the field. Every
    /// OTHER gesture has to say so, because `refreshDisplay` cannot write text
    /// the user is editing — see `SyncValueFieldEditor.overrideEditedValue`.
    private func applyCommit(_ ms: Double, fromField: Bool = false) {
        trimMs = ms
        isSet = true
        refreshDisplay()
        if !fromField { valueFieldEditor.overrideEditedValue(ms) }
        delegate?.syncDrawer(self, didChangeTrimMs: ms, committed: true)
    }

    private func refreshDisplay() {
        valueFieldEditor.setCommittedValue(trimMs, displayText: Self.fieldText(trimMs))
        revertButton.isEnabled = BTSyncTrim.quantise(trimMs) != BTSyncTrim.quantise(openTimeMs)
        // D7 (never a bare signed number with no direction) lives in the
        // spoken value and the field's tooltip — the visible number carries
        // its sign, and the row chip above the drawer states "N ms" for
        // context. The drawer stays compact (live feedback), so there is no
        // visible caption sentence.
        spokenValue = isSet ? BTSyncTrim.spokenOffset(trimMs) : "Not set"
        valueField.setAccessibilityLabel("Sync offset for \(deviceName)")
        valueField.setAccessibilityValue(spokenValue)
        valueField.toolTip = "\(deviceName): \(isSet ? BTSyncTrim.spokenOffset(trimMs) : "not tuned yet"). Type an exact value in whole milliseconds."
    }

    /// The value field's resting text: a bare signed whole number the field
    /// editor round-trips unchanged (it shows this at rest and an identical
    /// signed number while editing, so a no-op edit can't flip the sign). No
    /// The field's RESTING text carries the unit — "−414 ms" — so the box
    /// reads as a complete value rather than a bare number needing a label
    /// beside it. The "ms" is undeletable by construction, not by policing
    /// keystrokes: `SyncValueFieldEditor` swaps the whole string for a bare
    /// signed number the instant editing begins, and strips any "ms" it finds
    /// when parsing, so the suffix simply cannot be edited — it is re-rendered
    /// here on every commit.
    private static func fieldText(_ ms: Double) -> String {
        "\(Int(BTSyncTrim.quantise(ms))) ms"
    }

    // MARK: ⇧ modifier seam (mirrors `SyncValueFieldEditor
    // .test_optionModifierOverride`: a headless click carries no real
    // `NSApp.currentEvent`, and in a narrowly filtered `swift test` run `NSApp`
    // itself — an implicitly-unwrapped optional — can still be nil, so this
    // reads it via `?`, never force-unwrapped.)

    public var test_shiftModifierOverride: Bool?

    private var shiftIsHeld: Bool {
        test_shiftModifierOverride ?? (NSApp?.currentEvent?.modifierFlags.contains(.shift) ?? false)
    }

    /// Same seam for ⌥ (the align button's wizard relaunch).
    public var test_optionModifierOverride: Bool?

    private var optionIsHeld: Bool {
        test_optionModifierOverride ?? (NSApp?.currentEvent?.modifierFlags.contains(.option) ?? false)
    }

    // MARK: Test hooks — real dispatch through the exact delegate/action seam
    // (house convention, `AudiouterSharedUI/AGENTS.md`)

    public var test_trimMs: Double { trimMs }
    public var test_isSet: Bool { isSet }
    public var test_usableRangeMs: ClosedRange<Double> { usableRangeMs }
    public var test_revertEnabled: Bool { revertButton.isEnabled }
    public var test_alignActive: Bool { alignButton.state == .on }
    public var test_valueField: NSTextField { valueField }
    public var test_valueFieldText: String { valueField.stringValue }
    public var test_valueFieldIsBezeled: Bool { valueField.isBezeled }
    public var test_stepperButtonsAreBezeled: Bool {
        minusButton.isBordered && plusButton.isBordered
    }
    public var test_valueFieldAXValue: String { spokenValue }
    public var test_valueFieldEditor: SyncValueFieldEditor { valueFieldEditor }
    public var test_hintText: String { hintLabel.stringValue }
    /// True once the value field wears the house click-to-type skin.
    /// Whether `−`/`+` auto-repeat while held, and how fast.
    public var test_stepperRepeat: (isContinuous: Bool, delay: Float, interval: Float)? {
        guard let cell = plusButton.cell as? NSButtonCell else { return nil }
        var delay: Float = 0
        var interval: Float = 0
        cell.getPeriodicDelay(&delay, interval: &interval)
        return (plusButton.isContinuous, delay, interval)
    }

    public func test_fireMinusClick() { minusButton.performClick(nil) }
    public func test_firePlusClick() { plusButton.performClick(nil) }
    public func test_fireAlignClick() { alignButton.performClick(nil) }
    public func test_fireRevertClick() { revertButton.performClick(nil) }
    public func test_fireCancelOperation() { cancelOperation(nil) }
}

// MARK: - SyncValueFieldEditorDelegate

extension BTSyncDrawerView: SyncValueFieldEditorDelegate {
    public func syncValueFieldEditor(_ editor: SyncValueFieldEditor, didCommit ms: Double) {
        applyCommit(ms, fromField: true)
    }
}
