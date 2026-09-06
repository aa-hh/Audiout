// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import AudioutProtocol

/// What the Mac publishes about one Bluetooth speaker's timing, and the one
/// keep-or-replace decision a reported measurement needs. Answered per device
/// UID from two in-memory timestamps, the clock detector's standing verdict,
/// and the one durable fact — the store holds an offset for this UID or it
/// does not — which the owner injects as a closure so a reader passes nothing
/// but the UID.
///
/// A reconnect does not unset the row (ADR 0001). The stored offset is pushed
/// to the sink again on every arm, so the honest report is a tuned speaker
/// whose number is ``Source/fromLastTime``, and the phone offers a re-check
/// once the clock reads steady. What makes a row stale is a number that cannot
/// be trusted at all: one made while the clock was still settling, or a clock
/// that has stepped since.
///
/// Deliberately IN-MEMORY, not persisted: a launch starts every device at
/// "no alignment I watched being made", which is the honest answer — this
/// process saw no earlier session's link edges or Keeps. That is why a store
/// entry with no ``noteAligned(uid:at:)`` behind it reads tuned from last
/// time rather than measured: the number is real and applied, and this
/// process cannot say what found it.
///
/// It also carries the other half the sheet needs: ``ClockState``, the Mac's
/// standing verdict on whether this speaker's clock has settled since its link
/// came up. The Mac publishes that verdict and no seconds. The detector's own
/// count restarts on every jump, so a number would jitter up and down on the
/// very speakers it exists for, and the fixed floor's number promises a minute
/// to a speaker that is ready in eleven seconds.
///
/// Threading: a plain lock, because the writers are on different queues —
/// `NativeBackend.stateQueue` records connects, the main actor records
/// alignments, and the snapshot builder reads.
public final class BTSpeakerTiming: @unchecked Sendable {

    /// What the phone's row shows. Wire values are the raw strings
    /// (`AudioutProtocol.DeviceState.AlignmentState.status`).
    public enum Status: String, Sendable {
        /// No stored alignment at all — "Timing not set".
        case notSet
        /// Stored, applied, and nothing has happened to it the row must
        /// mention — whatever found the number, which ``Source`` carries.
        case tuned
        /// Stored and applied, but worth re-checking: made against a clock
        /// that had not settled, or the clock has stepped since.
        case stale
    }

    /// The Mac's verdict on this speaker's Bluetooth clock since its link came
    /// up, which is what decides whether a measurement now would measure the
    /// speaker or the settling. Wire values are the raw strings
    /// (`AudioutProtocol.DeviceState.AlignmentState.clockState`).
    public enum ClockState: String, Sendable {
        /// No verdict yet: fewer than ten jump-free seconds observed and no
        /// jump seen, or the speaker is not playing.
        case unknown
        /// The Mac has seen the clock jump since link-up and it has not yet
        /// held still for ten seconds.
        case settling
        /// Ten jump-free seconds observed, or a minute passed with no evidence
        /// either way.
        case steady
    }

    /// Where the offset now in force came from, so the row can say so without
    /// working it out. Raw values are the wire strings
    /// (`AudioutProtocol.AlignmentSource`).
    public enum Source: String, Sendable {
        /// A phone measurement taken once the Mac called the clock steady.
        case measured
        /// A measurement or a Keep made before the clock settled: applied and
        /// labelled at once, re-checked when the clock reads steady.
        case firstPass
        /// The offset this speaker had when it was last aligned, applied again
        /// on reconnect until a new measurement replaces it.
        case fromLastTime
        /// Found by ear — the Mac's paired-click wizard, or a nudge someone
        /// typed or dragged. No microphone was involved.
        case byEar
    }

    /// What a reported measurement does to the stored offset.
    public enum MeasurementDecision: Equatable, Sendable {
        /// Far enough from the stored offset to be a different answer.
        case replace
        /// Close enough that the stored offset stands, so the sink is left
        /// where it is and the phone is told the number agreed.
        case keepStored
    }

