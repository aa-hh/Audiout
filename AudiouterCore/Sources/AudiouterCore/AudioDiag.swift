// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 ahh and contributors.

import Foundation

/// Env-gated file logger for diagnosing live audio-path issues that only
/// reproduce in a real `open`-launched run (per-app tap device changes, local
/// playback engine state) — stderr isn't readable there, a file is. Appends one
/// line per event to the file named by `$AIRPLAY_AUDIO_DIAG`; a complete no-op
/// (zero cost, never touches disk) when that variable is unset, so it is inert
/// in production and tests. Temporary diagnostic scaffolding.
enum AudioDiag {
    private static let handle: FileHandle? = {
        guard let path = ProcessInfo.processInfo.environment["AIRPLAY_AUDIO_DIAG"] else { return nil }
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }()
    private static let queue = DispatchQueue(label: "AudioDiag")
    /// Enabled flag read once; lets hot paths skip the closure allocation.
    static let isEnabled: Bool = ProcessInfo.processInfo.environment["AIRPLAY_AUDIO_DIAG"] != nil
    /// Reference instant every line's `[+N.NNNs]` prefix is measured from (first
    /// touch of this enum, i.e. effectively process start) — lets two log lines
    /// be subtracted by eye to read an elapsed duration between pipeline stages
    /// (e.g. connect-latency diagnosis) without threading explicit timers through
    /// call sites.
    private static let startUptimeNanos = DispatchTime.now().uptimeNanoseconds

    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled, let handle else { return }
        // `start` MUST be read into a local before "now" below: `startUptimeNanos`
        // is itself a lazily-initialized static whose initializer calls
        // `DispatchTime.now()` — on this function's very first-ever call, Swift
        // does not guarantee that lazy init runs before the RHS "now" read in a
        // single subtraction expression. Inlining that subtraction directly
        // (`DispatchTime.now().uptimeNanoseconds - startUptimeNanos`) was
        // observed to evaluate "now" first, then force startUptimeNanos's init
        // microseconds later — making start > now and trapping on UInt64
        // underflow (checked `-`). Forcing the read here, then taking "now"
        // strictly after, guarantees now >= start. `&-` is kept as a second,
        // wrapping-not-trapping line of defense rather than relying solely on
        // ordering.
        let start = startUptimeNanos
        let elapsedSeconds = Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000_000
        let line = String(format: "[+%8.3fs] ", elapsedSeconds) + message() + "\n"
        queue.async { handle.write(Data(line.utf8)) }
    }

    // Per-label counters: logs the 1st, then every 100th, tick — enough to see a
    // stream start and to notice when it stops (the count stops advancing).
    private static let tickLock = NSLock()
    private nonisolated(unsafe) static var counts: [String: Int] = [:]
    static func tick(_ key: String, detail: @autoclosure () -> String = "") {
        guard isEnabled else { return }
        tickLock.lock(); let n = (counts[key] ?? 0) + 1; counts[key] = n; tickLock.unlock()
        if n % 100 == 1 { log("tick \(key) #\(n) \(detail())") }
    }

    // MARK: Live-handle counters (tap / aggregate / IOProc leak visibility)

    /// Thread-safe create/destroy tally, keyed by a short "kind" string (e.g.
    /// `"processTap"`, `"aggregateDevice"`, `"ioProc"`). This is MECHANISM only —
    /// it carries no `isEnabled` gate of its own, deliberately: `isEnabled` is a
    /// `static let` frozen for the life of the process on first access (see
    /// above), so nothing — including a test — can ever flip it back once read.
    /// Keeping the counting logic in its own ungated type lets a test construct
    /// a fresh instance and exercise increment/decrement/dump directly, without
    /// depending on `$AIRPLAY_AUDIO_DIAG` or process/test ordering. The gate
    /// lives on the call sites below (``handleCreated(_:)`` /
    /// ``handleDestroyed(_:)``), which is where production code actually pays
    /// (or doesn't pay) for it.
    final class HandleCounter {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]

        func increment(_ kind: String) {
            lock.lock(); counts[kind, default: 0] += 1; lock.unlock()
        }

        /// Deliberately unclamped at zero: a `kind` that goes negative means
        /// something called `decrement` without a matching prior `increment` —
        /// a bookkeeping bug worth surfacing, not hiding by flooring at 0.
        func decrement(_ kind: String) {
            lock.lock(); counts[kind, default: 0] -= 1; lock.unlock()
        }

        /// Formats every tracked kind's current count, sorted by kind, e.g.
        /// `"aggregateDevice=2 ioProc=2 processTap=2"`. Deliberately does NOT
        /// omit kinds that have netted back to 0 — "created and destroyed in
        /// equal measure" is itself useful signal, not noise. Empty (nothing
        /// ever recorded) reads as a fixed sentinel string.
        func dump() -> String {
            lock.lock(); let snapshot = counts; lock.unlock()
            guard !snapshot.isEmpty else { return "(no live handles)" }
            return snapshot.keys.sorted()
                .map { "\($0)=\(snapshot[$0] ?? 0)" }
                .joined(separator: " ")
        }
    }

    /// The process-wide live-handle counters, shared by every call site below.
    /// Deliberately a separate instance from ``counts``/``tickLock`` above
    /// (different lifecycle — net create/destroy vs. a monotonic per-label
    /// tally — and different callers, so sharing one dictionary would only
    /// invite a `tick` label to collide with a handle `kind`).
    private static let liveHandles = HandleCounter()

    /// Record that a `kind` coreaudiod-side object (e.g. `"processTap"`,
    /// `"aggregateDevice"`, `"ioProc"`) was just created — call right after the
    /// Core Audio creation call returns success. No-op when diagnostics are
    /// disabled (same gating as ``log(_:)``/``tick(_:detail:)``), so this costs
    /// nothing beyond the `isEnabled` read on the hot audio path in production.
    static func handleCreated(_ kind: String) {
        guard isEnabled else { return }
        liveHandles.increment(kind)
    }

    /// Record that a `kind` coreaudiod-side object was just destroyed — call
    /// ONLY when the corresponding destroy call itself returned `noErr`. A
    /// FAILED destroy must NOT decrement: the object most likely still exists in
    /// coreaudiod, so counting it gone here would hide exactly the leak this
    /// counter exists to make visible. No-op when diagnostics are disabled.
    static func handleDestroyed(_ kind: String) {
        guard isEnabled else { return }
        liveHandles.decrement(kind)
    }

    /// The current live handle counts, formatted for logging/display — e.g.
    /// `"aggregateDevice=2 ioProc=2 processTap=2"`. Cheap (one lock-guarded
    /// dictionary read) and always safe to call; naturally reads back
    /// `"(no live handles)"` when diagnostics are disabled, since nothing was
    /// ever recorded in that case.
    static func dumpLiveHandles() -> String {
        liveHandles.dump()
    }
}
