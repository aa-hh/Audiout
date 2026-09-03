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
            .space,
            SurfaceToolbarController.tabItemIdentifier(for: .groups),
            .space,
            SurfaceToolbarController.tabItemIdentifier(for: .settings),
            .flexibleSpace,
            SurfaceToolbarController.pinItemIdentifier,
            .space,
            SurfaceToolbarController.quitItemIdentifier,
        ], "three spaced tabs lead, Pin and Quit trail with a gap and nothing sits between")
        #expect(controller.test_quitItemTitle == "Quit",
                "Quit is the word, not a glyph")
        #expect(!controller.test_quitItemHasImage,
                "Quit is the word, not a glyph")
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


    @Test func pinResolvesItsGlyphAndQuitIsAWord() {
        let (controller, _) = makeAttached()
        #expect(controller.test_pinItemHasImage)
        #expect(controller.test_quitItemTitle == "Quit",
                "Quit is the word, not a glyph")
        #expect(!controller.test_quitItemHasImage,
                "Quit is the word, not a glyph")
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
    @Test func onlyTheSelectedTabIsFilled() {
        let (controller, _) = makeAttached()
        #expect(controller.test_onlySelectedTabIsFilled, "Mixer starts selected, alone")

        controller.setSelectedScreen(.settings)

        #expect(controller.test_onlySelectedTabIsFilled, "the fill followed the selection")
    }

    /// One header, one button style (Alec, live review 2026-08-30). The tabs
    /// had become custom-view items, which draw NO chrome — bare glyphs beside
    /// Pin/Quit's bordered circles, two styles
    /// in one strip. Every tab is the same bordered item Pin and Quit are.
    @Test func everyTabWearsTheSameControlAsPinAndQuit() {
        let (controller, _) = makeAttached()
        #expect(controller.test_allTabsAreBordered,
                "the tabs are bordered items — the same control Pin and Quit are")
        #expect(controller.test_pinItemIsBordered && controller.test_quitItemIsBordered,
                "and Pin/Quit really are bordered, so that comparison means something")
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

    /// The fill is neutral on purpose: gold means signal — carrying audio —
    /// and which screen you are on is chrome. Same rule that keeps the mute
    /// pill and the row washes off the gold family. It is an authored grey
    /// rather than the dynamic token because `.prominent` forces the glyph
    /// WHITE in both appearances, and a token that goes near-white in dark
    /// mode would hide it.
    @Test func theSelectionFillIsNeutralNotGold() {
        let fill = SurfaceToolbarController.selectedTabFill
            .usingColorSpace(.sRGB) ?? .black
        #expect(abs(fill.redComponent - fill.greenComponent) < 0.01
                    && abs(fill.greenComponent - fill.blueComponent) < 0.01,
                "the fill is a pure grey — no hue, and specifically not gold")
        #expect(fill.brightnessComponent < 0.5,
                "dark enough that the forced-white glyph reads on it in light mode too")
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
