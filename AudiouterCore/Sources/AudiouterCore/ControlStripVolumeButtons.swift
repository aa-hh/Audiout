// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

// Prepares the Touch Bar's Control Strip so the app's OWN volume buttons are
// visible and useful while we own the volume, and puts everything back exactly
// as it was the moment we don't
// (`docs/plans/PLAN-VOLUME-KEY-INTERCEPTION.md` §7b).
//
// WHY THE APP DRAWS ITS OWN BUTTONS: Apple's Control Strip volume buttons GREY
// OUT when the default output publishes no settable volume — our aggregate —
// and a greyed button posts no event at all. Live-probed at both the session
// and HID event-tap layers: nothing. So there is nothing to intercept and
// nothing to un-grey; the only way to give a Touch Bar user working volume is
// to put our own control there (registered by `TouchBarVolumeTrayItem` in the
// app target, which owns the private system-tray API).
//
// This type owns the two things that have to be true for that control to be
// seen, and BOTH are user settings we are borrowing, never keeping:
//   1. the Touch Bar must be in "App Controls with Control Strip" mode — a
//      tray item does not render in the expanded-strip mode;
//   2. Apple's dead audio controls should go, because a greyed volume sitting
//      next to a working one reads as a bug.

// MARK: - The layout transform (pure)

/// Control Strip item identifiers, and the transforms over a layout array.
/// Identifiers extracted from `ControlStrip.app`'s binary.
public enum ControlStripLayout {

    /// Tap-to-open volume slider.
    public static let sliderItem = "com.apple.system.volume"
    /// Expands into discrete −/+ buttons.
    public static let buttonGroupItem = "com.apple.system.group.volume"
    /// Standalone discrete buttons, for a user who placed them individually.
    public static let discreteItems: Set<String> = [
        "com.apple.system.volume-up", "com.apple.system.volume-down",
    ]
    public static let muteItem = "com.apple.system.mute"

    /// Every Apple audio control. All of them die together on an output with no
    /// settable volume — mute included, which is why it is in here.
    public static var audioItems: Set<String> {
        discreteItems.union([sliderItem, buttonGroupItem, muteItem])
    }

    /// "App Controls with Control Strip" — the only presentation mode a
    /// third-party tray item renders in (live-verified: invisible in
    /// `fullControlStrip`).
    public static let appControlsMode = "appWithControlStrip"

    /// `items` with Apple's dead audio controls removed, or `nil` when there
    /// were none — nothing to do, and no marker should be taken.
    ///
    /// Everything else keeps its exact position, including identifiers from a
    /// future macOS we know nothing about. This is a removal, never a rewrite.
    public static func removingAudioItems(_ items: [String]) -> [String]? {
        let audio = audioItems
        guard items.contains(where: { audio.contains($0) }) else { return nil }
        return items.filter { !audio.contains($0) }
    }

    /// What to write when handing a setting back, or `nil` to leave it alone.
    ///
    /// Declines when `current` is no longer what we wrote: the user changed that
    /// setting themselves while our change was in force, and restoring would
    /// throw their newer choice away. Losing our change is the right trade there
    /// — theirs is the deliberate one.
    public static func restoring<T: Equatable>(current: T, weWrote: T, original: T) -> T? {
        current == weWrote ? original : nil
    }
}

// MARK: - Seams

/// Reading and writing the Touch Bar's Control Strip settings, behind a protocol
/// so the logic is testable with a fake. **No fake may ever touch the real
/// `com.apple.controlstrip` / `com.apple.touchbar.agent` domains** — same rule
/// as ``AggregateDeviceControlling``.
public protocol ControlStripControlling: Sendable {
    /// The stored layout for `key`, or `nil` when the user has never customized
    /// it (macOS then renders a factory default that lives in ControlStrip's own
    /// code, readable from nowhere).
    func layout(forKey key: String) -> [String]?
    func setLayout(_ items: [String]?, forKey key: String)
    /// `com.apple.touchbar.agent`'s `PresentationModeGlobal`.
    var presentationMode: String? { get }
    func setPresentationMode(_ mode: String?)
    /// Make ControlStrip pick the changes up.
    func reload()
    /// Whether this Mac physically has a Touch Bar.
    var hasTouchBar: Bool { get }
}

