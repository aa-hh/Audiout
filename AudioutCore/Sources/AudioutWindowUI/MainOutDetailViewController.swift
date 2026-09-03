// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore
import AudioutSharedUI

/// The **Main Audio** page: the whole mix, described and tuned. Shown in the
/// Groups screen's detail area when the sidebar's "System Audio" row is
/// selected, and the destination the popover's Main Audio row deep-links to.
///
/// It is the device detail pane's sibling, not a variant of it: the two share
/// the geometry (``GroupsPaneLayout``, asserted by `GroupsHeaderParityTests`)
/// and the editor, and nothing else. This page fronts no `Device` — there is
/// no status, no volume, no membership to show — so it is the shortest form of
/// the one housing: a BARE identity band, an "Equalizer" title over the page's
/// ONE card, and a caption under that card saying where the tone lands. The
/// caption binds to the card with the same 6 pt (`labelToSectionGap`) that
/// binds the title to it — it belongs to the card, not to the pane.
///
/// Two deliberate differences from the device pane:
/// - the icon well is NOT editable (`isEditable = false`, so no pencil badge,
///   no hover, no keyboard press). Nobody chooses a glyph for the whole mix,
///   and the module's edit-affordance vocabulary (`AGENTS.md`) says a control
///   that cannot be edited must not wear the cue;
/// - the tone reported out carries no device id (``onSetEQ``) — it is the
///   whole-mix seam, `OutputBackend.setMainOutEQ`, not a per-device one.
///
/// Like the device pane it SCROLLS: the Equalizer's Advanced fold exceeds the
/// Groups screen's height budget, and the surface frame is FIXED for every
/// screen (`AppSurfaceController` — the frame never changes), so scrolling is
/// the only room; growing the window was rejected (roadmap 039).
public final class MainOutDetailViewController: NSViewController {

    /// Where this page's tone actually lands. Plain words, and deliberately
    /// not "system audio" or "the mix": what the user changes here is what
    /// leaves for the speakers.
    public static let noteText = "Applies to audio sent to speakers."

    /// The page's title — the same words the sidebar row carries.
    private static let title = "Main Audio"

    private let iconWell = DeviceIconWellView()
    private let nameLabel = NSTextField(labelWithString: MainOutDetailViewController.title)
    private let headerWell = GroupedSectionView()
    private let eqWell = GroupedSectionView()
    /// Titles the page's one card, the same idiom (and geometry) as the device
    /// pane's "Equalizer" label above its own.
    private let eqTitleLabel = NSTextField(labelWithString: "Equalizer")
    /// The Equalizer card's Reset button, on the title line beside
    /// `eqTitleLabel` — same idiom as `DeviceDetailViewController`.
    private let eqResetButton = NSButton()
    private let eqEditor: EQEditorView
    private let noteLabel = NSTextField(
        wrappingLabelWithString: MainOutDetailViewController.noteText)

    private var scrollView: NSScrollView?

    /// Report a whole-mix tone change: the new EQ and whether the gesture is
    /// finished (`false` = live scrub, apply only; `true` = apply AND
    /// persist). No device id — this seam is the mix itself.
    public var onSetEQ: ((DeviceEQ, Bool) -> Void)?

    /// The EQ this page has SENT while a gesture is IN FLIGHT, and whether
    /// that send was the COMMIT (`awaitingEcho`) — same cache/release rule as
    /// `DeviceDetailViewController.eqEdits`, minus the per-device keying (this
    /// page fronts exactly one seam, the whole mix). Released only once a
    /// LATER `show(eq:)` snapshot actually matches the committed value; a
    /// synchronous release at commit would let an already-queued stale
    /// snapshot land right after and replay the drag on the knob.
    private var pendingEdit: (eq: DeviceEQ, awaitingEcho: Bool)?

