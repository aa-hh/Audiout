// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
import AppKit
import AudioutSharedUI
@testable import AudioutPopoverUI

/// Coverage for `SurfaceToolbarController` — the one-surface header as a real
/// window-attached `NSToolbar` (live-review D1, which retired the custom
/// `PopoverHeaderView` strip and its three-tier material machinery; the
/// system toolbar owns materials and Reduce Transparency now, so no tier
/// seams remain to test), plus the brand header row beneath it. Headless:
/// items are materialized by attaching the toolbar to a never-shown window.
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
            SurfaceToolbarController.tabItemIdentifier(for: .mixer),
            SurfaceToolbarController.tabItemIdentifier(for: .groups),
            SurfaceToolbarController.tabItemIdentifier(for: .settings),
            .flexibleSpace,
            SurfaceToolbarController.titleItemIdentifier,
            .flexibleSpace,
            SurfaceToolbarController.pinItemIdentifier,
            .space,
            SurfaceToolbarController.quitItemIdentifier,
        ], "three separate tabs lead, the app name sits centered, Pin and Quit trail with a gap")
        #expect(controller.test_quitItemHasImage,
                "Quit carries an exit glyph, resolved on this OS")
        #expect(window.toolbar === controller.toolbar)
        #expect(window.toolbarStyle == .unified, "D1: unified — the toolbar IS the one header strip")
    }

    @Test func tabsCarryAllThreeScreensWithResolvedGlyphs() {
        let (controller, _) = makeAttached()
        #expect(controller.test_tabLabels == ["Mixer", "Groups", "Settings"])
        #expect(controller.test_allTabImagesResolved,
                "every tab resolved a system SF Symbol")
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

    @Test func theCenteredItemIsALockupWhoseMarkIsDecorative() {
        let (controller, _) = makeAttached()
        #expect(controller.test_centeredMarkHasImage,
                "the brand mark leads the wordmark")
        #expect(controller.test_centeredMarkIsDecorative,
                "the wordmark speaks the name — the mark must not say it twice")
    }

    /// The lockup's capsule is drawn by AppKit around the item's view, so its
    /// padding IS the stack's edge insets. The ends get more than the top and
    /// bottom on purpose (Alec, 2026-08-29): at equal insets the wordmark sat
    /// close enough to the glass edge to read as a cramped chip, and the
    /// horizontal axis is the one the strip height does not pin.
    @Test func theCenteredLockupBreathesInsideItsCapsule() {
        let (controller, _) = makeAttached()
        #expect(controller.test_centeredLockupHorizontalInset
                    == SurfaceToolbarController.lockupHorizontalInset)
        #expect(SurfaceToolbarController.lockupHorizontalInset
                    > SurfaceToolbarController.lockupVerticalInset,
                "the ends get more room than the strip-bound vertical axis can give")
    }

    @Test func pinAndQuitItemsResolveGlyphs() {
        let (controller, _) = makeAttached()
        #expect(controller.test_pinItemHasImage)
        #expect(controller.test_quitItemHasImage)
    }

    // MARK: No segmented separators, and clicks that really land

    /// The reason the tabs stopped being one `NSToolbarItemGroup` (live review
    /// 2026-08-29): a segmented control draws a hairline between adjacent
    /// segments and SUPPRESSES the one beside the selected segment, so the
    /// strip showed a divider that moved with the selection — one line with
    /// Mixer selected, none with Groups, one on the far side with Settings.
    /// Separate items cannot draw segment separators at all, so this asserts
    /// the structural fact that makes the dividers impossible.
    @Test func theTabsAreSeparateItemsSoNoSegmentSeparatorCanAppear() {
        let (controller, _) = makeAttached()
        let tabIdentifiers = SurfaceScreen.allCases.map(SurfaceToolbarController.tabItemIdentifier(for:))
        #expect(Set(tabIdentifiers).isSubset(of: Set(controller.test_itemIdentifiers)),
                "each screen is its own toolbar item")
        for identifier in tabIdentifiers {
            let item = controller.toolbar.items.first { $0.itemIdentifier == identifier }
            #expect(item as? NSToolbarItemGroup == nil,
                    "\(identifier.rawValue) must not be a group — a group is the segmented control whose separator moved with the selection")
        }
    }

    /// The selection has to be visible without the segmented capsule doing it
    /// for us, and it has to be visible on exactly one tab.
    @Test func onlyTheSelectedTabPaintsItsDisc() {
        let (controller, _) = makeAttached()
        #expect(controller.test_onlySelectedTabHasDisc, "Mixer starts selected, alone")

        controller.setSelectedScreen(.settings)

        #expect(controller.test_onlySelectedTabHasDisc, "the disc followed the selection")
    }

    /// The disc is neutral on purpose: gold means signal — carrying audio —
    /// and which screen you are on is chrome. Same rule that keeps the mute
    /// pill and the row washes off the gold family.
    @Test func theSelectionDiscIsNeutralNotGold() {
        #expect(SurfaceTabButton.selectionWashAlpha > 0, "the disc is actually painted")
        #expect(Tokens.Color.engagedChrome == Tokens.Color.label,
                "the disc draws in engagedChrome, which is the neutral label tone")
    }

    // MARK: Selection — host-confirmed round trip

    @Test func tabTapsReportTheScreenButDoNotSelfSelect() {
        // The host owns selection, same contract as the retired header: a tap
        // fires the callback with the right screen, and with no confirming
        // `setSelectedScreen` the tabs snap back to the confirmed selection.
        // `test_selectTab` is a REAL `performClick` through the button's own
        // target/action, so this proves the click path as well as the contract.
        let (controller, _) = makeAttached()
        var reported: [SurfaceScreen] = []
        controller.onSelectScreen = { reported.append($0) }

        controller.test_selectTab(.groups)
        controller.test_selectTab(.settings)

        #expect(reported == [.groups, .settings])
        #expect(controller.selectedScreen == .mixer, "selection unchanged until the host confirms")
        #expect(controller.test_selectedTabIndex == SurfaceScreen.mixer.rawValue,
                "the tabs snapped back to the host-confirmed screen")
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
        // synchronously, so the tapped tab stays.
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
