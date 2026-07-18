// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Detects whether the current process is a HEADLESS tool run — `swift test`,
/// or one of the offscreen harness/snapshot executables (`window-harness`,
/// `window-snapshot`, `popover-harness`, `settings-snapshot`, …) — rather than
/// a real, human-facing launch of the app.
///
/// Every window/panel controller's `show*()` entry point (`showWindow()`,
/// `show(anchorRect:)`, …) calls `NSApp.activate` + `makeKeyAndOrderFront` to
/// actually put itself on screen — correct for the real app, but those exact
/// same code paths are also what `swift test` and the harness/snapshot tools
/// exercise to build and assert a controller's structure. Because those
/// processes hold a normal WindowServer connection (they aren't sandboxed into
/// a virtual display), an un-gated `makeKeyAndOrderFront` there puts a real,
/// empty, uninteractive window on the ACTUAL screen for the run's duration —
/// disruptive noise with no product value. `HeadlessRuntime.isActive` lets
/// every such call site skip `activate`/`orderFront` while still exercising
/// every other line (layout, constraints, model wiring) so headless assertions
/// stay exactly as strong as before.
///
/// Detection is two-pronged so no caller has to remember an env var for the
/// common case:
/// - `swift test` (and Xcode's XCTest runner): detected by checking whether
///   the `XCTest` framework is loaded into the process — reliable regardless
///   of *how* the test binary was invoked, unlike undocumented XCTest env vars.
/// - `swift run <harness-or-snapshot-tool>`: these aren't XCTest processes, so
///   each tool's `main()` sets `AIRPLAY_HEADLESS=1` in its own environment (or
///   the invoking shell does) before touching AppKit. The REAL app
///   (`AudiouterApp`) never sets this — a live launch always shows its windows.
public enum HeadlessRuntime {
    /// True when running under `swift test` or a headless harness/snapshot
    /// tool; false for a normal launch of the real app.
    public static var isActive: Bool {
        if ProcessInfo.processInfo.environment["AIRPLAY_HEADLESS"] == "1" { return true }
        return NSClassFromStringIfLinked("XCTestCase") != nil
    }
}

/// `NSClassFromString` needs `Foundation`'s Objective-C runtime bridge, which
/// is always available on Darwin — a thin wrapper so the intent reads clearly
/// at the call site above (avoids importing `ObjectiveC` directly here).
private func NSClassFromStringIfLinked(_ name: String) -> AnyClass? {
    NSClassFromString(name)
}
