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

    @Test func theSettleFloorRunsFromTheConnectAndThenStops() {
        #expect(BTAlignmentFreshness.settleRemainingSeconds(
            lastConnectedAt: noon, now: noon) == 60)
        #expect(BTAlignmentFreshness.settleRemainingSeconds(
            lastConnectedAt: noon, now: noon.addingTimeInterval(30.4)) == 30)
        #expect(BTAlignmentFreshness.settleRemainingSeconds(
            lastConnectedAt: noon, now: noon.addingTimeInterval(59.5)) == 1)
        #expect(BTAlignmentFreshness.settleRemainingSeconds(
            lastConnectedAt: noon, now: noon.addingTimeInterval(60)) == nil)
        #expect(BTAlignmentFreshness.settleRemainingSeconds(lastConnectedAt: nil) == nil)
    }

    /// The clock verdict, without a clock: evidence it held beats everything,
    /// then evidence it jumped, and the floor decides only the case with no
    /// evidence at all.
    @Test func theClockVerdictIsDecidedByEvidenceThenByTheFloor() {
        func verdict(stableFor: Double, seenJump: Bool,
                     connectedSecondsAgo: TimeInterval?) -> BTAlignmentFreshness.ClockState {
            BTAlignmentFreshness.clockState(
                stableForSeconds: stableFor, seenJump: seenJump,
                lastConnectedAt: connectedSecondsAgo.map { noon.addingTimeInterval(-$0) },
                now: noon)
        }
        #expect(verdict(stableFor: 10, seenJump: false, connectedSecondsAgo: 1) == .steady)
        #expect(verdict(stableFor: 10, seenJump: true, connectedSecondsAgo: 1) == .steady,
                "ten jump-free seconds settle it however badly the link started")
        #expect(verdict(stableFor: 0, seenJump: true, connectedSecondsAgo: 1) == .settling)
        #expect(verdict(stableFor: 4, seenJump: true, connectedSecondsAgo: 300) == .settling,
                "a watched jump outlives the floor — this is the Sonos")
        #expect(verdict(stableFor: 0, seenJump: false, connectedSecondsAgo: 1) == .unknown,
                "inside the floor with nothing observed yet, the Mac has no verdict")
        #expect(verdict(stableFor: 4, seenJump: false, connectedSecondsAgo: 300) == .steady,
                "a whole minute with no evidence either way: nothing left to add")
        #expect(verdict(stableFor: 0, seenJump: false, connectedSecondsAgo: nil) == .steady,
                "no link-up this process watched")
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
        // settling window the first one opened.
        freshness.noteConnected(uid: "speaker-a", at: noon.addingTimeInterval(11))
        let justConnected = freshness.report(uid: "speaker-a", hasStoreEntry: true,
                                            now: noon.addingTimeInterval(10))
        #expect(justConnected.clockState == .unknown)
        #expect(justConnected.settleRemainingSeconds == nil, "the Mac publishes a verdict, not a number")
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

    @Test func theVerdictStaysUnknownWhileTheClockIsStillUnproven() {
        let freshness = BTAlignmentFreshness()
        freshness.noteConnected(uid: "speaker-a", at: noon)
        advance(freshness, from: 1, count: 5)   // four stable seconds by noon+5
        #expect(!freshness.isStable(uid: "speaker-a"))
        #expect(report(freshness, at: 5).clockState == .unknown)
        #expect(report(freshness, at: 5).settleRemainingSeconds == nil)
    }

    /// The Sony class: this clock never steps, so ten quiet seconds settle it
    /// about eleven seconds in, and the phone hears about it exactly once.
    @Test func aCleanClockGoesSteadyOnTenQuietSecondsAndPublishesOnce() {
        let freshness = BTAlignmentFreshness()
        let changes = counting(freshness)
        freshness.noteConnected(uid: "speaker-a", at: noon)
        // The first sample after a sink rebuild only sets the instant.
        freshness.noteClockOutcome(uid: "speaker-a", outcome: .ignored, at: at(1))
        advance(freshness, from: 2, count: 10)   // ten stable seconds at noon+11
        #expect(freshness.isStable(uid: "speaker-a"))
        #expect(report(freshness, at: 11).clockState == .steady)
        #expect(changes.value == 2, "the connect, then the one arrival at steady")
    }

    /// The Sonos class: jumps for forty seconds. The verdict flips to settling
    /// on the FIRST jump and stays there, so the phone is told once rather than
    /// once per jump, and ten clean seconds after the last one end it.
    @Test func aJumpingClockSettlesOnceAndSteadiesOnce() {
        let freshness = BTAlignmentFreshness()
        let changes = counting(freshness)
        freshness.noteConnected(uid: "speaker-a", at: noon)
        for second in stride(from: 1.0, through: 39.0, by: 2.0) {
            freshness.noteClockOutcome(uid: "speaker-a", outcome: .jumped(magnitudeMs: 30),
                                       at: at(second))
        }
        #expect(report(freshness, at: 40).clockState == .settling)
        #expect(changes.value == 2, "the connect, then unknown → settling on the first jump")

        advance(freshness, from: 41, count: 11)
        #expect(report(freshness, at: 51).clockState == .steady)
        #expect(changes.value == 3, "…and one more when it finally holds")
    }

    /// A jump against a clock the Mac had already called steady reopens the
    /// verdict, once.
    @Test func aJumpWhileSteadyReopensTheVerdict() {
        let freshness = BTAlignmentFreshness()
        let changes = counting(freshness)
        freshness.noteConnected(uid: "speaker-a", at: noon)
        advance(freshness, from: 1, count: 11)
        #expect(changes.value == 2)
        freshness.noteClockOutcome(uid: "speaker-a", outcome: .jumped(magnitudeMs: 30), at: at(70))
        #expect(changes.value == 3, "steady → settling")
        #expect(report(freshness, at: 70).clockState == .settling)
        freshness.noteClockOutcome(uid: "speaker-a", outcome: .jumped(magnitudeMs: 30), at: at(71))
        advance(freshness, from: 72, count: 2)
        #expect(changes.value == 3, "a second jump and ordinary samples move nothing")
        #expect(report(freshness, at: 73).clockState == .settling)
    }

    /// The deadlock guard: a speaker that produces no sample at all is not held
    /// at "no verdict yet" forever. The floor expires and it reads steady,
    /// which is what a Mac reporting no clock state gives the phone. A clock
    /// the Mac HAS watched jump is the other case: it stays settling until ten
    /// clean seconds arrive, and it strands nobody, because a speaker silent
    /// enough to produce no samples fails the run's own precondition first.
    @Test func aSpeakerThatNeverPlaysGoesSteadyWhenTheFloorExpires() {
        let freshness = BTAlignmentFreshness()
        freshness.noteConnected(uid: "speaker-a", at: noon)
        #expect(report(freshness, at: 59).clockState == .unknown)
        #expect(report(freshness, at: 61).clockState == .steady)

        let jumpy = BTAlignmentFreshness()
        jumpy.noteConnected(uid: "speaker-a", at: noon)
        jumpy.noteClockOutcome(uid: "speaker-a", outcome: .jumped(magnitudeMs: 12), at: at(70))
        #expect(report(jumpy, at: 200).clockState == .settling)
        jumpy.noteClockOutcome(uid: "speaker-a", outcome: .frozen, at: at(201))
        #expect(report(jumpy, at: 201).clockState == .settling, "a frozen sample says nothing")
    }

    /// Nothing fires at the instant the floor expires — the detector only
    /// speaks while the speaker plays — so the link-up arms its own re-check.
    /// The connect instant is backdated so the shortened timer lands past the
    /// floor.
    @Test func theFloorsExpiryRebroadcastsWhenNoEvidenceEverCame() {
        let freshness = BTAlignmentFreshness(floorRebroadcastDelay: 0.05)
        let changes = counting(freshness)
        freshness.noteConnected(
            uid: "speaker-a",
            at: Date().addingTimeInterval(-BTAlignmentFreshness.settleSeconds - 1))
        #expect(changes.value == 1, "the connect itself")
        SuiteWait.untilOnRunLoop("the floor's expiry to rebroadcast") { changes.value == 2 }
        #expect(changes.value == 2, "the verdict flipped on a clock, so the phone has to be told")
        #expect(freshness.report(uid: "speaker-a", hasStoreEntry: true).clockState == .steady)
    }

    /// A clock with no evidence either way reads steady once the floor is
    /// spent, so an alignment made against it stays ordinary. This is what
    /// keeps a device whose clock query never answers from marking every
    /// alignment early forever. A watched jump is the other side of the same
    /// rule: it marks the alignment early however long ago the link came up.
    @Test func anAlignmentWithNoWindowAndNoSamplesIsNotMarkedEarly() {
        let freshness = BTAlignmentFreshness()
        freshness.noteAligned(uid: "speaker-a", at: noon)
        #expect(report(freshness, at: 0).status == .tuned, "no connect this session")

        freshness.noteConnected(uid: "speaker-a", at: at(10))
        freshness.noteAligned(uid: "speaker-a", at: at(80))
        let pastTheFloor = report(freshness, at: 80)
        #expect(pastTheFloor.status == .tuned, "the floor ran out and no sample ever came")
        #expect(pastTheFloor.staleReason == nil)

        // A watched jump IS a reason, floor or no floor.
        freshness.noteClockOutcome(uid: "speaker-a", outcome: .jumped(magnitudeMs: 12), at: at(81))
        freshness.noteAligned(uid: "speaker-a", at: at(83))
        let early = report(freshness, at: 83)
        #expect(early.clockState == .settling)
        #expect(early.staleReason == BTAlignmentFreshness.staleReasonMeasuredWhileSettling)
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
        #expect(changes.value == 4, "the clock stepped: steady → settling")
        freshness.noteClockOutcome(uid: "speaker-a", outcome: .jumped(magnitudeMs: -4), at: at(14))
        #expect(changes.value == 4, "8 ms summed is under the line, and the verdict has not moved")
        #expect(report(freshness, at: 15).status == .tuned)
        freshness.noteClockOutcome(uid: "speaker-a", outcome: .jumped(magnitudeMs: 3), at: at(15))
        #expect(changes.value == 5, "11 ms: published once")
        let moved = report(freshness, at: 16)
        #expect(moved.status == .stale)
        #expect(moved.staleReason == BTAlignmentFreshness.staleReasonMoved)
        freshness.noteClockOutcome(uid: "speaker-a", outcome: .jumped(magnitudeMs: 5), at: at(16))
        #expect(changes.value == 5, "and not again")

        // The next alignment made while stable clears it.
        advance(freshness, from: 17, count: 11)
        freshness.noteAligned(uid: "speaker-a", at: at(28))
        #expect(report(freshness, at: 29).status == .tuned)
        #expect(changes.value == 7, "the return to steady, then the alignment")
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
        #expect(changes.value == 4,
                "one publish for steady → settling; the 8 ms before the restart is gone and the 4 ms since is under the line")
        #expect(report(freshness, at: 17).clockState == .settling,
                "a rebaseline loses the baseline, not the fact that this link's clock jumps")
        #expect(report(freshness, at: 17).status == .tuned)
    }

    @Test func aReconnectSupersedesBothMarks() {
        let freshness = BTAlignmentFreshness()
        freshness.noteConnected(uid: "speaker-a", at: noon)
        advance(freshness, from: 1, count: 11)
        freshness.noteAligned(uid: "speaker-a", at: at(12))
        freshness.noteClockOutcome(uid: "speaker-a", outcome: .jumped(magnitudeMs: 12), at: at(13))
        #expect(report(freshness, at: 14).staleReason == BTAlignmentFreshness.staleReasonMoved)
        #expect(report(freshness, at: 14).clockState == .settling)

        freshness.noteDisconnected(uid: "speaker-a")
        freshness.noteConnected(uid: "speaker-a", at: at(30))
        var again = report(freshness, at: 30)
        #expect(again.status == .stale)
        #expect(again.staleReason == BTAlignmentFreshness.staleReasonReconnected)
        #expect(again.clockState == .unknown,
                "a new link is a new clock: the floor restarts and the jump memory is gone")
        #expect(again.settleRemainingSeconds == nil)
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
            targetID: "local", among: room(), isAudible: { _ in true }) == .refused("Unknown speaker."))
        #expect(CompanionAlignmentPreconditions.evaluate(
            targetID: "nobody", among: room(), isAudible: { _ in true }) == .refused("Unknown speaker."))
    }
}