    /// One of the two ``Status/stale`` reasons
    /// (`DeviceState.AlignmentState.staleReason` on the wire): the alignment
    /// was made while the speaker's clock was still settling. A reconnected
    /// speaker is neither reason — it is tuned from last time.
    public static let staleReasonMeasuredWhileSettling = "measuredWhileSettling"
    /// The other reason, and the one published when both stand: the speaker's
    /// clock has stepped 10 ms or more, summed, since the alignment was
    /// applied.
    public static let staleReasonMoved = "moved"

    /// How long after a baseband reconnect the Mac holds its verdict open when
    /// the clock detector has said nothing either way. The only thing this
    /// floor still decides is how long ``ClockState/unknown`` lasts on a
    /// speaker that produces no evidence at all: past it the Mac has nothing
    /// to add, so the verdict becomes ``ClockState/steady`` and the phone's
    /// button goes live, exactly as it did for a Mac that reported no clock
    /// state at all. Evidence overrides it in both directions — 10 jump-free
    /// seconds end it early, a watched jump keeps the verdict at
    /// ``ClockState/settling`` well past it.
    /// razor: one fixed floor for every speaker. The ceiling is a learned
    /// per-device prior.
    public static let settleSeconds: TimeInterval = 60
    /// Summed jump magnitude since the alignment at which the row asks for a
    /// re-check: 2.5 times the ±4 ms "in step" band, 5 times the jump floor.
    static let movedThresholdMs = 10.0

    /// Fired after any recorded change, so the wiring layer can rebuild and
    /// rebroadcast the companion snapshot. Called on whichever queue recorded
    /// the change — the wiring hops to main itself.
    public var onChange: (@Sendable () -> Void)? {
        get { lock.withLock { _onChange } }
        set { lock.withLock { _onChange = newValue } }
    }

    private let lock = NSLock()
    private var _onChange: (@Sendable () -> Void)?
    private var lastConnectedAtByUID: [String: Date] = [:]
    private var alignedAtByUID: [String: Date] = [:]
    private var linkUpUIDs: Set<String> = []
    // The clock detector's view of each device, as ``noteClockOutcome`` folds
    // it in. Seconds of jump-free advance; when the last advancing sample
    // arrived; summed |jump| since the alignment instant.
    private var stableForSecondsByUID: [String: Double] = [:]
    private var lastAdvanceAtByUID: [String: Date] = [:]
    private var jumpSumSinceAlignedMsByUID: [String: Double] = [:]
    // Whether the detector has watched this device's clock step since its link
    // came up — the one piece of evidence that separates "settling" from "no
    // verdict yet". A sink rebuild loses the baseline, not the fact that this
    // link's clock jumps, so only a new link clears it.
    private var seenJumpSinceLinkUIDs: Set<String> = []
    private var measuredWhileSettlingUIDs: Set<String> = []
    private var movedUIDs: Set<String> = []
    // Whose current offset a microphone found, as opposed to somebody's ear.
    // Nothing else in here can tell the two apart, and the row says which.
    private var measuredUIDs: Set<String> = []
    private let floorRebroadcastDelay: TimeInterval
    private let storedOffsetMs: @Sendable (String) -> Double?

    /// - Parameter storedOffsetMs: the offset the store holds for a UID, or
    ///   `nil` for a speaker with none. Called OUTSIDE this type's lock, on
    ///   every read and before every decision, because it reaches into the
    ///   owner's store behind the owner's own lock.
    /// - Parameter floorRebroadcastDelay: how long after a link-up to re-check
    ///   whether ``settleSeconds`` expired with no evidence either way. Only
    ///   the tests pass anything but the floor itself.
    public init(storedOffsetMs: @escaping @Sendable (String) -> Double?,
                floorRebroadcastDelay: TimeInterval = BTSpeakerTiming.settleSeconds) {
        self.storedOffsetMs = storedOffsetMs
        self.floorRebroadcastDelay = floorRebroadcastDelay
    }

    // MARK: Recording

