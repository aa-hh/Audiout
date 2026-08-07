// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
import AppKit
@testable import AudiouterCore
@testable import AudiouterPopoverUI
@testable import AudiouterSettingsUI
@testable import AudiouterSharedUI

/// Structural + lifecycle coverage for the one-surface host (U3,
/// PLAN-ONE-SURFACE-032): screen switching (lazy build, `setContent` routing,
/// per-screen sizes), the Mixer's `surfaceDidShow`/`surfaceDidHide` lifecycle,
/// pin persistence, header state sync, and the pinned-chrome inset. Headless:
/// nothing here ever orders a window on screen (`HeadlessRuntime` gates the
/// shell's presentation calls), so every assertion reads window/controller
/// STATE, never visibility.
@MainActor
@Suite final class AppSurfaceControllerTests: IsolatedSuite {

    /// A stub content pane with a known published size, for the Settings
    /// root's per-tab sizing (mirrors how the real panes publish
    /// `preferredContentSize` at the fixed form width).
    private func makePane(height: CGFloat) -> NSViewController {
        let vc = NSViewController()
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        let body = NSView()
        body.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: view.topAnchor),
            body.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            body.heightAnchor.constraint(equalToConstant: height),
            body.widthAnchor.constraint(equalToConstant: SettingsForm.contentWidth),
        ])
        vc.view = view
        vc.preferredContentSize = NSSize(width: SettingsForm.contentWidth, height: height)
        return vc
    }

    private func makeSettingsRoot() -> SettingsRootViewController {
        SettingsRootViewController(tabs: [
            .init(title: "General", symbolName: "gearshape", viewController: makePane(height: 200)),
            .init(title: "Appearance", symbolName: "paintpalette", viewController: makePane(height: 300)),
            .init(title: "Audio", symbolName: "speaker.wave.2", viewController: makePane(height: 420)),
        ], tabStyle: .segmentedControlOnTop)
    }

    /// The surface under test plus spy state. The popover controller is real
    /// (its panel IS the Mixer screen); Groups content is a plain stub — the
    /// provider seam is exactly what the app fills with
    /// `MixerWindowController.contentController`.
    private func makeSurface(
        settings: AppSettings? = nil
    ) -> (surface: AppSurfaceController, popover: PopoverController,
          groupsBuilds: () -> Int, settingsBuilds: () -> Int) {
        let popover = PopoverController(
            appRouting: AppRoutingController(store: AppRouteStore(directory: scratchDir),
                                             loadPersisted: false),
            runningAppsProvider: { [] })
        var groupsBuilds = 0
        var settingsBuilds = 0
        let surface = AppSurfaceController(
            popoverController: popover,
            settings: settings ?? AppSettings(defaults: isolatedDefaults),
            groupsContent: {
                groupsBuilds += 1
                let vc = NSViewController()
                vc.view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 464))
                return vc
            },
            settingsContent: { [self] in
                settingsBuilds += 1
                return makeSettingsRoot()
            },
            frameAutosaveName: NSWindow.FrameAutosaveName(uniqueName("SurfaceTests")))
        return (surface, popover, { groupsBuilds }, { settingsBuilds })
    }

    // MARK: Screen switching — lazy build + setContent routing

    @Test func startsOnMixerAndHostsThePanelThroughSetContent() throws {
        let (surface, popover, groupsBuilds, settingsBuilds) = makeSurface()
        #expect(surface.selectedScreen == .mixer)
        #expect(surface.test_mixerPanel == nil, "nothing is built before the first show")

        surface.show(anchorRect: NSRect(x: 900, y: 1000, width: 30, height: 24))

        let panel = try #require(surface.test_mixerPanel, "showing claims the Mixer panel")
        #expect(surface.test_hostedContentViewController === panel,
                "the panel is mounted via the shell's setContent (R3)")
        #expect(groupsBuilds() == 0, "Groups is not built until first selected")
        #expect(settingsBuilds() == 0, "Settings is not built until first selected")
        _ = popover
    }

    @Test func selectingScreensBuildsEachExactlyOnceAndRoutesThroughSetContent() throws {
        let (surface, _, groupsBuilds, settingsBuilds) = makeSurface()
        surface.show(anchorRect: nil)

        surface.select(.groups)
        let groupsScreen = try #require(surface.test_groupsScreen)
        #expect(surface.selectedScreen == .groups)
        #expect(surface.test_hostedContentViewController === groupsScreen)
        #expect(groupsBuilds() == 1)

        surface.select(.settings)
        let settingsScreen = try #require(surface.test_settingsScreen)
        #expect(surface.test_hostedContentViewController === settingsScreen)
        #expect(settingsBuilds() == 1)

        surface.select(.groups)
        surface.select(.settings)
        #expect(groupsBuilds() == 1, "revisiting reuses the built screen")
        #expect(settingsBuilds() == 1, "revisiting reuses the built screen")

        surface.select(.mixer)
        #expect(surface.test_hostedContentViewController === surface.test_mixerPanel)
    }

    @Test func selectingTheCurrentScreenIsANoOp() {
        let (surface, popover, _, _) = makeSurface()
        surface.show(anchorRect: nil)
        let rebuilds = popover.test_rebuildCount
        surface.select(.mixer)
        #expect(popover.test_rebuildCount == rebuilds, "re-selecting Mixer must not re-open/rebuild")
    }

    @Test func reShowingAnAlreadyShownSurfaceOnlyFrontsIt() {
        // The pinned always-front click (and a repeat menu-bar click) reach
        // `show` while the surface is already up. That is the SAME open
        // session: no second surfaceDidShow, and no re-run of the open
        // ritual — rebuildForOpen would discard the user's mid-open collapse
        // toggles.
        let (surface, popover, _, _) = makeSurface()
        var meteringStates: [Bool] = []
        popover.onMeteringActiveChange = { meteringStates.append($0) }

        surface.show(anchorRect: nil)
        let rebuilds = popover.test_rebuildCount
        surface.show(anchorRect: nil)

        #expect(popover.test_rebuildCount == rebuilds, "no open ritual on a re-front")
        #expect(meteringStates == [true], "no duplicate surfaceDidShow")
    }

    // MARK: Per-screen sizes

    @Test func groupsGetsItsDesignedSizeAndMixerItsExactFit() throws {
        let (surface, _, _, _) = makeSurface()
        surface.show(anchorRect: nil)
        let window = try #require(surface.shell.window)
        let panel = try #require(surface.test_mixerPanel)

        // Mixer: the window wears the panel's exact-fit preferred size.
        let mixerFit = panel.preferredContentSize
        #expect(mixerFit.width == 623, "the Mixer panel's fixed width")
        #expect(window.frame.size.width == mixerFit.width)
        #expect(abs(window.frame.size.height - mixerFit.height) < 0.5,
                "the shell resized to the Mixer's exact fit")

        surface.select(.groups)
        #expect(window.frame.size == AppSurfaceController.groupsDefaultContentSize,
                "Groups opens at its designed 560×516 (the split view's real minimum)")
    }

    @Test func settingsSizesPerTabThroughTheFittedChannel() throws {
        let (surface, _, _, _) = makeSurface()
        surface.show(anchorRect: nil)
        surface.select(.settings)
        let window = try #require(surface.shell.window)
        let root = try #require(surface.test_settingsRoot)

        let header = SurfaceScreenViewController.headerHeight
        let fittedFirst = root.fittedContentSize
        #expect(fittedFirst.height > 200, "fitted height includes the in-content tab chrome")
        #expect(window.frame.size.height == fittedFirst.height + header,
                "settings screen = header strip + fitted tabs")

        // A tab switch re-measures and the surface follows (trigger 2).
        root.selectTab(at: 2)
        let fittedThird = root.fittedContentSize
        #expect(fittedThird.height > fittedFirst.height, "the third pane is taller")
        #expect(window.frame.size.height == fittedThird.height + header,
                "the surface resized for the newly selected tab")
    }

    // MARK: Mixer show/hide lifecycle (U2 seams)

    @Test func mixerLifecycleDrivesMeteringAndRebuild() {
        let (surface, popover, _, _) = makeSurface()
        var meteringStates: [Bool] = []
        popover.onMeteringActiveChange = { meteringStates.append($0) }

        surface.show(anchorRect: nil)
        #expect(meteringStates == [true], "showing the Mixer turns metering on (surfaceDidShow)")

        let rebuildsBeforeSwitch = popover.test_rebuildCount
        surface.select(.groups)
        #expect(meteringStates == [true, false],
                "leaving the Mixer screen turns metering off (surfaceDidHide)")

        surface.select(.mixer)
        #expect(meteringStates == [true, false, true], "returning turns it back on")
        #expect(popover.test_rebuildCount > rebuildsBeforeSwitch,
                "returning to the Mixer re-runs the open rebuild (hidden means idle)")
    }

    @Test func closingTheSurfaceHidesTheMixerAndReshowingReopensIt() {
        let (surface, popover, _, _) = makeSurface()
        var meteringStates: [Bool] = []
        popover.onMeteringActiveChange = { meteringStates.append($0) }
        var closes = 0
        surface.onClose = { closes += 1 }

        surface.show(anchorRect: nil)
        surface.shell.test_isPanelVisibleOverride = true
        surface.performClose()

        #expect(!surface.isShown)
        #expect(closes == 1, "the real-close path fired onClose")
        #expect(meteringStates == [true, false], "a real close is a Mixer hide")

        surface.show(anchorRect: nil)
        #expect(surface.isShown)
        #expect(meteringStates == [true, false, true], "reshow is a fresh Mixer show")
    }

    // MARK: Pin — persistence round-trip + chrome inset

    @Test func pinPersistsAndRestores() {
        let settings = AppSettings(defaults: isolatedDefaults)
        let (surface, _, _, _) = makeSurface(settings: settings)
        #expect(!surface.isPinned, "fresh install: transient bubble")

        surface.show(anchorRect: nil)
        surface.togglePin()
        #expect(surface.isPinned)
        #expect(surface.shell.isPinned, "the pin drives U1's manner flip on the shell")
        #expect(settings.surfacePinned, "the choice persisted")

        // A NEW surface over the same settings restores the pinned manner.
        let (restored, _, _, _) = makeSurface(settings: settings)
        #expect(restored.isPinned, "surfacePinned restored at construction")
        #expect(restored.shell.isPinned)

        restored.setPinned(false)
        #expect(!settings.surfacePinned, "unpinning persists too")
    }

    @Test func pinnedChromeInsetSeatsHeadersBelowTheTitleBarAndUnpinRemovesIt() throws {
        let (surface, _, _, _) = makeSurface()
        surface.show(anchorRect: nil)
        surface.select(.groups)
        let groupsScreen = try #require(surface.test_groupsScreen)
        let panel = try #require(surface.test_mixerPanel)
        #expect(groupsScreen.test_headerTopInset == 0, "unpinned: content under the invisible bar")
        #expect(panel.test_headerTopInset == 0)

        surface.togglePin()
        let inset = surface.test_chromeTopInset
        #expect(inset > 0, "pinned: a real title bar overlaps fullSizeContentView content")
        #expect(groupsScreen.test_headerTopInset == inset, "screens seat below the measured bar")
        #expect(panel.test_headerTopInset == inset, "the Mixer panel insets its own header")

        surface.togglePin()
        #expect(groupsScreen.test_headerTopInset == 0, "unpinning removes the inset")
        #expect(panel.test_headerTopInset == 0)
    }

    // MARK: Header sync — tab selection state across screens

    @Test func everyBuiltHeaderTracksSelectionAndPin() {
        let (surface, _, _, _) = makeSurface()
        surface.show(anchorRect: nil)
        surface.select(.groups)
        surface.select(.settings)

        #expect(surface.test_builtHeaders.count == 3, "all three screens built, three headers")
        #expect(surface.test_builtHeaders.allSatisfy { $0.selectedScreen == .settings },
                "every header shows the same selected tab")

        // Back to an ALREADY-BUILT screen: nothing lazy-builds on this switch,
        // so the sync must come from the select path itself (the lazy-build
        // path also syncs, which would mask a select-path regression above).
        surface.select(.groups)
        #expect(surface.test_builtHeaders.allSatisfy { $0.selectedScreen == .groups },
                "a switch between built screens re-syncs every header")

        surface.togglePin()
        #expect(surface.test_builtHeaders.allSatisfy { $0.isPinned },
                "every header shows the pinned state")
    }

    @Test func headerTabTapSwitchesTheScreen() throws {
        let (surface, _, _, _) = makeSurface()
        surface.show(anchorRect: nil)
        let panel = try #require(surface.test_mixerPanel)

        panel.header.test_selectTab(.groups)

        #expect(surface.selectedScreen == .groups,
                "the surface rewired the claimed panel's header: a tab IS the screen switch")
        #expect(surface.test_hostedContentViewController === surface.test_groupsScreen)
    }

    @Test func headerPinTapTogglesTheSurfacePin() throws {
        let (surface, _, _, _) = makeSurface()
        surface.show(anchorRect: nil)
        let panel = try #require(surface.test_mixerPanel)

        panel.header.test_tapPin()
        #expect(surface.isPinned, "the header Pin button drives the surface's pin flip")
        panel.header.test_tapPin()
        #expect(!surface.isPinned)
    }
}
