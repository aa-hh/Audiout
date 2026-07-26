// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Small bottom-anchored banner for one ``ToastEvent``. A tab attaches the
/// whole mechanism once via `.toastOverlay(session.toasts)`.
struct ToastBanner: View {
    let event: ToastEvent

    var body: some View {
        Text(event.message)
            .font(.subheadline)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .shadow(radius: 4)
            .padding(.bottom, 24)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

extension View {
    /// Attaches a ``ToastCenter``'s current event as a bottom overlay.
    func toastOverlay(_ center: ToastCenter) -> some View {
        overlay(alignment: .bottom) {
            if let event = center.current {
                ToastBanner(event: event)
            }
        }
        .animation(.spring(duration: 0.25), value: center.current)
    }
}
