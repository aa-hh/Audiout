// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import Foundation
import Testing
@testable import AudiouterCore
@testable import AudiouterOnboardingUI
@testable import AudiouterPopoverUI
@testable import AudiouterSharedUI

/// Structure + behavior of the Setup window's sequential flow, driven through the
/// real `OnboardingViewController` / `OnboardingWindowController` against fake
/// permission seams (no Core Audio, no network). The window isn't visible to a
/// headless test, so these assert via the `test_` hooks — the same approach the
/// popover/settings UI tests use.
@MainActor
@Suite final class OnboardingUITests {

    private struct CannedAudioProbe: AudioCapturePermissionProbing {
        let result: PermissionStatus
        /// What the SILENT read reports, if anything — the seam a revocation
        /// arrives through (`nil` leaves the cached status alone).
        let silent: PermissionStatus?
        init(result: PermissionStatus, silent: PermissionStatus? = nil) {
            self.result = result
            self.silent = silent
        }
        func probe() async -> PermissionStatus { result }
        func currentStatusSilently() -> PermissionStatus? { silent }
    }
    private struct CannedLocalNetwork: LocalNetworkPriming {
        let found: Int
        func probe() async -> Bool { found > 0 }
        func probeFoundSpeakers() async -> Int { found }
    }
    /// A browse whose count changes call to call — "turn a speaker on, then try
    /// again", modelled. The last count repeats once the script runs out.
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
    /// A Bluetooth prompt that never reports back — the wedge case.
    private struct NeverDecidingBluetooth: BluetoothPermissionPriming {
        func prime(onDecided: @escaping @Sendable () -> Void) {}
    }
    private struct NoopRemoteControl: RemoteControlPriming {
        let trusted: Bool
        init(trusted: Bool = false) { self.trusted = trusted }
        func prime() {}
        func isTrusted() -> Bool { trusted }
    }
    /// Reports a fixed ``PTPHelperStatus`` and records `register()`/
    /// `openSystemSettingsLoginItems()` calls — never touches `SMAppService`.
    private final class FakePTPHelper: PTPHelperManaging {
        var status: PTPHelperStatus
        private(set) var registerCount = 0
        private(set) var openSettingsCount = 0
        private(set) var unregisterCount = 0
        init(status: PTPHelperStatus = .notRegistered) { self.status = status }
        func register() throws { registerCount += 1 }
        func openSystemSettingsLoginItems() { openSettingsCount += 1 }
        func unregister() async throws { unregisterCount += 1 }
    }
    private final class ChangeCounter { var count = 0 }

    private let isolation = TestIsolation(owner: "OnboardingUITests")
    private var defaults: UserDefaults { isolation.isolatedDefaults }

    private func makeModel(audio: PermissionStatus,
                           silentAudio: PermissionStatus? = nil,
                           foundSpeakers: Int = 0,
                           localNetwork: LocalNetworkPriming? = nil,
                           bluetooth: PermissionStatus = .unknown,
                           bluetoothPrimer: BluetoothPermissionPriming? = nil,
                           bluetoothPromptTimeout: TimeInterval = 10,
                           remoteControlTrusted: Bool = false,
                           localNetworkGated: Bool = true,
                           ptpHelper: PTPHelperManaging = FakePTPHelper()) -> SetupModel {
        SetupModel(audioProbe: CannedAudioProbe(result: audio, silent: silentAudio),
                   localNetwork: localNetwork ?? CannedLocalNetwork(found: foundSpeakers),
                   remoteControl: NoopRemoteControl(trusted: remoteControlTrusted),
                   ptpHelper: ptpHelper,
                   bluetoothReader: SimulatedBluetoothPermission(status: bluetooth),
                   bluetoothPrimer: bluetoothPrimer ?? SimulatedBluetoothPermission(status: bluetooth),
                   settings: AppSettings(defaults: defaults),
                   localNetworkGated: localNetworkGated,
                   bluetoothPromptTimeout: bluetoothPromptTimeout)
    }

    private func makeVC(model: SetupModel,
                        reason: OnboardingReason = .firstRun,
                        onOpenSettings: @escaping (SystemSettingsPane) -> Void = { _ in },
                        onDone: @escaping () -> Void = {}) -> OnboardingViewController {
        let vc = OnboardingViewController(model: model, reason: reason,
                                          onOpenSettings: onOpenSettings, onDone: onDone)
        _ = vc.test_rootView   // force loadView + viewDidLoad
        return vc
    }

    /// A model where every required permission is satisfiable, so the flow can
    /// be walked to the gate.
    private func makeGrantableModel(silentAudio: PermissionStatus? = nil) -> SetupModel {
        makeModel(audio: .granted, silentAudio: silentAudio, foundSpeakers: 3,
                  ptpHelper: FakePTPHelper(status: .enabled))
    }

    // MARK: Sequencing

    @Test func flowOpensOnTheFirstCardWithEveryOtherCollapsed() {
        let vc = makeVC(model: makeModel(audio: .unknown))
        #expect(vc.test_activeStep == .audio)
        #expect(vc.test_expandedSteps == [.audio], "exactly one card is ever open")
    }

