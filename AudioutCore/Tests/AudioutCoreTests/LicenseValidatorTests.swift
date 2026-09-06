// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudioutCore

/// `LicenseValidator` (`Sources/AudioutCore/LicenseValidator.swift`) — the
/// SOFT license check. Modelled on `LicenseCheckInTests`: a recording
/// transport plus a throwaway `UserDefaults` suite keep this off both the
/// network and `.standard`.
///
/// The rule every test here defends is that only a real 200 changes stored
/// state. A missing server, a missing key, a transport error and a junk body
/// all leave `AppSettings` exactly as they found it — the check must never
/// turn a flaky network into "your license went bad".
@Suite struct LicenseValidatorTests {

    private let isolation = TestIsolation(owner: "LicenseValidatorTests")
    private var defaults: UserDefaults { isolation.isolatedDefaults }

    private static let server = URL(string: "https://license.example.com")!
    private static let key = "AUDT-AAAAA-BBBBB-CCCCC-DDDDD"

    /// Collects what the validator asked for and answers with a canned reply.
    /// A class because the transport closure escapes into the validator.
    private final class Transport: @unchecked Sendable {
        private(set) var requests: [URLRequest] = []
        var answer: (Data?, URLResponse?, Error?) = (nil, nil, nil)

        func stub(status: Int, json: String) {
            answer = (Data(json.utf8),
                      HTTPURLResponse(url: LicenseValidatorTests.server, statusCode: status,
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

    private func validate(_ settings: AppSettings,
                          _ transport: Transport) async -> LicenseValidator.Result {
        await withCheckedContinuation { continuation in
            LicenseValidator(settings: settings, transport: transport.closure)
                .validate { continuation.resume(returning: $0) }
        }
    }

    @Test func noLicenseServerAsksNothing() async {
        let settings = AppSettings(defaults: defaults)
        settings.licenseKey = Self.key
        let transport = Transport()

        #expect(await validate(settings, transport) == .noServer)
        #expect(transport.requests.isEmpty, "a build from source never reaches the network")
    }

    @Test func noKeyAsksNothing() async {
        let settings = AppSettings(defaults: defaults, licenseServerURL: Self.server)
        // licenseKey left unset
        let transport = Transport()

        #expect(await validate(settings, transport) == .noKey)
        #expect(transport.requests.isEmpty)
    }

    @Test func anActiveAnswerWritesStatusCanonicalKeyAndMaxMajor() async throws {
        let settings = AppSettings(defaults: defaults, licenseServerURL: Self.server)
        settings.licenseKey = "audt-aaaaa-bbbbb-ccccc-ddddd"
        let transport = Transport()
        transport.stub(status: 200,
                       json: #"{"status":"active","key":"\#(Self.key)","max_major":1}"#)

        #expect(await validate(settings, transport) == .verified(.active))
        #expect(settings.licenseStatus == .active)
        #expect(settings.licenseKey == Self.key, "the server's spelling of the key wins")
        #expect(settings.licenseMaxMajor == 1)

        let request = try #require(transport.requests.first)
        #expect(request.url == URL(string: "https://license.example.com/v1/validate"))
        #expect(request.httpMethod == "POST")
        #expect(request.timeoutInterval == 10, "never the 60s default: nothing waits on this answer")
        let body = try #require(request.httpBody)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["license_key"] as? String == "audt-aaaaa-bbbbb-ccccc-ddddd")
    }

    /// The user retyped the key while the server was still answering about
    /// the old one: that answer is about nothing in the field any more.
    @Test func anAnswerForAKeyTheUserHasSinceReplacedIsDropped() async {
        let settings = AppSettings(defaults: defaults, licenseServerURL: Self.server)
        settings.licenseKey = Self.key
        let transport = Transport()
        transport.answer = (nil, nil, nil)
        let held = Held()
        let validator = LicenseValidator(settings: settings) { request, completion in
            held.completion = completion
            transport.closure(request, { _, _, _ in })
        }
        let result = Task { await withCheckedContinuation { c in validator.validate { c.resume(returning: $0) } } }
        while held.completion == nil { await Task.yield() }

        settings.licenseKey = "AUDT-ZZZZZ-ZZZZZ-ZZZZZ-ZZZZZ"
        held.completion?(Data(#"{"status":"active","key":"\#(Self.key)","max_major":1}"#.utf8),
                         HTTPURLResponse(url: Self.server, statusCode: 200, httpVersion: nil, headerFields: nil),
                         nil)

        #expect(await result.value == .unreachable)
        #expect(settings.licenseKey == "AUDT-ZZZZZ-ZZZZZ-ZZZZZ-ZZZZZ", "the newer key is not overwritten")
        #expect(settings.licenseStatus == nil)
    }

    private final class Held: @unchecked Sendable {
        var completion: ((Data?, URLResponse?, Error?) -> Void)?
    }

    @Test func aTransportErrorLeavesEverySettingUntouched() async {
        let settings = AppSettings(defaults: defaults, licenseServerURL: Self.server)
        settings.licenseKey = Self.key
        settings.licenseStatus = .active
        settings.licenseMaxMajor = 1
        let transport = Transport()
        transport.answer = (nil, nil, URLError(.notConnectedToInternet))

        #expect(await validate(settings, transport) == .unreachable)
        #expect(settings.licenseStatus == .active, "the last known answer stands — the check is soft")
        #expect(settings.licenseKey == Self.key)
        #expect(settings.licenseMaxMajor == 1)
    }

    @Test func anUnknownAnswerSetsTheStatusWithoutTouchingTheKey() async {
        let settings = AppSettings(defaults: defaults, licenseServerURL: Self.server)
        settings.licenseKey = "not-a-real-key"
        let transport = Transport()
        transport.stub(status: 200, json: #"{"status":"unknown"}"#)

        #expect(await validate(settings, transport) == .verified(.unknown))
        #expect(settings.licenseStatus == .unknown)
        #expect(settings.licenseKey == "not-a-real-key",
                "no canonical key in the answer ⇒ the typed one stays as typed")
        #expect(settings.licenseMaxMajor == nil)
    }

    @Test func anActiveAnswerWithATokenStoresTheCompanionToken() async {
        let settings = AppSettings(defaults: defaults, licenseServerURL: Self.server)
        settings.licenseKey = Self.key
        let transport = Transport()
        transport.stub(status: 200,
                       json: #"{"status":"active","companion_token":"tok-123"}"#)

        #expect(await validate(settings, transport) == .verified(.active))
        #expect(settings.companionToken == "tok-123")
    }

    @Test func anActiveAnswerWithNoTokenLeavesTheStoredTokenUntouched() async {
        let settings = AppSettings(defaults: defaults, licenseServerURL: Self.server)
        settings.licenseKey = Self.key
        settings.companionToken = "stale-token"
        let transport = Transport()
        transport.stub(status: 200, json: #"{"status":"active"}"#)

        #expect(await validate(settings, transport) == .verified(.active))
        #expect(settings.companionToken == "stale-token",
                "old server or unconfigured secret — expiry bounds the staleness")
    }

    @Test func aNonActiveVerifiedAnswerClearsTheCompanionToken() async {
        let settings = AppSettings(defaults: defaults, licenseServerURL: Self.server)
        settings.licenseKey = Self.key
        settings.companionToken = "will-be-revoked"
        let transport = Transport()
        transport.stub(status: 200, json: #"{"status":"revoked"}"#)

        #expect(await validate(settings, transport) == .verified(.revoked))
        #expect(settings.companionToken == nil, "revocation bites")
    }

    // MARK: A trial is a licence key

    private static let paidKey = "AUDT-PPPPP-QQQQQ-RRRRR-SSSSS"
    private static let trialStarted = Date(timeIntervalSince1970: 1_800_000_000)
    private static let trialExpires = trialStarted.addingTimeInterval(TrialClock.length)

    /// A registered trial, as `TrialClock.apply` leaves it: the server's two
    /// dates and the trial key it handed back.
    private func settingsMidTrial() -> AppSettings {
        let settings = AppSettings(defaults: defaults, licenseServerURL: Self.server)
        TrialClock.apply(settings: settings,
                         startedAt: Self.trialStarted,
                         expiresAt: Self.trialExpires,
                         key: Self.key)
        return settings
    }

    /// An active trial's answer carries two fields a paid key's never does.
    /// Red if either stopped being read, or if reading them cost the fields
    /// that were already working.
    @Test func anActiveTrialAnswerStoresTheServersExpiryAndTouchesNothingElse() async {
        let settings = settingsMidTrial()
        settings.licenseReason = "stale"
        let transport = Transport()
        // A day later than the local record: the server's date is the one that
        // counts, so this is the answer to a clock that ran backwards.
        let corrected = Self.trialExpires.addingTimeInterval(86_400)
        transport.stub(status: 200,
                       json: #"{"status":"active","key":"\#(Self.key)","max_major":1,"kind":"trial","expires_at":"2027-01-30T08:00:00.000Z","companion_token":"tok-trial"}"#)

        #expect(await validate(settings, transport) == .verified(.active))
        #expect(settings.trialExpiresAt == corrected, "the server's expiry replaces the local one")
        #expect(settings.licenseReason == nil, "an answer with no reason clears the last one")
        #expect(settings.licenseKey == Self.key)
        #expect(settings.licenseMaxMajor == 1)
        #expect(settings.companionToken == "tok-trial")
        #expect(TrialClock.state(settings: settings, now: corrected.addingTimeInterval(-86_400))
                == .active(daysLeft: 1, expiresAt: corrected, registered: true))
    }

    /// The server may send the expiry with or without fractional seconds. Red
    /// if the whole-second spelling started reading as "no expiry", which
    /// would silently end a running trial.
    @Test func anExpiryWithoutFractionalSecondsIsStillADate() async {
        let settings = settingsMidTrial()
        let transport = Transport()
        transport.stub(status: 200,
                       json: #"{"status":"active","kind":"trial","expires_at":"2027-01-29T08:00:00Z"}"#)

        #expect(await validate(settings, transport) == .verified(.active))
        #expect(settings.trialExpiresAt == Self.trialExpires)
    }

    /// A trial converts by the server answering with the PAID key and none of
    /// the trial fields. Red if the swap stopped reading as an ordinary paid
    /// activation — a buyer would keep the trial pill and its countdown.
    @Test func aConvertedTrialBecomesAnOrdinaryPaidKey() async {
        let settings = settingsMidTrial()
        let transport = Transport()
        transport.stub(status: 200,
                       json: #"{"status":"active","key":"\#(Self.paidKey)","max_major":1}"#)

        #expect(await validate(settings, transport) == .verified(.active))
        #expect(settings.licenseKey == Self.paidKey, "the paid key replaces the trial key")
        #expect(settings.licenseStatus == .active, "the swap reads as verified, not as a fresh unknown key")
        #expect(settings.trialExpiresAt == nil, "no expiry in the answer ⇒ this Mac is no longer on trial")
        #expect(TrialClock.state(settings: settings, now: Self.trialStarted) == .none)
        #expect(!LicenseGate.shouldPresent(settings: settings, presentation: .auto))
    }

    /// A trial ends by the server saying so, and the gate is what the user
    /// then meets. Red if the reason stopped being stored — the expired gate
    /// cannot tell a spent trial from a refunded key without it — or if the
    /// gate stopped coming back.
    @Test func aSpentTrialIsRevokedWithAReasonAndTheGateReturns() async {
        let settings = settingsMidTrial()
        let transport = Transport()
        transport.stub(status: 200,
                       json: #"{"status":"revoked","key":"\#(Self.key)","reason":"trial_expired","expires_at":"2027-01-29T08:00:00Z"}"#)

        #expect(await validate(settings, transport) == .verified(.revoked))
        #expect(settings.licenseReason == "trial_expired")
        #expect(TrialClock.state(settings: settings, now: Self.trialExpires.addingTimeInterval(1))
                == .expired(expiresAt: Self.trialExpires))
        #expect(LicenseGate.shouldPresent(settings: settings, presentation: .auto))
    }

    /// The mechanism the conversion rides on, pinned here because nothing else
    /// would fail if it changed: the validator writes the status and THEN the
    /// server's key, so a key setter that reset the status on any new value
    /// would turn every converted trial into an unverified key and gate the
    /// buyer. Only clearing the key clears the verdict.
    @Test func aDifferentKeyKeepsTheVerdictAlreadyWritten() {
        let settings = AppSettings(defaults: defaults)
        settings.licenseKey = Self.key
        settings.licenseStatus = .active

        settings.licenseKey = Self.paidKey
        #expect(settings.licenseStatus == .active,
                "the swap must read as verified and active, not as an unverified new key")

        settings.licenseKey = nil
        #expect(settings.licenseStatus == nil, "only a deleted key clears the verdict")
    }
}
