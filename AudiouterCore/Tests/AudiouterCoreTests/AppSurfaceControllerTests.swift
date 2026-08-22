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
/// PLAN-ONE-SURFACE-032; header reworked to a native window toolbar by the
/// live-review D1): screen switching (lazy build, `setContent` routing,
/// per-screen sizes), the Mixer's `surfaceDidShow`/`surfaceDidHide` lifecycle,
/// pin persistence, toolbar state sync, ⌘1/⌘2/⌘3, and the toolbar chrome
/// inset. Headless: nothing here ever orders a window on screen
/// (`HeadlessRuntime` gates the shell's presentation calls), so every
/// assertion reads window/controller STATE, never visibility.
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
        SettingsRootViewController(sections: [
            .init(title: "General", symbolName: "gearshape", viewController: makePane(height: 200)),
            .init(title: "Appearance", symbolName: "paintpalette", viewController: makePane(height: 300)),
            .init(title: "Audio", symbolName: "speaker.wave.2", viewController: makePane(height: 420)),
        ])
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
                vc.view = NSView(frame: NSRect(x: 0, y: 0, width: 623, height: 464))
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

    /// One frame for the whole session, so a drag affordance would only ever
    /// fight it: the resize bit is flipped OFF once at construction and no
    /// screen and no manner profile flips it back.
    @Test func noScreenIsEverUserResizable() throws {
        let (surface, _, _, _) = makeSurface()
        surface.show(anchorRect: nil)
        #expect(!surface.shell.isUserResizable, "the Mixer wears the fixed frame")

        surface.select(.groups)
        #expect(!surface.shell.isUserResizable, "Groups has no drag memory any more")

        surface.select(.settings)
        #expect(!surface.shell.isUserResizable)

        surface.select(.mixer)
        #expect(!surface.shell.isUserResizable)

        // Pinning is a manner change, not a resize.
        surface.setPinned(true)
        #expect(!surface.shell.isUserResizable)
        surface.select(.groups)
        #expect(!surface.shell.isUserResizable, "Groups is not resizable pinned either")
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

    /// The whole contract in one test: one frame, measured once at open from
    /// the Mixer, worn unchanged by every screen — same SIZE and same ORIGIN,
    /// because a window that moves under the cursor on a tab click reads as
    /// the surface twitching.
    @Test func oneFrameForEveryScreen() throws {
        let (surface, _, _, _) = makeSurface()
        surface.show(anchorRect: NSRect(x: 900, y: 1000, width: 30, height: 24))
        let window = try #require(surface.shell.window)
        let panel = try #require(surface.test_mixerPanel)
        let frame = window.frame

        let contentHeight = window.contentRect(forFrameRect: frame).height
        #expect(abs(contentHeight - max(600, panel.preferredContentSize.height)) < 0.5,
                "the frame is the Mixer's fit, floored at 600 (got \(contentHeight))")
        #expect(frame.width == 623, "the one fixed width")

        surface.select(.groups)
        #expect(window.frame == frame, "Groups wears the same frame, and does not move it")
        surface.select(.settings)
        #expect(window.frame == frame, "so does Settings")
        surface.select(.mixer)
        #expect(window.frame == frame, "and coming back changes nothing")

        surface.togglePin()
        #expect(window.frame.size == frame.size, "a pin flip is a manner change, not a resize")
    }

    /// Settings sections swap content behind fixed glass — the pane host
    /// scrolls, the window does not move.
    @Test func settingsSectionSwitchLeavesTheFrameAlone() throws {
        let (surface, _, _, _) = makeSurface()
        surface.show(anchorRect: nil)
        surface.select(.settings)
        let window = try #require(surface.shell.window)
        let root = try #require(surface.test_settingsRoot)

        let frame = window.frame
        root.selectSection(at: 2)
        #expect(window.frame == frame,
                "the tallest section must not resize the surface")
    }

    /// A fold moves rows INSIDE the frame. The content's published size
    /// changes (that is what a collapse is); the window's frame must not.
    @Test func foldsNeverMoveTheFrame() throws {
        let (surface, popover, _, _) = makeSurface()
        surface.show(anchorRect: nil)
        let window = try #require(surface.shell.window)
        let panel = try #require(surface.test_mixerPanel)

        let frame = window.frame
        let fit = panel.preferredContentSize.height
        _ = popover.test_toggleCard(title: PopoverController.outputDevicesCardTitle)
        #expect(panel.preferredContentSize.height != fit, "the content really moved")
        #expect(window.frame == frame, "…inside the frame, which did not")

        _ = popover.test_toggleCard(title: PopoverController.outputDevicesCardTitle)
        #expect(window.frame == frame, "and un-folding does not move it back")
    }

    /// The floor is a floor, not the size: a Mixer with a real fleet fits
    /// taller than 600, and the frame follows it — up to the screen.
    @Test func theMixerFitRaisesTheHeightAboveTheFloor() throws {
        let backend = MockBackend(fleet: .demoFleet, staggerDiscovery: false,
                                  emitsLevels: false, simulatesDropouts: false)
        backend.start()
        let popover = PopoverController(
            appRouting: AppRoutingController(store: AppRouteStore(directory: scratchDir),
                                             loadPersisted: false),
            runningAppsProvider: { [] })
        popover.test_isShownOverride = true
        popover.update(devices: backend.devices)
        let surface = AppSurfaceController(
            popoverController: popover,
            settings: AppSettings(defaults: isolatedDefaults),
            groupsContent: { NSViewController() },
            settingsContent: { [self] in makeSettingsRoot() },
            frameAutosaveName: NSWindow.FrameAutosaveName(uniqueName("SurfaceTests")))

        surface.show(anchorRect: nil)
        let window = try #require(surface.shell.window)
        let panel = try #require(surface.test_mixerPanel)

        let contentHeight = window.contentRect(forFrameRect: window.frame).height
        #expect(abs(contentHeight - max(600, panel.preferredContentSize.height)) < 0.5,
                "the fit decides the height once it clears the floor (got \(contentHeight))")
        let visible = try #require(NSScreen.main).visibleFrame.height
        #expect(window.frame.height <= visible - 16,
                "…and the screen caps it (got \(window.frame.height), cap \(visible - 16))")
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

    @Test func toolbarChromeInsetSeatsContentBelowTheStripInBothProfiles() throws {
        let (surface, _, _, _) = makeSurface()
        surface.show(anchorRect: nil)
        surface.select(.groups)
        let groupsScreen = try #require(surface.test_groupsScreen)
        let panel = try #require(surface.test_mixerPanel)

        // The toolbar strip overlaps `.fullSizeContentView` content in BOTH
        // manner profiles now — the inset is measured, never zero.
        let unpinnedInset = surface.test_chromeTopInset
        #expect(unpinnedInset > 0, "the unified toolbar strip costs real height unpinned")
        #expect(groupsScreen.test_contentTopInset == unpinnedInset,
                "screens seat below the measured strip")
        #expect(panel.test_contentTopInset == unpinnedInset,
                "the Mixer panel insets its own content")

        surface.togglePin()
        let pinnedInset = surface.test_chromeTopInset
        #expect(pinnedInset > 0, "pinned keeps the one toolbar strip — no separate title bar")
        #expect(groupsScreen.test_contentTopInset == pinnedInset)
        #expect(panel.test_contentTopInset == pinnedInset)
    }

    // MARK: Toolbar header — the one strip, host-synced (D1)

    @Test func toolbarIsAttachedUnifiedWithTitleHidden() throws {
        let (surface, _, _, _) = makeSurface()
        let window = try #require(surface.shell.window)
        #expect(window.toolbar === surface.test_toolbarController.toolbar,
                "the surface's toolbar IS the shell window's toolbar")
        #expect(window.toolbarStyle == .unified)
        #expect(window.titleVisibility == .hidden,
                "no separate title bar ever — the centered toolbar item carries the name")
        #expect(surface.test_toolbarController.test_centeredTitleText == "Audiouter")
    }

    @Test func toolbarTracksSelectionAndPin() {
        let (surface, _, _, _) = makeSurface()
        surface.show(anchorRect: nil)
        surface.select(.groups)
        surface.select(.settings)
        #expect(surface.test_toolbarController.selectedScreen == .settings,
                "the toolbar shows the selected tab")

        surface.select(.groups)
        #expect(surface.test_toolbarController.selectedScreen == .groups,
                "a switch between built screens re-syncs the toolbar")

        surface.togglePin()
        #expect(surface.test_toolbarController.isPinned, "the toolbar shows the pinned state")
    }

    @Test func toolbarTabTapSwitchesTheScreen() {
        let (surface, _, _, _) = makeSurface()
        surface.show(anchorRect: nil)

        surface.test_toolbarController.test_selectTab(.groups)

        #expect(surface.selectedScreen == .groups, "a toolbar tab IS the screen switch")
        #expect(surface.test_hostedContentViewController === surface.test_groupsScreen)
    }

    @Test func toolbarPinTapTogglesTheSurfacePin() {
        let (surface, _, _, _) = makeSurface()
        surface.show(anchorRect: nil)

        surface.test_toolbarController.test_tapPin()
        #expect(surface.isPinned, "the toolbar Pin item drives the surface's pin flip")
        surface.test_toolbarController.test_tapPin()
        #expect(!surface.isPinned)
    }

    /// ⌘1/⌘2/⌘3 moved from the retired header buttons' key equivalents to the
    /// shell panel's pre-dispatch seam (a toolbar item group carries none).
    @Test func commandNumberShortcutsSelectScreensThroughTheShellSeam() throws {
        let (surface, _, _, _) = makeSurface()
        surface.show(anchorRect: nil)
        let handler = try #require(surface.shell.keyEquivalentHandler,
                                   "the surface installs the shortcut handler")

        func keyEvent(_ character: String, command: Bool) -> NSEvent? {
            NSEvent.keyEvent(with: .keyDown, location: .zero,
                             modifierFlags: command ? [.command] : [],
                             timestamp: 0, windowNumber: 0, context: nil,
                             characters: character, charactersIgnoringModifiers: character,
                             isARepeat: false, keyCode: 0)
        }

        let cmd2 = try #require(keyEvent("2", command: true))
        #expect(handler(cmd2), "⌘2 is consumed")
        #expect(surface.selectedScreen == .groups)

        let cmd3 = try #require(keyEvent("3", command: true))
        #expect(handler(cmd3), "⌘3 is consumed")
        #expect(surface.selectedScreen == .settings)

        let cmd1 = try #require(keyEvent("1", command: true))
        #expect(handler(cmd1), "⌘1 is consumed")
        #expect(surface.selectedScreen == .mixer)

        let bare2 = try #require(keyEvent("2", command: false))
        #expect(!handler(bare2), "an un-modified key falls through to stock dispatch")
        #expect(surface.selectedScreen == .mixer)
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
        // The dismissal decides a runloop pass later; headless, nothing turns.
        surface.shell.test_settleResignDismissal()
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

    /// (R7) A sheet-bearing unpinned surface (e.g. the New Group sheet) must
    /// not be handed `.dismiss`: `performClose` refuses on a window with an
    /// attached sheet and AppKit beeps, while the sheet survives untouched
    /// anyway — a beep with no effect. The click should front the window
    /// instead, bringing the sheet to the user.
    @Test func sheetBearingSurfaceFrontsInsteadOfDismissing() {
        let (surface, _, _, _) = makeSurface()
        surface.show(anchorRect: nil)
        surface.shell.test_isPanelVisibleOverride = true
        surface.shell.test_hasAttachedSheetOverride = true
        var closes = 0
        surface.onClose = { closes += 1 }

        let action = surface.clickAction(setupIsOpen: false)
        surface.perform(action, anchorRect: nil)

        #expect(action == .front, "not .dismiss — that would beep and leave the sheet stranded")
        #expect(closes == 0, "the sheet-bearing surface is never closed by this click")
        #expect(surface.isShown)
    }

    /// The same sheet guard applies before a click even reaches the
    /// pinned/unpinned split — a sheet on a currently-closed (pinned, reopening)
    /// surface still just shows, never dismisses (there's nothing to dismiss).
    @Test func sheetBearingClosedSurfaceStillShows() {
        let (surface, _, _, _) = makeSurface()
        surface.shell.test_isPanelVisibleOverride = false
        surface.shell.test_hasAttachedSheetOverride = true

        #expect(surface.clickAction(setupIsOpen: false) == .show)
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
        let window = try #require(surface.shell.window)
        let frameBefore = window.frame
        surface.select(.groups)

        #expect(window.frame == frameBefore,
                "the real split view mounts INTO the session frame: it neither snaps the window to a 500×500 fallback nor widens it to its own minimum")
        let screen = try #require(surface.test_groupsScreen)
        screen.view.layoutSubtreeIfNeeded()
        #expect(screen.content.view.frame.height > 0,
                "the hosted split view has real height (it is laid out, not collapsed)")
    }

    /// The one header must be a FIXED landmark: the tab strip sits where it
    /// sits, on every screen. The regression this pins (live build, 2026-08-22)
    /// was AppKit's, not ours — a split view item built with
    /// `sidebarWithViewController:` defaults to full-height layout, which makes
    /// the window reserve the toolbar's leading region for the sidebar and
    /// slides every toolbar item right by the sidebar's width for as long as
    /// that screen is mounted. Both sidebar-bearing screens (Groups, Settings)
    /// therefore opt out. Measured on the REAL content, since a stub screen has
    /// no sidebar to trigger it. The picker view is private AppKit, matched by
    /// class NAME like `SurfaceToolbarTests` does.
    @Test func theTabStripNeverMovesAcrossScreens() throws {
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
        let window = try #require(surface.shell.window)

        func tabStripLeadingX() throws -> CGFloat {
            window.layoutIfNeeded()
            let themeFrame = try #require(window.contentView?.superview)
            let picker = try #require(firstView(in: themeFrame,
                                                namedLike: "NSToolbarItemGroupPicker"),
                                      "the tab group's picker view is in the window's chrome")
            return picker.convert(picker.bounds, to: themeFrame).minX
        }

        // Mixer twice: the first layout pass of a freshly attached toolbar
        // settles the group's width, so the SECOND visit is the reference.
        _ = try tabStripLeadingX()
        surface.select(.groups)
        surface.select(.mixer)
        let onMixer = try tabStripLeadingX()

        surface.select(.groups)
        #expect(try tabStripLeadingX() == onMixer,
                "the Groups sidebar must not push the tab strip right")
        surface.select(.settings)
        #expect(try tabStripLeadingX() == onMixer,
                "nor may the Settings sidebar")
        surface.select(.mixer)
        #expect(try tabStripLeadingX() == onMixer, "and it comes back unchanged")
    }

    private func firstView(in root: NSView, namedLike name: String) -> NSView? {
        if String(describing: type(of: root)).contains(name) { return root }
        for subview in root.subviews {
            if let hit = firstView(in: subview, namedLike: name) { return hit }
        }
        return nil
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
        // Reach Groups via the Settings screen, so the split is laid out after
        // a swap.
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

    // MARK: The fixed frame's two hard budgets

    /// The Groups editor pane has NO scroll view, so whatever the frame gives
    /// it at the FLOOR is a hard budget — the popover here has no devices, so
    /// the Mixer's fit cannot raise the height and the floor is what the
    /// screen gets. If this fails, raise
    /// `AppSurfaceController.minimumContentSize`; never let the editor
    /// overflow.
    @Test func theSevenDeviceEditorFitsTheMinimumFrame() throws {
        let (surface, groups, groupID) = try makeRealGroupsSurface()
        surface.show(anchorRect: nil)
        surface.select(.groups)
        groups.test_select(.group(id: groupID))
        let screen = try #require(surface.test_groupsScreen)
        screen.view.layoutSubtreeIfNeeded()

        let editor = groups.test_editor.view
        #expect(editor.fittingSize.height <= editor.frame.height,
                Comment(rawValue: "the editor needs \(editor.fittingSize.height)pt but the "
                        + "fixed frame gives the pane \(editor.frame.height)pt. The pane has "
                        + "no scroll view, so this is an overflow, not a preference — raise "
                        + "AppSurfaceController.minimumContentSize."))
    }

    /// AppKit widens a window to its content's fitting width, and this window
    /// must never widen. Every Groups pane — a group, a device, Main Out —
    /// has to stay inside the frame.
    @Test func noGroupsPaneAsksForMoreThanTheFrameWidth() throws {
        let (surface, groups, groupID) = try makeRealGroupsSurface()
        surface.show(anchorRect: nil)
        surface.select(.groups)
        let screen = try #require(surface.test_groupsScreen)
        let window = try #require(surface.shell.window)

        for selection in [SidebarSelection.group(id: groupID),
                          .device(id: "office"),
                          .mainOut] {
            groups.test_select(selection)
            screen.view.layoutSubtreeIfNeeded()
            #expect(screen.content.view.fittingSize.width <= 623,
                    Comment(rawValue: "\(selection) asks for "
                            + "\(screen.content.view.fittingSize.width)pt of width"))
            #expect(window.frame.width == 623,
                    Comment(rawValue: "\(selection) widened the window"))
        }
    }

    /// The real Groups content over a discovered fleet with one saved group,
    /// hosted on a surface whose popover has NO devices — so the Mixer's fit
    /// cannot raise the frame above the floor and both budget tests measure
    /// the worst case.
    private func makeRealGroupsSurface() throws
        -> (AppSurfaceController, MixerWindowController, String) {
        let backend = MockBackend(fleet: .demoFleet, staggerDiscovery: false,
                                  emitsLevels: false, simulatesDropouts: false)
        backend.start()
        let groupController = GroupController(backend: backend,
                                              store: GroupStore(directory: scratchDir),
                                              loadPersisted: false)
        let group = try groupController.createGroup(name: "Group 1",
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
        return (surface, groups, group.group.id)
    }
}
