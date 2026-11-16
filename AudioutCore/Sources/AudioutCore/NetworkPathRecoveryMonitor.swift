// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 ahh and contributors.

import Foundation
import Network

/// Watches the Mac's own network path and reports when it comes back.
///
/// A Bonjour browser sees nothing when the Mac's Wi-Fi drops and returns: the
/// speaker never went away, this end did. So a parked speaker needs a signal
/// from the local path instead, which is what this seam carries.
///
/// `onRecovered` fires once per recovery report, on whatever thread the path
/// observation delivers; the caller hops onto its own queue and does its own
/// settling. The first path report after ``start()`` never fires.
protocol NetworkPathRecoveryObserving: AnyObject, Sendable {
    var onRecovered: (@Sendable () -> Void)? { get set }
    func start()
    func stop()
}

/// Production observer: an `NWPathMonitor` on a private serial queue.
///
/// Both ``start()`` and ``stop()`` do their work on that queue, so a stop that
/// races a queued start cannot leave a monitor running.
final class NetworkPathRecoveryMonitor: NetworkPathRecoveryObserving, @unchecked Sendable {
    /// One reading of the path: whether anything is routable, and which of the
    /// interfaces a speaker can be reached over are up.
    struct PathSnapshot: Equatable, Sendable {
        let satisfied: Bool
        let interfaces: Set<String>
    }

    var onRecovered: (@Sendable () -> Void)?

    private let queue = DispatchQueue(label: "Audiout.NetworkPathRecovery")
    private var monitor: NWPathMonitor?
    /// Confined to `queue`.
    private var previous: PathSnapshot?

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            // A cancelled NWPathMonitor cannot be restarted, so every start
            // builds a fresh one, and drops whatever the last one left behind.
            self.monitor?.cancel()
            self.previous = nil
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                guard let self else { return }
                // Only Wi-Fi and Ethernet carry a speaker's traffic. VPN tunnels
                // (utun and friends), cellular and loopback come and go for reasons
                // that have nothing to do with any speaker's path, and counting them
                // would spend an attempt on every one of those flaps.
                let carriers = path.availableInterfaces.filter {
                    $0.type == .wifi || $0.type == .wiredEthernet
                }
                let current = PathSnapshot(
                    satisfied: path.status == .satisfied,
                    interfaces: Set(carriers.map(\.name))
                )
                let recovered = Self.isRecovery(previous: self.previous, current: current)
                self.previous = current
                if recovered { self.onRecovered?() }
            }
            self.monitor = monitor
            // Starting on the queue we are already running on is fine: it only
            // enqueues the callbacks.
            monitor.start(queue: self.queue)
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.monitor?.cancel()
            self.monitor = nil
            self.previous = nil
        }
    }

    /// The path recovered when it is usable now AND either it was unusable
    /// before, or an interface appeared that the previous reading did not have.
    ///
    /// A Mac on Ethernet stays satisfied right through a Wi-Fi toggle, so an
    /// interface coming back is the only signal that the sockets bound to it
    /// died and can be rebuilt. An interface LEAVING is the outage itself, not
    /// the recovery: switching Wi-Fi off on an Ethernet Mac kills those sessions,
    /// and they only become reachable again when Wi-Fi returns. The first report
    /// after ``start()`` has no previous reading and is never a recovery.
    static func isRecovery(previous: PathSnapshot?, current: PathSnapshot) -> Bool {
        guard current.satisfied, let previous else { return false }
        return !previous.satisfied || !current.interfaces.isSubset(of: previous.interfaces)
    }
}
