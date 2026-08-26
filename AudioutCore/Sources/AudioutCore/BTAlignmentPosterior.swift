// Copyright (C) 2026 ahh and contributors.
//
// LICENSE-CLEAN by design (PLAN-UNIVERSAL-SYNC Decision 5 posture, same as
// `BTSyncedSink.swift`): this file carries NO GPL SPDX header. It is a pure
// Foundation-only state machine written fresh for this project. Do not add a
// GPL header, and do not copy code into it from GPL-headered siblings.

import Foundation

/// The alignment wizard's estimator: a BAYESIAN POSTERIOR over "how far apart
/// are these two speakers", updated by each judgment and asking next whatever
/// question it expects to learn the most from. This is the technique hearing
/// and vision tests have used for forty years (QUEST / the psi method) — no
/// training data, no model file, just a probability curve and Bayes' rule.
///
/// **Why it replaced the method of constant stimuli it supersedes**: the old
/// design asked a fixed fan of levels in blocks and needed ~30 answers, and its
/// progress bar had no honest denominator because the run's length was not
/// fixed in the first place. A posterior asks a variable number of questions
/// and knows how sure it is at every point, which is what both the stop rule
/// and the bar are built on. It also turns "they sound together" from a dead
/// end into evidence: a monotonic staircase cannot use a non-monotonic answer
/// (García-Pérez 2014), which is exactly why the old code needed blocks —
/// multiplying likelihoods has no such limitation.
///
/// **The listener model is still WIDER than a real listener, and it comes in
/// two widths** (`dev/notes/wizard-estimator-effectiveness-brief.md` §3.4).
/// Slope `σ = 5 ms` everywhere — that one must not move, dropping it to 3
/// doubles the bow-out rate. The fusion half-window and the lapse rate depend
/// on how wide the grid is: an ordinary (trim) run gets `c = 4`, `λ = 0.06`,
/// and a LATENCY run keeps the original `c = 6`, `λ = 0.12`, because on its
/// twice-as-wide grid the breadth is the thing holding the error down. An
/// over-broad model is unbiased within ~10 trials where an under-broad one is
/// not (Alcalá-Quintana & García-Pérez 2004), and the lapse rate must be
/// non-zero or real mistakes bias the result WORSE the longer the run goes
/// (Wichmann & Hill 2001) — 0.06 still satisfies both. These constants are
/// simulation-backed; tune them only against a fresh sweep.
///
/// Sign convention, identical to every estimator before it: `.target` means the
/// user heard the wizard's TARGET device first — it plays EARLY, so the true
/// offset lies ABOVE the presented level. `.reference` is the mirror.
///
/// Deterministic and single-threaded by contract: no randomness, no clocks, no
/// audio, no queues — the wizard session owns applying each
/// ``Phase/asking(candidateMs:)`` value to the live trim.
struct BTAlignmentPosterior {

    enum Answer: Hashable {
        /// The target (the device being aligned) ticked first.
        case target
        /// The reference (the rest of the group) ticked first.
        case reference
        /// The two clicks landed as one — the residual is inside the ear's
        /// fusion window, which is real evidence about where the truth is.
        case together
    }

    enum Phase: Equatable {
        case asking(candidateMs: Double)
        /// The posterior is tight enough to name a value: the user hears it
        /// applied and either agrees or sends the run back for more.
        case proposing(valueMs: Double)
        /// A proposal accepted.
        case converged(resultMs: Double)
        /// Too much of the belief is piled against an end of the usable range:
        /// whatever the user is hearing, this control cannot reach it.
        case unreachable
        /// The answers are not converging on anything — the interval stopped
        /// narrowing, or the run has simply gone on long enough.
        case unsettled(bestGuessMs: Double)
    }

    // MARK: The listener model (fixed — see the type comment)

