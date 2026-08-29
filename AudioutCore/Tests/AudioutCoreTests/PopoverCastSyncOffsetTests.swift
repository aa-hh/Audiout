// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import AppKit
@testable import AudioutCore
@testable import AudioutPopoverUI
@testable import AudioutSharedUI

/// CAST-SYNC at the popover level: a Cast row carries the SAME SYNC surface a
/// Bluetooth row does — chip and drawer — over its own store and its own wider
/// range, and carries NO alignment wizard. Every interaction rides real
/// dispatch (`performClick` / the control's own target/action), never a state
/// poke.
@MainActor
@Suite(.serialized) struct PopoverCastSyncOffsetTests {

    private final class Recorder {
        var castSets: [(ms: Double, id: String)] = []
        var castResets: [String] = []
        var btSets: [(ms: Double, id: String)] = []
    }

    private func cast(_ id: String = "cast-tv", name: String = "Living Room TV") -> Device {
        Device(id: id, name: name, kind: .cast)
    }

    private func airplay(_ id: String = "office", name: String = "Office") -> Device {
        Device(id: id, name: name, kind: .homePod)
    }

    private func local() -> Device {
        Device(id: "mac", name: "This Mac", kind: .localMac, isLocalDevice: true)
    }

    private func tempDirectory(_ isolation: TestIsolation) -> URL {
        isolation.scratchDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    /// The popover over a started `MockBackend` fleet with the Cast closures
    /// wired the way `AppDelegate` wires them, backed by a plain dictionary
    /// standing in for the store.
    private func makePopover(_ isolation: TestIsolation, storedOffsets: [String: Double] = [:])
        -> (PopoverController, Recorder, () -> [String: Double]) {
        let fleet = [local(), airplay(), cast()]
        let backend = MockBackend(fleet: fleet, staggerDiscovery: false,
                                  emitsLevels: false, simulatesDropouts: false)
        let controller = GroupController(backend: backend,
                                         store: GroupStore(directory: tempDirectory(isolation)),
                                         routingStore: RoutingStore(directory: tempDirectory(isolation)),
                                         loadPersisted: false)
        let popover = PopoverController()
        popover.configure(groupController: controller)
        popover.test_isShownOverride = true
        backend.start()
        waitFor { backend.devices.count == fleet.count }

        let recorder = Recorder()
        // Seeded BEFORE the first `update(devices:)`: the popover caches each
        // row's value on its first paint (freshest-edit-wins), so a later write
        // behind its back would not be read again.
        let store = StoreBox(storedOffsets)
        popover.castOffsetProvider = { store.values[$0] ?? 0 }
        popover.castOffsetIsSetProvider = { store.values[$0] != nil }
        popover.onSetCastOffset = { ms, id in
            store.values[id] = ms
            recorder.castSets.append((ms, id))
        }
        popover.onResetCastOffset = { id in
            store.values.removeValue(forKey: id)
            recorder.castResets.append(id)
        }
        popover.onSetBTTrim = { ms, id, _ in recorder.btSets.append((ms, id)) }
        popover.update(devices: fleet)
        return (popover, recorder, { store.values })
    }

    /// Reference box so the closures above share one mutable dictionary.
    private final class StoreBox {
        var values: [String: Double]
        init(_ values: [String: Double]) { self.values = values }
    }

    private func waitFor(timeout: TimeInterval? = nil,
                     sourceLocation: SourceLocation = #_sourceLocation,
                     _ cond: @escaping () -> Bool) {
        SuiteWait.untilOnRunLoop(timeout: timeout, sourceLocation: sourceLocation, cond)
    }

    // MARK: The chip

    @Test func aCastRowCarriesTheSyncChip() {
        let isolation = TestIsolation(owner: "PopoverCastSyncOffsetTests")
        let (popover, _, _) = makePopover(isolation, storedOffsets: ["cast-tv": -180])

        let row = popover.test_deviceRow(for: "cast-tv")
        #expect(row?.test_showsSyncControls == true)
        #expect(row?.test_syncChipTitle == "−180 ms")
        #expect(row?.test_syncChipIsDashed == false, "an explicit value is tuned")

        #expect(popover.test_deviceRow(for: "office")?.test_syncChipTitle == nil,
                "AirPlay rows still carry no trim (locked Decision 1)")
    }

