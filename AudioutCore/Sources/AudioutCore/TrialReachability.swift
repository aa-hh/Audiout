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
/// It never cancels itself: besides the trial, it tells its owner every time a
/// usable path appears, which is how a Mac that launched offline re-checks its
/// licence proof. A stored key with no verdict is also asked about when a
/// usable path appears; the monitor delivers the current path on start, so at
/// launch that key is asked about here as well as by the launch validation,
/// and that duplicate request is accepted.
public final class TrialReachability {

    /// What a path update leads to. Split out from the monitor so the decision
    /// is testable without a network: every branch is a pure function of the
    /// trial's state and whether the path is usable.
    enum Step: Equatable {

        /// Tell the server about the trial now.
        case register

        /// Ask the server about the stored key that has no verdict.
        case validate

        /// Nothing to do with this update, but keep watching.
        case wait
    }

    private let settings: AppSettings
    private let onRegistered: () -> Void
    private let onValidated: () -> Void
    private let onPathSatisfied: () -> Void
    private let monitor = NWPathMonitor()

    /// `onRegistered` runs on the main queue after the server has answered and
    /// its key is stored. The caller owns what a new key means — the check-in,
    /// the validate, the update feed's header — so none of that is decided
    /// here.
    /// `onValidated` runs on the main queue after the server has answered about
    /// a stored key that had no verdict.
    /// `onPathSatisfied` runs on the main queue on every path update that is
    /// usable, so the licence proof can be re-checked once the network returns.
    public init(settings: AppSettings,
                onRegistered: @escaping () -> Void = {},
                onValidated: @escaping () -> Void = {},
                onPathSatisfied: @escaping () -> Void = {}) {
        self.settings = settings
        self.onRegistered = onRegistered
        self.onValidated = onValidated
        self.onPathSatisfied = onPathSatisfied
    }

    /// Starts watching, unless this build has no licence server to talk to.
    /// A build run from source carries none and can have no trial to register,
    /// so it never starts a monitor at all.
    public func start() {
        guard settings.licenseServerURL != nil else { return }
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            switch Self.step(for: TrialClock.state(settings: self.settings),
                             hasKey: self.settings.hasLicenseKey,
                             hasVerdict: self.settings.licenseStatus != nil,
                             satisfied: path.status == .satisfied) {
            case .register:
                TrialRegistrar.registerIfNeeded(settings: self.settings, completion: { registered in
                    guard registered else { return }
                    self.onRegistered()
                })
            case .validate:
                LicenseValidator(settings: self.settings).validate { [weak self] _ in
                    self?.onValidated()
                }
            case .wait:
                break
            }
            if path.status == .satisfied {
                self.onPathSatisfied()
            }
        }
        // Main queue: `TrialRegistrar` writes settings through `TrialClock` and
        // reports on the main queue anyway, so the decision is made where the
        // state it reads is written.
        monitor.start(queue: .main)
    }

    /// The trial and unverified-key half of each path update. A registered
    /// trial, an expired one, and a key that already has a verdict have nothing
    /// to ask; a Mac with no trial and no key waits, because the welcome gate
    /// can start a trial later while the app runs. Only a running, unregistered trial
    /// on a usable path asks, and so does a stored key the server never
    /// answered about.
    static func step(for state: TrialState, hasKey: Bool, hasVerdict: Bool, satisfied: Bool) -> Step {
        switch state {
        case .active(_, _, registered: true), .expired:
            return .wait
        case .none:
            guard hasKey else { return .wait }
            guard !hasVerdict else { return .wait }
            return satisfied ? .validate : .wait
        case .active(_, _, registered: false):
            return satisfied ? .register : .wait
        }
    }
}
