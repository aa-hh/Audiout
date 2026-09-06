// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Network

/// Asks ``TrialRegistrar`` again when the network comes back.
///
/// A trial can start with no network at all, so the licence server may not hear
/// about it for hours. This is where the telling happens: `NWPathMonitor`
/// reports the current path as soon as it starts and again whenever it changes,
/// so a trial is announced at launch if the network is there and the moment it
/// arrives if it is not. The one trial this cannot see is one started at the
/// welcome gate in this same session, which follows no path change — the gate's
/// own pass handler asks for that one.
///
/// Deliberately narrow. It watches for exactly one thing, and cancels itself
/// once no later path update could produce a registration — a trial already
/// registered or already over, or a Mac holding a licence key, which is a
/// bought copy or a converted trial and never starts a trial again.
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
    private let onRegistered: () -> Void
    private let monitor = NWPathMonitor()

    /// `onRegistered` runs on the main queue after the server has answered and
    /// its key is stored. The caller owns what a new key means — the check-in,
    /// the validate, the update feed's header — so none of that is decided
    /// here.
    public init(settings: AppSettings, onRegistered: @escaping () -> Void = {}) {
        self.settings = settings
        self.onRegistered = onRegistered
    }

    /// Starts watching, unless this build has no licence server to talk to.
    /// A build run from source carries none and can have no trial to register,
    /// so it never starts a monitor at all.
    public func start() {
        guard settings.licenseServerURL != nil else { return }
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            switch Self.step(for: TrialClock.state(settings: self.settings),
                             hasKey: !(self.settings.licenseKey ?? "").isEmpty,
                             satisfied: path.status == .satisfied) {
            case .register:
                TrialRegistrar.registerIfNeeded(settings: self.settings, completion: { registered in
                    guard registered else { return }
                    self.onRegistered()
                })
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
    /// update can change either, so the monitor stops. A Mac with no trial
    /// splits on the key: one holding a key has bought the app or converted its
    /// trial, and will never start another, so watching is watching forever;
    /// one with no key can still be handed a trial by the welcome gate while
    /// the app runs, and cancelling there would leave that trial with no retry
    /// until the next launch. Only a running, unregistered trial on a usable
    /// path asks.
    static func step(for state: TrialState, hasKey: Bool, satisfied: Bool) -> Step {
        switch state {
        case .active(_, _, registered: true), .expired:
            return .stop
        case .none:
            return hasKey ? .stop : .wait
        case .active(_, _, registered: false):
            return satisfied ? .register : .wait
        }
    }
}
