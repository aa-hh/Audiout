// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterCore
import AudiouterSharedUI

/// The group editor pane (design revamp: the Groups window is
/// CONFIGURATION-ONLY — renaming, membership, and "Delete group…" live here,
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
/// editable and a device's is not):
/// - a large (``DeviceIconWellView/size``pt) group icon with the shared
///   Contacts-style hover scrim; clicking it opens the icon picker;
/// - the group name as an editable borderless title field (centered under the
///   icon, capped width — commits on Return/focus loss, like a Finder rename);
/// - a "Speakers" list of `MembershipRowView` rows, one per candidate device
///   (per HIG — checkboxes for membership, not switches);
/// - a "Delete group…" `NSButton`.
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

    /// Caps the form's content column width so long rows/fields don't stretch
    /// edge-to-edge in a wide window.
    private static let contentMaxWidth: CGFloat = 400

    /// The pane's LEFT SPINE gutter (Warm Signal v4 §Call-1): every piece of
    /// content — icon well, title, "Speakers", each row's icon, the delete
    /// button — starts at this inset, leaving the lane to its left owned
    /// entirely by the rail. v4 is explicit that the gutter is kept clear by
    /// MOVING THE TITLES, not by threading the rail around them; this constant
    /// is that move. Derived from the popover's own grid so the two surfaces
    /// can't drift: it already reserves `railGutterCenterX` plus the node radius
    /// plus `busNodeClearance`.
    private static let railContentInset = PopoverColumnGrid.firstElementLeading(indented: false)

    /// Leading edge of the membership grouped-list container, measured from the
    /// column's own leading edge. Placed just past the rail's widest point — a
    /// selected node's right edge (`railGutterCenterX + busNodeDiameterSelected
    /// / 2`) — plus a small gap, so the spine runs in clean pane background and
    /// never sits inside the container's fill. Derived from the shared grid, so
    /// widening the gutter moves the container in lockstep instead of silently
    /// overlapping the nodes.
    private static let wellLeadingInset: CGFloat =
        PopoverColumnGrid.railGutterCenterX + PopoverColumnGrid.busNodeDiameterSelected / 2 + 4

    /// Inset from the header section's top/bottom borders to the icon and
    /// title. Deliberately roomier than the list section's `verticalPadding`:
    /// the header holds one tall icon over one short title, so tight padding
    /// left the name looking pinned to the bottom edge of a mostly-empty box.
    private static let headerPadding: CGFloat = 14

    /// The continuous membership-rail spine, drawn ONCE for the whole pane on
    /// top of everything else so it reads unbroken where it crosses the header
    /// band and the "Speakers" label's row. Non-interactive.
    ///
    /// Its leading edge is pinned to the CONTAINER's, and the membership rows'
    /// leading edges are pinned there too — that alignment is load-bearing:
    /// `BusRailOverlayView` draws the spine at the literal
    /// `PopoverColumnGrid.railGutterCenterX` in its own coordinate space, while
    /// each row places its node at that same x from the ROW's leading edge. Move
    /// one without the other and the nodes float off the line.
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
    private let membershipStack = NSStackView()
    /// The checklist's recessed background + inter-row hairlines (T5) — see
    /// ``GroupedSectionView`` below. Sits BEHIND `membershipStack` in z-order.
    private let membershipWell = GroupedSectionView()
    /// The header's own bounded section (icon + title), the sibling of
    /// ``membershipWell``. Holds no rows, so it draws fill + border only — the
    /// rail climbs out of the list section and lands on the TITLE inside this
    /// one, which is what visually ties the members to the group they belong to.
    private let headerWell = GroupedSectionView()
    private let deleteButton = NSButton()

    /// Width cap for the editable title field (design feedback 2026-07-18:
    /// the full-width Name bar was "unnecessarily long").
    private static let titleFieldMaxWidth: CGFloat = 260

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
        iconWell.widthAnchor.constraint(equalToConstant: DeviceIconWellView.size).isActive = true
        iconWell.heightAnchor.constraint(equalToConstant: DeviceIconWellView.size).isActive = true
        iconWell.setAccessibilityLabel("Edit group icon")
        iconWell.onClick = { [weak self] in
            guard let self else { return }
            self.presentIconPicker(anchoredTo: self.iconWell)
        }

        // The editable title: styled like the detail pane's name label (header
        // parity) but a real first responder. Borderless label-look that edits
        // in place — bezel-less so the text baseline sits exactly where the
        // static label's does (the bezeled field drew its text visibly
        // off-center — live-test feedback 2026-07-18).
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.placeholderString = "Group name"
        nameField.font = Tokens.Font.heading
        nameField.alignment = .natural   // left-aligned (LTR) to match the column
        nameField.isBezeled = false
        nameField.drawsBackground = false
        nameField.usesSingleLineMode = true
        nameField.lineBreakMode = .byTruncatingTail
        nameField.target = self
        nameField.action = #selector(nameCommitted(_:))
        nameField.delegate = self

        let speakersLabel = NSTextField(labelWithString: "Speakers")
        speakersLabel.translatesAutoresizingMaskIntoConstraints = false
        speakersLabel.textColor = Tokens.Color.secondaryLabel

        membershipStack.translatesAutoresizingMaskIntoConstraints = false
        membershipStack.orientation = .vertical
        membershipStack.alignment = .leading
        membershipStack.spacing = 6

        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        deleteButton.title = "Delete group…"
        deleteButton.bezelStyle = .rounded
        deleteButton.target = self
        deleteButton.action = #selector(deleteTapped(_:))
        deleteButton.hasDestructiveAction = true

        // A host that re-invalidates the rail on every layout pass, so the spine
        // always reflects the CURRENT row frames (rebuild, resize, pane swap)
        // with no cached geometry — the popover's `RailHostView` pattern.
        let container = RailRepaintingView()
        container.railOverlay = railOverlay
        container.membershipWell = membershipWell
        // The form column: capped to `contentMaxWidth`, leading-aligned,
        // pinned below the safe area. Everything hangs off this column's
        // edges rather than the container's, so the cap applies uniformly.
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
            well.contentLeadingInset = Self.railContentInset
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

        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 20),
            // The column starts at the container's own leading edge — the 16pt
            // margin moved INTO `railContentInset`, which every child below
            // applies, so the rail gets an exclusive lane to their left.
            column.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            column.widthAnchor.constraint(
                lessThanOrEqualToConstant: Self.contentMaxWidth + Self.railContentInset),
            column.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),

            // Header parity with DeviceDetailViewController: left-aligned large
            // icon, left-aligned (editable) title beneath it, BOTH panes using
            // the same `railContentInset` so switching sidebar selection doesn't
            // shift the header sideways (design review 2026-07-25 — it used to
            // jump ~22.5pt because only this pane reserved the gutter).
            // Inset by the header's own padding so the icon doesn't touch its
            // top border.
            iconWell.topAnchor.constraint(equalTo: column.topAnchor,
                                          constant: Self.headerPadding),
            iconWell.leadingAnchor.constraint(equalTo: column.leadingAnchor,
                                              constant: Self.railContentInset),

            nameField.topAnchor.constraint(equalTo: iconWell.bottomAnchor, constant: 12),
            nameField.leadingAnchor.constraint(equalTo: column.leadingAnchor,
                                               constant: Self.railContentInset),
            // FIXED width, not a cap: an EDITABLE text field has no intrinsic
            // width, so a "<=" alone lets auto layout collapse it to zero (it
            // rendered invisible — snapshot-caught 2026-07-18).
            nameField.widthAnchor.constraint(equalToConstant: Self.titleFieldMaxWidth),

            // Sits BETWEEN the two sections, on bare pane — the gap below the
            // header section's bottom border, above the list section's top.
            speakersLabel.topAnchor.constraint(equalTo: headerWell.bottomAnchor, constant: 14),
            speakersLabel.leadingAnchor.constraint(equalTo: column.leadingAnchor,
                                                   constant: Self.railContentInset),

            // The header section: wraps the icon + title, padded off both, and
            // spans the column's full width so the rail lands INSIDE it.
            headerWell.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            headerWell.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            headerWell.topAnchor.constraint(equalTo: column.topAnchor),
            headerWell.bottomAnchor.constraint(equalTo: nameField.bottomAnchor,
                                               constant: Self.headerPadding),

            // The ROWS, uniquely, start at the column's own leading edge: each
            // row applies `railContentInset` internally to its icon and places
            // its node in the gutter, so row icons still line up with the header
            // content above them.
            // 8 → 10: the container now extends `verticalPadding` ABOVE the
            // first row, so the visible gap from the "Speakers" label to the
            // container's top edge is this minus that padding. Nudged up so the
            // label doesn't crowd the container's new border.
            membershipStack.topAnchor.constraint(equalTo: speakersLabel.bottomAnchor, constant: 10),
            membershipStack.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            membershipStack.trailingAnchor.constraint(lessThanOrEqualTo: column.trailingAnchor),
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

            deleteButton.leadingAnchor.constraint(equalTo: container.leadingAnchor,
                                                  constant: Self.railContentInset),
            // 16 → 20: the grouped-list container extends `verticalPadding`
            // BELOW the last row, so this gap minus that padding is what's
            // actually visible between the container's bottom border and the
            // button. 16 left it reading cramped against the border.
            deleteButton.topAnchor.constraint(equalTo: column.bottomAnchor, constant: 20),
            deleteButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),

            railOverlay.topAnchor.constraint(equalTo: container.topAnchor),
            railOverlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            railOverlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
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
        editingGroupID = groupID
        allDevices = devices

        nameField.stringValue = group.name
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
        }
        // Pin the sole remaining member: a group needs at least one device, so
        // its last member can't be unchecked here (delete the group instead).
        // Only one member → that row's checkbox is disabled with an explanation.
        if memberSet.count == 1, let onlyMemberID = memberSet.first {
            rowsByID[onlyMemberID]?.setCheckboxEnabled(
                false, tooltip: "A group needs at least one device. Use \u{201C}Delete group\u{2026}\u{201D} to remove it.")
        }
        // T5: re-point the well at the CURRENT rows so its hairlines land
        // between whatever's actually in the stack now (a rebuild can add or
        // drop rows — an unchecked unavailable device disappears).
        membershipWell.rows = candidateDevices.compactMap { rowsByID[$0.id] }
        updateRail()
    }

    /// Re-point the pane-level rail at the current rows and set each row's
    /// extent in the spine (Warm Signal v4 §Call-1): the rail runs from the
    /// group icon well down to the LOWEST CHECKED row, detouring around the
    /// unchecked rows inside that span; rows below the terminus render as bare
    /// nodes with no rail through them, so the spine's LENGTH reads as "how far
    /// down this group reaches." Called after every rebuild — which is also
    /// after every membership toggle, so the terminus follows the checkboxes.
    private func updateRail() {
        let rows = candidateDevices.compactMap { rowsByID[$0.id] }
        let terminus = rows.lastIndex { $0.isChecked }
        for (index, row) in rows.enumerated() {
            if let terminus, index <= terminus {
                row.setRail(above: true, below: index < terminus)
            } else {
                row.setRail(above: false, below: false)
            }
        }
        railOverlay.mainOutRow = self
        railOverlay.deviceRows = rows
        railOverlay.needsDisplay = true
    }

    // MARK: Actions

    @objc private func nameCommitted(_ sender: NSTextField) {
        commitRename()
    }

    private func commitRename() {
        guard let editingGroupID,
              var group = groupController.groups.first(where: { $0.id == editingGroupID }) else { return }
        let trimmed = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != group.name else { return }
        group.name = trimmed
        _ = try? groupController.saveGroup(group)
        onDidEditGroup?()
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
            // member (to remove the group entirely, use "Delete group…"). Revert
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
        commitRename()
    }

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

    /// True when "Delete group…" is currently visible (always true — the
    /// editor is edit-only).
    public var test_deleteButtonVisible: Bool { !deleteButton.isHidden }

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

    /// Each candidate row's rail extent, in candidate order — `above` is
    /// "inside the spine", `below` is "the rail continues past me".
    public var test_railExtents: [(above: Bool, below: Bool)] {
        candidateDevices.compactMap { rowsByID[$0.id] }.map { ($0.railHasSpine, $0.railBelow) }
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

    /// The title field's laid-out width — the rail's origin "ring" reports half
    /// of this as its radius, so a test can assert the hook geometry without
    /// re-deriving the field's width cap.
    public var test_titleFieldWidth: CGFloat { nameField.bounds.width }

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
    /// The group's TITLE is this pane's origin — the analogue of the popover's
    /// Main Audio ring: the rail curves out of the gutter and lands on the
    /// group's name, so the members visibly hang off the group they belong to.
    /// It hooked the ICON well until a design review (2026-07-25) moved it down
    /// to the title: the name is what the members belong to, and the shorter
    /// climb keeps the spine from cutting past the whole header.
    ///
    /// The protocol is phrased in terms of a ring because the popover's origin
    /// IS one; only `ringCenterX - ringRadius` (the left edge) and `centerY` are
    /// ever drawn to, so a rectangular title reports its own half-width and the
    /// hook lands on the field's leading edge. `gold` still follows the SAME
    /// active-group truth as the icon well's §5.3 gold ring, so an inactive
    /// group's hook reads in the quiet `ember` idle tone.
    public func railHookAnchor(in view: NSView)
        -> (centerY: CGFloat, ringCenterX: CGFloat, ringRadius: CGFloat, gold: Bool)? {
        guard isViewLoaded, nameField.superview != nil else { return nil }
        nameField.layoutSubtreeIfNeeded()
        let center = nameField.convert(
            NSPoint(x: nameField.bounds.midX, y: nameField.bounds.midY), to: view)
        return (center.y, center.x, nameField.bounds.width / 2, iconWell.isActiveGroup)
    }
}

