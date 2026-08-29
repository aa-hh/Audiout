import Foundation
import Testing
@testable import AudioutCore

/// CAST-SYNC room-delay policy (sync architecture brief §4). Pure — no queues,
/// no clocks, no sockets — so every rule that decides how far behind live a
/// room plays is pinned here rather than inferred from a live receiver.
@Suite struct CastRoomDelayTests {

    /// The steady lead a receiver settles at in these tests, well inside
    /// `R_max` and far enough from the default to be distinguishable from it.
    private static let steadyLeadMs = 6_000

    /// Feed one lead `count` times, returning the last settlement (if any).
    @discardableResult
    private func feed(_ policy: inout CastRoomDelay, _ leadMs: Int,
                      count: Int = CastRoomDelay.settleSampleCount,
                      id: String = "tv") -> CastRoomDelay.Settlement? {
        var last: CastRoomDelay.Settlement?
        for _ in 0..<count {
            if let settlement = policy.ingest(leadMs: leadMs, forID: id) { last = settlement }
        }
        return last
    }

    // MARK: - Selection

    /// Nothing selected contributes no term at all — the absent operand that
    /// makes every room delay reduce to the number it is today.
    @Test func noReceiverContributesNoTerm() {
        var policy = CastRoomDelay()
        #expect(policy.termMs == nil)
        #expect(policy.setReceivers([]) == false, "a no-op selection moves nothing")
        #expect(policy.termMs == nil)
    }

    /// A receiver contributes the assumed lead from the moment it is selected,
    /// before it has played a note — that is what lets everything else take
    /// its one delay hit up front instead of mid-song.
    @Test func selectingAReceiverAssumesTheDefaultLeadImmediately() {
        var policy = CastRoomDelay()
        #expect(policy.setReceivers(["tv"]) == true)
        #expect(policy.termMs == CastRoomDelay.defaultLeadMs)
        #expect(policy.settledLeadMs(forID: "tv") == nil, "assumed is not measured")

        #expect(policy.setReceivers([]) == true)
        #expect(policy.termMs == nil, "the last receiver leaving hands the room back")
    }

    /// The term is the FURTHEST-behind receiver: a second, faster one is
    /// zero-padded up to the room rather than dragging it forward.
    @Test func theTermIsTheFurthestBehindReceiver() {
        var policy = CastRoomDelay()
        policy.setReceivers(["slow", "fast"])
        feed(&policy, 7_000, id: "slow")
        feed(&policy, 2_000, id: "fast")
        #expect(policy.termMs == 7_000)
        #expect(policy.settledLeadMs(forID: "fast") == 2_000)
    }

    // MARK: - The settle gate

    /// One sample short of the gate decides nothing. A Cast session's first
    /// seconds contain two or three re-buffers; acting on each would silence
    /// the whole house three times.
    @Test func settlingTakesTheWholeWindow() {
        var policy = CastRoomDelay()
        policy.setReceivers(["tv"])
        #expect(feed(&policy, Self.steadyLeadMs, count: CastRoomDelay.settleSampleCount - 1) == nil)
        #expect(policy.settledLeadMs(forID: "tv") == nil)

        let settlement = policy.ingest(leadMs: Self.steadyLeadMs, forID: "tv")
        #expect(settlement?.leadMs == Self.steadyLeadMs)
        #expect(policy.settledLeadMs(forID: "tv") == Self.steadyLeadMs)
    }

