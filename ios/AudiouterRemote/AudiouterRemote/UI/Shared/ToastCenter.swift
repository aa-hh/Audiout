// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Observation

/// One transient feedback event surfaced after a command result: a refusal
/// (the Mac's own human-readable `refusalReason`, already presentable — see
/// `CompanionCommandDispatcher.Result`) or a Main-Out auto-swap notice.
/// Model only — ``ToastBanner`` (same folder) renders it; kept SwiftUI-free
/// so it stays reachable from the Model layer without pulling UIKit/SwiftUI
/// into that boundary.
struct ToastEvent: Identifiable, Equatable {
    enum Kind: Equatable {
        case refusal(reason: String)
        case autoSwap
    }

    let id = UUID()
    let kind: Kind

    var message: String {
        switch kind {
        case .refusal(let reason): return reason
        case .autoSwap: return "Main Out switched to the connected device"
        }
    }
}

/// Holds the current toast (if any) for a session. One at a time — a new
/// toast replaces whatever's showing rather than queuing, since feedback
/// about the freshest command is what the user needs.
@MainActor
@Observable
final class ToastCenter {
    private(set) var current: ToastEvent?
    private var dismissTask: Task<Void, Never>?

    /// How long a toast stays up before auto-dismissing.
    static let displayDuration: Duration = .seconds(3)

    func show(_ kind: ToastEvent.Kind) {
        dismissTask?.cancel()
        let event = ToastEvent(kind: kind)
        current = event
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: Self.displayDuration)
            guard !Task.isCancelled else { return }
            self?.dismiss(event.id)
        }
    }

    func dismiss(_ id: UUID) {
        if current?.id == id { current = nil }
    }
}
