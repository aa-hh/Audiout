// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 ahh and contributors.

import Foundation

/// Always-on, structured, size-bounded JSON-lines decision log for the
/// subsystems that have produced "only reproduces live, no evidence to read
/// afterward" bugs (see `docs/plans/PLAN-TELEMETRY-SYSTEM.md`). Appends one
/// JSON object per line to a stable file under `~/Library/Logs/Audiouter/` so
/// an agent can `Read`/grep it, days later, with no special permission (the
/// app is not sandboxed).
///
/// Generalizes `AudioDiag`'s shape (static facade, off-thread serial queue, an
/// `isEnabled` fast-path) but always-on rather than env-var-gated, structured
/// JSON rather than free text, and size-bounded with rotation so it can run
/// in every session indefinitely rather than being temporary diagnostic
/// scaffolding.
///
/// - **Non-blocking:** `log(_:_:_:)` formats its line on the CALLER's thread
///   (cheap — string building only, no I/O) then hands it to an internal
///   serial queue. It never calls back into the caller and never blocks the
///   caller on disk I/O.
/// - **Fails safe:** any directory/file/write error is swallowed. This must
///   never throw and never crash the host app — see `Writer.appendToDisk`.
/// - **Neutralized under tests:** `isEnabled` is false whenever
///   `HeadlessRuntime.isActive` (`swift test` and the harness/snapshot
///   tools), so the suite never writes or rotates a real file and never
///   races itself under `swift test --parallel`. `TelemetryTests` re-arms
///   writing for its own process via `_resetForTesting`/`_installTestSink` —
///   the two test seams below — so it can exercise the real writer against
///   an injected directory without ever touching the production path.
/// - **MUST NOT be called from the real-time IOProc/render path** — only
///   from the (non-realtime) decision points around it (serial-queue /
///   main-thread state machines).
public enum Telemetry {

    /// One of the subsystems this instruments (PLAN-TELEMETRY-SYSTEM.md §A):
    /// `permission` (TCC gate checks + reported-vs-actual divergence),
    /// `captureWS` (whole-system capture state transitions), `capturePA`
    /// (per-app capture transitions + sample-rate rebuilds), `airplay`
    /// (bind/rebind/session-reset + device-selection decisions),
    /// `localPlayback` (the local `AVAudioEngine` sink: engine start/config-
    /// change recovery, per-app player attach, and the synced-local session
    /// anchor — `LocalPlaybackEngine`/`SyncedLocalSink`), `lifecycle`
    /// (process/session boundaries — currently just the launch banner
    /// emitted below), and `cast` (Cast session lifecycle + 1 s media-status
    /// samples).
    public enum Category: String, Sendable {
        case permission, captureWS, capturePA, airplay, localPlayback, lifecycle, cast
    }

    /// Non-blocking. Formats `{"ts":...,"sid":...,"cat":...,"evt":...,
    /// ...fields}` on the caller's thread, then hands the finished line to
    /// the writer's serial queue. A no-op when `isEnabled` is false. Emits a
    /// one-line `lifecycle`/`session_start` banner ahead of the first line of
    /// any new session (see the `sid` field), so a reader can find session
    /// boundaries in the file.
    public static func log(_ category: Category, _ event: StaticString, _ fields: [String: String] = [:]) {
        let snapshot: (sessionID: String, directory: URL, sink: Sink?)? = state.withLock { s in
            guard s.enabled else { return nil }
            return (s.sessionID, s.directoryOverride ?? defaultDirectory, s.sink)
        }
        guard let snapshot else { return }
        let line = formattedLine(sessionID: snapshot.sessionID, category: category, event: event, fields: fields)
        Writer.shared.write(line, sessionID: snapshot.sessionID, directory: snapshot.directory, sink: snapshot.sink)
    }

    /// False whenever `HeadlessRuntime.isActive` (`swift test`, harness/
    /// snapshot tools) — unless this process has explicitly re-armed writing
    /// via `_resetForTesting(directory:)` or `_installTestSink(_:)`, the
    /// escape hatch `TelemetryTests` uses to exercise the real writer.
    public static var isEnabled: Bool { state.withLock { $0.enabled } }

    // MARK: - Test seams

