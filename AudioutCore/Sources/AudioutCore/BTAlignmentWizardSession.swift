// Copyright (C) 2026 ahh and contributors.
//
// LICENSE-CLEAN by design (same posture as `BTAlignmentPosterior.swift`
// / `BTSyncedSink.swift`): NO GPL SPDX header — fresh Foundation-only code. Do
// not add a GPL header or copy code in from GPL-headered siblings.

import Foundation

/// Which affordance opened a wizard run — carried into
/// `bt_sync:wizard_started` so the four doors can be told apart.
public enum BTAlignmentWizardDoor: String {
    case chip, note, drawer, menu
}

/// One run of the alignment wizard for one device (W2): owns the
/// ``BTAlignmentPosterior`` loop end to end and drives the backend through
/// three injected closures — candidate trims as LIVE PREVIEWS (relative to the
/// device's trim at session start, never persisted mid-run), the wizard-shaped
/// tick (continuous, keep-alive bed + wake preamble), and the end-of-preview
/// commit/restore. UI-framework-free: the panel renders ``screen`` and calls
/// the intents; every exit path — Sounds right, the bow-outs, cancel, deinit —
/// restores or persists explicitly and always switches the tick off.
public final class BTAlignmentWizardSession {

    public enum Answer: Equatable {
        /// The target device (the one being aligned) ticked first.
        case target
        /// The reference ticked first.
        case reference
        /// Both at once — evidence that the residual is inside the ear's
        /// fusion window, not a dead end.
        case together
    }

    public enum Screen: Equatable {
        case intro
        /// `progress` feeds the narrowing indicator, `credibleIntervalMs` the
        /// confidence line (already in VALUE space — the panel never does the
        /// sign conversion), and `answersSoFar` gates Back. The candidate ms
        /// is deliberately NOT for display: the number is named once, on the
        /// proposal.
        case question(progress: Double, credibleIntervalMs: ClosedRange<Double>,
                      answersSoFar: Int)
        /// The estimator is confident enough to name a value. It is applied
        /// live and the tick KEEPS RUNNING — the whole question is whether the
        /// clicks now land as one, which there is nothing to judge without.
        case proposal(valueMs: Double)
        /// The proposal accepted and persisted. Terminal for the run's audio,
        /// but the panel stays up so the row's chip can be seen flipping.
        case kept(valueMs: Double)
        /// The answers never settled on one value. Prior trim restored.
        case unsettled(bestGuessMs: Double)
        /// The belief piled against the end of the usable range: the offset
        /// the user is hearing is not one this control can reach. Prior trim
        /// restored.
        case unreachable
        /// A LATENCY run whose proposal is meaningfully negative: the speaker
        /// measured as playing EARLIER than the Mac, which the Mac being the
        /// zero makes physically implausible. Nothing is persisted — storing a
        /// negative latency, or silently flooring it to 0, would both dress a
        /// bad reading up as a measurement.
        case macIsLate
    }

    /// The speaker the target is compared against. Identity, not just a
    /// display string: the host has to engage it (make it audible) for the
    /// run and put the selection back afterwards.
    public struct Reference: Equatable {
        public let id: String
        public let name: String
        /// Which fan-out this speaker plays through, and so WHICH SOUND it
        /// makes during the run: the Bluetooth fan-out carries the bright
        /// click, the engine feed (AirPlay, and the Mac's own output) the low
        /// knock. See ``BTAlignmentWizardSession/pairSoundsDiffer``.
        public let isBluetooth: Bool
        public init(id: String, name: String, isBluetooth: Bool = false) {
            self.id = id
            self.name = name
            self.isBluetooth = isBluetooth
        }
    }

    public let deviceID: String
    /// Display name for the target's which-side button — the ACTUAL device,
    /// resolved by the host at launch.
    public let targetName: String
    /// `nil` when the host could not establish a second audible speaker: the
    /// run is refused (``start()`` is inert) until the host picks one.
    public private(set) var reference: Reference?

    /// Whether the target plays through the Bluetooth fan-out — see
    /// ``Reference/isBluetooth``.
    public let targetIsBluetooth: Bool

