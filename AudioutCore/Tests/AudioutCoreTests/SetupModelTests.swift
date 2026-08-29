// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudioutCore

/// `SetupModel` is the AppKit-free brain of the first-run flow. All three system
/// seams (audio-capture probe, local-network primer, remote-control primer) are
/// injected, so these run hermetically — no Core Audio, no real prompt. They pin
/// the status transitions, the `onChange` notifications, persistence of
/// completion, the launch gate, and the System Settings deep-link URLs.
///
/// Nested inside `SerializedSharedState` (cookbook §18): several tests here
/// install `Telemetry`'s process-global test sink, which would otherwise race
/// every other suite doing the same under swift-testing's concurrent-in-one-
/// process model.
extension SerializedSharedState {
    @MainActor
    @Suite final class SetupModelTests {

    // MARK: Fakes

    /// Returns a canned status without touching Core Audio.
    private struct CannedAudioProbe: AudioCapturePermissionProbing {
        let result: PermissionStatus
        func probe() async -> PermissionStatus { result }
    }

    /// Records local-network probes and returns a canned reachability result.
    private final class SpyLocalNetwork: LocalNetworkPriming, @unchecked Sendable {
        private let lock = NSLock()
        private var _probeCount = 0
        /// What `probe()` reports (default: not reachable ⇒ `.requested`).
        var reachable = false
        var probeCount: Int { lock.withLock { _probeCount } }
        func probe() async -> Bool { lock.withLock { _probeCount += 1 }; return reachable }

        /// The browse window each probe was handed, in order.
        private var _windows: [TimeInterval] = []
        var windows: [TimeInterval] { lock.withLock { _windows } }
        func probeFoundSpeakers(browseSeconds: TimeInterval) async -> Int {
            lock.withLock { _windows.append(browseSeconds) }
            return await probe() ? 1 : 0
        }

        /// Whether each prime was allowed to publish the self-discovery service,
        /// in order — the flag that keeps the firewall dialog out of every
        /// background rescan.
        private var _selfDiscoveryFlags: [Bool] = []
        var selfDiscoveryFlags: [Bool] { lock.withLock { _selfDiscoveryFlags } }
        func prime(browseSeconds: TimeInterval,
                   selfDiscovery: Bool,
                   onReachable: @escaping @Sendable () -> Void) async -> LocalNetworkOutcome {
            lock.withLock { _selfDiscoveryFlags.append(selfDiscovery) }
            return await prime(browseSeconds: browseSeconds, onReachable: onReachable)
        }
    }

    /// A prime whose answer the test changes between calls — the live shape of
    /// "granted once, then a rescan that sees nothing."
    private final class SwitchableLocalNetwork: LocalNetworkPriming, @unchecked Sendable {
        private let lock = NSLock()
        private var _outcome: LocalNetworkOutcome
        init(_ outcome: LocalNetworkOutcome) { _outcome = outcome }
        var outcome: LocalNetworkOutcome {
            get { lock.withLock { _outcome } }
            set { lock.withLock { _outcome = newValue } }
        }
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

    /// Reports a fixed speaker COUNT (the seam behind "3 speakers on your network"), with
    /// the Bool answer derived from it exactly as the real primer derives it.
    private struct CountingLocalNetwork: LocalNetworkPriming {
        let found: Int
        func probe() async -> Bool { found > 0 }
        func probeFoundSpeakers() async -> Int { found }
    }

    /// Reports a fixed ``LocalNetworkOutcome`` — the seam's full three-valued
    /// answer, including the refusal only a real primer can observe (the mDNS
    /// policy error) and the grant-with-no-speakers self-discovery proves.
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

    /// A prime the test drives step by step, so the two waits the card names are
    /// both observable: it parks first with the dialog notionally still up, then
    /// (once released) reports the network reachable and parks again while the
    /// speaker count fills in, then answers.
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

        /// Suspends until the prime is parked at its next step.
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

        /// Let it run on to the next step.
        func resume() {
            let gate: (() -> Void)? = lock.withLock {
                let gate = resumeGate
                resumeGate = nil
                return gate
            }
            gate?()
        }
    }

    /// Records Accessibility prompts and returns a canned trust state.
    private final class SpyRemoteControl: RemoteControlPriming, @unchecked Sendable {
        private let lock = NSLock()
        private var _primeCount = 0
        /// What `isTrusted()` reports (default: not trusted).
        var trusted = false
        var primeCount: Int { lock.withLock { _primeCount } }
        func prime() { lock.withLock { _primeCount += 1 } }
        func isTrusted() -> Bool { trusted }
    }

    /// Plays the Bluetooth pair: a scriptable authorization status plus a prompt
    /// that records itself and hands the decision callback back to the test, so
    /// nothing here constructs a `CBCentralManager`.
    private final class BluetoothScript: BluetoothPermissionReading, BluetoothPermissionPriming, @unchecked Sendable {
        private let lock = NSLock()
        private var _status: PermissionStatus = .unknown
        private var _primeCount = 0
        private var _onDecided: (@Sendable () -> Void)?
        var status: PermissionStatus {
            get { lock.withLock { _status } }
            set { lock.withLock { _status = newValue } }
        }
        var primeCount: Int { lock.withLock { _primeCount } }
        func currentStatus() -> PermissionStatus { status }
        func prime(onDecided: @escaping @Sendable () -> Void) {
            lock.withLock { _primeCount += 1; _onDecided = onDecided }
        }
        /// The user answered the prompt.
        func decide(_ answer: PermissionStatus) {
            status = answer
            lock.withLock { _onDecided }?()
        }
    }

    /// Records `register()`/`openSystemSettingsLoginItems()` calls and returns a
    /// canned ``PTPHelperStatus`` — never touches the real `SMAppService`.
    private final class FakePTPHelper: PTPHelperManaging, @unchecked Sendable {
        private let lock = NSLock()
        private var _registerCount = 0
        private var _openSettingsCount = 0
        private var _unregisterCount = 0
        /// What `.status` reports after `register()` (default: requires approval,
        /// the expected first-run outcome once registration succeeds).
        var statusAfterRegister: PTPHelperStatus = .requiresApproval
        /// What `register()` throws, if anything (default: succeeds).
        var registerError: Error?
        /// What `.status` reports BEFORE `register()` has been called.
        var status: PTPHelperStatus = .notRegistered
        var registerCount: Int { lock.withLock { _registerCount } }
        var openSettingsCount: Int { lock.withLock { _openSettingsCount } }
        var unregisterCount: Int { lock.withLock { _unregisterCount } }

        func register() throws {
            lock.withLock { _registerCount += 1 }
            if let registerError { throw registerError }
            status = statusAfterRegister
        }
        func openSystemSettingsLoginItems() { lock.withLock { _openSettingsCount += 1 } }
        func unregister() async throws { lock.withLock { _unregisterCount += 1 } }
    }

    /// Counts `onChange` fires (reference type so the escaping closure mutates it).
    private final class ChangeCounter { var count = 0 }

    // MARK: Helpers

    private let isolation = TestIsolation(owner: "SetupModelTests")
    private var defaults: UserDefaults { isolation.isolatedDefaults }

    private func makeModel(audio: PermissionStatus,
                           localNetwork: SpyLocalNetwork = SpyLocalNetwork(),
                           remoteControl: SpyRemoteControl = SpyRemoteControl(),
                           ptpHelper: FakePTPHelper = FakePTPHelper())
        -> (SetupModel, SpyLocalNetwork, SpyRemoteControl, ChangeCounter) {
        let counter = ChangeCounter()
        let model = SetupModel(audioProbe: CannedAudioProbe(result: audio),
                               localNetwork: localNetwork,
                               remoteControl: remoteControl,
                               ptpHelper: ptpHelper,
                               settings: AppSettings(defaults: defaults))
        model.onChange = { counter.count += 1 }
        return (model, localNetwork, remoteControl, counter)
    }

    // MARK: Initial state

    @Test func initialStatusesAreUnknown() {
        let (model, _, _, _) = makeModel(audio: .granted)
        #expect(model.audioStatus == .unknown)
        #expect(model.localNetworkStatus == .unknown)
        #expect(model.remoteControlStatus == .unknown)
        expectModelIsNotProbing(model)
    }

    private func expectModelIsNotProbing(_ model: SetupModel) {
        #expect(!model.isProbingAudio)
    }

    // MARK: Local Network — ungated OS (macOS < 15, no privacy gate exists)

    /// On macOS < 15 there is no Local Network privacy permission, so the model is
    /// constructed with `localNetworkGated: false`: it must start `.granted`, never
    /// run a Bonjour browse, and never surface as a missing required permission
    /// (which is what produced the dead-end "Open Settings…" → nonexistent pane).
    private func makeUngatedModel(localNetwork net: SpyLocalNetwork) -> SetupModel {
        SetupModel(audioProbe: CannedAudioProbe(result: .granted),
                   localNetwork: net,
                   remoteControl: SpyRemoteControl(),
                   ptpHelper: FakePTPHelper(),
                   settings: AppSettings(defaults: defaults),
                   localNetworkGated: false)
    }

