// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore
import AudioutSharedUI

/// The speaker page (CONFIGURATION-ONLY — `../../AGENTS.md`): shown in the
/// detail area when the sidebar selects a speaker. It DESCRIBES the speaker
/// and TUNES it — it renders a `Device` snapshot plus which saved scenes it
/// belongs to, and hosts that speaker's ``EQEditorView``. It never activates a
/// scene, changes routing, or moves audio; a tone change is reported straight
/// out through ``onSetEQ`` for the app to apply.
///
/// Top to bottom in an ELASTIC form column off the same ``GroupsPaneLayout``
/// numbers `GroupEditorViewController` reads:
///
/// - IDENTITY — the (``DeviceIconWellView/size``pt) icon and the speaker's
///   name side by side in a BARE band, with one caption line under the name:
///   kind and status ("Sonos · Ready"), "This Mac", or the failure glyph and
///   "Can’t be found" for a remembered speaker the Mac cannot see. The icon
///   resolves through an injected `DeviceIconController` + `Device.Kind
///   .symbolName` fallback, and clicking the well presents
///   `IconPickerViewController` as an anchored popover. The name is a PLAIN
///   label — a device's name is not renameable;
/// - "Equalizer" — a title row (label, the engaged mark and a summary when the
///   tone is shaped, Reset when there is something to reset), then the page's
///   ONE INSTRUMENT in a ``GroupedSectionView/Style/well``. Hidden whole for
///   This Mac (the audio's SOURCE has no send to tune). A speaker the Mac
///   cannot find keeps the title row with its stored tone's summary, a "kept"
///   note and a Forget button instead of the editor;
/// - "Volume" — the Bluetooth-only hardware-volume slot;
/// - an outlined list (``ListRowView`` rows over a `.card`): "Show in Mixer"
///   with the visibility pop-up and one sentence of effect, then "Scenes" with
///   one link per saved scene this speaker belongs to. A link NAVIGATES: it
///   reports out through ``onSelectGroup`` and the host opens that scene's
///   editor. Selecting is NOT activating. "Password" ("Saved" and a Forget
///   button) joins them only while the backend has a password on file.
///
/// The whole column SCROLLS (`../AGENTS.md`): the Equalizer's Advanced fold
/// exceeds the screen's height budget, and the surface frame is FIXED for
/// every screen (`AppSurfaceController` — the frame never changes), so
/// scrolling is the only room; growing the window was rejected (roadmap 039).
///
/// No volume slider, no mute, no Selected-Devices toggle, no scene activation
/// control of any kind lives here — that's the Mixer's job, not this page's;
/// the Equalizer is configuration, not playback.
public final class DeviceDetailViewController: NSViewController {

    private let groupController: GroupController

    /// Resolves/persists the icon override for the shown device. Optional and
    /// nil-tolerant (`../../AGENTS.md`'s "depends on the model, never the
    /// reverse") — without one the icon well still renders the kind default,
    /// it just can't be changed (the edit affordance still shows on hover;
    /// picking always no-ops without a controller to write through).
    public var deviceIconController: DeviceIconController?

    /// Reads/writes the per-speaker "Control speaker volume" opt-out. Optional
    /// and nil-tolerant, like ``deviceIconController``: without one there is
    /// nothing to read the checkbox's state from and nothing to write it to,
    /// so the whole slot stays hidden rather than showing a dead toggle.
    public var btHardwareVolumeStore: BTHardwareVolumeStore?

    private let iconWell = DeviceIconWellView()
    private let nameLabel = NSTextField(labelWithString: "")
    /// The one caption line under the name: kind and status.
    private let subtitleLabel = NSTextField(labelWithString: "")
    /// The failure glyph leading the caption of a speaker that can't be found.
    private let subtitleGlyph = NSImageView()
    private let subtitleStack = NSStackView()
    /// The identity BAND — `.bare`, so it draws nothing at all. Kept as a
    /// section purely for its GEOMETRY, which `GroupsHeaderParityTests` pins
    /// to the group editor's header band point for point.
    private let headerWell = GroupedSectionView()
    /// The page's ONE instrument, wrapping the shared editor — a `.well`
    /// (recessed), not a `.card`, so it still reads sunk where `raised`
    /// flattens to the pane's own ground in light (2026-09-04).
    private let eqWell = GroupedSectionView()
    private let eqEditor: EQEditorView
    /// The Equalizer title row: the label, the engaged mark and the summary.
    /// Reset sits on the same line, trailing-aligned on the content edge.
    private let eqTitleRow = NSStackView()
    private let eqTitleLabel = NSTextField(labelWithString: "Equalizer")
    private let eqMarkView = EqualizerMarkView()
    private let eqSummaryLabel = NSTextField(labelWithString: "")
    private let eqResetButton = NSButton()
    /// A speaker that can't be found: its stored tone is kept, and the page
    /// offers to forget it.
    private let keptNoteLabel = NSTextField(labelWithString: "")
    private let forgetButton = NSButton()
    /// The Bluetooth-only "Volume" slot: a `.panel` list holding one checkbox
    /// and its one-line explanation. `.panel`, not `.card` — `.card`'s
    /// `raised` fill measures identical to this pane's own ground in light
    /// (2026-09-04), and this is a fact row, not the page's instrument.
    private let btVolumeWell = GroupedSectionView()
    private let btVolumeTitleLabel = NSTextField(labelWithString: "Volume")
    private let btVolumeCheckbox = NSButton()
    private let btVolumeHintLabel =
        NSTextField(labelWithString: "The volume slider moves the speaker's own volume.")
    /// The outlined list: "Show in Mixer", "Scenes" and "Password".
    private let listWell = GroupedSectionView()
    private let listStack = NSStackView()
    /// The scene links, laid side by side as the "Scenes" row's accessory.
    private let groupsStack = NSStackView()
    private lazy var showInMixerRow = ListRowView(title: "Show in Mixer", caption: "",
                                                  accessory: visibilityPopup)
    private lazy var scenesRow = ListRowView(title: "Scenes", accessory: groupsStack)
    private let forgetPasswordButton = NSButton(title: "Forget", target: nil, action: nil)
    /// Shown only while the backend has a password on file for the speaker.
    private lazy var passwordRow = ListRowView(title: "Password", caption: "Saved",
                                               accessory: forgetPasswordButton)

    /// The list sits one section-gap below whatever precedes it, and WHICH
    /// slot that is depends on the speaker — the Equalizer well, the Bluetooth
    /// slot, the Forget button of a speaker that can't be found, or the
    /// identity band on This Mac. All four pins are built once and
    /// `applyPerDeviceSectionVisibility()` activates exactly one; rebuilding a
    /// constraint per refresh would leak one every time. Optional because
    /// `show(device:)` is legitimately called before the view is loaded.
    private var listBelowEQWell: NSLayoutConstraint?
    private var listBelowBTVolume: NSLayoutConstraint?
    private var listBelowForget: NSLayoutConstraint?
    private var listBelowHeader: NSLayoutConstraint?
    /// The Forget button hangs an action band below the kept note when the
    /// note shows, and below the title row when it doesn't.
    private var forgetBelowKeptNote: NSLayoutConstraint?
    private var forgetBelowTitleRow: NSLayoutConstraint?

    /// The saved groups the shown device belongs to, in the order the links
    /// currently in ``groupsStack`` render them — the link's `tag` indexes into
    /// this, so a click knows which group it names without a bespoke row type.
    private var shownGroupIDs: [String] = []

    /// The scroll view wrapping the whole form column, `nil` until `loadView`.
    private var scrollView: NSScrollView?

    /// The device currently shown, `nil` before the first `show(device:)`.
    private var shownDevice: Device?
    private var shownRecord: SpeakerPresentationRecord?
    public var speakerLibrary: SpeakerLibraryController?
    public var onVisibilityChange: (() -> Void)?
    private let visibilityPopup = NSPopUpButton()

