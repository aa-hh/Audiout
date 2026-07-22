// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterCore
import AudiouterSharedUI

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
    /// on. The native title bar is made visually invisible
    /// (`titlebarAppearsTransparent` + hidden title) while the standard CLOSE
    /// button is deliberately KEPT VISIBLE as the panel's close affordance: an
    /// anchored work surface that does NOT dismiss on click-out (it only tucks
    /// away on app-switch) has to give the user a real, obvious way out. The
    /// miniaturize/zoom buttons are hidden — neither makes sense on a fixed,
    /// anchored, non-movable panel. The window is painted transparent so the
    /// only large chrome is `ControlPanelBackingView`'s bubble in the window
    /// behind it, with the lone close button sitting in the top-left safe area
    /// over it. Escape is wired to close too — see `ControlPanelPanel`.
    private static func makePanel() -> NSPanel {
        let panel = ControlPanelPanel(
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
        // The close button is the panel's one visible close affordance — kept
        // shown (this is the fix for "no way to close the panel"). Miniaturize
        // and zoom are hidden: an anchored, non-movable panel has no use for
        // them, and a lone close button reads cleanly against the bubble.
        panel.standardWindowButton(.closeButton)?.isHidden = false
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isOpaque = false
        panel.backgroundColor = Tokens.Color.clear
        panel.hasShadow = false
        // Not user-draggable: an anchored, transient panel has no business
        // being repositioned by the user, and keeping it fixed guarantees the
        // decorative backing window (which follows this one's frame deltas,
        // not a live layout pass) never drifts out of sync.
        panel.isMovable = false
        // Summon onto the CURRENT Space (and over a fullscreen app) rather than
        // switching Spaces — matches the "summon → act → dismiss" model
        // (window-panel.md M1).
        panel.collectionBehavior.formUnion([.moveToActiveSpace, .fullScreenAuxiliary])
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
        // Match the panel's Space behavior so the decorative backing follows it.
        window.collectionBehavior.formUnion([.moveToActiveSpace, .fullScreenAuxiliary])
        window.isOpaque = false
        window.backgroundColor = Tokens.Color.clear
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
    /// `cornerRadius` so the two windows read as one continuous shape.
    ///
    /// The hosted view is left TRANSPARENT on purpose — it must NOT paint an
    /// opaque background of its own. The panel is fully transparent (see
    /// `makePanel`), and the decorative backing window behind it already draws
    /// an opaque, LIVE-adaptive `windowBackgroundColor` bubble
    /// (`ControlPanelBackingView.draw`). An earlier version filled this layer
    /// with a resolved `windowBackgroundColor.cgColor` "defensive fallback",
    /// but a CGColor is frozen at the instant's appearance and cannot follow a
    /// light/dark change — which is exactly what left Groups' transparent
    /// split-view content pane rendering a stale LIGHT fill in dark mode while
    /// its vibrancy sidebar adapted correctly (visual C3b, the "half-render").
    /// Clearing the fill lets the backing bubble's live color show through the
    /// content pane — identical to how the rounded corners already reveal it —
    /// so the whole panel tracks the appearance as one, and Groups in the shell
    /// matches Groups in its standalone window (source-list sidebar + a
    /// `windowBackgroundColor` content pane). Content that paints its OWN
    /// opaque, appearance-adaptive background (Settings' `NSVisualEffectView`
    /// root) simply covers the bubble, unaffected.
    private func configureContentAppearance(_ view: NSView) {
        view.wantsLayer = true
        view.layer?.backgroundColor = Tokens.Color.clear.cgColor
        view.layer?.cornerRadius = ControlPanelBackingView.cornerRadius
        view.layer?.masksToBounds = true
    }

    /// Set the panel's title bar text (e.g. "Groups", "Settings"). The title
    /// bar itself is invisible (T11), but the text still becomes the window's
    /// accessibility/VoiceOver title and the Mission Control / ⌘` window name.
    public func setTitle(_ title: String) {
        window?.title = title
    }

    /// Whether the panel is currently on screen, as opposed to tucked away by
    /// `hidesOnDeactivate` after an app-switch. The status-item click handler
    /// reads this to decide between toggling a live panel CLOSED and restoring
    /// a tucked-away one — see `AppDelegate`'s `onButtonClicked`.
    public var isPanelVisible: Bool { window?.isVisible ?? false }

    /// Close the panel exactly as the ✕ button or Escape would: routed through
    /// `performClose(_:)` so `windowWillClose` → `onClose` fires and the app
    /// lands home on the popover. The status-item toggle-close uses this rather
    /// than a bare `close()`/`orderOut`, which would skip the land-home contract.
    public func performClose() {
        window?.performClose(nil)
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
            // CENTER on the anchor's midX, exactly like `NSPopover.show(relativeTo:
            // of:preferredEdge:)` does — this is what actually replaces the popover
            // at its real on-screen position (design feedback 2026-07-18b: pinning
            // to the SCREEN's right edge only looked correct in the one screenshot
            // where the icon happened to sit right at the screen edge; for any
            // other icon position it drifted the panel away from where the
            // popover really was). Clamped below so it still stays fully on
            // screen if the icon sits near an edge.
            var origin = NSPoint(x: anchor.midX - size.width / 2,
                                 y: anchor.minY - gap - size.height)
            if let screen = panel.screen ?? NSScreen.main {
                let vf = screen.visibleFrame
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
        //
        // NEVER actually put a window on screen under `swift test` or a
        // harness/snapshot tool (`HeadlessRuntime`) — those hold a real
        // WindowServer connection, so an un-gated `makeKeyAndOrderFront` here
        // would flash an empty, real window on the developer's actual screen
        // for the run's duration. Everything else (frame math, model state)
        // still runs so headless assertions stay exactly as strong.
        if !HeadlessRuntime.isActive {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        }

        let finalFrame = panel.frame
        let beakFraction: CGFloat
        if let anchor = anchorRect, finalFrame.width > 0 {
            beakFraction = (anchor.midX - finalFrame.minX) / finalFrame.width
        } else {
            beakFraction = 0.85
        }
        if !HeadlessRuntime.isActive {
            backingWindow.orderFront(nil)
        }
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

// MARK: - ControlPanelPanel

/// The shell's `NSPanel`, subclassed for ONE reason: to make Escape a
/// deterministic close. Pressing Escape (or ⌘.) sends `cancelOperation(_:)` up
/// the responder chain; routing it to `performClose(_:)` guarantees Esc closes
/// the panel through the SAME path as the ✕ button — `windowWillClose` →
/// `onClose` (land home) — instead of relying on incidental default panel
/// behavior. `performClose(_:)` only fires when the style mask contains
/// `.titled`/`.closable` (it does — see `ControlPanelWindowController.makePanel`),
/// so this closes cleanly with no system beep. A field editor still gets first
/// crack at Escape (to cancel in-progress text editing) before it reaches here.
final class ControlPanelPanel: NSPanel {
    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
}
