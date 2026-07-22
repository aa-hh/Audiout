// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudiouterCore
import Foundation

/// Quits and relaunches the app so a just-granted system-audio permission
/// becomes visible to the process. See ``AppRelaunchCommand`` for *why* a
/// relaunch is required (the process-tap TCC grant is cached at launch and has
/// no live status API).
///
/// This is the non-visual mechanism behind a "Quit & Reopen" affordance: the
/// setup UI decides *when* to offer it, then wires the button's action to
/// ``relaunch()``. Nothing here draws anything.
enum AppRelauncher {

    /// Spawn a detached waiter that reopens the bundle once this instance has
    /// exited, then begin a graceful termination.
    ///
    /// `NSApp.terminate(_:)` still runs `applicationShouldTerminate`, so the
    /// backend tears down cleanly (its "Disconnecting…" path) and the PTP
    /// session/ports are released *before* the waiter relaunches — the waiter
    /// blocks on our pid, so the new instance can't race the old one for the
    /// exclusive PTP ports.
    @MainActor
    static func relaunch() {
        let argv = AppRelaunchCommand.shellInvocation(
            pid: ProcessInfo.processInfo.processIdentifier,
            bundlePath: Bundle.main.bundlePath)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: argv[0])
        task.arguments = Array(argv.dropFirst())
        do {
            // The child is reparented to launchd when we exit, so it survives to
            // do the reopen.
            try task.run()
        } catch {
            // If we can't even spawn the waiter, don't quit into nothing — leave
            // the app running so the user isn't left worse off than before.
            NSLog("[Audiouter] relaunch failed to spawn waiter: \(error)")
            return
        }
        NSApp.terminate(nil)
    }
}
