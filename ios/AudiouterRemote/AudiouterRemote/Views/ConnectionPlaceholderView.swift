// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Placeholder for T17a's Connection tab (Mac list, empty/denied states).
struct ConnectionPlaceholderView: View {
    var body: some View {
        ContentUnavailableView(
            "Connection",
            systemImage: "antenna.radiowaves.left.and.right",
            description: Text("No Mac found yet.")
        )
    }
}

#Preview {
    ConnectionPlaceholderView()
}
