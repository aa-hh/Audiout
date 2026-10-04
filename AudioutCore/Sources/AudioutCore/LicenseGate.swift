// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The first-open licence gate's decision, and the one-speaker limit that
/// replaced the trial-end gate (owner's call 2026-09-26,
/// dev/notes/unregistered-mode-spec-2026-09-26.md).
///
/// The differentiation is the build, not the user: a purchased build carries
/// `AudioutLicenseServerURL` in its Info.plist (written by scripts/make-app.sh
/// from `AUDIOUT_LICENSE_URL`; required by scripts/make-release.sh), and THAT
/// build is the paid product. A build from source carries no server URL and
/// never sees the gate or the limit — GPL keeps that path free and this type
/// keeps it structurally unreachable there.
///
/// The gate is the first-open welcome for an install with no key and no trial.
/// Everything else the server declines — an ended trial, a refunded or revoked
/// key — keeps running, limited to one speaker (`limitsToOneSpeaker`).
///
/// Both stay offline-tolerant: `licenseUnregistered` treats a stored key with
/// no verdict as registered (the soft-check posture), so a key accepted while
/// the server was unreachable passes and gets verified by the normal launch
/// validation on a later run.
public enum LicenseGate {

    public static func shouldPresent(
        settings: AppSettings,
        presentation: LicenseGatePresentation = .resolved()
    ) -> Bool {
        switch presentation {
        case .forceShow: return true
        case .forceHide: return false
        case .auto:
            guard settings.licenseServerURL != nil,
                  (settings.licenseKey ?? "").isEmpty,
                  case .none = TrialClock.state(settings: settings) else {
                return false
            }
            return true
        }
    }

    /// Whether this install plays on one speaker at a time: an official build
    /// the server declined, or whose trial ended with a verdict on record. A
    /// freshly typed key with no verdict yet (`licenseStatus == nil`) is not
    /// limited — the soft-check posture.
    public static func limitsToOneSpeaker(settings: AppSettings) -> Bool {
        guard settings.licenseServerURL != nil else { return false }
        var declined = settings.licenseUnregistered
        if case .expired = TrialClock.state(settings: settings), settings.licenseStatus != nil {
            declined = true
        }
        return declined && !trialIsRunningWithoutAKey(settings: settings)
    }

    /// Whether the one-time thank-you card is owed: an official build whose
    /// trial converted to a paid key that has not seen it. The popover reads it on open.
    public static func owesThankYouCard(settings: AppSettings) -> Bool {
        settings.licenseServerURL != nil
            && settings.licenseStatus == .active
            && !(settings.licenseKey ?? "").isEmpty
            && settings.trialStartedAt != nil
            && settings.trialExpiresAt == nil
            && !settings.licenseThankYouShown
    }

    /// Whether the one-time usage-counts ask is owed to a converted trial, on
    /// the open after its thank-you card. The host reads it on open.
    public static func owesConversionConsentAsk(settings: AppSettings) -> Bool {
        settings.licenseStatus == .active
            && !(settings.licenseKey ?? "").isEmpty
            && settings.trialStartedAt != nil
            && settings.trialExpiresAt == nil
            && settings.licenseThankYouShown
            && !settings.telemetryAsked
            && !settings.telemetryConversionAskShown
    }

    /// A trial running on this Mac that the licence server has not yet handed a
    /// key back for.
    ///
    /// A trial IS a licence key, so once `TrialRegistrar` has the key the
    /// ordinary rule already treats such a Mac as registered (a stored key with
    /// no verdict is registered). The window this covers is the one before that
    /// key arrives: there is nothing stored for
    /// ``AppSettings/licenseUnregistered`` to read, and without this clause a
    /// Mac on day one of its trial would run limited to one speaker.
    private static func trialIsRunningWithoutAKey(settings: AppSettings) -> Bool {
        guard (settings.licenseKey ?? "").isEmpty else { return false }
        if case .active = TrialClock.state(settings: settings) { return true }
        return false
    }
}

/// Launch-time override for the licence gate, driven by `AUDIOUT_LICENSE_GATE`
/// (sibling of `AIRPLAY_SETUP`). Dev builds carry no licence server, so without
/// `force` the gate is invisible in the whole dev loop — this is how the window
/// itself gets iterated on; `skip` keeps a URL-carrying test build out of the
/// way.
public enum LicenseGatePresentation {
    case auto
    case forceShow
    case forceHide

    public static let environmentVariableName = "AUDIOUT_LICENSE_GATE"

    /// Same posture as `SetupPresentation.resolved`: a dev knob, so an
    /// unrecognized value warns once on stderr and falls back to `.auto`.
    public static func resolved(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> LicenseGatePresentation {
        guard let raw = environment[environmentVariableName]?.lowercased() else { return .auto }
        switch raw {
        case "force", "show", "always", "on", "1":  return .forceShow
        case "skip", "hide", "off", "never", "0":   return .forceHide
        case "auto", "default":                     return .auto
        default:
            FileHandle.standardError.write(
                Data("warning: unrecognized \(environmentVariableName) value \"\(raw)\" — using auto\n".utf8))
            return .auto
        }
    }
}

/// The one wording for what a licence key looks like and for each server
/// verdict — shared by the Settings sheet and the first-open gate so the two
/// surfaces can never drift apart. Plain words; failure lines name the problem
/// and the recovery.
public enum LicenseCopy {

    /// A refused key on a limited install, named by the server's `reason`
    /// (`AppSettings.licenseReason`): the popover's standing note and the
    /// Settings status line both read it, so the two never disagree.
    public static func oneSpeakerKeyRefusedLine(reason: String?) -> String {
        "\(refusedKeyClause(reason: reason)), so Audiout plays on one speaker at a time."
    }

    /// What happened to a refused key, by the server's `reason`, in ONE place:
    /// `oneSpeakerKeyRefusedLine` and `statusLine` both open with it.
    private static func refusedKeyClause(reason: String?) -> String {
        switch reason {
        case "refund": return "This key was refunded"
        case "chargeback": return "This key\u{2019}s payment was reversed"
        default: return "This key was revoked"
        }
    }

    /// The shape of a key, in ONE place — field placeholders and the
    /// `.invalid` verdict both read it. `AUDT` is the prefix the license
    /// worker issues.
    public static let keyFormatHint = "AUDT-XXXXX-XXXXX-XXXXX-XXXXX"

    /// `reason` is the server's `reason` for a `revoked` answer
    /// (`AppSettings.licenseReason`); the line names it rather than lumping
    /// every revocation together. Other statuses ignore it.
    public static func statusLine(for status: LicenseStatus, reason: String?) -> String {
        switch status {
        case .active: return "Registered. Thank you for supporting Audiout."
        case .revoked:
            if reason == "trial_expired" { return "Your trial has ended. Buy Audiout to keep using it." }
            return "\(refusedKeyClause(reason: reason)). Buy a new one to keep using Audiout."
        case .unknown: return "This key isn’t recognized. Check it against your receipt."
        case .invalid: return "That doesn’t look like an Audiout key (\(keyFormatHint))."
        }
    }
}
