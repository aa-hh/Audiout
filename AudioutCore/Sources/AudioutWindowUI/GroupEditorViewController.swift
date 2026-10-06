// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore
import AudioutSharedUI

/// A scene page with an icon well and identity glow, editable name and speaker count.
/// Below the header, a Speakers heading introduces one card of membership rows.
/// The Delete band sits beside the saved-as-you-go note; edits write through GroupController.
/// The page provides no exit controls.
public final class GroupEditorViewController: NSViewController {

    private let groupController: GroupController

    /// Resolves/persists per-device icon overrides for `MembershipRowView`
    /// rows. Optional and nil-tolerant (`../../AGENTS.md`'s "depends on the
    /// model, never the reverse" — a host without one still renders default
    /// device glyphs, just no per-device overrides).
    public var deviceIconController: DeviceIconController?

    /// Called after a rename or membership change persisted (refresh sidebar +
    /// toolbar labels in place).
    public var onDidEditGroup: (() -> Void)?
    /// Called after deletion so the host selects another scene or the empty page.
    public var onDidDeleteGroup: (() -> Void)?
    /// The group currently being edited, nil before `show`.
    public private(set) var editingGroupID: String?

    private let iconWell = DeviceIconWellView()
    /// The group's identity light, mounted behind the well.
    private let iconGlow = GroupIdentityGlowView()
    private let nameField = NSTextField(string: "")
    private let countLabel: RollingCountLabel = {
        let label = RollingCountLabel(labelWithString: "")
        label.font = Tokens.Font.captionDigits
        label.textColor = Tokens.Color.labelCool
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }()
    private lazy var header = PageHeaderView(iconWell: iconWell, title: nameField, caption: countLabel)
    private let membershipStack = WellRepaintingStackView()
    /// THIS PAGE'S ONE INSTRUMENT, so it is the one `.card` here — a `raised`
    /// fill with a `containerEdge` edge behind the Speakers checklist, plus
    /// the inter-row rules in the same tone. Sits BEHIND `membershipStack` in
    /// z-order.
    /// NAME IS LOAD-BEARING: `GroupsInkTemperatureTests` reaches this stored
    /// property by reflection (the type is internal, the property is private)
    /// to sample the real drawn fill/divider colours.
    private let membershipWell = GroupedSectionView()
    private let deleteButton = NSButton()
    /// The pane's scroll view (roadmap 039) — see the note in ``loadView()``.
    /// Held so the `test_*` seams can measure the document without walking the
    /// view tree.
    private var scrollView: NSScrollView?

    private let reassuranceLabel: NSTextField = {
        let label = NSTextField(wrappingLabelWithString: GroupEditorViewController.savedAsYouGo)
        label.font = Tokens.Font.caption
        label.textColor = Tokens.Color.label2
        label.isSelectable = false
        label.maximumNumberOfLines = 0
        // It WRAPS into whatever the button leaves rather than pushing the
        // button's own required geometry around.
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }()

    /// Floor for the rename field's width. An editable `NSTextField` has NO
    /// intrinsic width, so without this a field whose width is otherwise driven
    /// by its (measured) content can be squeezed to nothing — it rendered
    /// invisible once already (snapshot-caught 2026-07-18). REQUIRED priority,
    /// deliberately: the field may overflow its section by a hair on a
    /// pathologically narrow pane rather than vanish.
    /// The identity glow's mounted side: the 48 pt opaque well plus 16, so 8
    /// pt of magenta leaks past the well's edge all round. A glow no wider
    /// than the well would sit wholly under it and never be seen.
    static let iconGlowSide: CGFloat = DeviceIconWellView.size + 16

    private static let titleFieldMinWidth: CGFloat = 140

    private static let savedAsYouGo = "Changes are saved as you go."

    private static func speakerCount(_ n: Int) -> String {
        n == 1 ? "1 speaker" : "\(n) speakers"
    }
    /// The rename field's live width, recomputed from the name it holds
    /// (an editable field has no intrinsic width to hug with, so the hug is
    /// measured by hand). Optional, not required, so the "never wider than its
    /// section" cap wins for a long name and the min-width floor wins for a
    /// short one.
    private var nameFieldWidth: NSLayoutConstraint?

    /// The pointer-hover tracking area over the rename field. The field itself
    /// stays a STOCK `NSTextField` (the skin is a cell — `WarmNameFieldCell`),
    /// so the tracking area is owned here rather than by an `NSTextField`
    /// subclass; `mouseEntered`/`mouseExited` below are its callbacks.
    private var nameFieldTracking: NSTrackingArea?

    /// Kept alive across a picker session so it can be dismissed/replaced;
    /// nil when no picker is currently presented.
    private var iconPickerPopover: NSPopover?

    /// The symbol name last resolved into the icon well's image (mirrors
    /// `iconWellButton.image`, but as the plain string a test can assert
    /// against without relying on `NSImage`'s internal name-tracking).
    private var iconWellSymbolName: String?

    /// Membership rows keyed by device id, so a test can read/drive them.
    public var speakerLibrary: SpeakerLibraryController?
    private var presentationByID: [String: SpeakerPresentationRecord] = [:]
    private var rowsByID: [String: MembershipRowView] = [:]
    /// The devices currently offered as membership candidates, in order:
    /// every device, unavailable ones included (see
    /// ``rebuildCandidates(memberSet:)``).
    private var candidateDevices: [Device] = []
    /// The full device set last passed to `show`, so membership toggles can
    /// rebuild the candidate list.
    private var allDevices: [Device] = []

