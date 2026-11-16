// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Asks the license server what Paddle will charge this buyer
/// (`GET /v1/price`, no query, so the server prices for the country it sees
/// for the caller's address) and holds the answer for this launch.
///
/// Only the answer's `formatted` field is used — Paddle's own display string,
/// shown as it arrives. It counts only when the reply is an HTTP 200 whose
/// JSON object carries `formatted` as a string of 1 through 24 characters with
/// no control characters; any other reply leaves the price unknown.
///
/// One request per launch, answered or not. Nothing is stored: the app never
/// shows a stored or hard-coded price, because one shown after the price or
/// the buyer's country changed would be a guess. With no answer, callers show
/// plain words with no figure. Main queue only.
public final class LocalPrice {
    private let settings: AppSettings
    private let transport: LicenseValidator.Transport
    private var requested = false

    /// The price for this launch; nil until a valid answer arrives.
    public private(set) var formatted: String?

    public init(settings: AppSettings, transport: @escaping LicenseValidator.Transport = LicenseValidator.defaultTransport) {
        self.settings = settings
        self.transport = transport
    }

    /// Asks once per launch. `completion` always lands on the main queue and
    /// receives the current ``formatted``. A build with no license server sends
    /// nothing and does not use up the launch's one request.
    public func fetchOnce(completion: @escaping (String?) -> Void) {
        guard let server = settings.licenseServerURL, !requested else {
            let current = formatted
            DispatchQueue.main.async { completion(current) }
            return
        }
        requested = true
        var request = URLRequest(url: server.appending(path: "v1/price"))
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        transport(request) { data, response, _ in
            let price = Self.formattedPrice(data: data, response: response)
            DispatchQueue.main.async {
                if let price { self.formatted = price }
                completion(self.formatted)
            }
        }
    }

    static func formattedPrice(data: Data?, response: URLResponse?) -> String? {
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let formatted = object["formatted"] as? String,
              (1...24).contains(formatted.count),
              !formatted.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
        else { return nil }
        return formatted
    }
}
