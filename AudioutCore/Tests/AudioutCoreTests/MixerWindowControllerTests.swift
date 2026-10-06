// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
import AppKit
@testable import AudioutCore
@testable import AudioutSharedUI
@testable import AudioutWindowUI

/// Structural + integration coverage for the Groups SCREEN's content
/// controller (design revamp, SPEC §9; the standalone window was retired in
/// U6). The content isn't visible to CI, so these assert the *built*
/// structure and that interactions call through the model — the same
/// checks the `window-harness` executable runs, folded into `swift test`.
///
/// The screen is CONFIGURATION-ONLY under the revamp: viewing/editing groups
/// here never activates them or moves audio (activation lives in the app's
/// Mixer screen). Group creation is a standard macOS sheet
/// (`GroupCreationSheetController`), not an in-pane draft.
///
/// `MixerWindowController` is `@MainActor`; these cases are `@MainActor` so they
/// touch it (and the non-`Sendable` `GroupController`) on the main thread,
/// exactly as the app does.
@MainActor
@Suite final class MixerWindowControllerTests: IsolatedSuite {

    // Turns red when the sidebar's Hide stops writing through the shared library, or a detail lookup consults only the live dictionary so remembered speakers become unreachable.
    @Test func speakersNavigationAndRememberedDetailUseSharedPreferences() throws {
        let backend = MockBackend(fleet: [])
        let controller = GroupController(backend: backend, store: GroupStore(directory: scratchDir),
            routingStore: RoutingStore(directory: scratchDir),
            settings: AppSettings(defaults: isolatedDefaults), loadPersisted: false)
        let bt = Device(id: "bt", name: "Remembered", kind: .bluetooth)
        let library = SpeakerLibraryController(loadPersisted: false)
        library.update(liveDevices: [bt], groups: [])
        library.setVisibility(.always, for: "bt")
        library.update(liveDevices: [], groups: [])
        let window = MixerWindowController(groupController: controller,
            settings: AppSettings(defaults: isolatedDefaults), speakerLibrary: library)
        window.test_isVisibleOverride = true
        window.update(devices: [])
        window.select(.speakersOverview)
        #expect(window.test_isShowingSpeakersPage)
        #expect(window.test_sidebar.test_clickContextMenuItem("Hide from Mixer", for: .device(id: "bt")))
        #expect(library.visibility(for: "bt") == .hideWhenNotInUse)
        #expect(window.test_sidebar.test_deviceRowIDs(inGroupTitled: "Hidden unless in use") == ["bt"])
        window.select(.device(id: "bt"))
        #expect(window.test_isShowingDetail)
        #expect(window.test_detail.test_subtitleText == "Bluetooth Speaker · Not connected")
        #expect(window.test_pendingSelection == nil)
        let count = window.test_sidebarReloadCount
        library.setVisibility(.always, for: "bt")
        window.refreshSpeakerPresentation()
        #expect(window.test_sidebarReloadCount == count + 1)
        window.refreshSpeakerPresentation()
        #expect(window.test_sidebarReloadCount == count + 1)
        #expect(controller.activeGroupID == nil)
        #expect(!controller.isSpeakerSelected("bt"))
    }

    // Capturing volumes from rendering records replaces live levels with synthetic zero for remembered members.
    @Test func sceneCreationAndEditorCaptureOnlyLiveMemberVolumes() throws {
        let controller = GroupController(backend: MockBackend(fleet: []),
            store: GroupStore(directory: scratchDir), routingStore: RoutingStore(directory: scratchDir),
            settings: AppSettings(defaults: isolatedDefaults), loadPersisted: false)
        var live = Device(id: "live", name: "Live", kind: .sonos, volume: 63)
        let other = Device(id: "other", name: "Other", kind: .sonos, volume: 37)
        let remembered = Device(id: "remembered", name: "Remembered", kind: .bluetooth, volume: 91)
        let library = SpeakerLibraryController(loadPersisted: false)
        library.update(liveDevices: [live, other, remembered], groups: [])
        library.setVisibility(.always, for: remembered.id)
        library.update(liveDevices: [live, other], groups: [])
        controller.updateDevices([live, other])
        let window = MixerWindowController(groupController: controller,
            settings: AppSettings(defaults: isolatedDefaults), speakerLibrary: library)
        window.test_isVisibleOverride = true
        window.update(devices: [live, other])
        window.test_presentCreateSheet(preselected: [live.id, remembered.id])
        let sheet = try #require(window.test_createSheet)
        sheet.test_setName("Saved levels")
        sheet.test_commit()
        let created = try #require(controller.groups.first)
        #expect(Set(created.memberIDs) == [live.id, remembered.id])
        #expect(created.memberVolumes[live.id] == 63)
        #expect(created.memberVolumes[remembered.id] == nil)

        live.volume = 81
        controller.updateDevices([live, other])
        library.update(liveDevices: [live, other], groups: controller.groups)
        window.update(devices: [live, other])
        window.select(.group(id: created.id))
        window.test_editor.test_setMembership(true, for: other.id)
        window.test_editor.test_setMembership(false, for: remembered.id)
        window.test_editor.test_setMembership(true, for: remembered.id)
        let edited = try #require(controller.groups.first)
        #expect(edited.memberVolumes[live.id] == 63)
        #expect(edited.memberVolumes[other.id] == 37)
        #expect(edited.memberVolumes[remembered.id] == nil)
        #expect(Set(edited.memberIDs) == [live.id, other.id, remembered.id])
        #expect(controller.activeGroupID == nil)
        #expect(!controller.isSpeakerSelected(live.id))
    }

    /// A MockBackend with the full demo fleet discovered, a GroupController, and
    /// a `MixerWindowController` with the devices pushed in.
    private func makeWindow() async throws -> (MixerWindowController, GroupController, MockBackend) {
        let backend = MockBackend(fleet: .demoFleet, staggerDiscovery: false,
                                  emitsLevels: false, simulatesDropouts: false)
        try await waitForFleet(backend, count: 7)
        let store = GroupStore(directory: tempDirectory())
        let controller = GroupController(backend: backend, store: store,
            routingStore: RoutingStore(directory: scratchDir),
            settings: AppSettings(defaults: isolatedDefaults), loadPersisted: false)
        let window = MixerWindowController(groupController: controller,
                                           settings: AppSettings(defaults: isolatedDefaults))
        // Headless test seam: simulate the content being visible so update(devices:)
        // refreshes the UI tree (same pattern: PopoverController.test_isShownOverride / B8).
        window.test_isVisibleOverride = true
        window.update(devices: backend.devices)
        return (window, controller, backend)
    }

    /// Compose a two-AirPlay-device Selected Devices set and save it as a group
    /// ("Group 1"). Under the SPEC §9b model `saveCurrentSetupAsGroup` builds from
    /// the Selected Devices set, so tests that want a populated group compose it
    /// first via this helper.
    @discardableResult
    private func makeGroup1(_ controller: GroupController) throws -> Group {
        _ = controller.setDeviceSelected("sonos-move", true)
        _ = controller.setDeviceSelected("office", true)
        return try controller.saveCurrentSetupAsGroup(name: "Group 1").group
    }

