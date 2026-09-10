// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore

/// Reports every gesture out of a ``BTSyncDrawerView`` (PLAN-BT-SYNC-DRAWER
/// T5) back to its host.
public protocol BTSyncDrawerViewDelegate: AnyObject {
    /// A committed trim change — a stepper click or a typed field commit.
    /// Apply AND persist. (There is no longer a live-scrub /
    /// don't-persist case: the scrubbing ruler that needed it was cut. Every
    /// change the drawer now makes is a discrete, complete gesture, so
    /// `committed` is always true — the parameter stays for the host's
    /// existing wiring and in case a live control returns later.)
    func syncDrawer(_ d: BTSyncDrawerView, didChangeTrimMs ms: Double, committed: Bool)
    /// The tick (metronome) toggle, moved off the row into the drawer (D9).
    func syncDrawer(_ d: BTSyncDrawerView, didToggleAlignTick active: Bool)
    /// Escape, pressed anywhere in the drawer OTHER than the value field
    /// (the field's own Escape reverts an in-progress edit instead —
    /// consumed inside `SyncValueFieldEditor`, never reaching here). This
    /// drawer has no visible close affordance of its own (T6's row chip
    /// owns opening/closing); the host decides how — or whether — to react.
    func syncDrawerDidRequestClose(_ d: BTSyncDrawerView)
    /// "Align again…", the drawer's leading button: re-run the guided
    /// alignment wizard for this device, opening on its last result. The row's
    /// "Align by ear…" context-menu item is the other visible door.
    func syncDrawerDidRequestAlignmentWizard(_ d: BTSyncDrawerView)
    /// "Reset alignment" (roadmap 056): delete this device's STORED alignment —
    /// its measured latency and its trim — returning the row to "Not set".
    func syncDrawerDidRequestResetAlignment(_ d: BTSyncDrawerView)
}

public extension BTSyncDrawerViewDelegate {
    /// Default no-op — only the popover hosts the alignment wizard.
    func syncDrawerDidRequestAlignmentWizard(_ d: BTSyncDrawerView) {}
    /// Default no-op — only the popover owns the stores Reset clears.
    func syncDrawerDidRequestResetAlignment(_ d: BTSyncDrawerView) {}
}

/// The **BT sync drawer** (PLAN-BT-SYNC-DRAWER §3 T5): the panel that opens
/// underneath a Bluetooth row when its SYNC value chip (T6) is clicked. ONE
/// horizontal band:
///
///     [⑂ Align again…] [♪ Play ticks] [Reset alignment]   hold ⇧ for 10 ms   [ − | −414 ms | + ]
///
/// with one caption line under it, carrying where the applied offset came
/// from or the over-40 ms notice.
///
/// **Why the two halves sit at opposite ends.** The two alignment doors and
/// Reset lead the band; the value cluster hugs the trailing edge so it lands
/// directly beneath the chip that opened the drawer. Reset deletes what is
/// stored, so it is parked as far from the steppers as the band allows — a
/// Reset adjacent to `−` is one slipped click away from discarding the
/// adjustment in progress.
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
/// themes, which is what "opens downward" needs to read. It is also EDGED,
/// in two weights (2026-09-03), because the fill alone stopped carrying it:
/// on the flat light ground the well is only 1.154:1 from the card, under the
/// 1.25:1 edge floor, so the boundary has to be drawn. The sides and bottom
/// bound the recess and take the container's own edge
/// (``Tokens/Color/containerEdge``, 1.75:1 on `well` light, 2.01:1 dark); the
/// TOP is not a card edge at all but the divider between this drawer and the
/// device row above it — the drawer is a full-width row clip inside the card
/// stack — so it takes ``Tokens/Color/hairline``, the rank below (1.31:1 on
/// `well` light, 1.49:1 dark, both over the edge floor). This overrides an
/// earlier live finding that the well needed no edge; it is on the owed
/// eye-check list. The tick toggle
/// keeps the exact `engagedChrome`/`label2` treatment it has on the row today
/// (`DeviceRowView.alignTapped`). The background is drawn in `draw(_:)`, not
/// stamped into a `CALayer`, so it re-resolves live on every pass with no
/// `viewDidChangeEffectiveAppearance` observer needed. Every control in the
/// band carries its own STOCK bezel, so AppKit re-resolves all of that chrome
/// per appearance too.
public final class BTSyncDrawerView: NSView {

