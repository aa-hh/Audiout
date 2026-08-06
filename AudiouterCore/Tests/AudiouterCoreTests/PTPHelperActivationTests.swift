// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudiouterCore

/// Hermetic tests for ``PTPHelperActivator`` (T4, PLAN-AIRPLAY-COEXISTENCE.md):
/// the connect-time seam that wakes the on-demand PTP helper and waits,
/// bounded, for its clock before `NativeBackend.convergeDevice` calls
/// `addOutput`. Status is driven entirely by a fake ``PTPHelperManaging`` —
/// never the real `SMAppService` — and every Mach touch below targets an
/// obviously-nonexistent, randomized service name, so even if the ordering
/// under test were broken, a run of this suite could never reach (let alone
/// demand-start) a REAL privileged helper that happens to be registered on
/// the machine.
///
/// ``PTPClockProbe/isReady()`` itself is NOT injected — by design (see
/// `PTPHelperService.swift`'s doc comment: only the status read is a seam,
/// reusing ``PTPHelperManaging``/``SimulatedPTPHelper`` rather than inventing
/// a parallel one) — it reads the real, fixed `/airptp_shm` name. That makes
/// the `.enabled` verdict below environment-dependent (a real helper running
/// ANYWHERE on the machine, e.g. someone else's live-testing session, makes
/// it `.ready`), so this suite never asserts which of `.ready` /
/// `.timingPortsUnavailable` `.enabled` resolves to — only that it is one of
/// those two, never a short-circuited `.needsApproval`. What IS fully and
/// hermetically covered here is the actual point of the task: the status
/// precheck must run BEFORE any Mach touch or wait, so the most common
/// real-world failure (never approved) fails instantly instead of hanging
/// out the full timeout.
@Suite struct PTPHelperActivationTests {

    // MARK: Doubles

    /// A canned ``PTPHelperManaging`` — never touches the real `SMAppService`.
    private struct FakeHelperStatus: PTPHelperManaging {
        let status: PTPHelperStatus
        func register() throws {}
        func openSystemSettingsLoginItems() {}
        func unregister() async throws {}
    }

    /// A minimal fake ``PTPHelperActivating`` returning a canned outcome —
    /// proves the three-case outcome type round-trips through the protocol
    /// exactly as declared, the contract a later task (T6) depends on
    /// without re-deriving its own type.
    private struct FakeActivator: PTPHelperActivating {
        let outcome: PTPHelperActivationOutcome
        var willWaitForClock: Bool { false }
        func activate(timeout: TimeInterval) async -> PTPHelperActivationOutcome { outcome }
    }

    /// A Mach service name guaranteed not to exist on any machine running this
    /// suite, so touching it is inert — no real launchd job, root daemon, or
    /// approval prompt can ever be involved.
    private func unreachableMachServiceName() -> String {
        "com.audiouter.PTPHelperActivationTests.\(UUID().uuidString)"
    }

    // MARK: - Status precheck ordering (the point of the task)

    @Test func notRegisteredNeedsApprovalWithNoWait() async {
        let activator = PTPHelperActivator(
            ptpHelper: FakeHelperStatus(status: .notRegistered),
            machServiceName: unreachableMachServiceName())

        let clock = ContinuousClock()
        let start = clock.now
        let outcome = await activator.activate(timeout: 30)
        let elapsed = clock.now - start

        #expect(outcome == .needsApproval(.notRegistered))
        // The whole point of the status precheck: a large timeout must NOT be
        // waited out when launchd was never going to demand-start anything.
        #expect(elapsed < .seconds(2), "returned in \(elapsed) — expected an instant short-circuit")
    }

    /// The specific case the task calls out: `.requiresApproval` must perform
    /// NO XPC touch and NO wait. Proven the same way as every non-`.enabled`
    /// status: an instant return despite a large timeout, using a Mach service
    /// name that could only ever matter if a touch actually happened.
    @Test func requiresApprovalPerformsNoXPCTouchAndNoWait() async {
        let activator = PTPHelperActivator(
            ptpHelper: FakeHelperStatus(status: .requiresApproval),
            machServiceName: unreachableMachServiceName())

        let clock = ContinuousClock()
        let start = clock.now
        let outcome = await activator.activate(timeout: 30)
        let elapsed = clock.now - start

        #expect(outcome == .needsApproval(.requiresApproval))
        #expect(elapsed < .seconds(2), "returned in \(elapsed) — a real wait would mean the Mach service WAS touched")
    }

    @Test func notFoundNeedsApprovalWithNoWait() async {
        let activator = PTPHelperActivator(
            ptpHelper: FakeHelperStatus(status: .notFound),
            machServiceName: unreachableMachServiceName())

        let clock = ContinuousClock()
        let start = clock.now
        let outcome = await activator.activate(timeout: 30)
        let elapsed = clock.now - start

        #expect(outcome == .needsApproval(.notFound))
        #expect(elapsed < .seconds(2))
    }

    /// The contrast case: `.enabled` does NOT short-circuit — it proceeds past
    /// the precheck to the (harmless, unreachable-named) Mach touch and the
    /// real `PTPClockProbe` poll, proving the guard above is actually gating
    /// on status rather than always returning fast. The final verdict itself
    /// is intentionally NOT asserted as a fixed value: `PTPClockProbe` reads
    /// the real, fixed `/airptp_shm`, so if some OTHER process on the machine
    /// happens to be running a real helper right now (e.g. a live-testing
    /// session elsewhere), this legitimately resolves `.ready` instead of
    /// `.timingPortsUnavailable` — both outcomes prove the same thing:
    /// `.needsApproval` is the ONLY outcome the precheck can short-circuit to,
    /// and it must never appear here.
    @Test func enabledDoesNotShortCircuit() async {
        let activator = PTPHelperActivator(
            ptpHelper: FakeHelperStatus(status: .enabled),
            machServiceName: unreachableMachServiceName(),
            pollInterval: 0.05)

        let outcome = await activator.activate(timeout: 0.3)
        #expect(outcome == .ready || outcome == .timingPortsUnavailable)
    }

    // MARK: - Outcome type shape (T6 consumes this directly)

    @Test func outcomeCasesRoundTripThroughTheProtocol() async {
        #expect(await FakeActivator(outcome: .ready).activate(timeout: 1) == .ready)
        #expect(
            await FakeActivator(outcome: .needsApproval(.requiresApproval)).activate(timeout: 1)
                == .needsApproval(.requiresApproval))
        #expect(await FakeActivator(outcome: .timingPortsUnavailable).activate(timeout: 1) == .timingPortsUnavailable)
    }
}
