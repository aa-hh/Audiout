// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import AppKit
@testable import AudioutCore
@testable import AudioutSharedUI
@testable import AudioutWindowUI

/// The group editor's membership rows: what a click lands on, and whether an
/// edit made there reaches the card overview.
@MainActor
struct GroupEditorClickTargetTests {

    private func warmRow() -> MembershipRowView {
        let device = Device(id: "d1", name: "Speaker", kind: .sonos,
                            isAvailable: true, volume: 50)
        let row = MembershipRowView(device: device, checked: false, surface: .warmPane)
        row.frame = NSRect(x: 0, y: 0, width: 320, height: MembershipRowView.rowHeight)
        row.layoutSubtreeIfNeeded()
        return row
    }

    /// The rail node and the name are ONE click target (live report: the name
    /// toggled membership and the node looked dead). The invisible checkbox's
    /// own frame is narrower than the drawn disc, so a click aimed at the node
    /// used to land on the button or the row depending on a boundary the user
    /// cannot see. Every hit now resolves to the row, which runs the same
    /// `performToggle` the checkbox does.
    @Test func theNodeAndTheNameAreTheSameClickTarget() {
        let row = warmRow()
        let midY = row.bounds.midY
        let node = row.hitTest(NSPoint(x: PopoverColumnGrid.railGutterCenterX, y: midY))
        let name = row.hitTest(NSPoint(x: 200, y: midY))
        #expect(node === row, "a click on the rail node reaches the row")
        #expect(name === row, "so does a click on the name")
    }

    /// The stock sheet keeps AppKit's own hit-testing: its checkbox is visible
    /// and the row is not an affordance.
    @Test func theSystemSheetRowKeepsStockHitTesting() {
        let device = Device(id: "d1", name: "Speaker", kind: .sonos,
                            isAvailable: true, volume: 50)
        let row = MembershipRowView(device: device, checked: false, surface: .systemSheet)
        row.frame = NSRect(x: 0, y: 0, width: 320, height: MembershipRowView.rowHeight)
        row.layoutSubtreeIfNeeded()
        // Its checkbox sits at the leading edge and takes its own clicks.
        let hit = row.hitTest(NSPoint(x: 4, y: row.bounds.midY))
        #expect(hit is NSButton, "the stock row's visible checkbox is the click target")
    }
}
