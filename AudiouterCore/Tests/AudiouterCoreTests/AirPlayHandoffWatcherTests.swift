// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 ahh and contributors.

import Foundation
import Testing

@testable import AudiouterCore

@Suite final class AirPlayHandoffWatcherTests: IsolatedSuite {
    // MARK: - Part 1: BlockedAirPlayAttempt.matches table

    @Test("BlockedAirPlayAttempt matches real line")
    func matchesRealLine() {
        let line = """
        {"subsystem":"com.apple.airplay","category":"APSNetworkClockPTP","eventMessage":"[0xB198] Failed to add peer: -536870203/0xE00002C5 kIOReturnExclusiveAccess"}
        """
        #expect(BlockedAirPlayAttempt.matches(ndjsonLine: line))
    }

    @Test("BlockedAirPlayAttempt matches version without hex token")
    func matchesVersionWithoutHexToken() {
        let line = """
        {"subsystem":"com.apple.airplay","category":"APSNetworkClockPTP","eventMessage":"Failed to add peer: kIOReturnExclusiveAccess"}
        """
        #expect(BlockedAirPlayAttempt.matches(ndjsonLine: line))
    }

    @Test("BlockedAirPlayAttempt matches version without constant name")
    func matchesVersionWithoutConstantName() {
        let line = """
        {"subsystem":"com.apple.airplay","category":"APSNetworkClockPTP","eventMessage":"got error -536870203/0xE00002C5"}
        """
        #expect(BlockedAirPlayAttempt.matches(ndjsonLine: line))
    }

    @Test("BlockedAirPlayAttempt rejects header line")
    func rejectsHeaderLine() {
        let line = """
        Filtering the log data using "subsystem == \"com.apple.airplay\" AND category == \"APSNetworkClockPTP\""
        """
        #expect(!BlockedAirPlayAttempt.matches(ndjsonLine: line))
    }

    @Test("BlockedAirPlayAttempt rejects malformed JSON")
    func rejectsMalformedJSON() {
        let line = """
        {"subsystem": "com.apple.airplay",
        """
        #expect(!BlockedAirPlayAttempt.matches(ndjsonLine: line))
    }

    @Test("BlockedAirPlayAttempt rejects benign message")
    func rejectsBenignMessage() {
        let line = """
        {"subsystem":"com.apple.airplay","category":"APSNetworkClockPTP","eventMessage":"[0xB198] APSNetworkClock PTP started"}
        """
        #expect(!BlockedAirPlayAttempt.matches(ndjsonLine: line))
    }

    @Test("BlockedAirPlayAttempt rejects wrong subsystem")
    func rejectsWrongSubsystem() {
        let line = """
        {"subsystem":"com.apple.example","category":"APSNetworkClockPTP","eventMessage":"Failed to add peer: kIOReturnExclusiveAccess"}
        """
        #expect(!BlockedAirPlayAttempt.matches(ndjsonLine: line))
    }

    @Test("BlockedAirPlayAttempt rejects wrong category")
    func rejectsWrongCategory() {
        let line = """
        {"subsystem":"com.apple.airplay","category":"APSenderSessionAirPlay","eventMessage":"Failed to add peer: kIOReturnExclusiveAccess"}
        """
        #expect(!BlockedAirPlayAttempt.matches(ndjsonLine: line))
    }

    @Test("BlockedAirPlayAttempt rejects empty string")
    func rejectsEmptyString() {
        #expect(!BlockedAirPlayAttempt.matches(ndjsonLine: ""))
    }

    @Test("BlockedAirPlayAttempt rejects JSON array")
    func rejectsJSONArray() {
        let line = "[1,2,3]"
        #expect(!BlockedAirPlayAttempt.matches(ndjsonLine: line))
    }

    // MARK: - Part 2: AirPlayHandoffWatcher lifecycle

    @Test("start() twice is idempotent")
    func startTwiceIsIdempotent() async {
        let fake = FakeLogStream()
        let watcher = AirPlayHandoffWatcher(
            spawn: fake,
            rateLimit: 0.15,
            respawnBaseDelay: 0.02,
            respawnMaxAttempts: 5,
            onBlockedAttempt: {}
        )

        watcher.start()
        watcher.start()

        #expect(fake.startCallCount == 1)
    }

