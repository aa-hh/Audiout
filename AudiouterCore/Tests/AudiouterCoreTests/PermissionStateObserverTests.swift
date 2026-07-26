// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
import CoreFoundation
@testable import AudiouterCore

/// T6-rev: exercises ``PermissionStateObserver`` fully headlessly — no real
/// `tcc-probe` process is ever spawned (an injected
/// ``TCCProbeRunner/SpawnHelper`` scripts every answer), no real TCC read
/// happens (`isAlreadyGranted` is injected), and the process-wide,
/// deliberately-un-clearable latch in ``SystemAudioCaptureTCC`` is never
/// touched (`recordFreshGrant` is injected too — latching it for real would
/// leak into every other test in this process).
///
/// The Darwin-notification tests register for a PRIVATE notification name
/// rather than the real `com.apple.tcc.access.changed`, so the suite never
/// posts a system-wide TCC notification other processes would react to. That
/// exercises the real `CFNotificationCenter` add/remove/deliver path — which is
/// the part that can dangle — while leaving the production name's correctness
/// where it necessarily lives: the live gated run.
final class PermissionStateObserverTests: IsolatedTestCase {

    // MARK: Fixtures

    /// Counts helper spawns and hands back a scripted line, asynchronously —
    /// mirroring how the real `Process`-backed spawn always calls back off the
    /// caller's thread.
    private final class SpawnLedger: @unchecked Sendable {
        private let lock = NSLock()
        private var _spawns = 0
        private var _line: String

        init(line: String) { _line = line }

        var spawns: Int { lock.lock(); defer { lock.unlock() }; return _spawns }

        /// Change what every SUBSEQUENT spawn answers — how a test models the
        /// user granting partway through a session.
        func setLine(_ line: String) { lock.lock(); _line = line; lock.unlock() }

