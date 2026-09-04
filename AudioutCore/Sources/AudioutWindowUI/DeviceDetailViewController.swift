// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore
import AudioutSharedUI

/// The device detail pane (CONFIGURATION-ONLY — `../../AGENTS.md`): shown in
/// the Groups screen's detail area when the sidebar selects a device. It
/// DESCRIBES the speaker and TUNES it — it renders a `Device` snapshot plus
/// which saved groups it belongs to, and hosts that speaker's ``EQEditorView``.
/// It never activates a group, changes routing, or moves audio; a tone change
/// is reported straight out through ``onSetEQ`` for the app to apply.
///
/// ONE HOUSING, four slots, top to bottom in an ELASTIC form column off the
/// same ``GroupsPaneLayout`` numbers `GroupEditorViewController` reads:
///
/// - IDENTITY — the large (``DeviceIconWellView/size``pt) icon and the device
///   name side by side in a BARE band: no fill, no border, because identity is
///   not an instrument. The icon resolves through an injected
///   `DeviceIconController` + `Device.Kind.symbolName` fallback (a stale
///   override still lands on the kind default, never a blank glyph), and its
///   always-present corner pencil badge is this phase's one APPROVED CUSTOM
///   ELEMENT (`../../AGENTS.md`): clicking the well presents
///   `IconPickerViewController` as an anchored popover, and picking writes
///   straight through `DeviceIconController`, instant-apply. The name beside
///   it is a PLAIN label — bordered + pencil means editable, bare means
///   read-only, which is exactly the difference between a group's name
///   (renameable) and a device's (not);
/// - "Equalizer" — the page's ONE INSTRUMENT, and therefore its ONLY box: a
///   ``GroupedSectionView/Style/well`` rather than `.card`, because in light
///   `.card`'s `raised` fill measures identical to this pane's own
///   `canvas`/`panel` ground (2026-09-04). Hidden whole for This Mac (the
///   device the audio comes FROM has no send to tune), which is why the
///   "Groups" title below it carries two alternative top constraints;
/// - "Groups" — BARE rows, one per saved group whose `memberIDs` contain this
///   device, in the order the sidebar lists them, each the group's icon + name
///   + a trailing chevron. A row NAVIGATES: it reports out through
///   ``onSelectGroup`` and the host selects that group in the sidebar, which
///   opens its editor. Selecting is NOT activating — nothing here moves audio.
///   A device in no saved group keeps the slot and shows one non-clickable
///   "Not in any group" row;
/// - "About" — BARE fact rows. Status folds `connectionState` and
///   `isAvailable` into ONE value: as two rows they read as a contradiction
///   ("Not connected" sitting over "On the network: Yes"). AirPlay reports
///   `supportsAirPlay2`, and is dropped entirely for Bluetooth and This Mac,
///   which are not AirPlay receivers at all.
///
/// Every title is a plain sibling label above the thing it names, at the group
/// editor's "Speakers" geometry — a label is never a section. There is NO hint
/// line: the window's own footer caption owns the division of labour, and this
/// page restating it put the same sentence on screen twice.
///
/// The whole column SCROLLS (`../AGENTS.md`): the Equalizer's Advanced fold
/// exceeds the Groups screen's height budget, and the surface frame is FIXED
/// for every screen (`AppSurfaceController` — the frame never changes), so
/// scrolling is the only room; growing the window was rejected (roadmap 039).
///
/// No volume slider, no mute, no Selected-Devices toggle, no group activation
/// control of any kind lives here — that's the popover/mixer's job, not this
/// pane's; the Equalizer is configuration, not playback.
public final class DeviceDetailViewController: NSViewController {

    private let groupController: GroupController

    /// Resolves/persists the icon override for the shown device. Optional and
    /// nil-tolerant (`../../AGENTS.md`'s "depends on the model, never the
    /// reverse") — without one the icon well still renders the kind default,
    /// it just can't be changed (the edit affordance still shows on hover;
    /// picking always no-ops without a controller to write through).
    public var deviceIconController: DeviceIconController?

    private let iconWell = DeviceIconWellView()
    private let nameLabel = NSTextField(labelWithString: "")
    /// The identity BAND — `.bare`, so it draws nothing at all. Kept as a
    /// section purely for its GEOMETRY, which `GroupsHeaderParityTests` pins
    /// to the group editor's header band point for point.
    private let headerWell = GroupedSectionView()
    /// The "Groups" and "About" lists — both `.bare`, so all either
    /// contributes is the inset hairline between adjacent rows.
    private let groupsWell = GroupedSectionView()
    private let aboutWell = GroupedSectionView()
    /// The page's ONE instrument, wrapping the shared editor — a `.well`
    /// (recessed), not a `.card`, so it still reads sunk where `raised`
    /// flattens to the pane's own ground in light (2026-09-04). Hidden whole
    /// for This Mac — the audio's SOURCE has no send to tune.
    private let eqWell = GroupedSectionView()
    private let eqEditor: EQEditorView
    /// The three slot titles. Each is a plain sibling label sitting on bare
    /// pane above the list or card it names, exactly as the group editor's
    /// "Speakers" label titles its checklist. `eqTitleLabel` hides in lockstep
    /// with `eqWell` (see `applyEQSectionVisibility()`): This Mac has nothing
    /// to tune, so neither the card nor its title has anything to say. The
    /// title line also carries the card's Reset button (`eqResetButton`),
    /// trailing-aligned on the content edge, hidden with the slot.
    private let eqTitleLabel = NSTextField(labelWithString: "Equalizer")
    /// The Equalizer card's Reset button — moved off the editor and onto this
    /// title line so the loudness row inside the card is the checkbox alone.
    private let eqResetButton = NSButton()
    private let groupsTitleLabel = NSTextField(labelWithString: "Groups")
    private let aboutTitleLabel = NSTextField(labelWithString: "About")
    private let aboutStack = NSStackView()
    private let groupsStack = NSStackView()

