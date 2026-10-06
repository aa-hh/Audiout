// Copyright (C) 2026 ahh and contributors.
//
// LICENSE-CLEAN by design, like its `CastOutputManager` and `PCMDelayLine`
// neighbours: this file carries NO GPL SPDX header. Everything in it is
// original — a settle window and a term that follows each settle over numbers this project
// measured itself. Do not add a GPL header, and do not move GPL-derived code in.

import Foundation

/// CAST-SYNC: how far behind live a room plays once Cast receivers are in the
/// mix (sync architecture brief §4). A Cast receiver decides its own delay —
/// ~5.5 s — and reports it; nothing can shorten it, so every OTHER output has
/// to be held back to meet it. This type decides by how much.
///
/// Pure and clock-free: lead samples in, decisions out. Queues, sockets and
/// wall clocks stay in ``NativeBackend``/``CastOutputManager``, which is what
/// lets the whole policy be replayed offline against recorded telemetry.
///
/// **The rules, all of them**
///  - A receiver nobody has measured yet contributes ``defaultLeadMs``, so the
///    rest of the house takes its one delay hit when the receiver is SELECTED
///    rather than ten seconds later, mid-song.
///  - A lead is believed only once ``settleSampleCount`` consecutive kept
///    samples agree to within ±``settleBandMs``; the settled figure is their
///    trimmed mean, the same estimate tracking takes. A Cast session's first
///    seconds contain two or three re-buffers, and following each one would
///    silence the whole house three times.
///  - What is compared, raised to and remembered is the settled lead adjusted
///    to the fallback hold: `settled + hold − CastFeedRing.macHoldMs`, where
///    `hold` is the median Mac hold of the last settle or tracking window
///    that measured one, or the fallback before the receiver's first settle.
///  - **A receiver's term follows each settle, both ways**: an adjusted lead
///    that lands more than ``raiseThresholdMs`` past its term, above or
///    below, becomes the term. The room's term also falls when a receiver
///    leaves the mix (``setReceivers(_:)``) or a by-ear advance is reduced or
///    cleared.
///  - A settled receiver is tracked: once the trimmed-mean lead plus median
///    hold of its last ``trackingWindowSamples`` kept samples moves more than
///    ``trackingStepMs`` from the settled lead plus hold, the settled lead and
///    hold take those values and the window empties, with no new settle, so
///    moves are at least ``trackingWindowSamples`` samples apart. The term
///    rises, as at a settle, only when the receiver would need more than
///    ``raiseThresholdMs`` of negative share; tracking never lowers a term or
///    refuses. A full window that lands past ``feedGateBandMs`` settles on its
///    samples at once instead, once their raw spread is within twice
///    ``settleBandMs``; until then its oldest sample drops and the receiver
///    stays settled. That re-settle keeps every tracked move within
///    ``feedGateBandMs``.
///  - A settled receiver's feed keeps pace with the room by its rate
///    (``speedMatch(errorMs:forID:)``): ``speedMatchGainPpmPerMs`` per ms of
///    the trimmed mean of its last ``trackingWindowSamples`` play-out errors,
///    within ±``speedMatchMaxPpm``, once it has ``speedMatchMinimumSamples`` of
///    them. A settle, a tracked move or a re-opened settle empties that window,
///    and the feed keeps its last rate until it refills.
///  - A by-ear advance (a negative offset) is added to the receiver's last
///    adjusted lead, never to its term: an advance that fits inside the
///    receiver's own share moves nothing. The sum stops at ``maxTermMs``, and
///    never lowers a term already past it (a measured hold above
///    ``CastFeedRing/macHoldMs`` can put one there).
///  - A receiver settling past ``maxTermMs`` is REFUSED for sync: it keeps
///    playing, unsynced, and contributes no term. Holding the rest of the
///    house that far behind live to reach it is not a trade anyone would take.
///  - A receiver's feed plays once it has settled (refused included) or its
///    play-out lands within ±``feedGateBandMs`` of the room; until then it is
///    silent, so a startup still climbing towards the room is never heard.
///    When a settle moves its share by more than that band, ``NativeBackend``
///    holds the open back by the Mac's hold, the audio still queued under the
///    old share.
struct CastRoomDelay {