    /// Whether the two speakers really do make DIFFERENT sounds this run. The
    /// tick's two timbres are split by TRANSPORT, not by role
    /// (`AlignmentTickInjector.mixWizardVariants` → the capture coordinator's
    /// fan-outs), so a Bluetooth target against the Mac differs while
    /// Bluetooth-against-Bluetooth plays one identical click on both sides. The
    /// panel names the two sounds only when this is true — copy that promised a
    /// cue the run isn't giving would be worse than saying nothing.
    public var pairSoundsDiffer: Bool {
        guard let reference else { return false }
        return reference.isBluetooth != targetIsBluetooth
    }

    /// Repainted on every transition (also fired by ``start()``).
    public var onScreenChange: ((Screen) -> Void)?

    public private(set) var screen: Screen = .intro

    /// The wizard's wide tempo and its close-quarters one. A run that is still
    /// hundreds of milliseconds wide walks an unknown 150–700 ms Bluetooth
    /// latency, and at 72 BPM a 650 ms lag aliases into an apparent ~180 ms
    /// LEAD — a whole beat wrong. One tick every 3 s is wider than anything the
    /// run can be uncertain about; once the interval closes up, so does the
    /// tempo.
    public static let searchTickBPM: Double = 20
    public static let blocksTickBPM: Double = 72
    /// The credible half-width at which the tempo closes up.
    public static let fineTempoHalfWidthMs: Double = 250

    /// The credible half-width at which the posterior proposes a result
    /// (wizard-stage v2 spec §5 — the `threshold` rung's own boundary lives
    /// here so the view never retypes it). Forwards `BTAlignmentPosterior`'s
    /// internal `proposeHalfWidthMs`, single-owned there.
    public static var proposeHalfWidthMs: Double { BTAlignmentPosterior.proposeHalfWidthMs }

    /// The floor a LATENCY result has to clear to be believable. Below it the
    /// run reports ``Screen/macIsLate`` and persists nothing; between it and 0
    /// the reading stands and accepting floors the stored value at 0. −4 ms is
    /// the confirm step's own fusion window — inside that, a negative result is
    /// measurement dust, not a claim about the hardware.
    public static let implausibleLatencyMs: Double = -BTAlignmentPosterior.fusedHalfWindowMs

    /// Whether this run measures a device LATENCY (a Bluetooth row) rather
    /// than the Mac's own sync offset. The panel picks its kept-screen copy
    /// off it: the two runs write different things in different places.
    public var measuresLatency: Bool { invertsEstimate }

    /// The values a result may take, in VALUE space — the stage's wire is a
    /// window onto this range, so the view never has to guess how far the
    /// interval could travel.
    public var candidateRange: ClosedRange<Double> { candidateRangeMs }

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
    private var estimator: BTAlignmentPosterior
    /// The tempo last pushed, so an unchanged one costs nothing.
    private var lastTempoBPM: Double?
    private let applyPreviewTrim: (_ ms: Double, _ halfWidthMs: Double?) -> Void
    private let endPreview: (_ keepMs: Double?) -> Void
    private let setTick: (Bool) -> Void
    private let setTempo: (Double) -> Void
    /// Set once the run is over — a terminal intent (accept/cancel) OR a
    /// terminal SCREEN (unsettled / unreachable / macIsLate), all of which have
    /// already put the tick off and the prior value back. The panel's Done
    /// button still calls ``cancel()``, and without this those screens fired a
    /// SECOND tick-off edge, which the backend pays for as a full re-anchor of
    /// every sink.
    private var ended = false