    public init(settings: AppSettings = AppSettings()) {
        self.eqEditor = EQEditorView(settings: settings)
        super.init(nibName: nil, bundle: nil)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func loadView() {
        iconWell.translatesAutoresizingMaskIntoConstraints = false
        iconWell.widthAnchor.constraint(equalToConstant: DeviceIconWellView.size).isActive = true
        iconWell.heightAnchor.constraint(equalToConstant: DeviceIconWellView.size).isActive = true
        // A picture, not a button: no badge, no hover, no press. Set BEFORE
        // the label, since the well's accessibility role changes with it.
        iconWell.isEditable = false
        iconWell.setAccessibilityLabel(Self.title)
        let image = NSImage(systemSymbolName: DeviceIcon.mainAudioSymbolName,
                            accessibilityDescription: Self.title)
        image?.isTemplate = true
        iconWell.iconImageView.image = image
        iconWell.iconImageView.contentTintColor = Tokens.Color.label

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = Tokens.Font.heading
        nameLabel.alignment = .natural
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        eqEditor.translatesAutoresizingMaskIntoConstraints = false
        eqEditor.delegate = self

        noteLabel.translatesAutoresizingMaskIntoConstraints = false
        noteLabel.font = Tokens.Font.caption
        noteLabel.textColor = Tokens.Color.secondaryLabel
        noteLabel.isSelectable = false
        // Wraps inside the CONTENT lane it now sits in, not across the whole
        // column — the caption is the card's, so it starts where the card's
        // content does.
        noteLabel.preferredMaxLayoutWidth = GroupsPaneLayout.contentMaxWidth
            - GroupsPaneLayout.railFreeContentLeadingInset
            - GroupsPaneLayout.contentTrailingInset
        // Yields before the pane does — a caption never widens the screen.
        noteLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let container = NSView()
        let column = NSView()
        column.translatesAutoresizingMaskIntoConstraints = false

        // The header keeps the full spine-gutter inset so its icon + name stay
        // pinned to the other two panes'; the Equalizer below it takes the
        // rail-free inset, like the device pane's sections.
        headerWell.contentLeadingInset = GroupsPaneLayout.contentLeadingInset
        eqWell.contentLeadingInset = GroupsPaneLayout.railFreeContentLeadingInset
        // Identity is bare; the Equalizer is this page's one card.
        headerWell.style = .bare

        eqTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        eqTitleLabel.font = Tokens.Font.body
        eqTitleLabel.textColor = Tokens.Color.secondaryLabel

        eqResetButton.translatesAutoresizingMaskIntoConstraints = false
        eqResetButton.bezelStyle = .rounded
        eqResetButton.controlSize = .small
        eqResetButton.font = Tokens.Font.caption
        eqResetButton.title = "Reset"
        eqResetButton.target = self
        eqResetButton.action = #selector(resetTapped(_:))
        eqResetButton.setAccessibilityLabel("Reset tone to flat")

        for well in [headerWell, eqWell] {
            well.translatesAutoresizingMaskIntoConstraints = false
            column.addSubview(well)
        }
        for v in [iconWell, nameLabel, eqTitleLabel, eqResetButton, eqEditor, noteLabel] { column.addSubview(v) }

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(column)

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = document
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        container.addSubview(scrollView)
        self.scrollView = scrollView

        let columnFill = column.trailingAnchor.constraint(
            equalTo: document.trailingAnchor, constant: -GroupsPaneLayout.columnTrailingInset)
        columnFill.priority = .defaultHigh

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            document.widthAnchor.constraint(equalTo: scrollView.widthAnchor),

            column.topAnchor.constraint(equalTo: document.topAnchor,
                                        constant: GroupsPaneLayout.columnTopInset),
            column.bottomAnchor.constraint(equalTo: document.bottomAnchor,
                                           constant: -GroupsPaneLayout.paneBottomInset),
            column.leadingAnchor.constraint(equalTo: document.leadingAnchor,
                                            constant: GroupsPaneLayout.columnInset),
            column.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor,
                                             constant: -GroupsPaneLayout.columnTrailingInset),
            column.widthAnchor.constraint(lessThanOrEqualToConstant: GroupsPaneLayout.contentMaxWidth),
            columnFill,

            // HEADER PARITY, geometric: the same five constraints the device
            // pane and the group editor use, off the same enum, so switching
            // sidebar selection never shifts the icon or the title.
            headerWell.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            headerWell.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            headerWell.topAnchor.constraint(equalTo: column.topAnchor),
            headerWell.bottomAnchor.constraint(equalTo: iconWell.bottomAnchor,
                                               constant: GroupsPaneLayout.headerPadding),

            iconWell.topAnchor.constraint(equalTo: column.topAnchor,
                                          constant: GroupsPaneLayout.headerPadding),
            iconWell.leadingAnchor.constraint(equalTo: column.leadingAnchor,
                                              constant: GroupsPaneLayout.contentLeadingInset),

            nameLabel.leadingAnchor.constraint(equalTo: iconWell.trailingAnchor,
                                               constant: GroupsPaneLayout.iconToTitleGap),
            nameLabel.centerYAnchor.constraint(equalTo: iconWell.centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: headerWell.trailingAnchor,
                                                constant: -GroupsPaneLayout.contentTrailingInset),

            // "Equalizer" on bare pane above its card — a label is never a
            // section (the device pane's identical break).
            eqTitleLabel.topAnchor.constraint(equalTo: headerWell.bottomAnchor,
                                              constant: GroupsPaneLayout.sectionGap),
            eqTitleLabel.leadingAnchor.constraint(
                equalTo: column.leadingAnchor,
                constant: GroupsPaneLayout.railFreeContentLeadingInset),

            // Reset sits on the SAME title line, trailing-aligned to the
            // card's content edge (the same edge `eqEditor` itself trails to).
            eqResetButton.trailingAnchor.constraint(
                equalTo: column.trailingAnchor, constant: -GroupsPaneLayout.contentTrailingInset),
            eqResetButton.centerYAnchor.constraint(equalTo: eqTitleLabel.centerYAnchor),

            // The editor is an INSTRUMENT (tone controls and, behind Advanced,
            // a scope), not a list of text rows, so it earns
            // `cardContentInset` rather than the narrower `verticalPadding` a
            // bare row list would use.
            eqEditor.topAnchor.constraint(
                equalTo: eqTitleLabel.bottomAnchor,
                constant: GroupsPaneLayout.labelToSectionGap + GroupsPaneLayout.cardContentInset),
            eqEditor.leadingAnchor.constraint(
                equalTo: column.leadingAnchor,
                constant: GroupsPaneLayout.railFreeContentLeadingInset),
            eqEditor.trailingAnchor.constraint(
                equalTo: column.trailingAnchor, constant: -GroupsPaneLayout.contentTrailingInset),

            eqWell.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            eqWell.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            eqWell.topAnchor.constraint(equalTo: eqEditor.topAnchor,
                                        constant: -GroupsPaneLayout.cardContentInset),
            eqWell.bottomAnchor.constraint(equalTo: eqEditor.bottomAnchor,
                                           constant: GroupsPaneLayout.cardContentInset),

            // The caption belongs to the card above it, so it binds with the
            // SAME 6 pt that binds the title to it, and starts on the card's
            // own content lane rather than spanning the column.
            noteLabel.topAnchor.constraint(equalTo: eqWell.bottomAnchor,
                                           constant: GroupsPaneLayout.labelToSectionGap),
            noteLabel.leadingAnchor.constraint(
                equalTo: column.leadingAnchor,
                constant: GroupsPaneLayout.railFreeContentLeadingInset),
            noteLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: column.trailingAnchor,
                constant: -GroupsPaneLayout.contentTrailingInset),
            noteLabel.bottomAnchor.constraint(equalTo: column.bottomAnchor),
        ])

        view = container
    }

    // MARK: Model

    /// Render the whole mix's current tone. Never bypassed: the two
    /// `Device.EQBypassReason`s are both per-device conditions (a stream-budget
    /// eviction, a per-app route), and the main-out stage sits before either.
    public func show(eq: DeviceEQ) {
        // A scrub (or a just-committed value still awaiting its echo) wins
        // over the snapshot — see ``pendingEdit``. Released here, the instant
        // a snapshot actually matches it.
        if let pending = pendingEdit, pending.awaitingEcho, eq == pending.eq {
            pendingEdit = nil
        }
        eqEditor.apply(eq: pendingEdit?.eq ?? eq, bypassReason: nil)
        refreshResetEnabled()
    }

    @objc private func resetTapped(_ sender: NSButton) {
        eqEditor.resetToFlat()
    }

    /// The editor's own rendered model IS the source of truth here — it
    /// already received `pendingEdit?.eq ?? eq`.
    private func refreshResetEnabled() {
        eqResetButton.isEnabled = !eqEditor.currentEQ.isFlat
    }

    // MARK: Test-support hooks

    /// The Equalizer section's editor — the host contract for every tone
    /// assertion on this page.
    public var test_eqEditor: EQEditorView { eqEditor }

    /// The footnote's visible text.
    public var test_noteText: String { noteLabel.stringValue }

    /// The card's title text — the same word the device pane's card carries.
    public var test_eqSectionTitleText: String { eqTitleLabel.stringValue }

    /// The page title's visible text.
    public var test_titleText: String { nameLabel.stringValue }

    /// False — the whole-mix well wears no edit cue.
    public var test_iconWellIsEditable: Bool { iconWell.isEditable }

    /// HEADER PARITY hooks — identical bodies to the device pane's, so
    /// `GroupsHeaderParityTests` can compare the two panes' real frames.

    public var test_headerIconFrame: NSRect {
        view.layoutSubtreeIfNeeded()
        return iconWell.convert(iconWell.bounds, to: view)
    }

    public var test_headerTitleAlignmentFrame: NSRect {
        view.layoutSubtreeIfNeeded()
        return nameLabel.alignmentRect(forFrame: nameLabel.convert(nameLabel.bounds, to: view))
    }

    public var test_headerSectionFrame: NSRect {
        view.layoutSubtreeIfNeeded()
        return headerWell.convert(headerWell.bounds, to: view)
    }

    /// The Equalizer EDITOR's own laid-out frame, in the page's own
    /// coordinates — mirrors `DeviceDetailViewController.test_eqEditorFrame`.
    public var test_eqEditorFrame: NSRect {
        view.layoutSubtreeIfNeeded()
        return eqEditor.convert(eqEditor.bounds, to: view)
    }

    /// The Equalizer title's ALIGNMENT rect — mirrors
    /// `DeviceDetailViewController.test_eqSectionTitleAlignmentFrame`.
    public var test_eqSectionTitleAlignmentFrame: NSRect {
        view.layoutSubtreeIfNeeded()
        return eqTitleLabel.alignmentRect(forFrame: eqTitleLabel.convert(eqTitleLabel.bounds, to: view))
    }

    public func test_fireResetClick() { eqResetButton.performClick(nil) }
    public var test_resetEnabled: Bool { eqResetButton.isEnabled }
    public var test_eqResetButtonFrame: NSRect {
        view.layoutSubtreeIfNeeded()
        return eqResetButton.convert(eqResetButton.bounds, to: view)
    }
}

