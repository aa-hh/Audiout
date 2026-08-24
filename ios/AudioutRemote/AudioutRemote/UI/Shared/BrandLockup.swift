// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Mark plus wordmark, on one line. Shown only while the app is still
/// searching for a Mac: once the list has something in it, the list is what
/// the screen is for.
struct BrandLockup: View {
    /// Tracks the wordmark's own text size, so the two never drift apart
    /// under Dynamic Type.
    @ScaledMetric(relativeTo: .headline) private var markSize: CGFloat = 22

    var body: some View {
        HStack(spacing: 8) {
            Image(.brandMark)
                .resizable()
                .scaledToFit()
                .frame(width: markSize, height: markSize)
            Text("Audiout")
                .font(.headline)
                .foregroundStyle(WarmSignal.label)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Audiout")
    }
}

#Preview {
    BrandLockup()
}