    @Test("matching line fires onBlockedAttempt once")
    func matchingLineFiresOnBlockedAttemptOnce() async {
        let fake = FakeLogStream()
        var fireCount = 0
        let watcher = AirPlayHandoffWatcher(
            spawn: fake,
            rateLimit: 0.15,
            respawnBaseDelay: 0.02,
            respawnMaxAttempts: 5,
            onBlockedAttempt: { fireCount += 1 }
        )

        watcher.start()
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms for async setup

        let line = """
        {"subsystem":"com.apple.airplay","category":"APSNetworkClockPTP","eventMessage":"Failed to add peer: kIOReturnExclusiveAccess"}
        """
        fake.pushLine(line)
        try? await Task.sleep(nanoseconds: 10_000_000) // 10ms for callback

        #expect(fireCount == 1)
    }

    @Test("rate limiting: two lines within window fires once")
    func rateLimitingTwoLinesWithinWindowFiresOnce() async {
        let fake = FakeLogStream()
        var fireCount = 0
        // Wide window (R4 #5): pushes land ~10ms apart against a 2s window, so
        // even heavy suite-contention oversleep cannot push the second line past
        // the limit and flip the expectation (Task.sleep only ever oversleeps).
        let watcher = AirPlayHandoffWatcher(
            spawn: fake,
            rateLimit: 2.0,
            respawnBaseDelay: 0.02,
            respawnMaxAttempts: 5,
            onBlockedAttempt: { fireCount += 1 }
        )

        watcher.start()
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms

        let line = """
        {"subsystem":"com.apple.airplay","category":"APSNetworkClockPTP","eventMessage":"Failed to add peer: kIOReturnExclusiveAccess"}
        """
        // NO await between the two pushes: pushLine→handleLine→callback is fully
        // synchronous, and any Task.sleep here can stretch past ANY finite window
        // under full-suite load (found live: a "10ms" sleep exceeded the window
        // and double-fired). Back-to-back pushes land microseconds apart —
        // deterministic against a 2s window regardless of machine load.
        fake.pushLine(line)
        fake.pushLine(line)

        #expect(fireCount == 1)
    }

