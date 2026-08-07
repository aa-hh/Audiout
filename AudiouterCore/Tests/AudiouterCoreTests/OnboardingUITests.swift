// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import Foundation
import Testing
@testable import AudiouterCore
@testable import AudiouterOnboardingUI

/// Structure + behavior of the onboarding UI, driven through the real
/// `OnboardingViewController` / `OnboardingWindowController` against fake
/// permission seams (no Core Audio, no network). The window isn't visible to a
/// headless test, so these assert via the `test_` hooks — the same approach the
/// popover/settings UI tests use.
@MainActor
@Suite final class OnboardingUITests {

    private struct CannedAudioProbe: AudioCapturePermissionProbing {
        let result: PermissionStatus
        func probe() async -> PermissionStatus { result }
    }
    private struct NoopLocalNetwork: LocalNetworkPriming {
        func probe() async -> Bool { false }
    }
    private struct NoopRemoteControl: RemoteControlPriming {
        func prime() {}
        func isTrusted() -> Bool { false }
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

    private var suiteName: String
    private var defaults: UserDefaults!

    init() {
        suiteName = "OnboardingUITests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeModel(audio: PermissionStatus,
                           ptpHelper: PTPHelperManaging = FakePTPHelper()) -> SetupModel {
        SetupModel(audioProbe: CannedAudioProbe(result: audio),
                   localNetwork: NoopLocalNetwork(),
                   remoteControl: NoopRemoteControl(),
                   ptpHelper: ptpHelper,
                   settings: AppSettings(defaults: defaults))
    }

    // MARK: View controller structure

    @Test func initialRowsOfferAllow() {
        let vc = OnboardingViewController(model: makeModel(audio: .granted),
                                          onOpenSettings: { _ in }, onDone: {})
        #expect(vc.test_audioRowButtonTitles == ["Allow…"])
        #expect(vc.test_networkRowButtonTitles == ["Allow…"])
        #expect(vc.test_remoteControlRowButtonTitles == ["Allow…"])
    }

    @Test func grantingAudioReplacesButtonWithAllowedStatus() async {
        let vc = OnboardingViewController(model: makeModel(audio: .granted),
                                          onOpenSettings: { _ in }, onDone: {})
        await vc.test_allowAudio()
        // Granted shows a status chip, no button.
        #expect(vc.test_audioRowButtonTitles == [])
        #expect(vc.test_audioRow.lastStatus == .granted)
    }

    @Test func deniedAudioOffersOpenSettings() {
        let vc = OnboardingViewController(model: makeModel(audio: .denied),
                                          onOpenSettings: { _ in }, onDone: {})
        vc.test_applyStatuses(audio: .denied, isProbingAudio: false, network: .unknown,
                              remoteControl: .unknown)
        #expect(vc.test_audioRowButtonTitles == ["Open Settings"])
    }

    @Test func primingNetworkShowsRequestedAndOpenSettings() async {
        // NoopLocalNetwork reports unreachable, so priming lands on .requested.
        let vc = OnboardingViewController(model: makeModel(audio: .granted),
                                          onOpenSettings: { _ in }, onDone: {})
        await vc.test_allowNetwork()
        #expect(vc.test_networkRow.lastStatus == .requested)
        #expect(vc.test_networkRowButtonTitles == ["Open Settings"])
    }

    @Test func primingRemoteControlShowsRequestedAndOpenSettings() {
        let vc = OnboardingViewController(model: makeModel(audio: .granted),
                                          onOpenSettings: { _ in }, onDone: {})
        vc.test_allowRemoteControl()
        #expect(vc.test_remoteControlRow.lastStatus == .requested)
        #expect(vc.test_remoteControlRowButtonTitles == ["Open Settings"])
    }

    // MARK: Deep-link routing

    @Test func openSettingsRoutesCorrectPanePerRow() {
        var opened: [SystemSettingsPane] = []
        let vc = OnboardingViewController(model: makeModel(audio: .denied),
                                          onOpenSettings: { opened.append($0) }, onDone: {})
        vc.test_applyStatuses(audio: .denied, isProbingAudio: false, network: .requested,
                              remoteControl: .requested)

        vc.test_audioRow.test_tapOpenSettings()
        vc.test_networkRow.test_tapOpenSettings()
        vc.test_remoteControlRow.test_tapOpenSettings()

        // Audio + Local Network deep-link to their panes. Remote Control does NOT —
        // its "Open Settings" re-fires the macOS Accessibility prompt (whose own
        // button highlights the app), so it never routes through the deep-link opener.
        #expect(opened == [.screenAndSystemAudioRecording, .localNetwork])
    }