    @Test func ungatedLocalNetworkStartsGrantedAndNeverProbes() async {
        let net = SpyLocalNetwork()
        net.reachable = false   // even a "not reachable" probe must be irrelevant
        let model = makeUngatedModel(localNetwork: net)

        // Starts satisfied — there's no gate on this OS to grant.
        #expect(model.localNetworkStatus == .granted)

        // "Allow…" is a no-op: stays granted, and never touches the network.
        await model.primeLocalNetwork()
        #expect(model.localNetworkStatus == .granted)
        #expect(net.probeCount == 0, "ungated OS must not run a Bonjour browse")

        // Never a required-but-missing permission → no dead-end row.
        #expect(!model.requiredPermissionsNotGranted().contains(.localNetwork))
        #expect(!model.unmetRequiredPermissions().contains(.localNetwork))
    }

    @Test func ungatedLocalNetworkSurvivesRefreshAndAudit() async {
        let net = SpyLocalNetwork()
        net.reachable = false
        let model = makeUngatedModel(localNetwork: net)

        await model.refreshStatuses()
        _ = await model.auditRequiredPermissions()

        #expect(model.localNetworkStatus == .granted,
                       "must not be downgraded on an OS without the gate")
        #expect(net.probeCount == 0, "refresh/audit must not browse on an ungated OS")
    }

    // MARK: Audio probe transitions

    @Test func audioProbeGranted() async {
        let (model, _, _, counter) = makeModel(audio: .granted)
        await model.requestAudioCapture()
        #expect(model.audioStatus == .granted)
        #expect(!model.isProbingAudio)
        // Two notifications: one entering the probe (progress), one on result.
        #expect(counter.count == 2)
    }

    @Test func audioProbeDenied() async {
        let (model, _, _, _) = makeModel(audio: .denied)
        await model.requestAudioCapture()
        #expect(model.audioStatus == .denied)
    }

    @Test func audioProbeUnsupported() async {
        let (model, _, _, _) = makeModel(audio: .unsupported)
        await model.requestAudioCapture()
        #expect(model.audioStatus == .unsupported)
    }

    @Test func audioProbeCanBeRetriedAfterCompletion() async {
        // A denied first pass followed by a granted retry (user granted in the
        // gap) must land on the retry's result — the flow is re-runnable.
        let denyThenAllow = FlippingAudioProbe(sequence: [.denied, .granted])
        let model = SetupModel(audioProbe: denyThenAllow,
                               localNetwork: SpyLocalNetwork(),
                               remoteControl: SpyRemoteControl(),
                               ptpHelper: FakePTPHelper(),
                               settings: AppSettings(defaults: defaults))
        await model.requestAudioCapture()
        #expect(model.audioStatus == .denied)
        await model.requestAudioCapture()
        #expect(model.audioStatus == .granted)
    }

    /// Returns each element of `sequence` on successive calls (last repeats).
    private final class FlippingAudioProbe: AudioCapturePermissionProbing, @unchecked Sendable {
        private let lock = NSLock()
        private var remaining: [PermissionStatus]
        init(sequence: [PermissionStatus]) { remaining = sequence }
        func probe() async -> PermissionStatus {
            lock.withLock {
                let next = remaining.first ?? .unknown
                if remaining.count > 1 { remaining.removeFirst() }
                return next
            }
        }
    }

    // MARK: Local network (functional check — no status API)

