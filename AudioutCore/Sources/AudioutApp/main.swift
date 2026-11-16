// Audiout — pure-AppKit menu-bar app entry point.
//
// SPDX-License-Identifier: GPL-2.0-or-later
//
// A regular app with a Dock icon and menu bar beside its NSStatusItem, and no
// window on launch. Per RESOLVED Q1 the app is a SwiftPM executable;
// scripts/make-app.sh wraps this binary into a real double-clickable `.app`.
//
// SwiftPM treats `main.swift` as the executable's top-level entry, so the
// bootstrap lives here rather than behind `@main` (which SwiftPM executable
// targets don't use when a `main.swift` is present).

import AppKit
import os

// Associated-object key that keeps the delegate alive for the app's lifetime.
private nonisolated(unsafe) var delegateKey = 0

// MARK: - Process-level crash-safety bootstrap (D1/D2)
//
// These two calls MUST run before anything else touches a socket, a pipe, or
// Objective-C exception machinery — including `AppDelegate` construction
// below, which can log to stderr.

// D1. Mask SIGPIPE process-wide, at the very first instruction. The native
// engine also masks SIGPIPE once it starts (AirPlayEngine.swift), but that
// happens well into launch and only on the native backend — the mock backend
// and the whole pre-engine-start window are otherwise exposed. A dead stderr pipe (routine for a dev
// launch from a terminal) or any closed socket write would otherwise kill
// the process outright on the default SIGPIPE disposition. `SIG_IGN` here is
// idempotent with the engine's later `engine_mask_sigpipe()` call.
signal(SIGPIPE, SIG_IGN)

// D2. Install an uncaught-exception handler so an aborting ObjC exception
// leaves a breadcrumb before this dockless accessory app silently vanishes
// from the menu bar. Diagnostic only: it logs and lets the abort proceed —
// it does not attempt recovery or continuation.
private let bootstrapLog = Logger(subsystem: "com.audiout.Audiout", category: "uncaught-exception")

NSSetUncaughtExceptionHandler { exception in
    let name = exception.name.rawValue
    let reason = exception.reason ?? "<no reason>"
    let stack = exception.callStackSymbols.joined(separator: "\n")
    let message = "[Audiout] FATAL uncaught exception: \(name): \(reason)\n\(stack)\n"

    audioutEmergencyWriteStderr(message)
    bootstrapLog.fault("FATAL uncaught exception: \(name, privacy: .public): \(reason, privacy: .public)\n\(stack, privacy: .public)")
}

// Bootstrap on the main actor. `main.swift`'s top-level code runs on the main
// thread, but the compiler treats it as non-isolated, so we hop onto the main
// actor explicitly to build the (MainActor-isolated) `AppDelegate` and set it
// on the shared application. `AppDelegate` is retained by the app.
MainActor.assumeIsolated {
    // One shared application instance. The activation policy is set in the
    // delegate's applicationWillFinishLaunching.
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
