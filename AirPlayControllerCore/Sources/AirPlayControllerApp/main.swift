// AirPlay Controller — pure-AppKit menu-bar app entry point.
//
// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Alec Henderson and contributors.
//
// This is a menu-bar-only ("accessory") app: no Dock icon, no main menu bar,
// no window on launch — just an NSStatusItem. Per RESOLVED Q1 the app is a
// SwiftPM executable; scripts/make-app.sh wraps this binary into a real
// double-clickable `.app` (Info.plist with LSUIElement=true, ad-hoc signed).
//
// SwiftPM treats `main.swift` as the executable's top-level entry, so the
// bootstrap lives here rather than behind `@main` (which SwiftPM executable
// targets don't use when a `main.swift` is present).

import AppKit

// Associated-object key that keeps the delegate alive for the app's lifetime.
private nonisolated(unsafe) var delegateKey = 0

// Bootstrap on the main actor. `main.swift`'s top-level code runs on the main
// thread, but the compiler treats it as non-isolated, so we hop onto the main
// actor explicitly to build the (MainActor-isolated) `AppDelegate` and set it
// on the shared application. `AppDelegate` is retained by the app.
MainActor.assumeIsolated {
    // One shared application instance. `.accessory` is set in the delegate's
    // applicationWillFinishLaunching (before the app finishes launching) so the
    // process never briefly shows a Dock icon (belt-and-suspenders alongside
    // the bundle's LSUIElement=true — see the brief §4 "App runs .accessory").
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // Retain the delegate for the process lifetime (NSApplication holds a weak
    // reference to its delegate).
    objc_setAssociatedObject(app, &delegateKey, delegate, .OBJC_ASSOCIATION_RETAIN)
}

// Hands control to AppKit's run loop; returns only after `NSApp.terminate(_:)`.
// The delegate owns startup (status item, backend) and teardown.
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
