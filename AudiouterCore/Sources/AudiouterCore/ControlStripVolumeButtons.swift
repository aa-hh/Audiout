// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

// Swaps the Touch Bar's volume SLIDER for its discrete −/+ buttons while we own
// the volume, and puts the user's own layout back the moment we don't
// (`docs/plans/PLAN-VOLUME-KEY-INTERCEPTION.md` §7).
//
// WHY THIS IS NEEDED AT ALL: `ControlStrip.app` drives its discrete Volume
// Up/Down buttons through `DFRFoundationPostHIDUsage` — a real HID usage, so the
// key interceptor sees them. Its volume SLIDER instead calls
// `AudioObjectSetPropertyData` on the device directly and greys itself out from
// `AudioObjectIsPropertySettable`. On our aggregate the slider is therefore dead
// and emits nothing anyone could intercept, while the buttons still work. A Touch
// Bar user sitting on the slider gets no benefit from the interceptor unless the
// layout changes — hence this.
//
// The change is DELIBERATELY not permanent: buttons while Audiouter is the Mac's
// output, their own layout back afterwards.

// MARK: - The layout transform (pure)

/// The Control Strip item identifiers we care about, and the in-place swap
/// between them. Extracted from `ControlStrip.app`'s binary.
public enum ControlStripLayout {

    /// Tap-to-open volume slider. The half that goes dead on our aggregate.
    public static let sliderItem = "com.apple.system.volume"
    /// Expands into discrete −/+ buttons. Occupies the same single slot as
    /// ``sliderItem``, which is what makes this swap a pure substitution.
    public static let buttonGroupItem = "com.apple.system.group.volume"
    /// Standalone discrete buttons, for a user who placed them individually.
    public static let discreteItems: Set<String> = [
        "com.apple.system.volume-up", "com.apple.system.volume-down",
    ]

    /// `items` with the volume slider replaced by the button group, or `nil` when
    /// there is nothing to do.
    ///
    /// `nil` covers two very different "leave it alone" cases, both deliberate:
    /// the user is ALREADY on buttons, or they have no volume item at all — in
    /// which case they removed it on purpose and adding one back would be us
    /// redesigning their Touch Bar rather than swapping one control for another.
    ///
    /// Every other identifier keeps its exact position, including ones from a
    /// future macOS we know nothing about. This is a substitution, never a rewrite.
    public static func swappingSliderForButtons(_ items: [String]) -> [String]? {
        guard !items.contains(buttonGroupItem),
              items.allSatisfy({ !discreteItems.contains($0) }),
              items.contains(sliderItem)
        else { return nil }

        return items.map { $0 == sliderItem ? buttonGroupItem : $0 }
    }

    /// What to write when handing the layout back, or `nil` to leave it alone.
    ///
    /// Declines when `current` is no longer what we wrote: the user re-customized
    /// their Control Strip while our swap was in force, and restoring would throw
    /// their newer choice away. Losing our swap is the right trade there — theirs
    /// is the deliberate one.
    public static func restoring(current: [String], weWrote: [String], original: [String]) -> [String]? {
        current == weWrote ? original : nil
    }
}

// MARK: - Seams

/// Reading and writing the Control Strip's layout, behind a protocol so the swap
/// logic is testable with a fake. **No fake may ever touch the real
/// `com.apple.controlstrip` domain** — same rule as ``AggregateDeviceControlling``.
public protocol ControlStripControlling: Sendable {
    /// The stored layout for `key`, or `nil` when the user has never customized
    /// it (macOS then renders a factory default that lives in ControlStrip's own
    /// code, readable from nowhere — see ``ControlStripVolumeButtons``).
    func layout(forKey key: String) -> [String]?
    func setLayout(_ items: [String]?, forKey key: String)
    /// Make ControlStrip pick the change up.
    func reload()
    /// Whether this Mac physically has a Touch Bar.
    var hasTouchBar: Bool { get }
}

/// Where the swap remembers what it changed, so a crash can't strand the user on
/// a layout they never chose.
public protocol ControlStripSwapStoring: Sendable {
    /// The layout that was there before we swapped, per key. Empty when we hold
    /// no swap — which is also the "nothing to undo" signal after a clean restore.
    var controlStripOriginalLayouts: [String: [String]] { get nonmutating set }
    /// What we actually wrote, per key, so a later restore can tell our own value
    /// from one the user has since changed.
    var controlStripWrittenLayouts: [String: [String]] { get nonmutating set }
}

// MARK: - The owner

