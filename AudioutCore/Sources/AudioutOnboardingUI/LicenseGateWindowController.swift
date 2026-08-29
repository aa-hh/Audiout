// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore

/// The first-open licence gate window (owner decision 2026-08-30): on a
/// purchased build (`AudioutLicenseServerURL` present — see `LicenseGate`),
/// the app's first act is this window, and nothing else starts until it
/// opens. It is the welcome: brand mark and key field over the live emitter
/// field, ahead of Setup, the backend, and the menu-bar surface's first use.
///
/// **Dismissal contract:** `onPassed` fires exactly once when a key is
/// accepted (verified active, or saved-unverified while the server is
/// unreachable) — the app continues its launch from there. Closing the window
/// any other way (✕, or the Quit button's terminate) means declining to run
/// the paid build: `onAbort` fires instead, and the app quits. The abort is a
/// closure so the policy lives in `AppDelegate` and tests never terminate.
///
/// Chrome: `.fullSizeContentView` with a hidden title so the field fills the
/// window edge to edge — the ✕ stays, floating over the field, as the honest
/// way out. Same level/Space posture as the Setup window it hands off to.
@MainActor
public final class LicenseGateWindowController: NSWindowController, NSWindowDelegate {

    private let contentVC: LicenseGateViewController
    private let onPassed: () -> Void
    private let onAbort: () -> Void
    private var didFinish = false

    public init(settings: AppSettings,
                transport: LicenseValidator.Transport? = nil,
                openURL: @escaping (URL) -> Void,
                onPassed: @escaping () -> Void,
                onAbort: @escaping () -> Void) {
        self.onPassed = onPassed
        self.onAbort = onAbort

        let trampoline = Trampoline()
        contentVC = LicenseGateViewController(
            settings: settings,
            transport: transport,
            openURL: openURL,
            onPassed: { trampoline.fire() })

        let window = NSWindow(contentViewController: contentVC)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.title = "Audiout"          // spoken identity; never drawn
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isRestorable = false       // fixed-size, centered; never restored
        window.collectionBehavior.formUnion([.moveToActiveSpace, .fullScreenAuxiliary])
        // Same reasoning as the Setup window's level: this is the only thing
        // the app has on screen, summoned deliberately, dead the moment it is
        // answered — it must not open buried.
        window.level = .floating

        super.init(window: window)
        trampoline.action = { [weak self] in self?.finish(passed: true) }
        window.delegate = self
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var hasBeenPresented = false

    /// Open/focus the window. Sizing + centering on first presentation only;
    /// the on-screen half is gated on `HeadlessRuntime` (a floating window
    /// parked over a developer's screen is exactly its job to prevent).
    public func present() {
        if !hasBeenPresented {
            hasBeenPresented = true
            contentVC.view.layoutSubtreeIfNeeded()
            window?.setContentSize(LicenseGateViewController.contentSize)
            window?.center()
            Analytics.capture("license:gate_shown")
        }
        guard !HeadlessRuntime.isActive else { return }
        NSApp?.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// The deep-link landing while the gate is up: `audiout://register?key=…`
    /// submits straight into the gate's own field.
    public func submit(key: String) { contentVC.submit(key: key) }

    private func finish(passed: Bool) {
        guard !didFinish else { return }
        didFinish = true
        window?.close()
        // `window?.close()` re-enters through `windowWillClose`, which is a
        // no-op once `didFinish` is set — the outcome closures fire here, once.
        if passed { onPassed() } else { onAbort() }
    }

    public func windowWillClose(_ notification: Notification) {
        guard !didFinish else { return }
        didFinish = true
        onAbort()
    }

    // MARK: Test-support hooks

    /// The content view controller (for structure assertions).
    public var test_contentViewController: LicenseGateViewController { contentVC }

    /// Simulate the ✕ close.
    public func test_closeWindow() {
        windowWillClose(Notification(name: NSWindow.willCloseNotification))
    }

    /// Whether the single-fire finish has run.
    public var test_didFinish: Bool { didFinish }
}

/// Bridges the VC's pass back to the window controller across the
/// `super.init` ordering gap (same shape as `OnboardingWindowController`).
@MainActor
private final class Trampoline {
    var action: (() -> Void)?
    func fire() { action?() }
}