/// The editor pane's container: re-invalidates the rail overlay AND the
/// membership well (T5) on every layout pass so both track the current row
/// frames with no cached geometry (the popover's `RailHostView` pattern). Both
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

// MARK: - Membership checklist recessed background (T5)

/// The membership checklist's recessed background: a rounded `Tokens.Color
/// .well` fill behind the row stack, with a faint `Tokens.Color.hairline`
/// divider between each pair of ADJACENT rows. Before this the checklist
/// carried no surface of its own at all — `MembershipRowView` paints nothing
/// behind itself — so there was zero visual separation either between rows or
/// against the pane (measured on the real post-fix tones: `panel` vs `canvas`
/// ~1.06:1 dark / ~1.08:1 light, effectively invisible). Measured floors for
/// THIS view's own tokens (WCAG relative luminance, both ≥ their required
/// floor — see `MembershipWellContrastTests`): `well` vs `panel` 1.109:1 dark /
/// 1.182:1 light (floor 1.10:1); `hairline` vs `panel` 1.404:1 dark / 1.309:1
/// light (floor 1.25:1, the same separator floor `Tokens.Color.hairline`
/// itself documents against `panel`).
///
/// A GROUPED-SECTION container (the macOS System Settings idiom), used TWICE in
/// this pane: once around the header (icon + title) and once around the
/// membership list. Two stacked sections with the rail threading out of the
/// list up into the header mirrors the popover's own composition — bounded
/// sections, tied together by the spine (design review 2026-07-25).
///
/// The geometry, all of it load-bearing:
///
/// - **Spans the full column width**, gutter included, so the rail's nodes sit
///   INSIDE the section rather than floating beside it. Content within is inset
///   past the gutter (`contentLeadingInset`) so the spine keeps a clear lane.
/// - **Padded** top/bottom (`verticalPadding`) so content breathes instead of
///   touching the container's edges.
/// - **Inset dividers** starting at `contentLeadingInset` — the standard
///   grouped-list separator treatment, never full-bleed under the corners. A
///   section holding fewer than two rows draws none, which is what lets this
///   same view serve as the plain header container.
/// - **A visible border** plus a radius large enough to read as a shape; the
///   first draft's 6pt radius rendered visually square.
///
/// `draw(_:)`-based, not a frozen layer color — `DeviceIconWellView`'s pattern
/// for a rounded/solid-fill background view in this same file's neighborhood:
/// every token re-resolves per appearance/Increase-Contrast on each paint, and
/// `viewDidChangeEffectiveAppearance` just triggers a repaint. Non-interactive
/// (`hitTest` always `nil`, `MembershipBusView`'s pattern) — it sits BEHIND
/// `membershipStack` in z-order, so no row/checkbox/rail click target is ever
/// affected; the small dead area to the right of a narrower row (the well is
/// wider than a row's intrinsic content) simply swallows a click with no
/// target, same as clicking blank pane background anywhere else.
private final class GroupedSectionView: NSView {
    /// Large enough to read as a rounded shape at this container's size — the
    /// 6pt first draft rendered visually square.
    static let cornerRadius: CGFloat = 10
    /// Breathing room above the first row and below the last, so rows never
    /// touch the container's edges.
    static let verticalPadding: CGFloat = 6
    private static let hairlineThickness: CGFloat = 1
    private static let borderWidth: CGFloat = 1

