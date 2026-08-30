// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudioutCore

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
        "com.audiout.PTPHelperActivationTests.\(UUID().uuidString)"
    }

    /// Synchronous, lock-guarded touch counter for ``PTPHelperActivator``'s
    /// `onTouch` hook — mirrors ``ProbeResumeGate``'s `NSLock` pattern
    /// (`PTPHelperService.swift`) rather than reaching for an actor, since
    /// `onTouch` fires synchronously and a `Task { }` hop around an actor call
    /// would race the assertion below against `activate(timeout:)` returning.
    private final class TouchCounter: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var count = 0
        func increment() {
            lock.lock(); defer { lock.unlock() }
            count += 1
        }
    }

    // MARK: - Status precheck ordering (the point of the task)

    @Test func notRegisteredNeedsApprovalWithNoWait() async {
        let activator = PTPHelperActivator(
            ptpHelper: FakeHelperStatus(status: .notRegistered),
            machServiceName: unreachableMachServiceName())

        let outcome = await activator.activate(timeout: 30)

        #expect(outcome == .needsApproval(.notRegistered))
        // The whole point of the status precheck: `.needsApproval` is reachable
        // ONLY through the `status == .enabled` guard (PTPHelperService.swift:258),
        // which returns before the Mach touch and the poll loop below it. So the
        // outcome alone proves the 30s timeout was never waited out — a regression
        // here means this test waits the full 30s and then fails on the outcome
        // (`.timingPortsUnavailable`, not `.needsApproval`), not that it flakes on
        // a timing bound.
    }

    /// The specific case the task calls out: `.requiresApproval` must perform
    /// NO XPC touch and NO wait. Proven structurally, not by timing:
    /// `.needsApproval` can only come from the status guard that precedes
    /// `touchMachService` (`PTPHelperService.swift:258`, ahead of `:262`), using
    /// a Mach service name that could only ever matter if a touch actually happened.
    @Test func requiresApprovalPerformsNoXPCTouchAndNoWait() async {
        let activator = PTPHelperActivator(
            ptpHelper: FakeHelperStatus(status: .requiresApproval),
            machServiceName: unreachableMachServiceName())

        let outcome = await activator.activate(timeout: 30)

        #expect(outcome == .needsApproval(.requiresApproval))
    }

    @Test func notFoundNeedsApprovalWithNoWait() async {
        let activator = PTPHelperActivator(
            ptpHelper: FakeHelperStatus(status: .notFound),
            machServiceName: unreachableMachServiceName())

        let outcome = await activator.activate(timeout: 30)

        #expect(outcome == .needsApproval(.notFound))
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

    // MARK: - Re-touch during the wait (root-cause fix for the helper's own
    // ~15 s idle self-exit racing a longer clock wait)

    /// The point of the fix: a wait that never becomes ready must re-touch the
    /// Mach service more than once, not just the one pre-loop touch. Uses a
    /// `touchInterval` far shorter than the production 2.0 s default so the
    /// test stays fast — the interval is injected the same way `pollInterval`
    /// already is for `enabledDoesNotShortCircuit` above. The Mach service
    /// name is the suite's usual unreachable one, so every touch here is
    /// inert — this proves the RE-TOUCH SCHEDULING, not anything about a real
    /// helper's liveness. `PTPClockProbe.isReady()` is not injected (by
    /// design, see the suite doc comment above), but reading the real, fixed
    /// `/airptp_shm` here is expected to stay not-ready for this timeout on a
    /// machine with no real helper live — the same environmental assumption
    /// `enabledDoesNotShortCircuit` already accepts.
    @Test func enabledRetouchesMoreThanOnceAcrossAWaitThatNeverBecomesReady() async {
        let counter = TouchCounter()
        let activator = PTPHelperActivator(
            ptpHelper: FakeHelperStatus(status: .enabled),
            machServiceName: unreachableMachServiceName(),
            pollInterval: 0.02,
            touchInterval: 0.1,
            onTouch: { counter.increment() })

        _ = await activator.activate(timeout: 0.35)

        #expect(counter.count > 1, "expected more than one touch across the wait, got \(counter.count)")
    }

    // MARK: - Outcome type shape (T6 consumes this directly)

    @Test func outcomeCasesRoundTripThroughTheProtocol() async {
        #expect(await FakeActivator(outcome: .ready).activate(timeout: 1) == .ready)
        #expect(
            await FakeActivator(outcome: .needsApproval(.requiresApproval)).activate(timeout: 1)
                == .needsApproval(.requiresApproval))
        #expect(await FakeActivator(outcome: .timingPortsUnavailable).activate(timeout: 1) == .timingPortsUnavailable)
    }

    // MARK: - Self-heal on repeated timing failure (T9b, wedged-helper incident)
    //
    // ``PTPHelperSelfHealingActivator`` wraps a ``PTPHelperActivating`` and cycles
    // the shared PTP helper (unregister → wait for the drain → register) exactly
    // once per rolling window, arming on the FIRST activation attempt that ends
    // `.timingPortsUnavailable` — no streak requirement. Everything below is
    // driven by fakes — a scripted inner activator and a recording
    // ``PTPHelperManaging`` double — never the real `SMAppService`/Mach path,
    // mirroring the rest of this suite.

    /// A scripted ``PTPHelperActivating`` that returns one outcome per call, in
    /// order (repeating the last once the list is exhausted) — proves the
    /// self-heal wrapper reacts to a REAL SEQUENCE of attempts, unlike
    /// ``FakeActivator`` above which only ever returns one fixed value. Never
    /// touches a real Mach service.
    private final class ScriptedActivator: PTPHelperActivating, @unchecked Sendable {
        private let lock = NSLock()
        private var outcomes: [PTPHelperActivationOutcome]
        private var _callCount = 0
        var willWaitForClock: Bool { true }
        var callCount: Int { lock.withLock { _callCount } }

        init(_ outcomes: [PTPHelperActivationOutcome]) { self.outcomes = outcomes }

        func activate(timeout: TimeInterval) async -> PTPHelperActivationOutcome {
            lock.withLock {
                _callCount += 1
                guard !outcomes.isEmpty else { return .timingPortsUnavailable }
                return outcomes.count > 1 ? outcomes.removeFirst() : outcomes[0]
            }
        }
    }

    /// A recording ``PTPHelperManaging`` whose `unregister()`/`register()` both
    /// succeed immediately (status flips straight to `.notRegistered`/`.enabled`)
    /// — the drain-wait RACE itself is already covered hermetically by
    /// `PTPHelperReconcilerTests`' `RecordingHelper` against the shared
    /// `unregisterDrainAndReregister` sequence these tests reuse; this double only
    /// needs to prove the self-heal wrapper calls it, and calls it in order.
    private final class SelfHealHelper: PTPHelperManaging, @unchecked Sendable {
        private let lock = NSLock()
        private var _status: PTPHelperStatus = .enabled
        private var _calls: [String] = []
        var status: PTPHelperStatus { lock.withLock { _status } }
        var recordedCalls: [String] { lock.withLock { _calls } }
        func register() throws { lock.withLock { _calls.append("register"); _status = .enabled } }
        func openSystemSettingsLoginItems() {}
        func unregister() async throws { lock.withLock { _calls.append("unregister"); _status = .notRegistered } }
    }

    private final class TelemetryLineBox: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) { lock.withLock { lines.append(line) } }
        var snapshot: [String] { lock.withLock { lines } }
    }

    @Test func firstTimingFailureTriggersCycleImmediately() async {
        let inner = ScriptedActivator([.timingPortsUnavailable, .ready])
        let helper = SelfHealHelper()
        let activator = PTPHelperSelfHealingActivator(
            inner: inner, helper: helper, window: 60,
            registerRetryDelay: 0, registerRetryAttempts: 3)

        _ = await activator.activate(timeout: 1)

        #expect(helper.recordedCalls == ["unregister", "register"],
                "a single failure arms the cycle immediately — no second-failure requirement")
        #expect(inner.callCount == 2, "1 failing attempt + 1 post-cycle retry")
    }

    @Test func successAfterCycleReportsSuccess() async {
        let inner = ScriptedActivator([.timingPortsUnavailable, .ready])
        let helper = SelfHealHelper()
        let activator = PTPHelperSelfHealingActivator(
            inner: inner, helper: helper, window: 60,
            registerRetryDelay: 0, registerRetryAttempts: 3)

        let outcome = await activator.activate(timeout: 1)

        #expect(outcome == .ready, "the post-cycle retry found the clock ready, so the caller sees success")
    }

    @Test func secondFailureWithinWindowDoesNotReCycle() async {
        // 1st external call: the single failure triggers the one cycle
        // immediately; its post-cycle retry (2nd inner call) still fails. 2nd
        // EXTERNAL call (3rd inner call): another failure, but the rate-limit
        // ceiling must refuse a second cycle inside the same window.
        let inner = ScriptedActivator([
            .timingPortsUnavailable, .timingPortsUnavailable, .timingPortsUnavailable,
        ])
        let helper = SelfHealHelper()
        let activator = PTPHelperSelfHealingActivator(
            inner: inner, helper: helper, window: 60,
            registerRetryDelay: 0, registerRetryAttempts: 3)

        let first = await activator.activate(timeout: 1)
        #expect(first == .timingPortsUnavailable, "the cycle fired but the retry still failed")
        #expect(helper.recordedCalls == ["unregister", "register"], "exactly one cycle so far")

        let second = await activator.activate(timeout: 1)

        #expect(second == .timingPortsUnavailable)
        #expect(helper.recordedCalls == ["unregister", "register"],
                "no second cycle within the same rolling window")
    }

    @Test func cycleEmitsPtpHelperCycleTelemetryWithOutcomeAndElapsed() async {
        let capturedLines = TelemetryLineBox()
        Telemetry._installTestSink { capturedLines.append($0) }
        defer { Telemetry._installTestSink(nil) }

        let inner = ScriptedActivator([.timingPortsUnavailable, .ready])
        let helper = SelfHealHelper()
        let activator = PTPHelperSelfHealingActivator(
            inner: inner, helper: helper, window: 60,
            registerRetryDelay: 0, registerRetryAttempts: 3)

        _ = await activator.activate(timeout: 1)
        Telemetry._installTestSink(nil)   // flush barrier, mirrors PTPHelperReconcilerTests

        let lines = capturedLines.snapshot
        #expect(lines.contains {
            $0.contains("\"evt\":\"ptp_helper_cycle\"") && $0.contains("\"outcome\":\"recovered\"")
                && $0.contains("\"elapsed_ms\"")
        })
        // No device name or identifier of any kind in the cycle telemetry.
        #expect(!lines.contains { $0.contains("\"evt\":\"ptp_helper_cycle\"") && $0.contains("device") })
    }

    /// Gate for ``GatedActivator``: lets a test hold one `activate()` call
    /// suspended mid-wait to simulate another device's takeover wait still
    /// being in flight, then release it on demand.
    private actor Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            await withCheckedContinuation { self.continuation = $0 }
        }
        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    /// A ``PTPHelperActivating`` whose FIRST call blocks on `gate` until
    /// released — every call (blocked or not) eventually resolves
    /// `.timingPortsUnavailable`. Used to hold one activation "mid-flight" while
    /// another completes, without any real Mach service or timer.
    private final class GatedActivator: PTPHelperActivating, @unchecked Sendable {
        private let gate: Gate
        private let lock = NSLock()
        private var _callCount = 0
        var willWaitForClock: Bool { true }

        init(gate: Gate) { self.gate = gate }

        func activate(timeout: TimeInterval) async -> PTPHelperActivationOutcome {
            let n: Int = lock.withLock { _callCount += 1; return _callCount }
            if n == 1 { await gate.wait() }
            return .timingPortsUnavailable
        }
    }

    @Test func neverCyclesWhileAnotherTakeoverWaitIsMidFlight() async {
        let gate = Gate()
        let inner = GatedActivator(gate: gate)
        let helper = SelfHealHelper()
        let activator = PTPHelperSelfHealingActivator(
            inner: inner, helper: helper, window: 60,
            registerRetryDelay: 0, registerRetryAttempts: 3)

        // Call #1 starts and blocks mid-wait inside the inner activator (simulates
        // a second device's takeover wait genuinely in flight). Call #2 starts
        // concurrently and finishes fast — a failure that, alone, would arm the
        // cycle immediately, but must be deferred while call #1 is still
        // mid-flight.
        let call1 = Task { await activator.activate(timeout: 1) }
        try? await Task.sleep(nanoseconds: 100_000_000)   // let call #1 register as in-flight
        let call2Outcome = await activator.activate(timeout: 1)

        #expect(call2Outcome == .timingPortsUnavailable)
        #expect(helper.recordedCalls.isEmpty,
                "call #2 must not cycle while call #1's takeover wait is still mid-flight")

        await gate.release()
        _ = await call1.value

        #expect(helper.recordedCalls == ["unregister", "register"],
                "the cycle deferred by the in-flight guard fires once nobody is left waiting")
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
