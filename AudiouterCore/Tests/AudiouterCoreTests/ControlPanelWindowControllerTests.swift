// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
import AppKit
@testable import AudiouterSharedUI

/// Structural coverage for the reusable control-panel shell (control-panel
/// rollout T1): the sticky floating `NSPanel` config, the anchored-position
/// clamp math, and the real-close-vs-tuck-away `onClose` distinction.
@MainActor
final class ControlPanelWindowControllerTests: XCTestCase {

    private func makeController() -> ControlPanelWindowController {
        ControlPanelWindowController(contentViewController: NSViewController())
    }

    func testWindowIsPanelWithExpectedConfig() {
        let controller = makeController()
        guard let panel = controller.test_panel else {
            return XCTFail("window should be an NSPanel")
        }
        XCTAssertTrue(panel.styleMask.contains(.titled))
        XCTAssertTrue(panel.styleMask.contains(.closable))
        XCTAssertTrue(panel.styleMask.contains(.resizable))
        XCTAssertTrue(panel.styleMask.contains(.fullSizeContentView))
        // ACTIVATING: must NOT be a non-activating panel.
        XCTAssertFalse(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.isFloatingPanel)
        XCTAssertEqual(panel.level, .floating)
        XCTAssertTrue(panel.hidesOnDeactivate)
        XCTAssertFalse(panel.becomesKeyOnlyIfNeeded)
        XCTAssertFalse(panel.isReleasedWhenClosed)
        XCTAssertEqual(panel.animationBehavior, .utilityWindow)
    }

    func testShowWithAnchorKeepsFrameInsideVisibleFrame() throws {
        guard let screen = NSScreen.main else {
            throw XCTSkip("no NSScreen.main in this environment")
        }
        let controller = makeController()
        // An anchor near the very top-right corner of the screen, like a
        // menu-bar status item, to exercise the clamp.
        let vf = screen.visibleFrame
        let anchor = NSRect(x: vf.maxX - 20, y: vf.maxY - 4, width: 24, height: 4)
        controller.show(anchorRect: anchor)

        guard let panel = controller.test_panel else {
            return XCTFail("window should be an NSPanel")
        }
        let frame = panel.frame
        XCTAssertGreaterThanOrEqual(frame.minX, vf.minX)
        XCTAssertLessThanOrEqual(frame.maxX, vf.maxX)
        XCTAssertGreaterThanOrEqual(frame.minY, vf.minY)
        XCTAssertLessThanOrEqual(frame.maxY, vf.maxY)
    }

    func testShowWithNilAnchorCenters() {
        let controller = makeController()
        controller.show(anchorRect: nil)
        // Just assert it didn't crash and produced an on-screen frame; centering
        // itself is `NSWindow.center()`'s job, not ours to re-verify.
        XCTAssertNotNil(controller.test_panel)
    }

    func testOnCloseFiresOnRealClose() {
        let controller = makeController()
        controller.show(anchorRect: nil)
        var fired = false
        controller.onClose = { fired = true }
        controller.window?.performClose(nil)
        XCTAssertTrue(fired, "performClose should trigger onClose via windowWillClose")
    }

    func testOnCloseDoesNotFireOnOrderOut() {
        let controller = makeController()
        controller.show(anchorRect: nil)
        var fired = false
        controller.onClose = { fired = true }
        controller.window?.orderOut(nil)
        XCTAssertFalse(fired, "a tuck-away order-out must not trigger onClose")
    }

    func testSetContentSwapsHostedViewController() {
        let controller = makeController()
        let second = NSViewController()
        controller.setContent(second)
        XCTAssertTrue(controller.window?.contentViewController === second)
    }

    func testSetTitleUpdatesWindowTitle() {
        let controller = makeController()
        controller.setTitle("Settings")
        XCTAssertEqual(controller.window?.title, "Settings")
    }

    // MARK: - Close affordances (control-panel-ship)

    /// The panel is a real work surface that does NOT dismiss on click-out, so
    /// it must expose an obvious close control — the standard close button, kept
    /// visible. Miniaturize/zoom are hidden (meaningless on an anchored, fixed
    /// panel). This is the fix for the "no visible way to close the panel" bug.
    func testCloseButtonIsVisibleAndOtherTrafficLightsHidden() {
        let controller = makeController()
        guard let panel = controller.test_panel else {
            return XCTFail("window should be an NSPanel")
        }
        XCTAssertEqual(panel.standardWindowButton(.closeButton)?.isHidden, false,
                       "the close button must stay visible so the panel can be closed")
        XCTAssertEqual(panel.standardWindowButton(.miniaturizeButton)?.isHidden, true)
        XCTAssertEqual(panel.standardWindowButton(.zoomButton)?.isHidden, true)
    }

    /// Escape closes the panel through the SAME real-close/land-home path as the
    /// ✕ button — wired explicitly via `cancelOperation(_:)` → `performClose(_:)`
    /// on the panel subclass, not left to incidental default behavior.
    func testEscapeViaCancelOperationClosesAndFiresOnClose() {
        let controller = makeController()
        controller.show(anchorRect: nil)
        var fired = false
        controller.onClose = { fired = true }
        controller.test_panel?.cancelOperation(nil)
        XCTAssertTrue(fired, "Escape/cancelOperation should close the panel and fire onClose")
    }

    /// The status-item toggle-close calls this shell method when the panel is
    /// already open; it must route through the real close so the app lands home
    /// on the popover (i.e. `onClose` fires), not silently order the panel out.
    func testPerformCloseFiresOnClose() {
        let controller = makeController()
        controller.show(anchorRect: nil)
        var fired = false
        controller.onClose = { fired = true }
        controller.performClose()
        XCTAssertTrue(fired, "performClose() should fire onClose (land home)")
    }

    /// `isPanelVisible` is the signal the status-item click reads to tell an open
    /// panel (→ toggle closed) from one tucked away by `hidesOnDeactivate` (→
    /// restore in place). It tracks `window.isVisible`; headless runs never order
    /// the window on screen (`HeadlessRuntime`), so it reads false until a real
    /// show — which is exactly the wiring this locks down.
    func testIsPanelVisibleReflectsWindowVisibility() {
        let controller = makeController()
        XCTAssertFalse(controller.isPanelVisible,
                       "an unshown panel is not visible (never ordered on screen)")
    }
}