    /// - Parameters:
    ///   - baseValueMs: the measured value when the wizard opened — the anchor
    ///     every candidate is relative to, and what cancel restores.
    ///   - candidateRangeMs: the values a candidate may actually take.
    ///   - invertsEstimate: see ``invertsEstimate``.
    ///   - openingProposalMs: a value to open the run's PROPOSAL on instead of
    ///     the first question — the zero-click path for a device that has been
    ///     measured before. Deliberately NOT kept: ``tryAgain()`` means "that
    ///     value was wrong", so re-offering it would be the one useless thing
    ///     a restart could do.
    ///   - applyPreviewTrim: live, non-persisting trim push (absolute ms),
    ///     carrying the belief's current half-width for the run's telemetry.
    ///   - endPreview: commit (`keepMs`) or restore (`nil`) — see
    ///     ``BTOutputControlling/endBTWizardTrimPreview(forDevice:keepMs:)``.
    ///   - setTick: the wizard tick gate.
    public init(
        deviceID: String,
        targetName: String,
        reference: Reference?,
        targetIsBluetooth: Bool = false,
        baseValueMs: Double,
        candidateRangeMs: ClosedRange<Double> = -BTSyncTrim.rangeMs...BTSyncTrim.rangeMs,
        invertsEstimate: Bool = false,
        openingProposalMs: Double? = nil,
        applyPreviewTrim: @escaping (_ ms: Double, _ halfWidthMs: Double?) -> Void,
        endPreview: @escaping (_ keepMs: Double?) -> Void,
        setTick: @escaping (Bool) -> Void,
        setTempo: @escaping (Double) -> Void = { _ in }
    ) {
        self.deviceID = deviceID
        self.targetName = targetName
        self.reference = reference
        self.targetIsBluetooth = targetIsBluetooth
        self.baseValueMs = Swift.min(Swift.max(baseValueMs, candidateRangeMs.lowerBound),
                                     candidateRangeMs.upperBound)
        self.candidateRangeMs = candidateRangeMs
        self.invertsEstimate = invertsEstimate
        self.applyPreviewTrim = applyPreviewTrim
        self.endPreview = endPreview
        self.setTick = setTick
        self.setTempo = setTempo
        let estimateRange = Self.estimateRange(base: self.baseValueMs,
                                               candidates: candidateRangeMs,
                                               inverted: invertsEstimate)
        let anchor = self.baseValueMs
        var opening: Double?
        if let openingProposalMs {
            opening = invertsEstimate ? anchor - openingProposalMs : openingProposalMs - anchor
        }
        // `invertsEstimate` IS the latency run, and the latency run is the wide
        // grid — which is the one that still needs the wide listener model.
        self.estimator = BTAlignmentPosterior(range: estimateRange,
                                              measuresLatency: invertsEstimate,
                                              openingProposalMs: opening)
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

    /// A fresh estimator over a flat prior. Deliberately WITHOUT the opening
    /// proposal: every caller here is a restart, and a restart's whole point is
    /// that the value it would open on was rejected.
    private func makeEstimator() -> BTAlignmentPosterior {
        BTAlignmentPosterior(range: Self.estimateRange(base: baseValueMs,
                                                       candidates: candidateRangeMs,
                                                       inverted: invertsEstimate),
                             measuresLatency: invertsEstimate)
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
            presentEstimatorPhase()
        case .proposal, .kept, .unsettled, .unreachable, .macIsLate:
            break
        }
    }

    /// Intro's Start: tick on (the wake preamble runs while the first
    /// question renders), first candidate applied. Refused without a
    /// reference — there would be nothing to compare the target against.
    /// A run carrying an opening proposal goes straight to it: the device has
    /// been measured before, so the honest first question is "still right?".
    public func start() {
        guard case .intro = screen, !ended, reference != nil else { return }
        // A fresh injector comes up with a fresh beat clock, so whatever tempo
        // the session pushed before is void.
        lastTempoBPM = nil
        setTick(true)
        presentEstimatorPhase()
    }

    /// One which-side (or they-sound-together) answer folded in.
    public func answer(_ answer: Answer) {
        guard case .question = screen, !ended else { return }
        estimator.record(estimatorAnswer(answer))
        presentEstimatorPhase()
    }

    /// A mic-probe measurement landing mid-run (roadmap 064): present it as
    /// the proposal to confirm by ear. `valueMs` is in VALUE space (a
    /// Bluetooth run's measured latency in ms). Meaningful only while
    /// questions are running — a run already proposing, ended, or still on the
    /// intro keeps its state, and the probe result is simply dropped (the
    /// by-ear machinery owes it nothing). The estimator's belief is untouched:
    /// the measurement feeds the proposal, never the prior.
    public func offerMeasuredProposal(valueMs: Double) {
        guard case .question = screen, !ended else { return }
        let estimate = invertsEstimate ? baseValueMs - valueMs : valueMs - baseValueMs
        estimator.offerProposal(estimate)
        Telemetry.log(.localPlayback, "wizard_mic_proposal", [
            "uid": deviceID,
            "valueMs": String(Int(valueMs.rounded())),
        ])
        presentEstimatorPhase()
    }

