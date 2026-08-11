// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudiouterCore

/// The setup flow's DECISION LOG: every Allow click and every Done
/// verification ends in exactly one named `Telemetry` outcome, so a live
/// session's misbehaviour ("Start listening took two clicks", 2026-08-11) is
/// read from the trail instead of guessed at.
///
/// Lives under `SerializedSharedState` because `Telemetry._installTestSink` is
/// process-global — a sink user outside the parent tears other tests' sinks
/// out from under them mid-run (see the parent's doc; the Allow test moved
/// here from `SetupFlowModelTests` for exactly that reason).
extension SerializedSharedState {
    @MainActor
    @Suite final class SetupTelemetryTests: IsolatedSuite {

        // MARK: Minimal canned seams (everything statuses need, nothing more)

        private struct CannedAudio: AudioCapturePermissionProbing {
            let result: PermissionStatus
            func probe() async -> PermissionStatus { result }
            func currentStatusSilently() -> PermissionStatus? { result }
        }
        private struct ReachableNetwork: LocalNetworkPriming {
            func probe() async -> Bool { true }
        }
        private struct UntrustedRemote: RemoteControlPriming {
            func prime() {}
            func isTrusted() -> Bool { false }
        }
        private struct CannedPTPHelper: PTPHelperManaging {
            let status: PTPHelperStatus
            func register() throws {}
            func openSystemSettingsLoginItems() {}
            func unregister() async throws {}
        }

        /// A flow whose three required permissions are granted except,
        /// optionally, Speaker Sync — the walk `verifyForDone` re-audits.
        private func makeFlow(audio: PermissionStatus = .granted,
                              ptpHelper: PTPHelperStatus = .enabled) async -> SetupFlowModel {
            let setup = SetupModel(audioProbe: CannedAudio(result: audio),
                                   localNetwork: ReachableNetwork(),
                                   remoteControl: UntrustedRemote(),
                                   ptpHelper: CannedPTPHelper(status: ptpHelper),
                                   settings: AppSettings(defaults: isolatedDefaults))
            await setup.requestAudioCapture()
            await setup.primeLocalNetwork()
            await setup.refreshStatuses()
            return SetupFlowModel(setup: setup)
        }

        /// Every Allow click ends in exactly ONE named outcome in the decision log.
        @Test func everyAllowClickLogsExactlyOneNamedOutcome() async throws {
            let setup = SetupModel(audioProbe: CannedAudio(result: .granted),
                                   localNetwork: ReachableNetwork(),
                                   remoteControl: UntrustedRemote(),
                                   ptpHelper: CannedPTPHelper(status: .notRegistered),
                                   settings: AppSettings(defaults: isolatedDefaults))
            let flow = SetupFlowModel(setup: setup)
            let capture = TelemetrySetupLineCapture()
            Telemetry._installTestSink { capture.append($0) }
            _ = await flow.allow(.audio)
            Telemetry._installTestSink(nil)   // flush barrier (serial queue) + removes the sink

            let lines = capture.snapshot().filter { $0.contains("\"evt\":\"setup_allow\"") }
            #expect(lines.count == 1, "one click, one outcome: \(lines)")
            let line = try #require(lines.first)
            #expect(line.contains("\"step\":\"audio\""), "line: \(line)")
            #expect(line.contains("\"outcome\":\"prompt_triggered\""), "line: \(line)")
        }

        /// Every Done verification leaves exactly ONE named `setup_done`
        /// outcome — finished, or refused naming the unmet permission. (The
        /// third outcome, `swallowed_in_flight`, is the UI single-flight
        /// guard's line; the swallow behaviour itself is pinned by
        /// `OnboardingUITests.aSecondClickDuringDoneVerificationIsANoOp`.)
        @Test func verifyForDoneLogsFinishedOrRefusedWithTheUnmetPermission() async throws {
            let granted = await makeFlow()
            let revoked = await makeFlow(ptpHelper: .requiresApproval)
            let capture = TelemetrySetupLineCapture()
            Telemetry._installTestSink { capture.append($0) }
            _ = await granted.verifyForDone()
            _ = await revoked.verifyForDone()
            Telemetry._installTestSink(nil)   // flush barrier (serial queue) + removes the sink

            let lines = capture.snapshot().filter { $0.contains("\"evt\":\"setup_done\"") }
            #expect(lines.count == 2, "one outcome per verification: \(lines)")
            #expect(try #require(lines.first).contains("\"outcome\":\"finished\""))
            let refused = try #require(lines.last)
            #expect(refused.contains("\"outcome\":\"refused\""), "line: \(refused)")
            #expect(refused.contains("\"unmet\":\"speaker_sync\""), "names the permission: \(refused)")
        }
    }
}

/// Captures lines from an installed `Telemetry` test sink. The sink is invoked
/// from `Telemetry`'s own serial writer queue (a different thread than the test
/// body), so a plain captured `var` won't do — same NSLock-guarded box
/// `SetupModelTests` uses for the reported-vs-actual lines.
private final class TelemetrySetupLineCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.withLock { lines.append(line) } }
    func snapshot() -> [String] { lock.withLock { lines } }
}
