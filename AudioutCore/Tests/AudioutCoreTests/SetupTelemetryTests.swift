// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import Foundation
import Testing
@testable import AudioutCore
@testable import AudioutOnboardingUI

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

        /// The AUTOMATIC check leaves its own named outcome beside the click's
        /// — passed, or refused naming the unmet permission — so a live trail
        /// shows the check the user watched apart from the click they made.
        @Test func theAutoCheckLogsPassedOrRefusedWithTheUnmetPermission() async throws {
            let granted = await makeFlow()
            let revoked = await makeFlow(ptpHelper: .requiresApproval)
            let capture = TelemetrySetupLineCapture()
            Telemetry._installTestSink { capture.append($0) }
            _ = await granted.runFinalCheck()
            _ = await revoked.runFinalCheck()
            Telemetry._installTestSink(nil)   // flush barrier (serial queue) + removes the sink

            let lines = capture.snapshot().filter { $0.contains("\"evt\":\"setup_done\"") }
            #expect(lines.count == 2, "one outcome per check: \(lines)")
            #expect(try #require(lines.first).contains("\"outcome\":\"auto_check_passed\""))
            let refused = try #require(lines.last)
            #expect(refused.contains("\"outcome\":\"auto_check_refused\""), "line: \(refused)")
            #expect(refused.contains("\"unmet\":\"speaker_sync\""), "names the permission: \(refused)")
        }

        /// A `register()` that throws is a packaging/signing fault the user can
        /// neither see nor fix, and stderr dies with the process — so it has to
        /// reach the decision log, where a support ticket can quote it.
        @Test func aFailedPTPHelperRegistrationReachesTheDecisionLog() throws {
            struct RegistrationFailed: Error {}
            struct FailingPTPHelper: PTPHelperManaging {
                let status: PTPHelperStatus = .notRegistered
                func register() throws { throw RegistrationFailed() }
                func openSystemSettingsLoginItems() {}
                func unregister() async throws {}
            }
            let setup = SetupModel(audioProbe: CannedAudio(result: .granted),
                                   localNetwork: ReachableNetwork(),
                                   remoteControl: UntrustedRemote(),
                                   ptpHelper: FailingPTPHelper(),
                                   settings: AppSettings(defaults: isolatedDefaults))
            let capture = TelemetrySetupLineCapture()
            Telemetry._installTestSink { capture.append($0) }
            setup.registerPTPHelper()
            Telemetry._installTestSink(nil)   // flush barrier (serial queue) + removes the sink

            let lines = capture.snapshot().filter { $0.contains("\"evt\":\"ptp_register_failed\"") }
            #expect(lines.count == 1, "one failure, one line: \(lines)")
            #expect(try #require(lines.first).contains("RegistrationFailed"),
                    "the error itself is in the line: \(lines)")
            #expect(setup.ptpHelperRegistrationFailed)
        }

        /// Every physical click on the Setup window leaves a `setup_click`
        /// down/up pair naming what it hit — the witness for a live click
        /// that dies before any control's action (the "first CTA click left
        /// no trace" symptom: with this, silence means the click never
        /// reached the app at all).
        @Test func aPhysicalClickOnTheSetupWindowLeavesDownAndUpLines() throws {
            let setup = SetupModel(audioProbe: CannedAudio(result: .granted),
                                   localNetwork: ReachableNetwork(),
                                   remoteControl: UntrustedRemote(),
                                   ptpHelper: CannedPTPHelper(status: .enabled),
                                   settings: AppSettings(defaults: isolatedDefaults))
            let wc = OnboardingWindowController(model: setup,
                                                openSettings: { _ in },
                                                onFinished: {})
            let window = try #require(wc.window)
            window.contentView?.layoutSubtreeIfNeeded()
            let capture = TelemetrySetupLineCapture()
            Telemetry._installTestSink { capture.append($0) }
            // An inert corner of the canvas — never a control, so this
            // headless dispatch cannot start a button tracking loop.
            let corner = NSPoint(x: 2, y: 2)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: corner,
                                                  modifierFlags: [], timestamp: 0,
                                                  windowNumber: window.windowNumber,
                                                  context: nil, eventNumber: 0,
                                                  clickCount: 1, pressure: 1) {
                    window.sendEvent(event)
                }
            }
            Telemetry._installTestSink(nil)   // flush barrier (serial queue) + removes the sink

            let lines = capture.snapshot().filter { $0.contains("\"evt\":\"setup_click\"") }
            #expect(lines.count == 2, "one line per phase: \(lines)")
            #expect(try #require(lines.first).contains("\"phase\":\"down\""))
            #expect(try #require(lines.last).contains("\"phase\":\"up\""))
            #expect(lines.allSatisfy { $0.contains("\"hit\":") && $0.contains("\"app_active\":")
                        && $0.contains("\"key\":") },
                    "each line snapshots delivery state: \(lines)")
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