    @Test("rate limiting: third line after window fires second")
    func rateLimitingThirdLineAfterWindowFiresSecond() async {
        let fake = FakeLogStream()
        var fireCount = 0
        let watcher = AirPlayHandoffWatcher(
            spawn: fake,
            rateLimit: 0.15,
            respawnBaseDelay: 0.02,
            respawnMaxAttempts: 5,
            onBlockedAttempt: { fireCount += 1 }
        )

        watcher.start()
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms

        let line = """
        {"subsystem":"com.apple.airplay","category":"APSNetworkClockPTP","eventMessage":"Failed to add peer: kIOReturnExclusiveAccess"}
        """
        let firstPush = ProcessInfo.processInfo.systemUptime
        fake.pushLine(line)
        fake.pushLine(line) // back-to-back: within window by construction, ignored
        // Cross the window against the SAME monotonic clock the limiter reads —
        // sleeping a fixed interval is load-dependent in both directions, but
        // "loop until the clock says the window has provably elapsed" cannot lie.
        while ProcessInfo.processInfo.systemUptime - firstPush < 0.25 { // rateLimit 0.15 + margin
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        fake.pushLine(line) // outside window, should fire (synchronous)

        #expect(fireCount == 2)
    }

    @Test("non-matching lines fire nothing")
    func nonMatchingLinesFireNothing() async {
        let fake = FakeLogStream()
        var fireCount = 0
        let watcher = AirPlayHandoffWatcher(
            spawn: fake,
            rateLimit: 0.15,
            respawnBaseDelay: 0.02,
            respawnMaxAttempts: 5,
            onBlockedAttempt: { fireCount += 1 }
        )

        watcher.start()
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms

        let benignLine = """
        {"subsystem":"com.apple.airplay","category":"APSNetworkClockPTP","eventMessage":"[0xB198] APSNetworkClock PTP started"}
        """
        fake.pushLine(benignLine)
        try? await Task.sleep(nanoseconds: 10_000_000) // 10ms

        #expect(fireCount == 0)
    }

    @Test("stop() calls spawn.stop()")
    func stopCallsSpawnStop() async {
        let fake = FakeLogStream()
        let watcher = AirPlayHandoffWatcher(
            spawn: fake,
            rateLimit: 0.15,
            respawnBaseDelay: 0.02,
            respawnMaxAttempts: 5,
            onBlockedAttempt: {}
        )

        watcher.start()
        try? await Task.sleep(nanoseconds: 50_000_000)

        watcher.stop()

        #expect(fake.stopCallCount == 1)
    }

    @Test("line after stop() fires nothing")
    func lineAfterStopFiresNothing() async {
        let fake = FakeLogStream()
        var fireCount = 0
        let watcher = AirPlayHandoffWatcher(
            spawn: fake,
            rateLimit: 0.15,
            respawnBaseDelay: 0.02,
            respawnMaxAttempts: 5,
            onBlockedAttempt: { fireCount += 1 }
        )

        watcher.start()
        try? await Task.sleep(nanoseconds: 50_000_000)
        watcher.stop()
        try? await Task.sleep(nanoseconds: 10_000_000)

        let line = """
        {"subsystem":"com.apple.airplay","category":"APSNetworkClockPTP","eventMessage":"Failed to add peer: kIOReturnExclusiveAccess"}
        """
        fake.pushLine(line)
        try? await Task.sleep(nanoseconds: 10_000_000)

        #expect(fireCount == 0)
    }

    @Test("unexpected termination schedules respawn")
    func unexpectedTerminationSchedulesRespawn() async {
        let fake = FakeLogStream()
        let watcher = AirPlayHandoffWatcher(
            spawn: fake,
            rateLimit: 0.15,
            respawnBaseDelay: 0.02,
            respawnMaxAttempts: 5,
            onBlockedAttempt: {}
        )

        watcher.start()
        try? await Task.sleep(nanoseconds: 50_000_000)

        let initialCount = fake.startCallCount
        fake.pushTermination()

        // Poll for respawn with deadline (0.15s is safe since backoff starts at 0.02s)
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline && fake.startCallCount == initialCount {
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }

        #expect(fake.startCallCount == initialCount + 1)
    }

    @Test("respawn gives up after max attempts")
    func respawnGivesUpAfterMaxAttempts() async {
        let fake = FakeLogStream(alwaysThrows: true)
        let watcher = AirPlayHandoffWatcher(
            spawn: fake,
            rateLimit: 0.15,
            respawnBaseDelay: 0.02,
            respawnMaxAttempts: 5,
            onBlockedAttempt: {}
        )

        watcher.start()

        // Poll for stabilization at 5 attempts (backoff sequence: 0.02, 0.04,
        // 0.08, 0.16, 0.32 = ~0.62s total). Deadline is ~8x the sum (R4 #6) so
        // suite contention cannot time the poll out before attempt 6 would fire.
        let deadline = Date().addingTimeInterval(5.0)
        var lastCount = fake.startCallCount
        var stableCount = 0
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
            let currentCount = fake.startCallCount
            if currentCount == lastCount {
                stableCount += 1
                // Stability must OUTLAST the largest backoff gap (0.32s before
                // the 6th spawn), or the loop declares "done" mid-sequence at 5
                // spawns and asserts before give-up ever runs — the exact flake
                // this suite's first real execution caught. 10 polls = 500ms.
                if stableCount >= 10 {
                    break
                }
            } else {
                stableCount = 0
            }
            lastCount = currentCount
        }

        #expect(fake.startCallCount == 6) // 1 initial + 5 respawn attempts
        #expect(watcher.test_isRunning == false, "give-up must leave the watcher stopped (R4 #9)")
    }

    @Test("termination after stop() does not respawn")
    func terminationAfterStopDoesNotRespawn() async {
        let fake = FakeLogStream()
        let watcher = AirPlayHandoffWatcher(
            spawn: fake,
            rateLimit: 0.15,
            respawnBaseDelay: 0.02,
            respawnMaxAttempts: 5,
            onBlockedAttempt: {}
        )

        watcher.start()
        try? await Task.sleep(nanoseconds: 50_000_000)

        let countAfterStart = fake.startCallCount
        watcher.stop()
        #expect(watcher.test_isRunning == false, "stop() must mark the watcher stopped (R4 #9)")
        try? await Task.sleep(nanoseconds: 10_000_000)
        // The fake deliberately keeps its captured onTermination closure after
        // stop() (see FakeLogStream.stop), so this push genuinely reaches the
        // watcher's own stale-generation guard — the behavior under test.
        fake.pushTermination()
        try? await Task.sleep(nanoseconds: 300_000_000) // 15x the 0.02s backoff — a scheduled respawn would have fired

        #expect(fake.startCallCount == countAfterStart)
    }

