// Copyright (C) 2026 ahh and contributors.
//
// LICENSE-CLEAN by design (PLAN-UNIVERSAL-SYNC Decision 5 posture, same as
// `BTSyncedSink.swift`): this file carries NO GPL SPDX header. It is a pure
// Foundation-only state machine written fresh for this project. Do not add a
// GPL header, and do not copy code into it from GPL-headered siblings.

import Foundation

/// The alignment wizard's estimator: a COARSE SEARCH followed by the METHOD OF
/// CONSTANT STIMULI (`dev/notes/per-device-trim-spec.md` §Part 2), replacing the
/// forced-choice bisection it superseded.
///
/// Why constant stimuli: a bisection is unforgiving. One mistaken judgment
/// freezes the bracket and converges early, "can't tell" is a dead end rather
/// than data, and there is no undo. Here every trial adds a KNOWN deliberate
/// offset δ on top of the working estimate, drawn from a fixed set and presented
/// in randomised order; the app subtracts δ back out. Each judgment therefore
/// stays an easy "which side leads?" question, a single wrong answer nudges the
/// fit instead of derailing it, "can't tell" near the crossover is expected,
/// averageable data, and ``back()`` just re-queues the trial.
///
/// **Why the search phase came first** (live run, 2026-08-22 — "every trial
/// sounds like the exact same pulse", then a bow-out that claimed the speakers
/// were already aligned): a never-aligned Bluetooth speaker starts 150–250 ms
/// out, and the stimulus fan is only E ± 24 ms wide. Every trial in a block was
/// therefore ~200 ms from truth and genuinely indistinguishable, and re-centring
/// 48 ms at a time out of the SAME block budget could reach 144 ms at most —
/// 36 questions to arrive nowhere. ``Stage/search`` is a step-halving staircase
/// (96 → 48 → 24 ms) that walks the estimate to within the fan's half-width in a
/// handful of answers; only then does the fan go up around it.
///
/// One BLOCK is one shuffled pass over all nine stimuli. At the end of a block
/// each presented level gets its majority verdict (a tie reads as can't-tell)
/// and the crossover is the midpoint between the highest target-first level and
/// the lowest reference-first level, pulled toward the centroid of any
/// can't-tell levels lying between them.
///
/// Sign convention, identical to the bisection's: `.target` means the user heard
/// the wizard's TARGET device first — it plays EARLY, so it needs MORE delay and
/// the true offset lies ABOVE the presented level. `.reference` is the mirror.
///
/// Stimulus spacing honours the probe-validated perceptual constraints: coarse
/// wings (lateralisation reads clearly at 7–15 ms even on a broken baseline),
/// dense centre (below ~4 ms two clicks fuse and the offset is heard as image
/// POSITION instead).
///
/// Pure and single-threaded by contract: no clocks, no audio, no queues — the
/// wizard session owns applying each ``Phase/asking(candidateMs:)`` value to the
/// live trim.
struct BTAlignmentConstantStimuli {

    enum Answer: Hashable {
        /// The target (the device being aligned) ticked first.
        case target
        /// The reference (the rest of the group) ticked first.
        case reference
        case cantTell
    }

    enum Phase: Equatable {
        case asking(candidateMs: Double)
        case converged(resultMs: Double)
        /// Nothing directional to hear twice over: these speakers need no
        /// alignment the ear can find.
        case gracefulExit
        /// The opposite outcome, and the honest one: the run never found the
        /// offset — the estimate pinned against the end of the usable range, or
        /// the block budget ran out without a single crossover.
        case unreachable
    }

    /// Which pass a question belongs to: the coarse staircase that finds the
    /// rough offset, or the stimulus blocks that measure it.
    enum Stage: Equatable { case search, blocks }

