// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// "No Mac found" — an App Store review requirement (T19), not decoration:
/// a reviewer with no other Mac around must be able to read this and
/// understand what to check, without needing the Demo system row (shown
/// alongside this, in ``MacListView``, as the always-available way to see
/// the app work regardless).
struct EmptyStateView: View {
    /// Distinguishes "still looking" from "gave up empty-handed" — both
    /// show the same checklist (the checklist is the useful part either
    /// way), just a different headline/symbol.
    var isSearching: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text(isSearching ? "Looking for a Mac…" : "No Mac Found")
                    .font(.headline)
            } icon: {
                if isSearching {
                    ProgressView()
                } else {
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 10) {
                checklistRow("Make sure this iPhone and your Mac are on the same Wi-Fi network.")
                checklistRow("Open Audiout on your Mac and keep it running.")
                checklistRow("In Audiout's Settings › General on your Mac, turn on \u{201C}Allow control from iPhone on this network.\u{201D}")
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }

    private func checklistRow(_ text: String) -> some View {
        Label {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.secondary)
        }
    }
}

#Preview("Not found") {
    List {
        Section {
            EmptyStateView()
        }
    }
}

#Preview("Searching") {
    List {
        Section {
            EmptyStateView(isSearching: true)
        }
    }
}
