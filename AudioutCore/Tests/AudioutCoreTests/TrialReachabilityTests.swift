// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudioutCore

/// `TrialReachability` (`Sources/AudioutCore/TrialReachability.swift`) — the
/// retry that fires when the network comes back.
///
/// Only the decision is tested. `NWPathMonitor` itself needs a real network
/// interface changing state, which no unit test can stage, so the rule it
/// drives was split into `step(for:satisfied:)` and that is what runs here.
///
/// Two failures this guards against. A monitor that keeps running after the
/// trial is registered or expired — or on a Mac that already holds a licence
/// key — watches forever for something that can never happen. And a monitor
/// that stops on a Mac with no trial and no key leaves the welcome gate's
/// brand-new trial with no retry until the next launch — the exact case the
/// network was most likely down for.
@Suite struct TrialReachabilityTests {

    private static let expires = Date().addingTimeInterval(TrialClock.length)

    @Test("A running, unregistered trial on a usable path asks the server")
    func unregisteredOnSatisfiedPathRegisters() {
        let state = TrialState.active(daysLeft: 14, expiresAt: Self.expires, registered: false)
        #expect(TrialReachability.step(for: state, hasKey: false, satisfied: true) == .register)
    }

    /// A path update that arrives with nothing usable behind it is still an
    /// update. Asking then spends a request on a network that cannot carry it.
    @Test("An unusable path waits rather than asking")
    func unregisteredOnUnsatisfiedPathWaits() {
        let state = TrialState.active(daysLeft: 14, expiresAt: Self.expires, registered: false)
        #expect(TrialReachability.step(for: state, hasKey: false, satisfied: false) == .wait)
    }

    @Test("A registered trial stops the monitor")
    func registeredStops() {
        let state = TrialState.active(daysLeft: 3, expiresAt: Self.expires, registered: true)
        #expect(TrialReachability.step(for: state, hasKey: true, satisfied: true) == .stop)
    }

    /// There is no second trial, so an expired one can never be registered.
    @Test("An expired trial stops the monitor")
    func expiredStops() {
        let state = TrialState.expired(expiresAt: Date().addingTimeInterval(-60))
        #expect(TrialReachability.step(for: state, hasKey: false, satisfied: true) == .stop)
    }

    /// The one state that is neither ready nor final: the gate can start a
    /// trial later in this same session.
    @Test("A Mac with no trial and no key keeps watching")
    func noTrialWithoutAKeyWaits() {
        #expect(TrialReachability.step(for: .none, hasKey: false, satisfied: true) == .wait)
    }

    /// A key with no trial behind it is a bought copy, or a trial that has
    /// already converted — either way no path update can ever produce a
    /// registration. Red if this went back to `.wait`: the monitor would then
    /// run for the whole session on every paid Mac, watching for nothing.
    @Test("A Mac holding a licence key stops the monitor")
    func noTrialWithAKeyStops() {
        #expect(TrialReachability.step(for: .none, hasKey: true, satisfied: true) == .stop)
    }
}
