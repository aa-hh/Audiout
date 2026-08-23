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

        let window = OnboardingWindow(contentViewController: contentVC)
        window.styleMask = [.titled, .closable]
        window.title = "Setup"
        window.isRestorable = false   // fixed-size, centered; never restored
        // Appear on whatever Space the user is on (incl. over a fullscreen app)
        // when summoned/re-fronted, rather than Space-switching (window-panel.md M1).
        window.collectionBehavior.formUnion([.moveToActiveSpace, .fullScreenAuxiliary])
        // Deliberately `.floating` — the resting level for the window's whole
        // open lifetime, dropped only for a surface that draws at NORMAL level
        // (a System Settings trip, and Remote Control's Accessibility alert —
        // both via `yieldToSystemSettings()`). The TCC dialogs draw above a
        // floating window, so an unanswered ask leaves the level alone:
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
        contentVC.onPromptInFlightChanged = { [weak self] in self?.setPromptInFlight($0) }
        window.delegate = self
        // When the app becomes active again — e.g. the user finished a system
        // permission dialog, or clicked back to us — bring the setup window
        // forward and re-read live permission status. This is what recovers the
        // window after a prompt without pinning it above every other app.
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification, object: nil)
        // The other half of the yield: losing the front is how we know the trip
        // to System Settings really started (see `isYieldingToSettings`).
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidResignActive),
            name: NSApplication.didResignActiveNotification, object: nil)
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
        stepAside()
        // Armed until we have ACTUALLY lost the front — see
        // `appDidBecomeActive`, which must not undo the line above.
        isYieldingToSettings = true
    }

    /// The yield itself, shared with the in-flight prompt below: drop out of
    /// the way of whatever is about to be drawn where we are.
    private func stepAside() { window?.level = .normal }

    /// Set while a system permission dialog this flow raised is unanswered.
    ///
    /// Another process fighting a TCC dialog for input focus is what leaves it
    /// frozen and unclickable, so for the length of the ask this window gives
    /// up both ways it grabs focus: the reactivate re-front
    /// (``appDidBecomeActive``) and the force-activate on mouse-down
    /// (``OnboardingWindow/suppressesActivation``).
    ///
    /// The LEVEL deliberately stays `.floating` (owner decision 2026-08-22 —
    /// this narrows the original go-quiet amendment, which also demoted to
    /// `.normal` here). Every dialog this state covers is a TCC dialog a
    /// system process draws ABOVE a floating window, so the demote bought
    /// nothing — and it is what made the setup vanish behind other apps for
    /// the length of the ask and pop back on the answer (the "blip"). Focus,
    /// not z-order, is what freezes a dialog; z-order never moves now. The two
    /// normal-level surfaces (System Settings, the Accessibility alert) still
    /// yield, via ``yieldToSystemSettings()``.
    private var isPromptInFlight = false

    private func setPromptInFlight(_ inFlight: Bool) {
        isPromptInFlight = inFlight
        (window as? OnboardingWindow)?.suppressesActivation = inFlight
        if !inFlight, !isYieldingToSettings {
            // Resolved, and not on the way to Settings — a trip there owns the
            // level until it comes back (see `isYieldingToSettings`); anything
            // else (e.g. a completed Settings trip that never re-activated us)
            // is restored to the resting level here.
            window?.level = .floating
        }
    }

    /// Set while a Settings trip has been started but the front has not yet
    /// moved away from us.
    ///
    /// **The bug this closes (live, macOS 26): Settings opened BEHIND the setup
    /// window even though the level drop above ran.** Clicking Allow can be the
    /// same click that activates our app, and `didBecomeActiveNotification` is
    /// delivered on the main run loop — while the Allow itself resolves through
    /// an `await` before it reaches the deep link. So the order on real hardware
    /// is: click → yield to `.normal` → `NSWorkspace.open` → *then* our own,
    /// already-queued activation arrives and restores `.floating` (and re-orders
    /// the window in) a beat before System Settings has finished coming
    /// forward. Net effect: exactly the reported symptom, with the unit test
    /// still green because it never had a stray activation in between.
    ///
    /// Losing the front is the only honest signal that the trip began, so that
    /// is what disarms this — an activation that arrives without an intervening
    /// deactivation is our own, not the user coming back.
    private var isYieldingToSettings = false

    @objc private func appDidResignActive() {
        // System Settings (or anything else) took the front: the yield did its
        // job, and the NEXT activation is a real return.
        isYieldingToSettings = false
        contentVC.appDidResignActive()
    }

    @objc private func appDidBecomeActive() {
        guard !didFinish else { return }
        // Not a return — our own activation catching up with the deep link we
        // just fired. Re-floating (or re-ordering) here is what buried System
        // Settings; the status re-read below is still worth doing.
        // A prompt still on screen owns the front: re-floating or taking key
        // here is exactly what freezes it (see `isPromptInFlight`).
        if !isYieldingToSettings, !isPromptInFlight {
            // Back in our app: take the floating level again (see
            // `yieldToSystemSettings()`).
            window?.level = .floating
            // The floating level already keeps the window visible, so this hook
            // only governs keyboard focus — and it must not grab it away from a
            // sibling window the user actually clicked (Settings and Setup open
            // together is a normal state: Setup is reached FROM Settings). Take
            // key only when nothing else in the app holds it, e.g. returning
            // from a permission prompt or System Settings.
            let key = keyWindowProvider()
            if key == nil || key === window {
                // Counted BEFORE the headless bail-out: ordering a window in is
                // invisible to a headless test, but WHETHER to take key is the
                // rule worth pinning (same shape as
                // `OnboardingViewController.returnToFront`).
                test_frontCount += 1
                if !HeadlessRuntime.isActive { window?.makeKeyAndOrderFront(nil) }
            }
        }
        // Returning to the app (e.g. back from System Settings) is exactly when a
        // permission the user just changed should be re-read — so the rows reflect
        // reality instead of a stale "Requested".
        contentVC.appDidBecomeActive()
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
    ///
    /// Sizing and centering run everywhere; only the on-screen half is gated on
    /// ``HeadlessRuntime``. A test process holds a real WindowServer connection,
    /// so an un-gated activate/order-front here parks a FLOATING, un-clickable
    /// Setup window above everything on the developer's actual screen until the
    /// whole run ends — the exact noise `HeadlessRuntime` exists to prevent, and
    /// which every other window controller in this app already gates (see
    /// `ControlPanelWindowController`, `AboutView`).
    public func present() {
        if !hasBeenPresented {
            hasBeenPresented = true
            contentVC.view.layoutSubtreeIfNeeded()
            window?.setContentSize(contentVC.view.fittingSize)
            window?.center()
        }
        guard !HeadlessRuntime.isActive else { return }
        NSApp?.activate(ignoringOtherApps: true)
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
        NotificationCenter.default.removeObserver(
            self, name: NSApplication.didResignActiveNotification, object: nil)
        model.onChange = nil   // stop repainting a torn-down view
        // A first-ask Local Network prime can outlive the window by up to its
        // 60 s ceiling (listener + browsers live, every other Allow blocked
        // behind the in-flight step) — closing the flow cancels it.
        model.cancelLocalNetworkPrime()
        onFinished()
    }

    /// Refuse the ✕ while a permission dialog is unanswered.
    ///
    /// Closing (and so deallocating) this window is a fourth way it can fight
    /// the dialog for focus — AppKit reassigns key/main status and reorders
    /// remaining windows on teardown, the same disturbance `isPromptInFlight`
    /// already gives up floating level, reactivate re-front and force-activate
    /// for. The stuck-prompt hint the content VC already shows after the 20 s
    /// timeout is the honest explanation for why the ✕ isn't doing anything.
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        !isPromptInFlight
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

    /// Fire the app-deactivate hook directly — "System Settings took the front"
    /// is the step that turns the NEXT activation into a real return.
    func test_appDidResignActive() { appDidResignActive() }

    /// How many times the reactivate hook decided to front the window. The
    /// decision, not the pixels: headless runs never really order a window in.
    private(set) var test_frontCount = 0
}

