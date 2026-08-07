// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import CoreGraphics
import AudiouterCore

/// Catches the hardware volume keys while the Mac's default output cannot take a
/// volume write, and drives Main Out with them instead.
///
/// WHY: when our public "Audiouter" aggregate is the default output, macOS
/// refuses to move the system volume — every press draws the crossed-out HUD and
/// nothing happens. Without this, the only way to change volume while the app is
/// routing is to open the app.
///
/// WHAT IT CANNOT DO, and no amount of work here will change it: the Touch Bar's
/// volume *slider*, the menu-bar slider, Control Center, Siri and `osascript set
/// volume` all write the device's volume scalar through Core Audio directly.
/// They emit no event, so there is nothing to intercept — macOS just greys them
/// out. Only things that travel the HID path arrive here: physical volume keys,
/// and the Touch Bar's DISCRETE Volume Up/Down/Mute buttons (`ControlStrip.app`
/// posts those through `DFRFoundationPostHIDUsage`, which is a real HID usage).
/// That asymmetry is why the Control Strip layout swap exists — see
/// `docs/plans/PLAN-VOLUME-KEY-INTERCEPTION.md` §7.
///
/// THIS TYPE IS A SHELL. Every decision it makes lives in `AudiouterCore`'s
/// ``VolumeKeyDecision`` so it can be tested without a tap, a grant, or an
/// aggregate. Nothing that decides anything belongs in this file.
@MainActor
final class VolumeKeyInterceptor {

    /// State the tap callback reads. Separate from `self` because the callback is
    /// a C function pointer that cannot capture context and is not `@MainActor`,
    /// so it needs somewhere lock-guarded to look.
    private let state = VolumeKeyTapState()

    /// The Accessibility read/prompt seam — the same ``RemoteControlPriming``
    /// ``MediaKeyController`` and onboarding use, injected so
    /// `AIRPLAY_PERMISSIONS=granted|denied` reaches this path instead of springing
    /// a real system dialog during an automated run.
    private let remoteControl: RemoteControlPriming

    /// True once we've shown the Accessibility prompt this launch, so repeatedly
    /// entering the mode can't stack system dialogs.
    private var didRequestAccessibility = false

    private var runLoopSource: CFRunLoopSource?

    /// Called on the main actor with what an intercepted key should do. Set by
    /// `AppDelegate`; the interceptor itself knows nothing about `GroupController`.
    var onAction: (@MainActor (VolumeKeyAction) -> Void)?

    /// Fires when the tap could not be created because Accessibility is not
    /// granted. The keys are silently dead in that state, so this has to reach
    /// the UI rather than just a log line.
    var onAccessibilityMissing: (@MainActor () -> Void)?

    init(remoteControl: RemoteControlPriming = RemoteControlPrimerFactory.makeDefault()) {
        self.remoteControl = remoteControl
        state.onAction = { [weak self] action in
            // Hop off the callback before touching app state: the tap must return
            // fast or macOS disables it, and this keeps `GroupController` work out
            // of the event path entirely.
            Task { @MainActor in self?.onAction?(action) }
        }
    }

    deinit { VolumeKeyInterceptor.teardown(state: state, source: runLoopSource) }

    // MARK: - Mode

    /// Follow ``BackendEvent/systemVolumeOwnershipChanged(_:)``. Installs the tap
    /// when we take ownership and tears it down when we lose it, so we hold an
    /// event tap only while it is actually doing something.
    func setOwnsVolume(_ owns: Bool) {
        state.setOwnsVolume(owns)
        if owns { installIfNeeded() } else { uninstall() }
    }

    /// Keep the volume the decision core steps FROM in sync. Pushed rather than
    /// pulled because the callback cannot reach `@MainActor` state synchronously,
    /// and must not block trying.
    func setCurrentMainVolume(_ volume: Int) {
        state.setMainVolume(volume)
    }

    // MARK: - The tap

    private func installIfNeeded() {
        guard state.tap == nil else {
            // Already installed, but macOS may have disabled it while we weren't
            // looking (a slow callback, or a login-window switch). Re-arm.
            state.reenableIfDisabled()
            return
        }

        // Unlike `MediaKeyController`'s posting — which merely no-ops without the
        // grant — a tap cannot be CREATED at all untrusted, so the grant stops
        // being optional the moment the aggregate goes live.
        guard remoteControl.isTrusted() else {
            requestAccessibilityOnce()
            onAccessibilityMissing?()
            return
        }

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let state = Unmanaged<VolumeKeyTapState>.fromOpaque(userInfo).takeUnretainedValue()
            return state.handle(type: type, event: event)
        }

