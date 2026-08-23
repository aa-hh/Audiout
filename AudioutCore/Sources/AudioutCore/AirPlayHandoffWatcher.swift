// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 ahh and contributors.

import Foundation

/// While Audiout streams AirPlay it exclusively holds UDP 319/320 (PTP
/// clock). If the user tries to switch the Mac's own output to an AirPlay
/// device via the macOS Sound dropdown, macOS dies on the port bind and logs
/// — unredacted — subsystem `com.apple.airplay`, category
/// `APSNetworkClockPTP`, an `eventMessage` containing
/// `"Failed to add peer: -536870203/0xE00002C5 kIOReturnExclusiveAccess"`
/// (~0.9s after the click; exactly one line per attempt; measured 6/6 over
/// 24h on this machine, zero spurious hits). This watcher spawns
/// `/usr/bin/log stream` filtered to that category and fires a callback once
/// per detected blocked attempt, so the backend can release the ports and
/// the user's retry succeeds.
///
/// Best-effort by contract: if the line changes in a macOS update, or log
/// access is unavailable (non-admin user), it degrades silently — equal to
/// pre-feature behavior. Measured cost of the stream: 0.0% CPU / ~10ms total
/// over 20s / 2.9MB RSS; a matching event reaches the pipe in milliseconds.
/// The alternative, `OSLogStore(scope: .system)`, works unprivileged here too
/// but costs ~0.13s of system CPU per poll and only polls — hence the
/// subprocess.
///
/// razor: best-effort. Capped-backoff respawn only — no OSLogStore fallback,
/// no second matcher. If the child keeps dying or the line changes, we
/// degrade to release-on-deselect, which equals pre-feature behaviour.

/// Pure decision core — no I/O. Testable with canned lines.
enum BlockedAirPlayAttempt {
    /// Verified sample that MUST match: eventMessage =
    /// `"[0xB198] Failed to add peer: -536870203/0xE00002C5 kIOReturnExclusiveAccess"`,
    /// subsystem = `"com.apple.airplay"`, category = `"APSNetworkClockPTP"`.
    /// Deliberately does NOT match on `messageType`, `processImagePath`,
    /// `formatString`, or the `[0xB198]` prefix — those are real in today's
    /// output but are extra rot points versus a macOS update.
    static func matches(ndjsonLine: String) -> Bool {
        let trimmed = ndjsonLine.trimmingCharacters(in: .whitespacesAndNewlines)
        // `log stream --style ndjson` writes its human header ("Filtering the
        // log data using …") to STDOUT (not stderr) as its own newline-
        // terminated line — verified live 2026-07-27 on this machine: stderr
        // carried 0 bytes, and all 4,376 real ndjson lines observed start
        // with `{`. This guard is what REJECTS that header line; load-bearing,
        // not belt-and-braces.
        guard trimmed.hasPrefix("{") else { return false }
        guard let data = trimmed.data(using: .utf8) else { return false }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else { return false }
        guard dict["subsystem"] as? String == "com.apple.airplay" else { return false }
        guard dict["category"] as? String == "APSNetworkClockPTP" else { return false }
        guard let message = dict["eventMessage"] as? String else { return false }
        return message.contains("kIOReturnExclusiveAccess") || message.contains("0xE00002C5")
    }
}

/// The injectable seam for the `log stream` subprocess, mirroring
/// `CaptureProcess`'s shape so `AirPlayHandoffWatcher` can be unit-tested
/// hermetically with a fake that emits scripted lines and simulates
/// crash/exit without ever spawning the real binary.
protocol LogStreamSpawning: AnyObject, Sendable {
    /// Idempotent while running. `onLine` may be called on any thread.
    func start(onLine: @escaping @Sendable (String) -> Void,
               onTermination: @escaping @Sendable () -> Void) throws
    /// Idempotent; MUST terminate the child.
    func stop()
    var isRunning: Bool { get }
}

/// `LogStreamSpawning` backed by `Foundation.Process`, spawning
/// `/usr/bin/log stream` filtered to the PTP-clock category. Shape is
/// modeled on `AudiocapProcess` (`CaptureProcess.swift`) but deliberately
/// diverges in three ways a review (D1/D2) found unsafe here: `run()` happens
/// INSIDE the lock (no window where a live child is unpublished and
/// therefore unreapable), each launch gets its own one-shot `OnceFlag`
/// instead of one instance-wide flag (so an old child's terminationHandler
/// can never suppress a newer child's real termination), and `fireTermination`
/// only clears the instance's `process`/`outputPipe` when they still identify
/// the launch that is terminating (so an old child's late termination can
/// never clobber a newer child's bookkeeping).
final class LogStreamProcess: LogStreamSpawning, @unchecked Sendable {

