// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import AppKit
@testable import AudioutCore
@testable import AudioutPopoverUI
@testable import AudioutSharedUI

/// Roadmap 056 Part 1 at the popover level: the Mac's own row carries the SAME
/// SYNC surface a Bluetooth row does — chip, drawer, stepper round-trip into
/// `AppSettings.syncOffsetMs`, and the alignment wizard driving the LOCAL
/// preview seam. Every interaction rides real dispatch (`performClick` / the
/// control's own target/action), never a state poke.
@MainActor
@Suite(.serialized) struct PopoverLocalSyncTrimTests {

    private final class Recorder {
        var localSets: [Double] = []
        var localPreviews: [Double] = []
        var localEnds: [Double?] = []
        var btSets: [(ms: Double, id: String)] = []
        var localResets = 0
    }

    private func local() -> Device {
        Device(id: "mac", name: "This Mac", kind: .localMac, isLocalDevice: true)
    }

    private func airplay(_ id: String = "office", name: String = "Office") -> Device {
        Device(id: id, name: name, kind: .homePod)
    }

    private func tempDirectory(_ isolation: TestIsolation) -> URL {
        isolation.scratchDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    /// The popover over a started `MockBackend` fleet, with the local-trim
    /// closures wired the way `AppDelegate` wires them — settings-backed reads
    /// and writes (no backend capability needed) plus the preview seam.
    private func makePopover(_ isolation: TestIsolation, syncOffsetMs: Int? = nil)
        -> (PopoverController, Recorder, AppSettings) {
        let fleet = [local(), airplay()]
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

        let settings = AppSettings(defaults: isolation.isolatedDefaults)
        // Seeded BEFORE the first `update(devices:)`: the popover caches each
        // row's trim on its first paint (freshest-edit-wins), so a later write
        // behind its back would not be read again.
        if let syncOffsetMs { settings.syncOffsetMs = syncOffsetMs }
        let recorder = Recorder()
        popover.localTrimProvider = { Double(settings.syncOffsetMs) }
        popover.localTrimIsSetProvider = { settings.isSyncOffsetSet }
        popover.onSetLocalTrim = { ms in
            settings.syncOffsetMs = Int(ms)
            recorder.localSets.append(ms)
        }
        popover.onResetLocalTrim = {
            settings.clearSyncOffset()
            recorder.localResets += 1
        }
        popover.onLocalTrimPreview = { recorder.localPreviews.append($0) }
        popover.onLocalTrimEndPreview = { recorder.localEnds.append($0) }
        popover.onSetBTTrim = { ms, id, _ in recorder.btSets.append((ms, id)) }
        popover.update(devices: fleet)
        return (popover, recorder, settings)
    }

    private func waitFor(timeout: TimeInterval? = nil,
                     sourceLocation: SourceLocation = #_sourceLocation,
                     _ cond: @escaping () -> Bool) {
        SuiteWait.untilOnRunLoop(timeout: timeout, sourceLocation: sourceLocation, cond)
    }

    // MARK: The chip

    @Test func theMacsOwnRowCarriesTheSyncChip() {
        let isolation = TestIsolation(owner: "PopoverLocalSyncTrimTests")
        let (popover, _, _) = makePopover(isolation, syncOffsetMs: -12)

        let row = popover.test_deviceRow(for: "mac")
        #expect(row?.test_syncChipTitle == "−12 ms",
                "the Mac's trim reads on its own row, not buried in Settings")
        #expect(row?.test_syncChipIsDashed == false, "an explicit value is tuned")

        #expect(popover.test_deviceRow(for: "office")?.test_syncChipTitle == nil,
                "AirPlay rows still carry no trim (locked Decision 1)")
    }

    @Test func anUntunedMacReadsNotSetAndCarriesTheRelocatedHelpCopy() {
        let isolation = TestIsolation(owner: "PopoverLocalSyncTrimTests")
        let (popover, _, _) = makePopover(isolation)
        let row = popover.test_deviceRow(for: "mac")
        #expect(row?.test_syncChipIsDashed == true, "never tuned")
        #expect(row?.test_syncChipTooltip?.contains(DeviceRowView.localSyncHelpCopy) == true,
                "the deleted Settings help lives on the chip now: \(String(describing: row?.test_syncChipTooltip))")
    }

    @Test func theOffsetColumnTitleRendersWhenTheMacRowCarriesItsChip() {
        let isolation = TestIsolation(owner: "PopoverLocalSyncTrimTests")
        let (popover, _, _) = makePopover(isolation)
        #expect(popover.test_offsetColumnTitleShown(),
                "the Mac's pinned row carries the sync chip, so the card header prints the Offset legend (once, 2026-08-28)")
    }

    // MARK: The drawer

    @Test func theDrawerOpensOnTheMacsOwnRowAndAStepperEditReachesSettings() {
        let isolation = TestIsolation(owner: "PopoverLocalSyncTrimTests")
        let (popover, recorder, settings) = makePopover(isolation, syncOffsetMs: 20)

        popover.test_deviceRow(for: "mac")?.test_fireSyncChipClick()
        let drawer = popover.test_syncDrawer
        #expect(drawer != nil, "the chip opens the same drawer a BT row uses")
        #expect(drawer?.superview != nil, "…mounted under the row")

        drawer?.test_firePlusClick()
        #expect(recorder.localSets.count == 1, "one committed gesture, one apply")
        #expect(settings.syncOffsetMs == Int(recorder.localSets[0]),
                "the edit round-trips into AppSettings")
        #expect(settings.syncOffsetMs > 20, "…and plus raises the delay")
        #expect(recorder.btSets.isEmpty, "the Bluetooth store is not involved")
    }

    @Test func theLocalRowsUsableRangeIsTheFullTrimRange() {
        let isolation = TestIsolation(owner: "PopoverLocalSyncTrimTests")
        let (popover, _, _) = makePopover(isolation)
        // A BT range provider that would clamp hard if it were ever consulted
        // for the local row.
        popover.btTrimRangeProvider = { _ in 0...1 }
        popover.test_deviceRow(for: "mac")?.test_fireSyncChipClick()
        #expect(popover.test_syncDrawer?.test_usableRangeMs
                == -BTSyncTrim.rangeMs...BTSyncTrim.rangeMs)
    }

    // MARK: Reset alignment on the Mac's own row (roadmap 056)

    @Test func resetClearsTheStoredOffsetAndPutsTheRowBackOnNotSet() {
        let isolation = TestIsolation(owner: "PopoverLocalSyncTrimTests")
        let (popover, recorder, settings) = makePopover(isolation, syncOffsetMs: -12)

        popover.test_deviceRow(for: "mac")?.test_fireSyncChipClick()
        let drawer = popover.test_syncDrawer
        #expect(drawer?.test_resetVisible == true, "a tuned Mac has something to clear")

        drawer?.test_fireResetClick()
        #expect(recorder.localResets == 1)
        #expect(!settings.isSyncOffsetSet, "the entry is DELETED, not written as 0")
        #expect(settings.syncOffsetMs == 0, "…and an unset offset resolves to 0")
        #expect(recorder.localSets.isEmpty, "a reset is never a committed trim")
        // Visible immediately, without waiting for a backend push.
        let row = popover.test_deviceRow(for: "mac")
        #expect(row?.test_syncChipTitle == "Not set")
        #expect(row?.test_syncChipIsDashed == true)
    }

    @Test func resetIsNotOfferedOnAMacThatWasNeverTuned() {
        let isolation = TestIsolation(owner: "PopoverLocalSyncTrimTests")
        let (popover, _, _) = makePopover(isolation)
        popover.test_deviceRow(for: "mac")?.test_fireSyncChipClick()
        #expect(popover.test_syncDrawer?.test_resetVisible == false)
    }

    // MARK: The wizard on a local target

    @Test func theWizardOnTheMacDrivesTheLocalPreviewClosures() {
        let isolation = TestIsolation(owner: "PopoverLocalSyncTrimTests")
        let (popover, recorder, _) = makePopover(isolation, syncOffsetMs: 5)
        // Office FIRST: an AirPlay device turning on while the Mac is the sole
        // selection auto-swaps the Mac out, so the reverse order would leave
        // the wizard's target outside the user's audio intent.
        _ = popover.test_toggleDeviceEnabled(deviceID: "office", on: true)
        _ = popover.test_toggleDeviceEnabled(deviceID: "mac", on: true)
        #expect(popover.test_isSpeakerSelected("mac"))

        popover.startBTAlignmentWizard(deviceID: "mac", door: .menu)
        let wizard = popover.test_btWizardView()
        #expect(wizard != nil, "the Mac's own row opens the same wizard")
        #expect(popover.test_btWizardReferenceID() == "office",
                "the target is excluded from its own reference resolution")

        wizard?.test_clickButton(titled: "Start")
        #expect(recorder.localPreviews.count == 1,
                "the first candidate previews through the LOCAL seam")
        #expect(recorder.btSets.isEmpty, "…never the Bluetooth one")
        // The Mac's run is not inverted, so its candidates are plain trims
        // inside the drawer's own range.
        if let first = recorder.localPreviews.first {
            #expect((-BTSyncTrim.rangeMs...BTSyncTrim.rangeMs).contains(first))
        }

        wizard?.test_clickButton(titled: BTAlignmentWizardView.stopTitle)
        #expect(recorder.localEnds == [nil], "abandoning restores the stored offset")
    }
}
