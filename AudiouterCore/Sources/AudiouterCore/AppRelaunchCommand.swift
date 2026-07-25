// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Pure construction of the detached relaunch command, factored out of the
/// AppKit relaunch (`AppRelauncher` in the app target) so it can be unit-tested
/// without spawning a process or terminating the app.
///
/// ## Why a relaunch was once the only option — and no longer is
/// **CORRECTED 2026-07-25 (measured on a signed build; this comment previously
/// claimed the opposite and was wrong on both counts).**
///
/// The old claim was that the grant is "only readable via
/// `CGPreflightScreenCaptureAccess()`, cached when the process launched". Both
/// halves are false. That call reads the *Screen Recording* list, which an
/// audio-only app is never listed in — it returned `false` in a process where
/// capture demonstrably worked. The grant is read from
/// `kTCCServiceAudioCapture` via the private `TCCAccessPreflight`
/// (``SystemAudioCaptureTCC``).
///
/// What IS true — and is the real constraint — is that `TCCAccessPreflight` is
/// cached **for the lifetime of the process**, not merely at launch: after the
/// user granted, the in-process read stayed "undetermined" for 203 s and never
/// moved, while a freshly spawned helper read "granted" in the same second.
/// Crucially, a real process tap **captured audio successfully in that stale
/// process** — macOS had authorised it; the app simply could not find out. So
/// this was always a DETECTION problem, never an authorisation one, and a
/// relaunch was never required by the OS.
///
/// Detection is now handled live by ``PermissionStateObserver`` (event-driven)
/// reading through ``TCCProbeRunner``, which spawns a short-lived helper whose
/// cache is necessarily fresh. This type therefore survives only as a
/// user-offered escape hatch, not as the mechanism.
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
