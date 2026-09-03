// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudioutCore

/// The staleness rule behind the phone's speaker row: what makes a stored
/// Bluetooth alignment count as tuned, stale, or never made.
@Suite final class BTAlignmentFreshnessTests: IsolatedSuite {

    private let noon = Date(timeIntervalSince1970: 1_756_000_000)

    // MARK: The pure rule

    @Test func noStoredEntryIsAlwaysNotSet() {
        // Even with a connect and an alignment behind it: "tuned" is decided by
        // whether the store holds an entry, and this one holds none.
        #expect(BTAlignmentFreshness.status(hasStoreEntry: false,
                                            lastConnectedAt: noon,
                                            alignedAt: noon) == .notSet)
    }

    @Test func aReconnectAfterTheAlignmentIsWhatMakesItStale() {
        #expect(BTAlignmentFreshness.status(hasStoreEntry: true,
                                            lastConnectedAt: noon.addingTimeInterval(30),
                                            alignedAt: noon) == .stale)
    }

    @Test func aligningAfterTheReconnectClearsIt() {
        #expect(BTAlignmentFreshness.status(hasStoreEntry: true,
                                            lastConnectedAt: noon,
                                            alignedAt: noon.addingTimeInterval(30)) == .tuned)
    }

    /// The launch case, and the reason the rule is written the way it is: a
    /// speaker tuned in some earlier session has a store entry but no alignment
    /// instant THIS process watched. Reading that as stale would put every
    /// tuned speaker under a stale banner on every launch.
    @Test func aStoredEntryWithNoAlignmentInstantIsTunedNotStale() {
        #expect(BTAlignmentFreshness.status(hasStoreEntry: true,
                                            lastConnectedAt: noon,
                                            alignedAt: nil) == .tuned)
        #expect(BTAlignmentFreshness.status(hasStoreEntry: true,
                                            lastConnectedAt: nil,
                                            alignedAt: nil) == .tuned)
    }

    // MARK: The settling window

    @Test func theSettleWindowCountsDownFromTheConnectAndThenStops() {
        #expect(BTAlignmentFreshness.settleRemainingSeconds(
            lastConnectedAt: noon, now: noon) == 60)
        // Rounded UP, so a phone counting down never reaches zero while the Mac
        // still holds the window open.
        #expect(BTAlignmentFreshness.settleRemainingSeconds(
            lastConnectedAt: noon, now: noon.addingTimeInterval(30.4)) == 30)
        #expect(BTAlignmentFreshness.settleRemainingSeconds(
            lastConnectedAt: noon, now: noon.addingTimeInterval(59.5)) == 1)
        #expect(BTAlignmentFreshness.settleRemainingSeconds(
            lastConnectedAt: noon, now: noon.addingTimeInterval(60)) == nil)
        #expect(BTAlignmentFreshness.settleRemainingSeconds(lastConnectedAt: nil) == nil)
    }

    // MARK: Recording

    @Test func recordingIsPerDeviceAndNotifiesOnEveryChange() {
        let freshness = BTAlignmentFreshness()
        final class Count: @unchecked Sendable {
            let lock = NSLock()
            var value = 0
        }
        let changes = Count()
        freshness.onChange = { changes.lock.withLock { changes.value += 1 } }

        freshness.noteAligned(uid: "speaker-a", at: noon)
        freshness.noteConnected(uid: "speaker-a", at: noon.addingTimeInterval(10))
        // The manual reconnect and the enumerator snapshot both report the SAME
        // link-up, moments apart. The second report must not restart the
        // settling window under a phone that is already counting it down.
        freshness.noteConnected(uid: "speaker-a", at: noon.addingTimeInterval(11))
        #expect(freshness.report(uid: "speaker-a", hasStoreEntry: true,
                                now: noon.addingTimeInterval(10)).settleRemainingSeconds == 60)
        #expect(freshness.report(uid: "speaker-a", hasStoreEntry: true,
                                now: noon.addingTimeInterval(20)).status == .stale)
        // The other speaker saw neither edge, so nothing about it moved.
        #expect(freshness.report(uid: "speaker-b", hasStoreEntry: true,
                                now: noon.addingTimeInterval(20)).status == .tuned)

        // Clearing a tuning removes the instant a later connect would be
        // measured against, so the row cannot come back reading stale.
        freshness.clearAligned(uid: "speaker-a")
        #expect(freshness.report(uid: "speaker-a", hasStoreEntry: false,
                                now: noon.addingTimeInterval(20)).status == .notSet)
        #expect(changes.lock.withLock { changes.value } == 3)
    }

    /// The echo is collapsed, but a speaker that genuinely drops and comes back
    /// is a NEW link-up and must land — otherwise a power-cycled speaker would
    /// never go stale again for the rest of the session.
    @Test func aLinkThatDroppedAndReturnedIsANewConnect() {
        let freshness = BTAlignmentFreshness()
        freshness.noteAligned(uid: "speaker-a", at: noon)
        freshness.noteConnected(uid: "speaker-a", at: noon.addingTimeInterval(-30))
        #expect(freshness.report(uid: "speaker-a", hasStoreEntry: true,
                                now: noon).status == .tuned)

        freshness.noteDisconnected(uid: "speaker-a")
        freshness.noteConnected(uid: "speaker-a", at: noon.addingTimeInterval(30))
        #expect(freshness.report(uid: "speaker-a", hasStoreEntry: true,
                                now: noon.addingTimeInterval(40)).status == .stale)
    }

    // MARK: The clock detector's estimate

    private final class ChangeCount: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = 0
        var value: Int { lock.withLock { _value } }
        func bump() { lock.withLock { _value += 1 } }
    }

    private func counting(_ freshness: BTAlignmentFreshness) -> ChangeCount {
        let changes = ChangeCount()
        freshness.onChange = { changes.bump() }
        return changes
    }

    private func at(_ seconds: TimeInterval) -> Date { noon.addingTimeInterval(seconds) }

    /// `count` advancing samples a second apart, the first at `from`. The
    /// first only sets the instant, so eleven make ten stable seconds.
    private func advance(_ freshness: BTAlignmentFreshness, uid: String = "speaker-a",
                         from: TimeInterval, count: Int) {
        for s in 0..<count {
            freshness.noteClockOutcome(uid: uid, outcome: .advanced, at: at(from + Double(s)))
        }
    }

    private func report(_ freshness: BTAlignmentFreshness, uid: String = "speaker-a",
                        at seconds: TimeInterval) -> BTAlignmentReport {
        freshness.report(uid: uid, hasStoreEntry: true, now: at(seconds))
    }

    @Test func theFloorHoldsWhileTheClockIsStillUnproven() {
        let freshness = BTAlignmentFreshness()
        freshness.noteConnected(uid: "speaker-a", at: noon)
        advance(freshness, from: 1, count: 5)   // four stable seconds by noon+5
        #expect(!freshness.isStable(uid: "speaker-a"))
        #expect(report(freshness, at: 5).settleRemainingSeconds == 55)
    }

    @Test func stableEndsTheWindowBeforeTheFloorRunsOut() {
        let freshness = BTAlignmentFreshness()
        let changes = counting(freshness)
        freshness.noteConnected(uid: "speaker-a", at: noon)
        advance(freshness, from: 1, count: 11)   // ten stable seconds at noon+11
        #expect(freshness.isStable(uid: "speaker-a"))
        #expect(report(freshness, at: 11).settleRemainingSeconds == nil)
        #expect(changes.value == 2, "the connect, then the one arrival at stable")
    }

    @Test func aJumpPastTheFloorPublishesTheDetectorsOwnCountdown() {
        let freshness = BTAlignmentFreshness()
        let changes = counting(freshness)
        freshness.noteConnected(uid: "speaker-a", at: noon)
        advance(freshness, from: 1, count: 11)
        #expect(changes.value == 2)
        freshness.noteClockOutcome(uid: "speaker-a", outcome: .jumped(magnitudeMs: 30), at: at(70))
        #expect(changes.value == 3, "a jump past the floor re-publishes the estimate")
        #expect(report(freshness, at: 70).settleRemainingSeconds == 10)
        advance(freshness, from: 71, count: 2)   // two stable seconds by noon+72
        #expect(report(freshness, at: 72).settleRemainingSeconds == 8)
        #expect(changes.value == 3, "ordinary advancing samples publish nothing")
    }

    @Test func aJumpInsideTheFloorPublishesNothingNew() {
        let freshness = BTAlignmentFreshness()
        let changes = counting(freshness)
        freshness.noteConnected(uid: "speaker-a", at: noon)
        freshness.noteClockOutcome(uid: "speaker-a", outcome: .jumped(magnitudeMs: 5), at: at(20))
        #expect(changes.value == 1, "the phone is already counting the floor down")
        #expect(report(freshness, at: 20).settleRemainingSeconds == 40)
    }

    /// The deadlock guard: past the floor, a device producing no advancing
    /// sample would otherwise publish 10 forever and the phone's Measure
    /// button would never go live.
    @Test func anIdleDevicePastTheFloorPublishesNoEstimate() {
        let freshness = BTAlignmentFreshness()
        freshness.noteConnected(uid: "speaker-a", at: noon)
        freshness.noteClockOutcome(uid: "speaker-a", outcome: .jumped(magnitudeMs: 12), at: at(70))
        #expect(report(freshness, at: 73).settleRemainingSeconds == 10, "within 3 s of a sample")
        #expect(report(freshness, at: 73.5).settleRemainingSeconds == nil, "and past it, nothing")
        freshness.noteClockOutcome(uid: "speaker-a", outcome: .frozen, at: at(80))
        #expect(report(freshness, at: 80).settleRemainingSeconds == nil, "frozen is not advancing")

        let never = BTAlignmentFreshness()
        never.noteConnected(uid: "speaker-a", at: noon)
        #expect(report(never, at: 61).settleRemainingSeconds == nil, "no sample at all, ever")
    }

    /// A clock the Mac has never sampled is unknown, not settling: with no
    /// window running and no sample seen, an alignment stays ordinary. This
    /// is what keeps a device whose clock query never answers from marking
    /// every alignment early forever.
    @Test func anAlignmentWithNoWindowAndNoSamplesIsNotMarkedEarly() {
        let freshness = BTAlignmentFreshness()
        freshness.noteAligned(uid: "speaker-a", at: noon)
        #expect(report(freshness, at: 0).status == .tuned, "no connect this session")

        freshness.noteConnected(uid: "speaker-a", at: at(10))
        freshness.noteAligned(uid: "speaker-a", at: at(80))
        let pastTheFloor = report(freshness, at: 80)
        #expect(pastTheFloor.status == .tuned, "the floor ran out and no sample ever came")
        #expect(pastTheFloor.staleReason == nil)

        // One sample that did not yet hold is a reason: it is settling.
        freshness.noteClockOutcome(uid: "speaker-a", outcome: .ignored, at: at(81))
        freshness.noteClockOutcome(uid: "speaker-a", outcome: .advanced, at: at(82))
        freshness.noteAligned(uid: "speaker-a", at: at(83))
        #expect(report(freshness, at: 83).staleReason == BTAlignmentFreshness.staleReasonMeasuredWhileSettling)
    }

    @Test func aMeasurementMadeWhileSettlingIsMarkedUntilOneMadeWhileStable() {
        let freshness = BTAlignmentFreshness()
        freshness.noteConnected(uid: "speaker-a", at: noon)
        freshness.noteAligned(uid: "speaker-a", at: at(5))
        var early = report(freshness, at: 6)
        #expect(early.status == .stale)
        #expect(early.staleReason == BTAlignmentFreshness.staleReasonMeasuredWhileSettling)
        #expect(freshness.earlyAlignmentJumpSumMs(uid: "speaker-a") == 0)
        // The jumps since are summed for the telemetry line, but never
        // promote the row to "moved": it is already asking for a re-check.
        freshness.noteClockOutcome(uid: "speaker-a", outcome: .jumped(magnitudeMs: 4), at: at(7))
        freshness.noteClockOutcome(uid: "speaker-a", outcome: .jumped(magnitudeMs: -8), at: at(8))
        #expect(freshness.earlyAlignmentJumpSumMs(uid: "speaker-a") == 12)
        early = report(freshness, at: 9)
        #expect(early.staleReason == BTAlignmentFreshness.staleReasonMeasuredWhileSettling)

        advance(freshness, from: 9, count: 11)
        freshness.noteAligned(uid: "speaker-a", at: at(20))
        let settled = report(freshness, at: 21)
        #expect(settled.status == .tuned)
        #expect(settled.staleReason == nil)
        #expect(freshness.earlyAlignmentJumpSumMs(uid: "speaker-a") == nil)
        #expect(report(freshness, uid: "speaker-b", at: 21).status == .tuned, "per device")
    }

    @Test func movedIsPublishedOnceWhenTheJumpsSumToTenMilliseconds() {
        let freshness = BTAlignmentFreshness()
        let changes = counting(freshness)
        freshness.noteConnected(uid: "speaker-a", at: noon)
        advance(freshness, from: 1, count: 11)
        freshness.noteAligned(uid: "speaker-a", at: at(12))
        #expect(changes.value == 3)
        freshness.noteClockOutcome(uid: "speaker-a", outcome: .jumped(magnitudeMs: 4), at: at(13))
        freshness.noteClockOutcome(uid: "speaker-a", outcome: .jumped(magnitudeMs: -4), at: at(14))
        #expect(changes.value == 3, "8 ms summed is under the line")
        #expect(report(freshness, at: 15).status == .tuned)
        freshness.noteClockOutcome(uid: "speaker-a", outcome: .jumped(magnitudeMs: 3), at: at(15))
        #expect(changes.value == 4, "11 ms: published once")
        let moved = report(freshness, at: 16)
        #expect(moved.status == .stale)
        #expect(moved.staleReason == BTAlignmentFreshness.staleReasonMoved)
        freshness.noteClockOutcome(uid: "speaker-a", outcome: .jumped(magnitudeMs: 5), at: at(16))
        #expect(changes.value == 4, "and not again")

        // The next alignment made while stable clears it.
        advance(freshness, from: 17, count: 11)
        freshness.noteAligned(uid: "speaker-a", at: at(28))
        #expect(report(freshness, at: 29).status == .tuned)
        #expect(changes.value == 6)
    }

    @Test func aLostBaselineRestartsTheSumWithoutAPrompt() {
        let freshness = BTAlignmentFreshness()
        let changes = counting(freshness)
        freshness.noteConnected(uid: "speaker-a", at: noon)
        advance(freshness, from: 1, count: 11)
        freshness.noteAligned(uid: "speaker-a", at: at(12))
        freshness.noteClockOutcome(uid: "speaker-a", outcome: .jumped(magnitudeMs: 4), at: at(13))
        freshness.noteClockOutcome(uid: "speaker-a", outcome: .jumped(magnitudeMs: 4), at: at(14))
        freshness.noteClockOutcome(uid: "speaker-a", outcome: .rebaselined, at: at(15))
        freshness.noteClockOutcome(uid: "speaker-a", outcome: .jumped(magnitudeMs: 4), at: at(16))
        #expect(changes.value == 3, "the 8 ms before the restart is gone; 4 ms since is under the line")
        #expect(report(freshness, at: 17).status == .tuned)
    }

    @Test func aReconnectSupersedesBothMarks() {
        let freshness = BTAlignmentFreshness()
        freshness.noteConnected(uid: "speaker-a", at: noon)
        advance(freshness, from: 1, count: 11)
        freshness.noteAligned(uid: "speaker-a", at: at(12))
        freshness.noteClockOutcome(uid: "speaker-a", outcome: .jumped(magnitudeMs: 12), at: at(13))
        #expect(report(freshness, at: 14).staleReason == BTAlignmentFreshness.staleReasonMoved)

        freshness.noteDisconnected(uid: "speaker-a")
        freshness.noteConnected(uid: "speaker-a", at: at(30))
        var again = report(freshness, at: 30)
        #expect(again.status == .stale)
        #expect(again.staleReason == BTAlignmentFreshness.staleReasonReconnected)
        #expect(again.settleRemainingSeconds == 60, "a new link is a new clock: the floor restarts")
        #expect(!freshness.isStable(uid: "speaker-a"))

        freshness.noteAligned(uid: "speaker-a", at: at(32))
        #expect(report(freshness, at: 33).staleReason == BTAlignmentFreshness.staleReasonMeasuredWhileSettling)
        freshness.noteDisconnected(uid: "speaker-a")
        freshness.noteConnected(uid: "speaker-a", at: at(40))
        again = report(freshness, at: 41)
        #expect(again.staleReason == BTAlignmentFreshness.staleReasonReconnected)
    }

    @Test func ordinarySamplesNeverPublish() {
        let freshness = BTAlignmentFreshness()
        let changes = counting(freshness)
        freshness.noteClockOutcome(uid: "speaker-a", outcome: .ignored, at: at(0))
        advance(freshness, from: 1, count: 5)
        freshness.noteClockOutcome(uid: "speaker-a", outcome: .frozen, at: at(6))
        freshness.noteClockOutcome(uid: "speaker-a", outcome: .rebaselined, at: at(7))
        #expect(changes.value == 0)
    }

    // MARK: Decision 5 — what must be true before a run can be staged

    private func room() -> [Device] {
        [
            Device(id: "local", name: "Mac", kind: .localMac, isLocalDevice: true),
            Device(id: "bt-a", name: "Kitchen", kind: .bluetooth),
            Device(id: "bt-b", name: "Study", kind: .bluetooth),
            Device(id: "cast", name: "Nest", kind: .cast),
        ]
    }

    @Test func aTargetThatIsNotPlayingIsRefusedByName() {
        let outcome = CompanionAlignmentPreconditions.evaluate(
            targetID: "bt-a", among: room(), isAudible: { $0 == "local" })
        #expect(outcome == .refused(
            "\u{201C}Kitchen\u{201D} isn't playing right now, so there's nothing to measure."))
    }

    @Test func aPlayingTargetWithNothingElseAudibleIsRefused() {
        let outcome = CompanionAlignmentPreconditions.evaluate(
            targetID: "bt-a", among: room(), isAudible: { $0 == "bt-a" })
        #expect(outcome == .refused("Nothing else is playing to compare \u{201C}Kitchen\u{201D} against."))
    }

    /// A Cast receiver plays seconds behind live, so it is never a reference —
    /// a room where it is the only other audible device has none.
    @Test func aCastReceiverIsNeverTheReference() {
        let outcome = CompanionAlignmentPreconditions.evaluate(
            targetID: "bt-a", among: room(), isAudible: { $0 == "bt-a" || $0 == "cast" })
        #expect(outcome == .refused("Nothing else is playing to compare \u{201C}Kitchen\u{201D} against."))
    }

    @Test func theMacsOwnOutputIsPreferredOverAnotherSpeaker() {
        let outcome = CompanionAlignmentPreconditions.evaluate(
            targetID: "bt-a", among: room(), isAudible: { _ in true })
        #expect(outcome == .ready(referenceID: "local"))
    }

    @Test func anotherBluetoothSpeakerIsTakenWhenTheMacIsSilent() {
        let outcome = CompanionAlignmentPreconditions.evaluate(
            targetID: "bt-a", among: room(), isAudible: { $0 == "bt-a" || $0 == "bt-b" })
        #expect(outcome == .ready(referenceID: "bt-b"))
    }

    @Test func aDeviceThatIsNotBluetoothIsNotAMeasurableTarget() {
        #expect(CompanionAlignmentPreconditions.evaluate(
            targetID: "local", among: room(), isAudible: { _ in true }) == .refused("Unknown device."))
        #expect(CompanionAlignmentPreconditions.evaluate(
            targetID: "nobody", among: room(), isAudible: { _ in true }) == .refused("Unknown device."))
    }
}