    /// The SHARPENED model — every run whose grid is the ordinary width.
    /// `4 / 5 / 0.06` against the `6 / 5 / 0.12` this shipped with: measured on
    /// the trim grid it is strictly better on every axis at once — median 9
    /// answers → 7, p90 error 7 ms → 5 ms, results more than 10 ms off
    /// 5.1% → 3.7%, bow-outs 2.7% → 2.0% (brief §3.4). Widening it back to 6 /
    /// 0.12 buys nothing here and costs two answers.
    static let fusionHalfWindowMs: Double = 4
    static let slopeMs: Double = 5
    static let lapseRate: Double = 0.06

    /// The WIDE model, kept for a LATENCY run — twice the grid (2001 points
    /// against 1001), where the breadth earns its keep: sharpening there saves
    /// one answer but takes results more than 10 ms off from 6.3% to 8.6%
    /// (brief §3.4). Do not collapse the two models into one until a sweep says
    /// the wide grid can afford it.
    static let latencyFusionHalfWindowMs: Double = 6
    static let latencyLapseRate: Double = 0.12

    /// The confirm step's window. "They land as one" is a claim that the
    /// residual is inside ±4 ms, and it carries its own (much smaller) lapse
    /// rate: agreeing with a value you have just been played is an easier
    /// judgment than naming a side.
    static let fusedHalfWindowMs: Double = 4
    static let fusedLapseRate: Double = 0.05

    /// Propose as soon as the 95% credible interval is this tight. 8 ms, not
    /// the 6 ms this shipped with, and the reason is that the two thresholds
    /// have the SAME p97 error: 12 ms, flat from 6 ms all the way out to 20 ms,
    /// because the tail is set by the listener's own resolution and not by
    /// where the run stops (brief §3.5). 6 ms simply pays two extra answers for
    /// that same tail, and 4 ms pays six. What loosening does cost is the
    /// middle of the distribution — results more than 10 ms off go 5.1% → ~6%
    /// (trim) and 6.3% → 8.5% (latency) — which the confirm-by-ear step
    /// backstops: nothing is persisted until the user has heard the value, and
    /// a rejection folds in real evidence rather than discarding the run.
    /// Measured end to end with the model above: median 6 answers / 8 clicks on
    /// a trim run, 9 / 10 on a latency one. Do NOT put this back to 6.
    static let proposeHalfWidthMs: Double = 8

    /// Where the next question may sit, relative to the posterior median.
    /// Coarse wings so a never-aligned speaker is reachable in a few answers,
    /// a dense centre for the endgame.
    static let candidateStepsMs: [Double] =
        [0, 2, 4, 6, 8, 11, 15, 20, 28, 40, 60, 90, 140, 220, 350, 550, 900]

    /// ``Phase/unreachable``: this much belief this close to an end of the
    /// range, once there are enough answers for it to mean anything.
    static let wingWidthMs = 20
    static let wingMassFraction: Double = 0.2
    static let minAnswersForUnreachable = 8

    /// ``Phase/unsettled``: the interval has to shrink by this much across
    /// this many answers, nobody is asked more than ``maxAnswers``, and a
    /// third rejected proposal ends the run wherever it stands.
    ///
    /// The shrink check gets two guards, one per false-positive mode it was
    /// measured producing (210 simulated runs, ~10% lapse listener). It never
    /// fires before ``minAnswersForStagnation``: a couple of early lapses can
    /// stall a still-wide interval for a window, and almost every such run
    /// recovers given a few more answers. And it never fires once the
    /// interval is inside ``stagnationFloorMs``: near the finish line
    /// relative shrink slows for every listener (the crawl from ~13 ms of
    /// half-width down to the 8 ms stop), which is convergence, not noise.
    /// ``maxAnswers`` and ``maxRejections`` stay the hard backstops.
    static let stagnationWindow = 8
    static let stagnationShrinkFraction: Double = 0.2
    static let stagnationFloorMs: Double = 20
    static let minAnswersForStagnation = 16
    static let maxAnswers = 40

