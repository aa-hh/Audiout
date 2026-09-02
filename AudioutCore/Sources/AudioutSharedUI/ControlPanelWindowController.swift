// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore

/// Reusable "control panel" shell: a sticky floating `NSPanel` that hosts an
/// arbitrary content `NSViewController`. It is the ONE SURFACE's window (the
/// old `AIRPLAY_CONTROL_PANEL` opt-in flag is retired — this shell always
/// ships): `AppSurfaceController` keeps exactly one
/// `ControlPanelWindowController` alive and calls `setContent(_:)` to swap
/// between the Mixer/Groups/Settings screens rather than opening a second
/// window. It stays content-agnostic — no screen concepts in here.
///
/// Panel behavior (decided, do not drift):
/// - ACTIVATING: takes focus on open. Deliberately NOT `.nonactivatingPanel` —
///   this is a real work surface (text fields, buttons), not a HUD.
/// - `hidesOnDeactivate = true` (UNPINNED only): tucks away on app-switch;
///   AppKit restores it automatically when the app regains activation. This is
///   NOT a close, so `onClose` must never fire for it — see `windowWillClose`.
/// - On a REAL close (✕ / Esc / `performClose`) the app "lands home": `onClose`
///   fires so the caller can re-present the menu-bar popover.
/// - Anchored just under the menu-bar status item via `show(anchorRect:)`,
///   CENTERED on its midX like `NSPopover` (clamped on-screen), with a
///   custom-drawn arrow "beak" tying the two together — see
///   `ControlPanelBackingView`.
///
/// ## Two manner profiles (U1)
///
/// The same window, the same hosted content, two sets of MANNERS — flipped at
/// runtime by `setPinned(_:)`. Content is NEVER re-hosted across the flip
/// (re-assigning `contentViewController` snaps the window to a 500×500
/// fallback — see `setContent`'s TRAP — and the hosted view trees are heavily
/// stateful), so "pin" is a property change on one live window, never a move
/// to a different one.
///
/// - UNPINNED (the default): anchored under the status item
///   with the beak, `isMovable = false`, `hidesOnDeactivate = true`,
///   `level = .floating`, transparent title-bar area (the surface's toolbar
///   items sit directly on the bubble), standard buttons hidden, no frame
///   autosave, and click-outside dismisses (`windowDidResignKey`).
/// - PINNED: an ordinary movable window — `isMovable = true`,
///   `hidesOnDeactivate = false`, `level = .normal`, the system toolbar strip
///   with the standard close button visible (the title-bar TEXT stays hidden
///   in both profiles — the one header strip is the surface's toolbar, owner
///   decision 2026-08-07), the decorative beak/backing window hidden, an
///   opaque warm background of its own, and frame autosave armed so the
///   position survives relaunch. It does NOT dismiss on click-out; it can sit
///   behind other apps. Dragging by the toolbar strip works (system default
///   for a movable window's title-bar area).
///
/// **Only APPEARANCE/manner bits ever change** — `.titled` and `.closable`
/// stay in the style mask in BOTH profiles, forever (see `makePanel`: removing
/// `.titled` silently kills `performClose`/`windowWillClose`/`onClose` and
/// Escape). "Show a real title bar" is `titlebarAppearsTransparent` +
/// `titleVisibility`, never style-mask surgery.
///
/// **Un-pinning re-anchors IMMEDIATELY when the panel is on screen** (rather
/// than deferring to the next `show`): a pinned window can be anywhere —
/// dragged to another corner, restored from a saved frame on a different
/// screen — and the moment it stops being pinned it grows a beak that points
/// at the status item. Leaving it in place until the next show would render a
/// beak aimed at nothing and a "transient" panel nowhere near the menu bar.
/// Re-anchoring on the spot keeps the window on screen and its manners and
/// position consistent at every instant. When it is NOT on screen there is
/// nothing to re-anchor — the next `show(anchorRect:)` positions it normally.
@MainActor
public final class ControlPanelWindowController: NSWindowController {

    /// The duration animated `setFrame` resizes of the shell window use — a
    /// window's frame animation reads `animationResizeTime(_:)`, never the
    /// enclosing `NSAnimationContext`, so a host that animates window and
    /// content in step MUST set this to the content's shared duration.
    public var resizeAnimationDuration: TimeInterval? {
        get { (window as? ControlPanelPanel)?.resizeAnimationDuration }
        set { (window as? ControlPanelPanel)?.resizeAnimationDuration = newValue }
    }

