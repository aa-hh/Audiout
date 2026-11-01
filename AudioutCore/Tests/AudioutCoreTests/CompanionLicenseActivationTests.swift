// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
import AudioutProtocol
@testable import AudioutCore

/// `CompanionLicenseActivation`, the phone's key path, driven through the
/// same fake server `LicenseValidatorTests` uses.
@MainActor
@Suite struct CompanionLicenseActivationTests {

    private let isolation = TestIsolation(owner: "CompanionLicenseActivationTests")
    private var defaults: UserDefaults { isolation.isolatedDefaults }

    private static let server = URL(string: "https://license.example.com")!
    private static let key = "AUDT-AAAAA-BBBBB-CCCCC-DDDDD"
    private static let newKey = "AUDT-BBBBB-BBBBB-BBBBB-BBBBB"
    private static let unreachableLine = "Your Mac couldn’t reach the licence server. Check its internet connection and try again."
    private static let unrecognisedLine = "Your Mac didn’t recognise this licence. Tap Restore purchase."

    /// A Mac holding an active key and its companion token, as a verified
    /// purchase leaves it.
    private func settingsHoldingActiveKey() -> AppSettings {
        let settings = AppSettings(defaults: defaults, licenseServerURL: Self.server)
        settings.licenseKey = Self.key
        settings.licenseStatus = .active
        settings.companionToken = "tok-a"
        settings.licenseMaxMajor = 1
        return settings
    }

    /// The same Mac part-way through a registered trial: the key is active
    /// and carries a trial end.
    private func settingsHoldingActiveTrialKey() -> AppSettings {
        let settings = settingsHoldingActiveKey()
        settings.trialStartedAt = Date().addingTimeInterval(-86_400)
        settings.trialExpiresAt = Date().addingTimeInterval(13 * 86_400)
        settings.trialRegistered = true
        return settings
    }

    private func expectActiveKeyKept(_ settings: AppSettings) {
        #expect(settings.licenseKey == Self.key)
        #expect(settings.licenseStatus == .active)
        #expect(settings.companionToken == "tok-a")
        #expect(settings.licenseMaxMajor == 1)
    }

    /// Collects what the validator asked for and answers with a canned reply.
    /// A class because the transport closure escapes into the validator.
    /// Queued answers are used first, one per request, then `answer`.
    private final class Transport: @unchecked Sendable {
        private(set) var requests: [URLRequest] = []
        var answer: (Data?, URLResponse?, Error?) = (nil, nil, nil)
        private var queued: [(Data?, URLResponse?, Error?)] = []

        private static func reply(status: Int, json: String) -> (Data?, URLResponse?, Error?) {
            (Data(json.utf8),
             HTTPURLResponse(url: CompanionLicenseActivationTests.server, statusCode: status,
                             httpVersion: nil, headerFields: nil),
             nil)
        }

        func stub(status: Int, json: String) {
            answer = Self.reply(status: status, json: json)
        }

        func stubNext(status: Int, json: String) {
            queued.append(Self.reply(status: status, json: json))
        }

        func stubNextUnreachable() {
            queued.append((nil, nil, nil))
        }

        var closure: LicenseValidator.Transport {
            { [self] request, completion in
                requests.append(request)
                let next = queued.isEmpty ? answer : queued.removeFirst()
                completion(next.0, next.1, next.2)
            }
        }
    }

    private func activate(_ settings: AppSettings, _ key: String,
                          _ transport: Transport) async -> CompanionServer.CommandResult {
        await withCheckedContinuation { continuation in
            CompanionLicenseActivation(settings: settings, transport: transport.closure)
                .activate(key: key) { continuation.resume(returning: $0) }
        }
    }

