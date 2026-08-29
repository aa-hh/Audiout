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
///   can't be read directly — but BOTH answers are provable behaviourally, and
///   ``LocalNetworkPrimer`` proves them. The app publishes its own Bonjour
///   service and browses for it:
///   finding itself proves the grant even on a network with no speaker on it, so
///   that's a real `.granted`; a browser going
///   `.waiting(.dns(kDNSServiceErr_PolicyDenied))` is the refusal itself, so
///   that's a real `.denied`. `.requested` now means only what it says — asked,
///   and nothing answered yet (the dialog is presumably still up).
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
    /// Confirmed working. Every permission here can reach this honestly: audio
    /// by capturing its own tone, Local Network by finding its own published
    /// service, Remote Control and Bluetooth by their real status APIs.
    case granted
    /// Confirmed denied — the tone probe's silence, Local Network's mDNS policy
    /// error, or Bluetooth's authorization read. Never inferred from a browse
    /// that merely found nothing.
    case denied
    /// Prompt was triggered and nothing has answered it yet (Local Network's
    /// still-open dialog, Remote Control's un-flipped toggle). The UI pairs this
    /// with a "…enable it in System Settings" deep link as the fallback path.
    case requested
    /// The capability isn't available on this OS at all (the process-tap API is
    /// macOS 14.2+), so no permission grant could help. Distinct from `.denied`,
    /// which is a fixable user choice — `.unsupported` means "don't offer to fix
    /// it, the advice would be wrong."
    case unsupported
}

extension PermissionStatus {
    /// Stable field value for ``Telemetry`` (T5) — an explicit, exhaustive
    /// mapping rather than relying on Swift's default enum description, so a
    /// future added case is a compile error here rather than a silently
    /// unlabeled log line.
    var telemetryDescription: String {
        switch self {
        case .unknown: return "unknown"
        case .granted: return "granted"
        case .denied: return "denied"
        case .requested: return "requested"
        case .unsupported: return "unsupported"
        }
    }
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
    /// "Accessibility" — gates two things now, and the second one is the reason
    /// this stopped being a nicety: simulating Mac media-key presses from the
    /// speaker's own transport controls (``MediaKeyController``), and INTERCEPTING
    /// the volume keys while our aggregate is the Mac's default output
    /// (`AudioutApp/VolumeKeyInterceptor.swift`).
    ///
    /// The difference matters. Posting merely no-ops untrusted; a `CGEventTap`
    /// cannot be created at all. So without this grant the volume keys are dead in
    /// exactly the state where macOS has already stopped handling them itself —
    /// see `docs/plans/PLAN-VOLUME-KEY-INTERCEPTION.md`.
    case remoteControl
    /// "Bluetooth" — gates the IOBluetooth paired list (so a powered-off
    /// speaker keeps its row) and programmatic reconnect. Deliberately absent
    /// from ``RequiredPermission``: without it the app still routes to
    /// AirPlay and to already-connected Bluetooth endpoints, so it must never
    /// block setup or force-reopen it.
    case bluetooth
}

/// A permission the app REQUIRES to operate — as opposed to Remote Control
/// (Accessibility), which is an *enhancement* (speaker-side transport control,
/// see ``RemoteControlPriming``) and is deliberately excluded here. Losing
/// Remote Control never stops the app from playing audio, so it must never
/// force-reopen onboarding; losing one of these three does (see
/// ``SetupModel/unmetRequiredPermissions()``). Locked product decision,
/// 2026-07-21.
public enum RequiredPermission: CaseIterable, Sendable {
    case audioCapture
    case localNetwork
    case ptpHelper
}

/// A System Settings privacy pane the setup flow deep-links to when a permission
/// is denied or unverifiable. The `x-apple.systempreferences:` scheme is the
/// documented way to open a specific pane; the `Privacy_*` anchors below are
/// stable, but the PANE the anchors hang off changed name in macOS 26 (see
/// ``privacySettingsBundleID(osMajorVersion:)``).
///
/// They are BEST-EFFORT, and there is no code-level fallback behind them:
/// `NSWorkspace.open` returns true for any of these URLs the scheme resolves,
/// including one whose anchor misroutes to the wrong pane, so a wrong anchor is
/// indistinguishable from a right one at the call site. What recovers a
/// misroute is the written path in the onboarding ribbon (the "turn Audiout on
/// under Privacy & Security ▸ …" sentence), not a retry.
public enum SystemSettingsPane: Equatable, Sendable {
    case screenAndSystemAudioRecording
    case localNetwork
    case accessibility
    /// Privacy & Security ▸ Bluetooth — the list of apps allowed to use
    /// Bluetooth, i.e. where THIS app's grant is toggled. Distinct from
    /// ``bluetooth`` below, which is the radio's own settings pane and can't
    /// fix a denied grant.
    case bluetoothPrivacy
    /// Not a Privacy anchor — the Bluetooth pane itself. The BT-CONNECT
    /// fallback (PLAN-UNIVERSAL-SYNC Decision 3): when a programmatic
    /// reconnect doesn't resolve, one tap lands the user where pairing and
    /// manual connect live.
    case bluetooth

    /// The `x-apple.systempreferences:` URL that opens this pane on THIS Mac.
    public var url: URL { url(osMajorVersion: Self.liveOSMajorVersion) }

    /// The same URL for an explicit macOS major version — the seam that makes
    /// the macOS 26 rename testable on either side of the boundary (a unit test
    /// can't change the runner's OS).
    public func url(osMajorVersion: Int) -> URL {
        switch self {
        case .screenAndSystemAudioRecording:
            return Self.make("Privacy_ScreenCapture", osMajorVersion: osMajorVersion)
        case .localNetwork:
            return Self.make("Privacy_LocalNetwork", osMajorVersion: osMajorVersion)
        case .accessibility:
            return Self.make("Privacy_Accessibility", osMajorVersion: osMajorVersion)
        case .bluetoothPrivacy:
            return Self.make("Privacy_Bluetooth", osMajorVersion: osMajorVersion)
        case .bluetooth:
            // The Bluetooth RADIO pane, not a Privacy anchor — its own bundle
            // id, unaffected by the Privacy & Security rename.
            return URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!
        }
    }