    /// What a receiver is assumed to lead by until it has been measured — the
    /// middle of the 5.1–5.9 s the roadmap 006 spike measured for the
    /// no-autoplay recipe, so the usual case never needs a second, audible
    /// correction.
    static let defaultLeadMs = 5_500

    /// `R_max` (brief §6) — the deepest room delay worth imposing on every
    /// other speaker. An autoplay receiver's ~8.4 s fits under it.
    static let maxTermMs = 9_500

    /// A settle needs this many consecutive kept samples...
    static let settleSampleCount = 10

    /// ...agreeing to within ±this, so a settling window spans at most twice
    /// it. Stalls are 0.5–5 s and drift is ~3 ms/min: 100 ms separates the two
    /// without splitting hairs below the receiver's own ~10 ms `currentTime`
    /// granularity.
    static let settleBandMs = 100

    /// How far one sample of a settled receiver's lead has to land from its
    /// settled lead, in either direction, to re-open its settle. Drift is
    /// tracked below it, so this only catches a mid-song stall (seconds), a
    /// re-GET or another jump.
    static let correctionThresholdMs = 150

    /// How far from its term a receiver's adjusted settle has to land, above
    /// or below, to move the term to it; and how far a tracked move has to
    /// carry the receiver past what it contributes to raise the term.
    /// razor: this TV's settles on 2026-10-04 spread 5474 to 5505; 20 keeps a
    /// re-measure from moving the room and caps uncorrected lateness at 20 ms.
    /// Lower it if the loop's median sits above +10.
    static let raiseThresholdMs = 20

    /// How many kept samples a settled receiver's tracking window holds, about
    /// a minute at the 1 Hz poll. Its lead is their trimmed mean
    /// (``trimmedMean(of:)``) and its hold the median of the ones that carry one.
    /// razor: a Google TV Streamer reports its position in ~20 ms steps and
    /// flips between two of them every few seconds, so a 10-sample median
    /// follows the flips (11 audible re-pushes in 4 minutes, live 2026-10-06);
    /// real drift is ~0.64 ms/min, so a minute of lag costs under 1 ms.
    static let trackingWindowSamples = 60

    /// How far a settled receiver's play-out has to move before its share
    /// follows: the trimmed-mean lead plus the median hold over its last
    /// ``trackingWindowSamples`` kept samples, against the settled lead plus
    /// hold its share was computed from.
    /// razor: speed matching holds slow drift, so tracking only catches what
    /// the feed rate cannot: a jump, a drift past ``speedMatchMaxPpm``, or a
    /// receiver running late with nothing above the ring's standing queue to
    /// drain. On the 2026-10-04 session the TV's ~22 ms position steps swing a
    /// minute's trimmed mean by up to 13 ms, which a 10 ms step tracked three
    /// times in two minutes on top of the rate; 20 sits above those swings and
    /// equals ``raiseThresholdMs``.
    static let trackingStepMs = 20

    /// How close an unsettled receiver's play-out has to land to the room for
    /// its feed to play. Also the largest move tracking makes (a tracking
    /// window past it re-settles instead) and the largest grow the Cast
    /// feed's delay line replays behind its crossfade.
    /// razor: inside the 150 ms correction threshold; opening on a settle
    /// covers the rest.
    static let feedGateBandMs = 100

    /// ppm per ms of the trimmed mean of a settled receiver's last
    /// ``trackingWindowSamples`` play-out errors against the room.
    /// razor: proportional only. Replayed on the 2026-10-04 and 2026-10-06
    /// sessions (drift −0.64 and +1.19 ms/min) it holds the error's median at
    /// +0.1 and +1.8 ms; a receiver drifting 60 ppm would sit about 6 ms off.
    /// Add an integral term if a live session's median sits past 5 ms.
    static let speedMatchGainPpmPerMs: Double = 10

