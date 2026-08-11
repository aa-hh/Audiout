// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterCore

/// The first-run onboarding/permission-priming window (public-release readiness).
///
/// Same lazy-create-then-reuse lifecycle as
/// `MixerWindowController`: the app builds it on demand, calls the no-arg
/// ``present()``, and reuses/focuses it thereafter. It hosts a single
/// ``OnboardingViewController`` bound to a Core ``SetupModel``, and wires the real
/// ``SystemSettingsOpener`` for the denial deep links.
///
/// **Dismissal contract (why Done and ✕ differ):** `onFinished` fires exactly
/// once, whether the user clicks **Done** or closes the window — the app uses it
/// to (finally) start the backend, whose Bonjour discovery is deferred on first
/// run so the Local Network prompt is *primed* here rather than sprung at launch.
/// Persisting "setup complete" is separate: only **Done** calls
/// ``SetupModel/complete()``, so closing with the ✕ leaves the flow to reappear
/// next launch (the user didn't finish). Re-running setup later ("Open
/// Setup…" in Settings ▸ General) just constructs and presents this again —
/// it never clears the completed flag.
@MainActor
public final class OnboardingWindowController: NSWindowController, NSWindowDelegate {

    private let model: SetupModel
    private let onFinished: () -> Void
    private let contentVC: OnboardingViewController
    private var didFinish = false

