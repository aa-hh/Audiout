// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import Testing
import AudiouterCore
@testable import AudiouterSharedUI

/// Row-level coverage for the **membership bus** (Warm Signal v3 §4, S-BUS):
/// the drawing-only bus skin over the real `NSButton` membership checkbox.
/// Asserts the node↦state mapping (member / non-member / blocked / unavailable),
/// the fixed node column (zero layout shift across toggles, off the shared
/// `PopoverColumnGrid` constants — R7/§4.1), the terminating rail, the
/// tint-not-alpha dormant dim (§4.7 — the HOST scopes which rows dim under the
/// final derived/diverged semantics; the row only renders the tint it's handed),
/// the group-member no-node rule,
/// the real checkbox action path under the node skin (§4.8), and the checkbox's
/// stable VoiceOver label.
@MainActor
@Suite struct MembershipBusTests {

    private func makeDevice(id: String = "dev-1",
                            connectionState: ConnectionState = .connected,
                            isAvailable: Bool = true) -> Device {
        Device(id: id, name: "Test Speaker", kind: .homePod,
               isAvailable: isAvailable, connectionState: connectionState)
    }

    private func makeBusRow(device: Device? = nil) -> DeviceRowView {
        DeviceRowView(device: device ?? makeDevice(), showsToggle: true,
                      paintsSelectionBackground: false, showsMeter: true, showsBus: true)
    }

    // MARK: Node ↦ state mapping (§4.3/§4.4/§4.6, matrix §3.6)

    @Test func memberRendersFilledNode() {
        let row = makeBusRow()
        row.apply(makeDevice(), selected: true, controllable: true)
        #expect(row.test_busNode == .member, "a member's node is the filled gold disc ON the line")
    }

