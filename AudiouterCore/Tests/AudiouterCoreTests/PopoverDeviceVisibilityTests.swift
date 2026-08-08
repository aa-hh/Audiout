// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import AppKit
@testable import AudiouterCore
@testable import AudiouterPopoverUI
@testable import AudiouterSharedUI

/// Device-list visibility in the popover: the per-device-TYPE subsection
/// collapse, and the per-DEVICE hide/show pair. Both are DISPLAY actions —
/// what is asserted throughout is that neither ever moves selection,
/// membership or a diagnosis-panel intent, and that the surfaces which depend
/// on "what is actually on screen" (the sync drawer, the rail terminus, the
/// empty-state copy) follow. Every interaction rides a real path: the panel's
/// own header gesture recognizer, `NSMenu.performActionForItem(at:)`, and
/// `DeviceRowView.menu(for:)`.
@MainActor
@Suite(.serialized) struct PopoverDeviceVisibilityTests {

    private func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func makePopover(fleet: [Device] = []) -> (PopoverController, GroupController) {
        let backend = MockBackend(fleet: fleet, staggerDiscovery: false,
                                  emitsLevels: false, simulatesDropouts: false)
        let controller = GroupController(backend: backend,
                                         store: GroupStore(directory: tempDirectory()),
                                         routingStore: RoutingStore(directory: tempDirectory()),
                                         loadPersisted: false)
        let popover = PopoverController()
        popover.configure(groupController: controller)
        popover.test_isShownOverride = true
        if !fleet.isEmpty {
            backend.start()
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline && backend.devices.count < fleet.count {
                RunLoop.current.run(until: Date().addingTimeInterval(0.005))
            }
        }
        return (popover, controller)
    }

    private func local() -> Device {
        Device(id: "mac", name: "This Mac", kind: .localMac, isLocalDevice: true)
    }

    private func airplay(_ id: String = "office", name: String = "Office") -> Device {
        Device(id: id, name: name, kind: .homePod)
    }

    private func bt(_ id: String, name: String, available: Bool = true) -> Device {
        Device(id: id, name: name, kind: .bluetooth,
               isAvailable: available, supportsAirPlay2: false)
    }

    private let airPlayTitle = PopoverController.airPlaySubsectionTitle
    private let bluetoothTitle = PopoverController.bluetoothSubsectionTitle

    // MARK: Feature A — collapsible device-type subsections

    @Test func subsectionHeaderClickCollapsesOnlyItsOwnRowsAndFlipsTheChevron() {
        let (popover, _) = makePopover()
        popover.update(devices: [local(), airplay(), bt("bt-a:output", name: "Speaker A")])
        #expect(popover.test_cardChevronSymbolName(title: airPlayTitle) == "chevron.down")

        popover.test_fireSubsectionHeaderClick(title: airPlayTitle)

        #expect(popover.test_isSubsectionCollapsed(title: airPlayTitle))
        #expect(popover.test_renderedDeviceIDs() == ["mac", "bt-a:output"])
        #expect(popover.test_deviceRow(for: "office") == nil)
        #expect(popover.test_cardChevronSymbolName(title: airPlayTitle) == "chevron.right")
        #expect(popover.test_subsectionTitles()
                == ["This Mac", airPlayTitle, bluetoothTitle],
                "a collapsed subsection keeps its header — only the rows go")

