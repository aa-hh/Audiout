// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

public enum SpeakerRecoveryState: Equatable, Sendable {
    case looking
    case found
    case notFound

    public var text: String {
        switch self {
        case .looking: return "Looking for speaker…"
        case .found: return "Available"
        case .notFound: return "Not found"
        }
    }

    public var help: String? {
        self == .notFound ? "Check that the speaker is on and on the same network." : nil
    }
}

/// Observes the host's fresh discovery snapshots. It never controls discovery or playback.
public final class SpeakerRecoveryController {
    public typealias Cancellation = () -> Void
    public typealias Scheduler = (TimeInterval, @escaping () -> Void) -> Cancellation

    private struct Attempt {
        let token: UUID
        let cancel: Cancellation
    }

    private let schedule: Scheduler
    private var attempts: [String: Attempt] = [:]
    private var liveDevices: [Device] = []
    public private(set) var states: [String: SpeakerRecoveryState] = [:]
    public var onChange: (() -> Void)?
    public var onRediscovered: ((String) -> Void)?

    /// Scheduler callbacks and snapshots use the host's presentation thread.
    public init(schedule: @escaping Scheduler = SpeakerRecoveryController.scheduleOnMainQueue,
                onRediscovered: ((String) -> Void)? = nil) {
        self.schedule = schedule
        self.onRediscovered = onRediscovered
    }

    deinit { for attempt in attempts.values { attempt.cancel() } }

    public static func scheduleOnMainQueue(after delay: TimeInterval, action: @escaping () -> Void) -> Cancellation {
        let item = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return { item.cancel() }
    }

    public var lookingDeviceIDs: Set<String> { Set(attempts.keys) }
    public var retainedDeviceIDs: Set<String> { Set(states.keys) }
    public func state(for id: String) -> SpeakerRecoveryState? { states[id] }

    public func lookForSpeaker(id: String) {
        guard attempts[id] == nil else { return }
        let token = UUID()
        states[id] = .looking
        let cancel = schedule(10) { [weak self] in self?.timeout(id: id, token: token) }
        attempts[id] = Attempt(token: token, cancel: cancel)
        onChange?()
        if liveDevices.contains(where: { $0.id == id && ($0.isAvailable || $0.connectionState == .connected) }) {
            found(id: id, token: token)
        }
    }

    public func update(liveDevices: [Device]) {
        self.liveDevices = liveDevices
        for device in liveDevices where device.isAvailable || device.connectionState == .connected {
            if let attempt = attempts[device.id] { found(id: device.id, token: attempt.token) }
        }
    }

    public func cancel(id: String) {
        attempts.removeValue(forKey: id)?.cancel()
        if states.removeValue(forKey: id) != nil { onChange?() }
    }

    /// Call when the owning surface closes, including attempts that already timed out.
    public func cancelAll() {
        let oldAttempts = attempts
        attempts.removeAll()
        for attempt in oldAttempts.values { attempt.cancel() }
        guard !states.isEmpty else { return }
        states.removeAll()
        onChange?()
    }

    private func found(id: String, token: UUID) {
        guard let attempt = attempts[id], attempt.token == token else { return }
        attempts.removeValue(forKey: id)
        attempt.cancel()
        states[id] = .found
        onChange?()
        onRediscovered?(id)
    }

    private func timeout(id: String, token: UUID) {
        guard attempts[id]?.token == token else { return }
        attempts.removeValue(forKey: id)
        states[id] = .notFound
        onChange?()
    }
}