    /// Three rejected proposals, not the two this shipped with. Measured, the
    /// third one is free — no accuracy cost at all — and it HALVES the share of
    /// runs that bow out `.unsettled` (5.6% → 2.9%, brief §3.5). That halving
    /// is what pays for the looser ``proposeHalfWidthMs`` above: a slightly
    /// looser stop proposes sooner, and the extra rejection is what a run gets
    /// back if the sooner proposal was wrong. Do NOT put this back to 2.
    static let maxRejections = 3

    /// How far outside the belief grid a presented level may sit, so the
    /// likelihood tables cover every residual that can ever be looked up.
    private static let lutMarginMs = Int(candidateStepsMs.last ?? 900)

    /// Belief below this contributes nothing measurable to an entropy
    /// evaluation, and skipping it is what keeps the 33-candidate search cheap
    /// once the posterior has narrowed onto a handful of milliseconds.
    private static let negligibleMass = 1e-12

    private(set) var phase: Phase
    /// Every answer this run has taken, undone ones excluded — the number the
    /// bow-out rules and the telemetry count.
    private(set) var answerCount = 0

    /// Every presented level is clamped into this — past it the sink's own
    /// ≥ 0 delay clamp eats the change and the trial would present a
    /// difference that isn't there.
    private let range: ClosedRange<Double>
    private let gridLowerMs: Int
    private var belief: [Double]
    /// The belief at the start of the current undoable stretch: the flat prior,
    /// or whatever a rejected proposal left behind. ``back()`` refolds from
    /// here rather than snapshotting whole states.
    private var baseBelief: [Double]
    /// The answers since that point, in order — what ``back()`` can undo. The
    /// posterior is order-independent, so replaying them is exact.
    private var history: [(levelMs: Double, answer: Answer)] = []
    /// The 95% half-width at the start and after each answer: the stagnation
    /// rule's ledger.
    private var halfWidths: [Double]
    private var rejections = 0
    private let openingHalfWidthMs: Double

    private let targetLikelihoods: [Double]
    private let referenceLikelihoods: [Double]
    private let togetherLikelihoods: [Double]
    private let lutOffset: Int

    /// - Parameters:
    ///   - range: the offsets a question may be asked at, in estimate space.
    ///   - measuresLatency: whether this run is a device LATENCY over the wide
    ///     grid, which picks the wide listener model — see
    ///     ``latencyFusionHalfWindowMs``.
    ///   - openingProposalMs: a value to open on rather than a question — the
    ///     zero-click path for a device that has been measured before. The
    ///     prior stays FLAT behind it: this is a UI shortcut, not a
    ///     statistical one (a narrow prior seeded from a stored value is
    ///     exactly the under-broad model the citations warn about).
    init(range: ClosedRange<Double>, measuresLatency: Bool = false,
         openingProposalMs: Double? = nil) {
        self.range = range
        let lower = Int(range.lowerBound.rounded())
        let upper = Swift.max(lower, Int(range.upperBound.rounded()))
        let count = upper - lower + 1
        gridLowerMs = lower
        belief = Array(repeating: 1 / Double(count), count: count)
        baseBelief = belief

        let span = count - 1
        lutOffset = span + Self.lutMarginMs
        var target = [Double](repeating: 0, count: 2 * lutOffset + 1)
        var reference = target
        var together = target
        let halfWindow = measuresLatency ? Self.latencyFusionHalfWindowMs
                                         : Self.fusionHalfWindowMs
        let lapse = measuresLatency ? Self.latencyLapseRate : Self.lapseRate
        for index in target.indices {
            let residual = Double(index - lutOffset)
            let (t, r, g) = Self.judgmentProbabilities(residualMs: residual,
                                                       halfWindowMs: halfWindow,
                                                       lapseRate: lapse)
            target[index] = t
            reference[index] = r
            together[index] = g
        }
        targetLikelihoods = target
        referenceLikelihoods = reference
        togetherLikelihoods = together

        let opening = Self.halfWidth(of: belief, gridLowerMs: lower)
        openingHalfWidthMs = opening
        halfWidths = [opening]

        // `nextLevelMs()` reads the finished belief, so every stored property
        // — `phase` included — has to hold something before it can be called.
        phase = .asking(candidateMs: 0)
        if let openingProposalMs {
            phase = .proposing(valueMs: Swift.min(Swift.max(openingProposalMs, range.lowerBound),
                                                  range.upperBound).rounded())
        } else {
            phase = .asking(candidateMs: nextLevelMs())
        }
    }