    // MARK: Auto-repeat timing
    //
    // Timing, not geometry: `PopoverColumnGrid` holds METRICS, so these live
    // with the control they time. Matched to
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

    /// What "Align again…" promises: another guided run, seeded by the last.
    static let alignAgainTooltip =
        "Measure this speaker again. Opens on the last result."

    // MARK: Subviews

    private let alignAgainButton = NSButton()
    private let alignButton = NSButton()
    private let resetButton = NSButton()
    private let hintLabel = NSTextField(labelWithString: "")
    private let captionLabel = NSTextField(labelWithString: "")
    private let minusButton = NSButton()
    private let plusButton = NSButton()
    private let valueField = NSTextField()

    private lazy var valueFieldEditor = SyncValueFieldEditor(field: valueField, initialValue: 0)

    public weak var delegate: BTSyncDrawerViewDelegate?

    // MARK: State — pushed by `configure` (T7 reuses one instance across
    // devices rather than creating one per row).

    private var deviceName = ""
    private var trimMs: Double = 0
    private var isSet = false
    /// Whether this device has anything STORED to reset — a measured latency, a
    /// trim, or (on the Mac's row) a set local offset. Pushed by the host,
    /// which owns both stores; a Reset button over nothing to clear is an
    /// offer the gesture would refuse.
    private var canReset = false
    /// Whether this device has a guided wizard at all — pushed by the host,
    /// which owns the refusal (a Cast receiver plays seconds behind live, so
    /// no by-ear bisection converges on it). A visible button whose click the
    /// host would refuse is worse than no button.
    private var canAlignAgain = false
    /// Where the applied offset came from — the caption line's usual text.
    /// `nil` on a speaker nothing has measured, where the line is empty and
    /// still reserved.
    private var offsetSource: BTOffsetSource?
    /// The over-40 ms notice's number, when one stands. It takes the caption
    /// line from the source until the host clears it, which the host does when
    /// the drawer closes.
    private var movedSinceLastTimeMs: Double?
    /// The band's leading anchor, swapped when "Align again…" is hidden: the
    /// metronome takes its place rather than leaving a 110 pt hole.
    private var alignLeadingToAlignAgain: NSLayoutConstraint?
    private var alignLeadingToEdge: NSLayoutConstraint?
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
        for subview in [minusButton, plusButton, valueField, alignAgainButton,
                        alignButton, resetButton, hintLabel, captionLabel] as [NSView] {
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
        // "Align by ear" names the paired-click WIZARD and nothing else (the
        // glossary in `audiout-shared/CONTEXT.md`), so the toggle that plays
        // the ticks says what it does. The phone's fine-tune page calls the
        // same thing "Start the ticks" / "Stop the ticks"; both apps say
        // "ticks".
        alignButton.title = "Play ticks"
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
        alignButton.contentTintColor = Tokens.Color.label2
        // `DeviceRowView.alignTooltip` — one string, shared across its module
        // (both types live in `AudioutSharedUI`), not re-authored here.
        alignButton.toolTip = DeviceRowView.alignTooltip
        alignButton.setAccessibilityLabel("Play ticks")
        alignButton.setAccessibilityHelp(DeviceRowView.alignTooltip)
        alignButton.target = self
        alignButton.action = #selector(alignTapped(_:))

        // Same push-button voice as the tick toggle beside it, and the same
        // glyph configuration — this one re-runs the guided wizard, that one
        // plays ticks.
        alignAgainButton.bezelStyle = .rounded
        alignAgainButton.controlSize = .small
        alignAgainButton.font = Tokens.Font.caption
        alignAgainButton.imagePosition = .imageLeading
        alignAgainButton.title = "Align again…"
        alignAgainButton.image = NSImage(systemSymbolName: "tuningfork",
                                         accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
        alignAgainButton.contentTintColor = Tokens.Color.label2
        alignAgainButton.toolTip = Self.alignAgainTooltip
        alignAgainButton.setAccessibilityLabel("Align again")
        alignAgainButton.setAccessibilityHelp(Self.alignAgainTooltip)
        alignAgainButton.target = self
        alignAgainButton.action = #selector(alignAgainTapped(_:))

        // Reset deletes the stored alignment (the measured latency AND the
        // nudge) so the row goes back to "Not set". Shown only when there IS
        // something stored to clear.
        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .small
        resetButton.font = Tokens.Font.caption
        resetButton.title = "Reset alignment"
        let resetHelp = "Clear the measured alignment and the sync nudge for this speaker."
        resetButton.setAccessibilityLabel("Reset alignment")
        resetButton.setAccessibilityHelp(resetHelp)
        resetButton.toolTip = resetHelp
        resetButton.target = self
        resetButton.action = #selector(resetTapped(_:))
    }

    private func configureLabels() {
        // The ⇧ hint sits next to the buttons it modifies, not in a tooltip:
        // a coarse step is the second thing anyone needs here, and a modifier
        // nobody is told about does not exist.
        hintLabel.stringValue = "hold \u{21E7} for 10 ms"
        hintLabel.font = Tokens.Font.caption
        hintLabel.textColor = Tokens.Color.label3

        // Where the applied offset came from, or the over-40 ms notice — a
        // NOTE, never a failure, so it keeps `label2` in both cases.
        captionLabel.font = Tokens.Font.caption
        captionLabel.textColor = Tokens.Color.label2
        captionLabel.lineBreakMode = .byTruncatingTail
        captionLabel.usesSingleLineMode = true
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

        // The band is its own guide now that a caption line hangs under it:
        // every control centres on the BAND rather than on the drawer, so
        // adding the line left the band exactly where it was.
        let band = NSLayoutGuide()
        addLayoutGuide(band)

        NSLayoutConstraint.activate([
            band.topAnchor.constraint(equalTo: topAnchor,
                                      constant: PopoverColumnGrid.syncDrawerVerticalInset),
            band.leadingAnchor.constraint(equalTo: leadingAnchor),
            band.trailingAnchor.constraint(equalTo: trailingAnchor),
            band.heightAnchor.constraint(equalToConstant: controlH),

            captionLabel.topAnchor.constraint(
                equalTo: band.bottomAnchor,
                constant: PopoverColumnGrid.syncDrawerCaptionGap),
            captionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            captionLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor, constant: -inset),
            captionLabel.heightAnchor.constraint(
                equalToConstant: PopoverColumnGrid.syncDrawerCaptionHeight),

            // LEADING half: the two alignment doors and Reset, together, as
            // far from the steppers as the band allows (see the header comment).
            alignAgainButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            alignAgainButton.centerYAnchor.constraint(equalTo: band.centerYAnchor),
            alignAgainButton.widthAnchor.constraint(
                equalToConstant: PopoverColumnGrid.syncDrawerAlignAgainButtonWidth),
            alignAgainButton.heightAnchor.constraint(equalToConstant: controlH),

            alignButton.centerYAnchor.constraint(equalTo: band.centerYAnchor),
            alignButton.widthAnchor.constraint(equalToConstant: PopoverColumnGrid.syncDrawerAlignButtonWidth),
            alignButton.heightAnchor.constraint(equalToConstant: controlH),

            resetButton.leadingAnchor.constraint(equalTo: alignButton.trailingAnchor,
                                                 constant: PopoverColumnGrid.syncDrawerButtonGap),
            resetButton.centerYAnchor.constraint(equalTo: alignButton.centerYAnchor),
            resetButton.widthAnchor.constraint(equalToConstant: PopoverColumnGrid.syncDrawerResetButtonWidth),
            resetButton.heightAnchor.constraint(equalToConstant: controlH),

            // TRAILING half, laid out trailing→leading so it lands directly
            // beneath the SYNC chip that opened the drawer: `+`, the unit, the
            // typeable box, `−`. Each control carries its OWN stock bezel — an
            // earlier version fused all three inside one hairline `NSBox`, and
            // on the drawer's flat fill that read as a single dead slab with
            // the buttons dissolved into it (live-found). Separate bezels give
            // each control its own edge, which is what makes them look
            // pressable; adjacency alone still binds them to the number.
            plusButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            plusButton.centerYAnchor.constraint(equalTo: band.centerYAnchor),
            plusButton.widthAnchor.constraint(equalToConstant: stepperW),
            plusButton.heightAnchor.constraint(equalToConstant: controlH),

            valueField.trailingAnchor.constraint(equalTo: plusButton.leadingAnchor,
                                                 constant: -PopoverColumnGrid.syncDrawerStepperToValueGap),
            valueField.centerYAnchor.constraint(equalTo: band.centerYAnchor),
            valueField.widthAnchor.constraint(equalToConstant: PopoverColumnGrid.syncDrawerValueFieldWidth),
            valueField.heightAnchor.constraint(equalToConstant: controlH),

            minusButton.trailingAnchor.constraint(equalTo: valueField.leadingAnchor,
                                                  constant: -PopoverColumnGrid.syncDrawerStepperToValueGap),
            minusButton.centerYAnchor.constraint(equalTo: band.centerYAnchor),
            minusButton.widthAnchor.constraint(equalToConstant: stepperW),
            minusButton.heightAnchor.constraint(equalToConstant: controlH),

            hintLabel.trailingAnchor.constraint(equalTo: minusButton.leadingAnchor,
                                                constant: -PopoverColumnGrid.syncDrawerHintToClusterGap),
            hintLabel.centerYAnchor.constraint(equalTo: band.centerYAnchor),
        ])

        // Two leading anchors for the metronome, one live at a time: behind
        // "Align again…" when that door exists, at the band's own edge when it
        // does not. Hiding a button Auto Layout still anchors to would leave
        // its width as a hole.
        alignLeadingToAlignAgain = alignButton.leadingAnchor.constraint(
            equalTo: alignAgainButton.trailingAnchor,
            constant: PopoverColumnGrid.syncDrawerButtonGap)
        alignLeadingToEdge = alignButton.leadingAnchor.constraint(
            equalTo: leadingAnchor, constant: inset)
        applyAlignAgainVisibility()
    }

