// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import Foundation
import Testing
@testable import AudiouterCore
@testable import AudiouterOnboardingUI

/// The Setup window's yield-to-System-Settings choreography, in sequence.
///
/// Split out from `OnboardingUITests` because this is a WINDOW-level contract
/// with one moving part — `OnboardingWindowController`'s level — driven purely
/// through its activation hooks. True cross-app z-order is not observable
/// headless; the window level and the activation ORDER are, and they are what
/// the live bug turned on (see `OnboardingWindowController.isYieldingToSettings`).
@MainActor
@Suite final class OnboardingWindowLevelTests {

    private struct CannedAudioProbe: AudioCapturePermissionProbing {
        let result: PermissionStatus
        func probe() async -> PermissionStatus { result }
        func currentStatusSilently() -> PermissionStatus? { nil }
    }
    private struct NoLocalNetwork: LocalNetworkPriming {
        func probe() async -> Bool { false }
        func probeFoundSpeakers() async -> Int { 0 }
    }
    private struct NoopRemoteControl: RemoteControlPriming {
        func prime() {}
        func isTrusted() -> Bool { false }
    }
    private final class FakePTPHelper: PTPHelperManaging {
        var status: PTPHelperStatus = .notRegistered
        func register() throws {}
        func openSystemSettingsLoginItems() {}
        func unregister() async throws {}
    }

    private let isolation = TestIsolation(owner: "OnboardingWindowLevelTests")

    private func makeController(audioDenied: Bool = true) -> OnboardingWindowController {
        let model = SetupModel(
            audioProbe: CannedAudioProbe(result: audioDenied ? .denied : .granted),
            localNetwork: NoLocalNetwork(),
            remoteControl: NoopRemoteControl(),
            ptpHelper: FakePTPHelper(),
            bluetoothReader: SimulatedBluetoothPermission(status: .unknown),
            bluetoothPrimer: SimulatedBluetoothPermission(status: .unknown),
            settings: AppSettings(defaults: isolation.isolatedDefaults),
            localNetworkGated: true,
            bluetoothPromptTimeout: 10)
        return OnboardingWindowController(model: model,
                                          openSettings: { _ in },
                                          onFinished: {})
    }

    /// **The live bug (macOS 26): System Settings opened BEHIND the setup
    /// window even with the level drop in place.** The click that fires Allow
    /// is often the same click that activates our app, and
    /// `didBecomeActiveNotification` is delivered on the run loop while the
    /// Allow is still resolving through its `await` — so our own activation
    /// lands AFTER the deep link and restored `.floating` on top of the
    /// Settings window we had just asked for. An activation with no
    /// deactivation ahead of it is not a return.
    @Test func ourOwnActivationRightAfterTheDeepLinkDoesNotReFloatOverSettings() async {
        let wc = makeController()
        let vc = wc.test_contentViewController
        _ = vc.test_rootView

        await vc.test_tapAllow(.audio)   // first click: the probe lands denied
        await vc.test_tapAllow(.audio)   // second click: the deep link
        #expect(wc.test_windowLevel == .normal, "the deep link yields")

        wc.test_appDidBecomeActive()     // our own queued activation, no resign first

        #expect(wc.test_windowLevel == .normal,
                "a stray own-activation must not undo the yield — that is what buried System Settings")
    }

    /// The other half of the amendment: yielding must never LOSE the window.
    /// Once Settings has really taken the front, the next activation — the user
    /// clicking back, or our own re-front when a grant lands — restores float.
    @Test func onceSettingsHasTheFrontTheNextActivationRestoresFloat() async {
        let wc = makeController()
        let vc = wc.test_contentViewController
        _ = vc.test_rootView

        await vc.test_tapAllow(.audio)
        await vc.test_tapAllow(.audio)   // the deep link
        wc.test_appDidResignActive()     // System Settings is frontmost now

        wc.test_appDidBecomeActive()     // the grant lands, or the user clicks back

        #expect(wc.test_windowLevel == .floating,
                "the window must never be left buried once the Settings trip is over")
    }

    /// A yield is per-trip: a SECOND Settings trip re-arms it, rather than the
    /// first completed round trip leaving the window pinned on top forever.
    @Test func aSecondSettingsTripYieldsAgain() {
        let wc = makeController(audioDenied: false)

        wc.test_yieldToSystemSettings()
        wc.test_appDidResignActive()
        wc.test_appDidBecomeActive()
        #expect(wc.test_windowLevel == .floating, "the first trip completes normally")

        wc.test_yieldToSystemSettings()
        wc.test_appDidBecomeActive()     // a stray own-activation again

        #expect(wc.test_windowLevel == .normal, "each trip yields on its own terms")
    }

    /// The yield must not swallow the ORDINARY reactivation either: with no
    /// Settings trip in flight, coming back to the app still re-floats.
    @Test func anOrdinaryReactivationStillRestoresFloat() {
        let wc = makeController(audioDenied: false)
        wc.window?.level = .normal   // as if something had demoted it

        wc.test_appDidBecomeActive()

        #expect(wc.test_windowLevel == .floating)
    }
}
