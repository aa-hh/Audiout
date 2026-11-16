// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 ahh and contributors.

import Foundation
import Testing

@testable import AudioutCore

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
        let manual = ManualDelayClock()
        let watcher = AirPlayHandoffWatcher(
            spawn: fake,
            rateLimit: 0.15,
            respawnBaseDelay: 0.02,
            respawnMaxAttempts: 5,
            onBlockedAttempt: {},
            uptime: manual.uptime,
            delay: manual.clock
        )

        watcher.start()
        watcher.start()

        #expect(fake.startCallCount == 1)
    }

    @Test("matching line fires onBlockedAttempt once")
    func matchingLineFiresOnBlockedAttemptOnce() async {
        let fake = FakeLogStream()
        let manual = ManualDelayClock()
        var fireCount = 0
        let watcher = AirPlayHandoffWatcher(
            spawn: fake,
            rateLimit: 0.15,
            respawnBaseDelay: 0.02,
            respawnMaxAttempts: 5,
            onBlockedAttempt: { fireCount += 1 },
            uptime: manual.uptime,
            delay: manual.clock
        )

        watcher.start()

        let line = """
        {"subsystem":"com.apple.airplay","category":"APSNetworkClockPTP","eventMessage":"Failed to add peer: kIOReturnExclusiveAccess"}
        """
        fake.pushLine(line)

        #expect(fireCount == 1)
    }

    @Test("rate limiting: two lines within window fires once")
    func rateLimitingTwoLinesWithinWindowFiresOnce() async {
        let fake = FakeLogStream()
        let manual = ManualDelayClock()
        var fireCount = 0
        // The manual clock never moves, so the two pushes are 0 s apart against a 2 s window.
        let watcher = AirPlayHandoffWatcher(
            spawn: fake,
            rateLimit: 2.0,
            respawnBaseDelay: 0.02,
            respawnMaxAttempts: 5,
            onBlockedAttempt: { fireCount += 1 },
            uptime: manual.uptime,
            delay: manual.clock
        )

        watcher.start()

        let line = """
        {"subsystem":"com.apple.airplay","category":"APSNetworkClockPTP","eventMessage":"Failed to add peer: kIOReturnExclusiveAccess"}
        """
        fake.pushLine(line)
        fake.pushLine(line)

        #expect(fireCount == 1)
    }

    @Test("rate limiting: third line after window fires second")
    func rateLimitingThirdLineAfterWindowFiresSecond() async {
        let fake = FakeLogStream()
        let manual = ManualDelayClock()
        var fireCount = 0
        let watcher = AirPlayHandoffWatcher(
            spawn: fake,
            rateLimit: 0.15,
            respawnBaseDelay: 0.02,
            respawnMaxAttempts: 5,
            onBlockedAttempt: { fireCount += 1 },
            uptime: manual.uptime,
            delay: manual.clock
        )

        watcher.start()

        let line = """
        {"subsystem":"com.apple.airplay","category":"APSNetworkClockPTP","eventMessage":"Failed to add peer: kIOReturnExclusiveAccess"}
        """
        fake.pushLine(line)
        fake.pushLine(line) // back-to-back: within window by construction, ignored
        manual.advance(by: 0.25) // past rateLimit 0.15, on the clock the limiter reads
        fake.pushLine(line) // outside window, should fire (synchronous)

        #expect(fireCount == 2)
    }

    @Test("non-matching lines fire nothing")
    func nonMatchingLinesFireNothing() async {
        let fake = FakeLogStream()
        let manual = ManualDelayClock()
        var fireCount = 0
        let watcher = AirPlayHandoffWatcher(
            spawn: fake,
            rateLimit: 0.15,
            respawnBaseDelay: 0.02,
            respawnMaxAttempts: 5,
            onBlockedAttempt: { fireCount += 1 },
            uptime: manual.uptime,
            delay: manual.clock
        )

        watcher.start()

        let benignLine = """
        {"subsystem":"com.apple.airplay","category":"APSNetworkClockPTP","eventMessage":"[0xB198] APSNetworkClock PTP started"}
        """
        fake.pushLine(benignLine)

        #expect(fireCount == 0)
    }

    @Test("stop() calls spawn.stop()")
    func stopCallsSpawnStop() async {
        let fake = FakeLogStream()
        let manual = ManualDelayClock()
        let watcher = AirPlayHandoffWatcher(
            spawn: fake,
            rateLimit: 0.15,
            respawnBaseDelay: 0.02,
            respawnMaxAttempts: 5,
            onBlockedAttempt: {},
            uptime: manual.uptime,
            delay: manual.clock
        )

        watcher.start()

        watcher.stop()

        #expect(fake.stopCallCount == 1)
    }

    @Test("line after stop() fires nothing")
    func lineAfterStopFiresNothing() async {
        let fake = FakeLogStream()
        let manual = ManualDelayClock()
        var fireCount = 0
        let watcher = AirPlayHandoffWatcher(
            spawn: fake,
            rateLimit: 0.15,
            respawnBaseDelay: 0.02,
            respawnMaxAttempts: 5,
            onBlockedAttempt: { fireCount += 1 },
            uptime: manual.uptime,
            delay: manual.clock
        )

        watcher.start()
        watcher.stop()

        let line = """
        {"subsystem":"com.apple.airplay","category":"APSNetworkClockPTP","eventMessage":"Failed to add peer: kIOReturnExclusiveAccess"}
        """
        fake.pushLine(line)

        #expect(fireCount == 0)
    }

    @Test("unexpected termination schedules respawn")
    func unexpectedTerminationSchedulesRespawn() async {
        let fake = FakeLogStream()
        let manual = ManualDelayClock()
        let watcher = AirPlayHandoffWatcher(
            spawn: fake,
            rateLimit: 0.15,
            respawnBaseDelay: 0.02,
            respawnMaxAttempts: 5,
            onBlockedAttempt: {},
            uptime: manual.uptime,
            delay: manual.clock
        )

        watcher.start()

        let initialCount = fake.startCallCount
        fake.pushTermination()
        manual.advance(by: 0.02)

        #expect(fake.startCallCount == initialCount + 1)
    }

    @Test("respawn gives up after max attempts")
    func respawnGivesUpAfterMaxAttempts() async {
        let fake = FakeLogStream(alwaysThrows: true)
        let manual = ManualDelayClock()
        let watcher = AirPlayHandoffWatcher(
            spawn: fake,
            rateLimit: 0.15,
            respawnBaseDelay: 0.02,
            respawnMaxAttempts: 5,
            onBlockedAttempt: {},
            uptime: manual.uptime,
            delay: manual.clock
        )

        watcher.start()

        // Backoff sequence 0.02, 0.04, 0.08, 0.16, 0.32: each advance fires the one
        // respawn that came due, which fails and schedules the next.
        for step in 0..<5 { manual.advance(by: 0.02 * pow(2, Double(step))) }

        #expect(fake.startCallCount == 6) // 1 initial + 5 respawn attempts
        #expect(watcher.test_isRunning == false, "give-up must leave the watcher stopped (R4 #9)")
    }

    @Test("termination after stop() does not respawn")
    func terminationAfterStopDoesNotRespawn() async {
        let fake = FakeLogStream()
        let manual = ManualDelayClock()
        let watcher = AirPlayHandoffWatcher(
            spawn: fake,
            rateLimit: 0.15,
            respawnBaseDelay: 0.02,
            respawnMaxAttempts: 5,
            onBlockedAttempt: {},
            uptime: manual.uptime,
            delay: manual.clock
        )

        watcher.start()

        let countAfterStart = fake.startCallCount
        watcher.stop()
        #expect(watcher.test_isRunning == false, "stop() must mark the watcher stopped (R4 #9)")
        // The fake deliberately keeps its captured onTermination closure after
        // stop() (see FakeLogStream.stop), so this push genuinely reaches the
        // watcher's own stale-generation guard — the behavior under test.
        fake.pushTermination()
        manual.advance(by: 0.3) // 15x the 0.02s backoff — a scheduled respawn would have fired

        #expect(fake.startCallCount == countAfterStart)
    }

    @Test("failed start() does not crash and schedules respawn")
    func failedStartDoesNotCrashAndSchedulesRespawn() async {
        let fake = FakeLogStream()
        let manual = ManualDelayClock()
        fake.throwsOnce = true
        let watcher = AirPlayHandoffWatcher(
            spawn: fake,
            rateLimit: 0.15,
            respawnBaseDelay: 0.02,
            respawnMaxAttempts: 5,
            onBlockedAttempt: {},
            uptime: manual.uptime,
            delay: manual.clock
        )

        watcher.start()
        let countAfterFailure = fake.startCallCount
        #expect(countAfterFailure == 1)

        manual.advance(by: 0.02)

        #expect(fake.startCallCount == 2)
    }

    @Test("stop() cancels pending respawn")
    func stopCancelsPendingRespawn() async {
        let fake = FakeLogStream()
        let manual = ManualDelayClock()
        // Backoff 0.4 s on the manual clock: the respawn only fires when the test advances it.
        let watcher = AirPlayHandoffWatcher(
            spawn: fake,
            rateLimit: 0.15,
            respawnBaseDelay: 0.4,
            respawnMaxAttempts: 5,
            onBlockedAttempt: {},
            uptime: manual.uptime,
            delay: manual.clock
        )

        watcher.start()

        let countAfterStart = fake.startCallCount
        fake.pushTermination() // schedules a respawn at +0.4s
        watcher.stop()          // cancels it (generation bump) microseconds later
        manual.advance(by: 1) // well past the 0.4s backoff

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
