// Copyright (c) 2026 ahh. All rights reserved.

import SwiftUI

/// Small bottom-anchored banner for one ``ToastEvent``. A tab attaches the
/// whole mechanism once via `.toastOverlay(session.toasts)`.
struct ToastBanner: View {
    let event: ToastEvent

    /// The banner's rise is its only motion; with Reduce Motion on it fades in
    /// where it lands instead.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(event.message)
            .font(.subheadline)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .shadow(radius: 4)
            .padding(.bottom, 24)
            .transition(reduceMotion
                        ? .opacity
                        : .move(edge: .bottom).combined(with: .opacity))
            // The banner appears far from wherever the finger just was and
            // takes no focus, so VoiceOver would never reach it on its own —
            // and this channel carries refusals, which are the one thing a
            // user must not miss. Announced here rather than in ``ToastCenter``
            // so that model-layer type stays free of SwiftUI.
            //
            // Keyed on the event, not `onAppear`: a second toast replaces the
            // first in the same view, which appears exactly once — so the
            // evicting message is the one that would have gone unspoken.
            .task(id: event.id) { AccessibilityNotification.Announcement(event.message).post() }
    }
}

/// The whole toast mechanism: the current event, its rise, and nothing else.
/// A modifier rather than a bare `View` extension because the rise has to read
/// Reduce Motion, and only a `View` type can.
private struct ToastOverlay: ViewModifier {
    let center: ToastCenter

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let event = center.current {
                    ToastBanner(event: event)
                }
            }
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.25),
                       value: center.current)
    }
}

extension View {
    /// Attaches a ``ToastCenter``'s current event as a bottom overlay.
    func toastOverlay(_ center: ToastCenter) -> some View {
        modifier(ToastOverlay(center: center))
    }
}
