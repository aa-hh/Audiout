// T7 (docs/plans/PLAN-AUDIO-THREAD-SCHEDULING.md §E): the audio I/O workgroup
// join/leave LIFECYCLE around ``NativeCaptureCoordinator``'s state machine.
//
// WHAT THIS FILE CAN TEST — and it is deliberately only this: the ORDER, the
// COUNT, and the ARGUMENT of the join/leave calls the coordinator makes at each
// of its lifecycle edges, plus the edge cases (no workgroup published, a rebuild
// that fails, a stop that races a start). All of it through a spy seam.
//
// WHAT THIS FILE MUST NOT TEST, stated plainly so nobody "improves" it into a
// flaky suite:
//   * that `os_workgroup_join` actually did anything to thread scheduling. It is
//     a kernel scheduling hint; there is no hermetic observation of its effect.
//   * that a TAP-BEARING aggregate device even publishes
//     `kAudioDevicePropertyIOThreadOSWorkgroup`. Plan risk #6: only a SYNTHETIC
//     aggregate with no `CATapDescription` was ever measured. If the real one
//     publishes nothing, the join returns EINVAL and we degrade to QoS-only —
//     which is a thing to report from a live run, not to assert here.
//   * anything requiring a real tap, a real aggregate, or a real engine thread.
//     The engine-side half of this contract (the shim's EINVAL/skip behaviour and
//     the leave-before-thread-exit edge) lives in
//     AirPlayEngineTests/WorkgroupLifecycleTests.swift.

import Foundation
import Testing
@testable import AudiouterCore

#if canImport(CoreAudio)
import CoreAudio
#endif

@Suite final class WorkgroupLifecycleTests: IsolatedSuite {

    // MARK: Doubles

    /// Every join/leave the coordinator issued, in order. Ordering is the whole
    /// point of the test: a join-then-leave rebuild would leave the audio thread
    /// in NO workgroup (the new join returns EALREADY, then the old membership is
    /// dropped), and nothing at the call site can observe that.
    private enum WorkgroupCall: Equatable, CustomStringConvertible {
        case join(AudioObjectID)
        case leave

        var description: String {
            switch self {
            case .join(let id): return "join(\(id))"
            case .leave: return "leave"
            }
        }
    }

    private final class SpyWorkgroup: AudioIOWorkgroupJoining, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [WorkgroupCall] = []

        func join(deviceID: AudioObjectID) { lock.withLock { recorded.append(.join(deviceID)) } }
        func leave() { lock.withLock { recorded.append(.leave) } }

