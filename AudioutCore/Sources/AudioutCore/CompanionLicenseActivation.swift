// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import AudioutProtocol

/// The phone's key path: a phone-bought licence key arrives over the
/// companion link as `.activateLicenseKey`. It validates the way
/// `LicenseSheetViewController.registerTapped` does, with three differences
/// the phone needs: an active paid key already on this Mac is re-checked and
/// kept (refused with `alreadyLicensed`), any answer other than active puts
/// back the Mac's whole previous licence and trial state, and every refusal
/// carries a `CompanionRefusalCode`.
@MainActor
public struct CompanionLicenseActivation {

    private static let unrecognisedLine = "Your Mac didn’t recognise this licence. Tap Restore purchase."
    private static let unreachableLine = "Your Mac couldn’t reach the licence server. Check its internet connection and try again."
    private static let noServerLine = "This copy of Audiout can’t check licences, so it can’t be unlocked from here."

    private let settings: AppSettings
    private let transport: LicenseValidator.Transport?

    public init(settings: AppSettings, transport: LicenseValidator.Transport? = nil) {
        self.settings = settings
        self.transport = transport
    }

    /// Validates and stores `raw` as the settings sheet's Register button
    /// does, then answers with the `CommandResult` the companion server sends
    /// back to the phone.
    public func activate(key raw: String, completion: @escaping (CompanionServer.CommandResult) -> Void) {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.count <= 64, key.hasPrefix("AUDT-") else {
            completion(CompanionServer.CommandResult(applied: false, refusalReason: Self.unrecognisedLine,
                                                     refusalCode: CompanionRefusalCode.unrecognised))
            return
        }

        let canonical = LicenseValidator.canonicalKey(key) ?? key
        // The Mac already holds this exact key, verified: answer applied with
        // no request and no event. Compared in the server's spelling, so the
        // same key typed in another case still matches.
        if canonical == settings.licenseKey, settings.licenseStatus == .active {
            completion(CompanionServer.CommandResult(applied: true))
            return
        }

        // D4: a phone purchase never replaces a paid licence the server still
        // calls active, so the Mac's own key is asked about first.
        if settings.licenseStatus == .active, settings.trialExpiresAt == nil,
           !(settings.licenseKey ?? "").isEmpty {
            makeValidator().validate { result in
                switch result {
                case .verified(.active) where settings.trialExpiresAt == nil:
                    completion(CompanionServer.CommandResult(
                        applied: false, refusalReason: "Your Mac already has its own licence, so it kept it.",
                        refusalCode: CompanionRefusalCode.alreadyLicensed))
                case .unreachable:
                    completion(CompanionServer.CommandResult(
                        applied: false, refusalReason: Self.unreachableLine,
                        refusalCode: CompanionRefusalCode.serverUnreachable))
                case .noServer:
                    completion(CompanionServer.CommandResult(
                        applied: false, refusalReason: Self.noServerLine,
                        refusalCode: CompanionRefusalCode.cannotCheck))
                default:
                    applyPhoneKey(canonical, completion: completion)
                }
            }
            return
        }

        applyPhoneKey(canonical, completion: completion)
    }

    private func makeValidator() -> LicenseValidator {
        transport.map { LicenseValidator(settings: settings, transport: $0) }
            ?? LicenseValidator(settings: settings)
    }

    /// Stores and validates the phone's key, putting the Mac's whole previous
    /// licence and trial state back unless the server calls it active.
    private func applyPhoneKey(_ canonical: String,
                               completion: @escaping (CompanionServer.CommandResult) -> Void) {
        // The validator overwrites these on a verdict, so keep a copy to put
        // back if the new key does not come back active.
        let previous = (key: settings.licenseKey, status: settings.licenseStatus,
                        reason: settings.licenseReason, maxMajor: settings.licenseMaxMajor,
                        companionToken: settings.companionToken,
                        trialStartedAt: settings.trialStartedAt, trialExpiresAt: settings.trialExpiresAt,
                        trialRegistered: settings.trialRegistered,
                        trialBannerThreeDaysShown: settings.trialBannerThreeDaysShown,
                        trialBannerLastDayShown: settings.trialBannerLastDayShown)

        // A different key is an unanswered question: the previous key's
        // verdict must not stand in for it while the server is asked.
        if canonical != settings.licenseKey { settings.licenseStatus = nil }
        settings.licenseKey = canonical

        makeValidator().validate { result in
            let outcome: String
            switch result {
            case .verified(.active): outcome = "active"
            case .verified(let status): outcome = status.rawValue
            case .unreachable: outcome = "unreachable"
            case .noServer: outcome = "no_server"
            case .noKey: outcome = "no_key"
            }
            Analytics.capture("license:key_submitted", ["outcome": outcome, "source": "phone"])
            let reply: CompanionServer.CommandResult
            switch result {
            case .verified(.active):
                reply = CompanionServer.CommandResult(applied: true)
            case .verified(.revoked):
                // `.revoked`'s shared line (the reason, then "buy a new one")
                // names no receipt and no typing, so it reads fine on the
                // phone too — unlike `.unknown`/`.invalid`, which do not.
                reply = CompanionServer.CommandResult(
                    applied: false,
                    refusalReason: LicenseCopy.statusLine(for: .revoked, reason: settings.licenseReason),
                    refusalCode: CompanionRefusalCode.revoked)
            case .verified:
                reply = CompanionServer.CommandResult(applied: false, refusalReason: Self.unrecognisedLine,
                                                      refusalCode: CompanionRefusalCode.unrecognised)
            case .unreachable:
                // An unreachable server is a refusal the phone may retry at
                // once; the Mac keeps what it had.
                reply = CompanionServer.CommandResult(applied: false, refusalReason: Self.unreachableLine,
                                                      refusalCode: CompanionRefusalCode.serverUnreachable)
            case .noServer:
                reply = CompanionServer.CommandResult(applied: false, refusalReason: Self.noServerLine,
                                                      refusalCode: CompanionRefusalCode.cannotCheck)
            case .noKey:
                reply = CompanionServer.CommandResult(applied: false, refusalReason: Self.unrecognisedLine,
                                                      refusalCode: CompanionRefusalCode.unrecognised)
            }
            // Restored only while the stored key is still the phone's: a key
            // typed in Settings during the check must not be overwritten.
            if result != .verified(.active), settings.licenseKey == canonical {
                // The key goes first: setting it to nil clears the trial,
                // which the lines below then put back.
                settings.licenseKey = previous.key
                settings.licenseStatus = previous.status
                settings.licenseReason = previous.reason
                settings.licenseMaxMajor = previous.maxMajor
                settings.companionToken = previous.companionToken
                settings.trialStartedAt = previous.trialStartedAt
                settings.trialExpiresAt = previous.trialExpiresAt
                settings.trialRegistered = previous.trialRegistered
                settings.trialBannerThreeDaysShown = previous.trialBannerThreeDaysShown
                settings.trialBannerLastDayShown = previous.trialBannerLastDayShown
            }
            completion(reply)
        }
    }
}