    /// A baseband link came up for this device.
    ///
    /// Two independent observers see the SAME link-up — the manual reconnect's
    /// own outcome, and the enumerator snapshot's availability edge a moment
    /// later — so this records only the first of them and ignores the rest
    /// until ``noteDisconnected(uid:)`` says the link went away. One link-up,
    /// one instant, whichever observer got there first; otherwise the settling
    /// window would restart on the echo.
    public func noteConnected(uid: String, at date: Date = Date()) {
        let (recorded, changed) = lock.withLock { () -> (Bool, (@Sendable () -> Void)?) in
            guard linkUpUIDs.insert(uid).inserted else { return (false, nil) }
            lastConnectedAtByUID[uid] = date
            // A new link is a new clock: whatever the detector knew about the
            // old one is gone, and a reconnect supersedes both marks.
            stableForSecondsByUID[uid] = 0
            lastAdvanceAtByUID[uid] = nil
            jumpSumSinceAlignedMsByUID[uid] = 0
            seenJumpSinceLinkUIDs.remove(uid)
            measuredWhileSettlingUIDs.remove(uid)
            movedUIDs.remove(uid)
            return (true, _onChange)
        }
        if recorded { scheduleFloorRebroadcast(uid: uid, linkUpAt: date) }
        changed?()
    }

    /// A link-up that produces no evidence at all sits at ``ClockState/unknown``
    /// until ``settleSeconds`` runs out and then reads ``ClockState/steady``.
    /// Nothing fires at that instant — the detector only speaks while the
    /// speaker plays — so the state flipped on a clock, and the phone has to be
    /// told. Skipped when a later link-up superseded this one, or when ten
    /// jump-free seconds settled the verdict and published for themselves.
    private func scheduleFloorRebroadcast(uid: String, linkUpAt: Date) {
        DispatchQueue.global(qos: .utility)
            .asyncAfter(deadline: .now() + floorRebroadcastDelay + 0.1) { [weak self] in
                guard let self else { return }
                let changed = self.lock.withLock { () -> (@Sendable () -> Void)? in
                    // Same link-up, not superseded; and steady by expiry
                    // rather than by ten jump-free seconds, which published
                    // for itself when it arrived.
                    guard self.lastConnectedAtByUID[uid] == linkUpAt,
                          self.stableForSecondsByUID[uid, default: 0] < BTClockStability.stableAfterSeconds,
                          self.clockStateLocked(uid, now: Date()) == .steady
                    else { return nil }
                    return self._onChange
                }
                changed?()
            }
    }

    /// The link for this device went away, so the next ``noteConnected(uid:)``
    /// is a new link-up rather than a second report of the one before it.
    /// Nothing the phone can see moves, so this fires no change.
    public func noteDisconnected(uid: String) {
        lock.withLock { _ = linkUpUIDs.remove(uid) }
    }

    /// An alignment somebody's ear landed for this device — the Mac wizard's
    /// Keep, a fine-tune committed, a nudge typed into the field. The phone's
    /// measurements come in through
    /// ``recordMeasurement(uid:correctedMs:at:)`` instead, and that is the
    /// whole difference between ``Source/byEar`` and ``Source/measured``.
    public func noteAligned(uid: String, at date: Date = Date()) {
        let changed = lock.withLock { () -> (@Sendable () -> Void)? in
            measuredUIDs.remove(uid)
            return recordAlignmentLocked(uid: uid, at: date)
        }
        changed?()
    }

    /// A measurement the phone reported, about to be written: keep the stored
    /// offset or replace it, and record the alignment either way.
    ///
    /// `correctedMs` is the offset the caller is about to store, already
    /// through its own stagger and clamp arithmetic — this type does none of
    /// that and hands the number back untouched. Call it BEFORE the store
    /// write, because the decision reads what is stored now. A `keepStored`
    /// still records the alignment: the phone confirmed the number, and a
    /// confirmed number is no longer last time's.
    public func recordMeasurement(uid: String, correctedMs: Double,
                                  at date: Date = Date()) -> MeasurementDecision {
        let decision = Self.decision(correctedMs: correctedMs, storedMs: storedOffsetMs(uid))
        let changed = lock.withLock { () -> (@Sendable () -> Void)? in
            measuredUIDs.insert(uid)
            return recordAlignmentLocked(uid: uid, at: date)
        }
        changed?()
        return decision
    }