    /// Privacy & Security root — the anchorless pane URL. Nothing falls back to
    /// it any more (see the type comment); it is kept for callers that want the
    /// root itself.
    public static var privacyRoot: URL { privacyRoot(osMajorVersion: liveOSMajorVersion) }

    /// The root for an explicit macOS major version (same seam as ``url(osMajorVersion:)``).
    public static func privacyRoot(osMajorVersion: Int) -> URL {
        make(nil, osMajorVersion: osMajorVersion)
    }

    /// Which Settings pane the `Privacy_*` anchors hang off, by macOS major
    /// version. macOS 26 moved Privacy & Security into an extension bundle —
    /// `com.apple.settings.PrivacySecurity.extension` — and the pre-26 id
    /// misroutes there (it opens Settings, but not the pane asked for), while
    /// the 26 id is unknown to earlier releases. The anchors themselves did not
    /// change, so only the id is gated.
    static func privacySettingsBundleID(osMajorVersion: Int) -> String {
        osMajorVersion >= 26
            ? "com.apple.settings.PrivacySecurity.extension"
            : "com.apple.preference.security"
    }

    /// This Mac's macOS major version — read once per call, no caching, so a
    /// value that only exists at runtime never gets frozen into a constant.
    private static var liveOSMajorVersion: Int {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    }

    private static func make(_ anchor: String?, osMajorVersion: Int) -> URL {
        // These string literals are compile-time-constant and known-valid, so the
        // force-unwrap can never fire; it keeps `url` non-optional for callers.
        let base = "x-apple.systempreferences:\(privacySettingsBundleID(osMajorVersion: osMajorVersion))"
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

    /// A SILENT, side-effect-free read of the current status — no tone, no
    /// prompt, no tap. `nil` when the concrete probe has no such read (the
    /// default, via the protocol extension below — existing test fakes need
    /// no change). This is the only way to catch a granted→revoked flip
    /// without re-firing the audible tone probe, so it's what BOTH the
    /// automatic post-onboarding revocation audit
    /// (``SetupModel/auditRequiredPermissions()``) AND the onboarding window's
    /// own reactivation refresh (``SetupModel/refreshStatuses()``) use; the
    /// production impl is ``CoreAudioTonePermissionProbe``.
    func currentStatusSilently() -> PermissionStatus?
}

public extension AudioCapturePermissionProbing {
    func currentStatusSilently() -> PermissionStatus? { nil }
}

/// What one Local Network prime proved. macOS has no status API for this
/// permission (TN3179), but both answers ARE provable behaviourally — see
/// ``LocalNetworkPrimer`` for the two mechanisms (self-discovery for the grant,
/// the mDNS policy error for the refusal).
public enum LocalNetworkOutcome: Equatable, Sendable {
    /// The browse demonstrably reached the network. `foundSpeakers` is how many
    /// speakers it saw, which may legitimately be ZERO: the permission is what
    /// this case asserts, not the presence of a speaker.
    case granted(foundSpeakers: Int)
    /// The user refused (an mDNS `kDNSServiceErr_PolicyDenied`).
    case denied
    /// Nothing answered within the window — the system dialog is presumably
    /// still up. NOT a denial.
    case undecided
}

/// Triggers AND functionally checks the Local Network permission. macOS exposes
/// no status API (TN3179), so every signal here is behavioural — but all three
/// answers are real (see ``LocalNetworkOutcome``). The same browse ALSO surfaces
/// the system prompt when the permission is still undetermined, so priming is
/// both the ask and the check. The production impl is ``LocalNetworkPrimer``;
/// tests inject a fake that returns a canned result.
public protocol LocalNetworkPriming: Sendable {
    /// Browse briefly; return `true` if the local network was reachable.
    func probe() async -> Bool

    /// Browse briefly; return HOW MANY speakers the browse saw (0 = none, which
    /// also covers "not reachable" — the two are indistinguishable, see
    /// ``PermissionStatus``). The count is what lets setup say "Found 3
    /// speakers" instead of a checkmark nobody can verify, and it is the same
    /// browse: `probe()` is exactly `count > 0`.
    ///
    /// Defaulted (below) so a fake that only answers the Bool keeps compiling.
    func probeFoundSpeakers() async -> Int

    /// The same browse with an explicit window, because the FIRST browse is
    /// also the system prompt: a human has to notice, read and click a dialog
    /// that hasn't even rendered yet, which takes far longer than a re-scan of
    /// a permission that is already decided. The caller picks the window (see
    /// ``SetupModel``); defaulted (below) so a fake that ignores timing keeps
    /// compiling.
    func probeFoundSpeakers(browseSeconds: TimeInterval) async -> Int

    /// The full answer: granted (with the speaker count), denied, or nothing
    /// yet. This is what ``SetupModel`` actually calls — the count-only calls
    /// above remain for the fakes and for callers that want the number alone.
    /// Defaulted (below) so every existing fake keeps compiling.
    ///
    /// `onReachable` fires (possibly on any thread) the moment the prime PROVES
    /// the network is reachable, which is earlier than it can answer: the
    /// speaker count is still filling in. That gap is what lets the card say
    /// "Checking your network…" instead of leaving a bare spinner up.
    func prime(browseSeconds: TimeInterval,
               onReachable: @escaping @Sendable () -> Void) async -> LocalNetworkOutcome

    /// The same prime, saying whether it may PUBLISH the service the grant is
    /// proved against. Publishing opens a listening TCP socket, which the macOS
    /// application firewall may ask the user about — so it belongs to the first
    /// ask, not to every background rescan of a permission already proved. See
    /// ``LocalNetworkPrimer``. Defaulted (below) so every fake keeps compiling.
    func prime(browseSeconds: TimeInterval,
               selfDiscovery: Bool,
               onReachable: @escaping @Sendable () -> Void) async -> LocalNetworkOutcome

    /// Abandon a prime that is in flight and tear its endpoints down (the
    /// window closing mid-ask). A seam with nothing to tear down does nothing.
    func cancel()
}

public extension LocalNetworkPriming {

    /// A seam with no listener of its own has nothing for the flag to change.
    func prime(browseSeconds: TimeInterval,
               selfDiscovery: Bool,
               onReachable: @escaping @Sendable () -> Void) async -> LocalNetworkOutcome {
        await prime(browseSeconds: browseSeconds, onReachable: onReachable)
    }

