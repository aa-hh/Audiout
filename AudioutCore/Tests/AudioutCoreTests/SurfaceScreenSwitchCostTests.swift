// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
import AppKit
@testable import AudioutCore
@testable import AudioutPopoverUI
@testable import AudioutSettingsUI
@testable import AudioutSharedUI
@testable import AudioutWindowUI

/// What a screen switch costs, and what it looks like.
///
/// The owner's report was that opening Groups, or a device row's Equalizer
/// door, "loads very juddery" (2026-09-04). Measured headless against the
/// seven-speaker demo fleet, the first Groups selection blocked the main
/// thread for 56 ms — 50 ms of it constructing `MixerWindowController` and its
/// panes — against 8 ms for every visit after, and the Equalizer door paid a
/// further 31 ms for the detail pane. These cases hold the two halves of the
/// answer: the heavy screens are built off the click path, and what is left is
/// dissolved in rather than cut to.
///
/// Nested here because three of these flip `FoldAnimator.shared`'s Reduce
/// Motion override, which is process-wide: run concurrently they set it against
/// each other.
extension SerializedSharedState {

@MainActor
@Suite final class SurfaceScreenSwitchCostTests: IsolatedSuite {

    private func makeSurface() -> AppSurfaceController {
        let popover = PopoverController(
            appRouting: AppRoutingController(store: AppRouteStore(directory: scratchDir),
                                             loadPersisted: false),
            runningAppsProvider: { [] })
        return AppSurfaceController(
            popoverController: popover,
            settings: AppSettings(defaults: isolatedDefaults),
            groupsContent: {
                let vc = NSViewController()
                vc.view = NSView(frame: NSRect(x: 0, y: 0,
                                               width: SurfaceLayout.width, height: 464))
                return vc
            },
            settingsContent: {
                SettingsRootViewController(sections: [
                    .init(title: "General", symbolName: "gearshape",
                          viewController: NSViewController()),
                ])
            },
            frameAutosaveName: NSWindow.FrameAutosaveName(uniqueName("SwitchCost")))
    }

    // MARK: The cut — building off the click path

    /// Opening the surface builds Groups and Settings a turn later, so the
    /// click that selects one has nothing left to construct. Drop the prewarm
    /// and this fails: both screens stay nil until their tab is clicked, which
    /// is what put a 56 ms build inside the click.
    @Test func openingTheSurfaceBuildsTheOtherScreensBeforeTheyAreClicked() async throws {
        let surface = makeSurface()
        #expect(surface.test_groupsScreen == nil, "nothing is built before the open")

        surface.show(anchorRect: nil)
        if surface.test_isRevealPending { surface.test_fireRevealCeiling() }
        #expect(surface.test_prewarmRequested)

        // Polled, not slept: a fixed span asserts how fast the machine is, and
        // this suite runs on two of them. The ASYNC wait, because the prewarm
        // arrives on a main-actor hop — pumping the run loop instead never
        // advances it, which is the distinction `SuiteWait` documents.
        await SuiteWait.until("the prewarmed screens to be built") {
            surface.test_groupsScreen != nil && surface.test_settingsScreen != nil
        }

        #expect(surface.test_groupsScreen != nil, "Groups is already built")
        #expect(surface.test_settingsScreen != nil, "and so is Settings")
    }

    /// The Groups screen's three swapped panes have their view trees built when
    /// the controller is, not when a swap first shows one. Remove the eager
    /// load and the Mixer row's Equalizer door pays the detail pane's build
    /// inside the click again (measured at 31 ms, cut to 23 ms).
    @Test func theGroupsPanesAreBuiltWithTheirController() throws {
        let backend = MockBackend(fleet: .demoFleet, staggerDiscovery: false,
                                  emitsLevels: false, simulatesDropouts: false)
        let controller = GroupController(backend: backend,
                                         store: GroupStore(directory: scratchDir),
                                         loadPersisted: false)
        let window = MixerWindowController(groupController: controller,
                                           settings: AppSettings(defaults: isolatedDefaults))

        #expect(window.test_detail.isViewLoaded, "the Equalizer page is already built")
        #expect(window.test_mainOutDetail.isViewLoaded, "so is the Main Audio page")
        #expect(window.test_editor.isViewLoaded, "so is the group editor")
    }

    // MARK: The smoothing — the swap's one animated value

    /// A screen swap DISSOLVES, except under Reduce Motion, where the new
    /// screen is simply THERE. Reduce Motion is the only axis that varies:
    /// off, the incoming screen is still part-transparent when the click
    /// returns and reaches full opacity only once the reveal clock has run;
    /// on, it is opaque in the caller's own turn. Sampled off the live
    /// opacity, so a version that merely ASKED for an animation fails — and
    /// routing the fade around `FoldAnimator` fails the Reduce Motion case,
    /// because that clock is the one place the setting is answered.
    @Test(arguments: [false, true])
    func aScreenSwapDissolvesUnlessReduceMotionIsOn(reduceMotion: Bool) throws {
        defer {
            FoldAnimator.shared.test_reduceMotionOverride = nil
            FoldAnimator.shared.test_settleNow()
        }
        FoldAnimator.shared.test_reduceMotionOverride = reduceMotion
        let surface = makeSurface()
        surface.show(anchorRect: nil)
        if surface.test_isRevealPending { surface.test_fireRevealCeiling() }

        surface.select(reduceMotion ? .settings : .groups)

        if reduceMotion {
            #expect(surface.test_swapFadeOpacity == 1,
                    "opaque already — \(surface.test_swapFadeOpacity)")
            #expect(!FoldAnimator.shared.isFolding, "nothing is left travelling")
        } else {
            #expect(surface.test_swapFadeOpacity < 1,
                    "the screen has not been cut to — \(surface.test_swapFadeOpacity)")
            #expect(FoldAnimator.shared.isFolding, "it is travelling there")
            FoldAnimator.shared.test_settleNow()
            #expect(surface.test_swapFadeOpacity == 1, "and arrives fully opaque")
        }
    }

    /// The dissolve moves opacity and NOTHING else. The surface's one frame per
    /// open session is a recorded contract, so a swap that animated the window
    /// — or let a mid-flight tick disturb it — fails here.
    @Test func theDissolveNeverMovesTheWindowFrame() throws {
        defer {
            FoldAnimator.shared.test_reduceMotionOverride = nil
            FoldAnimator.shared.test_settleNow()
        }
        FoldAnimator.shared.test_reduceMotionOverride = false
        let surface = makeSurface()
        surface.show(anchorRect: nil)
        if surface.test_isRevealPending { surface.test_fireRevealCeiling() }
        guard let window = surface.shell.window else {
            Issue.record("the shell has no window")
            return
        }
        let frame = window.frame

        surface.select(.groups)
        #expect(window.frame == frame, "the frame is still put mid-dissolve")

        FoldAnimator.shared.test_settleNow()
        #expect(window.frame == frame, "and after it lands")
    }
}
}
