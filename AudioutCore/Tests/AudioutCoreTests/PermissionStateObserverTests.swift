// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
import CoreFoundation
@testable import AudioutCore

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
@Suite final class PermissionStateObserverTests: IsolatedSuite {

    // MARK: Fixtures

    /// Counts helper spawns and hands back a scripted line, asynchronously —
    /// mirroring how the real `Process`-backed spawn always calls back off the
    /// caller's thread.
    private final class SpawnLedger: @unchecked Sendable {
        private let lock = NSLock()
        private var _spawns = 0
        private var _completions = 0
        private var _line: String

        init(line: String) { _line = line }

        var spawns: Int { lock.lock(); defer { lock.unlock() }; return _spawns }

        /// Whether every spawn handed out has already delivered its answer —
        /// i.e. ``TCCProbeRunner`` has nothing in flight and nothing coalesced
        /// behind it. Waiting on THIS, rather than sleeping a fixed interval, is
        /// what stops a re-kick from spawning later, after a test has already
        /// snapshotted the count.
        var isSettled: Bool { lock.lock(); defer { lock.unlock() }; return _completions == _spawns }

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
                    // Count the completion only AFTER it returns, and never
                    // under the lock: delivering the answer can re-enter this
                    // very closure (that is `TCCProbeRunner`'s coalesced
                    // re-kick), which under the lock would deadlock and before
                    // the call would read as "settled" while a second spawn is
                    // still in flight.
                    completion(.output(line))
                    self.lock.lock()
                    self._completions += 1
                    self.lock.unlock()
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
        "com.audiout.test.permissionobserver." + isolationToken.replacingOccurrences(of: "-", with: "")
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

    /// Spin until `condition` holds or the deadline passes; reports whether it
    /// held. Mirrors `NativeBackendTests.pollUntil` — the resolution completes on
    /// an arbitrary thread, so there is nothing to await. The final re-check
    /// after the loop matters: without it a change landing during the LAST sleep
    /// is never seen, because the loop exits on the deadline before testing the
    /// condition again.
    @discardableResult
    private func pollUntil(timeout: TimeInterval = 3, _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    /// Deadline for a BARRIER — a wait for something that must happen, as
    /// opposed to a wait-and-hope. Generous on purpose: a barrier costs only as
    /// long as the thing it waits for actually takes (milliseconds on an idle
    /// machine), so a long deadline buys tolerance of a loaded one for free.
    /// A fixed sleep can't make that trade — it always costs its full length and
    /// still races. This suite runs `@MainActor` (via ``IsolatedSuite``) and a
    /// Darwin notification is delivered on the main run loop, so it shares one
    /// thread with every other main-actor test in the process — several of which
    /// block it outright (`RunLoop.current.run(until:)`, `Thread.sleep`).
    private static let barrierTimeout: TimeInterval = 10

    // MARK: The grant edge

    /// The core contract: a kick that resolves `.granted` latches the fresh
    /// verdict FIRST and then fires `onBecameGranted`, exactly once.
    @Test func kick_firesOnceOnTheGrantEdge() async {
        let spawns = SpawnLedger(line: Self.grantedLine)
        let grants = GrantLedger()
        let observer = makeObserver(spawns: spawns, grants: grants)
        defer { observer.stop() }

        observer.start()   // the launch trigger: arms + kicks once
        await pollUntil { grants.fires == 1 }

        #expect(grants.fires == 1)
        #expect(grants.sources == ["PermissionStateObserver.launch"],
                "the latch must record WHICH trigger caught the grant")
        #expect(observer.test_didObserveGrant)
    }

    /// One-way, like the latch it feeds: further kicks after the edge neither
    /// re-fire the callback nor re-record the grant.
    @Test func kick_doesNotRefireAfterTheEdge() async {
        let spawns = SpawnLedger(line: Self.grantedLine)
        let grants = GrantLedger()
        let observer = makeObserver(spawns: spawns, grants: grants)
        defer { observer.stop() }

        observer.start()
        await pollUntil { grants.fires == 1 }

        for _ in 0..<10 { observer.kick(source: "routing_action") }
        try? await Task.sleep(nanoseconds: 200_000_000)

        #expect(grants.fires == 1, "onBecameGranted fires on the EDGE, once")
        #expect(grants.sources.count == 1)
    }

    /// "Then stops kicking": once the edge has been observed, no further kick
    /// spawns a helper — the design must not keep paying a process spawn per
    /// routing action for the rest of the session.
    @Test func kick_stopsSpawningAfterGranted() async {
        let spawns = SpawnLedger(line: Self.grantedLine)
        let grants = GrantLedger()
        let observer = makeObserver(spawns: spawns, grants: grants)
        defer { observer.stop() }

        observer.start()
        await pollUntil { grants.fires == 1 }
        let spawnsAtGrant = spawns.spawns

        for _ in 0..<20 { observer.kick(source: "routing_action") }
        try? await Task.sleep(nanoseconds: 200_000_000)

        #expect(spawns.spawns == spawnsAtGrant, "no helper spawn after the grant edge")
    }

