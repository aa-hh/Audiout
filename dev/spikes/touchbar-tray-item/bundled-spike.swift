// SPDX-License-Identifier: GPL-2.0-or-later
//
// Control Strip tray-item spike, rev 2 — now following the researched recipe
// exactly (touchtest / rubrail / MTMR, the only implementations proven to
// render): real .app bundle, launched via `open` (direct exec of the binary is
// documented to silently not register with the Touch Bar service), a plain
// NSButton (no sample ever rendered a segmented control in the tray slot),
// registration inside applicationDidFinishLaunching, strong item reference.
//
// Renders ONLY in "App Controls with Control Strip" mode (asmagill /
// Hammerspoon #1096) — invisible in expanded-Control-Strip mode. Set the mode
// before judging the result.
//
// `open` detaches stdout, so everything logs to taps.log next to the bundle.

import AppKit

func logLine(_ s: String) {
    let url = URL(fileURLWithPath: Bundle.main.bundlePath)
        .deletingLastPathComponent().appendingPathComponent("taps.log")
    let line = "\(Date()) \(s)\n"
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
    NSLog("[TrayItemSpike] %@", s)
}

typealias SetPresenceFn = @convention(c) (NSString, Bool) -> Void

func loadSetPresence() -> SetPresenceFn? {
    guard let handle = dlopen(
        "/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_NOW),
        let sym = dlsym(handle, "DFRElementSetControlStripPresenceForIdentifier")
    else { return nil }
    return unsafeBitCast(sym, to: SetPresenceFn.self)
}

final class SpikeDelegate: NSObject, NSApplicationDelegate {

    private let identifier = NSTouchBarItem.Identifier("com.audiout.spike.volumetray")
    /// Strong reference — the tray registration does not retain for us.
    private var item: NSCustomTouchBarItem?
    private var taps = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        logLine("launched — bundle: \(Bundle.main.bundleIdentifier ?? "<nil>")")

        guard let setPresence = loadSetPresence() else {
            logLine("FAIL: DFRElementSetControlStripPresenceForIdentifier not found")
            NSApp.terminate(nil); return
        }
        guard NSTouchBarItem.responds(to: NSSelectorFromString("addSystemTrayItem:")) else {
            logLine("FAIL: NSTouchBarItem.addSystemTrayItem: missing")
            NSApp.terminate(nil); return
        }

        let item = NSCustomTouchBarItem(identifier: identifier)
        let button = NSButton(title: "♪+", target: self, action: #selector(tapped))
        item.view = button
        self.item = item

        _ = (NSTouchBarItem.self as AnyObject).perform(
            NSSelectorFromString("addSystemTrayItem:"), with: item)
        setPresence(identifier.rawValue as NSString, false)
        setPresence(identifier.rawValue as NSString, true)
        logLine("registered — look for a ♪+ button by the collapsed Control Strip")
    }

    @objc private func tapped() {
        taps += 1
        logLine("TAP \(taps) — our button fired")
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = SpikeDelegate()
app.delegate = delegate
app.run()
