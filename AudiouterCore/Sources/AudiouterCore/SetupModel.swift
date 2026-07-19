// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The state of one macOS permission the app needs, as far as we can observe it.
///
/// Note the asymmetry, which the two cases `.requested` and `.unsupported`
/// exist to capture honestly:
///
/// - **Audio capture** (the Core Audio process tap) is *verifiable*: a denied
///   tap is created successfully and simply delivers all-zero buffers (it
///   returns `noErr` either way — it cannot self-report), so ``SetupModel``
///   proves the grant by capturing a known in-process tone and checking the
///   level. That yields a real `.granted` / `.denied`, and `.unsupported` when
///   the OS predates the tap API (< macOS 14.2), where no grant is possible.
/// - **Local Network** has *no* public request-or-check API (Apple TN3179), so it
///   can't be read directly. It IS inferred *functionally*: a brief Bonjour browse
///   that actually reaches the network (sees a service / goes ready) proves the
///   grant, giving a real `.granted`; a browse that gets nowhere leaves `.requested`
///   ("asked, but unproven — no speakers, or denied"). It never reports a hard
///   `.denied`, because "found nothing" can't distinguish denial from an empty
///   network.
/// - **Remote Control** (Accessibility) DOES have a real, public, *silent* status
///   API — `AXIsProcessTrusted()` reads the live value without prompting — so this
///   yields a genuine `.granted`, refreshed on every window focus (a grant the
///   user makes in System Settings shows up when they return; a revocation
///   downgrades it). It reports `.requested` rather than `.denied` when untrusted
///   after asking, since the user hasn't necessarily *refused* — the Accessibility
///   toggle just hasn't been flipped yet.
public enum PermissionStatus: Equatable, Sendable {
    /// Not yet asked (the initial state for every permission).
    case unknown
    /// Confirmed working — only ever set for audio capture (verifiable).
    case granted
    /// Confirmed denied — only ever set for audio capture (verifiable).
    case denied
    /// Prompt was triggered but macOS exposes no way to confirm the outcome
    /// (Local Network, Remote Control). The UI pairs this with a "…enable it in
    /// System Settings" deep link as the fallback path.
    case requested
    /// The capability isn't available on this OS at all (the process-tap API is
    /// macOS 14.2+), so no permission grant could help. Distinct from `.denied`,
    /// which is a fixable user choice — `.unsupported` means "don't offer to fix
    /// it, the advice would be wrong."
    case unsupported
}

/// The OS permissions the first-run flow covers. (The PTP/firewall step is
/// deliberately NOT here — a Developer ID + notarized build is auto-allowed by
/// the macOS Application Firewall's default "allow downloaded signed software",
/// so it needs no onboarding step; see the onboarding AGENTS notes.)
public enum SetupPermission: CaseIterable, Sendable {
    /// "Screen & System Audio Recording" — gates the Core Audio process tap the
    /// app uses to capture what you're hearing so it can send it to speakers.
    case audioCapture
    /// "Local Network" — gates the Bonjour discovery that finds AirPlay speakers.
    case localNetwork
    /// "Accessibility" — gates simulating Mac media-key presses from the
    /// speaker's own transport controls. Primed here AHEAD of the feature that
    /// consumes it (speaker-side remote control isn't merged yet — see
    /// ``RemoteControlPriming``'s doc comment) so the grant is already in place
    /// once it lands.
    case remoteControl
}

/// A System Settings privacy pane the setup flow deep-links to when a permission
/// is denied or unverifiable. The `x-apple.systempreferences:` scheme is the
/// documented way to open a specific pane; the anchors below are the ones macOS
/// 13/14 use. They are best-effort — Apple can rename an anchor between releases
/// — so the opener (``AudiouterOnboardingUI``) falls back to
/// ``privacyRoot`` if a specific pane URL won't open.
public enum SystemSettingsPane: Sendable {
    case screenAndSystemAudioRecording
    case localNetwork
    case accessibility