    /// Mount or hide the guided-wizard door and move the band's leading edge
    /// with it.
    private func applyAlignAgainVisibility() {
        alignAgainButton.isHidden = !canAlignAgain
        alignLeadingToAlignAgain?.isActive = canAlignAgain
        alignLeadingToEdge?.isActive = !canAlignAgain
    }

    // MARK: Drawing — well fill, containerEdge recess, hairline divider

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        Tokens.Color.well.setFill()
        bounds.fill()

        // Two edge weights, because the four sides are not the same thing.
        // The sides and the bottom BOUND the recess, so they carry the
        // container's own edge; the top is the divider between this drawer and
        // the device row it opened under — rows inside one container — which
        // is `hairline`, a rank lighter. This view is not flipped, so the
        // visual top is `maxY`.
        let inset = bounds.insetBy(dx: 0.5, dy: 0.5)
        let recess = NSBezierPath()
        recess.move(to: NSPoint(x: inset.minX, y: inset.maxY))
        recess.line(to: NSPoint(x: inset.minX, y: inset.minY))
        recess.line(to: NSPoint(x: inset.maxX, y: inset.minY))
        recess.line(to: NSPoint(x: inset.maxX, y: inset.maxY))
        recess.lineWidth = 1
        Tokens.Color.containerEdge.setStroke()
        recess.stroke()

