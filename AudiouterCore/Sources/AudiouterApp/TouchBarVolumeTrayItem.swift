// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterCore

/// Puts the app's OWN −/+ volume control into the Touch Bar's Control Strip
/// while we own the volume, because Apple's is dead there.
///
/// WHY OURS AND NOT THEIRS: when the default output publishes no settable volume
/// — our aggregate — macOS greys its Control Strip volume buttons, and a greyed
/// button posts NO event. Live-probed at both the session and HID event-tap
/// layers: nothing arrives. So there is nothing to intercept and no way to
/// un-grey them. Drawing our own control is the only route to working volume on
/// a Touch Bar. (Physical volume keys are a different story and DO emit events —
/// `VolumeKeyInterceptor` handles those.)
///
/// WHY PRIVATE API: the public `NSTouchBar` route only shows items while this
/// app is frontmost, and a menu-bar app never is — the user needs volume while
/// they are in Spotify. `addSystemTrayItem:` plus DFRFoundation's presence flag
/// is the only way to pin an item into the Control Strip system-wide. It is what
/// BetterTouchTool, Pock and MTMR ship; it forecloses the Mac App Store, which
/// the aggregate design already did.
///
/// LIVE-VERIFIED on macOS 27 (spike `dev/spikes/touchbar-tray-item/`), and three
/// requirements were each bought with a failed run — none is theoretical:
/// - the app must be a real `.app` bundle (a bare binary registers nothing);
/// - it must be launched via `open` (direct exec RENDERS the control but
///   delivers no taps — it looks like it works);
/// - the Touch Bar must be in "App Controls with Control Strip" mode, which
///   ``ControlStripVolumeButtons`` arranges.
@MainActor
final class TouchBarVolumeTrayItem {

    private let identifier = NSTouchBarItem.Identifier("com.audiouter.volume")
    /// Strong reference — the tray registration does not retain for us.
    private var item: NSCustomTouchBarItem?

    /// Called with the direction the user tapped. Set by `AppDelegate`; this type
    /// knows nothing about `GroupController`.
    var onStep: ((_ up: Bool) -> Void)?

    /// Follow volume ownership. Registered only while we own the volume, so we
    /// never sit in the user's Control Strip doing nothing.
    func setOwnsVolume(_ owns: Bool) {
        owns ? register() : unregister()
    }

    private func register() {
        guard item == nil, let setPresence = Self.setControlStripPresence else { return }

        // A two-segment control, NOT two buttons in a stack: the tray slot is
        // sized for a single control and CLIPS a stack — live-observed, only the
        // first button rendered. A segmented control sizes itself to fit and both
        // halves survive.
        let segmented = NSSegmentedControl(
            labels: ["−", "+"], trackingMode: .momentary,
            target: self, action: #selector(segmentTapped(_:)))
        segmented.segmentDistribution = .fillEqually
        segmented.setAccessibilityLabel("Audiouter volume")

        let item = NSCustomTouchBarItem(identifier: identifier)
        item.view = segmented
        self.item = item

        Self.addSystemTrayItem(item)
        // false→true: a stale presence entry for this identifier otherwise wins
        // over the fresh registration and nothing renders.
        setPresence(identifier.rawValue as NSString, false)
        setPresence(identifier.rawValue as NSString, true)
    }

    private func unregister() {
        guard let item else { return }
        Self.setControlStripPresence?(identifier.rawValue as NSString, false)
        Self.removeSystemTrayItem(item)
        self.item = nil
    }

    @objc private func segmentTapped(_ sender: NSSegmentedControl) {
        onStep?(sender.selectedSegment == 1)
    }

    // MARK: - Private API access

    /// `DFRElementSetControlStripPresenceForIdentifier`, resolved at runtime.
    /// `dlsym` rather than a link-time framework because private frameworks live
    /// in the shared cache with no binary on disk to link against. `nil` on a
    /// macOS that no longer exports it — every caller degrades to "no Touch Bar
    /// control", never a crash.
    private static let setControlStripPresence: (@convention(c) (NSString, Bool) -> Void)? = {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_NOW),
            let sym = dlsym(handle, "DFRElementSetControlStripPresenceForIdentifier")
        else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) (NSString, Bool) -> Void).self)
    }()

    private static func addSystemTrayItem(_ item: NSTouchBarItem) {
        let selector = NSSelectorFromString("addSystemTrayItem:")
        guard NSTouchBarItem.responds(to: selector) else { return }
        _ = (NSTouchBarItem.self as AnyObject).perform(selector, with: item)
    }

    private static func removeSystemTrayItem(_ item: NSTouchBarItem) {
        let selector = NSSelectorFromString("removeSystemTrayItem:")
        guard NSTouchBarItem.responds(to: selector) else { return }
        _ = (NSTouchBarItem.self as AnyObject).perform(selector, with: item)
    }
}
