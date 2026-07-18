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
}