    func cancel() {}

    /// A seam that only implements the Bool answer reports one speaker for
    /// reachable, none otherwise — preserving `count > 0 ⇔ probe()`.
    func probeFoundSpeakers() async -> Int { await probe() ? 1 : 0 }

    /// A seam with no window of its own just answers — fakes resolve instantly.
    func probeFoundSpeakers(browseSeconds: TimeInterval) async -> Int {
        await probeFoundSpeakers()
    }

    /// A seam that only counts speakers can still answer two of the three
    /// outcomes honestly: a speaker sighting proves the grant, and no sighting
    /// proves nothing at all (`.undecided`). Only a primer that watches for the
    /// policy error can ever report `.denied`.
    func prime(browseSeconds: TimeInterval,
               onReachable: @escaping @Sendable () -> Void) async -> LocalNetworkOutcome {
        let found = await probeFoundSpeakers(browseSeconds: browseSeconds)
        guard found > 0 else { return .undecided }
        onReachable()
        return .granted(foundSpeakers: found)
    }
}

/// How far along an in-flight prompt/probe is, for the one thing the UI can
/// honestly say while it waits. Two phases, because they are different waits:
/// ``waitingForAnswer`` is a system dialog sitting unanswered (up to a minute
/// for Local Network), while ``verifying`` is our own brief wrap-up after the
/// answer landed. A prime that gets refused skips ``verifying`` entirely —
/// there is nothing left to check.
public enum SetupProbePhase: Equatable, Sendable {
    case idle
    case waitingForAnswer
    case verifying
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

/// Reads the macOS **Bluetooth** permission. `CBManager.authorization` is the
/// one permission in this flow with a fully honest status API — synchronous,
/// prompt-free, and three-valued for real (undetermined / granted / denied), so
/// unlike Local Network and Remote Control this never has to settle for
/// `.requested`. The production impl is ``BluetoothPermissionReader``; tests
/// inject a fake.
public protocol BluetoothPermissionReading: Sendable {
    /// The live authorization state. Never prompts, never touches IOBluetooth.
    func currentStatus() -> PermissionStatus
}

/// Fires the macOS **Bluetooth** permission prompt. Separate from
/// ``BluetoothPermissionReading`` because only this half has side effects: the
/// prompt exists solely as a consequence of instantiating a `CBCentralManager`,
/// which must then be retained until the user answers.
///
/// `onDecided` fires ONCE, on granted OR denied — both end the wait, and the
/// caller re-reads the status to learn which. The production impl is
/// ``BluetoothPermissionPrimer``; tests inject a fake.
public protocol BluetoothPermissionPriming: Sendable {
    /// Open the prompt (if the status is still undetermined) and report back
    /// once it's answered. May fire `onDecided` on any thread.
    func prime(onDecided: @escaping @Sendable () -> Void)
}

// MARK: - The flow model

/// Drives the first-run setup/onboarding flow: holds the observable status of
/// each permission, runs the probes, and persists completion. Pure coordination
/// — AppKit-free and hermetically testable (both system seams are injected), so
/// the UI (``AudioutOnboardingUI``) is a thin renderer over this.
///
/// Main-actor: the UI binds to it directly and `onChange` fires on the main
/// thread. The async `requestAudioCapture()` awaits the (Sendable) probe, which
/// does its Core Audio work off the main actor, then resumes here to publish the
/// result.
@MainActor
public final class SetupModel {

    /// Verifiable audio-capture status. Starts `.unknown`.
    public private(set) var audioStatus: PermissionStatus = .unknown

    /// Local-network status. When the OS gates local network (`localNetworkGated`,
    /// macOS 15+), starts `.unknown` and becomes whichever of `.granted` /
    /// `.denied` / `.requested` the prime proved (see ``LocalNetworkOutcome``). On
    /// macOS < 15 there is NO local-network privacy gate — that permission arrived
    /// in Sequoia — so access is unconditionally allowed: it starts, and stays,
    /// `.granted`, and the row never routes the user to a Settings pane that
    /// doesn't exist there. See `localNetworkGated`.
    public private(set) var localNetworkStatus: PermissionStatus = .unknown

    /// How many speakers the most recent Local Network browse saw. `0` until a
    /// prime has run, and legitimately `0` afterwards too: self-discovery proves
    /// the permission on its own, so a `.granted` Local Network with zero
    /// speakers just means none is switched on. The count is the detail the card
    /// shows ("3 speakers on your network"), not the grant itself.
    public private(set) var localNetworkFoundSpeakers = 0

    /// Remote-control (Accessibility) status. Starts `.unknown`, becomes
    /// `.requested` once primed (never `.granted` on its own — see
    /// ``PermissionStatus``). Primes ahead of the feature that needs it; see
    /// ``RemoteControlPriming``.
    public private(set) var remoteControlStatus: PermissionStatus = .unknown

    /// Bluetooth status, backed by the honest `CBManager.authorization` read —
    /// so this is a real `.unknown`/`.granted`/`.denied` and never a
    /// `.requested` placeholder. Refreshed on every ``refreshStatuses()``: the
    /// read is free and prompt-free, so a grant OR a revocation made in System
    /// Settings lands (same posture as Remote Control).
    public private(set) var bluetoothStatus: PermissionStatus = .unknown

    /// PTP helper daemon status (T6). Starts `.notRegistered`; becomes
    /// `.requiresApproval` once ``registerPTPHelper()`` runs, then `.enabled`
    /// once the user approves it in Login Items. See ``PTPHelperStatus``.
    public private(set) var ptpHelperStatus: PTPHelperStatus = .notRegistered

    /// How far the explicit Local Network prime (the Allow tap) has got: it can
    /// sit a full minute on an unanswered dialog, so the card needs something
    /// truthful to say for the whole wait. Only ``primeLocalNetwork()`` moves
    /// this — a background refresh browses without ever claiming the user is
    /// being asked anything.
    public private(set) var localNetworkPhase: SetupProbePhase = .idle

    /// True while an audio probe is running, so the UI can show progress and
    /// ignore repeat taps. The probe blocks ~250 ms capturing the test tone.
    public private(set) var isProbingAudio = false