    /// The refusal side of the latch's one-way rule: only `.resolved(.granted)`
    /// may ever latch. A denied/undetermined answer, and every `.unresolved`
    /// reason, mean "we still don't know" — collapsing any of them into a
    /// verdict is the exact bug `SystemAudioCaptureTCC` exists to prevent.
    @Test func kick_neverLatchesOnAnythingButAResolvedGrant() async {
        for line in [Self.undeterminedLine, "audio=1 screen=1 control=1", "audio=0 screen=0 control=9", "garbage"] {
            let spawns = SpawnLedger(line: line)
            let grants = GrantLedger()
            let observer = makeObserver(spawns: spawns, grants: grants)
            observer.start()
            await pollUntil(timeout: 0.5) { spawns.spawns > 0 }
            try? await Task.sleep(nanoseconds: 150_000_000)
            #expect(grants.fires == 0, "line: \(line)")
            #expect(grants.sources == [], "line: \(line)")
            #expect(!observer.test_didObserveGrant, "line: \(line)")
            observer.stop()
        }
    }

    /// An already-granted app has nothing to detect, so a kick must not spawn a
    /// helper at all — this is what keeps a routing action free once the latch
    /// is set.
    @Test func kick_isInertWhenTheGrantIsAlreadyKnownGood() async {
        let spawns = SpawnLedger(line: Self.grantedLine)
        let grants = GrantLedger()
        let observer = makeObserver(spawns: spawns, grants: grants, alreadyGranted: { true })
        defer { observer.stop() }

        observer.start()
        for _ in 0..<10 { observer.kick(source: "routing_action") }
        try? await Task.sleep(nanoseconds: 200_000_000)

        #expect(spawns.spawns == 0)
        #expect(grants.fires == 0)
    }

    // MARK: Burst coalescing (the toggle-spam case, with no timer)

    /// A burst of routing actions must NOT spawn a helper each. There is no
    /// debounce timer here by design — `TCCProbeRunner`'s single-flighting is
    /// what bounds a burst of any size to at most two spawns.
    @Test func kick_burstCoalescesToAtMostTwoSpawns() async {
        // A slow spawn guarantees the burst genuinely overlaps one in flight,
        // which is the condition single-flighting exists for.
        let spawns = SpawnLedger(line: Self.undeterminedLine)
        let grants = GrantLedger()
        let observer = makeObserver(spawns: spawns, grants: grants, spawnDelay: 0.15)
        defer { observer.stop() }

        observer.start()
        for _ in 0..<50 { observer.kick(source: "routing_action") }
        try? await Task.sleep(nanoseconds: 600_000_000)

        #expect(spawns.spawns <= 2,
                "51 kicks must coalesce — got \(spawns.spawns) spawns")
        #expect(spawns.spawns > 0, "the burst must still resolve at least once")
    }

    // MARK: Darwin observer lifecycle

