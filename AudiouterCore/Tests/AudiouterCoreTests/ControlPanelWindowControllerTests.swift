// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import AppKit
@testable import AudiouterSharedUI

/// Whether this environment has a real `NSScreen.main` — knowable at
/// discovery time, unlike a skip that depends on state built up mid-test.
/// See the cookbook's "awkward case" section for why this is hoisted into a
/// suite-level trait rather than checked inside a test body.
enum ScreenGate {
    static let hasMainScreen = NSScreen.main != nil
}

/// Structural coverage for the reusable control-panel shell (control-panel
/// rollout T1): the sticky floating `NSPanel` config, the anchored-position
/// clamp math, and the real-close-vs-tuck-away `onClose` distinction.
@MainActor
@Suite(.enabled(if: ScreenGate.hasMainScreen, "no NSScreen.main in this environment"))
struct ControlPanelWindowControllerTests {

    /// Never the shipping `"ControlPanelSurface"` autosave name: AppKit's
    /// `setFrameAutosaveName` always persists into the standard defaults
    /// regardless of any suite, so a test that pins under the real key would
    /// write the developer's own saved surface position. Tests that actually
    /// arm autosave pass a unique name and clear it — see `uniqueAutosaveName`.
    private func makeController(
        frameAutosaveName: NSWindow.FrameAutosaveName = "ControlPanelSurfaceTests"
    ) -> ControlPanelWindowController {
        ControlPanelWindowController(contentViewController: NSViewController(),
                                     frameAutosaveName: frameAutosaveName)
    }

    /// A collision-proof autosave name, so two pinning tests (or two runs)
    /// can't read back each other's saved frame — the same per-test-instance
    /// key `MixerWindowControllerTests` uses for the window it pins.
    private func uniqueAutosaveName() -> NSWindow.FrameAutosaveName {
        NSWindow.FrameAutosaveName("ControlPanelSurfaceTests-\(UUID().uuidString)")
    }

    private func clearSavedFrame(_ name: NSWindow.FrameAutosaveName) {
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(name)") // isolation-ok: unique per-test key, AppKit forces this suite
    }

    /// The resign-key notification AppKit would deliver. The harness can't make
    /// a window key without putting it on the developer's real screen, so the
    /// delegate method is called directly — the same seam style the existing
    /// close tests use (`cancelOperation(nil)`, `performClose(nil)`).
    private func resignKey(_ controller: ControlPanelWindowController) {
        controller.windowDidResignKey(
            Notification(name: NSWindow.didResignKeyNotification, object: controller.window))
    }

    /// Put a controller in the state a live unpinned panel is in when the user
    /// clicks somewhere else in this app: on screen, app still active, no sheet.
    private func makeDismissableController() -> ControlPanelWindowController {
        let controller = makeController()
        controller.test_isPanelVisibleOverride = true
        controller.test_appIsActiveOverride = true
        controller.test_hasAttachedSheetOverride = false
        return controller
    }

    @Test func windowIsPanelWithExpectedConfig() {
        let controller = makeController()
        guard let panel = controller.test_panel else {
            Issue.record("window should be an NSPanel")
            return
        }
        #expect(panel.styleMask.contains(.titled))
        #expect(panel.styleMask.contains(.closable))
        #expect(panel.styleMask.contains(.resizable))
        #expect(panel.styleMask.contains(.fullSizeContentView))
        // ACTIVATING: must NOT be a non-activating panel.
        #expect(!panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.isFloatingPanel)
        #expect(panel.level == .floating)
        #expect(panel.hidesOnDeactivate)
        #expect(!panel.becomesKeyOnlyIfNeeded)
        #expect(!panel.isReleasedWhenClosed)
        // Decided policy (P3/W7): menu-bar app, no window restoration.
        #expect(!panel.isRestorable)
        #expect(panel.animationBehavior == .utilityWindow)
    }

    /// F3: `setUserResizable` toggles ONLY the `.resizable` bit — the surface
    /// uses it per-screen (exact-fit screens off, Groups on), and R6's
    /// protected bits (`.titled`/`.closable`) must survive untouched either
    /// way, same as a pin-profile flip.
    @Test func userResizableTogglesOnlyThatBitBothDirections() throws {
        let controller = makeController()
        let panel = try #require(controller.test_panel)
        #expect(controller.isUserResizable, "fresh panel starts resizable (Groups is the default)")

        controller.setUserResizable(false)
        #expect(!controller.isUserResizable)
        #expect(!panel.styleMask.contains(.resizable))
        #expect(panel.styleMask.contains(.titled))
        #expect(panel.styleMask.contains(.closable))
        #expect(panel.styleMask.contains(.fullSizeContentView))

        controller.setUserResizable(true)
        #expect(controller.isUserResizable)
        #expect(panel.styleMask.contains(.resizable))
        #expect(panel.styleMask.contains(.titled))
        #expect(panel.styleMask.contains(.closable))
    }

