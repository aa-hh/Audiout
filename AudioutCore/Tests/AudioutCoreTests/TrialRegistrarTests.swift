// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudioutCore

/// `TrialRegistrar` (`Sources/AudioutCore/TrialRegistrar.swift`) — the one call
/// that tells the licence server about a trial this Mac started on its own.
/// Modelled on `LicenseValidatorTests`: a recording transport plus a throwaway
/// `UserDefaults` suite keep this off both the network and `.standard`.
///
/// Two rules are under defense here. It asks only when there is something to
/// ask about — no trial, an expired one, or one already registered sends
/// nothing, so a registered Mac never keeps knocking. And only a complete 200
/// changes stored state: an error or a junk body leaves the local trial exactly
/// as it was, still counting down, free to ask again later.
@Suite struct TrialRegistrarTests {

    private let isolation = TestIsolation(owner: "TrialRegistrarTests")
    private var defaults: UserDefaults { isolation.isolatedDefaults }

    private static let server = URL(string: "https://license.example.com")!
    private static let key = "AUDT-AAAAA-BBBBB-CCCCC-DDDDD"
    /// Yesterday, on the second. `registerIfNeeded` reads the wall clock — it
    /// takes no `now` — so a trial these tests want running has to be running
    /// at the real current time, and a fixed epoch date would eventually drift
    /// to the wrong side of it. Whole seconds because the stored dates round
    /// trip through ISO 8601 text, and a comparison against a `Date()` carrying
    /// sub-millisecond precision would miss.
    private static let started = Date(
        timeIntervalSince1970: (Date().timeIntervalSince1970 - 86_400).rounded()
    )

    /// Collects what the registrar asked for and answers with a canned reply.
    /// A class because the transport closure escapes into the registrar.
    private final class Transport: @unchecked Sendable {
        private(set) var requests: [URLRequest] = []
        var answer: (Data?, URLResponse?, Error?) = (nil, nil, nil)
        /// Runs after the request is recorded and before the answer is handed
        /// back, so a test can change the world while the request is in flight.
        var whileInFlight: () -> Void = {}

        func stub(status: Int, json: String) {
            answer = (Data(json.utf8),
                      HTTPURLResponse(url: TrialRegistrarTests.server, statusCode: status,
                                      httpVersion: nil, headerFields: nil),
                      nil)
        }

        var closure: LicenseValidator.Transport {
            { [self] request, completion in
                requests.append(request)
                whileInFlight()
                completion(answer.0, answer.1, answer.2)
            }
        }
    }

    private func register(_ settings: AppSettings, _ transport: Transport) async -> Bool {
        await withCheckedContinuation { continuation in
            TrialRegistrar.registerIfNeeded(settings: settings, transport: transport.closure) {
                continuation.resume(returning: $0)
            }
        }
    }

    /// A Mac mid-trial that the server has not answered about yet — the only
    /// state that produces a request.
    private func unregisteredTrial() -> AppSettings {
        let settings = AppSettings(defaults: defaults, licenseServerURL: Self.server)
        TrialClock.start(settings: settings, now: Self.started)
        return settings
    }

    private static func body(outcome: String) -> String {
        let expires = started.addingTimeInterval(TrialClock.length)
        return #"{"key":"\#(key)","started_at":"\#(AppSettings.serverText(from: started))",""#
            + #"expires_at":"\#(AppSettings.serverText(from: expires))","outcome":"\#(outcome)"}"#
    }

    // MARK: Asking nothing

    /// Red if a Mac that never started a trial started announcing one — the
    /// server would then hold a row for a machine that is not trialling.
    @Test func noTrialAsksNothing() async {
        let settings = AppSettings(defaults: defaults, licenseServerURL: Self.server)
        let transport = Transport()

        #expect(await register(settings, transport) == false)
        #expect(transport.requests.isEmpty)
    }

    /// Red if the registrar kept knocking after the server had answered, which
    /// is one pointless request per launch for the rest of the trial.
    @Test func anAlreadyRegisteredTrialAsksNothing() async {
        let settings = AppSettings(defaults: defaults, licenseServerURL: Self.server)
        TrialClock.apply(settings: settings,
                         startedAt: Self.started,
                         expiresAt: Self.started.addingTimeInterval(TrialClock.length),
                         key: Self.key)
        let transport = Transport()

        #expect(await register(settings, transport) == false)
        #expect(transport.requests.isEmpty)
    }

    /// Red if an expired trial tried to register. There is no second trial, so
    /// there is nothing left to tell the server about.
    @Test func anExpiredTrialAsksNothing() async {
        let settings = AppSettings(defaults: defaults, licenseServerURL: Self.server)
        settings.trialStartedAt = Self.started.addingTimeInterval(-30 * 86_400)
        settings.trialExpiresAt = Self.started.addingTimeInterval(-16 * 86_400)
        let transport = Transport()

        #expect(await register(settings, transport) == false)
        #expect(transport.requests.isEmpty)
    }

    /// Red if a build run from source — which carries no licence server —
    /// started reaching the network.
    @Test func noLicenseServerAsksNothing() async {
        let settings = AppSettings(defaults: defaults)
        TrialClock.start(settings: settings, now: Self.started)
        let transport = Transport()

        #expect(await register(settings, transport) == false)
        #expect(transport.requests.isEmpty)
    }

