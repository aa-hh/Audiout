// SPDX-License-Identifier: GPL-2.0-or-later
//
// license-gate-preview — opens the real first-open licence gate window, and
// nothing else. No backend, no permissions, no network, no menu-bar item.
//
// It exists because the gate's ground is a live Metal shader
// (`EmitterFieldView`) and Metal is deliberately switched OFF under
// `HeadlessRuntime`, so the snapshot tools every other surface is reviewed
// with render this window as a flat colour. The only way to see the field is
// to run it. This is that.
//
//   swift run --package-path AudioutCore license-gate-preview
//
// The window is the shipping `LicenseGateWindowController` with the shipping
// view controller inside it — the only fakes are at the seams the gate
// already injects: a transport that answers from the key you type instead of
// a server, an `openURL` that goes nowhere, and a scratch defaults suite so a
// preview run cannot touch the real app's stored key.

import AppKit
import AudioutCore
import AudioutOnboardingUI

/// The key decides the verdict, so every scene the field can play is one
/// typed word away. Anything else is a good key.
enum FakeVerdict {
    static func forKey(_ key: String) -> String? {
        let key = key.uppercased()
        if key.contains("OFFLINE") { return nil }   // unreachable: saved, gate opens
        if key.contains("BAD") { return "invalid" }
        if key.contains("REVOKED") { return "revoked" }
        if key.contains("UNKNOWN") { return "unknown" }
        return "active"
    }
}

/// Answers the validator's POST from the key in its own body. Nothing leaves
/// the machine. The delay is the real thing's shape, not padding: the
/// `checking` scene is a rotating lead among the three emitters, and at zero
/// latency you would never see it.
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

@MainActor
final class PreviewDelegate: NSObject, NSApplicationDelegate {

    private var gate: LicenseGateWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        showGate()
    }

    /// A pass reopens the gate rather than quitting, so the farewell can be
    /// watched more than once without relaunching. ✕ and Quit still end it —
    /// those are the shipping window's own way out.
    private func showGate() {
        let settings = AppSettings(
            defaults: defaults,
            licenseServerURL: URL(string: "https://license.preview.invalid")!,
            buyURL: URL(string: "https://audiout.app/buy")!)
        settings.licenseKey = nil
        settings.licenseStatus = nil

        let gate = LicenseGateWindowController(
            settings: settings,
            transport: previewTransport,
            openURL: { url in
                // Never actually opens a browser: the point of pressing Buy
                // here is the `waiting` scene it puts the field into.
                print("  (Buy would open \(url.absoluteString) — the field is now `waiting`)")
            },
            onPassed: { [weak self] in
                print("  passed — reopening the gate")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self?.showGate() }
            },
            onAbort: { NSApp.terminate(nil) })
        self.gate = gate
        gate.present()
    }
}

print("""

  Audiout — licence gate preview

  The window is the real one. Type into the key field and press Register;
  the verdict comes from the key itself, not from a server:

    AUDT-AAAAA-BBBBB-CCCCC-DDDDD   accepted — the field surges, then leaves
    AUDT-BAD                       rejected — the field dims and freezes
    AUDT-REVOKED                   rejected, and Buy comes up to full strength
    AUDT-OFFLINE                   server unreachable — key saved, gate opens

  What the ground is doing, scene by scene: empty field is `idle` (breathing);
  a part-typed key steadies it; a full-length key lifts all three sources;
  Register hands the lead around them; Buy dims and slows it. Leave it
  untouched for 20 s to watch the Quit/Buy row lift once.

  ✕ or Quit ends the preview.

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