        popover.test_fireSubsectionHeaderClick(title: airPlayTitle)
        #expect(popover.test_deviceRow(for: "office") != nil)
    }

    /// Same two rebuild flavors the cards obey: a manual toggle is transient
    /// within one open and `rebuildForOpen()` resets it to the expanded default.
    @Test func subsectionCollapseSurvivesRebuildButResetsOnOpen() {
        let (popover, _) = makePopover()
        popover.update(devices: [local(), airplay()])
        popover.test_fireSubsectionHeaderClick(title: airPlayTitle)

        popover.rebuild()
        #expect(popover.test_isSubsectionCollapsed(title: airPlayTitle),
                "a mid-open repaint preserves the user's toggle")

        popover.test_simulateOpen()
        #expect(!popover.test_isSubsectionCollapsed(title: airPlayTitle),
                "every open recomputes the default (expanded)")
        #expect(popover.test_deviceRow(for: "office") != nil)
    }

    /// A drawer under a row that is no longer rendered must not survive, and
    /// the align-by-ear tick must stop with it.
    @Test func collapsingTheBluetoothSubsectionClosesAnOpenSyncDrawer() {
        let (popover, _) = makePopover()
        popover.update(devices: [local(), bt("bt-a:output", name: "Speaker A")])
        popover.test_toggleSyncDrawer(deviceID: "bt-a:output")
        popover.test_syncDrawer?.test_fireAlignClick()
        #expect(popover.test_expandedSyncDeviceID == "bt-a:output")
        #expect(popover.test_alignTickDeviceID() == "bt-a:output")

        popover.test_fireSubsectionHeaderClick(title: bluetoothTitle)

        #expect(popover.test_expandedSyncDeviceID == nil)
        #expect(!popover.test_syncDrawerVisible)
        #expect(popover.test_alignTickDeviceID() == nil,
                "no metronome without a visible control to stop it")
    }

    /// Collapse is DISPLAY, not membership: the diagnosis panel simply isn't
    /// rendered while collapsed, and comes back on expand because its open
    /// intent was never touched.
    @Test func collapseHidesADiagnosisPanelWithoutClearingItsIntent() {
        let (popover, controller) = makePopover(fleet: [local(), airplay()])
        controller.setDeviceSelected("office", true)
        let failure = ConnectionFailure(cause: .unknown, detail: nil)
        var failed = airplay()
        failed.connectionState = .failed(failure)
        popover.update(devices: [local(), failed])
        #expect(popover.test_diagnosisPanel(for: "office") != nil)

        popover.test_fireSubsectionHeaderClick(title: airPlayTitle)
        #expect(popover.test_diagnosisPanel(for: "office") == nil, "not rendered while collapsed")
        #expect(controller.selectedDeviceIDs.contains("office"), "membership is untouched")

        popover.test_fireSubsectionHeaderClick(title: airPlayTitle)
        #expect(popover.test_diagnosisPanel(for: "office") != nil,
                "the episode is still open, so the panel returns")
    }

    // MARK: Feature B — per-device visibility

    /// The whole hide path through real AppKit dispatch: the row's own
    /// `menu(for:)` override, then `performActionForItem`.
    @Test func rowContextMenuHidesTheDeviceWithoutTouchingSelection() {
        let (popover, controller) = makePopover(fleet: [local(), bt("bt-a:output", name: "Speaker A")])
        popover.update(devices: [local(), bt("bt-a:output", name: "Speaker A")])

        let menu = popover.test_deviceRow(for: "bt-a:output")?.test_contextMenu()
        #expect(menu?.items.map(\.title) == ["Hide 'Speaker A'"])
        menu?.performActionForItem(at: 0)

        #expect(popover.test_deviceRow(for: "bt-a:output") == nil, "the row is gone")
        #expect(popover.test_renderedDeviceIDs() == ["mac"])
        #expect(controller.selectedDeviceIDs.contains("bt-a:output") == false)
        #expect(popover.test_hiddenDeviceNames() == ["bt-a:output": "Speaker A"])
    }

    // MARK: Only Bluetooth is curatable, and never what is playing

    /// AirPlay rows are live discoveries and the point of the app — a hidden
    /// one reads as a bug, so they offer no menu at all. Neither does the Mac.
    @Test func onlyBluetoothRowsOfferAHideMenu() {
        let (popover, _) = makePopover()
        popover.update(devices: [local(), airplay(), bt("bt-a:output", name: "Speaker A")])

        #expect(popover.test_deviceRow(for: "office")?.test_contextMenu() == nil,
                "an AirPlay row is never hideable")
        #expect(popover.test_deviceRow(for: "mac")?.test_contextMenu() == nil,
                "nor the single This Mac row")
        #expect(popover.test_deviceRow(for: "bt-a:output")?.test_contextMenu() != nil)
    }

    /// Hiding the row for something still making noise would take away its
    /// only volume and mute control.
    @Test func aDeviceInTheMixCannotBeHidden() {
        let (popover, controller) = makePopover(fleet: [local(), bt("bt-a:output", name: "Speaker A")])
        controller.setDeviceSelected("bt-a:output", true)
        popover.update(devices: [local(), bt("bt-a:output", name: "Speaker A")])

        let item = popover.test_deviceRow(for: "bt-a:output")?.test_contextMenu()?.items.first
        #expect(item?.title == "Hide 'Speaker A'", "the action stays discoverable on its own row")
        #expect(item?.isEnabled == false, "…but not while the device is in the mix")
    }

    /// The invariant, not just the menu gate: a stored hide takes effect only
    /// while the device is OUT of the mix, so a device that becomes live again
    /// — here by being selected, in the app by an app route pointed straight at
    /// it — gets its row back, and hides itself again when it leaves.
    @Test func aHiddenDeviceThatRejoinsTheMixGetsItsRowBack() {
        let (popover, controller) = makePopover(fleet: [local(), bt("bt-a:output", name: "Speaker A")])
        popover.update(devices: [local(), bt("bt-a:output", name: "Speaker A")])
        popover.test_deviceRow(for: "bt-a:output")?.test_contextMenu()?.performActionForItem(at: 0)
        #expect(popover.test_deviceRow(for: "bt-a:output") == nil)

        controller.setDeviceSelected("bt-a:output", true)
        popover.update(devices: [local(), bt("bt-a:output", name: "Speaker A")])
        #expect(popover.test_deviceRow(for: "bt-a:output") != nil,
                "a playing device always has a row")
        #expect(popover.test_hiddenDeviceNames().keys.contains("bt-a:output"),
                "the hide INTENT survives — it is suspended, not forgotten")
        #expect(popover.test_outputDevicesPlusMenu().items.map(\.title)
                    .contains("Show 'Speaker A'") == false,
                "and it is not offered for restore while it is on screen")

        controller.setDeviceSelected("bt-a:output", false)
        popover.update(devices: [local(), bt("bt-a:output", name: "Speaker A")])
        #expect(popover.test_deviceRow(for: "bt-a:output") == nil, "and it hides itself again")
    }

    @Test func plusMenuListsHiddenDevicesAndShowingOneRestoresItsRow() {
        let (popover, _) = makePopover()
        popover.update(devices: [local(), bt("bt-a:output", name: "Speaker A"),
                                 bt("bt-z:output", name: "Zed Box")])
        #expect(popover.test_outputDevicesPlusMenu().items.map(\.title)
                == ["Save Selected Devices as group", "Pair a Bluetooth speaker…"],
                "no Hidden Devices section until something is hidden")

        popover.test_deviceRow(for: "bt-a:output")?.test_contextMenu()?.performActionForItem(at: 0)
        popover.test_deviceRow(for: "bt-z:output")?.test_contextMenu()?.performActionForItem(at: 0)

        var menu = popover.test_outputDevicesPlusMenu()
        #expect(menu.items.map(\.title) == ["Save Selected Devices as group",
                                            "Pair a Bluetooth speaker…",
                                            "", "Hidden Devices",
                                            "Show 'Speaker A'", "Show 'Zed Box'"],
                "sorted by the stored name, under a disabled section header")
        #expect(menu.items[3].isEnabled == false)

        menu.performActionForItem(at: 4)
        #expect(popover.test_deviceRow(for: "bt-a:output") != nil)
        menu = popover.test_outputDevicesPlusMenu()
        #expect(menu.items.map(\.title).contains("Show 'Speaker A'") == false)
    }

    /// A hidden device the backend can no longer see is still listed, still
    /// named — that is what the stored name is for.
    @Test func anUndiscoveredHiddenDeviceIsStillListedAndStillNamed() {
        let (popover, _) = makePopover()
        popover.update(devices: [local(), bt("bt-a:output", name: "Speaker A")])
        popover.test_deviceRow(for: "bt-a:output")?.test_contextMenu()?.performActionForItem(at: 0)

        popover.update(devices: [local()])
        let menu = popover.test_outputDevicesPlusMenu()
        #expect(menu.items.map(\.title).contains("Show 'Speaker A'"))
    }

    @Test func theHiddenSetRoundTripsThroughItsStore() {
        let store = HiddenDeviceStore(directory: tempDirectory())
        let fleet = [local(), bt("bt-a:output", name: "Speaker A")]
        let (first, _) = makePopover()
        first.hiddenDeviceStore = store
        first.update(devices: fleet)
        first.test_deviceRow(for: "bt-a:output")?.test_contextMenu()?.performActionForItem(at: 0)

        // A second launch over the same store.
        let (second, _) = makePopover()
        second.hiddenDeviceStore = store
        second.update(devices: fleet)
        #expect(second.test_hiddenDeviceNames() == ["bt-a:output": "Speaker A"])
        #expect(second.test_deviceRow(for: "bt-a:output") == nil)

        second.test_outputDevicesPlusMenu().performActionForItem(at: 4)
        let (third, _) = makePopover()
        third.hiddenDeviceStore = store
        #expect(third.test_hiddenDeviceNames().isEmpty, "showing it again persists too")
    }

    @Test func hidingTheDeviceWhoseDrawerIsOpenClosesTheDrawer() {
        let (popover, _) = makePopover()
        popover.update(devices: [local(), bt("bt-a:output", name: "Speaker A")])
        popover.test_toggleSyncDrawer(deviceID: "bt-a:output")
        #expect(popover.test_expandedSyncDeviceID == "bt-a:output")

        popover.test_deviceRow(for: "bt-a:output")?.test_contextMenu()?.performActionForItem(at: 0)
        #expect(popover.test_expandedSyncDeviceID == nil)
        #expect(!popover.test_syncDrawerVisible)
    }

    @Test func aSubsectionWhoseDevicesAreAllHiddenDisappearsEntirely() {
        let (popover, _) = makePopover()
        popover.update(devices: [local(), airplay(), bt("bt-a:output", name: "Speaker A")])
        popover.test_deviceRow(for: "bt-a:output")?.test_contextMenu()?.performActionForItem(at: 0)
        #expect(popover.test_subsectionTitles() == ["This Mac", airPlayTitle],
                "an all-hidden subsection reads exactly like an empty one")
    }

    /// "Looking for devices…" would be a lie once the devices exist and are
    /// merely hidden.
    @Test func theEmptyStateDistinguishesNoDevicesFromAllHidden() {
        let (popover, _) = makePopover()
        popover.update(devices: [])
        #expect(popover.test_devicesPlaceholderText() == "Looking for devices…")

        popover.update(devices: [bt("bt-a:output", name: "Speaker A")])
        #expect(popover.test_devicesPlaceholderText() == nil)

        popover.test_deviceRow(for: "bt-a:output")?.test_contextMenu()?.performActionForItem(at: 0)
        #expect(popover.test_devicesPlaceholderText() == "All devices hidden")
    }

    // MARK: The rail follows what is on screen

    /// The spine's terminus is the lowest selected VISIBLE node. Collapse is
    /// the case that can strand it — a hidden device is by definition out of
    /// the mix, but a COLLAPSED subsection takes selected rows off screen —
    /// and it must pull the terminus up rather than leave the row above it
    /// carrying a through-rail to nothing.
    @Test func theRailTerminatesAtTheLowestVISIBLESelectedNode() {
        let fleet = [local(), airplay(), bt("bt-z:output", name: "Zed Box")]
        let (popover, controller) = makePopover(fleet: fleet)
        controller.setDeviceSelected("office", true)
        controller.setDeviceSelected("bt-z:output", true)
        popover.update(devices: fleet)
        #expect(popover.test_deviceRow(for: "office")?.test_busRailBelow == true,
                "the rail runs on past Office to the Bluetooth box below it")

        popover.test_fireSubsectionHeaderClick(title: bluetoothTitle)
        #expect(popover.test_deviceRow(for: "office")?.test_busRailBelow == false,
                "with the Bluetooth rows collapsed away the rail ends at Office")
        #expect(controller.selectedDeviceIDs.contains("bt-z:output"),
                "collapse is display only — Zed Box is still in the mix")
    }
}