    /// The furthest a receiver's feed rate moves from the server's clock,
    /// either way.
    /// razor: five times the 20 ppm recorded, 0.17 cents of pitch.
    static let speedMatchMaxPpm: Double = 100

    /// Errors a settled receiver's speed window needs before it sets a rate;
    /// until then its feed keeps its last rate.
    static let speedMatchMinimumSamples = 20

    /// What one settle decided. `nil` from ``ingest(leadMs:holdMs:forID:)`` means the
    /// sample changed nothing — still settling, already on target, or tracking
    /// inside its step.
    struct Settlement: Equatable {
        let deviceID: String
        /// The measured steady lead (trimmed mean of the settling window), or
        /// the tracking window's trimmed mean for a tracked move.
        let leadMs: Int
        /// Too far behind live to sync: plays on, contributes no term.
        let refused: Bool
        /// Whether ``termMs`` itself moved, i.e. whether every other output in
        /// the room now has to be re-delayed.
        let termMoved: Bool
        /// `true` for a settled receiver's tracked move, which carries no
        /// settle and no gate hold-back.
        let tracked: Bool
    }

    private struct Receiver {
        /// This receiver's own term: the assumed lead, then its last settle's
        /// adjusted lead, raised by tracking.
        var termMs: Int
        var settledLeadMs: Int?
        var window: [(leadMs: Int, holdMs: Int?)] = []
        var tracking: [(leadMs: Int, holdMs: Int?)] = []
        var refused = false
        /// The median Mac hold of the last settle or tracking window that
        /// measured one.
        var holdMs: Int?
        /// The last settle or tracked raise's lead adjusted to the fallback hold.
        var adjustedLeadMs: Int?
        /// Play-out errors against the room since the last settle or tracked
        /// move, the newest ``trackingWindowSamples``.
        var speedWindow: [Int] = []
    }

    private var receivers: [String: Receiver] = [:]

    /// Session memory (brief §4: deliberately not persisted in v1) — each
    /// receiver's last settle or tracked raise the last time it was in the mix,
    /// so re-selecting one starts from its real lead instead of the generic guess.
    private var rememberedLeadMs: [String: Int] = [:]

    /// Each receiver's by-ear advance: how much earlier than the room it is
    /// asked to play, 0 for none.
    private var advanceMs: [String: Int] = [:]

    /// `castTermMs`: how far behind live the furthest Cast receiver in the mix
    /// plays, adjusted to the fallback hold, or `nil` when none contributes a
    /// term. Each receiver contributes its term, or its last adjusted lead plus
    /// its advance when that is later. That `nil` is the
    /// invariant — an absent operand makes the room delay's `max` the
    /// identity, so a Cast-free room reduces to exactly today's numbers.
    private(set) var termMs: Int?

    /// The receivers in the mix right now: selected, and not failed. Returns
    /// whether ``termMs`` moved.
    @discardableResult
    mutating func setReceivers(_ ids: [String]) -> Bool {
        let wanted = Set(ids)
        guard wanted != Set(receivers.keys) else { return false }
        receivers = receivers.filter { wanted.contains($0.key) }
        for id in wanted where receivers[id] == nil {
            receivers[id] = Receiver(termMs: rememberedLeadMs[id] ?? Self.defaultLeadMs)
        }
        return commitTerm()
    }