    // MARK: Derived reads (the session and the panel consume these)

    var medianMs: Double { quantileMs(0.5) }

    var credibleIntervalMs: ClosedRange<Double> {
        let lower = quantileMs(0.025)
        let upper = quantileMs(0.975)
        return Swift.min(lower, upper)...Swift.max(lower, upper)
    }

    var credibleHalfWidthMs: Double {
        let interval = credibleIntervalMs
        return (interval.upperBound - interval.lowerBound) / 2
    }

    /// 0…1 for the panel's indicator, measured in ORDERS of narrowing rather
    /// than answers given: a run's length is not fixed, so a bar counting
    /// questions has no honest denominator. It may RETREAT after a rejected
    /// proposal, because the interval really did widen — that is the truth,
    /// not a glitch, and it is not clamped monotone.
    var progress: Double {
        guard openingHalfWidthMs > Self.proposeHalfWidthMs else { return 1 }
        let ratio = openingHalfWidthMs / Swift.max(credibleHalfWidthMs, 1e-9)
        let value = log(ratio) / log(openingHalfWidthMs / Self.proposeHalfWidthMs)
        return Swift.min(Swift.max(value, 0), 1)
    }

    /// Answers that can still be taken back: the stretch since the last
    /// rejected proposal. The panel's Back button keys off this, so its
    /// enabled state and ``back()``'s own guard can never disagree.
    var undoableAnswerCount: Int { history.count }

    // MARK: Intents

    /// Fold one answer in. No-op unless currently ``Phase/asking(candidateMs:)``.
    mutating func record(_ answer: Answer) {
        guard case .asking(let levelMs) = phase else { return }
        history.append((levelMs: levelMs, answer: answer))
        answerCount += 1
        fold(answer, atLevel: levelMs)
        halfWidths.append(credibleHalfWidthMs)
        phase = phaseAfterAnswer()
    }

    /// Undo the newest answer and put its question straight back. The belief is
    /// REFOLDED from where the stretch began rather than restored from a
    /// snapshot — a posterior does not care what order its evidence arrived in,
    /// and replaying a few dozen multiplies is cheaper than keeping undo
    /// states around.
    mutating func back() {
        guard case .asking = phase, !history.isEmpty else { return }
        history.removeLast()
        answerCount -= 1
        halfWidths.removeLast()
        refold()
        phase = .asking(candidateMs: nextLevelMs())
    }

    /// "Sounds right": the user has just heard the proposed value and says the
    /// clicks land as one, which is itself a judgment — fold it in as such
    /// rather than simply stopping.
    /// The result is the value that was PROPOSED, not the median the fold
    /// leaves behind. On an ordinary run the two agree to the millisecond —
    /// the belief is already a spike at the proposal. On a ZERO-CLICK one they
    /// do not: the prior is still flat, and the confirm step's 5% lapse floor
    /// spread across two thousand grid points outweighs the fused bump, so the
    /// median sits nearer the middle of the range than the value the user just
    /// agreed to. Committing anything but the value they heard would be a
    /// different number appearing for no reason they could see.
    mutating func acceptProposal() {
        guard case .proposing(let valueMs) = phase else { return }
        foldFusedJudgment(atLevel: valueMs, fused: true)
        phase = .converged(resultMs: valueMs)
    }

    /// "Still off": the opposite evidence, which widens the belief around the
    /// proposal and sends the run back to questions. ``maxRejections`` is
    /// enough — one more proposal from the same answers would be the same
    /// proposal.
    mutating func rejectProposal() {
        guard case .proposing(let valueMs) = phase else { return }
        foldFusedJudgment(atLevel: valueMs, fused: false)
        rejections += 1
        // The rejection is not an ANSWER, so it is not undoable: it becomes the
        // floor the next stretch of answers refolds from.
        baseBelief = belief
        history = []
        if rejections >= Self.maxRejections {
            phase = .unsettled(bestGuessMs: medianMs)
        } else {
            phase = .asking(candidateMs: nextLevelMs())
        }
    }