    /// Redirects all writes to `directory` (or, when `nil`, fully resets to
    /// the default disabled-under-`HeadlessRuntime` state) and starts a fresh
    /// session (new `sid`, fresh session banner on the next line). Mirrors
    /// `GroupStore.init(directory:)`'s directory-injection idiom so tests
    /// never touch `~/Library/Logs/Audiouter/`. Also acts as a flush
    /// barrier: because the writer queue is serial/FIFO, every write
    /// enqueued before this call has completed by the time it returns.
    public static func _resetForTesting(directory: URL?) {
        state.withLock { s in
            s = State()
            s.directoryOverride = directory
        }
        Writer.shared.barrier()
    }

    /// Installs an in-memory capture sink: when non-nil, `log(...)` calls it
    /// with the finished line INSTEAD OF writing to disk — a lighter-weight
    /// seam than `_resetForTesting` for suites that just want to assert "did
    /// this emit the expected line" without touching the filesystem at all.
    /// A non-nil sink also re-arms `isEnabled` for this process, the same
    /// escape hatch as `_resetForTesting`. Also acts as a flush barrier (see
    /// above). Pass `nil` to remove it.
    public static func _installTestSink(_ sink: (@Sendable (String) -> Void)?) {
        state.withLock { $0.sink = sink }
        Writer.shared.barrier()
    }

    // MARK: - Implementation

    /// A test sink receives the exact line that would otherwise be written to
    /// disk (JSON, no trailing newline).
    typealias Sink = @Sendable (String) -> Void

    private struct State: Sendable {
        var sessionID = UUID().uuidString
        var directoryOverride: URL?
        var sink: Sink?

        /// Always-on except under `HeadlessRuntime.isActive` (`swift test`),
        /// where it stays off unless a test explicitly opted back in by
        /// setting an override directory or installing a sink.
        var enabled: Bool { !HeadlessRuntime.isActive || directoryOverride != nil || sink != nil }
    }