    // MARK: Probing state

    @Test func unsupportedAudioShowsNoButton() {
        let vc = OnboardingViewController(model: makeModel(audio: .unsupported),
                                          onOpenSettings: { _ in }, onDone: {})
        vc.test_applyStatuses(audio: .unsupported, isProbingAudio: false, network: .unknown,
                              remoteControl: .unknown)
        // Unsupported is not a user-fixable state — no button, just a message.
        #expect(vc.test_audioRowButtonTitles == [])
    }

    // MARK: PTP helper row (T6)

    @Test func notRegisteredShowsNoButton() {
        let vc = OnboardingViewController(model: makeModel(audio: .granted, ptpHelper: FakePTPHelper(status: .notRegistered)),
                                          onOpenSettings: { _ in }, onDone: {})
        vc.test_applyStatuses(audio: .granted, isProbingAudio: false, network: .unknown,
                              remoteControl: .unknown, ptpHelper: .notRegistered)
        #expect(vc.test_ptpHelperRow.lastStatus == .notRegistered)
        #expect(vc.test_ptpHelperRowButtonTitles == [],
                       "notRegistered: registration is automatic, nothing to tap")
    }

    @Test func requiresApprovalShowsTheExplainerAndOpenLoginItemsButton() {
        // requiresApproval → the explainer row is showing, with the deep-link
        // button that opens Login Items.
        let vc = OnboardingViewController(model: makeModel(audio: .granted, ptpHelper: FakePTPHelper(status: .requiresApproval)),
                                          onOpenSettings: { _ in }, onDone: {})
        vc.test_applyStatuses(audio: .granted, isProbingAudio: false, network: .unknown,
                              remoteControl: .unknown, ptpHelper: .requiresApproval)
        #expect(vc.test_ptpHelperRow.lastStatus == .requiresApproval)
        #expect(vc.test_ptpHelperRowButtonTitles == ["Open Login Items…"])
    }

    @Test func enabledShowsNoButtonAndIsAvailable() {
        // enabled → available: a plain "Enabled" chip, no button.
        let vc = OnboardingViewController(model: makeModel(audio: .granted, ptpHelper: FakePTPHelper(status: .enabled)),
                                          onOpenSettings: { _ in }, onDone: {})
        vc.test_applyStatuses(audio: .granted, isProbingAudio: false, network: .unknown,
                              remoteControl: .unknown, ptpHelper: .enabled)
        #expect(vc.test_ptpHelperRow.lastStatus == .enabled)
        #expect(vc.test_ptpHelperRowButtonTitles == [])
    }

