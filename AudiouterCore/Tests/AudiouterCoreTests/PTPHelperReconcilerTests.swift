// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudiouterCore

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
        private struct FakeHelperStatus: PTPHelperManaging {
            let status: PTPHelperStatus
            func register() throws {}
            func openSystemSettingsLoginItems() {}
            func unregister() async throws {}
        }

        /// Records the ORDER `unregister()`/`register()` are called in and
        /// lets `status` change after `register()` runs — so a test can drive
        /// the post-heal re-read to either `.enabled` or `.requiresApproval`.
        /// `@unchecked Sendable` because `NSLock` provides the synchronization
        /// the compiler cannot see (mirrors ``ProbeResumeGate``'s own posture).
        private final class RecordingHelper: PTPHelperManaging, @unchecked Sendable {
            private let lock = NSLock()
            private var _status: PTPHelperStatus
            private let statusAfterRegister: PTPHelperStatus
            private(set) var calls: [String] = []

            init(status: PTPHelperStatus, statusAfterRegister: PTPHelperStatus) {
                self._status = status
                self.statusAfterRegister = statusAfterRegister
            }

            var status: PTPHelperStatus { lock.withLock { _status } }

            func register() throws {
                lock.withLock {
                    calls.append("register")
                    _status = statusAfterRegister
                }
            }

            func openSystemSettingsLoginItems() {}

            func unregister() async throws {
                lock.withLock { calls.append("unregister") }
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
