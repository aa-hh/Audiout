// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudioutCore

/// `LicenseCheckIn` (`Sources/AudioutCore/LicenseCheckIn.swift`, roadmap
/// 054) — telemetry recording licence device spread, never a gate, and never
/// user-toggleable: this is abuse detection (a licence appearing on far more
/// devices than one buyer plausibly owns), so it cannot be something an
/// abuser opts out of (Alec, 2026-08-24). Covers the two-gate no-op paths (no
/// URL configured; no key on file) and the one path that actually sends,
/// asserting the JSON body carries exactly the three documented fields. A
/// recording `send` closure + a throwaway `UserDefaults` suite (the
/// `AppSettingsTests` pattern) keep this off both the network and `.standard`.
@Suite struct LicenseCheckInTests {

    private let isolation = TestIsolation(owner: "LicenseCheckInTests")
    private var defaults: UserDefaults { isolation.isolatedDefaults }

    @Test func noURLSendsNothing() {
        let settings = AppSettings(defaults: defaults)
        settings.licenseKey = "ABCD-1234"
        // checkInURL left unset — this is the absence that keeps the client
        // inert by default; no code path in the app sets it.

        var sent: [URLRequest] = []
        LicenseCheckIn(settings: settings) { sent.append($0) }.checkInIfNeeded()
        #expect(sent.isEmpty)
    }

    @Test func noKeySendsNothing() {
        let settings = AppSettings(defaults: defaults)
        settings.checkInURL = URL(string: "https://example.com/checkin")
        // licenseKey left unset

        var sent: [URLRequest] = []
        LicenseCheckIn(settings: settings) { sent.append($0) }.checkInIfNeeded()
        #expect(sent.isEmpty)
    }

    @Test func keyPlusURLSendsExactlyOneRequestWithTheThreeFieldsNoConsentRequired() throws {
        let settings = AppSettings(defaults: defaults)
        settings.licenseKey = "ABCD-1234"
        settings.checkInURL = URL(string: "https://example.com/checkin")
        let installID = settings.installID

        var sent: [URLRequest] = []
        LicenseCheckIn(settings: settings) { sent.append($0) }.checkInIfNeeded()

        #expect(sent.count == 1)
        let request = try #require(sent.first)
        #expect(request.url == URL(string: "https://example.com/checkin"))
        #expect(request.httpMethod == "POST")

        let body = try #require(request.httpBody)
        let obj = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(obj["license_key"] as? String == "ABCD-1234")
        #expect(obj["install_id"] as? String == installID)
        #expect(obj["app_version"] as? String != nil)
        #expect(obj.count == 3, "exactly the three documented fields, nothing else")
    }
}