    @Test func anUntunedCastRowReadsNotSet() {
        let isolation = TestIsolation(owner: "PopoverCastSyncOffsetTests")
        let (popover, _, _) = makePopover(isolation)
        let row = popover.test_deviceRow(for: "cast-tv")
        #expect(row?.test_syncChipTitle == "Not set")
        #expect(row?.test_syncChipIsDashed == true)
        #expect(row?.test_syncChipTooltip?.contains(DeviceRowView.castSyncHelpCopy) == true,
                "the chip is the only place that says what the dial is FOR")
    }

    @Test func theSyncColumnTitleRendersOverTheCastSubsection() {
        let isolation = TestIsolation(owner: "PopoverCastSyncOffsetTests")
        let (popover, _, _) = makePopover(isolation)
        #expect(popover.test_syncColumnTitleShown(in: "Cast Devices"))
        #expect(!popover.test_syncColumnTitleShown(in: "AirPlay Devices"))
    }

    // MARK: The drawer

    @Test func theDrawerOpensOnACastRowAndAStepperEditReachesTheCastStore() {
        let isolation = TestIsolation(owner: "PopoverCastSyncOffsetTests")
        let (popover, recorder, values) = makePopover(isolation, storedOffsets: ["cast-tv": 20])

        popover.test_deviceRow(for: "cast-tv")?.test_fireSyncChipClick()
        let drawer = popover.test_syncDrawer
        #expect(drawer != nil, "the chip opens the same drawer a BT row uses")
        #expect(drawer?.superview != nil, "…mounted under the row")

        drawer?.test_firePlusClick()
        #expect(recorder.castSets.count == 1, "one committed gesture, one apply")
        #expect(recorder.castSets.first?.id == "cast-tv")
        #expect(values()["cast-tv"] == recorder.castSets[0].ms)
        #expect((values()["cast-tv"] ?? 0) > 20, "…and plus raises the delay")
        #expect(recorder.btSets.isEmpty, "the Bluetooth store is not involved")
    }

    @Test func theCastRowsUsableRangeIsTheWiderCastRange() {
        let isolation = TestIsolation(owner: "PopoverCastSyncOffsetTests")
        let (popover, _, _) = makePopover(isolation)
        // A BT range provider that would clamp hard if it were ever consulted
        // for a Cast row.
        popover.btTrimRangeProvider = { _ in 0...1 }
        popover.test_deviceRow(for: "cast-tv")?.test_fireSyncChipClick()
        #expect(popover.test_syncDrawer?.test_usableRangeMs
                == -BTSyncTrim.castRangeMs...BTSyncTrim.castRangeMs)
        #expect(BTSyncTrim.castRangeMs == 1000,
                "a TV feeding a soundbar over ARC can pass 400 ms; ±500 would not cover it")
    }

    /// The whole point of the wider range: a value past the Bluetooth bound has
    /// to survive the commit, the store, and the row's own repaint.
    @Test func anOffsetPastTheBluetoothBoundSurvivesTheRoundTrip() {
        let isolation = TestIsolation(owner: "PopoverCastSyncOffsetTests")
        let (popover, recorder, values) = makePopover(isolation)

        popover.test_deviceRow(for: "cast-tv")?.test_fireSyncChipClick()
        let drawer = popover.test_syncDrawer
        drawer?.test_valueFieldEditor.test_setFieldText("800")
        drawer?.test_valueFieldEditor.test_performCommand(#selector(NSResponder.insertNewline(_:)))

        #expect(recorder.castSets.last?.ms == 800)
        #expect(values()["cast-tv"] == 800)
        #expect(popover.test_deviceRow(for: "cast-tv")?.test_syncChipTitle == "800 ms",
                "the chip prints the value, not the Bluetooth clamp")
    }

    // MARK: Reset

    @Test func resetDeletesTheStoredOffsetAndPutsTheRowBackOnNotSet() {
        let isolation = TestIsolation(owner: "PopoverCastSyncOffsetTests")
        let (popover, recorder, values) = makePopover(isolation, storedOffsets: ["cast-tv": -180])

        popover.test_deviceRow(for: "cast-tv")?.test_fireSyncChipClick()
        let drawer = popover.test_syncDrawer
        #expect(drawer?.test_resetVisible == true, "a tuned receiver has something to clear")

        drawer?.test_fireResetClick()
        #expect(recorder.castResets == ["cast-tv"])
        #expect(values()["cast-tv"] == nil, "the entry is DELETED, not written as 0")
        #expect(recorder.castSets.isEmpty, "a reset is never a committed offset")
        let row = popover.test_deviceRow(for: "cast-tv")
        #expect(row?.test_syncChipTitle == "Not set")
        #expect(row?.test_syncChipIsDashed == true)
    }

    @Test func resetIsNotOfferedOnAReceiverThatWasNeverTuned() {
        let isolation = TestIsolation(owner: "PopoverCastSyncOffsetTests")
        let (popover, _, _) = makePopover(isolation)
        popover.test_deviceRow(for: "cast-tv")?.test_fireSyncChipClick()
        #expect(popover.test_syncDrawer?.test_resetVisible == false)
    }

    // MARK: No wizard on a Cast row

    @Test func aCastRowOffersNoAlignSpeakerMenuItem() {
        let isolation = TestIsolation(owner: "PopoverCastSyncOffsetTests")
        let (popover, _, _) = makePopover(isolation)
        let titles = popover.test_deviceRow(for: "cast-tv")?.test_contextMenu()?
            .items.map(\.title) ?? []
        #expect(!titles.contains("Align speaker…"),
                "a Cast receiver plays seconds behind live; no ±500 ms bisection reaches it")
        #expect(titles.contains("Equalizer…"), "…but tone is unaffected")
    }

    @Test func theDrawersOptionClickWizardDoorIsRefusedForCast() {
        let isolation = TestIsolation(owner: "PopoverCastSyncOffsetTests")
        let (popover, _, _) = makePopover(isolation)
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        _ = popover.test_toggleDeviceEnabled(deviceID: "cast-tv", on: true)

        popover.test_deviceRow(for: "cast-tv")?.test_fireSyncChipClick()
        let drawer = popover.test_syncDrawer
        drawer?.test_optionModifierOverride = true
        drawer?.test_fireAlignClick()

        #expect(popover.test_btWizardView() == nil,
                "the hidden ⌥ door is refused too, not just the visible menu item")
    }
}
