// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudioutCore

/// Hermetic tests for ``PTPHelperReconciler`` (T3, T-ZOMBIE): the launch-time
/// auto-repair for a PTP helper `SMAppService` reports `.enabled` for but
/// launchd has no loaded job for. Everything here is driven through fakes —
/// an injected probe closure and a recording ``PTPHelperManaging`` double —
/// never the real `SMAppService`/XPC path (`realLivenessProbe` is the
/// documented untested-by-design ceiling, see its doc comment in
/// `PTPHelperService.swift`).
///
/// Nested inside `SerializedSharedState` (cookbook §18): the telemetry test
/// below installs `Telemetry._installTestSink`, a process-global seam shared
/// with every other suite that touches it.
extension SerializedSharedState {

    @Suite struct PTPHelperReconcilerTests {

        // MARK: Doubles

        /// A canned, immutable ``PTPHelperManaging`` — sufficient for every
        /// case that never calls `unregister()`/`register()`. Reused verbatim
        /// from ``PTPHelperActivationTests``' fixture (same shape, this file's
        /// own copy since that one is private to its file).
        private struct FakeHelperStatus: PTPHelperManaging, @unchecked Sendable {
            let status: PTPHelperStatus
            func register() throws {}
            func openSystemSettingsLoginItems() {}
            func unregister() async throws {}
        }

        /// Records the ORDER `unregister()`/`register()` are called in and
        /// lets `status` change after `register()` runs — so a test can drive
        /// the post-heal re-read to either `.enabled` or `.requiresApproval`.
        /// Models the live teardown drain (the 2026-08-06 root cause): after
        /// `unregister()`, the first `drainStatusReads` reads of `status` still
        /// see the old record (BTM accepted the teardown but hasn't drained
        /// it), then it reads `.notRegistered` until `register()` succeeds.
        /// `@unchecked Sendable` because `NSLock` provides the synchronization
        /// the compiler cannot see (mirrors ``ProbeResumeGate``'s own posture).
        private final class RecordingHelper: PTPHelperManaging, @unchecked Sendable {
            private let lock = NSLock()
            private var _status: PTPHelperStatus
            private let statusAfterRegister: PTPHelperStatus
            /// Live-race modeling: `SMAppService.register()` right after
            /// `unregister()` throws while launchd's async teardown is in
            /// flight. The first N register calls throw; later ones succeed.
            private var registerThrowsRemaining: Int
            /// 0 = the teardown drains before the first post-unregister status
            /// read; `Int.max` = it never drains.
            private var drainReadsRemaining: Int
            private var unregistered = false
            private(set) var calls: [String] = []

            init(status: PTPHelperStatus, statusAfterRegister: PTPHelperStatus,
                 registerThrowsFirst: Int = 0, drainStatusReads: Int = 0) {
                self._status = status
                self.statusAfterRegister = statusAfterRegister
                self.registerThrowsRemaining = registerThrowsFirst
                self.drainReadsRemaining = drainStatusReads
            }

            func register() throws {
                try lock.withLock {
                    calls.append("register")
                    if registerThrowsRemaining > 0 {
                        registerThrowsRemaining -= 1
                        throw NSError(domain: "test.smappservice", code: 1)
                    }
                    unregistered = false
                    _status = statusAfterRegister
                }
            }

            var status: PTPHelperStatus {
                lock.withLock {
                    guard unregistered else { return _status }
                    if drainReadsRemaining > 0 {
                        drainReadsRemaining -= 1
                        return _status
                    }
                    return .notRegistered
                }
            }

            func openSystemSettingsLoginItems() {}

            func unregister() async throws {
                lock.withLock {
                    calls.append("unregister")
                    unregistered = true
                }
            }

            var recordedCalls: [String] { lock.withLock { calls } }
        }

        /// Records whether the probe was invoked at all, alongside returning a
        /// canned result — proves the non-`.enabled` paths never run it.
        private final class RecordingProbe: @unchecked Sendable {
            private let lock = NSLock()
            private var _callCount = 0
            let result: PTPLivenessProbeResult

            init(result: PTPLivenessProbeResult) { self.result = result }

            var callCount: Int { lock.withLock { _callCount } }

            func probe() async -> PTPLivenessProbeResult {
                lock.withLock { _callCount += 1 }
                return result
            }
        }

        private final class TelemetryLineBox: @unchecked Sendable {
            private let lock = NSLock()
            private var lines: [String] = []
            func append(_ line: String) { lock.withLock { lines.append(line) } }
            var snapshot: [String] { lock.withLock { lines } }
        }

        // MARK: - shouldHeal truth table (pure)

        @Test func shouldHealTrueOnlyForEnabledZombie() {
            #expect(PTPHelperReconciler.shouldHeal(status: .enabled, probeResult: .zombie))
        }

        @Test(arguments: [
            PTPLivenessProbeResult.healthy, .indeterminate, .zombie,
        ])
        func shouldHealFalseForEveryNonEnabledStatus(probeResult: PTPLivenessProbeResult) {
            let nonEnabled: [PTPHelperStatus] = [.notRegistered, .requiresApproval, .notFound]
            for status in nonEnabled {
                #expect(!PTPHelperReconciler.shouldHeal(status: status, probeResult: probeResult),
                        "\(status)/\(probeResult) must never heal")
            }
        }

