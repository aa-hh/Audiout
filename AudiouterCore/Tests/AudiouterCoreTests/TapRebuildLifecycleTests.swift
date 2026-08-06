import Foundation
import Testing
@testable import AudiouterCore

/// Unit tests for the two pieces of tap-rebuild choreography
/// ``NativeCaptureCoordinator`` and ``PerAppCaptureCoordinator`` share
/// (`TapRebuildLifecycle.swift`).
///
/// These are pure-value tests of the mechanisms in isolation. The END-TO-END
/// behaviour each one exists for is covered by
///   - `NativeCaptureCoordinatorTests.deviceChangeDuringRebuildIsCoalescedAndReplayed`
///   - `PerAppCaptureCoordinatorTests.deviceChangeDuringRebuildIsCoalescedAndReplayed`
/// — both fire a SECOND device-change notification from inside the in-flight
/// rebuild's `createAndStart` (i.e. while the owner is genuinely
/// `.creatingTap`) and assert a third tap creation follows, proving the
/// trigger was coalesced and replayed rather than dropped.
@Suite struct TapRebuildLifecycleTests {

    // MARK: - TapRebuildCoalescer (STABILITY(C6))

    @Test func freshCoalescerHasNothingPending() {
        var coalescer = TapRebuildCoalescer()
        #expect(coalescer.isPending == false)
        let taken = coalescer.takePending()
        #expect(taken == false, "nothing was coalesced, so nothing is owed a replay")
    }

    @Test func markedTriggerIsReportedPendingAndThenTaken() {
        var coalescer = TapRebuildCoalescer()
        coalescer.markPending()
        #expect(coalescer.isPending, "isPending must observe without consuming — the per-app path reads it for telemetry")
        #expect(coalescer.isPending, "a second read must still see it: isPending does not consume")
        let taken1 = coalescer.takePending()
        #expect(taken1, "the commit point is owed exactly one replay")
    }

    /// The load-bearing half of C6: a trigger is replayed EXACTLY ONCE. Taking
    /// it must clear it in the same call, so a second commit (or a re-entrant
    /// read racing the same lock hold) can never replay it a second time and
    /// spin an unbounded rebuild loop.
    @Test func takingAPendingTriggerConsumesIt() {
        var coalescer = TapRebuildCoalescer()
        coalescer.markPending()
        let first = coalescer.takePending()
        #expect(first)
        #expect(coalescer.isPending == false, "taken means cleared — no double-processing")
        let second = coalescer.takePending()
        #expect(second == false, "a consumed trigger must never replay twice")
    }

    /// The other load-bearing half: a BURST arriving mid-rebuild collapses into
    /// ONE replay, not N. Rapid 44.1 -> 48 -> 44.1 bounces are the real-world
    /// case; replaying each would rebuild the tap once per notification.
    @Test func aBurstOfTriggersCoalescesIntoASingleReplay() {
        var coalescer = TapRebuildCoalescer()
        coalescer.markPending()
        coalescer.markPending()
        coalescer.markPending()
        let replay = coalescer.takePending()
        #expect(replay, "the burst is owed a replay")
        let extra = coalescer.takePending()
        #expect(extra == false, "...but exactly one, not three")
    }

    /// A trigger marked AFTER a take is a fresh trigger and gets its own
    /// replay — this is the "arrived after the commit hold ended" case, which
    /// must not be swallowed by the earlier consume.
    @Test func aTriggerMarkedAfterATakeIsItsOwnReplay() {
        var coalescer = TapRebuildCoalescer()
        coalescer.markPending()
        let taken4 = coalescer.takePending()
        #expect(taken4)
        coalescer.markPending()
        let taken5 = coalescer.takePending()
        #expect(taken5, "a trigger arriving after the previous replay must not be swallowed")
    }

    // MARK: - TapReanchor (the silent-dropout re-anchor compare)

    @Test func unchangedRateAndDeviceIsNotAReanchor() {
        let r = TapReanchor(previousRate: 44_100, newRate: 44_100, previousDeviceID: 7, newDeviceID: 7)
        #expect(r.rateMoved == false)
        #expect(r.deviceMoved == false)
        #expect(r.didReanchor == false, "a like-for-like rebuild must NOT re-fire the session reset")
    }

    @Test func aChangedRateIsAReanchor() {
        let r = TapReanchor(previousRate: 44_100, newRate: 48_000, previousDeviceID: 7, newDeviceID: 7)
        #expect(r.rateMoved)
        #expect(r.deviceMoved == false)
        #expect(r.didReanchor)
    }

    /// The window the compare exists to close: the default output device moves
    /// between the old tap's teardown and the new tap arming its listener, so
    /// nobody delivers a notification — but the rate happens to match, so only
    /// the identity half can catch it.
    @Test func aChangedDeviceAtTheSameRateIsStillAReanchor() {
        let r = TapReanchor(previousRate: 44_100, newRate: 44_100, previousDeviceID: 7, newDeviceID: 9)
        #expect(r.rateMoved == false)
        #expect(r.deviceMoved)
        #expect(r.didReanchor, "same rate on a DIFFERENT device is exactly the silent-dropout case")
    }

    /// A `nil` on either side of the identity compare abstains rather than
    /// guessing "moved" — an unknown is not evidence of a move, and a spurious
    /// reset costs a real audible glitch. (A tap that doesn't report its device
    /// returns `nil` from `tappedDeviceID`.)
    @Test func anUnknownDeviceAbstainsFromTheIdentityCompare() {
        let noBefore = TapReanchor(previousRate: 44_100, newRate: 44_100, previousDeviceID: nil, newDeviceID: 9)
        #expect(noBefore.deviceMoved == false)
        #expect(noBefore.didReanchor == false)

        let noAfter = TapReanchor(previousRate: 44_100, newRate: 44_100, previousDeviceID: 7, newDeviceID: Int?.none)
        #expect(noAfter.deviceMoved == false)
        #expect(noAfter.didReanchor == false)
    }

    /// Same abstain rule on the rate axis: no baseline rate means no claim
    /// either way. (`recreateTap` only ever passes `nil` here when it did not
    /// claim a `.capturing` format, i.e. on a path that doesn't reach the
    /// compare — but the rule is the shared type's, so it is pinned here.)
    @Test func anUnknownPreviousRateAbstainsFromTheRateCompare() {
        let r = TapReanchor(previousRate: nil, newRate: 48_000, previousDeviceID: 7, newDeviceID: 7)
        #expect(r.rateMoved == false)
        #expect(r.didReanchor == false)
    }

    /// The rate-only initializer (the per-app coordinator's, which does not
    /// track the tapped device's identity) must ABSTAIN on the identity half
    /// rather than fake participation it doesn't have.
    @Test func theRateOnlyInitializerAbstainsFromTheIdentityCompare() {
        #expect(TapReanchor(previousRate: 44_100, newRate: 48_000).rateMoved)
        #expect(TapReanchor(previousRate: 44_100, newRate: 48_000).deviceMoved == false)
        #expect(TapReanchor(previousRate: 44_100, newRate: 44_100).didReanchor == false)
        #expect(TapReanchor(previousRate: nil, newRate: 44_100).rateMoved == false)
    }
}
