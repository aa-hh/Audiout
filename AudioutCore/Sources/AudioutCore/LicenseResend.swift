// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Asks the license server to email a buyer their key again
/// (`POST /v1/resend`) — the "I lost my key" path on the first-open gate.
///
/// **This client learns nothing and reports nothing.** The server ALWAYS
/// answers 202 with a neutral body, whether or not the address ever bought
/// anything (no address enumeration), and its 3-deliveries-a-day throttle is
/// server-side and invisible. So `completion` carries no result: it means
/// "the request is over", nothing more, and the caller's one line of copy is
/// the same for a hit, a miss, a 500 and no network at all.
///
/// Same shape as ``LicenseValidator`` — a struct over an injectable transport,
/// so tests drive it without a network — and the same promise about threads:
/// `completion` always lands on the main queue, including on the two paths
/// that never send anything.
public struct LicenseResend {

    /// One request, one callback. Defaults to a real `URLSession` data task;
    /// tests inject a closure that answers from a canned response.
    public typealias Transport = (URLRequest, @escaping (Data?, URLResponse?, Error?) -> Void) -> Void

    private let settings: AppSettings
    private let transport: Transport

    public init(settings: AppSettings, transport: @escaping Transport = LicenseValidator.defaultTransport) {
        self.settings = settings
        self.transport = transport
    }

    /// Sends one resend request for `email`. Trimmed and lowercased so a
    /// receipt paste ("  Buyer@Example.com ") reaches the server the way the
    /// buyer's account is stored. An address with no `@`, an empty one, or a
    /// build with no license server sends nothing and completes immediately —
    /// there is no error to report, only a caller whose next line is already
    /// written.
    public func request(email: String, completion: @escaping () -> Void) {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !address.isEmpty, address.contains("@"),
              let server = settings.licenseServerURL
        else { return finish(completion) }

        var request = URLRequest(url: server.appending(path: "v1/resend"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["email": address])
        // Same ceiling as the validator: nothing waits on this answer, but a
        // captive portal that never replies must not hold the gate's controls
        // disabled for a minute.
        request.timeoutInterval = 10

        transport(request) { _, _, _ in
            // Nothing to parse: the answer is neutral by design, and no
            // settings are written on this path.
            DispatchQueue.main.async { completion() }
        }
    }

    private func finish(_ completion: @escaping () -> Void) {
        DispatchQueue.main.async { completion() }
    }
}
