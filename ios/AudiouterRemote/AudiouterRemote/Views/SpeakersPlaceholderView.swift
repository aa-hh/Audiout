// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Placeholder for T14's Speakers tab (device rows, Main Out picker, master
/// slider).
struct SpeakersPlaceholderView: View {
    var body: some View {
        ContentUnavailableView(
            "Speakers",
            systemImage: "speaker.wave.2",
            description: Text("Connect to a Mac to see its speakers here.")
        )
    }
}

#Preview {
    SpeakersPlaceholderView()
}