    private let lock = NSLock()
    private var process: Process?
    private var outputPipe: Pipe?

    init() {}

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return process?.isRunning ?? false
    }

    func start(
        onLine: @escaping @Sendable (String) -> Void,
        onTermination: @escaping @Sendable () -> Void
    ) throws {
        lock.lock()
        guard process == nil else { lock.unlock(); return }

        let proc = Process()
        // Absolute path mandatory: `log` is a zsh builtin, a bare name via
        // env lookup can resolve wrongly.
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        proc.arguments = [
            "stream", "--style", "ndjson", "--predicate",
            "subsystem == \"com.apple.airplay\" AND category == \"APSNetworkClockPTP\""
        ]
        // No --level flag: the target line is Error level and the default
        // stream level includes it (verified).

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        let buffer = LineBuffer()
        // Per-launch once-guard (D2): a shared instance-level flag would
        // permanently block onTermination after the FIRST child's exit,
        // silently swallowing every later launch's real termination.
        let onceFlag = OnceFlag()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            for line in buffer.append(data) { onLine(line) }
        }

        proc.terminationHandler = { [weak self] p in
            pipe.fileHandleForReading.readabilityHandler = nil
            // Flush any trailing partial line.
            for line in buffer.flush() { onLine(line) }
            guard onceFlag.tryFire() else { return }
            self?.fireTermination(onTermination, for: p)
        }

        // D1: publish `process`/`outputPipe` only AFTER a successful launch,
        // still holding the lock — no unlocked window in which stop() could
        // observe "no process" for a child that is, in fact, live and would
        // then never be reaped.
        do {
            try proc.run()
            process = proc
            outputPipe = pipe
            lock.unlock()
        } catch {
            lock.unlock()
            pipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }
    }

    func stop() {
        lock.lock()
        let proc = process
        lock.unlock()
        // Deliberately does NOT nil `process`/`outputPipe` here (D2): doing
        // so eagerly would let a subsequent start() begin a second launch
        // while this one is still winding down. Instead, SIGTERM this child
        // and let its own terminationHandler (identity-checked, below) clear
        // the fields once it actually exits — the only launch that is ever
        // "current" is the one whose process is still recorded.
        guard let proc, proc.isRunning else { return }
        proc.terminate() // SIGTERM
    }

    /// Only clears the instance's `process`/`outputPipe` when they still
    /// identify THIS launch's child (D2) — an old child's terminationHandler
    /// firing after a newer child has since been started under the same
    /// instance must never clobber the newer child's bookkeeping.
    private func fireTermination(_ handler: @escaping @Sendable () -> Void, for proc: Process) {
        lock.lock()
        if process === proc {
            process = nil
            outputPipe = nil
        }
        lock.unlock()
        handler()
    }
}

/// Per-launch once-guard captured fresh by each `start()` call (never shared
/// across launches) so `Process.terminationHandler` invoking `onTermination`
/// exactly once is guaranteed per launch, independent of whether the
/// instance's `process` field has since moved on to a newer child (D2).
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func tryFire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !fired else { return false }
        fired = true
        return true
    }
}

/// Watches for the AirPlay-handoff-blocked log line and fires
/// `onBlockedAttempt` (rate-limited) so the backend can release the PTP
/// ports and let the user's retry succeed. Best-effort: see the razor
/// comment at the top of this file. All mutable state is behind `lock`.
final class AirPlayHandoffWatcher: @unchecked Sendable {

    private let spawn: LogStreamSpawning
    private let rateLimit: TimeInterval
    private let respawnBaseDelay: TimeInterval
    private let respawnMaxAttempts: Int
    private let onBlockedAttempt: @Sendable () -> Void

    private let lock = NSLock()
    private var running = false
    /// Bumped on every start()/stop(); a scheduled respawn compares its
    /// captured generation and no-ops if stale (child from a prior run, or a
    /// respawn timer that outlived an intervening stop()).
    private var generation = 0
    private var respawnAttempt = 0
    /// Monotonic (`ProcessInfo.systemUptime`), not wall-clock (D5): a
    /// backward clock step must not suppress rate-limiting or the health
    /// reset below.
    private var lastFireTime: Double?
    /// Timestamp of the last spawn ATTEMPT, not the last successful spawn
    /// (D3) — set unconditionally in `attemptSpawn()` before the throwing
    /// call, so a run of immediate spawn failures doesn't keep re-arming the
    /// 60s health-reset and defeat backoff forever.
    private var lastSpawnTime: Double?