    /// Minimal `NSLock`-guarded box — generalizes `AudioDiag`'s `tickLock`/
    /// `counts` pattern in this same package so `log(...)` can read/mutate a
    /// few small fields from ANY caller thread cheaply, without hopping onto
    /// the writer's serial queue just to check whether it's enabled.
    private final class Locked<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value
        init(_ value: Value) { self.value = value }
        func withLock<R>(_ body: (inout Value) -> R) -> R {
            lock.lock()
            defer { lock.unlock() }
            return body(&value)
        }
    }

    private static let state = Locked(State())

    /// Owns the actual disk I/O. Everything below is touched only from
    /// `queue`'s closures (queue confinement — the same pattern as
    /// `MockBackend`/`CaptureCoordinator`/`DACPServer` in this package), so
    /// `@unchecked Sendable` is honest.
    private final class Writer: @unchecked Sendable {
        static let shared = Writer()
        private let queue = DispatchQueue(label: "com.audiouter.telemetry", qos: .utility)

        /// The `sid` this writer last opened a session banner for. Compared
        /// (not just a bool) so a `_resetForTesting` mid-process — a new
        /// `sid` — naturally gets its own fresh banner with no separate reset
        /// plumbing needed, and so two threads racing to log the first line
        /// of a new session can never emit the banner twice: both the check
        /// and both writes happen serially on `queue`, never interleaved.
        private var lastBannerSessionID: String?

        func write(_ line: String, sessionID: String, directory: URL, sink: Sink?) {
            queue.async {
                if self.lastBannerSessionID != sessionID {
                    self.lastBannerSessionID = sessionID
                    let banner = Telemetry.formattedLine(sessionID: sessionID, category: .lifecycle,
                                                          event: "session_start", fields: Telemetry.bannerFields())
                    self.emit(banner, directory: directory, sink: sink)
                }
                self.emit(line, directory: directory, sink: sink)
            }
        }

        /// A synchronous no-op round-trip through `queue`. Because `queue` is
        /// serial/FIFO, every write enqueued before this call is guaranteed
        /// complete by the time it returns — the mechanism behind both test
        /// seams' "flush barrier" behavior above.
        func barrier() {
            queue.sync {}
        }

        private func emit(_ line: String, directory: URL, sink: Sink?) {
            if let sink {
                sink(line)
                return
            }
            Self.appendToDisk(line, directory: directory)
        }

        /// Append `line` (+ `"\n"`) to `directory`'s active file, rotating
        /// first if it's at the per-file cap. Simple and correct beats
        /// clever: reopen the file fresh on every call (like `DACPServer.
        /// debugLog`) rather than keeping a handle around — trivially
        /// correct across rotation, relaunch, and an external `rm`, at the
        /// cost of one extra `stat`/`open`/`close` per line, which is fine
        /// for a decision log (this is never the per-buffer render path).
        ///
        /// Fails safe: any error here (can't create the directory, can't
        /// open the file, a disk-full/permission write failure, or an
        /// NSException bridged via `catchingObjCException`) is swallowed —
        /// never thrown, never crashes the host app.
        private static func appendToDisk(_ line: String, directory: URL) {
            guard let data = (line + "\n").data(using: .utf8) else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let activePath = directory.appendingPathComponent(Telemetry.fileName).path
            let backupPath = directory.appendingPathComponent(Telemetry.rotatedFileName).path

            let currentSize: Int = {
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: activePath) else { return 0 }
                return (attrs[.size] as? Int) ?? 0
            }()
            if currentSize > 0 && currentSize + data.count > Telemetry.perFileCapBytes {
                try? FileManager.default.removeItem(atPath: backupPath)
                try? FileManager.default.moveItem(atPath: activePath, toPath: backupPath)
            }
            if !FileManager.default.fileExists(atPath: activePath) {
                FileManager.default.createFile(atPath: activePath, contents: nil)
            }
            guard let handle = FileHandle(forWritingAtPath: activePath) else { return }
            handle.seekToEndOfFile()
            do {
                try catchingObjCException {
                    try handle.write(contentsOf: data)
                }
            } catch {
                // Swallowed — see doc comment above. Disk-full, permission
                // errors, and bridged NSExceptions all land here and are
                // dropped; the next log() call gets a fresh, independent try.
            }
            try? handle.close()
        }
    }

    /// `~/Library/Logs/Audiouter/` — created lazily by `Writer.appendToDisk`,
    /// not here (a pure path computation, mirroring `GroupStore.
    /// defaultDirectory`). Tests never touch this — they inject `directory`
    /// via `_resetForTesting`.
    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Audiouter", isDirectory: true)
    }

    static let fileName = "telemetry.jsonl"
    static let rotatedFileName = "telemetry.jsonl.1"

    /// Q3: ~10 MB total footprint across the active file + one rotated
    /// backup.
    static let totalCapBytes = 10 * 1024 * 1024
    static let defaultPerFileCapBytes = totalCapBytes / 2

    /// Test-only override so `TelemetryTests` can force rotation in a few KB
    /// instead of writing real megabytes. `nil` in production.
    static var testPerFileCapBytesOverride: Int?
    private static var perFileCapBytes: Int { testPerFileCapBytesOverride ?? defaultPerFileCapBytes }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    /// `{"ts":"...","sid":"...","cat":"...","evt":"...", ...fields (sorted by
    /// key, for deterministic output)}` — the line schema fixed by
    /// PLAN-TELEMETRY-SYSTEM.md §C.
    private static func formattedLine(sessionID: String, category: Category, event: StaticString, fields: [String: String]) -> String {
        var parts: [String] = []
        parts.reserveCapacity(4 + fields.count)
        parts.append("\"ts\":\"\(jsonEscaped(timestampFormatter.string(from: Date())))\"")
        parts.append("\"sid\":\"\(jsonEscaped(sessionID))\"")
        parts.append("\"cat\":\"\(category.rawValue)\"")
        parts.append("\"evt\":\"\(jsonEscaped(event.description))\"")
        for key in fields.keys.sorted() {
            parts.append("\"\(jsonEscaped(key))\":\"\(jsonEscaped(fields[key] ?? ""))\"")
        }
        return "{" + parts.joined(separator: ",") + "}"
    }

    /// Escapes `s` for embedding as a JSON string VALUE (quotes/backslashes/
    /// control characters). Hand-rolled rather than `JSONSerialization`
    /// because the four required keys need a fixed leading order (`ts`,
    /// `sid`, `cat`, `evt`) for a human/agent skimming the file — a plain
    /// dictionary has no guaranteed key order.
    private static func jsonEscaped(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    /// Session-banner fields: app version/build (never hardcoded — read
    /// live, same idiom as `AboutInfo.current`) + macOS version. The uuid
    /// itself is `sid`, already on every line, so it isn't repeated here.
    private static func bannerFields() -> [String: String] {
        let info = Bundle.main.infoDictionary
        return [
            "ver": (info?["CFBundleShortVersionString"] as? String) ?? "dev",
            "build": (info?["CFBundleVersion"] as? String) ?? "-",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
        ]
    }
}
