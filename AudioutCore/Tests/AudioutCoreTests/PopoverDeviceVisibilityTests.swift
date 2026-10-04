// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import AppKit
@testable import AudioutCore
@testable import AudioutPopoverUI
@testable import AudioutSharedUI

/// Device-list visibility in the popover: the per-device-TYPE subsection
/// collapse, and the Bluetooth connected-only listing (BT-LIST). Both are
/// DISPLAY actions — what is asserted throughout is that neither ever moves
/// selection, membership or a diagnosis-panel intent, and that the surfaces
/// which depend on "what is actually on screen" (the sync drawer, the rail
/// terminus, the empty-state copy) follow. Every interaction rides a real
/// path: the panel's own header gesture recognizer, `NSMenu
/// .performActionForItem(at:)`, and `DeviceRowView.menu(for:)`.
@MainActor
@Suite(.serialized) struct PopoverDeviceVisibilityTests {

    private let isolation = TestIsolation(owner: "PopoverDeviceVisibilityTests")

    private func tempDirectory() -> URL {
        isolation.scratchDir
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func makePopover(fleet: [Device] = []) -> (PopoverController, GroupController) {
        let backend = MockBackend(fleet: fleet, staggerDiscovery: false,
                                  emitsLevels: false, simulatesDropouts: false)
        let controller = GroupController(backend: backend,
                                         store: GroupStore(directory: tempDirectory()),
                                         routingStore: RoutingStore(directory: tempDirectory()),
                                         settings: AppSettings(defaults: isolation.makeDefaults()),
                                         loadPersisted: false)
        let popover = PopoverController(appRouting: AppRoutingController(
            store: AppRouteStore(directory: tempDirectory()), loadPersisted: false))
        popover.configure(groupController: controller)
        popover.test_isShownOverride = true
        if !fleet.isEmpty {
            backend.start()
            SuiteWait.untilOnRunLoop("the fleet has \(fleet.count) devices") {
                backend.devices.count >= fleet.count
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

    private func bt(_ id: String, name: String, available: Bool = true,
                    state: ConnectionState = .off) -> Device {
        Device(id: id, name: name, kind: .bluetooth,
               isAvailable: available, supportsAirPlay2: false, connectionState: state)
    }

    private func cast(_ id: String, name: String) -> Device {
        Device(id: id, name: name, kind: .cast, supportsAirPlay2: false)
    }

    private let airPlayTitle = PopoverController.airPlaySubsectionTitle
    private let bluetoothTitle = PopoverController.bluetoothSubsectionTitle
    private let castTitle = PopoverController.castSubsectionTitle

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
                == [airPlayTitle, bluetoothTitle],
                "a collapsed subsection keeps its header — only the rows go; the Mac row is pinned above the subsections, not one of them")

        popover.test_fireSubsectionHeaderClick(title: airPlayTitle)
        #expect(popover.test_deviceRow(for: "office") != nil)
    }

    /// The collapse's SIZE contract — the number the surface is told to travel
    /// to. The subsection's rows fold into their own clip, so the panel must
    /// publish exactly their height less, and the expand must put every point
    /// of it back. Headless takes the synchronous path (an `NSAnimationContext`
    /// completion handler never fires for a view in no window), so this pins the
    /// end states, not the interpolation — whether the two read as one motion is
    /// a live judgement.
    @Test func collapsingASubsectionPublishesExactlyItsRowsHeightLess() {
        let (popover, _) = makePopover()
        popover.update(devices: [local(), airplay("office", name: "Office"),
                                 airplay("kitchen", name: "Kitchen")])
        _ = popover.test_panelFittingSize   // settle Auto Layout before reading frames
        let rowsHeight = ["office", "kitchen"]
            .compactMap { popover.test_deviceRow(for: $0)?.frame.height }
            .reduce(0, +)
        #expect(rowsHeight > 0)
        let expanded = popover.test_preferredContentSize.height

        popover.test_fireSubsectionHeaderClick(title: airPlayTitle)

        #expect(popover.test_deviceRow(for: "office") == nil)
        #expect(popover.test_deviceRow(for: "kitchen") == nil)
        #expect(popover.test_preferredContentSize.height == expanded - rowsHeight,
                "the published height loses exactly the collapsed rows — no residue, no over-shrink")

        popover.test_fireSubsectionHeaderClick(title: airPlayTitle)

        #expect(popover.test_deviceRow(for: "office") != nil)
        #expect(popover.test_deviceRow(for: "kitchen") != nil)
        #expect(popover.test_preferredContentSize.height == expanded,
                "and the expand puts every point of it back")
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

    // MARK: Cast Devices — the third device-type subsection

    /// Cast receivers are their own band, between AirPlay and Bluetooth: they
    /// are non-local and non-Bluetooth, so without a section of their own they
    /// would silently land among the AirPlay rows.
    @Test func castDevicesRenderInTheirOwnSectionBetweenAirPlayAndBluetooth() {
        let (popover, _) = makePopover()
        popover.update(devices: [local(), airplay(), cast("c1", name: "Living Room TV"),
                                 bt("bt-a:output", name: "Speaker A")])

        #expect(popover.test_subsectionTitles()
                == [airPlayTitle, castTitle, bluetoothTitle])
        #expect(popover.test_renderedDeviceIDs() == ["mac", "office", "c1", "bt-a:output"])
    }

