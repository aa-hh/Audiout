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
/// Detection is three-pronged so no caller has to remember an env var for the
/// common case:
/// - **XCTest**: detected by checking whether the `XCTest` framework is loaded
///   into the process (`NSClassFromString("XCTestCase")`) — reliable regardless
///   of *how* the test binary was invoked, unlike undocumented XCTest env vars.
/// - **swift-testing**: detected the same way in spirit, but `Testing` is a
///   pure-Swift module with no Objective-C classes, so `NSClassFromString`
///   cannot see it. Instead we `dlsym` a symbol that only exists when the
///   `Testing` module is linked into the process (see `isSwiftTestingLoaded`).
///   This matters because this repo's suites are migrating from XCTest to
///   swift-testing: today `swift test` still drags `XCTest` in as long as ANY
///   file in the target imports it, but once the last `import XCTest` is gone
///   that is no longer guaranteed — and an un-detected test run means real,
///   empty windows flashing on the developer's screen for the run's duration.
///   Both checks are kept: mid-migration either one fires, end-state the
///   swift-testing one does, and a legacy XCTest-only target still works.
/// - `swift run <harness-or-snapshot-tool>`: these are neither, so each tool's
///   `main()` sets `AIRPLAY_HEADLESS=1` in its own environment (or the invoking
///   shell does) before touching AppKit. The REAL app (`AudioutApp`) never
///   sets this, links neither test library, and so always shows its windows.
public enum HeadlessRuntime {
    /// True when running under `swift test` (XCTest **or** swift-testing) or a
    /// headless harness/snapshot tool; false for a normal launch of the real app.
    public static var isActive: Bool {
        if ProcessInfo.processInfo.environment["AIRPLAY_HEADLESS"] == "1" { return true }
        return isXCTestLoaded || isSwiftTestingLoaded
    }

    /// True when Apple's `XCTest` framework is in the process image.
    static var isXCTestLoaded: Bool {
        NSClassFromStringIfLinked("XCTestCase") != nil
    }

    /// True when the swift-testing (`Testing`) module is in the process image.
    ///
    /// `Testing` exposes no Objective-C classes, so the `NSClassFromString`
    /// trick above does not work on it. What it does export is ordinary Swift
    /// metadata symbols, which `dlsym` against `RTLD_DEFAULT` (every globally
    /// loaded image, including the test bundle) can find. `$s7Testing4TestVMn`
    /// is the mangled name of the **nominal type descriptor for
    /// `Testing.Test`** — `$s` prefix, `7Testing` module, `4Test` type, `V`
    /// struct, `Mn` nominal type descriptor. `Testing.Test` is the public type
    /// backing the `@Test` attribute itself, so it cannot disappear without the
    /// library's entire public surface changing.
    ///
    /// Computed once: the answer cannot change during a process's lifetime, and
    /// `isActive` is read from window-presentation paths that can run per-frame.
    /// A second candidate (`Testing.Issue`) is probed too, so a rename of one
    /// type does not silently disable window gating.
    static let isSwiftTestingLoaded: Bool = {
        let candidates = [
            "$s7Testing4TestVMn",   // nominal type descriptor for Testing.Test
            "$s7Testing5IssueVMn",  // nominal type descriptor for Testing.Issue
        ]
        return candidates.contains { symbolIsLinked($0) }
    }()
}

/// `NSClassFromString` needs `Foundation`'s Objective-C runtime bridge, which
/// is always available on Darwin — a thin wrapper so the intent reads clearly
/// at the call site above (avoids importing `ObjectiveC` directly here).
private func NSClassFromStringIfLinked(_ name: String) -> AnyClass? {
    NSClassFromString(name)
}

/// True when `symbol` resolves anywhere in the process's globally loaded
/// images. `RTLD_DEFAULT` is `-2` on Darwin and is not exposed to Swift as a
/// constant, hence the `bitPattern:` construction.
private func symbolIsLinked(_ symbol: String) -> Bool {
    let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
    return dlsym(rtldDefault, symbol) != nil
}
