// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import AppKit
@testable import AudiouterSharedUI
@testable import AudiouterWindowUI

/// T7 — the Groups window sidebar's warm surface (spec Q4-b: a low-alpha
/// warm tint atop macOS 26+'s automatic Liquid Glass sidebar material, an
/// opaque warm backing as the fallback below macOS 26).
///
/// Which of the two the sidebar draws is `SidebarViewController`'s injectable
/// `rendersOnSystemSidebarMaterial` parameter, so both branches are drivable
/// from a test whatever the machine runs. In the app it is always the opaque
/// backing now — the screens' split items are plain, so no system material
/// sits behind the wash — but the tint branch is still real code and still
/// covered here.
@MainActor
@Suite struct SidebarWarmSurfaceTests {

    /// Force `loadView()` to run (AppKit builds the view tree lazily) without
    /// ever ordering a real window on screen.
    private func loaded(_ controller: SidebarViewController) -> SidebarViewController {
        _ = controller.view
        return controller
    }

    @Test func macOS26PlusShowsTintOverlayNotFallbackBacking() {
        let sidebar = loaded(SidebarViewController(rendersOnSystemSidebarMaterial: true))
        // Pin Reduce Transparency off — the alpha assertion below is about the
        // glass tint, and must not depend on the machine's live setting.
        sidebar.test_reduceTransparencyOverride = false

        #expect(sidebar.test_hasTintOverlay)
        #expect(!sidebar.test_hasFallbackBacking)
        #expect(abs(sidebar.test_warmSurfaceAlpha - 0.30) <= 0.0001)
    }

    @Test func belowMacOS26ShowsFallbackBackingNotTintOverlay() {
        let sidebar = loaded(SidebarViewController(rendersOnSystemSidebarMaterial: false))
        sidebar.test_reduceTransparencyOverride = false

        #expect(sidebar.test_hasFallbackBacking)
        #expect(!sidebar.test_hasTintOverlay)
        #expect(abs(sidebar.test_warmSurfaceAlpha - 1) <= 0.0001)
    }

    /// A1: on the glass branch, Reduce Transparency promotes the low-alpha
    /// wash to the same fully-opaque backing the pre-26 fallback draws — a
    /// translucent tint over whatever the flattened glass resolves to would
    /// still read as transparency. Flipping the setting back mid-session must
    /// restore the tint (the wash re-reads the flag per repaint).
    @Test func reduceTransparencyPromotesTheGlassWashToOpaque() {
        let sidebar = loaded(SidebarViewController(rendersOnSystemSidebarMaterial: true))

        sidebar.test_reduceTransparencyOverride = true
        #expect(abs(sidebar.test_warmSurfaceAlpha - 1) <= 0.0001)

        sidebar.test_reduceTransparencyOverride = false
        #expect(abs(sidebar.test_warmSurfaceAlpha - 0.30) <= 0.0001)
    }

    /// The pre-26 opaque fallback is already the Reduce Transparency answer —
    /// the setting must not change what it draws.
    @Test func reduceTransparencyLeavesTheOpaqueFallbackAlone() {
        let sidebar = loaded(SidebarViewController(rendersOnSystemSidebarMaterial: false))

        for reduce in [true, false] {
            sidebar.test_reduceTransparencyOverride = reduce
            #expect(abs(sidebar.test_warmSurfaceAlpha - 1) <= 0.0001)
        }
    }

    /// The default — what `MixerWindowController`'s `SidebarViewController()`
    /// call site gets — draws the opaque backing on every OS. The screens'
    /// split items are plain ones, so nothing puts a system sidebar material
    /// behind this wash to tint; a tint over bare window background would
    /// leave the sidebar barely distinguishable from the pane beside it.
    @Test func defaultInitDrawsTheOpaqueBacking() {
        let sidebar = loaded(SidebarViewController())
        #expect(sidebar.test_hasFallbackBacking)
        #expect(!sidebar.test_hasTintOverlay)
    }
}