    /// One lead sample the caller already judged trustworthy (brief §4: the
    /// receiver reported PLAYING and answered inside 100 ms). A sample for a
    /// receiver that is not in the mix is dropped.
    mutating func ingest(leadMs: Int, holdMs: Int? = nil, forID id: String) -> Settlement? {
        guard var receiver = receivers[id] else { return nil }
        if let settled = receiver.settledLeadMs {
            if abs(leadMs - settled) > Self.correctionThresholdMs {
                receiver.settledLeadMs = nil
                receiver.tracking = []
            } else {
                guard !receiver.refused else { return nil }
                receiver.tracking.append((leadMs, holdMs))
                guard receiver.tracking.count >= Self.trackingWindowSamples else {
                    receivers[id] = receiver
                    return nil
                }
                let trackedLead = Self.trimmedMean(of: receiver.tracking.map(\.leadMs))
                let trackedHolds = receiver.tracking.compactMap(\.holdMs)
                let trackedHold = trackedHolds.isEmpty ? receiver.holdMs : Self.median(of: trackedHolds)
                let basis = settled + (receiver.holdMs ?? CastFeedRing.macHoldMs)
                let playOut = trackedLead + (trackedHold ?? CastFeedRing.macHoldMs)
                if abs(playOut - basis) <= Self.trackingStepMs {
                    receiver.tracking.removeFirst()
                    receivers[id] = receiver
                    return nil
                }
                if abs(playOut - basis) > Self.feedGateBandMs {
                    // A window straddling a jump is not one plateau yet:
                    // stay settled until it agrees as a settle window must.
                    let leads = receiver.tracking.map(\.leadMs)
                    if let low = leads.min(), let high = leads.max(), high - low > 2 * Self.settleBandMs {
                        receiver.tracking.removeFirst()
                        receivers[id] = receiver
                        return nil
                    }
                    // Too big a move to track: settle on these samples now.
                    // The current sample is appended below.
                    receiver.settledLeadMs = nil
                    receiver.window = Array(receiver.tracking.dropLast())
                    receiver.tracking = []
                } else {
                    let have = contributionMs(of: receiver, id: id)
                    receiver.tracking = []
                    receiver.speedWindow = []
                    receiver.settledLeadMs = trackedLead
                    receiver.holdMs = trackedHold
                    let adjusted = trackedLead + (trackedHold ?? CastFeedRing.macHoldMs) - CastFeedRing.macHoldMs
                    if adjusted + (advanceMs[id] ?? 0) > have + Self.raiseThresholdMs {
                        receiver.adjustedLeadMs = adjusted
                        rememberedLeadMs[id] = adjusted
                        if adjusted > receiver.termMs + Self.raiseThresholdMs { receiver.termMs = adjusted }
                    }
                    receivers[id] = receiver
                    return Settlement(deviceID: id, leadMs: trackedLead, refused: false,
                                      termMoved: commitTerm(), tracked: true)
                }
            }
        }
        receiver.window.append((leadMs, holdMs))
        // A jump ejects the samples it disagrees with rather than the whole
        // window, so a stall's new plateau starts counting from its first
        // sample instead of one settle later.
        while let low = receiver.window.map(\.leadMs).min(), let high = receiver.window.map(\.leadMs).max(),
              high - low > 2 * Self.settleBandMs {
            receiver.window.removeFirst()
        }
        guard receiver.window.count >= Self.settleSampleCount else {
            receivers[id] = receiver
            return nil
        }
        let settled = Self.trimmedMean(of: receiver.window.map(\.leadMs))
        // A window with no hold keeps the last one measured.
        let holds = receiver.window.compactMap(\.holdMs)
        if !holds.isEmpty { receiver.holdMs = Self.median(of: holds) }
        receiver.window = []
        receiver.speedWindow = []
        receiver.settledLeadMs = settled
        receiver.refused = settled > Self.maxTermMs
        if receiver.refused {
            // Not remembered: a refusal is a reason to re-measure next time,
            // not a verdict to start the next session from.
            rememberedLeadMs[id] = nil
        } else {
            let adjusted = settled + (receiver.holdMs ?? CastFeedRing.macHoldMs) - CastFeedRing.macHoldMs
            receiver.adjustedLeadMs = adjusted
            rememberedLeadMs[id] = adjusted
            if abs(adjusted - receiver.termMs) > Self.raiseThresholdMs { receiver.termMs = adjusted }
        }
        receivers[id] = receiver
        return Settlement(deviceID: id, leadMs: settled,
                          refused: receiver.refused, termMoved: commitTerm(), tracked: false)
    }

