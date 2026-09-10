// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Tells the licence server about a trial this Mac started on its own
/// (`POST /v1/trial/start`) and writes the server's record back through
/// ``TrialClock/apply(settings:startedAt:expiresAt:key:)``.
///
/// ``TrialClock`` lets a trial begin with no network at all, which is the
/// reason this type exists as a separate step: the local dates are a
/// placeholder until the server has a row of its own, and only the server's
/// row can hand back the trial's licence key. Until that happens the trial is
/// `.active(registered: false)` — running, but not yet known anywhere else.
///
/// Failure is silent by design. A trial that cannot reach the server keeps
/// counting down locally and asks again later; nothing here surfaces an error,
/// because a user who has just been given fourteen free days has nothing to do
/// about a network that is down.
///
/// Same shape as ``LicenseValidator`` — one call over an injectable transport,
/// so tests drive every branch without a network.
public enum TrialRegistrar {

    /// Registers this Mac's trial if there is one to register.
    ///
    /// Does nothing unless the trial is running and unregistered: a Mac with no
    /// trial, an expired one, or one the server has already answered about all
    /// return `false` through `completion` without a request. `completion`
    /// reports whether the server's record was stored, always on the main
    /// queue, including on the paths that ask nothing.
    ///
    /// A stored key stops it too, and that guard is not redundant with the
    /// state above: an unregistered trial holds no key of its own, so a key
    /// sitting there can only be one the user typed — offline, or into the gate
    /// while this request was in flight. ``TrialClock/apply(settings:startedAt:expiresAt:key:)``
    /// would overwrite it with a trial key, replacing a paid licence with
    /// fourteen days. Checked again when the answer lands, for the key that
    /// arrives mid-flight.
    ///
    /// The server's answer is applied whatever its `outcome` says. All three
    /// outcomes — a trial issued, an existing one resumed, a refused request —
    /// come back with the real dates and key of the row the server holds for
    /// this Mac, and that row is the one that decides, so `refused` is as much
    /// worth storing as `issued`: it is how a Mac learns it already used its
    /// trial up.
    ///
    /// razor: one shot, no retry and no schedule of its own. A caller decides
    /// when to try again — at launch, or when the network comes back. Upgrade
    /// path, if that turns out to miss registrations: a backoff inside this
    /// type, not a retry loop copied into every call site.
    public static func registerIfNeeded(
        settings: AppSettings,
        transport: @escaping LicenseValidator.Transport = LicenseValidator.defaultTransport,
        completion: @escaping (Bool) -> Void = { _ in }
    ) {
        guard case .active(_, _, registered: false) = TrialClock.state(settings: settings),
              (settings.licenseKey ?? "").isEmpty,
              let startedAt = settings.trialStartedAt,
              let server = settings.licenseServerURL
        else {
            return finish(false, completion)
        }

        var request = URLRequest(url: server.appending(path: "v1/trial/start"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "install_id": settings.installID,
            "device_hash": DeviceIdentity.deviceHash(),
            // The local start date, which the server clamps to its own window.
            // Sent so a trial that began offline days ago keeps those days
            // rather than restarting the moment it finds a network.
            "client_started_at": AppSettings.serverText(from: startedAt),
        ])
        // Matches `LicenseValidator`: nothing waits on this answer, and a
        // captive portal that never replies must not hold a task for a minute.
        request.timeoutInterval = 10

        transport(request) { data, response, _ in
            // Parsed off the main queue; only the write and the callback hop.
            let answer = Self.parse(data: data, response: response)
            DispatchQueue.main.async {
                guard let answer, (settings.licenseKey ?? "").isEmpty else {
                    return completion(false)
                }
                TrialClock.apply(settings: settings,
                                 startedAt: answer.startedAt,
                                 expiresAt: answer.expiresAt,
                                 key: answer.key)
                completion(true)
            }
        }
    }

    /// A 200 carrying all three fields the trial needs, or `nil` for every
    /// other outcome — a transport error, a non-200, or a body missing a date
    /// or the key. Storing half an answer would leave the trial registered
    /// against dates nobody agreed on, so a partial body counts as no answer.
    private static func parse(data: Data?, response: URLResponse?)
        -> (key: String, startedAt: Date, expiresAt: Date)? {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let data,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let key = object["key"] as? String, !key.isEmpty,
              let startedAt = (object["started_at"] as? String).flatMap(AppSettings.date(fromServerText:)),
              let expiresAt = (object["expires_at"] as? String).flatMap(AppSettings.date(fromServerText:))
        else { return nil }
        return (key, startedAt, expiresAt)
    }

    private static func finish(_ registered: Bool, _ completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.async { completion(registered) }
    }
}