    /// Cast follows the hidden-when-empty rule the other non-Bluetooth
    /// subsections obey — no empty grouping label for a feature the user may
    /// own no hardware for.
    @Test func noCastDevicesMeansNoCastHeader() {
        let (popover, _) = makePopover()
        popover.update(devices: [local(), airplay(), bt("bt-a:output", name: "Speaker A")])

        #expect(popover.test_subsectionTitles() == [airPlayTitle, bluetoothTitle])
    }

    @Test func castSectionCollapsesLikeAirPlay() {
        let (popover, _) = makePopover()
        popover.update(devices: [local(), airplay(), cast("c1", name: "Living Room TV"),
                                 bt("bt-a:output", name: "Speaker A")])
        #expect(popover.test_cardChevronSymbolName(title: castTitle) == "chevron.down")

        popover.test_fireSubsectionHeaderClick(title: castTitle)

        #expect(popover.test_isSubsectionCollapsed(title: castTitle))
        #expect(popover.test_renderedDeviceIDs() == ["mac", "office", "bt-a:output"])
        #expect(popover.test_cardChevronSymbolName(title: castTitle) == "chevron.right")
        #expect(popover.test_subsectionTitles()
                == [airPlayTitle, castTitle, bluetoothTitle],
                "a collapsed subsection keeps its header — only the rows go")

