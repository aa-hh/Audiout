// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Re-checks an active licence before the phones' proof of it runs out.
///
/// The licence server's signed proof (``AppSettings/companionToken``) lasts 14
/// days, and without this the Mac asks the server only at launch, so a Mac
/// left running for two weeks would lock every phone that relies on it. This
/// asks again once fewer than seven days remain.
///
/// Four triggers call ``refreshIfNeeded()``: the Mac waking, a phone
/// connecting, a 24-hour timer, and a usable network path appearing. They
/// cannot stack: a request in flight blocks the next, and an answered request
/// holds off further ones for an hour. A request that never reached the server
/// does not start that hour, so a Mac that tried offline asks again as soon as
/// the network returns.
///
/// Main queue only, like ``TrialReachability``.
public final class LicenseProofRefresher {

    /// How long before the proof's expiry the Mac starts asking for a new one.
    public static let refreshWindow: TimeInterval = 7 * 86_400

    /// The quiet period after an answered request.
    public static let minimumInterval: TimeInterval = 3_600

    /// How often the timer checks, for a Mac that never sleeps and never sees a
    /// phone connect.
    public static let timerInterval: TimeInterval = 86_400

    private let settings: AppSettings
    private let transport: LicenseValidator.Transport
    private let now: () -> Date
    private let onRefreshed: () -> Void

    private var started = false
    private var inFlight = false
    private var lastAnsweredAt: Date?
    private var timer: Timer?

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
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        var base64 = String(parts[0])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let exp = object["exp"] as? NSNumber
        else { return nil }
        return Date(timeIntervalSince1970: exp.doubleValue)
    }

    /// Whether the stored licence is active and its proof is missing,
    /// unreadable, or inside its last ``refreshWindow``.
    static func needsRefresh(settings: AppSettings, now: Date) -> Bool {
        guard settings.licenseServerURL != nil,
              settings.hasLicenseKey,
              settings.licenseStatus == .active
        else { return false }
        guard let token = settings.companionToken,
              let expiry = proofExpiry(token)
        else { return true }
        return expiry.timeIntervalSince(now) < refreshWindow
    }

    /// Arms the triggers and the daily timer. Called once the launch check has
    /// answered, so it does not ask again straight away.
    public func start() {
        if started { return }
        started = true
        guard !HeadlessRuntime.isActive else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.timerInterval, repeats: true) { [weak self] _ in
            self?.refreshIfNeeded()
        }
    }

    /// Asks the server about the stored key when the proof needs it and no
    /// other request is in flight or answered within the last hour.
    public func refreshIfNeeded() {
        guard started, !inFlight else { return }
        if let lastAnsweredAt, now().timeIntervalSince(lastAnsweredAt) < Self.minimumInterval { return }
        guard Self.needsRefresh(settings: settings, now: now()) else { return }
        inFlight = true
        LicenseValidator(settings: settings, transport: transport).validate { [weak self] result in
            guard let self else { return }
            self.inFlight = false
            if case .verified = result {
                self.lastAnsweredAt = self.now()
            }
            self.onRefreshed()
        }
    }
}
