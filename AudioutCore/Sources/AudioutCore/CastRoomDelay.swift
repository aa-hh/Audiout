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
///  - **The term never falls while a receiver stays in the mix.** A receiver
///    that turns out to play LATER than assumed raises it once, by the excess.
///    One that plays earlier is absorbed by delaying its own feed instead —
///    chasing a lead downwards makes every other output jump forward for a
///    number the next stall would undo.
///  - A receiver settling past ``maxTermMs`` is REFUSED for sync: it keeps
///    playing, unsynced, and contributes no term. Holding the rest of the
///    house that far behind live to reach it is not a trade anyone would take.
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

    /// How far a settled receiver has to move before it is worth acting on —
    /// the same number in both directions it can move. Later than the term
    /// raises the term; different from the settled lead re-opens the settle.
    /// It covers a mid-song stall (seconds) and slow clock drift (~3 ms/min,
    /// so roughly once an hour) with one rule, and below it the error is
    /// inaudible while the correction would not be.
    static let correctionThresholdMs = 150

    /// What one settle decided. `nil` from ``ingest(leadMs:forID:)`` means the
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
        /// settled, then the largest steady lead it has shown.
        var termMs: Int
        var settledLeadMs: Int?
        var window: [Int] = []
        var refused = false
    }

    private var receivers: [String: Receiver] = [:]

    /// Session memory (brief §4: deliberately not persisted in v1) — what each
    /// receiver settled at last time it was in the mix, so re-selecting one
    /// starts from its real lead instead of the generic guess.
    private var rememberedLeadMs: [String: Int] = [:]

    /// `castTermMs`: how far behind live the furthest Cast receiver in the mix
    /// plays, or `nil` when none contributes a term. That `nil` is the
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
    mutating func ingest(leadMs: Int, forID id: String) -> Settlement? {
        guard var receiver = receivers[id] else { return nil }
        if let settled = receiver.settledLeadMs {
            guard abs(leadMs - settled) > Self.correctionThresholdMs else { return nil }
            receiver.settledLeadMs = nil
        }
        receiver.window.append(leadMs)
        // A jump ejects the samples it disagrees with rather than the whole
        // window, so a stall's new plateau starts counting from its first
        // sample instead of one settle later.
        while let low = receiver.window.min(), let high = receiver.window.max(),
              high - low > 2 * Self.settleBandMs {
            receiver.window.removeFirst()
        }
        guard receiver.window.count >= Self.settleSampleCount else {
            receivers[id] = receiver
            return nil
        }
        let settled = Self.median(of: receiver.window)
        receiver.window = []
        receiver.settledLeadMs = settled
        receiver.refused = settled > Self.maxTermMs
        if receiver.refused {
            // Not remembered: a refusal is a reason to re-measure next time,
            // not a verdict to start the next session from.
            rememberedLeadMs[id] = nil
        } else {
            rememberedLeadMs[id] = settled
            if settled > receiver.termMs + Self.correctionThresholdMs { receiver.termMs = settled }
        }
        receivers[id] = receiver
        return Settlement(deviceID: id, leadMs: settled,
                          refused: receiver.refused, termMoved: commitTerm())
    }

    /// This receiver's measured steady lead, or `nil` while it is still
    /// settling (or refused). The Cast feed's own delay is
    /// `roomDelay − settledLeadMs`: everything the receiver adds by itself is
    /// already in this number, and the delay inserted ahead of it is not
    /// (inserting silence changes the age of the content, not the depth of the
    /// receiver's buffer, so the lead metric cannot see it).
    func settledLeadMs(forID id: String) -> Int? {
        guard let receiver = receivers[id], !receiver.refused else { return nil }
        return receiver.settledLeadMs
    }

    /// Receivers refused for sync — they play unsynced (brief §6).
    var refusedIDs: Set<String> {
        Set(receivers.filter { $0.value.refused }.keys)
    }

    private mutating func commitTerm() -> Bool {
        let updated = receivers.values.filter { !$0.refused }.map(\.termMs).max()
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
