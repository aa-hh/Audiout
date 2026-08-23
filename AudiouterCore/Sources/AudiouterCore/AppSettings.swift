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
/// decision i): how strongly the gold instrument tokens (`gold`/`ember`/`glow`)
/// render. `.fullGold` is the flagship default; `.subtle` desaturates the gold
/// channel and removes the glow; `.systemAccent` pulls the Mac's accent color
/// into every gold slot. The dial remaps ONLY the gold channel — `failure`,
/// `caution`, `ring-connected`, and all text tokens are never remapped. Core
/// owns only the persisted choice; the token remap itself lives with the token
/// module (`AudiouterSharedUI.Tokens`), since Core imports no AppKit.
public enum AccentStyle: String, CaseIterable, Sendable {
    case fullGold
    case subtle
    case systemAccent
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

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private enum Keys {
        static let theme = "appearance.theme"
        static let accentStyle = "appearance.accentStyle"
        static let startBufferMs = "audio.startBufferMs"
        static let hasCompletedSetup = "setup.hasCompleted"
        static let reconnectAtLaunch = "general.reconnectAtLaunch"
        static let wakeRestoreMinutes = "audio.wakeRestoreMinutes"
        static let connectVolume = "audio.connectVolume"
        static let mainOutVolume = "audio.mainOutVolume"
        static let syncOffsetMs = "audio.syncOffsetMs"
        static let surfacePinned = "surface.pinned"
        static let eqAdvancedExpanded = "eq.advancedExpanded"
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

    /// Settings › General "Reconnect last speakers when Audiouter starts"
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
}
