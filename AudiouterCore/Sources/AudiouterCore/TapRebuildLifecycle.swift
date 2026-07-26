import Foundation

// MARK: - Shared tap-rebuild lifecycle pieces (architecture review 2026-07-26, defect A)
//
// ``NativeCaptureCoordinator``'s `recreateTap(cause:)` and
// ``PerAppCaptureCoordinator``'s `handleDeviceChange(bundleID:)` run the same
// SHAPE of choreography — claim-under-lock, tear the old tap down OFF the lock,
// commit the new one back under the lock — and the review flagged that shape as
// duplicated. This file holds the parts of it that are genuinely, provably
// IDENTICAL between the two and can therefore have exactly one implementation:
//
//   1. ``TapRebuildCoalescer`` — the STABILITY(C6) pending-rebuild flag.
//   2. ``TapReanchor``         — the `rateMoved`/`deviceMoved` re-anchor compare.
//
// ## What is deliberately NOT extracted, and why
//
// The claim/teardown/commit choreography itself stays written twice. It reads
// as one algorithm in prose but is two algorithms in code, and every step
// differs in a way that a shared implementation would have to parameterize with
// a closure — leaving a "shared" type that is pure control flow with all the
// actual work injected, which is strictly harder to audit than the two direct
// bodies it replaced. Concretely, at every step:
//
// | Step | Whole-system | Per-app |
// |---|---|---|
// | State store | one coordinator-level `_state` | a `[String: Slot]` dictionary of reference-type slots |
// | Claim payload | `(proceed, old, excludedProcessObjectIDs, previousRate, previousDeviceID)` | `(proceed, old, oldFormat)` |
// | Extra claim work | clears `converter`, calls `publishBufferSnapshot()`, resolves the live exclusion set | none |
// | Workgroup | leaves the old aggregate's I/O workgroup before teardown, joins the new one after commit (T7 EDGE 3) | does not participate in the audio workgroup at all |
// | Between teardown and create | nothing | re-resolves the bundle ID's process set, and may bail out to `.failed(.processNotYetAudible)` — a step with no whole-system counterpart |
// | Commit extras | `converter`, `publishBufferSnapshot()`, `lastExcludedObjects` | `lastTappedProcessObjects` |
// | Losing the commit race | returns the orphan and tears it down OFF the lock | tears the orphan down inside the lock |
// | Rebuild cause | a `RebuildCause` enum from two distinct triggers | one trigger, no cause |
// | Post-commit signal | fires `onDeviceRateRebuild` (resets the whole-system RTP session) | no session to reset; emits `rate_rebuild` telemetry only |
// | Telemetry subsystem | `.captureWS` | `.capturePA` |
//
// The workgroup asymmetry is the sharpest of these and is REAL, not an
// oversight: `os_workgroup_join`/`leave` act on the calling thread, and the
// whole-system tap's rebuild has to hand a leave/join pair to the single
// engine thread that carries its audio. The per-app path has no such single
// carrier thread and no workgroup membership to drop, so it must not be made to
// pretend it has one. A shared type with an optional workgroup hook would let
// per-app pass `nil` — but that is the only caller that ever would, which makes
// the hook a one-sided conditional living in shared code rather than shared
// behaviour.
//
// So: the two sites stay duplicated, but are now cross-linked to each other by
// name in both files, and the two pieces below are single-sourced. Widening
// this file to swallow the rest of the choreography is a deliberate future
// option, not an oversight — see the review's fix A.
//
// razor: partial consolidation. Upgrade path — if the per-app path ever grows
// workgroup participation AND an `onDeviceRateRebuild`-equivalent session
// reset, the two bodies converge enough that a shared template method stops
// being a closure sandwich, and the choreography can move here too.

