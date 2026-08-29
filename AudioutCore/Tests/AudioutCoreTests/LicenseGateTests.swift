// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import Foundation
import Testing
@testable import AudioutCore
@testable import AudioutOnboardingUI

/// `LicenseGate` (Core) and the first-open gate window (OnboardingUI). The
/// rule under defense: only a PURCHASED build (a licence server URL) with an
/// unregistered install gates, the gate never locks out an offline buyer, and
/// closing it unanswered aborts rather than leaking a running unlicensed app.
@Suite struct LicenseGateTests {

    private let isolation = TestIsolation(owner: "LicenseGateTests")
    private var defaults: UserDefaults { isolation.isolatedDefaults }

    private static let server = URL(string: "https://license.example.com")!
    private static let key = "AUDT-AAAAA-BBBBB-CCCCC-DDDDD"

    private func settings(withServer: Bool = true) -> AppSettings {
        AppSettings(defaults: defaults, licenseServerURL: withServer ? Self.server : nil)
    }

    // MARK: The decision

    @Test func sourceBuildNeverGates() {
        let settings = settings(withServer: false)
        #expect(!LicenseGate.shouldPresent(settings: settings, presentation: .auto))
    }

    @Test func purchasedBuildGatesWithoutAKey() {
        #expect(LicenseGate.shouldPresent(settings: settings(), presentation: .auto))
    }

    @Test func activeKeyPassesTheGate() {
        let settings = settings()
        settings.licenseKey = Self.key
        settings.licenseStatus = .active
        #expect(!LicenseGate.shouldPresent(settings: settings, presentation: .auto))
    }

    /// The soft-check posture carries into the gate: a stored key with no
    /// verdict yet (saved while the server was unreachable) is registered.
    @Test func unverifiedStoredKeyPassesTheGate() {
        let settings = settings()
        settings.licenseKey = Self.key
        #expect(settings.licenseStatus == nil)
        #expect(!LicenseGate.shouldPresent(settings: settings, presentation: .auto))
    }

    @Test(arguments: [LicenseStatus.revoked, .unknown, .invalid])
    func declinedKeyGates(status: LicenseStatus) {
        let settings = settings()
        settings.licenseKey = Self.key
        settings.licenseStatus = status
        #expect(LicenseGate.shouldPresent(settings: settings, presentation: .auto))
    }

