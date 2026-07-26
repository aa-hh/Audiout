// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Placeholder for T15's Apps tab (per-app routing rows, add-app sheet).
struct AppsPlaceholderView: View {
    var body: some View {
        ContentUnavailableView(
            "Apps",
            systemImage: "square.grid.2x2",
            description: Text("Per-app routing appears here once connected.")
        )
    }
}

#Preview {
    AppsPlaceholderView()
}
