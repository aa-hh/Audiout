// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudioutCore

/// `RemoteAppConfig` and `RemoteAppConfigFetcher`
/// (`Sources/AudioutCore/RemoteAppConfig.swift`) — the website's
/// `app-config.json`. Modelled on `LicenseValidatorTests`: a recording
/// transport and an in-memory defaults store keep this off the network.
///
/// The rule every test here defends is that only a valid file changes what is
/// stored. A bad version, junk, a server error and a dead network all leave
/// the last good file exactly where it was, so a flaky fetch can never turn the
/// waiver on or off.
@Suite(.serialized) struct RemoteAppConfigTests {

    private let isolation = TestIsolation(owner: "RemoteAppConfigTests")

    /// The fetcher remembers its last attempt in a shared static, so each test
    /// starts with it cleared and the suite runs one test at a time.
    init() { RemoteAppConfigFetcher.resetAttemptsForTesting() }
    private var defaults: UserDefaults { isolation.isolatedDefaults }

    private static let valid = Data(#"{"v": 1, "mac": {"licenseCheck": {"disabled": true, "upToBuild": null}}}"#.utf8)

    /// Collects what the fetcher asked for and answers with a canned reply.
    /// A class because the transport closure escapes into the fetcher.
    private final class Transport: @unchecked Sendable {
        private(set) var requests: [URLRequest] = []
        var answer: (Data?, URLResponse?, Error?) = (nil, nil, nil)

        func stub(status: Int, body: Data) {
            answer = (body,
                      HTTPURLResponse(url: RemoteAppConfig.url, statusCode: status,
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

    private func refresh(_ settings: AppSettings, _ transport: Transport,
                         minimumInterval: TimeInterval = 0,
                         now: @escaping () -> Date = Date.init) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            RemoteAppConfigFetcher(settings: settings, transport: transport.closure, now: now)
                .refresh(minimumInterval: minimumInterval) { continuation.resume() }
        }
    }

    // MARK: Parsing

    /// Red if the parser started accepting a file whose version is not exactly
    /// the number 1 (including `true`, which Swift bridges to 1), or text that
    /// is not a JSON object: the cached file would then be replaced by
    /// something this build cannot read.
    @Test func parseRefusesWhatItCannotRead() {
        #expect(RemoteAppConfig.parse(Data(#"{"v": 2}"#.utf8)) == nil)
        #expect(RemoteAppConfig.parse(Data(#"{"v": "1"}"#.utf8)) == nil)
        #expect(RemoteAppConfig.parse(Data(#"{"v": true}"#.utf8)) == nil)
        #expect(RemoteAppConfig.parse(Data("{}".utf8)) == nil)
        #expect(RemoteAppConfig.parse(Data("[1]".utf8)) == nil)
        #expect(RemoteAppConfig.parse(Data("<html>".utf8)) == nil)
        #expect(RemoteAppConfig.parse(Data()) == nil)
    }

    /// Red if a version-1 file with no `mac` section, or one whose `disabled`
    /// is the number 1 rather than the boolean true, switched anything off:
    /// a missing, unknown or wrongly typed key has to mean normal behaviour.
    @Test func aBareVersionOneFileSwitchesNothingOff() throws {
        let bare = try #require(RemoteAppConfig.parse(Data(#"{"v": 1}"#.utf8)))
        #expect(!bare.licenseCheckDisabled(build: 1))

        let off = try #require(RemoteAppConfig.parse(
            Data(#"{"v": 1, "mac": {"licenseCheck": {"disabled": false, "upToBuild": null}}}"#.utf8)))
        #expect(!off.licenseCheckDisabled(build: 1))

        let number = try #require(RemoteAppConfig.parse(
            Data(#"{"v": 1, "mac": {"licenseCheck": {"disabled": 1, "upToBuild": null}}}"#.utf8)))
        #expect(!number.licenseCheckDisabled(build: 1))
    }

    /// Red if a cut-off that is not a whole number (text, or a boolean that
    /// Swift would bridge to 1) started waiving builds, which would let a typo
    /// in the file switch the check off for everyone.
    @Test func aCutOffThatIsNotAWholeNumberSwitchesNothingOff() throws {
        let typo = try #require(RemoteAppConfig.parse(
            Data(#"{"v": 1, "mac": {"licenseCheck": {"disabled": true, "upToBuild": "ten"}}}"#.utf8)))
        #expect(!typo.licenseCheckDisabled(build: 1))

        let boolean = try #require(RemoteAppConfig.parse(
            Data(#"{"v": 1, "mac": {"licenseCheck": {"disabled": true, "upToBuild": true}}}"#.utf8)))
        #expect(!boolean.licenseCheckDisabled(build: 1))
    }

    // MARK: Fetching

    /// Red if a 200 with a valid body stopped storing the body and the fetch
    /// time, or if the request lost its 5 second timeout or its refusal to
    /// read the local cache.
    @Test func aValidFileIsStoredWithItsFetchTime() async {
        let settings = AppSettings(defaults: defaults)
        let transport = Transport()
        transport.stub(status: 200, body: Self.valid)

        await refresh(settings, transport)

        #expect(settings.remoteConfigData == Self.valid)
        #expect(settings.remoteConfigFetchedAt != nil)
        #expect(transport.requests.count == 1)
        #expect(transport.requests.first?.url == RemoteAppConfig.url)
        #expect(transport.requests.first?.timeoutInterval == 5)
        #expect(transport.requests.first?.cachePolicy == .reloadIgnoringLocalCacheData)
    }

    /// Red if a server error, a dead network or a 200 with an unreadable body
    /// started overwriting the stored file or its fetch time: a bad fetch would
    /// then change what the app does.
    @Test func aFailedFetchWritesNothing() async {
        let serverError = Transport()
        serverError.stub(status: 500, body: Self.valid)

        let deadNetwork = Transport()
        deadNetwork.answer = (nil, nil, URLError(.notConnectedToInternet))

        let junk = Transport()
        junk.stub(status: 200, body: Data("<html>captive portal</html>".utf8))

        for transport in [serverError, deadNetwork, junk] {
            let settings = AppSettings(defaults: isolation.makeDefaults())
            await refresh(settings, transport)

            #expect(transport.requests.count == 1)
            #expect(settings.remoteConfigData == nil)
            #expect(settings.remoteConfigFetchedAt == nil)
        }
    }

    /// Red if a failed fetch cleared the file already stored: the last good
    /// copy has to stay in force.
    @Test func aFailedFetchKeepsTheLastGoodFile() async {
        let settings = AppSettings(defaults: defaults)
        let earlier = Date(timeIntervalSinceNow: -2 * 86_400)
        settings.remoteConfigData = Self.valid
        settings.remoteConfigFetchedAt = earlier
        let transport = Transport()
        transport.stub(status: 500, body: Data())

        await refresh(settings, transport)

        #expect(settings.remoteConfigData == Self.valid)
        #expect(settings.remoteConfigFetchedAt == earlier)
    }

    /// Red if `minimumInterval` stopped holding back a fetch when the stored
    /// file is newer than it, or started holding one back when it is older:
    /// the popover would then hit the website on every open, or never refresh.
    @Test func minimumIntervalSkipsOnlyAFreshFile() async {
        let settings = AppSettings(defaults: defaults)
        settings.remoteConfigData = Self.valid
        let transport = Transport()
        transport.stub(status: 200, body: Self.valid)

        settings.remoteConfigFetchedAt = Date(timeIntervalSinceNow: -600)
        await refresh(settings, transport, minimumInterval: 3600)
        #expect(transport.requests.isEmpty, "a file ten minutes old is fresh enough")

        settings.remoteConfigFetchedAt = Date(timeIntervalSinceNow: -7200)
        await refresh(settings, transport, minimumInterval: 3600)
        #expect(transport.requests.count == 1, "a file two hours old is asked for again")
    }

    /// Red if a failed fetch stopped counting as an attempt, so an unreachable
    /// website would be asked again on every popover open instead of once an
    /// hour.
    @Test func aFailedFetchIsNotRetriedWithinTheMinimumInterval() async {
        let settings = AppSettings(defaults: defaults)
        let transport = Transport()
        transport.stub(status: 500, body: Data())
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        await refresh(settings, transport, minimumInterval: 3600, now: { start })
        await refresh(settings, transport, minimumInterval: 3600, now: { start.addingTimeInterval(600) })

        #expect(transport.requests.count == 1)
        #expect(settings.remoteConfigFetchedAt == nil)
    }
}