    public init(groupController: GroupController) {
        self.groupController = groupController
        super.init(nibName: nil, bundle: nil)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func loadView() {
        iconWell.setAccessibilityLabel("Edit scene icon")
        iconWell.onClick = { [weak self] in
            guard let self else { return }
            self.presentIconPicker(anchoredTo: self.iconWell)
        }

        // The inline rename field. STILL A REAL `NSTextField` — first
        // responder, field editor, Return/Escape, selection and VoiceOver all
        // stock; only the DRAWING is ours. The cell swap happens FIRST, before
        // any configuration, so the settings below land on the new cell (the
        // same ordering `MembershipRowView` uses for `InvisibleSwitchCell` and
        // `DeviceRowView` for `WarmFaderCell`).
        // `textCell:`, NOT the bare zero-arg initializer: a plain
        // `WarmNameFieldCell()` defaults its `stringValue` to AppKit's own
        // `NSCell` placeholder ("Field") — invisible as long as `loadView()`
        // runs before `show()` ever sets a real name, but `showEditor(for:)`
        // calls `show()` BEFORE `swapContent(to:)` embeds this controller's
        // view for the first time, so `loadView()` (and this cell swap) can
        // run AFTER `show()` already wrote the group's real name — silently
        // discarding it back to the AppKit default (caught 2026-07-26: every
        // rename-field test that compared against the LITERAL name passed
        // fine on its own, but the two that hardcoded "Downstairs" exposed
        // the mismatch). Carrying the field's current text into the new cell
        // makes the swap correct regardless of which runs first.
        nameField.cell = WarmNameFieldCell(textCell: nameField.stringValue)
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.placeholderString = "Scene name"
        nameField.font = Tokens.Font.heading
        nameField.textColor = Tokens.Color.label
        nameField.alignment = .natural   // left-aligned (LTR) to match the column
        nameField.isEditable = true
        nameField.isSelectable = true
        // Bezel-less/background-less: `WarmNameFieldCell` paints the fill and
        // border itself so both re-resolve per appearance on every paint
        // (a bezel would also draw its text visibly off-centre — live-test
        // feedback 2026-07-18).
        nameField.isBordered = false
        nameField.isBezeled = false
        nameField.drawsBackground = false
        nameField.usesSingleLineMode = true
        nameField.lineBreakMode = .byTruncatingTail
        nameField.setAccessibilityLabel("Scene name")
        nameField.target = self
        nameField.action = #selector(nameCommitted(_:))
        nameField.delegate = self
        // Hover is a neutral wash + a pencil step-up, never a geometry change
        // (R7). Owned here because the field is stock — see `nameFieldTracking`.
        let tracking = NSTrackingArea(rect: .zero,
                                      options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                      owner: self, userInfo: nil)
        nameField.addTrackingArea(tracking)
        nameFieldTracking = tracking

        reassuranceLabel.translatesAutoresizingMaskIntoConstraints = false

        let speakersLabel = NSTextField(labelWithString: "Speakers")
        speakersLabel.translatesAutoresizingMaskIntoConstraints = false
        speakersLabel.textColor = Tokens.Color.label2
        speakersLabel.setAccessibilityHeading()

        membershipStack.translatesAutoresizingMaskIntoConstraints = false
        membershipStack.orientation = .vertical
        membershipStack.alignment = .leading
        membershipStack.spacing = 6

        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        deleteButton.title = "Delete scene…"
        deleteButton.bezelStyle = .rounded
        deleteButton.target = self
        deleteButton.action = #selector(deleteTapped(_:))
        deleteButton.hasDestructiveAction = true

        let container = WellRepaintingView()
        container.membershipWell = membershipWell
        membershipStack.membershipWell = membershipWell
        // The form column: symmetric margins off the pane, ELASTIC up to
        // `GroupsPaneLayout.contentMaxWidth`. Everything hangs off this
        // column's edges rather than the container's.
        let column = NSView()
        column.translatesAutoresizingMaskIntoConstraints = false

        // Added FIRST so it sits behind every row (T5: a recessed background +
        // hairline dividers behind the checklist, which otherwise carries no
        // surface at all — measured ~1.06:1 dark / ~1.08:1 light against
        // `panel`, an invisible boundary). Non-interactive (`hitTest` always
        // nil), so it never intercepts a row's click.
        // The section spans the column's full width (rail gutter included), so
        // its dividers inset by the same gutter reserve every child uses.
        membershipWell.translatesAutoresizingMaskIntoConstraints = false
        membershipWell.radiusOverride = Tokens.Layout.Radius.row
        membershipWell.contentLeadingInset = GroupsPaneLayout.contentLeadingInset
        column.addSubview(membershipWell)
        // Below the rename field's 240 width preference, so the count caption
        // never pulls the field towards its own width.
        header.textStack.setHuggingPriority(NSLayoutConstraint.Priority(230), for: .horizontal)
        // The identity light sits behind the well it belongs to.
        iconGlow.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(iconGlow, positioned: .below, relativeTo: iconWell)
        for v in [header, speakersLabel, membershipStack] {
            v.translatesAutoresizingMaskIntoConstraints = false
            column.addSubview(v)
        }
        // The pane SCROLLS (roadmap 039, `../AGENTS.md`): the surface frame is
        // FIXED, so a fleet the editor cannot fit used to have to be paid for by
        // raising `AppSurfaceController.minimumContentSize`. It now overflows
        // into the scroller instead. Same recipe as `DeviceDetailViewController`
        // — overlay scrollers + no background so the pane still reads as one
        // warm surface, and a FLIPPED document so the form starts at the TOP
        // rather than bottom-gravitating.
        //
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        for v in [column, deleteButton, reassuranceLabel] {
            document.addSubview(v)
        }
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = document
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        container.addSubview(scrollView)
        self.scrollView = scrollView

        // The column STRETCHES with the pane: this pushes it out to the
        // trailing margin, the required `<=` cap stops it at
        // `contentMaxWidth`, and the required `<=` margin keeps it inside the
        // pane at any width. Without this fill the sections hugged their
        // ~277 pt intrinsic content and left a dead strip beside them.
        let columnFill = column.trailingAnchor.constraint(
            equalTo: document.trailingAnchor, constant: -GroupsPaneLayout.columnTrailingInset)
        columnFill.priority = .defaultHigh

        // The rename field HUGS its name — measured by hand, since an editable
        // `NSTextField` has no intrinsic width to hug with (see
        // ``updateNameFieldWidth()``). Optional, so the cap below wins for a
        // long name and the required floor wins for a short one.
        //
        // PRIORITY IS LOAD-BEARING: below `.defaultLow`, which is where the
        // split view holds its divider. At `.defaultHigh` a long group name was
        // satisfied by growing the whole content pane — the split view happily
        // squeezed the sidebar past its own minimum thickness to give the field
        // the width it asked for. A preference this weak can never move the
        // window's furniture; it only fills space the pane already has.
        let titleWidth = nameField.widthAnchor.constraint(
            equalToConstant: Self.titleFieldMinWidth)
        titleWidth.priority = NSLayoutConstraint.Priority(240)
        nameFieldWidth = titleWidth
        // …and `PageHeaderView` keeps it inside the band.

        // The reassurance line takes whatever "Delete scene…" leaves of the
        // row, wrapping into it — an EQUALITY, because a wrapping label needs a
        // definite width to wrap inside. 999 rather than required so a
        // pathologically narrow pane breaks THIS rather than the button's own
        // required geometry.
        let reassuranceTrailing = reassuranceLabel.trailingAnchor.constraint(
            equalTo: column.trailingAnchor, constant: -GroupsPaneLayout.contentTrailingInset)
        reassuranceTrailing.priority = NSLayoutConstraint.Priority(999)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            // The document is exactly as wide as the pane and as tall as its
            // content needs — vertical scrolling only, never horizontal.
            document.widthAnchor.constraint(equalTo: scrollView.widthAnchor),

            column.topAnchor.constraint(equalTo: document.topAnchor,
                                        constant: GroupsPaneLayout.columnTopInset),
            // SYMMETRIC margins (design review 2026-07-25). The column used to
            // start at the pane's own leading edge, with the whole left margin
            // living inside `contentLeadingInset` — which put the bordered
            // sections flush against the window edge on one side only.
            column.leadingAnchor.constraint(equalTo: document.leadingAnchor,
                                            constant: GroupsPaneLayout.columnInset),
            column.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor,
                                             constant: -GroupsPaneLayout.columnTrailingInset),
            column.widthAnchor.constraint(lessThanOrEqualToConstant: GroupsPaneLayout.contentMaxWidth),
            columnFill,

            // HEADER, SIDE BY SIDE (design review 2026-07-25): icon BESIDE the
            // name, not above it — 30 pt of reclaimed height on a pane that was
            // overflowing its own window. Header parity with
            // `DeviceDetailViewController` is the shared band height and
            // vertical centring, both read from `GroupsPaneLayout`. The icon
            // shares the other pages' content inset.
            header.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            header.topAnchor.constraint(equalTo: column.topAnchor),

            iconGlow.centerXAnchor.constraint(equalTo: iconWell.centerXAnchor),
            iconGlow.centerYAnchor.constraint(equalTo: iconWell.centerYAnchor),
            iconGlow.widthAnchor.constraint(equalToConstant: Self.iconGlowSide),
            iconGlow.heightAnchor.constraint(equalToConstant: Self.iconGlowSide),

            nameField.heightAnchor.constraint(equalToConstant: PopoverColumnGrid.titleFieldHeight),
            // REQUIRED floor: an editable text field has no intrinsic width, so
            // without this auto layout is free to collapse it to zero (it
            // rendered invisible — snapshot-caught 2026-07-18).
            nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.titleFieldMinWidth),
            titleWidth,