    @Test("failed start() does not crash and schedules respawn")
    func failedStartDoesNotCrashAndSchedulesRespawn() async {
        let fake = FakeLogStream()
        fake.throwsOnce = true
        let watcher = AirPlayHandoffWatcher(
            spawn: fake,
            rateLimit: 0.15,
            respawnBaseDelay: 0.02,
            respawnMaxAttempts: 5,
            onBlockedAttempt: {}
        )

        watcher.start()
        let countAfterFailure = fake.startCallCount
        #expect(countAfterFailure == 1)

        // Poll for respawn (first backoff is 0.02s)
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline && fake.startCallCount == countAfterFailure {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(fake.startCallCount == 2)
    }

    @Test("stop() cancels pending respawn")
    func stopCancelsPendingRespawn() async {
        let fake = FakeLogStream()
        // R4 #7: a LARGE backoff (0.4s) for this one test buys real headroom —
        // the 5ms gap between termination and stop() is now 80x inside the
        // backoff window, so stop() provably lands while the respawn is still
        // pending rather than racing it.
        let watcher = AirPlayHandoffWatcher(
            spawn: fake,
            rateLimit: 0.15,
            respawnBaseDelay: 0.4,
            respawnMaxAttempts: 5,
            onBlockedAttempt: {}
        )

        watcher.start()
        try? await Task.sleep(nanoseconds: 50_000_000)

        let countAfterStart = fake.startCallCount
        // NO await between the termination and stop(): a sleep here can stretch
        // past the 0.4s backoff under full-suite load (found live), letting the
        // respawn fire before stop() ever ran. Both calls are synchronous —
        // back-to-back guarantees stop() lands while the respawn is pending.
        fake.pushTermination() // schedules a respawn at +0.4s
        watcher.stop()          // cancels it (generation bump) microseconds later
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s — well past the 0.4s backoff

        #expect(fake.startCallCount == countAfterStart)
    }
}

// MARK: - FakeLogStream

private final class FakeLogStream: LogStreamSpawning, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    var throwsOnce = false
    let alwaysThrows: Bool

    private var onLine: ((String) -> Void)?
    private var onTermination: (() -> Void)?
    private var isRunningState = false

    init(alwaysThrows: Bool = false) {
        self.alwaysThrows = alwaysThrows
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return isRunningState
    }

    func start(
        onLine: @escaping @Sendable (String) -> Void,
        onTermination: @escaping @Sendable () -> Void
    ) throws {
        lock.lock()
        defer { lock.unlock() }

        // Count EVERY invocation BEFORE the idempotency guard. The watcher's own
        // start() guard is what the idempotency test asserts — if this fake's
        // guard swallowed a second call uncounted, a broken watcher guard would
        // still pass vacuously (review R4 finding #3).
        startCallCount += 1
        guard !isRunningState else { return }

        if alwaysThrows || throwsOnce {
            if throwsOnce {
                throwsOnce = false
            }
            throw NSError(domain: "test", code: 1, userInfo: nil)
        }

        isRunningState = true
        self.onLine = onLine
        self.onTermination = onTermination
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }

        stopCallCount += 1
        isRunningState = false
        // Deliberately do NOT nil onLine/onTermination: a line or termination
        // pushed after stop() must still REACH THE WATCHER so its own post-stop
        // guards (generation check, running flag) are what the tests exercise —
        // nilling here made those tests pass vacuously (review R4 findings #1/#2;
        // mirrors the sibling fake in AggregateOutputDeviceTests, which keeps its
        // captured closures for exactly this reason).
    }

    func pushLine(_ line: String) {
        lock.lock()
        let onLineCapture = onLine
        lock.unlock()

        onLineCapture?(line)
    }

    func pushTermination() {
        lock.lock()
        let onTerminationCapture = onTermination
        isRunningState = false
        lock.unlock()

        onTerminationCapture?()
    }
}
