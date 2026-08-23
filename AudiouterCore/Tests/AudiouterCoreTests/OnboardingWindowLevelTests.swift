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

    /// A Bluetooth prompt that never reports back — the simplest way to hold a
    /// system dialog open for the length of an assertion.
    private struct NeverDecidingBluetooth: BluetoothPermissionPriming {
        func prime(onDecided: @escaping @Sendable () -> Void) {}
    }

    /// A Local Network prime the test drives one step at a time, so both halves
    /// of the wait are observable: parked with the dialog notionally up, then
    /// parked AGAIN after the answer landed while the count settles.
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

    private let isolation = TestIsolation(owner: "OnboardingWindowLevelTests")

    private func makeController(audioDenied: Bool = true,
                                localNetwork: LocalNetworkPriming? = nil,
                                bluetoothPrimer: BluetoothPermissionPriming? = nil,
                                bluetoothPromptTimeout: TimeInterval = 10) -> OnboardingWindowController {
        let model = SetupModel(
            audioProbe: CannedAudioProbe(result: audioDenied ? .denied : .granted),
            localNetwork: localNetwork ?? NoLocalNetwork(),
            remoteControl: NoopRemoteControl(),
            ptpHelper: FakePTPHelper(),
            bluetoothReader: SimulatedBluetoothPermission(status: .unknown),
            bluetoothPrimer: bluetoothPrimer ?? SimulatedBluetoothPermission(status: .unknown),
            settings: AppSettings(defaults: isolation.isolatedDefaults),
            localNetworkGated: true,
            bluetoothPromptTimeout: bluetoothPromptTimeout)
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

    /// The freeze this window used to cause: a TCC dialog loses input focus to
    /// any process that grabs it, and this window had two ways to grab it.
    /// While a prompt is unanswered it gives up both — but the LEVEL stays
    /// `.floating`: a TCC dialog draws above it, and demoting to `.normal` is
    /// what made the setup vanish behind other apps for the length of the ask
    /// and pop back on the answer (the "blip", owner decision 2026-08-22).
    @Test func aPromptInFlightSilencesEveryWayThisWindowTakesTheFront() async {
        let wc = makeController(audioDenied: false, bluetoothPrimer: NeverDecidingBluetooth())
        let vc = wc.test_contentViewController
        _ = vc.test_rootView
        #expect(wc.test_windowLevel == .floating, "floating is the resting level")

        await vc.test_tapAllow(.bluetooth)

        #expect(vc.test_isPromptInFlight)
        #expect(wc.test_windowLevel == .floating,
                "the TCC dialog draws above floating — demoting is what caused the accept blip")
        #expect((wc.window as? OnboardingWindow)?.suppressesActivation == true,
                "a click is still delivered, but must not force the app active")

        let fronts = wc.test_frontCount
        wc.test_appDidBecomeActive()

        #expect(wc.test_frontCount == fronts,
                "reactivating must not take key while a dialog is still up")
    }

    /// …and the quiet is not left on: the click force-activate comes back the
    /// moment the prompt resolves (here, its undecided timeout).
    @Test func theQuietLiftsWhenThePromptResolves() async {
        let wc = makeController(audioDenied: false, bluetoothPrimer: NeverDecidingBluetooth(),
                                bluetoothPromptTimeout: 0.05)
        let vc = wc.test_contentViewController
        _ = vc.test_rootView
        await vc.test_tapAllow(.bluetooth)
        #expect((wc.window as? OnboardingWindow)?.suppressesActivation == true)

        for _ in 0..<600 where vc.test_isPromptInFlight {   // ≤3 s, then give up
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        #expect(wc.test_windowLevel == .floating)
        #expect((wc.window as? OnboardingWindow)?.suppressesActivation == false)
    }

    /// **The live bug: after Allow on the Local Network prompt the setup window
    /// dropped to the background** — the one step where that happened, because
    /// its `allowInFlight` OUTLIVES the dialog: once answered, the prime spends
    /// a few more seconds settling the speaker count
    /// (`localNetworkPhase == .verifying`). Two guarantees pin the fix: the
    /// level never demotes for a TCC ask in the first place (the demote was the
    /// whole burying mechanism, and the accept "blip" on every other step too),
    /// and the in-flight quiet — which still gates the ✕, click activation and
    /// the re-front — ends the instant the answer lands, not when the count
    /// finishes.
    @Test func theQuietEndsWhenTheLocalNetworkAnswerLandsNotAfterTheCountSettles() async {
        let net = SteppedLocalNetwork(found: 2)
        let wc = makeController(audioDenied: false, localNetwork: net)
        let vc = wc.test_contentViewController
        _ = vc.test_rootView
        await vc.test_tapAllow(.audio)   // clear the first card so Local Network is live
        #expect(vc.test_activeStep == .localNetwork)

        let priming = Task { await vc.test_tapAllow(.localNetwork) }

        // The dialog is notionally on screen: the app is quiet, the level stays.
        await net.waitUntilParked()
        for _ in 0..<600 where !vc.test_isPromptInFlight {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(vc.test_isPromptInFlight)
        #expect(wc.test_windowLevel == .floating,
                "no demote for a TCC dialog — it draws above floating, and demoting is the blip")

        // The answer lands (the network proves reachable); the count is still
        // settling, but there is no dialog left to go quiet for.
        net.resume()
        await net.waitUntilParked()
        for _ in 0..<600 where vc.test_isPromptInFlight {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(!vc.test_isPromptInFlight,
                "the quiet ends the moment the answer lands, not after the count settles")
        #expect(wc.test_windowLevel == .floating)

        net.resume()
        await priming.value
        #expect(wc.test_windowLevel == .floating)
    }
}