            // Sits BETWEEN the two sections, on bare pane — the gap below the
            // header section's bottom border, above the list section's top.
            speakersLabel.topAnchor.constraint(equalTo: header.bottomAnchor,
                                               constant: GroupsPaneLayout.sectionGap),
            speakersLabel.leadingAnchor.constraint(equalTo: column.leadingAnchor,
                                                   constant: GroupsPaneLayout.railFreeContentLeadingInset),

            // The ROWS, uniquely, start at the column's own leading edge: each
            // row applies `contentLeadingInset` internally to its icon and
            // places its node in the gutter, so row icons still line up with
            // the header content above them. They FILL the section's width
            // (`buildRows` pins each row to the stack) so a row's trailing
            // annotation lands at the section's own inset edge instead of
            // wherever the widest device name happens to end.
            // The container extends `verticalPadding` ABOVE the first row, so
            // the VISIBLE gap from the "Speakers" label to the container's top
            // border is `labelToSectionGap` and this constraint carries the
            // padding on top of it.
            membershipStack.topAnchor.constraint(
                equalTo: speakersLabel.bottomAnchor,
                constant: GroupsPaneLayout.labelToSectionGap + GroupedSectionView.verticalPadding),
            membershipStack.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            membershipStack.trailingAnchor.constraint(
                equalTo: column.trailingAnchor, constant: -GroupsPaneLayout.contentTrailingInset),
            membershipStack.bottomAnchor.constraint(equalTo: column.bottomAnchor),

            // The membership card spans the column, with its nodes inside.
            // Padding separates the first and last rows from the card's edge.
            membershipWell.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            membershipWell.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            membershipWell.topAnchor.constraint(equalTo: membershipStack.topAnchor,
                                                constant: -GroupedSectionView.verticalPadding),
            membershipWell.bottomAnchor.constraint(equalTo: membershipStack.bottomAnchor,
                                                   constant: GroupedSectionView.verticalPadding),

            // ANCHORING TRAP: anchored to the COLUMN, not the container. It
            // used to hang off the container's leading edge, which was the
            // same x only while the column started there too — the moment the
            // column took its own margin the button drifted 14 pt left of
            // everything it belongs under.
            deleteButton.leadingAnchor.constraint(equalTo: column.leadingAnchor,
                                                  constant: GroupsPaneLayout.railFreeContentLeadingInset),
            // The grouped-list container extends `verticalPadding` BELOW the
            // last row, so the VISIBLE gap between its bottom border and the
            // button is `actionBandGap` — wider than the gap between sections,
            // so the destructive action reads as its own band.
            deleteButton.topAnchor.constraint(
                equalTo: column.bottomAnchor,
                constant: GroupsPaneLayout.actionBandGap + GroupedSectionView.verticalPadding),
            // `==` against the DOCUMENT (roadmap 039). It used to be `<=`
            // against the pane, because pinning the button to the PANE's bottom
            // made the whole chain above it stretch to reach — the column grew,
            // the row stack (pinned to the column's bottom) grew with it, and
            // the section's bottom padding silently absorbed every spare point
            // of pane height (49.5pt below the last divider against 36.5pt
            // above the first — design review 2026-07-25). A scroll document
            // has no spare height to absorb: it HUGS its content, so this
            // equality is what gives the document its bottom edge, and the
            // slack — when the pane is taller than the content — falls below
            // the document inside the clip view, where nothing is drawn.
            deleteButton.bottomAnchor.constraint(equalTo: document.bottomAnchor,
                                                 constant: -GroupsPaneLayout.paneBottomInset),

