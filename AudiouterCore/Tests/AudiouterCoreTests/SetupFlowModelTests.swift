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

    /// Reports a fixed ``LocalNetworkOutcome`` — the answers only a primer that
    /// watches the mDNS policy error can give (a real refusal), and the grant
    /// self-discovery proves on a network with no speaker on it.
    private struct CannedOutcomeLocalNetwork: LocalNetworkPriming {
        let outcome: LocalNetworkOutcome
        func probe() async -> Bool {
            guard case .granted(let found) = outcome else { return false }
            return found > 0
        }
        func prime(browseSeconds: TimeInterval,
                   onReachable: @escaping @Sendable () -> Void) async -> LocalNetworkOutcome {
            if case .granted = outcome { onReachable() }
            return outcome
        }
    }

    /// A prime that always PROVES the grant (what self-discovery does), while
    /// reporting a scripted speaker count per call — the "granted, but nothing
    /// switched on yet" case. The last count repeats.
    private final class GrantingLocalNetwork: LocalNetworkPriming, @unchecked Sendable {
        private let lock = NSLock()
        private let counts: [Int]
        private var index = 0
        init(_ counts: [Int]) { self.counts = counts }
        func probe() async -> Bool { true }
        func prime(browseSeconds: TimeInterval,
                   onReachable: @escaping @Sendable () -> Void) async -> LocalNetworkOutcome {
            onReachable()
            let count = lock.withLock { () -> Int in
                let count = counts[min(index, counts.count - 1)]
                index += 1
                return count
            }
            return .granted(foundSpeakers: count)
        }
    }

    /// A browse whose result changes from call to call — how "turn a speaker on,
    /// then try again" is modelled: the first browse finds nothing, the next one
    /// finds speakers. The last count repeats once the script runs out.
    private final class ScriptedLocalNetwork: LocalNetworkPriming, @unchecked Sendable {
        private let lock = NSLock()
        private let counts: [Int]
        private var index = 0
        init(_ counts: [Int]) { self.counts = counts }
        func probeFoundSpeakers() async -> Int {
            lock.withLock {
                let count = counts[min(index, counts.count - 1)]
                index += 1
                return count
            }
        }
        func probe() async -> Bool { await probeFoundSpeakers() > 0 }
    }

    /// A Bluetooth prompt that NEVER reports back — the wedge case: the decision
    /// callback that `CBCentralManager` is supposed to deliver simply doesn't.
    private struct NeverDecidingBluetooth: BluetoothPermissionPriming {
        func prime(onDecided: @escaping @Sendable () -> Void) {}
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
        localNetwork: LocalNetworkPriming? = nil,
        bluetooth: PermissionStatus = .unknown,
        bluetoothPrimer: BluetoothPermissionPriming? = nil,
        bluetoothPromptTimeout: TimeInterval = 10,
        ptpHelper: PTPHelperStatus = .notRegistered,
        ptpHelperManager: PTPHelperManaging? = nil,
        remoteControlTrusted: Bool = false,
        localNetworkGated: Bool = true
    ) -> SetupModel {
        SetupModel(audioProbe: CannedAudioProbe(result: audio),
                   localNetwork: localNetwork ?? CannedLocalNetwork(reachable: localNetworkReachable),
                   remoteControl: CannedRemoteControl(trusted: remoteControlTrusted),
                   ptpHelper: ptpHelperManager ?? CannedPTPHelper(status: ptpHelper),
                   bluetoothReader: SimulatedBluetoothPermission(status: bluetooth),
                   bluetoothPrimer: bluetoothPrimer ?? SimulatedBluetoothPermission(status: bluetooth),
                   settings: AppSettings(defaults: isolatedDefaults),
                   localNetworkGated: localNetworkGated,
                   bluetoothPromptTimeout: bluetoothPromptTimeout)
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
        #expect(flow.isReadyForFinalCheck, "every card decided by a grant readies the check")
        #expect(!flow.isDoneAvailable, "the gate waits for the check itself")

        #expect(await flow.runFinalCheck() == .complete)

        #expect(flow.isDoneAvailable, "the passed check opens the gate")
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
        flow.skip(.bluetooth)
        flow.skip(.remoteControl)
        #expect(flow.isReadyForFinalCheck, "the auto-pass counts as decided — it never blocks the check")
    }

    /// macOS 14 has no Local Network privacy gate at all — nothing to grant, and
    /// no Settings pane to send anyone to.
    @Test func localNetworkAutoPassesWhenTheOSDoesNotGateIt() async {
        let setup = makeSetup(audio: .granted, ptpHelper: .enabled, localNetworkGated: false)
        await prime(setup)
        let flow = SetupFlowModel(setup: setup)

        #expect(flow.isComplete(.localNetwork))
        #expect(flow.activeStep == .bluetooth, "the ungated card is passed, not asked")
        flow.skip(.bluetooth)
        flow.skip(.remoteControl)
        #expect(flow.isReadyForFinalCheck, "the auto-pass counts as decided — it never blocks the check")
    }

    // MARK: The Done gate

    @Test func doneIsUnavailableUntilEveryRequiredPermissionVerifies() async {
        #expect(!SetupFlowModel(setup: makeSetup()).isDoneAvailable)

        let partial = makeSetup(audio: .granted, localNetworkReachable: true)
        await prime(partial)
        #expect(!SetupFlowModel(setup: partial).isReadyForFinalCheck, "Speaker Sync still unmet")

        let flow = await makeFullyGrantedFlow()
        flow.skip(.bluetooth)
        flow.skip(.remoteControl)
        #expect(!flow.isDoneAvailable, "decided is not yet checked")
        _ = await flow.runFinalCheck()
        #expect(flow.isDoneAvailable)
    }

    /// Owner decision 2026-08-11 (tightened gate): the optional cards'
    /// PERMISSIONS stay outside the gate, but an UNDECIDED card holds the
    /// check back — it runs only once every card is granted, auto-passed, or
    /// explicitly skipped, so it can never run beside a card still offering
    /// Allow/Skip. A skip is the decision that clears it.
    @Test func anUndecidedOptionalCardHoldsTheCheckAndASkipReadiesIt() async {
        let flow = await makeFullyGrantedFlow()
        #expect(!flow.isReadyForFinalCheck, "Bluetooth is still sitting undecided")
        flow.skip(.bluetooth)
        #expect(!flow.isReadyForFinalCheck, "…and Remote Control after it")
        flow.skip(.remoteControl)
        #expect(flow.isReadyForFinalCheck)
    }

    // MARK: The final check

    /// The row's walk: pending until every card is decided, running while the
    /// audit runs, passed once it lands — and only the pass opens the gate.
    @Test func theFinalCheckPassesAndOpensTheGate() async {
        let flow = await makeFullyGrantedFlow()
        #expect(flow.finalCheckState == .pending)
        flow.skip(.bluetooth)
        flow.skip(.remoteControl)
        #expect(flow.finalCheckState == .pending, "readiness alone is not a pass")

        #expect(await flow.runFinalCheck() == .complete)

        #expect(flow.finalCheckState == .passed)
        #expect(flow.isDoneAvailable)
    }

    /// A silent read that disagrees with the cached grant refuses the check:
    /// the verdict names the step, the state reverts to pending, and the gate
    /// stays shut.
    @Test func aRefusedFinalCheckRevertsToPendingAndNamesTheStep() async {
        let audio = TwoFacedAudioProbe(probed: .granted, silent: .denied)
        let setup = SetupModel(audioProbe: audio,
                               localNetwork: CannedLocalNetwork(reachable: true),
                               remoteControl: CannedRemoteControl(trusted: false),
                               ptpHelper: CannedPTPHelper(status: .enabled),
                               settings: AppSettings(defaults: isolatedDefaults))
        await setup.requestAudioCapture()
        await setup.primeLocalNetwork()
        // The plain refresh leaves a cached GRANTED audio alone (it only
        // silently re-reads engaged-and-unhappy rows), so readiness holds
        // until the audit's own silent read finds the revocation.
        await setup.refreshStatuses()
        let flow = SetupFlowModel(setup: setup)
        flow.skip(.bluetooth)
        flow.skip(.remoteControl)
        #expect(flow.isReadyForFinalCheck)

        #expect(await flow.runFinalCheck() == .unmet(.audio))

        #expect(flow.finalCheckState == .pending, "a refusal reverts the row")
        #expect(!flow.isDoneAvailable)
    }

    /// A revocation AFTER the pass closes the gate on its own: the state
    /// derives pending the moment readiness is lost, so the CTA can never sit
    /// beside a re-opened card.
    @Test func aRevocationAfterThePassClosesTheGate() async {
        let helper = MutablePTPHelper(.enabled)
        let setup = makeSetup(audio: .granted, localNetworkReachable: true, ptpHelperManager: helper)
        await prime(setup)
        let flow = SetupFlowModel(setup: setup)
        flow.skip(.bluetooth)
        flow.skip(.remoteControl)
        _ = await flow.runFinalCheck()
        #expect(flow.isDoneAvailable)

        helper.status = .requiresApproval
        await setup.refreshStatuses()

        #expect(!flow.isDoneAvailable)
        #expect(flow.finalCheckState == .pending)
    }

    /// Reports `probed` to the tone probe and `silent` to the silent read —
    /// how a mid-presentation revocation reaches the audit.
    private struct TwoFacedAudioProbe: AudioCapturePermissionProbing {
        let probed: PermissionStatus
        let silent: PermissionStatus
        func probe() async -> PermissionStatus { probed }
        func currentStatusSilently() -> PermissionStatus? { silent }
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
    /// on, so it offers the optional ones — and with the tightened gate they
    /// must each be decided (the skip set is per-presentation) before Done
    /// exists.
    @Test func reEntryWithNothingUnmetOffersTheOptionalSteps() async {
        let flow = await makeFullyGrantedFlow()
        #expect(flow.activeStep == .bluetooth)
        #expect(!flow.isReadyForFinalCheck, "the offered cards are undecided this presentation")
        flow.skip(.bluetooth)
        flow.skip(.remoteControl)
        _ = await flow.runFinalCheck()
        #expect(flow.isDoneAvailable)
    }

    /// A `.permissionLost` re-entry: the walk starts at the lost required step,
    /// so an undecided optional card BEHIND that start (Bluetooth here) is not
    /// walked and can never hold the tightened gate — re-granting the lost
    /// permission plus deciding the cards the flow actually shows (Remote
    /// Control, which the flow re-activated on re-entry before this gate
    /// existed too) is all Done asks for.
    @Test func reEntryGateIgnoresOptionalCardsBehindTheStart() async {
        let helper = MutablePTPHelper(.requiresApproval)
        let setup = makeSetup(audio: .granted, localNetworkReachable: true, ptpHelperManager: helper)
        await prime(setup)
        let flow = SetupFlowModel(setup: setup)
        #expect(flow.activeStep == .speakerSync, "the re-entry opens on the lost step")

        helper.status = .enabled          // the Login Items re-grant lands…
        await setup.refreshStatuses()     // …and the focus-return refresh sees it

        #expect(flow.activeStep == .remoteControl, "the walk continues to the card it shows")
        #expect(!flow.isReadyForFinalCheck, "that shown card is undecided")
        flow.skip(.remoteControl)
        _ = await flow.runFinalCheck()
        #expect(flow.isDoneAvailable, "Bluetooth, behind the start, never blocked the gate")
    }

    private final class MutablePTPHelper: PTPHelperManaging {
        var status: PTPHelperStatus
        init(_ status: PTPHelperStatus) { self.status = status }
        func register() throws {}
        func openSystemSettingsLoginItems() {}
        func unregister() async throws {}
    }

    // MARK: The Allow click (sequencing rules)

    @Test func firstAllowFiresThePromptAndNeverOpensSettings() async {
        let flow = SetupFlowModel(setup: makeSetup(audio: .granted))
        let result = await flow.allow(.audio)
        #expect(result.outcome == .promptTriggered)
        #expect(result.destination == .none)
    }

    /// A probe that ran and came back without a grant is its own outcome — the
    /// click asked, the answer was no.
    @Test func aProbeThatDoesNotLandReportsTimeout() async {
        let flow = SetupFlowModel(setup: makeSetup(audio: .denied))
        #expect(await flow.allow(.audio).outcome == .probeTimeout)
    }

    /// Preflight: a determined-and-denied permission's prompt silently no-ops,
    /// so the SECOND click must skip it and go straight to the pane.
    @Test func aSecondAllowOnDeniedAudioDeepLinksInstead() async {
        let setup = makeSetup(audio: .denied)
        let flow = SetupFlowModel(setup: setup)
        _ = await flow.allow(.audio)   // first click: the probe runs, lands denied

        let result = await flow.allow(.audio)

        #expect(result.outcome == .settingsFallbackDenied)
        #expect(result.destination == .settingsPane(.screenAndSystemAudioRecording))
    }

    /// Local Network is the one card whose "prompt" IS the browse, so an empty
    /// browse must stay RE-RUNNABLE: the card told the user to turn a speaker on
    /// and try again, and a click that deep-linked to Settings instead would
    /// leave nothing at all able to re-browse. It must also open nothing — the
    /// pane is offered beside the retry by the UI, not by this click.
    @Test func anEmptyLocalNetworkBrowseIsRetriedRatherThanDeadEnded() async {
        let setup = makeSetup(localNetwork: ScriptedLocalNetwork([0, 2]))
        let flow = SetupFlowModel(setup: setup)

        let first = await flow.allow(.localNetwork)
        #expect(first.outcome == .probeTimeout)
        #expect(first.destination == .none, "nothing to open: the retry is the browse")
        #expect(!flow.isComplete(.localNetwork))

        let second = await flow.allow(.localNetwork)

        #expect(second.outcome == .promptTriggered, "the second click browses again")
        #expect(flow.isComplete(.localNetwork))
        #expect(setup.localNetworkFoundSpeakers == 2)
    }

    /// A REFUSAL is a different thing from an empty browse, and the primer can
    /// now tell them apart — so this click stops pretending to re-ask (the
    /// browse would only be refused again) and goes where the refusal can be
    /// undone, exactly as a denied Bluetooth grant does.
    @Test func aRefusedLocalNetworkDeepLinksToItsPane() async {
        let setup = makeSetup(localNetwork: CannedOutcomeLocalNetwork(outcome: .denied))
        let flow = SetupFlowModel(setup: setup)

        let first = await flow.allow(.localNetwork)
        #expect(first.outcome == .probeTimeout, "the first click is still the ask")
        #expect(setup.localNetworkStatus == .denied)

        let second = await flow.allow(.localNetwork)

        #expect(second.outcome == .settingsFallbackDenied)
        #expect(second.destination == .settingsPane(.localNetwork))
        #expect(!flow.isComplete(.localNetwork))
    }

    /// The gate condition is the PERMISSION, not the speaker: self-discovery
    /// proves the grant with nothing switched on, so the step completes. The
    /// completed card is inert (it offers no Try Again), so the recount is not
    /// a user action at all — it rides the same refresh the window's focus
    /// fires, and a speaker switched on later simply appears in the title.
    @Test func aGrantedLocalNetworkWithNoSpeakersCompletesAndRecountsOnRefresh() async {
        let setup = makeSetup(localNetwork: GrantingLocalNetwork([0, 3]))
        let flow = SetupFlowModel(setup: setup)

        let first = await flow.allow(.localNetwork)

        #expect(first.outcome == .promptTriggered)
        #expect(flow.isComplete(.localNetwork), "the permission is what completes it")
        #expect(setup.localNetworkFoundSpeakers == 0)

        // The completed step has no click of its own, so the recount comes
        // through the same refresh the window's focus fires.
        await setup.refreshStatuses()

        #expect(setup.localNetworkFoundSpeakers == 3)
        #expect(flow.isComplete(.localNetwork))
    }

    /// Bluetooth's retry goes to the PRIVACY pane, where this app's grant is
    /// toggled — not the radio pane, which can't fix a denial.
    @Test func deniedBluetoothDeepLinksToThePrivacyPane() async {
        let setup = makeSetup(bluetooth: .denied)
        await setup.refreshStatuses()
        let flow = SetupFlowModel(setup: setup)

        let result = await flow.allow(.bluetooth)

        #expect(result.outcome == .settingsFallbackDenied)
        #expect(result.destination == .settingsPane(.bluetoothPrivacy))
    }

    /// Bluetooth's answer arrives on a callback we can't await, so a second
    /// click while the prompt is still unanswered must not fire a second one.
    @Test func bluetoothPromptIsSingleFlightWhileUndecided() async {
        let flow = SetupFlowModel(setup: makeSetup(bluetooth: .unknown))
        #expect(await flow.allow(.bluetooth).outcome == .promptTriggered)
        #expect(await flow.allow(.bluetooth).outcome == .promptInFlight)
    }

    /// …but single-flight must not become a LATCH. A prompt whose decision callback
    /// never fires would otherwise leave every later click reporting a prompt in
    /// flight forever — a card the user can click with nothing happening at all. The
    /// wait expires, and the next click asks again under its own named outcome
    /// (a fresh `CBCentralManager` re-raises the prompt while undetermined).
    @Test func anUndecidedBluetoothPromptRearmsAfterItsTimeout() async {
        let setup = makeSetup(bluetooth: .unknown,
                              bluetoothPrimer: NeverDecidingBluetooth(),
                              bluetoothPromptTimeout: 0.05)
        let flow = SetupFlowModel(setup: setup)
        #expect(await flow.allow(.bluetooth).outcome == .promptTriggered)
        #expect(await flow.allow(.bluetooth).outcome == .promptInFlight)
        #expect(setup.isPrimingBluetooth)

        // Polled, not slept through: the main actor is shared with every other
        // test in the run, so when the timeout lands is not this test's to decide.
        for _ in 0..<600 where setup.isPrimingBluetooth {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        #expect(!setup.isPrimingBluetooth, "an undecided prompt does not hold the card forever")
        #expect(await flow.allow(.bluetooth).outcome == .promptRearmed)
        #expect(setup.isPrimingBluetooth, "…and the fresh ask is itself in flight")
    }

    /// Speaker Sync has no prompt at all — Login Items is its only destination.
    @Test func speakerSyncAlwaysOpensLoginItems() async {
        let flow = SetupFlowModel(setup: makeSetup(ptpHelper: .requiresApproval))
        let result = await flow.allow(.speakerSync)
        #expect(result.outcome == .settingsOpened)
        #expect(result.destination == .loginItems)
    }

    /// Remote Control's exception: its retry re-fires the Accessibility PROMPT
    /// (whose own button highlights this app in the list) and never deep-links.
    @Test func remoteControlNeverDeepLinks() async {
        let flow = SetupFlowModel(setup: makeSetup(remoteControlTrusted: false))
        let first = await flow.allow(.remoteControl)
        let second = await flow.allow(.remoteControl)
        #expect(first.destination == .none)
        #expect(second.destination == .none)
    }

    /// Never send someone to Settings to fix what isn't broken.
    @Test func allowOnAnAlreadyGrantedStepIsANoOp() async {
        let setup = makeSetup(audio: .granted)
        await setup.requestAudioCapture()
        let flow = SetupFlowModel(setup: setup)

        let result = await flow.allow(.audio)

        #expect(result.outcome == .alreadyGranted)
        #expect(result.destination == .none)
    }

    /// An auto-passed step is satisfied without anyone granting anything, so its
    /// Allow must not offer a pane either.
    @Test func allowOnAnAutoPassedStepIsANoOp() async {
        let flow = SetupFlowModel(setup: makeSetup(localNetworkGated: false))
        #expect(await flow.allow(.localNetwork).outcome == .alreadyGranted)
    }

    // The setup_allow / setup_done decision-log tests live in
    // `SetupTelemetryTests` — `Telemetry._installTestSink` is process-global,
    // so its users belong under `SerializedSharedState`, not here.
}