        Tokens.Color.hairline.setFill()
        NSRect(x: bounds.minX, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }


    // MARK: Public API (T7)

    /// Push a fresh model snapshot. Guards the value field's DISPLAYED text
    /// against an in-progress edit exactly as `DeviceRowView.configure`
    /// guards `syncField` (`SyncValueFieldEditor.setCommittedValue`'s own
    /// `currentEditor() == nil` check) — the internal state updates either
    /// way, only the on-screen text is protected.
    public func configure(deviceName: String, trimMs: Double, isSet: Bool,
                          usableRangeMs: ClosedRange<Double>, alignTickActive: Bool,
                          canReset: Bool = false, canAlignAgain: Bool = false,
                          offsetSource: BTOffsetSource? = nil,
                          movedSinceLastTimeMs: Double? = nil) {
        self.deviceName = deviceName
        self.trimMs = trimMs
        self.isSet = isSet
        self.usableRangeMs = usableRangeMs
        self.canReset = canReset
        self.canAlignAgain = canAlignAgain
        self.offsetSource = offsetSource
        self.movedSinceLastTimeMs = movedSinceLastTimeMs
        alignButton.state = alignTickActive ? .on : .off
        alignButton.contentTintColor = alignTickActive
            ? Tokens.Color.engagedChrome : Tokens.Color.label2
        refreshDisplay()
    }

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

