// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterCore
import AudiouterSharedUI

/// The group editor pane (design revamp: the Groups window is
/// CONFIGURATION-ONLY — renaming, membership, and "Delete Group…" live here,
/// but activation/routing never do; that stays in the popover only). This is
/// the absorbed T-U3: the in-menu editable field is impossible (menu item
/// views get no keyboard events — `dev/notes/p1-menu-brief.md` §3), so a real
/// `NSTextField` works fine HERE, in a normal window.
///
/// EDIT-ONLY: this view controller never creates a group. Creation moved to a
/// standard macOS sheet (a parallel task); this editor only ever shows an
/// already-persisted group.
///
/// Layout, top to bottom (HEADER PARITY with `DeviceDetailViewController` —
/// design feedback 2026-07-18: groups and devices share the identical
/// large-icon header, the only difference being that a group's TITLE is
/// editable and a device's is not; every shared number lives in
/// ``GroupsPaneLayout``):
/// - a HEADER SECTION holding the large (``DeviceIconWellView/size``pt) group
///   icon and the group's name SIDE BY SIDE (design review 2026-07-25 — they
///   used to stack, which cost 30 pt of a pane that was overflowing its own
///   window); clicking the icon opens the icon picker;
/// - the name itself is an inline rename field: a real `NSTextField` wearing
///   the ``WarmNameFieldCell`` skin (filled, bordered, trailing pencil), which
///   commits on Return/focus loss, reverts on Escape, and restores the previous
///   name when emptied — a Finder rename in a box;
/// - a "Speakers" list of `MembershipRowView` rows, one per candidate device
///   (per HIG — checkboxes for membership, not switches), in a second section;
/// - a "Delete Group…" `NSButton`.
///
/// Edits write straight through the injected `GroupController`
/// (`saveGroup`/`deleteGroup`): renaming and membership toggles call
/// `saveGroup`; the delete button calls `deleteGroup`. The parent window is
/// notified via `onDidEditGroup` / `onDidDeleteGroup` so it can refresh the
/// sidebar labels + toolbar presets.
///
/// The header icon shows `group.iconSymbolName` (resolved through
/// `DeviceIcon.resolve`, so a stale override still renders the default rather
/// than a blank glyph). Picking a symbol (or "use default") persists instantly
/// through `saveGroup`, exactly like a rename — this window never gates a
/// group edit behind a separate "Save" step.
public final class GroupEditorViewController: NSViewController {

    /// The continuous membership-rail spine, drawn ONCE for the whole pane on
    /// top of everything else so it reads unbroken where it crosses the header
    /// band and the "Speakers" label's row. Non-interactive.
    ///
    /// ANCHORING TRAP: its leading edge is pinned to the COLUMN's, and the
    /// membership rows' leading edges are pinned there too — that alignment is
    /// load-bearing: `BusRailOverlayView` draws the spine at the literal
    /// `PopoverColumnGrid.railGutterCenterX` in its own coordinate space, while
    /// each row places its node at that same x from the ROW's leading edge. Move
    /// one without the other and the nodes float off the line by exactly the
    /// difference (`test_nodeCenterXInOverlaySpace` is the guard).
    private let railOverlay = BusRailOverlayView()

    private let groupController: GroupController

    /// Resolves/persists per-device icon overrides for `MembershipRowView`
    /// rows. Optional and nil-tolerant (`../../AGENTS.md`'s "depends on the
    /// model, never the reverse" — a host without one still renders default
    /// device glyphs, just no per-device overrides).
    public var deviceIconController: DeviceIconController?

    /// Called after a rename or membership change persisted (refresh sidebar +
    /// toolbar labels in place).
    public var onDidEditGroup: (() -> Void)?
    /// Called after the group was deleted (pop back to the mixer).
    public var onDidDeleteGroup: (() -> Void)?

    /// The group currently being edited, nil before `show`.
    public private(set) var editingGroupID: String?

