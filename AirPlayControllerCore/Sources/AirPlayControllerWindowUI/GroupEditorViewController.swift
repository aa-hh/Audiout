// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Alec Henderson and contributors.

import AppKit
import AirPlayControllerCore

/// The group editor pane (SPEC §9 "Group setup (REVISED 2026-07-13)": renaming,
/// membership checkboxes, reordering, and "Delete group…" live in the mixer
/// window — this is the editing home the menu's quick-create feeds into). This
/// is the absorbed T-U3: the in-menu editable field is impossible (menu item
/// views get no keyboard events — `dev/notes/p1-menu-brief.md` §3), so a real
/// `NSTextField` works fine HERE, in a normal window.
///
/// Layout, top to bottom:
/// - a rename `NSTextField` (real first responder — legal in a window);
/// - a "Speakers" list of `NSButton(checkboxWithTitle:)`, one per discovered
///   device, checked when the device is a member (per HIG — checkboxes for
///   membership, not switches);
/// - a "Delete group…" `NSButton`.
///
/// Edits write straight through the injected `GroupController`
/// (`saveGroup`/`deleteGroup`): renaming and membership toggles call
/// `saveGroup`; the delete button calls `deleteGroup`. The parent window is
/// notified via `onDidEditGroup` / `onDidDeleteGroup` so it can refresh the
/// sidebar labels + toolbar presets.
public final class GroupEditorViewController: NSViewController {

    private let groupController: GroupController

    /// Called after a rename or membership change persisted (refresh sidebar +
    /// toolbar labels in place).
    public var onDidEditGroup: (() -> Void)?
    /// Called after the group was deleted (pop back to the mixer).
    public var onDidDeleteGroup: (() -> Void)?
    /// Called after a *new* group is created via the draft "New Group" flow —
    /// `alreadyExisted` is true when the chosen member set matched an existing
    /// group and was resolved to instead of creating a duplicate (SPEC.md §9
    /// dedup). The window activates + selects `group` in the sidebar.
    public var onDidCreateGroup: ((_ group: Group, _ alreadyExisted: Bool) -> Void)?
    /// Called when the user cancels the draft "New Group" flow (pop back to the
    /// mixer, no group created).
    public var onDidCancelCreate: (() -> Void)?

    /// The group currently being edited, nil before `show` (or in create mode —
    /// a draft has no persisted id yet).
    public private(set) var editingGroupID: String?

    /// True while the editor is showing an unsaved draft (the "New Group" flow).
    public private(set) var isCreatingDraft = false

    private let nameField = NSTextField(string: "")
    private let membershipStack = NSStackView()
    private let deleteButton = NSButton()
    private let saveButton = NSButton()
    private let cancelButton = NSButton()
    private let titleLabel = NSTextField(labelWithString: "Group")

    /// Membership checkboxes keyed by device id, so a test can read/drive them.
    private var checkboxesByID: [String: NSButton] = [:]
    /// The devices offered as membership candidates, in order.
    private var candidateDevices: [Device] = []

    public init(groupController: GroupController) {
        self.groupController = groupController
        super.init(nibName: nil, bundle: nil)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func loadView() {
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
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

        // Draft-mode buttons (create flow). Hidden while editing an existing
        // group; the delete button is hidden while creating a draft.
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        saveButton.title = "Save"
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"        // default button (Return)
        saveButton.target = self
        saveButton.action = #selector(saveDraftTapped(_:))

        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.title = "Cancel"
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"  // Escape
        cancelButton.target = self
        cancelButton.action = #selector(cancelDraftTapped(_:))

        let container = NSView()
        for v in [titleLabel, nameLabel, nameField, speakersLabel, membershipStack,
                  deleteButton, saveButton, cancelButton] {
            container.addSubview(v)
        }

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

            nameLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
            nameLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),

            nameField.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 4),
            nameField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            nameField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