    @Test func notFoundShowsNoButton() {
        let vc = OnboardingViewController(model: makeModel(audio: .granted, ptpHelper: FakePTPHelper(status: .notFound)),
                                          onOpenSettings: { _ in }, onDone: {})
        vc.test_applyStatuses(audio: .granted, isProbingAudio: false, network: .unknown,
                              remoteControl: .unknown, ptpHelper: .notFound)
        #expect(vc.test_ptpHelperRow.lastStatus == .notFound)
        #expect(vc.test_ptpHelperRowButtonTitles == [],
                       "notFound is a packaging bug, not user-fixable")
    }

    @Test func openLoginItemsButtonRoutesToTheModelSeam() {
        let ptpHelper = FakePTPHelper(status: .requiresApproval)
        let vc = OnboardingViewController(model: makeModel(audio: .granted, ptpHelper: ptpHelper),
                                          onOpenSettings: { _ in }, onDone: {})
        vc.test_refresh()   // bind the row to the real (requiresApproval) model state
        vc.test_ptpHelperRow.test_tapOpenLoginItems()
        #expect(ptpHelper.openSettingsCount == 1)
    }

    @Test func viewDidLoadRegistersThePTPHelper() {
        let ptpHelper = FakePTPHelper(status: .notRegistered)
        let vc = OnboardingViewController(model: makeModel(audio: .granted, ptpHelper: ptpHelper),
                                          onOpenSettings: { _ in }, onDone: {})
        _ = vc.test_rootView   // forces loadView + viewDidLoad
        #expect(ptpHelper.registerCount == 1)
    }

    // MARK: Presentation reason (`.permissionLost` banner)

    @Test func firstRunRendersNoBanner() {
        let vc = OnboardingViewController(model: makeModel(audio: .granted),
                                          reason: .firstRun,
                                          onOpenSettings: { _ in }, onDone: {})
        #expect(!vc.test_showsPermissionLostBanner)
        #expect(vc.test_permissionLostBannerText == nil)
    }

    @Test func permissionLostRendersBannerNamingTheUnmetPermission() {
        let vc = OnboardingViewController(model: makeModel(audio: .denied),
                                          reason: .permissionLost([.audioCapture]),
                                          onOpenSettings: { _ in }, onDone: {})
        #expect(vc.test_showsPermissionLostBanner)
        let text = vc.test_permissionLostBannerText
        #expect(text != nil)
        #expect(text?.contains("System Audio") ?? false,
                      "banner names the specific unmet permission: \(text ?? "nil")")
    }

    @Test func permissionLostBannerNamesMultipleUnmetPermissions() {
        let vc = OnboardingViewController(model: makeModel(audio: .denied),
                                          reason: .permissionLost([.audioCapture, .ptpHelper]),
                                          onOpenSettings: { _ in }, onDone: {})
        let text = vc.test_permissionLostBannerText ?? ""
        #expect(text.contains("System Audio"), "\(text)")
        // "Speaker Sync", not "PTP helper" — the row was renamed out of jargon
        // (OnboardingViewController.displayName, spec 5.8).
        #expect(text.contains("Speaker Sync"), "\(text)")
    }

    @Test func permissionLostBannerClearsOnceItsFlaggedPermissionIsGranted() async {
        let vc = OnboardingViewController(model: makeModel(audio: .granted),
                                          reason: .permissionLost([.audioCapture]),
                                          onOpenSettings: { _ in }, onDone: {})
        _ = vc.test_rootView
        #expect(vc.test_permissionLostBannerIsVisible,
                      "banner shows while the flagged permission is still ungranted")

        await vc.test_allowAudio()   // a successful probe flips model.audioStatus to .granted

        #expect(!vc.test_permissionLostBannerIsVisible,
                       "the banner must clear once the permission it warned about is granted")
        #expect(vc.test_showsPermissionLostBanner,
                      "it's hidden, not never-built")
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

    // MARK: Window level + presentation (punch-list W10/W6)

    @Test func windowFloatsWhileOpen() {
        let wc = OnboardingWindowController(model: makeModel(audio: .granted),
                                            openSettings: { _ in },
                                            onFinished: {})
        #expect(wc.window?.level == .floating,
                "owner decision 2026-08-07: setup stays above other windows for its whole open lifetime")
    }

    @Test func representDoesNotRecenterAMovedWindow() {
        let wc = OnboardingWindowController(model: makeModel(audio: .granted),
                                            openSettings: { _ in },
                                            onFinished: {})
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
        wc.keyWindowProvider = { nil }   // e.g. returning from a permission prompt

        wc.test_appDidBecomeActive()

        #expect(wc.window?.isVisible == true,
                "with no key window, the hook re-fronts setup so the user lands back on it")
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

    // MARK: Done-tap confirmation gate (ONBOARD-GATE)
    //
    // The original bug: a first-time user could click Done with ZERO
    // permissions granted and the flow would silently complete, with no
    // warning and no path back once something failed later. These pin that
    // Done now asks first whenever a REQUIRED permission
    // (`SetupModel.requiredPermissionsNotGranted()`) isn't actually granted,
    // and that "Continue Anyway" still finishes (setup stays guidance, not a
    // hard gate — `SetupModel.complete()`).

    /// A local-network fake that reports the browse as reachable — needed here
    /// (unlike `NoopLocalNetwork`) to drive `localNetworkStatus` all the way to
    /// `.granted` for the "everything granted" case.
    private struct ReachableLocalNetwork: LocalNetworkPriming {
        func probe() async -> Bool { true }
    }

    @Test func doneAsksForConfirmationWhenNothingWasEverGranted() {
        // A fresh model: every required permission is still at its untouched
        // initial state (.unknown / .notRegistered) — exactly the scenario
        // that used to complete silently.
        var doneFired = false
        let vc = OnboardingViewController(model: makeModel(audio: .unknown),
                                          onOpenSettings: { _ in }, onDone: { doneFired = true })
        vc.test_tapDone()
        #expect(!doneFired, "must not finish silently with nothing granted")
        #expect(Set(vc.test_pendingConfirmationPermissions ?? []) ==
                       Set([.audioCapture, .localNetwork, .ptpHelper]))
    }

    @Test func doneAsksOnlyAboutPermissionsStillMissing() async {
        let ptpHelper = FakePTPHelper(status: .enabled)
        let vc = OnboardingViewController(model: makeModel(audio: .granted, ptpHelper: ptpHelper),
                                          onOpenSettings: { _ in }, onDone: {})
        // Actually grant audio (unlike test_applyStatuses, which only fakes the
        // row display and never touches the model the gate reads from). PTP
        // helper is already `.enabled` from `viewDidLoad()`'s automatic
        // registration; Local Network is left untouched.
        await vc.test_allowAudio()

        vc.test_tapDone()

        #expect(vc.test_pendingConfirmationPermissions == [.localNetwork],
                       "audio + PTP helper are already granted; only Local Network is still missing")
    }

    @Test func doneFinishesImmediatelyWhenEveryRequiredPermissionIsGranted() async {
        let ptpHelper = FakePTPHelper(status: .enabled)
        let model = SetupModel(audioProbe: CannedAudioProbe(result: .granted),
                               localNetwork: ReachableLocalNetwork(),
                               remoteControl: NoopRemoteControl(),
                               ptpHelper: ptpHelper,
                               settings: AppSettings(defaults: defaults))
        var doneFired = false
        let vc = OnboardingViewController(model: model, onOpenSettings: { _ in }, onDone: { doneFired = true })
        await vc.test_allowAudio()
        await vc.test_allowNetwork()
        #expect(model.requiredPermissionsNotGranted() == [])

        vc.test_tapDone()

        #expect(doneFired, "Done finishes immediately once every required permission is granted")
        #expect(vc.test_pendingConfirmationPermissions == nil)
    }

    @Test func continueAnywayStillFinishesDespiteUngrantedPermissions() {
        var doneFired = false
        let vc = OnboardingViewController(model: makeModel(audio: .unknown),
                                          onOpenSettings: { _ in }, onDone: { doneFired = true })
        vc.test_tapDone()
        #expect(!doneFired)

        vc.test_resolvePendingConfirmation(continueAnyway: true)

        #expect(doneFired, "Continue Anyway still finishes — setup is guidance, not a hard gate")
        #expect(vc.test_pendingConfirmationPermissions == nil)
    }

    @Test func goBackLeavesOnboardingOpenWithoutFinishing() {
        var doneFired = false
        let vc = OnboardingViewController(model: makeModel(audio: .unknown),
                                          onOpenSettings: { _ in }, onDone: { doneFired = true })
        vc.test_tapDone()

        vc.test_resolvePendingConfirmation(continueAnyway: false)

        #expect(!doneFired, "Go Back must not finish setup")
        #expect(vc.test_pendingConfirmationPermissions == nil, "the pending confirmation clears either way")
    }

    @Test func doneCanBeRetriedAfterGoingBackAndThenGranting() async {
        // Go Back, grant the missing permissions, tap Done again — the second
        // tap must re-evaluate rather than being stuck.
        let ptpHelper = FakePTPHelper(status: .enabled)
        let model = SetupModel(audioProbe: CannedAudioProbe(result: .granted),
                               localNetwork: ReachableLocalNetwork(),
                               remoteControl: NoopRemoteControl(),
                               ptpHelper: ptpHelper,
                               settings: AppSettings(defaults: defaults))
        var doneFired = false
        let vc = OnboardingViewController(model: model, onOpenSettings: { _ in }, onDone: { doneFired = true })

        vc.test_tapDone()   // nothing granted yet → asks
        #expect(!doneFired)
        vc.test_resolvePendingConfirmation(continueAnyway: false)   // Go Back

        await vc.test_allowAudio()
        await vc.test_allowNetwork()
        vc.test_tapDone()   // now everything is granted → finishes immediately

        #expect(doneFired)
    }
}
