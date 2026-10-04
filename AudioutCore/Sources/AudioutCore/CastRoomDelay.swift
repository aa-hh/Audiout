// Copyright (C) 2026 ahh and contributors.
//
// LICENSE-CLEAN by design, like its `CastOutputManager` and `PCMDelayLine`
// neighbours: this file carries NO GPL SPDX header. Everything in it is
// original — a settle window and a high-water mark over numbers this project
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
///    median. A Cast session's first seconds contain two or three re-buffers,
///    and following each one would silence the whole house three times.
///  - What is compared, raised to and remembered is the settled lead adjusted
///    to the fallback hold: `settled + hold − CastFeedRing.macHoldMs`, where
///    `hold` is the median Mac hold measured in the settle window, or the
///    fallback before the receiver's first settle.
///  - **The term never falls while a receiver stays in the mix.** A receiver
///    whose adjusted lead lands more than ``raiseThresholdMs`` past its term
///    raises the term to that lead. One that plays earlier is absorbed by
///    delaying its own feed instead — chasing a lead downwards makes every
///    other output jump forward for a number the next stall would undo.
///  - A by-ear advance (a negative offset) is added to the receiver's last
///    adjusted lead, never to its term: an advance that fits inside the
///    receiver's own share moves nothing.
///  - A receiver settling past ``maxTermMs`` is REFUSED for sync: it keeps
///    playing, unsynced, and contributes no term. Holding the rest of the
///    house that far behind live to reach it is not a trade anyone would take.
///  - A receiver's feed plays once it has settled (refused included) or its
///    play-out lands within ±``feedGateBandMs`` of the room; until then it is
///    silent, so a startup still climbing towards the room is never heard.
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

    /// How far a settled receiver's lead has to move, in either direction,
    /// before its settle re-opens. It covers a mid-song stall (seconds) and
    /// slow clock drift (~3 ms/min, so roughly once an hour) with one rule, and
    /// below it the error is inaudible while a re-settle would not be.
    static let correctionThresholdMs = 150

    /// How far past its term a receiver's adjusted settle has to land to raise
    /// the term.
    /// razor: this TV's settles on 2026-10-04 spread 5474 to 5505; 20 keeps a
    /// re-measure from moving the room and caps uncorrected lateness at 20 ms.
    /// Lower it if the loop's median sits above +10.
    static let raiseThresholdMs = 20

    /// How close an unsettled receiver's play-out has to land to the room for
    /// its feed to play.
    /// razor: inside the 150 ms correction threshold; opening on a settle
    /// covers the rest.
    static let feedGateBandMs = 100

    /// What one settle decided. `nil` from ``ingest(leadMs:holdMs:forID:)`` means the
    /// sample changed nothing — still settling, or already on target.
    struct Settlement: Equatable {
        let deviceID: String
        /// The measured steady lead (median of the settling window).
        let leadMs: Int
        /// Too far behind live to sync: plays on, contributes no term.
        let refused: Bool
        /// Whether ``termMs`` itself moved, i.e. whether every other output in
        /// the room now has to be re-delayed.
        let termMoved: Bool
    }

    private struct Receiver {
        /// This receiver's own high-water term: the assumed lead until it has
        /// settled, then the largest adjusted lead it has shown.
        var termMs: Int
        var settledLeadMs: Int?
        var window: [(leadMs: Int, holdMs: Int?)] = []
        var refused = false
        /// The median Mac hold of the last settle window that measured one.
        var holdMs: Int?
        /// The last settle's lead adjusted to the fallback hold.
        var adjustedLeadMs: Int?
    }

    private var receivers: [String: Receiver] = [:]

    /// Session memory (brief §4: deliberately not persisted in v1) — what each
    /// receiver settled at last time it was in the mix, so re-selecting one
    /// starts from its real lead instead of the generic guess.
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
            guard abs(leadMs - settled) > Self.correctionThresholdMs else { return nil }
            receiver.settledLeadMs = nil
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
        let settled = Self.median(of: receiver.window.map(\.leadMs))
        // A window with no hold keeps the last one measured.
        let holds = receiver.window.compactMap(\.holdMs)
        if !holds.isEmpty { receiver.holdMs = Self.median(of: holds) }
        receiver.window = []
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
            if adjusted > receiver.termMs + Self.raiseThresholdMs { receiver.termMs = adjusted }
        }
        receivers[id] = receiver
        return Settlement(deviceID: id, leadMs: settled,
                          refused: receiver.refused, termMoved: commitTerm())
    }

    /// This receiver's measured steady lead, or `nil` while it is still
    /// settling (or refused). The Cast feed's own delay is
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
        let updated = receivers.filter { !$0.value.refused }.map { id, receiver -> Int in
            let advance = advanceMs[id] ?? 0
            guard advance > 0 else { return receiver.termMs }
            return max(receiver.termMs, (receiver.adjustedLeadMs ?? receiver.termMs) + advance)
        }.max()
        guard updated != termMs else { return false }
        termMs = updated
        return true
    }

    private static func median(of samples: [Int]) -> Int {
        let sorted = samples.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }
}
