// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
import AppKit
@testable import AudiouterCore
@testable import AudiouterPopoverUI
@testable import AudiouterSettingsUI
@testable import AudiouterSharedUI
@testable import AudiouterWindowUI

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
                "Groups opens at its designed 560×520 (derived so the 7-device editor fits)")
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

    // MARK: Menu-bar click policy — all four cases (U4)

    /// The resign-key notification AppKit delivers when the user clicks
    /// somewhere else in this app — including on the status item. Driven
    /// directly because `swift test` can never make a window key on screen
    /// (same seam `ControlPanelWindowControllerTests` uses).
    private func resignKey(_ surface: AppSurfaceController) {
        surface.shell.test_appIsActiveOverride = true
        surface.shell.test_hasAttachedSheetOverride = false
        surface.shell.windowDidResignKey(
            Notification(name: NSWindow.didResignKeyNotification, object: surface.shell.window))
    }

    /// (a) Setup owns the click outright: no surface action of any kind, so a
    /// menu-bar click can never bury the window the user is being asked to
    /// finish.
    @Test func setupOpenTakesTheClickAndLeavesTheSurfaceAlone() {
        let (surface, _, _, _) = makeSurface()

        let action = surface.clickAction(setupIsOpen: true)
        surface.perform(action, anchorRect: nil)

        #expect(action == .refrontSetup)
        #expect(!surface.isShown, "the surface must not open behind Setup")
        #expect(surface.test_mixerPanel == nil, "nor build anything")
    }

    /// (b) Unpinned is a toggle — the transient bubble's whole contract.
    @Test func unpinnedClickTogglesTheSurface() {
        let (surface, _, _, _) = makeSurface()
        surface.shell.test_isPanelVisibleOverride = false

        let opening = surface.clickAction(setupIsOpen: false)
        surface.perform(opening, anchorRect: nil)
        #expect(opening == .show)
        #expect(surface.isShown)

        surface.shell.test_isPanelVisibleOverride = true
        var closes = 0
        surface.onClose = { closes += 1 }
        let closing = surface.clickAction(setupIsOpen: false)
        surface.perform(closing, anchorRect: nil)

        #expect(closing == .dismiss)
        #expect(closes == 1, "a toggle-close goes through the real close path")
        #expect(!surface.isShown)
    }

    /// (b, R1) The status click IS the click that made the unpinned surface
    /// resign key, and AppKit delivers that resign — and the close it causes —
    /// BEFORE the button's action runs. Without the guard the handler sees a
    /// closed surface, concludes "it wasn't open", and reopens it: the surface
    /// could never be dismissed from the menu bar, it would just flicker.
    @Test func theClickThatDismissedTheSurfaceDoesNotReopenIt() {
        let (surface, _, _, _) = makeSurface()
        surface.show(anchorRect: nil)
        surface.shell.test_isPanelVisibleOverride = true

        resignKey(surface)
        #expect(!surface.isShown, "the resign closed it")
        // What the app really sees a moment later, when the button action runs.
        surface.shell.test_isPanelVisibleOverride = false

        let sameClick = surface.clickAction(setupIsOpen: false)
        surface.perform(sameClick, anchorRect: nil)
        #expect(sameClick == .ignore)
        #expect(!surface.isShown, "the dismissing click must not bounce it back open")

        // The stamp is consumed, so the NEXT click is an ordinary open — the
        // guard swallows exactly one click, never two.
        let nextClick = surface.clickAction(setupIsOpen: false)
        surface.perform(nextClick, anchorRect: nil)
        #expect(nextClick == .show)
        #expect(surface.isShown)
    }

    /// (c) Pinned + open (visible, or sitting behind another app) fronts the
    /// window. Never a toggle: a pinned window is an ordinary window, and a
    /// click that closed it would make "pinned" mean nothing.
    @Test func pinnedClickFrontsAnOpenWindowInsteadOfTogglingIt() {
        let (surface, popover, _, _) = makeSurface()
        surface.show(anchorRect: nil)
        surface.togglePin()
        surface.shell.test_isPanelVisibleOverride = true
        var closes = 0
        surface.onClose = { closes += 1 }
        let rebuilds = popover.test_rebuildCount

        let action = surface.clickAction(setupIsOpen: false)
        surface.perform(action, anchorRect: nil)

        #expect(action == .front)
        #expect(closes == 0, "a pinned window is never toggled shut from the menu bar")
        #expect(surface.isShown)
        #expect(popover.test_rebuildCount == rebuilds,
                "fronting an open surface is the same session — no open ritual")
    }

    /// (d) Closing a pinned window does NOT unpin it: the next click reopens
    /// it, still pinned, at the frame it remembers.
    @Test func pinnedClickReopensAClosedWindowStillPinned() {
        let (surface, _, _, _) = makeSurface()
        surface.show(anchorRect: nil)
        surface.togglePin()
        surface.shell.test_isPanelVisibleOverride = true
        surface.performClose()
        surface.shell.test_isPanelVisibleOverride = false
        #expect(!surface.isShown)
        #expect(surface.isPinned, "closing is not unpinning")

        let action = surface.clickAction(setupIsOpen: false)
        surface.perform(action, anchorRect: nil)

        #expect(action == .show)
        #expect(surface.isShown, "the pinned surface came back")
        #expect(surface.isPinned)
    }

    /// A pinned window never self-dismisses on resign, so no stamp can be
    /// standing when its click arrives — but a stamp left over from an earlier
    /// unpinned spell must not swallow a pinned click either.
    @Test func aLeftoverDismissalNeverSwallowsAPinnedClick() {
        let (surface, _, _, _) = makeSurface()
        surface.show(anchorRect: nil)
        surface.shell.test_isPanelVisibleOverride = true
        resignKey(surface)                        // stamps a dismissal, unpinned
        surface.setPinned(true)
        surface.shell.test_isPanelVisibleOverride = false

        #expect(surface.clickAction(setupIsOpen: false) == .show,
                "pinned reads its own state, never a stale unpinned dismissal")
    }

    /// Every other case here stubs the Groups screen, and a real
    /// `NSSplitViewController` is exactly what breaks differently: mounted
    /// before its view is laid out it collapses to a near-zero intrinsic size,
    /// and its own minimums fight a host that asks for less. So this mounts the
    /// REAL content the app hands over and checks the geometry survives.
    @Test func theRealGroupsSplitViewMountsAtItsDesignedSize() throws {
        let backend = MockBackend(fleet: .demoFleet, staggerDiscovery: false,
                                  emitsLevels: false, simulatesDropouts: false)
        let groups = MixerWindowController(
            groupController: GroupController(backend: backend,
                                             store: GroupStore(directory: scratchDir),
                                             loadPersisted: false))
        let popover = PopoverController(
            appRouting: AppRoutingController(store: AppRouteStore(directory: scratchDir),
                                             loadPersisted: false),
            runningAppsProvider: { [] })
        let surface = AppSurfaceController(
            popoverController: popover,
            settings: AppSettings(defaults: isolatedDefaults),
            groupsContent: { groups.contentController },
            settingsContent: { [self] in makeSettingsRoot() },
            frameAutosaveName: NSWindow.FrameAutosaveName(uniqueName("SurfaceTests")))

        surface.show(anchorRect: nil)
        surface.select(.groups)

        let window = try #require(surface.shell.window)
        #expect(window.frame.size == AppSurfaceController.groupsDefaultContentSize,
                "the real split view mounts at the designed size, not a 500×500 fallback")
        let screen = try #require(surface.test_groupsScreen)
        screen.view.layoutSubtreeIfNeeded()
        #expect(screen.content.view.frame.height > 0,
                "the hosted split view has real height (it is laid out, not collapsed)")
    }

    /// The Groups screen is a SPLIT: speakers/groups sidebar on the left,
    /// editor pane on the right. Both halves must be mounted, laid out and
    /// side by side at the surface's real Groups size — a screen showing only
    /// the editor has no way to change selection at all. Hand the surface the
    /// content half alone, or drop the sidebar split item, and this fails.
    @Test func theGroupsScreenShowsTheSidebarAndTheEditor() throws {
        let backend = MockBackend(fleet: .demoFleet, staggerDiscovery: false,
                                  emitsLevels: false, simulatesDropouts: false)
        backend.start()
        let groupController = GroupController(backend: backend,
                                              store: GroupStore(directory: scratchDir),
                                              loadPersisted: false)
        // A saved group over a fully-discovered fleet, so the screen
        // auto-selects it and mounts a POPULATED editor pane — the state the
        // live regression was reported in.
        _ = try groupController.createGroup(name: "Group 1",
                                            memberIDs: ["sonos-move", "office"])
        let groups = MixerWindowController(groupController: groupController)
        groups.test_isVisibleOverride = true
        groups.update(devices: backend.devices)
        let popover = PopoverController(
            appRouting: AppRoutingController(store: AppRouteStore(directory: scratchDir),
                                             loadPersisted: false),
            runningAppsProvider: { [] })
        let surface = AppSurfaceController(
            popoverController: popover,
            settings: AppSettings(defaults: isolatedDefaults),
            groupsContent: { groups.contentController },
            settingsContent: { [self] in makeSettingsRoot() },
            frameAutosaveName: NSWindow.FrameAutosaveName(uniqueName("SurfaceTests")))

        surface.show(anchorRect: nil)
        // Reach Groups the way a user does — via the NARROWER Settings screen.
        // `mount` restores the outgoing screen's frame before animating to the
        // incoming one, so the split view is laid out at Settings' 460 first.
        surface.select(.settings)
        surface.shell.window?.contentView?.layoutSubtreeIfNeeded()
        surface.select(.groups)
        let screen = try #require(surface.test_groupsScreen)
        screen.view.layoutSubtreeIfNeeded()

        let split = try #require(screen.content as? NSSplitViewController,
                                 "the Groups screen's content IS the split view controller")
        #expect(split.splitViewItems.count == 2, "sidebar item + content item")
        #expect(split.splitViewItems.first?.isCollapsed == false,
                "the sidebar item is not collapsed")

        let sidebar = groups.test_sidebar.view
        let editor = groups.test_editor.view
        #expect(sidebar.isDescendant(of: screen.view),
                "the speakers/groups sidebar is mounted in the Groups screen")
        #expect(editor.isDescendant(of: screen.view),
                "the editor pane is mounted beside the sidebar")
        #expect(!sidebar.isHiddenOrHasHiddenAncestor, "and it is not hidden")

        // Compare in ONE coordinate space — the two panes have different
        // superviews, so raw `frame`s are not comparable.
        let sidebarBox = sidebar.convert(sidebar.bounds, to: screen.view)
        let editorBox = editor.convert(editor.bounds, to: screen.view)
        #expect(sidebarBox.width >= 200 && sidebarBox.height > 0,
                "the sidebar gets its real width, not a zero-width sliver (got \(sidebarBox))")
        #expect(editorBox.width > 0 && editorBox.height > 0,
                "the editor pane gets real space (got \(editorBox))")
        #expect(editorBox.minX >= sidebarBox.maxX - 1,
                "editor sits to the RIGHT of the sidebar — a real split, not a stack")
    }

    // MARK: Visible-screen publishing (the Groups content's hidden-work gate)

    @Test func visibleScreenIsPublishedOnShowSwitchAndClose() {
        let (surface, _, _, _) = makeSurface()
        var published: [SurfaceScreen?] = []
        surface.onVisibleScreenChange = { published.append($0) }

        surface.show(anchorRect: nil)
        surface.show(anchorRect: nil)          // re-front: same visible screen
        surface.select(.groups)
        surface.select(.groups)                // no-op switch
        surface.shell.test_isPanelVisibleOverride = true
        surface.performClose()

        #expect(published == [.mixer, .groups, nil],
                "one announcement per real change — a re-front or a no-op switch is not one")
    }

    @Test func aScreenSwitchWhileClosedAnnouncesNothing() {
        let (surface, _, _, _) = makeSurface()
        var published: [SurfaceScreen?] = []
        surface.onVisibleScreenChange = { published.append($0) }

        surface.select(.groups)

        #expect(published.isEmpty, "nothing is visible, so nothing became visible")
        #expect(surface.visibleScreen == nil)
    }
}
