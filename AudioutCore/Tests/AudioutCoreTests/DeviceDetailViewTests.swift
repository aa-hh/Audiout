// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import AppKit
@testable import AudioutCore
@testable import AudioutPopoverUI
@testable import AudioutSharedUI
@testable import AudioutWindowUI

/// Unit coverage for `DeviceDetailViewController` — the read-only device
/// detail pane (design revamp, `../../Sources/AudioutWindowUI/AGENTS.md`).
/// This view is CONFIGURATION-ONLY: it only ever renders a `Device` snapshot
/// plus its saved-group memberships, and never activates a group or moves
/// audio. Wiring it into the "Scenes" window's sidebar selection is covered
/// separately in `MixerWindowControllerTests`; these cases construct the
/// controller directly and drive it through its `test_*` hooks, since a
/// headless run can't synthesize the real hover/click gestures.
// `@MainActor` is load-bearing, not decoration: this suite builds and drives
// AppKit views, and every `NSView`-family API is main-actor-only. XCTest ran
// each test method on the main thread, so the annotation was never needed;
// swift-testing schedules non-isolated `@Test` bodies on the cooperative
// pool, where the same calls trip AppKit's "modifications to layout engine
// from a background thread" exception and take the whole process down
// (observed in `AppRowViewTests` during this migration). Do not remove it.
@MainActor
@Suite struct DeviceDetailViewTests {

    private let isolation = TestIsolation(owner: "DeviceDetailViewTests")

    private func tempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeviceDetailViewTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A `GroupController` with an empty, non-persisted `MockBackend` — this
    /// view only ever reads `groupController.groups` (for membership text),
    /// never the backend, so an un-started, fleet-less backend is enough.
    private func makeController() -> GroupController {
        let backend = MockBackend(fleet: [], staggerDiscovery: false, emitsLevels: false, simulatesDropouts: false)
        return GroupController(backend: backend, store: GroupStore(directory: tempDirectory()), loadPersisted: false)
    }

    private func makeDevice(
        id: String = "d1", name: String = "Office", kind: Device.Kind = .generic,
        isAvailable: Bool = true, supportsAirPlay2: Bool = true, volume: Int = 50,
        connectionState: ConnectionState = .off
    ) -> Device {
        Device(id: id, name: name, kind: kind, isAvailable: isAvailable,
              supportsAirPlay2: supportsAirPlay2, volume: volume,
              connectionState: connectionState)
    }

    // MARK: show(device:) basics

    @Test func showSetsShownDeviceID() {
        let detail = DeviceDetailViewController(groupController: makeController(),
                                            settings: AppSettings(defaults: isolation.isolatedDefaults))
        detail.show(device: makeDevice(id: "sonos-move"))
        #expect(detail.test_shownDeviceID == "sonos-move")
    }

    @Test func shownDeviceIDIsNilBeforeFirstShow() {
        let detail = DeviceDetailViewController(groupController: makeController(),
                                            settings: AppSettings(defaults: isolation.isolatedDefaults))
        #expect(detail.test_shownDeviceID == nil)
    }

    @Test func refreshUpdatesFieldsForTheSameDevice() {
        let detail = DeviceDetailViewController(groupController: makeController(),
                                            settings: AppSettings(defaults: isolation.isolatedDefaults))
        detail.show(device: makeDevice(isAvailable: true))
        #expect(detail.test_metadataStrings["status"] == "Ready")

        detail.refresh(device: makeDevice(isAvailable: false))
        #expect(detail.test_metadataStrings["status"] == "Not on the network")
        #expect(detail.test_shownDeviceID == "d1")
    }

    // MARK: Metadata form — status wording