    @Test func showWithAnchorKeepsFrameInsideVisibleFrame() throws {
        let screen = try #require(NSScreen.main)
        let controller = makeController()
        // An anchor near the very top-right corner of the screen, like a
        // menu-bar status item, to exercise the clamp.
        let vf = screen.visibleFrame
        let anchor = NSRect(x: vf.maxX - 20, y: vf.maxY - 4, width: 24, height: 4)
        controller.show(anchorRect: anchor)

        let panel = try #require(controller.test_panel, "window should be an NSPanel")
        let frame = panel.frame
        #expect(frame.minX >= vf.minX)
        #expect(frame.maxX <= vf.maxX)
        #expect(frame.minY >= vf.minY)
        #expect(frame.maxY <= vf.maxY)
    }

    @Test func showWithNilAnchorCenters() {
        let controller = makeController()
        controller.show(anchorRect: nil)
        // Just assert it didn't crash and produced an on-screen frame; centering
        // itself is `NSWindow.center()`'s job, not ours to re-verify.
        #expect(controller.test_panel != nil)
    }

    @Test func onCloseFiresOnRealClose() {
        let controller = makeController()
        controller.show(anchorRect: nil)
        var fired = false
        controller.onClose = { fired = true }
        controller.window?.performClose(nil)
        #expect(fired, "performClose should trigger onClose via windowWillClose")
    }

    @Test func onCloseDoesNotFireOnOrderOut() {
        let controller = makeController()
        controller.show(anchorRect: nil)
        var fired = false
        controller.onClose = { fired = true }
        controller.window?.orderOut(nil)
        #expect(!fired, "a tuck-away order-out must not trigger onClose")
    }

    @Test func setContentSwapsHostedViewController() {
        let controller = makeController()
        let second = NSViewController()
        controller.setContent(second)
        #expect(controller.window?.contentViewController === second)
    }

    @Test func setTitleUpdatesWindowTitle() {
        let controller = makeController()
        controller.setTitle("Settings")
        #expect(controller.window?.title == "Settings")
    }

    // MARK: - Close affordances (control-panel-ship, revised by live-review D1)

    /// Owner decision 2026-08-07: the transient bubble hides ALL standard
    /// buttons (Escape and the menu-bar toggle close it); pinning shows the
    /// standard close button, an ordinary window's close affordance.
    /// Miniaturize/zoom stay hidden in both profiles (neither is in the style
    /// mask — dead chrome).
    @Test func standardButtonsFollowThePinProfile() throws {
        let name = uniqueAutosaveName()
        defer { clearSavedFrame(name) }
        let controller = makeController(frameAutosaveName: name)
        let panel = try #require(controller.test_panel)

        #expect(panel.standardWindowButton(.closeButton)?.isHidden == true,
                "unpinned: the bubble carries no traffic lights")
        #expect(panel.standardWindowButton(.miniaturizeButton)?.isHidden == true)
        #expect(panel.standardWindowButton(.zoomButton)?.isHidden == true)

