// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterCore

/// Reports every gesture out of a ``BTSyncDrawerView`` (PLAN-BT-SYNC-DRAWER
/// T5) back to its host.
public protocol BTSyncDrawerViewDelegate: AnyObject {
    /// `committed == false` during a live ruler scrub: apply to audio, do
    /// NOT persist. `committed == true` on drag end, a stepper click, a
    /// typed field commit, or Revert: apply **and** persist. The split
    /// exists so a scrub does not write the JSON trim store dozens of times
    /// a second.
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
}

/// The **BT sync drawer** (PLAN-BT-SYNC-DRAWER §3 T5): the panel that opens
/// underneath a Bluetooth row when its SYNC value chip (T6) is clicked.
/// Composes T4's ``BTSyncRulerView`` with the big click-to-edit readout,
/// −/+ steppers, the align-by-ear toggle (D9, moved off the row), and Revert
/// (D8). `PopoverController` (T7) owns opening/closing/reuse — one drawer
/// instance is reconfigured across devices rather than one per row — and
/// inserts this view into the row stack; this view only renders one
/// device's sync state and reports gestures out through
/// ``BTSyncDrawerViewDelegate``.
///
/// **Colour (resolved by the product owner — the plan's own draft named a
/// `Tokens.Color.controlBackground` that was never a real token):** the
/// background is ``Tokens/Color/well`` — the recessed/inset fill already
/// used behind slider troughs, darker than the row card in BOTH themes,
/// which is what "opens downward" needs to read. The left edge is
/// ``Tokens/Color/accent`` — the SYSTEM accent, deliberately NOT `gold`: a
/// gold route-armed rail may sit immediately to this edge's left, and two
/// golds side by side is too much. `gold` stays the ruler's alone (its
/// centre pointer, `BTSyncRulerView`'s own header comment). The align-by-ear
/// button keeps the exact accent/secondaryLabel treatment it already has on
/// the row today (`DeviceRowView.alignTapped`) — this task does not touch
/// that vocabulary.
///
/// Background + accent edge are drawn in `draw(_:)`, not stamped into a
/// `CALayer`, so both re-resolve live on every pass with no
/// `viewDidChangeEffectiveAppearance` observer needed — same reasoning as
/// `BTSyncRulerView`'s header comment. Square corners throughout (house
/// rule: no rounded corners on a single-sided border).
public final class BTSyncDrawerView: NSView {

    // MARK: Subviews

    private let captionLabel = NSTextField(labelWithString: "")
    private let valueField = NSTextField()
    private let suffixLabel = NSTextField(labelWithString: "")
    private let minusButton = NSButton()
    private let plusButton = NSButton()
    private let alignButton = NSButton()
    private let revertButton = NSButton()
    private let ruler = BTSyncRulerView()
    private let hintLabel = NSTextField(labelWithString: "Drag to nudge · hold ⌥ for finer")

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