    /// "Groups" sits one section-gap below whatever precedes it, and WHICH
    /// slot that is depends on the device — the Equalizer card on a speaker,
    /// the identity band on This Mac. So both constraints are built once and
    /// `applyEQSectionVisibility()` swaps which one is active; rebuilding a
    /// constraint per refresh instead would leak one every time.
    /// Optional, not implicitly-unwrapped: `show(device:)` is legitimately
    /// called before the view is ever loaded (the pane is built long before
    /// it is mounted), and refreshing then must not trap.
    private var groupsTitleBelowEQCard: NSLayoutConstraint?
    private var groupsTitleBelowHeader: NSLayoutConstraint?

    private let statusValueLabel = NSTextField(labelWithString: "")
    private let kindValueLabel = NSTextField(labelWithString: "")
    private let airPlayValueLabel = NSTextField(labelWithString: "")
    /// The AirPlay row itself — the one About row that can be ABSENT, so it is
    /// held to be hidden. Lazy so it is the SAME view whichever of `loadView`
    /// and `refreshUI()` reaches it first; the two arrive in either order.
    private lazy var airPlayRow: NSView =
        makeMetadataRow(caption: "AirPlay", valueLabel: airPlayValueLabel)

    /// The saved groups the shown device belongs to, in the order the rows
    /// currently in ``groupsStack`` render them — the row's `tag` indexes into
    /// this, so a click knows which group it names without a bespoke row type.
    private var shownGroupIDs: [String] = []

    /// The scroll view wrapping the whole form column, `nil` until `loadView`.
    private var scrollView: NSScrollView?

    /// The device currently shown, `nil` before the first `show(device:)`.
    private var shownDevice: Device?

    /// Report a tone change: the new EQ, the device it belongs to, and whether
    /// the gesture is finished (`false` = live scrub, apply only; `true` =
    /// apply AND persist). The pane reaches no backend itself.
    public var onSetEQ: ((DeviceEQ, String, Bool) -> Void)?

    /// A membership row was activated: SELECT this saved group (open its
    /// editor), never activate it. The pane reaches no sidebar and no
    /// `GroupController` mutation itself — the host owns selection.
    public var onSelectGroup: ((String) -> Void)?

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
        // SELECTABLE, not editable: this page exists to state facts about a
        // speaker, and a fact you can't copy is a fact you have to retype.
        nameLabel.isSelectable = true
        // A long device name TRUNCATES; it never widens the pane. Without this
        // the label's default compression resistance beats the split view's own
        // divider geometry, and a long name silently squeezes the sidebar past
        // its minimum thickness.
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // "About" — the speaker's facts, one per row, on bare pane. Status
        // folds availability in rather than taking a row of its own: as two
        // rows they contradicted each other to read ("Not connected" over
        // "On the network: Yes").
        aboutStack.translatesAutoresizingMaskIntoConstraints = false
        aboutStack.orientation = .vertical
        aboutStack.alignment = .leading
        aboutStack.spacing = 10
        for row in [
            makeMetadataRow(caption: "Status", valueLabel: statusValueLabel),
            makeMetadataRow(caption: "Kind", valueLabel: kindValueLabel),
            airPlayRow,
        ] {
            aboutStack.addArrangedSubview(row)
            // Rows FILL the list, so a right-aligned value lands on the
            // content lane's own edge rather than at the end of its own
            // intrinsic width.
            row.widthAnchor.constraint(equalTo: aboutStack.widthAnchor).isActive = true
        }

        // A LIST, so it takes the group editor's checklist rhythm (6 pt)
        // rather than the state section's form rhythm (10 pt). Its rows are
        // per-device — see `rebuildGroupRows`.
        groupsStack.translatesAutoresizingMaskIntoConstraints = false
        groupsStack.orientation = .vertical
        groupsStack.alignment = .leading
        groupsStack.spacing = 6

        // The three slot titles are configured identically, because they are
        // the same thing three times: same font, same colour, same lane.
        for title in [eqTitleLabel, groupsTitleLabel, aboutTitleLabel] {
            title.translatesAutoresizingMaskIntoConstraints = false
            title.font = Tokens.Font.body
            title.textColor = Tokens.Color.label2
        }