    // MARK: The belief

    private mutating func fold(_ answer: Answer, atLevel levelMs: Double) {
        let table = likelihoods(for: answer)
        let level = Int(levelMs.rounded())
        var total = 0.0
        for i in belief.indices {
            let weight = belief[i] * table[lutIndex(gridIndex: i, levelMs: level)]
            belief[i] = weight
            total += weight
        }
        normalise(total)
    }

    /// The confirm step's likelihood: `Φ((4−a)/σ) − Φ((−4−a)/σ)` — the chance
    /// the residual reads as fused — or its complement for a rejection.
    private mutating func foldFusedJudgment(atLevel levelMs: Double, fused: Bool) {
        let level = Int(levelMs.rounded())
        var total = 0.0
        for i in belief.indices {
            let residual = Double(gridLowerMs + i - level)
            var p = Self.phi((Self.fusedHalfWindowMs - residual) / Self.slopeMs)
                - Self.phi((-Self.fusedHalfWindowMs - residual) / Self.slopeMs)
            p = (1 - Self.fusedLapseRate) * p + Self.fusedLapseRate / 2
            let weight = belief[i] * (fused ? p : 1 - p)
            belief[i] = weight
            total += weight
        }
        normalise(total)
    }

    private mutating func normalise(_ total: Double) {
        guard total > 0 else {
            // Every grid point ruled out at once cannot happen with a non-zero
            // lapse rate, but a belief of all zeroes would be unrecoverable.
            belief = Array(repeating: 1 / Double(belief.count), count: belief.count)
            return
        }
        for i in belief.indices { belief[i] /= total }
    }

    private mutating func refold() {
        belief = baseBelief
        for entry in history { fold(entry.answer, atLevel: entry.levelMs) }
    }

    // MARK: Where to ask next

    /// The candidate whose answer is expected to leave the least uncertainty
    /// behind. Ties break toward the median, which the generation order below
    /// gives for free (nearest step first) as long as the comparison is
    /// strict.
    private func nextLevelMs() -> Double {
        let median = medianMs
        var best = median
        var bestEntropy = Double.infinity
        var seen = Set<Double>()
        for step in Self.candidateStepsMs {
            for raw in (step == 0 ? [median] : [median - step, median + step]) {
                let candidate = Swift.min(Swift.max(raw.rounded(), range.lowerBound.rounded()),
                                          range.upperBound.rounded())
                guard seen.insert(candidate).inserted else { continue }
                let entropy = expectedEntropy(atLevel: candidate)
                if entropy < bestEntropy {
                    bestEntropy = entropy
                    best = candidate
                }
            }
        }
        return best
    }

    /// `Σ_answer P(answer) · H(posterior | answer)`, folded into one pass per
    /// answer: with `w = belief · likelihood`, `P = Σw` and
    /// `H = log P − (Σ w·log w) / P`, so the contribution is
    /// `P·log P − Σ w·log w`.
    private func expectedEntropy(atLevel levelMs: Double) -> Double {
        let level = Int(levelMs.rounded())
        var total = 0.0
        for table in [targetLikelihoods, referenceLikelihoods, togetherLikelihoods] {
            var mass = 0.0
            var weightedLogSum = 0.0
            for i in belief.indices where belief[i] > Self.negligibleMass {
                let weight = belief[i] * table[lutIndex(gridIndex: i, levelMs: level)]
                mass += weight
                if weight > 0 { weightedLogSum += weight * log(weight) }
            }
            guard mass > 0 else { continue }
            total += mass * log(mass) - weightedLogSum
        }
        return total
    }

    // MARK: The bow-outs

