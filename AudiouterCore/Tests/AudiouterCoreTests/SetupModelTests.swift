// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudiouterCore

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

    private var suiteName: String
    private var defaults: UserDefaults!

    init() {
        suiteName = "AudioControlSetupTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }

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
    /// (which is what produced the dead-end "Open Settings" → nonexistent pane).
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

    @Test func refreshPTPHelperStatusPicksUpApprovalWithoutReregistering() {
        // The poll while `.requiresApproval` waits for the user to flip Login
        // Items — it must re-read `.status`, never call `register()` again.
        let ptpHelper = FakePTPHelper()
        ptpHelper.statusAfterRegister = .requiresApproval
        let (model, _, _, _) = makeModel(audio: .granted, ptpHelper: ptpHelper)
        model.registerPTPHelper()
        #expect(model.ptpHelperStatus == .requiresApproval)

        ptpHelper.status = .enabled   // user approved it in Login Items
        model.refreshPTPHelperStatus()

        #expect(model.ptpHelperStatus == .enabled, "enabled → available")
        #expect(ptpHelper.registerCount == 1, "poll never re-registers")
    }

    @Test func refreshPTPHelperStatusIsQuietWhenUnchanged() {
        let ptpHelper = FakePTPHelper()
        let (model, _, _, counter) = makeModel(audio: .granted, ptpHelper: ptpHelper)
        counter.count = 0
        model.refreshPTPHelperStatus()
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
        // A refresh on a fresh screen (all unknown) must not probe audio or the
        // network — probing either would spring a system prompt the user hasn't
        // engaged. Only the silent Accessibility read runs.
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
        // Setup is guidance, not a gate: completing while a permission is still
        // denied/unknown still persists completion (the app runs and re-prompts
        // lazily).
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
        let fresh = AppSettings(defaults: UserDefaults(suiteName: "\(suiteName).fresh")!)
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

    @Test func unmetRequiredPermissionsFlagsRequiresApprovalPTPHelper() {
        let ptpHelper = FakePTPHelper()
        ptpHelper.statusAfterRegister = .requiresApproval
        let (model, _, _, _) = makeModel(audio: .granted, ptpHelper: ptpHelper)
        model.registerPTPHelper()
        #expect(model.unmetRequiredPermissions() == [.ptpHelper])
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
        ptpHelper.statusAfterRegister = .notFound
        let (model, net, _, _) = makeModel(audio: .denied, ptpHelper: ptpHelper)
        await model.requestAudioCapture()            // → .denied
        net.reachable = false
        await model.primeLocalNetwork()              // → .requested
        model.registerPTPHelper()                     // → .notFound
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

        // Now engage it, then revoke it — the audit re-probes because it's no
        // longer `.unknown`.
        net.reachable = true
        await model.primeLocalNetwork()
        #expect(model.localNetworkStatus == .granted)
        net.reachable = false
        let unmet = await model.auditRequiredPermissions()
        #expect(model.localNetworkStatus == .requested)
        #expect(unmet.contains(.localNetwork))
    }

    @Test func auditRequiredPermissionsSilentlyRereadsPTPHelperStatus() async {
        let ptpHelper = FakePTPHelper()
        ptpHelper.status = .requiresApproval
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

    @Test func systemSettingsPaneURLs() {
        #expect(
            SystemSettingsPane.screenAndSystemAudioRecording.url.absoluteString ==
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        #expect(
            SystemSettingsPane.localNetwork.url.absoluteString ==
            "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")
        #expect(
            SystemSettingsPane.accessibility.url.absoluteString ==
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        #expect(
            SystemSettingsPane.privacyRoot.absoluteString ==
            "x-apple.systempreferences:com.apple.preference.security")
    }
    }
}
