// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Placeholder for T16's Groups tab (list, create/edit editor).
struct GroupsPlaceholderView: View {
    var body: some View {
        ContentUnavailableView(
            "Groups",
            systemImage: "rectangle.3.group",
            description: Text("Saved speaker groups appear here once connected.")
        )
    }
}

#Preview {
    GroupsPlaceholderView()
}