/// Where the borrowed settings are remembered, so a crash can't strand the user
/// on a Touch Bar they never chose.
public protocol ControlStripSwapStoring: Sendable {
    /// Layouts as they were before we changed them, keyed by layout key. Empty
    /// means we hold nothing — also the "nothing to undo" signal after a restore.
    var controlStripOriginalLayouts: [String: [String]] { get nonmutating set }
    /// What we actually wrote, so a restore can tell our own value from one the
    /// user has changed since.
    var controlStripWrittenLayouts: [String: [String]] { get nonmutating set }
    /// The presentation mode as it was, and what we replaced it with. `nil`
    /// original is meaningful — the user had never set one.
    var controlStripOriginalMode: String? { get nonmutating set }
    var controlStripWrittenMode: String? { get nonmutating set }
    /// Whether we currently hold ANY borrowed setting. Needed because "original
    /// mode was nil" is a real state that the dictionaries alone can't express.
    var controlStripHoldsChanges: Bool { get nonmutating set }
}

// MARK: - The owner

/// Borrows the Control Strip settings our own volume buttons need, and gives
/// them back.
///
/// KNOWN CEILING: this can only transform a layout it can READ. A user who has
/// never opened Customize Control Strip has no stored layout — macOS renders a
/// factory default baked into `ControlStrip.app` and published through no plist
/// — so their Apple audio controls stay put, greyed, beside ours. Writing a
/// constructed "default minus audio" would put a strip on their Mac that we
/// invented, in slots that have nothing to do with volume.
/// razor: upgrade path, should it matter — pin the factory default per macOS
/// version by observation and treat an absent key as that array.
public struct ControlStripVolumeButtons: Sendable {

    /// Both Control Strip layouts: the collapsed strip and the expanded one.
    /// Handled independently — a user may have customized either, both, neither.
    public static let layoutKeys = ["MiniCustomized", "FullCustomized"]

    private let control: ControlStripControlling
    private let store: ControlStripSwapStoring

    public init(control: ControlStripControlling, store: ControlStripSwapStoring) {
        self.control = control
        self.store = store
    }

    /// Follow volume ownership: borrow while we own it, hand everything back
    /// when we don't.
    public func apply(weOwnVolume: Bool) {
        weOwnVolume ? borrow() : restore()
    }

    /// Undo changes left behind by a previous run — a crash or `SIGKILL` between
    /// borrowing and restoring would otherwise strand the user in a Touch Bar
    /// mode they never chose, with nothing on screen to explain it. Call at
    /// launch, before ownership is known.
    public func restoreIfStale() {
        guard store.controlStripHoldsChanges else { return }
        restore()
    }

    private func borrow() {
        guard control.hasTouchBar, !store.controlStripHoldsChanges else { return }

        var originalLayouts: [String: [String]] = [:]
        var writtenLayouts: [String: [String]] = [:]
        for key in Self.layoutKeys {
            guard let current = control.layout(forKey: key),
                  let stripped = ControlStripLayout.removingAudioItems(current)
            else { continue }
            originalLayouts[key] = current
            writtenLayouts[key] = stripped
        }

        let currentMode = control.presentationMode
        let needsMode = currentMode != ControlStripLayout.appControlsMode
        guard !originalLayouts.isEmpty || needsMode else { return }

        // Record BEFORE writing. A crash between the two must leave us able to
        // undo; the reverse order can strand the user permanently.
        store.controlStripOriginalLayouts = originalLayouts
        store.controlStripWrittenLayouts = writtenLayouts
        store.controlStripOriginalMode = needsMode ? currentMode : nil
        store.controlStripWrittenMode = needsMode ? ControlStripLayout.appControlsMode : nil
        store.controlStripHoldsChanges = true

        for (key, items) in writtenLayouts { control.setLayout(items, forKey: key) }
        if needsMode { control.setPresentationMode(ControlStripLayout.appControlsMode) }
        control.reload()
    }

