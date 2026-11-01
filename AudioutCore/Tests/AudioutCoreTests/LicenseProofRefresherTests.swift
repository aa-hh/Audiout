// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudioutCore

/// `LicenseProofRefresher`, which re-checks an active licence before the
/// phones' 14-day proof runs out, driven through a fake server and a clock the
/// test moves by hand.
@MainActor
@Suite struct LicenseProofRefresherTests {

    private let isolation = TestIsolation(owner: "LicenseProofRefresherTests")
    private var defaults: UserDefaults { isolation.isolatedDefaults }

    private static let server = URL(string: "https://license.example.com")!
    private static let key = "AUDT-AAAAA-BBBBB-CCCCC-DDDDD"
    private static let now0 = Date(timeIntervalSince1970: 1_800_000_000)
    private static let day: TimeInterval = 86_400

    /// The refresher's `now`, moved by the test.
    private final class Clock: @unchecked Sendable {
        var now = LicenseProofRefresherTests.now0
    }

    /// Collects what the validator asked for and answers with a canned reply.
    /// A class because the transport closure escapes into the validator.
    private final class Transport: @unchecked Sendable {
        private(set) var requests: [URLRequest] = []
        var answer: (Data?, URLResponse?, Error?) = (nil, nil, nil)

        func stub(status: Int, json: String) {
            answer = (Data(json.utf8),
                      HTTPURLResponse(url: LicenseProofRefresherTests.server, statusCode: status,
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

    /// Counts `onRefreshed` calls.
    private final class Counter: @unchecked Sendable {
        var count = 0
    }

    /// An unsigned proof whose payload carries `iat` and `exp`, shaped as the
    /// server mints it: unpadded base64url payload, a dot, a stand-in
    /// signature. With no `iat` it is a 14-day production proof.
    private static func token(exp: Date, iat: Date? = nil) -> String {
        let issued = iat ?? exp.addingTimeInterval(-14 * day)
        let json = "{\"v\":1,\"key_hash\":\"x\",\"iat\":\(Int(issued.timeIntervalSince1970)),\"exp\":\(Int(exp.timeIntervalSince1970))}"
        let payload = Data(json.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return payload + ".c2ln"
    }

    private func settings(token: String?) -> AppSettings {
        let settings = AppSettings(defaults: defaults, licenseServerURL: Self.server)
        settings.licenseKey = Self.key
        settings.licenseStatus = .active
        settings.companionToken = token
        return settings
    }

    private func nearExpirySettings() -> AppSettings {
        settings(token: Self.token(exp: Self.now0.addingTimeInterval(Self.day)))
    }

    private func refresher(_ settings: AppSettings, _ transport: Transport,
                           _ clock: Clock, _ counter: Counter) -> LicenseProofRefresher {
        LicenseProofRefresher(settings: settings, transport: transport.closure,
                              now: { clock.now }, onRefreshed: { counter.count += 1 })
    }

    /// Red if the payload's padding were not restored, the url-safe alphabet
    /// not mapped, or `exp` read from the wrong half of the proof.
    @Test func proofExpiryReadsExpFromTheUnsignedPayload() {
        let proof = "eyJ2IjoxLCJrZXlfaGFzaCI6IngiLCJpYXQiOjE3MzAwMDAwMDAsImV4cCI6MTczMTIwOTYwMH0.c2ln"
        #expect(LicenseProofRefresher.proofExpiry(proof) == Date(timeIntervalSince1970: 1_731_209_600))
        #expect(LicenseProofRefresher.proofExpiry("") == nil)
        #expect(LicenseProofRefresher.proofExpiry("nope") == nil)
        #expect(LicenseProofRefresher.proofExpiry("!!!.c2ln") == nil)
        #expect(LicenseProofRefresher.proofExpiry("eyJ2IjoxfQ.c2ln") == nil)
    }

    /// Red if the seven-day window moved or flipped: a proof would be
    /// refreshed on every trigger, or left until phones lock.
    @Test func aProofIsRefreshedOnlyInsideItsLastSevenDays() {
        let outside = settings(token: Self.token(exp: Self.now0.addingTimeInterval(7 * Self.day + 60)))
        #expect(LicenseProofRefresher.needsRefresh(settings: outside, now: Self.now0) == false)
        let inside = settings(token: Self.token(exp: Self.now0.addingTimeInterval(7 * Self.day - 60)))
        #expect(LicenseProofRefresher.needsRefresh(settings: inside, now: Self.now0) == true)
    }

    /// Red if a 14-day proof's timings change, or a short staging proof kept
    /// them and lapsed between checks.
    @Test func theTimingsFollowTheProofsLifetime() {
        typealias Timings = LicenseProofRefresher.Timings
        let production = Timings(window: 7 * Self.day, minimumInterval: 3_600, timerInterval: 86_400)
        #expect(LicenseProofRefresher.timings(for: Self.token(exp: Self.now0.addingTimeInterval(14 * Self.day),
                                                              iat: Self.now0)) == production)
        #expect(LicenseProofRefresher.timings(for: Self.token(exp: Self.now0.addingTimeInterval(600),
                                                              iat: Self.now0))
                == Timings(window: 300, minimumInterval: 150, timerInterval: 150))
        #expect(LicenseProofRefresher.timings(for: Self.token(exp: Self.now0.addingTimeInterval(120),
                                                              iat: Self.now0))
                == Timings(window: 60, minimumInterval: 60, timerInterval: 60))
        #expect(LicenseProofRefresher.timings(for: nil) == production)
        #expect(LicenseProofRefresher.timings(for: "garbage") == production)
        #expect(LicenseProofRefresher.timings(for: "eyJ2IjoxfQ.c2ln") == production)
    }

    /// Red if the window stopped following the proof's lifetime.
    @Test func aTenMinuteProofIsRefreshedOnlyInItsLastFiveMinutes() {
        let outside = settings(token: Self.token(exp: Self.now0.addingTimeInterval(310),
                                                 iat: Self.now0.addingTimeInterval(-290)))
        #expect(LicenseProofRefresher.needsRefresh(settings: outside, now: Self.now0) == false)
        let inside = settings(token: Self.token(exp: Self.now0.addingTimeInterval(290),
                                                iat: Self.now0.addingTimeInterval(-310)))
        #expect(LicenseProofRefresher.needsRefresh(settings: inside, now: Self.now0) == true)
    }

    /// Red if an active licence with no proof, or one whose expiry cannot be
    /// read, were treated as fresh and never re-asked.
    @Test func anActiveLicenceWithNoReadableProofNeedsRefresh() {
        #expect(LicenseProofRefresher.needsRefresh(settings: settings(token: nil), now: Self.now0) == true)
        #expect(LicenseProofRefresher.needsRefresh(settings: settings(token: "garbage"), now: Self.now0) == true)
    }

    /// Red if the refresher asked about a licence that is not active, or on a
    /// build with no server: those are re-asked elsewhere, or cannot be.
    @Test func onlyAnActiveLicenceWithAServerIsRefreshed() {
        let near = Self.token(exp: Self.now0.addingTimeInterval(Self.day))

        let noServer = AppSettings(defaults: defaults)
        noServer.licenseKey = Self.key
        noServer.licenseStatus = .active
        noServer.companionToken = near
        #expect(LicenseProofRefresher.needsRefresh(settings: noServer, now: Self.now0) == false)

        let noKey = settings(token: near)
        noKey.licenseKey = nil
        #expect(LicenseProofRefresher.needsRefresh(settings: noKey, now: Self.now0) == false)

        for status in [LicenseStatus.revoked, .unknown] {
            let other = settings(token: near)
            other.licenseStatus = status
            #expect(LicenseProofRefresher.needsRefresh(settings: other, now: Self.now0) == false)
        }

        let noVerdict = settings(token: near)
        noVerdict.licenseStatus = nil
        #expect(LicenseProofRefresher.needsRefresh(settings: noVerdict, now: Self.now0) == false)
    }

    /// Red if a trigger before `start()` sent a request, racing the launch
    /// check that `start()` waits for.
    @Test func nothingIsAskedBeforeStart() {
        let transport = Transport()
        let refresher = refresher(nearExpirySettings(), transport, Clock(), Counter())
        refresher.refreshIfNeeded()
        #expect(transport.requests.isEmpty)
    }

    /// Red if the in-flight flag were dropped, so wake and a phone connecting
    /// together sent two requests.
    @Test func aSecondTriggerWhileOneIsInFlightSendsNoRequest() {
        let transport = Transport()
        let refresher = refresher(nearExpirySettings(), transport, Clock(), Counter())
        refresher.start()
        refresher.refreshIfNeeded()
        refresher.refreshIfNeeded()
        #expect(transport.requests.count == 1)
    }

    /// Red if an answered request stopped holding off further requests for an
    /// hour, or held them off for longer.
    @Test func anAnsweredRefreshHoldsOffForAnHour() async {
        let transport = Transport()
        transport.stub(status: 200, json: #"{"status":"active"}"#)
        let clock = Clock()
        let counter = Counter()
        let refresher = refresher(nearExpirySettings(), transport, clock, counter)
        refresher.start()
        refresher.refreshIfNeeded()
        await SuiteWait.until { counter.count == 1 }

        clock.now = Self.now0.addingTimeInterval(59 * 60)
        refresher.refreshIfNeeded()
        #expect(transport.requests.count == 1)

        clock.now = Self.now0.addingTimeInterval(61 * 60)
        refresher.refreshIfNeeded()
        #expect(transport.requests.count == 2)
    }

    /// Red if a short proof kept the one-hour hold-off and lapsed waiting.
    @Test func anAnsweredRefreshOfATenMinuteProofHoldsOffForAQuarterOfItsLife() async {
        let transport = Transport()
        transport.stub(status: 200, json: #"{"status":"active"}"#)
        let clock = Clock()
        let counter = Counter()
        let shortProof = Self.token(exp: Self.now0.addingTimeInterval(120), iat: Self.now0.addingTimeInterval(-480))
        let refresher = refresher(settings(token: shortProof), transport, clock, counter)
        refresher.start()
        refresher.refreshIfNeeded()
        await SuiteWait.until { counter.count == 1 }

        clock.now = Self.now0.addingTimeInterval(149)
        refresher.refreshIfNeeded()
        #expect(transport.requests.count == 1)

        clock.now = Self.now0.addingTimeInterval(151)
        refresher.refreshIfNeeded()
        #expect(transport.requests.count == 2)
    }

    /// Red if the hour started on an unreachable answer, so a Mac that tried
    /// offline waits an hour after the network returns.
    @Test func aFailedRequestDoesNotHoldOff() async {
        let transport = Transport()
        let counter = Counter()
        let refresher = refresher(nearExpirySettings(), transport, Clock(), counter)
        refresher.start()
        refresher.refreshIfNeeded()
        await SuiteWait.until { counter.count == 1 }

        refresher.refreshIfNeeded()
        #expect(transport.requests.count == 2)
    }

    /// Red if a refresh stopped storing the server's new proof, or stopped
    /// reporting so the host could push it to phones.
    @Test func aSuccessfulRefreshStoresTheNewProofAndReports() async {
        let fresh = Self.token(exp: Self.now0.addingTimeInterval(14 * Self.day))
        let transport = Transport()
        transport.stub(status: 200, json: #"{"status":"active","companion_token":"\#(fresh)"}"#)
        let counter = Counter()
        let settings = nearExpirySettings()
        let refresher = refresher(settings, transport, Clock(), counter)
        refresher.start()
        refresher.refreshIfNeeded()
        await SuiteWait.until { counter.count == 1 }

        #expect(settings.companionToken == fresh)
        #expect(LicenseProofRefresher.needsRefresh(settings: settings, now: Self.now0) == false)
    }
}
