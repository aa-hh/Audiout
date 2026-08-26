// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import AppKit
@testable import AudiouterCore
@testable import AudiouterPopoverUI
@testable import AudiouterSharedUI

/// BT-UI row behavior on `DeviceRowView` itself: the greyed-row
/// click-connects branch, the reconnect node vocabulary, the failure-headline
/// FEED pill, and the SYNC value chip's three states + real-dispatch toggle
/// (this repo was bitten by test hooks bypassing AppKit dispatch — every
/// interaction here rides `performClick`/the control's own target/action).
@MainActor
@Suite final class BTDeviceRowTests: IsolatedSuite {

    private final class SpyDelegate: DeviceRowView.Delegate {
        var toggles: [(on: Bool, id: String)] = []
        var reconnects: [String] = []
        var drawerToggles: [String] = []
        var wizardRequests: [String] = []
        func deviceRow(_ row: DeviceRowView, didSetVolume volume: Int, for id: String) {}
        func deviceRow(_ row: DeviceRowView, didToggleMute muted: Bool, for id: String) {}
        func deviceRow(_ row: DeviceRowView, didToggleEnabled on: Bool, for id: String) {
            toggles.append((on, id))
        }
        func deviceRowDidRequestBlockedExplanation(_ row: DeviceRowView) {}
        func deviceRowDidRequestReconnect(_ row: DeviceRowView) {
            reconnects.append(row.device.id)
        }
        func deviceRow(_ row: DeviceRowView, didToggleSyncDrawerFor id: String) {
            drawerToggles.append(id)
        }
        func deviceRowDidRequestAlignmentWizard(_ row: DeviceRowView) {
            wizardRequests.append(row.device.id)
        }
    }

    private func btDevice(available: Bool = true,
                          state: ConnectionState = .off) -> Device {
        Device(id: "C4-38-75-0E-BF-4A:output", name: "Sonos Move 2", kind: .bluetooth,
               isAvailable: available, supportsAirPlay2: false, connectionState: state)
    }

    /// The popover's real BT row shape: bus + meter + SYNC chip.
    private func makeRow(_ device: Device, delegate: SpyDelegate,
                         syncTrimMs: Double = 0, syncTrimIsSet: Bool = false,
                         syncMeasuredLatencyMs: Double? = nil,
                         syncDrawerExpanded: Bool = false,
                         selected: Bool = false) -> DeviceRowView {
        let row = DeviceRowView(device: device, showsToggle: true,
                                paintsSelectionBackground: false, showsMeter: true,
                                showsBus: true, showsSyncControls: true)
        row.delegate = delegate
        row.apply(device, selected: selected, controllable: selected,
                  syncTrimMs: syncTrimMs, syncTrimIsSet: syncTrimIsSet,
                  syncMeasuredLatencyMs: syncMeasuredLatencyMs,
                  syncDrawerExpanded: syncDrawerExpanded)
        return row
    }

    // MARK: Click-connects (greyed row)

    @Test func greyedBTRowNameClickRequestsReconnectNotSelection() {
        let spy = SpyDelegate()
        let row = makeRow(btDevice(available: false), delegate: spy)
        row.test_clickName()
        #expect(spy.reconnects == [btDevice().id], "a greyed BT row's click CONNECTS")
        #expect(spy.toggles.isEmpty, "…and never edits membership")
    }

    @Test func availableBTRowNameClickTogglesSelectionLikeAirPlay() {
        let spy = SpyDelegate()
        let row = makeRow(btDevice(available: true), delegate: spy)
        row.test_clickName()
        #expect(spy.toggles.map(\.on) == [true], "an available BT row selects exactly like an AirPlay row")
        #expect(spy.reconnects.isEmpty)
    }

    // MARK: Node/ring vocabulary

    @Test func disconnectedRowRendersDimmedHollowNode() {
        let row = makeRow(btDevice(available: false), delegate: SpyDelegate())
        #expect(row.test_busNode == .nonMember, "paired-but-disconnected = hollow node")
        #expect(row.test_busNodeDimmed == true, "…dimmed")
        #expect(row.test_ringForm == .none)
    }