    /// Undo the last answer and ask that question again. Available only while
    /// questions are running and at least one answer stands — which is exactly
    /// what `.question`'s `answersSoFar` reports, so the button's enabled state
    /// and this guard can never disagree.
    public func back() {
        guard case .question = screen, !ended,
              estimator.undoableAnswerCount > 0 else { return }
        estimator.back()
        presentEstimatorPhase()
    }

    /// The proposal's "Sounds right": accepting IS keeping. The value the user
    /// just heard is the value persisted — the preview and the commit can never
    /// name different numbers.
    ///
    /// A LATENCY result is floored at 0 on the way out: the run can present
    /// negative candidates (it has to, or a fresh speaker's first answer
    /// dead-ends — see the range's floor), but a negative latency is not a
    /// physical quantity to store. Anything far enough below 0 to be a claim
    /// rather than dust never reached a proposal at all.
    public func acceptProposal() {
        guard case .proposal(let valueMs) = screen, !ended else { return }
        logProposal(valueMs: valueMs, accepted: true)
        estimator.acceptProposal()
        let keptMs = invertsEstimate ? Swift.max(0, valueMs) : valueMs
        ended = true
        setTick(false)
        endPreview(keptMs)
        transition(to: .kept(valueMs: keptMs))
    }

    /// One step of hand-tuning on a proposal the listener can nearly live
    /// with, applied LIVE so the next click is already at the new value —
    /// dialing it in by ear is the whole point, and a step you cannot hear
    /// until you commit is not a step.
    ///
    /// The ESTIMATOR is deliberately not told. Its belief was built from
    /// which-side answers, and a nudge is not one: it carries no information
    /// about which speaker was heard first, only that the user wants the
    /// number somewhere else. Folding it in would let a hand-tune masquerade
    /// as evidence. ``acceptProposal()`` persists whatever the screen is
    /// showing, so the nudged value is the value kept.
    public func nudgeProposal(byMs deltaMs: Double) {
        guard case .proposal(let valueMs) = screen, !ended else { return }
        let nudged = Swift.min(Swift.max(valueMs + deltaMs, candidateRangeMs.lowerBound),
                               candidateRangeMs.upperBound)
        guard nudged != valueMs else { return }
        applyPreviewTrim(nudged, estimator.credibleHalfWidthMs)
        transition(to: .proposal(valueMs: nudged))
    }

    /// The proposal's "Still off": the run takes the correction and goes back
    /// to questions, or bows out if this was the second time.
    public func rejectProposal() {
        guard case .proposal(let valueMs) = screen, !ended else { return }
        logProposal(valueMs: valueMs, accepted: false)
        estimator.rejectProposal()
        presentEstimatorPhase()
    }

    /// Try again: a fresh run from a flat prior. Reachable from the proposal
    /// and from every screen the run can bow out on, and the two arrive in
    /// opposite states — hence the split. Either way a SECOND edge of the tick
    /// or the preview costs the backend a re-anchor of every sink for nothing.
    public func tryAgain() {
        switch screen {
        case .proposal, .unsettled, .unreachable, .macIsLate: break
        case .intro, .question, .kept: return
        }
        if ended {
            // A bow-out already restored the prior value and silenced the tick;
            // the fresh run needs it back, and a fresh injector comes up with a
            // fresh beat clock, so the pushed tempo is void.
            ended = false
            lastTempoBPM = nil
            setTick(true)
        } else {
            // Straight from the proposal: the tick never stopped, so only the
            // previewed value has to go back.
            endPreview(nil)
        }
        estimator = makeEstimator()
        presentEstimatorPhase()
    }

    /// The kept screen's Done. The run is already over — this exists so the
    /// panel has one close intent that is not "cancel"; the HOST's `onFinished`
    /// does the teardown.
    public func done() {}