    /// The bow-outs come FIRST because they are about the run being unable to
    /// finish, and a proposal from a belief piled against the end of the range
    /// would be a number rather than an answer. Confidence beats stagnation,
    /// though: a run that has just reached its stop rule has not stagnated, it
    /// has arrived.
    private func phaseAfterAnswer() -> Phase {
        if answerCount >= Self.minAnswersForUnreachable, massIsPinnedInAWing {
            return .unreachable
        }
        if credibleHalfWidthMs <= Self.proposeHalfWidthMs {
            return .proposing(valueMs: medianMs.rounded())
        }
        if hasStagnated || answerCount >= Self.maxAnswers {
            return .unsettled(bestGuessMs: medianMs)
        }
        return .asking(candidateMs: nextLevelMs())
    }

    private var massIsPinnedInAWing: Bool {
        let wing = Swift.min(Self.wingWidthMs, belief.count)
        let low = belief.prefix(wing).reduce(0, +)
        let high = belief.suffix(wing).reduce(0, +)
        return low >= Self.wingMassFraction || high >= Self.wingMassFraction
    }

    private var hasStagnated: Bool {
        guard answerCount >= Self.minAnswersForStagnation else { return false }
        guard halfWidths.count > Self.stagnationWindow else { return false }
        let earlier = halfWidths[halfWidths.count - 1 - Self.stagnationWindow]
        let now = halfWidths[halfWidths.count - 1]
        // The endgame crawl is not stagnation — see ``stagnationFloorMs``.
        guard now > Self.stagnationFloorMs else { return false }
        return now > earlier * (1 - Self.stagnationShrinkFraction)
    }

    // MARK: Likelihoods

    private func likelihoods(for answer: Answer) -> [Double] {
        switch answer {
        case .target: targetLikelihoods
        case .reference: referenceLikelihoods
        case .together: togetherLikelihoods
        }
    }

    private func lutIndex(gridIndex: Int, levelMs: Int) -> Int {
        let raw = gridLowerMs + gridIndex - levelMs + lutOffset
        return Swift.min(Swift.max(raw, 0), targetLikelihoods.count - 1)
    }

    /// The three-way judgment model at one residual `a = θ − x`, every limb
    /// mixed with the lapse rate so no answer can ever rule a value out
    /// outright.
    private static func judgmentProbabilities(residualMs a: Double,
                                              halfWindowMs: Double,
                                              lapseRate: Double)
        -> (target: Double, reference: Double, together: Double)
    {
        let target = phi((a - halfWindowMs) / slopeMs)
        let reference = phi((-a - halfWindowMs) / slopeMs)
        let together = Swift.max(0, 1 - target - reference)
        func lapsed(_ p: Double) -> Double { (1 - lapseRate) * p + lapseRate / 3 }
        return (lapsed(target), lapsed(reference), lapsed(together))
    }

    /// The standard normal CDF, from Darwin's `erf` — no dependency, and
    /// tabulated once per run so nothing calls it per answer.
    private static func phi(_ z: Double) -> Double {
        0.5 * (1 + erf(z / 2.0.squareRoot()))
    }

    // MARK: Quantiles

    private func quantileMs(_ p: Double) -> Double {
        Self.quantileMs(p, of: belief, gridLowerMs: gridLowerMs)
    }

    private static func quantileMs(_ p: Double, of belief: [Double],
                                   gridLowerMs: Int) -> Double {
        var cumulative = 0.0
        for i in belief.indices {
            cumulative += belief[i]
            if cumulative >= p { return Double(gridLowerMs + i) }
        }
        return Double(gridLowerMs + belief.count - 1)
    }

    private static func halfWidth(of belief: [Double], gridLowerMs: Int) -> Double {
        let lower = quantileMs(0.025, of: belief, gridLowerMs: gridLowerMs)
        let upper = quantileMs(0.975, of: belief, gridLowerMs: gridLowerMs)
        return (upper - lower) / 2
    }

    // MARK: Test seams (pure reads)

    var test_belief: [Double] { belief }
    var test_gridLowerMs: Int { gridLowerMs }
    var test_rejections: Int { rejections }
    var test_openingHalfWidthMs: Double { openingHalfWidthMs }
}