    @Test func reconnectAttemptShowsTheConnectingNodeWhileStillUnavailable() {
        // A BT reconnect keeps `isAvailable == false` until the endpoint
        // appears — the node must show the attempt anyway (locked spec).
        let row = makeRow(btDevice(available: false, state: .connecting), delegate: SpyDelegate())
        #expect(row.test_busNode == .connecting)
        #expect(row.test_ringForm == .connecting)
        #expect(row.test_feedText != "Unavailable",
                "the in-flight attempt is never shouted over by the unavailable pill")
    }

    /// The GREYED row's reconnect spinner actually ANIMATES: the dashed ring's
    /// breathing pulse installs on an unavailable BT row exactly as on an
    /// available one (`HaloRingView` is driven by `connectionState` alone —
    /// availability never gates it). Same mapping pin as
    /// `DeviceRowConnectionStateTests.connectingRingBreathingMatchesReduceMotionSetting`:
    /// present iff on-screen and Reduce Motion off.
    @Test func greyedRowReconnectRingBreathesLikeAnyConnectingRing() {
        let spy = SpyDelegate()
        let row = makeRow(btDevice(available: false, state: .connecting), delegate: spy)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 44),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(row)
        row.apply(btDevice(available: false, state: .connecting), selected: false)
        #expect(row.test_ringIsDashed, "the connecting FORM renders on the greyed row")
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #expect(row.test_ringIsBreathing == !reduceMotion,
                "…and it breathes iff Reduce Motion is off — greyed-ness never freezes it")
    }

    /// The payoff of the backend's `.connecting` hold (BT-LIFECYCLE), on the
    /// row that renders it: a SELECTED, AVAILABLE BT speaker breathes with a
    /// dark dot and no meter while its audio is still in the delay line, and
    /// flips to the solid ring + lit dot + visible meter the moment the backend
    /// says it is audible. Spinner and meter are two halves of one predicate,
    /// so they are pinned together.
    @Test func selectedBTRowBreathesWithNoMeterThenArmsWhenConnected() {
        let spy = SpyDelegate()
        let row = makeRow(btDevice(state: .connecting), delegate: spy, selected: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 44),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(row)

        #expect(row.test_ringForm == .connecting)
        #expect(row.test_ringIsDashed, "the hold reads as the breathing (dashed) ring")
        #expect(!row.test_routeArmed, "…with the dot still dark")
        #expect(!row.test_meterVisible, "…and no meter while nothing is audible yet")

        row.apply(btDevice(state: .connected), selected: true, controllable: true)
        #expect(row.test_ringForm == .connected)
        #expect(row.test_routeArmed, "the audible edge lights the dot")
        #expect(row.test_meterVisible, "…and mounts the meter")
        row.setLevel(0.4)
        #expect(row.test_meterLevel() == 0.4, "levels now land on a meter the user can see")
    }

    // MARK: Failure headline (never instructional sublabels)

    @Test func failedRowRendersTheFailureHeadlineInTheFeedPill() {
        let spy = SpyDelegate()
        let elsewhere = makeRow(
            btDevice(available: false, state: .failed(.init(cause: .connectedElsewhere))),
            delegate: spy, selected: true)
        #expect(elsewhere.test_feedText == "Connected elsewhere")
        #expect(elsewhere.test_feedIsErrorColored)
        #expect(elsewhere.test_ringForm == .failed)

        let notPaired = makeRow(
            btDevice(available: false, state: .failed(.init(cause: .notPaired))),
            delegate: spy, selected: true)
        #expect(notPaired.test_feedText == "Not paired")
        #expect(notPaired.test_statusText == nil, "no instructional sublabels — ever")
    }

    // MARK: SYNC value chip (PLAN-BT-SYNC-DRAWER T6) — three states + real dispatch

    @Test func tunedChipShowsTheValueWithACollapsedChevron() {
        let row = makeRow(btDevice(), delegate: SpyDelegate(), syncTrimMs: 24, syncTrimIsSet: true)
        #expect(row.test_syncChipTitle == "24 ms",
                "the chip is a read-only summary of the trim, in whole ms")
        #expect(row.test_syncChipChevronSymbolName == "chevron.right", "collapsed ⇒ chevron.right, the disclosure convention")
        #expect(!row.test_syncChipIsDashed, "a tuned chip's border is solid")
        #expect(!row.test_syncChipIsEngaged)
        #expect(row.test_syncChipTitleColor == Tokens.Color.label)
        #expect(row.test_syncChipEnabled)
    }

    @Test func negativeTrimReadsAsEarlierWhereverTheChipSpellsItOut() {
        let row = makeRow(btDevice(), delegate: SpyDelegate(), syncTrimMs: -24, syncTrimIsSet: true)
        #expect(row.test_syncChipTitle == "−24 ms", "typographic minus, not a hyphen")
        #expect(row.test_syncChipTooltip?.contains("24 milliseconds earlier") == true,
                "the chip is too narrow for D7's phrasing, so the tooltip carries the direction")
    }

    /// The live complaint (owner, wizard v11): a run that printed "248 ms ·
    /// kept" left the row's SYNC chip reading the zeroed nudge, so the
    /// measurement was nowhere on the row. The chip's number is now the TOTAL
    /// the speaker actually carries — measurement plus nudge — and the split
    /// stays in the tooltip.
    @Test func theChipCarriesTheMeasuredLatencyNotJustTheNudge() {
        let measured = makeRow(btDevice(), delegate: SpyDelegate(),
                               syncTrimMs: 24, syncTrimIsSet: true,
                               syncMeasuredLatencyMs: 320)
        #expect(measured.test_syncChipTitle == "344 ms", "measurement plus the nudge on top")
        #expect(measured.test_syncChipTooltip?.contains("Measured latency: 320 ms") == true,
                "got \(measured.test_syncChipTooltip ?? "none")")
        #expect(measured.test_syncChipTooltip?.contains("24 milliseconds later") == true,
                "…and the nudge is named as the other half")

        // What a finished wizard run leaves: the nudge zeroed, the measurement
        // stored. The chip must read the measurement, never "0 ms".
        let justKept = makeRow(btDevice(), delegate: SpyDelegate(),
                               syncTrimMs: 0, syncTrimIsSet: true,
                               syncMeasuredLatencyMs: 248)
        #expect(justKept.test_syncChipTitle == "248 ms", "the number the wizard showed")
        #expect(justKept.test_syncChipAXValue?.hasPrefix("248 milliseconds later") == true,
                "got \(justKept.test_syncChipAXValue ?? "none")")
        #expect(justKept.test_syncChipTooltip?.contains("no nudge on top") == true)

        let neverMeasured = makeRow(btDevice(), delegate: SpyDelegate(),
                                    syncTrimMs: 24, syncTrimIsSet: true)
        #expect(neverMeasured.test_syncChipTitle == "24 ms", "no measurement, so just the nudge")
        #expect(neverMeasured.test_syncChipTooltip?.contains("Measured latency") == false,
                "a speaker the wizard has never run against says nothing about latency")
    }

    /// A measured latency can sit outside the TRIM's own ±500 ms bound, and the
    /// chip must print it rather than shrink it to the bound.
    @Test func aLatencyBeyondTheTrimsRangeIsPrintedWhole() {
        let row = makeRow(btDevice(), delegate: SpyDelegate(),
                          syncTrimMs: 0, syncTrimIsSet: true, syncMeasuredLatencyMs: 640)
        #expect(row.test_syncChipTitle == "640 ms")
        #expect(row.test_syncChipTooltip?.contains("640 milliseconds later") == true,
                "got \(row.test_syncChipTooltip ?? "none")")
    }

    /// A measurement alone counts as tuned: the dashed "never touched this"
    /// outline must not survive a finished run.
    @Test func aMeasuredSpeakerIsNeverTheUntunedInvitation() {
        let row = makeRow(btDevice(), delegate: SpyDelegate(),
                          syncTrimMs: 0, syncTrimIsSet: false, syncMeasuredLatencyMs: 248)
        #expect(row.test_syncChipTitle == "248 ms", "never 'Not set' once a run has measured it")
        #expect(row.test_syncChipIsDashed == false)
    }

    /// D10, the discoverability fix: an untuned speaker must not read "0.0 ms"
    /// (which looks finished) — it reads "Not set" inside a DASHED outline,
    /// which reads as an invitation.
    @Test func untunedChipReadsNotSetInADashedTertiaryOutline() {
        let row = makeRow(btDevice(), delegate: SpyDelegate(), syncTrimMs: 0, syncTrimIsSet: false)
        #expect(row.test_syncChipTitle == "Not set")
        #expect(row.test_syncChipIsDashed, "the dashed border IS the invitation")
        #expect(row.test_syncChipTitleColor == Tokens.Color.tertiaryLabel)
        #expect(row.test_syncChipBorderColor == Tokens.Color.tertiaryLabel,
                "one de-emphasis tone, spoken by both the text and its outline")
    }

    /// The engaged treatment is the MUTE PILL's recipe — a translucent
    /// ``Tokens/Color/engagedChrome`` fill — and never gold: gold is the
    /// route-armed/primary vocabulary, and a drawer disclosure is neither.
    /// Neutral is the point, so this also pins that the chip never picks up the
    /// system accent, which follows the user's macOS colour setting and would
    /// put a foreign hue on a warm panel.
    @Test func openDrawerChipWearsTheEngagedChromeTreatmentNotGold() {
        let row = makeRow(btDevice(), delegate: SpyDelegate(), syncTrimMs: 24,
                          syncTrimIsSet: true, syncDrawerExpanded: true)
        #expect(row.test_syncChipChevronSymbolName == "chevron.down", "expanded ⇒ rotated down to reveal")
        #expect(row.test_syncChipIsEngaged)
        #expect(row.test_syncChipFill
                == Tokens.Color.engagedChrome.withAlphaComponent(PopoverColumnGrid.mutePillFillAlpha),
                "exactly the mute pill's engaged fill")
        #expect(row.test_syncChipFill != Tokens.Color.gold, "…and never the gold accent")
        #expect(row.test_syncChipTitleColor == Tokens.Color.engagedChrome)
        #expect(row.test_syncChipBorderColor == Tokens.Color.engagedChrome)
        #expect(row.test_syncChipBorderColor != Tokens.Color.accent,
                "…nor the user's system accent")

        let collapsed = makeRow(btDevice(), delegate: SpyDelegate(), syncTrimMs: 24,
                                syncTrimIsSet: true)
        #expect(collapsed.test_syncChipFill == nil, "a resting chip fills nothing")
    }

    @Test func chipClickAsksTheHostToToggleTheDrawerAndNeverEditsTheTrim() {
        let spy = SpyDelegate()
        let row = makeRow(btDevice(), delegate: spy, syncTrimMs: 24, syncTrimIsSet: true)
        row.test_fireSyncChipClick()
        row.test_fireSyncChipClick()
        #expect(spy.drawerToggles == [btDevice().id, btDevice().id],
                "each click is one toggle request — the host owns open/close (D2)")
        #expect(row.test_syncChipTitle == "24 ms",
                "the chip is read-only: clicking it never moves the value")
    }

    @Test func disconnectedRowShowsTheSavedTrimOnADeadChip() {
        let spy = SpyDelegate()
        let row = makeRow(btDevice(available: false), delegate: spy,
                          syncTrimMs: -120, syncTrimIsSet: true)
        #expect(row.test_syncChipTitle == "−120 ms", "the saved value stays visible")
        #expect(!row.test_syncChipEnabled,
                "…but there is nothing to tune while the speaker is away")
        row.test_fireSyncChipClick()   // disabled button — a real click is a no-op
        #expect(spy.drawerToggles.isEmpty, "no drawer opens for an absent speaker")
    }

    @Test func chipSpeaksItsOffsetAndItsExpandedState() {
        let tuned = makeRow(btDevice(), delegate: SpyDelegate(), syncTrimMs: 24, syncTrimIsSet: true)
        #expect(tuned.test_syncChipAXLabel == "Sync offset for Sonos Move 2")
        #expect(tuned.test_syncChipAXValue == "24 milliseconds later",
                "never a bare signed number (D7)")
        #expect(tuned.test_syncChipAXExpanded == false)

        let untuned = makeRow(btDevice(), delegate: SpyDelegate(), syncTrimIsSet: false)
        #expect(untuned.test_syncChipAXValue == "not set")

        let open = makeRow(btDevice(), delegate: SpyDelegate(), syncTrimMs: -3,
                           syncTrimIsSet: true, syncDrawerExpanded: true)
        #expect(open.test_syncChipAXExpanded, "the drawer's state is spoken, not only drawn")
        #expect(open.test_syncChipAXValue == "3 milliseconds earlier")
    }

    /// The T6 regression guard from the other side: a non-BT row mounts no
    /// chip at all, so nothing about the AirPlay row's trailing slot moved.
    @Test func airPlayRowMountsNoSyncChip() {
        let device = Device(id: "office", name: "Office", kind: .homePod)
        let row = DeviceRowView(device: device, showsToggle: true,
                                paintsSelectionBackground: false, showsMeter: true,
                                showsBus: true)
        row.apply(device, selected: false)
        #expect(row.test_showsSyncControls == false)
        #expect(row.test_syncChipTitle == nil)
        #expect(row.test_syncChipEnabled == false)
    }

    /// The metronome button lives in the sync drawer now (D9); ⌥-click on it
    /// is the wizard relaunch that used to sit on the row's own button.
    @Test func optionClickOnTheDrawerMetronomeRequestsTheWizardNotTheTick() {
        final class DrawerSpy: BTSyncDrawerViewDelegate {
            var tickToggles: [Bool] = []
            var wizardRequests = 0
            func syncDrawer(_ d: BTSyncDrawerView, didChangeTrimMs ms: Double, committed: Bool) {}
            func syncDrawer(_ d: BTSyncDrawerView, didToggleAlignTick active: Bool) {
                tickToggles.append(active)
            }
            func syncDrawerDidRequestClose(_ d: BTSyncDrawerView) {}
            func syncDrawerDidRequestAlignmentWizard(_ d: BTSyncDrawerView) { wizardRequests += 1 }
        }
        let spy = DrawerSpy()
        let drawer = BTSyncDrawerView()
        drawer.delegate = spy
        drawer.test_optionModifierOverride = true
        drawer.test_fireAlignClick()
        #expect(spy.wizardRequests == 1, "⌥-click asks for the guided wizard")
        #expect(spy.tickToggles.isEmpty, "…never the manual tick")
        #expect(!drawer.test_alignActive, "and the toggle never flips")
        #expect(DeviceRowView.alignTooltip.contains("⌥ for the guided alignment"),
                "the tooltip teaches the invisible modifier")
    }

    @Test func contextMenuCarriesAlignSpeakerOnBTRowsThroughRealMenuDispatch() {
        let spy = SpyDelegate()
        let row = makeRow(btDevice(), delegate: spy)
        let menu = row.test_contextMenu()
        #expect(menu?.items.map(\.title) == ["Align speaker…"])
        #expect(menu?.items.first?.isEnabled == true)
        menu?.performActionForItem(at: 0)   // real AppKit menu dispatch
        #expect(spy.wizardRequests == [btDevice().id])

        let plain = DeviceRowView(device: btDevice(), showsToggle: true,
                                  paintsSelectionBackground: false, showsMeter: true,
                                  showsBus: true, showsSyncControls: false)
        #expect(plain.test_contextMenu() == nil, "non-sync rows carry no alignment menu")
    }

    @Test func contextMenuAlignItemDisablesOnAGreyedRow() {
        let row = makeRow(btDevice(available: false), delegate: SpyDelegate())
        #expect(row.test_contextMenu()?.items.first?.isEnabled == false,
                "no wizard offer over a silent target")
    }
}