    /// The `x-apple.systempreferences:` URL that opens this pane.
    public var url: URL {
        switch self {
        case .screenAndSystemAudioRecording:
            return Self.make("Privacy_ScreenCapture")
        case .localNetwork:
            return Self.make("Privacy_LocalNetwork")
        case .accessibility:
            return Self.make("Privacy_Accessibility")
        }
    }

    /// Privacy & Security root — the fallback when a specific anchor won't open.
    public static let privacyRoot = make(nil)

    private static func make(_ anchor: String?) -> URL {
        // These string literals are compile-time-constant and known-valid, so the
        // force-unwrap can never fire; it keeps `url` non-optional for callers.
        let base = "x-apple.systempreferences:com.apple.preference.security"
        return URL(string: anchor.map { "\(base)?\($0)" } ?? base)!
    }
}

/// Launch-time override for whether the first-run flow presents, driven by the
/// `AIRPLAY_SETUP` environment variable (sibling of `AIRPLAY_BACKEND`). This is
/// the testing/debug knob: during development the app is launched over and over,
/// and you don't want to depend on the persisted `hasCompletedSetup` flag (a ✕
/// dismissal doesn't set it, and a bare binary's `UserDefaults` domain can drift)
/// — so `skip` guarantees it stays out of the way, and `force` re-shows it every
/// launch to iterate on the flow itself.
public enum SetupPresentation {
    /// No override: the normal gate (native backend + not yet completed).
    case auto
    /// Always present on launch, ignoring backend + completed flag (`force`).
    case forceShow
    /// Never present on launch (`skip`).
    case forceHide

    public static let environmentVariableName = "AIRPLAY_SETUP"

    /// Resolve the override from the environment. Unrecognized values fall back
    /// to `.auto` with one stderr warning (a dev knob, not user config — same
    /// posture as `BackendKind.resolved`).
    public static func resolved(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SetupPresentation {
        guard let raw = environment[environmentVariableName]?.lowercased() else { return .auto }
        switch raw {
        case "force", "show", "always", "on", "1":  return .forceShow
        case "skip", "hide", "off", "never", "0":    return .forceHide
        case "auto", "default":                       return .auto
        default:
            FileHandle.standardError.write(
                Data("warning: unrecognized \(environmentVariableName) value \"\(raw)\" — using auto\n".utf8))
            return .auto
        }
    }
}

// MARK: - Injected seams

/// Triggers and verifies the system-audio-capture (TCC) permission.
///
/// `probe()` is BOTH the request and the check: on first run creating the tap
/// surfaces the system prompt, and capturing a known in-process tone through it
/// tells granted from denied (a denied tap returns `noErr` + all-zero buffers —
/// see ``PermissionStatus``). There is no separate "request" vs "status" call
/// because macOS provides neither for process taps. The production impl is
/// ``CoreAudioTonePermissionProbe`` (gated on live TCC verification); tests
/// inject a fake that returns a canned status without touching Core Audio.
public protocol AudioCapturePermissionProbing: Sendable {
    /// Fire the prompt (if not yet decided) and report the real outcome.
    func probe() async -> PermissionStatus
}

/// Triggers AND functionally checks the Local Network permission. macOS exposes
/// no status API (TN3179), so the only honest signal is behavioural: run a brief
/// Bonjour browse and report whether it actually reached the network — `true` if
/// it saw a service or the browser went `ready` (a functional proxy for "granted
/// and working"), `false` otherwise. The same browse ALSO surfaces the system
/// prompt when the permission is still undetermined, so probing is both the ask
/// and the check. The production impl is ``LocalNetworkPrimer``; tests inject a
/// fake that returns a canned result.
public protocol LocalNetworkPriming: Sendable {
    /// Browse briefly; return `true` if the local network was reachable.
    func probe() async -> Bool
}

/// Triggers and reads the macOS **Accessibility** permission, needed for a
/// **not-yet-merged** feature: simulating Mac media-key presses when the user
/// presses play/pause/skip on the speaker itself (see
/// `claude/speaker-input-responsiveness-b8123f`). Primed now so the grant is
/// already in place once that feature ships, rather than a cold third prompt later.
///
/// Unlike audio and network, Accessibility has a REAL, public, **silent** status
/// API — `AXIsProcessTrusted()` reads the live value without prompting — so
/// ``isTrusted()`` lets the flow reflect the true current state (including a grant
/// the user made in System Settings while the app is running, picked up on the
/// next status refresh). `prime()` is the separate "ask" that opens the prompt.
/// The production impl is ``RemoteControlPrimer``; tests inject a fake.
public protocol RemoteControlPriming: Sendable {
    /// Open the Accessibility prompt (the `…WithOptions([prompt:true])` variant).
    func prime()
    /// Read the live trust state WITHOUT prompting (`AXIsProcessTrusted()`).
    func isTrusted() -> Bool
}

// MARK: - The flow model

/// Drives the first-run setup/onboarding flow: holds the observable status of
/// each permission, runs the probes, and persists completion. Pure coordination
/// — AppKit-free and hermetically testable (both system seams are injected), so
/// the UI (``AudiouterOnboardingUI``) is a thin renderer over this.
///
/// Main-actor: the UI binds to it directly and `onChange` fires on the main
/// thread. The async `requestAudioCapture()` awaits the (Sendable) probe, which
/// does its Core Audio work off the main actor, then resumes here to publish the
/// result.
@MainActor
public final class SetupModel {