    /// The half both recording paths share.
    ///
    /// Decides here, not at the call sites, whether the alignment was made too
    /// early: one made against a clock the Mac does not call steady is marked
    /// "measured while settling", one made against a steady clock clears that
    /// mark. It is the same verdict the phone gates its button on, so the two
    /// surfaces can never disagree about what "too early" meant — including
    /// past the floor, where a clock the detector has watched jump is still
    /// settling. A clock with no evidence either way reads steady rather than
    /// settling, which is what keeps a device whose clock query never answers
    /// from marking every alignment early forever. Either way the jump sum
    /// restarts and a standing "moved" mark clears: this alignment is the new
    /// instant to move from.
    private func recordAlignmentLocked(uid: String, at date: Date) -> (@Sendable () -> Void)? {
        alignedAtByUID[uid] = date
        jumpSumSinceAlignedMsByUID[uid] = 0
        movedUIDs.remove(uid)
        if clockStateLocked(uid, now: date) != .steady {
            measuredWhileSettlingUIDs.insert(uid)
        } else {
            measuredWhileSettlingUIDs.remove(uid)
        }
        return _onChange
    }

    /// This device's tuning was cleared, so there is no alignment instant left
    /// for a later connect to be measured against, and nothing for either
    /// mark to be about.
    public func clearAligned(uid: String) {
        let changed = lock.withLock { () -> (@Sendable () -> Void)? in
            alignedAtByUID.removeValue(forKey: uid)
            measuredWhileSettlingUIDs.remove(uid)
            measuredUIDs.remove(uid)
            movedUIDs.remove(uid)
            return _onChange
        }
        changed?()
    }

    /// One sample's verdict from this device's ``BTClockStability``, on the
    /// watcher's queue once a second. Fires ``onChange`` ONLY when something
    /// the phone can see flips — the ``ClockState`` this sample left the device
    /// in differs from the one it found, or the jump sum crossed the "moved"
    /// line for an aligned device, once. That comparison is the whole publish
    /// rule: arrival at steady, the first jump after a link-up, and a jump
    /// against a steady clock each move it, and every ordinary advancing,
    /// frozen or repeat-jump sample leaves it where it was. A rebaseline (the
    /// device's clock origin moved under a running sink) restarts the count
    /// and the sum silently: the baseline is lost, and a prompt on a guess is
    /// a spurious prompt. A first sample (`.ignored`) only holds: it follows
    /// every sink rebuild, and a measurement run rebuilds the sink twice, so
    /// resetting there would leave a speaker "settling" for as long as it was
    /// being measured and mark every apply early. Seen live 2026-09-03.
    public func noteClockOutcome(uid: String, outcome: BTClockStability.Outcome, at date: Date = Date()) {
        let changed = lock.withLock { () -> (@Sendable () -> Void)? in
            let before = clockStateLocked(uid, now: date)
            var movedInserted = false
            switch outcome {
            case .frozen:
                return nil
            case .ignored:
                lastAdvanceAtByUID[uid] = date
            case .rebaselined:
                stableForSecondsByUID[uid] = 0
                lastAdvanceAtByUID[uid] = date
                jumpSumSinceAlignedMsByUID[uid] = 0
            case .advanced:
                if let last = lastAdvanceAtByUID[uid] {
                    stableForSecondsByUID[uid, default: 0] += date.timeIntervalSince(last)
                }
                lastAdvanceAtByUID[uid] = date
            case .jumped(let magnitudeMs):
                stableForSecondsByUID[uid] = 0
                lastAdvanceAtByUID[uid] = date
                seenJumpSinceLinkUIDs.insert(uid)
                if alignedAtByUID[uid] != nil {
                    jumpSumSinceAlignedMsByUID[uid, default: 0] += abs(magnitudeMs)
                    // Not evaluated while the early mark stands: that row is
                    // already asking for a re-check.
                    if !measuredWhileSettlingUIDs.contains(uid),
                       jumpSumSinceAlignedMsByUID[uid, default: 0] >= Self.movedThresholdMs,
                       movedUIDs.insert(uid).inserted {
                        movedInserted = true
                    }
                }
            }
            let after = clockStateLocked(uid, now: date)
            return before != after || movedInserted ? _onChange : nil
        }
        changed?()
    }

