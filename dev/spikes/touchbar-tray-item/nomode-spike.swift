// SPDX-License-Identifier: GPL-2.0-or-later
//
// Does a full-width Touch Bar presentation need PresentationModeGlobal changed,
// or does presentSystemModalTouchBar stand on its own?
//
// This matters beyond tidiness. Writing that pref is what stranded Alec's Touch
// Bar on nothing-but-the-emoji-key when the app was force-quit: the setting
// outlives the process, so any exit we don't catch leaves the user somewhere
// they didn't choose. If the bar presents with the pref untouched, we stop
// writing it and that failure becomes impossible rather than merely
// recoverable.
//
// Deliberately touches NO preference domain. Nothing to restore afterwards —
// quitting it is the whole cleanup.
//
// Same proven requirements as the other spikes: real .app bundle, launched via
// `open`. Logs to nomode-taps.log beside the bundle since `open` detaches stdout.

import AppKit

func logLine(_ s: String) {
    let url = URL(fileURLWithPath: Bundle.main.bundlePath)
        .deletingLastPathComponent().appendingPathComponent("nomode-taps.log")
    let line = "\(Date()) \(s)\n"
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
    NSLog("[NoModeSpike] %@", s)
}

final class NoModeDelegate: NSObject, NSApplicationDelegate, NSTouchBarDelegate {

    private let minusID = NSTouchBarItem.Identifier("com.audiout.nomode.minus")
    private let plusID = NSTouchBarItem.Identifier("com.audiout.nomode.plus")
    private var taps = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Report the mode WITHOUT writing it, so the log proves which mode the
        // result was obtained under.
        let mode = CFPreferencesCopyAppValue(
            "PresentationModeGlobal" as CFString,
            "com.apple.touchbar.agent" as CFString) as? String
        logLine("presentation mode (unmodified): \(mode ?? "<unset>")")

        let present = NSSelectorFromString(
            "presentSystemModalTouchBar:placement:systemTrayItemIdentifier:")
        guard NSTouchBar.responds(to: present) else {
            logLine("FAIL: presentSystemModalTouchBar unavailable")
            NSApp.terminate(nil); return
        }

        let bar = NSTouchBar()
        bar.delegate = self
        bar.defaultItemIdentifiers = [minusID, plusID]

        typealias PresentFn = @convention(c)
            (AnyObject, Selector, NSTouchBar, Int64, NSString?) -> Void
        let imp = NSTouchBar.method(for: present)
        unsafeBitCast(imp, to: PresentFn.self)(NSTouchBar.self, present, bar, 1, nil)

        logLine("presented at placement 1 with NO pref written — look at the Touch Bar")
    }

    func touchBar(_ touchBar: NSTouchBar,
                  makeItemForIdentifier id: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        let item = NSCustomTouchBarItem(identifier: id)
        item.view = NSButton(
            title: id == minusID ? "－ NO-MODE" : "＋ NO-MODE",
            target: self, action: #selector(tapped(_:)))
        return item
    }

    @objc private func tapped(_ sender: NSButton) {
        taps += 1
        logLine("TAP \(taps): \(sender.title)")
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = NoModeDelegate()
app.delegate = delegate
app.run()
