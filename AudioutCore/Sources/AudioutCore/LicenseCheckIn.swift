// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Telemetry recording licence device spread — **never a gate**: the app runs
/// identically whether this ever fires. Ties a licence key to an install so
/// the owner can *see* how widely a licence travels (PRODUCT.md Business Model,
/// 2026-08-12 — "a licence check-in may record how many devices a licence
/// appears on... it is telemetry, not a gate"; Data Collection stream 2 —
/// "License activation check-ins — identified by purchase... not anonymous").
/// GPL-2.0-or-later forbids a usage-restricting lock on this codebase, so
/// there is no enforcement path here to build even if one were wanted.
///
/// razor: fires once per launch, fire-and-forget — no retry, no schedule, no
/// queue. The endpoint is derived from the bundle's license server
/// (`AppSettings.checkInURL`), so a build run from source has none and this
/// never fires at all. Upgrade path, if once-per-launch turns out to under-
/// count: a real schedule, not a queue bolted onto this call.
public struct LicenseCheckIn {

    /// Sends one check-in request. Defaults to firing a real `URLSession` data
    /// task and ignoring its result; tests inject a recording closure instead.
    public typealias Send = (URLRequest) -> Void

    private let settings: AppSettings
    private let send: Send

    public init(settings: AppSettings, send: @escaping Send = LicenseCheckIn.defaultSend) {
        self.settings = settings
        self.send = send
    }

    /// Sends one check-in whenever a licence key is on file (
    /// ``AppSettings/licenseKey``) and a check-in endpoint is configured (
    /// ``AppSettings/checkInURL``) — unconditional, not opt-in: this is
    /// abuse detection (a licence appearing on far more devices than one
    /// buyer plausibly owns), so it cannot be a toggle an abuser simply
    /// turns off, any more than a paid app asks permission before its normal
    /// licence check. Either gate missing is a silent no-op — this must
    /// never surface as an error or a prompt, since it gates no feature. When
    /// both hold, POSTs exactly `{"license_key", "install_id",
    /// "app_version"}` and ignores the response: fire-and-forget, not a
    /// round-trip the app waits on.
    public func checkInIfNeeded() {
        guard let key = settings.licenseKey, !key.isEmpty,
              let url = settings.checkInURL else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "license_key": key,
            "install_id": settings.installID,
            "app_version": Self.appVersion,
        ])
        send(request)
    }

    /// The running app's version, same source as `AboutView`/`Telemetry`'s
    /// banner — never hardcoded.
    private static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }

    public static func defaultSend(_ request: URLRequest) {
        URLSession.shared.dataTask(with: request).resume()
    }
}