    /// Whether the clock detector has seen ``BTClockStability/stableAfterSeconds``
    /// of jump-free advance for this device since the last connect or jump.
    public func isStable(uid: String) -> Bool {
        lock.withLock { isStableLocked(uid) }
    }

    /// The summed |jump| since this device's alignment, when that alignment
    /// was made while settling; `nil` when no such mark stands. Read by the
    /// apply path before it records the re-check, for one telemetry line.
    public func earlyAlignmentJumpSumMs(uid: String) -> Double? {
        lock.withLock {
            measuredWhileSettlingUIDs.contains(uid) ? jumpSumSinceAlignedMsByUID[uid, default: 0] : nil
        }
    }

    private func isStableLocked(_ uid: String) -> Bool {
        stableForSecondsByUID[uid, default: 0] >= BTClockStability.stableAfterSeconds
    }

    private func clockStateLocked(_ uid: String, now: Date) -> ClockState {
        Self.clockState(stableForSeconds: stableForSecondsByUID[uid, default: 0],
                        seenJump: seenJumpSinceLinkUIDs.contains(uid),
                        lastConnectedAt: lastConnectedAtByUID[uid], now: now)
    }

    // MARK: Reading

    /// Everything the snapshot needs for one device, from the UID alone.
    ///
    /// `settleRemainingSeconds` is always `nil`: the Mac publishes `clockState`
    /// and no seconds, for the reason the type's header gives. The field stays
    /// on the wire so an older phone still decodes the snapshot.
    public func report(uid: String, now: Date = Date()) -> BTSpeakerTimingReport {
        let hasStoredOffset = storedOffsetMs(uid) != nil
        let (connected, aligned, clock, early, moved, measured) = lock.withLock {
            () -> (Date?, Date?, ClockState, Bool, Bool, Bool) in
            (lastConnectedAtByUID[uid], alignedAtByUID[uid], clockStateLocked(uid, now: now),
             measuredWhileSettlingUIDs.contains(uid), movedUIDs.contains(uid),
             measuredUIDs.contains(uid))
        }
        let status = Self.status(hasStoredOffset: hasStoredOffset, measuredEarly: early, moved: moved)
        return BTSpeakerTimingReport(
            status: status,
            source: Self.source(hasStoredOffset: hasStoredOffset, lastConnectedAt: connected,
                                alignedAt: aligned, measuredEarly: early, byEar: !measured),
            clockState: clock,
            staleReason: status == .stale
                ? (moved ? Self.staleReasonMoved : Self.staleReasonMeasuredWhileSettling)
                : nil,
            settleRemainingSeconds: nil)
    }

    /// The whole clock verdict, as a pure function of the three inputs — so it
    /// is assertable without a clock, a device, or a store.
    ///
    /// The last line is the floor's only remaining job: no evidence for a whole
    /// minute means the Mac has nothing to add, so the button goes live, which
    /// is exactly what an older Mac gave the phone.
    static func clockState(stableForSeconds: Double, seenJump: Bool,
                           lastConnectedAt: Date?, now: Date) -> ClockState {
        if stableForSeconds >= BTClockStability.stableAfterSeconds { return .steady }
        if seenJump { return .settling }
        return settleRemainingSeconds(lastConnectedAt: lastConnectedAt, now: now) != nil ? .unknown : .steady
    }

    /// The whole row rule, as a pure function of the store's answer and the
    /// two marks — so it is assertable without a clock, a device, or a store.
    /// A reconnect is not in it: the stored offset goes back on the sink, so the row stays tuned and
    /// ``source(hasStoredOffset:lastConnectedAt:alignedAt:measuredEarly:byEar:)``
    /// says where the number came from.
    public static func status(hasStoredOffset: Bool, measuredEarly: Bool, moved: Bool) -> Status {
        guard hasStoredOffset else { return .notSet }
        return measuredEarly || moved ? .stale : .tuned
    }

