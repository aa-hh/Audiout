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

        let container = NSView()
        // The form column: capped to `contentMaxWidth`, leading-aligned,
        // pinned below the safe area. Everything hangs off this column's
        // edges rather than the container's, so the cap applies uniformly.
        let column = NSView()
        column.translatesAutoresizingMaskIntoConstraints = false

        for v in [iconWell, nameField, speakersLabel, membershipStack] {
            column.addSubview(v)
        }
        for v in [column, deleteButton] {
            container.addSubview(v)
        }

        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 20),
            column.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            column.widthAnchor.constraint(lessThanOrEqualToConstant: Self.contentMaxWidth),
            column.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),

            // Header parity with DeviceDetailViewController: left-aligned large
            // icon, left-aligned (editable) title beneath it.
            iconWell.topAnchor.constraint(equalTo: column.topAnchor),
            iconWell.leadingAnchor.constraint(equalTo: column.leadingAnchor),

            nameField.topAnchor.constraint(equalTo: iconWell.bottomAnchor, constant: 12),
            nameField.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            // FIXED width, not a cap: an EDITABLE text field has no intrinsic
            // width, so a "<=" alone lets auto layout collapse it to zero (it
            // rendered invisible — snapshot-caught 2026-07-18).
            nameField.widthAnchor.constraint(equalToConstant: Self.titleFieldMaxWidth),

            speakersLabel.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 20),
            speakersLabel.leadingAnchor.constraint(equalTo: column.leadingAnchor),

            membershipStack.topAnchor.constraint(equalTo: speakersLabel.bottomAnchor, constant: 8),
            membershipStack.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            membershipStack.trailingAnchor.constraint(lessThanOrEqualTo: column.trailingAnchor),
            membershipStack.bottomAnchor.constraint(equalTo: column.bottomAnchor),

            deleteButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            deleteButton.topAnchor.constraint(equalTo: column.bottomAnchor, constant: 16),
            deleteButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
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
                iconSymbolName: deviceIconController?.symbolName(for: device))
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
}

// MARK: - NSTextFieldDelegate

extension GroupEditorViewController: NSTextFieldDelegate {
    /// Commit the rename when the field loses focus, not just on Return.
    public func controlTextDidEndEditing(_ obj: Notification) {
        commitRename()
    }
}
