// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore

/// The single resolution point for "what SF Symbol represents this device."
///
/// A device's icon is either the device's own default (`Device.symbolName`,
/// derived from its `Device.Kind`) or a user-chosen override persisted by
/// ``DeviceIconController``. Overrides are stored as bare SF Symbol name
/// strings (never colors, never custom assets — see the house rule in
/// `../../AGENTS.md`), so an override can go stale: a name saved on one
/// macOS version may not resolve on another (older OS, symbol renamed/
/// removed). `DeviceIcon` is where that staleness is caught, once, so every
/// caller — the popover, the mixer window, the icon picker — falls back to
/// the same default instead of silently rendering a blank/missing glyph.
public enum DeviceIcon {

    /// A hand-picked set of SF Symbols that read well as a device glyph at
    /// row-icon size, offered by the icon picker UI. This is a curation, not
    /// an exhaustive symbol catalog — every name here is expected to resolve
    /// on any macOS version the app ships against, but callers MUST still run
    /// the list through ``isValid(_:)`` before presenting it, since a symbol
    /// can be deprecated/removed in a future OS out from under this list.
    public static let curated: [String] = [
        "hifispeaker.fill",
        "hifispeaker.2.fill",
        "homepod.fill",
        "homepod.2.fill",
        "appletv.fill",
        "tv.fill",
        "airpods",
        "airpodspro",
        "headphones",
        "speaker.wave.2.fill",
        "speaker.wave.3.fill",
        "radio.fill",
        "music.note",
        "music.note.house.fill",
        "house.fill",
        "bed.double.fill",
        "sofa.fill",
        "fork.knife",
        "laptopcomputer",
        "desktopcomputer",
        "wifi.router.fill",
        "guitars.fill",
        "gamecontroller.fill",
        "rectangle.3.group",
    ]

    /// Whether `name` currently resolves to a real SF Symbol on this OS.
    /// Backed by `NSImage(systemSymbolName:accessibilityDescription:)`, which
    /// returns `nil` for an unknown or unavailable name — the same check the
    /// OS itself uses to decide whether the symbol exists.
    public static func isValid(_ name: String) -> Bool {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }

    /// Resolve the icon to actually render: `override` when it's non-nil
    /// AND resolves on this OS, else `defaultName`. This is the render-time
    /// fallback for a stale override (symbol renamed/removed since it was
    /// saved) — callers never need their own nil-check-plus-validate dance.
    public static func resolve(_ override: String?, default defaultName: String) -> String {
        guard let override, isValid(override) else { return defaultName }
        return override
    }

    /// The glyph for MAIN AUDIO — the whole mix, not a device. Owner's chosen
    /// symbol `hifispeaker.arrow.forward.fill` arrived in macOS 15 and the
    /// deployment target is macOS 14, so it resolves through the same
    /// staleness fallback every other icon uses: the exact symbol once the OS
    /// is new enough, plain `hifispeaker.fill` below that.
    ///
    /// One definition, because two surfaces now draw it — the popover's Main
    /// Audio row and the Groups screen's Main Audio page (sidebar row and
    /// header) — and they must never show different speakers.
    public static var mainAudioSymbolName: String {
        resolve("hifispeaker.arrow.forward.fill", default: "hifispeaker.fill")
    }

    /// The cache behind ``image(_:pointSize:weight:)``. MAIN-THREAD ONLY — every
    /// call site is AppKit view code, so no lock is bought for a dictionary that
    /// is only ever touched from one thread.
    private nonisolated(unsafe) static var imageCache: [String: NSImage] = [:]

    /// A template `NSImage` for the SF Symbol `name`, built once and reused.
    ///
    /// Row builds are the hot path: the sidebar, the membership rows and the
    /// detail pane's group rows each mint a fresh `NSImage` per row per
    /// rebuild, and rebuilds arrive with every backend event. The symbol lookup
    /// is the expensive half and its result is immutable, so it is memoized on
    /// all three inputs. No eviction: the key space is the curated set plus the
    /// device kinds, times a handful of sizes.
    ///
    /// The returned image is SHARED — callers must NOT mutate it. Tinting is a
    /// view property (`contentTintColor`), which is what every call site
    /// already uses.
    public static func image(_ name: String,
                             pointSize: CGFloat? = nil,
                             weight: NSFont.Weight = .regular) -> NSImage? {
        let key = "\(name)|\(pointSize ?? -1)|\(weight.rawValue)"
        if let cached = imageCache[key] { return cached }
        guard var image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            return nil
        }
        if let pointSize,
           let configured = image.withSymbolConfiguration(
               NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)) {
            image = configured
        }
        image.isTemplate = true
        imageCache[key] = image
        return image
    }
}

/// In-memory per-device icon override map, persisted through an injected
/// ``DeviceIconStore``. Mirrors the `ExcludedAppsController` idiom: a small,
/// independent controller with its own store, load-on-init, and persist-on-
/// every-mutation.
///
/// This is the ONLY place a device icon override is looked up or written —
/// the popover, the mixer window rows, and the icon picker all go through
/// `symbolName(for:)` / `setSymbolName(_:for:)` rather than touching the
/// store or an override dictionary directly, so staleness handling
/// (``DeviceIcon/resolve(_:default:)``) can never be bypassed.
public final class DeviceIconController {

    private let store: DeviceIconStore

    /// Raw `deviceID -> symbolName` overrides as persisted, keyed by
    /// `Device.id`. Never read directly by UI — go through
    /// `symbolName(for:)`, which resolves staleness against the device's
    /// default. Exposed for tests that need to assert the persisted shape.
    private(set) public var overrides: [String: String]

    /// Fired after any mutation (`setSymbolName`/`resetIcon`) that actually
    /// changed state, so hosts can refresh rows without polling.
    public var onChange: (() -> Void)?

    /// - Parameters:
    ///   - store: persistence for the override map. Defaults to the on-disk
    ///     store; tests inject one pointed at a temp directory.
    ///   - loadPersisted: load saved overrides immediately. Tests that don't
    ///     care about persistence can skip the disk hit.
    public init(store: DeviceIconStore = DeviceIconStore(), loadPersisted: Bool = true) {
        self.store = store
        self.overrides = loadPersisted ? ((try? store.load()) ?? [:]) : [:]
    }

    private func persist() {
        do { try store.save(overrides) } catch { StoreRecovery.noteWriteFailure(error) }
    }

    // MARK: Queries

    /// The symbol to render for `device`: its override if one is set and
    /// still valid on this OS, else the device's own default (`Device`'s
    /// `symbolName`, which is the kind's glyph everywhere except a Bluetooth
    /// pairing that reports itself as headphones or car audio).
    public func symbolName(for device: Device) -> String {
        DeviceIcon.resolve(overrides[device.id], default: device.symbolName)
    }

    // MARK: Mutations

    /// Set `deviceID`'s icon override to `name`. No-op (no persist, no
    /// state change, no `onChange`) if `name` isn't a symbol that resolves
    /// on this OS — an invalid override would just render as the default
    /// anyway, so there is nothing to gain by persisting it.
    public func setSymbolName(_ name: String, for deviceID: String) {
        guard DeviceIcon.isValid(name) else { return }
        guard overrides[deviceID] != name else { return }
        overrides[deviceID] = name
        persist()
        onChange?()
    }

    /// Clear `deviceID`'s override, reverting it to its kind's default icon.
    /// No-op if there was no override set.
    public func resetIcon(for deviceID: String) {
        guard overrides[deviceID] != nil else { return }
        overrides[deviceID] = nil
        persist()
        onChange?()
    }
}
