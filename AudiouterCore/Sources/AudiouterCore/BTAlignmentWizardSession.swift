// Copyright (C) 2026 ahh and contributors.
//
// LICENSE-CLEAN by design (same posture as `BTAlignmentConstantStimuli.swift`
// / `BTSyncedSink.swift`): NO GPL SPDX header — fresh Foundation-only code. Do
// not add a GPL header or copy code in from GPL-headered siblings.

import Foundation

/// One run of the alignment wizard for one device (W2): owns the
/// ``BTAlignmentConstantStimuli`` loop end to end and drives the backend through
/// three injected closures — candidate trims as LIVE PREVIEWS (relative to the
/// device's trim at session start, never persisted mid-run), the wizard-shaped
/// tick (continuous, keep-alive bed + wake preamble), and the end-of-preview
/// commit/restore. UI-framework-free: the panel renders ``screen`` and calls
/// the intents; every exit path — Keep, graceful exit, cancel, deinit —
/// restores or persists explicitly and always switches the tick off.
public final class BTAlignmentWizardSession {

    public enum Answer: Equatable {
        /// The target device (the one being aligned) ticked first.
        case target
        /// The reference ticked first.
        case reference
        case cantTell
    }

    public enum Screen: Equatable {
        case intro
        /// `answersSoFar`/`progress` feed the question count and the narrowing
        /// indicator (`answersSoFar + 1` is the question on screen), and
        /// `searching` says the coarse staircase is still finding the range;
        /// the candidate ms is deliberately NOT for display (the number is a
        /// closing receipt only — locked UX).
        case question(progress: Double, answersSoFar: Int, searching: Bool)
        /// The result, applied live and awaiting Keep / Try again.
        case receipt(trimMs: Double)
        /// Two consecutive all-can't-tell blocks: the speakers need no
        /// alignment the ear can find. The prior trim is already restored.
        case gracefulExit
        /// The opposite outcome, and the one the old run mislabelled as
        /// "already aligned": the estimate pinned against the end of the usable
        /// range, or the blocks never found a crossover. Prior trim restored.
        case unreachable
        /// A LATENCY run that converged on a meaningfully negative value: the
        /// speaker measured as playing EARLIER than the Mac, which the Mac
        /// being the zero makes physically implausible. Nothing is persisted —
        /// storing a negative latency, or silently flooring it to 0, would both
        /// dress a bad reading up as a measurement.
        case macIsLate
    }

    /// The speaker the target is compared against. Identity, not just a
    /// display string: the host has to engage it (make it audible) for the
    /// run and put the selection back afterwards.
    public struct Reference: Equatable {
        public let id: String
        public let name: String
        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    public let deviceID: String
    /// Display name for the target's which-side button — the ACTUAL device,
    /// resolved by the host at launch.
    public let targetName: String
    /// `nil` when the host could not establish a second audible speaker: the
    /// run is refused (``start()`` is inert) until the host picks one.
    public private(set) var reference: Reference?

    /// Repainted on every transition (also fired by ``start()``).
    public var onScreenChange: ((Screen) -> Void)?

    public private(set) var screen: Screen = .intro

    /// The wizard's coarse-search tempo (BPM) and its stimulus-block tempo. The
    /// search walks an unknown 150–700 ms Bluetooth latency, and at 72 BPM a
    /// 650 ms lag aliases into an apparent ~180 ms LEAD — a whole beat wrong.
    /// One tick every 3 s is wider than anything the search can reach; the
    /// blocks, by which point the estimate is inside ±24 ms, close back up.
    public static let searchTickBPM: Double = 20
    public static let blocksTickBPM: Double = 72

    /// The floor a LATENCY result has to clear to be believable. Below it the
    /// run reports ``Screen/macIsLate`` and persists nothing; between it and 0
    /// the reading stands and ``keep()`` floors the stored value at 0. −4 ms is
    /// the estimator's own convergence tolerance — inside that, a negative
    /// result is measurement dust, not a claim about the hardware.
    public static let implausibleLatencyMs: Double = -BTAlignmentConstantStimuli
        .convergenceToleranceMs

