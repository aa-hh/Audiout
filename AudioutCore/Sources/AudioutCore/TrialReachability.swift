// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Network

/// Asks ``TrialRegistrar`` again when the network comes back.
///
/// A trial can start with no network at all, so the licence server may not hear
/// about it for hours. Launch is one chance to tell it; this is the other — the
/// moment a usable path appears, the trial is announced.
///
/// Deliberately narrow. It watches for exactly one thing and cancels itself the
/// moment there is nothing left to register.
public final class TrialReachability {

    /// What a path update leads to. Split out from the monitor so the decision
    /// is testable without a network: every branch is a pure function of the
    /// trial's state and whether the path is usable.
    enum Step: Equatable {

        /// Tell the server about the trial now.
        case register

        /// Nothing to do with this update, but keep watching.
        case wait

        /// Nothing will ever come of watching — cancel the monitor.
        case stop
    }

    private let settings: AppSettings
    private let monitor = NWPathMonitor()

    public init(settings: AppSettings) {
        self.settings = settings
    }

    /// Starts watching, unless this build has no licence server to talk to.
    /// A build run from source carries none and can have no trial to register,
    /// so it never starts a monitor at all.
    public func start() {
        guard settings.licenseServerURL != nil else { return }
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            switch Self.step(for: TrialClock.state(settings: self.settings),
                             satisfied: path.status == .satisfied) {
            case .register:
                TrialRegistrar.registerIfNeeded(settings: self.settings)
            case .wait:
                break
            case .stop:
                self.monitor.cancel()
            }
        }
        // Main queue: `TrialRegistrar` writes settings through `TrialClock` and
        // reports on the main queue anyway, so the decision is made where the
        // state it reads is written.
        monitor.start(queue: .main)
    }

    /// The whole rule, as one decision.
    ///
    /// A registered trial and an expired one are both final — no later path
    /// update can change either, so the monitor stops. A Mac with no trial is
    /// NOT final: the welcome gate can start one at any point in the session,
    /// and cancelling here would leave that trial with no retry until the next
    /// launch. Only a running, unregistered trial on a usable path asks.
    static func step(for state: TrialState, satisfied: Bool) -> Step {
        switch state {
        case .active(_, _, registered: true), .expired:
            return .stop
        case .none:
            return .wait
        case .active(_, _, registered: false):
            return satisfied ? .register : .wait
        }
    }
}
