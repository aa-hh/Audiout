// SPDX-License-Identifier: GPL-2.0-or-later
//
// license-gate-preview — opens the real one surface (Mixer, Scenes, Speakers,
// Settings) over a mock speaker fleet, with the first-open licence gate drawn
// over it, so the gate can be clicked through on screen. No real backend, no
// permissions, no network, no menu-bar item.
//
//   swift run --package-path AudioutCore license-gate-preview
//
// The surface is the shipping `AppSurfaceController` hosting the shipping
// `PopoverController` panel, and the gate is the shipping
// `LicenseGateViewController`. The only fakes are at the seams they already
// inject: `MockBackend`'s demo fleet, a transport that answers from the key
// you type instead of a server, an `openURL` that goes nowhere, and a scratch
// defaults suite so a preview run cannot touch the real app's stored key.

import AppKit
import AudioutCore
import AudioutOnboardingUI
import AudioutPopoverUI
import AudioutSettingsUI
import AudioutSharedUI

/// The key decides the verdict, so every outcome is one typed word away.
/// Anything else is a good key.
enum FakeVerdict {
    static func forKey(_ key: String) -> String? {
        // The gate normalises what is typed (uppercase, dashes gone, O and I
        // read as 0 and 1), so the word is looked for in that shape.
        let key = key.uppercased().replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "0", with: "O").replacingOccurrences(of: "1", with: "I")
        if key.contains("OFFLINE") { return nil }   // unreachable: saved, gate opens
        if key.contains("BAD") { return "invalid" }
        if key.contains("REVOKED") { return "revoked" }
        if key.contains("UNKNOWN") { return "unknown" }
        return "active"
    }
}

/// Answers the validator's POST from the key in its own body. Nothing leaves
/// the machine. The delay is the real thing's shape, so "Verifying…" is
/// readable before the verdict replaces it.
func previewTransport(_ request: URLRequest,
                      _ completion: @escaping (Data?, URLResponse?, Error?) -> Void) {
    let body = request.httpBody.flatMap {
        try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
    } ?? [:]
    let key = (body["license_key"] as? String) ?? ""
    let verdict = FakeVerdict.forKey(key)

    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
        guard let verdict else {
            // No usable answer — the gate saves the key and opens anyway.
            return completion(nil, nil, URLError(.notConnectedToInternet))
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)
        let payload = try? JSONSerialization.data(
            withJSONObject: ["status": verdict, "key": key])
        completion(payload, response, nil)
    }
}

/// A suite of its own, wiped on every launch: the preview must never read or
/// write the key the real app has stored.
let defaults: UserDefaults = {
    let suite = "com.audiout.license-gate-preview"
    UserDefaults.standard.removePersistentDomain(forName: suite)
    return UserDefaults(suiteName: suite) ?? .standard
}()

func tempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("license-gate-preview-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// A screen with nothing on it, for the Scenes and Speakers tabs.
@MainActor
func emptyScreen() -> NSViewController {
    let vc = NSViewController()
    vc.view = NSView(frame: NSRect(x: 0, y: 0, width: SurfaceLayout.width, height: 464))
    return vc
}

@MainActor
final class PreviewDelegate: NSObject, NSApplicationDelegate {

    private let settings = AppSettings(
        defaults: defaults,
        licenseServerURL: URL(string: "https://license.preview.invalid")!,
        buyURL: URL(string: "https://audiout.app/buy")!)
    private let backend = MockBackend(fleet: .demoFleet, staggerDiscovery: false,
                                      emitsLevels: true, simulatesDropouts: false)
    private var groups: GroupController?
    private var popover: PopoverController?
    private var surface: AppSurfaceController?
    private var gate: LicenseGateViewController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let groups = GroupController(backend: backend, store: GroupStore(directory: tempDir()),
                                     routingStore: RoutingStore(directory: tempDir()),
                                     loadPersisted: false)
        let popover = PopoverController(
            appRouting: AppRoutingController(store: AppRouteStore(directory: tempDir()),
                                             loadPersisted: false),
            runningAppsProvider: { [] })
        backend.start()
        let deadline = Date().addingTimeInterval(3)
        while backend.devices.count < 7 && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        popover.configure(groupController: groups)
        groups.ensureDefaultSelection()
        popover.update(devices: backend.devices)

        let surface = AppSurfaceController(
            popoverController: popover, settings: settings,
            groupsContent: { emptyScreen() },
            speakersContent: { emptyScreen() },
            // The one tab the gate leaves uncovered. A key accepted in its
            // Licence pane lifts the gate, as it does in the app.
            settingsContent: { [weak self, settings] in
                let license = LicenseSettingsViewController(settings: settings, openURL: { url in
                    print("  (Buy would open \(url.absoluteString))")
                })
                license.licenseTransport = previewTransport
                license.onLicenseChanged = {
                    if let gate = self?.gate, !gate.isChecking, settings.licenseStatus == .active {
                        gate.passWithStoredKey()
                    }
                }
                return SettingsRootViewController(sections: [
                    .init(title: "Licence", symbolName: "key", viewController: license),
                ])
            },
            frameAutosaveName: "LicenseGatePreviewSurface")
        // Pinned, so clicking the terminal does not tuck the surface away.
        surface.setPinned(true)
        surface.onClose = { NSApp.terminate(nil) }
        self.groups = groups
        self.popover = popover
        self.surface = surface
        presentGate()
        surface.show(anchorRect: nil)
    }

    /// A pass fades the gate out, then puts a fresh one back, so the fade can
    /// be watched more than once without relaunching. Quit (or closing the
    /// surface) ends the preview.
    private func presentGate() {
        settings.licenseKey = nil
        settings.licenseStatus = nil
        let gate = LicenseGateViewController(
            settings: settings,
            transport: previewTransport,
            openURL: { url in
                // Never opens a browser; the gate still moves to the key state.
                print("  (Buy would open \(url.absoluteString))")
            },
            onPassed: { [weak self] in
                print("  passed — the gate fades, and a fresh one returns in 2 s")
                self?.surface?.dismissLicenseGate(animated: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.presentGate() }
            })
        self.gate = gate
        surface?.presentLicenseGate(gate)
    }
}

print("""

  Audiout — licence gate preview

  The surface is the real one over a mock fleet, with the gate drawn over the
  Mixer. It opens on the offer: "Buy Audiout" prints the checkout link instead
  of opening a browser and moves to the key state; "I have a key" goes
  there without the checkout; the trial button starts the 14 days and opens
  the gate.

  In the key state, type or paste a key into the boxes (or use "Paste key");
  the status line counts down, the twentieth character verifies
  it, and the verdict comes from the key itself, not from a server. "Back"
  at the bottom returns to the offer, where the trial button is:

    AUDT-AAAAA-BBBBB-CCCCC-DDDDD   accepted — "Registered", then the gate fades
    AUDT-BADBA-DBADB-ADBAD-BADBA   "Key not accepted", the reason on the line below
    AUDT-REVOK-EDREV-OKEDR-EVOKE   rejected as refunded
    AUDT-UNKNO-WNUNK-NOWNU-NKNOW   not recognised
    AUDT-OFFLI-NEOFF-LINEO-FFLIN   server unreachable — "Key saved", gate opens

  Switch tabs: Scenes and Speakers stay covered, Settings is left uncovered.
  Its Licence pane takes the same keys, and an accepted one lifts the gate.
  Quit, or closing the surface, ends the preview.

""")
// The app never exits, so a buffered stdout (anything but a terminal) would
// hold the block above forever.
fflush(stdout)

// `main.swift`'s top level is nonisolated, and every line below is main-actor
// work — but it does run on the main thread, which is what `assumeIsolated`
// asserts. `run()` never returns.
let previewDelegate = MainActor.assumeIsolated { PreviewDelegate() }
MainActor.assumeIsolated {
    NSApplication.shared.delegate = previewDelegate
    NSApplication.shared.run()
}