    /// The value this run is measuring, at the moment it opened. For a
    /// Bluetooth target that is the device's MEASURED LATENCY; for the Mac's
    /// own row it is the user's sync offset.
    private let baseValueMs: Double
    /// What the measured value may be set to. Past it the sink's own ≥ 0 delay
    /// clamp eats the change and a trial would present a difference that is not
    /// there.
    private let candidateRangeMs: ClosedRange<Double>
    /// Whether a RISING estimate means a FALLING candidate. It does for a
    /// Bluetooth latency: `.target` means the target was heard first, so it is
    /// early and needs MORE delay — and a larger latency feeds the speaker
    /// EARLIER (`SyncTiming.totalDelayNanos` subtracts it), so the latency must
    /// come DOWN. A trim is the mirror: it is added to the delay, so it rises
    /// with the estimate.
    private let invertsEstimate: Bool
    private var estimator: BTAlignmentConstantStimuli
    /// The tempo last pushed, so a stage that has not changed costs nothing.
    private var lastTempoBPM: Double?
    /// Handed to every estimator the session builds, so a seeded generator
    /// makes a whole run — restarts included — reproducible in tests.
    private let randomNumberGenerator: any RandomNumberGenerator
    private let applyPreviewTrim: (Double) -> Void
    private let endPreview: (_ keepMs: Double?) -> Void
    private let setTick: (Bool) -> Void
    private let setTempo: (Double) -> Void
    /// Set once the run is over — a terminal intent (keep/cancel) OR a terminal
    /// SCREEN (graceful exit / unreachable), both of which have already put the
    /// tick off and the prior value back. The panel's Done button still calls
    /// ``cancel()``, and without this those screens fired a SECOND tick-off
    /// edge, which the backend pays for as a full re-anchor of every sink.
    private var ended = false

    /// - Parameters:
    ///   - baseValueMs: the measured value when the wizard opened — the anchor
    ///     every candidate is relative to, and what cancel restores.
    ///   - candidateRangeMs: the values a candidate may actually take.
    ///   - invertsEstimate: see ``invertsEstimate``.
    ///   - randomNumberGenerator: drives each block's stimulus shuffle.
    ///   - applyPreviewTrim: live, non-persisting trim push (absolute ms).
    ///   - endPreview: commit (`keepMs`) or restore (`nil`) — see
    ///     ``BTOutputControlling/endBTWizardTrimPreview(forDevice:keepMs:)``.
    ///   - setTick: the wizard tick gate.
    public init(
        deviceID: String,
        targetName: String,
        reference: Reference?,
        baseValueMs: Double,
        candidateRangeMs: ClosedRange<Double> = -BTSyncTrim.rangeMs...BTSyncTrim.rangeMs,
        invertsEstimate: Bool = false,
        randomNumberGenerator: any RandomNumberGenerator = SystemRandomNumberGenerator(),
        applyPreviewTrim: @escaping (Double) -> Void,
        endPreview: @escaping (_ keepMs: Double?) -> Void,
        setTick: @escaping (Bool) -> Void,
        setTempo: @escaping (Double) -> Void = { _ in }
    ) {
        self.deviceID = deviceID
        self.targetName = targetName
        self.reference = reference
        self.baseValueMs = Swift.min(Swift.max(baseValueMs, candidateRangeMs.lowerBound),
                                     candidateRangeMs.upperBound)
        self.candidateRangeMs = candidateRangeMs
        self.invertsEstimate = invertsEstimate
        self.randomNumberGenerator = randomNumberGenerator
        self.applyPreviewTrim = applyPreviewTrim
        self.endPreview = endPreview
        self.setTick = setTick
        self.setTempo = setTempo
        self.estimator = BTAlignmentConstantStimuli(
            range: Self.estimateRange(base: self.baseValueMs, candidates: candidateRangeMs,
                                      inverted: invertsEstimate),
            randomNumberGenerator: randomNumberGenerator)
    }

    /// The estimator works in ESTIMATE space (`E`, relative to the base); the
    /// candidate range is in VALUE space. This is the one conversion between
    /// them, so a run can never present a level the sink would clamp away.
    private static func estimateRange(base: Double, candidates: ClosedRange<Double>,
                                      inverted: Bool) -> ClosedRange<Double> {
        inverted
            ? (base - candidates.upperBound)...(base - candidates.lowerBound)
            : (candidates.lowerBound - base)...(candidates.upperBound - base)
    }

    /// One estimate turned into the value that goes on the wire.
    private func candidate(for estimateMs: Double) -> Double {
        let raw = invertsEstimate ? baseValueMs - estimateMs : baseValueMs + estimateMs
        return Swift.min(Swift.max(raw, candidateRangeMs.lowerBound),
                         candidateRangeMs.upperBound).rounded()
    }

    deinit {
        // A dropped session (panel torn down without an explicit intent)
        // behaves as cancel: prior trim back, tick off.
        cancel()
    }

    private func makeEstimator() -> BTAlignmentConstantStimuli {
        BTAlignmentConstantStimuli(
            range: Self.estimateRange(base: baseValueMs, candidates: candidateRangeMs,
                                      inverted: invertsEstimate),
            randomNumberGenerator: randomNumberGenerator)
    }

    // MARK: Intents (host-called, main thread by convention)

    /// A different speaker to compare against, chosen mid-flight. Every answer
    /// so far was given against the OLD reference, so they are not evidence
    /// about this one — the run restarts rather than folding them in.
    public func setReference(_ reference: Reference?) {
        guard !ended, reference != self.reference else { return }
        self.reference = reference
        switch screen {
        case .intro:
            // Nothing to reset yet; repaint the names and the Start gate.
            transition(to: .intro)
        case .question:
            estimator = makeEstimator()
            applyCurrentCandidate()
            transition(to: questionScreen())
        case .receipt, .gracefulExit, .unreachable, .macIsLate:
            break
        }
    }