    @Test func grantingACardAdvancesToTheNextAndRewritesItsTitle() async {
        let vc = makeVC(model: makeModel(audio: .granted))
        #expect(vc.test_title(of: .audio) == "Let Audiouter hear your Mac's sound")

        await vc.test_tapAllow(.audio)

        #expect(vc.test_activeStep == .localNetwork)
        #expect(vc.test_expandedSteps == [.localNetwork])
        #expect(vc.test_title(of: .audio) == "Audiouter can now hear your Mac's sound")
        #expect(vc.test_hasCheckmark(.audio))
    }

    /// Local Network's earned title is the found COUNT, not a checkmark's worth
    /// of nothing — macOS won't confirm that permission, but a speaker it found
    /// is proof the user can check.
    @Test func localNetworkCompletedTitleReportsTheFoundCount() async {
        let vc = makeVC(model: makeModel(audio: .granted, foundSpeakers: 3))
        await vc.test_allow([.audio, .localNetwork])
        #expect(vc.test_title(of: .localNetwork) == "Found 3 speakers")
    }

    @Test func oneFoundSpeakerReadsSingular() async {
        let vc = makeVC(model: makeModel(audio: .granted, foundSpeakers: 1))
        await vc.test_allow([.audio, .localNetwork])
        #expect(vc.test_title(of: .localNetwork) == "Found 1 speaker")
    }

    /// On a macOS with no Local Network gate the step is satisfied without any
    /// browse, so the copy must not claim the user found anything.
    @Test func ungatedLocalNetworkNeverClaimsAFind() {
        let vc = makeVC(model: makeModel(audio: .unknown, localNetworkGated: false))
        #expect(vc.test_title(of: .localNetwork) == "Speakers on your Wi\u{2011}Fi are already reachable")
    }

    /// Auto-passed because the OS can't grant it at all: the strip says why,
    /// rather than showing a checkmark for a grant nobody made.
    @Test func autoPassedAudioShowsTheOSNoteNotACheckmark() {
        let vc = makeVC(model: makeModel(audio: .unsupported))
        // `.unsupported` only lands after a probe runs.
        #expect(vc.test_activeStep == .audio)
    }

