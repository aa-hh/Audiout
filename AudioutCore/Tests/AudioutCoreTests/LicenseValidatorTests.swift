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
}
