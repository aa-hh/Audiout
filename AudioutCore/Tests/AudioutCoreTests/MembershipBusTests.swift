// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import Testing
import AudioutCore
@testable import AudioutSharedUI

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

    @Test func unavailableRendersHollowTintedNode() {
        let row = makeBusRow()
        // Even a held (selected) membership renders hollow while unavailable —
        // the device is not currently in the mix (matrix §3.6 "Unavailable").
        row.apply(makeDevice(isAvailable: false), selected: true)
        #expect(row.test_busNode == .nonMember, "an unavailable device's node is hollow")
        // The dim flag rides along; it reaches only a FILL, and a hollow node
        // has none — the rim is the rail's and stays ember.
        #expect(row.test_busNodeDimmed == true, "…and carries the unavailable dim")
        // Unavailable is a tinted `.nonMember` + the "Unavailable" FEED
        // override (v4.1 item 3 moved this word off the sublabel and onto the
        // FEED column, since this row is a bus row).
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

    // MARK: The row states a NODE, never an extent

    /// Where the rail begins and ends is the overlay's to derive from the node
    /// kinds it is handed (the channel spans the whole band; the signal stops at
    /// the lowest member). A row therefore contributes ONE thing — its node — and
    /// that contribution must track the drawn node through an in-place repaint,
    /// or the rail resolves against stale geometry.
    @Test func theRowContributesItsDrawnNodeAndNoExtent() {
        let row = makeBusRow()
        row.apply(makeDevice(), selected: true, controllable: true)
        #expect(row.railNode == .member, "a member row contributes its member node")
        #expect(row.railNode == row.test_busNode, "the contribution IS the drawn node")

        row.apply(makeDevice(), selected: false)
        #expect(row.railNode == .nonMember, "and follows an in-place re-apply")
        #expect(row.railNode == row.test_busNode)
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

    // MARK: The node's clickability (generous hit target + hover affordance)

    @Test func membershipHitTargetCoversTheWholeNode() {
        let row = makeBusRow()
        row.frame = NSRect(x: 0, y: 0, width: 500, height: DeviceRowView.rowHeight)
        row.apply(makeDevice(), selected: true, controllable: true)
        guard let hit = row.test_membershipHitRect(), let node = row.test_nodeRect() else {
            Issue.record("a bus row must expose both rects"); return
        }
        #expect(hit.contains(node),
                "the invisible checkbox's target covers the node at the widest it ever draws, not just the resting disc")
        #expect(hit.height == row.bounds.height, "…over the full row height")
        #expect(hit.maxX <= PopoverColumnGrid.firstElementLeading(indented: false),
                "…and stops at the icon column, so it steals nothing from the row's other controls")
    }

    @Test func gutterHoverGrowsANonMemberIntoItsMemberSize() {
        let row = makeBusRow()
        row.apply(makeDevice(), selected: false, controllable: true)
        let resting = row.test_nodeTargetRadius
        #expect(resting == PopoverColumnGrid.busNodeDiameterUnselected / 2,
                "at rest the node draws at its own size — the gutter adds no ink")
        row.test_setGutterHovered(true)
        #expect(row.test_nodeTargetRadius == PopoverColumnGrid.busNodeDiameterSelected / 2,
                "hovering previews the click: this node's click ADDS it, so it grows to the member size — never past it")
        #expect(row.test_nodePreviewsClick)
        row.test_setGutterHovered(false)
        #expect(row.test_nodeTargetRadius == resting, "and it settles back on exit")
        #expect(!row.test_nodePreviewsClick)
    }

    @Test func gutterHoverShrinksAMemberIntoItsNonMemberSize() {
        // Alec's correction: the hover previews the POST-CLICK state, so a
        // member — whose click REMOVES it from the mix — travels DOWN. The
        // direction of travel is what says which way the click goes.
        let row = makeBusRow()
        row.apply(makeDevice(), selected: true, controllable: true)
        let resting = row.test_nodeTargetRadius
        #expect(resting == PopoverColumnGrid.busNodeDiameterSelected / 2)
        row.test_setGutterHovered(true)
        #expect(row.test_nodeTargetRadius == PopoverColumnGrid.busNodeDiameterUnselected / 2,
                "a member's click removes it, so the hover shrinks the node to the size it would land on")
        #expect(row.test_nodePreviewsClick)
        row.test_setGutterHovered(false)
        #expect(row.test_nodeTargetRadius == resting, "and it settles back on exit")
    }

    @Test func rowHoverGrowsAnUnselectedNode() {
        let row = makeBusRow()
        row.apply(makeDevice(), selected: false)
        row.test_setHovered(true)
        #expect(row.test_nodeTargetRadius == PopoverColumnGrid.busNodeDiameterSelected / 2,
                "hovering anywhere on an unselected row grows its node — the invisible checkbox's one resting invitation")
        row.test_setHovered(false)
        #expect(!row.test_nodePreviewsClick)
    }

    @Test func rowHoverDoesNotResizeASelectedNode() {
        let row = makeBusRow()
        row.apply(makeDevice(), selected: true, controllable: true)
        row.test_setHovered(true)
        #expect(row.test_nodeTargetRadius == PopoverColumnGrid.busNodeDiameterSelected / 2,
                "a selected row resizes only from the gutter — its filled node already reads as the control")
        #expect(!row.test_nodePreviewsClick)
    }

    @Test func rowHoverNeverResizesADisabledCheckbox() {
        let row = makeBusRow()
        row.apply(makeDevice(isAvailable: false), selected: false)
        row.test_setHovered(true)
        #expect(!row.test_nodePreviewsClick, "never preview a click the checkbox would refuse")
    }

    // MARK: The hover growth itself (the tween, and Reduce Motion's way out)

    /// A node in a live window TRAVELS to its hover size; the same node under
    /// Reduce Motion is simply AT it. Both halves are read before any clock
    /// tick, so neither depends on the run loop getting time.
    @Test func reduceMotionTakesTheHoverSizeWithoutTravelling() {
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 60, height: 40),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let resting = PopoverColumnGrid.busNodeDiameterUnselected / 2

        let postClick = PopoverColumnGrid.busNodeDiameterSelected / 2

        let travelling = makeBusView()
        travelling.test_reduceMotionOverride = false
        window.contentView!.addSubview(travelling)
        travelling.setHovered(true)
        #expect(travelling.test_nodeTargetRadius == postClick,
                "the hover moves the node's TARGET to its post-click radius")
        #expect(travelling.test_nodeRadius == resting,
                "…and the node starts the travel from its resting size, not at the target")
        travelling.removeFromSuperview()  // settles the tween; nothing ticks off screen

        let instant = makeBusView()
        instant.test_reduceMotionOverride = true
        window.contentView!.addSubview(instant)
        instant.setHovered(true)
        #expect(instant.test_nodeRadius == postClick,
                "Reduce Motion removes the tween, not the affordance — the node is at the post-click size already")
        instant.setHovered(false)
        #expect(instant.test_nodeRadius == resting, "…and back, in the same turn")
        instant.removeFromSuperview()
    }

    /// Structural hooks say the target moved; this says the PIXELS did — and in
    /// BOTH directions, which is the whole correction: a hovered non-member
    /// spans more of the gutter, a hovered member spans less. Off-window, so the
    /// size is taken instantly and the bitmaps are deterministic.
    @Test func theHoveredNodeReallyDrawsItsPostClickWidth() {
        let joining = makeBusView()
        let restingNonMember = drawnNodeExtent(joining)
        joining.setHovered(true)
        let hoveredNonMember = drawnNodeExtent(joining)
        #expect(hoveredNonMember > restingNonMember,
                Comment(rawValue: "the hovered non-member spans \(hoveredNonMember) px against \(restingNonMember) at rest"))

        let leaving = makeBusView(node: .member)
        let restingMember = drawnNodeExtent(leaving)
        leaving.setHovered(true)
        let hoveredMember = drawnNodeExtent(leaving)
        #expect(hoveredMember < restingMember,
                Comment(rawValue: "the hovered member spans \(hoveredMember) px against \(restingMember) at rest"))
        #expect(restingMember > restingNonMember,
                "sanity: the resting sizes the two hovers trade between are the real ones")
    }

    private func makeBusView(node: MembershipBusView.Node = .nonMember) -> MembershipBusView {
        let bus = MembershipBusView()
        bus.frame = NSRect(x: 0, y: 0, width: PopoverColumnGrid.busColumnWidth, height: 40)
        bus.apply(node: node)
        return bus
    }

    /// The drawn node's horizontal span, in pixels, read off a real bitmap of
    /// the node view: the inked extent along its centre scan line.
    private func drawnNodeExtent(_ bus: MembershipBusView) -> Int {
        guard let rep = bus.bitmapImageRepForCachingDisplay(in: bus.bounds) else { return 0 }
        bus.cacheDisplay(in: bus.bounds, to: rep)
        let y = rep.pixelsHigh / 2
        let inked = (0..<rep.pixelsWide).filter { x in
            (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05
        }
        guard let first = inked.first, let last = inked.last else { return 0 }
        return last - first + 1
    }

    @Test func nameTooltipInvitesOnlyUnselectedAvailableRows() {
        let row = makeBusRow()
        row.apply(makeDevice(), selected: false)
        #expect(row.test_nameTooltip == "Add Test Speaker to the mix")
        row.apply(makeDevice(), selected: true, controllable: true)
        #expect(row.test_nameTooltip == nil,
                "the node's own tooltip already names the removal")
        row.apply(makeDevice(isAvailable: false), selected: false)
        #expect(row.test_nameTooltip == nil,
                "a greyed Bluetooth row's name click CONNECTS — a mix tooltip there would lie")
    }

    @Test func modelRefreshClearsTheGutterHover() {
        let row = makeBusRow()
        row.apply(makeDevice(), selected: true, controllable: true)
        row.test_setGutterHovered(true)
        #expect(row.test_nodePreviewsClick)
        // Row reuse (any `apply`) drops the transient hover, exactly like the
        // row's own hover wash.
        row.apply(makeDevice(id: "dev-2"), selected: false)
        #expect(!row.test_nodePreviewsClick)
    }

    @Test func nonBusCheckboxKeepsItsLegacyVoiceOverLabel() {
        // Non-bus hosts (mixer window) are byte-for-byte unchanged.
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: false)
        #expect(row.test_membershipAXLabel == "Add Test Speaker to Selected Devices")
        row.apply(makeDevice(), selected: true, controllable: true)
        #expect(row.test_membershipAXLabel == "Remove Test Speaker from Selected Devices")
    }

    @Test func gutterCheckboxTooltipNamesTheMixAction() {
        let row = makeBusRow()
        row.apply(makeDevice(), selected: false)
        #expect(row.test_membershipTooltip == "Add Test Speaker to the mix")
        row.apply(makeDevice(), selected: true, controllable: true)
        #expect(row.test_membershipTooltip == "Remove Test Speaker from the mix")
    }

    @Test func nonBusRowHasNoMembershipTooltip() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: false)
        #expect(row.test_membershipTooltip == nil)
    }
}
