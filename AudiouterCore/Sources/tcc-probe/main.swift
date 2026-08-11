// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Darwin   // dlopen/dlsym for the private TCC status read

/// Tiny, short-lived probe process for the per-process `TCCAccessPreflight`
/// caching bug documented on `SystemAudioCaptureTCC` (T14): a live-instrumented
/// run proved the private TCC read is cached for a process's ENTIRE lifetime —
/// after the user granted System Audio permission, a running app kept reading
/// "undetermined" for 177 consecutive ticks over 203 seconds, while a real
/// process tap in that same stale process was already capturing audio
/// successfully. Quitting and relaunching read the fresh grant on the very
/// first tick of the new process. This is a DETECTION problem, not an
/// authorization one — the cache is per-PROCESS, so a brand-new, short-lived
/// process gets a brand-new cache and a live answer with no restart needed.
/// `TCCProbeRunner` (`AudiouterCore/Sources/AudiouterCore/TCCProbeRunner.swift`)
/// is what spawns this binary and parses its output.
///
/// Deliberately duplicates `SystemAudioCaptureTCC.preflight(service:)`'s
/// dlopen/dlsym resolution rather than linking `AudiouterCore` and calling it:
/// this binary's whole reason to exist is to be minimal and fast to spawn (no
/// entitlements, no AirPlayEngine transitive dependency, exits in
/// milliseconds) — every call site of `TCCAccessPreflight` in this codebase
/// re-resolves it independently for the same reason `TCCBucketDiagnostic`
/// gives for its own duplicate: staying decoupled from files that may be under
/// concurrent edit, and here additionally keeping the binary itself tiny.
///
/// No prompts: `TCCAccessPreflight` is a preflight read, not a request — this
/// was verified over 300+ calls with zero system prompts. Nothing in this file
/// calls anything that could prompt.
///
/// ## Output contract
/// Exactly one line to stdout, always, exit code always 0 — `TCCProbeRunner`
/// is the sole reader and treats a non-zero exit, a missing binary, or a
/// malformed line as "could not resolve," NEVER as a denial:
///
///     audio=<int> screen=<int> control=<int>
///
/// Each `<int>` is `TCCAccessPreflight`'s raw return for that bucket — 0
/// granted / 1 denied / 2 undetermined — or -1 if the private framework/symbol
/// itself couldn't be resolved at all. `control` reads a deliberately BOGUS
/// service name that is verified (empirically) to always read
/// back exactly 1 when the dlsym path is actually working. A `control` value
/// other than 1 means that path is broken, so `audio`/`screen` on the same
/// line are void — `TCCProbeRunner`'s parser must treat that as a failure, not
/// as data, and must never let it collapse into `.denied`.

/// A bogus TCC service name — never a real bucket — used purely as the
/// CONTROL described above. Distinct from `TCCBucketDiagnostic`'s own bogus
/// name so the two diagnostics' telemetry never gets confused for one another.
private let bogusServiceName = "kTCCServiceAudiouterProbeBogusControl"

private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int32

/// Resolves `TCCAccessPreflight` and returns its RAW `Int32` for `service`, or
/// `nil` if the private framework/symbol can't be resolved at all — mirrors
/// `SystemAudioCaptureTCC.preflight(service:)`'s resolution exactly (see that
/// file's doc comment for why `dlopen` is never `dlclose`'d).
private func rawPreflight(_ service: String) -> Int32? {
    guard let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/TCC", RTLD_NOW),
          let symbol = dlsym(handle, "TCCAccessPreflight") else {
        return nil
    }
    let preflight = unsafeBitCast(symbol, to: PreflightFn.self)
    return preflight(service as CFString, nil)
}

private func fieldValue(_ raw: Int32?) -> Int32 {
    raw ?? -1
}

let audio = fieldValue(rawPreflight("kTCCServiceAudioCapture"))
let screen = fieldValue(rawPreflight("kTCCServiceScreenCapture"))
let control = fieldValue(rawPreflight(bogusServiceName))

print("audio=\(audio) screen=\(screen) control=\(control)")
exit(0)
