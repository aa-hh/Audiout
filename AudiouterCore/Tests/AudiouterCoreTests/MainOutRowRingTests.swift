// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
import AppKit
@testable import AudiouterCore
@testable import AudiouterPopoverUI
@testable import AudiouterSharedUI

/// The Main Out row's connection **halo ring** (Warm Signal v3 §3.2 Main Out
/// note / §6): it reflects the AGGREGATE connection state of the active Audio
/// Out target, showing the pending (dashed) ring during a destination-switch
/// handshake and the connected (solid) ring once the target is live, so the
/// multi-second gap never reads as dead/broken.
final class MainOutRowRingTests: XCTestCase {

    private func makeOptions() -> [MainOutRowView.Option] {
        [
            .init(title: "Destination", isHeader: true),
            .init(title: "Selected Devices (1)", target: .selectedDevices, buttonTitle: "Selected (1)"),
        ]
    }

    func testNoRingWhenTargetIdle() {
        let row = MainOutRowView()
        row.apply(options: makeOptions(), current: .selectedDevices, master: 50,
                  connectionState: .off)
        XCTAssertEqual(row.test_ringForm, .none, "an idle Main Out shows no ring")
    }

    func testPendingRingDuringHandshake() {
        let row = MainOutRowView()
        row.apply(options: makeOptions(), current: .selectedDevices, master: 50,
                  connectionState: .connecting)
        XCTAssertEqual(row.test_ringForm, .connecting,
                       "a destination-switch handshake shows the pending (dashed) ring (spec §6)")
    }

    func testConnectedRingWhenTargetLive() {
        let row = MainOutRowView()
        row.apply(options: makeOptions(), current: .selectedDevices, master: 50,
                  connectionState: .connected)
        XCTAssertEqual(row.test_ringForm, .connected, "a live Main Out target shows the connected ring")
    }

    func testDefaultApplyLeavesNoRing() {
        // Back-compat: callers that omit `connectionState` (the pre-S1 signature)
        // render no ring, unchanged.
        let row = MainOutRowView()
        row.apply(options: makeOptions(), current: .selectedDevices, master: 50)
        XCTAssertEqual(row.test_ringForm, .none)
    }
}
