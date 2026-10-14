// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The Mac half of the website's `app-config.json`: a static file Alec edits
/// to switch a behaviour off for a range of builds without shipping a release.
/// Today it carries one switch, `mac.licenseCheck`, which waives the
/// one-speaker limit (``LicenseGate/limitsToOneSpeaker(settings:)``) while the
/// licence server is being repaired.
///
/// **A failed fetch never changes anything.** A stale, missing, unparseable or
/// unfamiliar file means normal behaviour, and the Mac never writes a licence
/// or token to stand in for the waiver; it only skips the limit.
public struct RemoteAppConfig {

    public static let url = URL(string: "https://audiout.app/app-config.json")!

    /// How long a fetched file stays in force. After that the limit is back
    /// until a fetch succeeds.
    public static let maxAge: TimeInterval = 7 * 86_400

    private let licenseCheckIsOff: Bool
    private let licenseCheckUpToBuild: Int?

    /// `nil` unless the body is a JSON object whose `v` is 1. Only
    /// `mac.licenseCheck` is read; a missing or malformed key means no switch.
    public static func parse(_ data: Data) -> RemoteAppConfig? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              jsonInt(root["v"]) == 1 else { return nil }
        let check = ((root["mac"] as? [String: Any])?["licenseCheck"]) as? [String: Any]
        var off = jsonBool(check?["disabled"]) == true
        var upTo: Int?
        if let raw = check?["upToBuild"], !(raw is NSNull) {
            // A cut-off that is not a whole number is a typo, and a typo must
            // not waive every build.
            upTo = jsonInt(raw)
            if upTo == nil { off = false }
        }
        return RemoteAppConfig(licenseCheckIsOff: off, licenseCheckUpToBuild: upTo)
    }

    /// JSONSerialization hands back every number and boolean as an NSNumber, and
    /// Swift's `as? Int` / `as? Bool` bridge between them (`true` reads as 1,
    /// `1` reads as true). The phone's JSONDecoder refuses both, so these two
    /// tell them apart by the underlying CFBoolean type.
    private static func isJSONBool(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func jsonInt(_ value: Any?) -> Int? {
        guard let value, !isJSONBool(value) else { return nil }
        return value as? Int
    }

    private static func jsonBool(_ value: Any?) -> Bool? {
        guard let value, isJSONBool(value) else { return nil }
        return value as? Bool
    }

    /// Whether the switch is in force for `build`: `disabled` is true and
    /// there is either no cut-off or the build is at or below it.
    public func licenseCheckDisabled(build: Int) -> Bool {
        guard licenseCheckIsOff else { return false }
        guard let upTo = licenseCheckUpToBuild else { return true }
        return build <= upTo
    }

    /// The running app's `CFBundleVersion` as an integer; 0 when unreadable.
    public static var currentBuild: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0
    }

    /// True only when a stored file parses, was fetched within ``maxAge`` of
    /// `now`, and its licence switch applies to `build`.
    public static func licenseCheckWaived(
        settings: AppSettings,
        build: Int = currentBuild,
        now: Date = Date()
    ) -> Bool {
        guard let data = settings.remoteConfigData,
              let fetchedAt = settings.remoteConfigFetchedAt,
              now.timeIntervalSince(fetchedAt) <= maxAge,
              let config = parse(data) else { return false }
        return config.licenseCheckDisabled(build: build)
    }
}

/// Fetches ``RemoteAppConfig/url`` and stores the body in ``AppSettings`` when
/// it is a valid file. Same shape as ``LicenseValidator``: a struct over an
/// injectable transport, so tests drive every branch without a network.
public struct RemoteAppConfigFetcher {

    private let settings: AppSettings
    private let transport: LicenseValidator.Transport
    private let now: () -> Date

    /// When the last request was sent, successful or not. Kept in memory and
    /// shared by every fetcher, so an unreachable website is asked once per
    /// `minimumInterval`, not on every popover open. Main queue only.
    private nonisolated(unsafe) static var lastAttemptAt: Date?

    static func resetAttemptsForTesting() { lastAttemptAt = nil }

    public init(settings: AppSettings,
                transport: @escaping LicenseValidator.Transport = LicenseValidator.defaultTransport,
                now: @escaping () -> Date = Date.init) {
        self.settings = settings
        self.transport = transport
        self.now = now
    }

    /// Asks for the file unless the stored copy, or the last attempt, is newer
    /// than `minimumInterval` seconds; `minimumInterval: 0` always asks. Only
    /// an HTTP 200 whose body parses writes anything; every other outcome
    /// leaves the stored copy as it was.
    /// `completion` always lands on the main queue, including when no request
    /// is made.
    public func refresh(minimumInterval: TimeInterval = 0, completion: @escaping () -> Void) {
        let current = now()
        let recent = [settings.remoteConfigFetchedAt, Self.lastAttemptAt].contains {
            $0.map { current.timeIntervalSince($0) < minimumInterval } ?? false
        }
        if recent {
            DispatchQueue.main.async(execute: completion)
            return
        }
        Self.lastAttemptAt = current
        var request = URLRequest(url: RemoteAppConfig.url)
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        transport(request) { data, response, _ in
            DispatchQueue.main.async {
                if let data,
                   (response as? HTTPURLResponse)?.statusCode == 200,
                   RemoteAppConfig.parse(data) != nil {
                    settings.remoteConfigData = data
                    settings.remoteConfigFetchedAt = now()
                }
                completion()
            }
        }
    }
}
