// SPDX-License-Identifier: GPL-2.0-or-later
//
// Spike for roadmap 034, pivot after the tap probe: Apple's Control Strip
// volume buttons post NO event when the default output has no settable volume
// (live-proven 2026-08-08 — nothing on a session OR HID tap), so interception
// can never reach them. This tests the replacement: the app adds ITS OWN
// volume buttons to the Control Strip via DFRFoundation's system-tray API —
// the same private API BetterTouchTool / Pock / MTMR ship on.
//
// Success = a −/+ control appears in the Touch Bar's Control Strip while this
// runs, taps print instantly, and it works with the aggregate as the default
// output. No admin, no Accessibility, no entitlement.

import AppKit

setbuf(stdout, nil)

// MARK: - Private DFRFoundation API, resolved at runtime
// (No link-time -framework: private frameworks live in the shared cache with no
// binary on disk, so dlopen/dlsym is the only way in.)

typealias SetPresenceFn = @convention(c) (NSString, Bool) -> Void

func loadSetPresence() -> SetPresenceFn? {
    guard let handle = dlopen(
        "/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_NOW),
        let sym = dlsym(handle, "DFRElementSetControlStripPresenceForIdentifier")
    else { return nil }
    return unsafeBitCast(sym, to: SetPresenceFn.self)
}

// MARK: - App

final class SpikeDelegate: NSObject, NSApplicationDelegate {

    private let identifier = NSTouchBarItem.Identifier("com.audiout.spike.volumetray")
    private var item: NSCustomTouchBarItem?
    private var taps = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let setPresence = loadSetPresence() else {
            print("FAIL: DFRElementSetControlStripPresenceForIdentifier not found — pivot dead on this macOS")
            NSApp.terminate(nil)
            return
        }

        let item = NSCustomTouchBarItem(identifier: identifier)
        let control = NSSegmentedControl(
            labels: ["−", "+"], trackingMode: .momentaryAccelerator,
            target: self, action: #selector(tapped(_:)))
        item.view = control
        self.item = item

        // Private class method: registers the item system-wide (visible whatever
        // app is frontmost), which is exactly what the Control Strip is.
        guard NSTouchBarItem.responds(to: NSSelectorFromString("addSystemTrayItem:")) else {
            print("FAIL: NSTouchBarItem.addSystemTrayItem: missing — pivot dead on this macOS")
            NSApp.terminate(nil)
            return
        }
        _ = (NSTouchBarItem.self as AnyObject).perform(
            NSSelectorFromString("addSystemTrayItem:"), with: item)
        setPresence(identifier.rawValue as NSString, true)

        print("""
        Item registered. LOOK AT YOUR TOUCH BAR — a −/+ control should now sit in
        the Control Strip (right side). Tap both halves a few times, including
        while the aggregate is your output. Each tap should print here instantly.
        Ctrl-C to quit (the control disappears with the process).
        """)
    }

    @objc private func tapped(_ sender: NSSegmentedControl) {
        taps += 1
        print("TAP \(taps): \(sender.selectedSegment == 0 ? "−" : "+")  ← our button fired")
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = SpikeDelegate()
app.delegate = delegate
app.run()