/// Applies and undoes the Touch Bar swap in step with volume ownership.
///
/// KNOWN CEILING, and it is the honest cost of not redesigning anyone's Touch
/// Bar: this can only transform a layout it can READ. A user who has never
/// opened Customize Control Strip has no stored layout — macOS renders a factory
/// default baked into `ControlStrip.app` and published through no plist — so
/// there is nothing to swap and they are left alone. Writing a constructed
/// "default with buttons" would put a strip on their Mac that we invented, in
/// slots that have nothing to do with volume.
/// razor: upgrade path, should it ever matter enough — pin the factory default
/// per macOS version by observation and treat an absent key as that array.
public struct ControlStripVolumeButtons: Sendable {

    /// Both Control Strip layouts: the collapsed four-item strip and the expanded
    /// one. Swapped independently — a user may have customized either, both, or
    /// neither.
    public static let layoutKeys = ["MiniCustomized", "FullCustomized"]

    private let control: ControlStripControlling
    private let store: ControlStripSwapStoring

    public init(control: ControlStripControlling, store: ControlStripSwapStoring) {
        self.control = control
        self.store = store
    }

    /// Follow volume ownership: swap in the buttons while we own it, hand the
    /// user's own layout back when we don't.
    public func apply(weOwnVolume: Bool) {
        weOwnVolume ? swapIn() : restore()
    }

    /// Undo a swap left behind by a previous run — a crash or `SIGKILL` between
    /// writing the layout and restoring it would otherwise strand the user on
    /// buttons they never chose, with nothing on screen to explain it. Call at
    /// launch, before ownership is known.
    public func restoreIfStale() {
        guard !store.controlStripOriginalLayouts.isEmpty else { return }
        restore()
    }

    private func swapIn() {
        guard control.hasTouchBar, store.controlStripOriginalLayouts.isEmpty else { return }

        var originals: [String: [String]] = [:]
        var written: [String: [String]] = [:]
        for key in Self.layoutKeys {
            guard let current = control.layout(forKey: key),
                  let swapped = ControlStripLayout.swappingSliderForButtons(current)
            else { continue }
            originals[key] = current
            written[key] = swapped
        }
        guard !originals.isEmpty else { return }

        // Record BEFORE writing. A crash between the two must leave us able to
        // undo; the reverse order can strand the user permanently.
        store.controlStripOriginalLayouts = originals
        store.controlStripWrittenLayouts = written
        for (key, items) in written { control.setLayout(items, forKey: key) }
        control.reload()
    }

    private func restore() {
        let originals = store.controlStripOriginalLayouts
        guard !originals.isEmpty else { return }
        let written = store.controlStripWrittenLayouts

        var didWrite = false
        for (key, original) in originals {
            guard let weWrote = written[key], let current = control.layout(forKey: key),
                  let restored = ControlStripLayout.restoring(
                    current: current, weWrote: weWrote, original: original)
            else { continue }
            control.setLayout(restored, forKey: key)
            didWrite = true
        }

        // Clear the marker even when we wrote nothing — the user changed their
        // layout out from under us, so our swap is theirs now and re-asserting it
        // later would be us fighting them.
        store.controlStripOriginalLayouts = [:]
        store.controlStripWrittenLayouts = [:]
        if didWrite { control.reload() }
    }
}

extension AppSettings: ControlStripSwapStoring {}

// MARK: - Production

/// ``ControlStripControlling`` over the real `com.apple.controlstrip` domain.
public struct CoreFoundationControlStripControl: ControlStripControlling {

    private static let domain = "com.apple.controlstrip" as CFString

    public init() {}

    public func layout(forKey key: String) -> [String]? {
        CFPreferencesCopyAppValue(key as CFString, Self.domain) as? [String]
    }

    /// Written through `CFPreferences`, never by touching the plist on disk:
    /// `cfprefsd` owns that file and would overwrite anything we put there behind
    /// its back.
    public func setLayout(_ items: [String]?, forKey key: String) {
        CFPreferencesSetAppValue(key as CFString, items as CFArray?, Self.domain)
        CFPreferencesAppSynchronize(Self.domain)
    }

    /// ControlStrip is an on-demand LaunchAgent running as the user, so ending it
    /// needs no privilege and it respawns immediately with the new layout.
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
    /// (2022), and Sonoma dropped every model older than 2018. Upgrade path, if a
    /// dynamic answer is ever wanted: `dlsym` `DFRGetStatus` out of
    /// `DFRFoundation`, the same shape the repo already uses for
    /// `TCCAccessPreflight`.
    ///
    /// NOT usable as a Touch Bar test, though it looks like one: ControlStrip's
    /// LaunchAgent carries no `LimitLoadToHardware` key, so the process exists on
    /// Macs that have no Touch Bar at all.
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