    /// Red if an active answer stopped applying and storing the server's
    /// canonical key — the phone re-sends its stored key on every
    /// reconnection, so a key never canonicalised would keep re-validating.
    @Test func anActiveAnswerAppliesAndStoresTheCanonicalKey() async {
        let settings = AppSettings(defaults: defaults, licenseServerURL: Self.server)
        let transport = Transport()
        transport.stub(status: 200, json: #"{"status":"active","key":"\#(Self.key)"}"#)

        let result = await activate(settings, "AUDT-aaaaa-bbbbb-ccccc-ddddd", transport)

        #expect(result == CompanionServer.CommandResult(applied: true))
        #expect(settings.licenseKey == Self.key)
        #expect(settings.licenseStatus == .active)
    }

    /// Red if a revoked answer stopped refusing, refused with anything other
    /// than the wording `LicenseCopy` shares with the Settings sheet, or left
    /// the refused key on file.
    @Test func aRevokedAnswerRefusesWithTheSharedStatusLineAndStoresNothing() async {
        let settings = AppSettings(defaults: defaults, licenseServerURL: Self.server)
        let transport = Transport()
        transport.stub(status: 200, json: #"{"status":"revoked","reason":"refund"}"#)

        let result = await activate(settings, Self.key, transport)

        #expect(result == CompanionServer.CommandResult(
            applied: false, refusalReason: LicenseCopy.statusLine(for: .revoked, reason: "refund"),
            refusalCode: CompanionRefusalCode.revoked))
        #expect(settings.licenseKey == nil, "a refused phone key puts back the Mac's previous state")
    }

    /// Red if re-sending the already-active stored key started a fresh
    /// network round trip on every reconnect instead of short-circuiting.
    @Test func aKeyEqualToTheStoredActiveKeyAppliesWithNoRequest() async {
        let settings = AppSettings(defaults: defaults, licenseServerURL: Self.server)
        settings.licenseKey = Self.key
        settings.licenseStatus = .active
        let transport = Transport()

        let result = await activate(settings, Self.key, transport)

        #expect(result == CompanionServer.CommandResult(applied: true))
        #expect(transport.requests.isEmpty, "an already-active key must not re-validate on every reconnect")
    }