        controller.setPinned(true)
        #expect(panel.standardWindowButton(.closeButton)?.isHidden == false,
                "pinned: an ordinary window shows its close button")
        #expect(panel.standardWindowButton(.miniaturizeButton)?.isHidden == true)
        #expect(panel.standardWindowButton(.zoomButton)?.isHidden == true)

        controller.setPinned(false)
        #expect(panel.standardWindowButton(.closeButton)?.isHidden == true,
                "un-pinning hides it again")
    }

    /// The window-attached toolbar's ⌘-shortcut seam (live-review D1): the
    /// panel consults the injected handler before stock dispatch, and an
    /// unhandled event falls through untouched.
    @Test func keyEquivalentHandlerIsConsultedBeforeStockDispatch() throws {
        let controller = makeController()
        let panel = try #require(controller.test_panel)
        var seen: [String] = []
        controller.keyEquivalentHandler = { event in
            seen.append(event.charactersIgnoringModifiers ?? "")
            return event.charactersIgnoringModifiers == "2"
        }

        func keyEvent(_ character: String) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                                          modifierFlags: [.command], timestamp: 0,
                                          windowNumber: 0, context: nil,
                                          characters: character,
                                          charactersIgnoringModifiers: character,
                                          isARepeat: false, keyCode: 0))
        }

        #expect(panel.performKeyEquivalent(with: try keyEvent("2")),
                "a handled event is consumed")
        #expect(!panel.performKeyEquivalent(with: try keyEvent("9")),
                "an unhandled event falls through to stock dispatch")
        #expect(seen == ["2", "9"], "the handler saw both, in order")
    }

    /// Escape closes the panel through the SAME real-close/land-home path as the
    /// ✕ button — wired explicitly via `cancelOperation(_:)` → `performClose(_:)`
    /// on the panel subclass, not left to incidental default behavior.
    @Test func escapeViaCancelOperationClosesAndFiresOnClose() {
        let controller = makeController()
        controller.show(anchorRect: nil)
        var fired = false
        controller.onClose = { fired = true }
        controller.test_panel?.cancelOperation(nil)
        #expect(fired, "Escape/cancelOperation should close the panel and fire onClose")
    }

    /// The status-item toggle-close calls this shell method when the panel is
    /// already open; it must route through the real close so the app lands home
    /// on the popover (i.e. `onClose` fires), not silently order the panel out.
    @Test func performCloseFiresOnClose() {
        let controller = makeController()
        controller.show(anchorRect: nil)
        var fired = false
        controller.onClose = { fired = true }
        controller.performClose()
        #expect(fired, "performClose() should fire onClose (land home)")
    }

    /// `isPanelVisible` is the signal the status-item click reads to tell an open
    /// panel (→ toggle closed) from one tucked away by `hidesOnDeactivate` (→
    /// restore in place). It tracks `window.isVisible`; headless runs never order
    /// the window on screen (`HeadlessRuntime`), so it reads false until a real
    /// show — which is exactly the wiring this locks down.
    @Test func isPanelVisibleReflectsWindowVisibility() {
        let controller = makeController()
        #expect(!controller.isPanelVisible,
                "an unshown panel is not visible (never ordered on screen)")
    }

    // MARK: - Sizing + resize lockstep (warm-signal-screens-followup)

    /// `windowDidResize` is the fix for the bubble/beak backing window
    /// desyncing the moment the user drags the (`.resizable`) panel's edge —
    /// `addChildWindow` tracks the parent's translation but never its size.
    /// Dragging the panel bigger must keep the backing window's origin/width
    /// matching the panel exactly, and its height exactly `beakHeight` taller.
    @Test func backingWindowStaysInLockstepAcrossResize() {
        let controller = makeController()
        let anchor = NSRect(x: 700, y: 800, width: 24, height: 22)
        controller.show(anchorRect: anchor)
        guard let panel = controller.test_panel, let backing = controller.test_backingWindow else {
            Issue.record("expected both the panel and its backing window")
            return
        }

        var resized = panel.frame
        resized.size.width += 120
        resized.size.height += 90
        panel.setFrame(resized, display: true)
        panel.contentView?.layoutSubtreeIfNeeded()

        #expect(backing.frame.minX == panel.frame.minX)
        #expect(backing.frame.minY == panel.frame.minY)
        #expect(backing.frame.width == panel.frame.width)
        #expect(backing.frame.height == panel.frame.height + ControlPanelBackingView.beakHeight,
                "the backing window must stay exactly beakHeight taller than the resized panel")
    }

    /// `setContent`'s `defaultSize:` must seed a size only on a content
    /// controller's FIRST mount — re-hosting content that was mounted before
    /// (even with a different `defaultSize:` argument) is a pure content
    /// swap and must never stomp whatever size is current, including a size
    /// the user dragged in between.
    @Test func secondMountOfSameContentDoesNotResetDraggedSize() {
        let groups = NSViewController()
        let controller = ControlPanelWindowController(contentViewController: groups)
        guard let panel = controller.test_panel else {
            Issue.record("expected a panel")
            return
        }
        #expect(panel.frame.size == NSSize(width: 720, height: 460),
                "first mount of the init-time content applies setContent's default size")

        // The user drags the panel to a custom size.
        var dragged = panel.frame
        dragged.size = NSSize(width: 850, height: 640)
        panel.setFrame(dragged, display: true)

        // Hosting different (never-before-mounted) content applies ITS
        // first-mount default size, as expected.
        let settings = NSViewController()
        controller.setContent(settings, defaultSize: NSSize(width: 500, height: 400))
        #expect(panel.frame.size == NSSize(width: 500, height: 400))

        // Re-hosting `groups` — already mounted once before — must be a pure
        // swap: it must NOT re-apply its defaultSize: argument and stomp the
        // size settings left current.
        controller.setContent(groups, defaultSize: NSSize(width: 720, height: 460))
        #expect(panel.frame.size == NSSize(width: 500, height: 400),
                "re-hosting previously-mounted content must not reset the panel's size")
    }

    // MARK: - Manner profiles (U1)

    /// A fresh shell wears the UNPINNED profile: an anchored, non-movable
    /// bubble that paints nothing itself (the decorative backing window behind
    /// it draws the bubble and shadow). The floating/level/tuck-away bits of
    /// the same profile are `windowIsPanelWithExpectedConfig`'s, not repeated
    /// here.
    @Test func freshShellIsUnpinned() throws {
        let controller = makeController()
        let panel = try #require(controller.test_panel)

        #expect(!controller.isPinned)
        #expect(!panel.isMovable)
        #expect(panel.titlebarAppearsTransparent)
        #expect(panel.titleVisibility == .hidden)
        #expect(!panel.isOpaque)
        #expect(!panel.hasShadow)
        #expect(controller.test_backingWindow?.parent === panel,
                "the decorative beak/bubble window is attached while unpinned")
    }

    /// Pinning flips EVERY manner bit to the ordinary-window profile: movable,
    /// normal level, survives an app-switch, the system toolbar-strip material
    /// (the title-bar TEXT stays hidden in both profiles — the one header is
    /// the surface's toolbar, D1), and it paints/shadows itself now that the
    /// decorative bubble is detached.
    @Test func pinningFlipsEveryMannerBit() throws {
        let name = uniqueAutosaveName()
        defer { clearSavedFrame(name) }
        let controller = makeController(frameAutosaveName: name)
        let panel = try #require(controller.test_panel)

        controller.setPinned(true)

        #expect(controller.isPinned)
        #expect(!panel.isFloatingPanel)
        #expect(panel.level == .normal)
        #expect(!panel.hidesOnDeactivate, "a pinned window may sit behind other apps")
        #expect(panel.isMovable)
        #expect(!panel.titlebarAppearsTransparent)
        #expect(panel.titleVisibility == .hidden,
                "no separate title bar ever — D1; the toolbar is the one strip")
        #expect(panel.isOpaque, "with the bubble gone the window has to paint itself")
        #expect(panel.hasShadow)
        #expect(controller.test_backingWindow?.parent == nil,
                "the beak/bubble window is detached while pinned")
    }

    /// Un-pinning restores every one of those bits — the flip is symmetric, so
    /// a pin/unpin round trip leaves the shell exactly as it started.
    @Test func unpinningRestoresEveryMannerBit() throws {
        let name = uniqueAutosaveName()
        defer { clearSavedFrame(name) }
        let controller = makeController(frameAutosaveName: name)
        let panel = try #require(controller.test_panel)

        controller.setPinned(true)
        controller.setPinned(false)

        #expect(!controller.isPinned)
        #expect(panel.isFloatingPanel)
        #expect(panel.level == .floating)
        #expect(panel.hidesOnDeactivate)
        #expect(!panel.isMovable)
        #expect(panel.titlebarAppearsTransparent)
        #expect(panel.titleVisibility == .hidden)
        #expect(!panel.isOpaque)
        #expect(!panel.hasShadow)
        #expect(controller.test_backingWindow?.parent === panel,
                "the beak/bubble window is re-attached on un-pin")
    }

    /// R6, the rule the whole flip is built around: the profile changes
    /// APPEARANCE bits only. `.titled`/`.closable` must survive both profiles,
    /// because `performClose(_:)` silently no-ops — no `windowWillClose`, no
    /// `onClose`, no Escape — on a window whose style mask lacks `.titled`.
    /// Asserting the mask alone would pass against a mask that was flipped and
    /// flipped back, so this also proves the close path still WORKS while
    /// pinned.
    @Test func styleMaskAndCloseContractSurviveBothProfiles() throws {
        let name = uniqueAutosaveName()
        defer { clearSavedFrame(name) }
        let controller = makeController(frameAutosaveName: name)
        let panel = try #require(controller.test_panel)

        controller.setPinned(true)
        #expect(panel.styleMask.contains(.titled))
        #expect(panel.styleMask.contains(.closable))

        var fired = false
        controller.onClose = { fired = true }
        panel.cancelOperation(nil)   // Escape, while pinned
        #expect(fired, "Escape must still close through windowWillClose while pinned")

        controller.setPinned(false)
        #expect(panel.styleMask.contains(.titled))
        #expect(panel.styleMask.contains(.closable))
    }

    /// Frame autosave is armed ONLY while pinned. An unpinned panel is
    /// positioned by its status-item anchor on every show, so persisting its
    /// frame would be meaningless at best and would fight the anchor at worst.
    @Test func frameAutosaveIsArmedOnlyWhilePinned() throws {
        let name = uniqueAutosaveName()
        defer { clearSavedFrame(name) }
        let controller = makeController(frameAutosaveName: name)
        let panel = try #require(controller.test_panel)

        controller.setPinned(true)
        #expect(panel.frameAutosaveName == name,
                "pinned: the window remembers where the user put it")

        controller.setPinned(false)
        #expect(panel.frameAutosaveName == "",
                "un-pinning disarms autosave so the re-anchor isn't written back")
    }

    /// A pinned window is an ordinary window: showing it fronts it wherever it
    /// already is (or wherever its saved frame restored it to) and never drags
    /// it back under the status item.
    @Test func showDoesNotReanchorWhilePinned() throws {
        let name = uniqueAutosaveName()
        defer { clearSavedFrame(name) }
        let controller = makeController(frameAutosaveName: name)
        let panel = try #require(controller.test_panel)
        let screen = try #require(NSScreen.main)

        controller.setPinned(true)
        let moved = NSRect(x: 120, y: 140, width: panel.frame.width, height: panel.frame.height)
        panel.setFrame(moved, display: false)

        let vf = screen.visibleFrame
        controller.show(anchorRect: NSRect(x: vf.maxX - 20, y: vf.maxY - 4, width: 24, height: 4))

        #expect(panel.frame == moved, "a pinned window stays where the user left it")
    }

    /// Un-pinning an ON-SCREEN panel re-anchors it under the status item
    /// immediately, rather than leaving it wherever it was dragged until the
    /// next show: it grows its beak back the instant it unpins, and a beak
    /// pointing at nothing (from a window nowhere near the menu bar) is not a
    /// state the surface may ever be in.
    @Test func unpinningWhileVisibleReanchorsImmediately() throws {
        let name = uniqueAutosaveName()
        defer { clearSavedFrame(name) }
        let controller = makeController(frameAutosaveName: name)
        let panel = try #require(controller.test_panel)
        let screen = try #require(NSScreen.main)

        let vf = screen.visibleFrame
        let anchor = NSRect(x: vf.midX, y: vf.maxY - 4, width: 24, height: 4)
        controller.show(anchorRect: anchor)
        let anchored = panel.frame

        controller.setPinned(true)
        panel.setFrame(NSRect(x: 120, y: 140, width: anchored.width, height: anchored.height),
                       display: false)

        controller.test_isPanelVisibleOverride = true
        controller.setPinned(false)

        #expect(panel.frame == anchored,
                "un-pinning an on-screen panel puts it back under the status item")
    }

    /// The beak/bubble lockstep is an UNPINNED-only contract: while pinned the
    /// decorative window is detached and off screen, so a resize must leave it
    /// alone rather than re-framing (and risk re-ordering) a hidden child.
    @Test func resizeLeavesTheBackingWindowAloneWhilePinned() throws {
        let name = uniqueAutosaveName()
        defer { clearSavedFrame(name) }
        let controller = makeController(frameAutosaveName: name)
        let panel = try #require(controller.test_panel)
        let backing = try #require(controller.test_backingWindow)
        controller.show(anchorRect: NSRect(x: 700, y: 800, width: 24, height: 22))

        controller.setPinned(true)
        let backingFrame = backing.frame
        var resized = panel.frame
        resized.size.width += 120
        panel.setFrame(resized, display: true)

        #expect(backing.frame == backingFrame,
                "a pinned resize must not drag the detached beak window around")
    }

    // MARK: - Click-outside dismiss + the status-click race (U1 / R1)

    /// The unpinned profile dismisses on click-out, which arrives as a
    /// resign-key. It closes for REAL (through `windowWillClose` → `onClose`),
    /// not a silent order-out, so the app still lands home.
    @Test func resignKeyDismissesUnpinnedPanel() {
        let controller = makeDismissableController()
        var fired = false
        controller.onClose = { fired = true }

        resignKey(controller)

        #expect(fired, "an unpinned panel dismisses when it loses focus in-app")
    }

    /// A pinned window is an ordinary window — clicking another window must
    /// leave it open and exactly where it is.
    @Test func resignKeyLeavesPinnedWindowOpen() {
        let name = uniqueAutosaveName()
        defer { clearSavedFrame(name) }
        let controller = makeController(frameAutosaveName: name)
        controller.test_isPanelVisibleOverride = true
        controller.test_appIsActiveOverride = true
        controller.test_hasAttachedSheetOverride = false
        controller.setPinned(true)
        var fired = false
        controller.onClose = { fired = true }

        resignKey(controller)

        #expect(!fired, "a pinned window never dismisses on click-out")
    }

    /// R7: a sheet (group creation) is attached. Dismissing the host would
    /// destroy the sheet mid-edit, so the panel stays.
    @Test func resignKeyIsSuppressedWhileASheetIsAttached() {
        let controller = makeDismissableController()
        controller.test_hasAttachedSheetOverride = true
        var fired = false
        controller.onClose = { fired = true }

        resignKey(controller)

        #expect(!fired, "a panel hosting a live sheet must not dismiss out from under it")
    }

    /// Switching to ANOTHER APP is the `hidesOnDeactivate` tuck-away, which
    /// AppKit reverses by itself on return — it is not a click-outside and must
    /// keep behaving exactly as it always has. Only in-app focus loss closes.
    @Test func resignKeyOnAppDeactivationTucksAwayInsteadOfClosing() {
        let controller = makeDismissableController()
        controller.test_appIsActiveOverride = false
        var fired = false
        controller.onClose = { fired = true }

        resignKey(controller)

        #expect(!fired, "an app-switch must stay a tuck-away, never become a close")
    }

    /// Closing a window RESIGNS its key status, so this delegate method fires
    /// again during every ✕/Esc/`performClose` teardown. Without the
    /// on-screen gate that second pass closes again and `onClose` — the whole
    /// land-home contract — fires TWICE.
    @Test func resignKeyOnAnOffScreenPanelDoesNothing() {
        let controller = makeDismissableController()
        controller.test_isPanelVisibleOverride = false
        var fires = 0
        controller.onClose = { fires += 1 }

        resignKey(controller)

        #expect(fires == 0, "a panel that isn't on screen cannot have been clicked away from")
    }

    /// R1, the status-click race. The status item's click is exactly the click
    /// that makes the panel resign key, and AppKit delivers the resign (→
    /// close) BEFORE the button's action runs — so the action must be able to
    /// tell "that click is what dismissed me" from "I was already closed",
    /// or the panel can never be toggled shut, it only flickers.
    @Test func aFreshResignDismissalIsConsumableExactlyOnce() {
        let controller = makeDismissableController()

        resignKey(controller)

        #expect(controller.consumeRecentResignDismissal(),
                "the click that dismissed the panel must be recognizable as such")
        #expect(!controller.consumeRecentResignDismissal(),
                "consuming clears it — one dismissal must never swallow two clicks")
    }

    /// A dismissal that happened outside the freshness window is somebody
    /// else's click: the handler must treat it as "I was already closed" and
    /// open the panel. Driven by the injectable interval rather than a sleep.
    @Test func aStaleResignDismissalIsNotConsumed() {
        let controller = makeDismissableController()

        resignKey(controller)

        #expect(!controller.consumeRecentResignDismissal(within: 0),
                "a dismissal older than the interval is not this click's doing")
        #expect(!controller.consumeRecentResignDismissal(),
                "a stale stamp is cleared too, so it can't ambush a later click")
    }

    /// Nothing dismissed the panel, so there is nothing to consume — the
    /// status-item click means "open me".
    @Test func noDismissalIsNeverConsumed() {
        let controller = makeController()
        #expect(!controller.consumeRecentResignDismissal())
    }

    /// A suppressed resign (pinned / sheet / app-switch) must not leave a
    /// dismissal stamp behind — the panel is still open, so a later
    /// status-item click has to be free to close it.
    @Test func aSuppressedResignRecordsNoDismissal() {
        let controller = makeDismissableController()
        controller.test_hasAttachedSheetOverride = true

        resignKey(controller)

        #expect(!controller.consumeRecentResignDismissal(),
                "nothing was dismissed, so there is nothing for a click to consume")
    }
}