/// BT-UI at the popover level: the Bluetooth subsection's hide-when-empty +
/// recency sort, the OUTPUT DEVICES "+" menu (real `NSMenu` dispatch), and the
/// SYNC column's host plumbing (trim cache/closures, align tick lifecycle).
/// `.serialized` for the same reason `PopoverControllerTests` is.
@MainActor
@Suite(.serialized) struct BTPopoverRowsTests {

    private func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    /// A popover over a `MockBackend` whose rendered rows are pushed by hand
    /// via `update(devices:)`, so BT rows can be scripted freely. `fleet` is
    /// only needed by tests whose interaction round-trips `GroupController`
    /// (its selection guard requires the id to exist on the backend); the
    /// default keeps the backend empty and never started.
    private func makePopover(fleet: [Device] = []) -> (PopoverController, GroupController, MockBackend) {
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
            waitFor { backend.devices.count == fleet.count }
        }
        return (popover, controller, backend)
    }

    private func waitFor(timeout: TimeInterval = 5, _ cond: @escaping () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
    }

    private func local() -> Device {
        Device(id: "mac", name: "This Mac", kind: .localMac, isLocalDevice: true)
    }

    private func airplay(_ id: String = "office") -> Device {
        Device(id: id, name: "Office", kind: .homePod)
    }

    private func bt(_ id: String, name: String, available: Bool = true,
                    state: ConnectionState = .off) -> Device {
        Device(id: id, name: name, kind: .bluetooth,
               isAvailable: available, supportsAirPlay2: false, connectionState: state)
    }

    // MARK: Subsection — always renders (BT-LIST) + recency sort

    @Test func bluetoothSubsectionHeaderAlwaysRendersWithAConnectRowWhenEmpty() {
        let (popover, _, _) = makePopover()
        popover.update(devices: [local(), airplay()])
        #expect(popover.test_subsectionTitles() == ["This Mac", "AirPlay Devices", "Bluetooth Devices"])
        #expect(popover.test_bluetoothRowOrder().isEmpty)
        #expect(popover.test_bluetoothConnectRowShown())
    }

    /// The "SYNC" column title is printed only when BT rows carrying a sync chip
    /// sit under it. The Bluetooth header renders even with nothing listed (its
    /// empty body IS the Connect affordance), so without the gate the title names
    /// a column that does not exist.
    @Test func syncColumnTitleIsPrintedOnlyWhenBluetoothRowsExist() {
        let (popover, _, _) = makePopover()
        popover.update(devices: [local(), airplay()])
        #expect(popover.test_bluetoothConnectRowShown(),
                "precondition: the subsection is in its empty state")
        #expect(!popover.test_syncColumnTitleShown(in: "Bluetooth Devices"),
                "no rows under it means no column to name")

        popover.update(devices: [local(), airplay(), bt("bt-a:output", name: "Attic Speaker")])
        #expect(popover.test_bluetoothRowOrder() == ["bt-a:output"])
        #expect(popover.test_syncColumnTitleShown(in: "Bluetooth Devices"),
                "one listed BT row brings its SYNC chip — and the title back")
    }

    @Test func bluetoothSubsectionRendersAfterAirPlaySortedByRecency() {
        let (popover, _, _) = makePopover()
        let now = Date()
        popover.btLastUsedProvider = {
            ["bt-old:output": now.addingTimeInterval(-86_400 * 400),
             "bt-new:output": now]
            // "bt-ghost:output" has no recency at all — the deadest pairing.
        }
        // All three must be AVAILABLE (BT-LIST is connected-only) or the
        // unlisted two would have no row to sort at all.
        popover.update(devices: [
            local(), airplay(),
            bt("bt-ghost:output", name: "Ancient Speaker"),
            bt("bt-new:output", name: "Zed Speaker"),
            bt("bt-old:output", name: "Attic Speaker"),
        ])
        #expect(popover.test_subsectionTitles()
                == ["This Mac", "AirPlay Devices", "Bluetooth Devices"])
        #expect(popover.test_bluetoothRowOrder()
                == ["bt-new:output", "bt-old:output", "bt-ghost:output"],
                "most recent first; a pairing with no recency sinks to the bottom")
        #expect(popover.test_deviceRow(for: "bt-new:output")?.test_showsSyncControls == true,
                "BT rows mount the SYNC chip")
        #expect(popover.test_deviceRow(for: "office")?.test_showsSyncControls == false,
                "AirPlay rows never do")
    }

    // MARK: OUTPUT DEVICES "+" menu

    @Test func plusMenuOffersPairingAndDispatchesThroughRealMenuActions() {
        let (popover, _, _) = makePopover()
        popover.update(devices: [local(), airplay()])
        var paired = 0
        popover.onPairBluetoothSpeaker = { paired += 1 }

        let menu = popover.test_outputDevicesPlusMenu()
        #expect(menu.items.map(\.title)
                == ["Save Selected Devices as group", "Pair a Bluetooth speaker…"])
        menu.performActionForItem(at: 1)   // real AppKit menu dispatch
        #expect(paired == 1)
    }

    // MARK: SYNC plumbing — cache, closures, chip seeding

    /// The chip is read-only (T6), so the edit ENTERS through the drawer. What
    /// is pinned here is the host half: the closure fires, the session cache
    /// outranks the provider, and the row's chip re-reads the freshest value
    /// on a repaint.
    @Test func trimEditsFlowThroughTheClosureAndSurviveRepaints() {
        let (popover, _, _) = makePopover()
        var written: [(ms: Double, id: String, persist: Bool)] = []
        popover.btTrimProvider = { _ in 120 }
        popover.btTrimIsSetProvider = { _ in true }
        popover.onSetBTTrim = { ms, id, persist in written.append((ms, id, persist)) }
        let devices = [local(), bt("bt-a:output", name: "Speaker A")]
        popover.update(devices: devices)

        let row = popover.test_deviceRow(for: "bt-a:output")
        #expect(row?.test_syncChipTitle == "120 ms", "rows seed from the persisted trim")
        #expect(row?.test_syncChipIsDashed == false, "a persisted trim is a TUNED chip")

        popover.test_toggleSyncDrawer(deviceID: "bt-a:output")
        popover.test_syncDrawer?.test_shiftModifierOverride = true
        popover.test_syncDrawer?.test_firePlusClick()        // ⇧+ = +10 ms, real target/action
        #expect(written.last?.ms == 130)
        #expect(written.last?.id == "bt-a:output")
        #expect(written.last?.persist == true, "a stepper click is a committed gesture")

        // A repaint keeps the freshest edit — the cache outranks the provider.
        popover.update(devices: devices)
        #expect(popover.test_deviceRow(for: "bt-a:output")?.test_syncChipTitle == "130 ms")
    }

    /// D10 at the popover level: a device with no persisted ENTRY reads "Not
    /// set" on its chip, not "0.0 ms" — and a device deliberately tuned to
    /// exactly 0.0 reads "0.0 ms", which the value alone could never tell
    /// apart (T7 §6).
    @Test func untunedChipTracksThePersistedENTRYNotTheValue() {
        let (popover, _, _) = makePopover()
        popover.btTrimProvider = { _ in 0 }
        popover.btTrimIsSetProvider = { $0 == "bt-b:output" }
        popover.update(devices: [local(),
                                 bt("bt-a:output", name: "Speaker A"),
                                 bt("bt-b:output", name: "Speaker B")])

        let never = popover.test_deviceRow(for: "bt-a:output")
        #expect(never?.test_syncChipTitle == "Not set")
        #expect(never?.test_syncChipIsDashed == true)

        let tunedToZero = popover.test_deviceRow(for: "bt-b:output")
        #expect(tunedToZero?.test_syncChipTitle == "0 ms",
                "a deliberate 0.0 is TUNED — the old value != 0 placeholder got this wrong")
        #expect(tunedToZero?.test_syncChipIsDashed == false)
    }

    @Test func disconnectedRowShowsPersistedTrimReadOnly() {
        // BT-LIST: a disconnected row only renders while it is IN THE MIX, so
        // it must be selected ("play when up") before going unavailable.
        let (popover, _, _) = makePopover(fleet: [local(), bt("bt-a:output", name: "Speaker A")])
        popover.btTrimProvider = { _ in -50 }
        popover.btTrimIsSetProvider = { _ in true }
        popover.update(devices: [local(), bt("bt-a:output", name: "Speaker A", available: false)])
        _ = popover.test_toggleDeviceEnabled(deviceID: "bt-a:output", on: true)
        popover.update(devices: [local(), bt("bt-a:output", name: "Speaker A", available: false)])
        let row = popover.test_deviceRow(for: "bt-a:output")
        #expect(row?.test_syncChipTitle == "−50 ms")
        #expect(row?.test_syncChipEnabled == false)
    }

    // MARK: Align tick lifecycle — one at a time, stops on close

    /// The align-by-ear BUTTON moved off the row into the drawer (D9), so the
    /// gesture arrives at the host from there. The HOST's lifecycle rules —
    /// one tick at a time, stopped by the popover closing — are unchanged.
    @Test func alignTickIsOneAtATimeAndStopsWhenThePopoverCloses() {
        let (popover, _, _) = makePopover()
        var gates: [Bool] = []
        popover.onAlignTickActiveChange = { gates.append($0) }
        popover.update(devices: [
            local(),
            bt("bt-a:output", name: "Speaker A"),
            bt("bt-b:output", name: "Speaker B"),
        ])

        popover.test_toggleSyncDrawer(deviceID: "bt-a:output")
        popover.test_syncDrawer?.test_fireAlignClick()
        #expect(popover.test_alignTickDeviceID() == "bt-a:output")
        #expect(gates.last == true)

        // Opening B's drawer closes A's, which takes A's tick with it — the
        // tick can only ever belong to the one visible control (T7 §3).
        popover.test_toggleSyncDrawer(deviceID: "bt-b:output")
        #expect(popover.test_alignTickDeviceID() == nil,
                "a collapsing drawer stops its tick — no metronome without a control")
        popover.test_syncDrawer?.test_fireAlignClick()
        #expect(popover.test_alignTickDeviceID() == "bt-b:output", "the single tick MOVES")

        popover.surfaceDidHide()
        #expect(popover.test_alignTickDeviceID() == nil, "click-away/close stops the tick")
        #expect(gates.last == false)
    }

    // MARK: Deselect on availability loss (off = unselected)

    /// A selected BT device that loses availability — power-off, vanish, or
    /// sleep all reach this surface as the same edge — is DESELECTED through
    /// `GroupController.setDeviceSelected`; on return it sits available but
    /// unselected (no auto-resume) until the user selects it again.
    @Test func selectedBTRowIsDeselectedOnAvailabilityLossAndStaysOffOnReturn() {
        let (popover, controller, _) = makePopover(fleet: [local(), bt("bt-a:output", name: "Speaker A")])
        popover.update(devices: [local(), bt("bt-a:output", name: "Speaker A")])
        popover.test_deviceRow(for: "bt-a:output")?.test_clickName()   // select
        #expect(controller.selectedDeviceIDs.contains("bt-a:output"))

        // Loss: off = unselected, truthfully.
        popover.update(devices: [local(), bt("bt-a:output", name: "Speaker A", available: false)])
        #expect(!controller.selectedDeviceIDs.contains("bt-a:output"),
                "availability loss deselects — the row reads what's true")
        #expect(popover.test_deviceRow(for: "bt-a:output") == nil,
                "BT-LIST: delisted, not greyed — deselect and delist are the same edge now")

        // Return: available, still unselected, NOT playing.
        popover.update(devices: [local(), bt("bt-a:output", name: "Speaker A")])
        #expect(!controller.selectedDeviceIDs.contains("bt-a:output"),
                "a return never auto-resumes — selecting again is the user's move")

        // The user's select-after-return plays (greyed-select semantics stay:
        // selection intact through a later loss-free connect auto-starts).
        popover.test_deviceRow(for: "bt-a:output")?.test_clickName()
        #expect(controller.selectedDeviceIDs.contains("bt-a:output"))
    }

    /// The edge-only guard: a selection made ON an already-greyed row ("play
    /// when up") has no loss edge, so it SURVIVES repaints while the device is
    /// still away — that deliberate intent is what auto-starts on connect.
    /// BT-LIST: this greyed-select entry point now only exists for IN-MIX rows
    /// (`wantsAudio`/`isMainOutMember` keep `isBluetoothRowListed` true) — the
    /// row stays on screen the whole time, never delisted mid-selection.
    @Test func selectionMadeOnAGreyedRowSurvivesWhileStillUnavailable() {
        let (popover, controller, _) = makePopover(fleet: [local(), bt("bt-a:output", name: "Speaker A")])
        popover.update(devices: [local(), bt("bt-a:output", name: "Speaker A", available: false)])
        _ = popover.test_toggleDeviceEnabled(deviceID: "bt-a:output", on: true)   // "play when up"
        #expect(controller.selectedDeviceIDs.contains("bt-a:output"))

        popover.update(devices: [local(), bt("bt-a:output", name: "Speaker A", available: false)])
        #expect(controller.selectedDeviceIDs.contains("bt-a:output"),
                "no availability EDGE ⇒ the held intent survives every repaint")
        #expect(popover.test_deviceRow(for: "bt-a:output") != nil,
                "in-mix keeps the row even while unavailable")
    }

    // MARK: Greyed-row click keeps membership honest end-to-end

    @Test func greyedBTRowClickNeverEditsSelection() {
        let (popover, controller, _) = makePopover(fleet: [local(), bt("bt-a:output", name: "Speaker A")])
        // BT-LIST: a greyed row only renders while the user still intends audio
        // on it — here, in the mix "play when up" — since a plain unselected/
        // unavailable BT device has no row at all any more (a sticky `.failed`
        // does NOT list one either; see `isBluetoothRowListed`).
        popover.update(devices: [local(), bt("bt-a:output", name: "Speaker A", available: false)])
        _ = popover.test_toggleDeviceEnabled(deviceID: "bt-a:output", on: true)
        popover.update(devices: [local(), bt("bt-a:output", name: "Speaker A", available: false)])
        #expect(popover.test_deviceRow(for: "bt-a:output") != nil,
                "the select must have remounted the row, or this test checks nothing")
        popover.test_deviceRow(for: "bt-a:output")?.test_clickName()
        #expect(controller.selectedDeviceIDs.contains("bt-a:output"),
                "click-connects is membership-free (requestReconnect, never setDeviceSelected)")

        // An AVAILABLE BT row's click selects — exactly like AirPlay rows. The
        // checkbox (not the click under test) clears the held intent first.
        _ = popover.test_toggleDeviceEnabled(deviceID: "bt-a:output", on: false)
        popover.update(devices: [local(), bt("bt-a:output", name: "Speaker A", available: true)])
        popover.test_deviceRow(for: "bt-a:output")?.test_clickName()
        #expect(controller.selectedDeviceIDs.contains("bt-a:output"))
    }
}

