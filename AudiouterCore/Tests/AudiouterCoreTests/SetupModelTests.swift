// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import AudiouterCore

/// `SetupModel` is the AppKit-free brain of the first-run flow. All three system
/// seams (audio-capture probe, local-network primer, remote-control primer) are
/// injected, so these run hermetically — no Core Audio, no real prompt. They pin
/// the status transitions, the `onChange` notifications, persistence of
/// completion, the launch gate, and the System Settings deep-link URLs.
@MainActor
final class SetupModelTests: XCTestCase {

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
        /// What `.status` reports after `register()` (default: requires approval,
        /// the expected first-run outcome once registration succeeds).
        var statusAfterRegister: PTPHelperStatus = .requiresApproval
        /// What `register()` throws, if anything (default: succeeds).
        var registerError: Error?
        /// What `.status` reports BEFORE `register()` has been called.
        var status: PTPHelperStatus = .notRegistered
        var registerCount: Int { lock.withLock { _registerCount } }
        var openSettingsCount: Int { lock.withLock { _openSettingsCount } }

        func register() throws {
            lock.withLock { _registerCount += 1 }
            if let registerError { throw registerError }
            status = statusAfterRegister
        }
        func openSystemSettingsLoginItems() { lock.withLock { _openSettingsCount += 1 } }
    }

    /// Counts `onChange` fires (reference type so the escaping closure mutates it).
    private final class ChangeCounter { var count = 0 }

    // MARK: Helpers

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "AudioControlSetupTests.\(name).\(ObjectIdentifier(self).hashValue)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
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

    func testInitialStatusesAreUnknown() {
        let (model, _, _, _) = makeModel(audio: .granted)
        XCTAssertEqual(model.audioStatus, .unknown)
        XCTAssertEqual(model.localNetworkStatus, .unknown)
        XCTAssertEqual(model.remoteControlStatus, .unknown)
        XCTAssertFalseModelProbing(model)
    }

    private func XCTAssertFalseModelProbing(_ model: SetupModel) {
        XCTAssertFalse(model.isProbingAudio)
    }

    // MARK: Audio probe transitions

    func testAudioProbeGranted() async {
        let (model, _, _, counter) = makeModel(audio: .granted)
        await model.requestAudioCapture()
        XCTAssertEqual(model.audioStatus, .granted)
        XCTAssertFalse(model.isProbingAudio)
        // Two notifications: one entering the probe (progress), one on result.
        XCTAssertEqual(counter.count, 2)
    }

    func testAudioProbeDenied() async {
        let (model, _, _, _) = makeModel(audio: .denied)
        await model.requestAudioCapture()
        XCTAssertEqual(model.audioStatus, .denied)
    }

    func testAudioProbeUnsupported() async {
        let (model, _, _, _) = makeModel(audio: .unsupported)
        await model.requestAudioCapture()
        XCTAssertEqual(model.audioStatus, .unsupported)
    }

    func testAudioProbeCanBeRetriedAfterCompletion() async {
        // A denied first pass followed by a granted retry (user granted in the
        // gap) must land on the retry's result — the flow is re-runnable.
        let denyThenAllow = FlippingAudioProbe(sequence: [.denied, .granted])
        let model = SetupModel(audioProbe: denyThenAllow,
                               localNetwork: SpyLocalNetwork(),
                               remoteControl: SpyRemoteControl(),
                               ptpHelper: FakePTPHelper(),
                               settings: AppSettings(defaults: defaults))
        await model.requestAudioCapture()
        XCTAssertEqual(model.audioStatus, .denied)
        await model.requestAudioCapture()
        XCTAssertEqual(model.audioStatus, .granted)
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

    func testPrimeLocalNetworkUnreachableStaysRequested() async {
        let (model, spy, _, _) = makeModel(audio: .granted)
        spy.reachable = false
        await model.primeLocalNetwork()
        XCTAssertEqual(spy.probeCount, 1)
        XCTAssertEqual(model.localNetworkStatus, .requested,
                       "browse got nowhere ⇒ asked-but-unproven")
    }

    func testPrimeLocalNetworkReachableBecomesGranted() async {
        // The case ahh hit: it's actually working, so we must NOT lie with a
        // sticky "Requested" — a browse that reaches the network proves the grant.
        let (model, spy, _, _) = makeModel(audio: .granted)
        spy.reachable = true
        await model.primeLocalNetwork()
        XCTAssertEqual(model.localNetworkStatus, .granted)
    }

    // MARK: Remote control (Accessibility — real, silent status API)

    func testPrimeRemoteControlReadsRealTrustState() {
        let (model, _, spy, _) = makeModel(audio: .granted)
        spy.trusted = true
        model.primeRemoteControl()
        XCTAssertEqual(spy.primeCount, 1)
        XCTAssertEqual(model.remoteControlStatus, .granted,
                       "already trusted ⇒ granted, not a sticky requested")
    }

    func testPrimeRemoteControlUntrustedStaysRequested() {
        let (model, _, spy, _) = makeModel(audio: .granted)
        spy.trusted = false
        model.primeRemoteControl()
        XCTAssertEqual(model.remoteControlStatus, .requested)
    }

    // MARK: PTP helper daemon (T6 — SMAppService registration + approval)

    func testInitialPTPHelperStatusIsNotRegistered() {
        let (model, _, _, _) = makeModel(audio: .granted)
        XCTAssertEqual(model.ptpHelperStatus, .notRegistered)
    }

    func testRegisterPTPHelperCallsRegisterAndAdoptsRequiresApproval() {
        let ptpHelper = FakePTPHelper()
        ptpHelper.statusAfterRegister = .requiresApproval
        let (model, _, _, counter) = makeModel(audio: .granted, ptpHelper: ptpHelper)

        model.registerPTPHelper()

        XCTAssertEqual(ptpHelper.registerCount, 1)
        XCTAssertEqual(model.ptpHelperStatus, .requiresApproval,
                       "requiresApproval → the explainer + Open Login Items… button")
        XCTAssertEqual(counter.count, 1)
    }

    func testRegisterPTPHelperCanReachEnabledDirectly() {
        // Covers the injected-fake path for "enabled → available": a fake that
        // reports already-approved right after register() (as a real daemon
        // would on a signed build once the user had already approved it once).
        let ptpHelper = FakePTPHelper()
        ptpHelper.statusAfterRegister = .enabled
        let (model, _, _, _) = makeModel(audio: .granted, ptpHelper: ptpHelper)

        model.registerPTPHelper()

        XCTAssertEqual(model.ptpHelperStatus, .enabled)
    }

    func testRegisterPTPHelperFailureLogsAndReadsRealStatus() {
        // A throwing register() (e.g. a loose dev binary) must not crash or lie —
        // it still reads back whatever `.status` really is afterward.
        struct Boom: Error {}
        let ptpHelper = FakePTPHelper()
        ptpHelper.registerError = Boom()
        ptpHelper.status = .notFound
        let (model, _, _, _) = makeModel(audio: .granted, ptpHelper: ptpHelper)

        model.registerPTPHelper()

        XCTAssertEqual(ptpHelper.registerCount, 1)
        XCTAssertEqual(model.ptpHelperStatus, .notFound)
    }

    func testOpenPTPHelperLoginItemsDelegatesToTheSeam() {
        let ptpHelper = FakePTPHelper()
        let (model, _, _, _) = makeModel(audio: .granted, ptpHelper: ptpHelper)
        model.openPTPHelperLoginItems()
        XCTAssertEqual(ptpHelper.openSettingsCount, 1)
    }

    func testRefreshPTPHelperStatusPicksUpApprovalWithoutReregistering() {
        // The poll while `.requiresApproval` waits for the user to flip Login
        // Items — it must re-read `.status`, never call `register()` again.
        let ptpHelper = FakePTPHelper()
        ptpHelper.statusAfterRegister = .requiresApproval
        let (model, _, _, _) = makeModel(audio: .granted, ptpHelper: ptpHelper)
        model.registerPTPHelper()
        XCTAssertEqual(model.ptpHelperStatus, .requiresApproval)

        ptpHelper.status = .enabled   // user approved it in Login Items
        model.refreshPTPHelperStatus()

        XCTAssertEqual(model.ptpHelperStatus, .enabled, "enabled → available")
        XCTAssertEqual(ptpHelper.registerCount, 1, "poll never re-registers")
    }

    func testRefreshPTPHelperStatusIsQuietWhenUnchanged() {
        let ptpHelper = FakePTPHelper()
        let (model, _, _, counter) = makeModel(audio: .granted, ptpHelper: ptpHelper)
        counter.count = 0
        model.refreshPTPHelperStatus()
        XCTAssertEqual(counter.count, 0, "no transition ⇒ no onChange noise")
    }

    func testRefreshStatusesSilentlyRereadsPTPHelperStatus() async {
        // `refreshStatuses()` (window-focus path) must ALSO pick up the PTP
        // helper's live status, without touching `register()`.
        let ptpHelper = FakePTPHelper()
        ptpHelper.status = .requiresApproval
        let (model, _, _, _) = makeModel(audio: .granted, ptpHelper: ptpHelper)
        await model.refreshStatuses()
        XCTAssertEqual(model.ptpHelperStatus, .requiresApproval)

        ptpHelper.status = .enabled
        await model.refreshStatuses()
        XCTAssertEqual(model.ptpHelperStatus, .enabled)
        XCTAssertEqual(ptpHelper.registerCount, 0, "refreshStatuses never registers")
    }

    // MARK: Live status refresh (reflect reality on window focus)

    func testRefreshUpgradesRemoteControlWhenGrantedInSettings() async {
        // User was untrusted, went to System Settings, toggled it on, came back.
        let (model, _, remote, _) = makeModel(audio: .unknown)
        remote.trusted = false
        model.primeRemoteControl()
        XCTAssertEqual(model.remoteControlStatus, .requested)
        remote.trusted = true                 // flipped it on in Settings
        await model.refreshStatuses()
        XCTAssertEqual(model.remoteControlStatus, .granted)
    }

    func testRefreshDowngradesRemoteControlWhenRevoked() async {
        let (model, _, remote, _) = makeModel(audio: .unknown)
        remote.trusted = true
        await model.refreshStatuses()
        XCTAssertEqual(model.remoteControlStatus, .granted)
        remote.trusted = false                // revoked in Settings
        await model.refreshStatuses()
        XCTAssertEqual(model.remoteControlStatus, .requested)
    }

    func testRefreshNeverPromptsUntouchedRows() async {
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
        XCTAssertEqual(audio.probeCount, 0, "audio not re-probed while unknown")
        XCTAssertEqual(net.probeCount, 0, "network not browsed while unknown")
    }

    func testRefreshReprobesAlreadyAskedNetwork() async {
        // Once the network row has been engaged, a refresh re-checks it — catching
        // the case where the browse first got nowhere (requested) but the network
        // is reachable on the next look (e.g. the user just answered the prompt).
        let (model, net, _, _) = makeModel(audio: .granted)
        net.reachable = false
        await model.primeLocalNetwork()          // → requested
        XCTAssertEqual(model.localNetworkStatus, .requested)
        net.reachable = true                      // reachable now
        await model.refreshStatuses()
        XCTAssertEqual(model.localNetworkStatus, .granted)
        XCTAssertGreaterThanOrEqual(net.probeCount, 2)
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

    func testCompletePersistsFlag() {
        let (model, _, _, _) = makeModel(audio: .granted)
        XCTAssertFalse(AppSettings(defaults: defaults).hasCompletedSetup)
        model.complete()
        XCTAssertTrue(AppSettings(defaults: defaults).hasCompletedSetup)
    }

    func testCompleteDoesNotRequireGrants() {
        // Setup is guidance, not a gate: completing while a permission is still
        // denied/unknown still persists completion (the app runs and re-prompts
        // lazily).
        let (model, _, _, _) = makeModel(audio: .denied)
        model.complete()
        XCTAssertTrue(AppSettings(defaults: defaults).hasCompletedSetup)
    }

    // MARK: Launch gate

    func testShouldPresentOnlyForNativeAndOnlyUntilCompleted() {
        let settings = AppSettings(defaults: defaults)
        let env: [String: String] = [:]   // no override — exercise the default gate

        // Native + not completed → present.
        XCTAssertTrue(SetupModel.shouldPresentOnLaunch(settings: settings, backendKind: .native, environment: env))

        // Non-native backends never present, regardless of completion — they
        // don't tap in-process or discover under the app's own identity.
        XCTAssertFalse(SetupModel.shouldPresentOnLaunch(settings: settings, backendKind: .mock, environment: env))
        XCTAssertFalse(SetupModel.shouldPresentOnLaunch(settings: settings, backendKind: .ownTone, environment: env))

        // Once completed, even native stops presenting.
        settings.hasCompletedSetup = true
        XCTAssertFalse(SetupModel.shouldPresentOnLaunch(settings: settings, backendKind: .native, environment: env))
    }

    func testAirplaySetupEnvOverridesTheGate() {
        let settings = AppSettings(defaults: defaults)
        settings.hasCompletedSetup = true   // default gate would say "hide"

        // skip → never present (the testing default), even native + not completed.
        let fresh = AppSettings(defaults: UserDefaults(suiteName: "\(suiteName!).fresh")!)
        for skip in ["skip", "off", "never", "0"] {
            XCTAssertFalse(SetupModel.shouldPresentOnLaunch(
                settings: fresh, backendKind: .native,
                environment: [SetupPresentation.environmentVariableName: skip]), "\(skip) should hide")
        }

        // force → always present, ignoring completed AND non-native backend.
        for show in ["force", "always", "1"] {
            XCTAssertTrue(SetupModel.shouldPresentOnLaunch(
                settings: settings, backendKind: .mock,
                environment: [SetupPresentation.environmentVariableName: show]), "\(show) should force-show")
        }

        // Unrecognized value → auto (falls through to the default gate).
        XCTAssertFalse(SetupModel.shouldPresentOnLaunch(
            settings: settings, backendKind: .native,
            environment: [SetupPresentation.environmentVariableName: "banana"]),
            "unrecognized value falls back to the default gate (completed ⇒ hide)")
    }

    // MARK: System Settings deep links

    func testSystemSettingsPaneURLs() {
        XCTAssertEqual(
            SystemSettingsPane.screenAndSystemAudioRecording.url.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        XCTAssertEqual(
            SystemSettingsPane.localNetwork.url.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")
        XCTAssertEqual(
            SystemSettingsPane.accessibility.url.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        XCTAssertEqual(
            SystemSettingsPane.privacyRoot.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security")
    }
}
