// SPDX-License-Identifier: GPL-2.0-or-later
//
// W5.1 — the one open question in the proven pivot: a single plain NSButton
// renders in the Control Strip tray slot (33 taps live-verified on macOS 27),
// but no known implementation has ever put TWO controls in one tray item. This
// tests a −/+ pair inside one NSStackView, which is what the real feature needs.
//
// Same three requirements as the proven spike, all live-bitten:
//   real .app bundle · launched via `open` · appWithControlStrip mode.
// `open` detaches stdout, so everything goes to pair-taps.log beside the bundle.
//
// PASS = both − and + visible AND each logs its own distinct tap.
// PARTIAL = renders but only one half is hittable → fall back to two items.
// FAIL = nothing renders → single button + press-and-hold, or two items.

import AppKit

func logLine(_ s: String) {
    let url = URL(fileURLWithPath: Bundle.main.bundlePath)
        .deletingLastPathComponent().appendingPathComponent("pair-taps.log")
    let line = "\(Date()) \(s)\n"
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
    NSLog("[PairSpike] %@", s)
}

typealias SetPresenceFn = @convention(c) (NSString, Bool) -> Void

func loadSetPresence() -> SetPresenceFn? {
    guard let handle = dlopen(
        "/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_NOW),
        let sym = dlsym(handle, "DFRElementSetControlStripPresenceForIdentifier")
    else { return nil }
    return unsafeBitCast(sym, to: SetPresenceFn.self)
}

final class PairDelegate: NSObject, NSApplicationDelegate {

    private let identifier = NSTouchBarItem.Identifier("com.audiout.spike.volumepair")
    private var item: NSCustomTouchBarItem?
    private var downTaps = 0
    private var upTaps = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        logLine("launched — bundle: \(Bundle.main.bundleIdentifier ?? "<nil>")")

        guard let setPresence = loadSetPresence(),
              NSTouchBarItem.responds(to: NSSelectorFromString("addSystemTrayItem:"))
        else {
            logLine("FAIL: private tray API unavailable")
            NSApp.terminate(nil); return
        }

        // A two-segment control, NOT a stack of buttons: an NSStackView gets
        // CLIPPED to the tray slot's single-control width — live-observed, only
        // the first button rendered. A segmented control is one compact control
        // that sizes itself to fit, which is what the slot expects.
        //
        // (This is also what the very first spike used, but that run was a bare
        // binary — the real reason it drew nothing — so the control type was
        // never actually on trial until now.)
        let segmented = NSSegmentedControl(
            labels: ["－", "＋"], trackingMode: .momentary,
            target: self, action: #selector(segmentTapped(_:)))
        segmented.segmentDistribution = .fillEqually

        let item = NSCustomTouchBarItem(identifier: identifier)
        item.view = segmented
        self.item = item

        _ = (NSTouchBarItem.self as AnyObject).perform(
            NSSelectorFromString("addSystemTrayItem:"), with: item)
        setPresence(identifier.rawValue as NSString, false)
        setPresence(identifier.rawValue as NSString, true)
        logLine("registered — look for a － ＋ pair beside the collapsed Control Strip")
    }

    @objc private func segmentTapped(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 { downTaps += 1 } else { upTaps += 1 }
        logLine("TAP \(sender.selectedSegment == 0 ? "－" : "＋")  (down \(downTaps), up \(upTaps))")
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = PairDelegate()
app.delegate = delegate
app.run()
