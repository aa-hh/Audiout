// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudiouterCore

/// `SetupFlowModel` sequences the five permission cards over `SetupModel`'s
/// statuses. These pin the things the UI can't be trusted to re-derive: the
/// advance order, that skipping records without granting, the two auto-passes (a
/// hard gate must never demand what the OS can't give), the Done gate, the
/// snap-back target behind a Done tap, and where a re-entry starts.
///
/// Hermetic: every seam is a scripted fake, so no probe, prompt, or Core Audio.
@MainActor
@Suite final class SetupFlowModelTests: IsolatedSuite {

    // MARK: Fakes

    private struct CannedAudioProbe: AudioCapturePermissionProbing {
        let result: PermissionStatus
        func probe() async -> PermissionStatus { result }
        func currentStatusSilently() -> PermissionStatus? { result }
    }

    private struct CannedLocalNetwork: LocalNetworkPriming {
        let reachable: Bool
        func probe() async -> Bool { reachable }
    }

    private struct CannedRemoteControl: RemoteControlPriming {
        let trusted: Bool
        func prime() {}
        func isTrusted() -> Bool { trusted }
    }

    private struct CannedPTPHelper: PTPHelperManaging {
        let status: PTPHelperStatus
        func register() throws {}
        func openSystemSettingsLoginItems() {}
        func unregister() async throws {}
    }

    /// A model wired to canned seams, with every status still at its initial
    /// value — nothing has been asked yet.
    private func makeSetup(
        audio: PermissionStatus = .unknown,
        localNetworkReachable: Bool = false,
        bluetooth: PermissionStatus = .unknown,
        ptpHelper: PTPHelperStatus = .notRegistered,
        remoteControlTrusted: Bool = false,
        localNetworkGated: Bool = true
    ) -> SetupModel {
        SetupModel(audioProbe: CannedAudioProbe(result: audio),
                   localNetwork: CannedLocalNetwork(reachable: localNetworkReachable),
                   remoteControl: CannedRemoteControl(trusted: remoteControlTrusted),
                   ptpHelper: CannedPTPHelper(status: ptpHelper),
                   bluetoothReader: SimulatedBluetoothPermission(status: bluetooth),
                   bluetoothPrimer: SimulatedBluetoothPermission(status: bluetooth),
                   settings: AppSettings(defaults: isolatedDefaults),
                   localNetworkGated: localNetworkGated)
    }

    /// Run what the cards run, in flow order, so the statuses under test are ones
    /// `SetupModel` can really produce. WHEN this runs relative to
    /// `SetupFlowModel(setup:)` is load-bearing: the flow's entry point is fixed
    /// at construction, so priming FIRST models a re-entry and priming AFTER
    /// models a user working down a fresh flow.
    private func prime(_ model: SetupModel) async {
        await model.requestAudioCapture()
        if model.isLocalNetworkGated { await model.primeLocalNetwork() }
        await model.refreshStatuses()   // Bluetooth, Speaker Sync, Remote Control
    }

    /// A re-entry onto everything a first run needs: the three required
    /// permissions, all satisfied.
    private func makeFullyGrantedFlow() async -> SetupFlowModel {
        let setup = makeSetup(audio: .granted, localNetworkReachable: true, ptpHelper: .enabled)
        await prime(setup)
        return SetupFlowModel(setup: setup)
    }

    // MARK: Order + advance

    @Test func stepOrderIsTheSpecOrder() {
        #expect(SetupFlowModel.steps == [.audio, .localNetwork, .bluetooth, .speakerSync, .remoteControl])
        #expect(SetupFlowModel.skippableSteps == [.bluetooth, .remoteControl])
    }

    @Test func freshFlowStartsOnSystemAudio() {
        let flow = SetupFlowModel(setup: makeSetup())
        #expect(flow.activeStep == .audio)
        #expect(flow.display(.audio) == .active)
        #expect(flow.display(.localNetwork) == .pending)
        #expect(flow.display(.remoteControl) == .pending)
    }

    /// Exactly one card is expanded at a time, and a granted card collapses with
    /// a checkmark as the next one opens.
    @Test func grantingAStepAdvancesToTheNext() async {
        let setup = makeSetup(audio: .granted)
        let flow = SetupFlowModel(setup: setup)
        #expect(flow.activeStep == .audio)

        await setup.requestAudioCapture()

        #expect(flow.display(.audio) == .completed)
        #expect(flow.activeStep == .localNetwork)
        #expect(SetupFlowModel.steps.filter { flow.display($0) == .active }.count == 1)
    }

