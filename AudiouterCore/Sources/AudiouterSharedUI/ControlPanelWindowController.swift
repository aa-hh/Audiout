// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

/// Reusable "control panel" shell (control-panel rollout, `AIRPLAY_CONTROL_PANEL=1`):
/// a sticky floating `NSPanel` that hosts an arbitrary content `NSViewController`.
/// The Groups window, Settings window, and future Setup surfaces are unifying
/// onto ONE of these instead of each owning its own orphaned `NSWindow` — the
/// app keeps exactly one `ControlPanelWindowController` alive and calls
/// `setContent(_:)` to swap what it's showing, so opening Settings replaces
/// Groups in the same shell rather than opening a second window.
///
/// Panel behavior (decided, do not drift):
/// - ACTIVATING: takes focus on open. Deliberately NOT `.nonactivatingPanel` —
///   this is a real work surface (text fields, buttons), not a HUD.
/// - `hidesOnDeactivate = true`: tucks away on app-switch; AppKit restores it
///   automatically when the app regains activation. This is NOT a close, so
///   `onClose` must never fire for it — see `windowWillClose` below.
/// - On a REAL close (✕ / Esc / `performClose`) the app "lands home": `onClose`
///   fires so the caller can re-present the menu-bar popover.
/// - Anchored just under the menu-bar status item via `show(anchorRect:)`,
///   RIGHT-EDGE aligned to it (T11) with a custom-drawn arrow "beak" tying the
///   two together — see `ControlPanelBackingView`.
///
/// Lifted from `MixerWindowController.makeContainer`'s `.panel` branch /
/// `showPanel` (the Groups-only prototype) — this type is the reusable
/// extraction; `MixerWindowController` itself is untouched by this change.
@MainActor
public final class ControlPanelWindowController: NSWindowController {

    /// Fired when the panel closes for real (✕ / Esc / `performClose`) — never
    /// for a `hidesOnDeactivate` tuck-away. The caller uses this to "land home"
    /// (re-present the menu-bar popover).
    public var onClose: (() -> Void)?

    /// The view controller currently hosted in the panel, so `setContent` can
    /// no-op when asked to show what's already showing.
    private var currentContent: NSViewController?

    /// Purely decorative window (T11) sitting BEHIND the real panel, drawing
    /// the rounded bubble + arrow "beak" that visually ties the panel to the
    /// menu-bar status item. `ignoresMouseEvents = true` — it never receives
    /// or intercepts a click; the real panel in front handles all input
    /// exactly as it did before this task. See `ControlPanelBackingView` and
    /// the "custom-drawn window chrome" exception in `AGENTS.md`.
    private let backingWindow: NSWindow
    private let backingView: ControlPanelBackingView

    public init(contentViewController: NSViewController? = nil, title: String = "") {
        let panel = Self.makePanel()
        (backingWindow, backingView) = Self.makeBackingWindow()
        super.init(window: panel)
        panel.delegate = self
        if !title.isEmpty { panel.title = title }
        // Attached once; the parent/child relationship survives close/reshow
        // (verified empirically — AppKit re-tracks position and visibility
        // automatically), so `show(anchorRect:)` never needs to re-attach it.
        panel.addChildWindow(backingWindow, ordered: .below)
        if let contentViewController {
            setContent(contentViewController)
        }
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Build the sticky floating panel. Config lifted verbatim from
    /// `MixerWindowController.makeContainer`'s `.panel` branch: ACTIVATING
    /// (no `.nonactivatingPanel`), floats above other apps, never claims a
    /// Dock slot, tucks away on app-switch and is restored on return, takes
    /// key for text editing, and isn't released on close so it can be reused.
    ///
    /// T11 adds the visual "borderless bubble" look WITHOUT touching any of
    /// the bits above: `.titled` + `.closable` stay in the style mask because
    /// `performClose(_:)` silently no-ops (no `windowWillClose`, no `onClose`)
    /// on a window whose style mask lacks `.titled` — verified empirically.
    /// Removing it would have desynchronized `onClose` from ✕/Esc/performClose,
    /// which the whole "land home" contract (and this file's own tests) depend
    /// on. Instead the native title bar is made fully invisible
    /// (`titlebarAppearsTransparent` + hidden title + hidden close button) and
    /// the window itself painted transparent so the ONLY visible chrome is
    /// `ControlPanelBackingView`'s custom drawing in the window behind it.
    private static func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = true       // tuck away on app-switch; restored on return
        panel.becomesKeyOnlyIfNeeded = false // ACTIVATING: takes key on open
        panel.isReleasedWhenClosed = false   // reused across opens (one panel, swapped content)
        panel.animationBehavior = .utilityWindow

        // Borderless bubble look (T11): no native title bar, no shadow of its
        // own (the backing window behind draws a shape-fitted shadow instead),
        // fully transparent everywhere the hosted content doesn't paint.
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Not user-draggable: an anchored, transient panel has no business
        // being repositioned by the user, and keeping it fixed guarantees the
        // decorative backing window (which follows this one's frame deltas,
        // not a live layout pass) never drifts out of sync.
        panel.isMovable = false
        return panel
    }

