// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
import AppKit
@testable import AudiouterPopoverUI

/// Coverage for `PopoverHeaderView` in its U3 role: the one-surface header
/// strip — the three-tab capsule switcher, the trailing Pin/Quit pair, the
/// ⌘1/⌘2/⌘3 key equivalents, and the three-tier material background
/// (glass / frost / opaque) with its Reduce-Transparency and OS seams.
@MainActor
@Suite struct PopoverHeaderViewTests {

    private func makeHeader(osSupportsGlass: Bool = true) -> PopoverHeaderView {
        let header = PopoverHeaderView(osSupportsGlassHeader: osSupportsGlass)
        header.frame = NSRect(x: 0, y: 0, width: 623, height: PopoverHeaderView.barHeight)
        return header
    }

    // MARK: Tabs

    @Test func allTabsAndTrailingButtonsResolveSymbolImages() {
        let header = makeHeader()
        #expect(header.test_allTabImagesResolved, "every switcher tab resolved a system SF Symbol")
        #expect(header.test_pinButtonHasImage)
        #expect(header.test_quitButtonHasImage)
    }

    @Test func tabTapsReportTheScreenButDoNotSelfSelect() {
        // The host owns selection: a tap must fire the callback with the
        // right screen, and the header must NOT flip its own state (the host
        // confirms via `setSelectedScreen`, which keeps sibling headers on
        // other screens in sync through one path).
        let header = makeHeader()
        var reported: [SurfaceScreen] = []
        header.onSelectScreen = { reported.append($0) }

        header.test_selectTab(.groups)
        header.test_selectTab(.settings)
        header.test_selectTab(.mixer)

        #expect(reported == [.groups, .settings, .mixer])
        #expect(header.selectedScreen == .mixer, "selection unchanged until the host confirms")
        #expect(header.test_isTabCapsuleFilled(.groups) == false)
    }

    @Test func hostConfirmedSelectionMovesTheFilledCapsule() {
        let header = makeHeader()
        #expect(header.test_isTabCapsuleFilled(.mixer) == true, "Mixer starts selected")

        header.setSelectedScreen(.settings)

        #expect(header.selectedScreen == .settings)
        #expect(header.test_isTabCapsuleFilled(.settings) == true)
        #expect(header.test_isTabCapsuleFilled(.mixer) == false,
                "exactly one capsule is filled — the selected segment")
        #expect(header.test_isTabCapsuleFilled(.groups) == false)
    }

    // MARK: ⌘1 / ⌘2 / ⌘3

    @Test func tabsCarryCommandNumberKeyEquivalentsInOrder() throws {
        let header = makeHeader()
        for (index, screen) in SurfaceScreen.allCases.enumerated() {
            let wiring = try #require(header.test_tabKeyEquivalent(screen))
            #expect(wiring.key == String(index + 1), "\(screen) is ⌘\(index + 1)")
            #expect(wiring.modifiers == [.command])
        }
    }

    // MARK: Pin / Quit

    @Test func pinAndQuitFireTheirCallbacks() {
        let header = makeHeader()
        var pinned = false
        var quit = false
        header.onTogglePin = { pinned = true }
        header.onQuit = { quit = true }

        header.test_tapPin()
        header.test_tapQuit()

        #expect(pinned)
        #expect(quit)
    }

    @Test func pinButtonReflectsThePinnedState() {
        let header = makeHeader()
        #expect(!header.isPinned)
        header.setPinned(true)
        #expect(header.isPinned)
        #expect(header.test_pinButtonHasImage, "pin.fill resolved for the pinned state")
        header.setPinned(false)
        #expect(!header.isPinned)
    }

    // MARK: Material tiers

    @Test func glassTierWhenTheOSSupportsIt() {
        let header = makeHeader(osSupportsGlass: true)
        header.test_reduceTransparencyOverride = false
        // On a pre-26 host the #available guard demotes this to frost; the
        // suite's own floor is macOS 14, so accept either only where the
        // runtime genuinely lacks glass.
        if #available(macOS 26.0, *) {
            #expect(header.test_materialTier == .glass)
        } else {
            #expect(header.test_materialTier == .frost)
        }
    }

    @Test func frostTierBelowGlassOS() {
        let header = makeHeader(osSupportsGlass: false)
        header.test_reduceTransparencyOverride = false
        #expect(header.test_materialTier == .frost,
                "macOS 14–15 fall back to the within-window frost")
    }

    @Test func reduceTransparencyForcesTheOpaqueTierOnAnyOS() {
        for osSupportsGlass in [true, false] {
            let header = makeHeader(osSupportsGlass: osSupportsGlass)
            header.test_reduceTransparencyOverride = true
            #expect(header.test_materialTier == .opaque,
                    "Reduce Transparency wins over glass=\(osSupportsGlass)")
        }
    }

    @Test func reduceTransparencyFlipRebuildsTheTierLive() {
        let header = makeHeader(osSupportsGlass: false)
        header.test_reduceTransparencyOverride = false
        #expect(header.test_materialTier == .frost)

        header.test_reduceTransparencyOverride = true
        #expect(header.test_materialTier == .opaque, "mid-session RT on rebuilds the background")

        header.test_reduceTransparencyOverride = false
        #expect(header.test_materialTier == .frost, "mid-session RT off restores the translucent tier")
    }
}