    /// Verifiable audio-capture status. Starts `.unknown`.
    public private(set) var audioStatus: PermissionStatus = .unknown

    /// Local-network status. Starts `.unknown`, becomes `.requested` once the
    /// prompt is triggered (never `.granted` on its own — see ``PermissionStatus``).
    public private(set) var localNetworkStatus: PermissionStatus = .unknown

    /// Remote-control (Accessibility) status. Starts `.unknown`, becomes
    /// `.requested` once primed (never `.granted` on its own — see
    /// ``PermissionStatus``). Primes ahead of the feature that needs it; see
    /// ``RemoteControlPriming``.
    public private(set) var remoteControlStatus: PermissionStatus = .unknown

    /// True while an audio probe is running, so the UI can show progress and
    /// ignore repeat taps. The probe blocks ~250 ms capturing the test tone.
    public private(set) var isProbingAudio = false

    /// Fired (on the main actor) after any observable change, so the UI repaints.
    public var onChange: (() -> Void)?

    private let audioProbe: AudioCapturePermissionProbing
    private let localNetwork: LocalNetworkPriming
    private let remoteControl: RemoteControlPriming
    private let settings: AppSettings

    public init(audioProbe: AudioCapturePermissionProbing,
                localNetwork: LocalNetworkPriming,
                remoteControl: RemoteControlPriming,
                settings: AppSettings = AppSettings()) {
        self.audioProbe = audioProbe
        self.localNetwork = localNetwork
        self.remoteControl = remoteControl
        self.settings = settings
    }

    /// Trigger + verify the audio-capture permission. On first run this surfaces
    /// the system prompt; either way it lands on a real `.granted` / `.denied` /
    /// `.unsupported`. Idempotent while a probe is in flight (a second call is a
    /// no-op until the first resolves).
    public func requestAudioCapture() async {
        guard !isProbingAudio else { return }
        isProbingAudio = true
        onChange?()

        let result = await audioProbe.probe()

        isProbingAudio = false
        audioStatus = result
        onChange?()
    }

    /// Ask for + functionally check Local Network. The browse fires the system
    /// prompt (if undetermined) and reports whether the network was reachable:
    /// reachable ⇒ `.granted` (it demonstrably works — the case ahh hit, where
    /// it was already allowed and "Requested" was a lie); not reachable ⇒
    /// `.requested` (asked, but we can't prove it — no speakers, or denied).
    public func primeLocalNetwork() async {
        let reachable = await localNetwork.probe()
        localNetworkStatus = reachable ? .granted : .requested
        onChange?()
    }