        func makeSpawn(delay: TimeInterval = 0) -> TCCProbeRunner.SpawnHelper {
            { [self] _, completion in
                lock.lock()
                _spawns += 1
                let line = _line
                lock.unlock()
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                    completion(.output(line))
                }
            }
        }
    }

    /// Records `recordFreshGrant(source:)` calls and `onBecameGranted` firings.
    private final class GrantLedger: @unchecked Sendable {
        private let lock = NSLock()
        private var _sources: [String] = []
        private var _fires = 0
        func recordSource(_ source: String) { lock.lock(); _sources.append(source); lock.unlock() }
        func recordFire() { lock.lock(); _fires += 1; lock.unlock() }
        var sources: [String] { lock.lock(); defer { lock.unlock() }; return _sources }
        var fires: Int { lock.lock(); defer { lock.unlock() }; return _fires }
    }

    private static let grantedLine = "audio=0 screen=1 control=1"
    private static let undeterminedLine = "audio=2 screen=2 control=1"

    /// A private Darwin notification name, unique per test, so posting it can
    /// never reach another process that cares about the real TCC name.
    private func privateNotificationName() -> String {
        "com.audiouter.test.permissionobserver." + isolationToken.replacingOccurrences(of: "-", with: "")
    }

    private func makeObserver(
        spawns: SpawnLedger,
        grants: GrantLedger,
        alreadyGranted: @escaping @Sendable () -> Bool = { false },
        spawnDelay: TimeInterval = 0,
        notificationName: String? = nil
    ) -> PermissionStateObserver {
        let observer = PermissionStateObserver(
            probeRunner: TCCProbeRunner(hardTimeout: 1.0, spawn: spawns.makeSpawn(delay: spawnDelay)),
            notificationName: notificationName ?? privateNotificationName(),
            isAlreadyGranted: alreadyGranted,
            recordFreshGrant: { grants.recordSource($0) })
        observer.onBecameGranted = { grants.recordFire() }
        return observer
    }

    /// Spin until `condition` holds or the deadline passes. Mirrors
    /// `NativeBackendTests.pollUntil` — the resolution completes on an arbitrary
    /// thread, so there is nothing to await.
    private func pollUntil(timeout: TimeInterval = 3, _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: The grant edge

    /// The core contract: a kick that resolves `.granted` latches the fresh
    /// verdict FIRST and then fires `onBecameGranted`, exactly once.
    func test_kick_firesOnceOnTheGrantEdge() async {
        let spawns = SpawnLedger(line: Self.grantedLine)
        let grants = GrantLedger()
        let observer = makeObserver(spawns: spawns, grants: grants)
        defer { observer.stop() }

        observer.start()   // the launch trigger: arms + kicks once
        await pollUntil { grants.fires == 1 }

        XCTAssertEqual(grants.fires, 1)
        XCTAssertEqual(grants.sources, ["PermissionStateObserver.launch"],
                       "the latch must record WHICH trigger caught the grant")
        XCTAssertTrue(observer.test_didObserveGrant)
    }

    /// One-way, like the latch it feeds: further kicks after the edge neither
    /// re-fire the callback nor re-record the grant.
    func test_kick_doesNotRefireAfterTheEdge() async {
        let spawns = SpawnLedger(line: Self.grantedLine)
        let grants = GrantLedger()
        let observer = makeObserver(spawns: spawns, grants: grants)
        defer { observer.stop() }

        observer.start()
        await pollUntil { grants.fires == 1 }

        for _ in 0..<10 { observer.kick(source: "routing_action") }
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(grants.fires, 1, "onBecameGranted fires on the EDGE, once")
        XCTAssertEqual(grants.sources.count, 1)
    }

    /// "Then stops kicking": once the edge has been observed, no further kick
    /// spawns a helper — the design must not keep paying a process spawn per
    /// routing action for the rest of the session.
    func test_kick_stopsSpawningAfterGranted() async {
        let spawns = SpawnLedger(line: Self.grantedLine)
        let grants = GrantLedger()
        let observer = makeObserver(spawns: spawns, grants: grants)
        defer { observer.stop() }

        observer.start()
        await pollUntil { grants.fires == 1 }
        let spawnsAtGrant = spawns.spawns

        for _ in 0..<20 { observer.kick(source: "routing_action") }
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(spawns.spawns, spawnsAtGrant, "no helper spawn after the grant edge")
    }

    /// The refusal side of the latch's one-way rule: only `.resolved(.granted)`
    /// may ever latch. A denied/undetermined answer, and every `.unresolved`
    /// reason, mean "we still don't know" — collapsing any of them into a
    /// verdict is the exact bug `SystemAudioCaptureTCC` exists to prevent.
    func test_kick_neverLatchesOnAnythingButAResolvedGrant() async {
        for line in [Self.undeterminedLine, "audio=1 screen=1 control=1", "audio=0 screen=0 control=9", "garbage"] {
            let spawns = SpawnLedger(line: line)
            let grants = GrantLedger()
            let observer = makeObserver(spawns: spawns, grants: grants)
            observer.start()
            await pollUntil(timeout: 0.5) { spawns.spawns > 0 }
            try? await Task.sleep(nanoseconds: 150_000_000)
            XCTAssertEqual(grants.fires, 0, "line: \(line)")
            XCTAssertEqual(grants.sources, [], "line: \(line)")
            XCTAssertFalse(observer.test_didObserveGrant, "line: \(line)")
            observer.stop()
        }
    }

    /// An already-granted app has nothing to detect, so a kick must not spawn a
    /// helper at all — this is what keeps a routing action free once the latch
    /// is set.
    func test_kick_isInertWhenTheGrantIsAlreadyKnownGood() async {
        let spawns = SpawnLedger(line: Self.grantedLine)
        let grants = GrantLedger()
        let observer = makeObserver(spawns: spawns, grants: grants, alreadyGranted: { true })
        defer { observer.stop() }

        observer.start()
        for _ in 0..<10 { observer.kick(source: "routing_action") }
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(spawns.spawns, 0)
        XCTAssertEqual(grants.fires, 0)
    }

    // MARK: Burst coalescing (the toggle-spam case, with no timer)

    /// A burst of routing actions must NOT spawn a helper each. There is no
    /// debounce timer here by design — `TCCProbeRunner`'s single-flighting is
    /// what bounds a burst of any size to at most two spawns.
    func test_kick_burstCoalescesToAtMostTwoSpawns() async {
        // A slow spawn guarantees the burst genuinely overlaps one in flight,
        // which is the condition single-flighting exists for.
        let spawns = SpawnLedger(line: Self.undeterminedLine)
        let grants = GrantLedger()
        let observer = makeObserver(spawns: spawns, grants: grants, spawnDelay: 0.15)
        defer { observer.stop() }

        observer.start()
        for _ in 0..<50 { observer.kick(source: "routing_action") }
        try? await Task.sleep(nanoseconds: 600_000_000)

        XCTAssertLessThanOrEqual(spawns.spawns, 2,
                                 "51 kicks must coalesce — got \(spawns.spawns) spawns")
        XCTAssertGreaterThan(spawns.spawns, 0, "the burst must still resolve at least once")
    }

    // MARK: Darwin observer lifecycle

    /// The registration hands `CFNotificationCenter` an UNRETAINED pointer to
    /// the observer, so a missing removal is a dangling pointer with no symptom
    /// until it crashes. This asserts both halves: the notification reaches the
    /// bare C callback while armed, and reaches nothing after `stop()`.
    func test_darwinObserver_isAddedAndRemoved() {
        let spawns = SpawnLedger(line: Self.undeterminedLine)
        let grants = GrantLedger()
        let name = privateNotificationName()
        let observer = makeObserver(spawns: spawns, grants: grants, notificationName: name)

        XCTAssertFalse(observer.test_isArmed)
        observer.start()
        XCTAssertTrue(observer.test_isArmed)

        // The launch kick already spawned once; wait it out so the count below
        // can only reflect the notification.
        let launchSettled = expectation(description: "launch kick resolved")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { launchSettled.fulfill() }
        wait(for: [launchSettled], timeout: 2)
        let spawnsBeforePost = spawns.spawns
        XCTAssertGreaterThan(spawnsBeforePost, 0, "start() performs the launch kick")

        post(name)
        let delivered = expectation(description: "darwin notification kicked the observer")
        pollOnMain(deadline: 3, until: { spawns.spawns > spawnsBeforePost }, fulfill: delivered)
        wait(for: [delivered], timeout: 4)
        let spawnsAfterPost = spawns.spawns

        observer.stop()
        XCTAssertFalse(observer.test_isArmed)

        post(name)
        let quiet = expectation(description: "no delivery after removal")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { quiet.fulfill() }
        wait(for: [quiet], timeout: 2)
        XCTAssertEqual(spawns.spawns, spawnsAfterPost,
                       "a removed observer must not be called back — a live one is a dangling pointer")
    }

    /// `stop()` is idempotent and safe to call when never armed — `deinit` calls
    /// it unconditionally.
    func test_stop_isIdempotentAndSafeWhenNeverArmed() {
        let spawns = SpawnLedger(line: Self.undeterminedLine)
        let observer = makeObserver(spawns: spawns, grants: GrantLedger())
        observer.stop()
        observer.stop()
        XCTAssertFalse(observer.test_isArmed)

        observer.start()
        observer.start()   // idempotent arm
        XCTAssertTrue(observer.test_isArmed)
        observer.stop()
        observer.stop()
        XCTAssertFalse(observer.test_isArmed)
    }

    /// An unarmed observer is completely inert — a routing action that fires
    /// before (or without) arming must not spawn anything.
    func test_kick_isInertBeforeStart() async {
        let spawns = SpawnLedger(line: Self.grantedLine)
        let grants = GrantLedger()
        let observer = makeObserver(spawns: spawns, grants: grants)
        defer { observer.stop() }

        observer.kick(source: "routing_action")
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(spawns.spawns, 0)
        XCTAssertEqual(grants.fires, 0)
    }

    // MARK: Darwin post/poll helpers

    private func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(rawValue: name as CFString),
            nil, nil, true)
    }

    /// Re-checks `until` on the MAIN run loop, which is also what lets a Darwin
    /// notification be delivered while a synchronous `wait(for:)` is pending.
    private func pollOnMain(
        deadline: TimeInterval, until condition: @escaping () -> Bool, fulfill: XCTestExpectation
    ) {
        let end = Date().addingTimeInterval(deadline)
        func step() {
            if condition() { fulfill.fulfill(); return }
            guard Date() < end else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { step() }
        }
        step()
    }
}