    /// Where the row's ICON starts, measured from this view's own leading edge
    /// — the inset dividers align to it. Set by the controller so it stays
    /// derived from the shared grid rather than re-typed here.
    var contentLeadingInset: CGFloat = 0 { didSet { needsDisplay = true } }

    /// The membership rows currently laid out in the stack above this view,
    /// in top-to-bottom order — read for LIVE frames on every draw, exactly
    /// like `BusRailOverlayView.deviceRows` (no cached geometry: a rebuild can
    /// add/drop rows when an unchecked unavailable device disappears).
    var rows: [NSView] = [] { didSet { needsDisplay = true } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        // Stroke sits ON the boundary, so inset by half its width to keep the
        // 1pt line crisp instead of straddling the pixel edge.
        let borderRect = bounds.insetBy(dx: Self.borderWidth / 2, dy: Self.borderWidth / 2)
        let shape = NSBezierPath(roundedRect: borderRect,
                                 xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
        Tokens.Color.well.setFill()
        shape.fill()
        Tokens.Color.hairline.setStroke()
        shape.lineWidth = Self.borderWidth
        shape.stroke()

        guard rows.count > 1 else { return }
        Tokens.Color.hairline.setFill()
        for (a, b) in zip(rows, rows.dropFirst()) {
            guard let aSuper = a.superview, let bSuper = b.superview else { continue }
            let aFrame = convert(a.frame, from: aSuper)
            let bFrame = convert(b.frame, from: bSuper)
            // Robust to either coordinate flip: two non-overlapping adjacent
            // rows' gap is bounded by the two INNER edges of the four
            // (min/max of each frame) — sorting picks them out without this
            // view needing to know which axis direction is "down".
            let ys = [aFrame.minY, aFrame.maxY, bFrame.minY, bFrame.maxY].sorted()
            let midY = (ys[1] + ys[2]) / 2
            // INSET to the icon's leading edge (grouped-list separator
            // treatment) — a full-bleed line would run under the container's
            // rounded corners and read as a slab, not a list.
            let lineRect = NSRect(x: bounds.minX + contentLeadingInset,
                                  y: midY - Self.hairlineThickness / 2,
                                  width: bounds.width - contentLeadingInset,
                                  height: Self.hairlineThickness)
            NSBezierPath(rect: lineRect).fill()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - NSTextFieldDelegate

extension GroupEditorViewController: NSTextFieldDelegate {
    /// Commit the rename when the field loses focus, not just on Return.
    public func controlTextDidEndEditing(_ obj: Notification) {
        commitRename()
    }
}