    /// This receiver's measured steady lead, or the tracked trimmed mean that
    /// replaced it, or `nil` while it is still settling (or refused). The Cast feed's own delay is
    /// `roomDelay − settledLeadMs − holdMs(forID:)`: everything the receiver adds by itself is
    /// already in this number, and the delay inserted ahead of it is not
    /// (inserting silence changes the age of the content, not the depth of the
    /// receiver's buffer, so the lead metric cannot see it).
    func settledLeadMs(forID id: String) -> Int? {
        guard let receiver = receivers[id], !receiver.refused else { return nil }
        return receiver.settledLeadMs
    }

    /// Whether this receiver's feed should play: `false` for one not in the
    /// mix, else settled (refused included) or `playOutMs` within
    /// ``feedGateBandMs`` of `roomMs`. Reads the settled field directly,
    /// because ``settledLeadMs(forID:)`` hides a refused receiver.
    func feedGateOpen(forID id: String, playOutMs: Int, roomMs: Int) -> Bool {
        guard let receiver = receivers[id] else { return false }
        return receiver.settledLeadMs != nil || abs(playOutMs - roomMs) <= Self.feedGateBandMs
    }

    /// The Mac's measured hold in front of this receiver, or
    /// ``CastFeedRing/macHoldMs`` before its first settle measured one.
    func holdMs(forID id: String) -> Int {
        receivers[id]?.holdMs ?? CastFeedRing.macHoldMs
    }

    /// One kept sample's play-out error in ms, positive when the receiver
    /// plays later than the room plus its by-ear trim. Returns the feed rate it
    /// now asks for and the error estimate behind it, or nil while the
    /// receiver is not in the mix, unsettled or refused or has fewer than
    /// ``speedMatchMinimumSamples`` errors since its last settle or tracked
    /// move.
    mutating func speedMatch(errorMs: Int, forID id: String) -> (ppm: Double, errorMs: Int)? {
        guard var receiver = receivers[id] else { return nil }
        guard receiver.settledLeadMs != nil, !receiver.refused else {
            receiver.speedWindow = []
            receivers[id] = receiver
            return nil
        }
        receiver.speedWindow.append(errorMs)
        if receiver.speedWindow.count > Self.trackingWindowSamples { receiver.speedWindow.removeFirst() }
        receivers[id] = receiver
        guard receiver.speedWindow.count >= Self.speedMatchMinimumSamples else { return nil }
        let estimate = Self.trimmedMean(of: receiver.speedWindow)
        let ppm = min(Self.speedMatchMaxPpm,
                      max(-Self.speedMatchMaxPpm, Self.speedMatchGainPpmPerMs * Double(estimate)))
        return (ppm, estimate)
    }

    /// Store this receiver's by-ear advance, floored at 0. Returns whether
    /// ``termMs`` moved.
    @discardableResult
    mutating func setAdvanceMs(_ ms: Int, forID id: String) -> Bool {
        advanceMs[id] = max(0, ms)
        return commitTerm()
    }

    /// Receivers refused for sync — they play unsynced (brief §6).
    var refusedIDs: Set<String> {
        Set(receivers.filter { $0.value.refused }.keys)
    }

    private mutating func commitTerm() -> Bool {
        let updated = receivers.filter { !$0.value.refused }.map { id, receiver in
            contributionMs(of: receiver, id: id)
        }.max()
        guard updated != termMs else { return false }
        termMs = updated
        return true
    }

    private func contributionMs(of receiver: Receiver, id: String) -> Int {
        let advance = advanceMs[id] ?? 0
        guard advance > 0 else { return receiver.termMs }
        return max(receiver.termMs, min(Self.maxTermMs, (receiver.adjustedLeadMs ?? receiver.termMs) + advance))
    }

    private static func median(of samples: [Int]) -> Int {
        let sorted = samples.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    /// The mean of `samples` with the lowest and highest fifth (`count / 5`
    /// each) dropped, rounded to the nearest millisecond, halves away from zero.
    private static func trimmedMean(of samples: [Int]) -> Int {
        let trim = samples.count / 5
        let kept = samples.sorted().dropFirst(trim).dropLast(trim)
        return Int((Double(kept.reduce(0, +)) / Double(kept.count)).rounded())
    }
}