    private func restore() {
        guard store.controlStripHoldsChanges else { return }
        let originalLayouts = store.controlStripOriginalLayouts
        let writtenLayouts = store.controlStripWrittenLayouts

        for (key, original) in originalLayouts {
            guard let weWrote = writtenLayouts[key], let current = control.layout(forKey: key),
                  let restored = ControlStripLayout.restoring(
                    current: current, weWrote: weWrote, original: original)
            else { continue }
            control.setLayout(restored, forKey: key)
        }

        if let weWrote = store.controlStripWrittenMode,
           let restored = ControlStripLayout.restoring(
            current: control.presentationMode, weWrote: weWrote,
            original: store.controlStripOriginalMode) {
            control.setPresentationMode(restored)
        }

        // Clear the marker even where we wrote nothing — the user changed that
        // setting out from under us, so it is theirs now and re-asserting our
        // version later would be us fighting them.
        store.controlStripOriginalLayouts = [:]
        store.controlStripWrittenLayouts = [:]
        store.controlStripOriginalMode = nil
        store.controlStripWrittenMode = nil
        store.controlStripHoldsChanges = false
        control.reload()
    }
}

extension AppSettings: ControlStripSwapStoring {}

// MARK: - Production

/// ``ControlStripControlling`` over the real preference domains.
public struct CoreFoundationControlStripControl: ControlStripControlling {

    private static let stripDomain = "com.apple.controlstrip" as CFString
    private static let agentDomain = "com.apple.touchbar.agent" as CFString
    private static let modeKey = "PresentationModeGlobal" as CFString

    public init() {}

    public func layout(forKey key: String) -> [String]? {
        CFPreferencesCopyAppValue(key as CFString, Self.stripDomain) as? [String]
    }

    /// Written through `CFPreferences`, never by touching the plist on disk:
    /// `cfprefsd` owns that file and would overwrite anything we put there
    /// behind its back.
    public func setLayout(_ items: [String]?, forKey key: String) {
        CFPreferencesSetAppValue(key as CFString, items as CFArray?, Self.stripDomain)
        CFPreferencesAppSynchronize(Self.stripDomain)
    }

    public var presentationMode: String? {
        CFPreferencesCopyAppValue(Self.modeKey, Self.agentDomain) as? String
    }

    public func setPresentationMode(_ mode: String?) {
        CFPreferencesSetAppValue(Self.modeKey, mode as CFString?, Self.agentDomain)
        CFPreferencesAppSynchronize(Self.agentDomain)
    }

    /// ControlStrip is an on-demand LaunchAgent running as the user, so ending
    /// it needs no privilege and it respawns immediately with the new settings.
    public func reload() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["ControlStrip"]
        try? task.run()
    }

    public var hasTouchBar: Bool {
        guard let model = Self.hardwareModel() else { return false }
        return Self.touchBarModels.contains(model)
    }

    /// Every Touch Bar Mac that can run macOS 14, our deployment target.
    ///
    /// razor: a literal set, not a private API. The list is CLOSED and can never
    /// need another entry — the Touch Bar was discontinued after the 13" M2
    /// (2022), and Sonoma dropped every model older than 2018.
    ///
    /// NOT usable as a Touch Bar test, though it looks like one: ControlStrip's
    /// LaunchAgent carries no `LimitLoadToHardware` key, so the process exists
    /// on Macs with no Touch Bar at all.
    private static let touchBarModels: Set<String> = [
        "MacBookPro15,1", "MacBookPro15,2", "MacBookPro15,3", "MacBookPro15,4",  // 2018–2019
        "MacBookPro16,1", "MacBookPro16,2", "MacBookPro16,3", "MacBookPro16,4",  // 2019–2020
        "MacBookPro17,1",                                                        // 13" M1 2020
        "Mac14,7",                                                               // 13" M2 2022
    ]

    private static func hardwareModel() -> String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