    /// Red if a key already on file stopped stopping the request. An
    /// unregistered trial holds no key of its own, so one stored here was typed
    /// by the user — and the answer to this request would overwrite their paid
    /// licence with fourteen days, which nothing later puts back.
    @Test func aStoredKeyBlocksRegistration() async {
        let settings = unregisteredTrial()
        settings.licenseKey = Self.key
        let transport = Transport()

        #expect(await register(settings, transport) == false)
        #expect(transport.requests.isEmpty)
        #expect(settings.licenseKey == Self.key)
    }

    /// The same key, arriving in the window the request is open: the user
    /// pastes their licence into the gate while the trial start is on the wire.
    /// Red if the answer were applied on top of it.
    @Test func aKeyThatArrivesDuringTheRequestBlocksTheAnswer() async {
        let settings = unregisteredTrial()
        let transport = Transport()
        transport.stub(status: 200, json: Self.body(outcome: "issued"))
        transport.whileInFlight = { settings.licenseKey = "AUDT-PAID0-PAID0-PAID0-PAID0" }

        #expect(await register(settings, transport) == false)
        #expect(settings.licenseKey == "AUDT-PAID0-PAID0-PAID0-PAID0")
        #expect(!settings.trialRegistered)
    }

    // MARK: The request

    /// Red if the endpoint, the method or any of the three body fields moved.
    /// The server matches a Mac on `device_hash`, so a missing or renamed field
    /// reads there as a brand new machine asking for a brand new trial.
    @Test func anUnregisteredTrialPostsInstallDeviceAndStartDate() async throws {
        let settings = unregisteredTrial()
        let transport = Transport()
        transport.stub(status: 200, json: Self.body(outcome: "issued"))

        #expect(await register(settings, transport) == true)

        #expect(transport.requests.count == 1, "one shot, not a retry loop")
        let request = try #require(transport.requests.first)
        #expect(request.url == URL(string: "https://license.example.com/v1/trial/start"))
        #expect(request.httpMethod == "POST")
        #expect(request.timeoutInterval == 10, "never the 60s default: nothing waits on this answer")
        let body = try #require(request.httpBody)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["install_id"] as? String == settings.installID)
        #expect(object["device_hash"] as? String == DeviceIdentity.deviceHash())
        #expect((object["client_started_at"] as? String)
            .flatMap(AppSettings.date(fromServerText:)) == Self.started)
    }

    // MARK: The answer

    /// Red if any outcome stopped being applied. `refused` carries the row the
    /// server already holds for this Mac just as `issued` does, and that row is
    /// the one that decides — dropping it leaves the Mac asking forever.
    @Test(arguments: ["issued", "resumed", "refused"])
    func everyOutcomeStoresTheServersRecord(outcome: String) async {
        let settings = unregisteredTrial()
        let transport = Transport()
        let serverStarted = Self.started.addingTimeInterval(-2 * 86_400)
        let serverExpires = serverStarted.addingTimeInterval(TrialClock.length)
        transport.stub(status: 200, json: #"""
        {"key":"\#(Self.key)","started_at":"\#(AppSettings.serverText(from: serverStarted))",
         "expires_at":"\#(AppSettings.serverText(from: serverExpires))","outcome":"\#(outcome)"}
        """#)

        #expect(await register(settings, transport) == true)
        #expect(settings.licenseKey == Self.key)
        #expect(settings.trialStartedAt == serverStarted, "the server's dates beat the local ones")
        #expect(TrialClock.state(settings: settings, now: Self.started)
                == .active(daysLeft: 12, expiresAt: serverExpires, registered: true))
    }

    /// Red if a network that is down started ending a trial, or marking it
    /// registered against nothing. The Mac keeps its own dates and asks again
    /// later.
    @Test func aTransportErrorLeavesTheTrialAlone() async {
        let settings = unregisteredTrial()
        let transport = Transport()
        transport.answer = (nil, nil, URLError(.notConnectedToInternet))

        #expect(await register(settings, transport) == false)
        #expect(settings.licenseKey == nil)
        #expect(TrialClock.state(settings: settings, now: Self.started)
                == .active(daysLeft: 14,
                           expiresAt: Self.started.addingTimeInterval(TrialClock.length),
                           registered: false))
    }

    /// Red if a body the registrar cannot read counted as an answer — a captive
    /// portal's login page would then register the trial with no key at all.
    @Test func aMalformedBodyLeavesTheTrialAlone() async {
        let settings = unregisteredTrial()
        let transport = Transport()
        transport.stub(status: 200, json: "<html>sign in to continue</html>")

        #expect(await register(settings, transport) == false)
        #expect(settings.licenseKey == nil)
        #expect(!settings.trialRegistered)
    }

    /// Red if half an answer were stored. A row registered against dates the
    /// server never sent is worse than no registration, because nothing later
    /// goes back to fix it.
    @Test func aBodyMissingTheDatesLeavesTheTrialAlone() async {
        let settings = unregisteredTrial()
        let transport = Transport()
        transport.stub(status: 200, json: #"{"key":"\#(Self.key)","outcome":"issued"}"#)

        #expect(await register(settings, transport) == false)
        #expect(settings.licenseKey == nil)
        #expect(!settings.trialRegistered)
    }

    /// Red if a non-200 were read as an answer. The server rejects a malformed
    /// body with a 400, and that must not mark anything registered.
    @Test func aRejectedRequestLeavesTheTrialAlone() async {
        let settings = unregisteredTrial()
        let transport = Transport()
        transport.stub(status: 400, json: Self.body(outcome: "issued"))

        #expect(await register(settings, transport) == false)
        #expect(settings.licenseKey == nil)
        #expect(!settings.trialRegistered)
    }
}
