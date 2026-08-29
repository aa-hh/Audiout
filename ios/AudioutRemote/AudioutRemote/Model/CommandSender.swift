// Copyright (c) 2026 ahh. All rights reserved.

import Foundation
import AudioutProtocol

/// Time source for ``CommandSender``'s coalescing window, abstracted so
/// tests drive the throttle deterministically instead of sleeping on a real
/// clock. Only relative deltas matter — the unit is seconds, the origin is
/// arbitrary.
protocol CommandClock {
    func now() -> TimeInterval
}

/// Production clock: monotonic uptime (immune to wall-clock adjustments).
struct WallCommandClock: CommandClock {
    func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
}

/// The wire-facing engine ``RemoteSession`` drives: assigns a fresh
/// requestID to every command actually written to the transport, and
/// throttles high-frequency slider commands to at most 20 Hz per control
/// while guaranteeing the drag's release value is never dropped.
///
/// Coalescing is a plain leading-edge throttle, not a debounce: a
/// ``sendCoalesced`` call is written to the wire immediately if at least
/// `minInterval` has elapsed since the last send under that `key`, and
/// silently dropped otherwise. Intermediate drag values are never queued for
/// later delivery — the UI already renders the live value locally (the
/// "local echo" slider policy), so a dropped interior sample costs nothing;
/// only the final ``sendFinal`` call is guaranteed to reach the Mac.
///
/// Both the socket (`transport`) and time (`clock`) are injected, so tests
/// exercise the throttle and requestID plumbing without sockets or real
/// time.
final class CommandSender {
    /// ≤20 Hz ⇒ at least 50ms between two sends under the same key.
    static let minInterval: TimeInterval = 1.0 / 20.0

    /// Writes one command to the wire under the given requestID.
    /// `ConnectionController.send(command:requestID:)` fits this shape.
    typealias Transport = (CompanionCommand, String) -> Void

    private let transport: Transport
    private let clock: CommandClock
    private let makeRequestID: () -> String
    /// Last actual-send time per coalescing key (e.g. `"device.volume.\(id)"`).
    private var lastSent: [String: TimeInterval] = [:]

    init(
        transport: @escaping Transport,
        clock: CommandClock = WallCommandClock(),
        makeRequestID: @escaping () -> String = { UUID().uuidString }
    ) {
        self.transport = transport
        self.clock = clock
        self.makeRequestID = makeRequestID
    }

    /// Sends immediately — every non-slider command (selection, mute,
    /// groups, app routes, drag brackets, settings apply).
    @discardableResult
    func send(_ command: CompanionCommand) -> String {
        let id = makeRequestID()
        transport(command, id)
        return id
    }

    /// Throttled send for a continuous control while its drag is in
    /// progress. Returns the requestID if actually sent, `nil` if dropped
    /// (too soon since the last send under `key`).
    @discardableResult
    func sendCoalesced(_ command: CompanionCommand, key: String) -> String? {
        let now = clock.now()
        if let last = lastSent[key], now - last < Self.minInterval {
            return nil
        }
        lastSent[key] = now
        return send(command)
    }

    /// The drag-release guarantee: always sent, regardless of how recently
    /// `key` last sent. Resets the key's throttle clock so the very next
    /// drag's first sample isn't penalized by the release landing at the
    /// edge of the window.
    @discardableResult
    func sendFinal(_ command: CompanionCommand, key: String) -> String {
        lastSent[key] = clock.now()
        return send(command)
    }
}