    /// The registration hands `CFNotificationCenter` an UNRETAINED pointer to
    /// the observer, so a missing removal is a dangling pointer with no symptom
    /// until it crashes. This asserts both halves: the notification reaches the
    /// bare C callback while armed, and reaches nothing after `stop()`.
    ///
    /// EVERY WAIT HERE IS A BARRIER, never a best-effort sleep, and none may go
    /// back to "wait a bit and hope" — that shape is what made this test flaky.
    /// The old version sleep-waited 300ms for the launch kick's spawn and then
    /// polled 3s for the post's, carrying on with a STALE count if neither came.
    /// A kick that arrives while a spawn is in flight does not spawn: it sets
    /// ``TCCProbeRunner``'s pending re-kick, which spawns whenever that in-flight
    /// completion happens to land. On a loaded machine that landed after the
    /// snapshot — and the resulting extra spawn failed the assertion below,
    /// reporting a dangling pointer when the real cause was a starved run loop.
    @Test func darwinObserver_isAddedAndRemoved() async throws {
        let spawns = SpawnLedger(line: Self.undeterminedLine)
        let grants = GrantLedger()
        let name = privateNotificationName()
        let observer = makeObserver(spawns: spawns, grants: grants, notificationName: name)
        let witness = NotificationWitness(name: name)

        #expect(!observer.test_isArmed)
        observer.start()
        #expect(observer.test_isArmed)

        // Let the launch kick's spawn finish, so the count below can only move
        // for the notification and nothing is left queued behind it.
        let launchSettled = await pollUntil(timeout: Self.barrierTimeout) { spawns.isSettled }
        try #require(launchSettled, "the launch kick's spawn never completed — infrastructure, not the observer")
        let spawnsBeforePost = spawns.spawns
        #expect(spawnsBeforePost > 0, "start() performs the launch kick")

        // Two separate failures, kept separate: the post not reaching this
        // process at all, and an armed observer not reacting to one that did.
        post(name)
        let firstPostDelivered = await pollUntil(timeout: Self.barrierTimeout) { witness.posts == 1 }
        try #require(firstPostDelivered, "the post never reached this process — infrastructure, not the observer")
        let armedObserverReacted = await pollUntil(timeout: Self.barrierTimeout) { spawns.spawns > spawnsBeforePost }
        try #require(armedObserverReacted, "an armed observer must re-check when the notification fires")
        let spawnsAfterPost = spawns.spawns

        observer.stop()
        #expect(!observer.test_isArmed)

        // The witness is the barrier the old fixed sleep only approximated:
        // waiting for it means the assertion can no longer pass merely because
        // the second post hadn't been delivered yet.
        post(name)
        let secondPostDelivered = await pollUntil(timeout: Self.barrierTimeout) { witness.posts == 2 }
        try #require(secondPostDelivered, "the post never reached this process — infrastructure, not the observer")
        #expect(spawns.spawns == spawnsAfterPost,
                "a removed observer must not be called back — a live one is a dangling pointer")
    }

    /// `stop()` is idempotent and safe to call when never armed — `deinit` calls
    /// it unconditionally.
    @Test func stop_isIdempotentAndSafeWhenNeverArmed() {
        let spawns = SpawnLedger(line: Self.undeterminedLine)
        let observer = makeObserver(spawns: spawns, grants: GrantLedger())
        observer.stop()
        observer.stop()
        #expect(!observer.test_isArmed)

        observer.start()
        observer.start()   // idempotent arm
        #expect(observer.test_isArmed)
        observer.stop()
        observer.stop()
        #expect(!observer.test_isArmed)
    }

    /// An unarmed observer is completely inert — a routing action that fires
    /// before (or without) arming must not spawn anything.
    @Test func kick_isInertBeforeStart() async {
        let spawns = SpawnLedger(line: Self.grantedLine)
        let grants = GrantLedger()
        let observer = makeObserver(spawns: spawns, grants: grants)
        defer { observer.stop() }

        observer.kick(source: "routing_action")
        try? await Task.sleep(nanoseconds: 200_000_000)

        #expect(spawns.spawns == 0)
        #expect(grants.fires == 0)
    }

    // MARK: Darwin post/poll helpers

    private func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(rawValue: name as CFString),
            nil, nil, true)
    }

    /// A second, independent observer of the same private name, registered
    /// exactly the way ``PermissionStateObserver`` does. It exists so a test can
    /// WAIT for a post to actually reach this process instead of sleeping and
    /// hoping — the difference between "the removed observer did no work" and
    /// "the notification hadn't been delivered yet," which a fixed sleep cannot
    /// tell apart on a machine whose main run loop is busy. `CFNotificationCenter`
    /// hands a Darwin post to every observer of that name in ONE synchronous
    /// pass, so a post this witness has counted is a post a still-registered
    /// observer would already have been called back for.
    private final class NotificationWitness: @unchecked Sendable {
        private let name: String
        private let lock = NSLock()
        private var _posts = 0

        var posts: Int { lock.lock(); defer { lock.unlock() }; return _posts }

        init(name: String) {
            self.name = name
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                Unmanaged.passUnretained(self).toOpaque(),
                Self.postedCallback,
                name as CFString,
                nil,
                .deliverImmediately)
        }

        /// Same unretained-pointer contract as the type under test: this MUST
        /// run, or the notification center is left holding a pointer to freed
        /// memory. Removing ONE observer of a name leaves the name registered
        /// for the others — which is what lets the observer under test be
        /// stopped mid-test while this one keeps counting.
        deinit {
            CFNotificationCenterRemoveObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                Unmanaged.passUnretained(self).toOpaque(),
                CFNotificationName(rawValue: name as CFString),
                nil)
        }

        /// A bare C function pointer, capturing nothing — same shape (and same
        /// reason) as ``PermissionStateObserver``'s own callback.
        private static let postedCallback: CFNotificationCallback = { _, observer, _, _, _ in
            guard let observer else { return }
            Unmanaged<NotificationWitness>.fromOpaque(observer).takeUnretainedValue().record()
        }

        private func record() { lock.lock(); _posts += 1; lock.unlock() }
    }
}
