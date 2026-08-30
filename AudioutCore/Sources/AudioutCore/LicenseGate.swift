// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The first-open licence gate's decision: whether this launch must present the
/// blocking "enter your key" window before anything else (owner decision
/// 2026-08-30, superseding the earlier "the app never blocks" line for OFFICIAL
/// builds only).
///
/// The differentiation is the build, not the user: a purchased build carries
/// `AudioutLicenseServerURL` in its Info.plist (written by scripts/make-app.sh
/// from `AUDIOUT_LICENSE_URL`; required by scripts/make-release.sh), and THAT
/// build is the paid product, so it links itself to a licence before it runs. A
/// build from source carries no server URL and never sees the gate — GPL keeps
/// that path free and this type keeps it structurally unreachable there.
///
/// The gate is still offline-tolerant: `licenseUnregistered` treats a stored
/// key with no verdict as registered (the soft-check posture), so a key
/// accepted while the server was unreachable passes the gate and gets verified
/// by the normal launch validation on a later run.
public enum LicenseGate {

    public static func shouldPresent(
        settings: AppSettings,
        presentation: LicenseGatePresentation = .resolved()
    ) -> Bool {
        switch presentation {
        case .forceShow: return true
        case .forceHide: return false
        case .auto:
            return settings.licenseServerURL != nil && settings.licenseUnregistered
        }
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

    /// The shape of a key, in ONE place — field placeholders and the
    /// `.invalid` verdict both read it. `AUDT` is the prefix the license
    /// worker issues.
    public static let keyFormatHint = "AUDT-XXXXX-XXXXX-XXXXX-XXXXX"

    public static func statusLine(for status: LicenseStatus) -> String {
        switch status {
        case .active: return "Registered. Thank you for supporting Audiout."
        case .revoked: return "This key was refunded or revoked. It no longer gets updates."
        case .unknown: return "This key isn’t recognized. Check it against your receipt."
        case .invalid: return "That doesn’t look like an Audiout key (\(keyFormatHint))."
        }
    }
}
