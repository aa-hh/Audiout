// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import AppKit
@testable import AudiouterCore
@testable import AudiouterPopoverUI
@testable import AudiouterSharedUI

/// The rail connect pulse's FIRING decision, end to end through
/// `PopoverController`: `update(devices:)` diffs the model fact "device is a
/// connected member of the active Main Out target" (`lastConnectedMemberIDs`)
/// and only a genuine join reaches the overlay. This is the regression net for
/// the whole class of spurious pulses the retired draw-diff used to fire —
/// layout-only changes (subsection/card collapse, reopen) must trigger ZERO
/// pulses, a genuine connect exactly ONE.
@MainActor
@Suite(.serialized) struct RailConnectPulseControllerTests {

    private func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private struct Harness {
        let popover: PopoverController
        let controller: GroupController
        /// Parked off-screen; retained so the overlay keeps a real window —
        /// `runConnectPulse` mounts a CALayer and bails without one (the
        /// `RailConnectPulseTests.makeScene` precedent).
        let window: NSWindow
        let overlay: BusRailOverlayView
    }

    private func makePopover(fleet: [Device]) -> Harness {
        let backend = MockBackend(fleet: fleet, staggerDiscovery: false,
                                  emitsLevels: false, simulatesDropouts: false)
        let controller = GroupController(backend: backend,
                                         store: GroupStore(directory: tempDirectory()),
                                         routingStore: RoutingStore(directory: tempDirectory()),
                                         loadPersisted: false)
        let popover = PopoverController()
        popover.configure(groupController: controller)
        popover.test_isShownOverride = true
        let overlay = popover.test_railOverlay()
        overlay.test_windowVisibleOverride = true
        overlay.test_reduceMotionOverride = false
        // `setDeviceSelected` no-ops for a device the backend hasn't
        // discovered — start the mock fleet before any selection.
        backend.start()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && backend.devices.count < fleet.count {
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        popover.test_applyExactFitSize()   // force the panel's view tree to load
        var root: NSView = overlay
        while let superview = root.superview { root = superview }
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 360, height: 700),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView!.addSubview(root)
        return Harness(popover: popover, controller: controller,
                       window: window, overlay: overlay)
    }

    private func local() -> Device {
        Device(id: "mac", name: "This Mac", kind: .localMac, isLocalDevice: true)
    }

    private func airplay(_ id: String, name: String,
                         state: ConnectionState = .off, muted: Bool = false) -> Device {
        Device(id: id, name: name, kind: .homePod, isMuted: muted, connectionState: state)
    }