    @Test func autoPassedAudioAfterProbingCarriesTheNote() async {
        let vc = makeVC(model: makeModel(audio: .unsupported))
        await vc.test_tapAllow(.audio)
        #expect(!vc.test_hasCheckmark(.audio), "nobody granted anything")
        #expect(vc.test_note(of: .audio) == "Requires macOS 14.2 or later")
        #expect(vc.test_title(of: .audio) == "Let Audiouter hear your Mac's sound",
                "a card with no checkmark keeps the imperative title")
    }

    // MARK: Locked / active rendering (owner decision 2026-08-11)

    /// A step the flow hasn't reached must READ locked, not merely un-ticked: the
    /// lock sits in the slot the checkmark will eventually take, and the content
    /// is dimmed past the completed steps' own secondary tone.
    @Test func stepsTheFlowHasNotReachedRenderLocked() {
        // Nothing granted, so every step behind the first really is unreached —
        // an already-satisfied one would carry a checkmark instead.
        let vc = makeVC(model: makeModel(audio: .unknown))
        for step: SetupStep in [.localNetwork, .bluetooth, .speakerSync, .remoteControl] {
            #expect(vc.test_isLocked(step), "\(step) is behind the active card")
        }
        #expect(!vc.test_isLocked(.audio), "the active card is not locked")
    }

    @Test func completedAndSkippedStepsCarryNoLock() async {
        let vc = makeVC(model: makeGrantableModel())
        await vc.test_allow([.audio, .localNetwork])
        vc.test_tapSkip(.bluetooth)

        #expect(!vc.test_isLocked(.audio), "completed: it has a checkmark instead")
        #expect(vc.test_hasCheckmark(.audio))
        #expect(!vc.test_isLocked(.bluetooth), "skipped: the user answered, they just said no")
        #expect(!vc.test_hasCheckmark(.bluetooth))
    }

    /// The active card is lifted off the canvas so current-vs-locked can't be
    /// mistaken, and the emphasis travels with the active step.
    @Test func onlyTheActiveCardIsEmphasized() async {
        let vc = makeVC(model: makeGrantableModel())
        #expect(vc.test_isEmphasized(.audio))
        #expect(!vc.test_isEmphasized(.localNetwork))

        await vc.test_tapAllow(.audio)

        #expect(!vc.test_isEmphasized(.audio))
        #expect(vc.test_isEmphasized(.localNetwork))
    }

    // MARK: The whole active card is the click target

    @Test func pressingTheActiveCardFiresItsAllow() async {
        let vc = makeVC(model: makeGrantableModel())
        #expect(vc.test_isCardClickable(.audio))

        #expect(await vc.test_pressCard(.audio))

        #expect(vc.test_hasCheckmark(.audio), "the card press ran the real Allow path")
        #expect(vc.test_activeStep == .localNetwork)
    }

    /// No jump-ahead: the flow is sequential, so a locked strip must refuse the
    /// press rather than asking for a permission out of order.
    @Test func lockedCardsAreNotClickable() {
        let vc = makeVC(model: makeGrantableModel())
        for step: SetupStep in [.localNetwork, .bluetooth, .speakerSync, .remoteControl] {
            #expect(!vc.test_isCardClickable(step))
            #expect(vc.test_cardPressIsRefused(step), "\(step) must refuse a press")
        }
    }

    /// The card-level target is two-mode aware for free — it fires whatever the
    /// button currently offers, so after a denial it opens Settings.
    @Test func theCardPressFollowsTheTwoModeAllow() async {
        var opened: [SystemSettingsPane] = []
        let vc = makeVC(model: makeModel(audio: .denied), onOpenSettings: { opened.append($0) })
        _ = await vc.test_pressCard(.audio)   // first press: the probe lands denied
        #expect(opened.isEmpty)

        _ = await vc.test_pressCard(.audio)

        #expect(opened == [.screenAndSystemAudioRecording])
    }

    /// VoiceOver sees the card itself as the button, named for what pressing it
    /// does; a card that isn't live is a plain group, since its press is refused.
    @Test func theActiveCardIsAccessibleAsAButtonNamedLikeItsAllow() async {
        let vc = makeVC(model: makeModel(audio: .denied))
        #expect(vc.test_cardIsAccessibilityButton(.audio))
        #expect(vc.test_cardAccessibilityAction(.audio) == "Allow…")
        #expect(!vc.test_cardIsAccessibilityButton(.localNetwork))

        await vc.test_tapAllow(.audio)   // spends the prompt → the label changes

        #expect(vc.test_cardAccessibilityAction(.audio) == "Open Settings…")
    }

    // MARK: Skip

    @Test func skipIsOfferedOnlyOnTheOptionalCards() async {
        let vc = makeVC(model: makeGrantableModel())
        #expect(vc.test_buttonTitles(of: .audio) == ["Allow…"], "System Audio is required")

        await vc.test_allow([.audio, .localNetwork])

        #expect(vc.test_activeStep == .bluetooth)
        #expect(vc.test_buttonTitles(of: .bluetooth) == ["Allow…", "Skip"])
    }

    @Test func skippingAdvancesWithoutACheckmark() async {
        let vc = makeVC(model: makeGrantableModel())
        await vc.test_allow([.audio, .localNetwork])

        vc.test_tapSkip(.bluetooth)

        // Speaker Sync is already satisfied in this model, so the next step the
        // flow can offer is Remote Control — skipping advances PAST a card, it
        // doesn't step onto the next index blindly.
        #expect(vc.test_activeStep == .remoteControl)
        #expect(!vc.test_hasCheckmark(.bluetooth), "skipped is not granted")
        #expect(vc.test_title(of: .bluetooth) == "Let Audiouter use Bluetooth speakers",
                "a skipped card keeps the imperative title")
    }

    @Test func skipIsIgnoredOnARequiredCard() async {
        let vc = makeVC(model: makeModel(audio: .unknown))
        vc.test_tapSkip(.audio)
        #expect(vc.test_activeStep == .audio, "the gate is not negotiable")
    }

    // MARK: Two-mode Allow + deep links

    @Test func deniedAudioSwitchesAllowToOpenSettings() async {
        let vc = makeVC(model: makeModel(audio: .denied))
        await vc.test_tapAllow(.audio)
        #expect(vc.test_buttonTitles(of: .audio) == ["Open Settings…"])
    }

    @Test func theSecondAllowOnDeniedAudioRoutesToTheRecordingPane() async {
        var opened: [SystemSettingsPane] = []
        let vc = makeVC(model: makeModel(audio: .denied), onOpenSettings: { opened.append($0) })

        await vc.test_tapAllow(.audio)   // the probe runs and lands denied
        #expect(opened.isEmpty, "the first click asks; it must not jump to Settings")

        await vc.test_tapAllow(.audio)
        #expect(opened == [.screenAndSystemAudioRecording])
    }

    /// An unproven browse can't be called a denial — it gets a "turn a speaker
    /// on" line rather than an accusation, and the primary click keeps being the
    /// retry that line asks for. Settings is demoted beside it, never instead of
    /// it: a card whose only button opened Settings left NOTHING able to
    /// re-browse, so the flow dead-ended on a speaker the user had just switched on.
    @Test func anUnprovenLocalNetworkOffersARetryNotADeadEnd() async {
        var opened: [SystemSettingsPane] = []
        let vc = makeVC(model: makeModel(audio: .granted, foundSpeakers: 0),
                        onOpenSettings: { opened.append($0) })
        await vc.test_allow([.audio, .localNetwork])

        #expect(vc.test_activeStep == .localNetwork, "an unproven browse does not advance")
        #expect(vc.test_hint(of: .localNetwork) == "No speakers found yet. Turn one on, then try again.")
        #expect(vc.test_buttonTitles(of: .localNetwork) == ["Try Again", "Open Settings…"])

        await vc.test_tapAllow(.localNetwork)

        #expect(opened.isEmpty, "the primary click browses again — it must not open Settings")
        #expect(vc.test_buttonTitles(of: .localNetwork) == ["Try Again", "Open Settings…"])
    }

    /// The retry really re-runs the browse, and the card reports what the second
    /// one found — the whole point of keeping it a retry.
    @Test func theLocalNetworkRetryBrowsesAgainAndReportsWhatItFinds() async {
        let vc = makeVC(model: makeModel(audio: .granted,
                                         localNetwork: ScriptedLocalNetwork([0, 2])))
        await vc.test_allow([.audio, .localNetwork])
        #expect(vc.test_activeStep == .localNetwork)

        await vc.test_tapAllow(.localNetwork)

        #expect(vc.test_title(of: .localNetwork) == "Found 2 speakers")
        #expect(vc.test_hint(of: .localNetwork) == nil, "nothing left to explain")
        #expect(vc.test_activeStep == .bluetooth)
    }

    /// A Local Network browse that proves nothing is NOT evidence the user is
    /// finished with the system dialog — macOS has no status API to ask
    /// (TN3179), so the timeout may well land while the dialog is still up.
    /// Re-fronting on it steals activation from that dialog and leaves it
    /// dimmed and unclickable.
    @Test func anUnprovenLocalNetworkBrowseDoesNotStealTheFront() async {
        let vc = makeVC(model: makeModel(audio: .granted, foundSpeakers: 0))
        await vc.test_tapAllow(.audio)
        let before = vc.test_returnToFrontCount

        await vc.test_tapAllow(.localNetwork)

        #expect(vc.test_activeStep == .localNetwork, "an unproven browse does not advance")
        #expect(vc.test_returnToFrontCount == before,
                "a bare probe timeout leaves the front to the system dialog")
    }

    /// The grant landing IS positive evidence the interaction is over, so the
    /// window comes back to show the rest of the flow.
    @Test func aProvenLocalNetworkBrowseTakesTheFrontBack() async {
        let vc = makeVC(model: makeModel(audio: .granted, foundSpeakers: 2))
        await vc.test_tapAllow(.audio)
        let before = vc.test_returnToFrontCount

        await vc.test_tapAllow(.localNetwork)

        #expect(vc.test_returnToFrontCount > before)
    }

    /// The demoted link still works, and still goes to the Local Network pane.
    @Test func theDemotedSettingsLinkOpensTheLocalNetworkPane() async {
        var opened: [SystemSettingsPane] = []
        let vc = makeVC(model: makeModel(audio: .granted, foundSpeakers: 0),
                        onOpenSettings: { opened.append($0) })
        await vc.test_allow([.audio, .localNetwork])

        vc.test_tapSettingsLink(.localNetwork)

        #expect(opened == [.localNetwork])
    }

    /// Bluetooth's answer arrives on a callback, so the click returns long before
    /// the user has answered — the card has to LOOK like it is waiting, or an
    /// undecided prompt is a click into nothing.
    @Test func anUndecidedBluetoothPromptShowsTheCardWaiting() async {
        let model = makeModel(audio: .granted, foundSpeakers: 2,
                              bluetoothPrimer: NeverDecidingBluetooth())
        let vc = makeVC(model: model)
        await vc.test_allow([.audio, .localNetwork])
        #expect(vc.test_activeStep == .bluetooth)

        await vc.test_tapAllow(.bluetooth)

        #expect(vc.test_isProbing(.bluetooth), "the wait is visible")
        #expect(!vc.test_isCardClickable(.bluetooth), "and the card is inert while it waits")
    }

    /// …and the wait expires, so the card comes back to life instead of staying
    /// wedged for the rest of the presentation.
    @Test func anUndecidedBluetoothPromptStopsWaitingAfterItsTimeout() async {
        let model = makeModel(audio: .granted, foundSpeakers: 2,
                              bluetoothPrimer: NeverDecidingBluetooth(),
                              bluetoothPromptTimeout: 0.05)
        let vc = makeVC(model: model)
        await vc.test_allow([.audio, .localNetwork])
        await vc.test_tapAllow(.bluetooth)
        #expect(vc.test_isProbing(.bluetooth))

        await waitUntil { !model.isPrimingBluetooth }

        #expect(!vc.test_isProbing(.bluetooth), "the spinner clears itself")
        #expect(vc.test_isCardClickable(.bluetooth), "and the card can ask again")
    }

    /// Wait for something a background timeout will make true. A fixed sleep is a
    /// flake here: the main actor is shared with every other test in the run, so
    /// how soon that work lands is not this test's to decide.
    private func waitUntil(_ satisfied: () -> Bool) async {
        for _ in 0..<600 {                                   // ≤3 s, then give up
            if satisfied() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    @Test func speakerSyncRoutesToLoginItemsThroughTheModelSeam() async {
        let ptpHelper = FakePTPHelper(status: .requiresApproval)
        var opened: [SystemSettingsPane] = []
        let vc = makeVC(model: makeModel(audio: .granted, foundSpeakers: 2, ptpHelper: ptpHelper),
                        onOpenSettings: { opened.append($0) })
        await vc.test_allow([.audio, .localNetwork])
        vc.test_tapSkip(.bluetooth)
        #expect(vc.test_activeStep == .speakerSync)
        #expect(vc.test_buttonTitles(of: .speakerSync) == ["Open Login Items…"])

        await vc.test_tapAllow(.speakerSync)

        #expect(ptpHelper.openSettingsCount == 1)
        #expect(opened.isEmpty, "Login Items is not a privacy pane deep link")
    }

    /// Remote Control's "Open Settings…" re-fires the Accessibility PROMPT (whose
    /// own button highlights the app in the list) and never deep-links.
    @Test func remoteControlNeverRoutesThroughTheDeepLinkOpener() async {
        var opened: [SystemSettingsPane] = []
        let vc = makeVC(model: makeGrantableModel(), onOpenSettings: { opened.append($0) })
        await vc.test_allow([.audio, .localNetwork])
        vc.test_tapSkip(.bluetooth)
        vc.test_tapSkip(.remoteControl)   // ignored below — it isn't active yet

        await vc.test_tapAllow(.remoteControl)

        #expect(opened.isEmpty)
    }

    // MARK: The gate

    @Test func doneIsAbsentUntilEveryRequiredPermissionVerifies() async {
        let vc = makeVC(model: makeGrantableModel())
        #expect(!vc.test_doneExists, "the gate is ABSENT, not disabled")

        await vc.test_tapAllow(.audio)
        #expect(!vc.test_doneExists, "Local Network is still unmet")

        await vc.test_tapAllow(.localNetwork)
        #expect(vc.test_doneExists, "every required permission is in")
        #expect(vc.test_doneIsReturnDefault)
    }

    /// Bluetooth and Remote Control are outside `RequiredPermission`, so leaving
    /// them untouched can never hold the gate shut.
    @Test func theOptionalCardsNeverHoldTheGateShut() async {
        let vc = makeVC(model: makeGrantableModel())
        await vc.test_allow([.audio, .localNetwork])
        #expect(vc.test_doneExists)
        #expect(vc.test_activeStep == .bluetooth, "the flow still offers them")
    }

    @Test func returnBelongsToTheActiveAllowUntilDoneExists() async {
        let vc = makeVC(model: makeGrantableModel())
        #expect(vc.test_allowIsReturnDefault(.audio))

        await vc.test_allow([.audio, .localNetwork])

        #expect(vc.test_doneIsReturnDefault)
        #expect(!vc.test_allowIsReturnDefault(.bluetooth),
                "Done takes Return the moment it exists")
    }

    @Test func doneFinishesWhenReVerificationPasses() async {
        var doneFired = false
        let vc = makeVC(model: makeGrantableModel(), onDone: { doneFired = true })
        await vc.test_allow([.audio, .localNetwork])

        await vc.test_tapDone()

        #expect(doneFired)
        #expect(vc.test_snapBackStep == nil)
    }

    /// The revocation case: Done's re-verify finds the silent audio read has gone
    /// denied since, so the flow snaps back to that card instead of finishing —
    /// no sheet, no "continue anyway".
    @Test func doneSnapsBackToARevokedCardInsteadOfFinishing() async {
        var doneFired = false
        let vc = makeVC(model: makeGrantableModel(silentAudio: .denied),
                        onDone: { doneFired = true })
        await vc.test_allow([.audio, .localNetwork])
        #expect(vc.test_doneExists)

        await vc.test_tapDone()

        #expect(!doneFired, "a hard gate does not finish on an unmet permission")
        #expect(vc.test_snapBackStep == .audio)
        #expect(vc.test_activeStep == .audio)
        #expect(vc.test_expandedSteps == [.audio])
        #expect(!vc.test_doneExists, "the gate closes again")
    }

    // MARK: Demo pane

    @Test func demoShowsThePromptMockForAFirstAsk() {
        let vc = makeVC(model: makeModel(audio: .unknown))
        #expect(vc.test_demoMode == .prompt)
    }

    @Test func demoSwapsToTheSettingsMockAfterADenial() async {
        let vc = makeVC(model: makeModel(audio: .denied))
        await vc.test_tapAllow(.audio)
        #expect(vc.test_demoMode == .settings)
        #expect(vc.test_demoStage == nil, "every step but Speaker Sync starts at the pane itself")
    }

    /// Speaker Sync's approval only exists in Login Items — there is no privacy
    /// dialog to mirror, so it is always the Settings mock. Its mock has TWO
    /// stages, and rests on the first: the system alert that sends the user to
    /// Login Items, which they have to act on before any pane opens.
    @Test func speakerSyncAlwaysShowsTheSettingsMock() async {
        let vc = makeVC(model: makeModel(audio: .granted, foundSpeakers: 2))
        await vc.test_allow([.audio, .localNetwork])
        vc.test_tapSkip(.bluetooth)
        #expect(vc.test_activeStep == .speakerSync)
        #expect(vc.test_demoMode == .settings)
        #expect(vc.test_demoStage == .alert)
    }

    /// The two-stage pass has the same contract as every one-stage one: it ends
    /// where it started. Resting on the Login Items pane would show a switch the
    /// user hasn't been told how to reach yet.
    @Test func theLoginItemsDemoRestsOnTheAlertNotThePane() {
        let mock = DemoLoginItemsMockView(step: .speakerSync)
        mock.layoutSubtreeIfNeeded()
        #expect(mock.test_stage == .alert)

        mock.startTimeline(loop: false)
        mock.stopTimeline()

        #expect(mock.test_stage == .alert, "a pass must end where it started")
    }

    @Test func demoSettlesWhenEveryStepIsDone() async {
        let vc = makeVC(model: makeModel(audio: .granted, foundSpeakers: 2,
                                         bluetooth: .granted, remoteControlTrusted: true,
                                         ptpHelper: FakePTPHelper(status: .enabled)))
        await vc.test_refreshStatuses()
        await vc.test_allow([.audio, .localNetwork])
        #expect(vc.test_activeStep == nil)
        #expect(vc.test_demoMode == .settled)
    }

    /// Zero idle CPU: the loop only ever runs on a window that is really on
    /// screen, so a headless/off-window pane is settled and silent.
    @Test func demoNeverAnimatesOffWindow() {
        let vc = makeVC(model: makeModel(audio: .unknown))
        #expect(!vc.test_isDemoAnimating)
        #expect(!vc.test_demoShowsReplay, "Replay is for a Reduce Motion user watching a live window")
    }

    /// The demo is decoration: every word of the information is in the card copy
    /// beside it. Un-electing only the container HOISTS its children, which left
    /// the mock's real text fields ("Allow", "Don't Allow", the pane title)
    /// reachable — VoiceOver reading out a picture of a dialog.
    @Test func theDemoIsInvisibleToVoiceOver() async {
        let vc = makeVC(model: makeModel(audio: .unknown))
        #expect(vc.test_demoAccessibilityElements.isEmpty,
                "still reachable: \(vc.test_demoAccessibilityElements)")

        await vc.test_tapAllow(.audio)   // a different mock, same rule

        #expect(vc.test_demoAccessibilityElements.isEmpty,
                "still reachable: \(vc.test_demoAccessibilityElements)")
        #expect(vc.test_replayIsAccessible, "Replay is a real control and stays reachable")
    }

    /// Reduce Motion: ONE play-through on step activation, resting at the settled
    /// frame, with Replay offered — never the loop. Headless never animates for
    /// real, so the policy is driven through the pane's own seams.
    @Test func reduceMotionPlaysTheDemoOnceAndOffersReplay() async {
        let vc = makeVC(model: makeGrantableModel())
        vc.test_demoReduceMotionOverride = true
        vc.test_demoCanAnimateOverride = true

        await vc.test_tapAllow(.audio)   // the step changes: the one play-through

        #expect(vc.test_demoShowsReplay, "a Reduce Motion user gets the button")
        #expect(vc.test_isDemoAnimating)
        #expect(!vc.test_demoIsLooping, "played once — it must not loop")
    }

    @Test func replayRunsTheDemoAgain() async {
        let vc = makeVC(model: makeGrantableModel())
        vc.test_demoReduceMotionOverride = true
        vc.test_demoCanAnimateOverride = true
        await vc.test_tapAllow(.audio)
        vc.test_demoCanAnimateOverride = nil   // headless: the pass stops, settled
        vc.test_demoCanAnimateOverride = true

        vc.test_tapReplay()

        #expect(vc.test_isDemoAnimating)
        #expect(!vc.test_demoIsLooping, "Replay is another single pass")
    }

    /// Reduce Motion OFF on a live pane loops instead, and offers no Replay.
    @Test func fullMotionLoopsTheDemoWithoutAReplayButton() async {
        let vc = makeVC(model: makeGrantableModel())
        vc.test_demoReduceMotionOverride = false
        vc.test_demoCanAnimateOverride = true

        await vc.test_tapAllow(.audio)

        #expect(vc.test_isDemoAnimating)
        #expect(vc.test_demoIsLooping)
        #expect(!vc.test_demoShowsReplay)
    }

    /// The Settings mock's switch: ON is a blue track AND the knob at the
    /// TRAILING end. It regressed once — an `NSView` knob offset by
    /// `layer.transform` had that transform wiped by the next layout pass, so an
    /// ON switch rendered blue with the knob still parked left.
    @Test func theMockSwitchPutsItsKnobAtTheTrailingEndWhenOn() {
        let switchView = DemoSwitchView()
        switchView.setOn(false)
        switchView.layoutSubtreeIfNeeded()
        #expect(!switchView.test_knobIsAtTrailingEnd, "off parks the knob at the leading inset")

        switchView.setOn(true)
        switchView.layoutSubtreeIfNeeded()

        #expect(switchView.test_isOn)
        #expect(switchView.test_knobIsAtTrailingEnd,
                "on must slide the knob across — a blue track with a left knob is a lie")
    }

    // MARK: The two-stage Remote Control demo

    /// Remote Control's "Open Settings…" re-fires the ASK rather than
    /// deep-linking, because that panel's own "Open System Settings" button is
    /// the only path that highlights Audiouter in the list. So the user has TWO
    /// clicks to make, on two surfaces — and a demo that opened straight onto the
    /// pane showed the toggle without showing how the pane carrying it is
    /// reached. The pass starts and ends on the alert, the click still to make.
    @Test func remoteControlsRetryDemoIsTwoStageAndRestsOnTheAsk() async {
        let vc = makeVC(model: makeGrantableModel())
        await vc.test_allow([.audio, .localNetwork])
        vc.test_tapSkip(.bluetooth)
        #expect(vc.test_activeStep == .remoteControl)

        await vc.test_tapAllow(.remoteControl)   // the prompt is spent: `.requested`

        #expect(vc.test_demoMode == .settings)
        #expect(vc.test_demoStage == .alert)
        // The opt-out has to reach a mock nested one stage deeper than before.
        #expect(vc.test_demoAccessibilityElements.isEmpty,
                "still reachable: \(vc.test_demoAccessibilityElements)")
    }

    /// Every other step's retry really does land on the pane, so only this one
    /// pays for the second surface.
    @Test func everyOtherRetryDemoIsASingleSurface() async {
        let vc = makeVC(model: makeModel(audio: .denied))
        await vc.test_tapAllow(.audio)
        #expect(vc.test_demoMode == .settings)
        #expect(vc.test_demoStage == nil)
    }

    /// Remote Control's retry rests on the same shape as Speaker Sync's, and it
    /// ends where it started.
    @Test func theRemoteControlRetryDemoRestsOnTheAlert() {
        let mock = DemoSettingsHandoffMockView(step: .remoteControl)
        mock.layoutSubtreeIfNeeded()
        #expect(mock.test_stage == .alert)

        mock.startTimeline(loop: false)
        mock.stopTimeline()

        #expect(mock.test_stage == .alert, "a pass must end where it started")
    }

    /// The system alert is the real panel's copy, not the privacy dialog's: the
    /// access as a header, the OS's own ask, and the instruction that names the
    /// pane the grant is actually made in. The privacy dialog's own titles are
    /// untouched.
    @Test func theSystemAlertCarriesTheRealPanelsCopy() {
        #expect(DemoSystemAlertMockView.headerText(for: .remoteControl) == "Accessibility Access")
        #expect(DemoSystemAlertMockView.askText(for: .remoteControl)
            == "“Audiouter” would like to control this computer using accessibility features.")
        #expect(DemoSystemAlertMockView.bodyText(for: .remoteControl)
            .contains("Privacy & Security settings"))

        #expect(DemoSystemAlertMockView.headerText(for: .speakerSync) == "Login Items")
        #expect(DemoSystemAlertMockView.bodyText(for: .speakerSync)
            .contains("Login Items settings"))

        #expect(DemoPromptMockView.confirmTitle(for: .audio) == "Allow")
    }

    /// A stage writes its score in its OWN seconds; the host lays it down at an
    /// offset. Core Animation wants a linear score to span the whole animation,
    /// so the stage HOLDS its first and last values through the time either side
    /// rather than being stretched over it.
    @Test func aStagedScoreIsMappedIntoItsWindowOfTheHostPass() {
        let mock = DemoMockView(frame: .zero)
        mock.stageWindow = (hostDuration: 10, start: 4)

        let animation = mock.keyframes("opacity", [(0, 0), (2, 1)])

        #expect(animation.duration == 10)
        #expect(animation.keyTimes?.map(\.doubleValue) == [0, 0.4, 0.6, 1])
        #expect(animation.values?.count == 4)
        #expect(animation.timingFunctions?.count == 3)
    }

    // MARK: One motion language

    /// The cards clip on the SAME constant every other collapsible element in
    /// the app uses — a second hand-synced copy is exactly what drifted before.
    @Test func collapseSharesTheOneMotionDuration() {
        #expect(Tokens.Motion.collapseRevealDuration == 0.15)
        #expect(PopoverPanelViewController.collapseRevealDuration == Tokens.Motion.collapseRevealDuration)
    }

    // MARK: Presentation reason (the lost-permission message)

    @Test func firstRunShowsNoLostPermissionMessage() {
        let vc = makeVC(model: makeModel(audio: .granted), reason: .firstRun)
        #expect(!vc.test_showsPermissionLostBanner)
        #expect(vc.test_permissionLostBannerText == nil)
    }

    @Test func permissionLostNamesTheUnmetPermissionInTheHeader() {
        let vc = makeVC(model: makeModel(audio: .denied), reason: .permissionLost([.audioCapture]))
        #expect(vc.test_showsPermissionLostBanner)
        let text = vc.test_permissionLostBannerText
        #expect(text != nil)
        #expect(text?.contains("System Audio") ?? false,
                "the header names the specific unmet permission: \(text ?? "nil")")
    }

    @Test func permissionLostNamesMultipleUnmetPermissions() {
        let vc = makeVC(model: makeModel(audio: .denied),
                        reason: .permissionLost([.audioCapture, .ptpHelper]))
        let text = vc.test_permissionLostBannerText ?? ""
        #expect(text.contains("System Audio"), "\(text)")
        // "Speaker Sync", not "PTP helper" — the card was named out of jargon.
        #expect(text.contains("Speaker Sync"), "\(text)")
    }

    /// The pronoun has to agree with the count: "Re-enable it below" beside two
    /// named permissions is a broken sentence, on the one screen whose whole job
    /// is explaining what went wrong.
    @Test func theLostPermissionMessageAgreesWithHowManyItNamed() {
        let one = OnboardingViewController.permissionLostText(for: [.audioCapture])
        #expect(one.contains("permission, currently turned off"), "\(one)")
        #expect(one.contains("Re-enable it below"), "\(one)")

        let two = OnboardingViewController.permissionLostText(for: [.audioCapture, .ptpHelper])
        #expect(two.contains("permissions, currently turned off"), "\(two)")
        #expect(two.contains("Re-enable them below"), "\(two)")
    }

    @Test func permissionLostMessageClearsOnceItsFlaggedPermissionIsGranted() async {
        let vc = makeVC(model: makeGrantableModel(), reason: .permissionLost([.audioCapture]))
        #expect(vc.test_permissionLostBannerIsVisible,
                "shown while the flagged permission is still ungranted")

        await vc.test_tapAllow(.audio)

        #expect(!vc.test_permissionLostBannerIsVisible,
                "the message must clear once the permission it warned about is granted")
        #expect(vc.test_showsPermissionLostBanner, "it cleared, it was never not-warranted")
    }

    @Test func windowControllerThreadsReasonThroughToTheContentViewController() {
        let wc = OnboardingWindowController(model: makeModel(audio: .denied),
                                            reason: .permissionLost([.localNetwork]),
                                            openSettings: { _ in },
                                            onFinished: {})
        #expect(wc.test_contentViewController.test_showsPermissionLostBanner)
    }

    @Test func windowControllerDefaultsToFirstRun() {
        let wc = OnboardingWindowController(model: makeModel(audio: .granted),
                                            openSettings: { _ in },
                                            onFinished: {})
        #expect(!wc.test_contentViewController.test_showsPermissionLostBanner)
    }

    // MARK: Load-time behavior

    @Test func viewDidLoadRegistersThePTPHelper() {
        let ptpHelper = FakePTPHelper(status: .notRegistered)
        _ = makeVC(model: makeModel(audio: .granted, ptpHelper: ptpHelper))
        #expect(ptpHelper.registerCount == 1)
    }

    /// Without the load-time silent re-read the Bluetooth card paints
    /// undetermined even when the grant is already in place (`bluetoothStatus`
    /// starts `.unknown`).
    @Test func loadReadsAnAlreadyGrantedBluetoothStatus() async {
        let model = makeModel(audio: .granted, bluetooth: .granted)
        let vc = makeVC(model: model)
        await vc.test_refreshStatuses()
        #expect(model.bluetoothStatus == .granted)
        #expect(vc.test_hasCheckmark(.bluetooth))
    }

    // MARK: Window level + presentation (punch-list W10/W6)

    @Test func windowFloatsWhileOpen() {
        let wc = OnboardingWindowController(model: makeModel(audio: .granted),
                                            openSettings: { _ in },
                                            onFinished: {})
        #expect(wc.window?.level == .floating,
                "owner decision 2026-08-07: setup stays above other windows for its whole open lifetime")
    }

    /// The 2026-08-11 amendment: floating yields to System Settings, because
    /// Settings is the one app we deliberately send the user to.
    @Test func openingSettingsDropsTheFloatingLevelAndComingBackRestoresIt() async {
        let wc = OnboardingWindowController(model: makeModel(audio: .denied),
                                            openSettings: { _ in },
                                            onFinished: {})
        let vc = wc.test_contentViewController
        _ = vc.test_rootView

        await vc.test_tapAllow(.audio)   // first click: the probe lands denied
        #expect(wc.test_windowLevel == .floating, "asking for a permission is not a Settings trip")

        await vc.test_tapAllow(.audio)   // second click: the deep link
        #expect(wc.test_windowLevel == .normal, "System Settings has to be able to come forward")

        wc.test_appDidBecomeActive()
        #expect(wc.test_windowLevel == .floating, "back in our app, back on top")
    }

    @Test func representDoesNotRecenterAMovedWindow() {
        let wc = OnboardingWindowController(model: makeModel(audio: .granted),
                                            openSettings: { _ in },
                                            onFinished: {})
        // `present()` sizes and centers headless but never orders the window in
        // (`HeadlessRuntime`), so this asserts the first-present-only rule
        // without parking a floating window on the tester's screen.
        wc.present()
        let moved = NSPoint(x: 13, y: 17)   // far from any plausible center
        wc.window?.setFrameOrigin(moved)

        wc.present()   // the presentSetup re-entry guard's re-front path

        #expect(wc.window?.frame.origin == moved,
                "a re-present must keep the position the user chose, not re-center")
    }

    @Test func reactivateDoesNotStealKeyFromASiblingWindow() {
        let wc = OnboardingWindowController(model: makeModel(audio: .granted),
                                            openSettings: { _ in },
                                            onFinished: {})
        let sibling = NSWindow()   // stands in for Settings holding key
        wc.keyWindowProvider = { sibling }

        wc.test_appDidBecomeActive()

        #expect(wc.test_frontCount == 0,
                "with another window key, the hook must not order setup in (visibility is the floating level's job)")
    }

    @Test func reactivateFrontsSetupWhenNothingHoldsKey() {
        let wc = OnboardingWindowController(model: makeModel(audio: .granted),
                                            openSettings: { _ in },
                                            onFinished: {})
        wc.keyWindowProvider = { nil }   // e.g. returning from a permission prompt

        wc.test_appDidBecomeActive()

        #expect(wc.test_frontCount == 1,
                "with no key window, the hook re-fronts setup so the user lands right back on it")
    }

    // MARK: Window controller dismissal contract

    @Test func doneFinishesOnceAndPersistsCompletion() {
        let counter = ChangeCounter()
        let wc = OnboardingWindowController(model: makeModel(audio: .granted),
                                            openSettings: { _ in },
                                            onFinished: { counter.count += 1 })
        #expect(!AppSettings(defaults: defaults).hasCompletedSetup)

        wc.test_finishWithDone()

        #expect(wc.test_didFinish)
        #expect(AppSettings(defaults: defaults).hasCompletedSetup, "Done persists completion")
        #expect(counter.count == 1)
    }

    @Test func closeWithoutDoneFinishesButDoesNotPersist() {
        let counter = ChangeCounter()
        let wc = OnboardingWindowController(model: makeModel(audio: .granted),
                                            openSettings: { _ in },
                                            onFinished: { counter.count += 1 })
        wc.test_closeWithoutDone()

        #expect(wc.test_didFinish)
        #expect(!AppSettings(defaults: defaults).hasCompletedSetup,
                "Closing with ✕ leaves setup to reappear next launch")
        #expect(counter.count == 1)
    }

    @Test func finishIsSingleFire() {
        let counter = ChangeCounter()
        let wc = OnboardingWindowController(model: makeModel(audio: .granted),
                                            openSettings: { _ in },
                                            onFinished: { counter.count += 1 })
        wc.test_finishWithDone()
        wc.test_closeWithoutDone()   // second dismissal path
        wc.test_finishWithDone()     // and again
        #expect(counter.count == 1, "onFinished fires exactly once")
    }
}