/// The SYNC drawer accordion (PLAN-BT-SYNC-DRAWER T7): one drawer at a time,
/// mounted directly under its row, auto-collapsing with its device, and the
/// live-scrub / committed-edit split that keeps a drag off the JSON store.
@MainActor
@Suite(.serialized) struct BTSyncDrawerAccordionTests {

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

    private func airplay(_ id: String = "office") -> Device {
        Device(id: id, name: "Office", kind: .homePod)
    }

    private func bt(_ id: String, name: String, available: Bool = true) -> Device {
        Device(id: id, name: name, kind: .bluetooth,
               isAvailable: available, supportsAirPlay2: false)
    }

    /// Every `BTSyncDrawerView` anywhere in the popover's view tree — the only
    /// way to prove D2 ("at most one") rather than merely trusting the model
    /// flag.
    private func mountedDrawers(_ popover: PopoverController, reachableFrom id: String)
        -> [BTSyncDrawerView] {
        var root: NSView? = popover.test_deviceRow(for: id)
        while let parent = root?.superview { root = parent }
        guard let root else { return [] }
        func collect(_ view: NSView) -> [BTSyncDrawerView] {
            if let drawer = view as? BTSyncDrawerView { return [drawer] }
            return view.subviews.flatMap(collect)
        }
        return collect(root)
    }