    /// Fired when the panel closes for real (✕ / Esc / `performClose`) — never
    /// for a `hidesOnDeactivate` tuck-away. The caller uses this to "land home"
    /// (re-present the menu-bar popover).
    public var onClose: (() -> Void)?

    /// The view controller currently hosted in the panel, so `setContent` can
    /// no-op when asked to show what's already showing.
    private var currentContent: NSViewController?

    /// Content controllers that have completed their FIRST mount, keyed by
    /// `ObjectIdentifier` so a specific content instance is sized at most once
    /// for the life of the shell. A later `setContent` re-hosting the same
    /// instance (e.g. returning to Groups after some other content showed) is
    /// a pure swap — it must never re-apply `defaultSize:` and stomp a size
    /// the user has since dragged. See `setContent` and the AGENTS.md rule
    /// contrasting this with the Settings window's "re-measure every show".
    private var sizedContentIDs = Set<ObjectIdentifier>()

    /// The anchor rect `show(anchorRect:)` was last called with, in screen
    /// coordinates — remembered so `windowDidResize` can recompute the beak's
    /// horizontal position against the SAME status-item anchor rather than a
    /// fraction frozen at open time. `nil` when the panel was last centered.
    private var lastAnchorRect: NSRect?

    /// Purely decorative window (T11) sitting BEHIND the real panel, drawing
    /// the rounded bubble + arrow "beak" that visually ties the panel to the
    /// menu-bar status item. `ignoresMouseEvents = true` — it never receives
    /// or intercepts a click; the real panel in front handles all input
    /// exactly as it did before this task. See `ControlPanelBackingView` and
    /// the "custom-drawn window chrome" exception in `AGENTS.md`.
    private let backingWindow: NSWindow
    private let backingView: ControlPanelBackingView

    /// The autosave name the PINNED profile persists its frame under. Injectable
    /// because `NSWindow.setFrameAutosaveName` always writes `UserDefaults
    /// .standard` no matter what defaults suite a caller uses — a per-test name
    /// is the only way to keep a test from racing the shipping key.
    private let frameAutosaveName: NSWindow.FrameAutosaveName

    /// Whether the panel is wearing the PINNED manner profile. Plain runtime
    /// state — persisting the user's choice belongs to `AppSettings`, not here.
    public private(set) var isPinned = false

    /// When the panel last closed ITSELF because it resigned key (click-out).
    /// Monotonic (`CACurrentMediaTime`, never wall-clock — an NTP step must not
    /// make a fresh dismissal look stale). Read and cleared exactly once by
    /// `consumeRecentResignDismissal(within:)`; `nil` when there is no
    /// unconsumed self-dismissal.
    private var lastResignDismissalTime: CFTimeInterval?

    /// How recently a resign-key self-dismissal has to have happened for the
    /// status-item click handler to treat it as "that click is what closed me".
    /// A whole mouse-down→mouse-up on a menu-bar item is milliseconds; this is
    /// sized for a slow deliberate click, not for a later unrelated one.
    nonisolated public static let recentResignDismissalInterval: TimeInterval = 0.3

