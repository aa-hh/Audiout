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

/// Row/icon density for the popover (Settings › Appearance). Two levels for now
/// — `.comfortable` is today's Control-Center spacing; `.compact` fits more
/// devices on screen at once. A third (`.large`, accessibility) is intentionally
/// left for later; callers must treat the set as open (`switch` with a default),
/// not exhaustive.
public enum InterfaceDensity: String, CaseIterable, Sendable {
    case comfortable
    case compact
}

/// The app's **scalar** user preferences, backed by `UserDefaults`.
///
/// This is the deliberate other half of the persistence split (decided with the
/// popover-routing work): *scalars* (theme, density, small booleans) live in
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
        static let density = "appearance.density"
        static let startBufferMs = "audio.startBufferMs"
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

    /// The popover density. Defaults to `.comfortable` when unset or unrecognised.
    public var density: InterfaceDensity {
        get { defaults.string(forKey: Keys.density).flatMap(InterfaceDensity.init(rawValue:)) ?? .comfortable }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Keys.density) }
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
}