    /// Whether the mounted drawer sits in the very next stack slot after its
    /// row (D1 — it opens in place, under the row it belongs to). An inserted
    /// row lives inside its own reveal clip, and the clip is what the stack
    /// arranges.
    private func drawerFollowsRow(_ popover: PopoverController, _ id: String) -> Bool {
        guard let row = popover.test_deviceRow(for: id),
              let clip = popover.test_syncDrawer?.superview,
              let stack = row.superview as? NSStackView,
              let rowIndex = stack.arrangedSubviews.firstIndex(of: row),
              let drawerIndex = stack.arrangedSubviews.firstIndex(of: clip)
        else { return false }
        return drawerIndex == rowIndex + 1
    }

    // MARK: The chip is really wired (the seam trap)

    /// `test_*` hooks here bypass AppKit dispatch and have hidden real breaks
    /// before, so this one goes through the chip's own target/action.
    @Test func chipClickOpensAndClosesTheDrawerThroughItsRealAction() {
        let (popover, _) = makePopover()
        popover.update(devices: [local(), bt("bt-a:output", name: "Speaker A")])

        popover.test_deviceRow(for: "bt-a:output")?.test_fireSyncChipClick()
        #expect(popover.test_expandedSyncDeviceID == "bt-a:output")
        #expect(popover.test_syncDrawerVisible)
        #expect(popover.test_deviceRow(for: "bt-a:output")?.test_syncChipIsEngaged == true)

        popover.test_deviceRow(for: "bt-a:output")?.test_fireSyncChipClick()
        #expect(popover.test_expandedSyncDeviceID == nil, "a second click closes it")
        #expect(!popover.test_syncDrawerVisible)
    }

