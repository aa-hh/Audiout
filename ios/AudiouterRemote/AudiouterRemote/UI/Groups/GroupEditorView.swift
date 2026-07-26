// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import AudiouterProtocol

/// Create/edit form for a group, presented as a sheet by ``GroupsView``.
///
/// Client-side validation mirrors only the two refusals a user should never
/// have to round-trip to the Mac to discover: a blank/whitespace name and
/// zero selected members both disable Save outright. Every other Mac-side
/// refusal (name/member-count caps, duplicate member-set on create, group
/// count cap) is left to the server — ``MacSessionProtocol``'s `createGroup`/
/// `updateGroup` already surface those as a toast on the session's shared
/// ``ToastCenter`` (`RemoteSession.handleCommandResult` /
/// `DemoMacSession`'s own `toasts.show(.refusal(...))`), so this view doesn't
/// need to duplicate that plumbing — it just has to not swallow anything by
/// intercepting the call.
///
/// Save fires the command and dismisses immediately, the same fire-and-forget
/// shape every other control on the phone uses (no completion handler on
/// ``MacSessionProtocol``) — a refusal shows up as a toast on ``GroupsView``
/// a moment later rather than blocking the sheet.
struct GroupEditorView: View {
    enum Mode {
        case create
        case edit(GroupState)

        var isCreate: Bool {
            if case .create = self { return true }
            return false
        }
    }

    let session: any MacSessionProtocol
    let mode: Mode

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var selectedMemberIDs: Set<String>
    @State private var iconSymbolName: String?

    init(session: any MacSessionProtocol, mode: Mode) {
        self.session = session
        self.mode = mode
        switch mode {
        case .create:
            _name = State(initialValue: "")
            _selectedMemberIDs = State(initialValue: [])
            _iconSymbolName = State(initialValue: nil)
        case .edit(let group):
            _name = State(initialValue: group.name)
            _selectedMemberIDs = State(initialValue: Set(group.memberIDs))
            _iconSymbolName = State(initialValue: group.iconSymbolName)
        }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { !trimmedName.isEmpty && !selectedMemberIDs.isEmpty }

    /// Rows to offer in the member list: every device the Mac currently
    /// knows about, plus — when editing — any member of the group being
    /// edited that has since vanished from the live fleet entirely (still
    /// togglable off, using its last-known name; see ``memberLabel(for:)``).
    private var memberRowIDs: [String] {
        var ids = session.snapshot?.devices.map(\.id) ?? []
        let known = Set(ids)
        for id in selectedMemberIDs where !known.contains(id) {
            ids.append(id)
        }
        return ids
    }

    private func memberLabel(for id: String) -> String {
        if let device = session.snapshot?.devices.first(where: { $0.id == id }) {
            return device.name
        }
        if case .edit(let group) = mode, let name = group.memberNames?[id], !name.isEmpty {
            return name
        }
        return "Unavailable speaker"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .accessibilityLabel("Group name")
                }

                Section {
                    NavigationLink {
                        GroupIconPicker(selection: $iconSymbolName)
                    } label: {
                        HStack {
                            Text("Icon")
                            Spacer()
                            Image(systemName: iconSymbolName ?? GroupIconLibrary.defaultSymbolName)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    if memberRowIDs.isEmpty {
                        Text("No speakers available")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(memberRowIDs, id: \.self) { id in
                            let isSelected = selectedMemberIDs.contains(id)
                            Button {
                                if isSelected {
                                    selectedMemberIDs.remove(id)
                                } else {
                                    selectedMemberIDs.insert(id)
                                }
                            } label: {
                                HStack {
                                    Text(memberLabel(for: id))
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if isSelected {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                    }
                                }
                            }
                            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                        }
                    }
                } header: {
                    Text("Members")
                } footer: {
                    if selectedMemberIDs.isEmpty {
                        Text("Choose at least one speaker.")
                    }
                }
            }
            .navigationTitle(mode.isCreate ? "New Group" : "Edit Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
        }
    }

    private func save() {
        let memberIDs = memberRowIDs.filter(selectedMemberIDs.contains)
        switch mode {
        case .create:
            session.createGroup(name: trimmedName, memberIDs: memberIDs, iconSymbolName: iconSymbolName)
        case .edit(var group):
            group.name = trimmedName
            group.memberIDs = memberIDs
            group.iconSymbolName = iconSymbolName
            // memberVolumes/isMuted ride back unchanged — the Mac backfills a
            // newly added member's volume and re-applies mute state
            // (CompanionCommandDispatcher.applyUpdateGroup).
            session.updateGroup(group)
        }
        dismiss()
    }
}

#Preview("Create Group") {
    GroupEditorView(session: DemoMacSession(), mode: .create)
}

#Preview("Edit Group") {
    let session = DemoMacSession()
    let group = session.snapshot!.groups.first!
    return GroupEditorView(session: session, mode: .edit(group))
}

#Preview("Edit Group — Offline Member") {
    let session = DemoMacSession()
    var group = session.snapshot!.groups.first!
    group.memberIDs.append("demo-vanished-speaker")
    group.memberNames = ["demo-vanished-speaker": "Bedroom Speaker"]
    session.updateGroup(group)
    return GroupEditorView(session: session, mode: .edit(session.snapshot!.groups.first!))
}
