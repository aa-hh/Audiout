// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import AudiouterProtocol

/// "Selected Speakers" plus every saved group, driving `setMainOut`. Reflects
/// `Snapshot.activeGroupID` (falling back to `mainOut.groupID` if a peer ever
/// omits it — the Mac keeps both in lockstep, but the picker shouldn't assume).
struct MainOutPicker: View {
    let snapshot: Snapshot
    let session: any MacSessionProtocol

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

    var body: some View {
        Picker("Main Out", selection: Binding(
            get: { current },
            set: { target in
                switch target {
                case .selectedSpeakers:
                    session.setMainOut(MainOutState(kind: "selected"))
                case .group(let id):
                    session.setMainOut(MainOutState(kind: "group", groupID: id))
                }
            }
        )) {
            Text("Selected Speakers").tag(Target.selectedSpeakers)
            ForEach(snapshot.groups, id: \.id) { group in
                Text(group.name).tag(Target.group(group.id))
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .tint(WarmSignal.label)
        .font(.system(size: 15, weight: .semibold))
        // The menu label draws ~20 pt tall, under the 44 pt floor, and it is
        // taken there the way every other sub-44 control on this screen is:
        // pad out, claim, pad back in. A `minHeight` frame reaches the same
        // floor but grows the deck header — and the list's bottom inset is a
        // constant (`SpeakerConsole.deckHeight`), so a taller deck buries the
        // last section rather than making room for itself.
        .hittable(drawn: 20)
        .accessibilityHint("Choose which speakers Main Out sends to")
    }
}

#Preview {
    let demo = DemoMacSession()
    return List {
        MainOutPicker(snapshot: demo.snapshot!, session: demo)
    }
}