        configureLabels()
        configureValueField()
        configureButtons()
        configureRuler()
        for subview in [captionLabel, valueField, suffixLabel, minusButton,
                        plusButton, alignButton, revertButton, ruler, hintLabel] {
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

    private func configureLabels() {
        captionLabel.font = Tokens.Font.caption
        captionLabel.textColor = Tokens.Color.tertiaryLabel
        // Composed into `valueField`'s single accessibility value/label
        // instead (house convention, `AudiouterSharedUI/AGENTS.md`: "each
        // channel spoken exactly ONCE, never duplicated across label/value").
        captionLabel.setAccessibilityElement(false)

        suffixLabel.font = Tokens.Font.body
        suffixLabel.textColor = Tokens.Color.secondaryLabel
        suffixLabel.setAccessibilityElement(false)

        hintLabel.font = Tokens.Font.caption
        hintLabel.textColor = Tokens.Color.tertiaryLabel
    }

    private func configureValueField() {
        valueField.translatesAutoresizingMaskIntoConstraints = false
        valueField.font = Tokens.Font.syncReadout
        valueField.textColor = Tokens.Color.label
        valueField.isBordered = false
        valueField.isBezeled = false
        valueField.drawsBackground = false
        valueField.alignment = .left
        valueField.toolTip = "Click to type an exact value — \(Self.stepDescription)"
        // The composed D7 phrase ("22.4 milliseconds later" / "Not set")
        // lives here as ONE accessibility value; `captionLabel`/`suffixLabel`
        // opt out above rather than duplicate it.
        valueField.setAccessibilityLabel("Sync offset")
    }

    private func configureButtons() {
        for (button, symbol, label) in [(minusButton, "minus", "Decrease sync offset"),
                                         (plusButton, "plus", "Increase sync offset")] {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.bezelStyle = .accessoryBar
            button.isBordered = false
            button.imagePosition = .imageOnly
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
                .withSymbolConfiguration(config)
            button.contentTintColor = Tokens.Color.secondaryLabel
            button.setAccessibilityLabel(label)
            button.toolTip = Self.stepDescription
        }
        minusButton.target = self
        minusButton.action = #selector(minusTapped(_:))
        plusButton.target = self
        plusButton.action = #selector(plusTapped(_:))

        alignButton.translatesAutoresizingMaskIntoConstraints = false
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

        revertButton.translatesAutoresizingMaskIntoConstraints = false
        revertButton.bezelStyle = .rounded
        revertButton.controlSize = .small
        revertButton.font = Tokens.Font.caption
        revertButton.title = "Revert"
        revertButton.setAccessibilityLabel("Revert to the value when this drawer opened")
        revertButton.target = self
        revertButton.action = #selector(revertTapped(_:))
    }

    private func configureRuler() {
        ruler.translatesAutoresizingMaskIntoConstraints = false
        ruler.delegate = self
    }

    private func installConstraints() {
        let contentLeading = PopoverColumnGrid.syncDrawerAccentEdgeWidth
            + PopoverColumnGrid.syncDrawerHorizontalInset

        NSLayoutConstraint.activate([
            captionLabel.topAnchor.constraint(equalTo: topAnchor,
                                              constant: PopoverColumnGrid.syncDrawerVerticalInset),
            captionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: contentLeading),

            valueField.topAnchor.constraint(equalTo: captionLabel.bottomAnchor,
                                            constant: PopoverColumnGrid.syncDrawerCaptionToReadoutGap),
            valueField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: contentLeading),

            suffixLabel.leadingAnchor.constraint(equalTo: valueField.trailingAnchor,
                                                 constant: PopoverColumnGrid.syncDrawerReadoutToSuffixGap),
            suffixLabel.firstBaselineAnchor.constraint(equalTo: valueField.firstBaselineAnchor),

            revertButton.trailingAnchor.constraint(equalTo: trailingAnchor,
                                                   constant: -PopoverColumnGrid.syncDrawerHorizontalInset),
            revertButton.centerYAnchor.constraint(equalTo: valueField.centerYAnchor),
            revertButton.heightAnchor.constraint(equalToConstant: PopoverColumnGrid.syncDrawerButtonHeight),

            alignButton.trailingAnchor.constraint(equalTo: revertButton.leadingAnchor,
                                                  constant: -PopoverColumnGrid.syncDrawerButtonGap),
            alignButton.centerYAnchor.constraint(equalTo: valueField.centerYAnchor),
            alignButton.heightAnchor.constraint(equalToConstant: PopoverColumnGrid.syncDrawerButtonHeight),

            plusButton.trailingAnchor.constraint(equalTo: alignButton.leadingAnchor,
                                                 constant: -PopoverColumnGrid.syncDrawerButtonGap),
            plusButton.centerYAnchor.constraint(equalTo: valueField.centerYAnchor),
            plusButton.widthAnchor.constraint(equalToConstant: PopoverColumnGrid.syncDrawerStepperButtonWidth),
            plusButton.heightAnchor.constraint(equalToConstant: PopoverColumnGrid.syncDrawerButtonHeight),

            minusButton.trailingAnchor.constraint(equalTo: plusButton.leadingAnchor,
                                                  constant: -PopoverColumnGrid.syncDrawerButtonGap),
            minusButton.centerYAnchor.constraint(equalTo: valueField.centerYAnchor),
            minusButton.widthAnchor.constraint(equalToConstant: PopoverColumnGrid.syncDrawerStepperButtonWidth),
            minusButton.heightAnchor.constraint(equalToConstant: PopoverColumnGrid.syncDrawerButtonHeight),

            ruler.topAnchor.constraint(equalTo: valueField.bottomAnchor,
                                       constant: PopoverColumnGrid.syncDrawerRulerTopGap),
            ruler.leadingAnchor.constraint(equalTo: leadingAnchor, constant: contentLeading),
            ruler.trailingAnchor.constraint(equalTo: trailingAnchor,
                                            constant: -PopoverColumnGrid.syncDrawerHorizontalInset),
            ruler.heightAnchor.constraint(equalToConstant: PopoverColumnGrid.syncRulerHeight),

            hintLabel.topAnchor.constraint(equalTo: ruler.bottomAnchor,
                                           constant: PopoverColumnGrid.syncDrawerRulerToFooterGap),
            hintLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: contentLeading),
        ])
    }

    // MARK: Drawing — background + accent edge (see header comment for the
    // colour rationale)

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let b = bounds
        Tokens.Color.well.setFill()
        b.fill()
        Tokens.Color.accent.setFill()
        NSRect(x: b.minX, y: b.minY,
               width: PopoverColumnGrid.syncDrawerAccentEdgeWidth, height: b.height).fill()
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
        alignButton.contentTintColor = alignTickActive ? Tokens.Color.accent : Tokens.Color.secondaryLabel
        refreshDisplay()
    }

    /// Captures `trimMs` as the value Revert restores (D8). Call this
    /// exactly once, right when the drawer opens for a device — `configure`
    /// alone can't tell a fresh open from a routine refresh of an
    /// already-open drawer.
    public func noteOpened(trimMs: Double) {
        openTimeMs = trimMs
        refreshDisplay()
    }

    // MARK: Actions

    @objc private func minusTapped(_ sender: NSButton) {
        stepTrim(by: -(optionIsHeld ? BTSyncTrim.fineStepMs : BTSyncTrim.coarseStepMs))
    }

    @objc private func plusTapped(_ sender: NSButton) {
        stepTrim(by: optionIsHeld ? BTSyncTrim.fineStepMs : BTSyncTrim.coarseStepMs)
    }

    private func stepTrim(by deltaMs: Double) {
        applyCommit(clampToUsableRange(BTSyncTrim.quantise(trimMs + deltaMs)))
    }

    @objc private func alignTapped(_ sender: NSButton) {
        // `pushOnPushOff` has already flipped the state; land the tint now
        // so the toggle reads immediately, before the host's re-apply echoes
        // it — mirrors `DeviceRowView.alignTapped` exactly.
        alignButton.contentTintColor = sender.state == .on
            ? Tokens.Color.accent : Tokens.Color.secondaryLabel
        delegate?.syncDrawer(self, didToggleAlignTick: sender.state == .on)
    }

    @objc private func revertTapped(_ sender: NSButton) {
        applyCommit(clampToUsableRange(openTimeMs))
    }

    /// Escape, anywhere in the drawer other than an in-progress field edit
    /// (which `SyncValueFieldEditor` consumes for its own revert — see its
    /// header comment). Standard AppKit key-binding translation: an
    /// unhandled Escape is delivered up the responder chain as this action
    /// message (`ControlPanelWindowController.cancelOperation` is the same
    /// codebase idiom for "Escape closes this").
    public override func cancelOperation(_ sender: Any?) {
        delegate?.syncDrawerDidRequestClose(self)
    }

    /// Whether ⌥ is held for the current stepper click — mirrors
    /// `DeviceRowView.optionIsHeld` / `BTSyncRulerView.optionIsHeld`.
    private var optionIsHeld: Bool {
        test_optionModifierOverride ?? (NSApp?.currentEvent?.modifierFlags.contains(.option) ?? false)
    }

    /// Modifier seam for the stepper tests — same idiom as
    /// `DeviceRowView.test_optionModifierOverride`; `nil` (default) reads
    /// the live event.
    public var test_optionModifierOverride: Bool?

    // MARK: Commit / scrub plumbing

    private func clampToUsableRange(_ ms: Double) -> Double {
        Swift.min(usableRangeMs.upperBound, Swift.max(usableRangeMs.lowerBound, ms))
    }

    /// A live ruler scrub (D6): apply to audio, do not persist.
    private func applyScrub(_ ms: Double) {
        trimMs = ms
        isSet = true
        refreshDisplay()
        delegate?.syncDrawer(self, didChangeTrimMs: ms, committed: false)
    }

    /// A discrete, complete gesture (drag end, stepper click, typed commit,
    /// Revert): apply AND persist.
    private func applyCommit(_ ms: Double) {
        trimMs = ms
        isSet = true
        refreshDisplay()
        delegate?.syncDrawer(self, didChangeTrimMs: ms, committed: true)
    }

    private func refreshDisplay() {
        captionLabel.stringValue = "\(deviceName) plays"
        valueFieldEditor.setCommittedValue(trimMs, displayText: Self.magnitudeText(trimMs, isSet: isSet))
        suffixLabel.stringValue = Self.suffixText(trimMs, isSet: isSet)
        ruler.usableRangeMs = usableRangeMs
        ruler.valueMs = trimMs
        revertButton.isEnabled = BTSyncTrim.quantise(trimMs) != BTSyncTrim.quantise(openTimeMs)
        valueField.setAccessibilityLabel("Sync offset for \(deviceName)")
        valueField.setAccessibilityValue(isSet ? BTSyncRulerView.accessibilityValueDescription(for: trimMs) : "Not set")
    }

    /// D7's split visual format: the value field shows only the MAGNITUDE
    /// (never a bare signed number — the suffix label carries direction).
    /// D10: an untuned device reads "Not set" here instead of a number.
    private static func magnitudeText(_ ms: Double, isSet: Bool) -> String {
        guard isSet else { return "Not set" }
        return String(format: "%.1f", abs(ms))
    }

    private static func suffixText(_ ms: Double, isSet: Bool) -> String {
        guard isSet else { return "" }
        let quantised = BTSyncTrim.quantise(ms)
        if quantised == 0 { return "ms" }
        return quantised > 0 ? "ms later" : "ms earlier"
    }

    private static var stepDescription: String {
        "\(String(format: "%g", BTSyncTrim.coarseStepMs)) ms steps — hold ⌥ for \(String(format: "%g", BTSyncTrim.fineStepMs)) ms"
    }

    // MARK: Test hooks — real dispatch through the exact delegate/action seam
    // (house convention, `AudiouterSharedUI/AGENTS.md`)

    public var test_trimMs: Double { trimMs }
    public var test_isSet: Bool { isSet }
    public var test_revertEnabled: Bool { revertButton.isEnabled }
    public var test_alignActive: Bool { alignButton.state == .on }
    public var test_valueFieldText: String { valueField.stringValue }
    public var test_suffixText: String { suffixLabel.stringValue }
    public var test_captionText: String { captionLabel.stringValue }
    public var test_ruler: BTSyncRulerView { ruler }
    public var test_valueFieldEditor: SyncValueFieldEditor { valueFieldEditor }

    public func test_fireMinusClick() { minusButton.performClick(nil) }
    public func test_firePlusClick() { plusButton.performClick(nil) }
    public func test_fireAlignClick() { alignButton.performClick(nil) }
    public func test_fireRevertClick() { revertButton.performClick(nil) }
    public func test_fireCancelOperation() { cancelOperation(nil) }
}

// MARK: - BTSyncRulerViewDelegate (T4 composition)

extension BTSyncDrawerView: BTSyncRulerViewDelegate {
    public func syncRuler(_ ruler: BTSyncRulerView, didScrubTo ms: Double) {
        applyScrub(ms)
    }

    public func syncRulerDidEndScrub(_ ruler: BTSyncRulerView) {
        applyCommit(ruler.valueMs)
    }
}

// MARK: - SyncValueFieldEditorDelegate

extension BTSyncDrawerView: SyncValueFieldEditorDelegate {
    public func syncValueFieldEditor(_ editor: SyncValueFieldEditor, didCommit ms: Double) {
        applyCommit(ms)
    }
}
