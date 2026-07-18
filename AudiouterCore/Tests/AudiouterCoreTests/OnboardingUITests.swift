// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import AudiouterCore
@testable import AudiouterOnboardingUI

/// Structure + behavior of the onboarding UI, driven through the real
/// `OnboardingViewController` / `OnboardingWindowController` against fake
/// permission seams (no Core Audio, no network). The window isn't visible to a
/// headless test, so these assert via the `test_` hooks — the same approach the
/// popover/settings UI tests use.
@MainActor
final class OnboardingUITests: XCTestCase {

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
    private final class ChangeCounter { var count = 0 }

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "OnboardingUITests.\(name).\(ObjectIdentifier(self).hashValue)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil; suiteName = nil
        super.tearDown()
    }

    private func makeModel(audio: PermissionStatus) -> SetupModel {
        SetupModel(audioProbe: CannedAudioProbe(result: audio),
                   localNetwork: NoopLocalNetwork(),
                   remoteControl: NoopRemoteControl(),
                   settings: AppSettings(defaults: defaults))
    }

    // MARK: View controller structure

    func testInitialRowsOfferAllow() {
        let vc = OnboardingViewController(model: makeModel(audio: .granted),
                                          onOpenSettings: { _ in }, onDone: {})
        XCTAssertEqual(vc.test_audioRowButtonTitles, ["Allow…"])
        XCTAssertEqual(vc.test_networkRowButtonTitles, ["Allow…"])
        XCTAssertEqual(vc.test_remoteControlRowButtonTitles, ["Allow…"])
    }

    func testGrantingAudioReplacesButtonWithAllowedStatus() async {
        let vc = OnboardingViewController(model: makeModel(audio: .granted),
                                          onOpenSettings: { _ in }, onDone: {})
        await vc.test_allowAudio()
        // Granted shows a status chip, no button.
        XCTAssertEqual(vc.test_audioRowButtonTitles, [])
        XCTAssertEqual(vc.test_audioRow.lastStatus, .granted)
    }

    func testDeniedAudioOffersOpenSettings() {
        let vc = OnboardingViewController(model: makeModel(audio: .denied),
                                          onOpenSettings: { _ in }, onDone: {})
        vc.test_applyStatuses(audio: .denied, isProbingAudio: false, network: .unknown,
                              remoteControl: .unknown)
        XCTAssertEqual(vc.test_audioRowButtonTitles, ["Open Settings"])
    }

    func testPrimingNetworkShowsRequestedAndOpenSettings() async {
        // NoopLocalNetwork reports unreachable, so priming lands on .requested.
        let vc = OnboardingViewController(model: makeModel(audio: .granted),
                                          onOpenSettings: { _ in }, onDone: {})
        await vc.test_allowNetwork()
        XCTAssertEqual(vc.test_networkRow.lastStatus, .requested)
        XCTAssertEqual(vc.test_networkRowButtonTitles, ["Open Settings"])
    }

    func testPrimingRemoteControlShowsRequestedAndOpenSettings() {
        let vc = OnboardingViewController(model: makeModel(audio: .granted),
                                          onOpenSettings: { _ in }, onDone: {})
        vc.test_allowRemoteControl()
        XCTAssertEqual(vc.test_remoteControlRow.lastStatus, .requested)
        XCTAssertEqual(vc.test_remoteControlRowButtonTitles, ["Open Settings"])
    }

    // MARK: Deep-link routing

    func testOpenSettingsRoutesCorrectPanePerRow() {
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
        XCTAssertEqual(opened, [.screenAndSystemAudioRecording, .localNetwork])
    }

    // MARK: Probing state

    func testUnsupportedAudioShowsNoButton() {
        let vc = OnboardingViewController(model: makeModel(audio: .unsupported),
                                          onOpenSettings: { _ in }, onDone: {})
        vc.test_applyStatuses(audio: .unsupported, isProbingAudio: false, network: .unknown,
                              remoteControl: .unknown)
        // Unsupported is not a user-fixable state — no button, just a message.
        XCTAssertEqual(vc.test_audioRowButtonTitles, [])
    }

    // MARK: Window controller dismissal contract

    func testDoneFinishesOnceAndPersistsCompletion() {
        let counter = ChangeCounter()
        let wc = OnboardingWindowController(model: makeModel(audio: .granted),
                                            openSettings: { _ in },
                                            onFinished: { counter.count += 1 })
        XCTAssertFalse(AppSettings(defaults: defaults).hasCompletedSetup)

        wc.test_finishWithDone()

        XCTAssertTrue(wc.test_didFinish)
        XCTAssertTrue(AppSettings(defaults: defaults).hasCompletedSetup, "Done persists completion")
        XCTAssertEqual(counter.count, 1)
    }

    func testCloseWithoutDoneFinishesButDoesNotPersist() {
        let counter = ChangeCounter()
        let wc = OnboardingWindowController(model: makeModel(audio: .granted),
                                            openSettings: { _ in },
                                            onFinished: { counter.count += 1 })
        wc.test_closeWithoutDone()

        XCTAssertTrue(wc.test_didFinish)
        XCTAssertFalse(AppSettings(defaults: defaults).hasCompletedSetup,
                       "Closing with ✕ leaves setup to reappear next launch")
        XCTAssertEqual(counter.count, 1)
    }

    func testFinishIsSingleFire() {
        let counter = ChangeCounter()
        let wc = OnboardingWindowController(model: makeModel(audio: .granted),
                                            openSettings: { _ in },
                                            onFinished: { counter.count += 1 })
        wc.test_finishWithDone()
        wc.test_closeWithoutDone()   // second dismissal path
        wc.test_finishWithDone()     // and again
        XCTAssertEqual(counter.count, 1, "onFinished fires exactly once")
    }
}
