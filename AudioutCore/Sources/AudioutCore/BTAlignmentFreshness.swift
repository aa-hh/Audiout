// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// How fresh a Bluetooth speaker's stored alignment is, as the phone's sync
/// sheet renders it. Answered per device UID from two in-memory timestamps
/// plus the one durable fact (`BTTrimStore` has an entry for this UID or it
/// does not).
///
/// v1 knows exactly one way an alignment goes stale: the speaker
/// **reconnected** since it was aligned. A Bluetooth link that drops and comes
/// back renegotiates its own buffering, so the measured latency underneath a
/// tuning made before that link is no longer the latency in force.
///
/// Deliberately IN-MEMORY, not persisted: a launch starts every device at
/// "nothing has reconnected since an alignment I know about", which is the
/// honest answer — this process watched no earlier session's link edges, so it
/// cannot claim a tuning went stale during one. That is also why ``status``
/// answers `.tuned` for a store entry with no ``noteAligned(uid:at:)`` behind
/// it: with no alignment instant recorded there is nothing for a connect to be
/// "after", and reporting stale there would put every tuned speaker into the
/// stale banner on every launch.
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
public final class BTAlignmentFreshness: @unchecked Sendable {

    /// What the phone's row shows. Wire values are the raw strings
    /// (`AudioutProtocol.DeviceState.AlignmentState.status`).
    public enum Status: String, Sendable {
        /// No stored alignment at all — "Timing not set".
        case notSet
        /// Stored, and nothing has happened to invalidate it.
        case tuned
        /// Stored, but the speaker reconnected after it was made.
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

    /// The ``Status/stale`` reasons (`DeviceState.AlignmentState.staleReason`
    /// on the wire). A reconnect supersedes the other two.
    public static let staleReasonReconnected = "reconnected"
    /// The alignment was applied while the speaker's clock was still settling.
    public static let staleReasonMeasuredWhileSettling = "measuredWhileSettling"
    /// The speaker's clock has stepped 10 ms or more, summed, since the
    /// alignment was applied.
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
    private let floorRebroadcastDelay: TimeInterval

    /// - Parameter floorRebroadcastDelay: how long after a link-up to re-check
    ///   whether ``settleSeconds`` expired with no evidence either way. Only
    ///   the tests pass anything but the floor itself.
    public init(floorRebroadcastDelay: TimeInterval = BTAlignmentFreshness.settleSeconds) {
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

    /// An alignment landed for this device — a reported measurement applied,
    /// a by-ear fine-tune committed, or the Mac wizard's Keep.
    ///
    /// Decides here, not at the call sites, whether it was made too early: an
    /// alignment made against a clock the Mac does not call steady is marked
    /// "measured while settling", one made against a steady clock clears that
    /// mark. It is the same verdict the phone gates its button on, so the two
    /// surfaces can never disagree about what "too early" meant — including
    /// past the floor, where a clock the detector has watched jump is still
    /// settling. A clock with no evidence either way reads steady rather than
    /// settling, which is what keeps a device whose clock query never answers
    /// from marking every alignment early forever. Either way the jump sum
    /// restarts and a standing "moved" mark clears: this alignment is the new
    /// instant to move from.
    public func noteAligned(uid: String, at date: Date = Date()) {
        let changed = lock.withLock { () -> (@Sendable () -> Void)? in
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
        changed?()
    }

    /// This device's tuning was cleared, so there is no alignment instant left
    /// for a later connect to be measured against, and nothing for either
    /// mark to be about.
    public func clearAligned(uid: String) {
        let changed = lock.withLock { () -> (@Sendable () -> Void)? in
            alignedAtByUID.removeValue(forKey: uid)
            measuredWhileSettlingUIDs.remove(uid)
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

    /// Everything the snapshot needs for one device.
    ///
    /// `settleRemainingSeconds` is always `nil`: the Mac publishes `clockState`
    /// and no seconds, for the reason the type's header gives. The field stays
    /// on the wire so an older phone still decodes the snapshot.
    public func report(uid: String, hasStoreEntry: Bool, now: Date = Date()) -> BTAlignmentReport {
        let (connected, aligned, clock, stale) = lock.withLock {
            (lastConnectedAtByUID[uid], alignedAtByUID[uid],
             clockStateLocked(uid, now: now),
             movedUIDs.contains(uid)
                ? Self.staleReasonMoved
                : measuredWhileSettlingUIDs.contains(uid) ? Self.staleReasonMeasuredWhileSettling : nil)
        }
        var status = Self.status(hasStoreEntry: hasStoreEntry, lastConnectedAt: connected, alignedAt: aligned)
        var staleReason: String?
        if status == .stale {
            staleReason = Self.staleReasonReconnected
        } else if status == .tuned, let stale {
            status = .stale
            staleReason = stale
        }
        return BTAlignmentReport(status: status, settleRemainingSeconds: nil,
                                 clockState: clock, staleReason: staleReason)
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

    /// The whole staleness rule, as a pure function of the three inputs — so
    /// it is assertable without a clock, a device, or a store.
    public static func status(hasStoreEntry: Bool,
                              lastConnectedAt: Date?,
                              alignedAt: Date?) -> Status {
        guard hasStoreEntry else { return .notSet }
        // No alignment instant recorded (a store entry made in an earlier
        // launch): nothing for a connect to be after. See the type's doc.
        guard let alignedAt, let lastConnectedAt else { return .tuned }
        return lastConnectedAt > alignedAt ? .stale : .tuned
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

/// One device's alignment freshness, as ``CompanionSnapshotBuilder`` maps it
/// onto the wire. The reference half of the wire struct is NOT here: it is a
/// function of the whole live device list, so the builder computes it.
public struct BTAlignmentReport: Equatable, Sendable {
    public let status: BTAlignmentFreshness.Status
    /// Always `nil` from ``BTAlignmentFreshness/report(uid:hasStoreEntry:now:)``
    /// — see its doc. The wire field is still there for an older phone to
    /// decode.
    public let settleRemainingSeconds: Int?
    /// Whether a measurement taken now would measure the speaker or its
    /// settling.
    public let clockState: BTAlignmentFreshness.ClockState
    /// Set exactly when `status` is ``BTAlignmentFreshness/Status/stale``:
    /// one of the three `staleReason*` strings.
    public let staleReason: String?

    public init(status: BTAlignmentFreshness.Status, settleRemainingSeconds: Int?,
                clockState: BTAlignmentFreshness.ClockState = .steady,
                staleReason: String? = nil) {
        self.status = status
        self.settleRemainingSeconds = settleRemainingSeconds
        self.clockState = clockState
        self.staleReason = staleReason
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
            return .refused("Unknown device.")
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
