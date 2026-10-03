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

    /// Point size and offset for each glyph a row draws inside its ring
    /// (owner-approved table, `dev/notes/ring-glyph-optical-table-2026-10-03.md`):
    /// each symbol is sized to the AirPlay speaker's visual weight and nudged
    /// so its optical centre sits on the ring's centre. Offsets in pt,
    /// + x = right, + y = up. A symbol missing here draws at
    /// `PopoverColumnGrid.iconGlyphPointSize`, centred.
    static let rowGlyphFits: [String: (pointSize: CGFloat, dx: CGFloat, dy: CGFloat)] = [
        "hifispeaker.fill": (18, 0, 0),
        "homepod.fill": (19, 0, 0),
        "appletv.fill": (16, 0, 0),
        "wifi.router.fill": (14.75, 0.25, 1.25),
        "laptopcomputer": (14.25, 0, 0.25),
        "tv.and.hifispeaker.fill": (14.25, 0, -0.5),
        "radio.fill": (14, 0, 0.75),
        "headphones": (17.5, 0, 0.5),
        "car.fill": (16.25, 0, 0.25),
        "airpods": (17.75, 0, -1),
        "airpodspro": (17.25, 0.25, 0),
        "airpodsmax": (17.25, 0, 0.5),
        "airpods.gen3": (16.75, 0, -0.5),
        "airpods.gen4": (17, 0, -0.5),
        "beats.powerbeatspro": (15, 0, 0),
        "beats.earphones": (16.5, 0, -1.25),
        "beats.fit.pro": (14.25, 0, 0.25),
        "beats.studiobud.right": (20.75, 0.75, 0.5),
        "beats.headphones": (18.25, 0, 0.25),
        "hifispeaker.arrow.forward.fill": (16.75, 0.5, 0),
        "hifispeaker.2.fill": (14.5, 0, -0.5),
        "homepod.2.fill": (15, 0, -0.5),
        "tv.fill": (14.25, 0, -0.25),
        "speaker.wave.2.fill": (17.5, 0.75, 0),
        "speaker.wave.3.fill": (15.5, 0.5, 0.25),
        "music.note": (21.25, 0, 0),
        "music.note.house.fill": (15, 0, 0.5),
        "house.fill": (15.25, 0, 0.5),
        "bed.double.fill": (15.75, 0, 0),
        "sofa.fill": (14, 0, -0.25),
        "fork.knife": (19.25, -0.25, -0.25),
        "desktopcomputer": (15.5, 0, 0),
        "guitars.fill": (14.5, -0.25, 1),
        "gamecontroller.fill": (14.5, 0, 0),
    ]

    @MainActor
    private static var rowGlyphCache: [String: NSImage] = [:]

    /// The glyph a row draws inside its ring: a `PopoverColumnGrid.iconWidth`
    /// square template image with `name` drawn at its ``rowGlyphFits`` size,
    /// centred in the square and moved by its offset. The image is the icon
    /// box's own size, so the image view shows it 1:1 and the ring and dot
    /// anchored to that view stay put. A symbol too big for the box shrinks
    /// to fit, as `.scaleProportionallyDown` did before. SHARED — never
    /// mutate it; tint with `contentTintColor`.
    @MainActor
    public static func rowGlyph(_ name: String) -> NSImage? {
        if let cached = rowGlyphCache[name] { return cached }
        let fit = rowGlyphFits[name] ?? (PopoverColumnGrid.iconGlyphPointSize, 0, 0)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: fit.pointSize, weight: .regular))
        else { return nil }
        let box = PopoverColumnGrid.iconWidth
        let scale = min(1, box / symbol.size.width, box / symbol.size.height)
        let size = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
        let image = NSImage(size: NSSize(width: box, height: box), flipped: false) { rect in
            symbol.draw(in: NSRect(x: rect.midX - size.width / 2 + fit.dx,
                                   y: rect.midY - size.height / 2 + fit.dy,
                                   width: size.width, height: size.height))
            return true
        }
        image.isTemplate = true
        rowGlyphCache[name] = image
        return image
    }

    /// The cache behind ``image(_:pointSize:weight:)``. Main-actor isolated —
    /// every call site is AppKit view code, so no lock is bought for a
    /// dictionary that is only ever touched from the main actor.
    @MainActor
    private static var imageCache: [String: NSImage] = [:]

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
    @MainActor
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
