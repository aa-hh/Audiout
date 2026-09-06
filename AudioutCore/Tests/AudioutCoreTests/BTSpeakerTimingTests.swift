// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudioutCore

/// What the Mac publishes about a Bluetooth speaker's timing: what makes a
/// stored offset count as tuned, worth re-checking, or never made, where the
/// row says the number came from, and when a new measurement replaces it.
@Suite final class BTSpeakerTimingTests: IsolatedSuite {

    private let noon = Date(timeIntervalSince1970: 1_756_000_000)

    /// The store the module reads through. Every speaker starts with an offset
    /// stored, because what varies in here is the link edges and the clock,
    /// not the store.
    private final class StoredOffsets: @unchecked Sendable {
        private let lock = NSLock()
        private var byUID: [String: Double]
        init(_ byUID: [String: Double] = [:]) { self.byUID = byUID }
        func set(_ ms: Double?, for uid: String) { lock.withLock { byUID[uid] = ms } }
        func read(_ uid: String) -> Double? { lock.withLock { byUID[uid] } }
    }

    private func timing(_ store: StoredOffsets = StoredOffsets(),
                        stored: Double? = 300,
                        floorRebroadcastDelay: TimeInterval = BTSpeakerTiming.settleSeconds)
        -> BTSpeakerTiming {
        BTSpeakerTiming(storedOffsetMs: { uid in store.read(uid) ?? stored },
                        floorRebroadcastDelay: floorRebroadcastDelay)
    }

    // MARK: The pure rules