        var calls: [WorkgroupCall] { lock.withLock { recorded } }
        var joins: Int { calls.filter { if case .join = $0 { return true }; return false }.count }
        var leaves: Int { calls.filter { $0 == .leave }.count }
    }

    /// A tap that reports a scripted aggregate id as its workgroup source, and can
    /// change that id across recreations (a rebuild really does build a NEW
    /// aggregate, so the second join must name a different object).
    private final class FakeTap: SystemAudioTap, @unchecked Sendable {
        var onBuffer: (@Sendable (CapturedBuffer) -> Void)?
        var onDefaultDeviceChanged: (@Sendable () -> Void)?
        var onCallActiveChanged: (@Sendable (Bool) -> Void)?

        private let lock = NSLock()
        var format = TapFormat(
            sampleRate: 48000, channels: 2, bitsPerSample: 32, isFloat: true, isInterleaved: false)
        var startError: NativeCaptureError?
        /// The aggregate ids to report, one per successful `createAndStart`. The
        /// LAST value is reused once the script is exhausted.
        var aggregateIDScript: [AudioObjectID?] = [77]
        private var _currentAggregateID: AudioObjectID?
        private var createCount = 0
        private var teardownCount = 0
        /// Runs synchronously at the top of `createAndStart`, while the coordinator
        /// is `.creatingTap` — lets a test inject a racing `stop()` deterministically.
        var onCreateAndStart: (() -> Void)?

        func createAndStart(
            muteBehavior: TapMuteBehavior, excludedProcessObjectIDs: Set<AudioObjectID>
        ) throws -> TapFormat {
            lock.lock()
            let index = min(createCount, aggregateIDScript.count - 1)
            createCount += 1
            lock.unlock()
            onCreateAndStart?()
            if let startError {
                // A failed create leaves no live aggregate — mirrors the real tap,
                // whose `createAndStart` tears itself down before rethrowing.
                lock.withLock { _currentAggregateID = nil }
                throw startError
            }
            lock.withLock { _currentAggregateID = aggregateIDScript[index] }
            return format
        }

        func teardown() {
            lock.withLock {
                teardownCount += 1
                _currentAggregateID = nil
            }
        }

        var workgroupDeviceID: AudioObjectID? { lock.withLock { _currentAggregateID } }
        var creates: Int { lock.withLock { createCount } }
        var teardowns: Int { lock.withLock { teardownCount } }

        func fireDeviceChange() { onDefaultDeviceChanged?() }
    }

    private final class SilentSink: PCMSink, @unchecked Sendable {
        func write(pcm: Data, pts: timespec) {}
    }

    private struct PassthroughConverter: PCMConverting {
        func convertToAirPlayPCM(_ buffer: CapturedBuffer) -> Data? { Data([0, 0, 0, 0]) }
    }

    private func makeCoordinator(
        tap: FakeTap, workgroup: AudioIOWorkgroupJoining?
    ) -> NativeCaptureCoordinator {
        NativeCaptureCoordinator(
            makeTap: { tap },
            sink: SilentSink(),
            makeConverter: { _ in PassthroughConverter() },
            muteBehavior: .mutedWhenTapped,
            workgroup: workgroup
        )
    }

    // MARK: - Edge 1: join at start

    @Test func startJoinsTheAggregatesWorkgroupExactlyOnce() {
        let tap = FakeTap()
        tap.aggregateIDScript = [4242]
        let spy = SpyWorkgroup()
        let coordinator = makeCoordinator(tap: tap, workgroup: spy)

        coordinator.start()

        #expect(coordinator.state == .capturing(tap.format))
        #expect(
            spy.calls == [.join(4242)],
            "start() joins exactly once, naming the AGGREGATE device the tap built")
    }

    @Test func startIsIdempotentAndDoesNotJoinTwice() {
        let tap = FakeTap()
        let spy = SpyWorkgroup()
        let coordinator = makeCoordinator(tap: tap, workgroup: spy)

        coordinator.start()
        coordinator.start()   // already capturing — a no-op

        #expect(spy.joins == 1, "a second join on an already-joined thread would return EALREADY")
    }

    @Test func startDoesNotJoinWhenTheTapPublishesNoWorkgroup() {
        // Plan risk #6: a tap-bearing aggregate may publish no 'oswg' at all. That
        // must be a quiet degrade-to-QoS-only, not a join attempt and not a failure.
        let tap = FakeTap()
        tap.aggregateIDScript = [nil]
        let spy = SpyWorkgroup()
        let coordinator = makeCoordinator(tap: tap, workgroup: spy)

        coordinator.start()

        #expect(coordinator.state == .capturing(tap.format), "capture still succeeds")
        #expect(spy.calls == [], "nothing to join, so nothing is called")
    }

    @Test func failedStartNeverJoins() {
        let tap = FakeTap()
        tap.startError = .tapCreationFailed(reason: "denied")
        let spy = SpyWorkgroup()
        let coordinator = makeCoordinator(tap: tap, workgroup: spy)

        coordinator.start()

        #expect(spy.calls == [], "no aggregate was ever created — there is nothing to join")
    }

    @Test func startThatLosesToARacingStopDoesNotJoin() {
        // The orphan path: stop() wins while createAndStart is in flight, so the
        // just-built tap is discarded. Joining a workgroup we are about to destroy
        // would only have to be unwound again.
        let tap = FakeTap()
        let spy = SpyWorkgroup()
        let coordinator = makeCoordinator(tap: tap, workgroup: spy)
        tap.onCreateAndStart = { coordinator.stop() }

        coordinator.start()

        #expect(coordinator.state == .idle)
        #expect(spy.joins == 0, "the orphaned tap's workgroup is never joined")
    }

    // MARK: - stop(): leave, and no join left dangling

    @Test func stopLeavesTheWorkgroup() {
        let tap = FakeTap()
        tap.aggregateIDScript = [9]
        let spy = SpyWorkgroup()
        let coordinator = makeCoordinator(tap: tap, workgroup: spy)

        coordinator.start()
        coordinator.stop()

        #expect(spy.calls == [.join(9), .leave])
    }

    @Test func stopFromIdleDoesNotLeave() {
        let spy = SpyWorkgroup()
        let coordinator = makeCoordinator(tap: FakeTap(), workgroup: spy)

        coordinator.stop()

        #expect(spy.calls == [], "a stop() with nothing running has no membership to unwind")
    }

    @Test func startStopStartRejoins() {
        let tap = FakeTap()
        tap.aggregateIDScript = [11, 12]
        let spy = SpyWorkgroup()
        let coordinator = makeCoordinator(tap: tap, workgroup: spy)

        coordinator.start()
        coordinator.stop()
        coordinator.start()

        #expect(spy.calls == [.join(11), .leave, .join(12)])
        #expect(spy.joins == spy.leaves + 1, "one unmatched join = the live membership")
    }

    // MARK: - Edge 3: on tap recreate, LEAVE OLD then JOIN NEW

    @Test func deviceChangeRebuildLeavesTheOldWorkgroupBeforeJoiningTheNew() {
        let tap = FakeTap()
        tap.aggregateIDScript = [100, 200]
        let spy = SpyWorkgroup()
        let coordinator = makeCoordinator(tap: tap, workgroup: spy)

        coordinator.start()
        tap.fireDeviceChange()

        #expect(tap.creates == 2, "the device change rebuilt the tap")
        #expect(
            spy.calls == [.join(100), .leave, .join(200)],
            "leave-then-join: joining first would return EALREADY and then the leave would drop the only membership, leaving the audio thread in none")
    }

    @Test func exclusionChangeRebuildAlsoLeavesThenJoins() {
        // The other recreate trigger (updateRouting / setSyncedLocalSink), which
        // fires on ordinary connects — not just on device changes.
        let tap = FakeTap()
        tap.aggregateIDScript = [1, 2]
        let spy = SpyWorkgroup()
        let coordinator = makeCoordinator(tap: tap, workgroup: spy)

        coordinator.start()
        coordinator.updateRouting(
            appRoutes: [AppRoute(bundleID: "com.example.a", displayName: "A", destination: .device(id: "dev"))],
            excludedBundleIDs: [])

        #expect(tap.creates == 2)
        #expect(spy.calls == [.join(1), .leave, .join(2)])
    }

    @Test func repeatedRebuildsNeverAccumulateMemberships() {
        let tap = FakeTap()
        tap.aggregateIDScript = [1, 2, 3, 4]
        let spy = SpyWorkgroup()
        let coordinator = makeCoordinator(tap: tap, workgroup: spy)

        coordinator.start()
        tap.fireDeviceChange()
        tap.fireDeviceChange()
        tap.fireDeviceChange()

        #expect(spy.calls == [.join(1), .leave, .join(2), .leave, .join(3), .leave, .join(4)])
        #expect(
            spy.joins - spy.leaves == 1,
            "the join/leave counts stay balanced to exactly one live membership")

        coordinator.stop()
        #expect(spy.joins == spy.leaves, "and stop() balances the last one")
    }

    @Test func rebuildWhoseRecreateFailsLeavesWithoutRejoining() {
        let tap = FakeTap()
        tap.aggregateIDScript = [5, 6]
        let spy = SpyWorkgroup()
        let coordinator = makeCoordinator(tap: tap, workgroup: spy)

        coordinator.start()
        tap.startError = .deviceLost(reason: "unplugged")
        tap.fireDeviceChange()

        guard case .failed = coordinator.state else {
            Issue.record("expected .failed after a rebuild that could not recreate the tap")
            return
        }
        #expect(
            spy.calls == [.join(5), .leave],
            "the old membership is still released even though there is no new aggregate to join")
    }

    @Test func rebuildIntoATapWithNoWorkgroupLeavesAndDoesNotJoin() {
        let tap = FakeTap()
        tap.aggregateIDScript = [8, nil]
        let spy = SpyWorkgroup()
        let coordinator = makeCoordinator(tap: tap, workgroup: spy)

        coordinator.start()
        tap.fireDeviceChange()

        #expect(spy.calls == [.join(8), .leave])
    }

    // MARK: - The seam is optional

    @Test func nilWorkgroupSeamChangesNothingAboutCapture() {
        // Every edge must be a no-op when the feature is not wired (the default for
        // the rest of the suite), not a crash and not a behaviour change.
        let tap = FakeTap()
        let coordinator = makeCoordinator(tap: tap, workgroup: nil)

        coordinator.start()
        #expect(coordinator.state == .capturing(tap.format))
        tap.fireDeviceChange()
        #expect(tap.creates == 2)
        coordinator.stop()
        #expect(coordinator.state == .idle)
    }
}