            speakersLabel.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 16),
            speakersLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),

            membershipStack.topAnchor.constraint(equalTo: speakersLabel.bottomAnchor, constant: 8),
            membershipStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            membershipStack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),

            deleteButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            deleteButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),

            // Save/Cancel sit at the bottom-trailing (standard sheet-style order:
            // Cancel then default Save at the far trailing edge).
            saveButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            saveButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            cancelButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -12),
            cancelButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
        ])

        view = container
    }

    // MARK: Model

    /// Show the editor for `groupID`, building the membership checkbox list from
    /// `devices` (offer every known device as a candidate — a group can gain any
    /// speaker). No-op if the group no longer exists.
    public func show(groupID: String, devices: [Device]) {
        guard let group = groupController.groups.first(where: { $0.id == groupID }) else { return }
        editingGroupID = groupID
        isCreatingDraft = false
        candidateDevices = devices

        titleLabel.stringValue = "Edit Group"
        nameField.stringValue = group.name
        buildCheckboxes(devices: devices, memberSet: Set(group.memberIDs))
        applyModeButtons()
    }

    /// Show the editor on an EMPTY draft group (SPEC.md §9 — manual creation is
    /// the PRIMARY path). `preselected` seeds the membership checklist (e.g. the
    /// devices multi-selected in the window); pass `[]` for a blank checklist.
    /// Save → ``createGroup``; Cancel → discard. The name field is prefilled with
    /// `defaultName` (the caller supplies the next "Group N").
    public func showNewDraft(defaultName: String, devices: [Device], preselected: [String] = []) {
        editingGroupID = nil
        isCreatingDraft = true
        candidateDevices = devices

        titleLabel.stringValue = "New Group"
        nameField.stringValue = defaultName
        buildCheckboxes(devices: devices, memberSet: Set(preselected))
        applyModeButtons()
    }

    /// (Re)build the membership checkbox list, checking members of `memberSet`.
    private func buildCheckboxes(devices: [Device], memberSet: Set<String>) {
        for v in membershipStack.arrangedSubviews { membershipStack.removeArrangedSubview(v); v.removeFromSuperview() }
        checkboxesByID.removeAll()
        for device in devices {
            let checkbox = NSButton(checkboxWithTitle: device.name,
                                    target: self, action: #selector(membershipToggled(_:)))
            checkbox.state = memberSet.contains(device.id) ? .on : .off
            checkbox.identifier = NSUserInterfaceItemIdentifier(device.id)
            checkboxesByID[device.id] = checkbox
            membershipStack.addArrangedSubview(checkbox)
        }
    }

    /// Toggle which action buttons are visible for the current mode: edit mode
    /// shows "Delete group…"; draft mode shows Save/Cancel.
    private func applyModeButtons() {
        deleteButton.isHidden = isCreatingDraft
        saveButton.isHidden = !isCreatingDraft
        cancelButton.isHidden = !isCreatingDraft
    }

    // MARK: Actions

    @objc private func nameCommitted(_ sender: NSTextField) {
        // In draft mode a Return commits the draft (the field is the default
        // path to "Save"); in edit mode it persists the rename.
        if isCreatingDraft { commitDraft(); return }
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

    @objc private func membershipToggled(_ sender: NSButton) {
        guard let editingGroupID,
              var group = groupController.groups.first(where: { $0.id == editingGroupID }),
              let deviceID = sender.identifier?.rawValue else { return }

        if sender.state == .on {
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
        onDidEditGroup?()
    }

    // MARK: Draft (create) actions

    @objc private func saveDraftTapped(_ sender: NSButton) {
        commitDraft()
    }

    @objc private func cancelDraftTapped(_ sender: NSButton) {
        guard isCreatingDraft else { return }
        isCreatingDraft = false
        onDidCancelCreate?()
    }

    /// Persist the draft as a new group via ``GroupController/createGroup`` (which
    /// dedups by member set). Notifies the window with the resolved group. A
    /// draft with no checked members is not saved (no empty groups).
    private func commitDraft() {
        guard isCreatingDraft else { return }
        let members = test_checkedDeviceIDs      // checked ids, in candidate order
        guard !members.isEmpty else { return }
        let trimmed = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "New Group" : trimmed
        let volumes = Dictionary(uniqueKeysWithValues: members.compactMap { id -> (String, Int)? in
            candidateDevices.first(where: { $0.id == id }).map { (id, $0.volume) }
        })
        guard let result = try? groupController.createGroup(name: name, memberIDs: members, memberVolumes: volumes) else { return }
        isCreatingDraft = false
        editingGroupID = result.group.id
        onDidCreateGroup?(result.group, result.alreadyExisted)
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

    /// Membership checkbox ids currently checked, in candidate order.
    public var test_checkedDeviceIDs: [String] {
        candidateDevices.map(\.id).filter { checkboxesByID[$0]?.state == .on }
    }

    /// All candidate device ids offered as membership checkboxes.
    public var test_candidateDeviceIDs: [String] { candidateDevices.map(\.id) }

    /// The current text in the rename field.
    public var test_nameFieldValue: String { nameField.stringValue }

    /// Simulate typing a new name and committing it (Return / focus loss).
    public func test_rename(to newName: String) {
        nameField.stringValue = newName
        commitRename()
    }

    /// Simulate ticking/unticking a membership checkbox for a device.
    public func test_setMembership(_ member: Bool, for deviceID: String) {
        guard let checkbox = checkboxesByID[deviceID] else { return }
        checkbox.state = member ? .on : .off
        membershipToggled(checkbox)
    }

    /// Simulate typing the draft's name (create mode; no commit).
    public func test_setDraftName(_ name: String) {
        nameField.stringValue = name
    }

    /// Simulate clicking "Save" in the draft (create) flow.
    public func test_commitDraft() {
        commitDraft()
    }

    /// Simulate clicking "Cancel" in the draft (create) flow.
    public func test_cancelDraft() {
        cancelDraftTapped(cancelButton)
    }

    /// True when "Delete group…" is currently visible (edit mode).
    public var test_deleteButtonVisible: Bool { !deleteButton.isHidden }

    /// True when the Save/Cancel draft buttons are currently visible (create mode).
    public var test_draftButtonsVisible: Bool { !saveButton.isHidden && !cancelButton.isHidden }

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
    /// Commit the rename when the field loses focus, not just on Return. In draft
    /// (create) mode the name is only persisted on explicit Save, so focus loss
    /// does nothing here.
    public func controlTextDidEndEditing(_ obj: Notification) {
        guard !isCreatingDraft else { return }
        commitRename()
    }
}