    @Test func nonMemberRendersHollowDetouredNode() {
        let row = makeBusRow()
        row.apply(makeDevice(), selected: false)
        #expect(row.test_busNode == .nonMember,
                       "a non-member's node is hollow — the line detours around it")
    }

    @Test func blockedLocalMixRendersBlockedNode() {
        let row = makeBusRow()
        row.apply(makeDevice(), selected: false, blocked: true, blockReason: "no mixed set")
        #expect(row.test_busNode == .blocked,
                       "the local-mix blocked row renders the distinct greyed hollow node (§4.6)")
    }

    @Test func unavailableRendersHollowTintedNode() {
        let row = makeBusRow()
        // Even a held (selected) membership renders hollow while unavailable —
        // the device is not currently in the mix (matrix §3.6 "Unavailable").
        row.apply(makeDevice(isAvailable: false), selected: true)
        #expect(row.test_busNode == .nonMember, "an unavailable device's node is hollow")
        #expect(row.test_busNodeDimmed == true, "…and tinted (the unavailable signature)")
        // Distinct from blocked (R5): blocked is `.blocked`, unavailable is a
        // tinted `.nonMember` + the "Unavailable" FEED override (v4.1 item 3
        // moved this word off the sublabel and onto the FEED column, since
        // this row is a bus row).
        #expect(row.test_feedText == "Unavailable")
        #expect(row.test_feedIsErrorColored)
        #expect(row.test_statusText == nil, "the sublabel carries no words on a bus row's unavailable state")
    }

    @Test func muteKeepsTheNodeFilled() {
        // §3.4: membership ≠ mute — a muted member is still in the mix set.
        var device = makeDevice()
        device.isMuted = true
        let row = makeBusRow()
        row.apply(device, selected: true, controllable: true)
        #expect(row.test_busNode == .member, "a muted member's node stays FILLED (§3.4)")
    }

    // MARK: No-bus rows

    @Test func nonBusRowHasNoBusNode() {
        let row = DeviceRowView(device: makeDevice())   // mixer-window style, no bus
        #expect(row.test_busNode == nil, "a non-bus host row draws no node")
        #expect(row.test_busNodeCenterX() == nil)
    }

    @Test func groupMemberRowKeepsNoBusNode() {
        // §4.6 group members: showsToggle == false rows carry no membership
        // control, so they keep NO bus node even under a bus host.
        let row = DeviceRowView(device: makeDevice(), indented: true, showsToggle: false,
                                paintsSelectionBackground: false, showsMeter: true,
                                showsBus: true)
        #expect(row.test_busNode == nil, "a showsToggle=false (group-member) row keeps no bus node")
    }

    // MARK: Fixed node column — zero layout shift (§4.1 / R7)

    @Test func nodeColumnXIsFixedAcrossToggles() {
        let row = makeBusRow()

        row.apply(makeDevice(), selected: true, controllable: true)
        let selectedX = row.test_busNodeCenterX()
        // Warm Signal v4 §Call-1: the spine moved to the LEFT gutter — every node
        // sits on `railGutterCenterX` (measured from the row's leading edge).
        let expectedX = PopoverColumnGrid.railGutterCenterX
        row.apply(makeDevice(), selected: false)
        let deselectedX = row.test_busNodeCenterX()

        #expect(abs((selectedX ?? -1) - expectedX) <= 0.5,
                       "the node sits on the left-gutter rail centreline")
        #expect(abs((deselectedX ?? -1) - expectedX) <= 0.5,
                       "…whether tapped in or out — toggling changes only fill and line path")
        #expect(abs((selectedX ?? -1) - (deselectedX ?? -2)) <= 0.001,
                       "zero layout shift across a membership toggle (R7)")
    }

    // MARK: Terminating rail (§4.1 "runs to the last device row's node")

    @Test func terminatingRowDrawsNoRailBelow() {
        let row = makeBusRow()
        #expect(row.test_busRailBelow == true, "an ordinary row rails below its node")
        row.setBusTerminates(true)
        #expect(row.test_busRailBelow == false, "the last node terminates the line")
        // Terminate-state is structural: it survives an in-place repaint.
        row.apply(makeDevice(), selected: true, controllable: true)
        #expect(row.test_busRailBelow == false, "termination survives a model re-apply")
    }

    // MARK: Dormant de-emphasis — tint, never alpha (§4.7; the host scopes WHO dims)

    @Test func dormantDimIsANodeTintWithTheCheckboxAtFullAlpha() {
        let row = makeBusRow()
        row.apply(makeDevice(), selected: true, controllable: true, selectionDimmed: true)
        #expect(row.test_isSelectionDimmed == true, "the dormancy dim reads out")
        #expect(row.test_busNodeDimmed == true, "…as the node TINT")
        // The control stays fully interactive under the tint.
        #expect(row.test_isEnabledOn == true)
    }

    @Test func failedMemberNodeIsFailureRedAndNeverDimmed() {
        let row = makeBusRow()
        row.apply(makeDevice(connectionState: .failed(.init(cause: .notResponding))),
                  selected: true, selectionDimmed: true)
        #expect(row.test_busNodeDimmed == false,
                       "a failed member renders at full failure emphasis even in a dormant card")
        #expect(row.test_busNode == .failed,
                       "…in the failure-red ring node form (v4 §Call-1 node vocabulary)")
    }

    // MARK: The node IS the checkbox (§4.8)

    private final class DelegateSpy: DeviceRowView.Delegate {
        var toggled: [(on: Bool, id: String)] = []
        func deviceRow(_ row: DeviceRowView, didSetVolume volume: Int, for id: String) {}
        func deviceRow(_ row: DeviceRowView, didToggleMute muted: Bool, for id: String) {}
        func deviceRow(_ row: DeviceRowView, didToggleEnabled on: Bool, for id: String) {
            toggled.append((on, id))
        }
    }

    @Test func checkboxActionDispatchStillDrivesTheDelegateUnderTheNodeSkin() {
        // Drives the checkbox's OWN target/action with the checkbox as sender —
        // the real AppKit click path, not the delegate shortcut — proving the
        // invisible-cell skin left the control's action wiring intact (§4.8).
        let row = makeBusRow()
        let spy = DelegateSpy()
        row.delegate = spy
        row.apply(makeDevice(), selected: false)
        row.test_fireCheckboxAction(settingStateTo: true)
        #expect(spy.toggled.count == 1, "the node's click path fires the delegate")
        #expect(spy.toggled.first?.on == true)
        #expect(spy.toggled.first?.id == "dev-1")
    }

    @Test func busMembershipVoiceOverLabelIsStable() {
        // §4.8: the node speaks as the checkbox — a STABLE "include … in main
        // audio" label; the checked/unchecked VALUE (from the untouched NSButton
        // state) carries the membership, so the label must not flip per state.
        let row = makeBusRow()
        row.apply(makeDevice(), selected: false)
        #expect(row.test_membershipAXLabel == "Include Test Speaker in main audio")
        row.apply(makeDevice(), selected: true, controllable: true)
        #expect(row.test_membershipAXLabel == "Include Test Speaker in main audio",
                       "the label is identical checked and unchecked — the value carries the state")
    }

    @Test func nonBusCheckboxKeepsItsLegacyVoiceOverLabel() {
        // Non-bus hosts (mixer window) are byte-for-byte unchanged.
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: false)
        #expect(row.test_membershipAXLabel == "Add Test Speaker to Selected Devices")
        row.apply(makeDevice(), selected: true, controllable: true)
        #expect(row.test_membershipAXLabel == "Remove Test Speaker from Selected Devices")
    }
}