    /// Where the offset in force came from, as a pure function of the same
    /// facts. Highest precedence first: a link that came up after the
    /// alignment — or an alignment this process never watched being made —
    /// means the number is last time's; then a clock that had not settled,
    /// which is a first pass whatever found the number; then the ear or the
    /// microphone. `nil` exactly when there is no stored offset, which is the
    /// one case ``Status/notSet`` covers.
    public static func source(hasStoredOffset: Bool, lastConnectedAt: Date?, alignedAt: Date?,
                              measuredEarly: Bool, byEar: Bool) -> Source? {
        guard hasStoredOffset else { return nil }
        guard let alignedAt else { return .fromLastTime }
        if let lastConnectedAt, lastConnectedAt > alignedAt { return .fromLastTime }
        if measuredEarly { return .firstPass }
        return byEar ? .byEar : .measured
    }

    /// Keep the stored offset or replace it, from the one number that decides
    /// it: how far the measurement about to be written lands from what is
    /// stored. Under ``AlignmentThresholds/replaceMs`` the stored value stands,
    /// so a re-measurement that agrees never moves the sink — the re-roll
    /// between two links of one speaker is tens of milliseconds, and this line
    /// is what separates that from measurement scatter (ADR 0001). A speaker
    /// with nothing stored has nothing to keep.
    public static func decision(correctedMs: Double, storedMs: Double?) -> MeasurementDecision {
        guard let storedMs else { return .replace }
        return abs(correctedMs - storedMs) >= AlignmentThresholds.replaceMs ? .replace : .keepStored
    }

    /// Whole seconds left in the post-connect floor, or `nil` once it has
    /// passed, and for a device this process never watched connect.
    /// Nothing publishes this number: ``clockState(stableForSeconds:seenJump:lastConnectedAt:now:)``
    /// reads it as the yes/no question "is the floor still running".
    public static func settleRemainingSeconds(lastConnectedAt: Date?, now: Date = Date()) -> Int? {
        guard let lastConnectedAt else { return nil }
        let remaining = settleSeconds - now.timeIntervalSince(lastConnectedAt)
        guard remaining > 0 else { return nil }
        return Int(remaining.rounded(.up))
    }
}

/// The one phone-driven sync-calibration run or by-ear fine-tune session a
/// Mac has in flight. One at a time by decision: both engage the wizard feed,
/// whose single producer means a second staging would replace the first's
/// under it.
struct CompanionAlignmentRun {
    enum Phase {
        /// The sweeps are in the feed.
        case probe
        /// The sweeps are silent and the room is back, but the run's record is
        /// still standing because the phone is still recording its own tail,
        /// transforming it, and has not reported yet. The AUDIO stands down
        /// long before the RUN does, and a
        /// measurement that arrives here still needs this record's stagger and
        /// suspended trim.
        case awaitingReport
        /// A by-ear fine-tune session, whose metronome is running.
        case tick
    }

    /// Distinguishes this run from a later one for the same device, so a timer
    /// armed by this run can never stand down its successor.
    let id = UUID()
    /// The Bluetooth device being measured or tuned (its Core Audio UID).
    let targetUID: String
    var phase: Phase
    /// How far apart the staging put the two sweeps, in ms — subtracted from
    /// the phone's raw reported offset before any trim arithmetic. `0` when
    /// the sweeps played together.
    let staggerMs: Double
    /// The user's trim, put aside for the run's duration and restored when it
    /// ends without a measurement. A probe SUSPENDS the trim (pushes 0 to the
    /// sink) so the sweeps are judged without it, exactly as the Mac's own
    /// wizard does; a fine-tune session leaves it in place, and this is then
    /// the value Revert goes back to.
    let trimAtSessionStartMs: Double
    /// Where the session's nudges have reached. Live on the sink from the
    /// first nudge, written to disk only when the session ends.
    var liveTrimMs: Double
}