    private let iconWell = DeviceIconWellView()
    private let nameField = NSTextField(string: "")
    private let membershipStack = RailRepaintingStackView()
    /// The checklist's recessed background + inter-row hairlines (T5) — see
    /// ``GroupedSectionView``. Sits BEHIND `membershipStack` in z-order.
    /// NAME IS LOAD-BEARING: `GroupsWindowTextColorLockTests` reaches this
    /// stored property by reflection (the type is internal, the property is
    /// private) to sample the real drawn fill/divider colours.
    private let membershipWell = GroupedSectionView()
    /// The header's own bounded section (icon + title side by side), the
    /// sibling of ``membershipWell``. Holds no rows, so it draws fill + border
    /// only — the rail climbs out of the list section and lands on the icon
    /// well inside this one, which is what visually ties the members to the
    /// group they belong to.
    private let headerWell = GroupedSectionView()
    private let deleteButton = NSButton()

    /// Floor for the rename field's width. An editable `NSTextField` has NO
    /// intrinsic width, so without this a field whose width is otherwise driven
    /// by its (measured) content can be squeezed to nothing — it rendered
    /// invisible once already (snapshot-caught 2026-07-18). REQUIRED priority,
    /// deliberately: the field may overflow its section by a hair on a
    /// pathologically narrow pane rather than vanish.
    private static let titleFieldMinWidth: CGFloat = 140

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
    private var rowsByID: [String: MembershipRowView] = [:]
    /// The devices currently offered as membership candidates, in order
    /// (available devices, plus unavailable devices only while they remain
    /// members of this group — see ``rebuildCandidates(devices:)``).
    private var candidateDevices: [Device] = []
    /// The full device set last passed to `show`, so membership toggles can
    /// rebuild the candidate list (an unchecked unavailable device drops out).
    private var allDevices: [Device] = []

    public init(groupController: GroupController) {
        self.groupController = groupController
        super.init(nibName: nil, bundle: nil)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func loadView() {
        iconWell.translatesAutoresizingMaskIntoConstraints = false
        // This pane's well is where the membership rail's origin hook lands, so
        // it wears the ring (gold when active, ember when idle) that the spine
        // terminates into. The device detail pane's well is NOT a rail origin
        // and keeps its neutral resting edge.
        iconWell.isRailOrigin = true
        iconWell.widthAnchor.constraint(equalToConstant: DeviceIconWellView.size).isActive = true
        iconWell.heightAnchor.constraint(equalToConstant: DeviceIconWellView.size).isActive = true
        iconWell.setAccessibilityLabel("Edit group icon")
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
        nameField.placeholderString = "Group name"
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
        nameField.setAccessibilityLabel("Group name")
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

        let speakersLabel = NSTextField(labelWithString: "Speakers")
        speakersLabel.translatesAutoresizingMaskIntoConstraints = false
        speakersLabel.textColor = Tokens.Color.secondaryLabel

        membershipStack.translatesAutoresizingMaskIntoConstraints = false
        membershipStack.orientation = .vertical
        membershipStack.alignment = .leading
        membershipStack.spacing = 6

        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        deleteButton.title = "Delete Group…"
        deleteButton.bezelStyle = .rounded
        deleteButton.target = self
        deleteButton.action = #selector(deleteTapped(_:))
        deleteButton.hasDestructiveAction = true

        // A host that re-invalidates the rail on every layout pass, so the spine
        // always reflects the CURRENT row frames (rebuild, resize, pane swap)
        // with no cached geometry.
        //
        // TWO hooks, deliberately, and neither replaces the other (2026-08-06 —
        // the popover's rail drew displaced by exactly the gap between them):
        // the CONTAINER's `layout()` fires on window resize / pane swap but NOT
        // when only descendants re-lay out inside an unchanged container frame
        // (a checklist row growing or a mid-animation reflow); the membership
        // STACK's fires for its own relayouts but — unlike the popover's card
        // stack, which is pinned to its container's four edges and so covers
        // both cases alone — this stack floats inside the elastic form column,
        // so its `layout()` is not guaranteed to run on every container
        // resize. The popover could DELETE its container hook; here both stay.
        let container = RailRepaintingView()
        container.railOverlay = railOverlay
        container.membershipWell = membershipWell
        membershipStack.railOverlay = railOverlay
        membershipStack.membershipWell = membershipWell
        // The form column: symmetric margins off the pane, ELASTIC up to
        // `GroupsPaneLayout.contentMaxWidth`. Everything hangs off this
        // column's edges rather than the container's, so both sections and the
        // rail move together.
        let column = NSView()
        column.translatesAutoresizingMaskIntoConstraints = false

        // Added FIRST so it sits behind every row (T5: a recessed background +
        // hairline dividers behind the checklist, which otherwise carries no
        // surface at all — measured ~1.06:1 dark / ~1.08:1 light against
        // `panel`, an invisible boundary). Non-interactive (`hitTest` always
        // nil), so it never intercepts a row's click.
        // Both sections span the column's full width (rail gutter included), so
        // their dividers inset by the same gutter reserve every child uses.
        for well in [headerWell, membershipWell] {
            well.translatesAutoresizingMaskIntoConstraints = false
            well.contentLeadingInset = GroupsPaneLayout.contentLeadingInset
            column.addSubview(well)
        }
        for v in [iconWell, nameField, speakersLabel, membershipStack] {
            column.addSubview(v)
        }
        for v in [column, deleteButton] {
            container.addSubview(v)
        }
        // Added LAST so the spine composites ON TOP of the header and the rows
        // it passes; non-interactive, so nothing beneath it loses a click.
        railOverlay.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(railOverlay)

        // The column STRETCHES with the pane: this pushes it out to the
        // trailing margin, the required `<=` cap stops it at
        // `contentMaxWidth`, and the required `<=` margin keeps it inside the
        // pane at any width. Without this fill the sections hugged their
        // ~277 pt intrinsic content and left a dead strip beside them.
        let columnFill = column.trailingAnchor.constraint(
            equalTo: container.trailingAnchor, constant: -GroupsPaneLayout.columnTrailingInset)
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

        // …and never overflows its section. Priority 999 rather than required:
        // on a pathologically narrow pane the REQUIRED min-width floor wins
        // instead of AppKit breaking one of two required constraints at random
        // (and logging about it).
        let titleCap = nameField.trailingAnchor.constraint(
            lessThanOrEqualTo: headerWell.trailingAnchor,
            constant: -GroupsPaneLayout.contentTrailingInset)
        titleCap.priority = NSLayoutConstraint.Priority(999)

        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor,
                                        constant: GroupsPaneLayout.columnTopInset),
            // SYMMETRIC margins (design review 2026-07-25). The column used to
            // start at the pane's own leading edge, with the whole left margin
            // living inside `contentLeadingInset` — which put the bordered
            // sections flush against the window edge on one side only.
            column.leadingAnchor.constraint(equalTo: container.leadingAnchor,
                                            constant: GroupsPaneLayout.columnInset),
            column.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor,
                                             constant: -GroupsPaneLayout.columnTrailingInset),
            column.widthAnchor.constraint(lessThanOrEqualToConstant: GroupsPaneLayout.contentMaxWidth),
            columnFill,

