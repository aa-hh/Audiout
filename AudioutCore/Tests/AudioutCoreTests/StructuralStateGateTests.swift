// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import Foundation
@testable import AudioutCore

/// `StructuralStateGate` — the guard standing between
/// `GroupController.onStateDidChange` (which fires for EVERY model change,
/// including every tick of a volume-key hold) and two full-sweep repaints.
/// What it must get right is not "does it detect a change" but "does it stay
/// silent for the changes that don't move selection or groups", which is the
/// whole reason it exists.
///
/// Every call is hoisted into a `let` before its `#expect`: `shouldRepaint` is
/// `mutating`, and the macro captures its expression immutably.
@Suite struct StructuralStateGateTests {

    private func makeGroup(id: String = "g1", name: String = "Living Room",
                           memberIDs: [String] = ["d1"]) -> Group {
        Group(id: id, name: name, memberIDs: memberIDs, memberVolumes: [:], iconSymbolName: nil)
    }

    @Test func theFirstCallAlwaysRepaints() {
        var gate = StructuralStateGate()
        let first = gate.shouldRepaint(selection: [], groups: [], target: .selectedDevices)
        #expect(first, "nothing has been painted from this state yet")
    }

    /// THE reason the gate exists: a master-volume move changes neither
    /// selection nor groups, so a held volume key must not drag the energize
    /// reconcile, the rail extents and an outline-view reload through every
    /// one of its ticks.
    @Test func repeatedAnnouncementsWithNoStructuralChangeStaySilent() {
        var gate = StructuralStateGate()
        let selection: Set<String> = ["d1", "d2"]
        let groups = [makeGroup()]
        _ = gate.shouldRepaint(selection: selection, groups: groups, target: .selectedDevices)

        var repaints = 0
        for _ in 0..<50 where gate.shouldRepaint(selection: selection, groups: groups, target: .selectedDevices) {
            repaints += 1
        }
        #expect(repaints == 0, "an unchanged announcement must never repaint")
    }

    @Test func aSelectionChangeRepaintsOnceThenSettles() {
        var gate = StructuralStateGate()
        _ = gate.shouldRepaint(selection: ["d1"], groups: [], target: .selectedDevices)

        let moved = gate.shouldRepaint(selection: ["d1", "d2"], groups: [], target: .selectedDevices)
        let settled = gate.shouldRepaint(selection: ["d1", "d2"], groups: [], target: .selectedDevices)
        #expect(moved, "the selection moved")
        #expect(!settled, "and has now been painted")
    }

    /// Selection is a SET: the same members arriving in a different order is
    /// not a change, and must not repaint.
    @Test func selectionOrderIsNotAChange() {
        var gate = StructuralStateGate()
        _ = gate.shouldRepaint(selection: ["d1", "d2", "d3"], groups: [], target: .selectedDevices)
        let reordered = gate.shouldRepaint(selection: ["d3", "d1", "d2"], groups: [], target: .selectedDevices)
        #expect(!reordered)
    }

    @Test func aGroupEditRepaintsEvenWhenTheSelectionIsUntouched() {
        var gate = StructuralStateGate()
        let selection: Set<String> = ["d1"]
        _ = gate.shouldRepaint(selection: selection, groups: [makeGroup()], target: .selectedDevices)

        let renamed = gate.shouldRepaint(selection: selection, groups: [makeGroup(name: "Kitchen")], target: .selectedDevices)
        let remembered = gate.shouldRepaint(selection: selection,
                                            groups: [makeGroup(name: "Kitchen", memberIDs: ["d1", "d2"])],
                                            target: .selectedDevices)
        let deleted = gate.shouldRepaint(selection: selection, groups: [], target: .selectedDevices)
        #expect(renamed, "a rename is a change the Groups screen draws")
        #expect(remembered, "so is a membership edit")
        #expect(deleted, "so is a delete")
    }

    /// The case this gate originally MISSED, reported live: activating a group
    /// from the phone moves `mainOut`/`activeGroupID` and nothing else, so the
    /// speakers lit up while the membership rail stayed unpainted.
    @Test func activatingAGroupRepaintsEvenThoughSelectionAndGroupsAreUntouched() {
        var gate = StructuralStateGate()
        let selection: Set<String> = ["d1"]
        let groups = [makeGroup()]
        _ = gate.shouldRepaint(selection: selection, groups: groups, target: .selectedDevices)

        let activated = gate.shouldRepaint(selection: selection, groups: groups, target: .group(id: "g1"))
        let settled = gate.shouldRepaint(selection: selection, groups: groups, target: .group(id: "g1"))
        let switchedBack = gate.shouldRepaint(selection: selection, groups: groups, target: .selectedDevices)
        #expect(activated, "the rail and the dormant dimming both derive from the target")
        #expect(!settled)
        #expect(switchedBack, "and going back to Selected Speakers is equally a change")
    }

    /// Switching between two GROUPS is a change too — same case, different id.
    @Test func switchingBetweenGroupsRepaints() {
        var gate = StructuralStateGate()
        _ = gate.shouldRepaint(selection: [], groups: [], target: .group(id: "a"))
        let switched = gate.shouldRepaint(selection: [], groups: [], target: .group(id: "b"))
        #expect(switched)
    }

    /// Group ORDER is meaningful — the sidebar lists them in it — so a
    /// reorder must repaint, unlike a selection reorder.
    @Test func aGroupReorderRepaints() {
        var gate = StructuralStateGate()
        let a = makeGroup(id: "a", name: "A")
        let b = makeGroup(id: "b", name: "B")
        _ = gate.shouldRepaint(selection: [], groups: [a, b], target: .selectedDevices)
        let reordered = gate.shouldRepaint(selection: [], groups: [b, a], target: .selectedDevices)
        #expect(reordered)
    }
}
