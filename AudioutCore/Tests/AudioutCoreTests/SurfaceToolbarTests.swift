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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SurfaceLayout.width, height: 400),
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
            .space,
            SurfaceToolbarController.tabItemIdentifier(for: .groups),
            .space,
            SurfaceToolbarController.tabItemIdentifier(for: .settings),
            .flexibleSpace,
            SurfaceToolbarController.pinItemIdentifier,
        ], "three spaced tabs lead and Pin trails; Quit left the strip for the menus")
        #expect(window.toolbar === controller.toolbar)
        #expect(window.toolbarStyle == .unified, "D1: unified — the toolbar IS the one header strip")
    }

    @Test func tabsCarryAllThreeScreensWithResolvedGlyphs() {
        let (controller, _) = makeAttached()
        #expect(controller.test_tabLabels == ["Mixer", "Groups", "Settings"])
        #expect(controller.test_allTabImagesResolved,
                "every tab resolved a system SF Symbol")
    }

    /// The tabs are ICON-ONLY (Alec, 2026-09-03). Names on the items' `title`
    /// were tried and removed: translated labels would widen the strip until
    /// AppKit swept the tabs into the overflow menu, and primary navigation
    /// cannot live behind a chevron. The names still reach the reader through
    /// the tooltip, the `label`, and ⌘1/⌘2/⌘3 — none of which costs width.
    @Test func tabsDrawNoNameSoTheStripCannotGrowWithTranslation() {
        let (controller, window) = makeAttached()
        window.layoutIfNeeded()
        // Hoisted out of `#expect`: the macro decomposes the call, and
        // `allSatisfy` is `rethrows`, so the expansion refuses to compile.
        let noTabDrawsAName = controller.test_tabTitles.allSatisfy(\.isEmpty)
        #expect(noTabDrawsAName, "no tab draws a name")
        #expect(controller.test_tabLabels == SurfaceScreen.allCases.map(\.label),
                "but every tab still carries its name for VoiceOver and the overflow menu")
        #expect(controller.test_tabToolTips == SurfaceScreen.allCases.map { "\($0.label) (⌘\($0.keyEquivalent))" },
                "and the tooltip spells it out with the shortcut")
        #expect(controller.test_allTabImagesResolved,
                "the glyph is what the tab shows")
        #expect(controller.toolbar.displayMode == .iconOnly)
    }


    @Test func pinResolvesItsGlyph() {
        let (controller, _) = makeAttached()
        #expect(controller.test_pinItemHasImage)
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
    @Test func onlyTheSelectedTabIsMarked() {
        let (controller, _) = makeAttached()
        #expect(controller.test_onlySelectedTabIsMarked, "Mixer starts selected, alone")

        controller.setSelectedScreen(.settings)

        #expect(controller.test_onlySelectedTabIsMarked, "the fill followed the selection")
    }

    /// One header, one button style (Alec, live review 2026-08-30). The tabs
    /// had become custom-view items, which draw NO chrome — bare glyphs beside
    /// Pin/Quit's bordered circles, two styles
    /// in one strip. Every tab is the same bordered item Pin and Quit are.
    @Test func everyTabWearsTheSameControlAsPin() {
        let (controller, _) = makeAttached()
        #expect(controller.test_allTabsAreBordered,
                "the tabs are bordered items — the same control Pin is")
        #expect(controller.test_pinItemIsBordered,
                "and Pin really is bordered, so that comparison means something")
    }

    /// The tabs are `.space`-separated so the strip cannot RESHAPE with the
    /// selection. Adjacent bordered items merge into one shared capsule on
    /// macOS 26+, and `.prominent` pulls the selected item out of that capsule —
    /// measured live: Mixer gave circle + capsule(2), Groups gave three
    /// circles, Settings gave capsule(2) + circle. Same wandering geometry the
    /// segmented divider had.
    @Test func theTabsAreSeparatedSoTheStripCannotReshape() {
        let (controller, _) = makeAttached()
        let ids = controller.test_itemIdentifiers
        let tabs = SurfaceScreen.allCases.map(SurfaceToolbarController.tabItemIdentifier(for:))
        for (first, second) in zip(tabs, tabs.dropFirst()) {
            guard let a = ids.firstIndex(of: first), let b = ids.firstIndex(of: second) else {
                Issue.record("a tab item is missing from the toolbar")
                return
            }
            #expect(b == a + 2 && ids[a + 1] == .space,
                    "a .space must sit between \(first.rawValue) and \(second.rawValue)")
        }
    }

    /// Selection is AppKit's own, not an authored fill. This test replaces
    /// `theSelectionFillIsNeutralNotGold`, which pinned the bug it was written
    /// to prevent: it required a PURE grey darker than 0.5 brightness, which
    /// forbade both a warm value and any value bright enough to clear the
    /// unselected capsule in dark mode.
    ///
    /// `selectedItemIdentifier` is version-free — the old cue lived inside
    /// `if #available(macOS 26.0, *)` while the package deploys to 14.2, so
    /// macOS 14–25 had no cue at all — and it is the selection AppKit exposes
    /// to VoiceOver, which a rendering style never was.
    @Test func theToolbarCarriesSelectionItselfOnEveryVersion() {
        let (controller, _) = makeAttached()
        // Asked of the delegate, because NSToolbar exposes no
        // `selectableItemIdentifiers` property — only the delegate method.
        #expect(controller.toolbarSelectableItemIdentifiers(controller.toolbar)
                    == SurfaceScreen.allCases.map(SurfaceToolbarController.tabItemIdentifier(for:)),
                "the three screens are the selectable set — without it AppKit draws no highlight")
        for screen in SurfaceScreen.allCases {
            controller.setSelectedScreen(screen)
            #expect(controller.toolbar.selectedItemIdentifier
                        == SurfaceToolbarController.tabItemIdentifier(for: screen),
                    "\(screen.label) is what the toolbar reports as selected")
        }
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

    // MARK: Pin

    @Test func pinFiresItsCallback() {
        let (controller, _) = makeAttached()
        var pinned = false
        controller.onTogglePin = { pinned = true }

        controller.test_tapPin()

        #expect(pinned)
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