    public init(contentViewController: NSViewController? = nil,
                title: String = "",
                frameAutosaveName: NSWindow.FrameAutosaveName = "ControlPanelSurface") {
        let panel = Self.makePanel()
        (backingWindow, backingView) = Self.makeBackingWindow()
        self.frameAutosaveName = frameAutosaveName
        super.init(window: panel)
        panel.delegate = self
        if !title.isEmpty { panel.title = title }
        // Applies the UNPINNED profile, which is also what attaches the
        // decorative backing window. Attached once per unpinned spell; the
        // parent/child relationship survives close/reshow (verified empirically
        // — AppKit re-tracks position and visibility automatically), so
        // `show(anchorRect:)` never needs to re-attach it.
        applyPinProfile()
        if let contentViewController {
            setContent(contentViewController)
        }
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Build the panel's PROFILE-INDEPENDENT configuration — the bits that are
    /// identical pinned and unpinned. Everything that differs between the two
    /// manner profiles (level, movability, `hidesOnDeactivate`, title-bar
    /// visibility, opacity/shadow, frame autosave, the decorative backing
    /// window) is set by `applyPinProfile()`, which `init` calls immediately;
    /// a panel returned from here is not yet fully configured.
    ///
    /// ACTIVATING (no `.nonactivatingPanel`), never claims a Dock slot, takes
    /// key for text editing, and isn't released on close so it can be reused.
    ///
    /// T11 gave it a visual "borderless bubble" look WITHOUT touching the bits
    /// above: `.titled` + `.closable` stay in the style mask — IN BOTH
    /// PROFILES, permanently — because `performClose(_:)` silently no-ops (no
    /// `windowWillClose`, no `onClose`) on a window whose style mask lacks
    /// `.titled`, verified empirically. Removing it would desynchronize
    /// `onClose` from ✕/Esc/performClose, which the whole "land home" contract
    /// (and this file's own tests) depend on. The title-bar TEXT is hidden in
    /// both profiles (the surface's window-attached toolbar is the one header
    /// strip); what flips per profile is the strip's material
    /// (`titlebarAppearsTransparent`) and the standard close button's
    /// visibility — see `applyPinProfile`. The miniaturize/zoom buttons stay
    /// hidden in both — the style mask carries neither `.miniaturizable` nor a
    /// zoom-worthy window, so they would be dead chrome. Escape is wired to
    /// close too — see `ControlPanelPanel`.
    private static func makePanel() -> NSPanel {
        let panel = ControlPanelPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.becomesKeyOnlyIfNeeded = false // ACTIVATING: takes key on open
        panel.isReleasedWhenClosed = false   // reused across opens (one panel, swapped content)
        panel.isRestorable = false           // decided policy (P3/W7): menu-bar app, no window restoration
        panel.animationBehavior = .utilityWindow

        // Miniaturize and zoom are hidden in BOTH profiles: neither is in the
        // style mask, so they would be dead chrome. The close button's
        // visibility is profile-dependent (owner decision 2026-08-07) — see
        // `applyPinProfile`.
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        // Summon onto the CURRENT Space (and over a fullscreen app) rather than
        // switching Spaces — matches the "summon → act → dismiss" model
        // (window-panel.md M1).
        panel.collectionBehavior.formUnion([.moveToActiveSpace, .fullScreenAuxiliary])
        return panel
    }

    // MARK: - Manner profiles (U1)

    /// Flip the panel between its two manner profiles (see the class doc).
    /// Only manner/appearance bits move — the style mask, the hosted content,
    /// and the window identity are untouched, so no state is lost either way.
    ///
    /// Un-pinning while the panel is ON SCREEN re-anchors it under the status
    /// item on the spot (a pinned window can be anywhere, and the beak it grows
    /// back has to point at something); un-pinning while it is hidden leaves
    /// positioning to the next `show(anchorRect:)`.
    public func setPinned(_ pinned: Bool) {
        guard pinned != isPinned else { return }
        isPinned = pinned
        applyPinProfile()
        if !pinned, isPanelVisible {
            show(anchorRect: lastAnchorRect)
        }
    }

    /// Stamp the current profile's manner bits onto the panel. Idempotent, and
    /// the ONLY place either profile's bits are written — `makePanel` sets none
    /// of them, so there is exactly one definition of each profile.
    private func applyPinProfile() {
        // Typed as `NSPanel`, not `NSWindow`: `isFloatingPanel` is READ-ONLY on
        // `NSWindow` and read-write only on `NSPanel`.
        guard let panel = window as? NSPanel else { return }
        if isPinned {
            // `isFloatingPanel` IS the level switch, in both directions — it
            // writes `level` as a side effect (`false` → `.normal`, `true` →
            // `.floating`), measured on both flips. So there is no explicit
            // level assignment here: one before this line would be silently
            // overwritten, and one after it would be dead code.
            panel.isFloatingPanel = false
            panel.hidesOnDeactivate = false  // may sit behind other apps
            panel.isMovable = true
            // NO separate visible title bar (owner decision 2026-08-07, live
            // build review): the window-attached toolbar the surface installs
            // IS the one header strip, and `titleVisibility` stays `.hidden`
            // so the title-bar text never stacks a second strip above it (the
            // toolbar carries a centered app-name item instead; `window.title`
            // remains set for VoiceOver / Mission Control). The title bar
            // area keeps its system material pinned (`titlebarAppearsTransparent
            // = false`) — the system draws the unified-toolbar strip, Liquid
            // Glass on macOS 26+, the older material below, Reduce
            // Transparency handled for free. Appearance bits only: the style
            // mask is NOT touched (see `makePanel`), so `.fullSizeContentView`
            // stays on — the hosted content still spans the whole frame,
            // including under the toolbar strip, and content that needs to
            // clear it has to inset itself.
            panel.titlebarAppearsTransparent = false
            panel.titleVisibility = .hidden
            // Pinned shows the standard close button (an ordinary window's
            // close affordance); unpinned hides it — the menu-bar click and
            // Escape close the transient bubble.
            panel.standardWindowButton(.closeButton)?.isHidden = false
            // The decorative bubble is gone, so the window has to paint and
            // cast a shadow itself — otherwise a pinned surface would be an
            // invisible rectangle under a floating toolbar strip. `panel` is
            // the same warm fill the bubble draws (the ONE surface canvas,
            // owner decision 2026-08-07), so the hosted content (deliberately
            // transparent — see `configureContentAppearance`) reads
            // identically in both profiles.
            panel.isOpaque = true
            panel.backgroundColor = Tokens.Color.panel
            panel.hasShadow = true
            panel.removeChildWindow(backingWindow)
            backingWindow.orderOut(nil)
            // `setFrameUsingName` FIRST, then `setFrameAutosaveName`:
            // `setFrameAutosaveName`'s own Bool return is not a trustworthy
            // "was a frame restored" signal (verified empirically — it returns
            // `true` even for a brand-new name with nothing ever saved), so
            // the restore goes through the API that both restores
            // and reports; the autosave call afterward only ARMS ongoing
            // save-on-move/resize. With no saved frame this is a no-op and the
            // window pins exactly where it already sits; with one it returns
            // to where it was last pinned, which is the whole point of
            // remembering it.
            _ = panel.setFrameUsingName(frameAutosaveName)
            panel.setFrameAutosaveName(frameAutosaveName)
        } else {
            // Disarm autosave FIRST: the re-anchor that follows must not be
            // written back over the user's remembered pinned position.
            panel.setFrameAutosaveName("")
            panel.isFloatingPanel = true     // also restores `level` to `.floating`
            panel.hidesOnDeactivate = true   // tuck away on app-switch; restored on return
            // Not user-draggable: an anchored, transient panel has no business
            // being repositioned by the user, and keeping it fixed guarantees
            // the decorative backing window (which follows this one's frame
            // deltas, not a live layout pass) never drifts out of sync.
            panel.isMovable = false
            // Borderless bubble look (T11): the title-bar area goes fully
            // transparent so the window-attached toolbar's items sit directly
            // on the warm bubble — the strip must not paint a rectangular
            // material band across the bubble's rounded top (owner decision
            // 2026-08-07: the header has no backing fill of its own). No
            // shadow of its own (the backing window behind draws a
            // shape-fitted shadow instead).
            panel.titlebarAppearsTransparent = true
            panel.titleVisibility = .hidden
            // The transient bubble hides the standard buttons; Escape and the
            // menu-bar toggle are its close affordances (owner decision
            // 2026-08-07).
            panel.standardWindowButton(.closeButton)?.isHidden = true
            panel.isOpaque = false
            // NOT `.clear`: the window server treats zero-alpha pixels as
            // CLICK-THROUGH, and on macOS 26 the glass toolbar renders in its
            // own surface — so with a clear background the whole toolbar band
            // is transparent in THIS window's surface wherever no content sits
            // behind it (Settings/Groups seat content below the strip; only
            // Mixer's list happens to underlap it). Result: clicks on the nav
            // tabs fell through to whatever app was behind the panel, which
            // deactivated us and read as "the tab click closed the popover"
            // (live-diagnosed 2026-08-12, window-server hit-grid probe). A 2%
            // wash is invisible over the backing bubble but keeps every pixel
            // of the panel hit-testable.
            panel.backgroundColor = NSColor.black.withAlphaComponent(0.02)
            panel.hasShadow = false
            if backingWindow.parent !== panel {
                panel.addChildWindow(backingWindow, ordered: .below)
            }
        }
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

    /// Swap the hosted content — the "one panel at a time" mechanism: hosting
    /// new content while something else is showing calls this rather than
    /// opening a new window. No-ops when `controller` is already the hosted
    /// content.
    ///
    /// `defaultSize` seeds the panel's size on the FIRST mount of `controller`
    /// ONLY (tracked by `ObjectIdentifier` in `sizedContentIDs`) — a later
    /// re-host of the same instance never re-applies it, so a size the user
    /// has since dragged survives a swap away and back. This is the
    /// deliberate OPPOSITE of the Settings window's "re-measure before every
    /// show" rule — see `AudioutSettingsUI/AGENTS.md` and this file's
    /// AGENTS.md for why both are correct for their own surface.
    ///
    /// TRAP, found by manual AppKit probe: assigning `window.contentViewController`
    /// is NOT size-neutral by itself — AppKit resizes the window to a generic
    /// (500, 500) fallback the moment a controller (new OR previously hosted)
    /// is (re-)assigned, before this method gets a chance to size anything. A
    /// naive "only call `setContentSize` on first mount" guard is defeated by
    /// that assignment alone, so a re-host would silently snap to (500, 500)
    /// instead of holding its current size. The fix: capture the panel's size
    /// BEFORE reassigning, and on every re-host (not just the first mount)
    /// explicitly restore it right after — `defaultSize` only wins on a
    /// controller's genuine first mount.
    public func setContent(_ controller: NSViewController, defaultSize: NSSize = NSSize(width: 720, height: 460)) {
        guard currentContent !== controller else { return }
        currentContent = controller
        let priorSize = window?.frame.size
        window?.contentViewController = controller
        configureContentAppearance(controller.view)

        let id = ObjectIdentifier(controller)
        if sizedContentIDs.contains(id) {
            if let priorSize { window?.setContentSize(priorSize) }
        } else {
            sizedContentIDs.insert(id)
            window?.setContentSize(defaultSize)
        }
    }

    /// T11: round the hosted content's corners to match the backing bubble's
    /// `cornerRadius` so the two windows read as one continuous shape.
    ///
    /// The hosted view is left TRANSPARENT on purpose — it must NOT paint an
    /// opaque background of its own. The panel is fully transparent (see
    /// `makePanel`), and the decorative backing window behind it already draws
    /// an opaque, LIVE-adaptive warm `canvas` bubble
    /// (`ControlPanelBackingView.draw`, Warm Signal §5.4 — bubble, beak, and
    /// content pane are one continuous warm shape with no seam). An earlier
    /// version filled this layer with a resolved `.cgColor` "defensive
    /// fallback", but a CGColor is frozen at the instant's appearance and
    /// cannot follow a light/dark change — which is exactly what left Groups'
    /// transparent split-view content pane rendering a stale LIGHT fill in
    /// dark mode while its vibrancy sidebar adapted correctly (visual C3b,
    /// the "half-render"). Clearing the fill lets the backing bubble's live
    /// warm color show through the content pane — identical to how the
    /// rounded corners already reveal it — so the whole panel tracks the
    /// appearance as one. Content that paints its OWN opaque,
    /// appearance-adaptive background (Settings' `NSVisualEffectView` root)
    /// simply covers the bubble, unaffected — intended per §5.4.
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

    /// Whether the panel currently offers the user a drag-resize handle/cursor.
    /// The surface turns this off ONCE at construction (one fixed frame for
    /// every screen, never per screen) — the shell just keeps the seam so it
    /// stays content-agnostic. Only the `.resizable` bit moves —
    /// `.titled`/`.closable` never do (R6), and `.resizable` is not one of
    /// them, so this is independent of the pin-profile manner bits
    /// `applyPinProfile()` owns.
    public func setUserResizable(_ resizable: Bool) {
        guard let panel = window else { return }
        if resizable {
            panel.styleMask.insert(.resizable)
        } else {
            panel.styleMask.remove(.resizable)
        }
    }

    /// Whether the panel's style mask currently carries `.resizable`, for
    /// structural assertions.
    public var isUserResizable: Bool {
        window?.styleMask.contains(.resizable) ?? false
    }

    /// The panel's pre-dispatch key-equivalent hook (see `ControlPanelPanel`).
    /// The surface installs its ⌘1/⌘2/⌘3 screen shortcuts here; the shell
    /// itself attaches no meaning to any key.
    public var keyEquivalentHandler: ((NSEvent) -> Bool)? {
        get { (window as? ControlPanelPanel)?.keyEquivalentHandler }
        set { (window as? ControlPanelPanel)?.keyEquivalentHandler = newValue }
    }

    /// Whether the panel is currently on screen, as opposed to tucked away by
    /// `hidesOnDeactivate` after an app-switch. The status-item click handler
    /// reads this to decide between toggling a live panel CLOSED and restoring
    /// a tucked-away one — see `AppDelegate`'s `onButtonClicked`.
    ///
    /// Honors `test_isPanelVisibleOverride` so headless tests can drive the
    /// on-screen-only paths (`swift test` never orders a real window on
    /// screen), mirroring `PopoverController.test_isShownOverride` and
    /// `MixerWindowController.test_isVisibleOverride`.
    public var isPanelVisible: Bool { test_isPanelVisibleOverride ?? (window?.isVisible ?? false) }

    /// Close the panel exactly as the ✕ button or Escape would: routed through
    /// `performClose(_:)` so `windowWillClose` → `onClose` fires and the app
    /// lands home on the popover. The status-item toggle-close uses this rather
    /// than a bare `close()`/`orderOut`, which would skip the land-home contract.
    public func performClose() {
        window?.performClose(nil)
    }

    /// Whether the panel closed ITSELF by resigning key within the last
    /// `interval`, consuming that fact so it can only ever be read once.
    ///
    /// This is the R1 status-click race guard. The status item's click is
    /// EXACTLY the click that makes an unpinned panel resign key, and AppKit
    /// delivers the resign (→ close) BEFORE the button's action fires. The
    /// action then looks at a closed panel, concludes "it wasn't open", and
    /// reopens it — the panel can never be toggled shut from the menu bar, it
    /// just flickers. So the click handler asks this first: a `true` means
    /// "the click you are handling is what dismissed me — do nothing", a
    /// `false` means "I was already closed — open me".
    ///
    /// Consuming on ANY call (stale or fresh) is deliberate: a leftover stamp
    /// must never survive to swallow a later, unrelated click.
    @discardableResult
    public func consumeRecentResignDismissal(
        within interval: TimeInterval = ControlPanelWindowController.recentResignDismissalInterval
    ) -> Bool {
        guard let stamp = lastResignDismissalTime else { return false }
        lastResignDismissalTime = nil
        return CACurrentMediaTime() - stamp <= interval
    }

    /// Bring the app forward so the panel can actually take key.
    ///
    /// `NSApp.activate()` — the macOS 14+ cooperative form — is DECLINED when
    /// the app is not already frontmost, which is exactly the state a menu-bar
    /// status-item click leaves us in. Measured in a Developer ID signed bundle
    /// (2026-08-30): after `show(anchorRect:)` had called it plus
    /// `makeKeyAndOrderFront`, the panel still reported
    /// `key=false appActive=false`. The panel then renders its whole header in
    /// the unfocused appearance forever — every control at ~1.2:1 instead of
    /// ~3.3:1, and the brand mark's gold washed to grey. Alec reported it as
    /// "the header is always in a dismissed state", in the notarised build too.
    ///
    /// `activate(ignoringOtherApps:)` is deprecated but is NOT refusable, and
    /// is the only form that reliably fronts an `.accessory` app from its own
    /// status item. We ask for it only in response to a user gesture that
    /// opened the surface, which is what the API is for.
    private static func activateForSurface() {
        NSApp?.activate(ignoringOtherApps: true)
    }

    /// Show the panel anchored just under `anchorRect` (the menu-bar status
    /// item's frame, in screen coordinates); `nil` centers it.
    ///
    /// The panel is CENTERED on the anchor's midX, like `NSPopover` (see
    /// the body comment for why edge-pinning was rejected), clamped fully
    /// on screen. The backing window is kept in lockstep (same x/width,
    /// `beakHeight` taller) and its beak tip repositioned to track wherever
    /// the anchor actually ends up after clamping.
    /// Pinned, this degrades to a plain front-and-focus: an ordinary window
    /// belongs wherever the user left it (or wherever its autosaved frame
    /// restored it to), it has no beak to keep in lockstep, and a re-front is
    /// not an appearance so it does not re-fade. The anchor is still recorded
    /// so a later un-pin has something to re-anchor to.
    public func show(anchorRect: NSRect?) {
        guard let panel = window else { return }
        lastAnchorRect = anchorRect
        panel.contentView?.layoutSubtreeIfNeeded()

        if isPinned {
            if !HeadlessRuntime.isActive {
                Self.activateForSurface()
                panel.makeKeyAndOrderFront(nil)
            }
            return
        }

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
            // Clamp against the ANCHOR's own display, not the panel's. On a
            // multi-display Mac the panel is still wherever it last was (or
            // nowhere at all) when this runs, so `panel.screen` could clamp a
            // menu-bar item on the second display against the first one's
            // frame and pull the bubble off its own beak.
            if let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) })
                ?? panel.screen ?? NSScreen.main {
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
            Self.activateForSurface()
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

    /// `nil` = read the real `window.isVisible`. `swift test` never orders a
    /// window on screen, so the on-screen-only paths (close-on-resign, the
    /// un-pin re-anchor) are unreachable without this.
    public var test_isPanelVisibleOverride: Bool?

    /// `nil` = read the real `window.attachedSheet`. A real sheet cannot be
    /// begun headlessly without putting a window on the developer's screen.
    public var test_hasAttachedSheetOverride: Bool?

    /// `nil` = read the real `NSApp.isActive`. Test processes are not active
    /// applications, so the in-app-focus-loss path needs to be driven.
    public var test_appIsActiveOverride: Bool?

    /// `nil` = read the real `window.isKeyWindow`.
    public var test_isKeyWindowOverride: Bool?

    /// Run the deferred half of a resign-key dismissal now — the runloop pass
    /// AppKit would have given it. Tests drive both halves explicitly because a
    /// headless run has no runloop turning between them.
    public func test_settleResignDismissal() { dismissIfStillResigned() }

    /// A sheet is up (e.g. group creation). Dismissing the panel out from under
    /// it would kill the sheet mid-edit — R7. Public: the surface's click
    /// policy (`AppSurfaceController.clickAction`) reads this too, to front
    /// the window instead of attempting `performClose` (which AppKit refuses,
    /// with a beep, while a sheet is attached).
    public var hasAttachedSheet: Bool {
        test_hasAttachedSheetOverride ?? (window?.attachedSheet != nil)
    }

    /// Whether THIS app still holds activation. The discriminator between the
    /// two very different reasons a window resigns key — see
    /// `windowDidResignKey`.
    private var appIsActive: Bool { test_appIsActiveOverride ?? NSApp?.isActive ?? false }
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

    /// UNPINNED ONLY: losing key focus inside this app is a click-outside, and
    /// a transient anchored panel dismisses on one. Four conditions, each of
    /// which is a real, separate bug if dropped:
    ///
    /// 1. `!isPinned` — a pinned window is an ordinary window. Click-out must
    ///    leave it exactly where it is.
    /// 2. `isPanelVisible` — closing a window RESIGNS its key status, so this
    ///    method fires again during every ✕/Esc/`performClose` teardown.
    ///    Without the visibility gate that second pass calls `performClose`
    ///    once more and `onClose` (the "land home" contract) fires TWICE. A
    ///    panel that is not on screen also cannot have been clicked away from,
    ///    so this is the honest precondition, not just re-entrancy defense.
    /// 3. `!hasAttachedSheet` — R7: dismissing the host out from under a live
    ///    sheet destroys the sheet mid-edit.
    /// 4. `appIsActive` — the two reasons a window resigns key are NOT the
    ///    same event. Another of OUR windows taking focus (Setup, a
    ///    standalone window, the status item) is the in-app focus loss that
    ///    means "click outside the panel" → close. The user switching to
    ///    ANOTHER APP is the `hidesOnDeactivate` tuck-away, which AppKit
    ///    reverses by itself when the app comes back and which must keep
    ///    behaving exactly as it always has — a close there would mean an
    ///    app-switch silently loses the surface.
    ///
    /// The timestamp recorded before closing is the R1 race guard — see
    /// `consumeRecentResignDismissal(within:)` for what it protects against.
    ///
    /// The four conditions are evaluated TWICE: once here, and again one
    /// runloop pass later, where the panel must also still not be key. Only a
    /// key loss that SURVIVES that pass is a click-outside. One that reverses
    /// itself is this window's own AppKit chrome borrowing key and handing it
    /// straight back (a toolbar picker, a menu, field-editor churn), and this
    /// delegate method is the ONLY path that can close the surface — so an
    /// instant dismissal here tears the whole surface down for a transition
    /// the user never made. The user loses nothing to the wait: the dismissal
    /// still lands in the same runloop turn, before anything is drawn.
    public func windowDidResignKey(_ notification: Notification) {
        guard shouldDismissOnResignKey else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.dismissIfStillResigned() }
        }
    }

    /// The four conditions a resign-key dismissal requires, each documented
    /// above `windowDidResignKey`.
    private var shouldDismissOnResignKey: Bool {
        !isPinned && isPanelVisible && !hasAttachedSheet && appIsActive
    }

    private func dismissIfStillResigned() {
        guard shouldDismissOnResignKey, !isKeyNow else { return }
        lastResignDismissalTime = CACurrentMediaTime()
        window?.performClose(nil)
    }

    /// Whether the panel holds key status right now. Honors
    /// `test_isKeyWindowOverride` — `swift test` never puts a window on screen,
    /// so the real property is permanently `false` there.
    private var isKeyNow: Bool { test_isKeyWindowOverride ?? (window?.isKeyWindow ?? false) }

    /// Resync the decorative bubble/beak window when the user drags the
    /// panel's (resizable) edge. `addChildWindow` (see `init`) tracks the
    /// parent's TRANSLATION automatically but never its SIZE — confirmed by a
    /// manual AppKit probe: `setContentSize` alone left the child desynced at
    /// its old size, `setFrameOrigin` alone tracked correctly. This re-runs
    /// the same lockstep math `show(anchorRect:)` performs after ordering on
    /// screen, in the same order: resize `backingWindow` to the panel's new
    /// frame (plus `beakHeight`) FIRST — `beakFraction`'s path math reads the
    /// view's (new) `bounds.width`, so the resize has to land before it's
    /// recomputed — then recompute `beakFraction` from the remembered anchor
    /// against the new frame, then `invalidateShadow()` LAST so the shadow
    /// reflects the just-redrawn shape. `lastAnchorRect` is `nil` when the
    /// panel was last centered (no anchor to track), in which case the beak
    /// simply keeps its current fraction.
    public func windowDidResize(_ notification: Notification) {
        // Pinned: the decorative backing window is detached and off screen —
        // there is nothing to keep in lockstep, and re-framing a hidden child
        // would only risk ordering it back on screen.
        guard !isPinned, let panel = window else { return }
        panel.contentView?.layoutSubtreeIfNeeded()
        let frame = panel.frame
        backingWindow.setFrame(
            NSRect(x: frame.minX, y: frame.minY,
                  width: frame.width, height: frame.height + ControlPanelBackingView.beakHeight),
            display: true)
        if let anchor = lastAnchorRect, frame.width > 0 {
            backingView.beakFraction = (anchor.midX - frame.minX) / frame.width
        }
        backingWindow.invalidateShadow()
    }
}