    /// Build the decorative backing window (T11): borderless, click-through,
    /// non-opaque so `ControlPanelBackingView`'s alpha shape (not the window's
    /// rectangular frame) determines both what's visible and where the shadow
    /// falls. Never shown/hidden/moved independently — always driven in
    /// lockstep with the real panel from `show(anchorRect:)`.
    private static func makeBackingWindow() -> (NSWindow, ControlPanelBackingView) {
        let initialRect = NSRect(x: 0, y: 0, width: 720, height: 460 + ControlPanelBackingView.beakHeight)
        let window = NSWindow(
            contentRect: initialRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.ignoresMouseEvents = true     // purely decorative — never intercepts a click
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = true      // belt-and-suspenders; also cascades from the parent
        window.animationBehavior = .none     // the parent's animationBehavior already applies

        let view = ControlPanelBackingView(frame: NSRect(origin: .zero, size: initialRect.size))
        window.contentView = view
        return (window, view)
    }

    /// Swap the hosted content — the "one panel at a time" mechanism: opening
    /// Settings while Groups is showing calls this rather than opening a new
    /// window. No-ops when `controller` is already the hosted content.
    public func setContent(_ controller: NSViewController) {
        guard currentContent !== controller else { return }
        currentContent = controller
        window?.contentViewController = controller
        configureContentAppearance(controller.view)
    }

    /// T11: round the hosted content's corners to match the backing bubble's
    /// `cornerRadius` (so the two windows read as one continuous shape) and
    /// give it an opaque backdrop fill, since the panel itself is now fully
    /// transparent (see `makePanel`) and can no longer be relied on to paint
    /// anything behind content that doesn't already paint its own background.
    /// The known limitation: the resolved fill color is a snapshot taken now,
    /// not a live-tracking dynamic color — a mid-session `NSApp.appearance`
    /// flip while this exact panel instance stays open without reopening
    /// would leave it stale until the next `setContent`/`show`. Every real
    /// caller (Groups' split view, Settings' `NSVisualEffectView` root) also
    /// paints its own opaque background already, so this is a defensive
    /// fallback, not the primary source of the visible fill.
    private func configureContentAppearance(_ view: NSView) {
        view.wantsLayer = true
        let appearance = window?.effectiveAppearance ?? NSApp.effectiveAppearance
        appearance.performAsCurrentDrawingAppearance {
            view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        view.layer?.cornerRadius = ControlPanelBackingView.cornerRadius
        view.layer?.masksToBounds = true
    }

    /// Set the panel's title bar text (e.g. "Groups", "Settings"). The title
    /// bar itself is invisible (T11), but the text still becomes the window's
    /// accessibility/VoiceOver title and the Mission Control / ⌘` window name.
    public func setTitle(_ title: String) {
        window?.title = title
    }

    /// Show the panel anchored just under `anchorRect` (the menu-bar status
    /// item's frame, in screen coordinates); `nil` centers it.
    ///
    /// T11: RIGHT-EDGE aligned to the anchor (previously center-aligned) —
    /// matches how macOS's own menu-bar panels (Control Center, Notification
    /// Center) sit under a narrow status item without the bulk of a wide panel
    /// overhanging both sides. The backing window is kept in lockstep (same
    /// x/width, `beakHeight` taller) and its beak tip repositioned to track
    /// wherever the anchor actually ends up after clamping. The signature is
    /// unchanged from T1 on purpose.
    public func show(anchorRect: NSRect?) {
        guard let panel = window else { return }
        panel.contentView?.layoutSubtreeIfNeeded()
        let size = panel.frame.size

        if let anchor = anchorRect {
            let gap: CGFloat = ControlPanelBackingView.beakHeight + 2
            var origin = NSPoint(x: anchor.maxX - size.width,
                                 y: anchor.minY - gap - size.height)
            if let screen = panel.screen ?? NSScreen.main {
                let vf = screen.visibleFrame
                // Match the popover's placement: right edge near the SCREEN edge
                // (not pinned to the icon), body extending left — so the surface
                // doesn't jump horizontally when it replaces the popover. The
                // beak still points at the icon via `beakFraction` below.
                origin.x = vf.maxX - size.width - 12
                origin.x = min(max(vf.minX + 8, origin.x), vf.maxX - size.width - 8)
                origin.y = max(vf.minY + 8, origin.y)
                // Leave room for the backing window's beak strip ABOVE the
                // panel too (T11) — AppKit's own screen-constrain (applied the
                // moment a window is actually ordered on screen, independent
                // of this clamp) silently clamps to `visibleFrame`, so without
                // this the backing window can get pushed down out of lockstep
                // with the panel whenever the panel already sits close to the
                // screen top (exactly where a menu-bar-anchored panel usually
                // does) — found via manual verification, not by the unit
                // tests, which never check the backing window's position.
                origin.y = min(origin.y, vf.maxY - size.height - ControlPanelBackingView.beakHeight)
            }
            panel.setFrameOrigin(origin)
        } else {
            panel.center()
        }

        // Order/activate BEFORE reading the panel's frame back: AppKit can
        // silently re-constrain an off-/edge-of-screen window's position the
        // moment it's actually ordered onto screen, which would otherwise
        // desync the backing window from wherever the panel really landed
        // (found via manual verification — the naive "compute once, position
        // both" ordering left the beak pointing at nothing).
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        let finalFrame = panel.frame
        let beakFraction: CGFloat
        if let anchor = anchorRect, finalFrame.width > 0 {
            beakFraction = (anchor.midX - finalFrame.minX) / finalFrame.width
        } else {
            beakFraction = 0.85
        }
        backingWindow.orderFront(nil)
        backingWindow.setFrame(
            NSRect(x: finalFrame.minX, y: finalFrame.minY,
                  width: finalFrame.width, height: finalFrame.height + ControlPanelBackingView.beakHeight),
            display: true)
        backingView.beakFraction = beakFraction
        backingWindow.invalidateShadow()

        animateAppearance()
    }

    // MARK: T11 — open/close animation

    /// Whether to skip the custom animation and just snap into place —
    /// System Settings › Accessibility › Display › Reduce Motion.
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Fade the panel in, anchored to the menu bar (it's already positioned
    /// there by the time this runs). Kept to a plain opacity fade rather than
    /// also sliding/scaling from the anchor point: a transform-based "grow
    /// from the beak" effect would need to run on the HOSTED content's layer
    /// too (so it moves in lockstep with the backing bubble), and that layer
    /// belongs to caller-owned content whose `isFlipped` state this shell
    /// doesn't control — a translate animation could slide the wrong
    /// direction depending on it. A fade is direction-agnostic and safe on
    /// any content. Flattened entirely under Reduce Motion.
    private func animateAppearance() {
        guard !reduceMotion else { return }
        for layer in [backingView.layer, window?.contentView?.layer] {
            guard let layer else { continue }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.16
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(fade, forKey: "controlPanelOpenFade")
        }
    }

    /// Best-effort fade as the panel closes. This is NOT a deferred/blocking
    /// close: `onClose` must keep firing synchronously from `windowWillClose`
    /// (✕/Esc/performClose/the existing test suite all depend on that timing
    /// unchanged from T1), so the real close is never held up waiting for this
    /// animation. Explicit `CABasicAnimation`s only touch the presentation
    /// layer — the moment they're added the MODEL values are already final —
    /// so this can't desync anything a caller reads. In practice the fade gets
    /// composited for however long AppKit takes to actually tear the window
    /// down after this returns; in a live app that's enough to read as a
    /// close transition, in a fast/headless run it may not render at all.
    private func animateDisappearance() {
        guard !reduceMotion else { return }
        for layer in [backingView.layer, window?.contentView?.layer] {
            guard let layer else { continue }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = 0.12
            fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
            layer.add(fade, forKey: "controlPanelCloseFade")
        }
    }

    // MARK: Test-support hooks

    /// The hosted panel, typed as `NSPanel`, for structural assertions.
    public var test_panel: NSPanel? { window as? NSPanel }

    /// The decorative backing window, for structural assertions (T11).
    public var test_backingWindow: NSWindow? { backingWindow }
}

// MARK: - NSWindowDelegate

extension ControlPanelWindowController: NSWindowDelegate {
    /// A real close (✕ / Esc / `performClose`) → land home. A tuck-away
    /// (`hidesOnDeactivate` order-out) is NOT a close and never reaches here —
    /// AppKit only calls this delegate method on an actual window close.
    public func windowWillClose(_ notification: Notification) {
        animateDisappearance()
        onClose?()
    }
}
