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
    private static let buy = URL(string: "https://audiout.app/buy")!

    /// `store` is for the tests that need two independent Macs in one test —
    /// one mid-trial and one whose trial ran out — since the trial fields live
    /// in the store, not in the struct.
    private func settings(withServer: Bool = true, withBuy: Bool = false,
                          store: UserDefaults? = nil) -> AppSettings {
        AppSettings(defaults: store ?? defaults,
                    licenseServerURL: withServer ? Self.server : nil,
                    buyURL: withBuy ? Self.buy : nil)
    }

    /// A trial that began `daysAgo` days ago. The dates are relative to the
    /// real clock because every question here is about right now: 1 day ago is
    /// mid-trial and 20 is long over, so no plausible clock skew moves either.
    private func startTrial(_ settings: AppSettings, daysAgo: Double) {
        TrialClock.start(settings: settings, now: Date(timeIntervalSinceNow: -daysAgo * 86_400))
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

    /// A trial started on this Mac but not yet answered for by the server has
    /// no key to read, so the old rule called it unregistered. Red if the
    /// trial clause went away — every trial user would meet the wall on day
    /// one, which is the whole thing the trial exists to remove.
    @Test func aRunningTrialWithoutAKeyPassesTheGate() {
        let settings = settings()
        startTrial(settings, daysAgo: 1)
        #expect(settings.licenseKey == nil)
        #expect(!LicenseGate.shouldPresent(settings: settings, presentation: .auto))
    }

    /// The trial ends by the gate coming back. Red if a spent trial started
    /// passing too — the app would then be free for good.
    @Test func anExpiredTrialGatesAgain() {
        let settings = settings()
        startTrial(settings, daysAgo: 20)
        #expect(LicenseGate.shouldPresent(settings: settings, presentation: .auto))
    }

    @Test func forceOverridesEvenASourceBuild() {
        #expect(LicenseGate.shouldPresent(settings: settings(withServer: false),
                                          presentation: .forceShow))
        #expect(!LicenseGate.shouldPresent(settings: settings(), presentation: .forceHide))
    }

    /// The dev knob answers on its own whatever the trial says. Red if the
    /// trial clause leaked into the override path, which is how the gate stops
    /// being reachable for anyone iterating on it.
    @Test func forceOverridesTheTrialInBothDirections() {
        let running = settings()
        startTrial(running, daysAgo: 1)
        #expect(LicenseGate.shouldPresent(settings: running, presentation: .forceShow))

        let spent = settings(store: isolation.makeDefaults())
        startTrial(spent, daysAgo: 20)
        #expect(!LicenseGate.shouldPresent(settings: spent, presentation: .forceHide))
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

    /// Canned-transport helper mirroring `LicenseValidatorTests.Transport`,
    /// plus the requests it was handed — the resend path has no verdict to
    /// assert on, only the fact that it asked.
    private final class Transport: @unchecked Sendable {
        var answer: (Data?, URLResponse?, Error?) = (nil, nil, nil)
        var requests: [URLRequest] = []
        func stub(status: Int, json: String) {
            answer = (Data(json.utf8),
                      HTTPURLResponse(url: LicenseGateTests.server, statusCode: status,
                                      httpVersion: nil, headerFields: nil),
                      nil)
        }
        var closure: LicenseValidator.Transport {
            { [self] request, completion in
                requests.append(request)
                completion(answer.0, answer.1, answer.2)
            }
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

    /// The gate's content on its own, for the states that never involve the
    /// window (the clipboard offer's seam is set after `init`).
    @MainActor
    private func makeContent(_ settings: AppSettings, _ transport: Transport,
                             onPassed: @escaping () -> Void = {}) -> LicenseGateViewController {
        LicenseGateViewController(settings: settings, transport: transport.closure,
                                  openURL: { _ in }, onPassed: onPassed)
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
        #expect(gate.test_contentViewController.test_resultText
            == "Your key is saved. We'll check it next time you're online.")
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

    // MARK: The one surface's states

    /// A key on the clipboard is OFFERED, never spent: filled in and named, so
    /// the buyer still presses Register themselves.
    @MainActor
    @Test func clipboardKeyIsOfferedNeverSubmitted() async {
        let settings = settings()
        var passed = 0
        let content = makeContent(settings, Transport(), onPassed: { passed += 1 })
        content.pasteboardAccessIsAlwaysAllowed = { true }
        content.pasteboardString = { "  \(Self.key)\n" }
        content.test_arrive()

        #expect(content.test_keyText == Self.key)
        #expect(content.test_resultText == "From your clipboard")
        #expect(passed == 0)
        #expect(settings.licenseKey == nil)
    }

    /// Anything that is not a key is left alone — the field stays empty and
    /// the gutter says nothing.
    @MainActor
    @Test func unrelatedClipboardIsIgnored() async {
        let content = makeContent(settings(), Transport())
        content.pasteboardAccessIsAlwaysAllowed = { true }
        content.pasteboardString = { "https://example.com" }
        content.test_arrive()

        #expect(content.test_keyText.isEmpty)
        #expect(content.test_resultText == nil)
    }

    /// The READ is the thing that costs the user a system paste alert, so this
    /// counts reads rather than results: unless the app is already allowed to
    /// read the clipboard, arrival must not touch it at all.
    @MainActor
    @Test func arrivalNeverReadsTheClipboardWithoutAlwaysAllow() async {
        let content = makeContent(settings(), Transport())
        var reads = 0
        content.pasteboardAccessIsAlwaysAllowed = { false }
        content.pasteboardString = { reads += 1; return Self.key }
        content.test_arrive()

        #expect(reads == 0)
        #expect(content.test_keyText.isEmpty)
        #expect(content.test_resultText == nil)
    }

    /// The click is the gesture that earns the read: it fills the field even
    /// where arrival may not look, replaces what was typed, and still leaves
    /// the submitting to the buyer.
    @MainActor
    @Test func pasteKeyFillsFromTheClipboardOnClick() async {
        let settings = settings()
        var passed = 0
        let content = makeContent(settings, Transport(), onPassed: { passed += 1 })
        content.pasteboardAccessIsAlwaysAllowed = { false }
        content.pasteboardString = { "  \(Self.key)\n" }
        content.test_setKeyText("AUDT-OLD")
        content.test_tapPasteKey()

        #expect(content.test_keyText == Self.key)
        #expect(content.test_resultText == "From your clipboard")
        #expect(passed == 0)
        #expect(settings.licenseKey == nil)
    }

    /// A clipboard with no key says so in the one gutter and changes nothing
    /// else.
    @MainActor
    @Test func pasteKeyWithoutAKeySaysSo() async {
        let content = makeContent(settings(), Transport())
        content.pasteboardAccessIsAlwaysAllowed = { false }
        content.pasteboardString = { "https://example.com" }
        content.test_tapPasteKey()

        #expect(content.test_keyText.isEmpty)
        #expect(content.test_resultText == "No key on the clipboard. It starts with AUDT-.")
    }

    /// While the resend question borrows the field there is nothing to paste
    /// into, so the link rests, greyed rather than hidden, because hiding it
    /// would collapse the row and move the link beside it.
    @MainActor
    @Test func pasteKeyRestsDuringTheLostKeyDetour() async {
        let content = makeContent(settings(), Transport())
        #expect(content.test_pasteKeyIsEnabled)

        content.test_tapLostKey()
        #expect(!content.test_pasteKeyIsEnabled)

        content.test_tapLostKey()
        #expect(content.test_pasteKeyIsEnabled)
    }

    /// "I lost my key" morphs the SAME field and button — no sheet, no second
    /// window — and lands one neutral line whatever the server did.
    @MainActor
    @Test func lostKeyMorphsInPlaceAndResends() async {
        let settings = settings()
        let transport = Transport()
        let content = makeContent(settings, transport)

        content.test_tapLostKey()
        #expect(content.test_placeholder == "you@example.com")
        #expect(content.test_commitTitle == "Email my key")
        #expect(content.test_lostKeyTitle == "Back to your key")
        #expect(content.test_resultText == "Enter the email you bought with.")

        content.test_setKeyText("Buyer@Example.com")
        content.test_tapRegister()
        await drainMain()

        #expect(transport.requests.count == 1)
        let request = transport.requests.first
        #expect(request?.url == Self.server.appending(path: "v1/resend"))
        let body = (try? JSONSerialization.jsonObject(with: request?.httpBody ?? Data()))
            as? [String: Any]
        #expect(body?["email"] as? String == "buyer@example.com")

        #expect(content.test_resultText == "If that address bought Audiout, the key is on its way.")
        #expect(content.test_commitTitle == "Register")
        #expect(content.test_placeholder == LicenseCopy.keyFormatHint)
        #expect(content.test_lostKeyTitle == "I lost my key")
    }

    /// Back restores the key that was mid-typing, and clears the detour's line.
    @MainActor
    @Test func backFromLostKeyRestoresTheTypedKey() async {
        let content = makeContent(settings(), Transport())
        content.test_setKeyText(Self.key)
        content.test_tapLostKey()
        #expect(content.test_keyText.isEmpty)

        content.test_tapLostKey()
        #expect(content.test_keyText == Self.key)
        #expect(content.test_resultText == nil)
    }

    @MainActor
    @Test func resendWithoutAnAddressAsksAgain() async {
        let transport = Transport()
        let content = makeContent(settings(), transport)
        content.test_tapLostKey()
        content.test_tapRegister()
        await drainMain()

        #expect(content.test_resultText == "Enter the email address you bought with.")
        #expect(transport.requests.isEmpty)
    }

    /// A refunded key has one useful answer left, so Buy stops being quiet.
    @MainActor
    @Test func revokedVerdictPromotesTheBuyLink() async {
        let settings = settings(withBuy: true)
        let transport = Transport()
        transport.stub(status: 200, json: #"{"status":"revoked","key":"\#(Self.key)"}"#)

        let content = makeContent(settings, transport)
        content.test_setKeyText(Self.key)
        content.test_tapRegister()
        await drainMain()

        #expect(content.test_resultText == LicenseCopy.statusLine(for: .revoked))
        #expect(content.test_buyIsVisible)
        #expect(content.test_buyAlpha == 1)
    }

    /// The field behind the type is part of the answer: a farewell on the way
    /// out, quiet on a refusal.
    @MainActor
    @Test func fieldSceneFollowsTheVerdict() async {
        let accepted = Transport()
        accepted.stub(status: 200, json: #"{"status":"active","key":"\#(Self.key)"}"#)
        let passing = makeContent(settings(), accepted)
        passing.test_setKeyText(Self.key)
        passing.test_tapRegister()
        await drainMain()
        #expect(passing.test_fieldScene == .farewell)

        let refused = Transport()
        refused.stub(status: 200, json: #"{"status":"unknown","key":"\#(Self.key)"}"#)
        let held = makeContent(settings(), refused)
        held.test_setKeyText(Self.key)
        held.test_tapRegister()
        await drainMain()
        #expect(held.test_fieldScene == .quiet)
    }

    // MARK: The trial offer

    /// The offer is for someone who has never had a trial, and for nobody
    /// else. Red if it came back for a trial already running or already spent
    /// — a second trial is not a thing this app has.
    @MainActor
    @Test func theTrialOfferIsOnlyThereBeforeAnyTrial() {
        let fresh = makeContent(settings(), Transport())
        #expect(fresh.test_trialIsVisible)
        #expect(fresh.test_trialTitle == "Try Audiout free for 14 days")

        let running = settings(store: isolation.makeDefaults())
        startTrial(running, daysAgo: 1)
        #expect(!makeContent(running, Transport()).test_trialIsVisible)

        let spent = settings(store: isolation.makeDefaults())
        startTrial(spent, daysAgo: 20)
        #expect(!makeContent(spent, Transport()).test_trialIsVisible)
    }

    /// The tap starts the 14 days and opens the gate in the same turn. Red if
    /// anything network-shaped got between the button and `onPassed` — telling
    /// the licence server is a later, silent job, and a start that waited on a
    /// server would put the wall back in front of someone who has not seen the
    /// app yet.
    @MainActor
    @Test func startingTheTrialOpensTheGateAtOnce() {
        let settings = settings()
        var passed = 0
        let content = makeContent(settings, Transport(), onPassed: { passed += 1 })
        content.test_tapTrial()

        #expect(passed == 1)
        #expect(content.test_didPass)
        #expect(settings.trialStartedAt != nil)
        #expect(!settings.trialRegistered)
        #expect(settings.licenseKey == nil)
        // And the next launch does not ask again.
        #expect(!LicenseGate.shouldPresent(settings: settings, presentation: .auto))
    }

    /// A gate raised by a trial running out says so; every other gate still
    /// welcomes. Red if the two sets of words merged — a returning user would
    /// be welcomed to an app they have already used for a fortnight, with no
    /// hint of why the window is back.
    @MainActor
    @Test func theExpiredGateSaysTheTrialEndedInsteadOfWelcoming() {
        let spent = settings()
        startTrial(spent, daysAgo: 20)
        let expired = makeContent(spent, Transport())
        #expect(expired.test_headlineText == "Your 14-day trial has ended.")
        #expect(expired.test_bodyText
            == "Buy Audiout for €30, once, and keep everything you set up. "
            + "Your scenes and speaker settings are still here.")

        let welcome = "Welcome to Audiout"
        let why = "It takes one key to open. Yours is in your receipt email, starting with AUDT."
        let fresh = makeContent(settings(store: isolation.makeDefaults()), Transport())
        #expect(fresh.test_headlineText == welcome)
        #expect(fresh.test_bodyText == why)

        // A running trial never reaches the gate (the rule above), but if one
        // ever did it gets the ordinary words, not the ending ones.
        let running = settings(store: isolation.makeDefaults())
        startTrial(running, daysAgo: 1)
        let midTrial = makeContent(running, Transport())
        #expect(midTrial.test_headlineText == welcome)
        #expect(midTrial.test_bodyText == why)
    }

    // MARK: LicenseResend (Core)

    @MainActor
    @Test func resendPostsTheTrimmedAddress() async throws {
        let settings = settings()
        let transport = Transport()
        var completions = 0
        LicenseResend(settings: settings, transport: transport.closure)
            .request(email: "  Buyer@Example.com ") { completions += 1 }
        await drainMain()

        #expect(completions == 1)
        let request = try #require(transport.requests.first)
        #expect(request.url == Self.server.appending(path: "v1/resend"))
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(request.httpBody)
        let obj = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(obj["email"] as? String == "buyer@example.com")
    }

    /// There is no failure to report — a dead network completes exactly like a
    /// delivered mail, because the caller's one line is the same either way.
    @MainActor
    @Test func resendCompletesOnFailureToo() async {
        let transport = Transport()
        transport.answer = (nil, nil, URLError(.notConnectedToInternet))
        var completions = 0
        LicenseResend(settings: settings(), transport: transport.closure)
            .request(email: "buyer@example.com") { completions += 1 }
        await drainMain()
        #expect(completions == 1)
    }

    /// No server (a build from source) and a malformed address both send
    /// nothing, and still call back.
    @MainActor
    @Test func resendSendsNothingWithoutAServerOrAnAtSign() async {
        let transport = Transport()
        var completions = 0
        LicenseResend(settings: settings(withServer: false), transport: transport.closure)
            .request(email: "buyer@example.com") { completions += 1 }
        LicenseResend(settings: settings(), transport: transport.closure)
            .request(email: "buyer") { completions += 1 }
        await drainMain()

        #expect(completions == 2)
        #expect(transport.requests.isEmpty)
    }

    // MARK: Layout

    /// The window is a FIXED 560 x 440 and the content column is centred in
    /// it, so every type size on this screen is spending a budget that cannot
    /// grow. The column has to clear the Quit/Buy row pinned to the bottom
    /// edge — an overlap here is two controls drawn on top of each other, not
    /// a scroll.
    ///
    /// The trial state is the axis that varies: each of the three draws a
    /// different column — the trial offer and its line are only in the first,
    /// and the ending's body copy is longer than the welcome's.
    @MainActor
    @Test(arguments: [nil, 1.0, 20.0] as [Double?])
    func theContentColumnClearsTheBottomButtonRow(trialStartedDaysAgo: Double?) {
        let settings = settings(withBuy: true, store: isolation.makeDefaults())
        if let trialStartedDaysAgo { startTrial(settings, daysAgo: trialStartedDaysAgo) }
        let gate = makeContent(settings, Transport())
        gate.view.frame = NSRect(origin: .zero, size: LicenseGateViewController.contentSize)
        gate.view.layoutSubtreeIfNeeded()

        let column = gate.view.subviews.compactMap { $0 as? NSStackView }.first
        #expect(column != nil)
        let buttons = gate.view.subviews.compactMap { $0 as? NSButton }
        #expect(buttons.count == 2, "expected the Quit and Buy pair on the root view")
        guard let column, let rowTop = buttons.map(\.frame.maxY).max() else { return }

        // The root view is unflipped, so y counts up from the bottom edge.
        #expect(column.frame.minY > rowTop,
                "the column reaches down to \(column.frame.minY), into a button row topping out at \(rowTop)")
        #expect(column.frame.maxY < LicenseGateViewController.contentSize.height,
                "the column overflows the top of a window that cannot grow")
    }
}

/// The gate's trial events, asserted on the real `Analytics` calls rather
/// than on a hook only a test can see.
///
/// Nested under `SerializedSharedState` because `Analytics.install` mutates
/// process-global state — the rule in `SerializedSharedStateSuite.swift`. The
/// suite above stays parallel; only this test pays for the global sink.
extension SerializedSharedState {
    @MainActor
    @Suite struct LicenseGateTrialAnalyticsTests {

        private final class Captured: @unchecked Sendable {
            private let lock = NSLock()
            private var items: [(String, [String: String])] = []
            func append(_ name: String, _ properties: [String: String] = [:]) {
                lock.withLock { items.append((name, properties)) }
            }
            func names() -> [String] { lock.withLock { items }.map(\.0) }
            func properties() -> [[String: String]] { lock.withLock { items }.map(\.1) }
        }

        private let isolation = TestIsolation(owner: "LicenseGateTrialAnalyticsTests")

        private static let key = "AUDT-AAAAA-BBBBB-CCCCC-DDDDD"

        private func gateSettings(_ store: UserDefaults) -> AppSettings {
            AppSettings(defaults: store,
                        licenseServerURL: URL(string: "https://license.example.com"))
        }

        /// Installs a sink for the body and puts `Analytics` back afterwards.
        private func withSink(_ body: (Captured) -> Void) {
            let captured = Captured()
            Analytics.install(Analytics.Sink(capture: { name, props in
                captured.append(name, props)
            }, consentChanged: { _ in }), consent: true)
            defer { Analytics.install(nil, consent: false) }
            body(captured)
        }

        /// Red if starting a trial stopped reporting it. This name is read as
        /// a string by the PostHog insight behind the trial funnel, so it is
        /// pinned here rather than left to whatever the call site says.
        @Test func startingTheTrialIsCaptured() {
            let settings = gateSettings(isolation.isolatedDefaults)
            let content = LicenseGateViewController(settings: settings,
                                                    openURL: { _ in }, onPassed: {})
            withSink { captured in
                content.test_tapTrial()
                #expect(captured.names() == ["license:trial_started"])
            }
        }

        /// Red if the gate a spent trial lands on stopped reporting itself —
        /// that count is the denominator every conversion is measured against.
        /// It must also stay silent on a FIRST open, or every fresh install
        /// would land in it.
        @Test func onlyTheExpiredGateReportsThatItWasShown() {
            withSink { captured in
                let firstOpen = gateSettings(isolation.makeDefaults())
                _ = LicenseGateViewController(settings: firstOpen,
                                              openURL: { _ in }, onPassed: {}).view
                #expect(captured.names().isEmpty, "nobody's trial has ended here")

                let spent = gateSettings(isolation.makeDefaults())
                TrialClock.apply(settings: spent,
                                 startedAt: Date(timeIntervalSinceNow: -20 * 86_400),
                                 expiresAt: Date(timeIntervalSinceNow: -6 * 86_400),
                                 key: Self.key)
                _ = LicenseGateViewController(settings: spent,
                                              openURL: { _ in }, onPassed: {}).view
                #expect(captured.names() == ["license:expired_gate_shown"])
            }
        }

        /// Red if either banner stopped reporting, or if the two stopped being
        /// told apart — the funnel could then not say which warning converts.
        @Test func showingABannerReportsWhichDayItWas() {
            withSink { captured in
                let settings = gateSettings(isolation.makeDefaults())
                TrialClock.start(settings: settings)
                TrialClock.markBannerShown(.threeDays, settings: settings)
                TrialClock.markBannerShown(.lastDay, settings: settings)

                #expect(captured.names()
                        == ["license:banner_shown", "license:banner_shown"])
                #expect(captured.properties().map { $0["day"] } == ["3", "1"])
            }
        }
    }
}
