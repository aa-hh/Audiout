// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
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
final class SidebarWarmSurfaceTests: IsolatedTestCase {

    /// Force `loadView()` to run (AppKit builds the view tree lazily) without
    /// ever ordering a real window on screen.
    private func loaded(_ controller: SidebarViewController) -> SidebarViewController {
        _ = controller.view
        return controller
    }

    func test_macOS26Plus_showsTintOverlay_notFallbackBacking() {
        let sidebar = loaded(SidebarViewController(osSupportsLiquidGlassSidebar: true))

        XCTAssertTrue(sidebar.test_hasTintOverlay)
        XCTAssertFalse(sidebar.test_hasFallbackBacking)
        XCTAssertEqual(sidebar.test_warmSurfaceAlpha, 0.30, accuracy: 0.0001)
    }

    func test_belowMacOS26_showsFallbackBacking_notTintOverlay() {
        let sidebar = loaded(SidebarViewController(osSupportsLiquidGlassSidebar: false))

        XCTAssertTrue(sidebar.test_hasFallbackBacking)
        XCTAssertFalse(sidebar.test_hasTintOverlay)
        XCTAssertEqual(sidebar.test_warmSurfaceAlpha, 1, accuracy: 0.0001)
    }

    /// The default (no explicit seam override) must resolve from the real
    /// OS-version check, matching whatever `osSupportsLiquidGlassSidebar`
    /// reports for the machine actually running the suite — proving the
    /// default wiring (used by `MixerWindowController`'s
    /// `SidebarViewController()` call site) isn't silently stuck on one
    /// branch.
    func test_defaultInit_matchesRealOSSeamValue() {
        let sidebar = loaded(SidebarViewController())
        XCTAssertEqual(sidebar.test_hasTintOverlay, SidebarViewController.osSupportsLiquidGlassSidebar)
    }
}