    /// Put a SUGGESTED value in the field, focused and selected, without
    /// applying it (the alignment wizard's "Set it by hand"). The drawer emits
    /// committed gestures only, and a number the user has merely been shown is
    /// not one — Return commits it like any typed edit, Escape puts the stored
    /// value back, and until then nothing has been written.
    ///
    /// Deliberately NOT `noteExternalTrimChange`: that is a gesture the user
    /// already made, so it moves the model with it.
    public func beginEditingSuggestedValue(_ ms: Double) {
        focusValueField()
        valueField.stringValue = "\(Int(BTSyncTrim.snap(ms)))"
        valueField.currentEditor()?.selectAll(nil)
    }

    /// A trim written by something OUTSIDE the drawer while it stands open —
    /// the alignment wizard's Keep, which zeroes the nudge its run suspended.
    ///
    /// Not `configure`: that is a background model push, and it deliberately
    /// refuses to yank text out from under an in-progress edit — so the field
    /// would go on SHOWING the pre-run value and commit it straight back over
    /// the measurement on its way out (live defect, 2026-08-22). This is a
    /// gesture in its own right, so it wins over a live edit exactly as the
    /// steppers do.
    public func noteExternalTrimChange(_ ms: Double) {
        trimMs = ms
        isSet = true
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
        // `snap`, not `quantise`: the host's usable range is the ONE bound a
        // drawer answers to (a Cast row's reaches past ±`BTSyncTrim.rangeMs`),
        // and `clampToUsableRange` right here is what applies it.
        applyCommit(clampToUsableRange(BTSyncTrim.snap(trimMs + deltaMs)))
    }

    @objc private func alignAgainTapped(_ sender: NSButton) {
        delegate?.syncDrawerDidRequestAlignmentWizard(self)
    }

    @objc private func alignTapped(_ sender: NSButton) {
        // `pushOnPushOff` has already flipped the state; land the tint now
        // so the toggle reads immediately, before the host's re-apply echoes
        // it — mirrors `DeviceRowView.alignTapped` exactly.
        alignButton.contentTintColor = sender.state == .on
            ? Tokens.Color.engagedChrome : Tokens.Color.label2
        delegate?.syncDrawer(self, didToggleAlignTick: sender.state == .on)
    }

    /// Reset alignment: a gesture of this drawer's own, so it moves its OWN
    /// display here rather than waiting for the host's next `configure` — that
    /// is a background model push and by contract never overwrites text being
    /// edited, which would leave the field showing (and later committing) the
    /// value just cleared. Same reasoning as `noteExternalTrimChange`, but this
    /// one lands on NOT-SET rather than on a value.
    @objc private func resetTapped(_ sender: NSButton) {
        trimMs = 0
        isSet = false
        canReset = false
        refreshDisplay()
        valueFieldEditor.overrideEditedValue(0)
        delegate?.syncDrawerDidRequestResetAlignment(self)
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

    /// A discrete, complete gesture (stepper click or typed commit): apply
    /// AND persist.
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
        // Hidden, not disabled: with nothing stored there is nothing to explain
        // — a permanently dead button in the band would only invite the
        // question. Nothing is anchored to it, so hiding it moves no other
        // control.
        resetButton.isHidden = !canReset
        applyAlignAgainVisibility()
        // D7 (never a bare signed number with no direction) lives in the
        // spoken value and the field's tooltip — the visible number carries
        // its sign, and the row chip above the drawer states "N ms" for
        // context. The drawer stays compact (live feedback), so there is no
        // visible caption sentence.
        captionLabel.stringValue = captionText
        // The line is chrome when it is empty (a reserved row keeps the band
        // from jumping) and a real element when it is not.
        captionLabel.setAccessibilityElement(!captionText.isEmpty)
        spokenValue = isSet ? BTSyncTrim.spokenOffset(trimMs) : "Not set"
        valueField.setAccessibilityLabel("Sync offset for \(deviceName)")
        valueField.setAccessibilityValue(spokenValue)
        valueField.toolTip = "\(deviceName): \(isSet ? BTSyncTrim.spokenOffset(trimMs) : "not tuned yet"). Type an exact value in whole milliseconds."
    }

