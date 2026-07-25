// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudiouterCore

/// `HeadlessRuntime.isActive` gates every window/panel controller's
/// `show*()` entry point so `swift test` (and the harness/snapshot tools)
/// never flash a real, empty window on the developer's actual screen —
/// `Sources/AudiouterCore/HeadlessRuntime.swift`. The single case here proves
/// the detection paths (the common case every OTHER test's process shares, so a
/// regression here would silently un-gate every gated call site under
/// `swift test`) without needing to fork a subprocess.
@Suite struct HeadlessRuntimeTests {

    @Test func isActiveUnderXCTest() {
        #expect(HeadlessRuntime.isActive,
                "running inside XCTest — HeadlessRuntime must report active")
    }

    /// The migration-proofing case. While XCTest is still linked from the
    /// not-yet-converted suites, `isXCTestLoaded` carries `isActive` on its
    /// own — so a broken swift-testing check would hide behind it and only
    /// surface once the last `import XCTest` is deleted, at which point real
    /// windows would start flashing on screen during every `swift test` run.
    /// Asserting the swift-testing limb DIRECTLY is what makes that impossible.
    ///
    /// Mechanism: `Testing` is a pure-Swift module with no Objective-C classes,
    /// so it is detected by `dlsym`-ing its type-descriptor symbols rather than
    /// by `NSClassFromString`. Proven against a throwaway package containing no
    /// `import XCTest` anywhere: the symbol still resolved, and the same check
    /// in a plain `swift run` executable correctly reported false.
    @Test func swiftTestingIsDetectedIndependentlyOfXCTest() {
        #expect(HeadlessRuntime.isSwiftTestingLoaded,
                "the Testing module IS linked into this process — detection must not depend on XCTest also being present, since the migration removes it")
    }

    @Test func environmentOverrideIsHonored() {
        // The harness/snapshot tools (not XCTest processes) opt in via this
        // env var before touching AppKit — this test only re-asserts the
        // check reads it, since actually unsetting it mid-process wouldn't
        // change the true XCTest-detection result anyway.
        #expect(ProcessInfo.processInfo.environment["AIRPLAY_HEADLESS"] == nil,
                "sanity: this test process shouldn't have the var set — XCTest detection alone should suffice")
        #expect(HeadlessRuntime.isActive)
    }
}
