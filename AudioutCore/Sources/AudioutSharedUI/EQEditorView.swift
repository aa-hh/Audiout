// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore

/// Reports every gesture out of an ``EQEditorView`` back to its host, in the
/// same shape ``BTSyncDrawerViewDelegate`` uses — the editor owns no model and
/// never talks to a backend.
public protocol EQEditorViewDelegate: AnyObject {
    /// A tone change. `committed == false` is a live scrub — apply to audio,
    /// persist nothing; `committed == true` is the gesture that ends it
    /// (mouse-up, a checkbox click, a keyboard step): apply AND persist. Same
    /// split the sync trim carries, for the same reason: a drag would
    /// otherwise rewrite the store dozens of times a second.
    func eqEditor(_ editor: EQEditorView, didChange eq: DeviceEQ, committed: Bool)
    /// The host's Reset button (via ``resetToFlat()``): put every stage back
    /// to flat, in ONE committed action. Separate from
    /// ``eqEditor(_:didChange:committed:)`` so the host can treat "the user
    /// cleared this device" as its own event rather than having to recognise
    /// a flat value.
    func eqEditorDidRequestReset(_ editor: EQEditorView)
}

/// The **EQ editor**: the tone controls for one speaker (or the whole mix),
/// hosted by the Groups screen's detail panes. State pushed in by
/// ``apply(eq:bypassReason:)``, gestures reported out through a delegate — it
/// owns no model and reaches no backend.
///
/// **Two tiers, both live at once.** The simple tier (Bass / Treble / Balance /
/// Loudness) is always visible; the ten-band graphic sits behind an "Advanced"
/// disclosure because most people never want it and a wall of vertical faders
/// would be the loudest thing on the panel. They are not two views of one
/// setting — ``DeviceEQ`` keeps both, so opening Advanced never discards a
/// Bass adjustment and vice versa. Reset lives on the host's "Equalizer" title
/// line and calls ``resetToFlat()`` — the loudness row is the checkbox alone.
///
/// **The Advanced row is a section row, not a bare disclosure.** A 1 pt
/// hairline sits above it; the word "Advanced" is clickable exactly like the
/// triangle; a `tertiaryLabel` hint names the band count ("10 bands"); and a
/// trailing readout counts the shaped bands ("N set", blank when flat). Every
/// channel is composed into one spoken label. The expanded/collapsed state is
/// one global switch — ``AppSettings/eqAdvancedExpanded`` — read at init and
/// applied instantly (no animation on first layout) and written on every
/// toggle, so every host's editor remembers the same state across launches.
///
/// **Stock AppKit only, and almost no surface of its own.** Every control here
/// is an un-subclassed `NSSlider`, `NSButton` or `NSTextField`, and every
/// colour is a semantic ``Tokens`` value. The editor draws nothing except that
/// one hairline: the host's `GroupedSectionView` is the well it sits in, and
/// the other custom-drawn element is the ``EQResponseCurveView`` scope, which
/// owns its own drawing. Its insets are zero for the same reason — the section
/// supplies the padding.
///
/// **The scope lives INSIDE the Advanced fold**, full width, directly above the
/// ten faders, whose columns are each centred on the scope's gridline for that
/// band (``EQResponseCurveView/bandCentreX(index:width:)``) — one x-axis shared
/// by the picture and the controls that shape it. At rest the card is the
/// simple tier alone: a curve drawn over Bass/Treble/Balance, whose axis means
/// something else entirely, reads as decoration rather than a readout.
public final class EQEditorView: NSView {

    // MARK: Copy — the exact strings the host contract names

    /// The sentence for each way a stored EQ can be inaudible
    /// (`Device.EQBypassReason`). The values stay on screen and stay editable;
    /// only this sentence says they are not reaching the audio right now — and
    /// it has to name the actual cause, because the two have nothing in common
    /// and nothing else on the row tells the user which one they are in.
    public static func bypassNoteText(_ reason: Device.EQBypassReason) -> String {
        switch reason {
        case .streamBudget: return "Not applied — too many different EQ settings at once."
        case .perAppRouting: return "Not applied — apps are routed directly to this speaker."
        }
    }
    /// The band labels, in ``DeviceEQ/bandCentresHz`` order. Spelled here
    /// rather than formatted from the centres: "1k" is not what any number
    /// formatter produces from 1000, and the ten strings are the contract.
    static let bandTitles = ["31", "63", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]

    // MARK: Metrics

    // The editor's own geometry — this one panel's internal spacings, not a
    // shared column ruler. The two INSETS are zero because the host's
    // `GroupedSectionView` already pads the well; a second inset here would
    // narrow the scope inside a lane that is already inset.
    private static let eqDrawerHorizontalInset: CGFloat = 0
    private static let eqDrawerVerticalInset: CGFloat = 0
    private static let eqDrawerRowSpacing: CGFloat = 8
    private static let eqDrawerCaptionWidth: CGFloat = 56
    private static let eqDrawerReadoutWidth: CGFloat = 48
    private static let eqDrawerControlHeight: CGFloat = 20
    private static let eqDrawerBandSliderHeight: CGFloat = 76
    private static let eqDrawerBandColumnWidth: CGFloat = 26
    /// The scope sits close to the faders on purpose: they are one instrument,
    /// and a row gap's worth of air would read as two stacked things.
    private static let eqDrawerScopeToFaderGap: CGFloat = 4