    /// True while the Bluetooth prompt is up and unanswered, so the card can
    /// show the same in-flight spinner the audio probe gets. Cleared by a
    /// decision that actually decided something — or, if none ever arrives, by
    /// ``bluetoothPromptTimeout``, which is what keeps a prompt that never
    /// reports back from wedging the card shut forever.
    public private(set) var isPrimingBluetooth = false

    /// Which prime this is, so a timeout from an earlier one can't clear a
    /// later one's flight.
    private var bluetoothPrimeGeneration = 0

    /// Fired (on the main actor) after any observable change, so the UI repaints.
    public var onChange: (() -> Void)?

    private let audioProbe: AudioCapturePermissionProbing
    private let localNetwork: LocalNetworkPriming
    private let remoteControl: RemoteControlPriming
    private let bluetoothReader: BluetoothPermissionReading
    private let bluetoothPrimer: BluetoothPermissionPriming
    private let ptpHelper: PTPHelperManaging
    private let settings: AppSettings

    /// Whether this OS gates local-network access behind a privacy permission.
    /// True on macOS 15+ (Sequoia introduced Local Network privacy); false below,
    /// where access is ungated and the onboarding row must NOT present a grant or
    /// a Settings link that doesn't exist. Injected so tests stay OS-independent;
    /// the app passes ``osGatesLocalNetwork``.
    private let localNetworkGated: Bool

    /// How long a Bluetooth prompt may sit undecided before the card re-arms.
    /// Injected so a test can drive the timeout without waiting on it.
    private let bluetoothPromptTimeout: TimeInterval

    /// Whether this OS gates local-network access — read by ``SetupFlowModel``,
    /// which must count the ungated case as satisfied without inventing a
    /// status for it.
    public var isLocalNetworkGated: Bool { localNetworkGated }

    /// The real per-OS value for `localNetworkGated`: macOS 15+ gates local
    /// network, earlier versions don't. The app injects this. The init default
    /// stays `true` so existing tests keep their gated expectations regardless of
    /// the test runner's OS version.
    public static var osGatesLocalNetwork: Bool {
        if #available(macOS 15, *) { return true } else { return false }
    }

    /// The Bluetooth pair defaults INERT (an undetermined read, a prime that
    /// decides immediately without a `CBCentralManager`) for the same reason
    /// ``BTDeviceEnumerator``'s authorization pair does: a test that forgets to
    /// inject it must degrade to "never asks, never reads the runner's real
    /// grant", not spring a system prompt mid-`swift test`.
    public init(audioProbe: AudioCapturePermissionProbing,
                localNetwork: LocalNetworkPriming,
                remoteControl: RemoteControlPriming,
                ptpHelper: PTPHelperManaging,
                bluetoothReader: BluetoothPermissionReading = SimulatedBluetoothPermission(status: .unknown),
                bluetoothPrimer: BluetoothPermissionPriming = SimulatedBluetoothPermission(status: .unknown),
                settings: AppSettings = AppSettings(),
                localNetworkGated: Bool = true,
                usageStatsAvailable: Bool = Analytics.isAvailable,
                bluetoothPromptTimeout: TimeInterval = 10) {
        self.usageStatsAreAvailable = usageStatsAvailable
        self.bluetoothPromptTimeout = bluetoothPromptTimeout
        self.audioProbe = audioProbe
        self.localNetwork = localNetwork
        self.remoteControl = remoteControl
        self.bluetoothReader = bluetoothReader
        self.bluetoothPrimer = bluetoothPrimer
        self.ptpHelper = ptpHelper
        self.settings = settings
        self.localNetworkGated = localNetworkGated
        // macOS < 15 has no local-network privacy gate → access is already
        // allowed. Reflect that up front so the row shows satisfied, never nags,
        // and never opens the Settings pane that doesn't exist on that OS.
        if !localNetworkGated {
            self.localNetworkStatus = .granted
        }
    }

