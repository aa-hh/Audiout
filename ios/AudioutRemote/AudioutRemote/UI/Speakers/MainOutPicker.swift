// Copyright (c) 2026 ahh. All rights reserved.

import SwiftUI
import AudioutProtocol

/// "Selected Speakers" plus every saved group, driving `setMainOut`. Reflects
/// `Snapshot.activeGroupID` (falling back to `mainOut.groupID` if a peer ever
/// omits it — the Mac keeps both in lockstep, but the picker shouldn't assume).
///
/// A `Menu` with its own drawn label rather than `Picker(.menu)` — the same
/// shape the Applications card's destination menu already uses
/// (`AppRouteRowView.destinationMenu`). A menu picker's label is drawn by UIKit
/// and ignores `.lineLimit`: its only defence against wrapping to four lines is
/// `.fixedSize()`, which makes it incompressible, and an incompressible picker
/// takes its width out of whatever label shares the row ("Main Out" → "Main
/// O…"). Drawn here, the group name is a plain `Text` that truncates itself —
/// which on the deck header is the only thing that may.
struct MainOutPicker: View {
    let snapshot: Snapshot
    let session: any MacSessionProtocol

    @ScaledMetric(relativeTo: .subheadline) private var pickerTextSize: CGFloat = 15

    private enum Target: Hashable {
        case selectedSpeakers
        case group(String)
    }

    private var current: Target {
        guard snapshot.mainOut.kind == "group",
              let id = snapshot.activeGroupID ?? snapshot.mainOut.groupID else {
            return .selectedSpeakers
        }
        return .group(id)
    }

    /// What the button says it is pointed at. A group that has been deleted
    /// out from under the target leaves nothing to name, and Selected Speakers
    /// is where the Mac falls back to anyway.
    private var currentTitle: String {
        switch current {
        case .selectedSpeakers:
            return "Selected Speakers"
        case .group(let id):
            return snapshot.groups.first { $0.id == id }?.name ?? "Selected Speakers"
        }
    }

    var body: some View {
        Menu {
            Button { select(.selectedSpeakers) } label: {
                entry("Selected Speakers", isCurrent: current == .selectedSpeakers)
            }
            if !snapshot.groups.isEmpty {
                Divider()
                ForEach(snapshot.groups, id: \.id) { group in
                    Button { select(.group(group.id)) } label: {
                        entry(group.name, isCurrent: current == .group(group.id))
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(currentTitle)
                    .font(.system(size: pickerTextSize, weight: .semibold))
                    // The deck header's designated loser: a group can be called
                    // anything, and the two words beside it cannot.
                    .lineLimit(1)
                    .truncationMode(.tail)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
            }
            .foregroundStyle(WarmSignal.label)
        }
        // The menu label draws ~20 pt tall, under the 44 pt floor, and it is
        // taken there the way every other sub-44 control on this screen is:
        // pad out, claim, pad back in. A `minHeight` frame reaches the same
        // floor but grows the deck header — and the list's bottom inset is a
        // constant (`SpeakerConsole.deckHeight`), so a taller deck buries the
        // last section rather than making room for itself.
        .hittable(drawn: 20)
        .accessibilityLabel("Main Out, \(currentTitle)")
        .accessibilityHint("Choose which speakers Main Out sends to")
    }

    private func select(_ target: Target) {
        switch target {
        case .selectedSpeakers:
            session.setMainOut(MainOutState(kind: "selected"))
        case .group(let id):
            session.setMainOut(MainOutState(kind: "group", groupID: id))
        }
    }

    /// A menu row: the current target carries the checkmark a menu of choices
    /// owes the reader, which a hand-drawn label has to supply itself.
    @ViewBuilder
    private func entry(_ title: String, isCurrent: Bool) -> some View {
        if isCurrent {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }
}

#Preview {
    let demo = DemoMacSession()
    return List {
        MainOutPicker(snapshot: demo.snapshot!, session: demo)
    }
}
