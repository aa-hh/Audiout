// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import AppKit
@testable import AudiouterSharedUI
@testable import AudiouterWindowUI

/// T7 — the Groups window sidebar's warm surface (spec Q4-b: a low-alpha
/// warm tint atop macOS 26+'s automatic Liquid Glass sidebar material, an
/// opaque warm backing as the fallback below macOS 26).
///
/// This machine runs macOS 27, so a bare `#available(macOS 26, *)` on the
/// drawing path would make the `< 26` fallback branch permanently
/// untestable here — `SidebarViewController` instead takes the seam as an
/// injectable init parameter (`osSupportsLiquidGlassSidebar`), defaulting to
/// the real OS value via `SidebarViewController.osSupportsLiquidGlassSidebar`
/// but overridable directly, exactly like `SetupModel`'s
/// `localNetworkGated`/`osGatesLocalNetwork` seam. These tests drive BOTH
/// sides of it explicitly rather than relying on whatever OS the suite
/// happens to run under.
@MainActor
@Suite struct SidebarWarmSurfaceTests {

    /// Force `loadView()` to run (AppKit builds the view tree lazily) without
    /// ever ordering a real window on screen.
    private func loaded(_ controller: SidebarViewController) -> SidebarViewController {
        _ = controller.view
        return controller
    }

    @Test func macOS26PlusShowsTintOverlayNotFallbackBacking() {
        let sidebar = loaded(SidebarViewController(osSupportsLiquidGlassSidebar: true))

        #expect(sidebar.test_hasTintOverlay)
        #expect(!sidebar.test_hasFallbackBacking)
        #expect(abs(sidebar.test_warmSurfaceAlpha - 0.30) <= 0.0001)
    }

    @Test func belowMacOS26ShowsFallbackBackingNotTintOverlay() {
        let sidebar = loaded(SidebarViewController(osSupportsLiquidGlassSidebar: false))

        #expect(sidebar.test_hasFallbackBacking)
        #expect(!sidebar.test_hasTintOverlay)
        #expect(abs(sidebar.test_warmSurfaceAlpha - 1) <= 0.0001)
    }

    /// The default (no explicit seam override) must resolve from the real
    /// OS-version check, matching whatever `osSupportsLiquidGlassSidebar`
    /// reports for the machine actually running the suite — proving the
    /// default wiring (used by `MixerWindowController`'s
    /// `SidebarViewController()` call site) isn't silently stuck on one
    /// branch.
    @Test func defaultInitMatchesRealOSSeamValue() {
        let sidebar = loaded(SidebarViewController())
        #expect(sidebar.test_hasTintOverlay == SidebarViewController.osSupportsLiquidGlassSidebar)
    }
}