        // Enablement/visibility are set by `refreshUI()`/`applyEQSectionVisibility()`,
        // which may already have run by the time `loadView` does — not here.
        eqResetButton.translatesAutoresizingMaskIntoConstraints = false
        eqResetButton.bezelStyle = .rounded
        eqResetButton.controlSize = .small
        eqResetButton.font = Tokens.Font.caption
        eqResetButton.title = "Reset"
        eqResetButton.target = self
        eqResetButton.action = #selector(resetTapped(_:))
        eqResetButton.setAccessibilityLabel("Reset tone to flat")

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
        // pinned to the group editor's; every list below it uses the rail-free
        // inset, because no rail runs past them and reserving the lane left
        // them looking hollow (design review 2026-07-25). That inset is also
        // where a bare list's dividers start.
        headerWell.contentLeadingInset = GroupsPaneLayout.contentLeadingInset
        eqWell.contentLeadingInset = GroupsPaneLayout.railFreeContentLeadingInset
        groupsWell.contentLeadingInset = GroupsPaneLayout.railFreeContentLeadingInset
        aboutWell.contentLeadingInset = GroupsPaneLayout.railFreeContentLeadingInset
        // The header band is bare — a box around an identity band is not a
        // container anyone asked for. The two fact lists are stroked `panel`
        // rows (the iPhone companion's PanelRow): the pane ground is `panel`
        // too, so their edge is the only pixel separating them from it. The
        // Equalizer stays the page's one instrument, but recesses as `.well`
        // rather than `.card` (2026-09-04): in light, `raised` measures
        // identical to this pane's `canvas`/`panel` ground, so the card was a
        // 1 pt outline around nothing — `well` is the one neutral that stays
        // visibly sunk on the flat chassis (DESIGN.md "Elevation & Depth").
        headerWell.style = .bare
        groupsWell.style = .panel
        aboutWell.style = .panel
        eqWell.style = .well
        eqEditor.translatesAutoresizingMaskIntoConstraints = false
        eqEditor.delegate = self

        for well in [headerWell, eqWell, groupsWell, aboutWell] {
            well.translatesAutoresizingMaskIntoConstraints = false
            column.addSubview(well)
        }
        for v in [iconWell, nameLabel, eqTitleLabel, eqResetButton, eqEditor,
                  groupsTitleLabel, groupsStack, aboutTitleLabel, aboutStack] {
            column.addSubview(v)
        }

        // The pane SCROLLS (`../AGENTS.md`): with the Equalizer's Advanced fold
        // open the column is taller than the Groups screen, and this screen is
        // the one the user can resize (with remembered size), so growing the
        // window to fit was rejected. Overlay scrollers + no background so the
        // pane still reads as one warm surface, and a FLIPPED document so the
        // form starts at the TOP rather than bottom-gravitating.
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

        // The rows' own hairlines come from the list, which reads their LIVE
        // frames on every draw. The Groups rows are per-device, so they are
        // built here as well as on every refresh — the pane can be mounted
        // before it is ever shown a device, and a list with no rows at all
        // collapses to nothing.
        aboutWell.rows = aboutStack.arrangedSubviews.filter { !$0.isHidden }
        rebuildGroupRows()

        let columnFill = column.trailingAnchor.constraint(
            equalTo: document.trailingAnchor, constant: -GroupsPaneLayout.columnTrailingInset)
        columnFill.priority = .defaultHigh

        // Both of the "Groups" title's possible top pins, built once (see the
        // properties). Neither goes in the array below — exactly one is
        // activated by `applyEQSectionVisibility()`.
        groupsTitleBelowEQCard = groupsTitleLabel.topAnchor.constraint(
            equalTo: eqWell.bottomAnchor, constant: GroupsPaneLayout.sectionGap)
        groupsTitleBelowHeader = groupsTitleLabel.topAnchor.constraint(
            equalTo: headerWell.bottomAnchor, constant: GroupsPaneLayout.sectionGap)

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

            // HEADER PARITY (design review 2026-07-25), now GEOMETRIC: every
            // number below comes from `GroupsPaneLayout`, the same source the
            // group editor reads, so the icon well and the title land on the
            // same x and the band is the same height in both panes. They used
            // to sit ~22.5 pt apart, so switching sidebar selection visibly
            // jumped the header sideways. This pane draws no rail, so the
            // reserved gutter simply reads as a wider left margin — the
            // alignment is worth more than reclaiming it.
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

            // "Equalizer" sits on bare pane one section-gap under identity —
            // the same break the group editor puts above its "Speakers" label,
            // but at the CONTENT lane's leading inset rather than the
            // header's, since this pane draws no rail past it.
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

            // The card's content, one label-to-section gap below its title,
            // plus the card's own top padding — mirrors the group editor's
            // `speakersLabel` → `membershipStack` math, but with
            // `cardContentInset` rather than `verticalPadding`: the editor is
            // an INSTRUMENT (tone controls and, behind Advanced, a scope), not
            // a list of text rows, so it earns the wider inset
            // (`GroupsPaneLayout.cardContentInset`).
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

            // "Groups". Its TOP is one of the two alternative pins built above
            // — deliberately NOT in this array, since exactly one of them is
            // activated by `applyEQSectionVisibility()`.
            groupsTitleLabel.leadingAnchor.constraint(
                equalTo: column.leadingAnchor,
                constant: GroupsPaneLayout.railFreeContentLeadingInset),