    /// Report a tone change: the new EQ, the device it belongs to, and whether
    /// the gesture is finished (`false` = live scrub, apply only; `true` =
    /// apply AND persist). The pane reaches no backend itself.
    public var onSetEQ: ((DeviceEQ, String, Bool) -> Void)?

    /// A scene link was activated: SELECT this saved group (open its editor),
    /// never activate it. The pane reaches no sidebar and no `GroupController`
    /// mutation itself — the host owns selection.
    public var onSelectGroup: ((String) -> Void)?

    /// Forget was clicked for a speaker the Mac can't find. The host asks
    /// first and does the forgetting.
    public var onForget: ((String) -> Void)?

    /// The stored tone of a speaker the backend no longer knows. The page
    /// reaches no store itself; read once per `show` and kept until the next.
    public var storedDeviceEQ: ((String) -> DeviceEQ?)?
    private var storedEQCache: (id: String, eq: DeviceEQ)?

    /// "Forget" on the list's Password row, with the shown device's id.
    public var onForgetPassword: ((String) -> Void)?

    /// The EQ this pane has SENT for a device while a gesture is IN FLIGHT, and
    /// whether that send was the COMMIT (`awaitingEcho`). Without it a mid-scrub
    /// `update(devices:)` (the backend fans out constantly) would re-render the
    /// slider from the older stored value and yank it out from under the
    /// pointer. A committed entry is released only once a LATER snapshot
    /// actually echoes it back (`refreshUI`) — dropping it synchronously at
    /// commit let events already queued from mid-drag land afterward and
    /// replay the drag on the knob. Kept past that echo it can still lie
    /// forever — a set the backend drops (an id it no longer knows, because the
    /// device vanished mid-drag) would leave this pane showing a shaped curve
    /// for the rest of the session while the audio and every snapshot stayed
    /// flat.
    private var eqEdits: [String: (eq: DeviceEQ, awaitingEcho: Bool)] = [:]

    /// Kept alive across a picker session so it can be dismissed/replaced;
    /// `nil` when no picker is currently presented (mirrors
    /// `GroupEditorViewController.iconPickerPopover`).
    private var iconPickerPopover: NSPopover?