        // Only NX_SYSDEFINED (14) — deliberately NOT `.keyDown`, which would put
        // this app in the path of every keystroke the user types. `CGEventType`
        // has no case for 14, hence the hand-built mask.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,   // .listenOnly cannot swallow the crossed-out HUD
            eventsOfInterest: CGEventMask(1 << 14),
            callback: callback,
            userInfo: Unmanaged.passUnretained(state).toOpaque()
        ) else {
            // Trusted a moment ago but the tap still failed — treat it as the same
            // user-visible problem rather than dying silently.
            onAccessibilityMissing?()
            return
        }

        // razor: the main run loop. A tap whose callback is starved gets disabled
        // by macOS, which `reenableIfDisabled` recovers from; if the main thread
        // ever blocks badly enough for that to be routine, the upgrade path is a
        // dedicated thread with its own run loop.
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        state.tap = tap
        runLoopSource = source
    }

    private func uninstall() {
        VolumeKeyInterceptor.teardown(state: state, source: runLoopSource)
        runLoopSource = nil
    }

    /// `nonisolated static` so `deinit` can call it. Mirrors `uninstall()`.
    private nonisolated static func teardown(state: VolumeKeyTapState, source: CFRunLoopSource?) {
        if let tap = state.tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        state.tap = nil
    }

    // MARK: - Accessibility

    /// Ask for Accessibility once per launch. `prime()` is
    /// `AXIsProcessTrustedWithOptions([prompt: true])` behind the seam, which both
    /// registers the app in the Accessibility list and shows the standard dialog.
    private func requestAccessibilityOnce() {
        guard !didRequestAccessibility else { return }
        didRequestAccessibility = true
        remoteControl.prime()

        let message = "[Audiouter] The volume keys need Accessibility access while Audiouter is "
            + "your output device — prompted. Grant it in System Settings › Privacy & Security › "
            + "Accessibility, then the volume keys will drive Main Out.\n"
        FileHandle.standardError.write(Data(message.utf8))
    }
}

// MARK: - Callback-side state

/// The only thing the tap callback touches. Lock-guarded because the callback is
/// a bare C function pointer with no actor isolation of its own.
private final class VolumeKeyTapState: @unchecked Sendable {

    private let lock = NSLock()
    private var ownsVolume = false
    /// What the next press steps FROM. Pushed by the main actor, and also stepped
    /// forward optimistically on each press so a HELD key walks the detents
    /// instead of re-computing from a stale value every repeat.
    private var mainVolume = 100

    /// Held so the callback can re-arm a tap macOS disabled. Only ever written
    /// from the main actor, only ever read on the callback's thread — both under
    /// the same lock via the accessors below.
    private var _tap: CFMachPort?
    var tap: CFMachPort? {
        get { lock.withLock { _tap } }
        set { lock.withLock { _tap = newValue } }
    }

    var onAction: ((VolumeKeyAction) -> Void)?

    func setOwnsVolume(_ owns: Bool) { lock.withLock { ownsVolume = owns } }
    func setMainVolume(_ volume: Int) { lock.withLock { mainVolume = volume } }

    func reenableIfDisabled() {
        guard let tap, !CGEvent.tapIsEnabled(tap: tap) else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS disables a tap whose callback ran too slowly, and tells us by
        // delivering these instead of an event. A tap that stays disabled looks
        // exactly like "the feature silently stopped working", so always re-arm.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reenableIfDisabled()
            return Unmanaged.passUnretained(event)
        }

        guard let nsEvent = NSEvent(cgEvent: event),
              nsEvent.type == .systemDefined,
              nsEvent.subtype.rawValue == 8
        else { return Unmanaged.passUnretained(event) }

        let (owns, current) = lock.withLock { (ownsVolume, mainVolume) }

        let outcome = VolumeKeyDecision.decide(
            data1: nsEvent.data1,
            modifierFlags: nsEvent.modifierFlags.rawValue,
            weOwnVolume: owns,
            currentMainVolume: current
        )

        switch outcome {
        case .passThrough:
            return Unmanaged.passUnretained(event)
        case .consume(let action):
            if let action {
                if case .setMainVolume(let target) = action {
                    lock.withLock { mainVolume = target }
                }
                onAction?(action)
            }
            return nil
        }
    }
}
