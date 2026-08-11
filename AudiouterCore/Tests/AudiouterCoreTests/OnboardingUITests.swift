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
    /// Reports a fixed ``LocalNetworkOutcome`` — the refusal and the
    /// grant-with-no-speakers only the real primer's two signals can produce.
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

    /// A prime the test drives step by step, so both halves of the wait are
    /// observable on screen: parked with the dialog notionally still up, then
    /// parked again after the network proved reachable while the count fills in.
    private final class SteppedLocalNetwork: LocalNetworkPriming, @unchecked Sendable {
        let found: Int
        init(found: Int) { self.found = found }

        private let lock = NSLock()
        private var resumeGate: (() -> Void)?
        private var parkedWaiter: (() -> Void)?

        func probe() async -> Bool { found > 0 }

        func prime(browseSeconds: TimeInterval,
                   onReachable: @escaping @Sendable () -> Void) async -> LocalNetworkOutcome {
            await park()
            onReachable()
            await park()
            return .granted(foundSpeakers: found)
        }

        private func park() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let waiter: (() -> Void)? = lock.withLock {
                    resumeGate = { continuation.resume() }
                    let waiter = parkedWaiter
                    parkedWaiter = nil
                    return waiter
                }
                waiter?()
            }
        }

        func waitUntilParked() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let alreadyParked: Bool = lock.withLock {
                    if resumeGate != nil { return true }
                    parkedWaiter = { continuation.resume() }
                    return false
                }
                if alreadyParked { continuation.resume() }
            }
        }

        func resume() {
            let gate: (() -> Void)? = lock.withLock {
                let gate = resumeGate
                resumeGate = nil
                return gate
            }
            gate?()
        }
    }

    /// The real `LocalNetworkPrimer`'s collision shape in miniature: a prime
    /// that runs while another is parked answers `.undecided` IMMEDIATELY —
    /// exactly what the primer's in-flight guard does to the loser. Unparked
    /// primes answer granted instantly so the flow can be walked; `armParking()`
    /// parks the NEXT prime until `resume()`.
    private final class CollidingLocalNetwork: LocalNetworkPriming, @unchecked Sendable {
        private let lock = NSLock()
        private var parkNext = false
        private var parkedResume: (() -> Void)?
        private var parkedWaiter: (() -> Void)?
        private(set) var primeCount = 0

        func probe() async -> Bool { true }

        func armParking() { lock.withLock { parkNext = true } }

        var test_primeCount: Int { lock.withLock { primeCount } }

        func prime(browseSeconds: TimeInterval,
                   onReachable: @escaping @Sendable () -> Void) async -> LocalNetworkOutcome {
            enum Role { case parked, collided, instant }
            let role: Role = lock.withLock {
                primeCount += 1
                if parkedResume != nil { return .collided }
                if parkNext { parkNext = false; return .parked }
                return .instant
            }
            switch role {
            case .collided: return .undecided
            case .instant: return .granted(foundSpeakers: 2)
            case .parked:
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let waiter: (() -> Void)? = lock.withLock {
                        parkedResume = { continuation.resume() }
                        let waiter = parkedWaiter
                        parkedWaiter = nil
                        return waiter
                    }
                    waiter?()
                }
                onReachable()
                return .granted(foundSpeakers: 2)
            }
        }

        func waitUntilParked() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let alreadyParked: Bool = lock.withLock {
                    if parkedResume != nil { return true }
                    parkedWaiter = { continuation.resume() }
                    return false
                }
                if alreadyParked { continuation.resume() }
            }
        }

        func resume() {
            let gate: (() -> Void)? = lock.withLock {
                let gate = parkedResume
                parkedResume = nil
                return gate
            }
            gate?()
        }
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
        #expect(vc.test_title(of: .localNetwork) == "3 speakers on your network")
    }

    /// A card the user already finished is DONE — clicking it must do nothing
    /// at all. Live, clicking the completed Local Network card flashed an error
    /// state that then dismissed itself: the click landed on a card that a
    /// rescan had just downgraded out of completed (fixed in `SetupModel`), so
    /// this pins the inertness the flash was hiding — no press accepted, no
    /// buttons, no probe, and the flow does not move.
    @Test func aCompletedCardIsInertToClicks() async {
        let net = CannedLocalNetwork(found: 3)
        let vc = makeVC(model: makeModel(audio: .granted, localNetwork: net))
        await vc.test_allow([.audio, .localNetwork])
        #expect(vc.test_activeStep == .bluetooth)
        let frontCount = vc.test_returnToFrontCount

        for done in [SetupStep.audio, .localNetwork] {
            #expect(!vc.test_isCardClickable(done), "\(done) is finished")
            #expect(vc.test_cardPressIsRefused(done), "\(done) must refuse a press")
            #expect(!vc.test_cardIsAccessibilityButton(done), "and offer VoiceOver no action")
            #expect(vc.test_buttonTitles(of: done).isEmpty, "a finished card offers no controls")
        }

        #expect(vc.test_activeStep == .bluetooth, "nothing moved")
        #expect(vc.test_title(of: .localNetwork) == "3 speakers on your network")
        #expect(vc.test_returnToFrontCount == frontCount)
    }

    /// The model half of the same rule: an Allow routed at a finished step is a
    /// no-op that says so, and never re-runs the probe.
    @Test func allowingACompletedStepIsANoOp() async {
        let vc = makeVC(model: makeModel(audio: .granted, foundSpeakers: 3))
        await vc.test_allow([.audio, .localNetwork])
        #expect(vc.test_hasCheckmark(.localNetwork))

        await vc.test_tapAllow(.localNetwork)

        #expect(vc.test_activeStep == .bluetooth)
        #expect(vc.test_hint(of: .localNetwork) == nil, "no error state on a finished card")
        #expect(vc.test_statusCaption(of: .localNetwork) == nil)
    }

    @Test func oneFoundSpeakerReadsSingular() async {
        let vc = makeVC(model: makeModel(audio: .granted, foundSpeakers: 1))
        await vc.test_allow([.audio, .localNetwork])
        #expect(vc.test_title(of: .localNetwork) == "1 speaker on your network")
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

    /// An unanswered ask can't be called a denial — it gets a line naming what
    /// actually happened (nothing answered) rather than an accusation or an
    /// invented switched-off speaker, and the primary click keeps being the
    /// retry that line asks for. Settings is demoted beside it, never instead of
    /// it: a card whose only button opened Settings left NOTHING able to
    /// re-browse, so the flow dead-ended on a speaker the user had just switched on.
    @Test func anUnprovenLocalNetworkOffersARetryNotADeadEnd() async {
        var opened: [SystemSettingsPane] = []
        let vc = makeVC(model: makeModel(audio: .granted, foundSpeakers: 0),
                        onOpenSettings: { opened.append($0) })
        await vc.test_allow([.audio, .localNetwork])

        #expect(vc.test_activeStep == .localNetwork, "an unproven browse does not advance")
        #expect(vc.test_hint(of: .localNetwork)
                == "Nothing has answered yet. If the permission dialog is open, choose Allow — or try again.")
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

        #expect(vc.test_title(of: .localNetwork) == "2 speakers on your network")
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

    /// A REFUSAL is answered evidence too — the dialog is gone, so the window
    /// comes back rather than hiding behind an alert that no longer exists.
    @Test func aRefusedLocalNetworkBrowseTakesTheFrontBack() async {
        let vc = makeVC(model: makeModel(audio: .granted,
                                         localNetwork: CannedOutcomeLocalNetwork(outcome: .denied)))
        await vc.test_tapAllow(.audio)
        let before = vc.test_returnToFrontCount

        await vc.test_tapAllow(.localNetwork)

        #expect(vc.test_returnToFrontCount > before)
    }

    /// A refused Local Network is the one state where re-browsing is pointless,
    /// so the card stops offering a retry and becomes the Settings deep link —
    /// the same two-mode shape a denied System Audio or Bluetooth card takes.
    @Test func aRefusedLocalNetworkCardOffersSettingsInsteadOfARetry() async {
        var opened: [SystemSettingsPane] = []
        let vc = makeVC(model: makeModel(audio: .granted,
                                         localNetwork: CannedOutcomeLocalNetwork(outcome: .denied)),
                        onOpenSettings: { opened.append($0) })
        await vc.test_allow([.audio, .localNetwork])

        #expect(vc.test_activeStep == .localNetwork, "a refusal does not advance the flow")
        #expect(vc.test_buttonTitles(of: .localNetwork) == ["Open Settings…"])
        #expect(vc.test_hint(of: .localNetwork) == nil, "no speaker advice — a speaker isn't the problem")

        await vc.test_tapAllow(.localNetwork)

        #expect(opened == [.localNetwork])
    }

    /// The permission is what completes this step: a grant with nothing switched
    /// on still earns the checkmark, and the title says exactly what happened.
    @Test func aGrantedLocalNetworkWithNoSpeakersStillCompletes() async {
        let vc = makeVC(model: makeModel(audio: .granted,
                                         localNetwork: CannedOutcomeLocalNetwork(
                                             outcome: .granted(foundSpeakers: 0))))
        await vc.test_allow([.audio, .localNetwork])

        #expect(vc.test_activeStep == .bluetooth, "the permission landed, so the flow moves on")
        #expect(vc.test_title(of: .localNetwork)
                == "No speakers found yet \u{2014} switch one on and it'll appear")
        #expect(vc.test_hasCheckmark(.localNetwork))
    }

    /// A Local Network prime can sit a full minute on an unanswered dialog, so
    /// the card has to say what it is waiting for — and then say something
    /// different once the answer lands and only the count is left.
    @Test func theLocalNetworkCardNamesBothHalvesOfItsWait() async {
        let net = SteppedLocalNetwork(found: 2)
        let vc = makeVC(model: makeModel(audio: .granted, localNetwork: net))
        await vc.test_tapAllow(.audio)

        let priming = Task { await vc.test_tapAllow(.localNetwork) }

        await net.waitUntilParked()
        await waitUntil { vc.test_statusCaption(of: .localNetwork) != nil }
        #expect(vc.test_statusCaption(of: .localNetwork) == "Waiting for your answer\u{2026}")
        #expect(vc.test_buttonTitles(of: .localNetwork).isEmpty, "no second ask while one is in flight")

        net.resume()                                    // the browse reaches the network
        await net.waitUntilParked()
        await waitUntil { vc.test_statusCaption(of: .localNetwork) == "Checking your network\u{2026}" }
        #expect(vc.test_statusCaption(of: .localNetwork) == "Checking your network\u{2026}")

        net.resume()
        await priming.value

        #expect(vc.test_statusCaption(of: .localNetwork) == nil, "the wait clears with the answer")
        #expect(vc.test_title(of: .localNetwork) == "2 speakers on your network")
    }

    /// A refusal skips the second half entirely — there is nothing left to
    /// check, so the card goes straight to its actionable denied state.
    @Test func aRefusedLocalNetworkLeavesNoWaitOnScreen() async {
        let vc = makeVC(model: makeModel(audio: .granted,
                                         localNetwork: CannedOutcomeLocalNetwork(outcome: .denied)))
        await vc.test_allow([.audio, .localNetwork])

        #expect(vc.test_statusCaption(of: .localNetwork) == nil)
        #expect(!vc.test_isProbing(.localNetwork))
        #expect(vc.test_buttonTitles(of: .localNetwork) == ["Open Settings…"])
    }

    /// An undecided prime (the dialog is still up when the ceiling expires) must
    /// leave the card ACTIONABLE, never stuck saying it is waiting.
    @Test func anUndecidedLocalNetworkPrimeLeavesTheCardActionable() async {
        let vc = makeVC(model: makeModel(audio: .granted, foundSpeakers: 0))
        await vc.test_allow([.audio, .localNetwork])

        #expect(vc.test_statusCaption(of: .localNetwork) == nil, "never a stuck wait")
        #expect(vc.test_buttonTitles(of: .localNetwork) == ["Try Again", "Open Settings…"])
        #expect(vc.test_isCardClickable(.localNetwork))
    }

    /// The waiting line is shared: every card whose Allow raises a system dialog
    /// says the same thing while that dialog is unanswered.
    @Test func anUndecidedBluetoothPromptSaysWhatItIsWaitingFor() async {
        let model = makeModel(audio: .granted, foundSpeakers: 2,
                              bluetoothPrimer: NeverDecidingBluetooth())
        let vc = makeVC(model: model)
        await vc.test_allow([.audio, .localNetwork])

        await vc.test_tapAllow(.bluetooth)

        #expect(vc.test_statusCaption(of: .bluetooth) == "Waiting for your answer\u{2026}")
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
        vc.test_tapSkip(.bluetooth)
        vc.test_tapSkip(.remoteControl)
        #expect(vc.test_doneExists, "every required permission is in, every card decided")
        #expect(vc.test_doneIsReturnDefault)
    }

    /// Owner decision 2026-08-11 (tightened gate): the optional cards'
    /// permissions stay outside `RequiredPermission`, but an UNDECIDED card
    /// holds the gate shut — the CTA must never appear beside a card still
    /// offering Allow/Skip. Each decision (a skip here) advances it.
    @Test func anUndecidedOptionalCardHoldsTheGateShut() async {
        let vc = makeVC(model: makeGrantableModel())
        await vc.test_allow([.audio, .localNetwork])
        #expect(vc.test_activeStep == .bluetooth, "the flow still offers them")
        #expect(!vc.test_doneExists, "…and the CTA waits for the answer")

        vc.test_tapSkip(.bluetooth)
        #expect(!vc.test_doneExists, "Remote Control is still undecided")

        vc.test_tapSkip(.remoteControl)
        #expect(vc.test_doneExists, "a skip is a decision — the gate opens")
    }

    @Test func returnBelongsToTheActiveAllowUntilDoneExists() async {
        let vc = makeVC(model: makeGrantableModel())
        #expect(vc.test_allowIsReturnDefault(.audio))

        await vc.test_allow([.audio, .localNetwork])
        #expect(vc.test_allowIsReturnDefault(.bluetooth),
                "the one live Allow keeps Return while any card is undecided")

        vc.test_tapSkip(.bluetooth)
        vc.test_tapSkip(.remoteControl)

        #expect(vc.test_doneIsReturnDefault, "Done takes Return the moment it exists")
    }

    /// v4 live fix ("Start listening took two clicks"): the last grant is often
    /// detected by the poll while the user is still IN System Settings, whose
    /// frontmost app can make macOS decline our re-activation — so the user
    /// returns to an INACTIVE app, where a stock control spends the first click
    /// activating the window. The CTA, every prominent Allow, and the live
    /// card target act on that activating click; a locked strip keeps stock
    /// behaviour. (The earlier headless `acceptsFirstMouse` probe on a bare
    /// NSButton never exercised this path — this pins the overrides that do.)
    @Test func theCTAAndLiveCardActOnTheActivatingClick() async {
        let vc = makeVC(model: makeGrantableModel())
        #expect(vc.test_cardAcceptsFirstMouse(.audio), "the live card acts on first mouse")
        #expect(!vc.test_cardAcceptsFirstMouse(.bluetooth), "a locked strip keeps stock behaviour")
        #expect(ProminentButton(title: "Allow…", target: nil, action: nil)
                    .acceptsFirstMouse(for: nil),
                "every prominent button — the card Allows live the same bounce loop")

        await vc.test_allow([.audio, .localNetwork])
        vc.test_tapSkip(.bluetooth)
        vc.test_tapSkip(.remoteControl)

        #expect(vc.test_doneAcceptsFirstMouse, "the CTA acts on the returning click")
    }

    @Test func doneFinishesWhenReVerificationPasses() async {
        var doneFired = false
        let vc = makeVC(model: makeGrantableModel(), onDone: { doneFired = true })
        await vc.test_allow([.audio, .localNetwork])
        vc.test_tapSkip(.bluetooth)
        vc.test_tapSkip(.remoteControl)

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
        vc.test_tapSkip(.bluetooth)
        vc.test_tapSkip(.remoteControl)
        #expect(vc.test_doneExists)

        await vc.test_tapDone()

        #expect(!doneFired, "a hard gate does not finish on an unmet permission")
        #expect(vc.test_snapBackStep == .audio)
        #expect(vc.test_activeStep == .audio)
        #expect(vc.test_expandedSteps == [.audio])
        #expect(!vc.test_doneExists, "the gate closes again")
    }

    /// The live double-click bug's exact shape: the app-reactivation
    /// `refreshStatuses()` is still browsing the local network when the user
    /// clicks Done. The verification must JOIN that running probe and finish on
    /// the first click — the real primer answers a colliding prime `.undecided`
    /// (its in-flight guard), which the model would have recorded as a real
    /// "not granted" and refused to finish on.
    @Test func doneFinishesOnTheFirstClickWhileAReactivationProbeIsStillBrowsing() async {
        let net = CollidingLocalNetwork()
        var doneCount = 0
        let vc = makeVC(model: makeModel(audio: .granted, localNetwork: net,
                                         ptpHelper: FakePTPHelper(status: .enabled)),
                        onDone: { doneCount += 1 })
        await vc.test_allow([.audio, .localNetwork])
        vc.test_tapSkip(.bluetooth)
        vc.test_tapSkip(.remoteControl)
        #expect(vc.test_doneExists)

        net.armParking()
        let reactivation = Task { await vc.test_refreshStatuses() }
        await net.waitUntilParked()

        let done = Task { await vc.test_tapDone() }
        await waitUntil { vc.test_doneVerifyInFlight }
        // Let the verification reach the shared probe before the browse answers.
        for _ in 0..<20 { await Task.yield() }
        net.resume()
        await done.value
        await reactivation.value

        #expect(doneCount == 1, "the FIRST click finishes")
        #expect(vc.test_snapBackStep == nil, "no fabricated unmet permission")
        #expect(net.test_primeCount == 2,
                "the walk's browse plus the reactivation's — the verification joined, it did not stack a third")
    }

    /// A second click while Done's verification is still running is a no-op —
    /// single-flight, like the Allow path. Without it the second verification
    /// would collide with the first's browse and race it past `onDone`.
    /// (Each click also leaves a named `setup_done` outcome in the decision
    /// log — the swallowed click's line is the guard this test pins; the
    /// line shapes themselves are pinned in `SetupTelemetryTests`, the
    /// serialized suite that may install the process-global sink.)
    @Test func aSecondClickDuringDoneVerificationIsANoOp() async {
        let net = CollidingLocalNetwork()
        var doneCount = 0
        let vc = makeVC(model: makeModel(audio: .granted, localNetwork: net,
                                         ptpHelper: FakePTPHelper(status: .enabled)),
                        onDone: { doneCount += 1 })
        await vc.test_allow([.audio, .localNetwork])
        vc.test_tapSkip(.bluetooth)
        vc.test_tapSkip(.remoteControl)

        net.armParking()
        let first = Task { await vc.test_tapDone() }
        await net.waitUntilParked()   // the first verification's browse is live

        await vc.test_tapDone()       // the second click, mid-verification

        #expect(doneCount == 0, "the no-op returned while the first verification still runs")
        net.resume()
        await first.value

        #expect(doneCount == 1, "exactly one finish")
        #expect(net.test_primeCount == 2, "the second click fired no browse of its own")
    }

    // MARK: The finale (setup-complete state)

    /// A model every step of the flow can be walked to completion on — the
    /// grantable trio plus Bluetooth and Remote Control already satisfied.
    private func makeCompleteableModel() -> SetupModel {
        makeModel(audio: .granted, foundSpeakers: 2, bluetooth: .granted,
                  remoteControlTrusted: true, ptpHelper: FakePTPHelper(status: .enabled))
    }

    @Test func theGateButtonIsTheGoldStartListeningCTA() async {
        let vc = makeVC(model: makeGrantableModel())
        await vc.test_allow([.audio, .localNetwork])
        vc.test_tapSkip(.bluetooth)
        vc.test_tapSkip(.remoteControl)

        #expect(vc.test_doneExists)
        #expect(vc.test_doneTitle == "Start listening")
        #expect(vc.test_doneIsGoldProminent, "the finale CTA is the gold prominent button")
        #expect(vc.test_doneIsReturnDefault)
    }

    /// The header keeps its welcome subtitle in EVERY state — the payoff line
    /// lives on the finale card in the demo pane, never in the header.
    @Test func theHeaderKeepsTheWelcomeSubtitleWhenTheGateOpens() async {
        let vc = makeVC(model: makeGrantableModel())
        #expect(vc.test_subtitleText == OnboardingViewController.welcomeSubtitle)

        await vc.test_allow([.audio, .localNetwork])
        vc.test_tapSkip(.bluetooth)
        vc.test_tapSkip(.remoteControl)

        #expect(vc.test_doneExists)
        #expect(vc.test_subtitleText == OnboardingViewController.welcomeSubtitle)
    }

    /// The finale card carries the payoff copy: display headline over the
    /// every-room line (owner copy 2026-08-11 — no found-speaker count).
    @Test func theFinaleCardCarriesThePayoffCopy() {
        let settled = DemoSettledMockView()
        #expect(settled.test_headlineText == "You're all set.")
        #expect(settled.test_lineText == "Your Mac's sound can reach every room.")
    }

    /// The warning stands down to the WELCOME line once its permission is
    /// re-granted — even with the gate open — and the banner hooks report the
    /// tracked message kind.
    @Test func theWarningStandsDownToTheWelcomeLineOnceRegranted() async {
        let vc = makeVC(model: makeGrantableModel(), reason: .permissionLost([.audioCapture]))
        #expect(vc.test_permissionLostBannerIsVisible,
                "the warning shows while its permission is missing")

        await vc.test_allow([.audio, .localNetwork])
        vc.test_tapSkip(.bluetooth)
        vc.test_tapSkip(.remoteControl)

        #expect(vc.test_doneExists)
        #expect(vc.test_subtitleText == OnboardingViewController.welcomeSubtitle)
        #expect(!vc.test_permissionLostBannerIsVisible)
        #expect(vc.test_permissionLostBannerText == nil)
    }

    /// The finale's one-shot fires on the transition into complete, and a
    /// repaint that changes nothing can never re-fire it.
    @Test func theCelebrationFiresOnceOnTheTransitionIntoComplete() async {
        let vc = makeVC(model: makeCompleteableModel())
        vc.test_demoReduceMotionOverride = false
        vc.test_demoCanAnimateOverride = true
        await vc.test_refreshStatuses()
        #expect(vc.test_demoCelebrationRunCount == 0, "nothing to celebrate yet")

        await vc.test_allow([.audio, .localNetwork])

        #expect(vc.test_demoMode == .settled)
        #expect(vc.test_demoCelebrationRunCount == 1)
        #expect(!vc.test_demoShowsReplay, "the finale is a one-shot, never a Replay offer")

        vc.test_refresh()   // a repaint that changes nothing

        #expect(vc.test_demoCelebrationRunCount == 1, "the shot is spent")
    }

    /// Reduce Motion spends the shot without motion: the settled frame IS the
    /// model state, so skipping the celebration skips nothing but movement.
    @Test func reduceMotionSpendsTheCelebrationWithoutMotion() async {
        let vc = makeVC(model: makeCompleteableModel())
        vc.test_demoReduceMotionOverride = true
        vc.test_demoCanAnimateOverride = true
        await vc.test_refreshStatuses()

        await vc.test_allow([.audio, .localNetwork])

        #expect(vc.test_demoMode == .settled)
        #expect(vc.test_demoCelebrationRunCount == 0, "no motion under Reduce Motion")
        #expect(vc.test_demoCelebrationConsumed, "but the moment is spent — no late replay")
    }

    /// Headless (and any off-window run) renders the settled frame instantly
    /// with the shot UNSPENT — snapshots stay deterministic, and the
    /// presentation that can show the shot still gets it.
    @Test func headlessSettlesTheFinaleInstantlyWithoutSpendingTheShot() async {
        let vc = makeVC(model: makeCompleteableModel())
        await vc.test_refreshStatuses()

        await vc.test_allow([.audio, .localNetwork])

        #expect(vc.test_demoMode == .settled)
        #expect(vc.test_demoCelebrationRunCount == 0)
        #expect(!vc.test_demoCelebrationConsumed)
        #expect(!vc.test_isDemoAnimating)
    }

    /// A window opened with everything already granted fires the shot once on
    /// its first real presentation — modelled through the visibility seam,
    /// which stands in for the occlusion notification.
    @Test func theUnspentShotFiresWhenTheFinaleFirstBecomesVisible() async {
        let vc = makeVC(model: makeCompleteableModel())
        await vc.test_refreshStatuses()
        await vc.test_allow([.audio, .localNetwork])
        #expect(vc.test_demoCelebrationRunCount == 0)

        vc.test_demoReduceMotionOverride = false
        vc.test_demoCanAnimateOverride = true   // the window lands on screen

        #expect(vc.test_demoCelebrationRunCount == 1)
    }

    /// The finale is decoration like every other mock: its headline and line
    /// must be swallowed by the accessibility opt-out — the left pane's header
    /// and cards carry the words.
    @Test func theFinaleStaysInvisibleToVoiceOver() async {
        let vc = makeVC(model: makeCompleteableModel())
        await vc.test_refreshStatuses()

        await vc.test_allow([.audio, .localNetwork])

        #expect(vc.test_demoMode == .settled)
        #expect(vc.test_demoAccessibilityElements.isEmpty,
                "still reachable: \(vc.test_demoAccessibilityElements)")
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
    }

    /// Speaker Sync's approval only exists in Login Items — there is no prompt to
    /// mirror, so it is always the Settings mock.
    @Test func speakerSyncAlwaysShowsTheSettingsMock() async {
        let vc = makeVC(model: makeModel(audio: .granted, foundSpeakers: 2))
        await vc.test_allow([.audio, .localNetwork])
        vc.test_tapSkip(.bluetooth)
        #expect(vc.test_activeStep == .speakerSync)
        #expect(vc.test_demoMode == .settings)
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

        wc.test_appDidResignActive()     // Settings takes the front
        wc.test_appDidBecomeActive()     // the user comes back
        #expect(wc.test_windowLevel == .floating, "back in our app, back on top")
    }

    @Test func representDoesNotRecenterAMovedWindow() {
        let wc = OnboardingWindowController(model: makeModel(audio: .granted),
                                            openSettings: { _ in },
                                            onFinished: {})
        // `present()` really does put the floating Setup window on the tester's
        // screen: left open it parks above every other window, un-clickable (the
        // test process is not a foreground app), until the whole run ends. Same
        // for the reactivate test below.
        defer { wc.window?.close() }
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

        #expect(wc.window?.isVisible == false,
                "with another window key, the hook must not order setup in (visibility is the floating level's job)")
    }

    @Test func reactivateFrontsSetupWhenNothingHoldsKey() {
        let wc = OnboardingWindowController(model: makeModel(audio: .granted),
                                            openSettings: { _ in },
                                            onFinished: {})
        defer { wc.window?.close() }
        wc.keyWindowProvider = { nil }   // e.g. returning from a permission prompt

        wc.test_appDidBecomeActive()

        #expect(wc.window?.isVisible == true,
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