    public init(groupController: GroupController, settings: AppSettings = AppSettings()) {
        self.groupController = groupController
        self.eqEditor = EQEditorView(settings: settings)
        super.init(nibName: nil, bundle: nil)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func loadView() {
        iconWell.translatesAutoresizingMaskIntoConstraints = false
        iconWell.widthAnchor.constraint(equalToConstant: DeviceIconWellView.size).isActive = true
        iconWell.heightAnchor.constraint(equalToConstant: DeviceIconWellView.size).isActive = true
        iconWell.setAccessibilityLabel("Edit speaker icon")
        iconWell.onClick = { [weak self] in
            _ = self?.presentIconPicker()
        }

        // A PLAIN label, deliberately: no fill, no border, no pencil. The
        // decoration IS the message — the group editor's title wears all three
        // because it is renameable, and a device's name is not.
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = Tokens.Font.heading
        nameLabel.alignment = .natural   // left-aligned (LTR) to match the form column
        nameLabel.lineBreakMode = .byTruncatingTail
        // SELECTABLE, not editable: a name you can't copy is a name you have
        // to retype.
        nameLabel.isSelectable = true
        // A long device name TRUNCATES; it never widens the pane. Without this
        // the label's default compression resistance beats the split view's own
        // divider geometry, and a long name silently squeezes the sidebar past
        // its minimum thickness.
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        subtitleLabel.font = Tokens.Font.caption
        subtitleLabel.textColor = Tokens.Color.label2
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // The Mixer failure pill's glyph.
        subtitleGlyph.image = DeviceIcon.image("exclamationmark.triangle", pointSize: 11)
        subtitleGlyph.contentTintColor = Tokens.Color.failure
        subtitleGlyph.setAccessibilityElement(false)
        subtitleStack.translatesAutoresizingMaskIntoConstraints = false
        subtitleStack.orientation = .horizontal
        subtitleStack.alignment = .centerY
        subtitleStack.spacing = 4
        subtitleStack.setViews([subtitleGlyph, subtitleLabel], in: .leading)

        visibilityPopup.menu?.autoenablesItems = false
        visibilityPopup.addItems(withTitles: SpeakerMixerVisibility.allCases.map(\.label))
        visibilityPopup.target = self
        visibilityPopup.action = #selector(visibilityChanged(_:))
        visibilityPopup.setAccessibilityLabel("Show in Mixer")

        // The scene links sit side by side and truncate before the row's
        // "Scenes" title gives way.
        groupsStack.orientation = .horizontal
        groupsStack.alignment = .centerY
        groupsStack.spacing = 12
        scenesRow.titleLabel.setContentCompressionResistancePriority(.defaultHigh + 1, for: .horizontal)
        groupsStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        listStack.translatesAutoresizingMaskIntoConstraints = false
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 0
        forgetPasswordButton.bezelStyle = .rounded
        forgetPasswordButton.controlSize = .small
        forgetPasswordButton.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        forgetPasswordButton.target = self
        forgetPasswordButton.action = #selector(forgetPasswordTapped)
        for row in [showInMixerRow, scenesRow, passwordRow] {
            listStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
        }

        // The Bluetooth-only volume slot. Stock checkbox, no custom drawing;
        // its state is set by `applyPerDeviceSectionVisibility()`, which may
        // already have run by the time `loadView` does.
        btVolumeCheckbox.translatesAutoresizingMaskIntoConstraints = false
        btVolumeCheckbox.setButtonType(.switch)
        btVolumeCheckbox.title = "Control speaker volume"
        btVolumeCheckbox.font = Tokens.Font.body
        btVolumeCheckbox.target = self
        btVolumeCheckbox.action = #selector(btVolumeToggled(_:))
        btVolumeHintLabel.translatesAutoresizingMaskIntoConstraints = false
        btVolumeHintLabel.font = Tokens.Font.caption
        btVolumeHintLabel.textColor = Tokens.Color.label2
        btVolumeHintLabel.lineBreakMode = .byTruncatingTail

        // The two slot titles take the scene editor's plain label voice.
        for title in [eqTitleLabel, btVolumeTitleLabel] {
            title.translatesAutoresizingMaskIntoConstraints = false
            title.font = Tokens.Font.body
            title.textColor = Tokens.Color.label2
        }
        eqSummaryLabel.font = Tokens.Font.caption
        eqSummaryLabel.textColor = Tokens.Color.label2
        eqSummaryLabel.lineBreakMode = .byTruncatingTail
        eqSummaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        eqMarkView.setAccessibilityElement(false)
        eqMarkView.widthAnchor.constraint(equalToConstant: 15).isActive = true
        eqMarkView.heightAnchor.constraint(equalToConstant: 15).isActive = true
        eqTitleRow.translatesAutoresizingMaskIntoConstraints = false
        eqTitleRow.orientation = .horizontal
        eqTitleRow.alignment = .centerY
        eqTitleRow.spacing = 8
        eqTitleRow.setViews([eqTitleLabel, eqMarkView, eqSummaryLabel], in: .leading)
        eqTitleRow.setCustomSpacing(5, after: eqMarkView)

        // Visibility is set by `refreshUI()`/`applyPerDeviceSectionVisibility()`,
        // which may already have run by the time `loadView` does — not here.
        eqResetButton.translatesAutoresizingMaskIntoConstraints = false
        eqResetButton.bezelStyle = .rounded
        eqResetButton.controlSize = .small
        eqResetButton.font = Tokens.Font.caption
        eqResetButton.title = "Reset"
        eqResetButton.target = self
        eqResetButton.action = #selector(resetTapped(_:))
        eqResetButton.setAccessibilityLabel("Reset tone to flat")

        keptNoteLabel.translatesAutoresizingMaskIntoConstraints = false
        keptNoteLabel.font = Tokens.Font.caption
        keptNoteLabel.textColor = Tokens.Color.label2
        keptNoteLabel.lineBreakMode = .byTruncatingTail
        keptNoteLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        forgetButton.translatesAutoresizingMaskIntoConstraints = false
        forgetButton.bezelStyle = .rounded
        forgetButton.target = self
        forgetButton.action = #selector(forgetTapped(_:))

        let container = NSView()
        // The form column: symmetric margins off the pane, ELASTIC up to
        // `GroupsPaneLayout.contentMaxWidth` — the same column idiom
        // `GroupEditorViewController` uses, off the same constants, so the two
        // panes are interchangeable behind one sidebar.
        let column = NSView()
        column.translatesAutoresizingMaskIntoConstraints = false

        // Sections go in FIRST so they sit behind the content they back
        // (non-interactive either way — `GroupedSectionView.hitTest` is nil).
        // The HEADER keeps the full spine-gutter inset so its icon + name stay
        // pinned to the group editor's; everything below it uses the rail-free
        // inset, because no rail runs past it.
        headerWell.contentLeadingInset = GroupsPaneLayout.contentLeadingInset
        eqWell.contentLeadingInset = GroupsPaneLayout.railFreeContentLeadingInset
        btVolumeWell.contentLeadingInset = GroupsPaneLayout.railFreeContentLeadingInset
        listWell.contentLeadingInset = ListRowView.leadingInset
        headerWell.style = .bare
        btVolumeWell.style = .panel
        eqWell.style = .well
        // The scene editor's outlined membership list.
        listWell.style = .card
        eqEditor.translatesAutoresizingMaskIntoConstraints = false
        eqEditor.delegate = self

        for well in [headerWell, eqWell, btVolumeWell, listWell] {
            well.translatesAutoresizingMaskIntoConstraints = false
            column.addSubview(well)
        }
        for v in [iconWell, nameLabel, subtitleStack, eqTitleRow, eqResetButton, eqEditor,
                  keptNoteLabel, forgetButton,
                  btVolumeTitleLabel, btVolumeCheckbox, btVolumeHintLabel, listStack] {
            column.addSubview(v)
        }

        // The pane SCROLLS (`../AGENTS.md`): with the Equalizer's Advanced fold
        // open the column is taller than the screen. Overlay scrollers + no
        // background so the pane still reads as one warm surface, and a
        // FLIPPED document so the form starts at the TOP rather than
        // bottom-gravitating.
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

        rebuildGroupRows()

        let columnFill = column.trailingAnchor.constraint(
            equalTo: document.trailingAnchor, constant: -GroupsPaneLayout.columnTrailingInset)
        columnFill.priority = .defaultHigh

        // The list's four possible top pins and the Forget button's two, built
        // once (see the properties). None goes in the array below —
        // `applyPerDeviceSectionVisibility()` and `refreshEQTitleRow()` pick.
        listBelowEQWell = listStack.topAnchor.constraint(
            equalTo: eqWell.bottomAnchor, constant: GroupsPaneLayout.sectionGap)
        listBelowBTVolume = listStack.topAnchor.constraint(
            equalTo: btVolumeWell.bottomAnchor, constant: GroupsPaneLayout.sectionGap)
        listBelowForget = listStack.topAnchor.constraint(
            equalTo: forgetButton.bottomAnchor, constant: GroupsPaneLayout.sectionGap)
        listBelowHeader = listStack.topAnchor.constraint(
            equalTo: headerWell.bottomAnchor, constant: GroupsPaneLayout.sectionGap)
        forgetBelowKeptNote = forgetButton.topAnchor.constraint(
            equalTo: keptNoteLabel.bottomAnchor, constant: GroupsPaneLayout.actionBandGap)
        forgetBelowTitleRow = forgetButton.topAnchor.constraint(
            equalTo: eqTitleRow.bottomAnchor, constant: GroupsPaneLayout.actionBandGap)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            // The document is exactly as wide as the pane and as tall as the
            // column needs — vertical scrolling only, never horizontal.
            document.widthAnchor.constraint(equalTo: scrollView.widthAnchor),

            // The column top-pins to the DOCUMENT, not the pane's safe-area
            // guide — the clip view already sits below the title-bar chrome,
            // so the document itself is the correct top reference here.
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

            // HEADER PARITY: every number below comes from `GroupsPaneLayout`,
            // the same source the group editor reads, so the icon well and the
            // name land on the same x and the band is the same height in both
            // panes; switching sidebar selection never jumps the header.
            headerWell.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            headerWell.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            headerWell.topAnchor.constraint(equalTo: column.topAnchor),
            headerWell.bottomAnchor.constraint(equalTo: iconWell.bottomAnchor,
                                               constant: GroupsPaneLayout.headerPadding),

            iconWell.topAnchor.constraint(equalTo: column.topAnchor,
                                          constant: GroupsPaneLayout.headerPadding),
            iconWell.leadingAnchor.constraint(equalTo: column.leadingAnchor,
                                              constant: GroupsPaneLayout.contentLeadingInset),

            // The name stays centred on the icon, as in the other panes; the
            // caption hangs under it.
            nameLabel.leadingAnchor.constraint(equalTo: iconWell.trailingAnchor,
                                               constant: GroupsPaneLayout.iconToTitleGap),
            nameLabel.centerYAnchor.constraint(equalTo: iconWell.centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: headerWell.trailingAnchor,
                                                constant: -GroupsPaneLayout.contentTrailingInset),
            subtitleStack.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            subtitleStack.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            subtitleStack.trailingAnchor.constraint(lessThanOrEqualTo: headerWell.trailingAnchor,
                                                    constant: -GroupsPaneLayout.contentTrailingInset),

            // "Equalizer" sits on bare pane one section-gap under identity, at
            // the CONTENT lane's leading inset, since this pane draws no rail.
            eqTitleRow.topAnchor.constraint(equalTo: headerWell.bottomAnchor,
                                            constant: GroupsPaneLayout.sectionGap),
            eqTitleRow.leadingAnchor.constraint(
                equalTo: column.leadingAnchor,
                constant: GroupsPaneLayout.railFreeContentLeadingInset),
            eqTitleRow.trailingAnchor.constraint(lessThanOrEqualTo: eqResetButton.leadingAnchor,
                                                 constant: -8),

            // Reset sits on the SAME title line, trailing-aligned to the
            // well's content edge (the same edge `eqEditor` itself trails to).
            eqResetButton.trailingAnchor.constraint(
                equalTo: column.trailingAnchor, constant: -GroupsPaneLayout.contentTrailingInset),
            eqResetButton.centerYAnchor.constraint(equalTo: eqTitleLabel.centerYAnchor),

            // The well's content, one label-to-section gap below its title,
            // plus the well's own top padding — `cardContentInset`, because
            // the editor is an INSTRUMENT, not a list of text rows.
            eqEditor.topAnchor.constraint(
                equalTo: eqTitleRow.bottomAnchor,
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

            // A speaker that can't be found: the kept note under the title
            // row, and Forget an action band below it.
            keptNoteLabel.topAnchor.constraint(equalTo: eqTitleRow.bottomAnchor,
                                               constant: GroupsPaneLayout.labelToSectionGap),
            keptNoteLabel.leadingAnchor.constraint(
                equalTo: column.leadingAnchor,
                constant: GroupsPaneLayout.railFreeContentLeadingInset),
            keptNoteLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: column.trailingAnchor,
                constant: -GroupsPaneLayout.contentTrailingInset),
            forgetButton.leadingAnchor.constraint(
                equalTo: column.leadingAnchor,
                constant: GroupsPaneLayout.railFreeContentLeadingInset),

            // "Volume" — Bluetooth only, one section-gap under the Equalizer
            // (a Bluetooth speaker always shows that slot), at the same
            // rail-free lane as every other title here.
            btVolumeTitleLabel.topAnchor.constraint(equalTo: eqWell.bottomAnchor,
                                                    constant: GroupsPaneLayout.sectionGap),
            btVolumeTitleLabel.leadingAnchor.constraint(
                equalTo: column.leadingAnchor,
                constant: GroupsPaneLayout.railFreeContentLeadingInset),

            btVolumeCheckbox.topAnchor.constraint(
                equalTo: btVolumeTitleLabel.bottomAnchor,
                constant: GroupsPaneLayout.labelToSectionGap + GroupedSectionView.verticalPadding),
            btVolumeCheckbox.leadingAnchor.constraint(
                equalTo: column.leadingAnchor,
                constant: GroupsPaneLayout.railFreeContentLeadingInset),
            btVolumeCheckbox.trailingAnchor.constraint(
                lessThanOrEqualTo: column.trailingAnchor,
                constant: -GroupsPaneLayout.contentTrailingInset),

            btVolumeHintLabel.topAnchor.constraint(equalTo: btVolumeCheckbox.bottomAnchor,
                                                   constant: 2),
            btVolumeHintLabel.leadingAnchor.constraint(equalTo: btVolumeCheckbox.leadingAnchor),
            btVolumeHintLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: column.trailingAnchor,
                constant: -GroupsPaneLayout.contentTrailingInset),

            btVolumeWell.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            btVolumeWell.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            btVolumeWell.topAnchor.constraint(equalTo: btVolumeCheckbox.topAnchor,
                                              constant: -GroupedSectionView.verticalPadding),
            btVolumeWell.bottomAnchor.constraint(equalTo: btVolumeHintLabel.bottomAnchor,
                                                 constant: GroupedSectionView.verticalPadding),

            // The outlined list. Its TOP is one of the four alternative pins
            // built above. The rows carry their own insets, so the list spans
            // the column.
            listStack.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            listWell.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            listWell.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            listWell.topAnchor.constraint(equalTo: listStack.topAnchor),
            listWell.bottomAnchor.constraint(equalTo: listStack.bottomAnchor),

            // The list is ALWAYS last, so it ties the slots to the column's
            // bottom. Without this the column's height is ambiguous and the
            // scroll document collapses.
            listWell.bottomAnchor.constraint(equalTo: column.bottomAnchor),
        ])

        view = container

        // `show(device:)` is routinely called BEFORE the view is ever loaded
        // (`MixerWindowController.showDetail` shows the device and mounts the
        // pane second), so the refresh that ran then found every pin still
        // nil. Run it again now that they exist.
        refreshUI()
    }

    // MARK: Model

    /// Show the pane for `device`, replacing whatever was shown before.
    public func show(device: Device) {
        shownRecord = presentation(for: device)
        shownDevice = device
        eqEdits.removeAll()
        storedEQCache = nil
        refreshUI()
    }

    /// Update the currently-shown fields from a fresher `device` snapshot (a
    /// live volume/connection-state change), without disturbing hover/popover
    /// state. Behaves exactly like `show(device:)` if `device.id` differs —
    /// the sidebar is expected to call `show(device:)` for a new selection,
    /// but this stays correct either way.
    public func refresh(device: Device) {
        shownRecord = presentation(for: device)
        shownDevice = device
        refreshUI()
    }

    public func show(record: SpeakerPresentationRecord) {
        shownRecord = record
        shownDevice = record.renderingDevice
        eqEdits.removeAll()
        storedEQCache = nil
        refreshUI()
    }

    public func refresh(record: SpeakerPresentationRecord) {
        shownRecord = record
        shownDevice = record.renderingDevice
        refreshUI()
    }

    private func presentation(for device: Device) -> SpeakerPresentationRecord? {
        if let record = speakerLibrary?.record(for: device.id) { return record }
        let library = SpeakerLibraryController(loadPersisted: false)
        library.update(liveDevices: [device], groups: [])
        return library.record(for: device.id)
    }

    @objc private func visibilityChanged(_ sender: NSPopUpButton) {
        guard let record = shownRecord, !record.isLocalDevice,
              let library = speakerLibrary,
              let value = SpeakerMixerVisibility.allCases.first(where: { $0.label == sender.titleOfSelectedItem }) else { return }
        if library.setVisibility(value, for: record.id) { onVisibilityChange?() }
        if let updated = library.record(for: record.id) { refresh(record: updated) }
    }

    /// This Mac is where the audio comes FROM: no Equalizer, no visibility.
    private var isThisMac: Bool {
        shownRecord?.isLocalDevice == true || shownDevice?.isLocalDevice == true
            || shownDevice?.kind == .localMac
    }

    /// A remembered speaker the backend no longer knows.
    private var isLost: Bool {
        shownDevice != nil && shownRecord != nil && shownRecord?.liveDevice == nil && !isThisMac
    }

    private func refreshUI() {
        guard let device = shownDevice else {
            applyPerDeviceSectionVisibility()
            return
        }
        nameLabel.stringValue = device.name
        nameLabel.toolTip = shownRecord?.secondaryText
        nameLabel.setAccessibilityLabel(shownRecord?.accessibilityIdentity ?? device.name)
        refreshSubtitle(for: device)
        let visibility = shownRecord?.visibility ?? .whenAvailable
        visibilityPopup.selectItem(withTitle: visibility.label)
        visibilityPopup.isEnabled = speakerLibrary != nil && shownRecord?.isLocalDevice != true
        showInMixerRow.caption = Self.visibilityCaption(visibility)
        keptNoteLabel.stringValue = "Kept for when \(device.name) is found again."
        forgetButton.title = "Forget \u{201C}\(device.name)\u{201D}…"
        rebuildGroupRows()
        refreshIcon()

        applyPerDeviceSectionVisibility()

        // A scrub (or a just-committed value still awaiting its echo) wins
        // over the snapshot: the backend fans out `update(devices:)`
        // constantly, and re-rendering mid-drag from the older stored value
        // yanks the slider out from under the pointer. A committed entry is
        // released here, the instant a snapshot actually matches it — never
        // synchronously at commit, or events already queued from mid-drag
        // would land afterward and replay the drag on the knob.
        if let entry = eqEdits[device.id], entry.awaitingEcho, device.eq == entry.eq {
            eqEdits[device.id] = nil
        }
        // An away speaker keeps its editor: the tone is stored per speaker and
        // waits for it to come back.
        let bypassNote: String?
        if let record = shownRecord, !record.isAvailable {
            bypassNote = "Not applied while \(device.name) is unavailable; kept for when it\u{2019}s back."
        } else {
            bypassNote = device.eqBypassReason.map(EQEditorView.bypassNoteText)
        }
        eqEditor.apply(eq: eqEdits[device.id]?.eq ?? device.eq, bypassNote: bypassNote)
        refreshEQTitleRow()
    }

    /// The caption under the name: "This Mac", "<kind> · <status>", or the
    /// failure glyph and "Can’t be found".
    private func refreshSubtitle(for device: Device) {
        let text: String
        if isThisMac {
            text = "This Mac"
        } else if isLost {
            text = shownRecord?.kind.map { "\(Self.kindText(for: $0)) · Can\u{2019}t be found" }
                ?? "Can\u{2019}t be found"
        } else {
            text = [Self.kindText(for: shownRecord?.kind ?? device.kind), shownRecord?.status.text]
                .compactMap { $0 }.joined(separator: " · ")
        }
        subtitleLabel.stringValue = text
        subtitleGlyph.isHidden = !isLost
    }

    /// The tone the title row describes: what the editor renders, or for a
    /// speaker that can't be found, what the store still holds for it.
    private var shownEQ: DeviceEQ {
        guard let id = shownDevice?.id else { return .flat }
        guard isLost else { return eqEditor.currentEQ }
        if let cache = storedEQCache, cache.id == id { return cache.eq }
        let eq = storedDeviceEQ?(id) ?? .flat
        storedEQCache = (id, eq)
        return eq
    }

    /// The title row's mark, summary and Reset, the kept note and the Forget
    /// button's position — everything that follows the shown tone.
    private func refreshEQTitleRow() {
        let eq = shownEQ
        eqSummaryLabel.stringValue = Self.eqSummary(eq)
        eqMarkView.isShaped = !eq.isFlat
        eqResetButton.isHidden = eqTitleRow.isHidden || isLost || eq.isFlat
        eqResetButton.isEnabled = shownRecord?.liveDevice != nil
        keptNoteLabel.isHidden = !isLost || eq.isFlat
        forgetBelowKeptNote?.isActive = false
        forgetBelowTitleRow?.isActive = false
        (keptNoteLabel.isHidden ? forgetBelowTitleRow : forgetBelowKeptNote)?.isActive = true
    }

    /// "Flat", or what is shaped, in the editor's own readout words.
    static func eqSummary(_ eq: DeviceEQ) -> String {
        guard !eq.isFlat else { return "Flat" }
        var parts: [String] = []
        if eq.bassDB != 0 { parts.append("Bass " + EQEditorView.gainText(eq.bassDB)) }
        if eq.trebleDB != 0 { parts.append("Treble " + EQEditorView.gainText(eq.trebleDB)) }
        if eq.balance != 0 { parts.append("Balance " + EQEditorView.balanceReadoutText(eq.balance)) }
        if eq.loudness { parts.append("Loudness on") }
        let bands = eq.bandGainsDB.filter { $0 != 0 }.count
        if bands > 0 { parts.append(bands == 1 ? "1 band set" : "\(bands) bands set") }
        return parts.joined(separator: ", ")
    }

    /// One sentence saying what the Show in Mixer value does.
    private static func visibilityCaption(_ visibility: SpeakerMixerVisibility) -> String {
        switch visibility {
        case .whenAvailable: return "Listed while it\u{2019}s on the network."
        case .always: return "Listed even while it\u{2019}s unavailable."
        case .hideWhenNotInUse: return "Listed only while it plays."
        }
    }

    /// Show or hide each slot for the shown device, and pin the list under
    /// whichever slot then precedes it.
    ///
    /// Called from `refreshUI()`, which `loadView` also runs, because the two
    /// arrive in either order (the pane is shown before it is mounted), and
    /// the list must never be left without a top pin: it ties the column's
    /// bottom, so an unpinned list makes the column's height ambiguous and
    /// the scroll document collapses.
    private func applyPerDeviceSectionVisibility() {
        let hasSpeaker = shownDevice != nil && !isThisMac
        let showsEQ = hasSpeaker && !isLost
        eqTitleRow.isHidden = !hasSpeaker
        eqWell.isHidden = !showsEQ
        eqEditor.isHidden = !showsEQ
        if !isLost { keptNoteLabel.isHidden = true }
        forgetButton.isHidden = !isLost
        if !hasSpeaker { eqResetButton.isHidden = true }

        // The "Volume" slot is Bluetooth-only, and needs a store to read and
        // write — nothing else can answer the checkbox's question. A speaker
        // CHECKED and found unable to deliver (`btHardwareVolumeCapable ==
        // false`) drops the slot: offering the toggle there promises
        // something that cannot happen. Unknown (`nil` — never connected this
        // run) keeps it, so the choice can be made ahead of a connect.
        let store = btHardwareVolumeStore
        let showsBTVolume = showsEQ && shownDevice?.kind == .bluetooth && store != nil
            && shownDevice?.btHardwareVolumeCapable != false
        btVolumeWell.isHidden = !showsBTVolume
        btVolumeTitleLabel.isHidden = !showsBTVolume
        btVolumeCheckbox.isHidden = !showsBTVolume
        btVolumeHintLabel.isHidden = !showsBTVolume
        if let store, let device = shownDevice {
            btVolumeCheckbox.state = store.isEnabled(uid: device.id) ? .on : .off
        }

        showInMixerRow.isHidden = isThisMac
        passwordRow.isHidden = shownDevice?.hasStoredPassword != true
        listWell.rows = listStack.arrangedSubviews.filter { !$0.isHidden }

        for pin in [listBelowEQWell, listBelowBTVolume, listBelowForget, listBelowHeader] {
            pin?.isActive = false
        }
        let listPin: NSLayoutConstraint?
        if showsBTVolume {
            listPin = listBelowBTVolume
        } else if showsEQ {
            listPin = listBelowEQWell
        } else if isLost {
            listPin = listBelowForget
        } else {
            listPin = listBelowHeader
        }
        listPin?.isActive = true
    }

    /// The per-speaker opt-out flipped. Persist first, then report — the event
    /// records what actually landed in the store, never an intent.
    @objc private func btVolumeToggled(_ sender: NSButton) {
        guard let store = btHardwareVolumeStore, let device = shownDevice else { return }
        let enabled = sender.state == .on
        guard store.setEnabled(enabled, uid: device.id) else { return }
        Analytics.capture("bt_volume:hardware_toggled", ["enabled": enabled ? "true" : "false"])
    }

    @objc private func forgetTapped(_ sender: NSButton) {
        guard isLost, let id = shownDevice?.id else { return }
        onForget?(id)
    }

    @objc private func forgetPasswordTapped() {
        guard let id = shownDevice?.id else { return }
        onForgetPassword?(id)
    }

    /// Human word for a device kind. No existing shared mapping for this
    /// (`Device.Kind.symbolName` only maps to a glyph); kept private to this
    /// pane rather than promoted to the model until a second caller needs it.
    private static func kindText(for kind: Device.Kind) -> String {
        switch kind {
        case .localMac:       return "This Mac"
        case .homePod:        return "HomePod"
        case .appleTV:        return "Apple TV"
        case .airportExpress: return "AirPort Express"
        case .sonos:          return "Sonos"
        case .generic:        return "AirPlay Speaker"
        case .bluetooth:      return "Bluetooth Speaker"
        case .cast:           return "Cast Speaker"
        }
    }

    // MARK: Scene links

    /// Shown when the device belongs to no saved group. The row STAYS —
    /// hiding it would make "which scenes is this speaker in?" unanswerable
    /// from the page that exists to answer it.
    private static let noGroupsRowText = "Not in any scene"

    /// Every saved group this device belongs to, in `groupController.groups`
    /// order.
    private func groups(containing device: Device) -> [Group] {
        groupController.groups.filter { $0.memberIDs.contains(device.id) }
    }

    /// Exactly what one scene link draws, named as one Equatable value so
    /// ``rebuildGroupRows()`` can be gated on it changing. Not a diffing
    /// framework — one struct, one equality check, the same shape
    /// `MixerWindowController.SidebarProjection` uses one pane over.
    private struct GroupRowProjection: Equatable {
        let id: String
        let name: String
        let symbolName: String
    }

    /// The projection the links currently on screen were built from.
    private var lastGroupRowProjection: [GroupRowProjection]?

    /// How many times the scene links have actually been rebuilt — proves
    /// the change gate: a volume/connection-only refresh must leave this
    /// unchanged, a group rename must bump it exactly once.
    public private(set) var test_groupRowsRebuildCount = 0

    /// Rebuild the scene links for the shown device. `NSStackView`'s
    /// `removeArrangedSubview` alone leaves the view IN the hierarchy (it only
    /// stops arranging it), so every old link is removed from its superview
    /// too or the row quietly stacks up ghosts behind the live links.
    private func rebuildGroupRows() {
        let memberGroups = shownDevice.map(groups(containing:)) ?? []
        // `refreshUI()` runs on every backend event for the app's whole
        // lifetime, and almost none of them touch these links — rebuilding a
        // fresh `NSButton` + `NSImage` per group each time threw away the
        // links under the pointer several times a second during discovery.
        let projection = memberGroups.map {
            GroupRowProjection(
                id: $0.id, name: $0.name,
                symbolName: DeviceIcon.resolve($0.iconSymbolName,
                                               default: Group.defaultIconSymbolName))
        }
        guard projection != lastGroupRowProjection else { return }
        lastGroupRowProjection = projection
        test_groupRowsRebuildCount += 1

        for row in groupsStack.arrangedSubviews {
            groupsStack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }

        shownGroupIDs = memberGroups.map(\.id)

        let rows: [NSView] = memberGroups.isEmpty
            ? [makeNoGroupsRow()]
            : memberGroups.enumerated().map { makeGroupRow($0.element, tag: $0.offset) }
        for row in rows {
            groupsStack.addArrangedSubview(row)
        }
    }

    /// Gap held clear between a link's title and its chevron, so a truncated
    /// name never crowds the glyph.
    private static let groupRowChevronGap: CGFloat = 8

    /// The least title room a squeezed link keeps: an ellipsis and a letter.
    private static let groupRowMinTitleWidth: CGFloat = 24

    /// One scene link: the group's icon, its name, and a trailing chevron
    /// saying the link OPENS something.
    ///
    /// A borderless `NSButton`, deliberately — not a stack view with a click
    /// recognizer. Stock AppKit then gives the whole keyboard/accessibility
    /// story for free: Tab focus with a focus ring, Space/Return activation,
    /// `NSAccessibilityButton` role, and `accessibilityPerformPress()`.
    ///
    /// The chevron is a click-through subview riding on the button.
    /// `NSButtonCell` only fires when the mouse-UP lands inside the button's
    /// own frame, so a button that stops short of the chevron leaves every
    /// click on the glyph dead. The title's clearance is therefore a CELL job —
    /// `GroupRowButtonCell` shortens `titleRect(forBounds:)` by the chevron's
    /// width plus the gap, so a long name truncates against the glyph instead
    /// of drawing under it.
    private func makeGroupRow(_ group: Group, tag: Int) -> NSView {
        let button = NSButton()
        // The cell is swapped BEFORE anything is configured on the button
        // (`WarmFaderCell`'s precedent) — assigning a fresh cell afterwards
        // would drop every setting made through the old one. The stock font
        // rides across so the swap changes nothing but the title's width.
        let stockFont = button.font
        let cell = GroupRowButtonCell()
        button.cell = cell
        button.font = stockFont
        button.setButtonType(.momentaryPushIn)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.tag = tag
        button.alignment = .left
        button.imagePosition = .imageLeading
        button.lineBreakMode = .byTruncatingTail
        button.title = group.name
        button.target = self
        button.action = #selector(groupRowClicked(_:))
        // The ONE group-icon resolution path (`AGENTS.md`): a stale override
        // falls back to the group default rather than a blank glyph.
        // CACHED and SHARED — never mutate it; the tint is a view property.
        let symbol = DeviceIcon.resolve(group.iconSymbolName, default: Group.defaultIconSymbolName)
        button.image = DeviceIcon.image(symbol)
        button.setAccessibilityLabel(group.name)
        // A long group name truncates; it never widens the pane. Earlier links
        // hold their width first, so which one truncates is never a toss-up.
        button.setContentCompressionResistancePriority(.defaultLow - Float(min(tag, 100)), for: .horizontal)

        // Rides ON the button — the WHOLE link is the target, so the glyph must
        // never swallow a click meant for it.
        let chevron = ClickThroughImageView()
        chevron.translatesAutoresizingMaskIntoConstraints = false
        let chevronImage = DeviceIcon.image("chevron.right")
        chevron.image = chevronImage
        chevron.contentTintColor = Tokens.Color.label2
        cell.chevronReserve = (chevronImage?.size.width ?? 0) + Self.groupRowChevronGap
        button.addSubview(chevron)
        NSLayoutConstraint.activate([
            // However hard the row squeezes, a link keeps its icon, a couple
            // of letters and the chevron inside its own frame.
            button.widthAnchor.constraint(greaterThanOrEqualToConstant:
                (button.image?.size.width ?? 0) + cell.chevronReserve + Self.groupRowMinTitleWidth),
            chevron.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            chevron.centerYAnchor.constraint(equalTo: button.centerYAnchor),
        ])
        return button
    }

    /// The empty state: a plain secondary-colour label, NOT a control — there
    /// is nothing to open.
    private func makeNoGroupsRow() -> NSView {
        let label = NSTextField(labelWithString: Self.noGroupsRowText)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = Tokens.Color.label2
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    @objc private func groupRowClicked(_ sender: NSButton) {
        guard shownGroupIDs.indices.contains(sender.tag) else { return }
        onSelectGroup?(shownGroupIDs[sender.tag])
    }

    @objc private func resetTapped(_ sender: NSButton) {
        eqEditor.resetToFlat()
    }

    /// Resolve and apply the icon for `shownDevice`: the controller's override
    /// when one is set and still valid on this OS, else the kind default —
    /// `DeviceIconController.symbolName(for:)` already does that fallback, so
    /// this only needs its own direct fallback for the no-controller-injected
    /// case.
    private func refreshIcon() {
        guard let device = shownDevice else { return }
        let name = deviceIconController?.symbolName(for: device) ?? device.symbolName
        let image = NSImage(systemSymbolName: name, accessibilityDescription: device.name)
        image?.isTemplate = true
        iconWell.iconImageView.image = image
    }

    // MARK: Icon picker

    /// Build `IconPickerViewController`, configure it against the shown
    /// device's current override + kind default, and present it as an
    /// anchored popover off the icon well — mirrors
    /// `GroupEditorViewController.presentIconPicker(anchoredTo:)`. Presenting
    /// is skipped when the icon well has no window (headless test), but the
    /// picker is still built, configured, wired, and returned so
    /// `test_clickEditIcon()` can drive it without a hosting window.
    @discardableResult
    private func presentIconPicker() -> IconPickerViewController {
        let device = shownDevice
        let defaultName = device?.symbolName ?? ""
        let currentOverride = device.flatMap { deviceIconController?.overrides[$0.id] }

        let picker = IconPickerViewController()
        picker.configure(currentSymbolName: currentOverride, defaultSymbolName: defaultName)
        picker.onPick = { [weak self] name in
            self?.pickIcon(name)
        }
        test_picker = picker

        // `iconWell.window != nil` is NOT a headless proxy — suites host this
        // pane in a real (ordered-out) window, so the gate has to be explicit.
        if iconWell.window != nil, !HeadlessRuntime.isActive {
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = picker
            popover.contentSize = picker.view.fittingSize
            iconPickerPopover = popover
            popover.show(relativeTo: iconWell.bounds, of: iconWell, preferredEdge: .maxY)
        }
        return picker
    }

    /// Persist `name` as the shown device's icon override (`nil` reverts to
    /// the default) through `DeviceIconController`, then refresh the well —
    /// instant-apply, no separate "Save" step. No-op without an injected
    /// controller (nothing to write through) or without a shown device.
    private func pickIcon(_ name: String?) {
        guard let device = shownDevice else { return }
        if let name {
            deviceIconController?.setSymbolName(name, for: device.id)
        } else {
            deviceIconController?.resetIcon(for: device.id)
        }
        refreshIcon()
    }

    // MARK: Test-support hooks
    //
    // No synthesized clicks in headless runs (`../AGENTS.md`) — these drive
    // the same code paths a real UI interaction would.

    /// The id of the device currently shown, `nil` before the first `show`.
    public var test_shownDeviceID: String? { shownDevice?.id }


    /// What the identity band's caption reads.
    public var test_subtitleText: String { subtitleLabel.stringValue }

    /// Whether the failure glyph leads the caption.
    public var test_subtitleGlyphShown: Bool { !subtitleGlyph.isHidden }

    /// The shown device's membership as ONE comma-joined string ("None" when it
    /// belongs to no saved group) — the plain-string contract `window-harness`
    /// check [9] and the suites assert against, off the same source and order
    /// the links render.
    public var test_groupMembershipText: String {
        guard let device = shownDevice else { return "" }
        let names = groups(containing: device).map(\.name)
        return names.isEmpty ? "None" : names.joined(separator: ", ")
    }

    /// What the Scenes row's links READ, left to right: one entry per saved
    /// group the device belongs to, or the single non-clickable
    /// "Not in any scene" label when it belongs to none.
    public var test_groupRowTitles: [String] {
        groupsStack.arrangedSubviews.map { row in
            if let button = Self.groupRowButton(in: row) { return button.title }
            return (row as? NSTextField)?.stringValue ?? ""
        }
    }

    /// The scene links' titles only — empty when the speaker is in no scene.
    public var test_sceneLinkTitles: [String] {
        groupsStack.arrangedSubviews.compactMap { Self.groupRowButton(in: $0)?.title }
    }

    /// The link button for a link view, or `nil` for the empty-state label.
    private static func groupRowButton(in row: NSView) -> NSButton? {
        row as? NSButton
    }

    /// Where each link's TITLE is actually drawn, in the pane's own
    /// coordinates — the cell's own answer, so the chevron clearance is
    /// measured rather than assumed from the button's frame.
    public var test_groupRowTitleRects: [NSRect] {
        view.layoutSubtreeIfNeeded()
        return groupsStack.arrangedSubviews.compactMap { row in
            guard let button = Self.groupRowButton(in: row), let cell = button.cell else { return nil }
            return button.convert(cell.titleRect(forBounds: button.bounds), to: view)
        }
    }

    /// The gap a link holds clear between its title and its chevron — read
    /// rather than hard-coded, so the geometry assertions can never pin a
    /// number the link no longer uses.
    public static var test_groupRowChevronGap: CGFloat { groupRowChevronGap }

    /// Each link's BUTTON frame, in the pane's own coordinates.
    public var test_groupRowButtonFrames: [NSRect] {
        view.layoutSubtreeIfNeeded()
        return groupsStack.arrangedSubviews.compactMap { row in
            Self.groupRowButton(in: row).map { $0.convert($0.bounds, to: view) }
        }
    }

    /// Each link's trailing CHEVRON frame, in the pane's own coordinates —
    /// paired index-for-index with `test_groupRowButtonFrames`.
    public var test_groupRowChevronFrames: [NSRect] {
        view.layoutSubtreeIfNeeded()
        return groupsStack.arrangedSubviews.compactMap { row in
            row.subviews.compactMap { $0 as? NSImageView }.first
                .map { $0.convert($0.bounds, to: view) }
        }
    }

    /// Activate the link at `index` exactly as a click (or Space/Return on the
    /// focused link) does — no synthesized clicks headless (`../AGENTS.md`).
    /// No-op for an out-of-range index or the empty-state label.
    public func test_selectGroupRow(at index: Int) {
        let rows = groupsStack.arrangedSubviews
        guard rows.indices.contains(index),
              let button = Self.groupRowButton(in: rows[index]) else { return }
        groupRowClicked(button)
    }

    /// The symbol name currently rendered by the icon well.
    public var test_iconSymbolName: String? {
        guard let device = shownDevice else { return nil }
        return deviceIconController?.symbolName(for: device) ?? device.symbolName
    }

    /// HEADER PARITY hooks — the three numbers that must match
    /// `GroupEditorViewController`'s identically-named hooks, so switching
    /// sidebar selection never shifts the header (`GroupsHeaderParityTests`).

    /// The icon well's laid-out frame in the pane's own coordinates.
    public var test_headerIconFrame: NSRect {
        view.layoutSubtreeIfNeeded()
        return iconWell.convert(iconWell.bounds, to: view)
    }

    /// The title's ALIGNMENT rect in the pane's own coordinates — what auto
    /// layout actually pins, so a plain label and the editor's editable field
    /// (whose alignment insets differ from their frames) compare honestly.
    public var test_headerTitleAlignmentFrame: NSRect {
        view.layoutSubtreeIfNeeded()
        return nameLabel.alignmentRect(forFrame: nameLabel.convert(nameLabel.bounds, to: view))
    }

    /// The header SECTION's laid-out frame in the pane's own coordinates.
    public var test_headerSectionFrame: NSRect {
        view.layoutSubtreeIfNeeded()
        return headerWell.convert(headerWell.bounds, to: view)
    }

    /// Leading inset of the list rows' titles, measured from the list's own
    /// edge.
    public var test_listRowContentInset: CGFloat {
        view.layoutSubtreeIfNeeded()
        let label = scenesRow.titleLabel
        let title = label.alignmentRect(forFrame: label.convert(label.bounds, to: view))
        return title.minX - listWell.convert(listWell.bounds, to: view).minX
    }

    /// The VISIBLE slot titles, in page order ("Equalizer", "Volume"; This
    /// Mac shows neither, and "Volume" shows only on a Bluetooth speaker with
    /// a store).
    public var test_slotTitles: [String] {
        var titles: [String] = []
        if !eqTitleRow.isHidden { titles.append(eqTitleLabel.stringValue) }
        if !btVolumeTitleLabel.isHidden { titles.append(btVolumeTitleLabel.stringValue) }
        return titles
    }

    /// Every VISIBLE `.card` OR `.well` section's frame in the pane's own
    /// coordinates, in subview order — a speaker has two (the Equalizer's
    /// `.well` and the list's `.card`), This Mac and a speaker that can't be
    /// found have the list alone. Walked RECURSIVELY — the column sits inside
    /// a scroll view, so the sections are several levels down.
    public var test_cardFrames: [NSRect] {
        view.layoutSubtreeIfNeeded()
        func cards(_ v: NSView) -> [GroupedSectionView] {
            let here: [GroupedSectionView]
            if let section = v as? GroupedSectionView,
               (section.style == .card || section.style == .well), !section.isHidden {
                here = [section]
            } else {
                here = []
            }
            return here + v.subviews.flatMap(cards)
        }
        return cards(view).map { $0.convert($0.bounds, to: view) }
    }

    /// The Equalizer section's editor — the host contract for every tone
    /// assertion (readouts, the bypass sentence, the curve).
    public var test_eqEditor: EQEditorView { eqEditor }

    public var test_visibilityTitle: String? { visibilityPopup.titleOfSelectedItem }
    public var test_visibilityEnabled: Bool { visibilityPopup.isEnabled }
    public func test_changeVisibility(_ value: SpeakerMixerVisibility) {
        visibilityPopup.selectItem(withTitle: value.label)
        visibilityPopup.sendAction(visibilityPopup.action, to: visibilityPopup.target)
    }
    /// False for This Mac and a speaker that can't be found.
    public var test_eqSectionShown: Bool { !eqWell.isHidden }

    /// The Equalizer title row's summary, `nil` when the row is hidden.
    public var test_eqSummaryText: String? { eqTitleRow.isHidden ? nil : eqSummaryLabel.stringValue }
    /// Whether the engaged mark shows beside the summary.
    public var test_eqMarkShown: Bool { !eqTitleRow.isHidden && eqMarkView.isShaped }
    public var test_showInMixerRowShown: Bool { !showInMixerRow.isHidden }
    public var test_showInMixerCaption: String? { showInMixerRow.isHidden ? nil : showInMixerRow.caption }
    public var test_forgetButtonShown: Bool { !forgetButton.isHidden }
    public var test_forgetButtonTitle: String { forgetButton.title }
    public func test_clickForget() { forgetButton.performClick(nil) }
    public var test_keptNoteText: String? { keptNoteLabel.isHidden ? nil : keptNoteLabel.stringValue }
    /// The Password row's caption, `nil` while the row is hidden.
    public var test_passwordCaption: String? { passwordRow.isHidden ? nil : passwordRow.caption }
    /// Invoke the Password row's "Forget" as a click would.
    public func test_tapForgetPassword() { forgetPasswordTapped() }

    /// True while the form column is wrapped in the scroll view the Equalizer
    /// made necessary (`../AGENTS.md`; roadmap 039).
    public var test_hasScrollView: Bool { scrollView != nil }

    /// True when the pane still mounts a stock `NSBox` separator — it must
    /// not: the sections' own inset hairlines replaced the orphaned 185 pt rule
    /// that stopped a third of the way across the pane.
    public var test_hasBoxDivider: Bool {
        func containsBox(_ v: NSView) -> Bool {
            v is NSBox || v.subviews.contains(where: containsBox)
        }
        return containsBox(view)
    }

    /// The outlined list's laid-out frame in the pane's own coordinates.
    public var test_listSectionFrame: NSRect {
        view.layoutSubtreeIfNeeded()
        return listWell.convert(listWell.bounds, to: view)
    }

    /// The Equalizer section's laid-out frame in the pane's own coordinates.
    public var test_eqSectionFrame: NSRect {
        view.layoutSubtreeIfNeeded()
        return eqWell.convert(eqWell.bounds, to: view)
    }

    /// The Equalizer EDITOR's own laid-out frame (inside the well), in the
    /// pane's own coordinates — lets a test measure the well's inner inset
    /// against `test_eqSectionFrame` directly.
    public var test_eqEditorFrame: NSRect {
        view.layoutSubtreeIfNeeded()
        return eqEditor.convert(eqEditor.bounds, to: view)
    }

    /// The Equalizer section title's visible text, `nil` when hidden (This
    /// Mac) — mirrors `test_eqSectionShown` rather than a bare `Bool` so a
    /// test can also assert the copy itself.
    public var test_eqSectionTitleText: String? {
        eqTitleRow.isHidden ? nil : eqTitleLabel.stringValue
    }

    /// The Equalizer section title's laid-out frame in the pane's own
    /// coordinates.
    public var test_eqSectionTitleFrame: NSRect {
        view.layoutSubtreeIfNeeded()
        return eqTitleLabel.convert(eqTitleLabel.bounds, to: view)
    }

    /// The Equalizer title's ALIGNMENT rect (`MainOutDetailViewController
    /// .test_headerTitleAlignmentFrame`'s idiom) — lets a test compare its
    /// centre line with `eqResetButton`'s own frame directly.
    public var test_eqSectionTitleAlignmentFrame: NSRect {
        view.layoutSubtreeIfNeeded()
        return eqTitleLabel.alignmentRect(forFrame: eqTitleLabel.convert(eqTitleLabel.bounds, to: view))
    }

    public func test_fireResetClick() { eqResetButton.performClick(nil) }
    public var test_resetEnabled: Bool { eqResetButton.isEnabled }
    public var test_resetShown: Bool { !eqResetButton.isHidden }
    public var test_eqResetButtonFrame: NSRect {
        view.layoutSubtreeIfNeeded()
        return eqResetButton.convert(eqResetButton.bounds, to: view)
    }

    /// Whether the Bluetooth-only "Control speaker volume" slot is on screen.
    public var test_speakerVolumeRowShown: Bool { !btVolumeWell.isHidden }

    /// The checkbox's own state, and a headless click on it.
    public var test_speakerVolumeEnabled: Bool { btVolumeCheckbox.state == .on }
    public func test_clickSpeakerVolumeCheckbox() { btVolumeCheckbox.performClick(nil) }

    /// Drive the hover scrim's visibility headlessly (a real `mouseEntered`/
    /// `mouseExited` can't be synthesized in a headless run) so the snapshot
    /// tool can render the hovered state.
    public func test_setOverlayVisible(_ visible: Bool) {
        iconWell.setOverlayVisible(visible)
    }

    /// Simulate clicking the icon well: builds, configures, and returns the
    /// `IconPickerViewController` exactly like a real click (also presenting
    /// it as a popover when there's a real window to anchor to).
    @discardableResult
    public func test_clickEditIcon() -> IconPickerViewController {
        presentIconPicker()
    }

    /// The most recently built icon picker (from a real click or
    /// `test_clickEditIcon()`), retained so a test can keep driving it
    /// (`test_pickCurated`, `test_apply`, …) without needing the popover that
    /// hosts it live.
    public private(set) var test_picker: IconPickerViewController?
}

