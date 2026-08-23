// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
import AppKit
@testable import AudioutPopoverUI

/// Coverage for `SurfaceToolbarController` — the one-surface header as a real
/// window-attached `NSToolbar` (live-review D1, which retired the custom
/// `PopoverHeaderView` strip and its three-tier material machinery; the
/// system toolbar owns materials and Reduce Transparency now, so no tier
/// seams remain to test). Headless: items are materialized by attaching the
/// toolbar to a never-shown window.
@MainActor
@Suite struct SurfaceToolbarTests {

    /// A controller with its toolbar attached (attachment is what makes
    /// AppKit materialize the delegate's items), on a window that never
    /// orders in.
    private func makeAttached() -> (SurfaceToolbarController, NSWindow) {
        let controller = SurfaceToolbarController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 623, height: 400),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        controller.attach(to: window)
        return (controller, window)
    }

    // MARK: Items present and ordered

    @Test func attachingMaterializesTheItemsInOrder() {
        let (controller, window) = makeAttached()
        #expect(controller.test_itemIdentifiers == [
            SurfaceToolbarController.tabsItemIdentifier,
            .flexibleSpace,
            SurfaceToolbarController.titleItemIdentifier,
            .flexibleSpace,
            SurfaceToolbarController.pinItemIdentifier,
            SurfaceToolbarController.quitItemIdentifier,
        ], "tabs lead, the app name sits centered, Pin and Quit trail")
        #expect(window.toolbar === controller.toolbar)
        #expect(window.toolbarStyle == .unified, "D1: unified — the toolbar IS the one header strip")
    }

    @Test func tabsGroupCarriesAllThreeScreensWithResolvedGlyphs() {
        let (controller, _) = makeAttached()
        #expect(controller.test_tabLabels == ["Mixer", "Groups", "Settings"])
        #expect(controller.test_allTabImagesResolved,
                "every tab segment resolved a system SF Symbol")
    }

    @Test func centeredAppNameItemExists() {
        let (controller, _) = makeAttached()
        #expect(controller.test_centeredTitleText == "Audiout",
                "the header carries the app name as a centered toolbar item (D1)")
        if #available(macOS 13.0, *) {
            #expect(controller.toolbar.centeredItemIdentifiers
                        .contains(SurfaceToolbarController.titleItemIdentifier))
        }
    }

    @Test func pinAndQuitItemsResolveGlyphs() {
        let (controller, _) = makeAttached()
        #expect(controller.test_pinItemHasImage)
        #expect(controller.test_quitItemHasImage)
    }

    // MARK: Display mode — the dead-tabs guard

    /// Icon-only is load-bearing, not cosmetic (live review 2026-08-11): under
    /// a label-showing display mode macOS 26+ builds the tab group's picker
    /// WITHOUT its interactive expanded view, and segments that render blank
    /// also swallow every click. Hence the assertion — no expanded view means
    /// dead tabs. Both classes are private AppKit, so they are matched by
    /// class NAME, never by type. It discriminates only where the break
    /// happens: a macOS 26.5 host builds the expanded view under labels too,
    /// so there this passes either way.
    @Test func theTabGroupBuildsItsInteractivePicker() {
        guard #available(macOS 26, *) else { return }
        let (_, window) = makeAttached()
        guard let themeFrame = window.contentView?.superview else {
            Issue.record("no theme frame to search — the window built no chrome")
            return
        }
        themeFrame.layoutSubtreeIfNeeded()

        guard let picker = firstView(in: themeFrame, named: "NSToolbarItemGroupPickerView") else {
            Issue.record("the tab group materialized no picker view at all")
            return
        }
        #expect(picker.subviews.contains {
            String(describing: type(of: $0)).contains("NSToolbarItemGroupPickerExpandedView")
        }, "no expanded view under the picker — the tabs would render blank and eat every click")
    }

    /// First view in `root`'s subtree whose class name contains `name`.
    private func firstView(in root: NSView, named name: String) -> NSView? {
        if String(describing: type(of: root)).contains(name) { return root }
        for subview in root.subviews {
            if let hit = firstView(in: subview, named: name) { return hit }
        }
        return nil
    }

    // MARK: Selection — host-confirmed round trip

    @Test func tabTapsReportTheScreenButDoNotSelfSelect() {
        // The host owns selection, same contract as the retired header: a tap
        // fires the callback with the right screen, and with no confirming
        // `setSelectedScreen` the segmented state snaps back to the confirmed
        // selection. NOTE: `test_selectTab` runs the action directly — it
        // proves the callback contract, never that a real click reaches it
        // (that is the picker guard above).
        let (controller, _) = makeAttached()
        var reported: [SurfaceScreen] = []
        controller.onSelectScreen = { reported.append($0) }

        controller.test_selectTab(.groups)
        controller.test_selectTab(.settings)

        #expect(reported == [.groups, .settings])
        #expect(controller.selectedScreen == .mixer, "selection unchanged until the host confirms")
        #expect(controller.test_selectedTabIndex == SurfaceScreen.mixer.rawValue,
                "the group snapped back to the host-confirmed segment")
    }

    @Test func hostConfirmedSelectionMovesTheSegment() {
        let (controller, _) = makeAttached()
        #expect(controller.test_selectedTabIndex == SurfaceScreen.mixer.rawValue,
                "Mixer starts selected")

        controller.setSelectedScreen(.settings)

        #expect(controller.selectedScreen == .settings)
        #expect(controller.test_selectedTabIndex == SurfaceScreen.settings.rawValue)
    }

    @Test func aConfirmingHostKeepsTheTappedSegment() {
        // The live wiring: the host's callback calls setSelectedScreen
        // synchronously, so the tapped segment stays.
        let (controller, _) = makeAttached()
        controller.onSelectScreen = { controller.setSelectedScreen($0) }

        controller.test_selectTab(.groups)

        #expect(controller.selectedScreen == .groups)
        #expect(controller.test_selectedTabIndex == SurfaceScreen.groups.rawValue)
    }

    // MARK: Pin / Quit

    @Test func pinAndQuitFireTheirCallbacks() {
        let (controller, _) = makeAttached()
        var pinned = false
        var quit = false
        controller.onTogglePin = { pinned = true }
        controller.onQuit = { quit = true }

        controller.test_tapPin()
        controller.test_tapQuit()

        #expect(pinned)
        #expect(quit)
    }

    @Test func pinItemReflectsThePinnedState() {
        let (controller, _) = makeAttached()
        #expect(!controller.isPinned)
        #expect(controller.test_pinItemLabel == "Pin")

        controller.setPinned(true)
        #expect(controller.isPinned)
        #expect(controller.test_pinItemLabel == "Unpin")
        #expect(controller.test_pinItemHasImage, "pin.fill resolved for the pinned state")

        controller.setPinned(false)
        #expect(controller.test_pinItemLabel == "Pin")
    }
}