        @Test(arguments: [PTPLivenessProbeResult.healthy, .indeterminate])
        func shouldHealFalseForEnabledNonZombieProbe(probeResult: PTPLivenessProbeResult) {
            #expect(!PTPHelperReconciler.shouldHeal(status: .enabled, probeResult: probeResult))
        }

        // MARK: - reconcile() orchestration

        @Test(arguments: [
            PTPHelperStatus.requiresApproval, .notRegistered, .notFound,
        ])
        func reconcileSkipsProbeAndHealForNonEnabledStatus(status: PTPHelperStatus) async {
            let helper = RecordingHelper(status: status, statusAfterRegister: .enabled)
            let probe = RecordingProbe(result: .zombie)
            let reconciler = PTPHelperReconciler(helper: helper, probe: probe.probe)

            let outcome = await reconciler.reconcile()

            #expect(outcome == .notEnabled)
            #expect(probe.callCount == 0, "probe must never run for a non-.enabled status")
            #expect(helper.recordedCalls.isEmpty, "unregister/register must never run for a non-.enabled status")
        }

        @Test func reconcileHealsZombieUnregisterBeforeRegisterThenReadsEnabled() async {
            let helper = RecordingHelper(status: .enabled, statusAfterRegister: .enabled)
            let probe = RecordingProbe(result: .zombie)
            let reconciler = PTPHelperReconciler(helper: helper, probe: probe.probe)

            let outcome = await reconciler.reconcile()

            #expect(outcome == .healed(.enabled))
            #expect(probe.callCount == 1)
            #expect(helper.recordedCalls == ["unregister", "register"],
                    "unregister must fire exactly once and strictly before register")
        }

        @Test func reconcileHealsZombieAndReportsRequiresApprovalAfterRegister() async {
            let helper = RecordingHelper(status: .enabled, statusAfterRegister: .requiresApproval)
            let probe = RecordingProbe(result: .zombie)
            let reconciler = PTPHelperReconciler(helper: helper, probe: probe.probe)

            let outcome = await reconciler.reconcile()

            #expect(outcome == .healed(.requiresApproval))
            #expect(helper.recordedCalls == ["unregister", "register"])
        }

        @Test func reconcileReturnsHealthyWithoutHealingWhenProbeIsHealthy() async {
            let helper = RecordingHelper(status: .enabled, statusAfterRegister: .enabled)
            let probe = RecordingProbe(result: .healthy)
            let reconciler = PTPHelperReconciler(helper: helper, probe: probe.probe)

            let outcome = await reconciler.reconcile()

            #expect(outcome == .healthy)
            #expect(helper.recordedCalls.isEmpty)
        }

        @Test func reconcileReturnsIndeterminateWithoutHealingOnPortContention() async {
            let helper = RecordingHelper(status: .enabled, statusAfterRegister: .enabled)
            let probe = RecordingProbe(result: .indeterminate)
            let reconciler = PTPHelperReconciler(helper: helper, probe: probe.probe)

            let outcome = await reconciler.reconcile()

            #expect(outcome == .indeterminate)
            #expect(helper.recordedCalls.isEmpty, "port contention must never be healed")
        }

        // MARK: - Register retry (the live-caught unregister/register race)

        /// LIVE FINDING 2026-08-06: on real launchd, `register()` immediately
        /// after `unregister()` throws while the async teardown is in flight —
        /// the same call succeeds moments later. The heal must retry register,
        /// not report failure on the first throw.
        @Test func healRetriesRegisterThroughTheTeardownRaceAndSucceeds() async {
            let helper = RecordingHelper(status: .enabled, statusAfterRegister: .enabled,
                                         registerThrowsFirst: 2)
            let probe = RecordingProbe(result: .zombie)
            let reconciler = PTPHelperReconciler(helper: helper, probe: probe.probe,
                                                 registerRetryDelay: 0)

            let outcome = await reconciler.reconcile()

            #expect(outcome == .healed(.enabled))
            #expect(helper.recordedCalls == ["unregister", "register", "register", "register"],
                    "two raced throws, then the settled register succeeds")
        }

        @Test func healFailsOnlyAfterExhaustingEveryRegisterAttempt() async {
            let helper = RecordingHelper(status: .enabled, statusAfterRegister: .enabled,
                                         registerThrowsFirst: Int.max)
            let probe = RecordingProbe(result: .zombie)
            let reconciler = PTPHelperReconciler(helper: helper, probe: probe.probe,
                                                 registerRetryDelay: 0,
                                                 registerRetryAttempts: 4)

            let outcome = await reconciler.reconcile()

            #expect(outcome == .healFailed)
            #expect(helper.recordedCalls.filter { $0 == "register" }.count == 4,
                    "every configured attempt is used before giving up")
        }

        // MARK: - Teardown-drain gate (the live-caught delayed-removal loop)

        /// LIVE ROOT CAUSE 2026-08-06: a `register()` accepted while the
        /// unregister teardown is still draining creates a registration a
        /// delayed BTM pass later removes — every launch then finds a real
        /// zombie and heals again, forever. The heal must WAIT until the
        /// record observably reads `.notRegistered` before registering.
        @Test func healWaitsOutTheTeardownDrainThenRegistersAndSucceeds() async {
            let helper = RecordingHelper(status: .enabled, statusAfterRegister: .enabled,
                                         drainStatusReads: 3)
            let probe = RecordingProbe(result: .zombie)
            let reconciler = PTPHelperReconciler(helper: helper, probe: probe.probe,
                                                 registerRetryDelay: 0)

            let outcome = await reconciler.reconcile()

            #expect(outcome == .healed(.enabled))
            #expect(helper.recordedCalls == ["unregister", "register"],
                    "register fires exactly once, only after the drain gate opened")
        }

        @Test func healFailsWithoutEverRegisteringWhenTeardownNeverDrains() async {
            let helper = RecordingHelper(status: .enabled, statusAfterRegister: .enabled,
                                         drainStatusReads: Int.max)
            let probe = RecordingProbe(result: .zombie)
            let reconciler = PTPHelperReconciler(helper: helper, probe: probe.probe,
                                                 registerRetryDelay: 0,
                                                 registerRetryAttempts: 4)

            let outcome = await reconciler.reconcile()

            #expect(outcome == .healFailed)
            #expect(helper.recordedCalls == ["unregister"],
                    "register must NEVER fire into an un-drained teardown — that recreates the doomed-registration loop")
        }

        // MARK: - Telemetry (ptp_zombie_heal)

        @Test func reconcileEmitsPtpZombieHealTelemetryOnlyOnHealPath() async {
            let capturedLines = TelemetryLineBox()
            Telemetry._installTestSink { capturedLines.append($0) }
            defer { Telemetry._installTestSink(nil) }

            let helper = RecordingHelper(status: .enabled, statusAfterRegister: .enabled)
            let probe = RecordingProbe(result: .zombie)
            let reconciler = PTPHelperReconciler(helper: helper, probe: probe.probe)

            let outcome = await reconciler.reconcile()
            Telemetry._installTestSink(nil)   // flush barrier, mirrors NativeCaptureCoordinatorTests

            #expect(outcome == .healed(.enabled))
            let lines = capturedLines.snapshot
            #expect(lines.contains { $0.contains("\"evt\":\"ptp_zombie_heal\"") })
        }

        @Test(arguments: [PTPLivenessProbeResult.healthy, .indeterminate])
        func reconcileEmitsNoPtpZombieHealTelemetryOnNoHealPaths(probeResult: PTPLivenessProbeResult) async {
            let capturedLines = TelemetryLineBox()
            Telemetry._installTestSink { capturedLines.append($0) }
            defer { Telemetry._installTestSink(nil) }

            let helper = RecordingHelper(status: .enabled, statusAfterRegister: .enabled)
            let probe = RecordingProbe(result: probeResult)
            let reconciler = PTPHelperReconciler(helper: helper, probe: probe.probe)

            _ = await reconciler.reconcile()
            Telemetry._installTestSink(nil)

            let lines = capturedLines.snapshot
            #expect(!lines.contains { $0.contains("\"evt\":\"ptp_zombie_heal\"") })
        }

        @Test func reconcileEmitsHealFailedTelemetryWhenTeardownNeverDrains() async {
            let capturedLines = TelemetryLineBox()
            Telemetry._installTestSink { capturedLines.append($0) }
            defer { Telemetry._installTestSink(nil) }

            let helper = RecordingHelper(status: .enabled, statusAfterRegister: .enabled,
                                         drainStatusReads: Int.max)
            let probe = RecordingProbe(result: .zombie)
            let reconciler = PTPHelperReconciler(helper: helper, probe: probe.probe,
                                                 registerRetryDelay: 0,
                                                 registerRetryAttempts: 2)

            _ = await reconciler.reconcile()
            Telemetry._installTestSink(nil)

            let lines = capturedLines.snapshot
            #expect(lines.contains {
                $0.contains("\"evt\":\"ptp_zombie_heal\"") && $0.contains("\"result\":\"heal_failed\"")
            })
        }

        @Test func reconcileEmitsNoPtpZombieHealTelemetryForNonEnabledStatus() async {
            let capturedLines = TelemetryLineBox()
            Telemetry._installTestSink { capturedLines.append($0) }
            defer { Telemetry._installTestSink(nil) }

            let helper = RecordingHelper(status: .requiresApproval, statusAfterRegister: .enabled)
            let probe = RecordingProbe(result: .zombie)
            let reconciler = PTPHelperReconciler(helper: helper, probe: probe.probe)

            _ = await reconciler.reconcile()
            Telemetry._installTestSink(nil)

            let lines = capturedLines.snapshot
            #expect(!lines.contains { $0.contains("\"evt\":\"ptp_zombie_heal\"") })
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
