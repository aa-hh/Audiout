// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import AppKit
@testable import AudioutCore
@testable import AudioutPopoverUI
@testable import AudioutSharedUI

/// The popover's **Equalizer door** (owner decision 2026-08-22: EQ never lives
/// on the Mixer). What this pins is the entry, not the editor: which rows offer
/// "Equalizer…", in what order, what the row ICON does, which id reaches
/// `onOpenEqualizer` — and that no tone CONTROL came back to the popover with
/// it. Every menu item goes through real AppKit dispatch
/// (`performActionForItem(at:)`), never the delegate shortcut.
///
/// `.serialized` for the same reason `PopoverControllerTests` is.
@MainActor
@Suite(.serialized) struct PopoverEqualizerEntryTests {

    private func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory   // isolation-ok — UUID-suffixed per call
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    final class Recorder {
        var opened: [String] = []
    }

    /// The `PopoverBTAlignmentUITests` harness: a STARTED `MockBackend` fleet
    /// behind a real `GroupController`, rows pushed by hand.
    private func makePopover() -> (PopoverController, Recorder) {
        let fleet = [local(), airplay(), bt()]
        let backend = MockBackend(fleet: fleet, staggerDiscovery: false,
                                  emitsLevels: false, simulatesDropouts: false)
        let controller = GroupController(backend: backend,
                                         store: GroupStore(directory: tempDirectory()),
                                         routingStore: RoutingStore(directory: tempDirectory()),
                                         loadPersisted: false)
        let popover = PopoverController()
        popover.configure(groupController: controller)
        popover.test_isShownOverride = true
        backend.start()
        waitFor { backend.devices.count == fleet.count }
        let recorder = Recorder()
        popover.onOpenEqualizer = { recorder.opened.append($0) }
        popover.update(devices: fleet)
        return (popover, recorder)
    }

    private func waitFor(timeout: TimeInterval? = nil,
                     sourceLocation: SourceLocation = #_sourceLocation,
                     _ cond: @escaping () -> Bool) {
        SuiteWait.untilOnRunLoop(timeout: timeout, sourceLocation: sourceLocation, cond)
    }

    private func local() -> Device {
        Device(id: "mac", name: "This Mac", kind: .localMac, isLocalDevice: true)
    }

    private func airplay(_ id: String = "office", name: String = "Office") -> Device {
        Device(id: id, name: name, kind: .homePod)
    }

    private func bt(_ id: String = "bt-a:output", name: String = "Move 2") -> Device {
        Device(id: id, name: name, kind: .bluetooth, supportsAirPlay2: false)
    }

    private func titles(_ menu: NSMenu?) -> [String] {
        (menu?.items ?? []).map(\.title)
    }

    // MARK: The menu

    @Test func airPlayRowMenuOffersEqualizerAndDispatchesTheDeviceID() {
        let (popover, recorder) = makePopover()
        let menu = popover.test_deviceRow(for: "office")?.test_contextMenu()
        #expect(titles(menu) == ["Equalizer…"])

        menu?.performActionForItem(at: 0)
        #expect(recorder.opened == ["office"])
    }

    @Test func bluetoothRowMenuOffersEqualizerThenAlign() {
        let (popover, _) = makePopover()
        let menu = popover.test_deviceRow(for: "bt-a:output")?.test_contextMenu()
        #expect(titles(menu) == ["Equalizer…", "Align speaker…"],
                "tone first, alignment second — and no separator between two items")
    }

    @Test func thisMacRowMenuOffersAlignmentButNeverEqualizer() {
        // Roadmap 060: the Mac's own row carries the SAME sync affordances as a
        // Bluetooth row — including "Align speaker…" — but it is still not an
        // Equalizer target (per-device EQ covers AirPlay and Bluetooth outputs).
        let (popover, _) = makePopover()
        let row = popover.test_deviceRow(for: "mac")
        #expect(row != nil)
        #expect(titles(row?.test_contextMenu()) == ["Align speaker…"],
                "alignment yes, tone no — This Mac is not an EQ target")
        #expect(row?.test_iconIsMenuTrigger == true)
        #expect(titles(row?.test_clickIcon()) == ["Align speaker…"],
                "the icon pops the same menu")
    }

    // MARK: The icon is the same door

    @Test func iconClickPopsTheSameMenu() {
        let (popover, _) = makePopover()
        let row = popover.test_deviceRow(for: "bt-a:output")
        #expect(titles(row?.test_clickIcon()) == titles(row?.test_contextMenu()))
        #expect(row?.test_iconIsMenuTrigger == true)
        #expect(row?.test_iconAXLabel == "Speaker options")
    }

    @Test func mainAudioMenuAndIconOpenTheWholeMixEqualizer() {
        let (popover, recorder) = makePopover()
        let row = popover.test_mainOutRow
        let menu = row.test_contextMenu()
        #expect(titles(menu) == ["Equalizer…"])

        menu.performActionForItem(at: 0)
        #expect(recorder.opened.last == PopoverController.mainOutEQID,
                "the whole mix has no device id — it travels as the sentinel")
        #expect(row.test_clickIcon() != nil)
        #expect(row.test_iconAXLabel == "Main Audio options")
    }

    // MARK: What the popover no longer carries

    @Test func noRowCarriesAnEQChip() {
        let (popover, _) = makePopover()
        func hasEQChip(_ view: NSView) -> Bool {
            if let button = view as? NSButton, button.title == "EQ" { return true }
            return view.subviews.contains(where: hasEQChip)
        }
        #expect(popover.test_deviceRow(for: "office").map(hasEQChip) == false)
        #expect(hasEQChip(popover.test_mainOutRow) == false)
    }

    @Test func syncDrawerStillOpensAfterTheEQDrawerLeft() {
        let (popover, _) = makePopover()
        popover.test_deviceRow(for: "bt-a:output")?.test_fireSyncChipClick()
        FoldAnimator.shared.test_settleNow()
        #expect(popover.test_syncDrawerVisible)
    }
}
