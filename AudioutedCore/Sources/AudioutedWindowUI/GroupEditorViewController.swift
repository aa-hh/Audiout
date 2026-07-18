// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutedCore

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
/// Layout, top to bottom:
/// - a rename `NSTextField` (real first responder — legal in a window);
/// - a "Speakers" list of `MembershipRowView` rows, one per candidate device
///   (per HIG — checkboxes for membership, not switches);
/// - a "Delete group…" `NSButton`.
///
/// Edits write straight through the injected `GroupController`
/// (`saveGroup`/`deleteGroup`): renaming and membership toggles call
/// `saveGroup`; the delete button calls `deleteGroup`. The parent window is
/// notified via `onDidEditGroup` / `onDidDeleteGroup` so it can refresh the
/// sidebar labels + toolbar presets.
public final class GroupEditorViewController: NSViewController {

    /// Caps the form's content column width so long rows/fields don't stretch
    /// edge-to-edge in a wide window.
    private static let contentMaxWidth: CGFloat = 400

    private let groupController: GroupController

    /// Called after a rename or membership change persisted (refresh sidebar +
    /// toolbar labels in place).
    public var onDidEditGroup: (() -> Void)?
    /// Called after the group was deleted (pop back to the mixer).
    public var onDidDeleteGroup: (() -> Void)?

    /// The group currently being edited, nil before `show`.
    public private(set) var editingGroupID: String?

    private let nameField = NSTextField(string: "")
    private let membershipStack = NSStackView()
    private let deleteButton = NSButton()
    private let titleLabel = NSTextField(labelWithString: "Edit Group")

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
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.stringValue = "Edit Group"
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor

        let nameLabel = NSTextField(labelWithString: "Name")
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.textColor = .secondaryLabelColor

        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.placeholderString = "Group name"
        nameField.target = self
        nameField.action = #selector(nameCommitted(_:))
        nameField.delegate = self

        let speakersLabel = NSTextField(labelWithString: "Speakers")
        speakersLabel.translatesAutoresizingMaskIntoConstraints = false
        speakersLabel.textColor = .secondaryLabelColor

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
        // pinned below the title. Everything hangs off this column's edges
        // rather than the container's, so the cap applies uniformly.
        let column = NSView()
        column.translatesAutoresizingMaskIntoConstraints = false

        for v in [nameLabel, nameField, speakersLabel, membershipStack] {
            column.addSubview(v)
        }
        for v in [titleLabel, column, deleteButton] {
            container.addSubview(v)
        }

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

            column.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
            column.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            column.widthAnchor.constraint(lessThanOrEqualToConstant: Self.contentMaxWidth),
            column.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),

            nameLabel.topAnchor.constraint(equalTo: column.topAnchor),
            nameLabel.leadingAnchor.constraint(equalTo: column.leadingAnchor),

            nameField.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 4),
            nameField.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            nameField.trailingAnchor.constraint(equalTo: column.trailingAnchor),

            speakersLabel.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 16),
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

        titleLabel.stringValue = "Edit Group"
        nameField.stringValue = group.name
        rebuildCandidates(memberSet: Set(group.memberIDs))
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
            let row = MembershipRowView(device: device, checked: memberSet.contains(device.id))
            row.onToggle = { [weak self] deviceID, isChecked in
                self?.membershipToggled(deviceID: deviceID, isChecked: isChecked)
            }
            rowsByID[device.id] = row
            membershipStack.addArrangedSubview(row)
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
            group.memberIDs.removeAll { $0 == deviceID }
            group.memberVolumes[deviceID] = nil
        }
        _ = try? groupController.saveGroup(group)
        // Rebuild: an unchecked unavailable device drops out of the list.
        rebuildCandidates(memberSet: Set(group.memberIDs))
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