            // HEADER, SIDE BY SIDE (design review 2026-07-25): icon BESIDE the
            // name, not above it — 30 pt of reclaimed height on a pane that was
            // overflowing its own window. Header parity with
            // `DeviceDetailViewController` is geometric: both panes read the
            // same `GroupsPaneLayout` numbers, so switching sidebar selection
            // never shifts the header (it used to jump ~22.5 pt sideways).
            iconWell.topAnchor.constraint(equalTo: column.topAnchor,
                                          constant: GroupsPaneLayout.headerPadding),
            iconWell.leadingAnchor.constraint(equalTo: column.leadingAnchor,
                                              constant: GroupsPaneLayout.contentLeadingInset),

            nameField.leadingAnchor.constraint(equalTo: iconWell.trailingAnchor,
                                               constant: GroupsPaneLayout.iconToTitleGap),
            nameField.centerYAnchor.constraint(equalTo: iconWell.centerYAnchor),
            nameField.heightAnchor.constraint(equalToConstant: PopoverColumnGrid.titleFieldHeight),
            // REQUIRED floor: an editable text field has no intrinsic width, so
            // without this auto layout is free to collapse it to zero (it
            // rendered invisible — snapshot-caught 2026-07-18).
            nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.titleFieldMinWidth),
            titleWidth,
            titleCap,

            // Sits BETWEEN the two sections, on bare pane — the gap below the
            // header section's bottom border, above the list section's top.
            speakersLabel.topAnchor.constraint(equalTo: headerWell.bottomAnchor, constant: 14),
            speakersLabel.leadingAnchor.constraint(equalTo: column.leadingAnchor,
                                                   constant: GroupsPaneLayout.contentLeadingInset),

            // The header section: wraps the icon + title, padded off both, and
            // spans the column's full width so the rail lands INSIDE it.
            headerWell.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            headerWell.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            headerWell.topAnchor.constraint(equalTo: column.topAnchor),
            headerWell.bottomAnchor.constraint(equalTo: iconWell.bottomAnchor,
                                               constant: GroupsPaneLayout.headerPadding),

            // The ROWS, uniquely, start at the column's own leading edge: each
            // row applies `contentLeadingInset` internally to its icon and
            // places its node in the gutter, so row icons still line up with
            // the header content above them. They FILL the section's width
            // (`buildRows` pins each row to the stack) so a row's trailing
            // annotation lands at the section's own inset edge instead of
            // wherever the widest device name happens to end.
            // 8 → 10: the container now extends `verticalPadding` ABOVE the
            // first row, so the visible gap from the "Speakers" label to the
            // container's top edge is this minus that padding. Nudged up so the
            // label doesn't crowd the container's new border.
            membershipStack.topAnchor.constraint(equalTo: speakersLabel.bottomAnchor, constant: 10),
            membershipStack.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            membershipStack.trailingAnchor.constraint(
                equalTo: column.trailingAnchor, constant: -GroupsPaneLayout.contentTrailingInset),
            membershipStack.bottomAnchor.constraint(equalTo: column.bottomAnchor),

            // The list section. Spans the column's FULL width, gutter included,
            // so the rail's nodes sit inside it (design review 2026-07-25 —
            // holding the spine outside left it reading as a detached stripe).
            // Padded off the stack's top/bottom so rows breathe.
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
                                                  constant: GroupsPaneLayout.contentLeadingInset),
            // 16 → 20: the grouped-list container extends `verticalPadding`
            // BELOW the last row, so this gap minus that padding is what's
            // actually visible between the container's bottom border and the
            // button. 16 left it reading cramped against the border.
            deleteButton.topAnchor.constraint(equalTo: column.bottomAnchor, constant: 20),
            // `<=`, NOT `==`: pinning the button to the PANE's bottom made the
            // whole chain above it stretch to reach — the column grew, the row
            // stack (pinned to the column's bottom) grew with it, and the
            // section's bottom padding silently absorbed every spare point of
            // pane height. It measured 49.5pt below the last divider against
            // 36.5pt above the first (design review 2026-07-25). Now the
            // content keeps its natural height and the slack falls BELOW the
            // button, where nothing is drawn.
            deleteButton.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor,
                                                 constant: -16),

            // ANCHORING TRAP: the overlay's LEADING edge must coincide with the
            // rows' leading edge (the column's), not the container's — the
            // overlay draws the spine at the literal `railGutterCenterX` in its
            // own space while each row places its node at that x from its own
            // leading edge, so a mismatch floats every node off the line by
            // exactly the difference.
            railOverlay.topAnchor.constraint(equalTo: container.topAnchor),
            railOverlay.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            railOverlay.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            railOverlay.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        view = container
    }

    // MARK: Model

    /// Show the editor for `groupID`, building the membership row list from
    /// `devices` (every known device is a candidate for an available row; an
    /// unavailable device is offered only while it remains a member — see
    /// ``rebuildCandidates(devices:)``). No-op if the group no longer exists.
    public func show(groupID: String, devices: [Device]) {
        guard let group = groupController.groups.first(where: { $0.id == groupID }) else { return }
        // A repaint must never discard text the user is still typing. This is
        // reached as a REFRESH as well as a first show — a membership toggle in
        // this same pane saves the group, and any phone-driven group edit
        // repaints too — and assigning `stringValue` under a live field editor
        // throws the edit away with nothing said. Skipping the overwrite loses
        // nothing: `controlTextDidEndEditing` still commits what was typed, and
        // if another actor renamed the group meanwhile, the commit wins over
        // their value rather than the user's typing vanishing mid-word.
        //
        // Read BEFORE `editingGroupID` moves, and scoped to the SAME group:
        // switching the pane to a different group must re-fill the field, or it
        // would show the previous group's half-typed name.
        let isRenamingThisGroup = editingGroupID == groupID && nameField.currentEditor() != nil
        editingGroupID = groupID
        allDevices = devices

        if !isRenamingThisGroup {
            nameField.stringValue = group.name
            updateNameFieldWidth()
        }
        refreshIconWell(group: group)
        // Warm Signal §5.3: the ACTIVE Main Out group's icon well carries the
        // thin gold ring (drawing-only; pure model state from
        // `GroupController.activeGroupID`, never audio-driven — §3.3).
        // VoiceOver equivalent: the well's accessibilityValue mirrors the
        // ring so the state isn't color-only (flagged for the C2 sweep to
        // harmonize wording with the popover's LIVE vocabulary).
        let isActive = groupController.activeGroupID == groupID
        iconWell.isActiveGroup = isActive
        iconWell.setAccessibilityValue(isActive ? "Active group" : "")
        // The origin hook's tone follows the same active-group truth the well's
        // gold ring does (`railHookAnchor`), so repaint the rail with it.
        railOverlay.needsDisplay = true
        rebuildCandidates(memberSet: Set(group.memberIDs))
    }

    /// Refresh the header icon's image from `group.iconSymbolName`, resolved
    /// through `DeviceIcon.resolve` so a stale/unrecognized override still
    /// renders the default rather than a blank glyph.
    private func refreshIconWell(group: Group) {
        let symbolName = DeviceIcon.resolve(group.iconSymbolName, default: Group.defaultIconSymbolName)
        iconWellSymbolName = symbolName
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Group icon")
        image?.isTemplate = true
        iconWell.iconImageView.image = image
        iconWell.iconImageView.contentTintColor = Tokens.Color.secondaryLabel
    }

    /// Recompute `candidateDevices` from `allDevices` — available devices,
    /// plus any unavailable device still in `memberSet` — and rebuild the
    /// membership rows from that list. Called on `show` and after every
    /// membership toggle, so an unchecked unavailable member disappears.
    private func rebuildCandidates(memberSet: Set<String>) {
        candidateDevices = allDevices.filter { $0.isAvailable || memberSet.contains($0.id) }
        buildRows(memberSet: memberSet)
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
        // Pin the sole remaining member: a group needs at least one device, so
        // its last member can't be unchecked here (delete the group instead).
        // Only one member → that row's checkbox is disabled with an explanation.
        if memberSet.count == 1, let onlyMemberID = memberSet.first {
            rowsByID[onlyMemberID]?.setCheckboxEnabled(
                false, tooltip: "A group needs at least one device. Use \u{201C}Delete Group\u{2026}\u{201D} to remove it.")
        }
        // T5: re-point the well at the CURRENT rows so its hairlines land
        // between whatever's actually in the stack now (a rebuild can add or
        // drop rows — an unchecked unavailable device disappears).
        membershipWell.rows = candidateDevices.compactMap { rowsByID[$0.id] }
        updateRail()
    }

    /// Re-point the pane-level rail at the current rows (Warm Signal v4 §Call-1):
    /// the channel runs from the group icon well down the WHOLE candidate list,
    /// detouring around every unchecked row wherever it sits, while the signal
    /// line inside it reaches only as far as the LOWEST CHECKED row — so the
    /// GOLD's length reads as "how far down this group reaches." The overlay
    /// derives both ends from the rows' node kinds, so this only has to hand it
    /// the current rows. Called after every rebuild — which is also after every
    /// membership toggle, so the signal's end follows the checkboxes.
    private func updateRail() {
        let rows = candidateDevices.compactMap { rowsByID[$0.id] }
        railOverlay.mainOutRow = self
        railOverlay.deviceRows = rows
        railOverlay.needsDisplay = true
    }

    // MARK: Actions

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
    private func commitRename() {
        guard var group = editingGroup else { return }
        let trimmed = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return restoreNameField() }
        guard trimmed != group.name else { return restoreNameField() }
        group.name = trimmed
        _ = try? groupController.saveGroup(group)
        nameField.stringValue = trimmed
        updateNameFieldWidth()
        onDidEditGroup?()
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
    private func cancelRename() {
        nameField.abortEditing()
        restoreNameField()
        nameField.window?.makeFirstResponder(nil)
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
                if let device = candidateDevices.first(where: { $0.id == deviceID }) {
                    group.memberVolumes[deviceID] = device.volume
                }
            }
        } else {
            // A group must keep at least one device — refuse to remove the last
            // member (to remove the group entirely, use "Delete Group…"). Revert
            // the checkbox so the row reflects the unchanged membership and bail
            // before persisting an empty group.
            guard group.memberIDs.contains(where: { $0 != deviceID }) else {
                rowsByID[deviceID]?.isChecked = true
                return
            }
            group.memberIDs.removeAll { $0 == deviceID }
            group.memberVolumes[deviceID] = nil
        }
        _ = try? groupController.saveGroup(group)
        // Rebuild: an unchecked unavailable device drops out of the list.
        rebuildCandidates(memberSet: Set(group.memberIDs))
        onDidEditGroup?()
    }

    /// Build and present `IconPickerViewController` anchored to `anchor`,
    /// wiring its `onPick` to ``pickIcon(_:)``. Guarded on `anchor.window !=
    /// nil` (`PopoverController.presentUnsupportedExplanation`'s pattern) so a
    /// headless test never needs a real `NSWindow` — ``test_pickIcon(_:)``
    /// drives ``pickIcon(_:)`` directly instead.
    private func presentIconPicker(anchoredTo anchor: NSView) {
        guard let editingGroupID,
              let group = groupController.groups.first(where: { $0.id == editingGroupID }) else { return }

        let picker = IconPickerViewController()
        picker.configure(currentSymbolName: group.iconSymbolName, defaultSymbolName: Group.defaultIconSymbolName)
        picker.onPick = { [weak self] name in
            self?.pickIcon(name)
        }

        guard anchor.window != nil else { return }
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
        _ = try? groupController.saveGroup(group)
        refreshIconWell(group: group)
        onDidEditGroup?()
    }

    @objc private func deleteTapped(_ sender: NSButton) {
        guard let editingGroupID else { return }
        // Confirm before deleting (HIG — destructive action). In a headless
        // test there's no window to host the sheet, so the test hook bypasses
        // this and calls `test_confirmDelete()` directly.
        let alert = NSAlert()
        alert.messageText = "Delete this group?"
        alert.informativeText = "Deleting a group doesn't change which speakers are playing."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        let performDelete = {
            try? self.groupController.deleteGroup(id: editingGroupID)
            self.editingGroupID = nil
            self.onDidDeleteGroup?()
        }
        if let window = view.window {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { performDelete() }
            }
        } else {
            performDelete()
        }
    }

    // MARK: Test-support hooks

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

    /// Simulate picking `name` from the icon picker (`nil` = "use default"),
    /// bypassing the anchored popover — drives the exact same
    /// ``pickIcon(_:)`` path `IconPickerViewController.onPick` would.
    public func test_pickIcon(_ name: String?) {
        pickIcon(name)
    }

    /// True when "Delete Group…" is currently visible (always true — the
    /// editor is edit-only).
    public var test_deleteButtonVisible: Bool { !deleteButton.isHidden }

    /// The delete button's laid-out frame in the pane's own coordinates — it
    /// must line up with the content above it (anchoring trap: it used to hang
    /// off the container, not the column).
    public var test_deleteButtonFrame: NSRect {
        view.layoutSubtreeIfNeeded()
        return deleteButton.convert(deleteButton.bounds, to: view)
    }

    /// Simulate confirming the delete (bypasses the confirmation sheet).
    public func test_confirmDelete() {
        guard let editingGroupID else { return }
        try? groupController.deleteGroup(id: editingGroupID)
        self.editingGroupID = nil
        onDidDeleteGroup?()
    }

    /// The rail geometry the overlay would draw from its CURRENT live frames.
    public func test_railPlan() -> RailPlan? {
        view.layoutSubtreeIfNeeded()
        return railOverlay.test_resolvePlan()
    }

    /// Each candidate row's drawn node, in candidate order.
    public var test_railNodes: [MembershipBusView.Node?] {
        candidateDevices.compactMap { rowsByID[$0.id] }.map(\.railNode)
    }

    /// Where a row's node centre lands in the RAIL OVERLAY's own coordinate
    /// space. The overlay draws the spine at the literal
    /// `PopoverColumnGrid.railGutterCenterX` in that space, so this MUST equal
    /// it — the one invariant that silently breaks if the row's leading edge and
    /// the overlay's leading edge ever stop coinciding.
    public func test_nodeCenterXInOverlaySpace(for deviceID: String) -> CGFloat? {
        guard let row = rowsByID[deviceID], let centerX = row.test_nodeCenterX else { return nil }
        view.layoutSubtreeIfNeeded()
        return railOverlay.convert(NSPoint(x: centerX, y: 0), from: row).x
    }

    /// The rename field's laid-out width — measured around the name it holds
    /// (``updateNameFieldWidth()``), clamped between its required floor and its
    /// section's edge.
    public var test_titleFieldWidth: CGFloat {
        view.layoutSubtreeIfNeeded()
        return nameField.bounds.width
    }

    /// HEADER PARITY hooks — the three numbers that must match
    /// `DeviceDetailViewController`'s identically-named hooks, so switching
    /// sidebar selection never shifts the header (`GroupsHeaderParityTests`).

    /// The icon well's laid-out frame in the pane's own coordinates.
    public var test_headerIconFrame: NSRect {
        view.layoutSubtreeIfNeeded()
        return iconWell.convert(iconWell.bounds, to: view)
    }

    /// The title's ALIGNMENT rect in the pane's own coordinates — what auto
    /// layout actually pins, so an editable field and a plain label (whose
    /// alignment insets differ from their frames) can be compared honestly.
    public var test_headerTitleAlignmentFrame: NSRect {
        view.layoutSubtreeIfNeeded()
        return nameField.alignmentRect(forFrame: nameField.convert(nameField.bounds, to: view))
    }

    /// The header SECTION's laid-out frame in the pane's own coordinates.
    public var test_headerSectionFrame: NSRect {
        view.layoutSubtreeIfNeeded()
        return headerWell.convert(headerWell.bounds, to: view)
    }

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
}