    /// Push a snapshot, settle layout, and spin the run loop so the deferred
    /// `playConnectPulse` body (if any) executes against laid-out rows.
    private func push(_ devices: [Device], into harness: Harness) {
        harness.popover.update(devices: devices)
        harness.popover.test_applyExactFitSize()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    @Test func aGenuineConnectFiresExactlyOnePulse() {
        let h = makePopover(fleet: [local(), airplay("office", name: "Office")])
        h.controller.setDeviceSelected("office", true)
        push([local(), airplay("office", name: "Office", state: .off)], into: h)   // baseline
        let before = h.overlay.test_pulsesStarted

        push([local(), airplay("office", name: "Office", state: .connecting)], into: h)
        #expect(h.overlay.test_pulsesStarted == before,
                "a handshake in flight is not a member yet — no early pulse")

        push([local(), airplay("office", name: "Office", state: .connected)], into: h)
        #expect(h.overlay.test_pulsesStarted == before + 1,
                "the member landing IS the connect — exactly one pulse")
        #expect(h.overlay.test_lastPulseDeparture == 1,
                "the previous member set was empty — the wire came to life, terminus departure")
    }

    @Test func aSecondRoomJoiningAnArmedSpineFiresOnceFromItsOwnNode() {
        // "Attic" sorts above "Office", so the joining room sits ABOVE the
        // wire's terminus — its departure must be a mid-wire fraction, proving
        // the `railDeviceID` mapping end to end.
        let h = makePopover(fleet: [local(), airplay("attic", name: "Attic"),
                                    airplay("office", name: "Office")])
        h.controller.setDeviceSelected("office", true)
        h.controller.setDeviceSelected("attic", true)
        push([local(), airplay("attic", name: "Attic", state: .off),
              airplay("office", name: "Office", state: .connected)], into: h)   // baseline: office live
        let before = h.overlay.test_pulsesStarted

        push([local(), airplay("attic", name: "Attic", state: .connecting),
              airplay("office", name: "Office", state: .connected)], into: h)
        #expect(h.overlay.test_pulsesStarted == before)

        push([local(), airplay("attic", name: "Attic", state: .connected),
              airplay("office", name: "Office", state: .connected)], into: h)
        #expect(h.overlay.test_pulsesStarted == before + 1,
                "the second room joining fires once")
        let departure = h.overlay.test_lastPulseDeparture
        #expect(departure != nil && departure! < 1,
                "a join on a live wire departs from its OWN node, not the terminus — got \(String(describing: departure))")
    }

    @Test func subsectionCollapseAndExpandFireNothing() {
        // THE live bug this refactor exists for: collapsing/expanding a
        // device-type subsection drops and re-adds rows, which the retired
        // draw-diff read as a join.
        let h = makePopover(fleet: [local(), airplay("office", name: "Office")])
        h.controller.setDeviceSelected("office", true)
        push([local(), airplay("office", name: "Office", state: .connected)], into: h)  // baseline, no fire
        let before = h.overlay.test_pulsesStarted

        h.popover.test_fireSubsectionHeaderClick(title: PopoverController.airPlaySubsectionTitle)
        h.popover.test_applyExactFitSize()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        h.popover.test_fireSubsectionHeaderClick(title: PopoverController.airPlaySubsectionTitle)
        h.popover.test_applyExactFitSize()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(h.overlay.test_pulsesStarted == before,
                "a subsection collapse/expand is layout, not a connect — zero pulses")
    }

    @Test func cardCollapseAndExpandFireNothing() {
        let h = makePopover(fleet: [local(), airplay("office", name: "Office")])
        h.controller.setDeviceSelected("office", true)
        push([local(), airplay("office", name: "Office", state: .connected)], into: h)  // baseline, no fire
        let before = h.overlay.test_pulsesStarted

        h.popover.test_toggleCard(title: PopoverController.outputDevicesCardTitle)
        h.popover.test_applyExactFitSize()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        h.popover.test_toggleCard(title: PopoverController.outputDevicesCardTitle)
        h.popover.test_applyExactFitSize()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(h.overlay.test_pulsesStarted == before,
                "a card collapse/expand is layout, not a connect — zero pulses")
    }

    @Test func aReopenFiresNothingEvenAfterAHiddenConnect() {
        let h = makePopover(fleet: [local(), airplay("attic", name: "Attic"),
                                    airplay("kitchen", name: "Kitchen"),
                                    airplay("office", name: "Office")])
        h.controller.setDeviceSelected("office", true)
        h.controller.setDeviceSelected("attic", true)
        h.controller.setDeviceSelected("kitchen", true)
        push([local(), airplay("attic", name: "Attic", state: .off),
              airplay("kitchen", name: "Kitchen", state: .off),
              airplay("office", name: "Office", state: .connected)], into: h)   // baseline
        let before = h.overlay.test_pulsesStarted

        // A room connects while the surface is hidden: the baseline advances
        // silently, and no pulse plays.
        h.popover.test_isShownOverride = false
        push([local(), airplay("attic", name: "Attic", state: .connected),
              airplay("kitchen", name: "Kitchen", state: .off),
              airplay("office", name: "Office", state: .connected)], into: h)
        #expect(h.overlay.test_pulsesStarted == before, "hidden means silent")

        // Reopen: the open ritual finds nothing "new".
        h.popover.test_isShownOverride = true
        h.popover.test_simulateOpen()
        h.popover.test_applyExactFitSize()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(h.overlay.test_pulsesStarted == before,
                "a reopen after a hidden connect fires nothing — the baseline already moved")

        // Live behavior resumed: a genuine join while shown still fires.
        push([local(), airplay("attic", name: "Attic", state: .connected),
              airplay("kitchen", name: "Kitchen", state: .connected),
              airplay("office", name: "Office", state: .connected)], into: h)
        #expect(h.overlay.test_pulsesStarted == before + 1,
                "…and a genuine join after the reopen fires exactly once")
    }

    @Test func muteAndLeaveFireNothing() {
        let h = makePopover(fleet: [local(), airplay("office", name: "Office")])
        h.controller.setDeviceSelected("office", true)
        push([local(), airplay("office", name: "Office", state: .connected)], into: h)  // baseline
        let before = h.overlay.test_pulsesStarted

        push([local(), airplay("office", name: "Office", state: .connected, muted: true)], into: h)
        #expect(h.overlay.test_pulsesStarted == before,
                "a mute changes no membership — no pulse")

        push([local(), airplay("office", name: "Office", state: .off)], into: h)
        #expect(h.overlay.test_pulsesStarted == before,
                "a room leaving is not a surge — no pulse")
    }
}
