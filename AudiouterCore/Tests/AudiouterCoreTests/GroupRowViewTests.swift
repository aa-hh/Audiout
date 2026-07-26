// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import AppKit
@testable import AudiouterCore
@testable import AudiouterPopoverUI

/// Interaction + accessibility coverage for `GroupRowView` — SPEC §9 revised's
/// "click anywhere on the row toggles expansion" contract, and task
/// A11Y-LABELS's fix: the row claimed `.button` accessibility role but
/// VoiceOver's activate gesture (VO+Space / double-tap) did nothing, since a
/// plain `NSView` doesn't get AXPress wired to an action the way `NSButton`
/// does. Built directly, like `PopoverIconTests`'s group-row cases — the row
/// has no host dependency.
// `@MainActor` is load-bearing, not decoration: this suite builds and drives
// AppKit views, and every `NSView`-family API is main-actor-only. XCTest ran
// each test method on the main thread, so the annotation was never needed;
// swift-testing schedules non-isolated `@Test` bodies on the cooperative
// pool, where the same calls trip AppKit's "modifications to layout engine
// from a background thread" exception and take the whole process down
// (observed in `AppRowViewTests` during this migration). Do not remove it.
@MainActor
@Suite struct GroupRowViewTests {

    private final class RecordingDelegate: GroupRowView.Delegate {
        var toggledGroupID: String?
        var toggleCount = 0
        func groupRowToggleExpansion(_ row: GroupRowView, groupID: String) {
            toggledGroupID = groupID
            toggleCount += 1
        }
        func groupRowActivate(_ row: GroupRowView, groupID: String) {}
        func groupRowBeginMasterDrag(_ row: GroupRowView, groupID: String) {}
        func groupRow(_ row: GroupRowView, didSetMaster volume: Int, groupID: String) {}
        func groupRowEndMasterDrag(_ row: GroupRowView, groupID: String) {}
        func groupRow(_ row: GroupRowView, didSetMuted muted: Bool, groupID: String) {}
    }

    private func makeRow() -> (GroupRowView, RecordingDelegate) {
        let group = Group(id: "group-1", name: "Whole House", memberIDs: ["office"], memberVolumes: ["office": 40])
        let row = GroupRowView(group: group, isActive: false, isExpanded: false, masterVolume: 50)
        let delegate = RecordingDelegate()
        row.delegate = delegate
        return (row, delegate)
    }

    // MARK: AXPress actually toggles expansion (A11Y-LABELS)

    /// The bug this task fixes: pressing the row via VoiceOver used to do
    /// nothing at all despite the row announcing itself as a button.
    @Test func accessibilityPerformPressTogglesExpansionLikeARealClick() {
        let (row, delegate) = makeRow()

        let handled = row.test_accessibilityPerformPress()

        #expect(handled, "accessibilityPerformPress must report it handled the press")
        #expect(delegate.toggledGroupID == "group-1")
        #expect(delegate.toggleCount == 1)
    }

    /// AXPress and a real pointer click must reach the exact same delegate
    /// call — a VoiceOver user and a mouse user get equivalent behavior.
    @Test func accessibilityPerformPressAndMouseDownFireTheSameDelegateCall() {
        let (row, delegate) = makeRow()

        row.mouseDown(with: syntheticMouseDownEvent())
        #expect(delegate.toggleCount == 1)

        row.test_accessibilityPerformPress()
        #expect(delegate.toggleCount == 2)
        #expect(delegate.toggledGroupID == "group-1")
    }

    @Test func accessibilityRoleIsButton() {
        let (row, _) = makeRow()
        #expect(row.accessibilityRole() == .button)
    }

    /// A minimal synthetic left-mouse-down event — `GroupRowView.mouseDown`
    /// never reads any field off it, so an otherwise-empty event (same
    /// factory `AppRowView`'s own tests use) is enough to drive the real
    /// override.
    private func syntheticMouseDownEvent() -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
}