    /// Convenience over the seam-by-seam init that takes a ``PermissionProviders``
    /// bundle — how the app builds it once from ``PermissionMode`` and threads
    /// the same set (real or simulated) into every construction site.
    public convenience init(providers: PermissionProviders,
                            settings: AppSettings = AppSettings(),
                            localNetworkGated: Bool = true,
                            usageStatsAvailable: Bool = Analytics.isAvailable) {
        self.init(audioProbe: providers.audioProbe,
                  localNetwork: providers.localNetwork,
                  remoteControl: providers.remoteControl,
                  ptpHelper: providers.ptpHelper,
                  bluetoothReader: providers.bluetoothReader,
                  bluetoothPrimer: providers.bluetoothPrimer,
                  settings: settings,
                  localNetworkGated: localNetworkGated,
                  usageStatsAvailable: usageStatsAvailable)
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

    /// Ask for + functionally check Local Network. The prime fires the system
    /// prompt (if undetermined) and reports one of three REAL answers (see
    /// ``LocalNetworkOutcome``): the network was demonstrably reachable ⇒
    /// `.granted`, even with no speaker on it; the user refused ⇒ `.denied`;
    /// nothing answered inside the window ⇒ `.requested` (the dialog is
    /// presumably still up).
    public func primeLocalNetwork() async {
        // No gate on this OS (macOS < 15): access is already allowed, so there's
        // nothing to prompt for and no Settings pane to open — report granted and
        // skip the browse entirely.
        guard localNetworkGated else {
            localNetworkStatus = .granted
            onChange?()
            return
        }
        localNetworkPhase = .waitingForAnswer
        onChange?()
        localNetworkStatus = await probeLocalNetwork(onReachable: { [weak self] in
            Task { @MainActor in self?.markLocalNetworkVerifying() }
        })
        localNetworkPhase = .idle
        onChange?()
    }

    /// The dialog was answered and the browse is through — only the speaker
    /// count is still filling in. Fired from the primer's own callback, so the
    /// card's "Checking your network…" is a real observation, not a timer.
    private func markLocalNetworkVerifying() {
        guard localNetworkPhase == .waitingForAnswer else { return }
        localNetworkPhase = .verifying
        onChange?()
    }

    /// The CEILING on the first Local Network prime — how long it may sit
    /// undecided before giving up. A grant or a refusal resolves it in well
    /// under a second, so this window is only ever spent waiting on a person
    /// who hasn't answered the dialog yet; it matches the audio probe's
    /// generous ceiling for the same reason.
    static let firstAskBrowseSeconds: TimeInterval = 60

    /// How long every later prime waits — a re-scan of an already-decided
    /// permission, where a spinner is pure cost.
    static let rescanBrowseSeconds: TimeInterval = 3

    /// The one Local Network prime in flight, shared by every concurrent
    /// caller — see ``probeLocalNetwork(onReachable:)``.
    private var localNetworkProbeTask: Task<PermissionStatus, Never>?

    /// Run the prime, record how many speakers it saw, and map the outcome to a
    /// status. One place so `primeLocalNetwork()`, ``refreshStatuses()`` and
    /// ``auditRequiredPermissions()`` can never disagree.
    ///
    /// Concurrent callers COALESCE onto one running prime instead of each
    /// firing their own: `LocalNetworkPrimer`'s in-flight guard answers a
    /// colliding prime `.undecided` — "not yet known" — which this funnel
    /// would then record as a real `.requested`. That fabricated answer is how
    /// clicking Done while the app-reactivation `refreshStatuses()` was still
    /// browsing made the verification claim Local Network was unmet and refuse
    /// to finish (live, 2026-08-11). A joiner inherits the running prime's
    /// browse window and outcome; only the starter's `onReachable` is live
    /// (the silent callers pass none, so nothing user-facing is lost).
    private func probeLocalNetwork(
        onReachable: @escaping @Sendable () -> Void = {}
    ) async -> PermissionStatus {
        if let running = localNetworkProbeTask { return await running.value }
        // `.unknown` means nothing has primed yet, so THIS prime is the one that
        // raises the system permission dialog, and it must outlast a person
        // reading it. Every later prime re-checks an already-decided permission,
        // with no dialog to wait for, so it stays snappy.
        let window = localNetworkStatus == .unknown ? Self.firstAskBrowseSeconds
                                                    : Self.rescanBrowseSeconds
        // A permission already PROVED granted needs no second proof, so its
        // rescans skip the published service (and the firewall dialog that
        // publishing can raise) and just browse.
        let wasGranted = localNetworkStatus == .granted
        let primer = localNetwork
        let probe = Task { @MainActor [weak self] () -> PermissionStatus in
            switch await primer.prime(browseSeconds: window,
                                      selfDiscovery: !wasGranted,
                                      onReachable: onReachable) {
            case .granted(let found):
                // A later browse that saw FEWER speakers hasn't unsaid the
                // earlier sighting — a speaker was switched off, which is not a
                // permission event. Only a browse that actually saw something
                // rewrites the count a granted card is showing.
                if found > 0 || !wasGranted { self?.localNetworkFoundSpeakers = found }
                return .granted
            case .denied:
                self?.localNetworkFoundSpeakers = 0
                return .denied
            case .undecided:
                // GRANTED IS PROVEN AND STICKY. Self-discovery proved the
                // permission; a later rescan that proves nothing (an empty
                // network, a prime already in flight, a browse that ended
                // early) has NOT disproved it. Downgrade here and every app
                // activation flaps the completed card to "permission lost" and
                // back. The only thing that takes the grant away is the refusal
                // itself — the mDNS policy error, which arrives as `.denied`
                // above.
                guard !wasGranted else { return .granted }
                self?.localNetworkFoundSpeakers = 0
                return .requested
            }
        }
        localNetworkProbeTask = probe
        let status = await probe.value
        localNetworkProbeTask = nil
        return status
    }

    /// Abandon a Local Network prime that is in flight — the window closing
    /// mid-ask. The prime resolves `.undecided`, which unwinds
    /// ``primeLocalNetwork()`` and releases the flow model's single-flight hold.
    public func cancelLocalNetworkPrime() {
        localNetwork.cancel()
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

    /// Ask for Bluetooth. The prompt's answer arrives through the primer's
    /// decision callback — granted and denied both end the wait — and the
    /// honest status comes from re-reading `CBManager.authorization`, never
    /// from assuming the answer. No status is written here: an undecided prompt
    /// must leave the step exactly as it was.
    ///
    /// ``isPrimingBluetooth`` stays true for the whole wait, and a callback that
    /// leaves the authorization still undetermined does NOT end it — that is the
    /// wedge case (the prompt reported back without deciding anything), and the
    /// only thing that ends it is ``bluetoothPromptTimeout``, after which a
    /// later click may ask again: a fresh `CBCentralManager` re-raises the
    /// prompt while the authorization is undetermined.
    public func primeBluetooth() {
        guard !isPrimingBluetooth else { return }
        isPrimingBluetooth = true
        bluetoothPrimeGeneration += 1
        let generation = bluetoothPrimeGeneration
        onChange?()
        bluetoothPrimer.prime {
            Task { @MainActor [weak self] in self?.bluetoothPromptDecided(generation) }
        }
        Task { @MainActor [weak self] in
            guard let timeout = self?.bluetoothPromptTimeout else { return }
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            self?.bluetoothPromptUndecidedTimeout(generation)
        }
    }

    private func bluetoothPromptDecided(_ generation: Int) {
        guard generation == bluetoothPrimeGeneration else { return }
        // A callback that left the authorization undetermined decided NOTHING —
        // the prompt is still in flight as far as the card is concerned, and only
        // the timeout ends that wait.
        let decided = bluetoothReader.currentStatus()
        guard decided != .unknown else { return }
        // Published in one go rather than through `refreshBluetoothStatus()`: the
        // wait ending is itself observable, so this must repaint even when the
        // status it read is the one already held.
        bluetoothStatus = decided
        isPrimingBluetooth = false
        onChange?()
    }

    private func bluetoothPromptUndecidedTimeout(_ generation: Int) {
        guard generation == bluetoothPrimeGeneration, isPrimingBluetooth else { return }
        isPrimingBluetooth = false
        onChange?()
    }

    /// Re-read the Bluetooth authorization — a silent, prompt-free read, so
    /// this is safe to call on any focus/decision edge and a `.granted` →
    /// revoked downgrade is allowed (same posture as
    /// ``refreshRemoteControlStatus()``). Fires `onChange` only on an actual
    /// transition.
    public func refreshBluetoothStatus() {
        let next = bluetoothReader.currentStatus()
        guard next != bluetoothStatus else { return }
        bluetoothStatus = next
        onChange?()
    }

    /// T5: emits the exact "setup says X, the live TCC-backed read says Y"
    /// comparison at every audio reconciliation point (``refreshStatuses()``,
    /// ``auditRequiredPermissions()``) — the evidence tonight's live bug had
    /// none of, where the app's own UI showed a permission as connected/granted
    /// while the real system grant was denied and nothing afterward could
    /// explain why. `reported` is the status as SetupModel/the UI currently
    /// hold it; `silent` is what ``AudioCapturePermissionProbing/currentStatusSilently()``
    /// just read live. `diverged` is computed explicitly (not left for a log
    /// reader to infer by comparing two other fields) so a single line is
    /// unambiguous on its own, and is logged on EVERY reconciliation — a match
    /// is useful positive evidence too, not just a mismatch.
    private func logReportedVsActual(site: String, reported: PermissionStatus, silent: PermissionStatus) {
        Telemetry.log(.permission, "reported_vs_actual", [
            "site": site,
            "reported": reported.telemetryDescription,
            "silent": silent.telemetryDescription,
            "diverged": reported == silent ? "false" : "true",
        ])
    }

    /// Re-derive every permission's status from its CURRENT real state, so the
    /// screen reflects reality rather than a stale "requested." Safe to call on
    /// every window focus/reactivate — deliberately never SPRINGS a prompt on a
    /// permission the user hasn't engaged yet, and (ONBOARD-TONE) never replays
    /// the audible System Audio tone outside the explicit "Allow…" gesture:
    ///
    /// - **Remote Control** always refreshes: `isTrusted()` is a silent read, so a
    ///   grant made in System Settings shows up the moment the window regains key
    ///   (and a revocation downgrades a prior `.granted` back to `.requested`).
    /// - **System Audio** re-reads ONLY if already asked (`.denied`/`.requested`),
    ///   and does so via the SILENT ``AudioCapturePermissionProbing/currentStatusSilently()``
    ///   — never the audible tone/tap ``AudioCapturePermissionProbing/probe()``,
    ///   which is reserved for the explicit "Allow…" tap (``requestAudioCapture()``).
    ///   This method runs on every plain app reactivation while onboarding is open
    ///   (`OnboardingWindowController.appDidBecomeActive`), not just an explicit
    ///   gesture, so firing the audible probe here would replay the tone on a bare
    ///   Cmd+Tab away and back — the original ONBOARD-TONE bug. The silent read
    ///   still catches a grant made in Settings; a `nil` result (a test fake that
    ///   hasn't implemented the silent seam) leaves `audioStatus` untouched, same
    ///   posture as ``auditRequiredPermissions()``.
    /// - **Local Network** re-primes ONLY if already asked (browsing fires the
    ///   prompt), which upgrades `.requested` → `.granted` once the browse
    ///   reaches the network, and can land on a real `.denied`. It can NEVER
    ///   take a proved grant back on anything less than that refusal — see
    ///   ``probeLocalNetwork(onReachable:)``.
    /// - **PTP helper** always re-reads `.status` (silent, no re-`register()` —
    ///   see ``refreshPTPHelperStatus()``), the same posture as Remote Control.
    /// - **Bluetooth** always re-reads `CBManager.authorization` (silent and
    ///   prompt-free), same posture again — see ``refreshBluetoothStatus()``.
    public func refreshStatuses() async {
        // Remote Control — silent, always safe.
        if remoteControl.isTrusted() {
            remoteControlStatus = .granted
        } else if remoteControlStatus == .granted {
            remoteControlStatus = .requested   // revoked in Settings since
        }

        // System Audio — re-read only a row the user has already engaged, and do
        // it SILENTLY: this runs on every plain app reactivation (not just an
        // explicit gesture), so it must never replay the audible tone/tap probe
        // — that stays reserved for `requestAudioCapture()`.
        if audioStatus == .denied || audioStatus == .requested,
           let silentAudio = audioProbe.currentStatusSilently() {
            logReportedVsActual(site: "SetupModel.refreshStatuses", reported: audioStatus, silent: silentAudio)
            audioStatus = silentAudio
        }

        // Local Network — re-probe only if already asked (else browsing prompts),
        // and only where the OS gates it. On macOS < 15 it's unconditionally
        // granted, so there's nothing to re-read and no prompt to risk.
        if localNetworkGated, localNetworkStatus != .unknown {
            localNetworkStatus = await probeLocalNetwork()
        }

        // PTP helper — silent status read only, never re-registers here.
        setPTPHelperStatus(ptpHelper.status)

        // Bluetooth — silent, prompt-free, so always re-read.
        refreshBluetoothStatus()

        onChange?()
    }

    /// Register the PTP helper daemon and read the resulting status.
    ///
    /// Unlike the three probes above, this needs no explicit user gesture to be
    /// safe to call: registering an `SMAppService` daemon shows NO system
    /// prompt of its own (see ``PTPHelperManaging/register()``'s doc comment) —
    /// it just adds a disabled entry to Login Items. The user-facing step is
    /// the *approval* afterwards, which `.requiresApproval` surfaces. Called
    /// once, at onboarding load (mirrors the design doc's "at first launch").
    /// Idempotent — safe to call again (e.g. "Open Setup…").
    ///
    /// NOTE (Developer-ID gating): under this branch's ad-hoc signing,
    /// `register()` cannot validate and this will not progress past
    /// `.notRegistered`/reach `.enabled` — see ``PTPHelperManaging``'s doc
    /// comment and PROGRESS.md T5/T6. Real end-to-end verification is blocked
    /// until Developer ID signing ships.
    public func registerPTPHelper() {
        do {
            try ptpHelper.register()
            ptpHelperRegistrationFailed = false
        } catch {
            // Nothing the user can fix — so it must not hold the gate shut
            // (``requiredPermissionsNotGranted()``), and the failure has to
            // reach somewhere a support ticket can quote: `Telemetry` writes to
            // `~/Library/Logs/Audiout/`, the stderr line stays for a dev run.
            ptpHelperRegistrationFailed = true
            Telemetry.log(.permission, "ptp_register_failed", ["error": String(describing: error)])
            FileHandle.standardError.write(
                Data("[Audiout] PTP helper registration failed: \(error)\n".utf8))
        }
        setPTPHelperStatus(ptpHelper.status)
        onChange?()
    }

    /// Whether the launch-time ``registerPTPHelper()`` threw. Like
    /// ``PTPHelperStatus/notFound`` it is a packaging/signing fault rather than
    /// a user decision, so the Speaker Sync step auto-passes on it instead of
    /// asking for an approval that can never be given.
    public private(set) var ptpHelperRegistrationFailed = false

    /// The one place ``ptpHelperStatus`` is written, so the "was it ever really
    /// on?" ratchet cannot be bypassed by a new assignment site. Reaching
    /// `.enabled` — however it is reached — is what arms the wake audit's
    /// Login Items nag; only an explicit skip
    /// (``noteSpeakerSyncSkipped()``) disarms it again.
    private func setPTPHelperStatus(_ next: PTPHelperStatus) {
        ptpHelperStatus = next
        if next == .enabled { settings.speakerSyncWasEnabled = true }
    }

    /// Remember that the user passed on Speaker Sync, so the wake audit stops
    /// treating an unapproved helper as something that got turned off.
    public func noteSpeakerSyncSkipped() {
        settings.speakerSyncWasEnabled = false
    }

    /// Deep-link to System Settings › General › Login Items & Extensions,
    /// where the user approves (or later revokes) the PTP helper.
    public func openPTPHelperLoginItems() {
        ptpHelper.openSystemSettingsLoginItems()
    }

    // MARK: Usage statistics

    /// Whether the user has agreed to share anonymous usage counts
    /// (`AppSettings.telemetryOptIn`, PRODUCT.md Data Collection stream 1).
    /// The Setup step's completion condition.
    public var usageStatsOptedIn: Bool { settings.telemetryOptIn }

    /// Whether the one-time ask has already been answered — either way.
    /// PRODUCT.md's rule for this stream is "asked once, never re-nagged", so
    /// a DECLINE has to be as final as a grant: the Setup flow seeds it as
    /// skipped rather than re-offering the step on every later presentation.
    public var usageStatsWereAnswered: Bool { settings.telemetryAsked }

    /// Whether there is anything to opt IN to. False in a build with no
    /// analytics sink installed — run-from-source, `swift run`, headless —
    /// where asking would promise a stream nothing can send. The step
    /// auto-passes there, the same posture as `.unsupported` audio and a
    /// `.notFound` helper: no grant exists to give.
    ///
    /// This is the ask's gate ONLY. Settings › General keeps its toggle either
    /// way, exactly as it did when this ask was an alert on the first
    /// menu-bar click.
    public let usageStatsAreAvailable: Bool

    /// Say yes: consent is persisted, the live sink is opted in, and the ask
    /// is spent.
    public func grantUsageStats() {
        setUsageStats(true)
    }

    /// Say no. Spends the ask exactly like a grant does — see
    /// ``usageStatsWereAnswered`` — and opts the sink out explicitly rather
    /// than leaving it at whatever it was.
    public func declineUsageStats() {
        setUsageStats(false)
    }

    private func setUsageStats(_ granted: Bool) {
        settings.telemetryOptIn = granted
        settings.telemetryAsked = true
        Analytics.setConsent(granted)
        // AFTER the consent flip, never before: this is the first event a new
        // opt-in can legitimately send, and it would be dropped on the floor
        // if it ran a line earlier. A DECLINE deliberately sends nothing —
        // `capture` no-ops without consent, which is exactly right.
        Analytics.capture("onboarding:usage_stats_opted_in")
        onChange?()
    }

    /// Re-read the PTP helper's live status WITHOUT re-registering, so the
    /// Setup window can poll while `.requiresApproval` waits for the user to
    /// flip the Login Items toggle (mirrors ``refreshRemoteControlStatus()``
    /// below). Fires `onChange` only on an actual transition.
    ///
    /// The read itself happens OFF the main actor: `SMAppService.status` is a
    /// synchronous launchd XPC round-trip, and riding it on the main thread
    /// every 1.5 s is a stall the window pays for the whole time it is open.
    /// Only the compare-and-publish comes back here.
    public func refreshPTPHelperStatus() async {
        let helper = ptpHelper
        let next = await Task.detached { helper.status }.value
        guard next != ptpHelperStatus else { return }
        setPTPHelperStatus(next)
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

    /// Which of the three REQUIRED permissions (``RequiredPermission`` — Remote
    /// Control is deliberately excluded) are currently unmet, read from the
    /// model's CURRENT cached statuses only — no probing, no side effects, safe
    /// to call anytime. Used both to decide whether to force-reopen onboarding
    /// after setup already completed, and (indirectly) by
    /// ``auditRequiredPermissions()`` after it refreshes the cached statuses.
    ///
    /// - Audio capture is unmet only on a confirmed `.denied` — `.unsupported`
    ///   (pre-14.2 OS) isn't fixable, and `.granted`/`.unknown` are fine.
    /// - Local Network is unmet on `.requested` (asked, nothing answered) and
    ///   on the now-real `.denied`; `.unknown` means never engaged, not lost,
    ///   so it never counts.
    /// - The PTP helper is unmet ONLY on a REGRESSION: `.requiresApproval` on a
    ///   helper the user did once approve (``AppSettings/speakerSyncWasEnabled``
    ///   — the ratchet set the first time the status reads `.enabled`). That is
    ///   the real "turned off in Login Items" case, and the only one worth
    ///   re-opening the window for. A helper that was never approved, or that
    ///   the user explicitly skipped (which clears the flag), is not a
    ///   regression; `.notFound` is a packaging bug the user cannot fix;
    ///   `.notRegistered` is the pre-registration state (handled by the app's
    ///   launch-time registration attempt, not a nag here); `.enabled` is fine.
    public func unmetRequiredPermissions() -> [RequiredPermission] {
        var unmet: [RequiredPermission] = []
        if audioStatus == .denied {
            unmet.append(.audioCapture)
        }
        if localNetworkStatus == .requested || localNetworkStatus == .denied {
            unmet.append(.localNetwork)
        }
        if ptpHelperStatus == .requiresApproval, settings.speakerSyncWasEnabled {
            unmet.append(.ptpHelper)
        }
        return unmet
    }

    /// Which of the three REQUIRED permissions are NOT currently confirmed
    /// granted/enabled, right now — the check behind onboarding's Done-tap
    /// confirmation (`OnboardingViewController`), not to be confused with
    /// ``unmetRequiredPermissions()`` above.
    ///
    /// The two methods answer different questions and deliberately disagree on
    /// `.unknown`: ``unmetRequiredPermissions()`` exists to catch a
    /// *regression* (something that WAS working and got turned off), so an
    /// untouched `.unknown` row correctly never counts — "never engaged" isn't
    /// "lost". This method exists to catch the opposite gap — a user who never
    /// engaged a row at all and taps Done anyway — so `.unknown` (and every
    /// other non-success state) DOES count here. Using
    /// ``unmetRequiredPermissions()`` for the Done gate would silently let a
    /// first-time user finish setup with zero permissions granted, since every
    /// untouched row starts life as `.unknown`/`.notRegistered`.
    ///
    /// - Audio capture: granted only on `.granted` — `.unsupported` is excluded
    ///   (pre-14.2 OS; no grant can fix it, so nagging about it would mislead).
    /// - Local Network: granted only on `.granted`.
    /// - PTP helper: granted on `.enabled`, and treated as granted on the two
    ///   states no approval can fix — `.notFound` (the daemon is missing from
    ///   the bundle) and a `register()` that threw
    ///   (``ptpHelperRegistrationFailed``). Holding the Done gate shut on a
    ///   packaging bug would leave the user with nothing to press.
    public func requiredPermissionsNotGranted() -> [RequiredPermission] {
        var notGranted: [RequiredPermission] = []
        if audioStatus != .granted, audioStatus != .unsupported {
            notGranted.append(.audioCapture)
        }
        if localNetworkStatus != .granted {
            notGranted.append(.localNetwork)
        }
        if ptpHelperStatus != .enabled, ptpHelperStatus != .notFound, !ptpHelperRegistrationFailed {
            notGranted.append(.ptpHelper)
        }
        return notGranted
    }

    /// Refresh ONLY the three required permissions' statuses using SILENT/
    /// functional reads (never the audible tone, never an unengaged prompt),
    /// then report ``unmetRequiredPermissions()``. This is the "did something
    /// I need get turned off since setup finished?" check — driven by the app
    /// on reactivate/wake, never by the onboarding UI itself.
    ///
    /// - Audio: uses ``AudioCapturePermissionProbing/currentStatusSilently()``
    ///   — the ONLY reliable way to catch a granted→revoked flip without
    ///   firing the 250 ms tone probe. A `nil` result (a test fake that hasn't
    ///   implemented it) leaves `audioStatus` untouched.
    /// - Local Network: re-probes ONLY if already engaged
    ///   (`localNetworkStatus != .unknown`) — same "never spring an untouched
    ///   prompt" rule ``refreshStatuses()`` follows. A model that has never
    ///   observed Local Network leave `.unknown` (e.g. the user skipped that
    ///   row during onboarding) can't detect a revocation for it — there's
    ///   nothing to revoke from a status we never confirmed in the first place.
    /// - PTP helper: a plain silent `.status` re-read, never re-``register()``.
    /// - Remote Control is NEVER touched here — it's excluded from "required"
    ///   entirely (see ``RequiredPermission``).
    /// - Parameter trustingProvenLocalNetworkGrant: skip the Local Network
    ///   re-browse when the cached status is already the PROVEN, sticky
    ///   `.granted`. The Setup window's own audits pass `true`: re-browsing a
    ///   proven grant costs ~3 s (`rescanBrowseSeconds`) and can learn nothing
    ///   there — while that window is open, any revocation requires a System
    ///   Settings round-trip whose reactivation `refreshStatuses()` already
    ///   re-browses — and that invisible cost behind the CTA click was the
    ///   live "Start listening took two clicks" (v7: 3.2 s between the
    ///   click's mouseUp and its `finished` line). The default `false` keeps
    ///   the browse for the app's wake/reactivate audit, where it is the ONLY
    ///   detector of a Local Network revocation (the mDNS refusal can only
    ///   arrive FROM a browse) and the only recount for the granted card's
    ///   speaker-count title.
    public func auditRequiredPermissions(trustingProvenLocalNetworkGrant: Bool = false) async -> [RequiredPermission] {
        var changed = false

        if let silentAudio = audioProbe.currentStatusSilently() {
            logReportedVsActual(site: "SetupModel.auditRequiredPermissions", reported: audioStatus, silent: silentAudio)
            if silentAudio != audioStatus {
                audioStatus = silentAudio
                changed = true
            }
        }

        if localNetworkGated, localNetworkStatus != .unknown,
           !(trustingProvenLocalNetworkGrant && localNetworkStatus == .granted) {
            let previousFound = localNetworkFoundSpeakers
            let next = await probeLocalNetwork()
            // The COUNT is observable too (the card reads "3 speakers on your
            // network"), so a same-status re-count still has to repaint.
            if next != localNetworkStatus || localNetworkFoundSpeakers != previousFound {
                localNetworkStatus = next
                changed = true
            }
        }

        let nextPTPHelperStatus = ptpHelper.status
        if nextPTPHelperStatus != ptpHelperStatus {
            setPTPHelperStatus(nextPTPHelperStatus)
            changed = true
        }

        if changed { onChange?() }
        return unmetRequiredPermissions()
    }

    /// Mark the flow finished so it doesn't present again on launch. A plain
    /// persistence write: it checks no status of its own.
    ///
    /// Completion IS gated, just not here. Setup is a GATE, not guidance (owner
    /// decision, reversing what this comment used to promise): the UI offers no
    /// Done affordance at all until ``SetupFlowModel/isDoneAvailable`` is true,
    /// so reaching this call means every required permission verified. The ✕
    /// close remains the one ungated exit and deliberately does NOT come through
    /// here — the flow returns next launch.
    public func complete() {
        settings.hasCompletedSetup = true
        Analytics.capture("onboarding:setup_completed")
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
