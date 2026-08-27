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
                == ["This Mac", airPlayTitle, bluetoothTitle],
                "a collapsed subsection keeps its header — only the rows go")

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
                == ["This Mac", airPlayTitle, castTitle, bluetoothTitle])
        #expect(popover.test_renderedDeviceIDs() == ["mac", "office", "c1", "bt-a:output"])
    }

    /// Cast follows the hidden-when-empty rule the other non-Bluetooth
    /// subsections obey — no empty grouping label for a feature the user may
    /// own no hardware for.
    @Test func noCastDevicesMeansNoCastHeader() {
        let (popover, _) = makePopover()
        popover.update(devices: [local(), airplay(), bt("bt-a:output", name: "Speaker A")])

        #expect(popover.test_subsectionTitles() == ["This Mac", airPlayTitle, bluetoothTitle])
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
                == ["This Mac", airPlayTitle, castTitle, bluetoothTitle],
                "a collapsed subsection keeps its header — only the rows go")

        popover.test_fireSubsectionHeaderClick(title: castTitle)
        #expect(popover.test_deviceRow(for: "c1") != nil)
    }

    // MARK: Feature B — Bluetooth connected-only listing (BT-LIST)

    /// The headline rule: a paired-but-disconnected Bluetooth device — no
    /// connection story, out of the mix — gets no row at all. macOS keeps
    /// every pairing forever, so this is what keeps the list from being a
    /// wall of dead rows.
    @Test func pairedButDisconnectedBluetoothDevicesAreNotListed() {
        let (popover, _) = makePopover()
        popover.update(devices: [
            local(),
            bt("bt-live:output", name: "Live Speaker"),
            bt("bt-dead-1:output", name: "Dead One", available: false),
            bt("bt-dead-2:output", name: "Dead Two", available: false),
        ])
        #expect(popover.test_renderedDeviceIDs() == ["mac", "bt-live:output"])
        #expect(popover.test_bluetoothRowOrder() == ["bt-live:output"])
        #expect(popover.test_subsectionTitles()
                == ["This Mac", airPlayTitle, bluetoothTitle],
                "the Bluetooth header still renders for the one listed row, and AirPlay's now carries its own search state (P1-1)")
    }

    /// When the connected-only list has nothing to show, the subsection's
    /// empty body IS the Connect affordance — and it opens the same Settings
    /// trip pairing already uses.
    @Test func emptyBluetoothSectionShowsTheConnectButtonAndItOpensSettings() {
        let (popover, _) = makePopover()
        popover.update(devices: [local(), airplay()])
        #expect(popover.test_bluetoothConnectRowShown())
        #expect(popover.test_subsectionTitles() == ["This Mac", airPlayTitle, bluetoothTitle])

        // It has to LOOK actionable, not like a greyed-out placeholder line:
        // a leading "+" glyph is the half a headless run can see (the pointing
        // hand cursor is Alec's to check live).
        #expect(popover.test_bluetoothConnectRowHasGlyph,
                "the Connect row carries its leading glyph")

        var pairTaps = 0
        popover.onPairBluetoothSpeaker = { pairTaps += 1 }
        popover.test_fireBluetoothConnectClick()
        #expect(pairTaps == 1)

        popover.update(devices: [local(), airplay(), bt("bt-live:output", name: "Live Speaker")])
        #expect(!popover.test_bluetoothConnectRowShown(),
                "a connected device replaces the empty state")
    }

    /// An explicit "+"-menu Connect attempt is listed for the REST OF THE
    /// SESSION and no longer: `.failed` is sticky and, for a paired Bluetooth
    /// device, never clears (macOS keeps pairing records forever), so a state
    /// alone must not list a row — that would be a permanent dead row with no
    /// diagnosis panel and no way to dismiss it.
    @Test func aFailedAttemptIsListedForTheSessionThenDropped() {
        let (popover, _) = makePopover(fleet: [local(), bt("bt-a:output", name: "Speaker A")])
        let failed = bt("bt-a:output", name: "Speaker A", available: false,
                        state: .failed(.init(cause: .unknown)))
        popover.update(devices: [local(), failed])
        #expect(popover.test_deviceRow(for: "bt-a:output") == nil,
                "a sticky `.failed` alone never lists a row")

        let menu = popover.test_outputDevicesPlusMenu()
        let index = menu.items.map(\.title).firstIndex(of: "Connect 'Speaker A'")
        #expect(index != nil, "the unlisted pairing is offered in the + menu")
        menu.performActionForItem(at: index!)   // real AppKit menu dispatch
        #expect(popover.test_deviceRow(for: "bt-a:output") != nil,
                "the explicit attempt's outcome is on screen while you look at it")

        popover.surfaceDidHide()
        popover.update(devices: [local(), failed])
        #expect(popover.test_deviceRow(for: "bt-a:output") == nil,
                "…and the list is clean again on the next open")
    }

    /// An IN-MIX disconnected Bluetooth device — selected while already
    /// greyed ("play when up") — keeps its row: the tension between
    /// keep-intent and connected-only resolves by never delisting a device
    /// the user still intends audio on.
    @Test func anInMixDisconnectedBluetoothDeviceKeepsItsGreyedRow() {
        let (popover, controller) = makePopover(fleet: [local(), bt("bt-a:output", name: "Speaker A")])
        popover.update(devices: [local(), bt("bt-a:output", name: "Speaker A", available: false)])
        _ = popover.test_toggleDeviceEnabled(deviceID: "bt-a:output", on: true)   // "play when up"
        #expect(controller.selectedDeviceIDs.contains("bt-a:output"))

        popover.update(devices: [local(), bt("bt-a:output", name: "Speaker A", available: false)])
        #expect(popover.test_deviceRow(for: "bt-a:output") != nil,
                "in-mix keeps the row visible even while unavailable")
        #expect(controller.selectedDeviceIDs.contains("bt-a:output"), "selection is untouched")
    }

    /// The "+" menu's Connect section is the history's surface (BT-LIST): a
    /// paired-but-unlisted Bluetooth device gets a one-click "Connect '<name>'"
    /// item, most recent first, dispatching through the same membership-free
    /// reconnect a greyed row's click fires.
    @Test func plusMenuOffersConnectForUnlistedPairingsByRecency() {
        let backend = RecordingRetryBackend(MockBackend(
            fleet: [local(), bt("bt-old:output", name: "Attic Speaker", available: false),
                    bt("bt-new:output", name: "Zed Speaker", available: false)],
            staggerDiscovery: false, emitsLevels: false, simulatesDropouts: false))
        let controller = GroupController(backend: backend,
                                         store: GroupStore(directory: tempDirectory()),
                                         routingStore: RoutingStore(directory: tempDirectory()),
                                         loadPersisted: false)
        let popover = PopoverController()
        popover.configure(groupController: controller)
        popover.test_isShownOverride = true
        backend.start()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && backend.devices.count < 3 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }

        let now = Date()
        popover.btLastUsedProvider = {
            ["bt-old:output": now.addingTimeInterval(-86_400 * 400), "bt-new:output": now]
        }
        popover.update(devices: [local(),
                                 bt("bt-old:output", name: "Attic Speaker", available: false),
                                 bt("bt-new:output", name: "Zed Speaker", available: false)])

        let menu = popover.test_outputDevicesPlusMenu()
        let titles = menu.items.map(\.title)
        #expect(titles.contains(""), "a separator precedes the Connect section")
        #expect(menu.item(withTitle: "Bluetooth Pairings")?.isEnabled == false,
                "the section header is a disabled label, not an action")
        let newIndex = titles.firstIndex(of: "Connect 'Zed Speaker'")
        let oldIndex = titles.firstIndex(of: "Connect 'Attic Speaker'")
        #expect(newIndex != nil && oldIndex != nil && newIndex! < oldIndex!,
                "most recent first")

        menu.performActionForItem(at: newIndex!)
        #expect(backend.retriedIDs == ["bt-new:output"])
        #expect(!controller.selectedDeviceIDs.contains("bt-new:output"), "selection is untouched")
    }

    @Test func theEmptyFleetPairsTheSearchLineWithTheBluetoothAffordance() {
        // Still no GENERIC "Looking for devices…" placeholder (removed
        // 2026-08-08 — it contradicted the always-rendered Bluetooth Connect
        // affordance directly below it). What P1-1 added instead lives INSIDE
        // the AirPlay subsection, under the header that names what is being
        // looked for, so the two lines are about different sections and cannot
        // contradict each other.
        let (popover, _) = makePopover()
        popover.update(devices: [])
        #expect(popover.test_subsectionTitles() == [airPlayTitle, bluetoothTitle],
                "the AirPlay search state and the always-on Bluetooth subsection")
        #expect(popover.test_bluetoothConnectRowShown(),
                "the Bluetooth section's own Connect affordance still renders")
    }

    // MARK: The rail runs to the lowest selected device, hidden or not

    /// The spine runs to the LOWEST SELECTED device, and a collapsed
    /// subsection hiding that device does NOT shorten it: the rail keeps
    /// running past the rows above and is CUT at that subsection's header with
    /// a dot — exactly what collapsing the whole CARD already does.
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

    /// The case that erased the rail outright: EVERY device inside the subsection
    /// being collapsed. No visible node is left for the channel to reach, so the
    /// rail is nothing BUT the cut — a dot at that subsection's header, never a
    /// hook curling off Main Audio into mid-air.
    @Test func collapsingTheSubsectionHoldingEveryDeviceStillEndsInADot() throws {
        let fleet = [local()]
        let (popover, controller) = makePopover(fleet: fleet)
        controller.setDeviceSelected("mac", true)   // …and nothing else
        popover.update(devices: fleet)
        popover.test_applyExactFitSize()
        #expect(!(try #require(popover.test_railPlan()).stops.isEmpty),
                "expanded: the Mac's own node is on the rail")

        popover.test_fireSubsectionHeaderClick(title: PopoverController.thisMacSubsectionTitle)
        popover.test_applyExactFitSize()

        let plan = try #require(popover.test_railPlan())
        #expect(plan.stops.isEmpty, "no visible node is left to draw")
        #expect(plan.terminusDotY != nil,
                "the rail ends in a dot at the collapsed header, not in mid-air")
    }

    /// The invariant behind both cases above, stated once. With the origin
    /// resolved and devices in the mix, a rail plan may never be BOTH stop-less
    /// and dot-less — that pair IS the dangling hook, a rail that starts at
    /// Main Audio and ends nowhere. Swept over every subsection, collapsing
    /// them one after another until all three are shut.
    @Test func aRailWithDevicesInTheMixIsNeverBothStopLessAndDotLess() throws {
        let fleet = [local(), airplay(), bt("bt-z:output", name: "Zed Box")]
        let (popover, controller) = makePopover(fleet: fleet)
        controller.setDeviceSelected("office", true)
        controller.setDeviceSelected("mac", true)
        controller.setDeviceSelected("bt-z:output", true)
        popover.update(devices: fleet)

        for title in [PopoverController.thisMacSubsectionTitle, airPlayTitle, bluetoothTitle] {
            popover.test_fireSubsectionHeaderClick(title: title)
            popover.test_applyExactFitSize()
            let plan = try #require(popover.test_railPlan())
            #expect(!(plan.stops.isEmpty && plan.terminusDotY == nil),
                    "collapsing \(title) left the rail with no stops AND no terminus")
        }
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
}

/// Wraps a real ``MockBackend`` and records every id `retryOutput` was called
/// with, so `plusMenuOffersConnectForUnlistedPairingsByRecency` can assert the
/// "+" menu's Connect item dispatches the real membership-free reconnect
/// (`GroupController.requestReconnect` → `OutputBackend.retryOutput`) without
/// touching selection. Mirrors `GroupControllerTests.RecordingBackend`.
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