    /// The stimulus set: coarse wings, dense ≥ 4 ms centre.
    static let stimuliMs: [Double] = [-24, -16, -8, -4, 0, 4, 8, 16, 24]
    /// Two blocks' crossovers this close together are the same answer.
    static let convergenceToleranceMs: Double = 4
    /// How far a one-sided block (the true offset is outside the stimulus fan)
    /// moves the working estimate before trying again.
    static let recenterStepMs: Double = 48
    /// Nobody is asked more than this many CONVERGING blocks' worth of
    /// questions.
    static let maxBlocks = 4
    /// Re-centres have their OWN budget: a block that moves the fan measured
    /// nothing, so spending a converging block on it is how the old run
    /// exhausted itself 144 ms short of the truth.
    static let maxRecenters = 3
    /// The staircase's opening step — wide enough that a 300 ms offset is
    /// inside reach in a handful of answers.
    static let searchStartStepMs: Double = 96
    /// A reversal at this step means the estimate is bracketed to within the
    /// stimulus fan's half-width: the blocks can see the crossover from here.
    static let searchFinalStepMs: Double = 24
    /// The search cannot outstay its welcome; past this it hands over wherever
    /// it has got to.
    static let maxSearchAnswers = 12
    /// A trial this far out is a WING: an early one-sided read needs one from
    /// each side, never three answers off the same end of the fan.
    static let wingMs: Double = 16
    /// The progress denominator: the most questions this run can ever ask —
    /// the search cap plus every block either budget allows.
    static let worstCaseQuestionCount =
        maxSearchAnswers + (maxBlocks + maxRecenters) * stimuliMs.count

    private(set) var phase: Phase
    private(set) var stage: Stage = .search
    /// Answers recorded in this run — exactly what ``back()`` can undo, which is
    /// why the wizard's Back button keys off it, and one less than the question
    /// number on screen.
    private(set) var answerCount = 0
    /// Every "can't tell", consecutive or not.
    private(set) var cantTellCount = 0

    /// Every presented level is clamped into this — past it the sink's own
    /// ≥ 0 delay clamp eats the change and the trial would present a difference
    /// that isn't there.
    private let range: ClosedRange<Double>
    private var rng: AnyRandomNumberGenerator
    /// The working estimate `E`, relative to the session's base trim. Every
    /// trial is presented at `E + δ`; δ never leaks into the result.
    private var estimateMs: Double = 0
    /// The δ values left to present in this block, in their shuffled order.
    private var pending: [Double] = []
    private var recorded: [(deltaMs: Double, levelMs: Double, answer: Answer)] = []
    private var crossovers: [Double] = []
    private var blocksCompleted = 0
    private var recenters = 0
    private var consecutiveAllCantTellBlocks = 0
    /// The staircase's current step, and the direction its last answer pointed
    /// (`nil` before the first): a change of direction is the reversal that
    /// halves the step.
    private var searchStepMs = BTAlignmentConstantStimuli.searchStartStepMs
    private var searchDirection: Double?
    private var searchAnswered = 0
    /// The range bound the previous estimate move clamped onto, if it clamped at
    /// all — a second consecutive move onto the SAME bound means the estimate
    /// cannot travel any further and the run bows out as ``Phase/unreachable``.
    private var lastClampBound: Double?
    private var history: [Undo] = []

    init(
        range: ClosedRange<Double> = -BTSyncTrim.rangeMs...BTSyncTrim.rangeMs,
        randomNumberGenerator: any RandomNumberGenerator = SystemRandomNumberGenerator()
    ) {
        self.range = range
        self.rng = AnyRandomNumberGenerator(base: randomNumberGenerator)
        // The staircase opens at the device's own trim: E = 0.
        self.phase = .asking(candidateMs: Swift.min(Swift.max(0, range.lowerBound),
                                                    range.upperBound))
    }

    /// 0…1 for the wizard's indicator: ANSWERS GIVEN over the run's WORST-case
    /// question count — never a bar that pegs with questions still to answer
    /// (live report, 2026-08-22). It measures work DONE, so it deliberately
    /// trails the caption by one: a fresh run opens at 0 with "Question 1" on
    /// screen, and the bar only moves once an answer is actually in.
    var progress: Double {
        guard case .asking = phase else { return 1 }
        return Double(answerCount) / Double(Self.worstCaseQuestionCount)
    }

    /// The question on screen right now, 1-based — the caption's number, one
    /// ahead of the bar's answer count by exactly the answer being asked for.
    var questionNumber: Int { answerCount + 1 }

    /// Fold one answer in. No-op unless currently ``Phase/asking(candidateMs:)``.
    mutating func record(_ answer: Answer) {
        guard case .asking = phase else { return }
        pushUndo()
        answerCount += 1
        if answer == .cantTell { cantTellCount += 1 }
        switch stage {
        case .search: recordSearchAnswer(answer)
        case .blocks: recordTrial(answer)
        }
    }

    /// Undo the newest answer and put its question straight back — a mis-click
    /// nudges nothing. The undo is a whole-state restore, so it crosses the
    /// search/blocks boundary and a block boundary alike.
    mutating func back() {
        guard case .asking = phase, let previous = history.popLast() else { return }
        let stack = history
        self = previous.state
        history = stack
    }

    // MARK: The coarse search