    /// Ask for Accessibility. Opens the prompt, then reads the REAL live state
    /// (`isTrusted()` is silent) — granted if the user already had it on, else
    /// `.requested` (the prompt only points them at System Settings; the actual
    /// toggle happens there, and ``refreshStatuses()`` picks it up on the next
    /// window focus).
    public func primeRemoteControl() {
        remoteControl.prime()
        remoteControlStatus = remoteControl.isTrusted() ? .granted : .requested
        onChange?()
    }

    /// Re-derive every permission's status from its CURRENT real state, so the
    /// screen reflects reality rather than a stale "requested." Safe to call on
    /// every window focus — deliberately never SPRINGS a prompt on a permission
    /// the user hasn't engaged yet:
    ///
    /// - **Remote Control** always refreshes: `isTrusted()` is a silent read, so a
    ///   grant made in System Settings shows up the moment the window regains key
    ///   (and a revocation downgrades a prior `.granted` back to `.requested`).
    /// - **System Audio** re-probes ONLY if already asked (`.denied`/`.requested`)
    ///   — probing fires the tap/prompt, so we must not do it on an untouched row.
    ///   This is also what catches a grant made in Settings, and quietly resolves
    ///   the first-run race where the initial probe read zeros before the user
    ///   answered the prompt.
    /// - **Local Network** re-probes ONLY if already asked (browsing fires the
    ///   prompt), upgrading `.requested` → `.granted` once discovery works.
    public func refreshStatuses() async {
        // Remote Control — silent, always safe.
        if remoteControl.isTrusted() {
            remoteControlStatus = .granted
        } else if remoteControlStatus == .granted {
            remoteControlStatus = .requested   // revoked in Settings since
        }

        // System Audio — re-probe only a row the user has already engaged, and do
        // it SILENTLY (no `isProbingAudio` spinner): a background re-check on every
        // window focus shouldn't flash a spinner each time. The explicit "Allow…"
        // tap still shows one (see `requestAudioCapture`).
        if audioStatus == .denied || audioStatus == .requested {
            audioStatus = await audioProbe.probe()
        }

        // Local Network — re-probe only if already asked (else browsing prompts).
        if localNetworkStatus != .unknown {
            localNetworkStatus = await localNetwork.probe() ? .granted : .requested
        }

        onChange?()
    }

    /// Re-check ONLY Remote Control via the silent `AXIsProcessTrusted()` read —
    /// cheap enough to poll on a timer while the window waits for the user to flip
    /// the Accessibility toggle in System Settings, which is the one grant that
    /// might land while we're just sitting open (no re-focus). Fires `onChange`
    /// only on an actual transition, so idle polling doesn't churn the UI.
    public func refreshRemoteControlStatus() {
        let next: PermissionStatus
        if remoteControl.isTrusted() {
            next = .granted
        } else if remoteControlStatus == .granted {
            next = .requested   // revoked in Settings since
        } else {
            next = remoteControlStatus
        }
        guard next != remoteControlStatus else { return }
        remoteControlStatus = next
        onChange?()
    }

    /// Mark the flow finished so it doesn't present again on launch. Does NOT
    /// require every permission to be granted — setup is guidance, not a gate;
    /// the app still runs (and re-prompts lazily) if the user skips a grant.
    public func complete() {
        settings.hasCompletedSetup = true
    }

    /// Whether the flow should present at launch.
    ///
    /// The `AIRPLAY_SETUP` override wins first (testing knob — `skip` never shows,
    /// `force` always shows). Otherwise the default gate: only on the native
    /// backend (the sole path that taps audio in-process under the app's own
    /// identity and discovers over the local network — the mock/OwnTone paths
    /// don't need these grants) and only until the user completes it once.
    public static func shouldPresentOnLaunch(
        settings: AppSettings,
        backendKind: BackendKind,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        switch SetupPresentation.resolved(environment: environment) {
        case .forceShow: return true
        case .forceHide: return false
        case .auto:
            guard case .native = backendKind else { return false }
            return !settings.hasCompletedSetup
        }
    }
}
