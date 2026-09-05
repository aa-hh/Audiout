// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import Foundation
import Testing
@testable import AudioutCore
@testable import AudioutOnboardingUI
@testable import AudioutPopoverUI
@testable import AudioutSharedUI

/// Structure + behavior of the Setup window's sequential flow, driven through the
/// real `OnboardingViewController` / `OnboardingWindowController` against fake
/// permission seams (no Core Audio, no network). The window isn't visible to a
/// headless test, so these assert via the `test_` hooks — the same approach the
/// popover/settings UI tests use.
///
/// The window is a SPINE (six compact status rows) and a HERO (the drawn
/// rehearsal over a ribbon of real UI), so the assertions come in two kinds:
/// the row hooks for where the flow stands, and the ribbon hooks for what it is
/// saying and offering.
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
        /// A `resume()` that arrived before anything was parked. Without it
        /// the signal is DROPPED and the next `park()` waits forever: the
        /// caller only reaches `park()` after an `await`, so a test that
        /// resumes first loses the race. That is the hang — it needs no
        /// hardware and no permission, only the scheduler ordering the two
        /// the wrong way round, which is why it surfaced in a full serial run
        /// and not in this suite on its own (2026-09-05).
        private var pendingResume = false

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
                enum Next { case resumeNow, wait(( () -> Void)?) }
                let next: Next = lock.withLock {
                    if pendingResume {
                        pendingResume = false
                        return .resumeNow
                    }
                    resumeGate = { continuation.resume() }
                    let waiter = parkedWaiter
                    parkedWaiter = nil
                    return .wait(waiter)
                }
                switch next {
                case .resumeNow: continuation.resume()
                case .wait(let waiter): waiter?()
                }
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
                if gate == nil { pendingResume = true }
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
        /// Same lost-wakeup guard as `SteppedLocalNetwork.pendingResume`, for
        /// the same reason — see the comment there.
        private var pendingResume = false
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
                    enum Next { case resumeNow, wait(( () -> Void)?) }
                    let next: Next = lock.withLock {
                        if pendingResume {
                            pendingResume = false
                            return .resumeNow
                        }
                        parkedResume = { continuation.resume() }
                        let waiter = parkedWaiter
                        parkedWaiter = nil
                        return .wait(waiter)
                    }
                    switch next {
                    case .resumeNow: continuation.resume()
                    case .wait(let waiter): waiter?()
                    }
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
                if gate == nil { pendingResume = true }
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
    private final class FakePTPHelper: PTPHelperManaging, @unchecked Sendable {
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

    /// A silent audio read a test can flip mid-run — how a revocation lands
    /// between the automatic check's pass and the CTA click.
    private final class MutableSilentAudioProbe: AudioCapturePermissionProbing, @unchecked Sendable {
        private let lock = NSLock()
        private var _silent: PermissionStatus
        init(silent: PermissionStatus) { _silent = silent }
        var silent: PermissionStatus {
            get { lock.withLock { _silent } }
            set { lock.withLock { _silent = newValue } }
        }
        func probe() async -> PermissionStatus { .granted }
        func currentStatusSilently() -> PermissionStatus? { silent }
    }

    private func makeModel(audio: PermissionStatus,
                           silentAudio: PermissionStatus? = nil,
                           audioProbe: AudioCapturePermissionProbing? = nil,
                           foundSpeakers: Int = 0,
                           localNetwork: LocalNetworkPriming? = nil,
                           bluetooth: PermissionStatus = .unknown,
                           bluetoothPrimer: BluetoothPermissionPriming? = nil,
                           bluetoothPromptTimeout: TimeInterval = 10,
                           remoteControlTrusted: Bool = false,
                           localNetworkGated: Bool = true,
                           ptpHelper: PTPHelperManaging = FakePTPHelper()) -> SetupModel {
        SetupModel(audioProbe: audioProbe ?? CannedAudioProbe(result: audio, silent: silentAudio),
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

    /// Drive a real top-down layout pass at the fixed window size — the moment
    /// the demo pane's finale launch waits for (its centres only resolve once
    /// the enclosing pass has positioned it). The live window lays out for free;
    /// a headless VC test has to ask.
    private func layoutRoot(_ vc: OnboardingViewController) {
        let root = vc.test_rootView
        root.frame = NSRect(x: 0, y: 0,
                            width: OnboardingViewController.contentWidth,
                            height: OnboardingViewController.contentHeight)
        root.layoutSubtreeIfNeeded()
    }

    /// A model where every required permission is satisfiable, so the flow can
    /// be walked to the gate.
    private func makeGrantableModel(silentAudio: PermissionStatus? = nil) -> SetupModel {
        makeModel(audio: .granted, silentAudio: silentAudio, foundSpeakers: 3,
                  ptpHelper: FakePTPHelper(status: .enabled))
    }

    /// The announcements MINUS the in-flight wait line. A wait is not a
    /// transition — it is the beat between two of them — and it is spoken on its
    /// own edge now (`theWaitTheStuckHintAndARefusedCloseAreAllSpoken` pins that
    /// half), so the transition pins below read past it.
    private func transitionAnnouncements(_ vc: OnboardingViewController) -> [String] {
        vc.test_announcements.filter { $0 != OnboardingViewController.waitingStatus }
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

    // MARK: Sequencing

    @Test func flowOpensOnTheFirstStepWithItsAskInTheRibbon() {
        let vc = makeVC(model: makeModel(audio: .unknown))
        #expect(vc.test_activeStep == .audio)
        #expect(vc.test_heroHeadline == "Hear your Mac's sound")
        #expect(vc.test_heroWhy == "Audiout needs this to send your music to your speakers. "
                + "Allowing plays a brief tone to confirm it's working.")
        #expect(vc.test_ribbonBodyText == nil, "a first ask has no paragraph under it")
        #expect(vc.test_previewFrameLabel?.contains("macOS") ?? false,
                "the frame says whose surface this is, so no line of copy has to")
        #expect(vc.test_ribbonButtonTitles == ["Enable system audio"])
        #expect(vc.test_browseStep == nil)
    }

    @Test func grantingAStepAdvancesTheFlowAndRewritesItsSpineTitle() async {
        let vc = makeVC(model: makeModel(audio: .granted))
        #expect(vc.test_spineTitle(of: .audio) == "Hear your Mac's sound")

        await vc.test_tapAllow(.audio)

        #expect(vc.test_activeStep == .localNetwork)
        #expect(vc.test_spineTitle(of: .audio) == "Hearing your Mac's sound")
        #expect(vc.test_hasCheckmark(.audio))
    }

    /// Local Network's earned title is the found COUNT, not a checkmark's worth
    /// of nothing — macOS won't confirm that permission, but a speaker it found
    /// is proof the user can check.
    @Test func localNetworkCompletedTitleReportsTheFoundCount() async {
        let vc = makeVC(model: makeModel(audio: .granted, foundSpeakers: 3))
        await vc.test_allow([.audio, .localNetwork])
        #expect(vc.test_spineTitle(of: .localNetwork) == "3 speakers on your network")
    }

    @Test func oneFoundSpeakerReadsSingular() async {
        let vc = makeVC(model: makeModel(audio: .granted, foundSpeakers: 1))
        await vc.test_allow([.audio, .localNetwork])
        #expect(vc.test_spineTitle(of: .localNetwork) == "1 speaker on your network")
    }

    /// The model half of the inertness rule: an Allow routed at a finished step
    /// is a no-op that says so, and never re-runs the probe.
    @Test func allowingACompletedStepIsANoOp() async {
        let vc = makeVC(model: makeModel(audio: .granted, foundSpeakers: 3))
        await vc.test_allow([.audio, .localNetwork])
        #expect(vc.test_hasCheckmark(.localNetwork))

        await vc.test_tapAllow(.localNetwork)

        #expect(vc.test_activeStep == .bluetooth, "nothing moved")
        #expect(!vc.test_ribbonIsWaiting, "no wait on a finished step")
        #expect(!vc.test_rowIsBroken(.localNetwork), "and no error state on it")
    }

    /// On a macOS with no Local Network gate the step is satisfied without any
    /// browse, so the copy must not claim the user found anything.
    @Test func ungatedLocalNetworkNeverClaimsAFind() {
        let vc = makeVC(model: makeModel(audio: .unknown, localNetworkGated: false))
        #expect(vc.test_spineTitle(of: .localNetwork) == "Speakers already reachable")
    }

    /// Auto-passed because the OS can't grant it at all: the row says why,
    /// rather than showing a checkmark for a grant nobody made.
    @Test func autoPassedAudioAfterProbingCarriesTheNote() async {
        let vc = makeVC(model: makeModel(audio: .unsupported))
        await vc.test_tapAllow(.audio)
        #expect(!vc.test_hasCheckmark(.audio), "nobody granted anything")
        #expect(vc.test_note(of: .audio) == "Requires macOS 14.2 or later")
        #expect(vc.test_spineTitle(of: .audio) == "Hear your Mac's sound",
                "a row with no checkmark keeps the imperative title")
    }

    /// And it is not browsable either: the note is the whole story, and there is
    /// no honest hero for a grant macOS cannot make — so the row refuses the
    /// press and VoiceOver sees a plain group, not a button.
    @Test func anAutoPassedRowRefusesThePress() async {
        let vc = makeVC(model: makeModel(audio: .unsupported))
        await vc.test_tapAllow(.audio)
        #expect(vc.test_note(of: .audio) == "Requires macOS 14.2 or later")

        #expect(!vc.test_isRowPressable(.audio))
        #expect(await vc.test_pressRow(.audio) == false)

        #expect(vc.test_browseStep == nil, "nothing opened for reading")
        #expect(!vc.test_rowIsAccessibilityButton(.audio))
        #expect(vc.test_rowAccessibilityAction(.audio) == nil, "no action to offer")
    }

    // MARK: Locked / live rendering

    /// A step the flow hasn't reached must READ locked, not merely un-ticked: the
    /// padlock sits in the slot the checkmark will eventually take.
    @Test func stepsTheFlowHasNotReachedRenderLocked() {
        // Nothing granted, so every step behind the first really is unreached —
        // an already-satisfied one would carry a checkmark instead.
        let vc = makeVC(model: makeModel(audio: .unknown))
        for step: SetupStep in [.localNetwork, .bluetooth, .speakerSync, .remoteControl] {
            #expect(vc.test_isLocked(step), "\(step) is behind the live row")
        }
        #expect(!vc.test_isLocked(.audio), "the live row is not locked")
    }

    @Test func completedAndSkippedStepsCarryNoLock() async {
        let vc = makeVC(model: makeGrantableModel())
        await vc.test_allow([.audio, .localNetwork])
        vc.test_tapSkip(.bluetooth)

        #expect(!vc.test_isLocked(.audio), "completed: it has a checkmark instead")
        #expect(vc.test_hasCheckmark(.audio))
        #expect(!vc.test_isLocked(.bluetooth), "skipped: the user answered, they just said no")
        #expect(vc.test_isSkipped(.bluetooth))
        #expect(!vc.test_hasCheckmark(.bluetooth))
    }

    // MARK: Row press dispatch

    /// The live row IS the ribbon's primary button: pressing anywhere on it runs
    /// the same Allow.
    @Test func pressingTheLiveRowFiresTheRibbonsPrimary() async {
        let vc = makeVC(model: makeGrantableModel())
        #expect(vc.test_isRowPressable(.audio))

        #expect(await vc.test_pressRow(.audio))

        #expect(vc.test_hasCheckmark(.audio), "the row press ran the real Allow path")
        #expect(vc.test_activeStep == .localNetwork)
    }

    /// No jump-ahead: the flow is sequential, so a locked row refuses the press
    /// rather than asking for a permission out of order — silently, and with
    /// nothing else moving.
    @Test func lockedRowsRefuseThePress() async {
        // Nothing satisfied, so every row behind the first really is locked — an
        // already-complete one (Speaker Sync in the grantable model) would be
        // browsable, which is a different rule.
        let vc = makeVC(model: makeModel(audio: .unknown))
        for step: SetupStep in [.localNetwork, .bluetooth, .speakerSync, .remoteControl] {
            #expect(!vc.test_isRowPressable(step))
            #expect(vc.test_rowPressIsRefused(step), "\(step) must refuse a press")
        }

        #expect(await vc.test_pressRow(.bluetooth) == false)

        #expect(vc.test_activeStep == .audio, "nothing moved")
        #expect(vc.test_browseStep == nil, "and nothing opened for reading")
    }

    /// The row-level target is two-mode aware for free — it fires whatever the
    /// ribbon currently offers, so after a denial it opens Settings.
    @Test func theRowPressFollowsTheTwoModePrimary() async {
        var opened: [SystemSettingsPane] = []
        let vc = makeVC(model: makeModel(audio: .denied), onOpenSettings: { opened.append($0) })
        _ = await vc.test_pressRow(.audio)   // first press: the probe lands denied
        #expect(opened.isEmpty)

        _ = await vc.test_pressRow(.audio)

        #expect(opened == [.screenAndSystemAudioRecording])
    }

    /// A DECIDED row opens for reading: the hero shows the pane its switch lives
    /// on, resting already ON, and nothing about the flow moves. A second press
    /// puts it back.
    @Test func browsingADoneRowRestsItsPaneWithTheSwitchOn() async {
        let vc = makeVC(model: makeGrantableModel())
        vc.test_demoReduceMotionOverride = false
        vc.test_demoCanAnimateOverride = true
        await vc.test_allow([.audio, .localNetwork])
        #expect(vc.test_activeStep == .bluetooth)

        #expect(await vc.test_pressRow(.audio))

        #expect(vc.test_browseStep == .audio)
        #expect(vc.test_rowIsBrowseSelected(.audio))
        #expect(vc.test_demoMode == .settings)
        #expect(vc.test_heroRestingSwitchOn, "a granted step really would be found switched on")
        #expect(!vc.test_isDemoAnimating, "a browse is a reading position, not a rehearsal")
        #expect(vc.test_ribbonButtonTitles == ["Open settings…"], "the quiet way back to it")
        #expect(vc.test_activeStep == .bluetooth, "browsing never touches the sequence")

        #expect(await vc.test_pressRow(.audio))

        #expect(vc.test_browseStep == nil, "a second press puts it back")
        #expect(!vc.test_rowIsBrowseSelected(.audio))
    }

    /// A browse is a reading position on a decided row — and the moment the LIVE
    /// row fires its ask, the stage belongs to that ask. Browse content left in
    /// place would mask the waiting dim, the denied status line, and the
    /// announcement that line drives.
    @Test func firingTheLiveRowsAskClosesAnyBrowse() async {
        let vc = makeVC(model: makeModel(audio: .granted,
                                         localNetwork: CannedOutcomeLocalNetwork(outcome: .denied),
                                         ptpHelper: FakePTPHelper(status: .enabled)))
        await vc.test_awaitInitialStatuses()
        await vc.test_tapAllow(.audio)
        #expect(vc.test_activeStep == .localNetwork)

        #expect(await vc.test_pressRow(.audio))
        #expect(vc.test_browseStep == .audio, "the decided row is open for reading")

        #expect(await vc.test_pressRow(.localNetwork))

        #expect(vc.test_browseStep == nil, "the live ask took the stage back")
        #expect(vc.test_ribbonStatusText?.contains("macOS only asks once") ?? false,
                "the refusal is what the ribbon is saying, not the browsed row's copy")
        #expect(vc.test_rowIsBroken(.localNetwork))
        // The refusal's own edge SPOKE — and it speaks the refusal, not the
        // waiting line: the edge is held while the prompt is in flight and
        // fires on the repaint after it resolves, when the ribbon carries the
        // denied copy.
        #expect(vc.test_announcements.last == vc.test_ribbonStatusText,
                "the refusal's edge announced the denied copy: \(vc.test_announcements)")
    }

    /// Awkward cell B: a GRANTED Local Network on macOS 14 was never gated, so
    /// there is no privacy pane to browse — the dialog it never raised is the
    /// honest picture, at rest, with nowhere to send anyone.
    @Test func browsingAnUngatedLocalNetworkFallsBackToThePromptMock() async {
        let vc = makeVC(model: makeModel(audio: .granted, localNetworkGated: false))
        await vc.test_tapAllow(.audio)
        #expect(vc.test_activeStep == .bluetooth)

        #expect(await vc.test_pressRow(.localNetwork))

        #expect(vc.test_browseStep == .localNetwork)
        #expect(vc.test_demoMode == .prompt)
        #expect(!vc.test_heroRestingSwitchOn)
        #expect(vc.test_ribbonButtonTitles.isEmpty, "no pane exists, so no link to it")
    }

    /// A SKIPPED row takes the skip back: the ask is re-armed, the check row
    /// derives back to pending, and the ribbon says the skip cost nothing.
    @Test func pressingASkippedRowReArmsItsAsk() async {
        let vc = makeVC(model: makeGrantableModel())
        await vc.test_allow([.audio, .localNetwork])
        vc.test_tapSkip(.bluetooth)
        vc.test_tapSkip(.remoteControl)
        await vc.test_awaitFinalCheck()
        #expect(vc.test_checkRowState == .passed)

        #expect(await vc.test_pressRow(.bluetooth))

        #expect(vc.test_activeStep == .bluetooth, "the ask is back")
        #expect(!vc.test_isSkipped(.bluetooth))
        #expect(vc.test_checkRowState == .pending, "the check reverts with the re-opened row")
        #expect(!vc.test_doneExists, "and the gate closes with it")
        #expect(vc.test_ribbonStatusText == "You skipped this earlier. Nothing's lost.")
        #expect(vc.test_ribbonButtonTitles == ["Skip for now", "Enable Bluetooth Access"])
    }

    /// VoiceOver sees a pressable row as the button, named for what pressing it
    /// does, with the trailing marker's meaning carried in the label — a marker
    /// VoiceOver can't see is a marker that isn't there.
    @Test func rowsSpeakTheirStateAndTheirAction() async {
        let vc = makeVC(model: makeGrantableModel())
        #expect(vc.test_rowIsAccessibilityButton(.audio))
        #expect(vc.test_rowAccessibilityAction(.audio) == "Enable system audio")
        #expect(!vc.test_rowIsAccessibilityButton(.localNetwork), "a locked row offers no action")
        #expect(vc.test_rowAccessibilityLabel(.localNetwork) == "Find speakers on Wi\u{2011}Fi, locked")

        await vc.test_tapAllow(.audio)

        #expect(vc.test_rowAccessibilityAction(.audio) == "Show", "a decided row browses")
        #expect(vc.test_rowAccessibilityLabel(.audio) == "Hearing your Mac's sound, allowed")
    }

    // MARK: Skip

    @Test func skipIsOfferedOnlyOnTheOptionalSteps() async {
        let vc = makeVC(model: makeGrantableModel())
        #expect(vc.test_ribbonButtonTitles == ["Enable system audio"], "System Audio is required")

        await vc.test_allow([.audio, .localNetwork])

        #expect(vc.test_activeStep == .bluetooth)
        #expect(vc.test_ribbonButtonTitles == ["Skip for now", "Enable Bluetooth Access"])
        #expect(vc.test_heroWhy == "Audiout needs this to stream to Bluetooth speakers "
                + "and wake ones that are off.")
        #expect(vc.test_ribbonBodyText == nil, "the honesty line went with the rest of the copy")
    }

    @Test func skippingAdvancesWithoutACheckmark() async {
        let vc = makeVC(model: makeGrantableModel())
        await vc.test_allow([.audio, .localNetwork])

        vc.test_ribbonTapSkip()

        // Speaker Sync is already satisfied in this model, so the next step the
        // flow can offer is Remote Control — skipping advances PAST a row, it
        // doesn't step onto the next index blindly.
        #expect(vc.test_activeStep == .remoteControl)
        #expect(!vc.test_hasCheckmark(.bluetooth), "skipped is not granted")
        #expect(vc.test_spineTitle(of: .bluetooth) == "Bluetooth speakers")
    }

    @Test func skipIsIgnoredOnARequiredStep() async {
        let vc = makeVC(model: makeModel(audio: .unknown))
        vc.test_tapSkip(.audio)
        #expect(vc.test_activeStep == .audio, "the gate is not negotiable")
    }

    // MARK: The ribbon's two-mode primary + deep links

    @Test func deniedAudioSwitchesThePrimaryToOpenSettings() async {
        let vc = makeVC(model: makeModel(audio: .denied))
        await vc.test_tapAllow(.audio)
        #expect(vc.test_ribbonButtonTitles == ["Open settings…"])
    }

    /// The refusal state, in the ribbon's own words: macOS only asks once, so
    /// the honest next move is a switch — and the row that was refused is the
    /// one on the spine drawing attention to itself.
    @Test func aRefusalSaysMacOSOnlyAsksOnceAndBreaksItsRow() async {
        let vc = makeVC(model: makeModel(audio: .denied))

        await vc.test_tapAllow(.audio)

        #expect(vc.test_ribbonStatusText
                == "You chose Don't Allow. macOS only asks once, so from here it's "
                   + "a switch in System Settings.")
        #expect(vc.test_rowIsBroken(.audio))
        #expect(vc.test_ribbonButtonTitles == ["Open settings…"])
        #expect(vc.test_ribbonStatusTextColor == Tokens.Color.label2,
                "the failure hue is graphical-object-only (house rule 8) — the words beside the red glyph stay ordinary body ink")
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
    /// invented switched-off speaker, and the primary keeps being the retry that
    /// line asks for. Settings is demoted beside it, never instead of it: a step
    /// whose only button opened Settings left NOTHING able to re-browse.
    @Test func anUnprovenLocalNetworkOffersARetryNotADeadEnd() async {
        var opened: [SystemSettingsPane] = []
        let vc = makeVC(model: makeModel(audio: .granted, foundSpeakers: 0),
                        onOpenSettings: { opened.append($0) })
        await vc.test_allow([.audio, .localNetwork])

        #expect(vc.test_activeStep == .localNetwork, "an unproven browse does not advance")
        #expect(vc.test_ribbonStatusText
                == "Nothing has answered yet. If the permission dialog is open, choose Allow, or try again.")
        #expect(vc.test_ribbonButtonTitles == ["Open settings…", "Try again"],
                "the bar reads leading to trailing, so the primary is last")

        await vc.test_ribbonTapPrimary()

        #expect(opened.isEmpty, "the primary browses again — it must not open Settings")
        #expect(vc.test_ribbonButtonTitles == ["Open settings…", "Try again"])
    }

    /// The retry really re-runs the browse, and the row reports what the second
    /// one found — the whole point of keeping it a retry.
    @Test func theLocalNetworkRetryBrowsesAgainAndReportsWhatItFinds() async {
        let vc = makeVC(model: makeModel(audio: .granted,
                                         localNetwork: ScriptedLocalNetwork([0, 2])))
        await vc.test_allow([.audio, .localNetwork])
        #expect(vc.test_activeStep == .localNetwork)

        await vc.test_tapAllow(.localNetwork)

        #expect(vc.test_spineTitle(of: .localNetwork) == "2 speakers on your network")
        #expect(vc.test_activeStep == .bluetooth)
        #expect(vc.test_ribbonStatusText == nil, "nothing left to explain")
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
    /// so the ribbon stops offering a retry and becomes the Settings deep link —
    /// the same two-mode shape a denied System Audio or Bluetooth step takes.
    @Test func aRefusedLocalNetworkOffersSettingsInsteadOfARetry() async {
        var opened: [SystemSettingsPane] = []
        let vc = makeVC(model: makeModel(audio: .granted,
                                         localNetwork: CannedOutcomeLocalNetwork(outcome: .denied)),
                        onOpenSettings: { opened.append($0) })
        await vc.test_allow([.audio, .localNetwork])

        #expect(vc.test_activeStep == .localNetwork, "a refusal does not advance the flow")
        #expect(vc.test_ribbonButtonTitles == ["Open settings…"])
        #expect(vc.test_ribbonStatusText?.contains("macOS only asks once") ?? false,
                "a refusal reads as a refusal — no speaker advice, a speaker isn't the problem")

        await vc.test_tapAllow(.localNetwork)

        #expect(opened == [.localNetwork])
    }

    /// The Settings trip a refused Local Network arms: the row keeps its
    /// spinner — and says so in its label — until a genuine return lets one
    /// re-read land, then clears while the denial itself is untouched.
    @Test func aSettingsTripLeavesTheRowWaitingUntilAGenuineReturn() async {
        var opened: [SystemSettingsPane] = []
        let vc = makeVC(model: makeModel(audio: .granted,
                                         localNetwork: CannedOutcomeLocalNetwork(outcome: .denied)),
                        onOpenSettings: { opened.append($0) })
        await vc.test_allow([.audio, .localNetwork])

        await vc.test_tapAllow(.localNetwork)   // the second tap: the deep link

        #expect(opened == [.localNetwork])
        #expect(vc.test_rowIsWaiting(.localNetwork))
        #expect(vc.test_rowAccessibilityLabel(.localNetwork)?.contains(", waiting") ?? false)

        vc.appDidResignActive()      // Settings takes the front
        vc.appDidBecomeActive()      // the user comes back
        await vc.test_awaitSettingsReturn()

        #expect(!vc.test_rowIsWaiting(.localNetwork), "a genuine return re-reads and clears the wait")
        #expect(vc.test_rowIsBroken(.localNetwork), "the re-read found nothing changed — still denied")
    }

    /// Our own activation catching up with the click that opened Settings is
    /// not the user coming back — no resign sits in front of it, so the wait
    /// must survive untouched (the same self-activation gate the window
    /// level already enforces, see `askingForRemoteControlYieldsTheLevel…`).
    @Test func aSelfActivationWithNoResignDoesNotClearTheWait() async {
        var opened: [SystemSettingsPane] = []
        let vc = makeVC(model: makeModel(audio: .granted,
                                         localNetwork: CannedOutcomeLocalNetwork(outcome: .denied)),
                        onOpenSettings: { opened.append($0) })
        await vc.test_allow([.audio, .localNetwork])
        await vc.test_tapAllow(.localNetwork)   // the second tap: the deep link
        #expect(vc.test_rowIsWaiting(.localNetwork))

        vc.appDidBecomeActive()   // no resign first — our own click, not a return
        await vc.test_awaitSettingsReturn()

        #expect(vc.test_rowIsWaiting(.localNetwork), "a wait that never saw a real resign must survive")
    }

    /// The permission is what completes this step: a grant with nothing switched
    /// on still earns the checkmark, and the title says exactly what happened.
    @Test func aGrantedLocalNetworkWithNoSpeakersStillCompletes() async {
        let vc = makeVC(model: makeModel(audio: .granted,
                                         localNetwork: CannedOutcomeLocalNetwork(
                                             outcome: .granted(foundSpeakers: 0))))
        await vc.test_allow([.audio, .localNetwork])

        #expect(vc.test_activeStep == .bluetooth, "the permission landed, so the flow moves on")
        #expect(vc.test_spineTitle(of: .localNetwork) == "No speakers found yet")
        #expect(vc.test_hasCheckmark(.localNetwork))
    }

    /// A Local Network prime can sit a full minute on an unanswered dialog, so
    /// the ribbon has to say what it is waiting for — and then say something
    /// different once the answer lands and only the count is left.
    @Test func theRibbonNamesBothHalvesOfTheLocalNetworkWait() async {
        let net = SteppedLocalNetwork(found: 2)
        let vc = makeVC(model: makeModel(audio: .granted, localNetwork: net))
        await vc.test_tapAllow(.audio)

        let priming = Task { await vc.test_tapAllow(.localNetwork) }

        await net.waitUntilParked()
        await waitUntil { vc.test_ribbonStatusText == OnboardingViewController.waitingStatus }
        #expect(vc.test_ribbonStatusText == OnboardingViewController.waitingStatus)
        #expect(vc.test_ribbonIsWaiting)
        #expect(vc.test_rowIsWaiting(.localNetwork), "the dialog wait shows on the row too")

        net.resume()                                    // the browse reaches the network
        await net.waitUntilParked()
        await waitUntil { vc.test_ribbonStatusText == "Checking your network\u{2026}" }
        #expect(vc.test_ribbonStatusText == "Checking your network\u{2026}")
        #expect(vc.test_ribbonIsWaiting)
        #expect(vc.test_rowIsWaiting(.localNetwork),
                "promptInFlightStep excludes the verifying tail, but the row spinner must not")

        net.resume()
        await priming.value

        #expect(!vc.test_ribbonIsWaiting, "the wait clears with the answer")
        #expect(!vc.test_rowIsWaiting(.localNetwork), "false after the answer lands")
        #expect(vc.test_spineTitle(of: .localNetwork) == "2 speakers on your network")
    }

    /// The ribbon's status spinner and the row's own must both honor Reduce
    /// Motion — the wait itself stays visible in words, but neither spinner
    /// spins.
    @Test func reduceMotionDropsTheLocalNetworkWaitSpinners() async {
        let net = SteppedLocalNetwork(found: 2)
        let vc = makeVC(model: makeModel(audio: .granted, localNetwork: net))
        await vc.test_tapAllow(.audio)
        vc.test_ribbonReduceMotionOverride = true
        vc.test_setRowReduceMotionOverride(.localNetwork, true)

        let priming = Task { await vc.test_tapAllow(.localNetwork) }

        await net.waitUntilParked()
        await waitUntil { vc.test_ribbonStatusText == OnboardingViewController.waitingStatus }
        #expect(vc.test_ribbonStatusText == OnboardingViewController.waitingStatus,
                "the wait is still named in words")
        #expect(!vc.test_ribbonIsWaiting, "Reduce Motion: the ribbon's own spinner never shows")
        #expect(vc.test_rowIsWaiting(.localNetwork), "the row still knows it is waiting")
        #expect(!vc.test_rowSpinnerIsAnimating(.localNetwork), "Reduce Motion: the row spinner never spins")

        net.resume()
        net.resume()
        await priming.value
    }

    /// A refusal skips the second half entirely — there is nothing left to
    /// check, so the ribbon goes straight to its actionable denied state.
    @Test func aRefusedLocalNetworkLeavesNoWaitOnScreen() async {
        let vc = makeVC(model: makeModel(audio: .granted,
                                         localNetwork: CannedOutcomeLocalNetwork(outcome: .denied)))
        await vc.test_allow([.audio, .localNetwork])

        #expect(!vc.test_ribbonIsWaiting)
        #expect(!vc.test_stageIsDimmed)
        #expect(vc.test_ribbonButtonTitles == ["Open settings…"])
    }

    /// An undecided prime (the dialog is still up when the ceiling expires) must
    /// leave the step ACTIONABLE, never stuck saying it is waiting.
    @Test func anUndecidedLocalNetworkPrimeLeavesTheStepActionable() async {
        let vc = makeVC(model: makeModel(audio: .granted, foundSpeakers: 0))
        await vc.test_allow([.audio, .localNetwork])

        #expect(!vc.test_ribbonIsWaiting, "never a stuck wait")
        #expect(vc.test_ribbonButtonTitles == ["Open settings…", "Try again"])
        #expect(vc.test_isRowPressable(.localNetwork))
    }

    /// The waiting beat, whole: the shared line, the spinner, a stage that steps
    /// back for the real dialog, and NO buttons — the answer is somewhere else
    /// now. Bluetooth's answer arrives on a callback the click can't await, so
    /// it is the step that shows the beat at rest.
    @Test func anUndecidedPromptDimsTheStageAndTakesEveryButtonAway() async {
        let model = makeModel(audio: .granted, foundSpeakers: 2,
                              bluetoothPrimer: NeverDecidingBluetooth())
        let vc = makeVC(model: model)
        await vc.test_allow([.audio, .localNetwork])
        #expect(vc.test_activeStep == .bluetooth)

        await vc.test_tapAllow(.bluetooth)

        #expect(vc.test_ribbonStatusText == OnboardingViewController.waitingStatus)
        #expect(vc.test_ribbonIsWaiting, "the wait is visible")
        #expect(vc.test_stageIsDimmed, "the rehearsal steps back for the real dialog")
        #expect(vc.test_ribbonButtonTitles.isEmpty, "no second ask while one is in flight")
    }

    /// …and the wait expires, so the ask comes back instead of staying wedged
    /// for the rest of the presentation.
    @Test func anUndecidedBluetoothPromptStopsWaitingAfterItsTimeout() async {
        let model = makeModel(audio: .granted, foundSpeakers: 2,
                              bluetoothPrimer: NeverDecidingBluetooth(),
                              bluetoothPromptTimeout: 0.05)
        let vc = makeVC(model: model)
        await vc.test_allow([.audio, .localNetwork])
        await vc.test_tapAllow(.bluetooth)
        #expect(vc.test_ribbonIsWaiting)

        await waitUntil { !model.isPrimingBluetooth }
        vc.test_refresh()

        #expect(!vc.test_ribbonIsWaiting, "the spinner clears itself")
        #expect(!vc.test_stageIsDimmed)
        #expect(vc.test_ribbonButtonTitles == ["Skip for now", "Enable Bluetooth Access"],
                "and the step can ask again")
    }

    /// The row's own spinner mirrors the ribbon's wait for an undecided
    /// Bluetooth prompt — and, like the ribbon, must never get stuck once the
    /// prompt's ceiling has passed.
    @Test func theRowSpinnerTracksAnUndecidedBluetoothPromptAndNeverLatches() async {
        let model = makeModel(audio: .granted, foundSpeakers: 2,
                              bluetoothPrimer: NeverDecidingBluetooth())
        let vc = makeVC(model: model)
        await vc.test_allow([.audio, .localNetwork])

        await vc.test_tapAllow(.bluetooth)

        #expect(vc.test_rowIsWaiting(.bluetooth))

        let timeoutModel = makeModel(audio: .granted, foundSpeakers: 2,
                                     bluetoothPrimer: NeverDecidingBluetooth(),
                                     bluetoothPromptTimeout: 0.05)
        let timeoutVC = makeVC(model: timeoutModel)
        await timeoutVC.test_allow([.audio, .localNetwork])
        await timeoutVC.test_tapAllow(.bluetooth)
        #expect(timeoutVC.test_rowIsWaiting(.bluetooth))

        await waitUntil { !timeoutModel.isPrimingBluetooth }
        timeoutVC.test_refresh()

        #expect(!timeoutVC.test_rowIsWaiting(.bluetooth), "a wait must never latch")
    }

    /// The demoted link still works, and still goes to the Local Network pane.
    @Test func theQuietLinkOpensTheLocalNetworkPane() async {
        var opened: [SystemSettingsPane] = []
        let vc = makeVC(model: makeModel(audio: .granted, foundSpeakers: 0),
                        onOpenSettings: { opened.append($0) })
        await vc.test_allow([.audio, .localNetwork])

        vc.test_ribbonTapQuietLink()

        #expect(opened == [.localNetwork])
    }

    /// A browsed row's quiet link is that row's OWN pane — the only way back to
    /// a permission that is already granted.
    @Test func aBrowsedRowsQuietLinkOpensThatRowsPane() async {
        var opened: [SystemSettingsPane] = []
        let vc = makeVC(model: makeGrantableModel(), onOpenSettings: { opened.append($0) })
        await vc.test_allow([.audio, .localNetwork])
        #expect(await vc.test_pressRow(.audio))

        vc.test_ribbonTapQuietLink()

        #expect(opened == [.screenAndSystemAudioRecording])
    }

    // MARK: The in-flight prompt

    /// A permission dialog fights any other process that grabs input focus, and
    /// loses — frozen, unclickable. So the re-front a grant would normally take
    /// is OWED while the dialog is still up, and paid exactly once when it
    /// resolves (here: the Bluetooth prompt's undecided timeout).
    @Test func aReFrontOwedDuringAPromptFiresOnceWhenThePromptResolves() async {
        let model = makeModel(audio: .granted, foundSpeakers: 2,
                              bluetoothPrimer: NeverDecidingBluetooth(),
                              bluetoothPromptTimeout: 0.05)
        let vc = makeVC(model: model)
        await vc.test_allow([.audio, .localNetwork])
        let before = vc.test_returnToFrontCount

        await vc.test_tapAllow(.bluetooth)
        #expect(vc.test_isPromptInFlight, "the prompt is up and unanswered")
        #expect(vc.test_returnToFrontCount == before,
                "the dialog owns the front while it is up")

        await waitUntil { !model.isPrimingBluetooth }

        #expect(!vc.test_isPromptInFlight)
        #expect(vc.test_returnToFrontCount == before + 1,
                "exactly one re-front, and only once the prompt resolved")
    }

    /// The escape hatch: a dialog that has stopped responding must not end the
    /// setup. After the delay the ribbon says so and offers the SAME pane the
    /// denied path deep-links to — nothing is re-asked.
    @Test func aPromptThatStopsRespondingOffersAWayIntoSystemSettings() async {
        var opened: [SystemSettingsPane] = []
        let model = makeModel(audio: .granted, foundSpeakers: 2,
                              bluetoothPrimer: NeverDecidingBluetooth())
        let vc = makeVC(model: model, onOpenSettings: { opened.append($0) })
        await vc.test_allow([.audio, .localNetwork])
        await vc.test_tapAllow(.bluetooth)
        #expect(vc.test_ribbonStatusText != "Dialog not responding?",
                "waiting is normal at first")

        vc.test_fireStuckPromptTimer()

        #expect(vc.test_ribbonStatusText == "Dialog not responding?")
        #expect(vc.test_ribbonButtonTitles.contains("Open settings…"))

        vc.test_ribbonTapQuietLink()

        #expect(opened == [.bluetoothPrivacy], "the denied path's pane, not a second table")
    }

    /// …and it is only ever an escape from a LIVE wait: once the prompt
    /// resolves the hint and its link go with it.
    @Test func theStuckDialogHintClearsWhenThePromptResolves() async {
        let model = makeModel(audio: .granted, foundSpeakers: 2,
                              bluetoothPrimer: NeverDecidingBluetooth(),
                              bluetoothPromptTimeout: 0.05)
        let vc = makeVC(model: model)
        await vc.test_allow([.audio, .localNetwork])
        await vc.test_tapAllow(.bluetooth)
        vc.test_fireStuckPromptTimer()
        #expect(vc.test_ribbonStatusText == "Dialog not responding?")

        await waitUntil { !model.isPrimingBluetooth }

        #expect(vc.test_ribbonStatusText != "Dialog not responding?",
                "nothing is stuck any more")
        #expect(!vc.test_ribbonButtonTitles.contains("Open settings…"))
    }

    @Test func speakerSyncRoutesToLoginItemsThroughTheModelSeam() async {
        let ptpHelper = FakePTPHelper(status: .requiresApproval)
        var opened: [SystemSettingsPane] = []
        let vc = makeVC(model: makeModel(audio: .granted, foundSpeakers: 2, ptpHelper: ptpHelper),
                        onOpenSettings: { opened.append($0) })
        await vc.test_allow([.audio, .localNetwork])
        vc.test_tapSkip(.bluetooth)
        #expect(vc.test_activeStep == .speakerSync)
        #expect(vc.test_ribbonButtonTitles == ["Skip for now", "Turn on at login"])
        #expect(vc.test_heroHeadline == "Keep speakers on one shared clock")
        #expect(vc.test_heroWhy == "A small helper shares one clock so your speakers never drift.")

        await vc.test_tapAllow(.speakerSync)

        #expect(ptpHelper.openSettingsCount == 1)
        #expect(opened.isEmpty, "Login Items is not a privacy pane deep link")
    }

    /// Speaker Sync's own Settings trip: the Login Items round-trip covers the
    /// row in its spinner, and a genuine return that finds the helper enabled
    /// clears the wait and lands the checkmark.
    @Test func speakerSyncRowWaitsThroughTheLoginItemsTripThenShowsItsCheckmark() async {
        let helper = FakePTPHelper(status: .requiresApproval)
        let vc = makeVC(model: makeModel(audio: .granted, foundSpeakers: 2, bluetooth: .granted,
                                         ptpHelper: helper))
        await vc.test_allow([.audio, .localNetwork, .bluetooth])
        #expect(vc.test_activeStep == .speakerSync)

        await vc.test_tapAllow(.speakerSync)

        #expect(helper.openSettingsCount == 1)
        #expect(vc.test_rowIsWaiting(.speakerSync))

        helper.status = .enabled
        vc.appDidResignActive()
        vc.appDidBecomeActive()
        await vc.test_awaitSettingsReturn()

        #expect(!vc.test_rowIsWaiting(.speakerSync))
        #expect(vc.test_hasCheckmark(.speakerSync))
    }

    // MARK: Speaker Sync's un-rehearsed states (P0-1)

    /// …and the trip that comes back with the switch STILL off — the state that
    /// used to re-draw the untouched first ask and leave the gate shut forever.
    /// It now says where the switch really is, offers the trip again, and offers
    /// the way past.
    @Test func speakerSyncSaysWhereTheSwitchIsWhenLoginItemsCameBackStillOff() async {
        let helper = FakePTPHelper(status: .requiresApproval)
        let vc = makeVC(model: makeModel(audio: .granted, foundSpeakers: 2, bluetooth: .granted,
                                         ptpHelper: helper))
        await vc.test_allow([.audio, .localNetwork, .bluetooth])
        #expect(vc.test_activeStep == .speakerSync)

        await vc.test_tapAllow(.speakerSync)        // → Login Items
        vc.appDidResignActive()
        vc.appDidBecomeActive()                     // → back, still unapproved
        await vc.test_awaitSettingsReturn()

        #expect(vc.test_ribbonStatusText == OnboardingViewController.speakerSyncRecoveryStatus)
        #expect(vc.test_ribbonBodyText == OnboardingViewController.speakerSyncRecoveryBody)
        #expect(vc.test_ribbonButtonTitles == ["Skip for now", "Open Login Items\u{2026}"])

        vc.test_ribbonTapSkip()

        #expect(vc.test_isSkipped(.speakerSync), "and the way past really goes through")
    }

    /// The daemon isn't in the bundle: there is no switch anywhere, so the row
    /// auto-passes with the note as its whole explanation and the flow moves on.
    @Test func speakerSyncAutoPassesWithItsNoteWhenTheHelperIsMissing() async {
        let vc = makeVC(model: makeModel(audio: .granted, foundSpeakers: 2, bluetooth: .granted,
                                         ptpHelper: FakePTPHelper(status: .notFound)))
        await vc.test_awaitInitialStatuses()
        await vc.test_allow([.audio, .localNetwork, .bluetooth])

        #expect(!vc.test_hasCheckmark(.speakerSync), "nobody approved anything")
        #expect(vc.test_note(of: .speakerSync) == "Couldn't be turned on")
        #expect(vc.test_activeStep == .remoteControl, "the gate is not held on a packaging bug")
    }

    /// An auto-pass is not a grant, so VoiceOver hears the NOTE — the reason the
    /// row passed — where a completed row says ", allowed".
    @Test func anAutoPassedRowSpeaksItsNoteInsteadOfClaimingAGrant() async {
        let vc = makeVC(model: makeModel(audio: .unsupported))
        await vc.test_tapAllow(.audio)

        let label = vc.test_rowAccessibilityLabel(.audio) ?? ""
        #expect(label.hasSuffix(", requires macOS 14.2 or later"), "\(label)")
        #expect(!label.contains(", allowed"), "\(label)")
    }

    /// A row drawn BROKEN is the one row asking to be looked at, so pressing it
    /// has to do the thing it is asking for — whatever state it otherwise wears,
    /// and for VoiceOver as much as for the mouse.
    @Test func aBrokenPendingRowIsPressableAndPressingItMovesTheFlow() async {
        let vc = makeVC(model: makeModel(audio: .unknown, foundSpeakers: 2,
                                         ptpHelper: FakePTPHelper(status: .requiresApproval)),
                        reason: .permissionLost([.ptpHelper]))
        await vc.test_awaitInitialStatuses()
        #expect(vc.test_activeStep == .audio, "the walk starts at the first unmet step")
        #expect(vc.test_rowIsBroken(.speakerSync))
        #expect(vc.test_isRowPressable(.speakerSync))
        #expect(vc.test_rowIsAccessibilityButton(.speakerSync))

        #expect(await vc.test_pressRow(.speakerSync))

        #expect(vc.test_snapBackStep == .speakerSync)
        #expect(vc.test_activeStep == .speakerSync)
    }

    // MARK: What a wait, a stuck dialog and a refused ✕ say out loud

    /// None of the three has anything a screen reader can see: the buttons leave
    /// the layout, the stage dims, and the ✕ simply does nothing. So all three
    /// are spoken, and the refusal takes the ribbon's status line too.
    @Test func theWaitTheStuckHintAndARefusedCloseAreAllSpoken() async {
        let model = makeModel(audio: .granted, foundSpeakers: 2,
                              bluetoothPrimer: NeverDecidingBluetooth())
        let vc = makeVC(model: model)
        await vc.test_awaitInitialStatuses()   // announcements start once the opening state is known
        await vc.test_allow([.audio, .localNetwork])

        await vc.test_tapAllow(.bluetooth)
        #expect(vc.test_announcements.contains(OnboardingViewController.waitingStatus),
                "\(vc.test_announcements)")

        vc.noteCloseRefused()
        #expect(vc.test_announcements.contains(OnboardingViewController.closeRefusedStatus),
                "\(vc.test_announcements)")
        #expect(vc.test_ribbonStatusText == OnboardingViewController.closeRefusedStatus,
                "the reason replaces the wait's line")
        #expect(vc.test_ribbonIsWaiting, "…and the spinner stays: the dialog is still up")

        vc.test_fireStuckPromptTimer()
        #expect(vc.test_announcements.contains(OnboardingViewController.stuckPromptHint),
                "\(vc.test_announcements)")
    }

    /// …and the window is the half that starts it: it still refuses to close
    /// while a dialog is unanswered, but hands the refusal to the content VC
    /// instead of swallowing it.
    @Test func theWindowHandsARefusedCloseToTheContentSoItCanSayWhy() async throws {
        let model = makeModel(audio: .granted, foundSpeakers: 2,
                              bluetoothPrimer: NeverDecidingBluetooth())
        let wc = OnboardingWindowController(model: model, openSettings: { _ in }, onFinished: {})
        let window = try #require(wc.window)
        let vc = wc.test_contentViewController
        _ = vc.test_rootView
        await vc.test_allow([.audio, .localNetwork])
        #expect(wc.windowShouldClose(window), "nothing in flight — the ✕ is the free exit")

        await vc.test_tapAllow(.bluetooth)

        #expect(!wc.windowShouldClose(window), "refused while the dialog is unanswered")
        #expect(vc.test_ribbonStatusText == OnboardingViewController.closeRefusedStatus,
                "and the refusal is not silent")
    }

    /// An armed Settings/Login Items trip that never actually left cannot leave
    /// the row spinning for the rest of the presentation: the ceiling stands it
    /// back down. (Only a REAL departure hands the wait to the return re-read.)
    @Test func theSettingsTripSpinnerCannotLatchPastItsCeiling() async {
        let vc = makeVC(model: makeModel(audio: .granted, foundSpeakers: 2, bluetooth: .granted,
                                         ptpHelper: FakePTPHelper(status: .requiresApproval)))
        await vc.test_allow([.audio, .localNetwork, .bluetooth])
        await vc.test_tapAllow(.speakerSync)
        #expect(vc.test_rowIsWaiting(.speakerSync), "the trip is armed")

        vc.test_fireSettingsTripTimer()

        #expect(!vc.test_rowIsWaiting(.speakerSync))
    }

    // MARK: Headings and the spoken caption

    /// Remote Control's rehearsal is the one that INSTRUCTS — two surfaces in
    /// sequence with the wrong button ghosted — and none of that reaches
    /// VoiceOver. The caption band speaks it instead.
    @Test func remoteControlsFirstAskSpeaksTheInstructionItsRehearsalDraws() async {
        let vc = makeVC(model: makeGrantableModel())
        await vc.test_allow([.audio, .localNetwork])
        vc.test_tapSkip(.bluetooth)
        #expect(vc.test_activeStep == .remoteControl)
        #expect(vc.test_demoMode == .prompt)

        #expect(vc.test_previewFrameSpokenCaption
                == OnboardingViewController.remoteControlSpokenCaption)
    }

    /// …and only that one: every other step's caption speaks its visible words.
    @Test func noOtherStepSubstitutesASpokenCaption() {
        let vc = makeVC(model: makeModel(audio: .unknown))
        #expect(vc.test_activeStep == .audio)
        #expect(vc.test_previewFrameSpokenCaption
                != OnboardingViewController.remoteControlSpokenCaption)
    }

    /// Both headlines are headings, so VoiceOver's rotor can jump between the
    /// window's title and the step's own.
    @Test func theHeaderAndHeroHeadlinesAreHeadingsForTheRotor() {
        let vc = makeVC(model: makeModel(audio: .unknown))
        #expect(vc.test_titleIsHeading)
        #expect(vc.test_heroHeadlineIsHeading)
    }

    /// Remote Control's first click is the PROMPT — that is what registers our
    /// row in the Accessibility list — and its "Open Settings…" retry then deep-
    /// links to that pane like every other step.
    @Test func remoteControlPromptsFirstThenOpensTheAccessibilityPane() async {
        var opened: [SystemSettingsPane] = []
        let vc = makeVC(model: makeGrantableModel(), onOpenSettings: { opened.append($0) })
        await vc.test_allow([.audio, .localNetwork])
        vc.test_tapSkip(.bluetooth)
        #expect(vc.test_ribbonButtonTitles == ["Skip for now", "Set Up Remote Control\u{2026}"])
        #expect(vc.test_heroHeadline == "Use your volume keys")
        #expect(vc.test_ribbonBodyText == nil,
                "the two-surface warning is the rehearsal's job now, not a paragraph's")

        await vc.test_tapAllow(.remoteControl)
        #expect(opened.isEmpty, "the first ask is the prompt, not a deep link")

        await vc.test_tapAllow(.remoteControl)
        #expect(opened == [.accessibility])
    }

    /// The Accessibility Access prompt is an ordinary alert panel at normal
    /// level, NOT a TCC dialog a system process draws above everything — so the
    /// window has to yield BEFORE the ask, and must not front itself back over
    /// the alert it just raised (owner live observation 2026-08-11).
    @Test func askingForRemoteControlYieldsTheLevelAndDoesNotReFrontOverTheAlert() async {
        let wc = OnboardingWindowController(model: makeGrantableModel(),
                                            openSettings: { _ in },
                                            onFinished: {})
        let vc = wc.test_contentViewController
        _ = vc.test_rootView
        await vc.test_allow([.audio, .localNetwork])
        vc.test_tapSkip(.bluetooth)
        #expect(vc.test_activeStep == .remoteControl)
        #expect(wc.test_windowLevel == .floating)
        let before = vc.test_returnToFrontCount

        await vc.test_tapAllow(.remoteControl)

        #expect(wc.test_windowLevel == .normal,
                "the alert is ordinary window chrome — floating buries it")
        #expect(vc.test_returnToFrontCount == before,
                "the dialog just OPENED; re-fronting would re-bury it")

        // An activation with NO resign in front of it is our own click catching
        // up with the ask, not the user coming back — re-floating there is what
        // buried the alert (`isYieldingToSettings`).
        wc.test_appDidBecomeActive()
        #expect(wc.test_windowLevel == .normal,
                "our own activation must not re-float over the alert it just raised")

        // A real return: the alert took the front, then we got it back.
        wc.test_appDidResignActive()
        wc.test_appDidBecomeActive()
        #expect(wc.test_windowLevel == .floating, "back in our app, back on top")
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
        #expect(!vc.test_doneExists, "decided is not yet checked — the CTA waits for the pass")
        await vc.test_awaitFinalCheck()
        #expect(vc.test_doneExists, "every required permission is in, every row decided, check passed")
        #expect(vc.test_doneIsReturnDefault)
    }

    /// Owner decision 2026-08-11 (tightened gate): the optional steps'
    /// permissions stay outside `RequiredPermission`, but an UNDECIDED one
    /// holds the gate shut — the CTA must never appear beside a row still
    /// offering Allow/Skip. Each decision (a skip here) advances it.
    @Test func anUndecidedOptionalStepHoldsTheGateShut() async {
        let vc = makeVC(model: makeGrantableModel())
        await vc.test_allow([.audio, .localNetwork])
        #expect(vc.test_activeStep == .bluetooth, "the flow still offers them")
        #expect(!vc.test_doneExists, "…and the CTA waits for the answer")

        vc.test_tapSkip(.bluetooth)
        #expect(!vc.test_doneExists, "Remote Control is still undecided")

        vc.test_tapSkip(.remoteControl)
        await vc.test_awaitFinalCheck()
        #expect(vc.test_doneExists, "a skip is a decision — the check runs and the gate opens")
    }

    /// The gate contract is "the CTA exists iff the final check passed", so a
    /// browse opened AFTER the gate must not read as the gate closing: the CTA
    /// stays, the browsed row's own quiet link sits beside it, Return stays with
    /// the CTA, and pressing it still finishes.
    @Test func browsingWithTheGateOpenKeepsTheCTA() async {
        var doneFired = false
        let vc = makeVC(model: makeGrantableModel(), onDone: { doneFired = true })
        await vc.test_allow([.audio, .localNetwork])
        vc.test_tapSkip(.bluetooth)
        vc.test_tapSkip(.remoteControl)
        await vc.test_awaitFinalCheck()
        #expect(vc.test_doneExists)

        #expect(await vc.test_pressRow(.audio))

        #expect(vc.test_browseStep == .audio)
        #expect(vc.test_doneExists, "a browse is a reading position, not the gate closing")
        #expect(vc.test_doneTitle == "Start listening")
        #expect(vc.test_ribbonButtonTitles.contains("Start listening"))
        #expect(vc.test_ribbonButtonTitles.contains("Open settings…"),
                "the browsed row's own pane, beside the CTA")
        #expect(vc.test_doneIsReturnDefault, "Return stays with the CTA")

        await vc.test_ribbonTapPrimary()
        await waitUntil { doneFired }

        #expect(doneFired, "the CTA still finishes from a browse")
    }

    // MARK: The final check (the sixth row + the beat)

    /// The sixth row's walk: dormant "One last check" while any row is
    /// undecided, auto-running the moment the last one is decided — with
    /// NOTHING payoff-ish on screen while it runs — then the pass lands the
    /// checkmark, the settled finale, and the CTA together.
    @Test func theCheckRowRunsOnTheLastDecisionAndGatesThePayoff() async {
        let vc = makeVC(model: makeGrantableModel())
        #expect(vc.test_checkRowState == .pending)
        #expect(vc.test_checkRowTitle == "One last check")
        #expect(!vc.test_checkRowIsSpinning)
        #expect(!vc.test_checkRowHasCheckmark)

        await vc.test_allow([.audio, .localNetwork])
        vc.test_tapSkip(.bluetooth)
        #expect(vc.test_checkRowState == .pending, "Remote Control is still undecided")

        vc.test_tapSkip(.remoteControl)   // the last decision — the check auto-runs

        #expect(vc.test_checkRowState == .running)
        #expect(vc.test_checkRowTitle == "Making sure everything's ready\u{2026}")
        #expect(vc.test_checkRowIsSpinning)
        #expect(!vc.test_doneExists, "no CTA until the check passes")
        #expect(vc.test_demoMode != .settled, "no finale until the check passes")

        await vc.test_awaitFinalCheck()

        #expect(vc.test_checkRowState == .passed)
        #expect(vc.test_checkRowTitle == "Everything's ready")
        #expect(vc.test_checkRowHasCheckmark)
        #expect(!vc.test_checkRowIsSpinning)
        #expect(vc.test_doneExists, "the CTA arrives on the pass")
        #expect(vc.test_demoMode == .settled, "…together with the finale")
    }

    /// The final check's spinner must also honor Reduce Motion — "running" is
    /// still the logical state the row's title reports, but the spinner
    /// itself never spins.
    @Test func reduceMotionDropsTheFinalCheckSpinner() async {
        let vc = makeVC(model: makeGrantableModel())
        vc.test_checkRowReduceMotionOverride = true

        await vc.test_allow([.audio, .localNetwork])
        vc.test_tapSkip(.bluetooth)
        vc.test_tapSkip(.remoteControl)   // the last decision — the check auto-runs

        #expect(vc.test_checkRowState == .running)
        #expect(vc.test_checkRowIsSpinning, "the logical state is still \"running\"")
        #expect(!vc.test_checkRowSpinnerIsAnimating, "Reduce Motion: the spinner never spins")

        await vc.test_awaitFinalCheck()
        #expect(vc.test_checkRowState == .passed)
    }

    /// The row is real UI (unlike the decorative demo pane): one VoiceOver
    /// element whose label is the same state-carrying title the pixels draw.
    @Test func theCheckRowSpeaksItsStateToVoiceOver() async {
        let vc = makeVC(model: makeGrantableModel())
        #expect(vc.test_checkRowAccessibilityLabel == "One last check")

        await vc.test_allow([.audio, .localNetwork])
        vc.test_tapSkip(.bluetooth)
        vc.test_tapSkip(.remoteControl)
        await vc.test_awaitFinalCheck()

        #expect(vc.test_checkRowAccessibilityLabel == "Everything's ready")
    }

    /// The fixed 820×560 fit, re-pinned on the spine: the header plus six rows
    /// must stay inside the pane in every state, including the tallest header
    /// (a two-permission lost-permission warning) and the complete state.
    @Test func theSpineFitsTheFixedWindowInItsTallestStates() async {
        func layout(_ vc: OnboardingViewController) {
            let root = vc.test_rootView
            root.frame = NSRect(x: 0, y: 0,
                                width: OnboardingViewController.contentWidth,
                                height: OnboardingViewController.contentHeight)
            root.layoutSubtreeIfNeeded()
        }

        let fresh = makeVC(model: makeModel(audio: .unknown))
        layout(fresh)
        #expect(fresh.test_spineStackFrame.minY >= 0,
                "first run: the six rows overrun the pane by \(-fresh.test_spineStackFrame.minY) pt")

        let lost = makeVC(model: makeModel(audio: .denied),
                          reason: .permissionLost([.audioCapture, .ptpHelper]))
        layout(lost)
        #expect(lost.test_spineStackFrame.minY >= 0,
                "the tallest header: the six rows overrun the pane by \(-lost.test_spineStackFrame.minY) pt")

        let complete = makeVC(model: makeGrantableModel())
        await complete.test_allow([.audio, .localNetwork])
        complete.test_tapSkip(.bluetooth)
        complete.test_tapSkip(.remoteControl)
        await complete.test_awaitFinalCheck()
        layout(complete)
        #expect(complete.test_doneExists)
        #expect(complete.test_spineStackFrame.minY >= 0,
                "complete: the six rows overrun the pane by \(-complete.test_spineStackFrame.minY) pt")
    }

    /// v4 live fix ("Start listening took two clicks"): the last grant is often
    /// detected by the poll while the user is still IN System Settings, whose
    /// frontmost app can make macOS decline our re-activation — so the user
    /// returns to an INACTIVE app, where a stock control spends the first click
    /// activating the window. The CTA, every prominent Allow, and the live row
    /// act on that activating click; a locked row keeps stock behaviour.
    @Test func theCTAAndLiveRowActOnTheActivatingClick() async {
        let vc = makeVC(model: makeGrantableModel())
        #expect(vc.test_rowAcceptsFirstMouse(.audio), "the live row acts on first mouse")
        #expect(!vc.test_rowAcceptsFirstMouse(.bluetooth), "a locked row keeps stock behaviour")
        #expect(ProminentButton(title: "Allow…", target: nil, action: nil)
                    .acceptsFirstMouse(for: nil),
                "every prominent button — the ribbon's Allow lives the same bounce loop")

        await vc.test_allow([.audio, .localNetwork])
        vc.test_tapSkip(.bluetooth)
        vc.test_tapSkip(.remoteControl)
        await vc.test_awaitFinalCheck()

        #expect(vc.test_doneAcceptsFirstMouse, "the CTA acts on the returning click")
    }

    @Test func doneFinishesWhenReVerificationPasses() async {
        var doneFired = false
        let vc = makeVC(model: makeGrantableModel(), onDone: { doneFired = true })
        await vc.test_allow([.audio, .localNetwork])
        vc.test_tapSkip(.bluetooth)
        vc.test_tapSkip(.remoteControl)
        await vc.test_awaitFinalCheck()

        await vc.test_tapDone()

        #expect(doneFired)
        #expect(vc.test_snapBackStep == nil)
    }

    /// The revocation case: Done's re-verify finds the silent audio read has gone
    /// denied since, so the flow snaps back to that step instead of finishing —
    /// no sheet, no "continue anyway". The revocation lands AFTER the automatic
    /// check passed (a flip caught BY the check is the auto-check failure test).
    @Test func doneSnapsBackToARevokedStepInsteadOfFinishing() async {
        var doneFired = false
        let audio = MutableSilentAudioProbe(silent: .granted)
        let vc = makeVC(model: makeModel(audio: .granted, audioProbe: audio, foundSpeakers: 3,
                                         ptpHelper: FakePTPHelper(status: .enabled)),
                        onDone: { doneFired = true })
        await vc.test_allow([.audio, .localNetwork])
        vc.test_tapSkip(.bluetooth)
        vc.test_tapSkip(.remoteControl)
        await vc.test_awaitFinalCheck()
        #expect(vc.test_doneExists)

        audio.silent = .denied   // revoked while the CTA sat on screen

        await vc.test_tapDone()

        #expect(!doneFired, "a hard gate does not finish on an unmet permission")
        #expect(vc.test_snapBackStep == .audio)
        #expect(vc.test_activeStep == .audio)
        #expect(!vc.test_doneExists, "the gate closes again")
        #expect(vc.test_checkRowState == .pending, "the check row reverts with the snap-back")
    }

    /// A snap-back must land on a VISIBLE stage: the browse the user opened
    /// after the gate opened is on a DIFFERENT row from the one that came up
    /// short, and leaving it up would hide the step that needs attention.
    @Test func aSnapBackClosesAnOpenBrowse() async {
        let audio = MutableSilentAudioProbe(silent: .granted)
        let vc = makeVC(model: makeModel(audio: .granted, audioProbe: audio, foundSpeakers: 3,
                                         ptpHelper: FakePTPHelper(status: .enabled)))
        await vc.test_allow([.audio, .localNetwork])
        vc.test_tapSkip(.bluetooth)
        vc.test_tapSkip(.remoteControl)
        await vc.test_awaitFinalCheck()

        #expect(await vc.test_pressRow(.localNetwork))
        #expect(vc.test_browseStep == .localNetwork, "browsing a decided row keeps the CTA")

        audio.silent = .denied   // revoked while the browse sat open

        await vc.test_tapDone()

        #expect(vc.test_snapBackStep == .audio)
        #expect(vc.test_activeStep == .audio)
        #expect(vc.test_browseStep == nil, "the browse yielded to the step that came up short")
    }

    /// The automatic check itself catches a revocation: the row reverts to
    /// pending, the offending step re-opens through the same snap-back
    /// machinery, and nothing payoff-ish ever appears.
    @Test func aFailedAutoCheckRevertsTheRowAndSnapsBack() async {
        // The revocation lands AFTER the rows are granted, the same shape the
        // two sibling snap-back tests use. It used to be canned as denied from
        // the start, which worked only while `refreshStatuses()` left an
        // unengaged row unread — now that it always takes the silent read, a
        // permission denied from the very first look is caught before the
        // check ever runs, which is a different (and earlier) story than the
        // one this test is about.
        let audio = MutableSilentAudioProbe(silent: .granted)
        let vc = makeVC(model: makeModel(audio: .granted, audioProbe: audio, foundSpeakers: 3,
                                         ptpHelper: FakePTPHelper(status: .enabled)))
        await vc.test_allow([.audio, .localNetwork])
        vc.test_tapSkip(.bluetooth)
        vc.test_tapSkip(.remoteControl)

        audio.silent = .denied   // revoked before the automatic check runs

        await vc.test_awaitFinalCheck()

        #expect(vc.test_snapBackStep == .audio)
        #expect(vc.test_activeStep == .audio)
        #expect(vc.test_checkRowState == .pending, "the row reverts to pending")
        #expect(!vc.test_doneExists, "no CTA on a failed check")
        #expect(vc.test_demoMode != .settled, "no finale on a failed check")
    }

    /// The reactivation `refreshStatuses()` is still browsing the local
    /// network when the user clicks Done — the click must finish FIRST, and
    /// instantly: the verification trusts the proven grant, so it never even
    /// meets the running probe. (The probe coalescing stays load-bearing
    /// behind it: a colliding prime answers `.undecided`, which the model
    /// would record as a real "not granted" — the original first-click
    /// refusal, live 2026-08-11.)
    @Test func doneFinishesOnTheFirstClickWhileAReactivationProbeIsStillBrowsing() async {
        let net = CollidingLocalNetwork()
        var doneCount = 0
        let vc = makeVC(model: makeModel(audio: .granted, localNetwork: net,
                                         ptpHelper: FakePTPHelper(status: .enabled)),
                        onDone: { doneCount += 1 })
        await vc.test_allow([.audio, .localNetwork])
        vc.test_tapSkip(.bluetooth)
        vc.test_tapSkip(.remoteControl)
        await vc.test_awaitFinalCheck()   // the auto-check's own browse (#2) completes
        #expect(vc.test_doneExists)

        net.armParking()
        let reactivation = Task { await vc.test_refreshStatuses() }
        await net.waitUntilParked()

        // The click completes WHILE the reactivation browse is still parked:
        // the verification trusts the proven grant, so it neither joins the
        // running probe nor stacks one of its own.
        await vc.test_tapDone()

        #expect(doneCount == 1, "the FIRST click finishes")
        net.resume()
        await reactivation.value
        #expect(vc.test_snapBackStep == nil, "no fabricated unmet permission")
        #expect(net.test_primeCount == 3,
                "the walk's browse, the auto-check's, and the reactivation's — the click fired none")
    }

    /// Grants until told otherwise, then reports the mDNS refusal, then PARKS
    /// the next browse. A slow verification now takes a REVOKED Local Network
    /// — a proven grant is trusted and never browses — so this is how the
    /// single-flight window is held open for the test to click into.
    private final class RevokableParkingLocalNetwork: LocalNetworkPriming, @unchecked Sendable {
        enum Mode { case grant, deny, park }
        private let lock = NSLock()
        private var mode: Mode = .grant
        private var parkedResume: (() -> Void)?
        private var parkedWaiter: (() -> Void)?
        /// Same lost-wakeup guard as `SteppedLocalNetwork.pendingResume` —
        /// see the comment there.
        private var pendingResume = false
        private var primeCount = 0

        func probe() async -> Bool { true }
        func set(_ mode: Mode) { lock.withLock { self.mode = mode } }
        var test_primeCount: Int { lock.withLock { primeCount } }

        func prime(browseSeconds: TimeInterval,
                   onReachable: @escaping @Sendable () -> Void) async -> LocalNetworkOutcome {
            let mode = lock.withLock { primeCount += 1; return self.mode }
            switch mode {
            case .grant:
                onReachable()
                return .granted(foundSpeakers: 2)
            case .deny:
                return .denied
            case .park:
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    enum Next { case resumeNow, wait(( () -> Void)?) }
                    let next: Next = lock.withLock {
                        if pendingResume {
                            pendingResume = false
                            return .resumeNow
                        }
                        parkedResume = { continuation.resume() }
                        let waiter = parkedWaiter
                        parkedWaiter = nil
                        return .wait(waiter)
                    }
                    switch next {
                    case .resumeNow: continuation.resume()
                    case .wait(let waiter): waiter?()
                    }
                }
                return .denied
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
                if gate == nil { pendingResume = true }
                return gate
            }
            gate?()
        }
    }

    /// A second click while Done's verification is still running is a no-op —
    /// single-flight, like the Allow path. Without it the second verification
    /// would collide with the first's browse and race it past `onDone`. A slow
    /// verification takes a REVOKED Local Network now (a proven grant never
    /// browses), so that is the shape driven here. (Each click also leaves a
    /// named `setup_done` outcome in the decision log — the swallowed click's
    /// line is the guard this test pins; the line shapes themselves are pinned
    /// in `SetupTelemetryTests`, the serialized suite that may install the
    /// process-global sink.)
    @Test func aSecondClickDuringDoneVerificationIsANoOp() async {
        let net = RevokableParkingLocalNetwork()
        var doneCount = 0
        let vc = makeVC(model: makeModel(audio: .granted, localNetwork: net,
                                         ptpHelper: FakePTPHelper(status: .enabled)),
                        onDone: { doneCount += 1 })
        await vc.test_allow([.audio, .localNetwork])   // browse #1
        vc.test_tapSkip(.bluetooth)
        vc.test_tapSkip(.remoteControl)
        await vc.test_awaitFinalCheck()                 // browse #2, the visible re-proof

        net.set(.deny)
        await vc.test_refreshStatuses()                 // browse #3 — the revocation lands
        #expect(!vc.test_doneExists, "the gate closed on the revocation")

        net.set(.park)
        let first = Task { await vc.test_tapDone() }    // denied is not trusted: browse #4 parks
        await net.waitUntilParked()

        await vc.test_tapDone()       // the second click, mid-verification

        #expect(doneCount == 0, "the no-op returned while the first verification still runs")
        net.resume()
        await first.value

        #expect(doneCount == 0, "a revoked permission refuses to finish")
        #expect(vc.test_snapBackStep == .localNetwork)
        #expect(net.test_primeCount == 4, "the second click fired no browse of its own")
    }

    // MARK: Announcements + the ribbon's accessibility

    /// Everything this window does happens somewhere other than the keyboard
    /// focus — a grant lands from System Settings, a check passes on its own —
    /// so each transition is spoken, and a repaint that changed nothing says
    /// nothing. The load-time paint is silent even though Speaker Sync is
    /// already satisfied in this model: every already-granted step reads as
    /// "newly completed" against the freshly-seeded edge set on that first
    /// paint, but the user never witnessed a transition, so it must not speak.
    @Test func everyTransitionIsAnnouncedExactlyOnce() async {
        let vc = makeVC(model: makeGrantableModel())
        // Through the ASYNC landing, not just the sync first paint: the silent
        // read is what decides the window's opening state.
        await vc.test_awaitInitialStatuses()

        #expect(vc.test_announcements.isEmpty, "the load-time paint says nothing")

        await vc.test_allow([.audio, .localNetwork])

        #expect(transitionAnnouncements(vc)
                == ["Hearing your Mac's sound", "3 speakers on your network"])

        vc.test_refresh()   // a repaint that changes nothing

        #expect(transitionAnnouncements(vc).count == 2, "a repaint says nothing new")

        vc.test_tapSkip(.bluetooth)
        vc.test_tapSkip(.remoteControl)
        await vc.test_awaitFinalCheck()

        #expect(transitionAnnouncements(vc) == ["Hearing your Mac's sound",
                                                "3 speakers on your network",
                                                "Skipped. Bluetooth speakers",
                                                "Skipped. Volume-key control",
                                                "Everything's ready"])
    }

    /// A permission already in place when the window opens is the opening
    /// STATE, not a transition the user witnessed — so the async status read
    /// landing it must neither speak nor pull the window to the front. Both
    /// arm only once that read has settled.
    @Test func thePreGrantedStatusLandingIsSilentAndDoesNotReFront() async {
        let vc = makeVC(model: makeModel(audio: .granted, bluetooth: .granted))

        await vc.test_awaitInitialStatuses()

        #expect(vc.test_hasCheckmark(.bluetooth), "the row still lands on the real status")
        #expect(vc.test_announcements.isEmpty, "nobody granted anything just now")
        #expect(vc.test_returnToFrontCount == 0, "and nothing came back from System Settings")

        await vc.test_tapAllow(.audio)   // a grant the user really did make

        #expect(transitionAnnouncements(vc) == ["Hearing your Mac's sound"])
    }

    /// The ribbon is REAL UI sitting inside the hero pane beside a demo that is
    /// deliberately invisible to VoiceOver — its controls must never be swept up
    /// in that opt-out.
    @Test func theRibbonStaysReachableBesideTheDecorativeMock() {
        let vc = makeVC(model: makeModel(audio: .unknown))
        #expect(vc.test_ribbonIsAccessible)
        #expect(vc.test_demoAccessibilityElements.isEmpty,
                "still reachable: \(vc.test_demoAccessibilityElements)")
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
        await vc.test_awaitFinalCheck()

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
        await vc.test_awaitFinalCheck()

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

    /// The finale's first play launches from the ICON CENTRE, not the
    /// bottom-left origin. `playCelebration()` runs ON the step crossfade,
    /// before the enclosing pass has positioned the view — the exact ordering
    /// the first-play bloom used to bloom from the corner. Spending the shot is
    /// immediate; its launch waits for the first real layout with a centre.
    @Test func theFinaleLaunchesFromTheIconCentreOnTheFirstPlay() {
        let host = NSView()
        let settled = DemoSettledMockView()
        settled.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(settled)
        NSLayoutConstraint.activate([
            settled.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            settled.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            settled.topAnchor.constraint(equalTo: host.topAnchor),
            settled.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])

        settled.playCelebration()   // before any layout — the real crossfade order
        #expect(settled.celebrationConsumed, "the shot is spent immediately")
        #expect(settled.celebrationRunCount == 0,
                "but it does NOT launch off a centre layout hasn't resolved")

        // Drive layout the way the window does: resolve the tree (the icon gets
        // its real frame), then the pass that lays out this view with that frame
        // fires the deferred launch. (A live window resolves frames before it
        // calls `layout()`; a detached tree needs the resolve made explicit.)
        host.setFrameSize(DemoSettledMockView.size)
        host.layoutSubtreeIfNeeded()
        #expect(settled.test_iconCentre != .zero, "the icon has a real frame now")
        settled.needsLayout = true
        settled.layoutSubtreeIfNeeded()

        #expect(settled.celebrationRunCount == 1, "the deferred launch fires once, now")
        #expect(settled.test_auraPosition == settled.test_iconCentre,
                "the bloom is anchored on the icon centre")
        #expect(settled.test_auraPosition != .zero, "never the bottom-left origin")
    }

    /// The AURA never paints at the bottom-left origin. Its resting opacity is 1
    /// (the rings' model 0 keeps THEM safe on their own), so before layout
    /// resolves the icon centre it is held fully transparent, then revealed only
    /// once it sits on that centre — the specific corner-bloom regression the
    /// finale recording caught. (The transient paint itself is invisible to a
    /// headless frame; the model opacity gate is what a test can pin.)
    @Test func theFinaleAuraStaysHiddenUntilItSitsOnTheIconCentre() {
        let host = NSView()
        let settled = DemoSettledMockView()
        settled.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(settled)
        NSLayoutConstraint.activate([
            settled.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            settled.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            settled.topAnchor.constraint(equalTo: host.topAnchor),
            settled.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])

        #expect(settled.test_auraOpacity == 0, "born hidden — no corner bloom possible")
        settled.playCelebration()   // before layout — the real crossfade order
        #expect(settled.test_auraOpacity == 0,
                "still hidden: the centre isn't resolved, so it must not paint")

        host.setFrameSize(DemoSettledMockView.size)
        host.layoutSubtreeIfNeeded()
        settled.needsLayout = true
        settled.layoutSubtreeIfNeeded()

        #expect(settled.test_auraPosition == settled.test_iconCentre,
                "revealed ON the icon centre")
        #expect(settled.test_auraPosition != .zero, "never the bottom-left origin")
        #expect(settled.test_auraOpacity == 1, "and only once it has that centre")
    }

    /// The finale rings sweep the WHOLE window now — far past the hero panel that
    /// gained almost nothing over the stage — yet every ring is fully faded
    /// (opacity 0) by the window's NEAREST edge, so no side ever shows a ring
    /// hitting a wall.
    @Test func theFinaleRingsFadeOutBeforeTheNearestWindowEdge() {
        // A host standing in for the whole 820×560 Setup window, with the stage
        // where the hero really puts it: 354 pt in from the leading edge (26
        // margin + 288 spine + 18 gap + 22 hero padding), so the icon centre
        // sits well right-of-centre and the left edge (across the spine) is the
        // farthest — nearest ≠ farthest, and the old panel cap would fall short.
        let window = NSView(frame: NSRect(x: 0, y: 0, width: 820, height: 560))
        let settled = DemoSettledMockView()
        settled.rippleBoundsView = window
        settled.translatesAutoresizingMaskIntoConstraints = false
        window.addSubview(settled)
        NSLayoutConstraint.activate([
            settled.leadingAnchor.constraint(equalTo: window.leadingAnchor, constant: 354),
            settled.centerYAnchor.constraint(equalTo: window.centerYAnchor),
        ])
        window.layoutSubtreeIfNeeded()
        settled.playCelebration()
        window.layoutSubtreeIfNeeded()   // fire the deferred launch

        guard let nearest = settled.test_nearestEdgeRadius,
              let farthest = settled.test_farthestEdgeRadius,
              let endRadius = settled.test_rippleEndRadius else {
            Issue.record("the ripple did not launch against the window geometry")
            return
        }

        // The icon sits right-of-centre, so the leading edge is > half the 820
        // window away — the reach now spans the window, not the ~231 pt half of
        // the hero panel it barely cleared before.
        #expect(farthest > 410, "the ripple reaches across the window's midline")
        #expect(endRadius > 209, "and far past the 418×278 stage")
        #expect(endRadius >= farthest - 0.5, "out to the window's farthest edge")

        let fadeRadii = settled.test_rippleFadeOutRadii
        #expect(fadeRadii.count == 3, "every staggered ring carries a ripple")
        for radius in fadeRadii {
            #expect(radius <= nearest + 0.5,
                    "opacity is 0 by the nearest window edge (\(radius) vs \(nearest))")
        }
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
        await vc.test_awaitFinalCheck()

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
        await vc.test_awaitFinalCheck()

        #expect(vc.test_demoMode == .settled)
        // The shot is spent immediately, but launches from the first real
        // layout — so drive one, exactly as the live window does.
        layoutRoot(vc)
        #expect(vc.test_demoCelebrationRunCount == 1)
        #expect(!vc.test_demoShowsReplay, "the finale is a one-shot, never a Replay offer")

        vc.test_refresh()   // a repaint that changes nothing
        layoutRoot(vc)

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
        await vc.test_awaitFinalCheck()

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
        await vc.test_awaitFinalCheck()

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
        await vc.test_awaitFinalCheck()
        #expect(vc.test_demoCelebrationRunCount == 0)

        vc.test_demoReduceMotionOverride = false
        vc.test_demoCanAnimateOverride = true   // the window lands on screen
        layoutRoot(vc)                          // the layout the launch waits for

        #expect(vc.test_demoCelebrationRunCount == 1)
    }

    /// The finale is decoration like every other mock: its headline and line
    /// must be swallowed by the accessibility opt-out — the spine and the
    /// ribbon carry the words.
    @Test func theFinaleStaysInvisibleToVoiceOver() async {
        let vc = makeVC(model: makeCompleteableModel())
        await vc.test_refreshStatuses()

        await vc.test_allow([.audio, .localNetwork])
        await vc.test_awaitFinalCheck()

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
        #expect(vc.test_demoStage == nil, "every step but Remote Control starts at the pane itself")
    }

    /// Speaker Sync's approval only exists in Login Items — there is no privacy
    /// dialog to mirror, so it is always the Settings mock, and SINGLE-stage:
    /// "Open Login Items…" opens System Settings directly, with no alert in
    /// between.
    @Test func speakerSyncAlwaysShowsTheSettingsMock() async {
        let vc = makeVC(model: makeModel(audio: .granted, foundSpeakers: 2))
        await vc.test_allow([.audio, .localNetwork])
        vc.test_tapSkip(.bluetooth)
        #expect(vc.test_activeStep == .speakerSync)
        #expect(vc.test_demoMode == .settings)
        #expect(vc.test_demoStage == nil, "no alert exists for Login Items — one stage, the pane")
    }

    @Test func demoSettlesWhenEveryStepIsDone() async {
        let vc = makeVC(model: makeModel(audio: .granted, foundSpeakers: 2,
                                         bluetooth: .granted, remoteControlTrusted: true,
                                         ptpHelper: FakePTPHelper(status: .enabled)))
        await vc.test_refreshStatuses()
        await vc.test_allow([.audio, .localNetwork])
        #expect(vc.test_activeStep == nil)
        await vc.test_awaitFinalCheck()
        #expect(vc.test_demoMode == .settled)
    }

    /// Zero idle CPU: the loop only ever runs on a window that is really on
    /// screen, so a headless/off-window pane is settled and silent.
    @Test func demoNeverAnimatesOffWindow() {
        let vc = makeVC(model: makeModel(audio: .unknown))
        #expect(!vc.test_isDemoAnimating)
        #expect(!vc.test_demoShowsReplay, "Replay is for a Reduce Motion user watching a live window")
    }

    /// The demo is decoration: every word of the information is in the ribbon
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

    /// The click splash is an EVENT at the pointer's tip: every press site arms
    /// it for the pass, and none of it survives into the settled frame — which
    /// is the frame the headless snapshot fixtures capture, so a ring at rest
    /// would stamp a decoration onto every fixture.
    @Test func theClickSplashFiresOnEveryPressAndNeverRests() {
        let mocks: [DemoMockView] = [
            DemoPromptMockView(step: .audio),
            DemoSettingsMockView(step: .localNetwork),
            DemoSettingsHandoffMockView(step: .remoteControl),
        ]
        for mock in mocks {
            mock.layoutSubtreeIfNeeded()
            #expect(mock.test_clickSplashesAreSettled,
                    "\(type(of: mock)) carries a splash before any pass has run")

            mock.startTimeline(loop: false)
            #expect(mock.test_clickSplashesAreArmed,
                    "\(type(of: mock)) did not wire the splash into its pass")

            mock.stopTimeline()
            #expect(mock.test_clickSplashesAreSettled,
                    "\(type(of: mock)) left a splash visible at rest")
        }
    }

    // MARK: The two-stage Remote Control demo

    /// Remote Control's FIRST ask raises the Accessibility alert, whose own
    /// button is what opens the pane — two clicks on two surfaces, and a demo
    /// that opened straight onto the pane showed the toggle without showing how
    /// the pane carrying it is reached. The pass starts and ends on the alert,
    /// the click still to make.
    @Test func remoteControlsFirstAskDemoIsTwoStageAndRestsOnTheAlert() async {
        let vc = makeVC(model: makeGrantableModel())
        await vc.test_allow([.audio, .localNetwork])
        vc.test_tapSkip(.bluetooth)
        #expect(vc.test_activeStep == .remoteControl)

        #expect(vc.test_demoMode == .prompt)
        #expect(vc.test_demoStage == .alert)
        // The opt-out has to reach a mock nested one stage deeper than before.
        #expect(vc.test_demoAccessibilityElements.isEmpty,
                "still reachable: \(vc.test_demoAccessibilityElements)")
    }

    /// Once the prompt is spent the retry deep-links straight to the pane, so
    /// there is no alert left to rehearse — one surface, like everyone else's.
    @Test func remoteControlsRetryDemoIsThePlainSettingsPane() async {
        let vc = makeVC(model: makeGrantableModel())
        await vc.test_allow([.audio, .localNetwork])
        vc.test_tapSkip(.bluetooth)

        await vc.test_tapAllow(.remoteControl)   // the prompt is spent: `.requested`

        #expect(vc.test_demoMode == .settings)
        #expect(vc.test_demoStage == nil)
        #expect(vc.test_ribbonBodyText?.contains("macOS won't tell us when you do") ?? false,
                "macOS won't tell us when the switch flips — the ribbon says so")
    }

    /// Every other step's ask really is one surface, so only Remote Control pays
    /// for the second one.
    @Test func everyOtherRetryDemoIsASingleSurface() async {
        let vc = makeVC(model: makeModel(audio: .denied))
        await vc.test_tapAllow(.audio)
        #expect(vc.test_demoMode == .settings)
        #expect(vc.test_demoStage == nil)
    }

    /// Remote Control's two-stage pass ends where it started — resting on the
    /// alert, the first of the two clicks the user still has to make.
    @Test func theRemoteControlFirstAskDemoRestsOnTheAlert() {
        let mock = DemoSettingsHandoffMockView(step: .remoteControl)
        mock.layoutSubtreeIfNeeded()
        #expect(mock.test_stage == .alert)

        mock.startTimeline(loop: false)
        mock.stopTimeline()

        #expect(mock.test_stage == .alert, "a pass must end where it started")
    }

    /// A mock's prose is abstracted to gist bars, but its BUTTON LABELS are
    /// real: the words are what the user has to recognise when the real surface
    /// arrives, and a greeked "Don't Allow" would teach them nothing.
    @Test func theMocksKeepTheirRealButtonLabels() {
        #expect(DemoPromptMockView.confirmTitle(for: .audio) == "Allow")

        let alert = DemoSystemAlertMockView(step: .remoteControl)
        alert.layoutSubtreeIfNeeded()
        #expect(alert.test_demoButtonTitles == ["Open System Settings", "Deny"])
    }

    /// The rehearsal has to say WHICH button to press — the copy that used to
    /// warn about the alert's accent-filled refusal is gone, so the marking
    /// carries it. Exactly one button per surface is marked, and it is the one
    /// the pointer presses.
    @Test func exactlyTheCorrectButtonIsMarkedOnEverySurface() {
        let prompt = DemoPromptMockView(step: .audio)
        prompt.layoutSubtreeIfNeeded()
        #expect(prompt.test_demoMarkedButtonTitle == "Allow")

        let alert = DemoSystemAlertMockView(step: .remoteControl)
        alert.layoutSubtreeIfNeeded()
        #expect(alert.test_demoMarkedButtonTitle == "Open System Settings",
                "the real panel emphasises Deny — the mock must not")
    }

    /// Every mock has to FIT the stage. The preview frame clips, so a mock
    /// taller than `surfaceSize` is not "a bit tight" — it loses its bottom
    /// edge, which is where the buttons the rehearsal exists to point at live.
    /// The near-life-size privacy card was over by ~50 pt before the copy came
    /// out of it.
    @Test func everyMockFitsTheStage() {
        let stage = DemoPaneView.surfaceSize
        let mocks: [NSView] = [
            DemoPromptMockView(step: .audio),
            DemoSettingsMockView(step: .localNetwork, metricScale: 1.35),
            DemoSettingsHandoffMockView(step: .remoteControl),
            DemoSystemAlertMockView(step: .remoteControl),
        ]
        for mock in mocks {
            mock.layoutSubtreeIfNeeded()
            let size = mock.fittingSize
            #expect(size.width <= stage.width && size.height <= stage.height,
                    "\(type(of: mock)) is \(size), stage is \(stage)")
        }
    }

    /// Increase Contrast picks the widened value, and a token that declares no
    /// widened value falls back rather than going blank. Driven through the
    /// pure resolver because the real setting is a workspace flag with no
    /// override seam — faking it through a mutable static would leak into this
    /// suite's other tests, which run in parallel.
    @Test func increaseContrastSelectsTheWidenedValuePerAppearance() {
        // Both axes, all four corners.
        #expect(DemoSystemColor.resolvedHex(light: 0x111111, dark: 0x222222,
                                            lightHighContrast: 0x333333, darkHighContrast: 0x444444,
                                            isDark: false, increaseContrast: false) == 0x111111)
        #expect(DemoSystemColor.resolvedHex(light: 0x111111, dark: 0x222222,
                                            lightHighContrast: 0x333333, darkHighContrast: 0x444444,
                                            isDark: true, increaseContrast: false) == 0x222222)
        #expect(DemoSystemColor.resolvedHex(light: 0x111111, dark: 0x222222,
                                            lightHighContrast: 0x333333, darkHighContrast: 0x444444,
                                            isDark: false, increaseContrast: true) == 0x333333)
        #expect(DemoSystemColor.resolvedHex(light: 0x111111, dark: 0x222222,
                                            lightHighContrast: 0x333333, darkHighContrast: 0x444444,
                                            isDark: true, increaseContrast: true) == 0x444444)

        // A token with no widened variant keeps its normal value under
        // Increase Contrast — the fallback every unchanged case relies on.
        #expect(DemoSystemColor.resolvedHex(light: 0x111111, dark: 0x222222,
                                            lightHighContrast: nil, darkHighContrast: nil,
                                            isDark: false, increaseContrast: true) == 0x111111)
        #expect(DemoSystemColor.resolvedHex(light: 0x111111, dark: 0x222222,
                                            lightHighContrast: nil, darkHighContrast: nil,
                                            isDark: true, increaseContrast: true) == 0x222222)
    }

    /// The mocks are stylised, but a SYSTEM DIALOG is mimicked truthfully: its
    /// icon symbol, its colours, its shape and its button words are what macOS
    /// really shows, and only the COPY is abstracted to grey bars (owner,
    /// 2026-08-13, reversing the 2026-08-12 pass that drained these to slate —
    /// a dusty-rose record mark and a grey-blue Bluetooth tile stopped reading
    /// as the thing they are mimicking).
    ///
    /// The Settings-window chrome is deliberately NOT included in that reversal:
    /// the owner named that surface as the one that got the balance right, so
    /// its switch and selected row keep the muted slate.
    @Test func systemDialogColoursAreTrueAndSettingsChromeStaysMuted() {
        for appearance in [NSAppearance(named: .aqua)!, NSAppearance(named: .darkAqua)!] {
            appearance.performAsCurrentDrawingAppearance {
                // The privacy dialog mimics macOS: real blue badge and tiles,
                // real red record mark. Asserted as full saturation rather than
                // as an exact hex so the system colours stay free to shift with
                // the OS — what is pinned is "true to life", not a value.
                let blue = DemoSystemColor.systemBlue.usingColorSpace(.sRGB)!
                #expect(blue.saturationComponent > 0.5,
                        "the privacy badge/tile went muted again: \(blue.saturationComponent)")
                let record = DemoSystemColor.recordTile.usingColorSpace(.sRGB)!
                #expect(record.saturationComponent > 0.5,
                        "the record tile went muted again: \(record.saturationComponent)")

                // The Settings mock's own chrome stays where it was.
                let settings = DemoSystemColor.settingsAccent.usingColorSpace(.sRGB)!
                #expect(settings.saturationComponent < 0.35,
                        "the settings switch drifted saturated: \(settings.saturationComponent)")
                #expect(settings.saturationComponent < blue.saturationComponent,
                        "the settings chrome must stay quieter than a real system colour")

                // Unchanged by the reversal: gold is spent on the CTA alone, so
                // the padlock stays a warm grey rather than the real icon's gold.
                let lock = DemoSystemColor.lockTop.usingColorSpace(.sRGB)!
                #expect(lock.saturationComponent < 0.15,
                        "the padlock is still gold: \(lock.saturationComponent)")
            }
        }
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

    /// Collapsible elements clip on the SAME constant every other one in the app
    /// uses — a second hand-synced copy is exactly what drifted before.
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

    /// A `.permissionLost` re-entry re-titles the whole window and marks the row
    /// that went off as BROKEN — the one row on the spine asking to be looked at.
    @Test func aPermissionLostReEntryRetitlesTheWindowAndBreaksItsRow() {
        let vc = makeVC(model: makeModel(audio: .denied), reason: .permissionLost([.audioCapture]))

        #expect(vc.test_titleText == "Let's get your sound back")
        #expect(vc.test_rowIsBroken(.audio))
        #expect(!vc.test_rowIsBroken(.localNetwork))
        #expect(vc.test_ribbonStatusText == "This was on. macOS says it's off now.")
        #expect(vc.test_ribbonButtonTitles == ["Open settings…"])
        #expect(vc.test_ribbonStatusTextColor == Tokens.Color.label2,
                "the failure hue is graphical-object-only (house rule 8) — the words beside the red glyph stay ordinary body ink")
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
        // "Speaker Sync", not "PTP helper" — the row was named out of jargon.
        #expect(text.contains("Speaker Sync"), "\(text)")
    }

    /// One whole sentence per arity, not one sentence with a pronoun spliced in:
    /// "Flip it back on" beside two named permissions was a broken sentence, on
    /// the one screen whose whole job is explaining what went wrong. And nothing
    /// says "access" any more — Speaker Sync's switch is a Login Item, not a
    /// grant. The list itself is `ListFormatter`'s, not a hand-rolled join.
    @Test func theLostPermissionMessageAgreesWithHowManyItNamed() {
        let one = OnboardingViewController.permissionLostText(for: [.audioCapture])
        #expect(one == "System Audio was turned off after setup. Turn it back on and your "
                + "speakers pick up where they left off.", "\(one)")

        let two = OnboardingViewController.permissionLostText(for: [.audioCapture, .ptpHelper])
        #expect(two == "System Audio and Speaker Sync were turned off after setup. Turn them "
                + "back on and your speakers pick up where they left off.", "\(two)")

        // Three names: the exact separators are `ListFormatter`'s business (the
        // Oxford comma is not the same in every English), so this pins the
        // sentence around them rather than the punctuation inside them.
        let three = OnboardingViewController
            .permissionLostText(for: [.audioCapture, .localNetwork, .ptpHelper])
        #expect(three.hasPrefix("System Audio, Local Network"), "\(three)")
        #expect(three.contains("Speaker Sync were turned off after setup."), "\(three)")
        #expect(!three.contains("access"), "\(three)")
    }

    @Test func permissionLostMessageClearsOnceItsFlaggedPermissionIsGranted() async {
        let vc = makeVC(model: makeGrantableModel(), reason: .permissionLost([.audioCapture]))
        #expect(vc.test_permissionLostBannerIsVisible,
                "shown while the flagged permission is still ungranted")

        await vc.test_tapAllow(.audio)

        #expect(!vc.test_permissionLostBannerIsVisible,
                "the message must clear once the permission it warned about is granted")
        #expect(vc.test_showsPermissionLostBanner, "it cleared, it was never not-warranted")
        #expect(!vc.test_rowIsBroken(.audio), "and the row stops asking to be looked at")
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

    /// Without the load-time silent re-read the Bluetooth row paints
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

    /// The Setup window is the click-witnessing kind: every physical click
    /// leaves a `setup_click` telemetry line, and a click on an inactive app
    /// activates it before dispatch (the "first CTA click left no trace" live
    /// symptom — the line shapes are pinned in `SetupTelemetryTests`).
    @Test func theSetupWindowIsTheClickReportingKind() {
        let wc = OnboardingWindowController(model: makeModel(audio: .granted),
                                            openSettings: { _ in },
                                            onFinished: {})
        #expect(wc.window is OnboardingWindow)
    }

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

    // MARK: The setup-v3 hero — gold spent once, ember on the spine

    /// The live row draws NO leading bar. It is already the row carrying the
    /// selection fill inside the grouped list, and a coloured rule beside it
    /// both repeated that and drew a shape macOS's own grouped lists don't
    /// have. Gold stays the accent of exactly ONE thing on screen — the button
    /// this step wants pressed — which is now true of the whole window rather
    /// than true only after the spine settled for ember.
    @Test func theLiveRowDrawsNoEdgeBarAndOnlyTheButtonIsGold() async {
        let vc = makeVC(model: makeGrantableModel())

        #expect(vc.test_rowEdgeBarFill(.audio) == nil, "the live row is marked by its fill, not a bar")
        #expect(vc.test_rowEdgeBarFill(.localNetwork) == nil, "a locked row draws no bar")

        await vc.test_tapAllow(.audio)

        // Advancing the flow must not introduce one either.
        #expect(vc.test_rowEdgeBarFill(.audio) == nil)
        #expect(vc.test_rowEdgeBarFill(.localNetwork) == nil,
                "the newly-live row is marked the same way the last one was")
    }

    /// A broken permission still outranks it — that row is the one asking to be
    /// looked at, and it says so in the failure hue.
    @Test func aBrokenRowsEdgeBarStaysTheFailureHue() {
        let vc = makeVC(model: makeModel(audio: .denied), reason: .permissionLost([.audioCapture]))
        #expect(resolvedSRGB(vc.test_rowEdgeBarFill(.audio))
                == resolvedSRGB(Tokens.Color.failure))
    }

    /// The frame's caption is the layout's answer to "whose window is this?".
    /// It comes off for the ONE surface that isn't macOS's — our own finale.
    @Test func thePreviewFrameIsCaptionedExceptOnTheFinale() async {
        let vc = makeVC(model: makeGrantableModel())
        #expect(vc.test_previewFrameLabel == "You'll see this from macOS")

        await vc.test_allow([.audio, .localNetwork])
        vc.test_tapSkip(.bluetooth)
        await vc.test_tapAllow(.speakerSync)
        vc.test_tapSkip(.remoteControl)
        await vc.test_awaitFinalCheck()

        #expect(vc.test_doneExists, "the gate opened")
        #expect(vc.test_previewFrameLabel == nil,
                "the finale card is ours — captioning it as macOS's would be a lie")
    }

    /// And the frame's CHROME goes with the caption: a permission step is a
    /// picture inside a boundary, the finale is our own moment on the panel —
    /// no well, no rim, and nothing to clip the ripple.
    @Test func thePreviewFrameDropsItsChromeOnTheFinale() async {
        let vc = makeVC(model: makeGrantableModel())
        #expect(vc.test_previewFrameDrawsChrome, "a permission step keeps the framed look")

        await vc.test_allow([.audio, .localNetwork])
        vc.test_tapSkip(.bluetooth)
        await vc.test_tapAllow(.speakerSync)
        vc.test_tapSkip(.remoteControl)
        await vc.test_awaitFinalCheck()

        #expect(vc.test_doneExists, "the gate opened")
        #expect(!vc.test_previewFrameDrawsChrome,
                "the finale sits on the hero panel, unframed and unclipped")
    }

    /// Resolve a dynamic token to comparable components: two accesses of a
    /// provider-backed colour are distinct instances whose `isEqual` is not
    /// documented to see through the provider.
    private func resolvedSRGB(_ color: NSColor?) -> NSColor? {
        guard let color else { return nil }
        var resolved: NSColor?
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB)
        }
        return resolved
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

    /// The alert triangle always carries `failure`, and any other status glyph
    /// takes the line's own ink.
    ///
    /// `SetupRibbonView` holds its own copy of the symbol name so the view can
    /// stay ignorant of who filled its content tuple in. Nothing in the
    /// compiler binds that copy to `OnboardingViewController.alertSymbol`, so
    /// this test is the binding: it feeds the CONTROLLER's constant to the VIEW
    /// and fails if either literal is edited on its own.
    @Test func onlyTheAlertTriangleTakesTheFailureTint() {
        let ribbon = SetupRibbonView()

        var alert = RibbonContent()
        alert.status = (OnboardingViewController.alertSymbol, "macOS says it's off now.",
                        Tokens.Color.label2, false)
        ribbon.apply(alert)
        #expect(resolvedSRGB(ribbon.test_statusGlyphTint) == resolvedSRGB(Tokens.Color.failure),
                "the alert triangle is red whatever colour the line's words take")

        var skipped = RibbonContent()
        skipped.status = ("slash.circle", "You skipped this earlier.",
                          Tokens.Color.label2, false)
        ribbon.apply(skipped)
        #expect(resolvedSRGB(ribbon.test_statusGlyphTint) == resolvedSRGB(Tokens.Color.label2),
                "any other glyph takes the line's own ink")
    }
}
