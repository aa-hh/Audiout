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

    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled, let handle else { return }
        let line = message() + "\n"
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
}