        popover.test_fireSubsectionHeaderClick(title: castTitle)
        #expect(popover.test_deviceRow(for: "c1") != nil)
    }

    // MARK: Visibility and pairing

    // Showing paired history in Mixer by default would bring unused offline rows back.
    @Test func pairedButDisconnectedBluetoothDevicesAreNotListed() {
        let (popover, _) = makePopover()
        popover.update(devices: [local(), bt("live", name: "Live"),
                                 bt("offline", name: "Offline", available: false)])
        #expect(popover.test_renderedDeviceIDs() == ["mac", "live"])
        #expect(popover.test_speakerLibrary.records.map(\.id).contains("offline"))
        #expect(popover.test_speakerLibrary.record(for: "offline")?.visibility == .whenAvailable)
    }

    // Putting Pair inside the Bluetooth body would hide the action on collapse.
    @Test func pairFooterDispatchesWithBluetoothCollapsedAndWithoutBluetoothRows() throws {
        let (popover, controller) = makePopover()
        popover.update(devices: [local(), airplay()])
        #expect(popover.test_subsectionTitles() == [airPlayTitle])
        let button = try #require(popover.test_pairBluetoothButton)
        #expect(button.title == "Pair Bluetooth speaker…")
        #expect(button.accessibilityLabel() == button.title)
        #expect(button.image?.isTemplate == true)
        #expect(popover.test_pairBluetoothIsLastCardRow)
        let selection = controller.selectedDeviceIDs
        var taps = 0
        popover.onPairBluetoothSpeaker = { taps += 1 }
        popover.test_tapPairBluetooth()
        popover.update(devices: [local(), airplay(), bt("bt", name: "Bluetooth")])
        popover.test_fireSubsectionHeaderClick(title: bluetoothTitle)
        #expect(popover.test_deviceRow(for: "bt") == nil)
        #expect(popover.test_pairBluetoothIsLastCardRow)
        popover.test_tapPairBluetooth()
        #expect(taps == 2)
        #expect(controller.selectedDeviceIDs == selection)
    }

    // A missing permission explanation would make denied Bluetooth history look empty.
    @Test func bluetoothPermissionExplanationKeepsTheHeaderAndDispatchesAccessAction() throws {
        let (popover, _) = makePopover()
        popover.bluetoothPermissionProvider = { .denied }
        popover.update(devices: [local(), airplay()])
        #expect(popover.test_subsectionTitles() == [airPlayTitle, bluetoothTitle])
        func buttons(_ view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
        }
        let action = try #require(buttons(popover.test_panelView).first { $0.title == "Open Bluetooth privacy…" })
        var accesses = 0
        popover.onBluetoothAccess = { accesses += 1 }
        action.performClick(nil)
        #expect(accesses == 1)
        #expect(popover.test_pairBluetoothIsLastCardRow)
    }

    // A membership-only visibility check would lose disconnected Main Audio intent.
    @Test func anInMixDisconnectedBluetoothDeviceKeepsItsGreyedRow() {
        let device = bt("bt", name: "Speaker", available: false)
        let (popover, controller) = makePopover(fleet: [local(), device])
        _ = controller.setDeviceSelected(device.id, true)
        popover.update(devices: [local(), device])
        #expect(popover.test_deviceRow(for: device.id) != nil)
        #expect(controller.selectedDeviceIDs.contains(device.id))
    }

    // Removing Pair from an empty fleet would leave no Bluetooth pairing action.
    @Test func theEmptyFleetPairsTheSearchLineWithTheBluetoothAffordance() {
        let (popover, _) = makePopover()
        popover.update(devices: [])
        #expect(popover.test_subsectionTitles() == [airPlayTitle])
        #expect(popover.test_speakerSearchStateText == "Looking for speakers…")
        #expect(popover.test_pairBluetoothButton != nil)
    }

    // MARK: The rail runs to the lowest selected device, hidden or not

    /// The spine runs to the LOWEST SELECTED device, and a collapsed
    /// subsection hiding that device does NOT shorten it: the rail keeps
    /// running past the rows above and ends on a dot on that subsection's
    /// header — exactly what collapsing the whole CARD already does.
    ///
    /// Ending it on the highest still-visible selected row instead, with no
    /// dot, is the bug this pins: the rail's length reads as "how far down the
    /// mix reaches", so stopping it early says the mix stopped early, and the
    /// row it stops on renders as a terminus it isn't.
    @Test func aCollapsedSubsectionCutsTheRailAtItsHeaderDot() throws {
        let fleet = [local(), airplay(), bt("bt-z:output", name: "Zed Box")]
        let (popover, controller) = makePopover(fleet: fleet)
        controller.setDeviceSelected("office", true)
        controller.setDeviceSelected("bt-z:output", true)
        popover.update(devices: fleet)
        popover.test_applyExactFitSize()
        let expanded = try #require(popover.test_railPlan())
        #expect(expanded.signalTerminusIndex == expanded.stops.count - 1,
                "the signal runs on past Office to the Bluetooth box below it")
        #expect(expanded.terminusDotY == nil,
                "expanded: the rail ends on Zed Box's own node, uncut")

        popover.test_fireSubsectionHeaderClick(title: bluetoothTitle)
        popover.test_applyExactFitSize()

        #expect(try #require(popover.test_railPlan()).terminusDotY != nil,
                "…so the rail is cut at the collapsed subsection's header, with a dot")
        #expect(controller.selectedDeviceIDs.contains("bt-z:output"),
                "collapse is display only — Zed Box is still in the mix")
    }

    /// S5 through the real host: with BOTH subsections collapsed over a
    /// speaker in the mix, each header gets its own dot and the rail ends on
    /// the lower one. The old host named only the lowest fold, so the AirPlay
    /// header looked the same as one hiding nothing.
    @Test func everyCollapsedSubsectionHidingAMemberGetsItsOwnDot() throws {
        let fleet = [airplay(), bt("bt-z:output", name: "Zed Box")]
        let (popover, controller) = makePopover(fleet: fleet)
        controller.setDeviceSelected("office", true)
        controller.setDeviceSelected("bt-z:output", true)
        popover.update(devices: fleet)
        popover.test_fireSubsectionHeaderClick(title: airPlayTitle)
        popover.test_fireSubsectionHeaderClick(title: bluetoothTitle)
        popover.test_applyExactFitSize()

        let plan = try #require(popover.test_railPlan())
        #expect(plan.headerDotYs.count == 2, "one dot on each collapsed header hiding a member")
        #expect(plan.terminusDotY == plan.headerDotYs.min(), "the rail ends on the lower dot")
    }

    /// The case that erased the rail outright: EVERY device inside the subsection
    /// being collapsed. No visible node is left for the channel to reach, so the
    /// rail is nothing BUT the cut — a dot at that subsection's header, never a
    /// hook curling off Main Audio into mid-air. (Fleet is a lone Bluetooth
    /// speaker: the Mac row is pinned outside every subsection since 2026-08-28,
    /// so a Mac in the fleet can never be hidden by a subsection collapse.)
    @Test func collapsingTheSubsectionHoldingEveryDeviceStillEndsInADot() throws {
        let fleet = [bt("bt-z:output", name: "Zed Box")]
        let (popover, controller) = makePopover(fleet: fleet)
        controller.setDeviceSelected("bt-z:output", true)   // …and nothing else
        popover.update(devices: fleet)
        popover.test_applyExactFitSize()
        #expect(!(try #require(popover.test_railPlan()).stops.isEmpty),
                "expanded: the speaker's node is on the rail")

        popover.test_fireSubsectionHeaderClick(title: bluetoothTitle)
        popover.test_applyExactFitSize()

        let plan = try #require(popover.test_railPlan())
        #expect(plan.stops.isEmpty, "no visible node is left to draw")
        #expect(plan.terminusDotY != nil,
                "the rail ends in a dot at the collapsed header, not in mid-air")
    }

    /// The cut follows the lowest device the rail REACHES, not the last device
    /// in the list. A collapsed AirPlay subsection hiding the only playing
    /// speaker, with an idle Cast speaker below it, used to leave no cut (the
    /// Cast device was the list's last) and no reached visible row — so the rail
    /// and the Main Audio ring's rail vanished while a speaker played.
    @Test func aCollapsedMidListSubsectionHidingTheLowestMemberCutsTheRail() throws {
        let fleet = [airplay(), cast("cast-k", name: "Kitchen")]
        let (popover, controller) = makePopover(fleet: fleet)
        controller.setDeviceSelected("office", true)
        popover.update(devices: fleet)
        popover.test_applyExactFitSize()

        popover.test_fireSubsectionHeaderClick(title: airPlayTitle)
        popover.test_applyExactFitSize()

        let plan = try #require(popover.test_railPlan())
        #expect(plan.terminusDotY != nil,
                "the rail is cut at the collapsed AirPlay header, with a dot")
        #expect(plan.isLive, "Office is still playing, so the rail stays")
    }

    /// A collapsed LAST subsection whose hidden speakers are all out of the mix
    /// hides no signal, so it must not cut: the rail keeps ending on the lowest
    /// visible member, and with no member anywhere there is no rail at all.
    @Test func aCollapsedSubsectionHidingOnlyIdleSpeakersDoesNotCut() throws {
        let fleet = [airplay(), bt("bt-z:output", name: "Zed Box")]
        let (popover, controller) = makePopover(fleet: fleet)
        controller.setDeviceSelected("office", true)
        popover.update(devices: fleet)
        popover.test_applyExactFitSize()

        popover.test_fireSubsectionHeaderClick(title: bluetoothTitle)
        popover.test_applyExactFitSize()
        #expect(try #require(popover.test_railPlan()).terminusDotY == nil,
                "the rail ends on Office's own node, uncut")

        controller.setDeviceSelected("office", false)
        popover.update(devices: fleet)
        popover.test_applyExactFitSize()
        #expect(!(try #require(popover.test_railPlan()).isLive),
                "nothing in the mix: no rail, even with Bluetooth collapsed")
    }

    /// The invariant behind both cases above, stated once. With the origin
    /// resolved and devices in the mix, a rail plan may never be BOTH stop-less
    /// and dot-less — that pair IS the dangling hook, a rail that starts at
    /// Main Audio and ends nowhere. Swept over every collapsible subsection,
    /// collapsing them one after another until both are shut (the pinned Mac
    /// row has no subsection to collapse — its node can only fold with the
    /// whole card).
    @Test func aRailWithDevicesInTheMixIsNeverBothStopLessAndDotLess() throws {
        let fleet = [local(), airplay(), bt("bt-z:output", name: "Zed Box")]
        let (popover, controller) = makePopover(fleet: fleet)
        controller.setDeviceSelected("office", true)
        controller.setDeviceSelected("mac", true)
        controller.setDeviceSelected("bt-z:output", true)
        popover.update(devices: fleet)

        for title in [airPlayTitle, bluetoothTitle] {
            popover.test_fireSubsectionHeaderClick(title: title)
            popover.test_applyExactFitSize()
            let plan = try #require(popover.test_railPlan())
            #expect(!(plan.stops.isEmpty && plan.terminusDotY == nil),
                    "collapsing \(title) left the rail with no stops AND no terminus")
        }
    }

    // MARK: The Mac row is pinned under the card header (2026-08-28)

    /// The Mac row has no subsection of its own any more: it renders directly
    /// under the "Output Devices" header, inside the card's COLLAPSIBLE body —
    /// so collapsing the card folds it with everything else. Pinning it in the
    /// header region instead (like the card note, which survives collapse)
    /// would leave a device row standing on a card that claims to be shut.
    @Test func thePinnedMacRowFoldsWithTheOutputDevicesCard() throws {
        let (popover, _) = makePopover()
        popover.update(devices: [local(), airplay()])
        popover.test_applyExactFitSize()
        let macRow = try #require(popover.test_deviceRow(for: "mac"))
        #expect(popover.test_subsectionTitles() == [airPlayTitle],
                "the Mac row has no grouping header")
        #expect(macRow.frame.height > 0)

        popover.test_toggleCard(title: PopoverController.outputDevicesCardTitle)
        popover.test_applyExactFitSize()

        // The row folded away inside the card's collapsed body clip — some
        // ancestor between it and the panel is now laid out at height 0.
        var ancestor = macRow.superview
        var insideCollapsedClip = false
        while let view = ancestor {
            if view.frame.height == 0 { insideCollapsedClip = true; break }
            ancestor = view.superview
        }
        #expect(insideCollapsedClip,
                "collapsing Output Devices folds the pinned Mac row with the card body")
    }

    /// Re-expanding restores the exact rail it had before — the plan carries no
    /// state across a collapse → expand cycle, so the geometry is a pure
    /// function of the settled layout (`RailPlan.resolve`).
    @Test func reExpandingASubsectionRestoresTheExactRail() throws {
        let fleet = [local(), airplay(), bt("bt-z:output", name: "Zed Box")]
        let (popover, controller) = makePopover(fleet: fleet)
        controller.setDeviceSelected("office", true)
        controller.setDeviceSelected("bt-z:output", true)
        popover.update(devices: fleet)
        popover.test_applyExactFitSize()
        let before = try #require(popover.test_railPlan())

        popover.test_fireSubsectionHeaderClick(title: bluetoothTitle)
        popover.test_applyExactFitSize()
        popover.test_fireSubsectionHeaderClick(title: bluetoothTitle)
        popover.test_applyExactFitSize()

        let after = try #require(popover.test_railPlan())
        #expect(after == before, "same origin, same stops, same terminus")
    }

    // MARK: Shared preferences and recovery

    // Replacing the row menu would drop Equalizer or Align, or route while hiding.
    @Test func rowAndIconMenusAppendVisibilityActionsWithoutRouting() throws {
        let fleet = [local(), airplay(), bt("bt", name: "Bluetooth")]
        let (popover, controller) = makePopover(fleet: fleet)
        popover.update(devices: fleet)
        let row = try #require(popover.test_deviceRow(for: "bt"))
        let menu = try #require(row.test_contextMenu())
        #expect(menu.items.map(\.title) == ["Equalizer…", "Align by ear…", "", "Show in Mixer", "When available", "Always", "Hide when not in use", "", "Speaker settings…"])
        #expect(menu.items.filter { $0.title == "Equalizer…" }.count == 1)
        #expect(menu.items.filter { $0.title == "Align by ear…" }.count == 1)
        #expect(row.test_iconIsMenuTrigger)
        let provider = row.additionalContextMenuItemsProvider
        var calls = 0
        row.additionalContextMenuItemsProvider = { current in calls += 1; return provider?(current) ?? [] }
        func findIcon(_ view: NSView) -> NSView? {
            if view.accessibilityLabel() == row.test_iconAXLabel { return view }
            return view.subviews.compactMap(findIcon).first
        }
        let icon = try #require(findIcon(row))
        #expect(icon.accessibilityPerformPress())
        #expect(calls == 1, "the icon builds the same menu once")
        let selection = controller.selectedDeviceIDs
        var openedEQ: String?
        popover.onOpenEqualizer = { openedEQ = $0 }
        menu.performActionForItem(at: 0)
        #expect(openedEQ == "bt")
        func item(_ menu: NSMenu, _ title: String) throws -> NSMenuItem {
            try #require(menu.items.first { $0.title == title })
        }
        #expect(try item(menu, "Show in Mixer").isSectionHeader)
        #expect(try item(menu, "When available").state == .on)
        #expect(try item(menu, "Always").state == .off)
        var opened: String?
        popover.onOpenSpeakerSettings = { opened = $0 }
        menu.performActionForItem(at: menu.index(of: try item(menu, "Speaker settings…")))
        #expect(opened == "bt")
        #expect(controller.selectedDeviceIDs == selection)
        menu.performActionForItem(at: menu.index(of: try item(menu, "Always")))
        #expect(popover.test_speakerLibrary.visibility(for: "bt") == .always)
        let rebuilt = try #require(row.test_contextMenu())
        #expect(try item(rebuilt, "Always").state == .on)
        menu.performActionForItem(at: menu.index(of: try item(menu, "Hide when not in use")))
        #expect(popover.test_deviceRow(for: "bt") == nil)
        #expect(controller.selectedDeviceIDs == selection)
        let mac = try #require(popover.test_deviceRow(for: "mac"))
        #expect(mac.test_contextMenu()?.items.contains { $0.title.contains("Mixer") } != true)
    }

    // Retaining an absent speaker must omit its placeholder volume and Equalizer, then restore live values on rediscovery.
    @Test func retainedSpeakerOnlyAnnouncesVolumeAndOffersEqualizerWhileLive() throws {
        let fleet = [local(), airplay()]
        let (popover, controller) = makePopover(fleet: fleet)
        popover.update(devices: fleet)
        let liveRow = try #require(popover.test_deviceRow(for: "office"))
        #expect(liveRow.test_accessibilityLabel?.contains("volume \(VolumePercent.spoken(50))") == true)
        let unconfigured = PopoverController(appRouting: AppRoutingController(
            store: AppRouteStore(directory: tempDirectory()), loadPersisted: false),
            speakerLibrary: popover.test_speakerLibrary)
        unconfigured.test_isShownOverride = true
        unconfigured.update(devices: fleet)
        #expect(unconfigured.test_deviceRow(for: "office")?.test_accessibilityLabel?.contains("volume \(VolumePercent.spoken(50))") == true)
        let liveMenu = try #require(liveRow.test_contextMenu())
        let equalizerIndex = try #require(liveMenu.items.firstIndex { $0.title == "Equalizer…" })
        let alwaysIndex = try #require(liveMenu.items.firstIndex { $0.title == "Always" })
        liveMenu.performActionForItem(at: alwaysIndex)
        #expect(popover.test_speakerLibrary.visibility(for: "office") == .always)

        let selection = controller.selectedDeviceIDs
        var openedEqualizers: [String] = []
        popover.onOpenEqualizer = { openedEqualizers.append($0) }
        popover.update(devices: [local()])
        let retainedRow = try #require(popover.test_deviceRow(for: "office"))
        #expect(retainedRow.test_accessibilityLabel?.contains("volume") == false)
        unconfigured.update(devices: [local()])
        #expect(unconfigured.test_deviceRow(for: "office")?.test_accessibilityLabel?.contains("volume") == false)
        let retainedMenu = try #require(retainedRow.test_contextMenu())
        #expect(retainedMenu.items.map(\.title) == ["Show in Mixer", "When available", "Always", "Hide when not in use", "", "Speaker settings…"])
        liveMenu.performActionForItem(at: equalizerIndex)
        retainedRow.test_clickEQButton()
        #expect(openedEqualizers.isEmpty)
        #expect(controller.selectedDeviceIDs == selection)

        var rediscovered = airplay()
        rediscovered.volume = 73
        let rediscoveredFleet = [local(), rediscovered]
        popover.update(devices: rediscoveredFleet)
        #expect(popover.test_deviceRow(for: "office")?.test_accessibilityLabel?.contains("volume \(VolumePercent.spoken(73))") == true)
        unconfigured.update(devices: rediscoveredFleet)
        #expect(unconfigured.test_deviceRow(for: "office")?.test_accessibilityLabel?.contains("volume \(VolumePercent.spoken(73))") == true)
        let rediscoveredMenu = try #require(popover.test_deviceRow(for: "office")?.test_contextMenu())
        let rediscoveredIndex = try #require(rediscoveredMenu.items.firstIndex { $0.title == "Equalizer…" })
        rediscoveredMenu.performActionForItem(at: rediscoveredIndex)
        #expect(openedEqualizers == ["office"])
    }

    // Hiding current use must retain its row and a connected, undiscovered receiver must keep its known volume.
    @Test(arguments: [Device.Kind.homePod, .cast])
    func hidingAPlayingSpeakerKeepsItVisibleUntilUseEnds(kind: Device.Kind) throws {
        let receiver = kind == .cast ? cast("office", name: "Office") : airplay()
        let fleet = [local(), receiver]
        let (popover, controller) = makePopover(fleet: fleet)
        controller.setDeviceSelected("office", true)
        popover.update(devices: fleet)
        let menu = try #require(popover.test_deviceRow(for: "office")?.test_contextMenu())
        let index = try #require(menu.items.firstIndex { $0.title == "Hide when not in use" })
        #expect(menu.items[index].isEnabled)
        menu.performActionForItem(at: index)
        #expect(popover.test_speakerLibrary.visibility(for: "office") == .hideWhenNotInUse)
        #expect(popover.test_deviceRow(for: "office") != nil)
        #expect(controller.selectedDeviceIDs.contains("office"))
        controller.setDeviceSelected("office", false)
        popover.update(devices: fleet)
        #expect(popover.test_deviceRow(for: "office") == nil)
        #expect(popover.test_speakerSearchStateText == nil)
        popover.test_fireSpeakerSearchGrace()
        #expect(popover.test_speakerSearchStateText == nil)
        #expect(!popover.test_subsectionTitles().contains(airPlayTitle))
        var connected = receiver
        connected.isAvailable = false
        connected.connectionState = .connected
        popover.update(devices: [local(), connected])
        #expect(popover.test_deviceRow(for: "office")?.test_accessibilityLabel?.contains("volume \(VolumePercent.spoken(connected.volume))") == true)
        popover.test_fireSpeakerSearchGrace()
        #expect(popover.test_speakerSearchStateText == nil)
        #expect(popover.test_subsectionTitles() == [kind == .cast ? castTitle : airPlayTitle])
    }

    // Restricting current use to checked speakers hides active scene/app targets; announcing volume invents a value for missing members. It also turns red when the unknown speaker's mounted row sits above a Bluetooth row in the Output Speakers card, or the Pair footer stops following it.
    @Test func hiddenRowsFollowActiveMainSceneAndDeviceAndGroupAppIntent() throws {
        let fleet = [local(), airplay()]
        let backend = RecordingRetryBackend(MockBackend(fleet: fleet, staggerDiscovery: false,
            emitsLevels: false, simulatesDropouts: false))
        let controller = GroupController(backend: backend, store: GroupStore(directory: tempDirectory()),
            routingStore: RoutingStore(directory: tempDirectory()),
            settings: AppSettings(defaults: isolation.makeDefaults()), loadPersisted: false)
        let routes = AppRoutingController(store: AppRouteStore(directory: tempDirectory()), loadPersisted: false)
        let popover = PopoverController(appRouting: routes)
        popover.configure(groupController: controller)
        popover.test_isShownOverride = true
        backend.start()
        SuiteWait.untilOnRunLoop("two devices") { backend.devices.count == 2 }
        let scene = try controller.createGroup(name: "Office scene", memberIDs: ["office", "missing"]).group
        popover.update(devices: fleet)
        popover.test_speakerLibrary.setVisibility(.hideWhenNotInUse, for: ["office", "missing"])
        popover.refreshSpeakerPresentation()
        #expect(popover.test_deviceRow(for: "office") == nil, "inactive scene is not current use")
        #expect(popover.test_deviceRow(for: "missing") == nil)
        controller.setMainOut(.group(id: scene.id))
        popover.update(devices: fleet)
        #expect(popover.test_deviceRow(for: "office") != nil)
        #expect(popover.test_deviceRow(for: "missing")?.test_unavailableStatusText == "Missing speaker")
        #expect(popover.test_deviceRow(for: "missing")?.toolTip == "missing")
        #expect(popover.test_deviceRow(for: "missing")?.accessibilityHelp() == "Missing speaker, missing")
        #expect(popover.test_deviceRow(for: "missing")?.test_accessibilityLabel?.contains("volume") == false)
        #expect(popover.deviceSections().first { $0.title == airPlayTitle }?.devices.contains { $0.id == "missing" } == false)
        let desk = bt("desk", name: "Desk", available: true, state: .connected)
        popover.update(devices: fleet + [desk])
        let order = popover.test_renderedDeviceIDs()
        #expect(order.first == "mac")
        let cardRows = popover.panel.test_cardRows(title: PopoverController.outputDevicesCardTitle)
        let missingRow = try #require(popover.test_deviceRow(for: "missing"))
        let deskRow = try #require(popover.test_deviceRow(for: "desk"))
        let missingIndex = try #require(cardRows.firstIndex { missingRow.isDescendant(of: $0) })
        let deskIndex = try #require(cardRows.firstIndex { deskRow.isDescendant(of: $0) })
        #expect(missingIndex > deskIndex, "unknown speakers close the list, after every Bluetooth row")
        #expect(popover.test_pairBluetoothIsLastCardRow, "the Pair footer still follows the unknown row")
        popover.update(devices: fleet)
        #expect(popover.test_deviceRow(for: "missing")?.test_showsSyncControls == false)
        #expect(popover.test_deviceRow(for: "missing")?.test_contextMenu()?.items.map(\.title)
                == ["Show in Mixer", "When available", "Always", "Hide when not in use", "", "Speaker settings…"])
        controller.setMainOut(.selectedDevices)
        routes.addRoute(bundleID: "music", displayName: "Music")
        routes.setDestination(.device(id: "office"), for: "music")
        popover.update(devices: fleet)
        #expect(popover.test_deviceRow(for: "office") != nil)
        routes.setDestination(.group(id: scene.id), for: "music")
        popover.update(devices: fleet)
        #expect(popover.test_deviceRow(for: "missing") != nil, "app-scene intent includes absent IDs")
        #expect(!controller.devices.contains { $0.id == "missing" })
        #expect(!popover.appDestinations(devices: Array(popover.devicesByID.values), keeping: .noRedirect, bundleID: "music").contains { $0.id == "missing" })
        #expect(backend.retriedIDs.isEmpty)
        routes.setDestination(.noRedirect, for: "music")
        popover.applyRoutedApps(deviceID: "office", appNames: ["Music"])
        popover.update(devices: fleet)
        #expect(popover.test_deviceRow(for: "office") != nil, "confirmed live feed keeps the row inspectable")
    }

    // Always must retain offline identity and known backend volume, but must omit volume once the device leaves the backend.
    @Test func alwaysBluetoothSurvivesBackendAbsenceAndUsesPermissionSpecificGuidance() throws {
        var device = bt("bt", name: "Remembered", available: false)
        device.volume = 48
        let (popover, controller) = makePopover(fleet: [local(), device])
        popover.update(devices: [local(), device])
        popover.test_speakerLibrary.setVisibility(.always, for: "bt")
        popover.refreshSpeakerPresentation()
        #expect(popover.test_deviceRow(for: "bt")?.test_unavailableStatusText == "Not connected")
        #expect(popover.test_deviceRow(for: "bt")?.test_liveControlsHidden == true)
        #expect(popover.test_deviceRow(for: "bt")?.test_accessibilityLabel?.contains("volume \(VolumePercent.spoken(48))") == true)
        let selection = controller.selectedDeviceIDs
        popover.bluetoothPermissionProvider = { .denied }
        popover.update(devices: [local()])
        #expect(popover.test_deviceRow(for: "bt")?.device.name == "Remembered")
        #expect(popover.test_deviceRow(for: "bt")?.test_accessibilityLabel?.contains("volume") == false)
        #expect(popover.test_deviceRow(for: "bt")?.test_unavailableStatusText == "Bluetooth access denied")
        var access = 0
        var pair = 0
        popover.onBluetoothAccess = { access += 1 }
        popover.onPairBluetoothSpeaker = { pair += 1 }
        try #require(popover.test_deviceRow(for: "bt")).test_clickName()
        #expect(access == 1 && pair == 0)
        popover.bluetoothPermissionProvider = { .granted }
        popover.refreshSpeakerPresentation()
        #expect(popover.test_deviceRow(for: "bt")?.test_unavailableStatusText == "Not paired")
        try #require(popover.test_deviceRow(for: "bt")).test_pressNameKey(36)
        #expect(pair == 1 && access == 1)
        #expect(controller.selectedDeviceIDs == selection)
        #expect(popover.devicesByID["bt"] == nil)
    }

    // A name reconnect must use retryOutput without turning playback on.
    @Test func bluetoothNameReconnectRetainsFailureOnlyForTheOpenSurface() throws {
        let device = bt("bt", name: "Bluetooth", available: false)
        let backend = RecordingRetryBackend(MockBackend(fleet: [local(), device], staggerDiscovery: false,
            emitsLevels: false, simulatesDropouts: false))
        let controller = GroupController(backend: backend, store: GroupStore(directory: tempDirectory()),
            routingStore: RoutingStore(directory: tempDirectory()),
            settings: AppSettings(defaults: isolation.makeDefaults()), loadPersisted: false)
        let popover = PopoverController(appRouting: AppRoutingController(
            store: AppRouteStore(directory: tempDirectory()), loadPersisted: false))
        popover.configure(groupController: controller)
        popover.test_isShownOverride = true
        backend.start()
        SuiteWait.untilOnRunLoop("two devices") { backend.devices.count == 2 }
        popover.update(devices: [local(), device])
        popover.test_speakerLibrary.setVisibility(.always, for: "bt")
        popover.refreshSpeakerPresentation()
        let selection = controller.selectedDeviceIDs
        try #require(popover.test_deviceRow(for: "bt")).test_clickName()
        #expect(backend.retriedIDs == ["bt"])
        #expect(controller.selectedDeviceIDs == selection)
        popover.test_speakerLibrary.setVisibility(.whenAvailable, for: "bt")
        var failure = device
        failure.connectionState = .failed(.init(cause: .notPaired))
        popover.update(devices: [local(), failure])
        #expect(popover.test_deviceRow(for: "bt") != nil)
        #expect(popover.test_deviceRow(for: "bt")?.test_feedTooltip == "Not paired")
        var closePublications: [Set<String>] = []
        popover.onSpeakerRecoveryChanged = { closePublications.append(popover.speakerRecoveryIDs) }
        popover.surfaceDidHide()
        #expect(closePublications == [Set<String>()])
        popover.update(devices: [local(), failure])
        #expect(popover.test_deviceRow(for: "bt") == nil)
        #expect(popover.speakerRecoveryIDs.isEmpty)
    }

    // Network lookup must observe fresh exact-ID snapshots and preserve selection.
    @Test func networkNameRecoveryCoalescesTimesOutAndReconnectsOnlyExistingMainIntent() throws {
        var timeouts: [() -> Void] = []
        var cancellations = 0
        let recovery = SpeakerRecoveryController(schedule: { delay, action in
            #expect(delay == 10)
            timeouts.append(action)
            return { cancellations += 1 }
        })
        var offline = airplay()
        offline.isAvailable = false
        let backend = RecordingRetryBackend(MockBackend(fleet: [local(), offline], staggerDiscovery: false,
            emitsLevels: false, simulatesDropouts: false))
        let controller = GroupController(backend: backend, store: GroupStore(directory: tempDirectory()),
            routingStore: RoutingStore(directory: tempDirectory()),
            settings: AppSettings(defaults: isolation.makeDefaults()), loadPersisted: false)
        let popover = PopoverController(appRouting: AppRoutingController(
            store: AppRouteStore(directory: tempDirectory()), loadPersisted: false), speakerRecovery: recovery)
        popover.configure(groupController: controller)
        popover.test_isShownOverride = true
        // Publishing recovery during ingest would let the host repaint a stale row.
        popover.onSpeakerRecoveryChanged = {
            if recovery.state(for: "office") == .found {
                #expect(popover.test_deviceRow(for: "office")?.device.isAvailable == true)
            }
        }
        backend.start()
        SuiteWait.untilOnRunLoop("two devices") { backend.devices.count == 2 }
        popover.update(devices: [local(), offline])
        popover.test_speakerLibrary.setVisibility(.always, for: "office")
        popover.refreshSpeakerPresentation()
        let selection = controller.selectedDeviceIDs
        try #require(popover.test_deviceRow(for: "office")).test_clickName()
        try #require(popover.test_deviceRow(for: "office")).test_pressNameKey(36)
        #expect(timeouts.count == 1)
        #expect(popover.test_deviceRow(for: "office")?.test_unavailableStatusText == "Looking for speaker…")
        #expect(backend.retriedIDs.isEmpty)
        popover.update(devices: [local(), offline, airplay("other", name: "Office")])
        #expect(recovery.state(for: "office") == .looking)
        timeouts[0]()
        #expect(popover.test_deviceRow(for: "office")?.test_unavailableStatusText == "Not found")
        #expect(popover.test_deviceRow(for: "office")?.test_nameTooltip == "Check that the speaker is on and on the same network.")
        #expect(try #require(popover.test_deviceRow(for: "office")).test_pressNameAccessibility())
        popover.update(devices: [local(), airplay()])
        #expect(recovery.state(for: "office") == .found)
        #expect(backend.retriedIDs.isEmpty)
        #expect(controller.selectedDeviceIDs == selection)
        controller.setDeviceSelected("office", true)
        popover.update(devices: [local(), offline])
        try #require(popover.test_deviceRow(for: "office")).test_clickName()
        popover.update(devices: [local(), airplay()])
        #expect(backend.retriedIDs == ["office"])
        let selectedBeforeClose = controller.selectedDeviceIDs
        popover.update(devices: [local(), offline])
        try #require(popover.test_deviceRow(for: "office")).test_clickName()
        let stale = try #require(timeouts.last)
        popover.surfaceDidHide()
        #expect(recovery.states.isEmpty)
        #expect(cancellations >= 3)
        stale()
        #expect(recovery.states.isEmpty)
        #expect(controller.selectedDeviceIDs == selectedBeforeClose)
    }

    // Discovery absence must not hide a connected Cast session.
    @Test func connectedUndiscoveredCastKeepsItsLiveRow() {
        let (popover, _) = makePopover()
        var receiver = cast("cast", name: "TV")
        receiver.isAvailable = false
        receiver.connectionState = .connected
        popover.update(devices: [receiver])
        #expect(popover.test_deviceRow(for: "cast") != nil)
        #expect(popover.test_deviceRow(for: "cast")?.test_unavailableStatusText == nil)
        #expect(popover.test_deviceRow(for: "cast")?.test_liveControlsHidden == false)
    }

}

/// Records the backend reconnect call while retaining normal mock behavior.
private final class RecordingRetryBackend: OutputBackend {
    private let inner: MockBackend
    private(set) var retriedIDs: [String] = []

    init(_ inner: MockBackend) { self.inner = inner }

    var devices: [Device] { inner.devices }
    func start() { inner.start() }
    func stop() { inner.stop() }
    func makeEventStream() -> AsyncStream<BackendEvent> { inner.makeEventStream() }
    func setMuted(_ muted: Bool, for id: String) { inner.setMuted(muted, for: id) }
    func setOutputSet(_ ids: Set<String>) { inner.setOutputSet(ids) }
    func setVolume(_ volume: Int, for id: String) { inner.setVolume(volume, for: id) }

    func retryOutput(_ id: String) {
        retriedIDs.append(id)
        inner.retryOutput(id)
    }
}
