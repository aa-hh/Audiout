// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// How the app resolves its light/dark appearance (Settings › Appearance).
///
/// `.system` is the default and the historical behaviour — the app forces no
/// `NSAppearance` and everything resolves from `effectiveAppearance` (SPEC §9:
/// "dark/light just work"). `.light`/`.dark` are the user override, applied
/// app-wide by the app layer via `NSApp.appearance` (Core stays AppKit-free).
public enum AppearanceTheme: String, CaseIterable, Sendable {
    case system
    case light
    case dark
}

/// The accent dial (Settings › Appearance › Accent — Warm Signal spec §1.3,
/// decision i): how strongly the gold instrument tokens render. TWO positions
/// — `.fullGold` is the flagship default; `.subtle` desaturates the gold
/// channel and removes the glow. The dial remaps ONLY the gold channel;
/// `failure`, the edge tokens and every text token are never remapped. A value
/// persisted by a build that had a third position no longer decodes, and the
/// getter's existing `?? .fullGold` fallback catches it. Core owns only the
/// persisted choice; the token remap itself lives with the token module
/// (`AudioutSharedUI.Tokens`), since Core imports no AppKit.
public enum AccentStyle: String, CaseIterable, Sendable {
    case fullGold
    case subtle
}

/// What the license server last said about the stored key (`POST /v1/validate`).
/// The raw values are the server's own strings, so a response maps straight
/// across. `active`/`revoked` are answers about a real key; `unknown` means the
/// server has no such key; `invalid` means the text isn't key-shaped at all.
public enum LicenseStatus: String {
    case active
    case revoked
    case unknown
    case invalid
}

/// The app's **scalar** user preferences, backed by `UserDefaults`.
///
/// This is the deliberate other half of the persistence split (decided with the
/// popover-routing work): *scalars* (theme, small booleans) live in
/// `UserDefaults` — the platform norm, trivial, and what a Settings window
/// expects — while *list* data keeps the Codable-store idiom (`AppRouteStore`,
/// `GroupStore`, `RoutingStore`, and the future `ExcludedAppsStore`). Don't grow
/// a JSON store for three booleans, and don't push a device/app list in here.
///
/// A value type over a reference (`UserDefaults`): setters are `nonmutating`
/// because they write through to the store, so `let settings = AppSettings()`
/// still mutates persisted state. The store is injectable so tests use a
/// throwaway suite and never touch `.standard`.
///
/// Not `Sendable` (it wraps `UserDefaults`, which isn't) — it's used only on the
/// main actor (app delegate + settings panes), so it never crosses actors.
public struct AppSettings {

    private let defaults: UserDefaults
    private let licenseServerURLOverride: URL?
    private let buyURLOverride: URL?

    /// - Parameters:
    ///   - licenseServerURL: overrides the bundle-supplied license server (see
    ///     ``licenseServerURL``).
    ///   - buyURL: overrides the bundle-supplied purchase page (see ``buyURL``).
    ///
    ///   Both exist because the values normally come from the app bundle's
    ///   Info.plist, and under `swift test` `Bundle.main` is the test
    ///   runner — there is no other way to exercise a build that HAS a license
    ///   server. The app always passes neither.
    public init(defaults: UserDefaults = .standard,
                licenseServerURL: URL? = nil,
                buyURL: URL? = nil) {
        self.defaults = defaults
        self.licenseServerURLOverride = licenseServerURL
        self.buyURLOverride = buyURL
    }

    private enum Keys {
        static let theme = "appearance.theme"
        static let accentStyle = "appearance.accentStyle"
        static let startBufferMs = "audio.startBufferMs"
        static let hasCompletedSetup = "setup.hasCompleted"
        static let speakerSyncWasEnabled = "speakerSync.wasEnabled"
        static let localNetworkWasGranted = "localNetwork.wasGranted"
        static let reconnectAtLaunch = "general.reconnectAtLaunch"
        static let wakeRestoreMinutes = "audio.wakeRestoreMinutes"
        static let connectVolume = "audio.connectVolume"
        static let mainOutVolume = "audio.mainOutVolume"
        static let syncOffsetMs = "audio.syncOffsetMs"
        static let allowRemoteControl = "companion.allowRemoteControl"
        static let surfacePinned = "surface.pinned"
        static let eqAdvancedExpanded = "eq.advancedExpanded"
        static let licenseKey = "license.key"
        static let licenseInstallID = "license.installID"
        static let licenseCheckInURL = "license.checkInURL"
        static let licenseStatus = "license.status"
        static let licenseMaxMajor = "license.maxMajor"
        static let licenseReason = "license.reason"
        static let companionToken = "license.companionToken"
        static let trialStartedAt = "trial.startedAt"
        static let trialExpiresAt = "trial.expiresAt"
        static let trialRegistered = "trial.registered"
        static let trialBannerThreeDaysShown = "trial.bannerThreeDaysShown"
        static let trialBannerLastDayShown = "trial.bannerLastDayShown"
        static let telemetryOptIn = "telemetry.optIn"
        static let telemetryAsked = "telemetry.asked"
        static let touchBarControls = "general.touchBarControls"
        static let mixerMembershipHintDismissed = "mixer.membershipHintDismissed"
    }