// MARK: - EQEditorViewDelegate

/// Tone gestures leave the page immediately: it keeps only the value it just
/// sent (``pendingEdit``, so a snapshot mid-scrub — or a stale one still in
/// flight right after a commit — can't rewind the slider) and hands
/// everything else to the app through ``onSetEQ``. No backend, no store.
extension MainOutDetailViewController: EQEditorViewDelegate {

    public func eqEditor(_ editor: EQEditorView, didChange eq: DeviceEQ, committed: Bool) {
        // Set BEFORE forwarding: `onSetEQ` can fan a snapshot straight back,
        // and until it matches this exact value the snapshot must not win.
        pendingEdit = (eq, committed)
        onSetEQ?(eq, committed)
        refreshResetEnabled()
        if committed { Analytics.capture("eq:adjusted", ["target": "main_out"]) }
    }

    public func eqEditorDidRequestReset(_ editor: EQEditorView) {
        // One committed action; the editor has already flattened its controls.
        pendingEdit = (.flat, true)
        onSetEQ?(.flat, true)
        refreshResetEnabled()
        Analytics.capture("eq:reset", ["target": "main_out"])
    }
}

/// A flipped document view so the page scrolls from the TOP rather than
/// bottom-gravitating with dead space above the header. File-scoped on purpose.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