    @Test func statusTextOff() {
        let detail = DeviceDetailViewController(groupController: makeController(),
                                            settings: AppSettings(defaults: isolation.isolatedDefaults))
        detail.show(device: makeDevice(isAvailable: true, connectionState: .off))
        #expect(detail.test_metadataStrings["status"] == "Ready",
                "a reachable idle speaker is something you can use, not something broken")
    }

    @Test func statusTextOffAndUnreachable() {
        let detail = DeviceDetailViewController(groupController: makeController(),
                                            settings: AppSettings(defaults: isolation.isolatedDefaults))
        detail.show(device: makeDevice(isAvailable: false, connectionState: .off))
        #expect(detail.test_metadataStrings["status"] == "Not on the network",
                "Status folds availability in — it is the only row that reports it")
    }

    @Test func statusTextConnecting() {
        let detail = DeviceDetailViewController(groupController: makeController(),
                                            settings: AppSettings(defaults: isolation.isolatedDefaults))
        detail.show(device: makeDevice(connectionState: .connecting))
        #expect(detail.test_metadataStrings["status"] == "Connecting…")
    }

    @Test func statusTextConnectingIgnoresAvailability() {
        let detail = DeviceDetailViewController(groupController: makeController(),
                                            settings: AppSettings(defaults: isolation.isolatedDefaults))
        detail.show(device: makeDevice(isAvailable: false, connectionState: .connecting))
        #expect(detail.test_metadataStrings["status"] == "Connecting…",
                "availability is consulted only in the idle arm")
    }

    @Test func statusTextReconnecting() {
        let detail = DeviceDetailViewController(groupController: makeController(),
                                            settings: AppSettings(defaults: isolation.isolatedDefaults))
        detail.show(device: makeDevice(connectionState: .reconnecting))
        #expect(detail.test_metadataStrings["status"] == "Reconnecting…")
    }

    @Test func statusTextConnected() {
        let detail = DeviceDetailViewController(groupController: makeController(),
                                            settings: AppSettings(defaults: isolation.isolatedDefaults))
        detail.show(device: makeDevice(connectionState: .connected))
        #expect(detail.test_metadataStrings["status"] == "Connected")
    }

    @Test func statusTextFailed() {
        let detail = DeviceDetailViewController(groupController: makeController(),
                                            settings: AppSettings(defaults: isolation.isolatedDefaults))
        detail.show(device: makeDevice(connectionState: .failed(.init(cause: .notResponding))))
        #expect(detail.test_metadataStrings["status"] == "Couldn't connect",
                       "matches DeviceRowView's existing failed vocabulary")
    }

    // MARK: About list — the AirPlay row

    @Test func airPlayRowReadsAirPlay2OrAirPlay1() {
        let detail = DeviceDetailViewController(groupController: makeController(),
                                            settings: AppSettings(defaults: isolation.isolatedDefaults))
        detail.show(device: makeDevice(kind: .generic, supportsAirPlay2: true))
        #expect(detail.test_metadataStrings["airplay"] == "AirPlay 2")

        detail.show(device: makeDevice(kind: .airportExpress, supportsAirPlay2: false))
        #expect(detail.test_metadataStrings["airplay"] == "AirPlay 1 — sync not exact",
                "says what AirPlay 1 costs, not just its version number")
    }

    @Test func airPlayRowIsHiddenForBluetoothAndThisMac() {
        let detail = DeviceDetailViewController(groupController: makeController(),
                                            settings: AppSettings(defaults: isolation.isolatedDefaults))
        detail.show(device: makeDevice(kind: .bluetooth, supportsAirPlay2: false))
        #expect(detail.test_metadataStrings["airplay"] == nil,
                "a Bluetooth speaker is not an AirPlay receiver at all")

        detail.show(device: makeDevice(kind: .localMac))
        #expect(detail.test_metadataStrings["airplay"] == nil,
                "This Mac is where the audio comes FROM")
    }

    // MARK: About list — kind

    @Test func kindTextForEveryKind() {
        let detail = DeviceDetailViewController(groupController: makeController(),
                                            settings: AppSettings(defaults: isolation.isolatedDefaults))
        let expectations: [(Device.Kind, String)] = [
            (.localMac, "This Mac"),
            (.homePod, "HomePod"),
            (.appleTV, "Apple TV"),
            (.airportExpress, "AirPort Express"),
            (.sonos, "Sonos"),
            (.generic, "AirPlay Speaker"),
            (.bluetooth, "Bluetooth Speaker"),
        ]
        for (kind, expected) in expectations {
            detail.show(device: makeDevice(kind: kind))
            #expect(detail.test_metadataStrings["kind"] == expected, "kind: \(kind)")
        }
    }

    // MARK: "In groups" membership text

    @Test func groupMembershipTextIsNoneWhenDeviceIsInNoGroup() {
        let detail = DeviceDetailViewController(groupController: makeController(),
                                            settings: AppSettings(defaults: isolation.isolatedDefaults))
        detail.show(device: makeDevice(id: "office"))
        #expect(detail.test_groupMembershipText == "None")
    }

    @Test func groupMembershipTextListsEverySavedGroupContainingTheDevice() throws {
        let controller = makeController()
        try controller.saveGroup(Group(id: "g1", name: "Kitchen", memberIDs: ["office", "appletv-lr"],
                                       memberVolumes: ["office": 50, "appletv-lr": 60]))
        try controller.saveGroup(Group(id: "g2", name: "Whole House", memberIDs: ["office"],
                                       memberVolumes: ["office": 50]))
        try controller.saveGroup(Group(id: "g3", name: "Bedroom", memberIDs: ["appletv-lr"],
                                       memberVolumes: ["appletv-lr": 60]))

        let detail = DeviceDetailViewController(groupController: controller,
                                            settings: AppSettings(defaults: isolation.isolatedDefaults))
        detail.show(device: makeDevice(id: "office"))
        #expect(detail.test_groupMembershipText == "Kitchen, Whole House",
                       "only groups this device is a member of, in groupController.groups order")
    }

    @Test func groupMembershipTextUpdatesOnRefreshAfterAMembershipChange() throws {
        let controller = makeController()
        // Seed with a DIFFERENT member so "office" starts as a non-member while
        // the group stays non-empty (an empty group is now rejected).
        try controller.saveGroup(Group(id: "g1", name: "Kitchen", memberIDs: ["living-room"],
                                       memberVolumes: ["living-room": 50]))
        let detail = DeviceDetailViewController(groupController: controller,
                                            settings: AppSettings(defaults: isolation.isolatedDefaults))
        detail.show(device: makeDevice(id: "office"))
        #expect(detail.test_groupMembershipText == "None")

        var group = try #require(controller.groups.first { $0.id == "g1" })
        group.memberIDs = ["office"]
        group.memberVolumes["office"] = 50
        try controller.saveGroup(group)

        detail.refresh(device: makeDevice(id: "office"))
        #expect(detail.test_groupMembershipText == "Kitchen")
    }

    // MARK: The "Scenes" membership section — rows, order, empty state

    @Test func groupsSectionIsTitledGroups() {
        let detail = DeviceDetailViewController(groupController: makeController(),
                                            settings: AppSettings(defaults: isolation.isolatedDefaults))
        _ = detail.view
        detail.show(device: makeDevice(id: "office"))
        #expect(detail.test_groupsSectionTitleText == "Scenes")
    }

    @Test func groupRowsListEverySavedGroupContainingTheDeviceInSidebarOrder() throws {
        let controller = makeController()
        try controller.saveGroup(Group(id: "g1", name: "Kitchen", memberIDs: ["office", "appletv-lr"],
                                       memberVolumes: ["office": 50, "appletv-lr": 60]))
        try controller.saveGroup(Group(id: "g2", name: "Whole House", memberIDs: ["office"],
                                       memberVolumes: ["office": 50]))
        try controller.saveGroup(Group(id: "g3", name: "Bedroom", memberIDs: ["appletv-lr"],
                                       memberVolumes: ["appletv-lr": 60]))

        let detail = DeviceDetailViewController(groupController: controller,
                                            settings: AppSettings(defaults: isolation.isolatedDefaults))
        _ = detail.view
        detail.show(device: makeDevice(id: "office"))

        #expect(detail.test_groupRowTitles == ["Kitchen", "Whole House"],
                Comment(rawValue: "one row per group this device is in, in groupController.groups order — " +
                "the same order SidebarViewController.reload maps to its Groups section"))
    }

    @Test func groupRowsShowTheEmptyStateRowWhenTheDeviceIsInNoGroup() {
        let detail = DeviceDetailViewController(groupController: makeController(),
                                            settings: AppSettings(defaults: isolation.isolatedDefaults))
        _ = detail.view
        detail.show(device: makeDevice(id: "office"))
        #expect(detail.test_groupRowTitles == ["Not in any scene"],
                "the section stays visible and says so, rather than disappearing")
    }

    @Test func groupRowsRebuildWhenMembershipChanges() throws {
        let controller = makeController()
        try controller.saveGroup(Group(id: "g1", name: "Kitchen", memberIDs: ["living-room"],
                                       memberVolumes: ["living-room": 50]))
        let detail = DeviceDetailViewController(groupController: controller,
                                            settings: AppSettings(defaults: isolation.isolatedDefaults))
        _ = detail.view
        detail.show(device: makeDevice(id: "office"))
        #expect(detail.test_groupRowTitles == ["Not in any scene"])

        var group = try #require(controller.groups.first { $0.id == "g1" })
        group.memberIDs = ["office"]
        group.memberVolumes["office"] = 50
        try controller.saveGroup(group)

        detail.refresh(device: makeDevice(id: "office"))
        #expect(detail.test_groupRowTitles == ["Kitchen"],
                "a rebuild replaces the rows — it never stacks a second set behind the first")
    }

    /// `refreshUI()` runs on every backend event for the app's whole lifetime.
    /// A volume/connection-only change touches nothing a membership row draws,
    /// so it must not throw away and rebuild the rows (and the clicks and
    /// focus riding on them); a group rename still must.
    @Test func groupRowsSkipARebuildWhenNothingTheyRenderChanged() throws {
        let controller = makeController()
        try controller.saveGroup(Group(id: "g1", name: "Kitchen", memberIDs: ["office"],
                                       memberVolumes: ["office": 50]))
        let detail = DeviceDetailViewController(groupController: controller,
                                            settings: AppSettings(defaults: isolation.isolatedDefaults))
        _ = detail.view
        detail.show(device: makeDevice(id: "office"))
        #expect(detail.test_groupRowTitles == ["Kitchen"])
        let baseline = detail.test_groupRowsRebuildCount
        #expect(baseline > 0, "the first show built the rows once")

        detail.refresh(device: makeDevice(id: "office", volume: 80, connectionState: .connected))
        #expect(detail.test_groupRowsRebuildCount == baseline,
                "no membership row shows a volume or a connection state")

        var group = try #require(controller.groups.first { $0.id == "g1" })
        group.name = "Kitchen Speakers"
        try controller.saveGroup(group)
        detail.refresh(device: makeDevice(id: "office"))
        #expect(detail.test_groupRowsRebuildCount == baseline + 1,
                "a rename IS on a membership row, so it rebuilds exactly once")
        #expect(detail.test_groupRowTitles == ["Kitchen Speakers"])
    }

    @Test func selectingAGroupRowReportsThatGroupsID() throws {
        let controller = makeController()
        try controller.saveGroup(Group(id: "g1", name: "Kitchen", memberIDs: ["office"],
                                       memberVolumes: ["office": 50]))
        try controller.saveGroup(Group(id: "g2", name: "Whole House", memberIDs: ["office"],
                                       memberVolumes: ["office": 50]))

        let detail = DeviceDetailViewController(groupController: controller,
                                            settings: AppSettings(defaults: isolation.isolatedDefaults))
        _ = detail.view
        detail.show(device: makeDevice(id: "office"))

        var reported: [String] = []
        detail.onSelectGroup = { reported.append($0) }

        detail.test_selectGroupRow(at: 1)
        #expect(reported == ["g2"], "the row's id, not its position in groupController.groups")

        detail.test_selectGroupRow(at: 0)
        #expect(reported == ["g2", "g1"])
    }

    @Test func theEmptyStateRowIsNotClickable() {
        let detail = DeviceDetailViewController(groupController: makeController(),
                                            settings: AppSettings(defaults: isolation.isolatedDefaults))
        _ = detail.view
        detail.show(device: makeDevice(id: "office"))

        var reported: [String] = []
        detail.onSelectGroup = { reported.append($0) }
        detail.test_selectGroupRow(at: 0)
        detail.test_selectGroupRow(at: 7)

        #expect(reported.isEmpty, "there is nothing to open")
    }

    @Test func theGroupsTitleSitsBetweenTheEqualizerCardAndTheGroupsList() throws {
        let detail = try laidOutPaneWithOneGroup()

        let card = detail.test_eqSectionFrame
        let title = detail.test_groupsSectionTitleFrame
        let section = detail.test_groupsSectionFrame

        // The pane's own view is NOT flipped, so "below" reads as a SMALLER y.
        // Half-point tolerance: auto layout snaps frames onto a rounding grid
        // whose pitch varies BETWEEN RUNS of the same binary
        // (`AudioutWindowUI/AGENTS.md`), and this pane's insets are half
        // points. Never assert absolute widths here for the same reason.
        #expect(title.maxY <= card.minY + 0.5,
                "the title sits below the Equalizer card's bottom edge")
        #expect(section.maxY <= title.minY + 0.5,
                "…and above the Groups list it titles")
    }

    @Test func theEqualizerCardInsetsTheEditorByCardContentInsetNotVerticalPadding() throws {
        let detail = try laidOutPaneWithOneGroup()

        let card = detail.test_eqSectionFrame
        let editor = detail.test_eqEditorFrame

        // The pane's own view is NOT flipped, so the card's top edge is a
        // LARGER y than the editor's. Half-point tolerance: auto layout snaps
        // frames onto a rounding grid whose pitch varies BETWEEN RUNS of the
        // same binary (`AudioutWindowUI/AGENTS.md`).
        #expect(abs(card.maxY - editor.maxY - GroupsPaneLayout.cardContentInset) < 0.5,
                "the card's top breathes cardContentInset above the editor's first row, not the tighter verticalPadding used by bare row lists")
        #expect(abs(editor.minY - card.minY - GroupsPaneLayout.cardContentInset) < 0.5,
                "…and the same inset below it")
    }

    @Test func theAboutTitleSitsBetweenTheGroupsListAndTheAboutList() throws {
        let detail = try laidOutPaneWithOneGroup()

        let groups = detail.test_groupsSectionFrame
        let title = detail.test_aboutSectionTitleFrame
        let about = detail.test_aboutSectionFrame

        #expect(title.maxY <= groups.minY + 0.5,
                "the title sits below the Groups list")
        #expect(about.maxY <= title.minY + 0.5,
                "…and above the About list it titles")
    }

    @Test func aGroupRowsNameStretchesToTheChevronAndTruncatesRatherThanRunningUnderIt() throws {
        let controller = makeController()
        // ~55 characters — far past any realistic column width, so the row has
        // to give way somewhere — and a short one right after it.
        try controller.saveGroup(Group(id: "g1",
                                       name: "Whole House Downstairs Speakers and the Back Patio Pair",
                                       memberIDs: ["office"], memberVolumes: ["office": 50]))
        try controller.saveGroup(Group(id: "g2", name: "Den",
                                       memberIDs: ["office"], memberVolumes: ["office": 50]))
        let detail = DeviceDetailViewController(groupController: controller,
                                            settings: AppSettings(defaults: isolation.isolatedDefaults))
        detail.show(device: makeDevice(id: "office"))
        _ = detail.view
        detail.view.setFrameSize(AppSurfaceController.minimumContentSize)
        detail.view.layoutSubtreeIfNeeded()

        let buttons = detail.test_groupRowButtonFrames
        let chevrons = detail.test_groupRowChevronFrames
        let titles = detail.test_groupRowTitleRects
        #expect(buttons.count == 2)
        #expect(chevrons.count == 2)
        #expect(titles.count == 2)

        let gap = DeviceDetailViewController.test_groupRowChevronGap
        for (row, name) in [(0, "long"), (1, "short")] {
            // `NSButtonCell` fires only when the mouse-UP lands inside the
            // button's OWN frame, so the glyph has to sit INSIDE the button or
            // every click on it is dead however the hit test is routed.
            let glyphMiddle = NSPoint(x: chevrons[row].midX, y: chevrons[row].midY)
            #expect(buttons[row].contains(glyphMiddle),
                    Comment(rawValue: "the \(name) row's chevron sits inside its button, so a click " +
                    "on the glyph opens the group"))
            // Half-point tolerance for the per-run rounding grid, the same
            // reason the slot-order assertions carry one. Never an absolute
            // width.
            #expect(titles[row].maxX <= chevrons[row].minX - gap + 0.5,
                    Comment(rawValue: "the \(name) row's title stops a gap short of the chevron " +
                    "rather than drawing under it"))
        }
    }

    /// A speaker pane in one saved group, mounted and laid out at the screen's
    /// real content size — the shared setup for the slot-order assertions.
    private func laidOutPaneWithOneGroup() throws -> DeviceDetailViewController {
        let controller = makeController()
        try controller.saveGroup(Group(id: "g1", name: "Kitchen", memberIDs: ["office"],
                                       memberVolumes: ["office": 50]))
        let detail = DeviceDetailViewController(groupController: controller,
                                            settings: AppSettings(defaults: isolation.isolatedDefaults))
        detail.show(device: makeDevice(id: "office"))
        _ = detail.view
        detail.view.setFrameSize(AppSurfaceController.minimumContentSize)
        detail.view.layoutSubtreeIfNeeded()
        return detail
    }

    // MARK: Icon resolution — no injected controller

    @Test func iconSymbolNameFallsBackToKindDefaultWithNoInjectedController() {
        let detail = DeviceDetailViewController(groupController: makeController(),
                                            settings: AppSettings(defaults: isolation.isolatedDefaults))
        detail.show(device: makeDevice(kind: .homePod))
        #expect(detail.test_iconSymbolName == Device.Kind.homePod.symbolName)
    }

    // MARK: Icon resolution — injected controller with/without an override

    @Test func iconSymbolNameUsesKindDefaultWhenControllerHasNoOverride() {
        let iconController = DeviceIconController(store: DeviceIconStore(directory: tempDirectory()), loadPersisted: false)
        let detail = DeviceDetailViewController(groupController: makeController(),
                                            settings: AppSettings(defaults: isolation.isolatedDefaults))
        detail.deviceIconController = iconController

        detail.show(device: makeDevice(kind: .sonos))
        #expect(detail.test_iconSymbolName == Device.Kind.sonos.symbolName)
    }

    @Test func iconSymbolNameUsesOverrideWhenControllerHasOneSet() {
        let iconController = DeviceIconController(store: DeviceIconStore(directory: tempDirectory()), loadPersisted: false)
        let device = makeDevice(kind: .sonos)
        iconController.setSymbolName("airpods", for: device.id)

        let detail = DeviceDetailViewController(groupController: makeController(),
                                            settings: AppSettings(defaults: isolation.isolatedDefaults))
        detail.deviceIconController = iconController
        detail.show(device: device)

        #expect(detail.test_iconSymbolName == "airpods")
    }

    @Test func iconSymbolNameFallsBackToDefaultForAStaleOverride() {
        // The controller only ever persists a valid name (`setSymbolName` is a
        // no-op for an invalid one — DeviceIconResolverTests), so a "stale"
        // override is simulated by writing the store's raw file directly, the
        // same way a symbol removed on a future OS would surface.
        let directory = tempDirectory()
        let store = DeviceIconStore(directory: directory)
        try? store.save(["d1": "definitely.not.a.symbol.zzz"])
        let iconController = DeviceIconController(store: store, loadPersisted: true)

        let detail = DeviceDetailViewController(groupController: makeController(),
                                            settings: AppSettings(defaults: isolation.isolatedDefaults))
        detail.deviceIconController = iconController
        detail.show(device: makeDevice(id: "d1", kind: .appleTV))

        #expect(detail.test_iconSymbolName == Device.Kind.appleTV.symbolName,
                       "a stale override still falls back to the kind default, never a blank glyph")
    }

    // MARK: Icon picker flow — instant-apply through DeviceIconController

    @Test func clickEditIconBuildsAPickerConfiguredWithCurrentOverrideAndKindDefault() {
        let iconController = DeviceIconController(store: DeviceIconStore(directory: tempDirectory()), loadPersisted: false)
        let device = makeDevice(kind: .homePod)
        iconController.setSymbolName("airpods", for: device.id)

        let detail = DeviceDetailViewController(groupController: makeController(),
                                            settings: AppSettings(defaults: isolation.isolatedDefaults))
        detail.deviceIconController = iconController
        detail.show(device: device)

        let picker = detail.test_clickEditIcon()
        #expect(picker != nil)
        #expect(detail.test_picker === picker, "the most recently built picker is retained for further driving")
    }

    @Test func pickingACuratedIconPersistsThroughControllerAndUpdatesTheWell() {
        let iconController = DeviceIconController(store: DeviceIconStore(directory: tempDirectory()), loadPersisted: false)
        let device = makeDevice(kind: .homePod)

        let detail = DeviceDetailViewController(groupController: makeController(),
                                            settings: AppSettings(defaults: isolation.isolatedDefaults))
        detail.deviceIconController = iconController
        detail.show(device: device)
        #expect(detail.test_iconSymbolName == Device.Kind.homePod.symbolName)

        let picker = detail.test_clickEditIcon()
        picker.test_pickCurated("airpods")

        #expect(detail.test_iconSymbolName == "airpods", "instant-apply — no separate Save step")
        #expect(iconController.overrides[device.id] == "airpods")
    }

    @Test func useDefaultResetsTheOverride() {
        let iconController = DeviceIconController(store: DeviceIconStore(directory: tempDirectory()), loadPersisted: false)
        let device = makeDevice(kind: .homePod)
        iconController.setSymbolName("airpods", for: device.id)

        let detail = DeviceDetailViewController(groupController: makeController(),
                                            settings: AppSettings(defaults: isolation.isolatedDefaults))
        detail.deviceIconController = iconController
        detail.show(device: device)
        #expect(detail.test_iconSymbolName == "airpods")

        let picker = detail.test_clickEditIcon()
        picker.test_useDefault()

        #expect(detail.test_iconSymbolName == Device.Kind.homePod.symbolName)
        #expect(iconController.overrides[device.id] == nil)
    }

    @Test func pickingAnIconWithNoInjectedControllerIsANoOp() {
        let device = makeDevice(kind: .sonos)
        let detail = DeviceDetailViewController(groupController: makeController(),
                                            settings: AppSettings(defaults: isolation.isolatedDefaults))
        // No `deviceIconController` assigned — nil-tolerant per `../../AGENTS.md`.
        detail.show(device: device)

        let picker = detail.test_clickEditIcon()
        picker.test_pickCurated("airpods")

        #expect(detail.test_iconSymbolName == Device.Kind.sonos.symbolName,
                       "nothing to write through — the glyph stays at the kind default")
    }

    // MARK: The Equalizer section

    /// Loads the view (the Equalizer's delegate and the "Scenes" title's two
    /// alternative top constraints are wired in `loadView`) and shows `device`.
    private func makeLoadedPane(device: Device) -> DeviceDetailViewController {
        let detail = DeviceDetailViewController(groupController: makeController(),
                                            settings: AppSettings(defaults: isolation.isolatedDefaults))
        _ = detail.view
        detail.show(device: device)
        return detail
    }

    @Test func equalizerSectionIsHiddenOnThisMac() {
        let detail = makeLoadedPane(device: makeDevice(id: "local", name: "This Mac", kind: .localMac))
        #expect(!detail.test_eqSectionShown,
                "the Mac is where the audio comes FROM — there is no send to tune")
    }

    @Test func equalizerSectionIsShownOnASpeaker() {
        let detail = makeLoadedPane(device: makeDevice())
        #expect(detail.test_eqSectionShown)
        #expect(detail.test_slotTitles == ["Equalizer", "Scenes", "About"])
        #expect(detail.test_cardFrames.count == 1,
                "the Equalizer is the page's one instrument, so its one card")
    }

    // MARK: The Equalizer section's title

    @Test func eqSectionTitleShowsOnASpeaker() {
        let detail = makeLoadedPane(device: makeDevice())
        #expect(detail.test_eqSectionTitleText == "Equalizer")
    }

    @Test func eqSectionTitleIsNilOnThisMac() {
        let detail = makeLoadedPane(device: makeDevice(id: "local", name: "This Mac", kind: .localMac))
        #expect(detail.test_eqSectionTitleText == nil,
                "hides together with the Equalizer section it titles")
    }

    @Test func eqSectionTitleSitsBetweenTheHeaderAndTheEqualizerCard() {
        let detail = makeLoadedPane(device: makeDevice())
        // The pane's own `view` is NOT flipped, so "below" reads as a SMALLER
        // y here; the half point is the run's rounding grid, nothing else.
        #expect(detail.test_eqSectionTitleFrame.maxY <= detail.test_headerSectionFrame.minY + 0.5,
                "the title sits below the identity band")
        #expect(detail.test_eqSectionFrame.maxY <= detail.test_eqSectionTitleFrame.minY + 0.5,
                "the Equalizer card's own content sits below its title")
    }

    /// One card per page, and identity/Groups/About are bare: a box is earned
    /// by holding a different instrument, never by length. The titles are bare
    /// pane text, the same idiom as the group editor's "Speakers" label.
    @Test func onlyTheEqualizerIsACard() {
        let detail = makeLoadedPane(device: makeDevice())
        #expect(detail.test_cardFrames.count == 1)

        detail.show(device: makeDevice(id: "local", name: "This Mac", kind: .localMac))
        #expect(detail.test_cardFrames.count == 0,
                "This Mac has no instrument, so it has no card at all")
        #expect(detail.test_slotTitles == ["Scenes", "About"])
    }

    /// Proves `settings:` actually threads from the host's `init` down to the
    /// editor it builds, rather than each falling back to its own default
    /// `AppSettings()` (which would read `.standard`): a store that already
    /// has the Advanced fold expanded produces a pane whose editor opens
    /// expanded, and an untouched store produces one that opens collapsed.
    @Test func eqAdvancedExpandedThreadsFromInjectedSettings() {
        AppSettings(defaults: isolation.isolatedDefaults).eqAdvancedExpanded = true
        let expandedPane = DeviceDetailViewController(groupController: makeController(),
                                                       settings: AppSettings(defaults: isolation.isolatedDefaults))
        #expect(expandedPane.test_eqEditor.test_advancedExpanded == true)

        let freshStore = TestIsolation(owner: "DeviceDetailViewTests-fresh")
        let freshPane = DeviceDetailViewController(groupController: makeController(),
                                                    settings: AppSettings(defaults: freshStore.isolatedDefaults))
        #expect(freshPane.test_eqEditor.test_advancedExpanded == false)
    }

    @Test func bypassSentencesComeFromTheSnapshot() {
        var device = makeDevice()
        device.eqBypassReason = .streamBudget
        let detail = makeLoadedPane(device: device)
        #expect(detail.test_eqEditor.test_bypassNoteText
                == "Not applied — too many different EQ settings at once.")

        device.eqBypassReason = .perAppRouting
        detail.refresh(device: device)
        #expect(detail.test_eqEditor.test_bypassNoteText
                == "Not applied — apps are routed directly to this speaker.")
    }

    @Test func aScrubAppliesAndAMouseUpCommits() {
        let detail = makeLoadedPane(device: makeDevice(id: "office"))
        var reported: [(DeviceEQ, String, Bool)] = []
        detail.onSetEQ = { eq, id, committed in reported.append((eq, id, committed)) }

        detail.test_eqEditor.test_committedGestureOverride = false
        detail.test_eqEditor.test_dragBass(to: 5)
        #expect(reported.last?.0.bassDB == 5)
        #expect(reported.last?.1 == "office")
        #expect(reported.last?.2 == false)

        detail.test_eqEditor.test_committedGestureOverride = true
        detail.test_eqEditor.test_dragBass(to: 5)
        #expect(reported.last?.2 == true)
    }

    @Test func resetCommitsFlatInOneAction() {
        let detail = makeLoadedPane(device: makeDevice(id: "office"))
        detail.test_eqEditor.test_committedGestureOverride = true
        detail.test_eqEditor.test_dragBass(to: 5)

        var reported: [(DeviceEQ, String, Bool)] = []
        detail.onSetEQ = { eq, id, committed in reported.append((eq, id, committed)) }
        detail.test_fireResetClick()

        #expect(reported.count == 1, "Reset is ONE action, not one per stage")
        #expect(reported.last?.0 == .flat)
        #expect(reported.last?.2 == true)
    }

    /// Reset now sits on the "Equalizer" title line, trailing-aligned to the
    /// same content edge the editor itself trails to — not inside the editor.
    @Test func resetSitsOnTheEqualizerTitleLine() {
        let detail = makeShownThenLoadedPane(device: makeDevice())
        let reset = detail.test_eqResetButtonFrame
        let titleAlign = detail.test_eqSectionTitleAlignmentFrame
        #expect(abs(reset.midY - titleAlign.midY) <= 0.5)
        #expect(abs(reset.maxX - detail.test_eqEditorFrame.maxX) <= 0.5)
    }

    /// The editor's own rendered model IS the source of truth for enablement.
    @Test func resetEnablementTracksTheTone() {
        let detail = makeLoadedPane(device: makeDevice(id: "office"))
        #expect(detail.test_resetEnabled == false, "a flat device has nothing to reset")

        var shaped = makeDevice(id: "office")
        shaped.eq = DeviceEQ(bassDB: 3)
        detail.refresh(device: shaped)
        #expect(detail.test_resetEnabled == true)

        var reported: [(DeviceEQ, String, Bool)] = []
        detail.onSetEQ = { eq, id, committed in reported.append((eq, id, committed)) }
        detail.test_fireResetClick()
        #expect(detail.test_resetEnabled == false)
        #expect(reported.last?.0 == .flat)
        #expect(reported.last?.1 == "office")
        #expect(reported.last?.2 == true)
    }

    /// This Mac has no send to tune, so the Reset button hides with the slot.
    @Test func resetIsHiddenOnThisMac() {
        let detail = makeLoadedPane(device: makeDevice(id: "local", name: "This Mac", kind: .localMac))
        #expect(detail.test_resetShown == false)
    }

    @Test func curveTracksTheEditor() {
        let detail = makeLoadedPane(device: makeDevice())
        #expect(detail.test_eqEditor.test_curve.test_plan.state == .flat)

        detail.test_eqEditor.test_committedGestureOverride = true
        detail.test_eqEditor.test_dragBass(to: 6)
        #expect(detail.test_eqEditor.test_curve.test_plan.state == .shaped,
                "the picture and the controls read the same model")
    }

    // MARK: First load — shown BEFORE mounted (the live order)

    /// Mirrors what `MixerWindowController.showDetail` really does: it calls
    /// `show(device:)` and swaps the pane in AFTERWARDS, so the first
    /// `refreshUI()` runs while the hint's two alternative top pins are still
    /// nil. `makeLoadedPane` forces the view first and can never catch that.
    /// No window is involved — the pane is laid out at the Groups screen's
    /// content size directly, so nothing can appear on screen.
    private func makeShownThenLoadedPane(device: Device) -> DeviceDetailViewController {
        let detail = DeviceDetailViewController(groupController: makeController(),
                                            settings: AppSettings(defaults: isolation.isolatedDefaults))
        detail.show(device: device)
        _ = detail.view
        // The fixed frame's floor; only the width matters here.
        detail.view.setFrameSize(AppSurfaceController.minimumContentSize)
        detail.view.layoutSubtreeIfNeeded()
        return detail
    }

    /// The scroll document's laid-out height — what collapses when the
    /// "Scenes" title has no top pin, since everything below it (down to the
    /// About list that ties the column's bottom) hangs off that pin.
    private func documentHeight(_ detail: DeviceDetailViewController) -> CGFloat {
        let scroll = detail.view.subviews.compactMap { $0 as? NSScrollView }.first
        return scroll?.documentView?.frame.height ?? 0
    }

    @Test func aPaneShownBeforeItIsMountedStillTiesTheColumnToTheAboutList() {
        let detail = makeShownThenLoadedPane(device: makeDevice())

        #expect(detail.test_activeGroupsTitlePinCount == 1,
                Comment(rawValue: "the \"Groups\" title must have exactly one top pin from the moment " +
                "the view loads — with none the column's height goes ambiguous"))
        // The pane's own view is NOT flipped, so "below" is a SMALLER y.
        #expect(detail.test_groupsSectionTitleFrame.maxY <= detail.test_eqSectionFrame.minY + 0.5,
                "the title sits under the Equalizer card, what precedes it on a speaker")

        let slots = detail.test_headerSectionFrame.height + detail.test_eqSectionFrame.height
            + detail.test_groupsSectionFrame.height + detail.test_aboutSectionFrame.height
        #expect(documentHeight(detail) > slots,
                "the document holds the whole stack — a collapsed one is shorter than its own slots")
    }

    @Test func aThisMacPaneShownBeforeItIsMountedPutsGroupsDirectlyUnderTheHeader() {
        let detail = makeShownThenLoadedPane(
            device: makeDevice(id: "local", name: "This Mac", kind: .localMac))

        #expect(detail.test_activeGroupsTitlePinCount == 1)
        #expect(!detail.test_eqSectionShown)
        #expect(detail.test_groupsSectionTitleFrame.maxY <= detail.test_headerSectionFrame.minY + 0.5,
                "with the Equalizer gone, Groups closes up under the identity band")

        let slots = detail.test_headerSectionFrame.height + detail.test_groupsSectionFrame.height
            + detail.test_aboutSectionFrame.height
        #expect(documentHeight(detail) > slots)
    }

    @Test func theGroupsTitlePinFollowsTheDeviceInBothDirections() {
        let detail = makeShownThenLoadedPane(device: makeDevice())
        #expect(detail.test_groupsSectionTitleFrame.maxY <= detail.test_eqSectionFrame.minY + 0.5)

        detail.show(device: makeDevice(id: "local", name: "This Mac", kind: .localMac))
        detail.view.layoutSubtreeIfNeeded()
        #expect(detail.test_activeGroupsTitlePinCount == 1)
        #expect(detail.test_groupsSectionTitleFrame.maxY
                <= detail.test_headerSectionFrame.minY + 0.5)

        detail.show(device: makeDevice())
        detail.view.layoutSubtreeIfNeeded()
        #expect(detail.test_activeGroupsTitlePinCount == 1)
        #expect(detail.test_groupsSectionTitleFrame.maxY <= detail.test_eqSectionFrame.minY + 0.5,
                "Mac → speaker puts the Equalizer card back above the Groups title")
    }

    // MARK: The in-flight scrub cache

    @Test func aScrubSurvivesASnapshotAndTheCommitHandsTheTruthBack() {
        let detail = makeLoadedPane(device: makeDevice(id: "office"))

        // Mid-drag: a snapshot carrying the OLD value must not rewind the slider.
        detail.test_eqEditor.test_committedGestureOverride = false
        detail.test_eqEditor.test_dragBass(to: 5)
        detail.refresh(device: makeDevice(id: "office"))
        #expect(detail.test_eqEditor.currentEQ.bassDB == 5,
                "a snapshot arriving mid-gesture can't yank the slider out from under the pointer")

        // Committed: the entry is now AWAITING ITS OWN ECHO. A STALE snapshot
        // already queued from before the commit — even flat — must not replay
        // the drag backward; only a snapshot matching the committed value
        // releases the cache.
        detail.test_eqEditor.test_committedGestureOverride = true
        detail.test_eqEditor.test_dragBass(to: 5)
        var flat = makeDevice(id: "office")
        flat.eq = .flat
        detail.refresh(device: flat)
        #expect(detail.test_eqEditor.currentEQ.bassDB == 5,
                "a stale snapshot queued before the commit must not replay the drag on the knob")

        // The committed value's OWN echo arrives: it renders (unsurprising —
        // it already matched) AND releases the cache in the same beat.
        var echoed = makeDevice(id: "office")
        echoed.eq = DeviceEQ(bassDB: 5)
        detail.refresh(device: echoed)
        #expect(detail.test_eqEditor.currentEQ.bassDB == 5)

        // Proof the cache is actually gone: a LATER flat snapshot now renders
        // flat, where a still-cached entry would have kept showing 5 forever.
        detail.refresh(device: flat)
        #expect(detail.test_eqEditor.currentEQ.bassDB == 0,
                Comment(rawValue: "kept past the echo the cache lies forever — the pane would show a shaped " +
                "curve for the rest of the session while the audio stayed flat"))
    }

    @Test func resetAlsoHandsTheTruthBackToTheSnapshot() {
        let detail = makeLoadedPane(device: makeDevice(id: "office"))
        detail.test_eqEditor.test_committedGestureOverride = true
        detail.test_eqEditor.test_dragBass(to: 5)
        detail.test_fireResetClick()

        // Reset's own committed value is flat — a matching flat echo is what
        // releases the cache, same rule as any other committed gesture.
        var flat = makeDevice(id: "office")
        flat.eq = .flat
        detail.refresh(device: flat)
        #expect(detail.test_eqEditor.currentEQ.bassDB == 0)

        var shaped = makeDevice(id: "office")
        shaped.eq = DeviceEQ(bassDB: 3)
        detail.refresh(device: shaped)
        #expect(detail.test_eqEditor.currentEQ.bassDB == 3,
                "Reset released its cache on the matching echo — a later snapshot is free to render again")
    }

    // MARK: The facts are copyable (P3-3)

    /// The page exists to state facts about a speaker; a fact you cannot copy
    /// is a fact you have to retype. The name and all three About values are
    /// selectable — still labels, never editable.
    @Test func theDeviceNameAndAboutValuesAreSelectable() throws {
        let detail = makeLoadedPane(device: makeDevice(id: "office", name: "Office"))
        let fields = detail.view.descendantTextFields()

        for text in ["Office", "Ready", "AirPlay Speaker", "AirPlay 2"] {
            let matches = fields.filter { $0.stringValue == text }
            #expect(!matches.isEmpty, "expected a field carrying \"\(text)\"")
            for field in matches {
                #expect(field.isSelectable, "\"\(text)\" must be selectable")
                #expect(!field.isEditable, "…and still a label, not an editable field")
            }
        }
    }

    @Test func detailPaneScrolls() {
        let detail = makeLoadedPane(device: makeDevice())
        #expect(detail.test_hasScrollView,
                "the Equalizer's Advanced fold exceeds the screen's budget, and the window can't grow (roadmap 039)")
    }

    // MARK: Hover scrim headless test hook

    @Test func setOverlayVisibleDoesNotCrashHeadless() {
        let detail = DeviceDetailViewController(groupController: makeController(),
                                            settings: AppSettings(defaults: isolation.isolatedDefaults))
        detail.show(device: makeDevice())
        detail.test_setOverlayVisible(true)
        detail.test_setOverlayVisible(false)
        // No assertion beyond "didn't crash" — the scrim's layer state isn't
        // exposed, and this is exercised visually by the live snapshot tool.
    }
}

private extension NSView {
    /// Every `NSTextField` in this view's subtree, for asserting on labels
    /// the pane builds internally and exposes no seam for.
    func descendantTextFields() -> [NSTextField] {
        var result: [NSTextField] = []
        if let field = self as? NSTextField { result.append(field) }
        for sub in subviews { result.append(contentsOf: sub.descendantTextFields()) }
        return result
    }
}