/// The Setup window itself: logs every physical click it receives, and forces
/// the app active before dispatching a click that arrives while it isn't.
///
/// Both halves exist because of one live symptom ("Start listening took two
/// clicks" — the first CTA click left NO `setup_done` trace at all, not even
/// the single-flight swallow, so it either never reached this window or died
/// between delivery and the button's action). The candidate mechanisms all
/// produce the same EMPTY telemetry, so `sendEvent` is made the witness: from
/// now on a dead click either leaves a `setup_click` line naming the exact
/// view it hit (delivery happened — the fault is below, and the line says
/// where), or leaves nothing (the click was consumed upstream of the app,
/// where no in-process code can help). The activation force closes the half
/// we can reach: a click that physically lands on this window is the user's
/// intent to use it, so an inactive app is activated BEFORE the event is
/// dispatched — the ordinary click path instead of the fragile first-mouse
/// one. The `acceptsFirstMouse` overrides on the CTA/cards stay regardless:
/// they are what lets this same click also PRESS the control.
final class OnboardingWindow: NSWindow {

    /// Set while a system permission dialog is unanswered. The click is still
    /// DELIVERED — only the force-activate is skipped, because activating this
    /// app is what takes input focus off the dialog the user is trying to
    /// answer (see `OnboardingWindowController.isPromptInFlight`).
    var suppressesActivation = false

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .leftMouseUp {
            let wasActive = NSApp?.isActive == true
            if event.type == .leftMouseDown, !wasActive, !HeadlessRuntime.isActive,
               !suppressesActivation {
                NSApp?.activate(ignoringOtherApps: true)
                makeKeyAndOrderFront(nil)
            }
            // `hitTest` takes a point in the SUPERVIEW's space; the content
            // view's superview is the frame view, whose coordinates are the
            // window's own — so the raw window location is the right point.
            let hit = contentView?.hitTest(event.locationInWindow)
            Telemetry.log(.permission, "setup_click", [
                "phase": event.type == .leftMouseDown ? "down" : "up",
                "hit": hit.map { String(describing: type(of: $0)) } ?? "none",
                "app_active": wasActive ? "true" : "false",
                "key": isKeyWindow ? "true" : "false",
            ])
        }
        super.sendEvent(event)
    }
}

/// Bridges the VC's Done tap back to the window controller across the
/// `super.init` ordering gap (see ``OnboardingWindowController/init``).
@MainActor
private final class Trampoline {
    var action: (() -> Void)?
    func fire() { action?() }
}
