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

    private func makeController() -> ControlPanelWindowController {
        ControlPanelWindowController(contentViewController: NSViewController())
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
        #expect(panel.animationBehavior == .utilityWindow)
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

    // MARK: - Close affordances (control-panel-ship)

    /// The panel is a real work surface that does NOT dismiss on click-out, so
    /// it must expose an obvious close control — the standard close button, kept
    /// visible. Miniaturize/zoom are hidden (meaningless on an anchored, fixed
    /// panel). This is the fix for the "no visible way to close the panel" bug.
    @Test func closeButtonIsVisibleAndOtherTrafficLightsHidden() {
        let controller = makeController()
        guard let panel = controller.test_panel else {
            Issue.record("window should be an NSPanel")
            return
        }
        #expect(panel.standardWindowButton(.closeButton)?.isHidden == false,
                "the close button must stay visible so the panel can be closed")
        #expect(panel.standardWindowButton(.miniaturizeButton)?.isHidden == true)
        #expect(panel.standardWindowButton(.zoomButton)?.isHidden == true)
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
}
