// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Re-checks an active licence before the phones' proof of it runs out.
///
/// Without this the Mac asks the server only at launch, so a Mac left running
/// past the end of the licence server's signed proof
/// (``AppSettings/companionToken``) would lock every phone that relies on it.
/// The timings come from the proof's own lifetime: ask once less than half of
/// it remains, hold off a quarter of it after an answer (at most an hour) and
/// check on a timer every quarter (at most 24 hours), never more often than
/// once a minute. For the 14-day production proof that is seven days, an hour
/// and a day, and a staging proof of minutes is re-asked in minutes. A request
/// that got no answer (offline, a 429, a server error) holds off one minute.
///
/// Four triggers call ``refreshIfNeeded()``: the Mac waking, a phone
/// connecting, the timer, and a usable network path appearing. They cannot
/// stack: a request in flight blocks the next, and every finished request
/// holds off further ones. A request with no answer holds off only a minute,
/// so a Mac that tried offline asks again soon after the network returns
/// without sending back to back while the server is down.
///
/// Main queue only, like ``TrialReachability``.
public final class LicenseProofRefresher {

    /// How long before the proof's expiry the Mac starts asking for a new
    /// one, for a 14-day proof and for a proof whose lifetime cannot be read.
    public static let refreshWindow: TimeInterval = 7 * 86_400

    /// The quiet period after an answered request, for a 14-day proof and for
    /// a proof whose lifetime cannot be read.
    public static let minimumInterval: TimeInterval = 3_600

    /// How often the timer checks, for a Mac that never sleeps and never sees a
    /// phone connect, for a 14-day proof and for a proof whose lifetime cannot
    /// be read.
    public static let timerInterval: TimeInterval = 86_400

    /// The least time between requests and between timer checks however
    /// short the proof, and the hold-off after a request with no answer,
    /// which keeps a Mac far under the server's 10 validates per key per
    /// minute.
    public static let shortestInterval: TimeInterval = 60

    private let settings: AppSettings
    private let transport: LicenseValidator.Transport
    private let now: () -> Date
    private let onRefreshed: () -> Void

    private var started = false
    private var inFlight = false
    /// No request before this time: the end of the hold-off after the last
    /// finished request.
    private var holdOffUntil: Date?
    private var timer: Timer?
    /// The proof the timer was last timed for, so a licence change that kept
    /// the same proof leaves the timer alone.
    private var timedToken: String?
    /// When the timer is due, recorded even where no timer is armed (under
    /// tests), so the timing can be checked without one.
    private(set) var timerDue: Date?

    /// `onRefreshed` runs on the main queue after every request this sends,
    /// answered or not, so the host can apply the stored state and push a new
    /// proof to phones.
    public init(settings: AppSettings,
                transport: @escaping LicenseValidator.Transport = LicenseValidator.defaultTransport,
                now: @escaping () -> Date = Date.init,
                onRefreshed: @escaping () -> Void) {
        self.settings = settings
        self.transport = transport
        self.now = now
        self.onRefreshed = onRefreshed
    }

    /// The `exp` claim of a proof, read from its payload without checking the
    /// signature (the phone does that). Nil for anything that is not a proof
    /// with a numeric `exp`.
    static func proofExpiry(_ token: String) -> Date? {
        guard let exp = payload(token)?["exp"] as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: exp.doubleValue)
    }

    /// A proof's payload as a JSON object, unsigned. Nil when it is not two
    /// dot-separated parts whose first decodes to a JSON object.
    private static func payload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        var base64 = String(parts[0])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// When to ask, how long to hold off after an answer, and how often the
    /// timer checks, for one proof.
    struct Timings: Equatable {
        let window: TimeInterval
        let minimumInterval: TimeInterval
        let timerInterval: TimeInterval
    }

    /// The timings for a proof, from its own lifetime (`exp` minus `iat`):
    /// half of it for the window, a quarter of it (at least
    /// ``shortestInterval``) for the hold-off and the timer, each capped at
    /// the 14-day proof's value. The 14-day values when there is no proof or
    /// its lifetime cannot be read.
    static func timings(for token: String?) -> Timings {
        guard let token,
              let payload = payload(token),
              let iat = payload["iat"] as? NSNumber,
              let exp = payload["exp"] as? NSNumber
        else {
            return Timings(window: refreshWindow, minimumInterval: minimumInterval, timerInterval: timerInterval)
        }
        let lifetime = max(0, exp.doubleValue - iat.doubleValue)
        let quarter = max(shortestInterval, lifetime / 4)
        return Timings(window: lifetime / 2,
                       minimumInterval: min(minimumInterval, quarter),
                       timerInterval: min(timerInterval, quarter))
    }

    /// Whether the stored licence is active and its proof is missing,
    /// unreadable, or inside its window from ``timings(for:)``.
    static func needsRefresh(settings: AppSettings, now: Date) -> Bool {
        guard settings.licenseServerURL != nil,
              settings.hasLicenseKey,
              settings.licenseStatus == .active
        else { return false }
        guard let token = settings.companionToken,
              let expiry = proofExpiry(token)
        else { return true }
        return expiry.timeIntervalSince(now) < timings(for: token).window
    }

    /// Arms the triggers and the timer. Called once the launch check has
    /// answered, so it does not ask again straight away.
    public func start() {
        if started { return }
        started = true
        scheduleTimer()
    }

    /// Re-times the timer when the stored proof changed, because a new proof
    /// can have a different lifetime. The host calls it after every licence
    /// change, including every Mixer open, so an unchanged proof must leave
    /// the timer running or a daily Mixer user would never reach it.
    public func licenseDidChange() {
        guard started, settings.companionToken != timedToken else { return }
        scheduleTimer()
    }

    /// One check after the stored proof's timer interval, which then schedules
    /// the next, so each wait follows the proof stored at the time.
    private func scheduleTimer() {
        timer?.invalidate()
        timedToken = settings.companionToken
        let interval = Self.timings(for: timedToken).timerInterval
        timerDue = now().addingTimeInterval(interval)
        guard !HeadlessRuntime.isActive else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.refreshIfNeeded()
            self?.scheduleTimer()
        }
    }

    /// Asks the server about the stored key when the proof needs it, no other
    /// request is in flight, and the last one's hold-off has passed: the
    /// proof's hold-off after an answer, ``shortestInterval`` after none.
    public func refreshIfNeeded() {
        guard started, !inFlight else { return }
        if let holdOffUntil, now() < holdOffUntil { return }
        guard Self.needsRefresh(settings: settings, now: now()) else { return }
        inFlight = true
        LicenseValidator(settings: settings, transport: transport).validate { [weak self] result in
            guard let self else { return }
            self.inFlight = false
            let holdOff: TimeInterval
            if case .verified = result {
                holdOff = Self.timings(for: self.settings.companionToken).minimumInterval
            } else {
                holdOff = Self.shortestInterval
            }
            self.holdOffUntil = self.now().addingTimeInterval(holdOff)
            self.onRefreshed()
        }
    }
}