    // MARK: Subviews

    private let contentStack = NSStackView()
    private let curve = EQResponseCurveView()
    private let bypassLabel = NSTextField(labelWithString: "")

    private let bassSlider = NSSlider()
    private let bassReadout = NSTextField(labelWithString: "")
    private let trebleSlider = NSSlider()
    private let trebleReadout = NSTextField(labelWithString: "")
    private let balanceSlider = NSSlider()
    private let balanceReadout = NSTextField(labelWithString: "")
    private let loudnessCheckbox = NSButton()
    // Row captions, kept as stored views (rather than built inline in
    // `sliderRow`) so `EQEditorViewTests` can compare frames without a
    // second, view-hierarchy-walking lookup.
    private let bassCaption = NSTextField(labelWithString: "Bass")
    private let trebleCaption = NSTextField(labelWithString: "Treble")
    private let balanceCaption = NSTextField(labelWithString: "Balance")

    private let advancedDivider = ContainerEdgeView()
    private let advancedHeader = NSStackView()
    private let advancedDisclosure = NSButton()
    private let advancedTitle = NSButton()
    private let advancedHint = NSTextField(labelWithString: "\(DeviceEQ.bandCount) bands")
    private let advancedReadout = NSTextField(labelWithString: "")
    private let advancedClip = NSView()
    // A plain view, not a stack: the fader columns are positioned by the
    // SCOPE's x-axis, not by an even distribution, so there is no stack
    // arrangement that could produce them.
    private let advancedContent = NSView()
    private let hzLegend = NSTextField(labelWithString: "Hz")
    private var advancedClipCollapsed: NSLayoutConstraint!
    private var bandSliders: [NSSlider] = []
    private var bandLabels: [NSTextField] = []
    private var bandColumns: [NSView] = []

    public weak var delegate: EQEditorViewDelegate?

    private let settings: AppSettings

    // MARK: State — pushed by `apply`, never read from a model

    private var eq: DeviceEQ = .flat
    private var bypassReason: Device.EQBypassReason?
    private var advancedExpanded = false

    /// The slider currently mid-pointer-drag, if any. `refreshDisplay` must
    /// never write this one: overwriting a slider's `doubleValue` while
    /// AppKit's own drag loop is still tracking it is what turns a queued,
    /// now-stale snapshot into a knob that visibly jumps back and rubber-bands
    /// forward again after mouse-up.
    private weak var pointerTrackedSlider: NSSlider?