    /// What the caption line says: the over-40 ms notice while one stands,
    /// otherwise where the applied offset came from, otherwise nothing —
    /// a speaker nobody has measured has no source to name, and the line
    /// stays reserved so the band never jumps when one arrives.
    private var captionText: String {
        if let movedSinceLastTimeMs {
            return BTOffsetSource.movedNotice(byMs: movedSinceLastTimeMs)
        }
        return offsetSource?.drawerCaption ?? ""
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
        "\(Int(BTSyncTrim.snap(ms))) ms"
    }

    // MARK: ⇧ modifier seam (a headless click carries no real
    // `NSApp.currentEvent`, and in a narrowly filtered `swift test` run `NSApp`
    // itself — an implicitly-unwrapped optional — can still be nil, so this
    // reads it via `?`, never force-unwrapped.)

    public var test_shiftModifierOverride: Bool?

    private var shiftIsHeld: Bool {
        test_shiftModifierOverride ?? (NSApp?.currentEvent?.modifierFlags.contains(.shift) ?? false)
    }

    // MARK: Test hooks — real dispatch through the exact delegate/action seam
    // (house convention, `AudioutSharedUI/AGENTS.md`)

    public var test_trimMs: Double { trimMs }
    public var test_isSet: Bool { isSet }
    public var test_usableRangeMs: ClosedRange<Double> { usableRangeMs }
    /// Whether the "Reset alignment" button is on screen at all (it is hidden,
    /// not disabled, when there is nothing stored to clear).
    public var test_resetVisible: Bool { !resetButton.isHidden }
    public var test_resetTitle: String { resetButton.title }
    public var test_alignActive: Bool { alignButton.state == .on }
    public var test_alignAgainTitle: String { alignAgainButton.title }
    /// Whether the guided-wizard door is on screen at all (it is hidden, not
    /// disabled, for a device with no wizard).
    public var test_alignAgainVisible: Bool { !alignAgainButton.isHidden }
    /// The band's leading buttons and the hint, for the layout guards.
    public var test_bandFrames: (alignAgain: NSRect, align: NSRect, reset: NSRect,
                                hint: NSRect, minus: NSRect) {
        (alignAgainButton.frame, alignButton.frame, resetButton.frame,
         hintLabel.frame, minusButton.frame)
    }
    public var test_valueField: NSTextField { valueField }
    public var test_valueFieldText: String { valueField.stringValue }
    public var test_valueFieldIsBezeled: Bool { valueField.isBezeled }
    public var test_stepperButtonsAreBezeled: Bool {
        minusButton.isBordered && plusButton.isBordered
    }
    public var test_valueFieldAXValue: String { spokenValue }
    public var test_valueFieldEditor: SyncValueFieldEditor { valueFieldEditor }
    public var test_hintText: String { hintLabel.stringValue }
    /// The caption line under the band — empty on a speaker with no source.
    public var test_captionText: String { captionLabel.stringValue }
    public var test_captionTextColor: NSColor? { captionLabel.textColor }
    public var test_captionFrame: NSRect { captionLabel.frame }
    public var test_alignTitle: String { alignButton.title }
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
    public func test_fireAlignAgainClick() { alignAgainButton.performClick(nil) }
    public func test_fireAlignClick() { alignButton.performClick(nil) }
    public func test_fireResetClick() { resetButton.performClick(nil) }
    public func test_fireCancelOperation() { cancelOperation(nil) }
}

// MARK: - SyncValueFieldEditorDelegate

extension BTSyncDrawerView: SyncValueFieldEditorDelegate {
    public func syncValueFieldEditor(_ editor: SyncValueFieldEditor, didCommit ms: Double) {
        applyCommit(ms, fromField: true)
    }
}
