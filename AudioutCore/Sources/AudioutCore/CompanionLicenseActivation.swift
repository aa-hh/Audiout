// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The phone's key path: a phone-bought licence key arrives over the
/// companion link as `.activateLicenseKey`, and this runs the same sequence
/// `LicenseSheetViewController.registerTapped` runs for a pasted key. It must
/// stay in step with that method — same validation, same soft-check handling,
/// same "the key is saved either way" rule.
@MainActor
public struct CompanionLicenseActivation {

    private let settings: AppSettings
    private let transport: LicenseValidator.Transport?

    public init(settings: AppSettings, transport: LicenseValidator.Transport? = nil) {
        self.settings = settings
        self.transport = transport
    }

    /// Validates and stores `raw` exactly as the settings sheet's Register
    /// button does, then answers with the `CommandResult` the companion
    /// server sends back to the phone.
    public func activate(key raw: String, completion: @escaping (CompanionServer.CommandResult) -> Void) {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.count <= 64, key.hasPrefix("AUDT-") else {
            completion(CompanionServer.CommandResult(applied: false, refusalReason: "Your Mac didn’t recognise this licence. Tap Restore purchase."))
            return
        }

        // The Mac already holds this exact key, verified: answer applied with
        // no request and no event, so a phone that reconnects and re-sends
        // its stored key on every connection does not re-validate it every time.
        if key == settings.licenseKey, settings.licenseStatus == .active {
            completion(CompanionServer.CommandResult(applied: true))
            return
        }

        // A different key is an unanswered question: the previous key's
        // verdict must not stand in for it while the server is asked.
        if key != settings.licenseKey { settings.licenseStatus = nil }
        settings.licenseKey = key

        let validator = transport.map { LicenseValidator(settings: settings, transport: $0) }
            ?? LicenseValidator(settings: settings)
        validator.validate { result in
            let outcome: String
            switch result {
            case .verified(.active): outcome = "active"
            case .verified(let status): outcome = status.rawValue
            case .unreachable: outcome = "unreachable"
            case .noServer: outcome = "no_server"
            case .noKey: outcome = "no_key"
            }
            Analytics.capture("license:key_submitted", ["outcome": outcome, "source": "phone"])
            switch result {
            case .verified(.active), .unreachable:
                // The key is saved either way, exactly as the sheet and the
                // gate leave it: an unreachable server must not refuse a
                // purchase the phone already confirmed with Apple.
                completion(CompanionServer.CommandResult(applied: true))
            case .verified(.revoked):
                // `.revoked`'s shared line ("refunded or revoked ... buy a new
                // one") names no receipt and no typing, so it reads fine on
                // the phone too — unlike `.unknown`/`.invalid`, which do not.
                completion(CompanionServer.CommandResult(applied: false, refusalReason: LicenseCopy.statusLine(for: .revoked)))
            case .verified:
                completion(CompanionServer.CommandResult(applied: false, refusalReason: "Your Mac didn’t recognise this licence. Tap Restore purchase."))
            case .noServer:
                completion(CompanionServer.CommandResult(applied: false, refusalReason: "This copy of Audiout can’t check licences, so it can’t be unlocked from here."))
            case .noKey:
                completion(CompanionServer.CommandResult(applied: false, refusalReason: "Your Mac didn’t recognise this licence. Tap Restore purchase."))
            }
        }
    }
}