    /// - Parameter onBlockedAttempt: invoked synchronously on the log
    ///   stream's pipe I/O thread (never the main thread) — the caller must
    ///   hop to its own queue before touching any shared state.
    init(
        spawn: LogStreamSpawning = LogStreamProcess(),
        rateLimit: TimeInterval = 5,
        respawnBaseDelay: TimeInterval = 1,
        respawnMaxAttempts: Int = 5,
        onBlockedAttempt: @escaping @Sendable () -> Void
    ) {
        self.spawn = spawn
        self.rateLimit = rateLimit
        self.respawnBaseDelay = respawnBaseDelay
        self.respawnMaxAttempts = respawnMaxAttempts
        self.onBlockedAttempt = onBlockedAttempt
    }

    var test_isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    /// Idempotent while already running.
    func start() {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        respawnAttempt = 0
        generation += 1
        lock.unlock()
        attemptSpawn()
    }

    /// Idempotent; cancels any pending respawn (via the generation bump) and
    /// stops the child. Runs unconditionally (D6) — even after the give-up
    /// path has already set `running = false` — so an app-quit stop() can
    /// still reap a child; `spawn.stop()` is documented idempotent.
    func stop() {
        lock.lock()
        running = false
        generation += 1
        lock.unlock()
        spawn.stop()
    }

    private func attemptSpawn() {
        lock.lock()
        guard running else { lock.unlock(); return }
        let myGeneration = generation
        // D3: record the ATTEMPT here, unconditionally — including the path
        // where spawn.start() below throws — not only a successful launch.
        lastSpawnTime = ProcessInfo.processInfo.systemUptime
        lock.unlock()

        do {
            try spawn.start(
                onLine: { [weak self] line in self?.handleLine(line) },
                onTermination: { [weak self] in
                    self?.handleUnexpectedTermination(generation: myGeneration)
                }
            )
        } catch {
            Telemetry.log(.airplay, "handoff_watcher_spawn_failed", [:])
            scheduleRespawnOrGiveUp(generation: myGeneration)
        }
    }

    private func handleLine(_ line: String) {
        guard BlockedAirPlayAttempt.matches(ndjsonLine: line) else { return }

        lock.lock()
        // A line can arrive AFTER stop(): SIGTERM is asynchronous, and buffered
        // pipe data keeps flowing until the child actually exits. A stopped
        // watcher must never fire — the consumer's release path treats a fire as
        // live user intent (behavior table: "a line pushed after stop() fires
        // nothing").
        guard running else {
            lock.unlock()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastFireTime, now - last < rateLimit {
            lock.unlock()
            return
        }
        lastFireTime = now
        lock.unlock()

        onBlockedAttempt()
        Telemetry.log(.airplay, "handoff_blocked_attempt", [:])
    }

    private func handleUnexpectedTermination(generation myGeneration: Int) {
        lock.lock()
        let stillOurs = running && myGeneration == generation
        lock.unlock()
        // A termination arriving after stop() (or from a superseded child)
        // must not respawn.
        guard stillOurs else { return }

        Telemetry.log(.airplay, "handoff_watcher_exited", [:])
        scheduleRespawnOrGiveUp(generation: myGeneration)
    }

    /// Shared by both the spawn-throws path and the unexpected-termination
    /// path: increments the attempt counter (after a lazy 60s health-reset —
    /// see below), gives up past `respawnMaxAttempts`, otherwise schedules
    /// `attemptSpawn()` behind uncapped exponential backoff (D8 — see below).
    ///
    /// razor: the 60s "child survives, earn back retries" reset is checked
    /// lazily here — right before counting this new failure — rather than
    /// via a dedicated 60s timer. One fewer scheduled callback for the same
    /// observable behavior.
    private func scheduleRespawnOrGiveUp(generation myGeneration: Int) {
        lock.lock()
        guard running, myGeneration == generation else { lock.unlock(); return }

        if let lastSpawn = lastSpawnTime, ProcessInfo.processInfo.systemUptime - lastSpawn >= 60 {
            respawnAttempt = 0
        }
        respawnAttempt += 1
        let currentAttempt = respawnAttempt

        guard currentAttempt <= respawnMaxAttempts else {
            running = false
            lock.unlock()
            Telemetry.log(.airplay, "handoff_watcher_gave_up", [:])
            return
        }
        lock.unlock()

        // D8: uncapped doubling — with base 1s and 5 attempts the sequence is
        // [1,2,4,8,16]; a max-delay cap is unreachable at this attempt count,
        // so `respawnMaxAttempts` is the only bound that matters.
        let delay = respawnBaseDelay * pow(2, Double(currentAttempt - 1))
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard self.running, self.generation == myGeneration else {
                self.lock.unlock()
                return
            }
            self.lock.unlock()
            self.attemptSpawn()
        }
    }
}