/// The STABILITY(C6) pending-rebuild flag, single-sourced.
///
/// A device/rate-change notification that arrives while a tap rebuild is
/// already in flight (the owner is in `.creatingTap`, having already claimed
/// and torn down the old tap) must be neither dropped nor acted on immediately:
/// acting on it would re-enter the rebuild against a half-built state, and
/// dropping it leaves the tap anchored to a stale device/rate — which is
/// exactly the silent-audio dropout the mechanism exists to prevent. Rapid
/// bounces (44.1 -> 48 -> 44.1) mean the notification that would be dropped is
/// often the LAST and most authoritative one.
///
/// So it is coalesced: however many arrive mid-rebuild collapse into one
/// replay, fired once the in-flight rebuild has committed back to `.capturing`.
///
/// See dev/notes/stability-audit-2026-07-18.md §C6.
///
/// ## Lock contract
///
/// This type carries NO synchronization of its own — deliberately. Both owners
/// already confine the flag to their own state lock, and the flag's correctness
/// depends on being read/written in the SAME critical section as the state
/// transition it is paired with (mark it while observing `.creatingTap`; take
/// it while committing `.capturing`). An internal lock here would be a second,
/// finer-grained lock that could not make that pairing atomic and would only
/// obscure who actually owns the ordering. Every call below must therefore be
/// made while holding the owner's state lock.
struct TapRebuildCoalescer {

    private var pending = false

    /// Whether a rebuild trigger is currently coalesced and awaiting replay.
    /// Read-only — for telemetry and assertions; use ``takePending()`` to
    /// actually consume it.
    var isPending: Bool { pending }

    /// Record that a rebuild trigger arrived while a rebuild was already in
    /// flight. Idempotent: a burst of triggers coalesces into the single replay
    /// ``takePending()`` will report.
    mutating func markPending() { pending = true }

    /// Consume the coalesced trigger, if any: returns whether a replay is owed
    /// and clears the flag in the same critical section, so a trigger can never
    /// be replayed twice. Call at the commit point, under the same lock hold
    /// that publishes the new `.capturing` state — a trigger arriving after
    /// that hold ends sees `.capturing`, not `.creatingTap`, and drives its own
    /// rebuild directly rather than being coalesced.
    mutating func takePending() -> Bool {
        defer { pending = false }
        return pending
    }
}

/// The re-anchor compare, single-sourced: did a completed tap rebuild actually
/// move the clock it is anchored to?
///
/// The rebuild's nominal *cause* cannot be trusted to answer this. The default
/// output device can move inside the window between the old tap's `teardown()`
/// (which takes its device listener with it) and the new tap arming its own —
/// nobody delivers that notification, so a rebuild that was nominally for
/// something else (an exclusion toggle, a plain connect) can silently come back
/// up on a DIFFERENT device's clock while downstream receivers stay on the old
/// timeline, and stay silent until some later event happens to fire a reset.
/// Comparing what the outgoing tap was anchored to against what the incoming
/// one landed on closes that window with a fact instead of an assumption.
///
/// A `nil` baseline (or a tap that does not report its device) ABSTAINS from
/// that half of the compare rather than guessing "moved" — an unknown is not
/// evidence of a move, and a spurious reset costs a real audio glitch.
struct TapReanchor {

    /// The tap's sample rate differs from what the outgoing tap was anchored to.
    let rateMoved: Bool

    /// The tap landed on a different device than the outgoing tap was anchored
    /// to. Always `false` for callers that do not track device identity.
    let deviceMoved: Bool

    /// Whether the rebuild re-anchored on either axis.
    var didReanchor: Bool { rateMoved || deviceMoved }

    /// Compare both axes. `DeviceID` is generic purely so this file needs no
    /// Core Audio import; callers pass `AudioObjectID?`.
    init<DeviceID: Equatable>(
        previousRate: Int?, newRate: Int,
        previousDeviceID: DeviceID?, newDeviceID: DeviceID?
    ) {
        self.rateMoved = previousRate.map { $0 != newRate } ?? false
        self.deviceMoved = {
            guard let before = previousDeviceID, let after = newDeviceID else { return false }
            return before != after
        }()
    }

    /// Compare the rate axis only, for a caller that does not track the tapped
    /// device's identity. ``deviceMoved`` is `false` — abstaining, per the
    /// type's doc: not tracked is not the same as not moved.
    init(previousRate: Int?, newRate: Int) {
        self.rateMoved = previousRate.map { $0 != newRate } ?? false
        self.deviceMoved = false
    }
}
