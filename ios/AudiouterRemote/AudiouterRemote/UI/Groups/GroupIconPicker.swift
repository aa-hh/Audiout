// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// A modest curated SF Symbol grid for picking a group's icon — mirrors the
/// spirit of the Mac's own curated set (`AudiouterSharedUI/DeviceIcon.swift`,
/// unreachable from iOS per `ios/AGENTS.md`'s `AudiouterCore` import ban) with
/// a short iOS-side list: speakers, rooms, home symbols only, not the Mac's
/// full catalog.
enum GroupIconLibrary {
    /// Mirrors `Group.defaultIconSymbolName` (AudiouterCore/GroupStore.swift)
    /// — what renders when a group has no `iconSymbolName` of its own.
    static let defaultSymbolName = "rectangle.3.group"

    /// (SF Symbol name, human-readable label for the grid button + VoiceOver).
    static let curated: [(symbol: String, label: String)] = [
        ("hifispeaker.fill", "Speaker"),
        ("hifispeaker.2.fill", "Speaker Pair"),
        ("homepod.fill", "HomePod"),
        ("speaker.wave.2.fill", "Speaker Volume"),
        ("headphones", "Headphones"),
        ("house.fill", "Whole House"),
        ("sofa.fill", "Living Room"),
        ("bed.double.fill", "Bedroom"),
        ("fork.knife", "Kitchen"),
        ("tv.fill", "TV Room"),
        ("laptopcomputer", "Office"),
        ("rectangle.3.group", "Group (Default)"),
    ]
}

/// Grid picker for a group's `iconSymbolName`. `selection` is `nil` for
/// "use the default" — tapping "Default" in the toolbar reports that
/// directly, no separate grid cell needed for it.
struct GroupIconPicker: View {
    @Binding var selection: String?

    private let columns = [GridItem(.adaptive(minimum: 64), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(GroupIconLibrary.curated, id: \.symbol) { item in
                    Button {
                        selection = item.symbol
                    } label: {
                        Image(systemName: item.symbol)
                            .font(.title2)
                            .frame(width: 56, height: 56)
                            .background(
                                selection == item.symbol
                                    ? WarmSignal.gold.opacity(0.15)
                                    : Color(.secondarySystemBackground)
                            )
                            .foregroundStyle(selection == item.symbol ? WarmSignal.gold : Color.primary)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay {
                                if selection == item.symbol {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(WarmSignal.gold, lineWidth: 2)
                                }
                            }
                    }
                    .accessibilityLabel(item.label)
                    .accessibilityAddTraits(selection == item.symbol ? [.isSelected] : [])
                }
            }
            .padding()
        }
        .navigationTitle("Icon")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Default") { selection = nil }
                    .accessibilityHint("Uses the standard group icon")
            }
        }
    }
}

#Preview("Icon Picker") {
    NavigationStack {
        GroupIconPicker(selection: .constant("sofa.fill"))
    }
}
