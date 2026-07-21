// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
import AppKit
@testable import AudiouterCore
@testable import AudiouterPopoverUI

/// Guards the **real AppKit action-dispatch path** of the Main Out destination
/// pop-up — the seam where group activation silently broke.
///
/// Every other Main Out selection test (`PopoverControllerTests`, and the
/// `test_select` hook) drives selection by calling the delegate directly, which
/// bypasses AppKit entirely. That is exactly why a real regression slipped
/// through green tests: each `NSMenuItem` carries its own `target`/`action`, and
/// when the user clicks one AppKit invokes that action **passing the menu item
/// as the sender**. The handler had been typed to expect the `NSPopUpButton`
/// instead, so a real click either misfired or crashed — while the shortcut
/// (delegate-direct) stayed happy.
///
/// These tests reproduce the genuine dispatch: they fetch the live `NSMenuItem`
/// and `perform` its own `action` with the item as sender, precisely as menu
/// tracking does. If the handler's sender type or `representedObject` decoding
/// regresses, `perform` sends an `NSPopUpButton`-only selector (e.g.
/// `indexOfSelectedItem`) to an `NSMenuItem` and the test fails loudly instead
/// of passing while the feature is dead.
final class MainOutRowMenuDispatchTests: XCTestCase {

    private final class RecordingDelegate: MainOutRowView.Delegate {
        var selectedTargets: [MainOutTarget] = []
        func mainOutRow(_ row: MainOutRowView, didSelect target: MainOutTarget) {
            selectedTargets.append(target)
        }
        func mainOutRowBeginMasterDrag(_ row: MainOutRowView) {}
        func mainOutRow(_ row: MainOutRowView, didSetMaster volume: Int) {}
        func mainOutRowEndMasterDrag(_ row: MainOutRowView) {}
        func mainOutRow(_ row: MainOutRowView, didSetMuted muted: Bool) {}
    }

    /// The two-section shape a real host builds: "Selected Devices" + one saved
    /// group under an "Output Groups" header. `current` selects the checkmark.
    private func makeRow(current: MainOutTarget = .selectedDevices)
        -> (MainOutRowView, RecordingDelegate)
    {
        let row = MainOutRowView()
        let delegate = RecordingDelegate()
        row.delegate = delegate
        row.apply(options: [
            .init(title: "Selected Devices (2)", target: .selectedDevices,
                  buttonTitle: "Selected (2)"),
            .init(title: "Output Groups", isHeader: true),
            .init(title: "tester", target: .group(id: "g1")),
        ], current: current, master: 50)
        return (row, delegate)
    }

    /// Faithfully reproduces AppKit menu tracking: invoke the menu item's OWN
    /// `action` on its OWN `target`, passing the item as sender.
    private func fire(_ item: NSMenuItem) {
        guard let action = item.action, let target = item.target as? NSObject else {
            return XCTFail("menu item is missing its target/action wiring")
        }
        _ = target.perform(action, with: item)
    }

    // MARK: Structural — the fix's core invariant

    func testGroupMenuItemCarriesItsTargetAsRepresentedObject() {
        let (row, _) = makeRow()
        let item = row.test_menuItem(for: .group(id: "g1"))
        XCTAssertNotNil(item, "the 'tester' group must have a real, selectable menu item")
        XCTAssertEqual(item?.representedObject as? MainOutTarget, .group(id: "g1"),
                       "the group item must carry its MainOutTarget so the handler can decode it")
    }

    func testOutputGroupsHeaderIsDisabledAndInert() {
        let (row, _) = makeRow()
        // The header renders via an uppercased `attributedTitle`, which is what
        // `NSMenuItem.title` reports back.
        let header = row.test_menuItem(titled: "OUTPUT GROUPS")
        XCTAssertNotNil(header, "the 'Output Groups' section header must exist")
        XCTAssertFalse(header?.isEnabled ?? true,
                       "the header must be disabled so it can't be clicked like a real choice")
        XCTAssertNil(header?.representedObject,
                     "the header carries no target — clicking it must route nowhere")
    }

    // MARK: Behavioral — the regression guard

    /// The test that would have caught the original bug: clicking the group
    /// (via the real action path) must route Main Out to that group.
    func testFiringGroupMenuItemRoutesToThatGroup() {
        let (row, delegate) = makeRow(current: .selectedDevices)
        guard let item = row.test_menuItem(for: .group(id: "g1")) else {
            return XCTFail("no group menu item to fire")
        }
        fire(item)
        XCTAssertEqual(delegate.selectedTargets, [.group(id: "g1")],
                       "firing the group's real menu action must select that group")
    }

    /// The other direction: firing "Selected Devices" routes back to it, proving
    /// the dispatch reads each item's own target rather than a fixed index.
    func testFiringSelectedDevicesMenuItemRoutesToSelectedDevices() {
        let (row, delegate) = makeRow(current: .group(id: "g1"))
        guard let item = row.test_menuItem(for: .selectedDevices) else {
            return XCTFail("no Selected Devices menu item to fire")
        }
        fire(item)
        XCTAssertEqual(delegate.selectedTargets, [.selectedDevices],
                       "firing the Selected Devices menu action must select it")
    }
}