    /// Local Network completes on `.granted` ONLY. `.requested` is the honest
    /// "asked, but nothing answered" state — indistinguishable from a denial, so
    /// it must never read as done.
    @Test func localNetworkRequestedDoesNotComplete() async {
        let setup = makeSetup(audio: .granted, localNetworkReachable: false)
        let flow = SetupFlowModel(setup: setup)
        await prime(setup)

        #expect(setup.localNetworkStatus == .requested, "browse reached nothing")
        #expect(flow.display(.localNetwork) == .active)
        #expect(!flow.isDoneAvailable)
    }

    @Test func everyStepGrantedLeavesNoActiveStep() async {
        let setup = makeSetup(audio: .granted, localNetworkReachable: true,
                              bluetooth: .granted, ptpHelper: .enabled,
                              remoteControlTrusted: true)
        let flow = SetupFlowModel(setup: setup)
        await prime(setup)

        #expect(flow.activeStep == nil)
        #expect(SetupFlowModel.steps.allSatisfy { flow.display($0) == .completed })
    }

    // MARK: Skipping

    @Test func skippingAdvancesButNeverCounts() async {
        let setup = makeSetup(audio: .granted, localNetworkReachable: true)
        let flow = SetupFlowModel(setup: setup)
        await prime(setup)
        #expect(flow.activeStep == .bluetooth)

        flow.skip(.bluetooth)

        #expect(flow.activeStep == .speakerSync, "a skip advances past the step")
        #expect(!flow.isComplete(.bluetooth), "skipped is NOT granted")
        #expect(flow.display(.bluetooth) == .pending, "collapsed, and unchecked")
        #expect(flow.skippedSteps == [.bluetooth])
    }

    /// A required card can't be talked out of the flow — the gate IS the product
    /// decision, so `skip` refuses it rather than quietly recording it.
    @Test func requiredStepsCannotBeSkipped() {
        let flow = SetupFlowModel(setup: makeSetup())
        flow.skip(.audio)
        #expect(flow.skippedSteps.isEmpty)
        #expect(flow.activeStep == .audio)
    }

    /// A skipped step that the user later grants anyway (in System Settings)
    /// shows its checkmark — the honest read wins over the record of the skip.
    @Test func skippedStepStillCompletesIfGrantedLater() async {
        let setup = makeSetup(audio: .granted, localNetworkReachable: true, bluetooth: .granted)
        let flow = SetupFlowModel(setup: setup)
        flow.skip(.bluetooth)
        await prime(setup)
        #expect(flow.display(.bluetooth) == .completed)
    }

    // MARK: Auto-pass (a hard gate must never demand the impossible)

    /// macOS < 14.2 has no process-tap API, so no grant exists to give: the card
    /// must not block, and its status stays honestly `.unsupported` rather than
    /// being rewritten to a grant nobody made.
    @Test func audioAutoPassesWhenUnsupported() async {
        let setup = makeSetup(audio: .unsupported, localNetworkReachable: true, ptpHelper: .enabled)
        await prime(setup)
        let flow = SetupFlowModel(setup: setup)

        #expect(flow.isComplete(.audio))
        #expect(setup.audioStatus == .unsupported, "the status itself is never faked")
        #expect(flow.isDoneAvailable)
    }

    /// macOS 14 has no Local Network privacy gate at all — nothing to grant, and
    /// no Settings pane to send anyone to.
    @Test func localNetworkAutoPassesWhenTheOSDoesNotGateIt() async {
        let setup = makeSetup(audio: .granted, ptpHelper: .enabled, localNetworkGated: false)
        await prime(setup)
        let flow = SetupFlowModel(setup: setup)

        #expect(flow.isComplete(.localNetwork))
        #expect(flow.activeStep == .bluetooth, "the ungated card is passed, not asked")
        #expect(flow.isDoneAvailable)
    }

    // MARK: The Done gate

    @Test func doneIsUnavailableUntilEveryRequiredPermissionVerifies() async {
        #expect(!SetupFlowModel(setup: makeSetup()).isDoneAvailable)

        let partial = makeSetup(audio: .granted, localNetworkReachable: true)
        await prime(partial)
        #expect(!SetupFlowModel(setup: partial).isDoneAvailable, "Speaker Sync still unmet")

        #expect(await makeFullyGrantedFlow().isDoneAvailable)
    }