// MARK: - Continuous rail origin hook (Warm Signal v4 §Call-1)

extension GroupEditorViewController: RailHookProviding {
    /// The group's ICON WELL is this pane's origin — the analogue of the
    /// popover's Main Audio ring: the rail curves out of the group tile's left
    /// edge and drops into the gutter, so the members visibly hang off the
    /// group they belong to.
    ///
    /// It briefly hooked the TITLE instead (design review 2026-07-25, when the
    /// icon sat ABOVE the name and the climb from the list past the whole
    /// header read badly). The header is now SIDE BY SIDE: icon and name share
    /// one horizontal band, so hooking the icon hooks the name's line too, and
    /// the hook goes back to the well — a fixed 64 pt tile whose leading edge
    /// sits on the content inset, rather than a field whose width changes with
    /// the name it holds.
    ///
    /// The well is a rounded-rect tile rather than a circle, so the "ring"
    /// reported here is its inscribed circle; only `ringCenterX - ringRadius`
    /// (the left edge) and `centerY` are ever drawn to. `gold` follows the SAME
    /// active-group truth as the well's §5.3 gold ring, so an inactive group's
    /// hook reads in the quiet `ember` idle tone.
    public func railHookAnchor(in view: NSView)
        -> (centerY: CGFloat, ringCenterX: CGFloat, ringRadius: CGFloat, gold: Bool)? {
        guard isViewLoaded, iconWell.superview != nil else { return nil }
        iconWell.layoutSubtreeIfNeeded()
        let center = iconWell.convert(
            NSPoint(x: iconWell.bounds.midX, y: iconWell.bounds.midY), to: view)
        return (center.y, center.x, DeviceIconWellView.size / 2, iconWell.isActiveGroup)
    }
}

/// The editor pane's container: re-invalidates the rail overlay AND the
/// membership well (T5) on every layout pass so both track the current row
/// frames with no cached geometry. Both
/// draw from settled frames, so `cacheDisplay` snapshots stay deterministic.
private final class RailRepaintingView: NSView {
    weak var railOverlay: BusRailOverlayView?
    weak var membershipWell: GroupedSectionView?
    override func layout() {
        super.layout()
        railOverlay?.needsDisplay = true
        membershipWell?.needsDisplay = true
    }
}

/// The checklist stack, carrying the SAME re-invalidation for relayouts that
/// never reach the container's `layout()` — a row growing inside an unchanged
/// container frame (see the two-hooks note in `loadView`; the popover's
/// `RailStackView` is the precedent). Dirtying from `layout()` cannot loop:
/// `needsDisplay` does not invalidate layout.
final class RailRepaintingStackView: NSStackView {
    weak var railOverlay: BusRailOverlayView?
    weak var membershipWell: GroupedSectionView?
    override func layout() {
        super.layout()
        railOverlay?.needsDisplay = true
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
