// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Asks the license server what it thinks of the stored key
/// (`POST /v1/validate`) and records the answer in ``AppSettings``.
///
/// **The check is SOFT and this type is the reason it stays that way.** It
/// blocks nothing, refuses nothing and fails silently: an unreachable server
/// leaves the last known answer exactly as it was, so a user on a plane sees
/// whatever they saw yesterday rather than being told their key went bad. Only
/// a real 200 from the server ever changes stored state.
///
/// Same shape as ``LicenseCheckIn`` — a struct over an injectable transport, so
/// tests drive every branch without a network.
public struct LicenseValidator {

    /// One request, one callback. Defaults to a real `URLSession` data task;
    /// tests inject a closure that answers from a canned response.
    public typealias Transport = (URLRequest, @escaping (Data?, URLResponse?, Error?) -> Void) -> Void

    /// What the round trip produced. `noServer`/`noKey` mean nothing was even
    /// asked; `unreachable` means the question was asked and no usable answer
    /// came back, which deliberately leaves settings untouched.
    public enum Result: Equatable {
        case verified(LicenseStatus)
        case unreachable
        case noServer
        case noKey
    }

    private let settings: AppSettings
    private let transport: Transport

    public init(settings: AppSettings, transport: @escaping Transport = LicenseValidator.defaultTransport) {
        self.settings = settings
        self.transport = transport
    }

    /// Validates the stored key against the bundle's license server, writing
    /// the server's verdict — and its canonical spelling of the key and the
    /// major version it covers — into ``AppSettings`` when one arrives.
    /// `completion` always lands on the main queue, including on the two
    /// no-request paths, so a caller never has to ask which thread it is on.
    public func validate(completion: @escaping (Result) -> Void) {
        guard let server = settings.licenseServerURL else {
            return finish(.noServer, completion)
        }
        guard let key = settings.licenseKey, !key.isEmpty else {
            return finish(.noKey, completion)
        }

        var request = URLRequest(url: server.appending(path: "v1/validate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["license_key": key])
        // Well under URLSession's 60s default: nothing waits on this answer, but
        // a captive portal that never replies would otherwise leave the Settings
        // pane's "Checking…" line sitting there for a minute.
        request.timeoutInterval = 10

        transport(request) { data, response, _ in
            // Parsed off the main queue; only the write and the callback hop.
            let body = Self.parse(data: data, response: response)
            DispatchQueue.main.async {
                guard let body, let status = body.status else {
                    completion(.unreachable)
                    return
                }
                // The user edited the field while this was in flight: the
                // answer is about a key that is no longer there.
                guard settings.licenseKey == key else {
                    completion(.unreachable)
                    return
                }
                settings.licenseStatus = status
                // The server's spelling of the key wins — it normalises case
                // and separators, so storing it back means the field shows
                // what the receipt shows.
                if let canonical = body.key, !canonical.isEmpty {
                    settings.licenseKey = canonical
                }
                if let maxMajor = body.maxMajor {
                    settings.licenseMaxMajor = maxMajor
                }
                // Unconditional, unlike the two writes above. Both of these
                // fields disappear from the response to MEAN something — the
                // refund window has closed, the key is no longer revoked — so
                // writing them only when present would pin a stale deadline in
                // UserDefaults forever.
                settings.licenseRefundDeadline = body.refundDeadline
                settings.licenseRevokedReason = body.reason
                completion(.verified(status))
            }
        }
    }

    /// A 200 with a body we can read, or `nil` for every other outcome — a
    /// transport error, a non-200, or JSON that isn't the documented shape.
    /// All of those are "no answer", never "the key is bad".
    private static func parse(data: Data?, response: URLResponse?)
        -> (status: LicenseStatus?, key: String?, maxMajor: Int?,
            refundDeadline: Date?, reason: String?)? {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let data,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return ((object["status"] as? String).flatMap(LicenseStatus.init(rawValue:)),
                object["key"] as? String,
                object["max_major"] as? Int,
                timestamp(object["refund_deadline"] as? String),
                object["reason"] as? String)
    }

    /// The server stamps `refund_deadline` with JavaScript's `toISOString()`,
    /// which always carries milliseconds — but the column behind it is plain
    /// text a row could have been seeded by hand, so a stamp without them is
    /// read too. An unreadable stamp is no deadline rather than a wrong one:
    /// the buyer then sees nothing, which is the same as a window that closed.
    private static func timestamp(_ text: String?) -> Date? {
        guard let text else { return nil }
        return withMilliseconds.date(from: text) ?? wholeSeconds.date(from: text)
    }

    private static let withMilliseconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let wholeSeconds = ISO8601DateFormatter()

    private func finish(_ result: Result, _ completion: @escaping (Result) -> Void) {
        DispatchQueue.main.async { completion(result) }
    }

    public static func defaultTransport(_ request: URLRequest,
                                        _ completion: @escaping (Data?, URLResponse?, Error?) -> Void) {
        URLSession.shared.dataTask(with: request, completionHandler: completion).resume()
    }
}