/// What the Mac did with a phone's reported measurement, which is more than the
/// phone can work out for itself: the phone knows the raw offset it heard, not
/// the stagger that was baked into the staging nor where clamping and flooring
/// left the stored latency.
public enum CompanionAlignmentApplyResult: Equatable {
    /// `measuredMs` is the phone's raw report with the staging's stagger taken
    /// back out — signed, positive meaning the target sounded late.
    /// `correctedMs` is how far the stored latency actually moved, which is `0`
    /// when the clamp or the floor left it where it was.
    case applied(measuredMs: Double, correctedMs: Double)
    /// Why the Mac declined, in words the phone can show.
    case refused(String)
}

/// One device's timing, as ``CompanionSnapshotBuilder`` maps it onto the wire.
/// The reference half of the wire struct is NOT here: it is a function of the
/// whole live device list, so the builder computes it.
public struct BTSpeakerTimingReport: Equatable, Sendable {
    public let status: BTSpeakerTiming.Status
    /// Set exactly when `status` is anything but
    /// ``BTSpeakerTiming/Status/notSet``.
    public let source: BTSpeakerTiming.Source?
    /// Whether a measurement taken now would measure the speaker or its
    /// settling.
    public let clockState: BTSpeakerTiming.ClockState
    /// Set exactly when `status` is ``BTSpeakerTiming/Status/stale``: either
    /// `staleReason*` string.
    public let staleReason: String?
    /// Always `nil` from ``BTSpeakerTiming/report(uid:now:)`` — see its doc.
    /// The wire field is still there for an older phone to decode.
    public let settleRemainingSeconds: Int?

    public init(status: BTSpeakerTiming.Status,
                source: BTSpeakerTiming.Source? = nil,
                clockState: BTSpeakerTiming.ClockState = .steady,
                staleReason: String? = nil,
                settleRemainingSeconds: Int? = nil) {
        self.status = status
        self.source = source
        self.clockState = clockState
        self.staleReason = staleReason
        self.settleRemainingSeconds = settleRemainingSeconds
    }
}

/// The gate: what must already be true of the ROOM before a
/// phone-driven run may be staged, and the sentence the phone shows when it
/// isn't.
///
/// Preconditions, deliberately — not engagement. Nothing here asks whether the
/// user is interested; it asks whether a measurement could physically happen:
/// the speaker under test has to be making sound, and something else has to be
/// making sound for it to be compared against. Everything else the run needs
/// (a live delay line, nothing already in flight) is the backend's to answer,
/// because only the backend knows it.
///
/// Lives in the library rather than in `AppDelegate` for the reason that
/// target's own AGENTS.md gives: behavior decided in the app target is
/// invisible to the test suite. The four sentences travel with the rule that
/// produces them — the phone shows them verbatim.
public enum CompanionAlignmentPreconditions {

    public enum Outcome: Equatable {
        /// Staging may proceed, against this speaker.
        case ready(referenceID: String)
        /// The reason, as the phone will show it.
        case refused(String)
    }

    /// `isAudible` must be the GROUP-AWARE read (`GroupController
    /// .isMainOutMember(_:)`), never `isSpeakerSelected(_:)` — the latter sees
    /// Selected Devices only and is wrong in both directions under a group
    /// target, which would refuse a speaker the room can plainly hear and hide
    /// every reference in the group from the run.
    public static func evaluate(
        targetID: String,
        among devices: [Device],
        isAudible: (String) -> Bool
    ) -> Outcome {
        guard let target = devices.first(where: { $0.id == targetID }), target.isBluetooth else {
            return .refused("Unknown speaker.")
        }
        guard isAudible(targetID) else {
            return .refused(
                "\u{201C}\(target.name)\u{201D} isn't playing right now, so there's nothing to measure.")
        }
        guard let referenceID = CompanionSnapshotBuilder.alignmentReferenceID(
            forTarget: targetID, among: devices, isAudible: isAudible)
        else {
            return .refused(
                "Nothing else is playing to compare \u{201C}\(target.name)\u{201D} against.")
        }
        return .ready(referenceID: referenceID)
    }
}
