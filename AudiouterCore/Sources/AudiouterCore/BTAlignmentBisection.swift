// Copyright (C) 2026 ahh and contributors.
//
// LICENSE-CLEAN by design (PLAN-UNIVERSAL-SYNC Decision 5 posture, same as
// `BTSyncedSink.swift`): this file carries NO GPL SPDX header. It is a pure
// Foundation-only state machine written fresh for this project. Do not add a
// GPL header, and do not copy code into it from GPL-headered siblings.

import Foundation

/// The alignment wizard's which-side bisection (PLAN-UNIVERSAL-SYNC,
/// "ALIGNMENT WIZARD UX LOCKED 2026-08-08"): a bracket over the candidate trim
/// (ms, signed, relative to whatever trim the wizard session anchors on) that
/// each which-speaker-ticked-first answer halves toward the named side.
///
/// The stop rules, exactly as locked:
///
///  - **Two consecutive disagreements** (an answer reversing the previous
///    answer's direction, twice in a row — the A, B, A pattern that means the
///    user is oscillating around their point of subjective equality) →
///    ``Phase/converged(resultMs:)`` at the MEAN of the last two reversal
///    midpoints (the candidates computed as each of those reversals folded).
///  - **Two consecutive "can't tell"** → ``Phase/gracefulExit`` (the speakers
///    are far enough apart — or close enough together — that the flam carries
///    no usable direction; the wizard restores the prior trim and bows out).
///    A directional answer resets the run; "can't tell" never folds the
///    bracket, but every one is counted in ``cantTellCount``.
///  - **Width floor**: a bracket folded down to ≤ ``floorWidthMs`` converges
///    at its midpoint outright — a perfectly consistent answerer must
///    terminate too, in ⌈log₂(2·bracket/floor)⌉ ≈ 9 answers from ±500 ms.
///
/// Sign convention: `.target` means the user heard the wizard's TARGET device
/// first — it plays EARLY, so it needs MORE delay and the true offset lies
/// ABOVE the candidate (the bracket's low edge rises). `.reference` is the
/// mirror image.
///
/// Pure and single-threaded by contract: no clocks, no audio, no queues —
/// the wizard session owns applying each ``Phase/asking(candidateMs:)``
/// candidate to the live trim.
struct BTAlignmentBisection {

    enum Answer: Equatable {
        /// The target (the device being aligned) ticked first.
        case target
        /// The reference (the rest of the group) ticked first.
        case reference
        case cantTell
    }

    enum Phase: Equatable {
        case asking(candidateMs: Int)
        case converged(resultMs: Int)
        case gracefulExit
    }

    /// Below this bracket width (ms) further halving is beyond by-ear
    /// resolution (the flam collapses around 10–20 ms; trims step 1 ms fine).
    static let floorWidthMs = 2

    private(set) var phase: Phase
    /// Every "can't tell", consecutive or not — recorded separately from the
    /// bracket per the locked spec (diagnostics/receipt copy may read it).
    private(set) var cantTellCount = 0
    /// Directional answers folded so far (drives the ~5-answer expectation).
    private(set) var answerCount = 0

    private var lowMs: Int
    private var highMs: Int
    private let initialWidthMs: Int
    private var consecutiveCantTell = 0
    /// The previous directional answer, for reversal detection.
    private var lastDirection: Answer?
    /// Midpoints computed as each reversal folded, newest last.
    private var reversalMidpoints: [Int] = []
    /// `true` while the newest entry of `reversalMidpoints` came from the
    /// immediately preceding answer — the "consecutive" half of the stop rule.
    private var lastAnswerWasReversal = false

    /// - Parameter bracketMs: half-width of the starting bracket. ±500 ms (the
    ///   trim range) unless a coarse pass already narrowed it.
    init(bracketMs: Int = BTSyncTrim.rangeMs) {
        let bracket = max(Self.floorWidthMs, abs(bracketMs))
        self.lowMs = -bracket
        self.highMs = bracket
        self.initialWidthMs = 2 * bracket
        self.phase = .asking(candidateMs: 0)
    }

    /// 0…1 narrowing progress for the wizard's indicator, log-scaled so each
    /// answer advances it evenly (each fold halves the bracket).
    var progress: Double {
        guard case .asking = phase else { return 1 }
        let width = Double(highMs - lowMs)
        let floorWidth = Double(Self.floorWidthMs)
        let total = log2(Double(initialWidthMs) / floorWidth)
        guard total > 0 else { return 1 }
        return min(1, max(0, log2(Double(initialWidthMs) / width) / total))
    }

    /// Fold one answer in. No-op unless currently ``Phase/asking(candidateMs:)``.
    mutating func record(_ answer: Answer) {
        guard case .asking(let candidate) = phase else { return }

        if answer == .cantTell {
            cantTellCount += 1
            consecutiveCantTell += 1
            lastAnswerWasReversal = false
            if consecutiveCantTell >= 2 { phase = .gracefulExit }
            return
        }
        consecutiveCantTell = 0
        answerCount += 1

        // Fold toward the named side.
        if answer == .target {
            lowMs = candidate       // true offset above the candidate
        } else {
            highMs = candidate      // true offset below the candidate
        }
        let midpoint = (lowMs + highMs) / 2

        let isReversal = lastDirection != nil && lastDirection != answer
        lastDirection = answer
        if isReversal {
            reversalMidpoints.append(midpoint)
            if lastAnswerWasReversal, reversalMidpoints.count >= 2 {
                // Two consecutive disagreements: the mean of the last two
                // reversal midpoints is the point of subjective equality.
                let last = reversalMidpoints.suffix(2)
                phase = .converged(resultMs: last.reduce(0, +) / last.count)
                return
            }
            lastAnswerWasReversal = true
        } else {
            lastAnswerWasReversal = false
        }

        if highMs - lowMs <= Self.floorWidthMs {
            phase = .converged(resultMs: midpoint)
            return
        }
        phase = .asking(candidateMs: midpoint)
    }

    // MARK: Test seams (pure reads)

    var test_bracket: (lowMs: Int, highMs: Int) { (lowMs, highMs) }
}
