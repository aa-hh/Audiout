// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import Foundation
import Testing
@testable import AudioutCore
@testable import AudioutOnboardingUI
import AudioutSharedUI

/// `LicenseGate` (Core) and the first-open gate overlay (OnboardingUI). The
/// rule under defense: only a PURCHASED build (a licence server URL) with an
/// unregistered install gates, and the gate never locks out an offline buyer.
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

    /// A refunded or revoked key keeps the app running on one speaker. Red if
    /// a declined verdict brought the blocking gate back.
    @Test(arguments: [LicenseStatus.revoked, .unknown, .invalid])
    func declinedKeyLimitsInsteadOfGating(status: LicenseStatus) {
        let settings = settings()
        settings.licenseKey = Self.key
        settings.licenseStatus = status
        #expect(!LicenseGate.shouldPresent(settings: settings, presentation: .auto))
        #expect(LicenseGate.limitsToOneSpeaker(settings: settings))
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

    /// The trial ends by the one-speaker limit, not the gate. Red if a spent
    /// trial met the blocking window again, or ran unlimited for good.
    @Test func anExpiredTrialIsLimitedNotGated() {
        let settings = settings()
        startTrial(settings, daysAgo: 20)
        #expect(!LicenseGate.shouldPresent(settings: settings, presentation: .auto))
        #expect(LicenseGate.limitsToOneSpeaker(settings: settings))
    }

    /// Red if a key typed after the trial ended were limited before the server
    /// answered — an offline buyer would pay and still get one speaker.
    @Test func anUnverifiedKeyAfterAnExpiredTrialIsNotLimited() {
        let settings = settings()
        startTrial(settings, daysAgo: 20)
        settings.licenseKey = Self.key
        #expect(settings.licenseStatus == nil)
        #expect(!LicenseGate.limitsToOneSpeaker(settings: settings))
    }

    /// Red if an expired trial key whose last verdict was `.active` escaped
    /// the limit — the stored trial key would keep every speaker for good.
    @Test func anExpiredTrialWithAnActiveLastVerdictIsLimited() {
        let settings = settings()
        startTrial(settings, daysAgo: 20)
        settings.licenseKey = Self.key
        settings.licenseStatus = .active
        #expect(LicenseGate.limitsToOneSpeaker(settings: settings))
    }

    /// Red if day one of a trial, before its key arrives, were gated or
    /// limited — the trial exists to remove both.
    @Test func aRunningTrialWithoutAKeyIsNeitherGatedNorLimited() {
        let settings = settings()
        startTrial(settings, daysAgo: 1)
        #expect(!LicenseGate.shouldPresent(settings: settings, presentation: .auto))
        #expect(!LicenseGate.limitsToOneSpeaker(settings: settings))
    }

    /// Red if a build from source ever limited speakers — GPL keeps that path
    /// free.
    @Test func aSourceBuildIsNeverLimited() {
        let settings = settings(withServer: false)
        startTrial(settings, daysAgo: 20)
        #expect(!LicenseGate.limitsToOneSpeaker(settings: settings))
        #expect(!LicenseGate.limitsToOneSpeaker(settings: self.settings(withServer: false, store: isolation.makeDefaults())))
    }

    /// Red if a fresh official install with no key and no trial skipped the
    /// welcome, or ran unlimited behind it.
    @Test func noKeyAndNoTrialGatesAndIsLimited() {
        let settings = settings()
        #expect(LicenseGate.shouldPresent(settings: settings, presentation: .auto))
        #expect(LicenseGate.limitsToOneSpeaker(settings: settings))
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

    // Turns red if a shipping build reads the Developer popup's stored value,
    // which would let a leftover dev preference hide the gate in a release.
    @Test func shippingBuildIgnoresTheStoredGateSetting() {
        let stored = settings(store: isolation.makeDefaults())
        stored.licenseGatePresentation = .forceShow
        #expect(LicenseGatePresentation.resolved(
            environment: [:], settings: stored, isDevBuild: false) == .auto)
    }

    // Turns red if the resolver stops reading the Developer popup on a dev build.
    @Test func devBuildStoredGateSettingBeatsAuto() {
        let stored = settings(store: isolation.makeDefaults())
        stored.licenseGatePresentation = .forceHide
        #expect(LicenseGatePresentation.resolved(
            environment: [:], settings: stored, isDevBuild: true) == .forceHide)
    }

    // Turns red if the stored setting is checked before `AUDIOUT_LICENSE_GATE`.
    @Test func environmentKnobBeatsTheStoredGateSetting() {
        let stored = settings(store: isolation.makeDefaults())
        stored.licenseGatePresentation = .forceHide
        #expect(LicenseGatePresentation.resolved(
            environment: ["AUDIOUT_LICENSE_GATE": "force"], settings: stored, isDevBuild: true) == .forceShow)
    }

    // MARK: Remote waiver

    /// A purchased build whose key the server revoked: limited to one speaker
    /// until something waives it.
    private func revokedSettings() -> AppSettings {
        let settings = settings()
        settings.licenseKey = Self.key
        settings.licenseStatus = .revoked
        return settings
    }

    /// The website's app-config with the Mac licence switch set as given.
    private func appConfig(disabled: Bool, upToBuild: String = "null") -> Data {
        Data("""
        {"v": 1,
         "ios": {"sync": {"disabled": false, "upToBuild": null, "message": null},
                 "licenseCheck": {"disabled": false, "upToBuild": null}},
         "mac": {"licenseCheck": {"disabled": \(disabled), "upToBuild": \(upToBuild)}}}
        """.utf8)
    }

    /// Red if a revoked key stopped being limited when no config was ever
    /// fetched, which would make the waiver the default instead of the
    /// exception.
    @Test func aRevokedKeyWithNoCachedConfigIsLimited() {
        #expect(LicenseGate.limitsToOneSpeaker(settings: revokedSettings()))
    }

    /// Red if a fresh file with `mac.licenseCheck.disabled` true stopped
    /// lifting the limit, which is the whole point of the switch.
    @Test func aFreshWaiverLiftsTheLimit() {
        let settings = revokedSettings()
        settings.remoteConfigData = appConfig(disabled: true)
        settings.remoteConfigFetchedAt = Date()
        #expect(!LicenseGate.limitsToOneSpeaker(settings: settings))
    }

    /// Red if a file fetched eight days ago still waived the limit, which would
    /// let one forgotten switch unlicense the app for good.
    @Test func aWaiverFetchedEightDaysAgoNoLongerCounts() {
        let settings = revokedSettings()
        settings.remoteConfigData = appConfig(disabled: true)
        settings.remoteConfigFetchedAt = Date(timeIntervalSinceNow: -8 * 86_400)
        #expect(LicenseGate.limitsToOneSpeaker(settings: settings))
    }

    /// Red if `upToBuild` stopped being inclusive or stopped being checked: a
    /// build above the cut-off must stay limited, and the cut-off build itself
    /// must be waived.
    @Test func theWaiverStopsAtItsBuildCutOff() {
        let settings = revokedSettings()
        settings.remoteConfigFetchedAt = Date()

        settings.remoteConfigData = appConfig(disabled: true, upToBuild: "4")
        #expect(!RemoteAppConfig.licenseCheckWaived(settings: settings, build: 5, now: Date()))

        settings.remoteConfigData = appConfig(disabled: true, upToBuild: "5")
        #expect(RemoteAppConfig.licenseCheckWaived(settings: settings, build: 5, now: Date()))
    }

    // MARK: The thank-you card and the consent ask

    /// A trial that converted to a paid key: started, then cleared of its end
    /// date when the bought key arrived.
    private func convert(_ s: AppSettings) {
        startTrial(s, daysAgo: 3)
        s.trialExpiresAt = nil
        s.licenseKey = Self.key
        s.licenseStatus = .active
    }

    /// Fails if the card stops being owed to a converted trial, or is owed again once shown.
    @Test func aConvertedTrialIsOwedTheThankYouCardOnce() {
        let s = settings()
        convert(s)
        #expect(LicenseGate.owesThankYouCard(settings: s))
        s.licenseThankYouShown = true
        #expect(!LicenseGate.owesThankYouCard(settings: s))
    }

    /// Fails if the `licenseServerURL` clause is dropped: a source build has no purchase to thank.
    @Test func aSourceBuildIsNeverOwedTheThankYouCard() {
        let s = settings(withServer: false)
        convert(s)
        #expect(!LicenseGate.owesThankYouCard(settings: s))
    }

    /// Fails if the `trialStartedAt` clause is dropped: a direct buyer never had a trial to convert.
    @Test func aDirectBuyerIsNeverOwedTheThankYouCard() {
        let s = settings()
        s.licenseKey = Self.key
        s.licenseStatus = .active
        #expect(!LicenseGate.owesThankYouCard(settings: s))
    }

    /// Fails if the `trialExpiresAt == nil` clause is dropped: a running trial has not converted.
    @Test func aRunningTrialIsNeverOwedTheThankYouCard() {
        let s = settings()
        startTrial(s, daysAgo: 1)
        s.licenseKey = Self.key
        s.licenseStatus = .active
        #expect(!LicenseGate.owesThankYouCard(settings: s))
    }

    /// Fails if the consent ask comes before the thank-you card, after an
    /// answer, or a second time.
    @Test func theConsentAskIsOwedOnlyAfterTheCardAndOnlyOnce() {
        let s = settings()
        convert(s)
        s.licenseThankYouShown = true
        #expect(LicenseGate.owesConversionConsentAsk(settings: s))

        s.licenseThankYouShown = false
        #expect(!LicenseGate.owesConversionConsentAsk(settings: s))
        s.licenseThankYouShown = true

        s.telemetryAsked = true
        #expect(!LicenseGate.owesConversionConsentAsk(settings: s))
        s.telemetryAsked = false

        s.telemetryConversionAskShown = true
        #expect(!LicenseGate.owesConversionConsentAsk(settings: s))
    }

    // MARK: The gate

    /// Canned-transport helper mirroring `LicenseValidatorTests.Transport`,
    /// plus the requests it was handed.
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

    /// The gate on its own (the clipboard offer's seam is set after `init`).
    @MainActor
    private func makeContent(_ settings: AppSettings, _ transport: Transport,
                             openURL: @escaping (URL) -> Void = { _ in },
                             onPassed: @escaping () -> Void = {}) -> LicenseGateViewController {
        LicenseGateViewController(settings: settings, transport: transport.closure,
                                  openURL: openURL, onPassed: onPassed)
    }

    /// `LicenseValidator` lands every completion via `DispatchQueue.main.async`
    /// even with a synchronous transport — one queued turn stands between
    /// the submission and its outcome.
    private func drainMain() async {
        await withCheckedContinuation { cont in
            DispatchQueue.main.async { cont.resume() }
        }
    }

    private static let offerCopy = AppSettings.remoteAppIsOffered
        ? LicenseGateViewController.offerSubtitleWithPhone : LicenseGateViewController.offerSubtitleMacOnly
    private static let enterCopy = "Paste or type the key from your receipt email."

    // MARK: The two states

    /// Red if the offer subtitle stopped asking `AppSettings.remoteAppIsOffered`
    /// and invited buyers to the phone app in a build that does not offer it.
    @Test func theOfferSubtitleMentionsThePhoneOnlyWhenTheRemoteAppIsOffered() {
        #expect(LicenseGateViewController.offerSubtitleWithPhone ==
            "One purchase covers this Mac and Audiout Remote on your iPhone.")
        #expect(LicenseGateViewController.offerSubtitleMacOnly ==
            "One purchase covers this Mac.")
        #expect(Self.offerCopy == (AppSettings.remoteAppIsOffered
            ? LicenseGateViewController.offerSubtitleWithPhone : LicenseGateViewController.offerSubtitleMacOnly))
    }


    /// Red if a build with a checkout stopped opening on the offer, the title
    /// or subtitle copy changed, Buy, the trial or its reassurance line went
    /// missing before any trial, or the status line showed through the offer.
    @MainActor
    @Test func theGateOpensOnTheOffer() {
        let gate = makeContent(settings(withBuy: true), Transport())
        #expect(gate.test_state == .offer)
        #expect(gate.test_headlineText == "Unlock Audiout")
        #expect(gate.test_bodyText == Self.offerCopy)
        #expect(gate.test_buyIsVisible)
        #expect(gate.test_trialIsVisible)
        #expect(gate.test_trialTitle == "Try free for 14 days")
        let haveKey = gate.test_visibleControls.compactMap { $0 as? TextActionButton }
        #expect(haveKey.map(\.actionTitle) == ["I have a key"])
        #expect(gate.test_visibleControls.contains {
            ($0 as? NSTextField)?.stringValue == LicenseGateViewController.reassuranceLine
        })
        #expect(gate.test_resultText == nil)
    }

    /// Red if Buy stopped opening the checkout exactly once, or stopped moving
    /// the panel to the key state with its own subtitle and no Buy.
    @MainActor
    @Test func buyOpensTheCheckoutAndEntersTheKeyState() {
        var opened: [URL] = []
        let settings = settings(withBuy: true)
        let gate = makeContent(settings, Transport(), openURL: { opened.append($0) })
        gate.test_tapBuy()
        #expect(opened == [settings.buyURL].compactMap { $0 })
        #expect(opened.count == 1)
        #expect(gate.test_state == .enter)
        #expect(gate.test_headlineText == "Unlock Audiout")
        #expect(gate.test_bodyText == Self.enterCopy)
        #expect(!gate.test_buyIsVisible)
        #expect(gate.test_resultText == "20 characters to go")
    }

    /// Red if "I have a key" opened the checkout on its way to the
    /// key state, or stopped going there.
    @MainActor
    @Test func haveAKeyEntersWithoutTheCheckout() {
        var opened = 0
        let gate = makeContent(settings(withBuy: true), Transport(), openURL: { _ in opened += 1 })
        gate.test_tapHaveKey()
        #expect(gate.test_state == .enter)
        #expect(opened == 0)
    }

    /// Red if a build with no checkout URL showed an offer whose Buy goes
    /// nowhere instead of opening on the key state, or showed a Back to it.
    @MainActor
    @Test func aBuildWithoutABuyURLOpensInTheKeyState() {
        let gate = makeContent(settings(), Transport())
        #expect(gate.test_state == .enter)
        #expect(gate.test_bodyText == Self.enterCopy)
        #expect(!gate.test_buyIsVisible)
        #expect(!gate.test_visibleControls.contains { ($0 as? TextLinkButton)?.linkTitle == "Back" })
        gate.test_tapBack()
        #expect(gate.test_state == .enter)
    }

    /// Red if "Lost your key?" left the key state, stopped opening the
    /// website's resend page with the app's source tag, or showed in a build
    /// with no website to send the buyer to.
    @MainActor
    @Test func lostKeyOpensTheResendPage() {
        var opened: [URL] = []
        let gate = makeContent(settings(withBuy: true), Transport(), openURL: { opened.append($0) })
        gate.test_tapHaveKey()
        #expect(gate.test_visibleControls.contains { ($0 as? TextLinkButton)?.linkTitle == "Lost your key?" })
        gate.test_tapLostKey()
        #expect(opened == [URL(string: "https://audiout.app/resend?s=mac-app")!])
        #expect(gate.test_state == .enter)

        let noSite = makeContent(settings(), Transport())
        #expect(!noSite.test_visibleControls.contains { ($0 as? TextLinkButton)?.linkTitle == "Lost your key?" })
    }

    /// Red if "Back" stopped returning a buyer who abandoned the checkout to
    /// the offer with Buy reachable, or the trip moved the title.
    @MainActor
    @Test func backReturnsToTheOffer() throws {
        let gate = makeContent(settings(withBuy: true), Transport())
        gate.view.frame = NSRect(x: 0, y: 0, width: 713, height: 600)
        gate.view.layoutSubtreeIfNeeded()
        let title = try #require(gate.test_visibleControls.first)
        let before = title.convert(title.bounds, to: gate.view)

        gate.test_tapBuy()
        gate.test_setKeyText("AUDT-AAAAA")
        gate.test_tapBack()
        gate.view.layoutSubtreeIfNeeded()
        #expect(gate.test_state == .offer)
        #expect(gate.test_buyIsVisible)
        #expect(title.convert(title.bounds, to: gate.view) == before)
        #expect(gate.test_keyText == "AUDT-AAAAA", "the boxes keep the key for the way back")
    }

    /// Red if the status line stopped counting down the characters still to
    /// enter on every fill, or lost the singular at one.
    @MainActor
    @Test func theCountFallsAsCharactersLand() {
        let transport = Transport()
        let gate = makeContent(settings(), transport)
        #expect(gate.test_resultText == "20 characters to go")
        for typed in 1...19 {
            gate.test_setKeyText(String(repeating: "A", count: typed))
            let left = 20 - typed
            #expect(gate.test_resultText == "\(left) character\(left == 1 ? "" : "s") to go")
        }
        #expect(gate.test_resultText == "1 character to go")
        #expect(transport.requests.isEmpty)
        #expect(!gate.isChecking)
    }

    /// Red if a key verified before its twentieth character, or the
    /// twentieth stopped submitting it, locking the boxes and showing
    /// "Verifying…" until the verdict replaces it. Headless, so no pulse.
    @MainActor
    @Test func theTwentiethCharacterStartsVerifying() async {
        let transport = Transport()
        transport.stub(status: 200, json: #"{"status":"unknown","key":"\#(Self.key)"}"#)
        let gate = makeContent(settings(), transport)
        gate.test_setKeyText(String(repeating: "A", count: 19))
        #expect(transport.requests.isEmpty)

        gate.test_setKeyText(String(repeating: "A", count: 20))
        #expect(gate.test_resultText == "Verifying…")
        #expect(gate.isChecking)
        #expect(!gate.test_keyEntry.isEnabled, "the boxes lock while the server is asked")
        #expect(!gate.test_statusIsPulsing, "no pulse headless")
        await drainMain()
        #expect(transport.requests.count == 1)
        #expect(gate.test_resultText == "Key not accepted")
    }

    // MARK: Verdicts

    /// The transport answers synchronously and headless runs skip the settle
    /// beat, so the pass lands one main-queue turn after the full key does.
    /// Red if an accepted key stopped saying "Registered" with its thanks, or
    /// stopped opening the gate exactly once.
    @MainActor
    @Test func verifiedActiveKeyOpensTheGate() async {
        let settings = settings()
        let transport = Transport()
        transport.stub(status: 200, json: #"{"status":"active","key":"\#(Self.key)"}"#)

        var passed = 0
        let gate = makeContent(settings, transport, onPassed: { passed += 1 })
        gate.test_setKeyText(Self.key)
        #expect(gate.test_resultText == "Verifying…")
        await drainMain()

        #expect(transport.requests.count == 1)
        #expect(passed == 1)
        #expect(gate.test_didPass)
        #expect(settings.licenseStatus == .active)
        #expect(gate.test_resultText == "Registered")
        #expect(gate.test_detailText == "Thank you for supporting Audiout.")
    }

    /// An unreachable server saves the key AND opens the gate — "couldn't
    /// verify" must never lock a buyer out. Red if it stopped doing either, or
    /// stopped saying so.
    @MainActor
    @Test func unreachableServerSavesKeyAndOpens() async {
        let settings = settings()
        let transport = Transport()   // (nil, nil, nil) → .unreachable

        var passed = 0
        let gate = makeContent(settings, transport, onPassed: { passed += 1 })
        gate.test_setKeyText(Self.key)
        await drainMain()

        #expect(passed == 1)
        #expect(settings.licenseKey == Self.key)
        #expect(settings.licenseStatus == nil)
        #expect(gate.test_resultText == "Key saved")
        #expect(gate.test_detailText == "We'll check it next time you're online.")
        // Next launch does not re-gate on the saved-unverified key.
        #expect(!LicenseGate.shouldPresent(settings: settings, presentation: .auto))
    }

    /// Red if a refused key opened the gate, stopped naming the refusal with
    /// the shared `LicenseCopy` reason, or left the boxes locked or the caret
    /// anywhere but the first box.
    @MainActor
    @Test func rejectedKeyHoldsTheGateAndSaysWhy() async {
        let settings = settings()
        let transport = Transport()
        transport.stub(status: 200, json: #"{"status":"unknown","key":"\#(Self.key)"}"#)

        var passed = 0
        let gate = makeContent(settings, transport, onPassed: { passed += 1 })
        gate.test_setKeyText(Self.key)
        await drainMain()

        #expect(passed == 0)
        #expect(!gate.test_didPass)
        #expect(gate.test_resultText == "Key not accepted")
        #expect(gate.test_detailText == LicenseCopy.statusLine(for: .unknown, reason: nil))
        // The boxes keep the key and take edits again, from the first box.
        #expect(gate.test_keyText == Self.key)
        #expect(gate.test_keyEntry.isEnabled)
        #expect(gate.test_keyEntry.test_focusedIndex == 0)
        #expect(!gate.isChecking)
    }

    /// Red if editing a rejected key short of twenty characters left the
    /// verdict in place instead of the count with an empty detail line, or
    /// completing it again stopped asking the server again.
    @MainActor
    @Test func editingAfterARejectionRestoresTheCount() async throws {
        let transport = Transport()
        transport.stub(status: 200, json: #"{"status":"unknown","key":"\#(Self.key)"}"#)
        let gate = makeContent(settings(), transport)
        gate.test_setKeyText(Self.key)
        await drainMain()
        #expect(gate.test_resultText == "Key not accepted")

        let entry = gate.test_keyEntry
        let last = try #require(entry.test_boxes.last)
        last.stringValue = "DDDD"
        entry.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: last))
        #expect(gate.test_resultText == "1 character to go")
        #expect(gate.test_detailText == nil)
        #expect(transport.requests.count == 1)

        last.stringValue = "DDDDD"
        entry.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: last))
        #expect(gate.test_resultText == "Verifying…")
        await drainMain()
        #expect(transport.requests.count == 2)
    }

    /// Red if the purchase deep link stopped moving the offer to the key
    /// state without the checkout, or asked the server twice for one key.
    @MainActor
    @Test func deepLinkEntersAndVerifies() async {
        let settings = settings(withBuy: true)
        let transport = Transport()
        transport.stub(status: 200, json: #"{"status":"active","key":"\#(Self.key)"}"#)

        var passed = 0
        var opened = 0
        let gate = makeContent(settings, transport, openURL: { _ in opened += 1 },
                               onPassed: { passed += 1 })
        gate.submit(key: Self.key)
        #expect(gate.test_state == .enter)
        await drainMain()
        #expect(passed == 1)
        #expect(opened == 0)
        #expect(settings.licenseKey == Self.key)
        // The full key started its own check as it landed; the link's submit
        // must not ask the server a second time.
        #expect(transport.requests.count == 1)
    }

    /// Red if the phone-verified pass stopped opening the gate exactly once.
    @MainActor
    @Test func aPhoneVerifiedKeyOpensTheGateExactlyOnce() async {
        var passed = 0
        let gate = makeContent(settings(), Transport(), onPassed: { passed += 1 })
        gate.passWithStoredKey()
        gate.passWithStoredKey()
        #expect(passed == 1)
    }

    /// Red if `isChecking` stopped reporting a key check in flight, which
    /// let the phone's key race the gate's own check on the stored key.
    @MainActor
    @Test func isCheckingCoversOnlyARegisterInFlight() async {
        let gate = makeContent(settings(), Transport())
        #expect(!gate.isChecking)
        gate.submit(key: Self.key)
        #expect(gate.isChecking, "the validator has not answered until the next main-queue turn")
        await drainMain()
    }

    // MARK: The clipboard

    /// A key on the clipboard is filled in on the first arrival in the key
    /// state, and only then. A full one verifies at once; a partial one shows
    /// its count. Red if the offer read the clipboard, a partial key was sent
    /// to the server, a full one stopped submitting itself, or a second
    /// arrival looked again.
    @MainActor
    @Test func clipboardKeyIsOfferedAndAFullOneVerifies() async {
        let partialSettings = settings(withBuy: true, store: isolation.makeDefaults())
        let partialTransport = Transport()
        let partial = makeContent(partialSettings, partialTransport)
        var reads = 0
        partial.pasteboardAccessIsAlwaysAllowed = { true }
        partial.pasteboardString = { reads += 1; return "AUDT-AAAAA-BBBBB" }
        partial.test_arrive()
        #expect(reads == 0, "the offer never reads the clipboard")

        partial.test_tapHaveKey()
        #expect(partial.test_keyText == "AUDT-AAAAA-BBBBB")
        #expect(partial.test_resultText == "10 characters to go")
        #expect(partialTransport.requests.isEmpty)
        #expect(partialSettings.licenseKey == nil)

        partial.test_setKeyText("")
        partial.test_arrive()
        #expect(reads == 1, "one look only")
        #expect(partial.test_keyText.isEmpty)

        let settings = settings()
        let transport = Transport()
        var passed = 0
        let content = makeContent(settings, transport, onPassed: { passed += 1 })
        content.pasteboardAccessIsAlwaysAllowed = { true }
        content.pasteboardString = { "  \(Self.key)\n" }
        content.test_arrive()

        #expect(content.test_keyText == Self.key)
        #expect(content.test_resultText == "Verifying…")
        await drainMain()
        #expect(transport.requests.count == 1)
        #expect(settings.licenseKey == Self.key)
        #expect(passed == 1, "an unreachable server still opens the gate")
    }

    /// Red if a clipboard that holds no key changed the boxes or the count.
    @MainActor
    @Test func unrelatedClipboardIsIgnored() async {
        let content = makeContent(settings(), Transport())
        content.pasteboardAccessIsAlwaysAllowed = { true }
        content.pasteboardString = { "https://example.com" }
        content.test_arrive()

        #expect(content.test_keyText.isEmpty)
        #expect(content.test_resultText == "20 characters to go")
    }

    /// The READ is the thing that costs the user a system paste alert, so this
    /// counts reads rather than results. Red if arrival touched the clipboard
    /// without the app already being allowed to read it.
    @MainActor
    @Test func arrivalNeverReadsTheClipboardWithoutAlwaysAllow() async {
        let content = makeContent(settings(), Transport())
        var reads = 0
        content.pasteboardAccessIsAlwaysAllowed = { false }
        content.pasteboardString = { reads += 1; return Self.key }
        content.test_arrive()

        #expect(reads == 0)
        #expect(content.test_keyText.isEmpty)
        #expect(content.test_resultText == "20 characters to go")
    }

    /// The click is the gesture that earns the read. Red if "Paste key"
    /// stopped filling the boxes where arrival may not look,
    /// stopped replacing what was typed, or a full key stopped verifying.
    @MainActor
    @Test func pasteLinkFillsFromTheClipboard() async {
        let settings = settings()
        let transport = Transport()
        var passed = 0
        let content = makeContent(settings, transport, onPassed: { passed += 1 })
        content.pasteboardAccessIsAlwaysAllowed = { false }
        content.pasteboardString = { "  \(Self.key)\n" }
        content.test_setKeyText("AUDT-OLD")
        content.test_tapPasteKey()

        #expect(content.test_keyText == Self.key)
        #expect(content.test_resultText == "Verifying…")
        #expect(passed == 0)
        await drainMain()
        #expect(transport.requests.count == 1)
        #expect(settings.licenseKey == Self.key)
    }

    /// Red if a paste with no key on the clipboard stopped saying so in the
    /// detail line, or touched the boxes or the count.
    @MainActor
    @Test func pasteLinkWithoutAKeySaysSo() async {
        let content = makeContent(settings(), Transport())
        content.pasteboardAccessIsAlwaysAllowed = { false }
        content.pasteboardString = { "https://example.com" }
        content.test_tapPasteKey()

        #expect(content.test_keyText.isEmpty)
        #expect(content.test_resultText == "20 characters to go")
        #expect(content.test_detailText == "No key on the clipboard. It starts with AUDT-.")
    }

    // MARK: The trial offer

    /// Red if the key state's trial button came back (the key state ends in
    /// Back alone; the trial is on the offer, one Back away), or the offer's
    /// button stopped starting the trial.
    @MainActor
    @Test func theTrialIsOfferedOnTheOfferOnly() throws {
        let settings = settings(withBuy: true)
        var passed = 0
        let gate = makeContent(settings, Transport(), onPassed: { passed += 1 })
        let isTrial = { (view: NSView) in (view as? NSButton)?.title == "Try free for 14 days" }
        gate.test_tapHaveKey()
        #expect(!gate.test_trialIsVisible)
        #expect(!gate.test_visibleControls.contains(where: isTrial))
        gate.test_tapBack()
        #expect(gate.test_trialIsVisible)
        #expect(gate.test_trialTitle == "Try free for 14 days")
        let trials = gate.test_visibleControls.filter(isTrial).compactMap { $0 as? NSButton }
        #expect(trials.count == 1)
        let button = try #require(trials.first)
        _ = (button.target as? NSObject)?.perform(button.action, with: button)
        #expect(passed == 1)
        #expect(settings.trialStartedAt != nil)
    }

    /// The offer is for someone who has never had a trial, and for nobody
    /// else. Red if it, or its reassurance line, came back for a trial
    /// already running or already spent — a second trial is not a thing this
    /// app has.
    @MainActor
    @Test func theTrialOfferIsOnlyThereBeforeAnyTrial() {
        let fresh = makeContent(settings(withBuy: true), Transport())
        #expect(fresh.test_trialIsVisible)

        for daysAgo in [1.0, 20.0] {
            let started = settings(withBuy: true, store: isolation.makeDefaults())
            startTrial(started, daysAgo: daysAgo)
            let gate = makeContent(started, Transport())
            #expect(!gate.test_trialIsVisible)
            #expect(!gate.test_visibleControls.contains {
                ($0 as? NSTextField)?.stringValue == LicenseGateViewController.reassuranceLine
            })
            gate.test_tapHaveKey()
            #expect(!gate.test_trialIsVisible)
        }
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

    /// A converted trial keeps its start date and loses its expiry — that is
    /// what the validator writes when the paid key answers — so it reads as no
    /// trial at all. Red if the offer were driven off that reading again: a
    /// refund brings this window back, `TrialClock.start` refuses a Mac that
    /// has trialled before, and the user would be let through on no trial and
    /// no valid key, every launch.
    @MainActor
    @Test func aTrialThatConvertedIsNeverOfferedASecondOne() {
        let settings = settings(withBuy: true)
        startTrial(settings, daysAgo: 3)
        settings.trialExpiresAt = nil
        #expect(TrialClock.state(settings: settings) == .none, "reads as no trial")

        var passed = 0
        let content = makeContent(settings, Transport(), onPassed: { passed += 1 })
        #expect(!content.test_trialIsVisible)

        content.test_tapTrial()
        #expect(passed == 0)
        #expect(!content.test_didPass)
        #expect(settings.trialExpiresAt == nil, "no second trial was written")
    }

    // MARK: The key boxes

    /// Red if normalising stopped dropping the `AUDT-` prefix and the dashes,
    /// stopped uppercasing, stopped mapping `O` to `0`, or `fill` stopped
    /// laying five characters into each box.
    @MainActor
    @Test(arguments: ["audt-ab0de-fghjk-mnpqr-stvwx", "AB0DEFGHJKMNPQRSTVWX"])
    func aKeyFillsTheSameWithOrWithoutItsPrefix(text: String) {
        let entry = makeContent(settings(), Transport()).test_keyEntry
        entry.fill(text)
        #expect(entry.test_boxTexts == ["AB0DE", "FGHJK", "MNPQR", "STVWX"])
        #expect(entry.keyText == "AUDT-AB0DE-FGHJK-MNPQR-STVWX")
        #expect(entry.isComplete)
    }

    /// Red if `O`, `I` or `L` stopped reading as the digit the licence server
    /// forgives them as.
    @MainActor
    @Test func lookalikeLettersBecomeDigits() {
        let entry = makeContent(settings(), Transport()).test_keyEntry
        entry.fill("o1il2l")
        #expect(entry.test_boxTexts == ["01112", "1", "", ""])
    }

    /// Red if a character outside Crockford base32 (here `U`, a dash and a
    /// space) reached a box, typed or filled.
    @MainActor
    @Test func charactersOutsideTheAlphabetAreDropped() {
        let entry = makeContent(settings(), Transport()).test_keyEntry
        entry.fill("A U-B")
        #expect(entry.keyText == "AUDT-AB")
        for junk in ["U", "-", " "] {
            entry.test_type(junk)
            #expect(entry.test_boxTexts[0] == "AB", "\(junk) landed in a box")
        }
    }

    /// Red if `normalised` went back to dropping `U` before the fourth letter
    /// of a hand-typed AUDT landed, which left "ADT" in the first box.
    @MainActor
    @Test func aHandTypedPrefixIsDroppedLikeAPastedOne() {
        let typed = makeContent(settings(), Transport()).test_keyEntry
        for letter in ["a", "u", "d", "t"] { typed.test_type(letter) }
        #expect(typed.test_boxTexts[0] == "")
        typed.test_type("b")
        #expect(typed.test_boxTexts[0] == "B")

        let notAPrefix = makeContent(settings(), Transport()).test_keyEntry
        for letter in ["a", "d", "t"] { notAPrefix.test_type(letter) }
        #expect(notAPrefix.test_boxTexts[0] == "ADT")
    }

    /// Red if focus moved before the fifth character or stopped moving on
    /// it, or Delete on an empty box stopped stepping back to the box before
    /// without deleting there.
    @MainActor
    @Test func typingMovesOnAndDeleteStepsBack() {
        let entry = makeContent(settings(), Transport()).test_keyEntry
        entry.test_type("abcd")
        #expect(entry.test_boxTexts[0] == "ABCD")
        #expect(entry.test_focusedIndex == 0)
        entry.test_type("e")
        #expect(entry.test_boxTexts[0] == "ABCDE")
        #expect(entry.test_focusedIndex == 1)
        entry.test_backspace()
        #expect(entry.test_focusedIndex == 0)
        #expect(entry.test_boxTexts == ["ABCDE", "", "", ""])
    }

    /// Red if a paste stopped spreading five per box from the edited box
    /// onward, touched a box before it, or ran past the fourth box.
    @MainActor
    @Test func aPasteSpreadsAcrossTheBoxesFromTheEditedOne() {
        let entry = makeContent(settings(), Transport()).test_keyEntry
        entry.fill("AAAAA")
        #expect(entry.test_focusedIndex == 1)
        entry.test_type("bbbbb-ccccc-ddddd-eeeee")
        #expect(entry.test_boxTexts == ["AAAAA", "BBBBB", "CCCCC", "DDDDD"])
        #expect(entry.test_focusedIndex == 3)
        #expect(entry.isComplete)
    }

    /// Red if `controlTextDidChange` went back to re-splitting a full box's
    /// own five plus an appended whole key from that box, instead of sending
    /// the appended key through `fill`.
    @MainActor
    @Test func aWholeKeyPastedAfterAFullBoxReplacesEveryBox() {
        let entry = makeContent(settings(), Transport()).test_keyEntry
        entry.fill("AAAAA")
        entry.focusBox(0)
        entry.test_type("AUDT-BBBBB-CCCCC-DDDDD-EEEEE")
        #expect(entry.test_boxTexts == ["BBBBB", "CCCCC", "DDDDD", "EEEEE"])
    }

    /// Red if `controlTextDidChange` stopped laying the characters appended
    /// to a full box from the next box onward.
    @MainActor
    @Test func charactersAppendedToAFullBoxGoToTheNextBox() {
        let entry = makeContent(settings(), Transport()).test_keyEntry
        entry.fill("AAAAA")
        entry.focusBox(0)
        entry.test_type("BBBBB")
        #expect(entry.test_boxTexts == ["AAAAA", "BBBBB", "", ""])
    }

    /// Red if the box geometry drifted from the four 92 pt boxes, their
    /// 16 pt dash slots and the plate, or the row went back to stretching
    /// across the panel instead of keeping its natural width.
    @MainActor
    @Test func theKeyRowFitsThePanel() {
        let gate = makeContent(settings(), Transport())
        gate.view.frame = NSRect(x: 0, y: 0, width: 713, height: 600)
        gate.view.layoutSubtreeIfNeeded()
        let width = gate.test_keyEntry.frame.width
        #expect(width >= 516 && width <= 532, "the key row measures \(width) pt")
    }

    // MARK: Layout

    private func buttons(in view: NSView) -> [NSButton] {
        view.subviews.flatMap { sub in ((sub as? NSButton).map { [$0] } ?? []) + buttons(in: sub) }
    }

    /// The panel sits 14 pt in from both sides and 8 pt above the bottom of
    /// the overlay, and everything the current state shows lies inside it.
    /// Red if the panel's insets change, it outgrows the overlay at the
    /// surface's 713 x 600 floor, a row spills out of it in either state (the
    /// full-width Buy and trial, "Paste key" beside the subtitle and the
    /// status label are the widest), the key state gained a control beyond
    /// title, subtitle, "Paste key", boxes, status, Back and "Lost your key?",
    /// or a Quit button comes back. The trial and its reassurance line are
    /// only on the offer and only before any trial; Back is there in the key
    /// state of a build with a checkout.
    @MainActor
    @Test(arguments: [nil, 1.0, 20.0] as [Double?], [false, true])
    func thePanelHoldsEveryControlAtTheSurfaceFloor(trialStartedDaysAgo: Double?, enter: Bool) {
        let settings = settings(withBuy: true, store: isolation.makeDefaults())
        if let trialStartedDaysAgo { startTrial(settings, daysAgo: trialStartedDaysAgo) }
        let gate = makeContent(settings, Transport())
        if enter { gate.test_tapHaveKey() }
        let size = NSSize(width: 713, height: 600)
        gate.view.frame = NSRect(origin: .zero, size: size)
        gate.view.layoutSubtreeIfNeeded()

        let panel = gate.test_panel.frame
        // Unflipped overlay: y counts up from the bottom edge.
        #expect(panel.minX == 14)
        #expect(size.width - panel.maxX == 14)
        #expect(panel.minY == 8)
        #expect(panel.maxY <= size.height, "the panel overflows the top of the overlay")

        let controls = gate.test_visibleControls
        let trial = trialStartedDaysAgo == nil ? 1 : 0
        let expected = enter ? 7 : 4 + 2 * trial
        #expect(controls.count == expected)
        for control in controls {
            let frame = control.convert(control.bounds, to: gate.view)
            #expect(panel.contains(frame), "\(control) at \(frame) spills out of the panel \(panel)")
        }
        #expect(!buttons(in: gate.view).contains { $0.title == "Quit" || $0.keyEquivalent == "q" })
    }

    /// Red if the panel stopped holding one height across the two states, so
    /// the title (pinned to a bottom-anchored panel) jumps when Buy or "I
    /// have a key" moves to the key state.
    @MainActor
    @Test func theTitleDoesNotMoveBetweenStates() throws {
        let gate = makeContent(settings(withBuy: true), Transport())
        gate.view.frame = NSRect(x: 0, y: 0, width: 713, height: 600)
        gate.view.layoutSubtreeIfNeeded()
        let title = try #require(gate.test_visibleControls.first)
        let before = title.convert(title.bounds, to: gate.view)

        gate.test_tapHaveKey()
        gate.view.layoutSubtreeIfNeeded()
        #expect(gate.test_visibleControls.first === title)
        #expect(title.convert(title.bounds, to: gate.view) == before)
    }

    /// Red if Back went back to riding under the status line, which left an
    /// empty band below it because the offer sets the panel's height.
    @MainActor
    @Test func backSitsOnTheOffersBottomLine() throws {
        let gate = makeContent(settings(withBuy: true), Transport())
        gate.view.frame = NSRect(x: 0, y: 0, width: 713, height: 600)
        gate.view.layoutSubtreeIfNeeded()
        let lastLine = try #require(gate.test_visibleControls.last)
        let offerBottom = lastLine.convert(lastLine.bounds, to: gate.view).minY

        gate.test_tapHaveKey()
        gate.view.layoutSubtreeIfNeeded()
        let back = try #require(gate.test_visibleControls.first {
            ($0 as? TextLinkButton)?.linkTitle == "Back"
        })
        #expect(abs(back.convert(back.bounds, to: gate.view).minY - offerBottom) < 0.5)
    }

    /// Buy and the trial button are 320 x 36 pt `CTAButton`s stacked and
    /// centred in the panel, Buy above the trial, both in `plateTitle`, the
    /// title one step down in `heading`, and Buy is the offer's Return
    /// default. Red if the buttons went back to the iPhone's full-width 44 pt
    /// face, the faces split fonts, the title went back to `display`, or Buy
    /// stopped being the Return default.
    @MainActor
    @Test func theCTAsAreMacSized() throws {
        let gate = makeContent(settings(withBuy: true), Transport())
        gate.view.frame = NSRect(x: 0, y: 0, width: 713, height: 600)
        gate.view.layoutSubtreeIfNeeded()
        let cta = CGSize(width: 320, height: 36)
        #expect(gate.test_buyFrame.size == cta)
        #expect(gate.test_trialFrame.size == cta)
        // Within the half point a centred 320 pt face rounds to on a 713 pt surface.
        #expect(abs(gate.test_buyFrame.midX - gate.view.bounds.midX) <= 0.5)
        #expect(abs(gate.test_trialFrame.midX - gate.view.bounds.midX) <= 0.5)
        // Unflipped overlay: above means a larger y.
        #expect(gate.test_buyFrame.minY > gate.test_trialFrame.maxY)
        let controls = gate.test_visibleControls
        #expect((controls.first as? NSTextField)?.font == Tokens.Font.heading)
        let buttons = controls.compactMap { $0 as? CTAButton }
        let buy = try #require(buttons.first { $0.title == "Buy Audiout" })
        #expect(buy.style == .primary)
        #expect(buy.font == Tokens.Font.plateTitle)
        #expect(buy.keyEquivalent == "\r")
        let trial = try #require(buttons.first { $0.title == "Try free for 14 days" })
        #expect(trial.style == .secondary)
        #expect(trial.font == Tokens.Font.plateTitle)
    }

    /// Red if the line explaining the trial drifted away from the trial
    /// button again, with "I have a key" between them.
    @MainActor
    @Test func theTrialTermsSitUnderTheTrial() throws {
        let gate = makeContent(settings(withBuy: true), Transport())
        gate.view.frame = NSRect(x: 0, y: 0, width: 713, height: 600)
        gate.view.layoutSubtreeIfNeeded()
        let controls = gate.test_visibleControls
        let terms = try #require(controls.first {
            ($0 as? NSTextField)?.stringValue == LicenseGateViewController.reassuranceLine
        })
        let haveKey = try #require(controls.first { ($0 as? TextActionButton)?.actionTitle == "I have a key" })
        let termsFrame = terms.convert(terms.bounds, to: gate.view)
        #expect(gate.test_trialFrame.minY - termsFrame.maxY < 10)
        #expect(termsFrame.minY > haveKey.convert(haveKey.bounds, to: gate.view).maxY)
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
            }, captureError: { _, _ in }, consentChanged: { _ in }), consent: true)
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
