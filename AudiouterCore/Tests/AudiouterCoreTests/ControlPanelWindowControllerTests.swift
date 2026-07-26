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
}