            groupsStack.topAnchor.constraint(
                equalTo: groupsTitleLabel.bottomAnchor,
                constant: GroupsPaneLayout.labelToSectionGap + GroupedSectionView.verticalPadding),
            groupsStack.leadingAnchor.constraint(
                equalTo: column.leadingAnchor,
                constant: GroupsPaneLayout.railFreeContentLeadingInset),
            groupsStack.trailingAnchor.constraint(
                equalTo: column.trailingAnchor, constant: -GroupsPaneLayout.contentTrailingInset),

            groupsWell.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            groupsWell.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            groupsWell.topAnchor.constraint(equalTo: groupsStack.topAnchor,
                                            constant: -GroupedSectionView.verticalPadding),
            groupsWell.bottomAnchor.constraint(equalTo: groupsStack.bottomAnchor,
                                               constant: GroupedSectionView.verticalPadding),

            // "About", the last slot on every device.
            aboutTitleLabel.topAnchor.constraint(equalTo: groupsWell.bottomAnchor,
                                                 constant: GroupsPaneLayout.sectionGap),
            aboutTitleLabel.leadingAnchor.constraint(
                equalTo: column.leadingAnchor,
                constant: GroupsPaneLayout.railFreeContentLeadingInset),

            aboutStack.topAnchor.constraint(
                equalTo: aboutTitleLabel.bottomAnchor,
                constant: GroupsPaneLayout.labelToSectionGap + GroupedSectionView.verticalPadding),
            aboutStack.leadingAnchor.constraint(
                equalTo: column.leadingAnchor,
                constant: GroupsPaneLayout.railFreeContentLeadingInset),
            aboutStack.trailingAnchor.constraint(
                equalTo: column.trailingAnchor, constant: -GroupsPaneLayout.contentTrailingInset),

            aboutWell.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            aboutWell.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            aboutWell.topAnchor.constraint(equalTo: aboutStack.topAnchor,
                                           constant: -GroupedSectionView.verticalPadding),
            aboutWell.bottomAnchor.constraint(equalTo: aboutStack.bottomAnchor,
                                              constant: GroupedSectionView.verticalPadding),