    // MARK: D2 — one drawer at a time

    @Test func openingASecondDrawerLeavesExactlyOneAttachedToTheNewRow() {
        let (popover, _) = makePopover()
        popover.update(devices: [local(),
                                 bt("bt-a:output", name: "Speaker A"),
                                 bt("bt-b:output", name: "Speaker B")])

        popover.test_toggleSyncDrawer(deviceID: "bt-a:output")
        #expect(drawerFollowsRow(popover, "bt-a:output"))

        popover.test_toggleSyncDrawer(deviceID: "bt-b:output")
        #expect(popover.test_expandedSyncDeviceID == "bt-b:output")
        #expect(mountedDrawers(popover, reachableFrom: "bt-a:output").count == 1,
                "opening B while A is open leaves exactly ONE drawer")
        #expect(drawerFollowsRow(popover, "bt-b:output"), "…attached to B")
        #expect(popover.test_deviceRow(for: "bt-a:output")?.test_syncChipIsEngaged == false)
        #expect(popover.test_deviceRow(for: "bt-b:output")?.test_syncChipIsEngaged == true)
    }

    // MARK: Auto-collapse

    @Test func drawerCollapsesWhenItsDeviceIsDeselected() {
        let (popover, controller) = makePopover(fleet: [local(), bt("bt-a:output", name: "Speaker A")])
        popover.update(devices: [local(), bt("bt-a:output", name: "Speaker A")])
        popover.test_deviceRow(for: "bt-a:output")?.test_clickName()   // select
        #expect(controller.selectedDeviceIDs.contains("bt-a:output"))

        popover.test_toggleSyncDrawer(deviceID: "bt-a:output")
        #expect(popover.test_syncDrawerVisible)

        popover.test_deviceRow(for: "bt-a:output")?.test_clickName()   // deselect
        popover.update(devices: [local(), bt("bt-a:output", name: "Speaker A")])
        #expect(popover.test_expandedSyncDeviceID == nil, "out of the mix ⇒ no drawer")
        #expect(!popover.test_syncDrawerVisible)
    }

    /// A drawer opened on an available-but-UNSELECTED row (tuning a speaker
    /// before adding it to the mix) has no selection to lose, so it survives
    /// repaints — the collapse above is an EDGE, not a standing requirement.
    @Test func drawerOpenedOnAnUnselectedRowSurvivesRepaints() {
        let (popover, _) = makePopover()
        let devices = [local(), bt("bt-a:output", name: "Speaker A")]
        popover.update(devices: devices)
        popover.test_toggleSyncDrawer(deviceID: "bt-a:output")

        popover.update(devices: devices)
        #expect(popover.test_expandedSyncDeviceID == "bt-a:output")
        #expect(popover.test_syncDrawerVisible)
    }

    @Test func drawerCollapsesWhenItsRowDisappearsOrGoesUnavailable() {
        let (popover, _) = makePopover()
        popover.update(devices: [local(), bt("bt-a:output", name: "Speaker A")])
        popover.test_toggleSyncDrawer(deviceID: "bt-a:output")
        #expect(popover.test_syncDrawerVisible)

        popover.update(devices: [local(), bt("bt-a:output", name: "Speaker A", available: false)])
        #expect(popover.test_expandedSyncDeviceID == nil, "an unavailable row has nothing to tune")

        popover.test_toggleSyncDrawer(deviceID: "bt-a:output")
        popover.update(devices: [local(), bt("bt-a:output", name: "Speaker A")])
        popover.test_toggleSyncDrawer(deviceID: "bt-a:output")
        #expect(popover.test_syncDrawerVisible)

        popover.update(devices: [local()])            // the device vanishes entirely
        #expect(popover.test_expandedSyncDeviceID == nil)
        #expect(!popover.test_syncDrawerVisible)
    }

    @Test func popoverCloseCollapsesTheDrawer() {
        let (popover, _) = makePopover()
        popover.update(devices: [local(), bt("bt-a:output", name: "Speaker A")])
        popover.test_toggleSyncDrawer(deviceID: "bt-a:output")

        popover.surfaceDidHide()
        #expect(popover.test_expandedSyncDeviceID == nil)
        #expect(!popover.test_syncDrawerVisible)
    }

    // MARK: Stepper commits persist, and the chip tracks them (T7 §4)

    @Test func eachStepperClickAppliesAndPersistsAndTheChipTracksIt() {
        let (popover, _) = makePopover()
        var applied: [(ms: Double, persist: Bool)] = []
        popover.onSetBTTrim = { ms, _, persist in applied.append((ms, persist)) }
        popover.update(devices: [local(), bt("bt-a:output", name: "Speaker A")])
        popover.test_toggleSyncDrawer(deviceID: "bt-a:output")

        // Three coarse (⇧) clicks: each is a complete gesture, so each applies
        // AND persists (the scrubbing ruler and its apply-without-persist path
        // were cut — every change the drawer now makes is discrete).
        popover.test_syncDrawer!.test_shiftModifierOverride = true
        popover.test_syncDrawer!.test_firePlusClick()
        popover.test_syncDrawer!.test_firePlusClick()
        popover.test_syncDrawer!.test_firePlusClick()
        #expect(applied.count == 3)
        #expect(applied.allSatisfy { $0.persist }, "a stepper click always writes the store")
        #expect(applied.map(\.ms) == [10, 20, 30])
        #expect(popover.test_deviceRow(for: "bt-a:output")?.test_syncChipTitle == "30 ms",
                "the chip tracks each committed step")
    }

    /// T7 §7: every value that reaches the host is quantised to whole ms, so
    /// the chip, the field and the persisted value can never disagree.
    @Test func committedTrimsAreQuantisedToWholeMilliseconds() {
        let (popover, _) = makePopover()
        var applied: [Double] = []
        popover.onSetBTTrim = { ms, _, _ in applied.append(ms) }
        popover.update(devices: [local(), bt("bt-a:output", name: "Speaker A")])
        popover.test_toggleSyncDrawer(deviceID: "bt-a:output")

        popover.syncDrawer(popover.test_syncDrawer!, didChangeTrimMs: 22.4, committed: true)
        popover.syncDrawer(popover.test_syncDrawer!, didChangeTrimMs: 22.6, committed: true)
        #expect(applied == [22, 23])
    }

    // MARK: Geometry + range

    @Test func popoverGrowsByTheDrawerHeightAndReturnsExactlyOnCollapse() {
        let (popover, _) = makePopover()
        popover.update(devices: [local(), bt("bt-a:output", name: "Speaker A")])
        let collapsed = popover.test_panelContentHeight

        popover.test_toggleSyncDrawer(deviceID: "bt-a:output")
        #expect(popover.test_panelContentHeight
                == collapsed + PopoverColumnGrid.syncDrawerHeight)

        popover.test_toggleSyncDrawer(deviceID: "bt-a:output")
        #expect(popover.test_panelContentHeight == collapsed, "…and returns exactly")
    }

    /// T3's trap: the usable range moves when AirPlay joins or leaves the
    /// group, so an OPEN drawer must re-read it on every snapshot.
    @Test func openDrawerReReadsTheUsableRangeOnEveryUpdate() {
        let (popover, _) = makePopover()
        var floor: Double = -100
        popover.btTrimRangeProvider = { _ in floor...BTSyncTrim.rangeMs }
        popover.update(devices: [local(), bt("bt-a:output", name: "Speaker A")])
        popover.test_toggleSyncDrawer(deviceID: "bt-a:output")
        #expect(popover.test_syncDrawer?.test_usableRangeMs.lowerBound == -100)

        floor = -420
        popover.update(devices: [local(), bt("bt-a:output", name: "Speaker A")])
        #expect(popover.test_syncDrawer?.test_usableRangeMs.lowerBound == -420,
                "the range is never cached at open time")
    }

    // MARK: AirPlay rows are untouched

    @Test func airPlayRowsExposeNeitherChipNorDrawer() {
        let (popover, _) = makePopover()
        popover.update(devices: [local(), airplay(), bt("bt-a:output", name: "Speaker A")])

        let airplayRow = popover.test_deviceRow(for: "office")
        #expect(airplayRow?.test_showsSyncControls == false)
        #expect(airplayRow?.test_syncChipTitle == nil)

        popover.test_toggleSyncDrawer(deviceID: "office")
        #expect(popover.test_expandedSyncDeviceID == nil,
                "a non-Bluetooth row can never carry a drawer")
        #expect(!popover.test_syncDrawerVisible)
    }
}