    @Test func noStoredOffsetIsAlwaysNotSet() {
        // Even with both marks standing: the row is decided first by whether
        // the store holds an offset, and this one holds none.
        #expect(BTSpeakerTiming.status(hasStoredOffset: false,
                                       measuredEarly: true, moved: true) == .notSet)
        #expect(BTSpeakerTiming.source(hasStoredOffset: false, lastConnectedAt: noon,
                                       alignedAt: noon, measuredEarly: false, byEar: true) == nil)
    }

    /// ADR 0001: a reconnect applies the stored offset again, so it leaves the
    /// row tuned and moves the source, where the old rule flipped the row to
    /// stale and asked the user for a measurement it already had.
    @Test func aReconnectLeavesTheRowTunedFromLastTime() {
        #expect(BTSpeakerTiming.status(hasStoredOffset: true,
                                       measuredEarly: false, moved: false) == .tuned)
        #expect(BTSpeakerTiming.source(hasStoredOffset: true,
                                       lastConnectedAt: noon.addingTimeInterval(30),
                                       alignedAt: noon,
                                       measuredEarly: false, byEar: true) == .fromLastTime)
    }

    @Test func aligningAfterTheReconnectMakesTheNumberThisLinksAgain() {
        #expect(BTSpeakerTiming.source(hasStoredOffset: true, lastConnectedAt: noon,
                                       alignedAt: noon.addingTimeInterval(30),
                                       measuredEarly: false, byEar: false) == .measured)
        #expect(BTSpeakerTiming.source(hasStoredOffset: true, lastConnectedAt: noon,
                                       alignedAt: noon.addingTimeInterval(30),
                                       measuredEarly: false, byEar: true) == .byEar)
    }

    /// A clock that had not settled outranks whatever found the number: the
    /// row is asking for a re-check either way, and `firstPass` is the value
    /// the phone renders that with.
    @Test func anAlignmentMadeEarlyIsAFirstPassWhoeverMadeIt() {
        #expect(BTSpeakerTiming.status(hasStoredOffset: true,
                                       measuredEarly: true, moved: false) == .stale)
        for byEar in [true, false] {
            #expect(BTSpeakerTiming.source(hasStoredOffset: true, lastConnectedAt: noon,
                                           alignedAt: noon.addingTimeInterval(30),
                                           measuredEarly: true, byEar: byEar) == .firstPass)
        }
    }

    /// The launch case: a speaker tuned in some earlier session has a stored
    /// offset but no alignment instant THIS process watched. It is applied and
    /// tuned — reading it as stale would put every tuned speaker under a
    /// re-check banner on every launch — and last time's is all this process
    /// can honestly say about where it came from.
    @Test func aStoredOffsetWithNoAlignmentInstantIsTunedFromLastTime() {
        for connected in [noon, nil] {
            #expect(BTSpeakerTiming.source(hasStoredOffset: true, lastConnectedAt: connected,
                                           alignedAt: nil,
                                           measuredEarly: false, byEar: false) == .fromLastTime)
        }
    }

    /// The 10 ms line (ADR 0001): a re-measurement that agrees leaves the
    /// stored offset alone so the speaker never churns, and one that disagrees
    /// replaces it. Widen the comparison and 9 ms starts moving the sink.
    @Test func aMeasurementReplacesTheStoredOffsetAtTenMilliseconds() {
        let timing = self.timing(stored: 300)
        #expect(timing.recordMeasurement(uid: "speaker-a", correctedMs: 309, at: noon) == .keepStored)
        #expect(timing.recordMeasurement(uid: "speaker-a", correctedMs: 310, at: noon) == .replace)
        #expect(timing.recordMeasurement(uid: "speaker-a", correctedMs: 311, at: noon) == .replace)
        #expect(timing.recordMeasurement(uid: "speaker-a", correctedMs: 291, at: noon) == .keepStored,
                "the same distance the other way")
        #expect(BTSpeakerTiming.decision(correctedMs: 42, storedMs: nil) == .replace,
                "a speaker with nothing stored has nothing to keep")
    }

    // MARK: The settling window

    @Test func theSettleFloorRunsFromTheConnectAndThenStops() {
        #expect(BTSpeakerTiming.settleRemainingSeconds(
            lastConnectedAt: noon, now: noon) == 60)
        #expect(BTSpeakerTiming.settleRemainingSeconds(
            lastConnectedAt: noon, now: noon.addingTimeInterval(30.4)) == 30)
        #expect(BTSpeakerTiming.settleRemainingSeconds(
            lastConnectedAt: noon, now: noon.addingTimeInterval(59.5)) == 1)
        #expect(BTSpeakerTiming.settleRemainingSeconds(
            lastConnectedAt: noon, now: noon.addingTimeInterval(60)) == nil)
        #expect(BTSpeakerTiming.settleRemainingSeconds(lastConnectedAt: nil) == nil)
    }

    /// The clock verdict, without a clock: evidence it held beats everything,
    /// then evidence it jumped, and the floor decides only the case with no
    /// evidence at all.
    @Test func theClockVerdictIsDecidedByEvidenceThenByTheFloor() {
        func verdict(stableFor: Double, seenJump: Bool,
                     connectedSecondsAgo: TimeInterval?) -> BTSpeakerTiming.ClockState {
            BTSpeakerTiming.clockState(
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
        let store = StoredOffsets(["speaker-a": 300, "speaker-b": 300])
        let timing = self.timing(store, stored: nil)
        final class Count: @unchecked Sendable {
            let lock = NSLock()
            var value = 0
        }
        let changes = Count()
        timing.onChange = { changes.lock.withLock { changes.value += 1 } }

        timing.noteAligned(uid: "speaker-a", at: noon)
        timing.noteConnected(uid: "speaker-a", at: noon.addingTimeInterval(10))
        // The manual reconnect and the enumerator snapshot both report the SAME
        // link-up, moments apart. The second report must not restart the
        // settling window the first one opened.
        timing.noteConnected(uid: "speaker-a", at: noon.addingTimeInterval(11))
        let justConnected = timing.report(uid: "speaker-a", now: noon.addingTimeInterval(10))
        #expect(justConnected.clockState == .unknown)
        #expect(justConnected.settleRemainingSeconds == nil, "the Mac publishes a verdict, not a number")
        let reconnected = timing.report(uid: "speaker-a", now: noon.addingTimeInterval(20))
        #expect(reconnected.status == .tuned)
        #expect(reconnected.source == .fromLastTime)
        // The other speaker saw neither edge, so nothing about it moved.
        #expect(timing.report(uid: "speaker-b", now: noon.addingTimeInterval(20)).status == .tuned)

        // Clearing a tuning removes the stored offset and the instant a later
        // connect would be measured against.
        store.set(nil, for: "speaker-a")
        timing.clearAligned(uid: "speaker-a")
        #expect(timing.report(uid: "speaker-a", now: noon.addingTimeInterval(20)).status == .notSet)
        #expect(changes.lock.withLock { changes.value } == 3)
    }

    /// The echo is collapsed, but a speaker that genuinely drops and comes back
    /// is a NEW link-up and must land — otherwise a power-cycled speaker would
    /// go on claiming an alignment made before its link re-rolled.
    @Test func aLinkThatDroppedAndReturnedIsANewConnect() {
        let timing = self.timing()
        timing.noteAligned(uid: "speaker-a", at: noon)
        timing.noteConnected(uid: "speaker-a", at: noon.addingTimeInterval(-30))
        #expect(timing.report(uid: "speaker-a", now: noon).source == .byEar)

        timing.noteDisconnected(uid: "speaker-a")
        timing.noteConnected(uid: "speaker-a", at: noon.addingTimeInterval(30))
        let again = timing.report(uid: "speaker-a", now: noon.addingTimeInterval(40))
        #expect(again.status == .tuned)
        #expect(again.source == .fromLastTime)
    }

    /// Everything else in here treats the ear and the microphone as one
    /// alignment, and the row still has to say which found the number.
    @Test func theRowSaysWhetherTheEarOrTheMicrophoneFoundTheNumber() {
        let timing = self.timing()
        timing.noteConnected(uid: "speaker-a", at: noon)
        advance(timing, from: 1, count: 11)
        _ = timing.recordMeasurement(uid: "speaker-a", correctedMs: 340, at: at(12))
        #expect(report(timing, at: 13).source == .measured)
        timing.noteAligned(uid: "speaker-a", at: at(14))
        #expect(report(timing, at: 15).source == .byEar)
    }

    /// A kept measurement records the alignment as surely as a replaced one:
    /// the phone confirmed the number, so it is no longer last time's.
    @Test func aKeptMeasurementStillRecordsTheAlignment() {
        let timing = self.timing(stored: 300)
        timing.noteConnected(uid: "speaker-a", at: noon)
        advance(timing, from: 1, count: 11)
        #expect(report(timing, at: 12).source == .fromLastTime)
        #expect(timing.recordMeasurement(uid: "speaker-a", correctedMs: 305, at: at(12)) == .keepStored)
        #expect(report(timing, at: 13).source == .measured)
    }

    // MARK: The clock detector's estimate

    private final class ChangeCount: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = 0
        var value: Int { lock.withLock { _value } }
        func bump() { lock.withLock { _value += 1 } }
    }

    private func counting(_ timing: BTSpeakerTiming) -> ChangeCount {
        let changes = ChangeCount()
        timing.onChange = { changes.bump() }
        return changes
    }

    private func at(_ seconds: TimeInterval) -> Date { noon.addingTimeInterval(seconds) }

    /// `count` advancing samples a second apart, the first at `from`. The
    /// first only sets the instant, so eleven make ten stable seconds.
    private func advance(_ timing: BTSpeakerTiming, uid: String = "speaker-a",
                         from: TimeInterval, count: Int) {
        for s in 0..<count {
            timing.noteClockOutcome(uid: uid, outcome: .advanced, at: at(from + Double(s)))
        }
    }

    private func report(_ timing: BTSpeakerTiming, uid: String = "speaker-a",
                        at seconds: TimeInterval) -> BTSpeakerTimingReport {
        timing.report(uid: uid, now: at(seconds))
    }

    @Test func theVerdictStaysUnknownWhileTheClockIsStillUnproven() {
        let timing = self.timing()
        timing.noteConnected(uid: "speaker-a", at: noon)
        advance(timing, from: 1, count: 5)   // four stable seconds by noon+5
        #expect(!timing.isStable(uid: "speaker-a"))
        #expect(report(timing, at: 5).clockState == .unknown)
        #expect(report(timing, at: 5).settleRemainingSeconds == nil)
    }

    /// The Sony class: this clock never steps, so ten quiet seconds settle it
    /// about eleven seconds in, and the phone hears about it exactly once.
    @Test func aCleanClockGoesSteadyOnTenQuietSecondsAndPublishesOnce() {
        let timing = self.timing()
        let changes = counting(timing)
        timing.noteConnected(uid: "speaker-a", at: noon)
        // The first sample after a sink rebuild only sets the instant.
        timing.noteClockOutcome(uid: "speaker-a", outcome: .ignored, at: at(1))
        advance(timing, from: 2, count: 10)   // ten stable seconds at noon+11
        #expect(timing.isStable(uid: "speaker-a"))
        #expect(report(timing, at: 11).clockState == .steady)
        #expect(changes.value == 2, "the connect, then the one arrival at steady")
    }

    /// The Sonos class: jumps for forty seconds. The verdict flips to settling
    /// on the FIRST jump and stays there, so the phone is told once rather than
    /// once per jump, and ten clean seconds after the last one end it.
    @Test func aJumpingClockSettlesOnceAndSteadiesOnce() {
        let timing = self.timing()
        let changes = counting(timing)
        timing.noteConnected(uid: "speaker-a", at: noon)
        for second in stride(from: 1.0, through: 39.0, by: 2.0) {
            timing.noteClockOutcome(uid: "speaker-a", outcome: .jumped(magnitudeMs: 30),
                                    at: at(second))
        }
        #expect(report(timing, at: 40).clockState == .settling)
        #expect(changes.value == 2, "the connect, then unknown → settling on the first jump")

        advance(timing, from: 41, count: 11)
        #expect(report(timing, at: 51).clockState == .steady)
        #expect(changes.value == 3, "…and one more when it finally holds")
    }

    /// A jump against a clock the Mac had already called steady reopens the
    /// verdict, once.
    @Test func aJumpWhileSteadyReopensTheVerdict() {
        let timing = self.timing()
        let changes = counting(timing)
        timing.noteConnected(uid: "speaker-a", at: noon)
        advance(timing, from: 1, count: 11)
        #expect(changes.value == 2)
        timing.noteClockOutcome(uid: "speaker-a", outcome: .jumped(magnitudeMs: 30), at: at(70))
        #expect(changes.value == 3, "steady → settling")
        #expect(report(timing, at: 70).clockState == .settling)
        timing.noteClockOutcome(uid: "speaker-a", outcome: .jumped(magnitudeMs: 30), at: at(71))
        advance(timing, from: 72, count: 2)
        #expect(changes.value == 3, "a second jump and ordinary samples move nothing")
        #expect(report(timing, at: 73).clockState == .settling)
    }

    /// The deadlock guard: a speaker that produces no sample at all is not held
    /// at "no verdict yet" forever. The floor expires and it reads steady,
    /// which is what a Mac reporting no clock state gives the phone. A clock
    /// the Mac HAS watched jump is the other case: it stays settling until ten
    /// clean seconds arrive, and it strands nobody, because a speaker silent
    /// enough to produce no samples fails the run's own precondition first.
    @Test func aSpeakerThatNeverPlaysGoesSteadyWhenTheFloorExpires() {
        let timing = self.timing()
        timing.noteConnected(uid: "speaker-a", at: noon)
        #expect(report(timing, at: 59).clockState == .unknown)
        #expect(report(timing, at: 61).clockState == .steady)

        let jumpy = self.timing()
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
        let timing = self.timing(floorRebroadcastDelay: 0.05)
        let changes = counting(timing)
        timing.noteConnected(
            uid: "speaker-a",
            at: Date().addingTimeInterval(-BTSpeakerTiming.settleSeconds - 1))
        #expect(changes.value == 1, "the connect itself")
        SuiteWait.untilOnRunLoop("the floor's expiry to rebroadcast") { changes.value == 2 }
        #expect(changes.value == 2, "the verdict flipped on a clock, so the phone has to be told")
        #expect(timing.report(uid: "speaker-a").clockState == .steady)
    }

    /// A clock with no evidence either way reads steady once the floor is
    /// spent, so an alignment made against it stays ordinary. This is what
    /// keeps a device whose clock query never answers from marking every
    /// alignment early forever. A watched jump is the other side of the same
    /// rule: it marks the alignment early however long ago the link came up.
    @Test func anAlignmentWithNoWindowAndNoSamplesIsNotMarkedEarly() {
        let timing = self.timing()
        timing.noteAligned(uid: "speaker-a", at: noon)
        #expect(report(timing, at: 0).status == .tuned, "no connect this session")

        timing.noteConnected(uid: "speaker-a", at: at(10))
        timing.noteAligned(uid: "speaker-a", at: at(80))
        let pastTheFloor = report(timing, at: 80)
        #expect(pastTheFloor.status == .tuned, "the floor ran out and no sample ever came")
        #expect(pastTheFloor.staleReason == nil)

        // A watched jump IS a reason, floor or no floor.
        timing.noteClockOutcome(uid: "speaker-a", outcome: .jumped(magnitudeMs: 12), at: at(81))
        timing.noteAligned(uid: "speaker-a", at: at(83))
        let early = report(timing, at: 83)
        #expect(early.clockState == .settling)
        #expect(early.staleReason == BTSpeakerTiming.staleReasonMeasuredWhileSettling)
        #expect(early.source == .firstPass)
    }

    @Test func aMeasurementMadeWhileSettlingIsMarkedUntilOneMadeWhileStable() {
        let timing = self.timing()
        timing.noteConnected(uid: "speaker-a", at: noon)
        timing.noteAligned(uid: "speaker-a", at: at(5))
        var early = report(timing, at: 6)
        #expect(early.status == .stale)
        #expect(early.staleReason == BTSpeakerTiming.staleReasonMeasuredWhileSettling)
        #expect(timing.earlyAlignmentJumpSumMs(uid: "speaker-a") == 0)
        // The jumps since are summed for the telemetry line, but never
        // promote the row to "moved": it is already asking for a re-check.
        timing.noteClockOutcome(uid: "speaker-a", outcome: .jumped(magnitudeMs: 4), at: at(7))
        timing.noteClockOutcome(uid: "speaker-a", outcome: .jumped(magnitudeMs: -8), at: at(8))
        #expect(timing.earlyAlignmentJumpSumMs(uid: "speaker-a") == 12)
        early = report(timing, at: 9)
        #expect(early.staleReason == BTSpeakerTiming.staleReasonMeasuredWhileSettling)

        advance(timing, from: 9, count: 11)
        timing.noteAligned(uid: "speaker-a", at: at(20))
        let settled = report(timing, at: 21)
        #expect(settled.status == .tuned)
        #expect(settled.staleReason == nil)
        #expect(timing.earlyAlignmentJumpSumMs(uid: "speaker-a") == nil)
        #expect(report(timing, uid: "speaker-b", at: 21).status == .tuned, "per device")
    }

    @Test func movedIsPublishedOnceWhenTheJumpsSumToTenMilliseconds() {
        let timing = self.timing()
        let changes = counting(timing)
        timing.noteConnected(uid: "speaker-a", at: noon)
        advance(timing, from: 1, count: 11)
        timing.noteAligned(uid: "speaker-a", at: at(12))
        #expect(changes.value == 3)
        timing.noteClockOutcome(uid: "speaker-a", outcome: .jumped(magnitudeMs: 4), at: at(13))
        #expect(changes.value == 4, "the clock stepped: steady → settling")
        timing.noteClockOutcome(uid: "speaker-a", outcome: .jumped(magnitudeMs: -4), at: at(14))
        #expect(changes.value == 4, "8 ms summed is under the line, and the verdict has not moved")
        #expect(report(timing, at: 15).status == .tuned)
        timing.noteClockOutcome(uid: "speaker-a", outcome: .jumped(magnitudeMs: 3), at: at(15))
        #expect(changes.value == 5, "11 ms: published once")
        let moved = report(timing, at: 16)
        #expect(moved.status == .stale)
        #expect(moved.staleReason == BTSpeakerTiming.staleReasonMoved)
        #expect(moved.source == .byEar, "a moved clock says nothing about who found the number")
        timing.noteClockOutcome(uid: "speaker-a", outcome: .jumped(magnitudeMs: 5), at: at(16))
        #expect(changes.value == 5, "and not again")

        // The next alignment made while stable clears it.
        advance(timing, from: 17, count: 11)
        timing.noteAligned(uid: "speaker-a", at: at(28))
        #expect(report(timing, at: 29).status == .tuned)
        #expect(changes.value == 7, "the return to steady, then the alignment")
    }

    @Test func aLostBaselineRestartsTheSumWithoutAPrompt() {
        let timing = self.timing()
        let changes = counting(timing)
        timing.noteConnected(uid: "speaker-a", at: noon)
        advance(timing, from: 1, count: 11)
        timing.noteAligned(uid: "speaker-a", at: at(12))
        timing.noteClockOutcome(uid: "speaker-a", outcome: .jumped(magnitudeMs: 4), at: at(13))
        timing.noteClockOutcome(uid: "speaker-a", outcome: .jumped(magnitudeMs: 4), at: at(14))
        timing.noteClockOutcome(uid: "speaker-a", outcome: .rebaselined, at: at(15))
        timing.noteClockOutcome(uid: "speaker-a", outcome: .jumped(magnitudeMs: 4), at: at(16))
        #expect(changes.value == 4,
                "one publish for steady → settling; the 8 ms before the restart is gone and the 4 ms since is under the line")
        #expect(report(timing, at: 17).clockState == .settling,
                "a rebaseline loses the baseline, not the fact that this link's clock jumps")
        #expect(report(timing, at: 17).status == .tuned)
    }

    /// A reconnect supersedes both marks, and outranks a first pass in the
    /// source: whatever the last link's clock did, the number in force is the
    /// one this speaker had when it was last aligned.
    @Test func aReconnectSupersedesBothMarksAndBeatsAFirstPass() {
        let timing = self.timing()
        timing.noteConnected(uid: "speaker-a", at: noon)
        advance(timing, from: 1, count: 11)
        timing.noteAligned(uid: "speaker-a", at: at(12))
        timing.noteClockOutcome(uid: "speaker-a", outcome: .jumped(magnitudeMs: 12), at: at(13))
        #expect(report(timing, at: 14).staleReason == BTSpeakerTiming.staleReasonMoved)
        #expect(report(timing, at: 14).clockState == .settling)

        timing.noteDisconnected(uid: "speaker-a")
        timing.noteConnected(uid: "speaker-a", at: at(30))
        var again = report(timing, at: 30)
        #expect(again.status == .tuned, "the stored offset goes back on the sink, so nothing is asked")
        #expect(again.staleReason == nil)
        #expect(again.source == .fromLastTime)
        #expect(again.clockState == .unknown,
                "a new link is a new clock: the floor restarts and the jump memory is gone")
        #expect(again.settleRemainingSeconds == nil)
        #expect(!timing.isStable(uid: "speaker-a"))

        _ = timing.recordMeasurement(uid: "speaker-a", correctedMs: 340, at: at(32))
        let firstPass = report(timing, at: 33)
        #expect(firstPass.staleReason == BTSpeakerTiming.staleReasonMeasuredWhileSettling)
        #expect(firstPass.source == .firstPass, "measured before this link's clock settled")

        timing.noteDisconnected(uid: "speaker-a")
        timing.noteConnected(uid: "speaker-a", at: at(40))
        again = report(timing, at: 41)
        #expect(again.status == .tuned)
        #expect(again.source == .fromLastTime, "the reconnect outranks the first pass")
    }

    @Test func ordinarySamplesNeverPublish() {
        let timing = self.timing()
        let changes = counting(timing)
        timing.noteClockOutcome(uid: "speaker-a", outcome: .ignored, at: at(0))
        advance(timing, from: 1, count: 5)
        timing.noteClockOutcome(uid: "speaker-a", outcome: .frozen, at: at(6))
        timing.noteClockOutcome(uid: "speaker-a", outcome: .rebaselined, at: at(7))
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
