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

    /// The only ``Status/stale`` reason v1 can produce
    /// (`DeviceState.AlignmentState.staleReason` on the wire).
    public static let staleReasonReconnected = "reconnected"

    /// How long after a baseband reconnect a Bluetooth speaker's clock is
    /// still settling. Measuring inside this window measures the settling, not
    /// the speaker, so the phone counts it down before offering the run.
    public static let settleSeconds: TimeInterval = 60

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

    public init() {}

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
        let changed = lock.withLock { () -> (@Sendable () -> Void)? in
            guard linkUpUIDs.insert(uid).inserted else { return nil }
            lastConnectedAtByUID[uid] = date
            return _onChange
        }
        changed?()
    }

    /// The link for this device went away, so the next ``noteConnected(uid:)``
    /// is a new link-up rather than a second report of the one before it.
    /// Nothing the phone can see moves, so this fires no change.
    public func noteDisconnected(uid: String) {
        lock.withLock { _ = linkUpUIDs.remove(uid) }
    }

    /// An alignment landed for this device — a reported measurement applied,
    /// or a by-ear fine-tune committed.
    public func noteAligned(uid: String, at date: Date = Date()) {
        let changed = lock.withLock { () -> (@Sendable () -> Void)? in
            alignedAtByUID[uid] = date
            return _onChange
        }
        changed?()
    }

    /// This device's tuning was cleared, so there is no alignment instant left
    /// for a later connect to be measured against.
    public func clearAligned(uid: String) {
        let changed = lock.withLock { () -> (@Sendable () -> Void)? in
            alignedAtByUID.removeValue(forKey: uid)
            return _onChange
        }
        changed?()
    }

    // MARK: Reading

    /// Everything the snapshot needs for one device.
    public func report(uid: String, hasStoreEntry: Bool, now: Date = Date()) -> BTAlignmentReport {
        let (connected, aligned) = lock.withLock {
            (lastConnectedAtByUID[uid], alignedAtByUID[uid])
        }
        return BTAlignmentReport(
            status: Self.status(hasStoreEntry: hasStoreEntry,
                                lastConnectedAt: connected,
                                alignedAt: aligned),
            settleRemainingSeconds: Self.settleRemainingSeconds(lastConnectedAt: connected, now: now))
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

    /// Whole seconds left in the post-connect settling window, or `nil` once
    /// it has passed (and for a device that has not connected in this
    /// session). Rounded UP so a phone counting it down never reaches zero
    /// while the Mac still considers the window open.
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
    public let settleRemainingSeconds: Int?

    public init(status: BTAlignmentFreshness.Status, settleRemainingSeconds: Int?) {
        self.status = status
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