    /// Red if a malformed key stopped being refused before it ever touched
    /// the network or `AppSettings`.
    @Test func aMalformedKeyRefusesAndWritesNothing() async {
        let settings = AppSettings(defaults: defaults, licenseServerURL: Self.server)
        let transport = Transport()

        let result = await activate(settings, "nope", transport)

        #expect(result == CompanionServer.CommandResult(
            applied: false, refusalReason: Self.unrecognisedLine,
            refusalCode: CompanionRefusalCode.unrecognised))
        #expect(settings.licenseKey == nil)
        #expect(transport.requests.isEmpty)
    }

    /// Red if a rejected phone key overwrote the active trial key, cleared its
    /// token, or left its trial dates as the refusal wrote them.
    @Test func aRevokedPhoneKeyLeavesTheActiveKeyAndItsTokenInPlace() async {
        let settings = settingsHoldingActiveTrialKey()
        let started = settings.trialStartedAt
        let expires = settings.trialExpiresAt
        let transport = Transport()
        transport.stub(status: 200, json: #"{"status":"revoked","reason":"refund"}"#)

        let result = await activate(settings, Self.newKey, transport)

        #expect(result == CompanionServer.CommandResult(
            applied: false, refusalReason: LicenseCopy.statusLine(for: .revoked, reason: "refund"),
            refusalCode: CompanionRefusalCode.revoked))
        expectActiveKeyKept(settings)
        #expect(settings.trialStartedAt == started)
        #expect(settings.trialExpiresAt == expires)
        #expect(settings.trialRegistered)
        #expect(transport.requests.count == 1)
    }

    /// Red if an unreachable server during the Mac's own key check answered
    /// applied, or went on to send the phone's key.
    @Test func anUnreachableServerDuringTheOwnKeyCheckRefusesAndChangesNothing() async {
        let settings = settingsHoldingActiveKey()
        let transport = Transport()

        let result = await activate(settings, Self.newKey, transport)

        #expect(result == CompanionServer.CommandResult(
            applied: false, refusalReason: Self.unreachableLine,
            refusalCode: CompanionRefusalCode.serverUnreachable))
        expectActiveKeyKept(settings)
        #expect(transport.requests.count == 1)
    }

    /// Red if the restore overwrote a key stored during the check.
    @Test func aKeyStoredDuringThePhoneCheckIsNotOverwrittenByTheRestore() async {
        let settings = settingsHoldingActiveTrialKey()
        let transport = Transport()
        transport.stub(status: 200, json: #"{"status":"revoked","reason":"refund"}"#)
        let typedKey = "AUDT-CCCCC-CCCCC-CCCCC-CCCCC"

        // The validator's answer lands one main-queue turn after `activate`
        // returns, so the write below happens while the check is in flight.
        _ = await withCheckedContinuation { continuation in
            CompanionLicenseActivation(settings: settings, transport: transport.closure)
                .activate(key: Self.newKey) { continuation.resume(returning: $0) }
            settings.licenseKey = typedKey
        }

        #expect(settings.licenseKey == typedKey)
    }

    /// Red if the restore of the previous key ran after an active verdict too,
    /// or a trial key were re-checked as if it were paid.
    @Test func anActivePhoneKeyReplacesAnActiveTrialKeyAndTakesItsToken() async {
        let settings = settingsHoldingActiveTrialKey()
        let transport = Transport()
        transport.stub(status: 200, json: #"{"status":"active","key":"\#(Self.newKey)","companion_token":"tok-b"}"#)

        let result = await activate(settings, Self.newKey, transport)

        #expect(result == CompanionServer.CommandResult(applied: true))
        #expect(settings.licenseKey == Self.newKey)
        #expect(settings.companionToken == "tok-b")
        #expect(transport.requests.count == 1)
        #expect(settings.trialExpiresAt == nil)
    }

    /// Red if a phone key replaced a paid key the server still calls active.
    @Test func aDifferentPhoneKeyIsRefusedWhileTheMacsPaidKeyIsStillActive() async {
        let settings = settingsHoldingActiveKey()
        let transport = Transport()
        transport.stubNext(status: 200, json: #"{"status":"active","key":"\#(Self.key)","companion_token":"tok-a2"}"#)

        let result = await activate(settings, Self.newKey, transport)

        #expect(result == CompanionServer.CommandResult(
            applied: false, refusalReason: "Your Mac already has its own licence, so it kept it.",
            refusalCode: CompanionRefusalCode.alreadyLicensed))
        #expect(transport.requests.count == 1)
        let body = String(decoding: transport.requests.first?.httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains(Self.key))
        #expect(!body.contains(Self.newKey))
        #expect(settings.licenseKey == Self.key)
        #expect(settings.companionToken == "tok-a2")
    }

    /// Red if a paid key the server has revoked still blocked the phone's key.
    @Test func aPhoneKeyReplacesThePaidKeyOnceTheServerNoLongerCallsItActive() async {
        let settings = settingsHoldingActiveKey()
        let transport = Transport()
        transport.stubNext(status: 200, json: #"{"status":"revoked","key":"\#(Self.key)","reason":"refund"}"#)
        transport.stubNext(status: 200, json: #"{"status":"active","key":"\#(Self.newKey)","companion_token":"tok-b"}"#)

        let result = await activate(settings, Self.newKey, transport)

        #expect(result == CompanionServer.CommandResult(applied: true))
        #expect(transport.requests.count == 2)
        #expect(settings.licenseKey == Self.newKey)
        #expect(settings.companionToken == "tok-b")
    }

    /// Red if the restore wrote the key back as nil without putting the trial
    /// back, since clearing the key clears the trial too.
    @Test func anUnreachableServerRefusesThePhoneKeyAndKeepsTheMacsLocalTrial() async {
        let settings = AppSettings(defaults: defaults, licenseServerURL: Self.server)
        TrialClock.start(settings: settings, now: Date())
        let started = settings.trialStartedAt
        let expires = settings.trialExpiresAt
        let transport = Transport()

        let result = await activate(settings, Self.newKey, transport)

        #expect(result == CompanionServer.CommandResult(
            applied: false, refusalReason: Self.unreachableLine,
            refusalCode: CompanionRefusalCode.serverUnreachable))
        #expect(settings.licenseKey == nil)
        #expect(settings.trialStartedAt == started)
        #expect(settings.trialExpiresAt == expires)
        #expect(settings.trialRegistered == false)
    }

    /// Red if a refused phone key left the Mac without its ended trial key, or
    /// with the refusal's verdict instead of its own.
    @Test func aRevokedPhoneKeyPutsTheMacsEndedTrialKeyBack() async {
        let settings = AppSettings(defaults: defaults, licenseServerURL: Self.server)
        settings.licenseKey = Self.key
        settings.licenseStatus = .revoked
        settings.licenseReason = "trial_expired"
        settings.trialStartedAt = Date().addingTimeInterval(-20 * 86_400)
        settings.trialExpiresAt = Date().addingTimeInterval(-6 * 86_400)
        settings.trialRegistered = true
        settings.trialBannerLastDayShown = true
        let started = settings.trialStartedAt
        let expires = settings.trialExpiresAt
        let transport = Transport()
        transport.stub(status: 200, json: #"{"status":"revoked","reason":"refund"}"#)

        let result = await activate(settings, Self.newKey, transport)

        #expect(result == CompanionServer.CommandResult(
            applied: false, refusalReason: LicenseCopy.statusLine(for: .revoked, reason: "refund"),
            refusalCode: CompanionRefusalCode.revoked))
        #expect(settings.licenseKey == Self.key)
        #expect(settings.licenseStatus == .revoked)
        #expect(settings.licenseReason == "trial_expired")
        #expect(settings.trialStartedAt == started)
        #expect(settings.trialExpiresAt == expires)
        #expect(settings.trialRegistered)
        #expect(settings.trialBannerLastDayShown)
    }

    /// Red if a phone purchase stopped replacing the Mac's ENDED trial key,
    /// which stays stored after the trial so a later purchase can convert it.
    @Test func anActivePhoneKeyReplacesAnEndedTrialKey() async {
        let settings = AppSettings(defaults: defaults, licenseServerURL: Self.server)
        settings.licenseKey = Self.key
        settings.licenseStatus = .revoked
        settings.licenseReason = "trial_expired"
        settings.trialStartedAt = Date().addingTimeInterval(-20 * 86_400)
        settings.trialExpiresAt = Date().addingTimeInterval(-6 * 86_400)
        settings.trialRegistered = true
        let transport = Transport()
        transport.stub(status: 200, json: #"{"status":"active","key":"\#(Self.newKey)","companion_token":"tok-b"}"#)

        let result = await activate(settings, Self.newKey, transport)

        #expect(result == CompanionServer.CommandResult(applied: true))
        #expect(settings.licenseKey == Self.newKey)
        #expect(settings.licenseStatus == .active)
        #expect(settings.trialExpiresAt == nil)
        #expect(!TrialClock.holdsKey(settings: settings))
    }

    /// Red if a build with no licence server stopped refusing as `cannotCheck`
    /// or left the phone's key on file.
    @Test func aMacWithNoLicenceServerRefusesAsCannotCheck() async {
        let settings = AppSettings(defaults: defaults)
        let transport = Transport()

        let result = await activate(settings, Self.newKey, transport)

        #expect(result.refusalCode == CompanionRefusalCode.cannotCheck)
        #expect(transport.requests.isEmpty)
        #expect(settings.licenseKey == nil)
    }

    /// Red if the shortcut compared raw text and sent the Mac's own key through
    /// the `alreadyLicensed` check.
    @Test func theStoredActiveKeySpelledDifferentlyAppliesWithNoRequest() async {
        let settings = settingsHoldingActiveKey()
        let transport = Transport()

        let result = await activate(settings, "AUDT-aaaaa-bbbbb-ccccc-ddddd", transport)

        #expect(result == CompanionServer.CommandResult(applied: true))
        #expect(transport.requests.isEmpty)
    }
}
