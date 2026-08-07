// Copyright (C) 2026 ahh and contributors.
//
// LICENSE-CLEAN by design (same posture as `BTAlignmentBisection.swift` /
// `BTSyncedSink.swift`): NO GPL SPDX header — fresh Foundation-only code. Do
// not add a GPL header or copy code in from GPL-headered siblings.

import Foundation

/// One run of the alignment wizard for one Bluetooth device (W2): owns the
/// ``BTAlignmentBisection`` loop end to end and drives the backend through
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
        /// `answersSoFar`/`progress` feed the narrowing indicator; the
        /// candidate ms is deliberately NOT for display (the number is a
        /// closing receipt only — locked UX).
        case question(progress: Double, answersSoFar: Int)
        /// The result, applied live and awaiting Keep / Try again.
        case receipt(trimMs: Int)
        /// Two consecutive can't-tells: the speakers need no alignment the ear
        /// can find. The prior trim is already restored.
        case gracefulExit
    }

    public let deviceID: String
    /// Display names for the two which-side buttons — the ACTUAL devices,
    /// resolved by the host at launch.
    public let targetName: String
    public let referenceName: String

    /// Repainted on every transition (also fired by ``start()``).
    public var onScreenChange: ((Screen) -> Void)?

    public private(set) var screen: Screen = .intro

    private let baseTrimMs: Int
    private var bisection: BTAlignmentBisection
    private let seedBracketMs: Int?
    private let applyPreviewTrim: (Int) -> Void
    private let endPreview: (_ keepMs: Int?) -> Void
    private let setTick: (Bool) -> Void
    /// Set once a terminal intent (keep/cancel) ran, so deinit cleanup and
    /// double-clicks are inert.
    private var ended = false

    /// - Parameters:
    ///   - baseTrimMs: the device's trim when the wizard opened — the anchor
    ///     every candidate is relative to, and what cancel restores.
    ///   - seedBracketMs: optional narrower start (a coarse pass's result).
    ///   - applyPreviewTrim: live, non-persisting trim push (absolute ms).
    ///   - endPreview: commit (`keepMs`) or restore (`nil`) — see
    ///     ``BTOutputControlling/endBTWizardTrimPreview(forDevice:keepMs:)``.
    ///   - setTick: the wizard tick gate.
    public init(
        deviceID: String,
        targetName: String,
        referenceName: String,
        baseTrimMs: Int,
        seedBracketMs: Int? = nil,
        applyPreviewTrim: @escaping (Int) -> Void,
        endPreview: @escaping (_ keepMs: Int?) -> Void,
        setTick: @escaping (Bool) -> Void
    ) {
        self.deviceID = deviceID
        self.targetName = targetName
        self.referenceName = referenceName
        self.baseTrimMs = baseTrimMs
        self.seedBracketMs = seedBracketMs
        self.bisection = Self.makeBisection(seedBracketMs: seedBracketMs)
        self.applyPreviewTrim = applyPreviewTrim
        self.endPreview = endPreview
        self.setTick = setTick
    }

    deinit {
        // A dropped session (panel torn down without an explicit intent)
        // behaves as cancel: prior trim back, tick off.
        cancel()
    }

    private static func makeBisection(seedBracketMs: Int?) -> BTAlignmentBisection {
        seedBracketMs.map { BTAlignmentBisection(bracketMs: $0) } ?? BTAlignmentBisection()
    }

    // MARK: Intents (host-called, main thread by convention)

    /// Intro's Start: tick on (the wake preamble runs while the first
    /// question renders), first candidate applied.
    public func start() {
        guard case .intro = screen, !ended else { return }
        setTick(true)
        applyCurrentCandidate()
        transition(to: questionScreen())
    }

    /// One which-side (or can't-tell) answer folded in.
    public func answer(_ answer: Answer) {
        guard case .question = screen, !ended else { return }
        bisection.record(bisectionAnswer(answer))
        switch bisection.phase {
        case .asking:
            applyCurrentCandidate()
            transition(to: questionScreen())
        case .converged(let resultMs):
            let trimMs = BTSyncTrim.clamp(baseTrimMs + resultMs)
            applyPreviewTrim(trimMs)
            setTick(false)
            transition(to: .receipt(trimMs: trimMs))
        case .gracefulExit:
            setTick(false)
            endPreview(nil)
            transition(to: .gracefulExit)
        }
    }

    /// Receipt's Keep: persist the applied result. Terminal.
    public func keep() {
        guard case .receipt(let trimMs) = screen, !ended else { return }
        ended = true
        endPreview(trimMs)
    }

    /// Receipt's Try again: prior trim back, fresh bisection, tick back on.
    public func tryAgain() {
        guard case .receipt = screen, !ended else { return }
        endPreview(nil)
        bisection = Self.makeBisection(seedBracketMs: seedBracketMs)
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

    private func bisectionAnswer(_ answer: Answer) -> BTAlignmentBisection.Answer {
        switch answer {
        case .target: .target
        case .reference: .reference
        case .cantTell: .cantTell
        }
    }

    private func applyCurrentCandidate() {
        guard case .asking(let candidateMs) = bisection.phase else { return }
        applyPreviewTrim(BTSyncTrim.clamp(baseTrimMs + candidateMs))
    }

    private func questionScreen() -> Screen {
        .question(progress: bisection.progress, answersSoFar: bisection.answerCount)
    }

    private func transition(to newScreen: Screen) {
        screen = newScreen
        onScreenChange?(newScreen)
    }
}