    /// One staircase answer: step toward the side the user named, halving on
    /// each change of direction. "Can't tell" here is not data about a level —
    /// at these spacings there is nothing to fuse — so it simply hands over.
    private mutating func recordSearchAnswer(_ answer: Answer) {
        searchAnswered += 1
        guard answer != .cantTell else { return beginBlocks() }
        let direction: Double = answer == .target ? 1 : -1
        let reversed = searchDirection.map { $0 != direction } ?? false
        if reversed, searchStepMs <= Self.searchFinalStepMs {
            // Bracketed inside the stimulus fan's half-width: measure from here.
            return beginBlocks()
        }
        if reversed { searchStepMs /= 2 }
        searchDirection = direction
        guard moveEstimate(by: direction * searchStepMs) else { return }
        if searchAnswered >= Self.maxSearchAnswers { return beginBlocks() }
        phase = .asking(candidateMs: level(for: 0))
    }

    private mutating func beginBlocks() {
        stage = .blocks
        // A fresh two-strikes budget for the blocks' own re-centres.
        lastClampBound = nil
        beginBlock()
    }

    // MARK: The stimulus blocks

    private func level(for deltaMs: Double) -> Double {
        Swift.min(Swift.max(estimateMs + deltaMs, range.lowerBound), range.upperBound)
    }

    private mutating func beginBlock() {
        pending = Self.stimuliMs
        pending.shuffle(using: &rng)
        recorded = []
        phase = .asking(candidateMs: level(for: pending[0]))
    }

    private mutating func recordTrial(_ answer: Answer) {
        guard let delta = pending.first else { return }
        pending.removeFirst()
        recorded.append((deltaMs: delta, levelMs: level(for: delta), answer: answer))
        if let side = earlyOneSidedSide() {
            recenter(towardTarget: side == .target, requeueRemaining: true)
            return
        }
        if pending.isEmpty {
            completeBlock()
        } else {
            phase = .asking(candidateMs: level(for: pending[0]))
        }
    }

    /// The block is ALREADY plainly one-sided: BOTH wings have been heard, every
    /// answer so far names the same side and nothing has fused. Asking the rest
    /// of a fan the offset sits outside of is wasted questions, so the fan moves
    /// now and the unanswered trials come back around the new estimate.
    ///
    /// Both wings is the load-bearing half. Reading "the widest few agree" would
    /// fire whenever the shuffle happened to open with three trials off ONE end
    /// of the fan — and then the result would depend on the presentation order,
    /// which is the single thing this design guarantees it cannot.
    private func earlyOneSidedSide() -> Answer? {
        guard !pending.isEmpty,
              recorded.contains(where: { $0.deltaMs >= Self.wingMs }),
              recorded.contains(where: { $0.deltaMs <= -Self.wingMs }),
              !recorded.contains(where: { $0.answer == .cantTell }) else { return nil }
        let sides = Set(recorded.map(\.answer))
        guard sides.count == 1, let side = sides.first else { return nil }
        return side
    }

    private mutating func completeBlock() {
        blocksCompleted += 1
        let verdicts = majorityVerdictsByLevel()
        let targetLevels = verdicts.filter { $0.value == .target }.map(\.key)
        let referenceLevels = verdicts.filter { $0.value == .reference }.map(\.key)

        // Nothing directional anywhere: at this spread the ear finds no
        // difference, which IS the answer — the estimate stands. Twice running
        // and there is nothing left to learn.
        guard !targetLevels.isEmpty || !referenceLevels.isEmpty else {
            consecutiveAllCantTellBlocks += 1
            lastClampBound = nil
            if consecutiveAllCantTellBlocks >= 2 {
                phase = .gracefulExit
            } else {
                recordCrossover(estimateMs)
            }
            return
        }
        consecutiveAllCantTellBlocks = 0

        // One-sided: the true offset is outside the stimulus fan entirely, so
        // there is no crossover to read — move the whole fan toward the side the
        // user keeps naming and ask again.
        guard !targetLevels.isEmpty, !referenceLevels.isEmpty else {
            recenter(towardTarget: !targetLevels.isEmpty, requeueRemaining: false)
            return
        }
        lastClampBound = nil

        let highestTarget = targetLevels.max() ?? estimateMs
        let lowestReference = referenceLevels.min() ?? estimateMs
        var crossover = (highestTarget + lowestReference) / 2
        // Can't-tell levels sitting BETWEEN the two sides are the fused region
        // around the point of subjective equality — averageable data, not a
        // failure, so they pull the crossover toward their centre.
        let lower = Swift.min(highestTarget, lowestReference)
        let upper = Swift.max(highestTarget, lowestReference)
        let fused = verdicts
            .filter { $0.value == .cantTell && $0.key > lower && $0.key < upper }
            .map(\.key)
        if !fused.isEmpty {
            crossover = (crossover + fused.reduce(0, +) / Double(fused.count)) / 2
        }
        recordCrossover(crossover)
    }