// MARK: - EQEditorViewDelegate

/// Tone gestures leave the pane immediately: it keeps only the value it just
/// sent (``eqEdits``, so a snapshot mid-scrub — or a stale one still in flight
/// right after a commit — can't rewind the slider) and hands everything else
/// to the app through ``onSetEQ``. No backend, no store — same discipline as
/// the rest of this module. A committed entry is released by ``refreshUI``,
/// never here: releasing it synchronously would let an already-queued stale
/// snapshot land right after and replay the drag.
extension DeviceDetailViewController: EQEditorViewDelegate {

    public func eqEditor(_ editor: EQEditorView, didChange eq: DeviceEQ, committed: Bool) {
        guard shownRecord?.liveDevice != nil, let id = shownDevice?.id else { return }
        // Set BEFORE forwarding: `onSetEQ` can fan a snapshot straight back,
        // and until it matches this exact value the snapshot must not win.
        eqEdits[id] = (eq, committed)
        onSetEQ?(eq, id, committed)
        refreshEQTitleRow()
        if committed { Analytics.capture("eq:adjusted", ["target": "device"]) }
    }

    public func eqEditorDidRequestReset(_ editor: EQEditorView) {
        guard shownRecord?.liveDevice != nil, let id = shownDevice?.id else { return }
        // One committed action, not ten: the editor has already put its own
        // controls back to flat.
        eqEdits[id] = (.flat, true)
        onSetEQ?(.flat, id, true)
        refreshEQTitleRow()
        Analytics.capture("eq:reset", ["target": "device"])
    }
}