            // About is ALWAYS last, so it is what ties the slots to the
            // column's bottom — no alternates needed, unlike the hint it
            // replaced. Without this the column's height is ambiguous and the
            // scroll document collapses.
            aboutWell.bottomAnchor.constraint(equalTo: column.bottomAnchor),
        ])

        view = container

        // Seed the "Groups" title's top pin NOW, not at the next refresh.
        // `show(device:)` is routinely called BEFORE the view is ever loaded
        // (see `MixerWindowController.showDetail`: it shows the device and
        // mounts the pane second), so the `refreshUI()` that ran then found
        // both constraints still nil and left the title — and everything
        // hanging off it — with no top pin at all.
        applyEQSectionVisibility()
    }

    /// Build one "Caption ······ Value" row: a secondary-colour caption on the
    /// leading edge and its value RIGHT-ALIGNED on the trailing edge, so the
    /// values line up in a real column that uses the section's full width.
    /// (They used to hang off a fixed 90 pt caption column, which left them
    /// stranded mid-pane in a window this wide.)
    ///
    /// The row fills its section: the caller pins each row's width to the
    /// stack's, so "trailing" means the section's own inset edge.
    private func makeMetadataRow(caption: String, valueLabel: NSTextField) -> NSView {
        let captionLabel = NSTextField(labelWithString: caption)
        captionLabel.textColor = Tokens.Color.label2
        captionLabel.translatesAutoresizingMaskIntoConstraints = false
        captionLabel.setContentHuggingPriority(.required, for: .horizontal)
        captionLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.alignment = .right
        valueLabel.lineBreakMode = .byTruncatingTail
        // Selectable for the same reason the device name is: these are facts
        // to quote in a support thread, not decoration.
        valueLabel.isSelectable = true
        valueLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(captionLabel)
        row.addSubview(valueLabel)
        NSLayoutConstraint.activate([
            captionLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            captionLabel.topAnchor.constraint(equalTo: row.topAnchor),
            captionLabel.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            valueLabel.firstBaselineAnchor.constraint(equalTo: captionLabel.firstBaselineAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: captionLabel.trailingAnchor,
                                                constant: 8),
            valueLabel.trailingAnchor.constraint(equalTo: row.trailingAnchor),
        ])
        return row
    }

    // MARK: Model

    /// Show the pane for `device`, replacing whatever was shown before.
    public func show(device: Device) {
        shownDevice = device
        eqEdits.removeAll()
        refreshUI()
    }

    /// Update the currently-shown fields from a fresher `device` snapshot (a
    /// live volume/connection-state change), without disturbing hover/popover
    /// state. Behaves exactly like `show(device:)` if `device.id` differs —
    /// the sidebar is expected to call `show(device:)` for a new selection,
    /// but this stays correct either way.
    public func refresh(device: Device) {
        shownDevice = device
        refreshUI()
    }

    private func refreshUI() {
        guard let device = shownDevice else { return }
        nameLabel.stringValue = device.name
        statusValueLabel.stringValue = Self.statusText(for: device)
        kindValueLabel.stringValue = Self.kindText(for: device.kind)
        let airPlay = Self.airPlayText(for: device)
        airPlayValueLabel.stringValue = airPlay ?? ""
        airPlayRow.isHidden = airPlay == nil
        // Only the rows that are actually there, so no divider is drawn above
        // a row that isn't.
        aboutWell.rows = aboutStack.arrangedSubviews.filter { !$0.isHidden }
        rebuildGroupRows()
        refreshIcon()

        applyEQSectionVisibility()

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
        eqEditor.apply(eq: eqEdits[device.id]?.eq ?? device.eq,
                       bypassReason: device.eqBypassReason)
        refreshResetEnabled()
    }

    /// Show or hide the Equalizer slot for the shown device, and pin the
    /// "Groups" title under whichever slot then precedes it. This Mac is where
    /// the audio comes FROM: there is no send to tune, so the whole slot goes
    /// and Groups closes the gap behind it.
    ///
    /// Called from `loadView` as well as `refreshUI()` because the two arrive
    /// in either order (the pane is shown before it is mounted), and the title
    /// must never be left without a top pin: everything below it hangs off
    /// that pin, down to the About list that ties the column's bottom, so an
    /// unpinned title makes the column's height ambiguous and the scroll
    /// document collapses. With no device yet the speaker branch is the
    /// default — the slot it shows is the one a following `refreshUI()` keeps
    /// for every device but This Mac.
    private func applyEQSectionVisibility() {
        let showsEQ = !(shownDevice?.isLocalDevice == true || shownDevice?.kind == .localMac)
        eqWell.isHidden = !showsEQ
        eqEditor.isHidden = !showsEQ
        eqTitleLabel.isHidden = !showsEQ
        eqResetButton.isHidden = !showsEQ
        groupsTitleBelowEQCard?.isActive = false
        groupsTitleBelowHeader?.isActive = false
        (showsEQ ? groupsTitleBelowEQCard : groupsTitleBelowHeader)?.isActive = true
    }

    /// ONE plain-word line for where this speaker stands, folding the two
    /// facts the form used to split across two rows — "Status: Not connected"
    /// sitting over "On the network: Yes" reads as a contradiction to anyone
    /// not holding the model in their head. Availability only ever changes the
    /// IDLE word: a speaker mid-connect is mid-connect whatever the network
    /// says, and a failure is a failure. "Ready" (not "Not connected") because
    /// a reachable idle speaker is a thing you can use, not a thing that's
    /// broken. The busy words keep `DeviceRowView`'s existing vocabulary.
    private static func statusText(for device: Device) -> String {
        switch device.connectionState {
        case .connected:     return "Connected"
        case .connecting:    return "Connecting…"
        case .reconnecting:  return "Reconnecting…"
        case .failed:        return "Couldn't connect"
        case .off:           return device.isAvailable ? "Ready" : "Not on the network"
        }
    }

    /// Which AirPlay this speaker speaks, or `nil` when the question does not
    /// apply and the row is dropped: `.bluetooth` is not an AirPlay receiver
    /// at all (it carries `supportsAirPlay2 == false` for an unrelated
    /// reason), and `.localMac` is where the audio comes FROM.
    ///
    /// Says what AirPlay 1 COSTS rather than only its version number — the
    /// number alone tells the person reading it nothing.
    private static func airPlayText(for device: Device) -> String? {
        switch device.kind {
        case .bluetooth, .localMac, .cast:
            return nil
        case .homePod, .appleTV, .airportExpress, .sonos, .generic:
            return device.supportsAirPlay2 ? "AirPlay 2" : "AirPlay 1 — sync not exact"
        }
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
        case .cast:           return "Cast Device"
        }
    }

    // MARK: Membership section

    /// Height of one membership row. 28 pt is the Groups screen's locked row
    /// height (`dev/notes/warm-signal-screens-followup.md` — "row height 28pt",
    /// frozen alongside the text colours); the editor's checklist rows are
    /// taller only because the WHOLE row there is a checkbox target.
    private static let groupRowHeight: CGFloat = 28

    /// Shown when the device belongs to no saved group. The section STAYS —
    /// hiding it would make "which groups is this speaker in?" unanswerable
    /// from the page that exists to answer it.
    private static let noGroupsRowText = "Not in any group"

    /// Every saved group this device belongs to, in `groupController.groups`
    /// order — the same order the sidebar's Groups section lists them in
    /// (`SidebarViewController.reload` maps that array straight to rows), so
    /// clicking the third row here lands on the third group there.
    private func groups(containing device: Device) -> [Group] {
        groupController.groups.filter { $0.memberIDs.contains(device.id) }
    }

    /// Exactly what one membership row draws, named as one Equatable value so
    /// ``rebuildGroupRows()`` can be gated on it changing. Not a diffing
    /// framework — one struct, one equality check, the same shape
    /// `MixerWindowController.SidebarProjection` uses one pane over.
    private struct GroupRowProjection: Equatable {
        let id: String
        let name: String
        let symbolName: String
    }

    /// The projection the rows currently on screen were built from.
    private var lastGroupRowProjection: [GroupRowProjection]?

    /// How many times the membership rows have actually been rebuilt — proves
    /// the change gate: a volume/connection-only refresh must leave this
    /// unchanged, a group rename must bump it exactly once.
    public private(set) var test_groupRowsRebuildCount = 0

    /// Rebuild the membership rows for the shown device. `NSStackView`'s
    /// `removeArrangedSubview` alone leaves the view IN the hierarchy (it only
    /// stops arranging it), so every old row is removed from its superview too
    /// or the section quietly stacks up ghosts behind the live rows.
    private func rebuildGroupRows() {
        let memberGroups = shownDevice.map(groups(containing:)) ?? []
        // `refreshUI()` runs on every backend event for the app's whole
        // lifetime, and almost none of them touch this list — rebuilding a
        // fresh `NSButton` + `NSImage` per group each time threw away the rows
        // under the pointer several times a second during discovery. This is
        // exactly what a row renders, as one comparable value; an empty list
        // compares equal to empty, so the "Not in any group" row is stable too.
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
            // Rows FILL the section, so the chevron lands on the section's own
            // inset edge rather than at the end of the row's intrinsic width.
            row.widthAnchor.constraint(equalTo: groupsStack.widthAnchor).isActive = true
            row.heightAnchor.constraint(equalToConstant: Self.groupRowHeight).isActive = true
        }
        // Live views, so the section's inset hairlines draw between them.
        groupsWell.rows = rows
    }

    /// Gap held clear between a membership row's title button and its chevron,
    /// so a truncated name never crowds the glyph.
    private static let groupRowChevronGap: CGFloat = 8

    /// One membership row: the group's icon, its name, and a trailing chevron
    /// saying the row OPENS something.
    ///
    /// A borderless `NSButton`, deliberately — not a stack view with a click
    /// recognizer. Stock AppKit then gives the whole keyboard/accessibility
    /// story for free: Tab focus with a focus ring, Space/Return activation,
    /// `NSAccessibilityButton` role, and `accessibilityPerformPress()`. A
    /// gesture recognizer on a plain view has none of that and would have to
    /// hand-roll every one of them — the price `DeviceIconWellView` pays for
    /// being the one approved custom element.
    ///
    /// The button IS the row, full width and full height, with the chevron a
    /// click-through subview riding on it. That is not cosmetic: `NSButtonCell`
    /// only fires when the mouse-UP lands inside the button's own frame, so a
    /// button that stops short of the chevron leaves every click on the glyph
    /// (and on the gap before it) dead, however the hit test is routed. The
    /// title's clearance is therefore a CELL job, not a layout one —
    /// `GroupRowButtonCell` shortens `titleRect(forBounds:)` by the chevron's
    /// width plus the gap, so a long name ("Whole House Downstairs Speakers")
    /// truncates against the glyph instead of drawing under it.
    ///
    /// No hover fill: this pane's text colours are frozen and there is no
    /// approved hover chrome for it (`AGENTS.md`).
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
        // A long group name truncates; it never widens the pane (the same rule
        // the device name above it follows).
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Rides ON the button — the WHOLE row is the target, so the glyph must
        // never swallow a click meant for it (`hitTest` nil, the module's
        // documented non-interactive-chrome pattern).
        let chevron = ClickThroughImageView()
        chevron.translatesAutoresizingMaskIntoConstraints = false
        let chevronImage = DeviceIcon.image("chevron.right")
        chevron.image = chevronImage
        chevron.contentTintColor = Tokens.Color.label2
        cell.chevronReserve = (chevronImage?.size.width ?? 0) + Self.groupRowChevronGap
        button.addSubview(chevron)
        NSLayoutConstraint.activate([
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

        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    @objc private func groupRowClicked(_ sender: NSButton) {
        guard shownGroupIDs.indices.contains(sender.tag) else { return }
        onSelectGroup?(shownGroupIDs[sender.tag])
    }

    @objc private func resetTapped(_ sender: NSButton) {
        eqEditor.resetToFlat()
    }

    /// The editor's own rendered model IS the source of truth here — it
    /// already received `eqEdits[device.id]?.eq ?? device.eq`.
    private func refreshResetEnabled() {
        eqResetButton.isEnabled = !eqEditor.currentEQ.isFlat
    }

    /// Resolve and apply the icon for `shownDevice`: the controller's override
    /// when one is set and still valid on this OS, else the kind default —
    /// `DeviceIconController.symbolName(for:)` already does that fallback, so
    /// this only needs its own direct fallback for the no-controller-injected
    /// case.
    private func refreshIcon() {
        guard let device = shownDevice else { return }
        let name = deviceIconController?.symbolName(for: device) ?? device.kind.symbolName
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
        let defaultName = device?.kind.symbolName ?? ""
        let currentOverride = device.flatMap { deviceIconController?.overrides[$0.id] }

        let picker = IconPickerViewController()
        picker.configure(currentSymbolName: currentOverride, defaultSymbolName: defaultName)
        picker.onPick = { [weak self] name in
            self?.pickIcon(name)
        }
        test_picker = picker

        if iconWell.window != nil {
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

    /// The About list's current visible text, keyed by field (not by its
    /// on-screen caption, so a future copy change doesn't reshape this API).
    /// "airplay" is ABSENT, not empty, when the row is dropped — Bluetooth and
    /// This Mac are not AirPlay receivers, so the question has no answer
    /// rather than a blank one.
    public var test_metadataStrings: [String: String] {
        var strings = [
            "status": statusValueLabel.stringValue,
            "kind": kindValueLabel.stringValue,
        ]
        if !airPlayRow.isHidden { strings["airplay"] = airPlayValueLabel.stringValue }
        return strings
    }

    /// The shown device's membership as ONE comma-joined string ("None" when it
    /// belongs to no saved group) — the plain-string contract `window-harness`
    /// check [9] and the suites assert against, off the same source and order
    /// the section's rows render.
    public var test_groupMembershipText: String {
        guard let device = shownDevice else { return "" }
        let names = groups(containing: device).map(\.name)
        return names.isEmpty ? "None" : names.joined(separator: ", ")
    }

    /// The membership section's title label.
    public var test_groupsSectionTitleText: String { groupsTitleLabel.stringValue }

    /// What the membership section's rows READ, top to bottom: one entry per
    /// saved group the device belongs to, or the single non-clickable
    /// "Not in any group" row when it belongs to none.
    public var test_groupRowTitles: [String] {
        groupsStack.arrangedSubviews.map { row in
            if let button = Self.groupRowButton(in: row) { return button.title }
            return (row.subviews.compactMap { $0 as? NSTextField }.first?.stringValue) ?? ""
        }
    }

    /// The title button inside a membership row container, or `nil` for the
    /// non-clickable empty-state row.
    private static func groupRowButton(in row: NSView) -> NSButton? {
        row as? NSButton
    }

    /// Where each row's TITLE is actually drawn, in the pane's own coordinates
    /// — the cell's own answer, so the chevron clearance is measured rather
    /// than assumed from the button's frame (the button spans the whole row).
    public var test_groupRowTitleRects: [NSRect] {
        view.layoutSubtreeIfNeeded()
        return groupsStack.arrangedSubviews.compactMap { row in
            guard let button = Self.groupRowButton(in: row), let cell = button.cell else { return nil }
            return button.convert(cell.titleRect(forBounds: button.bounds), to: view)
        }
    }

    /// The gap a membership row holds clear between its title button and its
    /// chevron — read rather than hard-coded, so the geometry assertions can
    /// never pin a number the row no longer uses.
    public static var test_groupRowChevronGap: CGFloat { groupRowChevronGap }

    /// Each membership row's title BUTTON frame, in the pane's own
    /// coordinates, top to bottom.
    public var test_groupRowButtonFrames: [NSRect] {
        view.layoutSubtreeIfNeeded()
        return groupsStack.arrangedSubviews.compactMap { row in
            Self.groupRowButton(in: row).map { $0.convert($0.bounds, to: view) }
        }
    }

    /// Each membership row's trailing CHEVRON frame, in the pane's own
    /// coordinates, top to bottom — paired index-for-index with
    /// `test_groupRowButtonFrames`, so a long name can be shown to truncate
    /// rather than run under the glyph.
    public var test_groupRowChevronFrames: [NSRect] {
        view.layoutSubtreeIfNeeded()
        return groupsStack.arrangedSubviews.compactMap { row in
            row.subviews.compactMap { $0 as? NSImageView }.first
                .map { $0.convert($0.bounds, to: view) }
        }
    }

    /// Activate the membership row at `index` exactly as a click (or Space/
    /// Return on the focused row) does — no synthesized clicks headless
    /// (`../AGENTS.md`). No-op for an out-of-range index or the empty-state row.
    public func test_selectGroupRow(at index: Int) {
        let rows = groupsStack.arrangedSubviews
        guard rows.indices.contains(index),
              let button = Self.groupRowButton(in: rows[index]) else { return }
        groupRowClicked(button)
    }

    /// The symbol name currently rendered by the icon well.
    public var test_iconSymbolName: String? {
        guard let device = shownDevice else { return nil }
        return deviceIconController?.symbolName(for: device) ?? device.kind.symbolName
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

    /// Leading inset of the About rows, measured from their list's own edge.
    /// This pane draws NO rail, so its rows use the tighter
    /// `railFreeContentLeadingInset` rather than reserving the spine's lane —
    /// its HEADER still uses the full inset so the icon + name stay pinned to
    /// the group editor's (design review 2026-07-25).
    public var test_metadataRowInset: CGFloat {
        view.layoutSubtreeIfNeeded()
        let row = aboutStack.convert(aboutStack.bounds, to: view)
        let section = aboutWell.convert(aboutWell.bounds, to: view)
        return row.minX - section.minX
    }

    /// The VISIBLE slot titles, in page order — the page's shape as words
    /// ("Equalizer", "Groups", "About"; This Mac drops the first).
    public var test_slotTitles: [String] {
        [eqTitleLabel, groupsTitleLabel, aboutTitleLabel]
            .filter { !$0.isHidden }
            .map(\.stringValue)
    }

    /// Every VISIBLE `.card` OR `.well` section's frame in the pane's own
    /// coordinates, in subview order — both are "box" instruments, as
    /// opposed to `.panel`/`.bare`. There is exactly one on a speaker (the
    /// Equalizer, a `.well` since 2026-09-04) and none on This Mac: a box is
    /// earned by holding a different instrument, never by length. Walked
    /// RECURSIVELY — the column sits inside a scroll view, so the sections
    /// are several levels down rather than two.
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

    /// False for This Mac, where the whole Equalizer section is hidden.
    public var test_eqSectionShown: Bool { !eqWell.isHidden }

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

    /// The device NAME's own trailing edge vs the value column's, so a test can
    /// assert the metadata values really right-align into the section instead
    /// of hanging off a fixed caption width.
    public var test_valueTrailingX: CGFloat {
        view.layoutSubtreeIfNeeded()
        return statusValueLabel.convert(statusValueLabel.bounds, to: view).maxX
    }

    /// The About list's laid-out frame in the pane's own coordinates.
    public var test_aboutSectionFrame: NSRect {
        view.layoutSubtreeIfNeeded()
        return aboutWell.convert(aboutWell.bounds, to: view)
    }

    /// The "About" TITLE label's laid-out frame in the pane's own coordinates
    /// — it must sit between the Groups list and the About list it titles,
    /// never inside either.
    public var test_aboutSectionTitleFrame: NSRect {
        view.layoutSubtreeIfNeeded()
        return aboutTitleLabel.convert(aboutTitleLabel.bounds, to: view)
    }

    /// The Groups list's laid-out frame in the pane's own coordinates.
    public var test_groupsSectionFrame: NSRect {
        view.layoutSubtreeIfNeeded()
        return groupsWell.convert(groupsWell.bounds, to: view)
    }

    /// The "Groups" TITLE label's laid-out frame in the pane's own coordinates
    /// — it must sit between whatever precedes it (the Equalizer card, or the
    /// identity band on This Mac) and the list it titles, never inside either.
    public var test_groupsSectionTitleFrame: NSRect {
        view.layoutSubtreeIfNeeded()
        return groupsTitleLabel.convert(groupsTitleLabel.bounds, to: view)
    }

    /// The Equalizer section's laid-out frame in the pane's own coordinates.
    public var test_eqSectionFrame: NSRect {
        view.layoutSubtreeIfNeeded()
        return eqWell.convert(eqWell.bounds, to: view)
    }

    /// The Equalizer EDITOR's own laid-out frame (inside the card), in the
    /// pane's own coordinates — lets a test measure the card's inner inset
    /// against `test_eqSectionFrame` directly.
    public var test_eqEditorFrame: NSRect {
        view.layoutSubtreeIfNeeded()
        return eqEditor.convert(eqEditor.bounds, to: view)
    }

    /// The Equalizer section title's visible text, `nil` when hidden (This
    /// Mac) — mirrors `test_eqSectionShown` rather than a bare `Bool` so a
    /// test can also assert the copy itself.
    public var test_eqSectionTitleText: String? {
        eqTitleLabel.isHidden ? nil : eqTitleLabel.stringValue
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

    /// How many of the "Groups" title's two alternative top pins are active —
    /// must be exactly 1 from the moment the view loads. Zero leaves the
    /// column's height ambiguous and collapses the scroll document; two
    /// conflict.
    public var test_activeGroupsTitlePinCount: Int {
        [groupsTitleBelowEQCard, groupsTitleBelowHeader].filter { $0?.isActive == true }.count
    }

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
        guard let id = shownDevice?.id else { return }
        // Set BEFORE forwarding: `onSetEQ` can fan a snapshot straight back,
        // and until it matches this exact value the snapshot must not win.
        eqEdits[id] = (eq, committed)
        onSetEQ?(eq, id, committed)
        refreshResetEnabled()
        if committed { Analytics.capture("eq:adjusted", ["target": "device"]) }
    }

    public func eqEditorDidRequestReset(_ editor: EQEditorView) {
        guard let id = shownDevice?.id else { return }
        // One committed action, not ten: the editor has already put its own
        // controls back to flat.
        eqEdits[id] = (.flat, true)
        onSetEQ?(.flat, id, true)
        refreshResetEnabled()
        Analytics.capture("eq:reset", ["target": "device"])
    }
}

/// The membership row's trailing chevron: pure signal, never a click target.
/// It sits ON the row button, so without this the trailing strip of every row
/// would refuse the click the rest of the row accepts. Same `hitTest`-nil
/// pattern as `HairlineView`/`GroupedSectionView`; no `draw(_:)` of its own.
private final class ClickThroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The membership row button's cell, which does exactly one thing: hold the
/// trailing chevron's width clear of the title. The button spans the WHOLE row
/// (it has to — `NSButtonCell` fires only on a mouse-up inside its own frame),
/// so without this the title would measure itself against the full width and a
/// long group name would draw straight under the glyph.
private final class GroupRowButtonCell: NSButtonCell {

    /// Width kept clear at the trailing edge: the chevron plus the gap before
    /// it. Set once, when the chevron's image is made.
    var chevronReserve: CGFloat = 0

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        var r = super.titleRect(forBounds: rect)
        r.size.width = max(0, r.maxX - chevronReserve - r.minX)
        return r
    }
}

/// A flipped document view so the form scrolls from the TOP rather than
/// bottom-gravitating with dead space above the header. File-scoped on purpose
/// (`GroupCreationSheetController` keeps its own for the same reason).
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