    private func waitForFleet(_ backend: MockBackend, count: Int) async throws {
        let stream = backend.makeEventStream()
        let box = WindowTestCountBox()
        try await confirmation("fleet discovered") { discovered in
            let task = Task {
                for await event in stream {
                    if case .deviceAdded = event, await box.increment() >= count {
                        discovered(); break
                    }
                }
            }
            defer { task.cancel() }
            backend.start()
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { _ = await task.value }
                group.addTask { try await Task.sleep(for: .seconds(2)) }
                try await group.next()
                group.cancelAll()
            }
        }
    }

    /// Like `makeWindow()`, but also constructs and injects a
    /// `DeviceIconController` (non-persisted, its own temp store) so a test
    /// can drive icon overrides and assert they reach a shared mixer row.
    private func makeWindowWithIconController() async throws
        -> (MixerWindowController, GroupController, MockBackend, DeviceIconController) {
        let backend = MockBackend(fleet: .demoFleet, staggerDiscovery: false,
                                  emitsLevels: false, simulatesDropouts: false)
        try await waitForFleet(backend, count: 7)
        let store = GroupStore(directory: tempDirectory())
        let controller = GroupController(backend: backend, store: store,
            routingStore: RoutingStore(directory: scratchDir),
            settings: AppSettings(defaults: isolatedDefaults), loadPersisted: false)
        let iconController = DeviceIconController(store: DeviceIconStore(directory: tempDirectory()),
                                                   loadPersisted: false)
        let window = MixerWindowController(groupController: controller, deviceIconController: iconController,
                                           settings: AppSettings(defaults: isolatedDefaults))
        // Headless test seam: simulate the content being visible so update(devices:)
        // refreshes the UI tree (same pattern: PopoverController.test_isShownOverride / B8).
        window.test_isVisibleOverride = true
        window.update(devices: backend.devices)
        return (window, controller, backend, iconController)
    }

    private func tempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MixerWindowControllerTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Let queued MockBackend echoes drain before asserting on backend state.
    private func drain() async {
        try? await Task.sleep(nanoseconds: 150_000_000)
    }

    /// Hosted as the surface's Scenes and Speakers screens this controller
    /// owns no window, so `setVisibleTab(_:)` is what tells it the
    /// user is looking at its content. Turning it on must CATCH UP on whatever
    /// arrived while it was hidden — otherwise every speaker discovered before
    /// the Groups tab was first opened would be missing from the sidebar for
    /// the rest of the session.
    @Test func hostVisibilityOpensTheRefreshGateAndCatchesUp() async throws {
        let backend = MockBackend(fleet: .demoFleet, staggerDiscovery: false,
                                  emitsLevels: false, simulatesDropouts: false)
        try await waitForFleet(backend, count: 7)
        let store = GroupStore(directory: tempDirectory())
        let controller = GroupController(backend: backend, store: store,
            routingStore: RoutingStore(directory: scratchDir),
            settings: AppSettings(defaults: isolatedDefaults), loadPersisted: false)
        let window = MixerWindowController(groupController: controller,
                                           settings: AppSettings(defaults: isolatedDefaults))

        window.update(devices: backend.devices)
        #expect(window.test_sidebar.test_deviceRowCount == 0,
                "no host is showing the content, so the snapshot is only stored (B8)")

        window.setVisibleTab(.speakers)
        #expect(window.test_sidebar.test_deviceRowCount == 7,
                "becoming the visible screen refreshes from the stored snapshot")
    }

    // Turns red when a backend update repaints the sidebar while only the Scenes tab is on screen.
    @Test func scenesOnScreenLeaveTheSidebarAlone() {
        let controller = GroupController(backend: MockBackend(fleet: []), store: GroupStore(directory: scratchDir),
            routingStore: RoutingStore(directory: scratchDir),
            settings: AppSettings(defaults: isolatedDefaults), loadPersisted: false)
        let window = MixerWindowController(groupController: controller,
                                           settings: AppSettings(defaults: isolatedDefaults))
        window.setVisibleTab(.scenes)
        window.update(devices: [Device(id: "a", name: "Alpha", kind: .sonos),
                                Device(id: "b", name: "Beta", kind: .homePod)])
        #expect(window.test_sidebarReloadCount == 0)
        #expect(window.test_sidebar.test_deviceRowCount == 0)

        window.setVisibleTab(.speakers)
        #expect(window.test_sidebar.test_deviceRowCount == 2, "showing Speakers catches the sidebar up")
    }

    // Turns red when the Speakers page rebuilds for a Bluetooth access change while its tab is hidden, misses it once the tab shows, the controller stops handing the search's can't-be-found list to the page, the sidebar or the speaker page, or a Bluetooth access change repaints only the Overview so the sidebar keeps its old list.
    @Test func aHiddenSpeakersPageStoresItsStateAndCatchesUpWhenShown() throws {
        let controller = GroupController(backend: MockBackend(fleet: []), store: GroupStore(directory: scratchDir),
            routingStore: RoutingStore(directory: scratchDir),
            settings: AppSettings(defaults: isolatedDefaults), loadPersisted: false)
        try controller.saveGroup(Group(id: "porch", name: "Porch", memberIDs: ["live", "den"], memberVolumes: [:]))
        let library = SpeakerLibraryController(loadPersisted: false)
        let live = Device(id: "live", name: "Live", kind: .sonos)
        library.update(liveDevices: [live, Device(id: "headset", name: "Headset", kind: .bluetooth)],
                       groups: controller.groups, confirmedUsedIDs: ["headset"])
        library.update(liveDevices: [live], groups: controller.groups)
        let window = MixerWindowController(groupController: controller,
            settings: AppSettings(defaults: isolatedDefaults), speakerLibrary: library)
        window.setVisibleTab(.scenes)
        let page = window.test_speakersPage
        let before = page.test_rowTitles

        var pending: [() -> Void] = []
        let search = SpeakerSearch(library: library, schedule: { _, fire in pending.append(fire) })
        var bluetoothGranted = false
        search.isBluetoothAccessGranted = { bluetoothGranted }
        // Filled before it hears the list, so the counts event never fires into another suite's sink.
        search.pageDidAppear()
        while !pending.isEmpty { pending.removeFirst()() }
        search.libraryDidChange()
        window.speakerSearch = search
        window.setSpeakerBluetoothAccess(SpeakerBluetoothAccessPresentation(status: .unknown, priming: false))
        #expect(page.test_rowTitles == before, "a hidden page only stores what it is told")

        window.setVisibleTab(.speakers)
        #expect(page.test_rowTitles == ["1 speaker can\u{2019}t be found", "Bluetooth access is off",
                                        "Pair Bluetooth speaker\u{2026}"])
        #expect(window.test_sidebar.test_contextMenuItems(for: .device(id: "den"))
                    .contains("Forget \u{201C}Missing speaker\u{201D}\u{2026}"))
        window.select(.device(id: "den"))
        #expect(window.test_detail.test_subtitleText == "Can\u{2019}t be found")

        let forgetHeadset = "Forget \u{201C}Headset\u{201D}\u{2026}"
        #expect(!window.test_sidebar.test_contextMenuItems(for: .device(id: "headset")).contains(forgetHeadset))
        bluetoothGranted = true
        window.setSpeakerBluetoothAccess(SpeakerBluetoothAccessPresentation(status: .granted, priming: false))
        #expect(window.test_sidebar.test_contextMenuItems(for: .device(id: "headset")).contains(forgetHeadset))
    }

    // MARK: Sidebar structure (the fleet, beside the Speakers page)

    // Turns red when the sidebar regains a scenes row or the split stops starting on the Speakers page.
    @Test func sidebarIsTheFleetBesideTheSpeakersPage() async throws {
        let (window, _, _) = try await makeWindow()
        #expect(window.test_sidebar.test_sectionTitles == ["System Audio", "Speakers", "Shown in Mixer"],
                "scenes live on their own screen; the speakers sit in their visibility group")
        #expect(window.test_isShowingSpeakersPage, "with nothing selected the split shows the Speakers page")
        #expect(window.test_sidebar.test_deviceRowCount == 7)
        #expect(!(window.test_isShowingEditor))
    }

    /// The sidebar must survive every route to a collapse. A collapsed sidebar
    /// is unrecoverable — no toolbar sidebar toggle, no View menu, and this
    /// controller is reused for the process lifetime — and it is the ONLY way
    /// to change selection, so a collapse strands the user on one group's
    /// editor. `canCollapse` refuses the user's divider drag; the refresh
    /// re-assert covers AppKit's own narrow-layout auto-collapse.
    @Test func theSidebarCannotBeCollapsedAway() async throws {
        let (window, controller, backend) = try await makeWindow()
        let split = try #require(window.speakersContentController as? NSSplitViewController)
        let sidebarItem = try #require(split.splitViewItems.first)
        #expect(!sidebarItem.canCollapse, "the user's divider drag cannot collapse it")

        // AppKit's own auto-collapse takes this route; recovery is on us.
        sidebarItem.isCollapsed = true
        _ = try makeGroup1(controller)
        window.update(devices: backend.devices)
        #expect(!sidebarItem.isCollapsed, "a refresh restores a collapsed sidebar")
        #expect(window.test_sidebar.test_sectionTitles == ["System Audio", "Speakers", "Shown in Mixer"],
                "and it still lists every section")
    }

    @Test func baselineContentIsTheOverviewsEmptyCanvasAtZeroGroups() async throws {
        let (window, _, _) = try await makeWindow()
        #expect(window.test_isShowingScenesOverview, "zero groups + no selection auto-lands on the overview")
        #expect(window.test_overview.test_isShowingEmptyCanvas,
                "with nothing saved the overview IS the empty state — there is no separate pane")
    }

    @Test func emptyCanvasNewGroupTilePresentsCreationSheet() async throws {
        let (window, _, _) = try await makeWindow()
        #expect(window.test_overview.test_isShowingEmptyCanvas)
        // The empty canvas's call-to-action runs the same sheet as the sidebar "+".
        window.test_overview.test_tapNewGroup()
        #expect(window.test_isPresentingCreateSheet)
        window.test_createSheet?.test_cancel()
    }

    // Turns red when the scenes host opens on a scene's editor instead of the card field, or the speakers host leaves the Speakers page with nothing selected.
    @Test func autoSelectLandsOnTheGroupsOverviewNotAGroupsEditor() async throws {
        let (window, controller, backend) = try await makeWindow()
        let saved = try makeGroup1(controller)
        window.update(devices: backend.devices)
        await drain()
        #expect(window.test_isShowingScenesOverview,
                "with a saved group the scenes host shows the card field, not one group's editor")
        #expect(!(window.test_isShowingEditor))
        #expect(window.test_overview.test_cardGroupIDs == [saved.id])
        #expect(window.test_isShowingSpeakersPage, "the speakers host is untouched by scenes")
        #expect(window.test_sidebar.currentSelection == nil)
        #expect(controller.activeGroupID == nil, "auto-select never activates")
    }

    @Test func savingAGroupAddsItsCardAndKeepsAllDevicesListed() async throws {
        let (window, controller, backend) = try await makeWindow()
        let saved = try makeGroup1(controller)
        window.update(devices: backend.devices)

        #expect(window.test_sidebar.test_sectionTitles == ["System Audio", "Speakers", "Shown in Mixer"])
        #expect(window.test_overview.test_cardGroupIDs == [saved.id])
        #expect(!(window.test_overview.test_isShowingEmptyCanvas))
        #expect(window.test_overview.test_chipCount(forCard: saved.id) == saved.memberIDs.count,
                "each member gets a chip along the card's bottom edge")
        #expect(window.test_sidebar.test_deviceRowCount == 7, "the Speakers section lists every device, a saved group's members included")
    }

    // MARK: Overview → editor (the in-pane push on the Scenes screen)

    // Turns red when the two hosts stop being independent: returning the scenes host to its cards disturbs a speaker's page, or the reverse.
    @Test func selectingTheGroupsRowShowsTheOverview() async throws {
        let (window, controller, backend) = try await makeWindow()
        let saved = try makeGroup1(controller)
        window.update(devices: backend.devices)
        window.select(.device(id: "office"))
        window.test_overview.test_clickCard(id: saved.id)
        await drain()
        #expect(window.test_isShowingDetail)
        #expect(window.test_isShowingEditor)

        window.test_select(.groupsOverview)
        await drain()
        #expect(window.test_isShowingScenesOverview)
        #expect(window.test_isShowingDetail, "the speaker's page beside the sidebar stays")
        #expect(window.test_sidebar.currentSelection == .device(id: "office"))
    }

    @Test func openingACardPushesTheEditorAndLeavesTheSidebarAlone() async throws {
        let (window, controller, backend) = try await makeWindow()
        let saved = try makeGroup1(controller)
        window.update(devices: backend.devices)
        await drain()

        window.test_overview.test_clickCard(id: saved.id)
        await drain()

        #expect(window.test_isShowingEditor, "a card opens its group's editor")
        #expect(window.test_editor.editingGroupID == saved.id)
        #expect(window.test_sidebar.currentSelection == nil,
                "the fleet never moves under the pointer — the sidebar is untouched")
        #expect(controller.activeGroupID == nil, "opening a card never activates the group")
    }

    /// A membership edit reaches the card overview at once, not only when the
    /// user walks back to it (live report: removing a speaker left the card
    /// showing its old chips and count, so a group looked like it only ever
    /// grew). The overview is a projection of the same model and its pane is
    /// off screen during the edit, so nothing else was re-reading it.
    @Test func removingAMemberUpdatesTheOverviewCardImmediately() async throws {
        let (window, controller, backend) = try await makeWindow()
        let saved = try makeGroup1(controller)
        window.update(devices: backend.devices)
        window.test_overview.test_clickCard(id: saved.id)
        await drain()
        #expect(window.test_overview.test_chipCount(forCard: saved.id) == 2)

        window.test_editor.test_setMembership(false, for: "office")
        await drain()

        #expect(controller.groups.first { $0.id == saved.id }?.memberIDs == ["sonos-move"],
                "the model drops the member")
        #expect(window.test_overview.test_chipCount(forCard: saved.id) == 1,
                "and the card behind the editor already reflects it")
    }

    @Test func theEditorsBackBandReturnsToTheOverview() async throws {
        let (window, controller, backend) = try await makeWindow()
        let saved = try makeGroup1(controller)
        window.update(devices: backend.devices)
        window.test_overview.test_clickCard(id: saved.id)
        await drain()
        #expect(window.test_isShowingEditor)

        window.test_editor.test_goBack()
        await drain()

        #expect(window.test_isShowingScenesOverview, "'‹ Groups' pops the editor back to the card field")
    }

    /// The surface's Escape asks this: an open editor pops and reports so;
    /// with nothing to pop the answer is `false` and Escape closes the window.
    @Test func dismissEditorPopsAnOpenEditorAndRefusesWhenNoneIsOpen() async throws {
        let (window, controller, backend) = try await makeWindow()
        let saved = try makeGroup1(controller)
        window.update(devices: backend.devices)
        await drain()
        #expect(window.test_isShowingScenesOverview)
        #expect(!window.dismissEditor(), "nothing to step back from")

        window.test_overview.test_clickCard(id: saved.id)
        await drain()
        #expect(window.test_isShowingEditor)

        #expect(window.dismissEditor())
        #expect(window.test_isShowingScenesOverview)
        #expect(!window.dismissEditor(), "a second press has nothing left to pop")
    }

    @Test func doneAndCommandBracketBothReturnToTheOverview() async throws {
        let (window, controller, backend) = try await makeWindow()
        let saved = try makeGroup1(controller)
        window.update(devices: backend.devices)

        window.test_overview.test_clickCard(id: saved.id)
        await drain()
        #expect(window.test_isShowingEditor)
        window.test_editor.test_done()
        await drain()
        #expect(window.test_isShowingScenesOverview, "Done leaves the editor")

        window.test_overview.test_clickCard(id: saved.id)
        await drain()
        #expect(window.test_isShowingEditor)
        #expect(window.test_editor.test_performBackKeyEquivalent(), "the editor claims ⌘[")
        await drain()
        #expect(window.test_isShowingScenesOverview, "⌘[ leaves the editor")
    }

    // Turns red when a deep link to the Overview plate stops showing the Overview or stops lighting its row.
    @Test func selectingTheSpeakersPlateShowsTheSpeakersPage() async throws {
        let (window, _, _) = try await makeWindow()
        window.select(.device(id: "office"))
        #expect(window.test_isShowingDetail)

        window.select(.speakersOverview)

        #expect(window.test_isShowingSpeakersPage)
        #expect(window.test_sidebar.currentSelection == .speakersOverview)
    }

    // Turns red when a scene created from the sidebar's selection stops opening its editor in the scenes host or stops asking the host for the Scenes tab.
    @Test func aSceneCreatedFromTheSidebarOpensOnTheScenesTab() async throws {
        let (window, controller, _) = try await makeWindow()
        var requests = 0
        window.onRequestScenesTab = { requests += 1 }
        window.test_sidebar.test_selectDevices(["office", "sonos-move"])
        window.test_sidebar.test_tapAdd()
        let sheet = try #require(window.test_createSheet)
        sheet.test_commit()
        await drain()

        let group = try #require(controller.groups.first)
        #expect(Set(group.memberIDs) == ["office", "sonos-move"])
        #expect(window.test_isShowingEditor)
        #expect(window.test_editor.editingGroupID == group.id)
        #expect(requests == 1)
        #expect(controller.activeGroupID == nil, "creating never activates")
    }

    /// The card menu inherits the sidebar group row's two items and both of its
    /// flows verbatim — open the editor, then focus the rename field.
    @Test func aCardsRenameOpensTheEditorWithTheRenameFieldFocused() async throws {
        let (window, controller, backend) = try await makeWindow()
        let saved = try makeGroup1(controller)
        window.update(devices: backend.devices)
        await drain()

        #expect(window.test_overview.test_contextMenuItems(forCard: saved.id)
                == ["Rename…", "Delete scene…"])
        window.test_overview.test_clickContextMenuItem("Rename…", forCard: saved.id)
        await drain()

        #expect(window.test_isShowingEditor)
        #expect(window.test_editor.editingGroupID == saved.id)
    }

    @Test func aCardsDeleteRunsTheEditorsConfirmThenDeleteFlow() async throws {
        let (window, controller, backend) = try await makeWindow()
        let saved = try makeGroup1(controller)
        window.update(devices: backend.devices)
        await drain()

        window.test_overview.test_clickContextMenuItem("Delete scene…", forCard: saved.id)
        await drain()
        // The card's Delete lands in the editor's confirm flow. Headless there
        // is no window to host the confirmation sheet, and deleting without
        // one is exactly what the sheet prevents — so nothing is deleted yet
        // (`GroupEditorViewController.deleteTapped`), and `test_confirmDelete()`
        // stands in for the sheet's Delete button.
        #expect(window.test_isShowingEditor, "the confirm flow runs in the group's editor")
        #expect(!controller.groups.isEmpty, "no window, no confirmation — nothing deleted yet")
        window.test_editor.test_confirmDelete()
        await drain()
        #expect(controller.groups.isEmpty)
        #expect(window.test_isShowingScenesOverview, "the delete falls back to the overview")
        #expect(window.test_overview.test_isShowingEmptyCanvas)
    }

    @Test func sidebarSupportsMultipleSelection() async throws {
        let (window, _, _) = try await makeWindow()
        #expect(window.test_sidebar.test_allowsMultipleSelection)
    }

    /// `update(devices:)` fires on every backend event for the app's whole
    /// lifetime — an EQ-only change touches nothing any sidebar cell renders,
    /// so it must not rebuild the sidebar's node tree. A change the sidebar
    /// DOES render (a rename) must still reload.
    @Test func sidebarReloadSkipsAnEQOnlyChangeButNotARename() async throws {
        let (window, _, backend) = try await makeWindow()
        let baseline = window.test_sidebarReloadCount
        #expect(baseline > 0, "the initial makeWindow() snapshot already reloaded once")

        var eqOnly = backend.devices
        eqOnly[0].eq = DeviceEQ(bassDB: 4)
        window.update(devices: eqOnly)
        #expect(window.test_sidebarReloadCount == baseline,
                "no sidebar cell shows a tone value, so this must be a no-op reload")

        var renamed = eqOnly
        renamed[0].name += " (renamed)"
        window.update(devices: renamed)
        #expect(window.test_sidebarReloadCount == baseline + 1,
                "a name change IS on a sidebar cell, so it must reload")
    }

    @Test func sidebarReloadDetectsAnIconOverrideOnlyChange() async throws {
        let (window, _, _, icons) = try await makeWindowWithIconController()
        let baseline = window.test_sidebarReloadCount
        #expect(baseline > 0, "the initial makeWindow() snapshot already reloaded once")

        icons.setSymbolName("sofa.fill", for: "office")
        #expect(window.test_sidebarReloadCount == baseline + 1,
                "an icon override IS the rendered sidebar icon, so a same-id/name/kind/isAvailable change must still reload")
    }

    // Turns red when the sidebar's reload gate reads availability from discovery instead of the presentation record, so a Main Audio member whose discovery entry lapsed keeps a stale spoken state when it connects or drops.
    @Test func sidebarRepaintsAConnectedSpeakerWhoseDiscoveryLapsed() throws {
        let controller = GroupController(backend: MockBackend(fleet: []), store: GroupStore(directory: scratchDir),
            routingStore: RoutingStore(directory: scratchDir), settings: AppSettings(defaults: isolatedDefaults),
            loadPersisted: false)
        var cast = Device(id: "cast", name: "Cast", kind: .cast, isAvailable: false)
        let use = SpeakerCurrentUse(mainAudioMemberIDs: ["cast"])
        let library = SpeakerLibraryController(loadPersisted: false)
        library.update(liveDevices: [cast], groups: [], currentUse: use)
        let window = MixerWindowController(groupController: controller,
            settings: AppSettings(defaults: isolatedDefaults), speakerLibrary: library)
        window.test_isVisibleOverride = true
        window.update(devices: [cast])
        let spoken = { window.test_sidebar.test_deviceCell(id: "cast")?.nameLabel.accessibilityLabel() }
        #expect(spoken() == "Cast, unavailable")
        let steps: [(ConnectionState, String)] = [(.connected, "Cast"), (.off, "Cast, unavailable")]
        for (state, label) in steps {
            cast.connectionState = state
            library.update(liveDevices: [cast], groups: [], currentUse: use)
            window.update(devices: [cast])
            #expect(spoken() == label, "\(state)")
        }
    }

    // MARK: New Group — sheet (SPEC.md §9, design revamp)

    @Test func tapAddRoutesToCreationSheet() async throws {
        let (window, controller, _) = try await makeWindow()
        window.test_sidebar.test_tapAdd()
        await drain()

        #expect(window.test_createSheet != nil, "the '+' with no selection presents the New Group sheet")
        #expect(controller.groups.count == 0, "presenting the sheet creates nothing")
    }

    @Test func createSheetShowsATitleAndAnEditablePencilOnItsIconWell() async throws {
        let (window, _, _) = try await makeWindow()
        window.test_presentCreateSheet(preselected: [])
        await drain()
        let sheet = try #require(window.test_createSheet)

        #expect(sheet.test_titleText == "Add scene", "the sheet names itself instead of opening as a bare form")
        #expect(sheet.test_iconWellShowsPencil, "bordered + pencil = editable — the icon well is editable, so it wears the same cue DeviceIconWellView does")
    }

    @Test func createSheetPrefillsPreselectedMembersChecked() async throws {
        let (window, _, _) = try await makeWindow()
        window.test_presentCreateSheet(preselected: ["office", "appletv-lr"])
        await drain()

        let sheet = try #require(window.test_createSheet)
        #expect(Set(sheet.test_checkedDeviceIDs) == ["office", "appletv-lr"], "the sheet is pre-populated with exactly the multi-selected speakers")
    }

    @Test func createSheetCreateDisabledAtZeroMembersEnabledAtOne() async throws {
        let (window, _, _) = try await makeWindow()
        window.test_presentCreateSheet(preselected: [])
        await drain()
        let sheet = try #require(window.test_createSheet)

        #expect(!(sheet.test_isCreateEnabled), "Create is disabled with zero members checked")

        sheet.test_setMembership(deviceID: "office", isChecked: true)
        #expect(sheet.test_isCreateEnabled, "Create enables once >= 1 member is checked")

        sheet.test_setMembership(deviceID: "office", isChecked: false)
        #expect(!(sheet.test_isCreateEnabled), "unchecking the only member disables Create again")
    }

    @Test func createSheetCommitCreatesExactlyCheckedMembers() async throws {
        let (window, controller, _) = try await makeWindow()
        window.test_presentCreateSheet(preselected: [])
        await drain()
        let sheet = try #require(window.test_createSheet)

        sheet.test_setName("Downstairs")
        sheet.test_setMembership(deviceID: "office", isChecked: true)
        sheet.test_setMembership(deviceID: "homepod-bed", isChecked: true)
        sheet.test_commit()
        await drain()

        #expect(controller.groups.count == 1)
        let group = try #require(controller.groups.first)
        #expect(group.name == "Downstairs")
        #expect(Set(group.memberIDs) == ["office", "homepod-bed"])
        #expect(Set(group.memberVolumes.keys) == Set(group.memberIDs), "each checked member gets a remembered volume")
    }

    @Test func createSheetCommitDoesNotActivate() async throws {
        let (window, controller, _) = try await makeWindow()
        #expect(controller.activeGroupID == nil)
        window.test_presentCreateSheet(preselected: [])
        await drain()
        let sheet = try #require(window.test_createSheet)

        sheet.test_setMembership(deviceID: "office", isChecked: true)
        sheet.test_commit()
        await drain()

        #expect(controller.groups.count == 1)
        #expect(controller.activeGroupID == nil, "creating a group never activates it — CONFIG-ONLY")
    }

    @Test func createSheetCommitAfterCreateSelectsAndOpensEditorWithoutActivating() async throws {
        let (window, controller, _) = try await makeWindow()
        window.test_presentCreateSheet(preselected: [])
        await drain()
        let sheet = try #require(window.test_createSheet)
        sheet.test_setMembership(deviceID: "office", isChecked: true)
        sheet.test_commit()
        await drain()

        let group = try #require(controller.groups.first)
        #expect(window.test_isShowingEditor, "creation opens the new group's editor")
        #expect(window.test_editor.editingGroupID == group.id)
        #expect(controller.activeGroupID == nil, "still not activated after opening the editor")
    }

    @Test func createSheetDedupsIdenticalMemberSetToExistingGroup() async throws {
        let (window, controller, _) = try await makeWindow()
        window.test_presentCreateSheet(preselected: ["office", "appletv-lr"])
        await drain()
        var sheet = try #require(window.test_createSheet)
        var completedResult: (group: Group, alreadyExisted: Bool)?
        sheet.onComplete = { completedResult = $0 }
        sheet.test_commit()
        await drain()
        #expect(controller.groups.count == 1)
        #expect(completedResult?.alreadyExisted == false)
        let firstID = controller.groups[0].id

        // Same member set again (order swapped). The sheet REFUSES TO ARM
        // rather than letting the user press Create into a refusal (owner's call,
        // 2026-09-03) — the count line names the group that already holds them.
        window.test_presentCreateSheet(preselected: ["appletv-lr", "office"])
        await drain()
        sheet = try #require(window.test_createSheet)
        completedResult = nil
        sheet.onComplete = { completedResult = $0 }

        #expect(!sheet.test_isCreateEnabled, "Create cannot be pressed into a set that is already a group")
        #expect(sheet.test_countText.contains(controller.groups[0].name),
                Comment(rawValue: "and the count line says which group holds them: " + sheet.test_countText))

        sheet.test_commit()
        await drain()

        #expect(controller.groups.count == 1, "no duplicate group for an identical member set")
        #expect(controller.groups[0].id == firstID)
        #expect(completedResult == nil, "a disarmed Create reports nothing at all")
    }

    /// Reversed 2026-08-28 (owner's call): an offline speaker MAY join a
    /// brand-new group — it simply plays when it is back — and listing it is also
    /// what keeps the add bar's "New Group from N Speakers…" count honest when
    /// the selection includes a sleeping speaker. Unavailable candidates sort to
    /// the bottom, matching every other list on the screen.
    @Test func createSheetOffersUnavailableDevicesLast() async throws {
        let (window, _, backend) = try await makeWindow()
        let unavailableID = "office"
        let devices = backend.devices.map { device -> Device in
            var d = device
            if d.id == unavailableID { d.isAvailable = false }
            return d
        }
        window.update(devices: devices)

        window.test_presentCreateSheet(preselected: [unavailableID])
        await drain()
        let sheet = try #require(window.test_createSheet)

        #expect(sheet.test_candidateDeviceIDs.count == 7,
                "every device is a candidate, asleep or not")
        #expect(sheet.test_candidateDeviceIDs.last == unavailableID,
                "the unavailable one sorts to the bottom")
        #expect(sheet.test_checkedDeviceIDs.contains(unavailableID),
                "a preselected offline speaker stays checked — the count never lies")
    }

    // MARK: Selecting a group → editor only, never activation

    @Test func selectingGroupShowsEditorAndDoesNotActivate() async throws {
        let (window, controller, backend) = try await makeWindow()
        let saved = try makeGroup1(controller)
        window.update(devices: backend.devices)
        #expect(controller.activeGroupID == nil)

        window.test_select(.group(id: saved.id))
        await drain()

        #expect(window.test_isShowingEditor)
        #expect(controller.activeGroupID == nil, "selecting a group in the sidebar never activates it")
        #expect(window.test_editor.editingGroupID == saved.id)
        #expect(Set(window.test_editor.test_checkedDeviceIDs) == Set(saved.memberIDs))
        #expect(window.test_editor.test_candidateDeviceIDs.count == 7)
    }

    // MARK: Editor candidates: every device, unavailable ones last

    /// Reversed 2026-08-28 (owner's call): the editor offers EVERY device —
    /// an unavailable non-member can be checked into the group and plays when
    /// it returns. Unavailable rows sort to the bottom (the shared
    /// `orderedDevices()` rule), rendered dimmed by the row itself.
    @Test func editorOffersUnavailableDevicesLast() async throws {
        let (window, controller, backend) = try await makeWindow()
        let saved = try makeGroup1(controller)
        // "office" is a member of Group 1; mark it unavailable, and mark a
        // non-member ("appletv-lr") unavailable too, in the same push.
        let devices = backend.devices.map { device -> Device in
            var d = device
            if d.id == "office" || d.id == "appletv-lr" {
                d.isAvailable = false
                d.connectionState = .off
            }
            return d
        }
        window.update(devices: devices)

        window.test_select(.group(id: saved.id))
        await drain()

        let ids = window.test_editor.test_candidateDeviceIDs
        #expect(ids.contains("office"), "an unavailable member is still offered")
        #expect(ids.contains("appletv-lr"), "an unavailable NON-member is offered too — it may join now")
        #expect(ids.suffix(2).sorted() == ["appletv-lr", "office"],
                "the two unavailable devices sort to the bottom")
    }

    // MARK: Editor → GroupController

    @Test func renameInEditorCallsSaveGroup() async throws {
        let (window, controller, backend) = try await makeWindow()
        let saved = try makeGroup1(controller)
        window.update(devices: backend.devices)
        window.test_select(.group(id: saved.id))
        await drain()

        window.test_editor.test_rename(to: "Whole House")
        #expect(controller.groups.first { $0.id == saved.id }?.name == "Whole House")
    }

    @Test func membershipCheckboxUpdatesGroup() async throws {
        let (window, controller, backend) = try await makeWindow()
        let saved = try makeGroup1(controller)
        window.update(devices: backend.devices)
        window.test_select(.group(id: saved.id))
        await drain()

        let extra = try #require(backend.devices.first { !saved.memberIDs.contains($0.id) }?.id)
        let before = try #require(controller.groups.first { $0.id == saved.id }).memberIDs.count

        window.test_editor.test_setMembership(true, for: extra)
        #expect(controller.groups.first { $0.id == saved.id }?.memberIDs.count == before + 1)
        #expect(controller.groups.first { $0.id == saved.id }!.memberIDs.contains(extra))

        window.test_editor.test_setMembership(false, for: extra)
        #expect(controller.groups.first { $0.id == saved.id }?.memberIDs.count == before)
        #expect(!(controller.groups.first { $0.id == saved.id }!.memberIDs.contains(extra)))
    }

    @Test func cannotRemoveLastMemberOfGroupInEditor() async throws {
        let (window, controller, backend) = try await makeWindow()
        let saved = try makeGroup1(controller)   // 2 members: sonos-move, office
        window.update(devices: backend.devices)
        window.test_select(.group(id: saved.id))
        await drain()

        // Removing one of two members is allowed — the group drops to a single member.
        window.test_editor.test_setMembership(false, for: "office")
        #expect(controller.groups.first { $0.id == saved.id }?.memberIDs == ["sonos-move"], "one member removed, one remains")

        // The sole remaining member's checkbox is pinned (disabled) as the affordance.
        #expect(!(window.test_editor.test_isMembershipRowEnabled(for: "sonos-move")), "the last member's checkbox is disabled so it can't be unchecked")

        // Attempting to remove the last member is refused: the group keeps it and
        // the row reverts to checked (delete the group instead to remove it).
        window.test_editor.test_setMembership(false, for: "sonos-move")
        #expect(controller.groups.first { $0.id == saved.id }?.memberIDs == ["sonos-move"], "removing the last member must be refused — the group stays non-empty")
        #expect(window.test_editor.test_checkedDeviceIDs.contains("sonos-move"), "the reverted checkbox shows the member still belongs")
    }

    /// Fable review fix: `rebuildCandidates`'s REUSE path (`apply` re-enables
    /// the checkbox but never clears the tooltip/VoiceOver help `pinSoleMember`
    /// set earlier) used to leave a formerly-pinned row stuck announcing "A
    /// group needs at least one device…" even after it stopped being the sole
    /// member.
    @Test func gainingASecondMemberClearsTheFormerSoleMembersStalePin() async throws {
        let (window, controller, backend) = try await makeWindow()
        let saved = try controller.createGroup(name: "Solo", memberIDs: ["office"]).group
        window.update(devices: backend.devices)
        window.test_select(.group(id: saved.id))
        await drain()

        #expect(!(window.test_editor.test_isMembershipRowEnabled(for: "office")), "the sole member starts pinned")
        let officeRow = try #require(window.test_editor.test_membershipRow(for: "office") as? MembershipRowView)
        #expect(officeRow.test_checkboxAccessibilityHelp != nil, "the pin explanation is set")

        // Every demo-fleet device is already available, so this takes the
        // REUSE path (the candidate ID sequence is unchanged), not a full
        // rebuild that would have fresh rows anyway.
        window.test_editor.test_setMembership(true, for: "sonos-move")

        #expect(window.test_editor.test_isMembershipRowEnabled(for: "office"), "no longer the sole member — its checkbox must re-enable")
        #expect(officeRow.test_checkboxAccessibilityHelp == nil, "the reuse path must clear the stale pin explanation, not just re-enable the checkbox")
    }

    @Test func deleteInEditorCallsDeleteGroupAndReturnsToMixer() async throws {
        let (window, controller, backend) = try await makeWindow()
        let saved = try makeGroup1(controller)
        window.update(devices: backend.devices)
        window.test_select(.group(id: saved.id))
        await drain()
        #expect(window.test_isShowingEditor)

        window.test_editor.test_confirmDelete()
        await drain()

        #expect(controller.groups.count == 0)
        #expect(!(window.test_isShowingEditor))
        #expect(window.test_isShowingScenesOverview, "deleting the last group falls back to the overview")
        #expect(window.test_overview.test_isShowingEmptyCanvas, "which is now the empty state too")
    }

    // MARK: The delete confirmation (P0-1)

    @Test func deleteAlertNamesTheGroupAndDefaultsToCancel() async throws {
        let (window, controller, backend) = try await makeWindow()
        let saved = try makeGroup1(controller)
        window.update(devices: backend.devices)
        window.test_select(.group(id: saved.id))
        await drain()

        let alert = try #require(window.test_editor.test_makeDeleteAlert())
        #expect(alert.messageText == "Delete \u{201C}Group 1\u{201D}?",
                "the sheet names the group being deleted, not \"this group\"")
        #expect(alert.informativeText == "Deleting a scene doesn't change which speakers are playing.",
                "an inactive group really is pure configuration")
        #expect(alert.buttons[0].title == "Delete")
        #expect(alert.buttons[0].hasDestructiveAction)
        #expect(alert.buttons[0].keyEquivalent == "",
                "Return must not be the destructive answer")
        #expect(alert.buttons[1].title == "Cancel")
        #expect(alert.buttons[1].keyEquivalent == "\r", "Cancel is the default button")
    }

    /// The lie this fixed: deleting the group that is PLAYING switches Main Out
    /// back to Selected Devices, so a speaker that is only in this group stops.
    /// The old sentence claimed nothing would change.
    @Test func deleteAlertTellsTheTruthForTheGroupThatIsPlaying() async throws {
        let (window, controller, backend) = try await makeWindow()
        let saved = try makeGroup1(controller)
        window.update(devices: backend.devices)
        window.test_select(.group(id: saved.id))
        await drain()

        controller.activateGroup(id: saved.id)
        window.update(devices: backend.devices)
        await drain()

        let alert = try #require(window.test_editor.test_makeDeleteAlert())
        #expect(alert.informativeText
                == "This scene is playing. Deleting it switches playback to Selected Speakers; "
                   + "speakers that are only in this scene will stop.")
    }

    /// With no window there is no confirmation, so the sidebar's "Delete
    /// Group…" must NOT delete — it used to delete outright on that path.
    @Test func aWindowlessDeleteRequestIsANoOp() async throws {
        let (window, controller, backend) = try await makeWindow()
        let saved = try makeGroup1(controller)
        window.update(devices: backend.devices)
        window.test_select(.group(id: saved.id))
        await drain()

        window.test_editor.requestDelete()
        await drain()
        #expect(controller.groups.count == 1, "no window means no confirmation, so nothing is deleted")

        window.test_editor.test_confirmDelete()
        await drain()
        #expect(controller.groups.isEmpty, "the confirmed path still deletes")
        _ = saved
    }

    // MARK: The editor's projection gate (P1-1) and row reuse (P1-2)

    @Test func editorSkipsAnEQOnlyChangeButNotARename() async throws {
        let (window, controller, backend) = try await makeWindow()
        let saved = try makeGroup1(controller)
        window.update(devices: backend.devices)
        window.test_select(.group(id: saved.id))
        await drain()
        let baseline = window.test_editor.test_renderCount
        #expect(baseline > 0, "opening the editor rendered it once")

        var eqOnly = backend.devices
        eqOnly[0].eq = DeviceEQ(bassDB: 4)
        window.update(devices: eqOnly)
        #expect(window.test_editor.test_renderCount == baseline,
                "nothing this pane draws shows a tone value")

        var renamed = eqOnly
        renamed[0].name += " (renamed)"
        window.update(devices: renamed)
        #expect(window.test_editor.test_renderCount == baseline + 1,
                "a device name IS on a membership row, so the pane repaints")
    }

    @Test func aRefreshReusesTheMembershipRowsWhenTheCandidateListIsUnchanged() async throws {
        let (window, controller, backend) = try await makeWindow()
        let saved = try makeGroup1(controller)
        let transient = Device(id: "transient", name: "Transient", kind: .generic)
        let base = backend.devices + [transient]
        window.update(devices: base)
        window.test_select(.group(id: saved.id))
        await drain()
        let editor = window.test_editor
        let candidatesBefore = editor.test_candidateDeviceIDs
        let row = try #require(editor.test_membershipRow(for: "office"))

        var updated = base
        let officeIndex = try #require(updated.firstIndex { $0.id == "office" })
        updated[officeIndex].connectionState = .connecting
        window.update(devices: updated)
        #expect(editor.test_membershipRow(for: "office") === row,
                "the same candidate sequence refreshes its existing rows")
        #expect(editor.test_candidateDeviceIDs == candidatesBefore)

        let fewer = updated.filter { $0.id != transient.id }
        window.update(devices: fewer)
        #expect(!editor.test_candidateDeviceIDs.contains(transient.id))
        #expect(editor.test_membershipRow(for: "office") !== row,
                "removing an unused transient candidate rebuilds the list")
        window.update(devices: fewer.filter { $0.id != "office" })
        #expect(editor.test_candidateDeviceIDs.contains("office"),
                "a remembered scene member remains editable after discovery removes it")
    }

    /// Fable review fix: the projection gate in `show(groupID:devices:)` used
    /// to return early on a volume-only change (correctly — nothing this pane
    /// draws shows a volume) WITHOUT refreshing `allDevices`/`candidateDevices`,
    /// so a check-in right after persisted the volume from BEFORE that event
    /// instead of the fresh one. The render count must stay untouched either
    /// way — this is a model-write fix, not a rendering one.
    @Test func aVolumeOnlyRefreshBeforeACheckInPersistsTheFreshVolume() async throws {
        let (window, controller, backend) = try await makeWindow()
        let saved = try makeGroup1(controller)   // sonos-move, office
        window.update(devices: backend.devices)
        window.test_select(.group(id: saved.id))
        await drain()
        let editor = window.test_editor
        let baseline = editor.test_renderCount

        // Through `window.update(devices:)`, exactly like a real backend echo
        // arrives — it re-sorts into `orderedDevices()` before handing the
        // editor its snapshot, so this isn't a second, independently-ordered
        // fetch of `backend.devices` (which doesn't promise a stable order).
        var volumeOnly = backend.devices
        let index = try #require(volumeOnly.firstIndex { $0.id == "homepod-bed" })
        volumeOnly[index].volume = 77
        controller.updateDevices(volumeOnly)
        window.update(devices: volumeOnly)
        #expect(editor.test_renderCount == baseline, "a volume-only change draws nothing this pane shows")

        editor.test_setMembership(true, for: "homepod-bed")

        #expect(controller.groups.first { $0.id == saved.id }?.memberVolumes["homepod-bed"] == 77,
                "the persisted volume must come from the FRESH snapshot, not the stale one from before the gated refresh")
    }

    // MARK: Duplicate names are refused (P2-5)

    @Test func renamingOntoAnotherGroupsNameIsRefused() async throws {
        let (window, controller, backend) = try await makeWindow()
        let first = try makeGroup1(controller)
        _ = try controller.createGroup(name: "Upstairs", memberIDs: ["homepod-bed"], memberVolumes: [:])
        window.update(devices: backend.devices)
        window.test_select(.group(id: first.id))
        await drain()

        window.test_editor.test_rename(to: "upstairs")

        #expect(controller.groups.first { $0.id == first.id }?.name == "Group 1",
                "the model is untouched")
        #expect(window.test_editor.test_nameFieldValue == "Group 1",
                "…and the field goes back to what is actually saved")
        #expect(window.test_editor.test_duplicateNameRefused)
    }

    @Test func recasingAGroupsOwnNameIsStillAllowed() async throws {
        let (window, controller, backend) = try await makeWindow()
        let saved = try makeGroup1(controller)
        window.update(devices: backend.devices)
        window.test_select(.group(id: saved.id))
        await drain()

        window.test_editor.test_rename(to: "GROUP 1")

        #expect(controller.groups.first { $0.id == saved.id }?.name == "GROUP 1",
                "a group never collides with itself")
        #expect(!window.test_editor.test_duplicateNameRefused)
    }

    @Test func creatingWithATakenNameIsRefused() async throws {
        let (window, controller, _) = try await makeWindow()
        _ = try makeGroup1(controller)   // "Group 1"
        window.test_presentCreateSheet(preselected: [])
        await drain()
        let sheet = try #require(window.test_createSheet)
        var completed = false
        sheet.onComplete = { _ in completed = true }

        sheet.test_setName("group 1")
        sheet.test_setMembership(deviceID: "homepod-bed", isChecked: true)
        sheet.test_commit()
        await drain()

        #expect(controller.groups.count == 1, "nothing was created")
        #expect(!completed, "the sheet stays up with the form intact")
        #expect(sheet.test_duplicateNameRefused)
        #expect(sheet.test_checkedDeviceIDs == ["homepod-bed"], "the selection survives the refusal")
    }

    /// Return in the name field and the default button both reach `commit()`,
    /// so a single keypress could run it twice — the second run then found the
    /// group the first had just saved and refused its own name. Live-caught
    /// 2026-09-03 on a first-ever group.
    @Test func committingTheCreateSheetTwiceCreatesOneGroupAndNoRefusal() async throws {
        let (window, controller, _) = try await makeWindow()
        window.test_presentCreateSheet(preselected: [])
        await drain()
        let sheet = try #require(window.test_createSheet)

        sheet.test_setName("Kitchen")
        sheet.test_setMembership(deviceID: "homepod-bed", isChecked: true)
        sheet.test_commit()
        sheet.test_commit()
        await drain()

        #expect(controller.groups.map(\.name) == ["Kitchen"], "one group, created once")
        #expect(!sheet.test_duplicateNameRefused,
                "the sheet never refuses the name of the group it just created")
    }

    /// A second Return while the sheet's own alert is still up used to raise a
    /// second alert on a window that already had one attached, which AppKit
    /// hosts on a blank window of its own. Live-caught 2026-09-03.
    @Test func theSheetRaisesNoSecondAlertWhileOneIsStillUp() async throws {
        let (window, controller, _) = try await makeWindow()
        let existing = try makeGroup1(controller)   // "Group 1"
        window.test_presentCreateSheet(preselected: [])
        await drain()
        let sheet = try #require(window.test_createSheet)

        // The member set that already belongs to "Group 1" — the dedup path,
        // which is what reports an outcome (headlessly it completes rather
        // than raising the alert a presented sheet would).
        for id in existing.memberIDs { sheet.test_setMembership(deviceID: id, isChecked: true) }
        sheet.test_setName("Kitchen")
        var completed = false
        sheet.onComplete = { _ in completed = true }
        sheet.test_alertIsUpOverride = true
        sheet.test_commit()
        await drain()

        #expect(!completed, "the second landing does nothing at all while the alert is up")
        #expect(controller.groups.count == 1, "and writes nothing")
    }

    /// A text field sends its action whenever editing ENDS unless told
    /// otherwise, so closing the sheet after a refusal ran `commit()` once
    /// more — against a window already leaving the screen, and AppKit hosted
    /// that alert on a blank "Untitled" window. Live-caught 2026-09-03 on a
    /// build that already had both re-entry guards above.
    @Test func theCreateSheetNameFieldCommitsOnReturnOnly() async throws {
        let (window, _, _) = try await makeWindow()
        window.test_presentCreateSheet(preselected: [])
        await drain()
        let sheet = try #require(window.test_createSheet)

        #expect(!sheet.test_nameFieldCommitsOnEndEditing,
                "tabbing out of the name field, or the sheet closing, must not commit")
    }

    // MARK: The creation sheet reports a failed save (P1-4)

    @Test func createSheetReportsAFailedSaveAndKeepsTheForm() async throws {
        let backend = MockBackend(fleet: .demoFleet, staggerDiscovery: false,
                                  emitsLevels: false, simulatesDropouts: false)
        try await waitForFleet(backend, count: 7)
        // A plain FILE where the store wants a directory: `createDirectory`
        // throws, so every write fails.
        let blocker = tempDirectory().appendingPathComponent("blocker")
        FileManager.default.createFile(atPath: blocker.path, contents: Data())
        let controller = GroupController(
            backend: backend,
            store: GroupStore(directory: blocker.appendingPathComponent("sub", isDirectory: true)),
            routingStore: RoutingStore(directory: scratchDir),
            settings: AppSettings(defaults: isolatedDefaults),
            loadPersisted: false)
        let window = MixerWindowController(groupController: controller,
                                           settings: AppSettings(defaults: isolatedDefaults))
        window.test_isVisibleOverride = true
        window.update(devices: backend.devices)

        window.test_presentCreateSheet(preselected: [])
        await drain()
        let sheet = try #require(window.test_createSheet)
        var completed = false
        sheet.onComplete = { _ in completed = true }
        sheet.test_setName("Downstairs")
        sheet.test_setMembership(deviceID: "office", isChecked: true)

        sheet.test_commit()
        await drain()

        #expect(sheet.test_saveFailureReported, "a failed write is reported, never swallowed")
        #expect(!completed, "the sheet does not finish on a failure")
        #expect(sheet.test_nameFieldText == "Downstairs", "the form is intact…")
        #expect(sheet.test_checkedDeviceIDs == ["office"])
        #expect(sheet.test_isCreateEnabled, "…and Create stays live, so the user can try again")
    }

    /// The dedup outcome is now unreachable from the sheet at all — Create is
    /// disarmed for a set that is already a group, window or not, so nobody
    /// arrives at the announcement by pressing a live button (owner's call,
    /// 2026-09-03).
    @Test func aSetThatIsAlreadyAGroupNeverArmsCreate() async throws {
        let (window, controller, _) = try await makeWindow()
        window.test_presentCreateSheet(preselected: ["office", "homepod-bed"])
        await drain()
        try #require(window.test_createSheet).test_commit()
        await drain()
        #expect(controller.groups.count == 1)

        window.test_presentCreateSheet(preselected: ["homepod-bed", "office"])
        await drain()
        let second = try #require(window.test_createSheet)
        var result: (group: Group, alreadyExisted: Bool)?
        second.onComplete = { result = $0 }

        #expect(!second.test_isCreateEnabled, "Create is disarmed for a set that is already a group")
        second.test_commit()
        await drain()

        #expect(controller.groups.count == 1, "nothing was written")
        #expect(result == nil, "and nothing was reported — there is no outcome to announce")
    }

    // MARK: The creation sheet's empty checklist (P1-5)

    /// Since 2026-08-28 an offline speaker is still a candidate, so a fleet
    /// that is merely ASLEEP no longer empties the checklist — only a fleet
    /// the app has never seen does. The explanatory copy is for that case.
    @Test func anEmptyChecklistExplainsItself() async throws {
        let (window, _, backend) = try await makeWindow()
        window.update(devices: [])
        window.test_presentCreateSheet(preselected: [])
        await drain()
        let sheet = try #require(window.test_createSheet)

        #expect(sheet.test_candidateDeviceIDs.isEmpty)
        #expect(sheet.test_emptyChecklistText
                == "No speakers found yet. Speakers appear here once they\u{2019}re reachable on your Wi-Fi network.")
        #expect(!sheet.test_isCreateEnabled)

        let allOffline = backend.devices.map { device -> Device in
            var d = device
            d.isAvailable = false
            return d
        }
        window.update(devices: allOffline)
        window.test_presentCreateSheet(preselected: [])
        await drain()
        #expect(try #require(window.test_createSheet).test_candidateDeviceIDs.count == 7,
                "an all-asleep fleet is still a checklist, not an empty state")

        window.update(devices: backend.devices)
        window.test_presentCreateSheet(preselected: [])
        await drain()
        #expect(try #require(window.test_createSheet).test_emptyChecklistText == nil,
                "with real rows there is nothing to explain")
    }

    // MARK: Selecting a device → detail pane (config-only, never activation)

    @Test func selectingDeviceShowsDetailPaneWithMetadataAndGroupMembership() async throws {
        let (window, controller, backend) = try await makeWindow()
        // Untouched by makeGroup1 below (which selects sonos-move + office,
        // actually connecting them) — a clean "Not connected" / "None" case.
        window.test_select(.device(id: "appletv-lr"))
        await drain()

        #expect(window.test_isShowingDetail)
        #expect(!(window.test_isShowingEditor))
        #expect(window.test_detail.test_shownDeviceID == "appletv-lr")
        #expect(window.test_detail.test_subtitleText == "Apple TV · Ready")
        #expect(window.test_detail.test_groupMembershipText == "None", "appletv-lr isn't a member of any saved group")

        let saved = try makeGroup1(controller)   // members: sonos-move, office
        window.update(devices: backend.devices)

        window.test_select(.device(id: "office"))
        await drain()

        #expect(window.test_isShowingDetail)
        #expect(window.test_detail.test_shownDeviceID == "office")
        #expect(window.test_detail.test_groupMembershipText == saved.name, "office is a Group 1 member")
    }

    /// Membership on the detail pane is NAVIGATION: clicking a group row
    /// opens that group's editor in the scenes host. Still
    /// configuration-only — selecting is not activating, so `activeGroupID`
    /// stays nil and no audio moves.
    @Test func clickingAGroupRowOnTheDetailPaneOpensThatGroupsEditor() async throws {
        let (window, controller, backend) = try await makeWindow()
        let saved = try makeGroup1(controller)   // members: sonos-move, office
        window.update(devices: backend.devices)

        window.select(.device(id: "office"))
        await drain()
        #expect(window.test_isShowingDetail)
        #expect(window.test_detail.test_groupRowTitles == [saved.name])

        window.test_detail.test_selectGroupRow(at: 0)
        await drain()

        #expect(window.test_isShowingEditor, "the row opened the group's editor")
        #expect(window.test_editor.editingGroupID == saved.id)
        #expect(window.test_sidebar.currentSelection == .device(id: "office"),
                "the sidebar is untouched by a scene selection")
        #expect(controller.activeGroupID == nil,
                "selecting a group from the detail pane NEVER activates it")
    }

    // Turns red when the speaker page's scene link stops calling `onRequestScenesTab`, which leaves the editor opening on a screen nobody is looking at.
    @Test func aSceneLinkOnASpeakerPageAsksForTheScenesTab() async throws {
        let (window, controller, backend) = try await makeWindow()
        _ = try makeGroup1(controller)   // members: sonos-move, office
        window.update(devices: backend.devices)
        var requests = 0
        window.onRequestScenesTab = { requests += 1 }

        window.select(.device(id: "office"))
        await drain()
        #expect(requests == 0, "showing a speaker page asks for no tab")
        window.test_detail.test_selectGroupRow(at: 0)
        await drain()

        #expect(window.test_isShowingEditor)
        #expect(requests == 1, "the scene link asks the surface for the Scenes tab")
    }

    // Turns red when the sidebar stops putting This Mac first, or stops listing the reachable speakers by name before the unreachable ones.
    @Test func sidebarIsAlphabeticalWithinItsGroupWithTheMacFirst() async throws {
        let (window, _, backend) = try await makeWindow()
        let devices = backend.devices.map { device -> Device in
            var d = device
            if d.id == "office" || d.id == "appletv-lr" {
                d.isAvailable = false
                d.connectionState = .off
            }
            return d
        }
        window.update(devices: devices)

        // MacBook Pro Speakers; then Bedroom HomePod, Mixer, Move 2, Sonos
        // Move; then, under the divider, the two asleep ones: Living Room TV, Office.
        #expect(window.test_sidebar.test_deviceRowIDs(inGroupTitled: "Shown in Mixer")
                == ["local-mac", "homepod-bed", "airport-mixer", "sonos-move-2", "sonos-move", "appletv-lr", "office"])
    }

    /// `select(_:)` is the deep-link/cross-link entry point (the detail pane's
    /// group rows, `AppDelegate.showSurface(_:selecting:)`), and unlike a real
    /// click it has to move the sidebar's highlight ITSELF. Sidebar and content
    /// must end up agreeing: a speaker's pane means the speaker's row is lit.
    @Test func selectingASpeakerHighlightsThatSpeakersRow() async throws {
        let (window, controller, backend) = try await makeWindow()
        _ = try makeGroup1(controller)
        window.update(devices: backend.devices)
        await drain()

        window.select(.device(id: "office"))
        await drain()

        #expect(window.test_isShowingDetail)
        #expect(window.test_sidebar.currentSelection == .device(id: "office"))
    }

    // Turns red when a deselected sidebar leaves a speaker's page up, or lands anywhere but the Speakers page.
    @Test func deselectingADeviceLandsOnTheSpeakersPage() async throws {
        let (window, controller, backend) = try await makeWindow()
        window.test_select(.device(id: "office"))
        await drain()
        #expect(window.test_isShowingDetail)

        window.test_select(nil)
        await drain()
        #expect(!(window.test_isShowingDetail))
        #expect(window.test_isShowingSpeakersPage, "deselecting a device lands on the Speakers page")

        let saved = try makeGroup1(controller)
        window.update(devices: backend.devices)
        window.test_select(.device(id: "office"))
        await drain()
        window.test_select(nil)
        await drain()
        #expect(window.test_isShowingSpeakersPage)
        #expect(window.test_isShowingScenesOverview, "the scenes host still shows the cards")
        #expect(window.test_overview.test_cardGroupIDs == [saved.id])
    }

    @Test func selectingUnknownDeviceIDFallsBackToDefaultContent() async throws {
        let (window, _, _) = try await makeWindow()
        window.test_select(.device(id: "does-not-exist"))
        await drain()

        #expect(!(window.test_isShowingDetail))
        #expect(window.test_isShowingSpeakersPage)
        #expect(window.test_detail.test_shownDeviceID == nil, "the detail pane was never actually shown")
    }

    @Test func selectingDeviceNeverActivatesAGroup() async throws {
        let (window, controller, backend) = try await makeWindow()
        let saved = try makeGroup1(controller)
        window.update(devices: backend.devices)
        #expect(controller.activeGroupID == nil)

        window.test_select(.device(id: saved.memberIDs[0]))
        await drain()

        #expect(window.test_isShowingDetail)
        #expect(controller.activeGroupID == nil, "selecting a device in the sidebar never activates anything")
    }

    @Test func detailPaneRefreshesLiveWhenDeviceSnapshotChanges() async throws {
        let (window, _, backend) = try await makeWindow()
        window.test_select(.device(id: "office"))
        await drain()
        #expect(window.test_detail.test_subtitleText == "AirPlay Speaker · Ready")

        let updated = backend.devices.map { device -> Device in
            var d = device
            if d.id == "office" { d.isAvailable = false }
            return d
        }
        window.update(devices: updated)

        #expect(window.test_isShowingDetail, "still showing the detail pane, just re-rendered")
        #expect(window.test_detail.test_subtitleText == "AirPlay Speaker · Unavailable", "refreshAll() re-renders the visible detail pane from the fresher snapshot")
    }

    @Test func refreshAllFallsBackWhenShownDeviceDisappears() async throws {
        let (window, _, backend) = try await makeWindow()
        window.test_select(.device(id: "office"))
        await drain()
        #expect(window.test_isShowingDetail)

        let devicesWithoutOffice = backend.devices.filter { $0.id != "office" }
        window.update(devices: devicesWithoutOffice)

        #expect(!(window.test_isShowingDetail), "refreshAll() falls back to the default content once the shown device vanishes")
        #expect(window.test_isShowingSpeakersPage, "the fallback is the Speakers page")
    }

    // MARK: Forget

    /// A screen whose injected library remembers two speakers the Mac can no
    /// longer find, Den and Attic, beside a live one; Den is in Kitchen and
    /// Porch, Attic only in Porch, and Porch has no other speaker.
    private func makeForgetWindow(groupDirectory: URL? = nil)
        throws -> (MixerWindowController, GroupController, SpeakerLibraryController) {
        let controller = GroupController(backend: MockBackend(fleet: []),
            store: GroupStore(directory: groupDirectory ?? scratchDir), routingStore: RoutingStore(directory: scratchDir),
            settings: AppSettings(defaults: isolatedDefaults), loadPersisted: false)
        let live = Device(id: "live", name: "Live", kind: .sonos)
        let den = Device(id: "den", name: "Den", kind: .sonos)
        let attic = Device(id: "attic", name: "Attic", kind: .homePod)
        try controller.saveGroup(Group(id: "kitchen", name: "Kitchen", memberIDs: ["live", "den"], memberVolumes: [:]))
        try controller.saveGroup(Group(id: "porch", name: "Porch", memberIDs: ["den", "attic"], memberVolumes: [:]))
        let library = SpeakerLibraryController(loadPersisted: false)
        library.update(liveDevices: [live, den, attic], groups: controller.groups)
        library.setVisibility(.always, for: ["den", "attic"])
        library.update(liveDevices: [live], groups: controller.groups)
        let window = MixerWindowController(groupController: controller,
            settings: AppSettings(defaults: isolatedDefaults), speakerLibrary: library)
        window.test_isVisibleOverride = true
        window.update(devices: [live])
        return (window, controller, library)
    }

    // Turns red when the Forget confirm stops counting the scenes a speaker leaves, puts Return on Forget, or offers Forget when a scene would be left with no speaker.
    @Test func forgetAlertCountsScenesAndRefusesToEmptyOne() throws {
        let (window, _, _) = try makeForgetWindow()

        let den = window.test_makeForgetAlert(ids: ["den"])
        #expect(den.messageText == "Forget \u{201C}Den\u{201D}?")
        #expect(den.informativeText == "It will be removed from 2 scenes. If it turns up again, it comes back to "
                + "the speaker list, but not to those scenes.")
        #expect(den.buttons.map(\.title) == ["Forget", "Cancel"])
        #expect(den.buttons[0].hasDestructiveAction)
        #expect(den.buttons[1].keyEquivalent == "\r", "Return is Cancel on a destructive sheet")

        let attic = window.test_makeForgetAlert(ids: ["attic"])
        #expect(attic.informativeText == "It will be removed from 1 scene. If it turns up again, it comes back to "
                + "the speaker list, but not to that scene.")

        let both = window.test_makeForgetAlert(ids: ["den", "attic"])
        #expect(both.messageText == "Can\u{2019}t forget 2 speakers")
        #expect(both.informativeText == "Delete \u{201C}Porch\u{201D} first: it has no other speaker.")
        #expect(both.buttons.map(\.title) == ["OK"])
    }

    // Turns red when the Forget confirm for several speakers stops naming them in the sidebar's order, names one with no saved details, stops counting the rest, or drops the sentence about a speaker coming back.
    @Test func forgetAlertNamesUpToTwoSpeakersAndCountsTheRest() throws {
        let controller = GroupController(backend: MockBackend(fleet: []), store: GroupStore(directory: scratchDir),
            routingStore: RoutingStore(directory: scratchDir),
            settings: AppSettings(defaults: isolatedDefaults), loadPersisted: false)
        let live = Device(id: "live", name: "Live", kind: .sonos)
        // The fourth speaker has no saved details: it exists only as a member of Porch, beside a live speaker.
        try controller.saveGroup(Group(id: "porch", name: "Porch", memberIDs: ["live", "ghost"], memberVolumes: [:]))
        let named = [Device(id: "c", name: "C", kind: .homePod), Device(id: "a", name: "A", kind: .sonos),
                     Device(id: "b", name: "B", kind: .bluetooth)]
        let library = SpeakerLibraryController(loadPersisted: false)
        library.update(liveDevices: [live] + named, groups: controller.groups, confirmedUsedIDs: ["a", "b", "c"])
        library.update(liveDevices: [live], groups: controller.groups)
        let window = MixerWindowController(groupController: controller,
            settings: AppSettings(defaults: isolatedDefaults), speakerLibrary: library)

        let all = window.test_makeForgetAlert(ids: ["a", "b", "c", "ghost"])
        #expect(all.messageText == "Forget 4 speakers?")
        #expect(all.informativeText == "\u{201C}A\u{201D}, \u{201C}B\u{201D} and 2 more will be removed from 1 scene. "
                + "If one turns up again, it comes back to the speaker list, but not to that scene.")

        let three = window.test_makeForgetAlert(ids: ["a", "b", "c"])
        #expect(three.informativeText == "\u{201C}A\u{201D}, \u{201C}B\u{201D} and \u{201C}C\u{201D} aren\u{2019}t "
                + "in any scene. If one turns up again, it comes back to the speaker list.")
    }

    // Turns red when confirming Forget leaves the speaker's record or a scene membership behind, or leaves its page showing once it is gone.
    @Test func confirmingForgetRemovesTheSpeakerAndFallsBackToTheSpeakersPage() throws {
        let (window, controller, library) = try makeForgetWindow()
        window.select(.device(id: "den"))
        #expect(window.test_isShowingDetail)

        window.test_confirmForget(ids: ["den"])

        #expect(library.record(for: "den") == nil)
        #expect(controller.groups.map(\.memberIDs) == [["live"], ["attic"]])
        #expect(!window.test_sidebar.test_deviceRowIDs.contains("den"))
        #expect(window.test_isShowingSpeakersPage)
        #expect(controller.activeGroupID == nil)
    }

    // Turns red when `performForget` swallows a failed scene write instead of reporting it.
    @Test func aForgetWhoseSceneWriteFailsIsReported() throws {
        let directory = tempDirectory()
        let (window, controller, library) = try makeForgetWindow(groupDirectory: directory)
        // A plain FILE where the store wants its directory: the scene write throws.
        try FileManager.default.removeItem(at: directory)
        FileManager.default.createFile(atPath: directory.path, contents: Data())

        window.test_confirmForget(ids: ["den"])

        #expect(window.test_forgetFailureReported)
        #expect(library.record(for: "den") != nil, "nothing was forgotten")
        #expect(controller.groups.map(\.memberIDs) == [["live", "den"], ["den", "attic"]])
    }

    // Turns red when the Forget confirm offers Forget for a speaker Main Audio still names, `forget` drops it anyway, or a retained recovery lookup alone refuses Forget.
    @Test func forgetRefusesOnlyASpeakerStillRouted() throws {
        let (window, controller, library) = try makeForgetWindow()
        library.update(liveDevices: [Device(id: "live", name: "Live", kind: .sonos)], groups: controller.groups,
                       currentUse: SpeakerCurrentUse(mainAudioMemberIDs: ["den"], recoveryIDs: ["attic"]))

        let alert = window.test_makeForgetAlert(ids: ["den"])
        #expect(alert.messageText == "Can\u{2019}t forget \u{201C}Den\u{201D}")
        #expect(alert.informativeText
                == "Main Audio or an app is still set to play on \u{201C}Den\u{201D}. Change that in the Mixer first.")
        #expect(alert.buttons.map(\.title) == ["OK"])

        window.test_confirmForget(ids: ["den"])
        #expect(library.record(for: "den") != nil)
        #expect(controller.groups.map(\.memberIDs) == [["live", "den"], ["den", "attic"]])

        #expect(window.test_makeForgetAlert(ids: ["attic"]).buttons.map(\.title) == ["Forget", "Cancel"])
        window.test_confirmForget(ids: ["attic"])
        #expect(library.record(for: "attic") == nil)
        #expect(controller.groups.map(\.memberIDs) == [["live", "den"], ["den"]])
    }

    // Turns red when "Manage speakers…" stops landing on This Mac's page while the Mac is in the list.
    @Test func firstSpeakerSelectionIsThisMac() async throws {
        let (window, _, _) = try await makeWindow()
        #expect(window.firstSpeakerSelection == .device(id: "local-mac"))
    }

    // MARK: Icon flows

    @Test func editorIconPickPersistsThroughSaveGroup() async throws {
        let (window, controller, backend) = try await makeWindow()
        let saved = try makeGroup1(controller)
        window.update(devices: backend.devices)
        window.test_select(.group(id: saved.id))
        await drain()
        #expect(controller.groups.first { $0.id == saved.id }?.iconSymbolName == nil)

        window.test_editor.test_pickIcon("airpods")

        #expect(controller.groups.first { $0.id == saved.id }?.iconSymbolName == "airpods", "the editor's icon pick persists group.iconSymbolName through saveGroup")
        #expect(window.test_editor.test_iconWellSymbolName == "airpods")
    }

    @Test func createSheetChosenIconLandsOnCreatedGroup() async throws {
        let (window, controller, _) = try await makeWindow()
        window.test_presentCreateSheet(preselected: [])
        await drain()
        let sheet = try #require(window.test_createSheet)

        sheet.test_setMembership(deviceID: "office", isChecked: true)
        sheet.test_pickIcon("airpods")
        sheet.test_commit()
        await drain()

        let group = try #require(controller.groups.first)
        #expect(group.iconSymbolName == "airpods", "the sheet's chosen icon lands on the created group")
    }

    @Test func createSheetDedupDoesNotOverwriteExistingGroupsIcon() async throws {
        let (window, controller, _) = try await makeWindow()
        window.test_presentCreateSheet(preselected: ["office", "appletv-lr"])
        await drain()
        var sheet = try #require(window.test_createSheet)
        sheet.test_pickIcon("airpods")
        sheet.test_commit()
        await drain()
        #expect(controller.groups.count == 1)
        let firstID = controller.groups[0].id
        #expect(controller.groups[0].iconSymbolName == "airpods")

        // Same member set again (order swapped), a DIFFERENT icon picked —
        // dedups onto the existing group, whose own icon must win
        // (`GroupController.createGroup`'s documented dedup rule).
        window.test_presentCreateSheet(preselected: ["appletv-lr", "office"])
        await drain()
        sheet = try #require(window.test_createSheet)
        sheet.test_pickIcon("homepod.fill")
        sheet.test_commit()
        await drain()

        #expect(controller.groups.count == 1, "no duplicate group for an identical member set")
        #expect(controller.groups.first { $0.id == firstID }?.iconSymbolName == "airpods", "dedup resolves to the existing group and does NOT overwrite its icon")
    }

    @Test func deviceIconControllerOverrideReachesEditorMembershipRow() async throws {
        let (window, controller, backend, icons) = try await makeWindowWithIconController()
        let saved = try makeGroup1(controller)   // members incl. office
        icons.setSymbolName("sofa.fill", for: "office")
        window.update(devices: backend.devices)
        window.test_select(.group(id: saved.id))
        await drain()
        // The mixer pane is gone (live-test feedback) — the shared override's
        // window-side rendering surface is the editor's membership rows.
        #expect(window.test_editor.test_candidateDeviceIDs.contains("office"))
        #expect(icons.symbolName(for: backend.devices.first { $0.id == "office" }!) == "sofa.fill", "the shared controller resolves the override the row renders")
    }

    // MARK: Keyboard focus (A11Y-GROUPS)
    //
    // Live-test finding: pressing Tab did nothing anywhere in the Groups
    // window, because nothing in its lifecycle ever calls
    // `NSWindow.makeFirstResponder(_:)` — so a freshly-shown window has no
    // real first responder to advance Tab FROM. `SidebarViewController`'s
    // `viewDidAppear()` override seeds the outline view as first responder
    // (see its doc comment for the full root-cause writeup); this asserts
    // that seed fires exactly the way a real hosting window appearing would
    // trigger it, without needing an actual on-screen window (never available
    // under `swift test`). The controller owns no window (U6), so the tests
    // stand a plain host window in for the surface's shell.

    @Test func contentHasNoFirstResponderBeforeItEverAppears() async throws {
        let (window, _, _) = try await makeWindow()
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 505),
                            styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        host.contentViewController = window.speakersContentController
        // Before `viewDidAppear()` has ever run, the host's first responder
        // is itself — nothing has claimed it. This is the exact state a live
        // Tab press found: nothing to advance from.
        #expect(window.test_sidebar.view.window === host)
        #expect(!(window.test_sidebar.test_isOutlineViewFirstResponder))
    }

    @Test func sidebarViewDidAppearSeedsTheOutlineViewAsFirstResponder() async throws {
        let (window, _, _) = try await makeWindow()
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 505),
                            styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        host.contentViewController = window.speakersContentController
        window.test_sidebar.test_simulateViewDidAppear()
        #expect(window.test_sidebar.test_isOutlineViewFirstResponder, "the sidebar's outline view must become first responder once the content appears, or Tab has nothing to advance from")
    }

    // MARK: Live marker (the card)

    // Turns red when the live scene's card stops carrying the gold marker, or carries it while nothing is the active Main Out.
    @Test func theLiveCardCarriesTheGoldMarker() async throws {
        let (window, controller, backend) = try await makeWindow()
        let saved = try makeGroup1(controller)
        window.update(devices: backend.devices)
        #expect(!window.test_overview.test_cardShowsLive(id: saved.id),
                "no marker while nothing is the active Main Out")

        controller.activateGroup(id: saved.id)
        window.update(devices: backend.devices)
        #expect(window.test_overview.test_cardShowsLive(id: saved.id),
                "the card names the live scene")
    }

    // MARK: Add-button retitle (multi-select discoverability)

    @Test func addButtonRetitlesWhileSpeakersAreMultiSelected() async throws {
        let (window, _, _) = try await makeWindow()
        #expect(window.test_sidebar.test_addButtonTitle == "Add scene")

        window.test_sidebar.test_selectDevices(["office", "sonos-move", "sonos-move-2"])
        #expect(window.test_sidebar.test_addButtonTitle == "Add scene from 3 speakers…",
                "the button says what + will actually do while speakers are multi-selected")

        window.test_sidebar.test_selectDevices([])
        #expect(window.test_sidebar.test_addButtonTitle == "Add scene")
    }

    // MARK: Selection-seeded create-sheet name

    @Test func createSheetPrefillsNameFromTheSelectedSpeakers() async throws {
        let (window, _, _) = try await makeWindow()
        window.test_presentCreateSheet(preselected: ["office", "sonos-move"])
        let sheet = try #require(window.test_createSheet)
        let candidates = sheet.test_candidateDeviceIDs   // sanity: both offered
        #expect(candidates.contains("office") && candidates.contains("sonos-move"))
        #expect(sheet.test_nameFieldText == "Office + Sonos Move")
    }

    // MARK: Deep link from the popover ("Equalizer…")

    @Test func selectDeviceShowsItsDetailAndHighlightsTheSidebarRow() async throws {
        let (window, _, _) = try await makeWindow()

        window.select(.device(id: "office"))

        #expect(window.test_isShowingDetail)
        #expect(window.test_detail.test_shownDeviceID == "office")
        #expect(window.test_sidebar.currentSelection == .device(id: "office"),
                "the deep link highlights the row too — arriving on a pane whose sidebar shows nothing selected reads as a bug")
    }

    @Test func selectingAnUnknownDevicePendsUntilTheSnapshotCarriesIt() async throws {
        let (window, _, backend) = try await makeWindow()

        window.select(.device(id: "ghost"))
        #expect(!window.test_isShowingDetail,
                "a device this screen has never been told about doesn't fall back to the default pane")
        #expect(window.test_pendingSelection == .device(id: "ghost"))

        let ghost = Device(id: "ghost", name: "Ghost", kind: .generic, isAvailable: true)
        window.update(devices: backend.devices + [ghost])

        #expect(window.test_isShowingDetail)
        #expect(window.test_detail.test_shownDeviceID == "ghost")
        #expect(window.test_pendingSelection == nil, "the deep link is spent, not repeated")
    }

    @Test func selectMainAudioShowsTheWholeMixPage() async throws {
        let (window, _, _) = try await makeWindow()
        window.mainOutEQProvider = { DeviceEQ(bassDB: 2) }

        window.select(.mainOut)

        #expect(window.test_isShowingMainOut)
        #expect(window.test_mainOutDetail.test_eqEditor.currentEQ.bassDB == 2,
                "the page pulls the whole mix's current tone when it opens")
        #expect(window.test_mainOutDetail.test_noteText == "Applies to audio sent to speakers.")
        #expect(window.test_mainOutDetail.test_eqSectionTitleText == "Equalizer",
                "the page's one card is titled, the same word the device page's card carries")
        #expect(window.test_mainOutDetail.test_titleText == "Main Audio")
    }

    @Test func mainOutScrubSurvivesASnapshotAndTheEchoReleasesTheCache() async throws {
        let (window, _, _) = try await makeWindow()
        window.mainOutEQProvider = { .flat }
        window.select(.mainOut)

        let detail = window.test_mainOutDetail
        let editor = detail.test_eqEditor

        // Mid-drag: a snapshot carrying the OLD value must not rewind the slider.
        editor.test_committedGestureOverride = false
        editor.test_dragBass(to: 5)
        detail.show(eq: .flat)
        #expect(editor.currentEQ.bassDB == 5,
                "a snapshot arriving mid-gesture can't yank the slider out from under the pointer")

        // Committed: the entry awaits its own echo — a stale flat snapshot
        // already queued from before the commit must not replay the drag
        // backward.
        editor.test_committedGestureOverride = true
        editor.test_dragBass(to: 5)
        detail.show(eq: .flat)
        #expect(editor.currentEQ.bassDB == 5,
                "a stale snapshot queued before the commit must not replay the drag on the knob")

        // The committed value's own echo releases the cache.
        detail.show(eq: DeviceEQ(bassDB: 5))
        #expect(editor.currentEQ.bassDB == 5)

        // Proof the cache is gone: a LATER flat snapshot now renders flat.
        detail.show(eq: .flat)
        #expect(editor.currentEQ.bassDB == 0,
                "kept past the echo the cache lies forever — the page would show a shaped curve while the audio stayed flat")
    }

    // MARK: The two tone seams

    @Test func mainAudioEditsReportOnTheWholeMixSeam() async throws {
        let (window, _, _) = try await makeWindow()
        var reported: [(DeviceEQ, Bool)] = []
        window.onSetMainOutEQ = { eq, committed in reported.append((eq, committed)) }
        window.select(.mainOut)

        let editor = window.test_mainOutDetail.test_eqEditor
        editor.test_committedGestureOverride = false
        editor.test_dragTreble(to: -4)
        #expect(reported.last?.0.trebleDB == -4)
        #expect(reported.last?.1 == false, "a live scrub applies but must not persist")

        editor.test_committedGestureOverride = true
        editor.test_dragTreble(to: -4)
        #expect(reported.last?.1 == true, "the gesture that ends the drag persists")

        window.test_mainOutDetail.test_fireResetClick()
        #expect(reported.last?.0 == .flat)
        #expect(reported.last?.1 == true, "Reset is one committed action")
    }

    /// Reset lives on the Main Audio page's title line too, wired through the
    /// same `MixerWindowController` seam a device page uses.
    @Test func mainAudioResetSitsOnTheTitleLineAndTracksTheTone() async throws {
        let (window, _, _) = try await makeWindow()
        window.mainOutEQProvider = { .flat }
        window.select(.mainOut)
        window.speakersContentController.view.layoutSubtreeIfNeeded()

        let detail = window.test_mainOutDetail
        #expect(detail.test_resetShown == false, "hidden while the curve is flat, as on the speaker page")

        detail.show(eq: DeviceEQ(bassDB: 2))
        #expect(detail.test_resetShown == true)

        let reset = detail.test_eqResetButtonFrame
        let titleAlign = detail.test_eqSectionTitleAlignmentFrame
        #expect(abs(reset.midY - titleAlign.midY) <= 0.5)
        #expect(abs(reset.maxX - detail.test_eqEditorFrame.maxX) <= 0.5)

        var reported: [(DeviceEQ, Bool)] = []
        window.onSetMainOutEQ = { eq, committed in reported.append((eq, committed)) }
        detail.test_fireResetClick()
        #expect(reported.last?.0 == .flat)
        #expect(reported.last?.1 == true)
        #expect(detail.test_resetShown == false)
    }

    @Test func deviceEditsReportWithTheDeviceID() async throws {
        let (window, _, _) = try await makeWindow()
        var reported: [(DeviceEQ, String, Bool)] = []
        window.onSetDeviceEQ = { eq, id, committed in reported.append((eq, id, committed)) }
        window.select(.device(id: "office"))

        let editor = window.test_detail.test_eqEditor
        editor.test_committedGestureOverride = true
        editor.test_dragBass(to: 3)

        #expect(reported.last?.0.bassDB == 3)
        #expect(reported.last?.1 == "office", "the whole point of the per-device seam is the id")
        #expect(reported.last?.2 == true)
    }

    // Turns red when an empty sidebar selection lands on Main Audio (or anywhere but the Speakers page) or disturbs the scene cards.
    @Test func autoSelectLandsOnTheOverviewWhenNothingIsSelected() async throws {
        let (window, controller, backend) = try await makeWindow()
        let group = try makeGroup1(controller)
        window.update(devices: backend.devices)

        window.test_select(nil)

        #expect(window.test_isShowingSpeakersPage,
                "the System Audio row must not steal the empty selection's landing")
        #expect(!window.test_isShowingMainOut)
        #expect(window.test_isShowingScenesOverview)
        #expect(window.test_overview.test_cardGroupIDs == [group.id])
    }
}

private actor WindowTestCountBox {
    private var count = 0
    func increment() -> Int { count += 1; return count }
}