            // Beside "Delete scene…", centred on it, with NO bottom pin: the
            // line's overhang rides inside the `paneBottomInset` margin above,
            // so the pane's fitting height is unchanged (see ``reassuranceLabel``).
            reassuranceLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: deleteButton.trailingAnchor, constant: 16),
            reassuranceLabel.centerYAnchor.constraint(equalTo: deleteButton.centerYAnchor),
            reassuranceTrailing,

        ])

        view = container
    }

    // MARK: Model

    /// Show the editor for `groupID`, building the membership row list from
    /// the speaker library's records: every speaker it keeps, unavailable and
    /// remembered ones included. `devices` stands in only when no library is
    /// injected. No-op if the group no longer exists.
    ///
    /// GATED on what the pane actually draws. The host calls this on EVERY
    /// backend event while the screen is visible, and a re-render tears down
    /// and rebuilds every membership row — which threw away clicks, hover and
    /// keyboard focus several times a second during discovery. An unchanged
    /// ``EditorProjection`` means there is nothing to repaint.
    public func show(groupID: String, devices: [Device]) {
        let records: [SpeakerPresentationRecord]
        if let speakerLibrary { records = speakerLibrary.records }
        else {
            let library = SpeakerLibraryController(loadPersisted: false)
            library.update(liveDevices: devices, groups: groupController.groups)
            records = library.records
        }
        presentationByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        let renderedDevices = records.map(\.renderingDevice)
        let devices = renderedDevices.filter(\.isLocalDevice) + renderedDevices.filter { !$0.isLocalDevice }
        guard let group = groupController.groups.first(where: { $0.id == groupID }) else { return }
        guard editorProjection(for: group, devices: devices) != lastRenderedProjection else {
            // Nothing to repaint, but a later membership toggle
            // (`membershipToggled`) reads `allDevices`/`candidateDevices` to
            // persist a device's CURRENT volume — a volume-only change is
            // correctly invisible to `EditorProjection` (nothing this pane
            // draws shows a volume), but leaving those two stale here let a
            // subsequent check-in persist a volume from before this event.
            // Re-derive them from the fresh snapshot without touching the
            // rows: only the render path may rebuild those.
            allDevices = devices
            candidateDevices = devices
            return
        }
        render(group: group, devices: devices)
    }

    /// Paint the pane from `group` + `devices`, unconditionally. The single
    /// writer of ``lastRenderedProjection`` (recomputed at the end, so a
    /// failure re-render always re-syncs the gate).
    private func render(group: Group, devices: [Device]) {
        // Read BEFORE `editingGroupID` moves: the typing guard below is scoped
        // to the SAME group, and switching the pane to a different group must
        // re-fill the field, or it would show the previous group's half-typed
        // name (a phone-driven edit can force exactly that switch).
        let switchedGroup = editingGroupID != group.id
        editingGroupID = group.id
        allDevices = devices

        // NEVER overwrite a name being typed. The host's refresh arrives on
        // every backend event, and writing `stringValue` while the field
        // editor is up replaced the user's half-typed name mid-keystroke.
        // Everything else below still runs.
        if nameField.currentEditor() == nil || switchedGroup {
            nameField.stringValue = group.name
            updateNameFieldWidth()
        }
        refreshIconWell(group: group)
        let count = Self.speakerCount(group.memberIDs.count)
        if switchedGroup {
            countLabel.test_settleNow()
            countLabel.stringValue = count
        } else {
            countLabel.roll(to: count)
        }
        rebuildCandidates(memberSet: Set(group.memberIDs))
        lastRenderedProjection = editorProjection(for: group, devices: devices)
        test_renderCount += 1
    }

    /// Exactly what this pane draws, as one Equatable value — the gate
    /// ``show(groupID:devices:)`` compares. Not a diffing framework: one
    /// struct, one equality check (the same shape `MixerWindowController`
    /// already uses for the sidebar). It may only err toward RENDERING: a
    /// stale projection costs a repaint, a too-clever one drops a real change.
    private struct EditorProjection: Equatable {
        struct Row: Equatable {
            let id: String
            let name: String
            let isAvailable: Bool
            let symbolName: String
            let isMember: Bool
            let status: SpeakerPresentationStatus?
        }
        let groupID: String
        let groupName: String
        let iconSymbolName: String
        let rows: [Row]
    }

    /// The projection the pane's current contents were rendered from.
    private var lastRenderedProjection: EditorProjection?

    private func editorProjection(for group: Group, devices: [Device]) -> EditorProjection {
        let memberSet = Set(group.memberIDs)
        // Every device is a candidate, unavailable ones included (owner's
        // call, 2026-08-28) — same rule as `rebuildCandidates(memberSet:)` and
        // the creation sheet. Rows for unavailable devices render dimmed.
        let candidates = devices
        return EditorProjection(
            groupID: group.id,
            groupName: group.name,
            iconSymbolName: DeviceIcon.resolve(group.iconSymbolName,
                                               default: Group.defaultIconSymbolName),
            rows: candidates.map { device in
                EditorProjection.Row(
                    id: device.id,
                    name: device.name,
                    isAvailable: device.isAvailable,
                    symbolName: deviceIconController?.symbolName(for: device)
                        ?? device.kind.symbolName,
                    isMember: memberSet.contains(device.id),
                    status: presentationByID[device.id]?.status)
            })
    }

    /// Refresh the header icon's image from `group.iconSymbolName`, resolved
    /// through `DeviceIcon.resolve` so a stale/unrecognized override still
    /// renders the default rather than a blank glyph.
    private func refreshIconWell(group: Group) {
        let symbolName = DeviceIcon.resolve(group.iconSymbolName, default: Group.defaultIconSymbolName)
        iconWellSymbolName = symbolName
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Scene icon")
        image?.isTemplate = true
        iconWell.iconImageView.image = image
    }

    /// Recompute `candidateDevices` from `allDevices` — every device, an
    /// unavailable one offered whether or not it is a member — and rebuild
    /// the membership rows from that list. Called on `show` and after every
    /// membership toggle.
    ///
    /// REUSES the existing rows whenever the candidate ID SEQUENCE is
    /// unchanged — only the list's membership/labels moved, so refreshing each
    /// row in place keeps the very view instances the pointer, the keyboard
    /// focus and any in-flight click are attached to. A changed sequence (a
    /// device appeared or vanished) still falls through to the full rebuild.
    private func rebuildCandidates(memberSet: Set<String>) {
        // Every device, unavailable ones included (owner's call, 2026-08-28).
        let newCandidates = allDevices
        guard newCandidates.map(\.id) == candidateDevices.map(\.id), !rowsByID.isEmpty else {
            candidateDevices = newCandidates
            buildRows(memberSet: memberSet)
            return
        }
        candidateDevices = newCandidates
        for device in newCandidates {
            guard let row = rowsByID[device.id] else { continue }
            row.apply(device: device,
                      checked: memberSet.contains(device.id),
                      iconSymbolName: deviceIconController?.symbolName(for: device))
            row.applyPresentation(presentationByID[device.id])
            // `apply` re-enables the checkbox but doesn't know about the sole-
            // member pin, so a formerly-pinned row that gained company here
            // (still `apply`'s job, not this loop's) kept its stale "A group
            // needs at least one device…" tooltip/VoiceOver help forever.
            // Clear it for every row; `pinSoleMember` below re-pins the
            // current sole member, if there still is one.
            row.setCheckboxEnabled(true, tooltip: nil)
        }
        // `apply` re-enables the checkbox (visibility policy is the host's
        // job), so the pinning has to run AFTER it, exactly as in `buildRows`.
        pinSoleMember(memberSet: memberSet)
        membershipWell.rows = candidateDevices.compactMap { rowsByID[$0.id] }
    }

    /// Pin the sole remaining member: a group needs at least one device, so
    /// its last member can't be unchecked here (delete the group instead).
    /// Only one member → that row's checkbox is disabled with an explanation.
    private func pinSoleMember(memberSet: Set<String>) {
        guard memberSet.count == 1, let onlyMemberID = memberSet.first else { return }
        rowsByID[onlyMemberID]?.setCheckboxEnabled(
            false, tooltip: "A scene needs at least one speaker. Use \u{201C}Delete scene\u{2026}\u{201D} to remove it.")
    }

    /// (Re)build the membership row list, checking members of `memberSet`.
    private func buildRows(memberSet: Set<String>) {
        for v in membershipStack.arrangedSubviews { membershipStack.removeArrangedSubview(v); v.removeFromSuperview() }
        rowsByID.removeAll()
        for device in candidateDevices {
            let row = MembershipRowView(
                device: device,
                checked: memberSet.contains(device.id),
                iconSymbolName: deviceIconController?.symbolName(for: device),
                surface: .warmPane)
            row.applyPresentation(presentationByID[device.id])
            row.onToggle = { [weak self] deviceID, isChecked in
                self?.membershipToggled(deviceID: deviceID, isChecked: isChecked)
            }
            rowsByID[device.id] = row
            membershipStack.addArrangedSubview(row)
            // Rows FILL the section (the stack is pinned to both of the
            // column's edges) instead of sizing to their own intrinsic width —
            // otherwise the trailing "Unavailable" annotation lands wherever
            // the widest device name happens to end, and the list reads as a
            // narrow strip inside a wide box.
            row.widthAnchor.constraint(equalTo: membershipStack.widthAnchor).isActive = true
        }
        pinSoleMember(memberSet: memberSet)
        // T5: re-point the well at the CURRENT rows so its hairlines land
        // between whatever's actually in the stack now (a rebuild can add or
        // drop rows — an unchecked unavailable device disappears).
        membershipWell.rows = candidateDevices.compactMap { rowsByID[$0.id] }
    }

    // MARK: Actions

    /// Save the active field editor before the host changes scenes.
    func finishRename() -> Bool {
        guard let fieldEditor = nameField.currentEditor() else { return true }
        nameField.stringValue = fieldEditor.string
        guard commitRename() else {
            restoreNameField()
            fieldEditor.string = nameField.stringValue
            return false
        }
        nameField.abortEditing()
        return true
    }

    @objc private func nameCommitted(_ sender: NSTextField) {
        commitRename()
    }

    /// The group being edited, or `nil` before `show` / after a delete.
    private var editingGroup: Group? {
        guard let editingGroupID else { return nil }
        return groupController.groups.first(where: { $0.id == editingGroupID })
    }

    /// Commit the field's current text as the group's name — driven by Return
    /// (the field's action) and by focus loss (`controlTextDidEndEditing`).
    ///
    /// EMPTIED: an all-whitespace name is refused, and the field is put BACK to
    /// the group's real name. It used to be refused silently, leaving a blank
    /// box on screen while the group still had its old name — the UI lied about
    /// what was saved.
    ///
    /// Returns whether the field and the model now AGREE — false only when the
    /// rename was refused with an explanation on screen (a name another group
    /// holds, or a failed save), which is the one case a caller must not leave
    /// the editor on.
    @discardableResult
    private func commitRename() -> Bool {
        guard var group = editingGroup else { return true }
        let trimmed = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { restoreNameField(); return true }
        guard trimmed != group.name else { restoreNameField(); return true }
        // TAKEN: two groups with the same name are two rows the sidebar can't
        // tell apart. Refused with an explanation rather than silently
        // suffixed — the same honesty the empty-name refusal above follows.
        // Case-insensitive, but excluding THIS group, so re-casing its own
        // name stays a legal rename.
        guard !isNameTaken(trimmed, excluding: group.id) else {
            restoreNameField()
            test_duplicateNameRefused = true
            presentDuplicateNameAlert(name: trimmed)
            return false
        }
        group.name = trimmed
        guard saveOrReport(group) else { return false }
        Analytics.capture("scene:renamed")
        nameField.stringValue = trimmed
        updateNameFieldWidth()
        onDidEditGroup?()
        return true
    }

    /// Persist `group`, REPORTING failure instead of swallowing it (the same
    /// "UI never lies" contract the empty-name rename fix established): on a
    /// throw the pane re-renders from the model — so no checkbox, name, or icon
    /// keeps claiming a state that never saved — and a plain-words alert names
    /// the problem. Returns whether the save took.
    @discardableResult
    private func saveOrReport(_ group: Group) -> Bool {
        do {
            try groupController.saveGroup(group)
            return true
        } catch {
            test_saveFailureReported = true
            // `render` DIRECTLY, not `show`: the projection gate would compare
            // equal (nothing in the model changed — that is the whole point of
            // a failed save) and skip the repaint that puts the controls back
            // to the truth.
            if let group = editingGroup { render(group: group, devices: allDevices) }
            Self.presentPersistFailureAlert(message: "Couldn\u{2019}t save the change.", over: view.window)
            return false
        }
    }

    /// Whether another group already carries `name` (case-insensitively).
    /// `excluding` is the group being renamed, so re-casing its own name is
    /// never a collision with itself.
    private func isNameTaken(_ name: String, excluding id: String?) -> Bool {
        groupController.groups.contains {
            $0.id != id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
    }

    /// The refusal for a name another group already has — same window-guarded
    /// shape as ``presentPersistFailureAlert(message:over:)``.
    private func presentDuplicateNameAlert(name: String) {
        guard let window = view.window, !HeadlessRuntime.isActive else { return }
        let alert = NSAlert()
        alert.messageText = "That name is already taken."
        alert.informativeText =
            "Another scene is named \u{201C}\(name)\u{201D}. Choose a different name."
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window)
    }

    /// The failure alert `saveOrReport`, the delete path and the host's
    /// Forget present — a sheet over `window`, skipped headless (the `test_*`
    /// seams observe the failure instead).
    static func presentPersistFailureAlert(message: String, over window: NSWindow?) {
        // A window is NOT a headless proxy — suites host these panes in a
        // real (ordered-out) window, so the gate has to be explicit.
        guard let window, !HeadlessRuntime.isActive else { return }
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = "The scene\u{2019}s saved settings couldn\u{2019}t be updated. Try again."
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window)
    }

    /// Put the field back to the group's persisted name and re-measure it —
    /// the shared tail of "you emptied it" and "you pressed Escape".
    private func restoreNameField() {
        guard let group = editingGroup else { return }
        if nameField.stringValue != group.name { nameField.stringValue = group.name }
        updateNameFieldWidth()
    }

    /// ESCAPE: discard the in-progress edit and hand focus back, exactly like a
    /// Finder rename. `abortEditing()` is what drops the field editor's pending
    /// text; the restore then guarantees the visible string matches the model
    /// even if the field was showing a half-typed name.
    ///
    /// Focus goes SOMEWHERE REAL. It used to go to `makeFirstResponder(nil)`,
    /// which is the exact dead-Tab state A11Y-GROUPS fixed: the window becomes
    /// its own first responder and Tab has nothing to advance from. Focus
    /// lands on the editable icon well.
    private func cancelRename() {
        nameField.abortEditing()
        restoreNameField()
        view.window?.makeFirstResponder(iconWell)
    }

    /// Re-measure the rename field around its current text. An editable
    /// `NSTextField` reports NO intrinsic width, so "hug the name, then stop at
    /// the section's edge" has to be measured by hand: this drives the optional
    /// width constraint, and the required floor / 999-priority cap clamp it.
    private func updateNameFieldWidth() {
        guard let nameFieldWidth else { return }
        let text = nameField.stringValue.isEmpty
            ? (nameField.placeholderString ?? "")
            : nameField.stringValue
        let font = nameField.font ?? Tokens.Font.heading
        let measured = (text as NSString).size(withAttributes: [.font: font]).width
        // The insets the cell reserves for the leading margin and the trailing
        // pencil, plus a hair of slack so the caret at the end of the string
        // never sits on the truncation edge.
        nameFieldWidth.constant = (measured
            + WarmNameFieldCell.textInsetLeading
            + WarmNameFieldCell.textInsetTrailing
            + 2).rounded(.up)
    }

    /// The rename field's skin, for the hover/pencil state below.
    private var nameFieldCell: WarmNameFieldCell? { nameField.cell as? WarmNameFieldCell }

    /// Hover on the rename field (the tracking area installed in `loadView`;
    /// the field itself stays stock, so this controller owns the callbacks).
    /// DRAWING ONLY — a neutral wash plus the pencil's alpha step-up, no
    /// geometry change (R7).
    public override func mouseEntered(with event: NSEvent) { setNameFieldHovered(true) }
    public override func mouseExited(with event: NSEvent) { setNameFieldHovered(false) }

    private func setNameFieldHovered(_ hovered: Bool) {
        guard let cell = nameFieldCell, cell.isHovered != hovered else { return }
        cell.isHovered = hovered
        nameField.needsDisplay = true
    }

    private func membershipToggled(deviceID: String, isChecked: Bool) {
        guard let editingGroupID,
              var group = groupController.groups.first(where: { $0.id == editingGroupID }) else { return }

        if isChecked {
            if !group.memberIDs.contains(deviceID) {
                group.memberIDs.append(deviceID)
                // Remember the device's current volume for this membership.
                if let device = groupController.devices.first(where: { $0.id == deviceID }) {
                    group.memberVolumes[deviceID] = device.volume
                }
            }
        } else {
            // A group must keep at least one device — refuse to remove the last
            // member (to remove the group entirely, use "Delete scene…"). Revert
            // the checkbox so the row reflects the unchanged membership and bail
            // before persisting an empty group.
            guard group.memberIDs.contains(where: { $0 != deviceID }) else {
                rowsByID[deviceID]?.isChecked = true
                return
            }
            group.memberIDs.removeAll { $0 == deviceID }
            group.memberVolumes[deviceID] = nil
        }
        guard saveOrReport(group) else { return }   // failure re-renders from the model
        Analytics.capture("scene:membership_changed", ["added": isChecked ? "true" : "false"])
        // Rebuild: an unchecked unavailable device drops out of the list.
        rebuildCandidates(memberSet: Set(group.memberIDs))
        countLabel.roll(to: Self.speakerCount(group.memberIDs.count))
        onDidEditGroup?()
    }

    /// Build and present `IconPickerViewController` anchored to `anchor`,
    /// wiring its `onPick` to ``pickIcon(_:)``. The popover needs a hosting
    /// window AND a non-headless process: `anchor.window != nil` alone is not a
    /// headless check, because suites host this pane in a real (ordered-out)
    /// window. ``test_pickIcon(_:)`` drives ``pickIcon(_:)`` directly instead.
    private func presentIconPicker(anchoredTo anchor: NSView) {
        guard let editingGroupID,
              let group = groupController.groups.first(where: { $0.id == editingGroupID }) else { return }

        let picker = IconPickerViewController()
        picker.configure(currentSymbolName: group.iconSymbolName, defaultSymbolName: Group.defaultIconSymbolName)
        picker.onPick = { [weak self] name in
            self?.pickIcon(name)
        }

        guard anchor.window != nil, !HeadlessRuntime.isActive else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = picker
        popover.contentSize = picker.view.fittingSize
        iconPickerPopover = popover
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    /// Persist `name` as the editing group's icon override (`nil` reverts to
    /// the default) and refresh the well — instant-apply, like a rename.
    private func pickIcon(_ name: String?) {
        guard let editingGroupID,
              var group = groupController.groups.first(where: { $0.id == editingGroupID }) else { return }
        guard group.iconSymbolName != name else { return }
        group.iconSymbolName = name
        guard saveOrReport(group) else { return }   // failure re-renders from the model
        refreshIconWell(group: group)
        onDidEditGroup?()
    }

    /// Put keyboard focus in the rename field with its text selected — the
    /// sidebar's "Rename…" / Return path, after the host has shown this
    /// editor. First-focus select-all comes from the existing delegate.
    public func focusRenameField() {
        view.window?.makeFirstResponder(nameField)
    }

    /// Run the same confirm-then-delete flow the "Delete scene…" button does —
    /// the sidebar's context-menu "Delete scene…" path.
    public func requestDelete() {
        test_deleteRequestCount += 1
        deleteTapped(deleteButton)
    }

    @objc private func deleteTapped(_ sender: NSButton) {
        guard let group = editingGroup else { return }
        guard let window = view.window, !HeadlessRuntime.isActive else {
            // No confirmation means no delete: doing it unconfirmed is exactly
            // the thing the sheet is there to prevent. `test_confirmDelete()`
            // is the headless path.
            return
        }
        makeDeleteAlert(for: group).beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.performDelete(id: group.id)
        }
    }

    /// The delete confirmation (HIG — destructive action). Two sentences,
    /// depending on what deleting this group actually DOES:
    ///
    /// - the ACTIVE group is the Main Out target, so deleting it sends
    ///   playback back to Selected Devices (`GroupController.deleteGroup`
    ///   calls `setMainOut(.selectedDevices)`): a speaker that is also in
    ///   Selected Devices keeps playing, one that is only in this group stops.
    ///   "Deleting a group doesn't change which speakers are playing" is a
    ///   plain lie in that case, and it was the sentence on screen.
    /// - any OTHER group is pure configuration, and the old sentence is true.
    ///
    /// Delete stays the FIRST button (the `.alertFirstButtonReturn` mapping
    /// depends on it) but loses the Return key to Cancel: an accidental Return
    /// on a destructive sheet must not be the destructive answer.
    private func makeDeleteAlert(for group: Group) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Delete \u{201C}\(group.name)\u{201D}?"
        alert.informativeText = groupController.activeGroupID == group.id
            ? "This scene is playing. Deleting it switches playback to Selected Speakers; "
              + "speakers that are only in this scene will stop."
            : "Deleting a scene doesn't change which speakers are playing."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.buttons[0].hasDestructiveAction = true
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        return alert
    }

    // MARK: Test-support hooks

    var test_iconWell: NSView { iconWell }
    var test_captionText: String { countLabel.stringValue }
    var test_captionIsRolling: Bool { countLabel.test_isRolling }
    var test_countReduceMotionOverride: Bool? {
        get { countLabel.test_reduceMotionOverride }
        set { countLabel.test_reduceMotionOverride = newValue }
    }
    func test_settleCount() { countLabel.test_settleNow() }

    /// Membership row ids currently checked, in candidate order.
    public var test_checkedDeviceIDs: [String] {
        candidateDevices.map(\.id).filter { rowsByID[$0]?.test_isChecked == true }
    }

    /// All candidate device ids currently offered as membership rows.
    public var test_candidateDeviceIDs: [String] { candidateDevices.map(\.id) }

    /// Whether the membership checkbox for `deviceID` is currently interactive.
    /// The sole remaining member of a group is pinned (disabled) so it can't be
    /// unchecked into an empty group.
    public func test_isMembershipRowEnabled(for deviceID: String) -> Bool {
        rowsByID[deviceID]?.test_isCheckboxEnabled ?? false
    }

    /// The current text in the rename field.
    public var test_nameFieldValue: String { nameField.stringValue }

    /// Simulate typing a new name and committing it (Return / focus loss).
    public func test_rename(to newName: String) {
        nameField.stringValue = newName
        updateNameFieldWidth()
        commitRename()
    }

    /// Simulate pressing RETURN in the rename field — drives the field's real
    /// target/action, the same dispatch AppKit performs, rather than calling
    /// `commitRename` behind its back.
    public func test_commitRenameViaReturn(_ newName: String) {
        nameField.stringValue = newName
        updateNameFieldWidth()
        _ = nameField.target?.perform(nameField.action, with: nameField)
    }

    /// Simulate the rename field LOSING FOCUS with `newName` typed in it —
    /// drives the real `controlTextDidEndEditing` delegate path.
    public func test_commitRenameViaFocusLoss(_ newName: String) {
        nameField.stringValue = newName
        updateNameFieldWidth()
        controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification,
                                              object: nameField))
    }

    /// Simulate pressing ESCAPE with `typed` in the rename field — drives the
    /// real `control(_:textView:doCommandBy:)` seam AppKit routes the key
    /// through, with a throwaway field editor stand-in (the implementation
    /// never touches it).
    public func test_cancelRename(after typed: String) {
        nameField.stringValue = typed
        updateNameFieldWidth()
        _ = control(nameField, textView: NSTextView(),
                    doCommandBy: #selector(NSResponder.cancelOperation(_:)))
    }

    /// The rename field's laid-out frame in the pane's own coordinates.
    public var test_titleFieldFrame: NSRect {
        view.layoutSubtreeIfNeeded()
        return nameField.convert(nameField.bounds, to: view)
    }

    /// Drive the rename field's hover state headlessly (a real `mouseEntered`
    /// can't be synthesized in a headless run) — the same path the tracking
    /// area's callback takes.
    public func test_setTitleHovered(_ hovered: Bool) { setNameFieldHovered(hovered) }

    /// Whether the rename field is currently drawing its hover wash.
    public var test_isTitleHovered: Bool { nameFieldCell?.isHovered ?? false }

    /// Whether the rename field currently paints its trailing pencil (hidden
    /// while the field is being edited).
    public var test_titleShowsPencil: Bool {
        nameFieldCell?.test_showsPencil(in: nameField) ?? false
    }

    /// Whether the rename field wears the `WarmNameFieldCell` skin while
    /// staying a real, editable, focusable `NSTextField`.
    public var test_titleHasWarmSkin: Bool { nameFieldCell != nil }

    /// The rename field itself, so a test can drive real AppKit editing (a
    /// window + `makeFirstResponder`) instead of a stand-in.
    public var test_titleField: NSTextField { nameField }

    /// Simulate ticking/unticking a membership row for a device.
    public func test_setMembership(_ member: Bool, for deviceID: String) {
        guard let row = rowsByID[deviceID], row.test_isChecked != member else { return }
        row.test_toggle()
    }

    /// The SF Symbol name currently resolved for the icon well's image, or
    /// `nil` if it has none loaded yet (before `show`).
    public var test_iconWellSymbolName: String? { iconWellSymbolName }

    /// True when the identity glow shares the well's parent AND sits below it
    /// in z-order — in front of the opaque well it would be invisible, and the
    /// magenta has to read as light behind the seat.
    public var test_hasIdentityGlow: Bool {
        guard let parent = iconWell.superview,
              iconGlow.superview === parent,
              let glowIndex = parent.subviews.firstIndex(of: iconGlow),
              let wellIndex = parent.subviews.firstIndex(of: iconWell) else { return false }
        return glowIndex < wellIndex
    }

    /// The size the glow is actually laid out at — the gradient scales to its
    /// own bounds, so this is what the magenta's radius follows.
    public var test_identityGlowSide: CGFloat {
        view.layoutSubtreeIfNeeded()
        return iconGlow.frame.width
    }

    /// Simulate picking `name` from the icon picker (`nil` = "use default"),
    /// bypassing the anchored popover — drives the exact same
    /// ``pickIcon(_:)`` path `IconPickerViewController.onPick` would.
    public func test_pickIcon(_ name: String?) {
        pickIcon(name)
    }

    /// Whether the reassurance line beside the delete row is on screen.
    public var test_reassuranceVisible: Bool { !reassuranceLabel.isHidden }

    /// The reassurance line's exact wording.
    public var test_reassuranceText: String { reassuranceLabel.stringValue }

    /// Drive a membership row's pointer state headlessly — the node's hover
    /// resize is the row's "this is clickable" affordance now that the whole
    /// row toggles.
    public func test_setRowHovered(_ hovered: Bool, for deviceID: String) {
        rowsByID[deviceID]?.test_setHovered(hovered)
    }

    /// Whether a membership row's node is previewing its post-click size.
    public func test_rowNodePreviewsClick(for deviceID: String) -> Bool {
        rowsByID[deviceID]?.test_nodePreviewsClick ?? false
    }

    /// Simulate a click on a membership row's BODY (not its checkbox) — the
    /// same path a real `mouseUp` on the row takes.
    public func test_clickRow(for deviceID: String) {
        rowsByID[deviceID]?.test_clickRow()
    }

    /// True when "Delete scene…" is currently visible (always true — the
    /// editor is edit-only).
    public func test_presentationText(for id: String) -> String? { rowsByID[id]?.test_presentationText }
    public var test_deleteButtonVisible: Bool { !deleteButton.isHidden }

    /// The delete button's laid-out frame in the pane's own coordinates — it
    /// must line up with the content above it (anchoring trap: it used to hang
    /// off the container, not the column).
    public var test_deleteButtonFrame: NSRect {
        view.layoutSubtreeIfNeeded()
        return deleteButton.convert(deleteButton.bounds, to: view)
    }

    /// Delete `id`, reporting failure instead of swallowing it — a failed
    /// delete keeps the editor on the still-existing group rather than popping
    /// to a sidebar that still lists it.
    private func performDelete(id: String) {
        do {
            try groupController.deleteGroup(id: id)
        } catch {
            test_saveFailureReported = true
            Self.presentPersistFailureAlert(message: "Couldn\u{2019}t delete the scene.", over: view.window)
            return
        }
        Analytics.capture("scene:deleted")
        editingGroupID = nil
        onDidDeleteGroup?()
    }

    /// Simulate confirming the delete (bypasses the confirmation sheet).
    public func test_confirmDelete() {
        guard let editingGroupID else { return }
        performDelete(id: editingGroupID)
    }

    /// True once a persistence failure (save or delete) has been reported to
    /// the user instead of swallowed. Headless seam for the failure paths,
    /// which present no sheet without a window.
    public private(set) var test_saveFailureReported = false

    private(set) var test_deleteRequestCount = 0

    /// True once a rename was refused because another group already had that
    /// name. Headless seam — the explanation is a window-guarded sheet.
    public private(set) var test_duplicateNameRefused = false

    /// The confirmation the "Delete scene…" button would put up right now, or
    /// nil when nothing is being edited. Built through the real
    /// ``makeDeleteAlert(for:)``, so the copy and the button roles under test
    /// are the ones the user sees.
    public func test_makeDeleteAlert() -> NSAlert? {
        editingGroup.map(makeDeleteAlert(for:))
    }

    /// How many times the pane has actually repainted — proves the projection
    /// gate in ``show(groupID:devices:)``: a backend event that changes
    /// nothing this pane draws must leave it unchanged.
    public private(set) var test_renderCount = 0

    /// A membership row view by device id, so a test can prove a refresh
    /// REUSED the instance rather than rebuilding it.
    public func test_membershipRow(for deviceID: String) -> NSView? {
        rowsByID[deviceID]
    }

    /// The rename field's laid-out width — measured around the name it holds
    /// (``updateNameFieldWidth()``), clamped between its required floor and its
    /// section's edge.
    public var test_titleFieldWidth: CGFloat {
        view.layoutSubtreeIfNeeded()
        return nameField.bounds.width
    }

    /// HEADER PARITY hooks — compared with `DeviceDetailViewController`'s
    /// identically-named hooks by `GroupsHeaderParityTests`, which require the
    /// same header band height and the same vertical centring; the icon's x
    /// differs from the device page's by design.

    /// The icon well's laid-out frame in the pane's own coordinates.
    public var test_headerIconFrame: NSRect { header.frames(in: view).icon }

    /// The title's ALIGNMENT rect in the pane's own coordinates — what auto
    /// layout actually pins, so an editable field and a plain label (whose
    /// alignment insets differ from their frames) can be compared honestly.
    public var test_headerTitleAlignmentFrame: NSRect {
        view.layoutSubtreeIfNeeded()
        return nameField.alignmentRect(forFrame: nameField.convert(nameField.bounds, to: view))
    }

    /// The header SECTION's laid-out frame in the pane's own coordinates.
    public var test_headerSectionFrame: NSRect { header.frames(in: view).band }

    /// The name-and-marker block's laid-out frame in the pane's own
    /// coordinates.
    public var test_headerTextBlockFrame: NSRect { header.frames(in: view).textBlock }

    /// T5: the number of rows currently fed to the checklist's recessed
    /// background (`GroupedSectionView.rows`) — mirrors `candidateDevices`
    /// when the well is correctly kept in sync with the row rebuild.
    public var test_membershipWellRowCount: Int { membershipWell.rows.count }

    /// T5: whether the well sits BEHIND the row stack in the column's
    /// z-order (so it can never intercept a row's click).
    public var test_membershipWellIsBehindStack: Bool {
        guard let column = membershipWell.superview,
              let wellIndex = column.subviews.firstIndex(of: membershipWell),
              let stackIndex = column.subviews.firstIndex(of: membershipStack) else { return false }
        return wellIndex < stackIndex
    }

    /// True while the pane is wrapped in the scroll view roadmap 039 gave it
    /// (`../AGENTS.md`) — the same seam `DeviceDetailViewController` carries.
    public var test_hasScrollView: Bool { scrollView != nil }

    /// The height the scroll DOCUMENT needs for its content — the editor's real
    /// content height now that the pane's own fitting height is capped by the
    /// scroll view. Overflow past the frame scrolls; it no longer asks the
    /// surface to grow.
    public var test_scrollDocumentHeight: CGFloat {
        view.layoutSubtreeIfNeeded()
        guard let document = scrollView?.documentView else { return 0 }
        return document.fittingSize.height
    }
}