    /// Intro's Start: tick on (the wake preamble runs while the first
    /// question renders), first candidate applied. Refused without a
    /// reference — there would be nothing to compare the target against.
    public func start() {
        guard case .intro = screen, !ended, reference != nil else { return }
        // A fresh injector comes up with a fresh beat clock, so whatever tempo
        // the session pushed before is void.
        lastTempoBPM = nil
        setTick(true)
        applyCurrentCandidate()
        transition(to: questionScreen())
    }

    /// One which-side (or can't-tell) answer folded in.
    public func answer(_ answer: Answer) {
        guard case .question = screen, !ended else { return }
        estimator.record(estimatorAnswer(answer))
        switch estimator.phase {
        case .asking:
            applyCurrentCandidate()
            transition(to: questionScreen())
        case .converged(let resultMs):
            let trimMs = candidate(for: resultMs)
            // A latency run that lands below this measured the speaker as
            // EARLIER than the reference — with the Mac as the zero that is not
            // a thing a speaker does, so the honest answer is "no clean
            // reading", not a receipt. (Dust either side of 0 is a real reading
            // of a speaker with no measurable latency; Keep floors it.)
            if invertsEstimate, trimMs < Self.implausibleLatencyMs {
                endRun()
                transition(to: .macIsLate)
                return
            }
            applyPreviewTrim(trimMs)
            setTick(false)
            transition(to: .receipt(trimMs: trimMs))
        case .gracefulExit:
            endRun()
            transition(to: .gracefulExit)
        case .unreachable:
            endRun()
            transition(to: .unreachable)
        }
    }

    /// Undo the last answer and ask that question again. Available only while
    /// questions are running and at least one answer stands — which is exactly
    /// what `.question`'s `answersSoFar` reports, so the button's enabled state
    /// and this guard can never disagree. It crosses the search/blocks boundary
    /// (and a block boundary): the estimator undoes whole states, not trials.
    public func back() {
        guard case .question = screen, !ended, estimator.answerCount > 0 else { return }
        estimator.back()
        applyCurrentCandidate()
        transition(to: questionScreen())
    }

    /// Receipt's Keep: persist the applied result. Terminal.
    ///
    /// A LATENCY result is floored at 0 on the way out: the run can present
    /// negative candidates (it has to, or a fresh speaker's first answer
    /// dead-ends — see the range's floor), but a negative latency is not a
    /// physical quantity to store. Anything far enough below 0 to be a claim
    /// rather than dust never reached a receipt at all.
    public func keep() {
        guard case .receipt(let trimMs) = screen, !ended else { return }
        ended = true
        endPreview(invertsEstimate ? Swift.max(0, trimMs) : trimMs)
    }

    /// Receipt's Try again: prior trim back, fresh run, tick back on.
    public func tryAgain() {
        guard case .receipt = screen, !ended else { return }
        endPreview(nil)
        estimator = makeEstimator()
        lastTempoBPM = nil
        setTick(true)
        applyCurrentCandidate()
        transition(to: questionScreen())
    }

    /// Any abandonment (close button, popover closing, row vanishing): prior
    /// trim back, tick off. Idempotent; a no-op after Keep.
    public func cancel() {
        guard !ended else { return }
        ended = true
        setTick(false)
        // After a graceful exit the restore already ran, but `endPreview(nil)`
        // is a stored-trim re-push — repeating it is harmless and keeps this
        // path unconditional.
        endPreview(nil)
    }

    // MARK: Internals

    /// The two terminal SCREENS' shared exit: tick off, prior value back, and
    /// the run marked over so the panel's Done (``cancel()``) is inert.
    private func endRun() {
        ended = true
        setTick(false)
        endPreview(nil)
    }

    private func estimatorAnswer(_ answer: Answer) -> BTAlignmentConstantStimuli.Answer {
        switch answer {
        case .target: .target
        case .reference: .reference
        case .cantTell: .cantTell
        }
    }

    private func applyCurrentCandidate() {
        guard case .asking(let estimateMs) = estimator.phase else { return }
        applyPreviewTrim(candidate(for: estimateMs))
    }

    private func questionScreen() -> Screen {
        .question(progress: estimator.progress,
                  answersSoFar: estimator.answerCount,
                  searching: estimator.stage == .search)
    }

    private func transition(to newScreen: Screen) {
        // The stimulus tempo follows the estimator's stage: slow enough while
        // the coarse search is out at unknown distances that nothing can alias,
        // back to the metronome's pace once the blocks are inside ±24 ms.
        if case .question(_, _, let searching) = newScreen {
            let bpm = searching ? Self.searchTickBPM : Self.blocksTickBPM
            if lastTempoBPM != bpm {
                lastTempoBPM = bpm
                setTempo(bpm)
            }
        }
        screen = newScreen
        onScreenChange?(newScreen)
    }
}
