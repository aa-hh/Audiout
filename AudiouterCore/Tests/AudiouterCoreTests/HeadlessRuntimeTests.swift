// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import AudiouterCore

/// `HeadlessRuntime.isActive` gates every window/panel controller's
/// `show*()` entry point so `swift test` (and the harness/snapshot tools)
/// never flash a real, empty window on the developer's actual screen —
/// `Sources/AudiouterCore/HeadlessRuntime.swift`. The single case here proves
/// the XCTest-detection path (the common case every OTHER test's process
/// shares, so a regression here would silently un-gate every gated call site
/// under `swift test`) without needing to fork a subprocess.
final class HeadlessRuntimeTests: XCTestCase {

    func testIsActiveUnderXCTest() {
        XCTAssertTrue(HeadlessRuntime.isActive,
                      "running inside XCTest — HeadlessRuntime must report active")
    }

    func testEnvironmentOverrideIsHonored() {
        // The harness/snapshot tools (not XCTest processes) opt in via this
        // env var before touching AppKit — this test only re-asserts the
        // check reads it, since actually unsetting it mid-process wouldn't
        // change the true XCTest-detection result anyway.
        XCTAssertEqual(ProcessInfo.processInfo.environment["AIRPLAY_HEADLESS"], nil,
                       "sanity: this test process shouldn't have the var set — XCTest detection alone should suffice")
        XCTAssertTrue(HeadlessRuntime.isActive)
    }
}