    @Test func primeLocalNetworkUnreachableStaysRequested() async {
        let (model, spy, _, _) = makeModel(audio: .granted)
        spy.reachable = false
        await model.primeLocalNetwork()
        #expect(spy.probeCount == 1)
        #expect(model.localNetworkStatus == .requested,
                       "browse got nowhere ⇒ asked-but-unproven")
    }

    /// The first prime IS the system permission dialog, and it resolves the
    /// instant the user answers EITHER way — so its window is a pure ceiling on
    /// an unanswered dialog and can afford to be generous. Only that first ask
    /// carries it; a retry re-checks an already-decided permission and stays
    /// snappy.
    @Test func onlyTheFirstLocalNetworkBrowseWaitsForAHuman() async {
        let (model, spy, _, _) = makeModel(audio: .granted)
        spy.reachable = false

        await model.primeLocalNetwork()   // first ask — the dialog appears here
        await model.primeLocalNetwork()   // "Try Again" — no dialog to wait for

        #expect(spy.windows == [SetupModel.firstAskBrowseSeconds,
                                SetupModel.rescanBrowseSeconds])
        #expect(SetupModel.firstAskBrowseSeconds > SetupModel.rescanBrowseSeconds)
    }

    /// The refusal is REAL now (the mDNS policy error the primer watches for),
    /// so the model must report it as such rather than hiding it inside the
    /// "asked, unproven" bucket — that is what routes the card to Settings
    /// instead of asking the user to switch a speaker on that would not help.
    @Test func aRefusedLocalNetworkIsReportedAsDenied() async {
        let model = SetupModel(audioProbe: CannedAudioProbe(result: .granted),
                               localNetwork: CannedOutcomeLocalNetwork(outcome: .denied),
                               remoteControl: SpyRemoteControl(),
                               ptpHelper: FakePTPHelper(),
                               settings: AppSettings(defaults: defaults))
        await model.primeLocalNetwork()

        #expect(model.localNetworkStatus == .denied)
        #expect(model.localNetworkFoundSpeakers == 0)
        #expect(model.unmetRequiredPermissions().contains(.localNetwork))
        #expect(model.requiredPermissionsNotGranted().contains(.localNetwork))
    }

    /// Self-discovery proves the PERMISSION, not the presence of a speaker — so
    /// a grant on a network with nothing switched on is a real grant, and the
    /// required-permission gate must not hold it against the user.
    @Test func aGrantWithNoSpeakersIsStillAGrant() async {
        let model = SetupModel(audioProbe: CannedAudioProbe(result: .granted),
                               localNetwork: CannedOutcomeLocalNetwork(
                                   outcome: .granted(foundSpeakers: 0)),
                               remoteControl: SpyRemoteControl(),
                               ptpHelper: FakePTPHelper(),
                               settings: AppSettings(defaults: defaults))
        await model.primeLocalNetwork()

        #expect(model.localNetworkStatus == .granted)
        #expect(model.localNetworkFoundSpeakers == 0)
        #expect(!model.requiredPermissionsNotGranted().contains(.localNetwork))
        #expect(!model.unmetRequiredPermissions().contains(.localNetwork))
    }

    /// The wait has two halves and they are different things to say: the dialog
    /// is unanswered, then the answer landed and only the count is filling in.
    /// Both are observations, never timers — the second one is the primer's own
    /// reachability callback.
    @Test func theLocalNetworkPrimeReportsBothWaits() async {
        let net = SteppedLocalNetwork(found: 2)
        let model = SetupModel(audioProbe: CannedAudioProbe(result: .granted),
                               localNetwork: net,
                               remoteControl: SpyRemoteControl(),
                               ptpHelper: FakePTPHelper(),
                               settings: AppSettings(defaults: defaults))
        #expect(model.localNetworkPhase == .idle)

        let priming = Task { await model.primeLocalNetwork() }

        await net.waitUntilParked()
        #expect(model.localNetworkPhase == .waitingForAnswer)

        net.resume()                         // …the browse reaches the network
        await net.waitUntilParked()
        await waitForChange { model.localNetworkPhase == .verifying }
        #expect(model.localNetworkPhase == .verifying)

        net.resume()
        await priming.value
        #expect(model.localNetworkPhase == .idle, "the wait never outlives the prime")
        #expect(model.localNetworkStatus == .granted)
        #expect(model.localNetworkFoundSpeakers == 2)
    }

    /// A refusal has no second half to report — there is nothing left to check.
    @Test func aRefusedLocalNetworkNeverEntersTheVerifyingWait() async {
        let model = SetupModel(audioProbe: CannedAudioProbe(result: .granted),
                               localNetwork: CannedOutcomeLocalNetwork(outcome: .denied),
                               remoteControl: SpyRemoteControl(),
                               ptpHelper: FakePTPHelper(),
                               settings: AppSettings(defaults: defaults))
        var phases: [SetupProbePhase] = []
        model.onChange = { phases.append(model.localNetworkPhase) }

        await model.primeLocalNetwork()

        #expect(!phases.contains(.verifying))
        #expect(model.localNetworkPhase == .idle)
    }

    @Test func primeLocalNetworkReachableBecomesGranted() async {
        // The case ahh hit: it's actually working, so we must NOT lie with a
        // sticky "Requested" — a browse that reaches the network proves the grant.
        let (model, spy, _, _) = makeModel(audio: .granted)
        spy.reachable = true
        await model.primeLocalNetwork()
        #expect(model.localNetworkStatus == .granted)
    }

    // MARK: Remote control (Accessibility — real, silent status API)

    @Test func primeRemoteControlReadsRealTrustState() {
        let (model, _, spy, _) = makeModel(audio: .granted)
        spy.trusted = true
        model.primeRemoteControl()
        #expect(spy.primeCount == 1)
        #expect(model.remoteControlStatus == .granted,
                       "already trusted ⇒ granted, not a sticky requested")
    }

    @Test func primeRemoteControlUntrustedStaysRequested() {
        let (model, _, spy, _) = makeModel(audio: .granted)
        spy.trusted = false
        model.primeRemoteControl()
        #expect(model.remoteControlStatus == .requested)
    }

    // MARK: Bluetooth (CBManager.authorization — the one fully honest status API)

    private func makeBluetoothModel(_ script: BluetoothScript) -> (SetupModel, ChangeCounter) {
        let counter = ChangeCounter()
        let model = SetupModel(audioProbe: CannedAudioProbe(result: .granted),
                               localNetwork: SpyLocalNetwork(),
                               remoteControl: SpyRemoteControl(),
                               ptpHelper: FakePTPHelper(),
                               bluetoothReader: script,
                               bluetoothPrimer: script,
                               settings: AppSettings(defaults: defaults))
        model.onChange = { counter.count += 1 }
        return (model, counter)
    }

    /// `primeBluetooth()`'s decision callback reaches the main actor through a
    /// `Task`, so it lands on a suspension point rather than synchronously.
    private func waitForChange(_ satisfied: () -> Bool) async {
        for _ in 0..<1_000 {
            if satisfied() { return }
            await Task.yield()
        }
    }

    @Test func bluetoothStatusMapsFromTheSilentRead() async {
        let script = BluetoothScript()
        let (model, _) = makeBluetoothModel(script)
        #expect(model.bluetoothStatus == .unknown, "undetermined ⇒ unknown, never a sticky requested")

        script.status = .granted
        await model.refreshStatuses()
        #expect(model.bluetoothStatus == .granted)

        // Bluetooth has a REAL denied — unlike Local Network / Remote Control,
        // this flow never has to soften a refusal into `.requested`.
        script.status = .denied
        await model.refreshStatuses()
        #expect(model.bluetoothStatus == .denied)
    }

    /// A revocation made in System Settings downgrades a prior `.granted` — the
    /// read is free and prompt-free, so it is always re-read (same posture as
    /// Remote Control).
    @Test func refreshDowngradesBluetoothWhenRevoked() async {
        let script = BluetoothScript()
        script.status = .granted
        let (model, _) = makeBluetoothModel(script)
        await model.refreshStatuses()
        #expect(model.bluetoothStatus == .granted)

        script.status = .denied
        await model.refreshStatuses()
        #expect(model.bluetoothStatus == .denied)
    }

    @Test func primeBluetoothLeavesStatusUntouchedUntilTheUserAnswers() async {
        let script = BluetoothScript()
        let (model, counter) = makeBluetoothModel(script)

        model.primeBluetooth()
        #expect(script.primeCount == 1)
        #expect(model.bluetoothStatus == .unknown, "an unanswered prompt is not an answer")
        // The STATUS is untouched, but the wait itself is observable now — the
        // card shows a spinner while the prompt is up, so starting one repaints.
        #expect(model.isPrimingBluetooth)
        #expect(counter.count == 1, "the wait began ⇒ one repaint, and no status write")
    }

    @Test func primeBluetoothAdoptsTheGrantWhenDecided() async {
        let script = BluetoothScript()
        let (model, counter) = makeBluetoothModel(script)

        model.primeBluetooth()
        script.decide(.granted)
        await waitForChange { model.bluetoothStatus == .granted }

        #expect(model.bluetoothStatus == .granted)
        #expect(!model.isPrimingBluetooth, "a real decision ends the wait")
        // Two repaints, both earned: the wait starting, and the grant landing.
        #expect(counter.count == 2, "one for the wait, one for the transition")
    }

    /// A denial ends the wait exactly like a grant does — the callback fires
    /// either way, and re-reading the status is what tells them apart.
    @Test func primeBluetoothAdoptsADenialWhenDecided() async {
        let script = BluetoothScript()
        let (model, _) = makeBluetoothModel(script)

        model.primeBluetooth()
        script.decide(.denied)
        await waitForChange { model.bluetoothStatus == .denied }

        #expect(model.bluetoothStatus == .denied)
    }

    /// Bluetooth is an ENHANCEMENT (locked: it joins the flow, not the required
    /// set): a denial must leave Done available and must never force-reopen
    /// setup, or a user without Bluetooth could never finish.
    @Test func deniedBluetoothLeavesEveryRequiredPermissionSatisfied() async {
        let script = BluetoothScript()
        script.status = .denied
        let net = SpyLocalNetwork()
        net.reachable = true
        let ptpHelper = FakePTPHelper()
        ptpHelper.status = .enabled
        let model = SetupModel(audioProbe: CannedAudioProbe(result: .granted),
                               localNetwork: net,
                               remoteControl: SpyRemoteControl(),
                               ptpHelper: ptpHelper,
                               bluetoothReader: script,
                               bluetoothPrimer: script,
                               settings: AppSettings(defaults: defaults))
        await model.requestAudioCapture()
        await model.primeLocalNetwork()
        await model.refreshStatuses()

        #expect(model.bluetoothStatus == .denied)
        #expect(model.requiredPermissionsNotGranted().isEmpty,
                "a denied Bluetooth must not hold the Done gate shut")
        #expect(model.unmetRequiredPermissions().isEmpty,
                "a denied Bluetooth must not force-reopen setup")
    }

    /// Bluetooth is a step in the flow but never a required permission — the
    /// locked product decision, in the only two places it is expressible.
    @Test func bluetoothIsASetupStepButNotRequired() {
        #expect(SetupPermission.allCases.contains(.bluetooth))
        #expect(RequiredPermission.allCases.count == 3)
    }

    /// The mapping from `CBManager.authorization`, exhaustively — the live read
    /// itself can only ever report whatever this Mac happens to have granted.
    @Test func cbAuthorizationMapping() {
        #expect(BluetoothPermissionReader.status(for: .notDetermined) == .unknown)
        #expect(BluetoothPermissionReader.status(for: .allowedAlways) == .granted)
        #expect(BluetoothPermissionReader.status(for: .denied) == .denied)
        #expect(BluetoothPermissionReader.status(for: .restricted) == .denied)
    }

    // MARK: PTP helper daemon (T6 — SMAppService registration + approval)

    @Test func initialPTPHelperStatusIsNotRegistered() {
        let (model, _, _, _) = makeModel(audio: .granted)
        #expect(model.ptpHelperStatus == .notRegistered)
    }

    @Test func registerPTPHelperCallsRegisterAndAdoptsRequiresApproval() {
        let ptpHelper = FakePTPHelper()
        ptpHelper.statusAfterRegister = .requiresApproval
        let (model, _, _, counter) = makeModel(audio: .granted, ptpHelper: ptpHelper)

        model.registerPTPHelper()

        #expect(ptpHelper.registerCount == 1)
        #expect(model.ptpHelperStatus == .requiresApproval,
                       "requiresApproval → the explainer + Open Login Items… button")
        #expect(counter.count == 1)
    }

    @Test func registerPTPHelperCanReachEnabledDirectly() {
        // Covers the injected-fake path for "enabled → available": a fake that
        // reports already-approved right after register() (as a real daemon
        // would on a signed build once the user had already approved it once).
        let ptpHelper = FakePTPHelper()
        ptpHelper.statusAfterRegister = .enabled
        let (model, _, _, _) = makeModel(audio: .granted, ptpHelper: ptpHelper)

        model.registerPTPHelper()

        #expect(model.ptpHelperStatus == .enabled)
    }

    @Test func registerPTPHelperFailureLogsAndReadsRealStatus() {
        // A throwing register() (e.g. a loose dev binary) must not crash or lie —
        // it still reads back whatever `.status` really is afterward.
        struct Boom: Error {}
        let ptpHelper = FakePTPHelper()
        ptpHelper.registerError = Boom()
        ptpHelper.status = .notFound
        let (model, _, _, _) = makeModel(audio: .granted, ptpHelper: ptpHelper)

        model.registerPTPHelper()

        #expect(ptpHelper.registerCount == 1)
        #expect(model.ptpHelperStatus == .notFound)
    }

    @Test func openPTPHelperLoginItemsDelegatesToTheSeam() {
        let ptpHelper = FakePTPHelper()
        let (model, _, _, _) = makeModel(audio: .granted, ptpHelper: ptpHelper)
        model.openPTPHelperLoginItems()
        #expect(ptpHelper.openSettingsCount == 1)
    }

    @Test func refreshPTPHelperStatusPicksUpApprovalWithoutReregistering() async {
        // The poll while `.requiresApproval` waits for the user to flip Login
        // Items — it must re-read `.status`, never call `register()` again.
        let ptpHelper = FakePTPHelper()
        ptpHelper.statusAfterRegister = .requiresApproval
        let (model, _, _, _) = makeModel(audio: .granted, ptpHelper: ptpHelper)
        model.registerPTPHelper()
        #expect(model.ptpHelperStatus == .requiresApproval)

        ptpHelper.status = .enabled   // user approved it in Login Items
        await model.refreshPTPHelperStatus()

        #expect(model.ptpHelperStatus == .enabled, "enabled → available")
        #expect(ptpHelper.registerCount == 1, "poll never re-registers")
    }

    @Test func refreshPTPHelperStatusIsQuietWhenUnchanged() async {
        let ptpHelper = FakePTPHelper()
        let (model, _, _, counter) = makeModel(audio: .granted, ptpHelper: ptpHelper)
        counter.count = 0
        await model.refreshPTPHelperStatus()
        #expect(counter.count == 0, "no transition ⇒ no onChange noise")
    }

    @Test func refreshStatusesSilentlyRereadsPTPHelperStatus() async {
        // `refreshStatuses()` (window-focus path) must ALSO pick up the PTP
        // helper's live status, without touching `register()`.
        let ptpHelper = FakePTPHelper()
        ptpHelper.status = .requiresApproval
        let (model, _, _, _) = makeModel(audio: .granted, ptpHelper: ptpHelper)
        await model.refreshStatuses()
        #expect(model.ptpHelperStatus == .requiresApproval)

        ptpHelper.status = .enabled
        await model.refreshStatuses()
        #expect(model.ptpHelperStatus == .enabled)
        #expect(ptpHelper.registerCount == 0, "refreshStatuses never registers")
    }

    // MARK: Live status refresh (reflect reality on window focus)

    @Test func refreshUpgradesRemoteControlWhenGrantedInSettings() async {
        // User was untrusted, went to System Settings, toggled it on, came back.
        let (model, _, remote, _) = makeModel(audio: .unknown)
        remote.trusted = false
        model.primeRemoteControl()
        #expect(model.remoteControlStatus == .requested)
        remote.trusted = true                 // flipped it on in Settings
        await model.refreshStatuses()
        #expect(model.remoteControlStatus == .granted)
    }

    @Test func refreshDowngradesRemoteControlWhenRevoked() async {
        let (model, _, remote, _) = makeModel(audio: .unknown)
        remote.trusted = true
        await model.refreshStatuses()
        #expect(model.remoteControlStatus == .granted)
        remote.trusted = false                // revoked in Settings
        await model.refreshStatuses()
        #expect(model.remoteControlStatus == .requested)
    }

    @Test func refreshNeverPromptsUntouchedRows() async {
        // A refresh on a fresh screen (all unknown) must not fire either
        // PROMPTING read — the audible audio probe or a network browse — since
        // both spring a system dialog the user hasn't engaged. The silent reads
        // (Accessibility, and audio's `currentStatusSilently()`, which this
        // fake leaves `nil`) are free and are not what this pins.
        let audio = CountingAudioProbe(result: .granted)
        let net = SpyLocalNetwork()
        let model = SetupModel(audioProbe: audio, localNetwork: net,
                               remoteControl: SpyRemoteControl(),
                               ptpHelper: FakePTPHelper(),
                               settings: AppSettings(defaults: defaults))
        await model.refreshStatuses()
        #expect(audio.probeCount == 0, "audio not re-probed while unknown")
        #expect(net.probeCount == 0, "network not browsed while unknown")
    }

    @Test func refreshStatusesReadsAudioSilentlyNeverTheAudibleTone() async {
        // ONBOARD-TONE regression: `refreshStatuses()` is what
        // `OnboardingWindowController.appDidBecomeActive` calls on EVERY plain
        // app reactivation while onboarding is still open (e.g. Cmd+Tab away
        // and back) — not just the explicit "Allow…" tap. Once the row has
        // been engaged (`.denied`), a refresh must adopt the SILENT read and
        // must NEVER call the audible `probe()` — that stays reserved for
        // `requestAudioCapture()`.
        let audio = SilentAudioProbe(probeResult: .denied, silentResult: .granted)
        let model = SetupModel(audioProbe: audio,
                               localNetwork: SpyLocalNetwork(),
                               remoteControl: SpyRemoteControl(),
                               ptpHelper: FakePTPHelper(),
                               settings: AppSettings(defaults: defaults))
        await model.requestAudioCapture()   // the one legitimate audible call
        #expect(model.audioStatus == .denied)
        #expect(audio.probeCallCount == 1)

        await model.refreshStatuses()       // simulated plain app reactivation
        #expect(model.audioStatus == .granted, "picks up a grant made in Settings via the silent read")
        #expect(audio.silentCallCount == 1)
        #expect(audio.probeCallCount == 1, "reactivation must not replay the audible tone probe")
    }

    @Test func refreshStatusesLeavesAudioUnchangedWhenSilentReadIsNil() async {
        // A fake that hasn't implemented the silent seam (default `nil`, e.g.
        // `CannedAudioProbe`) must not fall back to the audible probe on an
        // engaged (`.denied`) row — it just leaves the cached status
        // untouched, same posture as `auditRequiredPermissions()`.
        let audio = SilentAudioProbe(probeResult: .denied, silentResult: nil)
        let model = SetupModel(audioProbe: audio,
                               localNetwork: SpyLocalNetwork(),
                               remoteControl: SpyRemoteControl(),
                               ptpHelper: FakePTPHelper(),
                               settings: AppSettings(defaults: defaults))
        await model.requestAudioCapture()   // → .denied, engages the row
        #expect(model.audioStatus == .denied)
        #expect(audio.probeCallCount == 1)

        await model.refreshStatuses()
        #expect(model.audioStatus == .denied, "unchanged — nil silent read must not clobber the cached status")
        #expect(audio.probeCallCount == 1, "still never falls back to the audible probe")
    }

    @Test func refreshReadsAudioOnAnUnengagedRow() async {
        // Live report, 2026-08-29: "Open Setup…" showed System Audio as
        // un-granted although the grant was in place. Every re-open builds a
        // FRESH model, so `audioStatus` is `.unknown` — and the refresh used to
        // read audio only on an ALREADY-ENGAGED row (`.denied`/`.requested`),
        // so it skipped the one read that would have shown the truth. The
        // silent read raises no prompt, so there is nothing to protect the user
        // from by skipping it.
        let audio = SilentAudioProbe(probeResult: .denied, silentResult: .granted)
        let model = SetupModel(audioProbe: audio,
                               localNetwork: SpyLocalNetwork(),
                               remoteControl: SpyRemoteControl(),
                               ptpHelper: FakePTPHelper(),
                               settings: AppSettings(defaults: defaults))
        #expect(model.audioStatus == .unknown, "a fresh model has never asked")

        await model.refreshStatuses()

        #expect(model.audioStatus == .granted, "an existing grant shows without being re-granted by hand")
        #expect(audio.probeCallCount == 0, "and still never through the audible probe")
    }

    @Test func refreshNeverUnsaysAProvenAudioGrant() async {
        // The other half of always-reading: `requestAudioCapture()` proves a
        // grant FUNCTIONALLY (it hears its own tone through the tap) without
        // writing `SystemAudioCaptureTCC`'s fresh-grant latch, while the silent
        // read is the process-lifetime-cached TCC read that keeps reporting
        // undetermined (⇒ `.unknown`) after that same grant. Adopting it
        // blindly would flip a just-proven row back to "not asked" on the next
        // Cmd+Tab — so `.unknown` must never unsay `.granted`.
        let audio = SilentAudioProbe(probeResult: .granted, silentResult: .unknown)
        let model = SetupModel(audioProbe: audio,
                               localNetwork: SpyLocalNetwork(),
                               remoteControl: SpyRemoteControl(),
                               ptpHelper: FakePTPHelper(),
                               settings: AppSettings(defaults: defaults))
        await model.requestAudioCapture()
        #expect(model.audioStatus == .granted)

        await model.refreshStatuses()

        #expect(model.audioStatus == .granted, "an undetermined re-read is an absence, not a refusal")
    }

    @Test func refreshStillDowngradesAudioOnARealDenial() async {
        // The stickiness above is scoped to `.unknown`. A refusal read back
        // from TCC is real information and must still take the grant away,
        // exactly as it did before.
        let audio = SilentAudioProbe(probeResult: .granted, silentResult: .denied)
        let model = SetupModel(audioProbe: audio,
                               localNetwork: SpyLocalNetwork(),
                               remoteControl: SpyRemoteControl(),
                               ptpHelper: FakePTPHelper(),
                               settings: AppSettings(defaults: defaults))
        await model.requestAudioCapture()
        #expect(model.audioStatus == .granted)

        await model.refreshStatuses()

        #expect(model.audioStatus == .denied)
    }

    @Test func freshModelStartsFromAProvenLocalNetworkGrant() async {
        // The Local Network half of the same live report. This permission has
        // no silent read — browsing is what raises the prompt — so a fresh
        // `.unknown` can never be resolved by looking, and the row asked again
        // for a permission held for weeks. The persisted proof is what a new
        // model starts from; the re-browse that follows is prompt-free because
        // the permission is already granted (no self-discovery publish).
        let settings = AppSettings(defaults: defaults)
        settings.localNetworkWasGranted = true
        let net = SpyLocalNetwork()
        net.reachable = true
        let model = SetupModel(audioProbe: CannedAudioProbe(result: .granted),
                               localNetwork: net,
                               remoteControl: SpyRemoteControl(),
                               ptpHelper: FakePTPHelper(),
                               settings: settings)

        #expect(model.localNetworkStatus == .granted, "starts from the proof, not from scratch")

        await model.refreshStatuses()

        #expect(model.localNetworkStatus == .granted)
        #expect(net.selfDiscoveryFlags == [false],
                "a permission already granted is re-checked by browsing only — never by republishing")
    }

    @Test func provingLocalNetworkPersistsTheGrantAndARefusalClearsIt() async {
        // The one prime funnel owns the bit, so it can never drift from the
        // status the same funnel returns.
        let (model, net, _, _) = makeModel(audio: .granted)
        net.reachable = true
        await model.primeLocalNetwork()
        #expect(model.localNetworkStatus == .granted)
        #expect(AppSettings(defaults: defaults).localNetworkWasGranted,
                "the proof outlives this session, for the next fresh model")

        // A refusal is the one thing that takes it back — the same event that
        // is allowed to downgrade the status itself.
        let settings = AppSettings(defaults: defaults)
        let refused = SetupModel(audioProbe: CannedAudioProbe(result: .granted),
                                 localNetwork: CannedOutcomeLocalNetwork(outcome: .denied),
                                 remoteControl: SpyRemoteControl(),
                                 ptpHelper: FakePTPHelper(),
                                 settings: settings)
        await refused.primeLocalNetwork()
        #expect(refused.localNetworkStatus == .denied)
        #expect(!settings.localNetworkWasGranted, "a refusal clears the proof, so the next session asks again")
    }

    @Test func refreshReprobesAlreadyAskedNetwork() async {
        // Once the network row has been engaged, a refresh re-checks it — catching
        // the case where the browse first got nowhere (requested) but the network
        // is reachable on the next look (e.g. the user just answered the prompt).
        let (model, net, _, _) = makeModel(audio: .granted)
        net.reachable = false
        await model.primeLocalNetwork()          // → requested
        #expect(model.localNetworkStatus == .requested)
        net.reachable = true                      // reachable now
        await model.refreshStatuses()
        #expect(model.localNetworkStatus == .granted)
        #expect(net.probeCount >= 2)
    }

    /// Audio probe that counts how many times it was asked (to prove refresh does
    /// NOT probe audio while the row is still `.unknown`).
    private final class CountingAudioProbe: AudioCapturePermissionProbing, @unchecked Sendable {
        let result: PermissionStatus
        private let lock = NSLock()
        private var _probeCount = 0
        var probeCount: Int { lock.withLock { _probeCount } }
        init(result: PermissionStatus) { self.result = result }
        func probe() async -> PermissionStatus { lock.withLock { _probeCount += 1 }; return result }
    }

    // MARK: Completion + persistence

    @Test func completePersistsFlag() {
        let (model, _, _, _) = makeModel(audio: .granted)
        #expect(!AppSettings(defaults: defaults).hasCompletedSetup)
        model.complete()
        #expect(AppSettings(defaults: defaults).hasCompletedSetup)
    }

    @Test func completeDoesNotRequireGrants() {
        // `complete()` is a plain persistence write and checks nothing itself.
        // The GATE is real (owner decision 2026-08-11) but lives one level up:
        // the UI offers no Done affordance until every required permission
        // verifies, so reaching this call already means they did.
        let (model, _, _, _) = makeModel(audio: .denied)
        model.complete()
        #expect(AppSettings(defaults: defaults).hasCompletedSetup)
    }

    // MARK: Launch gate

    @Test func shouldPresentOnlyForNativeAndOnlyUntilCompleted() {
        let settings = AppSettings(defaults: defaults)
        let env: [String: String] = [:]   // no override — exercise the default gate

        // Native + not completed → present.
        #expect(SetupModel.shouldPresentOnLaunch(settings: settings, backendKind: .native, environment: env))

        // Non-native backends never present, regardless of completion — they
        // don't tap in-process or discover under the app's own identity.
        #expect(!SetupModel.shouldPresentOnLaunch(settings: settings, backendKind: .mock, environment: env))
        #expect(!SetupModel.shouldPresentOnLaunch(settings: settings, backendKind: .ownTone, environment: env))

        // Once completed, even native stops presenting.
        settings.hasCompletedSetup = true
        #expect(!SetupModel.shouldPresentOnLaunch(settings: settings, backendKind: .native, environment: env))
    }

    @Test func airplaySetupEnvOverridesTheGate() {
        let settings = AppSettings(defaults: defaults)
        settings.hasCompletedSetup = true   // default gate would say "hide"

        // skip → never present (the testing default), even native + not completed.
        let fresh = AppSettings(defaults: isolation.makeDefaults())
        for skip in ["skip", "off", "never", "0"] {
            #expect(!SetupModel.shouldPresentOnLaunch(
                settings: fresh, backendKind: .native,
                environment: [SetupPresentation.environmentVariableName: skip]), "\(skip) should hide")
        }

        // force → always present, ignoring completed AND non-native backend.
        for show in ["force", "always", "1"] {
            #expect(SetupModel.shouldPresentOnLaunch(
                settings: settings, backendKind: .mock,
                environment: [SetupPresentation.environmentVariableName: show]), "\(show) should force-show")
        }

        // Unrecognized value → auto (falls through to the default gate).
        #expect(!SetupModel.shouldPresentOnLaunch(
            settings: settings, backendKind: .native,
            environment: [SetupPresentation.environmentVariableName: "banana"]),
            "unrecognized value falls back to the default gate (completed ⇒ hide)")
    }

    // MARK: Required permissions (revocation audit)

    /// Records `probe()` (audible) and `currentStatusSilently()` (silent) calls
    /// separately and returns canned results for each — exercises the OPT-IN
    /// silent seam (default is `nil` via the protocol extension, so every other
    /// fake in this file needs no change) while also proving the audible path
    /// was or wasn't touched.
    private final class SilentAudioProbe: AudioCapturePermissionProbing, @unchecked Sendable {
        let probeResult: PermissionStatus
        let silentResult: PermissionStatus?
        private let lock = NSLock()
        private var _silentCallCount = 0
        private var _probeCallCount = 0
        var silentCallCount: Int { lock.withLock { _silentCallCount } }
        var probeCallCount: Int { lock.withLock { _probeCallCount } }
        init(probeResult: PermissionStatus = .granted, silentResult: PermissionStatus?) {
            self.probeResult = probeResult
            self.silentResult = silentResult
        }
        func probe() async -> PermissionStatus {
            lock.withLock { _probeCallCount += 1 }
            return probeResult
        }
        func currentStatusSilently() -> PermissionStatus? {
            lock.withLock { _silentCallCount += 1 }
            return silentResult
        }
    }

    @Test func unmetRequiredPermissionsEmptyWhenAllSatisfied() async {
        let ptpHelper = FakePTPHelper()
        ptpHelper.status = .enabled
        let (model, _, _, _) = makeModel(audio: .granted, ptpHelper: ptpHelper)
        await model.requestAudioCapture()          // → .granted
        #expect(model.audioStatus == .granted)
        #expect(model.unmetRequiredPermissions() == [])
    }

    @Test func unmetRequiredPermissionsFlagsDeniedAudio() async {
        let (model, _, _, _) = makeModel(audio: .denied)
        await model.requestAudioCapture()           // → .denied
        #expect(model.unmetRequiredPermissions() == [.audioCapture])
    }

    @Test func unmetRequiredPermissionsFlagsRequestedLocalNetwork() async {
        let (model, net, _, _) = makeModel(audio: .granted)
        net.reachable = false
        await model.primeLocalNetwork()             // → .requested
        #expect(model.unmetRequiredPermissions() == [.localNetwork])
    }

    @Test func unmetRequiredPermissionsNeverFlagsUnengagedLocalNetwork() {
        // `.unknown` (never asked) must NOT count as unmet — only a proven
        // "asked but unproven" (`.requested`) does.
        let (model, _, _, _) = makeModel(audio: .granted)
        #expect(model.localNetworkStatus == .unknown)
        #expect(model.unmetRequiredPermissions() == [])
    }

    /// The nag is for a REGRESSION only: a helper the user did once approve and
    /// that is off now. The ratchet (``AppSettings/speakerSyncWasEnabled``) is
    /// what remembers the "once approved" half.
    @Test func unmetRequiredPermissionsFlagsARevokedPTPHelper() async {
        let ptpHelper = FakePTPHelper()
        ptpHelper.statusAfterRegister = .enabled
        let (model, _, _, _) = makeModel(audio: .granted, ptpHelper: ptpHelper)
        model.registerPTPHelper()                       // → .enabled, arming the ratchet
        #expect(model.unmetRequiredPermissions() == [], "nothing lost while it is on")

        ptpHelper.status = .requiresApproval             // switched off in Login Items
        await model.refreshPTPHelperStatus()

        #expect(model.unmetRequiredPermissions() == [.ptpHelper])
    }

    /// …and a helper that was NEVER approved is not a regression, however loudly
    /// `.requiresApproval` reads: nobody turned anything off.
    @Test func unmetRequiredPermissionsNeverFlagsANeverApprovedPTPHelper() {
        let ptpHelper = FakePTPHelper()
        ptpHelper.statusAfterRegister = .requiresApproval
        let (model, _, _, _) = makeModel(audio: .granted, ptpHelper: ptpHelper)
        model.registerPTPHelper()
        #expect(model.ptpHelperStatus == .requiresApproval)
        #expect(model.unmetRequiredPermissions() == [])
    }

    /// A skip takes the ratchet back down, so passing on Speaker Sync is not
    /// re-litigated at every wake.
    @Test func noteSpeakerSyncSkippedDisarmsTheWakeAudit() async {
        let ptpHelper = FakePTPHelper()
        ptpHelper.statusAfterRegister = .enabled
        let (model, _, _, _) = makeModel(audio: .granted, ptpHelper: ptpHelper)
        model.registerPTPHelper()                       // → .enabled, arming the ratchet
        ptpHelper.status = .requiresApproval
        await model.refreshPTPHelperStatus()
        #expect(model.unmetRequiredPermissions() == [.ptpHelper], "armed, as a sanity check")

        model.noteSpeakerSyncSkipped()

        #expect(model.unmetRequiredPermissions() == [])
        #expect(!AppSettings(defaults: defaults).speakerSyncWasEnabled, "and it persists")
    }

    @Test func unmetRequiredPermissionsNeverFlagsNotRegisteredPTPHelper() {
        // Pre-registration is handled by the app's launch-time registration
        // attempt, not a permission-lost nag.
        let (model, _, _, _) = makeModel(audio: .granted)
        #expect(model.ptpHelperStatus == .notRegistered)
        #expect(model.unmetRequiredPermissions() == [])
    }

    @Test func unmetRequiredPermissionsNeverIncludesRevokedRemoteControl() async {
        // Remote Control is an ENHANCEMENT, deliberately excluded from
        // "required" (2026-07-21 product decision) — even a revoked one
        // (granted → requested) must never show up here.
        let (model, _, remote, _) = makeModel(audio: .granted)
        remote.trusted = true
        model.primeRemoteControl()
        #expect(model.remoteControlStatus == .granted)
        remote.trusted = false
        await model.refreshStatuses()
        #expect(model.remoteControlStatus == .requested, "revoked, as a sanity check on the setup")
        #expect(model.unmetRequiredPermissions() == [], "Remote Control is never 'required'")
    }

    @Test func unmetRequiredPermissionsCanReportAllThree() async {
        let ptpHelper = FakePTPHelper()
        ptpHelper.statusAfterRegister = .enabled
        let (model, net, _, _) = makeModel(audio: .denied, ptpHelper: ptpHelper)
        await model.requestAudioCapture()            // → .denied
        net.reachable = false
        await model.primeLocalNetwork()              // → .requested
        model.registerPTPHelper()                     // → .enabled, arming the ratchet
        ptpHelper.status = .requiresApproval          // …then switched off again
        await model.refreshPTPHelperStatus()
        #expect(Set(model.unmetRequiredPermissions()) ==
                       Set([.audioCapture, .localNetwork, .ptpHelper]))
    }

    // MARK: Required permissions NOT granted (onboarding Done-tap gate)

    /// The original ONBOARD-GATE bug: a first-time user who never touched a
    /// single row and taps Done straight away. Every required permission is
    /// still at its untouched initial state — unlike
    /// ``SetupModel/unmetRequiredPermissions()`` (which exists to catch a
    /// *regression* and deliberately never flags `.unknown`/`.notRegistered`),
    /// `requiredPermissionsNotGranted()` must flag all three here, since
    /// nothing was ever actually granted.
    @Test func requiredPermissionsNotGrantedFlagsAllThreeOnAFreshModel() {
        let (model, _, _, _) = makeModel(audio: .granted)   // audioProbe would say granted, but never asked
        #expect(model.audioStatus == .unknown)
        #expect(model.localNetworkStatus == .unknown)
        #expect(model.ptpHelperStatus == .notRegistered)
        #expect(Set(model.requiredPermissionsNotGranted()) ==
                       Set([.audioCapture, .localNetwork, .ptpHelper]))
    }

    @Test func requiredPermissionsNotGrantedEmptyWhenAllThreeAreActuallyGranted() async {
        let ptpHelper = FakePTPHelper()
        ptpHelper.statusAfterRegister = .enabled
        let (model, net, _, _) = makeModel(audio: .granted, ptpHelper: ptpHelper)
        await model.requestAudioCapture()   // → .granted
        net.reachable = true
        await model.primeLocalNetwork()     // → .granted
        model.registerPTPHelper()           // → .enabled (mirrors viewDidLoad's real call)
        #expect(model.requiredPermissionsNotGranted() == [])
    }

    @Test func requiredPermissionsNotGrantedExcludesUnsupportedAudio() async {
        // `.unsupported` (pre-14.2 OS) can't be fixed by granting anything, so
        // it must not be nagged about — unlike `.unknown`/`.denied`.
        let (model, _, _, _) = makeModel(audio: .unsupported)
        await model.requestAudioCapture()   // → .unsupported
        #expect(!model.requiredPermissionsNotGranted().contains(.audioCapture))
    }

    @Test func requiredPermissionsNotGrantedIncludesNotRegisteredPTPHelper() {
        // Contrast with `unmetRequiredPermissions()`, which deliberately
        // excludes `.notRegistered` (see
        // `unmetRequiredPermissionsNeverFlagsNotRegisteredPTPHelper`) —
        // that method only cares about a REGRESSION after setup completed.
        // This one cares whether Done is about to finish with the helper
        // never actually enabled, so `.notRegistered` counts.
        let (model, _, _, _) = makeModel(audio: .granted)
        #expect(model.ptpHelperStatus == .notRegistered)
        #expect(model.requiredPermissionsNotGranted().contains(.ptpHelper))
    }

    /// `.notFound` means the daemon isn't in the bundle — a packaging fault with
    /// no switch anywhere for the user to flip, so it must not hold Done shut.
    @Test func requiredPermissionsNotGrantedExcludesANotFoundPTPHelper() {
        let ptpHelper = FakePTPHelper()
        ptpHelper.statusAfterRegister = .notFound
        let (model, _, _, _) = makeModel(audio: .granted, ptpHelper: ptpHelper)
        model.registerPTPHelper()
        #expect(model.ptpHelperStatus == .notFound)
        #expect(!model.requiredPermissionsNotGranted().contains(.ptpHelper))
        #expect(model.unmetRequiredPermissions() == [], "and it never nags on wake either")
    }

    /// Same for a `register()` that threw: nothing got registered, so there is
    /// nothing to approve, and the flag says so.
    @Test func aFailedRegistrationIsRecordedAndNeverHoldsTheGate() {
        struct RegistrationFailed: Error {}
        let ptpHelper = FakePTPHelper()
        ptpHelper.registerError = RegistrationFailed()
        let (model, _, _, _) = makeModel(audio: .granted, ptpHelper: ptpHelper)
        #expect(!model.ptpHelperRegistrationFailed, "nothing has been tried yet")

        model.registerPTPHelper()

        #expect(model.ptpHelperRegistrationFailed)
        #expect(!model.requiredPermissionsNotGranted().contains(.ptpHelper))
    }

    @Test func requiredPermissionsNotGrantedIgnoresRemoteControl() {
        // Remote Control isn't in `RequiredPermission` at all (enhancement,
        // not a requirement), so it can never appear here regardless of state.
        let (model, _, remote, _) = makeModel(audio: .granted)
        remote.trusted = false
        model.primeRemoteControl()
        #expect(model.remoteControlStatus == .requested)
        #expect(Set(model.requiredPermissionsNotGranted()) ==
                       Set([.audioCapture, .localNetwork, .ptpHelper]),
                       "Remote Control status never influences this list")
    }

    @Test func auditRequiredPermissionsUsesSilentAudioReadAndFlagsRevocation() async {
        // The model starts out never-probed (audioStatus == .unknown); the
        // silent read is what discovers the revocation without firing the tone.
        let silentAudio = SilentAudioProbe(silentResult: .denied)
        let ptpHelper = FakePTPHelper()
        let model = SetupModel(audioProbe: silentAudio,
                               localNetwork: SpyLocalNetwork(),
                               remoteControl: SpyRemoteControl(),
                               ptpHelper: ptpHelper,
                               settings: AppSettings(defaults: defaults))
        let unmet = await model.auditRequiredPermissions()
        #expect(silentAudio.silentCallCount == 1)
        #expect(model.audioStatus == .denied)
        #expect(unmet == [.audioCapture])
    }

    @Test func auditRequiredPermissionsLeavesAudioUnchangedWhenSilentReadIsNil() async {
        // A fake that hasn't implemented the silent seam (the default, `nil`)
        // must not clobber a previously-observed real status.
        let silentAudio = SilentAudioProbe(silentResult: nil)
        let model = SetupModel(audioProbe: silentAudio,
                               localNetwork: SpyLocalNetwork(),
                               remoteControl: SpyRemoteControl(),
                               ptpHelper: FakePTPHelper(),
                               settings: AppSettings(defaults: defaults))
        await model.requestAudioCapture()   // seeds a real .granted via the (canned) probe path
        #expect(model.audioStatus == .granted)
        _ = await model.auditRequiredPermissions()
        #expect(model.audioStatus == .granted, "nil silent read must not overwrite the cached status")
    }

    @Test func auditRequiredPermissionsReprobesEngagedLocalNetworkOnly() async {
        let silentAudio = SilentAudioProbe(silentResult: .granted)
        let net = SpyLocalNetwork()
        let model = SetupModel(audioProbe: silentAudio,
                               localNetwork: net,
                               remoteControl: SpyRemoteControl(),
                               ptpHelper: FakePTPHelper(),
                               settings: AppSettings(defaults: defaults))
        // Untouched (.unknown) — audit must not browse (would spring a prompt).
        _ = await model.auditRequiredPermissions()
        #expect(net.probeCount == 0)

        // Now engage it — the audit re-probes because it's no longer `.unknown`.
        net.reachable = true
        await model.primeLocalNetwork()
        #expect(model.localNetworkStatus == .granted)
        let probesAfterAsk = net.probeCount

        _ = await model.auditRequiredPermissions()
        #expect(net.probeCount > probesAfterAsk)
    }

    /// THE state churn caught live: after the grant, every app activation
    /// re-probes, and a re-probe that proved nothing used to downgrade the
    /// permission to `.requested` — the card flashed "not granted", the
    /// completed step re-opened as the active one, and the next probe put it
    /// back. The grant is SELF-PROVEN; nothing but the refusal itself takes it
    /// away.
    @Test func aRescanThatProvesNothingNeverTakesAProvedGrantBack() async {
        let net = SwitchableLocalNetwork(.granted(foundSpeakers: 3))
        let model = SetupModel(audioProbe: CannedAudioProbe(result: .granted),
                               localNetwork: net,
                               remoteControl: SpyRemoteControl(),
                               ptpHelper: FakePTPHelper(),
                               settings: AppSettings(defaults: defaults))
        await model.primeLocalNetwork()
        #expect(model.localNetworkStatus == .granted)

        // Every status the UI could have repainted from here on.
        var seen: [PermissionStatus] = []
        model.onChange = { seen.append(model.localNetworkStatus) }

        net.outcome = .undecided                  // the rescan sees nothing
        await model.refreshStatuses()             // ← the app-activation path
        #expect(model.localNetworkStatus == .granted)
        #expect(model.localNetworkFoundSpeakers == 3, "a speaker switched off is not a permission event")

        _ = await model.auditRequiredPermissions() // ← the wake/reactivate audit
        #expect(model.localNetworkStatus == .granted)
        #expect(!model.unmetRequiredPermissions().contains(.localNetwork))
        #expect(!model.requiredPermissionsNotGranted().contains(.localNetwork))

        #expect(!seen.contains(.requested),
                "not even an intermediate repaint may show the grant as lost")
    }

    /// The one signal that DOES take it back. A revocation in System Settings
    /// reaches the browse as the mDNS policy error, and that is a real denial.
    @Test func aRefusalStillRevokesAProvedGrant() async {
        let net = SwitchableLocalNetwork(.granted(foundSpeakers: 2))
        let model = SetupModel(audioProbe: CannedAudioProbe(result: .granted),
                               localNetwork: net,
                               remoteControl: SpyRemoteControl(),
                               ptpHelper: FakePTPHelper(),
                               settings: AppSettings(defaults: defaults))
        await model.primeLocalNetwork()

        net.outcome = .denied
        await model.refreshStatuses()

        #expect(model.localNetworkStatus == .denied)
        #expect(model.localNetworkFoundSpeakers == 0)
        #expect(model.unmetRequiredPermissions().contains(.localNetwork))
    }

    /// Publishing the self-discovery service opens a listening socket, which the
    /// macOS application firewall can ask about. It belongs to the ASK; a
    /// permission already proved needs no second proof, so its rescans browse
    /// and nothing more.
    @Test func onlyAnUnprovedLocalNetworkPublishesTheSelfDiscoveryService() async {
        let (model, spy, _, _) = makeModel(audio: .granted)
        spy.reachable = true

        await model.primeLocalNetwork()            // the first ask — publish
        #expect(model.localNetworkStatus == .granted)
        await model.refreshStatuses()              // a rescan of a proved grant
        _ = await model.auditRequiredPermissions()

        #expect(spy.selfDiscoveryFlags == [true, false, false])
    }

    @Test func auditRequiredPermissionsSilentlyRereadsPTPHelperStatus() async {
        let ptpHelper = FakePTPHelper()
        ptpHelper.status = .requiresApproval
        // The wake nag is for a REGRESSION, so the helper has to have been on
        // once for `.requiresApproval` to count as one.
        AppSettings(defaults: defaults).speakerSyncWasEnabled = true
        let model = SetupModel(audioProbe: SilentAudioProbe(silentResult: .granted),
                               localNetwork: SpyLocalNetwork(),
                               remoteControl: SpyRemoteControl(),
                               ptpHelper: ptpHelper,
                               settings: AppSettings(defaults: defaults))
        let unmet = await model.auditRequiredPermissions()
        #expect(model.ptpHelperStatus == .requiresApproval)
        #expect(ptpHelper.registerCount == 0, "audit never registers")
        #expect(unmet.contains(.ptpHelper))
    }

    /// The window-open audits TRUST a proven, sticky grant: the trust flag
    /// skips the ~3 s Local Network re-browse whose invisible cost behind the
    /// CTA click was the live "Start listening took two clicks" (v7 — a 3.2 s
    /// verification the second click was correctly swallowed inside). The
    /// default keeps the browse: the wake audit is the app's only Local
    /// Network revocation detector.
    @Test func auditSkipsTheLocalNetworkBrowseOnlyWhenTrustingAProvenGrant() async {
        let spy = SpyLocalNetwork()
        spy.reachable = true
        let (model, _, _, _) = makeModel(audio: .granted, localNetwork: spy)
        await model.primeLocalNetwork()
        #expect(model.localNetworkStatus == .granted)
        let browsesAfterPrime = spy.probeCount

        _ = await model.auditRequiredPermissions(trustingProvenLocalNetworkGrant: true)

        #expect(spy.probeCount == browsesAfterPrime, "a proven grant is trusted — no re-browse")
        #expect(model.localNetworkStatus == .granted)

        _ = await model.auditRequiredPermissions()

        #expect(spy.probeCount == browsesAfterPrime + 1, "the default audit still re-browses")
    }

    /// The trust flag only covers a PROVEN grant: any other engaged status
    /// still browses — a denial's audit must stay able to observe the user
    /// re-allowing it (and vice versa).
    @Test func aTrustingAuditStillBrowsesAnUnprovenLocalNetwork() async {
        let spy = SpyLocalNetwork()   // not reachable ⇒ `.requested`
        let (model, _, _, _) = makeModel(audio: .granted, localNetwork: spy)
        await model.primeLocalNetwork()
        #expect(model.localNetworkStatus == .requested)
        let browsesAfterPrime = spy.probeCount

        _ = await model.auditRequiredPermissions(trustingProvenLocalNetworkGrant: true)

        #expect(spy.probeCount == browsesAfterPrime + 1,
                "only a proven grant is trusted — an unproven status re-browses")
    }

    @Test func auditRequiredPermissionsFiresOnChangeOnlyWhenSomethingChanged() async {
        let ptpHelper = FakePTPHelper()
        let model = SetupModel(audioProbe: SilentAudioProbe(silentResult: nil),
                               localNetwork: SpyLocalNetwork(),
                               remoteControl: SpyRemoteControl(),
                               ptpHelper: ptpHelper,
                               settings: AppSettings(defaults: defaults))
        let counter = ChangeCounter()
        model.onChange = { counter.count += 1 }
        _ = await model.auditRequiredPermissions()
        #expect(counter.count == 0, "nothing changed (nil silent read, unengaged network, unchanged PTP) ⇒ silent")
    }

    // MARK: Telemetry (T5) — permission reported-vs-actual divergence

    /// Captures lines from an installed `Telemetry` test sink. The sink is a
    /// `@Sendable` closure invoked from `Telemetry`'s own serial writer queue
    /// (a different thread than the test body), so a plain captured `var`
    /// won't do — this mirrors `TelemetryTests`' own NSLock-guarded `Locked`
    /// box, the sanctioned pattern for reading back what was logged.
    private final class TelemetryLineCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) { lock.withLock { lines.append(line) } }
        func snapshot() -> [String] { lock.withLock { lines } }
    }

    /// Tonight's exact bug shape: the stored/UI-visible status says `.granted`
    /// (set here by an earlier successful `requestAudioCapture()`, exactly
    /// like a completed onboarding flow), but the live silent re-check
    /// disagrees (`.denied` — revoked since, or never really live).
    /// `auditRequiredPermissions()` is the reconciliation path that re-checks
    /// audio UNCONDITIONALLY, regardless of the current cached status (unlike
    /// `refreshStatuses()`, which only re-checks an already-`.denied`/
    /// `.requested` row — see its doc comment), so it's the path that
    /// actually catches a granted→revoked flip. This asserts the emitted
    /// `permission`/`reported_vs_actual` line makes that divergence legible
    /// on its own, without needing to also read the source to interpret it.
    @Test func auditRequiredPermissionsLogsReportedVsActualDivergence() async throws {
        let silentAudio = SilentAudioProbe(probeResult: .granted, silentResult: .denied)
        let model = SetupModel(audioProbe: silentAudio,
                               localNetwork: SpyLocalNetwork(),
                               remoteControl: SpyRemoteControl(),
                               ptpHelper: FakePTPHelper(),
                               settings: AppSettings(defaults: defaults))
        await model.requestAudioCapture()   // → .granted: the "reported"/UI-visible status
        #expect(model.audioStatus == .granted)

        let capture = TelemetryLineCapture()
        Telemetry._installTestSink { capture.append($0) }
        _ = await model.auditRequiredPermissions()
        Telemetry._installTestSink(nil)   // flush barrier (serial queue) + removes the sink

        #expect(model.audioStatus == .denied,
                       "the silent read must win — this is the actual regression, not just the log")

        let line = try #require(
            capture.snapshot().first { $0.contains("\"evt\":\"reported_vs_actual\"") },
            "expected a permission/reported_vs_actual line")
        #expect(line.contains("\"cat\":\"permission\""), "line: \(line)")
        #expect(line.contains("\"site\":\"SetupModel.auditRequiredPermissions\""), "line: \(line)")
        #expect(line.contains("\"reported\":\"granted\""), "line: \(line)")
        #expect(line.contains("\"silent\":\"denied\""), "line: \(line)")
        #expect(line.contains("\"diverged\":\"true\""), "line: \(line)")
    }

    /// The companion case: reported and silent AGREE (both `.granted`). This
    /// guards the `diverged` field itself — without it, a hard-coded
    /// `"diverged":"true"` would pass the divergence test above too.
    @Test func auditRequiredPermissionsLogsNonDivergenceWhenStatusesAgree() async throws {
        let silentAudio = SilentAudioProbe(probeResult: .granted, silentResult: .granted)
        let model = SetupModel(audioProbe: silentAudio,
                               localNetwork: SpyLocalNetwork(),
                               remoteControl: SpyRemoteControl(),
                               ptpHelper: FakePTPHelper(),
                               settings: AppSettings(defaults: defaults))
        await model.requestAudioCapture()   // → .granted
        #expect(model.audioStatus == .granted)

        let capture = TelemetryLineCapture()
        Telemetry._installTestSink { capture.append($0) }
        _ = await model.auditRequiredPermissions()
        Telemetry._installTestSink(nil)

        #expect(model.audioStatus == .granted, "no divergence ⇒ no change")

        let line = try #require(
            capture.snapshot().first { $0.contains("\"evt\":\"reported_vs_actual\"") },
            "expected a permission/reported_vs_actual line even when statuses agree")
        #expect(line.contains("\"reported\":\"granted\""), "line: \(line)")
        #expect(line.contains("\"silent\":\"granted\""), "line: \(line)")
        #expect(line.contains("\"diverged\":\"false\""), "line: \(line)")
    }

    // MARK: System Settings deep links

    /// Below macOS 26 the anchors hang off the old Privacy & Security pane id.
    /// Driven through the explicit-version seam, not the live one: a unit test
    /// can't change the runner's OS, and both branches ship.
    @Test func systemSettingsPaneURLsBeforeMacOS26() {
        #expect(
            SystemSettingsPane.screenAndSystemAudioRecording.url(osMajorVersion: 15).absoluteString ==
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        #expect(
            SystemSettingsPane.localNetwork.url(osMajorVersion: 15).absoluteString ==
            "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")
        #expect(
            SystemSettingsPane.accessibility.url(osMajorVersion: 15).absoluteString ==
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        #expect(
            SystemSettingsPane.privacyRoot(osMajorVersion: 15).absoluteString ==
            "x-apple.systempreferences:com.apple.preference.security")
    }

    /// macOS 26 moved Privacy & Security into an extension bundle. The `Privacy_*`
    /// ANCHORS are unchanged — only the pane id — and the old id misroutes there,
    /// so the gate has to flip for every anchor including the root fallback.
    @Test func systemSettingsPaneURLsOnMacOS26AndLater() {
        let expected = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
        #expect(
            SystemSettingsPane.screenAndSystemAudioRecording.url(osMajorVersion: 26).absoluteString ==
            "\(expected)?Privacy_ScreenCapture")
        #expect(
            SystemSettingsPane.localNetwork.url(osMajorVersion: 26).absoluteString ==
            "\(expected)?Privacy_LocalNetwork")
        #expect(
            SystemSettingsPane.accessibility.url(osMajorVersion: 26).absoluteString ==
            "\(expected)?Privacy_Accessibility")
        #expect(
            SystemSettingsPane.bluetoothPrivacy.url(osMajorVersion: 26).absoluteString ==
            "\(expected)?Privacy_Bluetooth")
        #expect(
            SystemSettingsPane.privacyRoot(osMajorVersion: 26).absoluteString == expected)
    }

    /// The Bluetooth radio pane is its own bundle id, so the Privacy rename
    /// leaves it alone on both sides of the boundary.
    @Test func theBluetoothRadioPaneIsUnaffectedByThePrivacyRename() {
        #expect(
            SystemSettingsPane.bluetooth.url(osMajorVersion: 15).absoluteString ==
            "x-apple.systempreferences:com.apple.BluetoothSettings")
        #expect(
            SystemSettingsPane.bluetooth.url(osMajorVersion: 26).absoluteString ==
            "x-apple.systempreferences:com.apple.BluetoothSettings")
    }

    /// The Bluetooth CARD's retry destination is the Privacy pane (where this
    /// app's grant is toggled), NOT `SystemSettingsPane.bluetooth`, which is the
    /// radio's own pane and can't fix a denied grant.
    @Test func bluetoothPrivacyPaneIsThePrivacyAnchorNotTheRadioPane() {
        #expect(
            SystemSettingsPane.bluetoothPrivacy.url(osMajorVersion: 15).absoluteString ==
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")
        #expect(
            SystemSettingsPane.bluetooth.url(osMajorVersion: 15).absoluteString ==
            "x-apple.systempreferences:com.apple.BluetoothSettings")
    }

    // MARK: Local Network found count

    /// The count is the Local Network card's proof, so it has to survive the trip
    /// from the browse to the model — and `.granted` on a gated OS means exactly
    /// "the browse saw at least one speaker".
    @Test func primingLocalNetworkRecordsHowManySpeakersTheBrowseSaw() async {
        let model = SetupModel(audioProbe: CannedAudioProbe(result: .granted),
                               localNetwork: CountingLocalNetwork(found: 3),
                               remoteControl: SpyRemoteControl(),
                               ptpHelper: FakePTPHelper(),
                               settings: AppSettings(defaults: defaults))
        #expect(model.localNetworkFoundSpeakers == 0, "nothing has browsed yet")

        await model.primeLocalNetwork()

        #expect(model.localNetworkFoundSpeakers == 3)
        #expect(model.localNetworkStatus == .granted)
    }

    /// A browse that found nothing is NOT a denial — there is no status API to
    /// tell them apart — so it stays `.requested` with a count of zero.
    @Test func aBrowseThatFindsNothingLeavesTheCountAtZeroAndTheStatusUnproven() async {
        let model = SetupModel(audioProbe: CannedAudioProbe(result: .granted),
                               localNetwork: CountingLocalNetwork(found: 0),
                               remoteControl: SpyRemoteControl(),
                               ptpHelper: FakePTPHelper(),
                               settings: AppSettings(defaults: defaults))
        await model.primeLocalNetwork()

        #expect(model.localNetworkFoundSpeakers == 0)
        #expect(model.localNetworkStatus == .requested)
    }

    /// A seam that only implements the Bool answer still has to satisfy
    /// `count > 0 ⇔ probe()`, so every existing fake keeps working.
    @Test func aBoolOnlySeamReportsOneSpeakerForReachable() async {
        let reachable = SpyLocalNetwork()
        reachable.reachable = true
        #expect(await reachable.probeFoundSpeakers() == 1)
        #expect(await SpyLocalNetwork().probeFoundSpeakers() == 0)
    }
    }
}