    public init(settings: AppSettings = AppSettings()) {
        self.settings = settings
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

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = EQEditorView.eqDrawerRowSpacing
        contentStack.distribution = .fill
        addSubview(contentStack)

        let inset = EQEditorView.eqDrawerHorizontalInset
        let vInset = EQEditorView.eqDrawerVerticalInset
        // Pinned on all four edges: the drawer's height IS its content's
        // height. `BTSyncDrawerView`'s trap #6 applies here too — an ambiguous
        // drawer height silently collapses the popover instead of erroring —
        // but this drawer's height genuinely changes (the Advanced fold), so a
        // definite CONSTANT would be the wrong fix; a fully pinned content
        // chain is the definite-but-flexible one.
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: vInset),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -vInset),
        ])

        configureNotes()
        configureSimpleTier()
        configureAdvancedTier()

        if settings.eqAdvancedExpanded {
            advancedDisclosure.state = .on
            setAdvancedExpanded(true, animated: false)
        }

        refreshDisplay()
    }

    /// Add a row to the column and make it span the column's full width. The
    /// width constraint is activated only AFTER the row is an arranged
    /// subview: a constraint between two views with no common ancestor yet
    /// raises, and `contentStack` becomes the row's ancestor here.
    private func addFullWidthRow(_ view: NSView) {
        contentStack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
    }

    private func configureNotes() {
        bypassLabel.font = Tokens.Font.caption
        // `secondaryLabel`, never `tertiaryLabel`: the line is live state text
        // explaining the controls beneath it, and the module rule is that a
        // dimmed label must be dimmed BY something.
        bypassLabel.textColor = Tokens.Color.secondaryLabel
        bypassLabel.lineBreakMode = .byTruncatingTail
    }

    private func configureSimpleTier() {
        configureGainSlider(bassSlider, action: #selector(bassChanged(_:)), label: "Bass")
        configureGainSlider(trebleSlider, action: #selector(trebleChanged(_:)), label: "Treble")
        for readout in [bassReadout, trebleReadout, balanceReadout] {
            readout.font = Tokens.Font.caption
            readout.textColor = Tokens.Color.secondaryLabel
            readout.alignment = .right
        }

        // Balance: `neutralValue` at centre + a centre tick is the documented
        // AppKit shape for a rest-at-centre control (docs/SPEC.md, "Balance").
        // `allowsTickMarkValuesOnly` stays OFF — the tick marks where centre
        // IS, it does not quantise the control to it.
        balanceSlider.translatesAutoresizingMaskIntoConstraints = false
        balanceSlider.minValue = DeviceEQ.balanceRange.lowerBound
        balanceSlider.maxValue = DeviceEQ.balanceRange.upperBound
        balanceSlider.numberOfTickMarks = 1
        balanceSlider.tickMarkPosition = .below
        balanceSlider.allowsTickMarkValuesOnly = false
        balanceSlider.isContinuous = true
        balanceSlider.target = self
        balanceSlider.action = #selector(balanceChanged(_:))
        balanceSlider.setAccessibilityLabel("Balance")
        balanceSlider.heightAnchor.constraint(
            equalToConstant: EQEditorView.eqDrawerControlHeight).isActive = true
        // `neutralValue` is the documented rest-point API and is exactly a
        // balance control (docs/SPEC.md), but it only exists from macOS 26 —
        // below that the centre TICK carries the same reference on its own,
        // which is why the tick is set unconditionally above.
        if #available(macOS 26.0, *) { balanceSlider.neutralValue = 0 }

        loudnessCheckbox.setButtonType(.switch)
        loudnessCheckbox.title = "Loudness"
        loudnessCheckbox.font = Tokens.Font.caption
        loudnessCheckbox.target = self
        loudnessCheckbox.action = #selector(loudnessToggled(_:))
        loudnessCheckbox.setAccessibilityLabel("Loudness")

        contentStack.addArrangedSubview(bypassLabel)
        addFullWidthRow(sliderRow(caption: bassCaption, middle: bassSlider, readout: bassReadout))
        addFullWidthRow(sliderRow(caption: trebleCaption, middle: trebleSlider, readout: trebleReadout))
        addFullWidthRow(sliderRow(caption: balanceCaption, middle: balanceMiddleView(), readout: balanceReadout))
        addFullWidthRow(loudnessRow())
    }

    private func configureGainSlider(_ slider: NSSlider, action: Selector, label: String) {
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.minValue = DeviceEQ.gainRangeDB.lowerBound
        slider.maxValue = DeviceEQ.gainRangeDB.upperBound
        slider.isContinuous = true
        slider.target = self
        slider.action = action
        slider.setAccessibilityLabel(label)
        slider.heightAnchor.constraint(
            equalToConstant: EQEditorView.eqDrawerControlHeight).isActive = true
        // Same centre-tick-and-neutral recipe Balance carries (docs/SPEC.md):
        // a bipolar gain control rests at 0 dB, and the tick names where that
        // is even below macOS 26, where `neutralValue` doesn't exist yet.
        slider.numberOfTickMarks = 1
        slider.tickMarkPosition = .below
        slider.allowsTickMarkValuesOnly = false
        if #available(macOS 26.0, *) { slider.neutralValue = 0 }
    }

    /// One simple-tier line: caption column, a middle view — usually the
    /// slider itself, but Balance wraps its (narrower) slider with L/R
    /// labels — and an optional readout column. Caption and readout are the
    /// same width/spacing on every row regardless of what the middle view
    /// is, so Balance's narrower slider still lines up caption-to-caption
    /// and readout-to-readout with Bass/Treble.
    private func sliderRow(caption: NSTextField, middle: NSView, readout: NSTextField?) -> NSView {
        caption.font = Tokens.Font.caption
        caption.textColor = Tokens.Color.secondaryLabel
        let row = NSStackView(views: readout.map { [caption, middle, $0] } ?? [caption, middle])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = EQEditorView.eqDrawerRowSpacing
        row.distribution = .fill
        caption.widthAnchor.constraint(
            equalToConstant: EQEditorView.eqDrawerCaptionWidth).isActive = true
        if let readout {
            readout.widthAnchor.constraint(
                equalToConstant: EQEditorView.eqDrawerReadoutWidth).isActive = true
        }
        return row
    }

    /// Balance's middle view: the slider flanked by "L"/"R" captions
    /// so the row reads on its own without the printed readout, which — like
    /// Bass/Treble's — only shows once a value moves off centre. Wrapping the
    /// slider here (rather than widening it to the row like Bass/Treble)
    /// is what makes it visibly narrower: the L/R labels claim some of the
    /// same middle column Bass/Treble give entirely to the slider.
    private func balanceMiddleView() -> NSView {
        let leftLabel = NSTextField(labelWithString: "L")
        let rightLabel = NSTextField(labelWithString: "R")
        for label in [leftLabel, rightLabel] {
            label.font = Tokens.Font.caption
            label.textColor = Tokens.Color.tertiaryLabel
        }
        let row = NSStackView(views: [leftLabel, balanceSlider, rightLabel])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 4
        row.distribution = .fill
        return row
    }

    private func loudnessRow() -> NSView {
        let row = NSStackView(views: [loudnessCheckbox])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = EQEditorView.eqDrawerRowSpacing
        row.distribution = .fill
        return row
    }

    /// The "Advanced" disclosure and the ten band faders behind it. The clip +
    /// zero-height constraint shape is the app's one collapse idiom (Settings'
    /// own Advanced disclosure, `AudioSettingsViewController`): the content
    /// sits in a layer-clipped container whose height==0 constraint is the
    /// single controlled value, and its bottom pin is `.defaultHigh` so the
    /// clip always wins without a conflict.
    private func configureAdvancedTier() {
        advancedDisclosure.setButtonType(.pushOnPushOff)
        advancedDisclosure.bezelStyle = .disclosure
        advancedDisclosure.title = ""
        advancedDisclosure.state = .off
        advancedDisclosure.target = self
        advancedDisclosure.action = #selector(advancedToggled(_:))

        // The title is a click target too, not just the triangle — same
        // idiom as `AudioSettingsViewController.advancedTitleTapped`.
        advancedTitle.isBordered = false
        advancedTitle.setButtonType(.momentaryChange)
        advancedTitle.attributedTitle = NSAttributedString(
            string: "Advanced",
            attributes: [.font: Tokens.Font.caption,
                         .foregroundColor: Tokens.Color.secondaryLabel])
        advancedTitle.target = self
        advancedTitle.action = #selector(advancedTitleTapped(_:))

        advancedHint.font = Tokens.Font.caption
        advancedHint.textColor = Tokens.Color.tertiaryLabel

        advancedReadout.font = Tokens.Font.caption
        advancedReadout.textColor = Tokens.Color.secondaryLabel
        advancedReadout.alignment = .right
        advancedReadout.widthAnchor.constraint(
            equalToConstant: EQEditorView.eqDrawerReadoutWidth).isActive = true

        advancedDivider.translatesAutoresizingMaskIntoConstraints = false
        advancedDivider.heightAnchor.constraint(equalToConstant: 1).isActive = true

        let headerSpacer = NSView()
        headerSpacer.translatesAutoresizingMaskIntoConstraints = false
        let header = advancedHeader
        header.translatesAutoresizingMaskIntoConstraints = false
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 4
        for view in [advancedDisclosure, advancedTitle, advancedHint, headerSpacer, advancedReadout] {
            header.addArrangedSubview(view)
        }
        header.setCustomSpacing(EQEditorView.eqDrawerRowSpacing, after: advancedTitle)

        advancedContent.translatesAutoresizingMaskIntoConstraints = false
        // The scope tops the fold, spanning the whole editor, and the ten
        // faders hang off ITS grid — see `layOutFaders(under:)`.
        advancedContent.addSubview(curve)
        NSLayoutConstraint.activate([
            curve.leadingAnchor.constraint(equalTo: advancedContent.leadingAnchor),
            curve.trailingAnchor.constraint(equalTo: advancedContent.trailingAnchor),
            curve.topAnchor.constraint(equalTo: advancedContent.topAnchor),
        ])
        layOutFaders(under: curve)

        advancedClip.translatesAutoresizingMaskIntoConstraints = false
        advancedClip.wantsLayer = true
        advancedClip.layer?.masksToBounds = true
        advancedClip.addSubview(advancedContent)
        let bottomPin = advancedContent.bottomAnchor.constraint(equalTo: advancedClip.bottomAnchor)
        bottomPin.priority = .defaultHigh
        advancedClipCollapsed = advancedClip.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            advancedContent.leadingAnchor.constraint(equalTo: advancedClip.leadingAnchor),
            advancedContent.topAnchor.constraint(equalTo: advancedClip.topAnchor),
            advancedContent.trailingAnchor.constraint(equalTo: advancedClip.trailingAnchor),
            bottomPin,
        ])
        advancedClipCollapsed.isActive = true
        advancedContent.isHidden = true

        addFullWidthRow(advancedDivider)
        addFullWidthRow(header)
        contentStack.addArrangedSubview(advancedClip)
        advancedClip.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
    }

    /// Hang the ten faders off the scope's own x-axis. Each column's centre is
    /// pinned to `EQResponseCurveView.bandCentreX(index:width:)` for its band —
    /// expressed as a MULTIPLIER on `advancedContent`'s trailing edge, which is
    /// the only way Auto Layout can state "a fraction of a width that is not
    /// known until layout":
    ///
    ///     centre = g·W + L − g·(L + T) = L + g·(W − L − T)
    ///
    /// which is exactly what `bandCentreX` computes. The columns are therefore
    /// not evenly spaced — they follow the log frequency scale the trace above
    /// them is drawn on, so 31 Hz and 63 Hz crowd the left just as their
    /// gridlines do.
    private func layOutFaders(under scope: NSView) {
        let leadingInset = EQResponseCurveView.plotLeadingInset
        let trailingInset = EQResponseCurveView.plotTrailingInset
        var constraints: [NSLayoutConstraint] = []
        for (index, title) in Self.bandTitles.enumerated() {
            let column = bandColumn(index: index, title: title)
            advancedContent.addSubview(column)
            bandColumns.append(column)
            let g = EQResponseCurveView.bandGridX[index]
            constraints.append(column.topAnchor.constraint(
                equalTo: scope.bottomAnchor, constant: Self.eqDrawerScopeToFaderGap))
            constraints.append(NSLayoutConstraint(
                item: column, attribute: .centerX, relatedBy: .equal,
                toItem: advancedContent, attribute: .trailing,
                multiplier: g, constant: leadingInset - g * (leadingInset + trailingInset)))
        }
        // ONE column defines the content's bottom — every column is the same
        // fixed height, so pinning all ten would just restate it.
        constraints.append(
            bandColumns[0].bottomAnchor.constraint(equalTo: advancedContent.bottomAnchor))

        // ONE "Hz" legend for the row, not ten repeated units — parked in the
        // scope's ruler gutter, on the band labels' baseline, so it reads as
        // the unit for the row of numbers rather than an eleventh column.
        hzLegend.translatesAutoresizingMaskIntoConstraints = false
        hzLegend.font = Tokens.Font.caption
        hzLegend.textColor = Tokens.Color.tertiaryLabel
        advancedContent.addSubview(hzLegend)
        constraints.append(hzLegend.centerXAnchor.constraint(
            equalTo: advancedContent.leadingAnchor, constant: leadingInset / 2))
        constraints.append(
            hzLegend.firstBaselineAnchor.constraint(equalTo: bandLabels[0].firstBaselineAnchor))
        NSLayoutConstraint.activate(constraints)
    }

    private func bandColumn(index: Int, title: String) -> NSView {
        let slider = NSSlider()
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.isVertical = true
        slider.minValue = DeviceEQ.gainRangeDB.lowerBound
        slider.maxValue = DeviceEQ.gainRangeDB.upperBound
        slider.isContinuous = true
        slider.tag = index
        slider.target = self
        slider.action = #selector(bandChanged(_:))
        slider.setAccessibilityLabel("\(title) hertz")
        // Same centre-tick-and-neutral recipe as Bass/Treble/Balance —
        // `.leading` rather than `.below` because a VERTICAL slider's tick
        // marks are leading/trailing, not above/below.
        slider.numberOfTickMarks = 1
        slider.tickMarkPosition = .leading
        slider.allowsTickMarkValuesOnly = false
        if #available(macOS 26.0, *) { slider.neutralValue = 0 }
        bandSliders.append(slider)

        let label = NSTextField(labelWithString: title)
        label.font = Tokens.Font.caption
        label.textColor = Tokens.Color.tertiaryLabel
        label.alignment = .center
        bandLabels.append(label)

        let column = NSStackView(views: [slider, label])
        column.translatesAutoresizingMaskIntoConstraints = false
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 2
        NSLayoutConstraint.activate([
            slider.heightAnchor.constraint(
                equalToConstant: EQEditorView.eqDrawerBandSliderHeight),
            column.widthAnchor.constraint(
                equalToConstant: EQEditorView.eqDrawerBandColumnWidth),
        ])
        return column
    }

    // MARK: Public API

    /// Push a fresh snapshot. A non-`nil` `bypassReason` mounts that reason's
    /// "not applied" sentence and hollows the curve (the stored values stay
    /// editable — the host is saying they are inaudible right now, not that
    /// they are gone).
    public func apply(eq: DeviceEQ, bypassReason: Device.EQBypassReason?) {
        self.eq = eq
        self.bypassReason = bypassReason
        refreshDisplay()
    }

    /// The tone the drawer is currently rendering — the model every spoken
    /// value and every readout below is derived from, so the two can't drift.
    public var currentEQ: DeviceEQ { eq }

    /// Put every stage back to flat, in ONE committed action. The host's
    /// Reset button (now on the "Equalizer" title line, not this view) calls
    /// this directly.
    public func resetToFlat() {
        eq = .flat
        refreshDisplay()
        delegate?.eqEditorDidRequestReset(self)
    }

    // MARK: Actions

    @objc private func bassChanged(_ sender: NSSlider) {
        let value = quantizedGain(sender.doubleValue, pointerGesture: isPointerDragFrame)
        if sender.doubleValue != value { sender.doubleValue = value }
        eq.bassDB = value
        trackPointerGesture(sender)
        report()
    }

    @objc private func trebleChanged(_ sender: NSSlider) {
        let value = quantizedGain(sender.doubleValue, pointerGesture: isPointerDragFrame)
        if sender.doubleValue != value { sender.doubleValue = value }
        eq.trebleDB = value
        trackPointerGesture(sender)
        report()
    }

    @objc private func balanceChanged(_ sender: NSSlider) {
        let value = quantizedBalance(sender.doubleValue, pointerGesture: isPointerDragFrame)
        if sender.doubleValue != value { sender.doubleValue = value }
        eq.balance = value
        trackPointerGesture(sender)
        report()
    }

    @objc private func bandChanged(_ sender: NSSlider) {
        guard sender.tag >= 0, sender.tag < eq.bandGainsDB.count else { return }
        let value = quantizedGain(sender.doubleValue, pointerGesture: isPointerDragFrame)
        if sender.doubleValue != value { sender.doubleValue = value }
        eq.bandGainsDB[sender.tag] = value
        trackPointerGesture(sender)
        report()
    }

    /// The magnetic detent radius: a pointer gesture (never a keyboard/
    /// VoiceOver step) whose raw dB reading lands within this of 0 snaps
    /// exactly onto it.
    private static let gainDetentRangeDB: Double = 0.6
    /// Same recipe for Balance's [-1, 1] range.
    private static let balanceDetentRange: Double = 0.06

    /// Quantizes a bipolar gain slider's raw reading to the nearest half dB,
    /// and — only while a pointer gesture is dragging it — snaps a value
    /// close to 0 dB exactly onto it (the "magnetic detent"). Hard-quantizing
    /// the whole travel via `allowsTickMarkValuesOnly` was rejected: it would
    /// make a deliberate near-zero value unreachable. Keyboard/VoiceOver steps
    /// get the quantization only — a discrete step is already a deliberate
    /// choice, and pulling it toward 0 would fight it.
    private func quantizedGain(_ raw: Double, pointerGesture: Bool) -> Double {
        let detented = (pointerGesture && abs(raw) <= Self.gainDetentRangeDB) ? 0 : raw
        return (detented * 2).rounded() / 2
    }

    /// Same recipe as ``quantizedGain(_:pointerGesture:)`` for Balance: 0.05
    /// steps, ±0.06 magnetic centre.
    private func quantizedBalance(_ raw: Double, pointerGesture: Bool) -> Double {
        let detented = (pointerGesture && abs(raw) <= Self.balanceDetentRange) ? 0 : raw
        return (detented * 20).rounded() / 20
    }

    /// Remember whether `sender` is the slider AppKit's drag loop is currently
    /// tracking, so ``refreshDisplay`` can skip writing it. Set on a drag frame
    /// (`.leftMouseDown`/`.leftMouseDragged` — the same pair ``gestureIsComplete``
    /// treats as "not yet committed"), cleared on any other triggering event
    /// (mouse-up, a keyboard/VoiceOver step) since the gesture is then over.
    private func trackPointerGesture(_ sender: NSSlider) {
        pointerTrackedSlider = isPointerDragFrame ? sender : nil
    }

    /// True when the event that triggered the current action is a pointer-drag
    /// frame. `nil` override reads the live event, mirroring
    /// ``test_committedGestureOverride`` — a headless action carries no
    /// `NSApp.currentEvent`.
    private var isPointerDragFrame: Bool {
        if let override = test_pointerGestureOverride { return override }
        switch NSApp?.currentEvent?.type {
        case .leftMouseDown, .leftMouseDragged: return true
        default: return false
        }
    }

    @objc private func loudnessToggled(_ sender: NSButton) {
        eq.loudness = sender.state == .on
        // A checkbox click is a complete gesture, never a scrub.
        refreshDisplay()
        delegate?.eqEditor(self, didChange: eq, committed: true)
    }

    @objc private func advancedToggled(_ sender: NSButton) {
        let expanded = sender.state == .on
        settings.eqAdvancedExpanded = expanded
        setAdvancedExpanded(expanded,
                             animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                                 && !HeadlessRuntime.isActive)
    }

    /// Clicking the word "Advanced" mirrors the triangle exactly — same idiom
    /// as `AudioSettingsViewController.advancedTitleTapped`.
    @objc private func advancedTitleTapped(_ sender: NSButton) {
        advancedDisclosure.state = advancedDisclosure.state == .on ? .off : .on
        advancedToggled(advancedDisclosure)
    }

    /// Report the freshest value out, splitting a live drag from the gesture
    /// that ends it. Every slider's own min/max is ``DeviceEQ``'s range, so a
    /// value read off one is already inside it — and the type clamps again on
    /// its way through the backend regardless.
    private func report() {
        refreshDisplay()
        delegate?.eqEditor(self, didChange: eq, committed: gestureIsComplete)
    }

    /// True when the change that just fired is a COMPLETE gesture rather than
    /// a frame of a drag. A continuous `NSSlider` fires on mouse-down, on
    /// every drag frame and once more on mouse-up; only the last of those may
    /// persist. A keyboard/VoiceOver step arrives as a single event that is
    /// none of the drag types, and correctly commits.
    private var gestureIsComplete: Bool {
        if let override = test_committedGestureOverride { return override }
        switch NSApp?.currentEvent?.type {
        case .leftMouseDown, .leftMouseDragged: return false
        default: return true
        }
    }

    // MARK: Rendering

    /// Write `value` into `slider` unless (a) it is already showing it, or (b)
    /// AppKit's own drag loop is mid-track on it — both of those are the write
    /// guards that keep a queued, now-stale snapshot from yanking the knob.
    private func writeSliderIfNeeded(_ slider: NSSlider, value: Double) {
        guard slider !== pointerTrackedSlider, slider.doubleValue != value else { return }
        slider.doubleValue = value
    }

    private func refreshDisplay() {
        if let bypassReason { bypassLabel.stringValue = Self.bypassNoteText(bypassReason) }
        bypassLabel.isHidden = bypassReason == nil
        // The scope reads the SAME model every slider below it renders, so the
        // picture and the controls can never disagree.
        curve.apply(eq: eq, bypassed: bypassReason != nil)

        writeSliderIfNeeded(bassSlider, value: eq.bassDB)
        writeSliderIfNeeded(trebleSlider, value: eq.trebleDB)
        writeSliderIfNeeded(balanceSlider, value: eq.balance)
        loudnessCheckbox.state = eq.loudness ? .on : .off
        for (index, slider) in bandSliders.enumerated() where index < eq.bandGainsDB.count {
            writeSliderIfNeeded(slider, value: eq.bandGainsDB[index])
        }

        bassReadout.stringValue = Self.gainText(eq.bassDB)
        trebleReadout.stringValue = Self.gainText(eq.trebleDB)
        balanceReadout.stringValue = Self.balanceReadoutText(eq.balance)

        // Every spoken value derives from the SAME model the sliders render,
        // so VoiceOver and the pixels can never disagree.
        bassSlider.setAccessibilityValue(Self.gainText(eq.bassDB))
        trebleSlider.setAccessibilityValue(Self.gainText(eq.trebleDB))
        balanceSlider.setAccessibilityValue(Self.balanceText(eq.balance))
        loudnessCheckbox.setAccessibilityValue(eq.loudness ? "on" : "off")
        for (index, slider) in bandSliders.enumerated() where index < eq.bandGainsDB.count {
            slider.setAccessibilityValue(Self.gainText(eq.bandGainsDB[index]))
        }

        refreshAdvancedRow()
    }

    /// The Advanced row's readout ("N set") and its composed spoken label.
    /// The readout counts non-zero bands — a shaped band is the one thing the
    /// fold's collapsed row can say about content the user can't currently
    /// see.
    private func refreshAdvancedRow() {
        let shaped = eq.bandGainsDB.filter { $0 != 0 }.count
        advancedReadout.stringValue = shaped == 0 ? "" : "\(shaped) set"

        var spoken = "Advanced, \(DeviceEQ.bandCount) bands"
        if shaped > 0 { spoken += ", \(shaped) set" }
        spoken += advancedExpanded ? ", expanded" : ", collapsed"
        advancedDisclosure.setAccessibilityLabel(spoken)
        advancedTitle.setAccessibilityLabel(spoken)
    }

    /// Bare number plus the unit — no locale-specific preset wording, and a
    /// typographic MINUS so a negative value keeps the digit's own width.
    /// Rounds to one decimal and prints exactly that: a whole value prints
    /// "3 dB", a half prints "3.5 dB" — every stored gain is a half-dB step,
    /// so nothing here needs more precision than that.
    static func gainText(_ db: Double) -> String {
        let tenths = (db * 10).rounded()
        let magnitude = abs(Int(tenths))
        let whole = magnitude / 10
        let fraction = magnitude % 10
        let numberText = fraction == 0 ? "\(whole)" : "\(whole).\(fraction)"
        return "\(tenths < 0 ? "−" : "")\(numberText) dB"
    }

    /// The Balance readout: "Center" at rest, otherwise "L 30%" / "R 20%" —
    /// printed alongside the slider in the same readout column Bass/Treble use.
    static func balanceReadoutText(_ balance: Double) -> String {
        let percent = Int((abs(balance) * 100).rounded())
        if percent == 0 { return "Center" }
        return balance < 0 ? "L \(percent)%" : "R \(percent)%"
    }

    /// The spoken (accessibility-value) form — a full sentence rather than
    /// the printed readout's short form. The digits go through `VolumePercent`
    /// so a screen reader hears the listener's own grouping, not a raw
    /// interpolation.
    static func balanceText(_ balance: Double) -> String {
        let percent = Int((abs(balance) * 100).rounded())
        if percent == 0 { return "center" }
        let spoken = VolumePercent.spoken(percent)
        return balance < 0 ? "left \(spoken)" : "right \(spoken)"
    }

    // MARK: The Advanced fold (Settings-Advanced precedent, one clock)

    /// Same choreography as `AudioSettingsViewController.setAdvancedExpanded`:
    /// the clip height is the single animated value on ``FoldAnimator``'s
    /// clock. No follower — the editor's pane SCROLLS rather than growing its
    /// window (roadmap 039), so nothing above it has to re-lay itself out per
    /// tick. Instant under Reduce Motion AND headless — the driver ticks off
    /// the main runloop, which `swift test` and the harness tools don't
    /// reliably spin, so a deferred terminal state would be stranded.
    private func setAdvancedExpanded(_ expanded: Bool, animated: Bool) {
        advancedExpanded = expanded
        refreshAdvancedRow()
        if expanded {
            advancedContent.isHidden = false
            guard animated else {
                advancedClipCollapsed.isActive = false
                return
            }
            advancedContent.layoutSubtreeIfNeeded()
            let target = advancedContent.fittingSize.height
            advancedClipCollapsed.isActive = true
            FoldAnimator.shared.animate(advancedClipCollapsed, to: target,
                                        follower: nil) { [weak self] in
                self?.advancedClipCollapsed.isActive = false
            }
        } else {
            guard animated else {
                advancedClipCollapsed.constant = 0
                advancedClipCollapsed.isActive = true
                advancedContent.isHidden = true
                return
            }
            if !advancedClipCollapsed.isActive {
                advancedClipCollapsed.constant = advancedClip.frame.height
                advancedClipCollapsed.isActive = true
                layoutSubtreeIfNeeded()
            }
            FoldAnimator.shared.animate(advancedClipCollapsed, to: 0,
                                        follower: nil) { [weak self] in
                self?.advancedContent.isHidden = true
            }
        }
    }

    // MARK: Test hooks — real target/action dispatch, nothing presented

    /// Forces the live-scrub / committed verdict a real `NSEvent` would
    /// supply. `nil` = read the live event (the production path). Mirrors
    /// ``BTSyncDrawerView/test_shiftModifierOverride``: a headless action
    /// carries no `NSApp.currentEvent`, and in a narrowly filtered
    /// `swift test` run `NSApp` itself can be nil.
    public var test_committedGestureOverride: Bool?

    /// Forces the pointer-drag-frame verdict ``isPointerDragFrame`` would
    /// otherwise read off the live event. `nil` = read the live event.
    /// Mirrors ``test_committedGestureOverride`` for the same reason: a
    /// headless action carries no `NSApp.currentEvent`.
    public var test_pointerGestureOverride: Bool?

    public var test_bypassNoteShown: Bool { !bypassLabel.isHidden }
    public var test_bypassNoteText: String { bypassLabel.stringValue }
    public var test_curve: EQResponseCurveView { curve }
    public var test_bassReadout: String { bassReadout.stringValue }
    public var test_trebleReadout: String { trebleReadout.stringValue }
    public var test_balanceReadout: String { balanceReadout.stringValue }
    public var test_loudnessOn: Bool { loudnessCheckbox.state == .on }
    public var test_advancedExpanded: Bool { advancedExpanded }
    public var test_bandTitles: [String] { Self.bandTitles }
    public var test_balanceHasCentreTick: Bool {
        balanceSlider.numberOfTickMarks == 1 && !balanceSlider.allowsTickMarkValuesOnly
    }
    public var test_bassHasCentreTick: Bool {
        bassSlider.numberOfTickMarks == 1 && !bassSlider.allowsTickMarkValuesOnly
    }
    public var test_trebleHasCentreTick: Bool {
        trebleSlider.numberOfTickMarks == 1 && !trebleSlider.allowsTickMarkValuesOnly
    }
    public func test_bandHasCentreTick(_ index: Int) -> Bool {
        guard index >= 0, index < bandSliders.count else { return false }
        let slider = bandSliders[index]
        return slider.numberOfTickMarks == 1 && !slider.allowsTickMarkValuesOnly
    }
    public var test_bassAXValue: String? { bassSlider.accessibilityValue() as? String }
    public var test_balanceAXValue: String? { balanceSlider.accessibilityValue() as? String }

    // Frames for the layout assertions (relative comparisons only — never an
    // absolute width, per the Groups-pane rounding-grid trap). Every one is in
    // the EDITOR's own coordinates, so a control in one row can be compared
    // with a control in another without assuming where the rows start.
    // The ALIGNMENT rect, not the raw frame: an `NSTextField` label's frame
    // overhangs its text box by ~2 pt on every side, so raw frames make a label
    // and a button that Auto Layout has aligned perfectly read as 2 pt apart.
    private func frameInEditor(_ view: NSView) -> NSRect {
        convert(view.alignmentRect(forFrame: view.bounds), from: view)
    }
    public var test_bassCaptionFrame: NSRect { frameInEditor(bassCaption) }
    public var test_balanceCaptionFrame: NSRect { frameInEditor(balanceCaption) }
    public var test_bassReadoutFrame: NSRect { frameInEditor(bassReadout) }
    public var test_balanceReadoutFrame: NSRect { frameInEditor(balanceReadout) }
    public var test_bassSliderFrame: NSRect { frameInEditor(bassSlider) }
    public var test_balanceSliderFrame: NSRect { frameInEditor(balanceSlider) }
    public var test_loudnessCheckboxFrame: NSRect { frameInEditor(loudnessCheckbox) }
    public var test_advancedDividerFrame: NSRect { frameInEditor(advancedDivider) }
    public var test_advancedRowFrame: NSRect { frameInEditor(advancedHeader) }
    public var test_advancedReadoutFrame: NSRect { frameInEditor(advancedReadout) }

    // Everything inside the fold reads `nil` while it is closed — the resting
    // card genuinely has no scope on it, and a frame from a hidden view would
    // let a test claim otherwise.
    public var test_curveFrame: NSRect? {
        advancedContent.isHidden ? nil : frameInEditor(curve)
    }
    public var test_hzLegendFrame: NSRect? {
        advancedContent.isHidden ? nil : frameInEditor(hzLegend)
    }
    public func test_bandColumnCenterX(_ index: Int) -> CGFloat? {
        guard !advancedContent.isHidden, bandColumns.indices.contains(index) else { return nil }
        return frameInEditor(bandColumns[index]).midX
    }
    public func test_bandSliderFrame(_ index: Int) -> NSRect? {
        guard !advancedContent.isHidden, bandSliders.indices.contains(index) else { return nil }
        return frameInEditor(bandSliders[index])
    }

    public var test_advancedReadoutText: String { advancedReadout.stringValue }
    public var test_advancedHintText: String { advancedHint.stringValue }
    public var test_advancedAXLabel: String? { advancedDisclosure.accessibilityLabel() }

    /// Drive one slider through its REAL target/action, exactly as a live drag
    /// does (a gesture cannot be synthesized headlessly).
    public func test_dragBass(to db: Double) { fire(bassSlider, value: db) }
    public func test_dragTreble(to db: Double) { fire(trebleSlider, value: db) }
    public func test_dragBalance(to value: Double) { fire(balanceSlider, value: value) }
    public func test_dragBand(_ index: Int, to db: Double) {
        guard index >= 0, index < bandSliders.count else { return }
        fire(bandSliders[index], value: db)
    }

    public func test_fireLoudnessClick() { loudnessCheckbox.performClick(nil) }
    public func test_fireAdvancedClick() { advancedDisclosure.performClick(nil) }
    public func test_fireAdvancedTitleClick() { advancedTitle.performClick(nil) }

    private func fire(_ slider: NSSlider, value: Double) {
        slider.doubleValue = value
        guard let action = slider.action, let target = slider.target as? NSObject else { return }
        _ = target.perform(action, with: slider)
    }
}

/// A one-token divider above the Advanced row. The editor sits in a `raised`
/// card (`GroupedSectionView`), and `hairline` is never drawn on `raised`
/// (1.154:1 dark) — `containerEdge` measures 1.55:1 dark / 2.02:1 light there.
/// `draw(_:)`-based rather than a frozen layer color so the token re-resolves
/// per appearance and Increase Contrast on every paint.
/// Non-interactive — pure chrome, never an `NSBox` (`test_hasBoxDivider`).
private final class ContainerEdgeView: NSView {

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        Tokens.Color.containerEdge.setFill()
        bounds.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