/// Repaints the membership card when the page lays out.
private final class WellRepaintingView: NSView {
    weak var membershipWell: GroupedSectionView?
    override func layout() {
        super.layout()
        membershipWell?.needsDisplay = true
    }
}

/// Repaints the membership card when its rows lay out.
final class WellRepaintingStackView: NSStackView {
    weak var membershipWell: GroupedSectionView?
    override func layout() {
        super.layout()
        membershipWell?.needsDisplay = true
    }
}

// MARK: - NSTextFieldDelegate

extension GroupEditorViewController: NSTextFieldDelegate {
    /// Select the whole name the moment the field takes focus, Finder-style —
    /// a rename usually replaces the name rather than appending to it.
    public func controlTextDidBeginEditing(_ obj: Notification) {
        nameField.currentEditor()?.selectAll(nil)
    }

    /// The field grows with the name as it's typed (see
    /// ``updateNameFieldWidth()``), up to its section's edge.
    public func controlTextDidChange(_ obj: Notification) {
        updateNameFieldWidth()
    }

    /// Commit the rename when the field loses focus, not just on Return.
    public func controlTextDidEndEditing(_ obj: Notification) {
        commitRename()
    }

    /// ESCAPE reverts to the pre-edit name. AppKit routes the key through the
    /// field editor as `cancelOperation(_:)`; without this it does nothing at
    /// all here, and a half-typed name sat there until it was committed by
    /// focus loss.
    public func control(_ control: NSControl, textView: NSTextView,
                        doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        cancelRename()
        return true
    }
}
