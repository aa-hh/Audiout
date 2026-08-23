// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import UIKit

/// The local-network denial case (``MacBrowserState/permissionSuspected``).
/// Honest wording matters here: `PermissionDenialDetector` (MacBrowser.swift)
/// is a HEURISTIC, not an API fact — iOS never tells an app whether Local
/// Network access was granted or denied. A user who simply hasn't answered
/// the system prompt yet must never be told they denied it; this copy
/// hedges accordingly and explains the prompt clears itself once answered.
struct PermissionDeniedView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text("Local Network Access Needed")
                    .font(.headline)
            } icon: {
                Image(systemName: "wifi.exclamationmark")
                    .foregroundStyle(.orange)
            }
            .accessibilityAddTraits(.isHeader)

            Text("This app may not be allowed to find devices on your Wi-Fi network. If you haven't answered the \u{201C}Local Network\u{201D} prompt yet, this clears itself as soon as you do \u{2014} otherwise, allow it in Settings.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                openSettings()
            } label: {
                Label("Open Settings", systemImage: "gear")
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Opens this app's page in the Settings app, where Local Network access can be turned on.")
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

#Preview {
    List {
        Section {
            PermissionDeniedView()
        }
    }
}
