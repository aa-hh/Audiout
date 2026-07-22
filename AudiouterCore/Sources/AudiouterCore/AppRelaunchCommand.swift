// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Pure construction of the detached relaunch command, factored out of the
/// AppKit relaunch (`AppRelauncher` in the app target) so it can be unit-tested
/// without spawning a process or terminating the app.
///
/// ## Why the app has to relaunch at all
/// The system-audio-capture (Core Audio process-tap) TCC grant is only readable
/// via `CGPreflightScreenCaptureAccess()`, which returns the value **cached when
/// the process launched**. A grant the user makes *while the app is running*
/// stays invisible until the process relaunches — there is no live, silent
/// status API for this permission bucket (that is the whole reason
/// ``CoreAudioTonePermissionProbe`` resorts to an audible self-test tone). So
/// once the user enables the permission in System Settings, the only way for the
/// running app to pick it up is to relaunch — exactly what macOS's own
/// "Quit & Reopen" dialog does for the same grant.
///
/// This type builds the shell invocation that performs that relaunch; the
/// AppKit side spawns it detached and then terminates the app gracefully.
public enum AppRelaunchCommand {

    /// A `/bin/sh -c` argv that waits for `pid` to fully exit — releasing the
    /// exclusive PTP ports (319/320) and tearing down the audio/TCC session —
    /// and only *then* reopens the bundle, so the fresh process reads the
    /// now-current permission decision.
    ///
    /// Waiting for exit (rather than `open -n` for an immediate second instance)
    /// is deliberate: two overlapping instances would fight over the exclusive
    /// PTP ports and the shared bundle id (`com.audiouter.Audiouter`).
    ///
    /// - Parameters:
    ///   - pid: the current process's pid, captured before termination begins.
    ///   - bundlePath: `Bundle.main.bundlePath` — the `.app` to reopen.
    public static func shellInvocation(pid: Int32, bundlePath: String) -> [String] {
        let quoted = singleQuoted(bundlePath)
        // `kill -0` succeeds while the pid is alive; the loop ends once it exits.
        // `exec` replaces the shell with `open` so no shell lingers afterward.
        let script = "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; exec /usr/bin/open \(quoted)"
        return ["/bin/sh", "-c", script]
    }

    /// POSIX single-quote escaping so a bundle path containing spaces or quotes
    /// survives the `sh -c` round-trip. This app's own path routinely contains a
    /// space (e.g. `.../AirPlay Controller/...`), so this is load-bearing, not
    /// hypothetical. Wrap in single quotes and replace each embedded `'` with the
    /// `'\''` idiom (close-quote, escaped literal quote, reopen-quote).
    public static func singleQuoted(_ raw: String) -> String {
        "'" + raw.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
