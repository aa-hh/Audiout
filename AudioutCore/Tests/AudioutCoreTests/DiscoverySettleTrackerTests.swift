// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudioutPopoverUI

/// The launch splash's discovery-quiescence debouncer, driven deterministically
/// through its injectable scheduling seam — no real run loop, no waits.
@MainActor
@Suite struct DiscoverySettleTrackerTests {

    /// A hand-driven scheduler: stores each armed fire closure so a test can
    /// invoke exactly the one it means to.
    final class FakeScheduler {
        private(set) var pending: [() -> Void] = []
        func schedule(_ delay: TimeInterval, _ fire: @escaping () -> Void) { pending.append(fire) }
        func fire(at index: Int) { pending[index]() }
        func fireLast() { pending.last?() }
        var armCount: Int { pending.count }
    }

    @Test func aQuietWindowWithNoChangeSettlesExactlyOnce() {
        let sched = FakeScheduler()
        var settles = 0
        let tracker = DiscoverySettleTracker(quietWindow: 0.3, schedule: sched.schedule)
        tracker.onSettled = { settles += 1 }

        tracker.note(deviceIDs: ["a"])
        #expect(!tracker.isSettled)
        sched.fireLast()
        #expect(tracker.isSettled)
        #expect(settles == 1)

        // A superseded/late timer that still fires must never double-settle.
        sched.fireLast()
        #expect(settles == 1)
    }

    @Test func aChangeReArmsSoAnOldWindowDoesNotSettleEarly() {
        let sched = FakeScheduler()
        var settles = 0
        let tracker = DiscoverySettleTracker(quietWindow: 0.3, schedule: sched.schedule)
        tracker.onSettled = { settles += 1 }

        tracker.note(deviceIDs: ["a"])          // arm 0
        tracker.note(deviceIDs: ["a", "b"])     // change → arm 1
        #expect(sched.armCount == 2)

        sched.fire(at: 0)                        // the SUPERSEDED window
        #expect(!tracker.isSettled, "an old arm cannot settle after a later change")
        #expect(settles == 0)

        sched.fire(at: 1)                        // the current window
        #expect(tracker.isSettled)
        #expect(settles == 1)
    }

    @Test func anUnchangedSetDoesNotReArm() {
        let sched = FakeScheduler()
        let tracker = DiscoverySettleTracker(schedule: sched.schedule)
        tracker.note(deviceIDs: ["a"])
        tracker.note(deviceIDs: ["a"])          // identical → no new arm
        #expect(sched.armCount == 1)
    }

    @Test func aStableFleetSettlesFromStartAlone() {
        let sched = FakeScheduler()
        var settles = 0
        let tracker = DiscoverySettleTracker(schedule: sched.schedule)
        tracker.onSettled = { settles += 1 }

        tracker.start()                          // arm without any device arriving
        #expect(sched.armCount == 1)
        sched.fireLast()
        #expect(tracker.isSettled)
        #expect(settles == 1)
    }

    @Test func notesAfterSettleAreIgnored() {
        let sched = FakeScheduler()
        let tracker = DiscoverySettleTracker(schedule: sched.schedule)
        tracker.note(deviceIDs: ["a"])
        sched.fireLast()
        #expect(tracker.isSettled)

        tracker.note(deviceIDs: ["a", "b", "c"])
        #expect(sched.armCount == 1, "a settled tracker never re-arms")
    }
}