    @Test func forceOverridesEvenASourceBuild() {
        #expect(LicenseGate.shouldPresent(settings: settings(withServer: false),
                                          presentation: .forceShow))
        #expect(!LicenseGate.shouldPresent(settings: settings(), presentation: .forceHide))
    }

    @Test func environmentKnobResolves() {
        #expect(LicenseGatePresentation.resolved(environment: [:]) == .auto)
        #expect(LicenseGatePresentation.resolved(
            environment: ["AUDIOUT_LICENSE_GATE": "force"]) == .forceShow)
        #expect(LicenseGatePresentation.resolved(
            environment: ["AUDIOUT_LICENSE_GATE": "skip"]) == .forceHide)
        #expect(LicenseGatePresentation.resolved(
            environment: ["AUDIOUT_LICENSE_GATE": "gibberish"]) == .auto)
    }

    // MARK: The window

    /// Canned-transport helper mirroring `LicenseValidatorTests.Transport`.
    private final class Transport: @unchecked Sendable {
        var answer: (Data?, URLResponse?, Error?) = (nil, nil, nil)
        func stub(status: Int, json: String) {
            answer = (Data(json.utf8),
                      HTTPURLResponse(url: LicenseGateTests.server, statusCode: status,
                                      httpVersion: nil, headerFields: nil),
                      nil)
        }
        var closure: LicenseValidator.Transport {
            { [self] _, completion in completion(answer.0, answer.1, answer.2) }
        }
    }

    @MainActor
    private func makeGate(_ settings: AppSettings, _ transport: Transport,
                          onPassed: @escaping () -> Void = {},
                          onAbort: @escaping () -> Void = {}) -> LicenseGateWindowController {
        LicenseGateWindowController(settings: settings, transport: transport.closure,
                                    openURL: { _ in },
                                    onPassed: onPassed, onAbort: onAbort)
    }

    /// `LicenseValidator` lands every completion via `DispatchQueue.main.async`
    /// even with a synchronous transport — one queued turn stands between
    /// Register and its outcome.
    private func drainMain() async {
        await withCheckedContinuation { cont in
            DispatchQueue.main.async { cont.resume() }
        }
    }

    /// The transport answers synchronously and headless runs skip the settle
    /// beat, so the pass lands one main-queue turn after Register.
    @MainActor
    @Test func verifiedActiveKeyOpensTheGate() async {
        let settings = settings()
        let transport = Transport()
        transport.stub(status: 200, json: #"{"status":"active","key":"\#(Self.key)"}"#)

        var passed = 0
        let gate = makeGate(settings, transport, onPassed: { passed += 1 })
        gate.test_contentViewController.test_setKeyText(Self.key)
        gate.test_contentViewController.test_tapRegister()
        await drainMain()

        #expect(passed == 1)
        #expect(gate.test_didFinish)
        #expect(settings.licenseStatus == .active)
    }

    @MainActor
    @Test func rejectedKeyHoldsTheGateAndSaysWhy() async {
        let settings = settings()
        let transport = Transport()
        transport.stub(status: 200, json: #"{"status":"unknown","key":"\#(Self.key)"}"#)

        var passed = 0
        let gate = makeGate(settings, transport, onPassed: { passed += 1 })
        gate.test_contentViewController.test_setKeyText(Self.key)
        gate.test_contentViewController.test_tapRegister()
        await drainMain()

        #expect(passed == 0)
        #expect(!gate.test_didFinish)
        #expect(gate.test_contentViewController.test_resultText
            == LicenseCopy.statusLine(for: .unknown))
    }

    /// An unreachable server saves the key AND opens the gate — "couldn't
    /// verify" must never lock a buyer out.
    @MainActor
    @Test func unreachableServerSavesKeyAndOpens() async {
        let settings = settings()
        let transport = Transport()   // (nil, nil, nil) → .unreachable

        var passed = 0
        let gate = makeGate(settings, transport, onPassed: { passed += 1 })
        gate.test_contentViewController.test_setKeyText(Self.key)
        gate.test_contentViewController.test_tapRegister()
        await drainMain()

        #expect(passed == 1)
        #expect(settings.licenseKey == Self.key)
        #expect(settings.licenseStatus == nil)
        // Next launch does not re-gate on the saved-unverified key.
        #expect(!LicenseGate.shouldPresent(settings: settings, presentation: .auto))
    }

    @MainActor
    @Test func emptySubmitPromptsWithoutPassing() async {
        let settings = settings()
        var passed = 0
        let gate = makeGate(settings, Transport(), onPassed: { passed += 1 })
        gate.test_contentViewController.test_tapRegister()
        #expect(passed == 0)
        #expect(gate.test_contentViewController.test_resultText != nil)
    }

    @MainActor
    @Test func closingUnansweredAborts() async {
        let settings = settings()
        var aborted = 0
        var passed = 0
        let gate = makeGate(settings, Transport(),
                            onPassed: { passed += 1 }, onAbort: { aborted += 1 })
        gate.test_closeWindow()
        #expect(aborted == 1)
        #expect(passed == 0)
        // The single-fire guard: a second close changes nothing.
        gate.test_closeWindow()
        #expect(aborted == 1)
    }

    /// The purchase deep link lands in the gate's own field.
    @MainActor
    @Test func deepLinkSubmitsIntoTheGate() async {
        let settings = settings()
        let transport = Transport()
        transport.stub(status: 200, json: #"{"status":"active","key":"\#(Self.key)"}"#)

        var passed = 0
        let gate = makeGate(settings, transport, onPassed: { passed += 1 })
        gate.submit(key: Self.key)
        await drainMain()
        #expect(passed == 1)
        #expect(settings.licenseKey == Self.key)
    }
}