    /// A jump ejects only the samples it disagrees with, so the new plateau
    /// starts counting from its own first sample — a receiver that stalls once
    /// and then holds steady settles ten seconds later, not twenty.
    @Test func aJumpRestartsTheWindowAtTheJump() {
        var policy = CastRoomDelay()
        policy.setReceivers(["tv"])
        feed(&policy, 4_000, count: 5)
        // The jump: the samples before it are dropped, this one survives.
        #expect(policy.ingest(leadMs: Self.steadyLeadMs, forID: "tv") == nil)
        #expect(feed(&policy, Self.steadyLeadMs, count: CastRoomDelay.settleSampleCount - 2) == nil,
                "eight more is still one short of a window")
        let settlement = policy.ingest(leadMs: Self.steadyLeadMs, forID: "tv")
        #expect(settlement?.leadMs == Self.steadyLeadMs, "the tenth sample AFTER the jump settles")
    }

    /// Sample-to-sample wobble inside the band is what a settle is made of,
    /// not what stops one: the settled figure is their median.
    @Test func aSettleTakesTheMedianOfTheWindow() {
        var policy = CastRoomDelay()
        policy.setReceivers(["tv"])
        var settlement: CastRoomDelay.Settlement?
        for lead in [5_450, 5_500, 5_550, 5_500, 5_500, 5_500, 5_500, 5_500, 5_450, 5_550] {
            if let landed = policy.ingest(leadMs: lead, forID: "tv") { settlement = landed }
        }
        #expect(settlement?.leadMs == 5_500)
    }

    // MARK: - High-water mark

    /// A receiver that turns out to play LATER than assumed raises the room —
    /// once, by the excess. Everything else takes a second, smaller gap.
    @Test func aLateReceiverRaisesTheTermOnce() {
        var policy = CastRoomDelay()
        policy.setReceivers(["tv"])
        let raise = feed(&policy, 7_000)
        #expect(raise?.termMoved == true)
        #expect(policy.termMs == 7_000)

        // Same lead again: already settled and already the term, so nothing
        // moves — a settled receiver is left alone.
        #expect(feed(&policy, 7_000) == nil)
        #expect(policy.termMs == 7_000)
    }

    /// **The hysteresis.** A receiver that comes BACK towards live keeps the
    /// room where it is: it is delayed on its own feed instead. Chasing a lead
    /// downwards makes every other output jump forward for a number the next
    /// stall would undo.
    @Test func theTermNeverFallsWhileAReceiverStays() {
        var policy = CastRoomDelay()
        policy.setReceivers(["tv"])
        feed(&policy, 7_000)
        #expect(policy.termMs == 7_000)

        let recovered = feed(&policy, 6_000)
        #expect(recovered?.leadMs == 6_000, "the receiver's own measurement follows it down")
        #expect(recovered?.termMoved == false)
        #expect(policy.termMs == 7_000, "but the room stays where it is")
    }

    /// Inside the correction band nothing happens at all: the error is below
    /// what a correction could fix without being heard.
    @Test func aSmallDriftIsLeftAlone() {
        var policy = CastRoomDelay()
        policy.setReceivers(["tv"])
        feed(&policy, Self.steadyLeadMs)
        let nudge = CastRoomDelay.correctionThresholdMs - 10
        #expect(feed(&policy, Self.steadyLeadMs + nudge, count: 30) == nil)
        #expect(policy.settledLeadMs(forID: "tv") == Self.steadyLeadMs)
    }

    // MARK: - R_max

    /// Past `R_max` the trade stops being worth it: the receiver plays on,
    /// unsynced, and the rest of the house is handed back its own timeline.
    @Test func aReceiverPastTheCapIsRefusedAndContributesNothing() {
        var policy = CastRoomDelay()
        policy.setReceivers(["tv"])
        let settlement = feed(&policy, CastRoomDelay.maxTermMs + 500)
        #expect(settlement?.refused == true)
        #expect(settlement?.termMoved == true)
        #expect(policy.termMs == nil, "a refused receiver holds nothing back")
        #expect(policy.refusedIDs == ["tv"])
        #expect(policy.settledLeadMs(forID: "tv") == nil)

        // And it un-refuses itself if it comes back inside the cap, at the
        // lead it now measures.
        feed(&policy, Self.steadyLeadMs)
        #expect(policy.refusedIDs.isEmpty)
        #expect(policy.termMs == Self.steadyLeadMs)
    }

    // MARK: - Session memory

    /// Re-selecting a receiver starts from what it settled at last time, so
    /// the house takes ONE gap on the second select instead of two.
    @Test func aReselectedReceiverStartsFromItsRememberedLead() {
        var policy = CastRoomDelay()
        policy.setReceivers(["tv"])
        feed(&policy, Self.steadyLeadMs)
        policy.setReceivers([])

        policy.setReceivers(["tv"])
        #expect(policy.termMs == Self.steadyLeadMs, "not the generic default")
    }

    /// A refusal is a reason to re-measure, not a verdict to start from — a
    /// remembered 10 s lead would refuse the receiver before it played a note.
    @Test func aRefusalIsNotRemembered() {
        var policy = CastRoomDelay()
        policy.setReceivers(["tv"])
        feed(&policy, CastRoomDelay.maxTermMs + 500)
        policy.setReceivers([])

        policy.setReceivers(["tv"])
        #expect(policy.termMs == CastRoomDelay.defaultLeadMs)
        #expect(policy.refusedIDs.isEmpty)
    }

    // MARK: - Startup and stalls

    /// **A receiver announces PLAYING long before its buffer is full**, so the
    /// first seconds of every session report a lead that is still CLIMBING.
    /// Latching onto one of those numbers would set the room too low — and
    /// since the term is a high-water mark, too low is a hole with no way out
    /// except the receiver getting even further behind. The gate must wait for
    /// the climb to stop.
    @Test func theSettleGateDoesNotLatchDuringTheStartupClimb() {
        var policy = CastRoomDelay()
        policy.setReceivers(["tv"])

        // The measured Google TV Streamer profile: the buffer fills to ~4.6 s
        // while the clock is already running, then one re-buffer lands it on
        // its 5.5 s plateau.
        for climbing in stride(from: 1_000, through: 4_600, by: 400) {
            #expect(policy.ingest(leadMs: climbing, forID: "tv") == nil,
                    "settled at \(climbing) ms, mid-climb")
        }
        #expect(policy.settledLeadMs(forID: "tv") == nil)

        // The plateau it actually reaches is what it settles on.
        feed(&policy, 5_500)
        #expect(policy.settledLeadMs(forID: "tv") == 5_500)
        #expect(policy.termMs == CastRoomDelay.defaultLeadMs, "which the default already covers")
    }

    /// A mid-song stall costs the receiver its delay PERMANENTLY — every lead
    /// after it is that much higher. The room follows it up once and stays
    /// there: the gap the others take is the one the receiver already took.
    @Test func aMidSongStallRaisesTheRoomOnceAndItStaysUp() {
        var policy = CastRoomDelay()
        policy.setReceivers(["tv"])
        feed(&policy, 5_500)
        #expect(policy.termMs == CastRoomDelay.defaultLeadMs)

        let afterStall = 7_500
        let raise = feed(&policy, afterStall)
        #expect(raise?.termMoved == true)
        #expect(policy.termMs == afterStall)

        // The rest of the song at the new lead moves nothing further.
        for _ in 0..<5 { #expect(feed(&policy, afterStall) == nil) }
        #expect(policy.termMs == afterStall)
    }

    // MARK: - Recorded receiver

    /// **The real thing.** Every `PLAYING` lead a Google TV Streamer reported
    /// in `dev/notes/006-cast-live-telemetry-2026-08-22.jsonl`, in order and in
    /// milliseconds: a first sample before a re-buffer, the ~5.47 s plateau it
    /// held for twenty seconds, and the two dips that follow. This is the
    /// series the whole policy exists to survive.
    private static let recordedLeadsMs = [
        4_820, 4_570, 4_560, 5_470, 5_460, 5_480, 5_470, 5_470, 5_470, 5_470,
        5_570, 5_470, 5_470, 5_480, 5_550, 5_480, 5_470, 5_470, 5_470, 5_480,
        4_610, 4_880, 4_580, 5_620, 5_630, 5_530,
    ]

    /// Replayed end to end, the room moves exactly ONCE — when the receiver is
    /// selected — and never afterwards: the default covers what this receiver
    /// actually does, its plateau settles inside the band, and the dips it
    /// takes later never drag the rest of the house forward.
    @Test func theRecordedSessionMovesTheRoomExactlyOnce() {
        var policy = CastRoomDelay()
        var terms: [Int?] = []

        #expect(policy.setReceivers(["e7af49b4"]) == true)
        terms.append(policy.termMs)
        for lead in Self.recordedLeadsMs {
            if let settlement = policy.ingest(leadMs: lead, forID: "e7af49b4"), settlement.termMoved {
                terms.append(policy.termMs)
            }
        }

        #expect(terms == [CastRoomDelay.defaultLeadMs],
                "one move, at select; got \(terms)")
        #expect(policy.settledLeadMs(forID: "e7af49b4") == nil,
                "the session ends mid-re-settle, three samples into a new plateau")
        #expect(policy.termMs == CastRoomDelay.defaultLeadMs, "and the room never fell")
    }

    /// The same series, stopped where the receiver was steady: it settles on
    /// the plateau it actually held, which is what the Cast feed's own delay
    /// (`roomDelay − settledLead`) is measured from.
    @Test func theRecordedPlateauSettlesAtItsMeasuredLead() {
        var policy = CastRoomDelay()
        policy.setReceivers(["e7af49b4"])
        for lead in Self.recordedLeadsMs.prefix(20) {
            _ = policy.ingest(leadMs: lead, forID: "e7af49b4")
        }
        #expect(policy.settledLeadMs(forID: "e7af49b4") == 5_470)
        #expect(policy.termMs == CastRoomDelay.defaultLeadMs,
                "5.47 s sits inside the assumed 5.5 s, so the room is not raised")
    }
}