    /// The user-selectable sender start-buffer options in ms (Settings › Audio
    /// › Advanced "Audio buffer", PLAN-LATENCY-SETTING.md). Bare numeric values
    /// by design (ahh, 2026-07-17): named presets with embedded delay text
    /// don't survive localization. 1000 is both the default and the floor —
    /// it leaves receivers a 750 ms jitter buffer, comfortably safe on
    /// ordinary Wi-Fi; 2250 is OwnTone-parity (the old behavior). The engine
    /// shim independently hard-clamps to 300...5000, so no stored value can
    /// produce a non-working session.
    public static let startBufferOptionsMs: [Int] = [1000, 1500, 2250]

    /// The default (and lowest offered) start buffer in ms.
    public static let defaultStartBufferMs = 1000

    /// The appearance override. Defaults to `.system` when unset or unrecognised
    /// (a value written by a newer build).
    public var theme: AppearanceTheme {
        get { defaults.string(forKey: Keys.theme).flatMap(AppearanceTheme.init(rawValue:)) ?? .system }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Keys.theme) }
    }

    /// The accent dial (Settings › Appearance › Accent, spec §1.3). Defaults to
    /// `.fullGold` when unset or unrecognised (a value written by a newer build).
    public var accentStyle: AccentStyle {
        get { defaults.string(forKey: Keys.accentStyle).flatMap(AccentStyle.init(rawValue:)) ?? .fullGold }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Keys.accentStyle) }
    }

    /// The persisted sender start buffer (ms). Values outside
    /// ``startBufferOptionsMs`` — including unset (0) and anything written by a
    /// newer/older build — resolve to ``defaultStartBufferMs``, so the getter
    /// can never return a value the UI doesn't offer.
    public var startBufferMs: Int {
        get {
            let stored = defaults.integer(forKey: Keys.startBufferMs)
            return Self.startBufferOptionsMs.contains(stored) ? stored : Self.defaultStartBufferMs
        }
        nonmutating set { defaults.set(newValue, forKey: Keys.startBufferMs) }
    }

    /// Whether the first-run setup/onboarding flow has been completed (the
    /// permission-priming window — ``SetupModel``). Defaults to `false` (unset),
    /// so a fresh install shows setup once; ``SetupModel/complete()`` flips it,
    /// and "Open Setup…" (Settings › General) never clears it — re-running
    /// setup is a manual re-open, not a reset of this flag. A plain scalar bool,
    /// exactly what this store is for (see the type comment). The launch gate
    /// that reads this is ``SetupModel/shouldPresentOnLaunch(settings:backendKind:)``.
    public var hasCompletedSetup: Bool {
        get { defaults.bool(forKey: Keys.hasCompletedSetup) }
        nonmutating set { defaults.set(newValue, forKey: Keys.hasCompletedSetup) }
    }

    /// Whether the Speaker Sync helper has EVER been seen `.enabled` — set the
    /// first time ``SetupModel`` reads that status, and cleared by an explicit
    /// skip of the Speaker Sync step. It gates the wake audit's "this was
    /// turned off in Login Items" nag (``SetupModel/unmetRequiredPermissions()``),
    /// so only a real REGRESSION re-opens the Setup window: a user who never
    /// approved the helper, or who passed on it, is never nagged about it.
    public var speakerSyncWasEnabled: Bool {
        get { defaults.bool(forKey: Keys.speakerSyncWasEnabled) }
        nonmutating set { defaults.set(newValue, forKey: Keys.speakerSyncWasEnabled) }
    }

    /// Whether a Local Network browse has EVER reached the network — written by
    /// ``SetupModel``'s one prime funnel the first time it proves the grant, and
    /// cleared only by a real refusal (the mDNS policy error).
    ///
    /// It exists because Local Network is the one permission with no silent
    /// read: browsing is what raises the system prompt, so a status of
    /// `.unknown` — which every freshly built ``SetupModel`` starts at — cannot
    /// be resolved by just looking. Without this bit, re-opening Setup showed a
    /// long-granted permission as un-asked and invited the user to grant it
    /// again (live report, 2026-08-29). With it, a fresh model starts from the
    /// proven grant and re-verifies by browsing, which raises no prompt on a
    /// permission already held.
    public var localNetworkWasGranted: Bool {
        get { defaults.bool(forKey: Keys.localNetworkWasGranted) }
        nonmutating set { defaults.set(newValue, forKey: Keys.localNetworkWasGranted) }
    }

    /// Settings › General "Reconnect last speakers when Audiout starts"
    /// (roadmap 050). Defaults to **off**: the locked launch behavior (ahh,
    /// 2026-07-17 — see `GroupController.init`) is that a previously-selected
    /// AirPlay device never auto-streams when the app opens; this bool is the
    /// sanctioned opt-in that lets `GroupController.ensureDefaultSelection()`
    /// resume the persisted routing set instead of seeding {local}.
    public var reconnectAtLaunch: Bool {
        get { defaults.bool(forKey: Keys.reconnectAtLaunch) }
        nonmutating set { defaults.set(newValue, forKey: Keys.reconnectAtLaunch) }
    }

    /// Options (in MINUTES) for the post-wake "restore Mac audio if speakers don't
    /// return" fallback (Settings › Audio, B6b). `0` means "Never". Bare numeric
    /// values by design (ahh, 2026-07-17: named presets with embedded text don't
    /// survive localization; the pane's popup formats these as "N minute(s)").
    public static let wakeRestoreMinuteOptions: [Int] = [0, 1, 2, 5, 10]

    /// The default wake-restore fallback (minutes). `2` — a short sleep reconnects
    /// in ~1–2 s, so 2 minutes only ever trips on a genuine "speaker isn't coming
    /// back" wake, at which point silent-everywhere is worse than un-muting the Mac.
    public static let defaultWakeRestoreMinutes = 2

    /// The persisted post-wake fallback in minutes (`0` = Never). Unset resolves to
    /// ``defaultWakeRestoreMinutes`` (NOT 0 — `UserDefaults.integer` returns 0 for a
    /// missing key, which is a valid "Never", so unset is distinguished via
    /// `object(forKey:)`). Any stored value outside ``wakeRestoreMinuteOptions``
    /// (a newer/older build) also resolves to the default.
    public var wakeRestoreMinutes: Int {
        get {
            guard defaults.object(forKey: Keys.wakeRestoreMinutes) != nil else {
                return Self.defaultWakeRestoreMinutes
            }
            let stored = defaults.integer(forKey: Keys.wakeRestoreMinutes)
            return Self.wakeRestoreMinuteOptions.contains(stored) ? stored : Self.defaultWakeRestoreMinutes
        }
        nonmutating set { defaults.set(newValue, forKey: Keys.wakeRestoreMinutes) }
    }

    /// The default starting volume (percent) a speaker gets the moment it joins
    /// the output set (Settings › Audio "Volume when connecting a speaker"). A
    /// MODERATE 35% by deliberate product decision (G1-N1): the seed used to be
    /// inherited from the Mac's current system level, but Mac speakers often run
    /// loud, so a real AirPlay speaker could BLAST the user on first connect — a
    /// jarring, arguably unsafe first impression. A fixed moderate default is
    /// predictable and safe; the per-device slider still takes over immediately
    /// afterward.
    public static let defaultConnectVolume = 35

    /// The lowest connect volume the setting can hold. NOT 0 on purpose: the
    /// AirPlay volume model maps 0% to ≈ −30 dB, the quietest non-muted level —
    /// effectively silent on the receiver. Seeding a connect at 0 is the −30 dB
    /// "silent connect" trap (see `NativeBackend.connectVolumeSeed`); clamping the
    /// floor above 0 here makes that unreachable through this setting. A low but
    /// audible floor so a user who wants a quiet connect still gets one.
    public static let minConnectVolume = 5

    /// The highest connect volume the setting can hold.
    public static let maxConnectVolume = 100

    /// The default main-out volume (percent). Used when the setting is unset or
    /// during initialization of a new routing session.
    public static let defaultMainOutVolume = 100

    /// The lowest main-out volume the setting can hold.
    public static let minMainOutVolume = 0

    /// The highest main-out volume the setting can hold.
    public static let maxMainOutVolume = 100

    /// The persisted connect-time seed volume (percent), clamped to
    /// ``minConnectVolume``…``maxConnectVolume`` on both read and write so no
    /// stored value — unset (0), a newer build's out-of-range value, or a hand-
    /// edited default — can ever reintroduce the silent-connect floor. Unset
    /// resolves to ``defaultConnectVolume`` (distinguished from a stored 0 via
    /// `object(forKey:)`, then clamped regardless).
    public var connectVolume: Int {
        get {
            guard defaults.object(forKey: Keys.connectVolume) != nil else {
                return Self.defaultConnectVolume
            }
            let stored = defaults.integer(forKey: Keys.connectVolume)
            return min(max(stored, Self.minConnectVolume), Self.maxConnectVolume)
        }
        nonmutating set {
            defaults.set(min(max(newValue, Self.minConnectVolume), Self.maxConnectVolume), forKey: Keys.connectVolume)
        }
    }

    /// The persisted main-out volume (percent), clamped to
    /// ``minMainOutVolume``…``maxMainOutVolume`` on both read and write so no
    /// stored value — unset (0), a newer build's out-of-range value, or a hand-
    /// edited default — can ever escape the valid range. Unset resolves to
    /// ``defaultMainOutVolume`` (distinguished from a stored 0 via `object(forKey:)`,
    /// then clamped regardless).
    public var mainOutVolume: Int {
        get {
            guard defaults.object(forKey: Keys.mainOutVolume) != nil else {
                return Self.defaultMainOutVolume
            }
            let stored = defaults.integer(forKey: Keys.mainOutVolume)
            return min(max(stored, Self.minMainOutVolume), Self.maxMainOutVolume)
        }
        nonmutating set {
            defaults.set(min(max(newValue, Self.minMainOutVolume), Self.maxMainOutVolume), forKey: Keys.mainOutVolume)
        }
    }

    /// The lowest/highest manual sync-offset the setting can hold, and the
    /// unset/reset default (T-OFFSET-UI, Settings › Audio › Advanced). Bare
    /// milliseconds by design — same house rule as ``startBufferOptionsMs``/
    /// ``wakeRestoreMinuteOptions``: no named preset survives localization. Signed
    /// — a device that reports its own latency wrong needs to be nudged either
    /// direction (R1), so unlike the connect-volume floor this range straddles
    /// zero. ±500 ms comfortably covers any plausible misreport while keeping the
    /// slider usable (a wider range buys nothing but a mis-clickable control).
    public static let minSyncOffsetMs = -500
    public static let maxSyncOffsetMs = 500
    public static let defaultSyncOffsetMs = 0

    /// The persisted manual sync-offset bias (ms), clamped to
    /// ``minSyncOffsetMs``…``maxSyncOffsetMs`` on both read and write. Added, as a
    /// static user bias, on top of the computed+corrected delay target inside
    /// ``SyncTiming/totalDelayNanos(presentationDelayMs:localOutputLatencySeconds:safetyMarginMs:userOffsetMs:)``.
    /// Unset resolves to ``defaultSyncOffsetMs`` (0) — distinguished from an
    /// explicitly-stored 0 via `object(forKey:)`, though both resolve to the same
    /// value, exactly like ``wakeRestoreMinutes``'s unset-vs-zero handling.
    public var syncOffsetMs: Int {
        get {
            guard defaults.object(forKey: Keys.syncOffsetMs) != nil else {
                return Self.defaultSyncOffsetMs
            }
            let stored = defaults.integer(forKey: Keys.syncOffsetMs)
            return min(max(stored, Self.minSyncOffsetMs), Self.maxSyncOffsetMs)
        }
        nonmutating set {
            defaults.set(min(max(newValue, Self.minSyncOffsetMs), Self.maxSyncOffsetMs), forKey: Keys.syncOffsetMs)
        }
    }

    /// Whether the iPhone companion app may connect to and control this Mac
    /// (Settings › General "Allow control from iPhone on this network").
    /// Defaults to **`true`** when unset (T22 flip, the owner's call
    /// 2026-08-06): the phone app ships alongside the Mac app now, and the
    /// per-phone approval gate (T24) means an enabled listener still admits
    /// nobody the user hasn't explicitly approved. Unchecking the Settings ›
    /// General checkbox stores `false` and wins. See
    /// ``resolvedAllowRemoteControl(explicit:environment:)``
    /// for the env-var override AppDelegate actually reads at launch.
    public var allowRemoteControl: Bool {
        get {
            guard defaults.object(forKey: Keys.allowRemoteControl) != nil else { return true }
            return defaults.bool(forKey: Keys.allowRemoteControl)
        }
        nonmutating set { defaults.set(newValue, forKey: Keys.allowRemoteControl) }
    }

    /// The env var that force-overrides ``allowRemoteControl`` for one launch,
    /// mirroring `BackendKind.environmentVariableName`'s dev-convenience idiom.
    public static let allowRemoteControlEnvironmentVariableName = "AUDIOUT_COMPANION"

    /// What decided a ``resolvedAllowRemoteControlWithSource(explicit:environment:settings:)``
    /// call — carried alongside the resolved value so a caller that needs to
    /// EXPLAIN itself (the Settings › General checkbox, FIX-C) can tell "this is
    /// the user's own setting" apart from "an override forced this value for the
    /// launch, the setting can't take effect until it's gone." Without this, the
    /// General pane rendered the raw persisted bool while the server actually
    /// ran on the resolved one — a checkbox that could show OFF while a LAN
    /// server was running, and silently do nothing when unchecked.
    public enum RemoteControlResolution: Equatable, Sendable {
        /// The persisted ``allowRemoteControl`` setting decided — nothing
        /// overrode it, so writing the setting takes effect immediately.
        case setting(Bool)
        /// An explicit argument or the `AUDIOUT_COMPANION` env var forced
        /// this value for the current process launch. The persisted setting
        /// still exists underneath but cannot change what's running.
        case forced(Bool)

        /// The resolved value, regardless of what decided it.
        public var value: Bool {
            switch self {
            case .setting(let value), .forced(let value): return value
            }
        }

        /// Whether an override is in force — the setting can't be changed
        /// through the normal write path while this is `true`.
        public var isForced: Bool {
            if case .forced = self { return true }
            return false
        }
    }

    /// Resolve whether the companion server should run, in priority order: an
    /// explicit argument → the `AUDIOUT_COMPANION` env var (`1`/`0` or
    /// `on`/`off`, case-insensitive) → the persisted ``allowRemoteControl``
    /// setting — same priority ``resolvedAllowRemoteControl(explicit:environment:settings:)``
    /// uses, but returned alongside ``RemoteControlResolution`` so a UI can
    /// render the override honestly instead of just reading the raw setting.
    ///
    /// This is an explicit knob, never a silent fallback (mirrors
    /// `BackendKind.resolved`'s policy, OwnToneBackend.swift): an unrecognized
    /// env value is treated as absent — it falls back to the setting and
    /// prints one warning to stderr rather than silently guessing which way
    /// to go.
    public static func resolvedAllowRemoteControlWithSource(
        explicit: Bool? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        settings: AppSettings
    ) -> RemoteControlResolution {
        if let explicit { return .forced(explicit) }

        guard let raw = environment[allowRemoteControlEnvironmentVariableName] else {
            return .setting(settings.allowRemoteControl)
        }
        switch raw.lowercased() {
        case "1", "on":  return .forced(true)
        case "0", "off": return .forced(false)
        default:
            FileHandle.standardError.write(
                Data("warning: unrecognized \(allowRemoteControlEnvironmentVariableName) value \"\(raw)\" — falling back to the setting\n".utf8)
            )
            return .setting(settings.allowRemoteControl)
        }
    }

    /// Convenience over ``resolvedAllowRemoteControlWithSource(explicit:environment:settings:)``
    /// for callers that only need the resolved value (`AppDelegate`, which
    /// only starts/stops the server and never has to explain the source).
    public static func resolvedAllowRemoteControl(
        explicit: Bool? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        settings: AppSettings
    ) -> Bool {
        resolvedAllowRemoteControlWithSource(explicit: explicit, environment: environment, settings: settings).value
    }

    /// Whether this Mac's sync trim has an ENTRY at all — the honest answer to
    /// "tuned or never tuned?", which the value alone cannot give: a Mac
    /// deliberately trimmed to exactly 0 ms IS tuned and must not read "Not
    /// set". The local twin of ``BTOutputControlling/btHasSyncTrim(forDevice:)``.
    public var isSyncOffsetSet: Bool {
        defaults.object(forKey: Keys.syncOffsetMs) != nil
    }

    /// Delete the stored sync offset, returning this Mac to never-tuned
    /// (roadmap 056: the drawer's "Reset alignment"). Removing the key rather
    /// than writing 0 is what ``isSyncOffsetSet`` reads, so a stored 0 would
    /// leave the row reading "0 ms" instead of "Not set".
    public func clearSyncOffset() {
        defaults.removeObject(forKey: Keys.syncOffsetMs)
    }

    /// Whether the one-surface panel is PINNED (an ordinary movable window)
    /// rather than the transient menu-bar bubble. Written by the surface's Pin
    /// button, restored when the surface is constructed — the manner survives
    /// relaunch, matching the pinned window's own frame autosave. Defaults to
    /// `false` (unset): a fresh install gets the transient bubble.
    public var surfacePinned: Bool {
        get { defaults.bool(forKey: Keys.surfacePinned) }
        nonmutating set { defaults.set(newValue, forKey: Keys.surfacePinned) }
    }

    /// Whether the Equalizer card's "Advanced" ten-band fold is expanded. One
    /// global switch — every host's editor shares it, so opening it in one
    /// place opens it everywhere — remembered across launches. Read by
    /// ``EQEditorView`` at init and written on every toggle. Defaults to
    /// `false` (unset): a fresh install shows the fold collapsed.
    public var eqAdvancedExpanded: Bool {
        get { defaults.bool(forKey: Keys.eqAdvancedExpanded) }
        nonmutating set { defaults.set(newValue, forKey: Keys.eqAdvancedExpanded) }
    }

    /// Whether the Mixer's first-run membership hint has been dismissed. Set
    /// the first time the user toggles a speaker's membership in the Mixer;
    /// the hint shows on every Mixer open while this is `false`.
    public var mixerMembershipHintDismissed: Bool {
        get { defaults.bool(forKey: Keys.mixerMembershipHintDismissed) }
        nonmutating set { defaults.set(newValue, forKey: Keys.mixerMembershipHintDismissed) }
    }

    /// The purchase licence key, entered once from the receipt (Settings ›
    /// General, roadmap 054). `nil` when unset — Audiout is fully functional
    /// without one (the Ardour model: the binary is what's sold, never a
    /// software lock — GPL forbids one). Setting `nil` removes the stored value
    /// AND clears ``licenseStatus``: a verdict about a key the user has deleted
    /// is not a verdict about anything. It clears the trial fields for the same
    /// reason — a trial IS a licence key, so a deleted key leaves no trial
    /// behind to be on day 9 of.
    public var licenseKey: String? {
        get { defaults.string(forKey: Keys.licenseKey) }
        nonmutating set {
            defaults.set(newValue, forKey: Keys.licenseKey)
            if newValue == nil {
                licenseStatus = nil
                licenseReason = nil
                companionToken = nil
                clearTrial()
            }
        }
    }

    /// What the server last said about ``licenseKey`` (``LicenseValidator``).
    /// `nil` means never verified — no key, or no answer has ever arrived. The
    /// check is SOFT, so a value here only ever chooses what the UI says; it
    /// gates nothing.
    public var licenseStatus: LicenseStatus? {
        get { defaults.string(forKey: Keys.licenseStatus).flatMap(LicenseStatus.init(rawValue:)) }
        nonmutating set { defaults.set(newValue?.rawValue, forKey: Keys.licenseStatus) }
    }

    /// Whether this install should be treated as unregistered: no key at all,
    /// or a key the server declined (`unknown`/`invalid`/`revoked`). A stored
    /// key with NO verdict yet is **not** unregistered — the check is soft, so
    /// an unanswered question gets the benefit of the doubt.
    ///
    /// Deliberately says nothing about whether this build even has a license
    /// server: callers compose it with `licenseServerURL != nil` themselves,
    /// because a build run from source hides the whole surface rather than
    /// calling anyone unregistered.
    public var licenseUnregistered: Bool {
        if (licenseKey ?? "").isEmpty { return true }
        switch licenseStatus {
        case .unknown, .invalid, .revoked: return true
        case .active, nil: return false
        }
    }

    /// The highest major version the stored key covers, as the server reported
    /// it. `nil` when absent (and for a stored 0, which no real answer uses).
    public var licenseMaxMajor: Int? {
        get {
            let stored = defaults.integer(forKey: Keys.licenseMaxMajor)
            return stored == 0 ? nil : stored
        }
        nonmutating set { defaults.set(newValue, forKey: Keys.licenseMaxMajor) }
    }

    /// Why the server gave the verdict it gave, in the server's own words —
    /// `nil` unless the answer carried one. `trial_expired` is the only value
    /// the server sends today, and it is what separates a trial that ran out
    /// from a key that was refunded: both come back `revoked`, and the gate
    /// has different words for them. Read through
    /// ``TrialClock/hasEnded(settings:now:)``: this is the server's half of
    /// that question, ``trialExpiresAt`` the local half, and a Mac whose
    /// stored dates are gone has only this one. Written on every verified
    /// answer, so an answer with no reason clears the one before it.
    public var licenseReason: String? {
        get { defaults.string(forKey: Keys.licenseReason) }
        nonmutating set { defaults.set(newValue, forKey: Keys.licenseReason) }
    }

    /// The opaque licence-server token for the companion server to forward
    /// to approved iPhones in `welcome`, so the iOS app can unlock offline.
    /// Written only by ``LicenseValidator``. `nil` when never issued, or
    /// cleared alongside ``licenseKey``/``licenseStatus``.
    public var companionToken: String? {
        get { defaults.string(forKey: Keys.companionToken) }
        nonmutating set { defaults.set(newValue, forKey: Keys.companionToken) }
    }

    /// The two trial dates are stored as ISO 8601 text. No other setting here
    /// keeps a date, so this sets the convention rather than following one:
    /// the licence server sends these same two values as ISO 8601 strings, and
    /// text stays readable under `defaults read` where a stored `Date` is an
    /// opaque blob. Fractional seconds are on so a `Date` round-trips exactly.
    private static let trialDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    /// A whole-second twin of ``trialDateFormatter``. `ISO8601DateFormatter`
    /// matches its options exactly, so one formatter reads one spelling.
    private static let wholeSecondDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    /// Reads a timestamp the licence server sent, with or without the
    /// fractional seconds. Both spellings are ordinary ISO 8601 and the server
    /// is free to send either; a date this refused would read to the caller as
    /// "this key has no expiry", which is a wrong answer rather than a missing
    /// one. Only the server's text goes through here — this type's own storage
    /// is always written by ``trialDateFormatter`` and reads back with it.
    static func date(fromServerText text: String) -> Date? {
        trialDateFormatter.date(from: text) ?? wholeSecondDateFormatter.date(from: text)
    }

    /// The other direction, for the one request that sends a date to the
    /// licence server (``TrialRegistrar``). Same formatter the trial dates are
    /// stored with, so the text the server reads is the text on disk — a second
    /// spelling of a timestamp here is how the two ends start disagreeing.
    static func serverText(from date: Date) -> String {
        trialDateFormatter.string(from: date)
    }

    /// When this Mac's 14-day trial began, or `nil` if it never started one.
    /// Written by ``TrialClock`` — locally at the start, then replaced by the
    /// licence server's own record once the trial registers.
    public var trialStartedAt: Date? {
        get { defaults.string(forKey: Keys.trialStartedAt).flatMap(Self.trialDateFormatter.date(from:)) }
        nonmutating set {
            defaults.set(newValue.map(Self.trialDateFormatter.string(from:)), forKey: Keys.trialStartedAt)
        }
    }

    /// When the trial ends. Set once when the trial starts and moved only by
    /// the licence server's own record; nothing else may extend it. A verified
    /// answer that carries no expiry clears it, which is how a trial that has
    /// been bought stops reading as one.
    public var trialExpiresAt: Date? {
        get { defaults.string(forKey: Keys.trialExpiresAt).flatMap(Self.trialDateFormatter.date(from:)) }
        nonmutating set {
            defaults.set(newValue.map(Self.trialDateFormatter.string(from:)), forKey: Keys.trialExpiresAt)
        }
    }

    /// Whether the licence server has answered about this trial. `false` is
    /// ordinary, not a failure: a trial may start with no network at all and
    /// registers on the first connection.
    public var trialRegistered: Bool {
        get { defaults.bool(forKey: Keys.trialRegistered) }
        nonmutating set { defaults.set(newValue, forKey: Keys.trialRegistered) }
    }

    /// Set once the "three days left" trial banner has been shown, so it is
    /// shown once and never again.
    public var trialBannerThreeDaysShown: Bool {
        get { defaults.bool(forKey: Keys.trialBannerThreeDaysShown) }
        nonmutating set { defaults.set(newValue, forKey: Keys.trialBannerThreeDaysShown) }
    }

    /// Set once the last-day trial banner has been shown. Same one-shot rule as
    /// ``trialBannerThreeDaysShown``.
    public var trialBannerLastDayShown: Bool {
        get { defaults.bool(forKey: Keys.trialBannerLastDayShown) }
        nonmutating set { defaults.set(newValue, forKey: Keys.trialBannerLastDayShown) }
    }

    /// Forgets every trial field. Called only from ``licenseKey``'s setter, so
    /// the trial and the key it issued are removed together.
    private func clearTrial() {
        defaults.removeObject(forKey: Keys.trialStartedAt)
        defaults.removeObject(forKey: Keys.trialExpiresAt)
        defaults.removeObject(forKey: Keys.trialRegistered)
        defaults.removeObject(forKey: Keys.trialBannerThreeDaysShown)
        defaults.removeObject(forKey: Keys.trialBannerLastDayShown)
    }

    /// The license server this build talks to, from the bundle's
    /// `AudioutLicenseServerURL` (written by `scripts/make-app.sh` from
    /// `AUDIOUT_LICENSE_URL`). **A build run from source has none** — so it
    /// does no validation, no check-in and shows no buy prompt. That is the
    /// free build, and the absence is the whole switch. The initializer's
    /// override wins when non-nil, for tests.
    public var licenseServerURL: URL? {
        licenseServerURLOverride ?? Self.bundleURL(forInfoDictionaryKey: "AudioutLicenseServerURL")
    }

    /// Where "Buy Audiout…" sends the user, from the bundle's
    /// `AudioutBuyURL` (written by `scripts/make-app.sh` from
    /// `AUDIOUT_BUY_URL`). `nil` in a build that carries no such key, which
    /// is what hides every buy affordance — the Settings button and the
    /// Mixer note's action alike read this one value.
    ///
    /// While a trial is running it carries `?t=<trial key>`, which is what lets
    /// the checkout mark that trial converted and activate this Mac without
    /// anyone pasting a key. It is added HERE, not at the four places that open
    /// the page, so no call site can forget it. Two cases deliberately get the
    /// plain page: a trial that has not registered yet holds no key, and an
    /// invented `t` would name nothing; and a trial that is over is no longer
    /// converting, so its expired key has nothing to say to the checkout.
    public var buyURL: URL? {
        guard let page = buyPageURL else { return nil }
        guard case .active = TrialClock.state(settings: self),
              let key = licenseKey, !key.isEmpty,
              var components = URLComponents(url: page, resolvingAgainstBaseURL: false)
        else { return page }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "t", value: key)]
        return components.url ?? page
    }

    /// The purchase page as configured, before the trial id is added.
    private var buyPageURL: URL? {
        buyURLOverride ?? Self.bundleURL(forInfoDictionaryKey: "AudioutBuyURL")
    }

    /// **https only.** Requests to the license server carry the license key, so
    /// a plain-http endpoint would put it on the wire in the clear; a non-https
    /// value is treated as absent, which degrades to the free build's behavior
    /// rather than to an insecure one. The initializer's
    /// `licenseServerURL`/`buyURL` overrides deliberately bypass this — they
    /// are a test seam, not a shipped input.
    private static func bundleURL(forInfoDictionaryKey key: String) -> URL? {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String)
            .flatMap(URL.init(string:))
            .flatMap { $0.scheme == "https" ? $0 : nil }
    }

    /// A stable per-install identifier for licence check-ins — lazily created
    /// on first read and persisted immediately, so every later read (including
    /// from a fresh `AppSettings` instance over the same store) returns the
    /// same value for the life of this install.
    public var installID: String {
        if let existing = defaults.string(forKey: Keys.licenseInstallID) {
            return existing
        }
        let generated = UUID().uuidString
        defaults.set(generated, forKey: Keys.licenseInstallID)
        return generated
    }

    /// Opt-in usage analytics consent (PRODUCT.md Data Collection stream 1).
    /// Defaults to `false` — off by default, and only ever flipped on by the
    /// user's own answer to the one-time ask (``telemetryAsked``).
    public var telemetryOptIn: Bool {
        get { defaults.bool(forKey: Keys.telemetryOptIn) }
        nonmutating set { defaults.set(newValue, forKey: Keys.telemetryOptIn) }
    }

    /// Whether the one-time ask has been answered — never re-prompt.
    /// Defaults to `false` (unset): a fresh install hasn't been asked yet.
    public var telemetryAsked: Bool {
        get { defaults.bool(forKey: Keys.telemetryAsked) }
        nonmutating set { defaults.set(newValue, forKey: Keys.telemetryAsked) }
    }

    /// The licence check-in endpoint (``LicenseCheckIn``). Normally DERIVED —
    /// `v1/checkin` under ``licenseServerURL`` — so a build that carries a
    /// license server checks in and a build run from source, which carries
    /// none, has no endpoint and stays silent. A stored value overrides the
    /// derived one, which is how tests point it somewhere harmless. `nil` when
    /// there is neither.
    ///
    /// The stored value must be **https** for the same reason
    /// ``bundleURL(forInfoDictionaryKey:)`` insists on it — the check-in POSTs
    /// the license key — so a preference-planted `http://` endpoint is ignored
    /// and the derived https URL answers instead.
    public var checkInURL: URL? {
        get {
            defaults.string(forKey: Keys.licenseCheckInURL)
                .flatMap(URL.init(string:))
                .flatMap { $0.scheme == "https" ? $0 : nil }
                ?? licenseServerURL?.appending(path: "v1/checkin")
        }
        nonmutating set { defaults.set(newValue?.absoluteString, forKey: Keys.licenseCheckInURL) }
    }

    /// Whether Audiout may replace the Touch Bar with its own controls while
    /// it is playing to speakers (Settings › General, "Use Audiout's Touch Bar
    /// controls"). ON unless the user turned it off — taking the whole bar is
    /// a big enough intrusion that it needs a visible way out. Only meaningful
    /// on Touch Bar hardware; the Settings row hides itself everywhere else.
    /// Unset resolves to `true` (distinguished from a stored `false` via
    /// `object(forKey:)`, the same discipline the other default-true settings
    /// use).
    public var touchBarControlsEnabled: Bool {
        get {
            guard defaults.object(forKey: Keys.touchBarControls) != nil else { return true }
            return defaults.bool(forKey: Keys.touchBarControls)
        }
        nonmutating set { defaults.set(newValue, forKey: Keys.touchBarControls) }
    }
}
