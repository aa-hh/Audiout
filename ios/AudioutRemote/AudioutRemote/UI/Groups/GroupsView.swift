// Copyright (c) 2026 ahh. All rights reserved.

import SwiftUI
import AudioutProtocol

/// The Groups tab (T16): list of saved groups + create/edit/delete, backed
/// by whatever ``MacSessionProtocol`` conformer the app was handed (a live
/// ``RemoteSession`` or T13's ``DemoMacSession`` — this view never knows or
/// cares which).
///
/// Deleting the active group is not special-cased here: the Mac falls Main
/// Out back to Selected Speakers on its own
/// (`GroupController.swift:577-582`), and this view always reads "is this
/// group active" straight off the latest `session.snapshot?.activeGroupID`
/// rather than caching it — so the next snapshot just quietly stops showing
/// a chip on a group that no longer exists.
struct GroupsView: View {
    let session: any MacSessionProtocol

    @State private var isPresentingCreate = false
    @State private var isPresentingEdit = false
    @State private var editingGroup: GroupState?
    @State private var pendingDeletion: GroupState?

    private var groups: [GroupState] { session.snapshot?.groups ?? [] }
    private var activeGroupID: String? { session.snapshot?.activeGroupID }

    var body: some View {
        NavigationStack {
            List {
                if groups.isEmpty {
                    ContentUnavailableView(
                        "No Groups",
                        systemImage: GroupIconLibrary.defaultSymbolName,
                        description: Text("Create a group to play several speakers together.")
                    )
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(groups, id: \.id) { group in
                        let isActive = group.id == activeGroupID
                        Button {
                            editingGroup = group
                            isPresentingEdit = true
                        } label: {
                            GroupRow(group: group, isActive: isActive)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .leading) {
                            Button {
                                session.setMainOut(.init(kind: "group", groupID: group.id))
                            } label: {
                                Label("Set as Output", systemImage: "hifispeaker.and.homepod")
                            }
                            .tint(WarmSignal.gold)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                pendingDeletion = group
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Groups")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isPresentingCreate = true
                    } label: {
                        Label("Add Group", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $isPresentingCreate) {
                GroupEditorView(session: session, mode: .create)
            }
            .sheet(isPresented: $isPresentingEdit) {
                if let editingGroup {
                    GroupEditorView(session: session, mode: .edit(editingGroup))
                }
            }
            .confirmationDialog(
                "Delete \u{201C}\(pendingDeletion?.name ?? "")\u{201D}?",
                isPresented: Binding(
                    get: { pendingDeletion != nil },
                    set: { if !$0 { pendingDeletion = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete Group", role: .destructive) {
                    if let group = pendingDeletion {
                        session.deleteGroup(id: group.id)
                    }
                    pendingDeletion = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingDeletion = nil
                }
            } message: {
                Text("This can't be undone. If this group is currently playing, Main Out falls back to Selected Speakers.")
            }
            .toastOverlay(session.toasts)
        }
    }
}

/// One row: icon, name, member count, and an active chip when this group is
/// the current Main Out target.
private struct GroupRow: View {
    let group: GroupState
    let isActive: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: group.iconSymbolName ?? GroupIconLibrary.defaultSymbolName)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(group.name)
                    .font(.body)
                Text("\(group.memberIDs.count) speaker\(group.memberIDs.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isActive {
                Label("Active", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.tint)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(group.name), \(group.memberIDs.count) speaker\(group.memberIDs.count == 1 ? "" : "s")"
                + (isActive ? ", active" : "")
        )
        .accessibilityHint("Double tap to edit")
    }
}

#Preview("Groups List") {
    let session = DemoMacSession()
    session.setMainOut(.init(kind: "group", groupID: session.snapshot!.groups.first!.id))
    return GroupsView(session: session)
}

#Preview("Create Sheet") {
    GroupsView(session: DemoMacSession())
        .sheet(isPresented: .constant(true)) {
            GroupEditorView(session: DemoMacSession(), mode: .create)
        }
}

#Preview("Edit Sheet") {
    let session = DemoMacSession()
    let group = session.snapshot!.groups.first!
    return GroupsView(session: session)
        .sheet(isPresented: .constant(true)) {
            GroupEditorView(session: session, mode: .edit(group))
        }
}

#Preview("Offline Member") {
    let session = DemoMacSession()
    var group = session.snapshot!.groups.first!
    group.memberIDs.append("demo-vanished-speaker")
    group.memberNames = ["demo-vanished-speaker": "Bedroom Speaker"]
    session.updateGroup(group)
    return GroupsView(session: session)
        .sheet(isPresented: .constant(true)) {
            GroupEditorView(session: session, mode: .edit(session.snapshot!.groups.first!))
        }
}
