// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import AppKit
@testable import AudiouterCore
@testable import AudiouterPopoverUI
@testable import AudiouterSharedUI

/// BT-UI row behavior on `DeviceRowView` itself: the greyed-row
/// click-connects branch, the reconnect node vocabulary, the failure-headline
/// FEED pill, and the SYNC cluster's real-dispatch stepper/typing/align paths
/// (this repo was bitten by test hooks bypassing AppKit dispatch — every
/// interaction here rides `performClick`/the control's own target/action).
@MainActor
@Suite final class BTDeviceRowTests: IsolatedSuite {

    private final class SpyDelegate: DeviceRowView.Delegate {
        var toggles: [(on: Bool, id: String)] = []
        var reconnects: [String] = []
        var trims: [(ms: Int, id: String)] = []
        var alignToggles: [(active: Bool, id: String)] = []
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
        func deviceRow(_ row: DeviceRowView, didSetSyncTrimMs ms: Int, for id: String) {
            trims.append((ms, id))
        }
        func deviceRow(_ row: DeviceRowView, didToggleAlignTick active: Bool, for id: String) {
            alignToggles.append((active, id))
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

    /// The popover's real BT row shape: bus + meter + SYNC cluster.
    private func makeRow(_ device: Device, delegate: SpyDelegate,
                         syncTrimMs: Int = 0, alignTickActive: Bool = false,
                         selected: Bool = false) -> DeviceRowView {
        let row = DeviceRowView(device: device, showsToggle: true,
                                paintsSelectionBackground: false, showsMeter: true,
                                showsBus: true, showsSyncControls: true)
        row.delegate = delegate
        row.apply(device, selected: selected, controllable: selected,
                  syncTrimMs: syncTrimMs, alignTickActive: alignTickActive)
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

    // MARK: SYNC cluster — real dispatch

    @Test func stepperStepsByTenAndClampsAtTheRange() {
        let spy = SpyDelegate()
        let row = makeRow(btDevice(), delegate: spy, syncTrimMs: 0)
        row.test_fireSyncPlusClick()
        row.test_fireSyncPlusClick()
        row.test_fireSyncMinusClick()
        #expect(spy.trims.map(\.ms) == [10, 20, 10], "− / + move in coarse 10 ms steps")
        #expect(row.test_syncTrimDisplayed == "10")

        let ceiling = makeRow(btDevice(), delegate: spy, syncTrimMs: 495)
        ceiling.test_fireSyncPlusClick()
        #expect(spy.trims.last?.ms == 500, "clamped at +\(BTSyncTrim.rangeMs)")
        ceiling.test_fireSyncPlusClick()
        #expect(spy.trims.last?.ms == 500)
        #expect(ceiling.test_syncTrimDisplayed == "500")
    }

    @Test func typingCommitsAtOneMillisecondAndClampsAndReverts() {
        let spy = SpyDelegate()
        let row = makeRow(btDevice(), delegate: spy, syncTrimMs: 0)
        row.test_commitSyncField("37")
        #expect(spy.trims.last?.ms == 37, "typing allows 1 ms precision")
        row.test_commitSyncField("-1000")
        #expect(spy.trims.last?.ms == -500, "typed values clamp to the range")
        row.test_commitSyncField("abc")
        #expect(spy.trims.last?.ms == -500, "unparseable input reverts to the current value")
        #expect(row.test_syncTrimDisplayed == "-500")
    }

    @Test func optionClickOnTheSteppersStepsOneMillisecond() {
        let spy = SpyDelegate()
        let row = makeRow(btDevice(), delegate: spy, syncTrimMs: 0)
        row.test_optionModifierOverride = true
        row.test_fireSyncPlusClick()
        #expect(spy.trims.last?.ms == 1, "⌥-click steps fine (1 ms)")
        row.test_fireSyncMinusClick()
        #expect(spy.trims.last?.ms == 0)
        row.test_optionModifierOverride = false
        row.test_fireSyncPlusClick()
        #expect(spy.trims.last?.ms == 10, "a plain click keeps the coarse 10 ms step")
    }

    @Test func returnCommitsAndIsConsumedAndFocusLossCommitsToo() {
        let spy = SpyDelegate()
        let row = makeRow(btDevice(), delegate: spy, syncTrimMs: 0)
        row.test_setSyncFieldText("42")
        let consumed = row.test_performSyncFieldCommand(#selector(NSResponder.insertNewline(_:)))
        #expect(consumed, "Return is CONSUMED — it must never bubble past the field and close the popover")
        #expect(spy.trims.last?.ms == 42, "…and it COMMITS the typed value")

        row.test_setSyncFieldText("77")
        row.test_endSyncFieldEditing()
        #expect(spy.trims.last?.ms == 77, "focus loss commits the typed value too")
        #expect(row.test_syncTrimDisplayed == "77")

        row.test_setSyncFieldText("9999")
        row.test_performSyncFieldCommand(#selector(NSResponder.insertNewline(_:)))
        #expect(spy.trims.last?.ms == 500, "a Return-committed value still clamps")
    }

    @Test func arrowKeysNudgeOneMillisecondOptionArrowsTen() {
        let spy = SpyDelegate()
        let row = makeRow(btDevice(), delegate: spy, syncTrimMs: 0)
        row.test_optionModifierOverride = false
        row.test_performSyncFieldCommand(#selector(NSResponder.moveUp(_:)))
        #expect(spy.trims.last?.ms == 1, "↑ nudges fine — the by-ear granularity")
        row.test_performSyncFieldCommand(#selector(NSResponder.moveDown(_:)))
        #expect(spy.trims.last?.ms == 0)
        row.test_performSyncFieldCommand(Selector(("moveToBeginningOfParagraph:")))
        #expect(spy.trims.last?.ms == 10, "⌥↑ arrives as the paragraph binding and nudges coarse")
        row.test_performSyncFieldCommand(Selector(("moveToEndOfParagraph:")))
        #expect(spy.trims.last?.ms == 0, "⌥↓ likewise")

        let ceiling = makeRow(btDevice(), delegate: spy, syncTrimMs: 500)
        ceiling.test_optionModifierOverride = false
        ceiling.test_performSyncFieldCommand(#selector(NSResponder.moveUp(_:)))
        #expect(spy.trims.last?.ms == 500, "the clamp holds under arrow nudges")
    }

    @Test func disconnectedRowShowsTheSavedTrimReadOnly() {
        let spy = SpyDelegate()
        let row = makeRow(btDevice(available: false), delegate: spy, syncTrimMs: -120)
        #expect(row.test_syncTrimDisplayed == "-120", "the saved value stays visible")
        #expect(!row.test_syncControlsEnabled)
        row.test_fireSyncPlusClick()   // disabled button — a real click is a no-op
        row.test_fireSyncMinusClick()
        #expect(spy.trims.isEmpty, "no edits reach the delegate while disconnected")
    }

    @Test func alignButtonUsesTheFilledMetronomeWithTooltipAndRealDispatch() {
        let spy = SpyDelegate()
        let row = makeRow(btDevice(), delegate: spy)
        #expect(row.test_alignSymbolName == "metronome.fill",
                "the fill variant resolved (outline `metronome` is only the fallback)")
        #expect(row.test_alignTooltip?.contains("alignment ticks") == true,
                "the bare glyph explains itself on hover")
        row.test_fireAlignClick()
        #expect(spy.alignToggles.map(\.active) == [true])
        #expect(row.test_alignTickOn)
        row.test_fireAlignClick()
        #expect(spy.alignToggles.map(\.active) == [true, false])
    }

    @Test func optionClickOnTheMetronomeRequestsTheWizardNotTheTick() {
        let spy = SpyDelegate()
        let row = makeRow(btDevice(), delegate: spy)
        row.test_optionModifierOverride = true
        row.test_fireAlignClick()
        #expect(spy.wizardRequests == [btDevice().id], "⌥-click asks for the guided wizard")
        #expect(spy.alignToggles.isEmpty, "…never the manual tick")
        #expect(!row.test_alignTickOn, "and the toggle never flips")
        #expect(row.test_alignTooltip?.contains("⌥ for the guided alignment") == true,
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

    private func bt(_ id: String, name: String, available: Bool = true) -> Device {
        Device(id: id, name: name, kind: .bluetooth,
               isAvailable: available, supportsAirPlay2: false)
    }

    // MARK: Subsection — hide-when-empty + recency sort

    @Test func bluetoothSubsectionIsHiddenWhenNoBTDeviceExists() {
        let (popover, _, _) = makePopover()
        popover.update(devices: [local(), airplay()])
        #expect(popover.test_subsectionTitles() == ["This Mac", "AirPlay Devices"])
        #expect(popover.test_bluetoothRowOrder().isEmpty)
    }

    @Test func bluetoothSubsectionRendersAfterAirPlaySortedByRecency() {
        let (popover, _, _) = makePopover()
        let now = Date()
        popover.btLastUsedProvider = {
            ["bt-old:output": now.addingTimeInterval(-86_400 * 400),
             "bt-new:output": now]
            // "bt-ghost:output" has no recency at all — the deadest pairing.
        }
        popover.update(devices: [
            local(), airplay(),
            bt("bt-ghost:output", name: "Ancient Speaker", available: false),
            bt("bt-new:output", name: "Zed Speaker"),
            bt("bt-old:output", name: "Attic Speaker", available: false),
        ])
        #expect(popover.test_subsectionTitles()
                == ["This Mac", "AirPlay Devices", "Bluetooth Devices"])
        #expect(popover.test_bluetoothRowOrder()
                == ["bt-new:output", "bt-old:output", "bt-ghost:output"],
                "most recent first; a pairing with no recency sinks to the bottom")
        #expect(popover.test_deviceRow(for: "bt-new:output")?.test_showsSyncControls == true,
                "BT rows mount the SYNC cluster")
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

    // MARK: SYNC plumbing — cache, closures, clamping

    @Test func trimEditsFlowThroughTheClosureAndSurviveRepaints() {
        let (popover, _, _) = makePopover()
        var written: [(ms: Int, id: String)] = []
        popover.btTrimProvider = { _ in 120 }
        popover.onSetBTTrim = { ms, id in written.append((ms, id)) }
        let devices = [local(), bt("bt-a:output", name: "Speaker A")]
        popover.update(devices: devices)

        let row = popover.test_deviceRow(for: "bt-a:output")
        #expect(row?.test_syncTrimDisplayed == "120", "rows seed from the persisted trim")

        row?.test_fireSyncPlusClick()
        #expect(written.last?.ms == 130)
        #expect(written.last?.id == "bt-a:output")

        // A repaint keeps the freshest edit — the cache outranks the provider.
        popover.update(devices: devices)
        #expect(popover.test_deviceRow(for: "bt-a:output")?.test_syncTrimDisplayed == "130")
    }

    @Test func disconnectedRowShowsPersistedTrimReadOnly() {
        let (popover, _, _) = makePopover()
        popover.btTrimProvider = { _ in -50 }
        popover.update(devices: [local(), bt("bt-a:output", name: "Speaker A", available: false)])
        let row = popover.test_deviceRow(for: "bt-a:output")
        #expect(row?.test_syncTrimDisplayed == "-50")
        #expect(row?.test_syncControlsEnabled == false)
    }

    // MARK: Align tick lifecycle — one at a time, stops on close

    @Test func alignTickIsOneAtATimeAndStopsWhenThePopoverCloses() {
        let (popover, _, _) = makePopover()
        var gates: [Bool] = []
        popover.onAlignTickActiveChange = { gates.append($0) }
        popover.update(devices: [
            local(),
            bt("bt-a:output", name: "Speaker A"),
            bt("bt-b:output", name: "Speaker B"),
        ])

        popover.test_deviceRow(for: "bt-a:output")?.test_fireAlignClick()
        #expect(popover.test_alignTickDeviceID() == "bt-a:output")
        #expect(gates.last == true)
        #expect(popover.test_deviceRow(for: "bt-a:output")?.test_alignTickOn == true)

        popover.test_deviceRow(for: "bt-b:output")?.test_fireAlignClick()
        #expect(popover.test_alignTickDeviceID() == "bt-b:output", "the single tick MOVES")
        #expect(popover.test_deviceRow(for: "bt-a:output")?.test_alignTickOn == false,
                "the previous row's button drops on the re-apply")

        popover.popoverDidClose(Notification(name: NSPopover.didCloseNotification))
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
        #expect(popover.test_deviceRow(for: "bt-a:output")?.test_isEnabledOn == false)

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
    @Test func selectionMadeOnAGreyedRowSurvivesWhileStillUnavailable() {
        let (popover, controller, _) = makePopover(fleet: [local(), bt("bt-a:output", name: "Speaker A")])
        popover.update(devices: [local(), bt("bt-a:output", name: "Speaker A", available: false)])
        _ = popover.test_toggleDeviceEnabled(deviceID: "bt-a:output", on: true)   // "play when up"
        #expect(controller.selectedDeviceIDs.contains("bt-a:output"))

        popover.update(devices: [local(), bt("bt-a:output", name: "Speaker A", available: false)])
        #expect(controller.selectedDeviceIDs.contains("bt-a:output"),
                "no availability EDGE ⇒ the held intent survives every repaint")
    }

    // MARK: Greyed-row click keeps membership honest end-to-end

    @Test func greyedBTRowClickNeverEditsSelection() {
        let (popover, controller, _) = makePopover(fleet: [local(), bt("bt-a:output", name: "Speaker A")])
        popover.update(devices: [local(), bt("bt-a:output", name: "Speaker A", available: false)])
        popover.test_deviceRow(for: "bt-a:output")?.test_clickName()
        #expect(!controller.selectedDeviceIDs.contains("bt-a:output"),
                "click-connects is membership-free (requestReconnect, never setDeviceSelected)")

        // An AVAILABLE BT row's click selects — exactly like AirPlay rows.
        popover.update(devices: [local(), bt("bt-a:output", name: "Speaker A", available: true)])
        popover.test_deviceRow(for: "bt-a:output")?.test_clickName()
        #expect(controller.selectedDeviceIDs.contains("bt-a:output"))
    }
}