    /// Majority verdict per PRESENTED level. Distinct δ can land on the same
    /// level once the range clamp bites, which is the case this exists for; a
    /// tie (including no directional answers at all) reads as can't-tell.
    private func majorityVerdictsByLevel() -> [Double: Answer] {
        var byLevel: [Double: (target: Int, reference: Int)] = [:]
        for trial in recorded {
            var counts = byLevel[trial.levelMs] ?? (0, 0)
            switch trial.answer {
            case .target: counts.target += 1
            case .reference: counts.reference += 1
            case .cantTell: break
            }
            byLevel[trial.levelMs] = counts
        }
        return byLevel.mapValues { counts in
            if counts.target > counts.reference { return .target }
            if counts.reference > counts.target { return .reference }
            return .cantTell
        }
    }

    private mutating func recenter(towardTarget: Bool, requeueRemaining: Bool) {
        // `.target` at every level = the target is early everywhere it was
        // asked about, so it needs MORE delay: shift up.
        recenters += 1
        guard moveEstimate(by: towardTarget ? Self.recenterStepMs : -Self.recenterStepMs)
        else { return }
        guard recenters <= Self.maxRecenters else { return finishAtCap() }
        if requeueRemaining {
            // The answers given at the old fan are not evidence about this one.
            recorded = []
            phase = .asking(candidateMs: level(for: pending[0]))
        } else {
            beginBlock()
        }
    }

    /// Move the working estimate, clamped into the usable range. `false` means
    /// the estimate has pinned against the same bound twice running: whatever
    /// the user is hearing, this control cannot reach it.
    private mutating func moveEstimate(by deltaMs: Double) -> Bool {
        let raw = estimateMs + deltaMs
        let shifted = Swift.min(Swift.max(raw, range.lowerBound), range.upperBound)
        let clampBound: Double? = shifted != raw ? shifted : nil
        if let clampBound, lastClampBound == clampBound {
            estimateMs = shifted
            phase = .unreachable
            return false
        }
        lastClampBound = clampBound
        estimateMs = shifted
        return true
    }

    private mutating func recordCrossover(_ crossover: Double) {
        let previous = crossovers.last
        crossovers.append(crossover)
        estimateMs = crossover
        if let previous, abs(crossover - previous) < Self.convergenceToleranceMs {
            phase = .converged(resultMs: (previous + crossover) / 2)
            return
        }
        if crossovers.count >= 3 {
            let last = crossovers.suffix(2)
            phase = .converged(resultMs: last.reduce(0, +) / Double(last.count))
            return
        }
        if crossovers.count >= Self.maxBlocks { finishAtCap() } else { beginBlock() }
    }

    /// Out of budget. A crossover, even an unconfirmed one, is a real reading
    /// and stands; no crossover at all means the run never found the offset, and
    /// saying so is the whole point of ``Phase/unreachable``.
    private mutating func finishAtCap() {
        if let last = crossovers.last {
            phase = .converged(resultMs: last)
        } else {
            phase = .unreachable
        }
    }

    // MARK: Undo

    /// One undo step: the whole estimator as it stood before an answer. A struct
    /// cannot store itself, hence the box — and the stored copy carries an EMPTY
    /// history, so the stack stays linear instead of quadratic.
    private final class Undo {
        let state: BTAlignmentConstantStimuli
        init(_ state: BTAlignmentConstantStimuli) { self.state = state }
    }

    private mutating func pushUndo() {
        var before = self
        before.history = []
        history.append(Undo(before))
    }

    // MARK: Test seams (pure reads)

    var test_estimateMs: Double { estimateMs }
    var test_crossoversMs: [Double] { crossovers }
    var test_blocksCompleted: Int { blocksCompleted }
    var test_pendingCount: Int { pending.count }
    var test_searchStepMs: Double { searchStepMs }
}

/// A concrete box over an injected generator: `shuffle(using:)` takes its
/// generator `inout` and generic, which an `any RandomNumberGenerator` cannot
/// satisfy directly.
struct AnyRandomNumberGenerator: RandomNumberGenerator {
    var base: any RandomNumberGenerator
    mutating func next() -> UInt64 { base.next() }
}
