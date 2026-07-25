// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Launch-time override for how the app reads the four OS permission seams
/// (system-audio capture, Local Network, Accessibility, PTP helper), driven by
/// the `AIRPLAY_PERMISSIONS` environment variable — sibling knob to
/// ``BackendKind`` (`AIRPLAY_BACKEND`) and ``SetupPresentation`` (`AIRPLAY_SETUP`).
///
/// ## Why this exists
///
/// macOS keys every TCC grant to the running binary's *code signature*. An
/// ad-hoc-signed build (`codesign --sign -`, the fallback in `make-app.sh` when
/// no Developer ID is present) gets a **new signature on every rebuild**, so a
/// grant the user clicked through for yesterday's binary is orphaned today: the
/// real probes read "denied", onboarding re-opens, and every dev/test iteration
/// pays the re-grant tax. That churn — not any product bug — is what makes
/// permission-dependent iteration unsustainable.
///
/// `AIRPLAY_PERMISSIONS` sidesteps it: `granted` (or `denied`) injects
/// deterministic *simulated* seams so the app's permission-handling logic, the
/// onboarding flow, and everything downstream of a grant can be driven — over
/// and over, in CI or by hand — WITHOUT touching real TCC. The unit suite is
/// already hermetic (it injects fakes directly into ``SetupModel``); this brings
/// the same hermeticity to *running the actual app*.
///
/// ## Honest limit (read before trusting a green run)
///
/// A simulated `.granted` audio probe makes the flow *believe* capture is
/// granted; it does NOT make the Core Audio process tap deliver real samples —
/// that still needs the genuine system grant. So `granted` is for exercising
/// permission LOGIC and UI state (onboarding rows, the reopen-on-revocation
/// audit, per-app route re-push), not for validating that audio actually flows.
/// End-to-end audio still requires a real, stably-signed (Developer ID) build
/// whose grant persists across rebuilds. See `dev/notes` / AGENTS.md.
public enum PermissionMode: Sendable {
    /// No override: read the real OS permissions via the production factories.
    /// The default, so a plain launch behaves exactly as before.
    case system
    /// Inject simulated seams that all report satisfied (audio `.granted`,
    /// Local Network reachable, Accessibility trusted, PTP helper `.enabled`).
    case granted
    /// Inject simulated seams that all report the actionable "not granted"
    /// state (audio `.denied`, Local Network unreachable, Accessibility
    /// untrusted, PTP helper `.requiresApproval`).
    case denied

    public static let environmentVariableName = "AIRPLAY_PERMISSIONS"

    /// Resolve the mode from the environment. Unrecognized values fall back to
    /// `.system` with one stderr warning — a dev/test knob, not user config, so
    /// the same forgiving posture as ``BackendKind/resolved(explicit:environment:)``.
    public static func resolved(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> PermissionMode {
        guard let raw = environment[environmentVariableName]?.lowercased() else { return .system }
        switch raw {
        case "system", "real", "auto", "os":       return .system
        case "granted", "grant", "allow", "yes":   return .granted
        case "denied", "deny", "no":               return .denied
        default:
            FileHandle.standardError.write(
                Data("warning: unrecognized \(environmentVariableName) value \"\(raw)\" — using system\n".utf8))
            return .system
        }
    }

    /// Build the four permission seams for this mode. `.system` hands back the
    /// production factories (the exact objects `AppDelegate` used before this
    /// knob existed); `.granted`/`.denied` hand back the ``Simulated`` seams.
    public func makeProviders() -> PermissionProviders {
        switch self {
        case .system:
            return PermissionProviders(
                audioProbe: AudioCapturePermissionProbeFactory.makeDefault(),
                localNetwork: LocalNetworkPrimerFactory.makeDefault(),
                remoteControl: RemoteControlPrimerFactory.makeDefault(),
                ptpHelper: SMAppServicePTPHelper())
        case .granted:
            return PermissionProviders(
                audioProbe: SimulatedAudioCaptureProbe(status: .granted),
                localNetwork: SimulatedLocalNetworkPrimer(reachable: true),
                remoteControl: SimulatedRemoteControlPrimer(trusted: true),
                ptpHelper: SimulatedPTPHelper(status: .enabled))
        case .denied:
            return PermissionProviders(
                audioProbe: SimulatedAudioCaptureProbe(status: .denied),
                localNetwork: SimulatedLocalNetworkPrimer(reachable: false),
                remoteControl: SimulatedRemoteControlPrimer(trusted: false),
                ptpHelper: SimulatedPTPHelper(status: .requiresApproval))
        }
    }
}

/// The four injected permission seams the app needs, bundled so `AppDelegate`
/// resolves them once (from ``PermissionMode``) and threads the same set into
/// every consumer: both ``SetupModel`` construction sites, the launch-time PTP
/// registration, and `MediaKeyController`'s Accessibility check. One bundle
/// keeps those consumers from each re-deriving the mode (and drifting).
public struct PermissionProviders {
    public let audioProbe: AudioCapturePermissionProbing
    public let localNetwork: LocalNetworkPriming
    public let remoteControl: RemoteControlPriming
    public let ptpHelper: PTPHelperManaging

    public init(audioProbe: AudioCapturePermissionProbing,
                localNetwork: LocalNetworkPriming,
                remoteControl: RemoteControlPriming,
                ptpHelper: PTPHelperManaging) {
        self.audioProbe = audioProbe
        self.localNetwork = localNetwork
        self.remoteControl = remoteControl
        self.ptpHelper = ptpHelper
    }
}

// MARK: - Simulated seams (production, env-selected — not the test fakes)

/// A ``AudioCapturePermissionProbing`` that reports a fixed status without
/// touching Core Audio (no tone, no tap, no prompt). Distinct from
/// ``UnsupportedAudioCaptureProbe`` (which only ever says `.unsupported`) — this
/// carries whatever ``PermissionMode`` chose, and implements the silent read too
/// so the revocation audit sees a stable value rather than `nil`.
public struct SimulatedAudioCaptureProbe: AudioCapturePermissionProbing {
    public let status: PermissionStatus
    public init(status: PermissionStatus) { self.status = status }
    public func probe() async -> PermissionStatus { status }
    public func currentStatusSilently() -> PermissionStatus? { status }
}

/// A ``LocalNetworkPriming`` that reports a fixed reachability without a Bonjour
/// browse (so no real network access, no Local Network prompt).
public struct SimulatedLocalNetworkPrimer: LocalNetworkPriming {
    public let reachable: Bool
    public init(reachable: Bool) { self.reachable = reachable }
    public func probe() async -> Bool { reachable }
}

/// A ``RemoteControlPriming`` that reports a fixed trust state and never opens
/// the Accessibility prompt — so an automated run in `granted`/`denied` mode
/// can't spring a real system dialog.
public struct SimulatedRemoteControlPrimer: RemoteControlPriming {
    public let trusted: Bool
    public init(trusted: Bool) { self.trusted = trusted }
    public func prime() {}
    public func isTrusted() -> Bool { trusted }
}

/// A ``PTPHelperManaging`` that reports a fixed status and never registers a
/// real `SMAppService` daemon (so no Login Items entry appears).
public struct SimulatedPTPHelper: PTPHelperManaging {
    public let simulatedStatus: PTPHelperStatus
    public init(status: PTPHelperStatus) { self.simulatedStatus = status }
    public var status: PTPHelperStatus { simulatedStatus }
    public func register() throws {}
    public func openSystemSettingsLoginItems() {}
}