/// A scene link's trailing chevron: pure signal, never a click target. It
/// sits ON the link button, so without this the glyph would refuse the click
/// the rest of the link accepts. Same `hitTest`-nil pattern as
/// `HairlineView`/`GroupedSectionView`; no `draw(_:)` of its own.
final class ClickThroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The scene link button's cell, which does exactly one thing: hold the
/// trailing chevron's width clear of the title. The chevron rides inside the
/// button (`NSButtonCell` fires only on a mouse-up inside its own frame), so
/// without this the title would measure itself against the full width and a
/// long group name would draw straight under the glyph.
final class GroupRowButtonCell: NSButtonCell {

    /// Width kept clear at the trailing edge: the chevron plus the gap before
    /// it. Set once, when the chevron's image is made.
    var chevronReserve: CGFloat = 0

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        var r = super.titleRect(forBounds: rect)
        r.size.width = max(0, r.maxX - chevronReserve - r.minX)
        return r
    }

    /// The natural width includes the chevron, so a link sized to its content
    /// still holds the glyph.
    override var cellSize: NSSize {
        var size = super.cellSize
        size.width += chevronReserve
        return size
    }
}

/// The engaged equalizer mark beside the title row's summary, re-inked on an
/// appearance change because the mark's ink is resolved per appearance.
private final class EqualizerMarkView: NSImageView {
    var isShaped = false { didSet { refresh() } }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    private func refresh() {
        isHidden = !isShaped
        image = isShaped ? DeviceRowView.equalizerEngagedMarkImage(in: effectiveAppearance) : nil
    }
}

/// A flipped document view so the form scrolls from the TOP rather than
/// bottom-gravitating with dead space above the header. File-scoped on purpose
/// (`GroupCreationSheetController` keeps its own for the same reason).
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