    /// - Parameters:
    ///   - model: the Core flow model, pre-wired with the production probes.
    ///   - reason: why this presentation is happening — `.firstRun` (default,
    ///     every existing call site) renders exactly as before; `.permissionLost`
    ///     shows the "turned off" banner (see ``OnboardingReason``).
    ///   - openSettings: how to open a System Settings pane; defaults to the real
    ///     `NSWorkspace`-backed opener, injected as a spy in tests.
    ///   - onFinished: called once when the window is dismissed (Done or close) —
    ///     the app starts the (deferred) backend here.
    public init(model: SetupModel,
                reason: OnboardingReason = .firstRun,
                openSettings: @escaping (SystemSettingsPane) -> Void = SystemSettingsOpener.open,
                onFinished: @escaping () -> Void) {
        self.model = model
        self.onFinished = onFinished

        // The VC's Done closure must route back into `finish(markComplete:)`, but
        // `self` isn't available until after `super.init`. A one-line trampoline
        // bridges that ordering without an associated-object hack: the VC calls
        // `trampoline.fire()`; we point it at `self` below.
        let trampoline = Trampoline()
        contentVC = OnboardingViewController(
            model: model,
            reason: reason,
            onOpenSettings: openSettings,
            onDone: { trampoline.fire() })
        let levelTrampoline = Trampoline()
        contentVC.onWillOpenSystemSettings = { levelTrampoline.fire() }

        let window = NSWindow(contentViewController: contentVC)
        window.styleMask = [.titled, .closable]
        window.title = "Setup"
        window.isRestorable = false   // fixed-size, centered; never restored
        // Appear on whatever Space the user is on (incl. over a fullscreen app)
        // when summoned/re-fronted, rather than Space-switching (window-panel.md M1).
        window.collectionBehavior.formUnion([.moveToActiveSpace, .fullScreenAuxiliary])
        // Deliberately `.floating` for the window's whole open lifetime:
        // granting a permission must never leave this window buried, and the
        // normal-level alternative depends on `NSApp.activate`, which macOS 14's
        // cooperative activation may decline while another app is frontmost.
        // The cost that killed an earlier floating version ("the setup keeps
        // popping up") is bounded two ways: the window exists only for a
        // deliberately-summoned flow that dies at Done/✕, and the reactivate
        // hook below never steals keyboard focus from sibling windows. Decision
        // history in this folder's AGENTS.md — read it before changing the level.
        window.level = .floating

        super.init(window: window)
        trampoline.action = { [weak self] in self?.finish(markComplete: true) }
        levelTrampoline.action = { [weak self] in self?.yieldToSystemSettings() }
        window.delegate = self
        // When the app becomes active again — e.g. the user finished a system
        // permission dialog, or clicked back to us — bring the setup window
        // forward and re-read live permission status. This is what recovers the
        // window after a prompt without pinning it above every other app.
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    /// Seam for `NSApp.keyWindow` so the take-key-only-when-unclaimed rule in
    /// `appDidBecomeActive` is testable headless (no real key windows there).
    var keyWindowProvider: () -> NSWindow? = { NSApp?.keyWindow }

    /// Step out of the way of System Settings (amendment to the floating
    /// decision, owner call 2026-08-11).
    ///
    /// `.floating` is what keeps a grant from leaving this window buried — but
    /// it ALSO parks us on top of System Settings, which is the one app we
    /// deliberately send the user to. Native permission ALERTS already draw
    /// above a floating window, so this is only about Settings. Dropping to
    /// `.normal` for the trip and restoring on the way back keeps both
    /// behaviours: `appDidBecomeActive` is the restore, and it fires whether the
    /// user comes back by granting (we activate ourselves) or by hand.
    private func yieldToSystemSettings() {
        window?.level = .normal
    }

    @objc private func appDidBecomeActive() {
        guard !didFinish else { return }
        // Back in our app: take the floating level again (see
        // `yieldToSystemSettings()`).
        window?.level = .floating
        // The floating level already keeps the window visible, so this hook only
        // governs keyboard focus — and it must not grab it away from a sibling
        // window the user actually clicked (Settings and Setup open together is a
        // normal state: Setup is reached FROM Settings). Take key only when
        // nothing else in the app holds it, e.g. returning from a permission
        // prompt or System Settings.
        let key = keyWindowProvider()
        if key == nil || key === window {
            window?.makeKeyAndOrderFront(nil)
        }
        // Returning to the app (e.g. back from System Settings) is exactly when a
        // permission the user just changed should be re-read — so the rows reflect
        // reality instead of a stale "Requested".
        contentVC.refreshStatuses()
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var hasBeenPresented = false

    /// Open/focus the window. The app is an accessory (no Dock icon), so
    /// activate explicitly to bring it forward. Sizing + centering happen on the
    /// first presentation only — a re-present (the `presentSetup` re-entry
    /// guard's re-front, "Open Setup…" while already open) must not throw
    /// away a position the user chose (punch-list W6).
    ///
    /// The content's `fittingSize` is the two-pane screen's FIXED size
    /// (`OnboardingViewController.contentWidth` × `contentHeight`), not a
    /// measurement that moves per step — the window must not resize under the
    /// user as cards expand and collapse.
    public func present() {
        NSApp?.activate(ignoringOtherApps: true)
        if !hasBeenPresented {
            hasBeenPresented = true
            contentVC.view.layoutSubtreeIfNeeded()
            window?.setContentSize(contentVC.view.fittingSize)
            window?.center()
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Dismissal

    /// Finish the flow once: optionally persist completion (Done), fire the
    /// single-shot `onFinished`, then close the window. Both Done and ✕ funnel
    /// through ``dismiss()`` so `onFinished` runs exactly once either way.
    func finish(markComplete: Bool) {
        if markComplete { model.complete() }
        dismiss()
        window?.close()
    }

    /// The single-fire finish: guard, unbind, notify. Called by both `finish`
    /// (Done) and `windowWillClose` (✕); the guard makes the second a no-op.
    private func dismiss() {
        guard !didFinish else { return }
        didFinish = true
        NotificationCenter.default.removeObserver(
            self, name: NSApplication.didBecomeActiveNotification, object: nil)
        model.onChange = nil   // stop repainting a torn-down view
        onFinished()
    }

    public func windowWillClose(_ notification: Notification) {
        dismiss()
    }

    // MARK: Test-support hooks

    /// The content view controller (for structure assertions).
    public var test_contentViewController: OnboardingViewController { contentVC }

    /// Simulate Done (persist completion + finish) without a live window.
    public func test_finishWithDone() { finish(markComplete: true) }

    /// Simulate a ✕ close (finish WITHOUT persisting completion).
    public func test_closeWithoutDone() {
        windowWillClose(Notification(name: NSWindow.willCloseNotification))
    }

    /// Whether the single-fire finish has run.
    public var test_didFinish: Bool { didFinish }

    /// The window's current level — the yield-to-Settings contract, which has no
    /// other observable effect headless.
    public var test_windowLevel: NSWindow.Level? { window?.level }

    /// Fire the yield directly (the content VC's `onWillOpenSystemSettings`
    /// seam, without a live Settings launch).
    public func test_yieldToSystemSettings() { yieldToSystemSettings() }

    /// Fire the app-reactivate hook directly — headless tests can't activate
    /// the app, and the key-steal guard is exactly what needs pinning.
    func test_appDidBecomeActive() { appDidBecomeActive() }
}

/// Bridges the VC's Done tap back to the window controller across the
/// `super.init` ordering gap (see ``OnboardingWindowController/init``).
@MainActor
private final class Trampoline {
    var action: (() -> Void)?
    func fire() { action?() }
}