// MARK: - ControlPanelPanel

/// The shell's `NSPanel`, subclassed for TWO reasons:
///
/// 1. To make Escape a deterministic close. Pressing Escape (or ⌘.) sends
///    `cancelOperation(_:)` up the responder chain; routing it to
///    `performClose(_:)` guarantees Esc closes the panel through the SAME path
///    as the close button — `windowWillClose` → `onClose` (land home) —
///    instead of relying on incidental default panel behavior.
///    `performClose(_:)` only fires when the style mask contains
///    `.titled`/`.closable` (it does — see
///    `ControlPanelWindowController.makePanel`), so this closes cleanly with no
///    system beep. A field editor still gets first crack at Escape (to cancel
///    in-progress text editing) before it reaches here.
/// 2. To offer callers a key-equivalent seam. The surface's screen shortcuts
///    (⌘1/⌘2/⌘3) used to ride `NSButton.keyEquivalent` on in-content header
///    buttons; a window-attached `NSToolbarItemGroup` carries no per-segment
///    key equivalents, so the window itself consults the injected handler
///    first. Content-agnostic: the shell knows nothing about what the keys
///    mean, and an unhandled event falls through to stock dispatch untouched.
final class ControlPanelPanel: NSPanel {
    /// Consulted before stock key-equivalent dispatch; return `true` to
    /// consume the event. Set through
    /// `ControlPanelWindowController.keyEquivalentHandler`.
    var keyEquivalentHandler: ((NSEvent) -> Bool)?

    /// The duration `animator().setFrame` resizes actually use. An NSWindow
    /// frame animation takes its duration from `animationResizeTime(_:)`, NOT
    /// from the enclosing `NSAnimationContext` — so a host animating window
    /// and content together must set this to the content's duration or the two
    /// run on different clocks no matter what the context says (live
    /// slow-motion capture 2026-08-11: content slowed 10x, window still
    /// snapped shut at AppKit's default pace). `nil` keeps the default.
    var resizeAnimationDuration: TimeInterval?

    override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval {
        resizeAnimationDuration ?? super.animationResizeTime(newFrame)
    }

    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyEquivalentHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}
