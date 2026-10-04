// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudioutCore

/// `CompanionLicenseActivation`, the phone's key path, driven through the
/// same fake server `LicenseValidatorTests` uses.
@MainActor
@Suite struct CompanionLicenseActivationTests {

    private let isolation = TestIsolation(owner: "CompanionLicenseActivationTests")
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
                      HTTPURLResponse(url: CompanionLicenseActivationTests.server, statusCode: status,
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

    /// Red if a revoked answer stopped refusing, or refused with anything
    /// other than the wording `LicenseCopy` shares with the Settings sheet.
    @Test func aRevokedAnswerRefusesWithTheSharedStatusLineAndLeavesTheKeyStored() async {
        let settings = AppSettings(defaults: defaults, licenseServerURL: Self.server)
        let transport = Transport()
        transport.stub(status: 200, json: #"{"status":"revoked","reason":"refund"}"#)

        let result = await activate(settings, Self.key, transport)

        #expect(result == CompanionServer.CommandResult(
            applied: false, refusalReason: LicenseCopy.statusLine(for: .revoked, reason: "refund")))
        #expect(settings.licenseKey == Self.key, "the sheet and the gate both keep a rejected key on file")
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
            applied: false, refusalReason: "Your Mac didn’t recognise this licence. Tap Restore purchase."))
        #expect(settings.licenseKey == nil)
        #expect(transport.requests.isEmpty)
    }
}