    /// Any abandonment (close button, popover closing, row vanishing): prior
    /// trim back, tick off. Idempotent; a no-op once the run has ended.
    public func cancel() {
        guard !ended else { return }
        ended = true
        setTick(false)
        // After a bow-out the restore already ran, but `endPreview(nil)` is a
        // stored-trim re-push — repeating it is harmless and keeps this path
        // unconditional.
        endPreview(nil)
    }

    // MARK: Internals

    /// Put whatever the estimator is now on, on screen — the ONE place a
    /// candidate is applied and a screen is chosen, so every intent
    /// (start/answer/back/reject/restart) lands on identical behaviour.
    private func presentEstimatorPhase() {
        switch estimator.phase {
        case .asking(let estimateMs):
            applyPreviewTrim(candidate(for: estimateMs), estimator.credibleHalfWidthMs)
            transition(to: questionScreen())
        case .proposing(let estimateMs):
            let valueMs = candidate(for: estimateMs)
            // A proposal below this measured the speaker as EARLIER than the
            // reference — with the Mac as the zero that is not a thing a
            // speaker does, so the honest answer is "no clean reading", not a
            // value to confirm.
            guard !invertsEstimate || valueMs >= Self.implausibleLatencyMs else {
                endRun()
                transition(to: .macIsLate)
                return
            }
            // The tick STAYS ON: the user judges the proposal by listening to
            // it, and re-firing the gate would cost a full re-anchor.
            applyPreviewTrim(valueMs, estimator.credibleHalfWidthMs)
            transition(to: .proposal(valueMs: valueMs))
        case .unsettled(let estimateMs):
            let bestGuessMs = candidate(for: estimateMs)
            endRun()
            transition(to: .unsettled(bestGuessMs: bestGuessMs))
        case .unreachable:
            endRun()
            transition(to: .unreachable)
        case .converged:
            // Reached only through `acceptProposal()`, which owns the exit.
            break
        }
    }

    /// The bow-out screens' shared exit: tick off, prior value back, and the
    /// run marked over so the panel's Done (``cancel()``) is inert.
    private func endRun() {
        ended = true
        setTick(false)
        endPreview(nil)
    }

    private func estimatorAnswer(_ answer: Answer) -> BTAlignmentPosterior.Answer {
        switch answer {
        case .target: .target
        case .reference: .reference
        case .together: .together
        }
    }

    private func questionScreen() -> Screen {
        .question(progress: estimator.progress,
                  credibleIntervalMs: valueSpaceCredibleInterval(),
                  answersSoFar: estimator.undoableAnswerCount)
    }

    /// The credible interval the panel shows, converted once here so the view
    /// never has to know about the sign flip — an inverted run's interval comes
    /// out reversed, and both ends are clamped into the usable range, so the
    /// line can never claim more spread than the run ever had.
    private func valueSpaceCredibleInterval() -> ClosedRange<Double> {
        let interval = estimator.credibleIntervalMs
        let first = candidate(for: interval.lowerBound)
        let second = candidate(for: interval.upperBound)
        return Swift.min(first, second)...Swift.max(first, second)
    }

    private func logProposal(valueMs: Double, accepted: Bool) {
        Telemetry.log(.localPlayback, "wizard_proposal", [
            "uid": deviceID,
            "valueMs": String(Int(valueMs.rounded())),
            "answers": String(estimator.answerCount),
            "halfWidthMs": String(format: "%.1f", estimator.credibleHalfWidthMs),
            "accepted": accepted ? "true" : "false",
        ])
    }

    private func transition(to newScreen: Screen) {
        // The tempo follows how sure the run is, and moves only when a level is
        // being PRESENTED — never between a level and its answer, or the user
        // would be judging one thing and answering about another.
        switch newScreen {
        case .question, .proposal:
            let bpm = estimator.credibleHalfWidthMs > Self.fineTempoHalfWidthMs
                ? Self.searchTickBPM : Self.blocksTickBPM
            if lastTempoBPM != bpm {
                lastTempoBPM = bpm
                setTempo(bpm)
            }
        case .intro, .kept, .unsettled, .unreachable, .macIsLate:
            break
        }
        screen = newScreen
        onScreenChange?(newScreen)
    }
}