    /// The two skippable cards are outside `RequiredPermission`, so neither an
    /// untouched nor a skipped one can hold Done shut.
    @Test func skippableStepsNeverAffectTheGate() async {
        let flow = await makeFullyGrantedFlow()
        #expect(flow.isDoneAvailable)
        flow.skip(.bluetooth)
        flow.skip(.remoteControl)
        #expect(flow.isDoneAvailable)
    }

    // MARK: verifyForDone

    @Test func verifyForDoneReportsCompleteWhenEverythingHolds() async {
        let flow = await makeFullyGrantedFlow()
        #expect(await flow.verifyForDone() == .complete)
    }

    /// The revocation case: something was turned off while setup was open, so
    /// Done must refuse and name the card to snap back to.
    @Test func verifyForDoneReportsTheFirstUnmetStep() async {
        let setup = makeSetup(audio: .granted, localNetworkReachable: true, ptpHelper: .requiresApproval)
        await prime(setup)
        let flow = SetupFlowModel(setup: setup)
        #expect(await flow.verifyForDone() == .unmet(.speakerSync))
    }

    /// First unmet means FIRST: an audio failure outranks a later one, so the
    /// user is sent to the card at the top of the flow.
    @Test func verifyForDoneSnapsBackToTheEarliestUnmetStep() async {
        let setup = makeSetup(audio: .denied, localNetworkReachable: false, ptpHelper: .requiresApproval)
        await prime(setup)
        let flow = SetupFlowModel(setup: setup)
        #expect(await flow.verifyForDone() == .unmet(.audio))
    }

    /// `verifyForDone` re-reads SILENTLY. The audible tone probe belongs to an
    /// explicit Allow tap only — replaying it behind a Done tap is the
    /// ONBOARD-TONE bug in a new place.
    @Test func verifyForDoneNeverReplaysTheAudibleProbe() async {
        let audio = CountingAudioProbe()
        let setup = SetupModel(audioProbe: audio,
                               localNetwork: CannedLocalNetwork(reachable: true),
                               remoteControl: CannedRemoteControl(trusted: false),
                               ptpHelper: CannedPTPHelper(status: .enabled),
                               settings: AppSettings(defaults: isolatedDefaults))
        await setup.requestAudioCapture()      // the one legitimate audible call
        await setup.primeLocalNetwork()
        let flow = SetupFlowModel(setup: setup)

        #expect(await flow.verifyForDone() == .complete)
        #expect(audio.probeCount == 1, "Done must not re-run the tone probe")
        #expect(audio.silentCount > 0, "…it re-reads silently instead")
    }

    private final class CountingAudioProbe: AudioCapturePermissionProbing, @unchecked Sendable {
        private let lock = NSLock()
        private var _probeCount = 0
        private var _silentCount = 0
        var probeCount: Int { lock.withLock { _probeCount } }
        var silentCount: Int { lock.withLock { _silentCount } }
        func probe() async -> PermissionStatus {
            lock.withLock { _probeCount += 1 }
            return .granted
        }
        func currentStatusSilently() -> PermissionStatus? {
            lock.withLock { _silentCount += 1 }
            return .granted
        }
    }

    // MARK: Re-entry

    /// A `.permissionLost` reopen starts on the card that was lost, not back at
    /// the top and not on an optional card the user never engaged: Bluetooth is
    /// neither complete nor skipped here, yet the flow opens on Speaker Sync.
    @Test func reEntryStartsOnTheFirstUnmetRequiredStep() async {
        let setup = makeSetup(audio: .granted, localNetworkReachable: true, ptpHelper: .requiresApproval)
        await prime(setup)
        let flow = SetupFlowModel(setup: setup)

        #expect(flow.activeStep == .speakerSync)
        #expect(flow.display(.audio) == .completed, "earlier granted cards start collapsed-completed")
        #expect(flow.display(.localNetwork) == .completed)
        #expect(flow.display(.bluetooth) == .pending, "an optional card behind the entry point stays collapsed")
    }

    /// Reopening a fully-satisfied setup by hand has no required step to land
    /// on, so it offers the optional ones — and Done is available throughout.
    @Test func reEntryWithNothingUnmetOffersTheOptionalSteps() async {
        let flow = await makeFullyGrantedFlow()
        #expect(flow.activeStep == .bluetooth)
        #expect(flow.isDoneAvailable)
    }
}
