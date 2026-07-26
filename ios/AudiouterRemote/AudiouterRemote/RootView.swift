// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// The 4-tab skeleton (T10). Each tab is a placeholder view under `Views/`
/// until its own task (T14-T17a) replaces it.
struct RootView: View {
    var body: some View {
        TabView {
            SpeakersPlaceholderView()
                .tabItem {
                    Label("Speakers", systemImage: "speaker.wave.2")
                }

            AppsPlaceholderView()
                .tabItem {
                    Label("Apps", systemImage: "square.grid.2x2")
                }

            GroupsPlaceholderView()
                .tabItem {
                    Label("Groups", systemImage: "rectangle.3.group")
                }

            ConnectionPlaceholderView()
                .tabItem {
                    Label("Connection", systemImage: "antenna.radiowaves.left.and.right")
                }
        }
    }
}

#Preview {
    RootView()
}
