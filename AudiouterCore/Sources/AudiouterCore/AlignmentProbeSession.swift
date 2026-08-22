// Copyright (C) 2026 ahh and contributors.
//
// LICENSE-CLEAN by design (same posture as `BTAlignmentWizardSession.swift` /
// `BTSyncedSink.swift`): NO GPL SPDX header — fresh Foundation-only code. Do
// not add a GPL header or copy code in from GPL-headered siblings.

import Foundation

/// One run of the phone-measured alignment probe (BT auto-cal spike,
/// `dev/notes/bt-autocal-spike-spec.md`): the Mac plays the shared align tick
/// and alternates WHICH speaker is audible, so a phone recording a single
/// microphone stream hears the reference and the target in strict alternation
/// and can recover their offset without ever comparing two clocks.
///
/// The pattern is a binding contract with the phone-side analyzer — it decodes
/// the recording against exactly these constants, so changing one here is a
/// protocol break, not a tuning knob:
///
///  1. `preambleSeconds` of bed-only audio with BOTH sides audible. The tick
///     injector's own preamble must cover the same span (`.probe` config), so
///     no tick sounds while both speakers are up — a tick heard from both at
///     once would merge into the analyzer's first block.
///  2. `repetitions` × `[REF block: ticksPerBlock ticks, target muted]`
///     `[gap: gapBeats, both muted]` `[TGT block: ticksPerBlock ticks,
///     reference muted]` `[gap: gapBeats]`. **The first block is always REF** —
///     the phone starts recording before asking the Mac to start, so it can
///     take the alternation from the top with no handshake.
///
/// Every step is scheduled from run start as a wall-clock offset rather than
/// chained off the previous one, so a late step never pushes the rest of the
/// pattern out; ±200 ms is well inside the analyzer's tolerance (it discards
/// each block's first tick, which is the one a mute boundary can clip).
///
/// UI-framework-free and hardware-free, like ``BTAlignmentWizardSession``: the
/// host injects the mute writes, the tick gate, the liveness check and the
/// timer, so the whole sequence is assertable with no audio at all. Every exit
/// path — the pattern finishing, `cancel()`, the 90 s timeout, the target
/// device vanishing mid-run, `deinit` — restores every mute this run touched
/// and switches the tick off. Main-thread-only by convention, exactly like the
/// wizard session: every injected closure ends up at `GroupController`.
public final class AlignmentProbeSession {

    /// Why a run ended, for the host's log and the phone's status.
    public enum Outcome: Equatable {
        /// The whole pattern played.
        case finished
        /// `cancel()` — the phone's Cancel, or the host tearing the run down.
        case cancelled
        /// `timeoutSeconds` elapsed with the pattern still running.
        case timedOut
        /// The target stopped being a live output mid-run: there is nothing
        /// left to measure, and holding the reference muted would be silence
        /// for no reason.
        case targetVanished
    }

    // MARK: The binding pattern (see the spec — all three tracks share these)

    /// 60/72 s ≈ 833.33 ms. The tick's own tempo: `AlignmentTickInjector`'s
    /// default 72 BPM, spaced so a fully-offset device can't alias as aligned
    /// one beat late (the ±500 ms trim range).
    public static let beatPeriodSeconds = 60.0 / 72.0
    public static let ticksPerBlock = 6
    public static let gapBeats = 2
    public static let repetitions = 3
    /// Bed-only, both sides audible: long enough to wake a power-gated amp
    /// (the Sonos Move swallows the first transients after silence).
    public static let preambleSeconds = 5.0
    /// Hard ceiling on one run (~45 s of pattern). A run that somehow stops
    /// stepping still restores the fleet's mutes.
    public static let timeoutSeconds = 90.0

    /// Seconds from run start to the end of the pattern.
    public static var patternSeconds: Double {
        let beatsPerRepetition = Double(2 * ticksPerBlock + 2 * gapBeats)
        return preambleSeconds + Double(repetitions) * beatsPerRepetition * beatPeriodSeconds
    }

    /// One scheduled boundary: who should be audible from this moment on.
    enum Step: Equatable {
        /// Bed-only wake, both sides audible.
        case preamble
        /// A REF block — the reference ticks alone.
        case referenceBlock
        /// A TGT block — the target ticks alone.
        case targetBlock
        /// Between blocks: silence on both sides, so the analyzer can split
        /// blocks on the gap.
        case gap
    }

    public let targetDeviceID: String
    /// Everything standing in for "the reference". A single picked speaker, or
    /// — when the phone named no reference — every OTHER audible Main Out
    /// member, which is what "compare against Main Out" means once the target
    /// is taken out of it.
    public let referenceDeviceIDs: [String]

    /// Fired once, on whichever exit path ends the run, AFTER the mutes are
    /// restored and the tick is off.
    public var onEnd: ((Outcome) -> Void)?

    public private(set) var isRunning = false

    private let setMuted: (String, Bool) -> Void
    private let isMuted: (String) -> Bool
    private let isTargetLive: () -> Bool
    private let setTick: (Bool) -> Void
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void

    /// Mute state as it was when `start()` ran, for every device this run
    /// touches — what every exit path puts back.
    private var priorMuted: [String: Bool] = [:]
    /// The last mute value this run WROTE per device, so a step only emits the
    /// transitions it actually changes.
    private var appliedMuted: [String: Bool] = [:]
    private var ended = false

    /// - Parameters:
    ///   - setMuted: the host's per-device mute write (`GroupController
    ///     .setMuted(_:for:)`). Per-device even for a Main Out reference: the
    ///     target may itself be a Main Out member, and `setMainOutMuted` would
    ///     silence the very speaker being measured.
    ///   - isMuted: the same controller's read-back, sampled once at `start()`.
    ///   - isTargetLive: whether the target is still a device the host can
    ///     write to (discovered, connected). Re-checked at every step.
    ///   - setTick: the probe-shaped tick run's gate.
    ///   - schedule: run a body after N seconds. Injected so tests step the
    ///     pattern deterministically instead of sleeping ~45 s of wall clock.
    public init(
        targetDeviceID: String,
        referenceDeviceIDs: [String],
        setMuted: @escaping (String, Bool) -> Void,
        isMuted: @escaping (String) -> Bool,
        isTargetLive: @escaping () -> Bool,
        setTick: @escaping (Bool) -> Void,
        schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, body in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { body() }
        }
    ) {
        self.targetDeviceID = targetDeviceID
        self.referenceDeviceIDs = referenceDeviceIDs
        self.setMuted = setMuted
        self.isMuted = isMuted
        self.isTargetLive = isTargetLive
        self.setTick = setTick
        self.schedule = schedule
    }

    deinit {
        // A dropped session (host torn down mid-run) behaves as cancel: prior
        // mutes back, tick off — never speakers left silent.
        end(.cancelled)
    }

    // MARK: Intents

    /// Begin the run: sample the mute state to restore, unmute both sides for
    /// the preamble, start the tick, and schedule every boundary. Inert on a
    /// second call.
    public func start() {
        guard !isRunning, !ended else { return }
        isRunning = true
        for id in [targetDeviceID] + referenceDeviceIDs {
            priorMuted[id] = isMuted(id)
        }
        setTick(true)
        apply(.preamble)
        for (offset, step) in Self.stepSchedule() {
            schedule(offset) { [weak self] in self?.stepFired(step) }
        }
        schedule(Self.patternSeconds) { [weak self] in self?.end(.finished) }
        schedule(Self.timeoutSeconds) { [weak self] in self?.end(.timedOut) }
    }

    /// Abandon the run: prior mutes back, tick off. Idempotent, and a no-op
    /// once the run has ended by any other path.
    public func cancel() {
        end(.cancelled)
    }

    // MARK: Internals

    /// Every boundary after the preamble, as a wall-clock offset from run
    /// start. Built once per run; the preamble itself is applied immediately by
    /// `start()` rather than scheduled at 0.
    static func stepSchedule() -> [(offset: TimeInterval, step: Step)] {
        var steps: [(TimeInterval, Step)] = []
        var beat = 0.0
        for _ in 0..<repetitions {
            steps.append((preambleSeconds + beat * beatPeriodSeconds, .referenceBlock))
            beat += Double(ticksPerBlock)
            steps.append((preambleSeconds + beat * beatPeriodSeconds, .gap))
            beat += Double(gapBeats)
            steps.append((preambleSeconds + beat * beatPeriodSeconds, .targetBlock))
            beat += Double(ticksPerBlock)
            steps.append((preambleSeconds + beat * beatPeriodSeconds, .gap))
            beat += Double(gapBeats)
        }
        return steps
    }

    private func stepFired(_ step: Step) {
        guard isRunning, !ended else { return }
        guard isTargetLive() else {
            end(.targetVanished)
            return
        }
        apply(step)
    }

    /// Realize one step's audibility. Mutes are written before unmutes so no
    /// boundary ever has both sides up for a beat.
    private func apply(_ step: Step) {
        let targetAudible: Bool
        let referenceAudible: Bool
        switch step {
        case .preamble:        (targetAudible, referenceAudible) = (true, true)
        case .referenceBlock:  (targetAudible, referenceAudible) = (false, true)
        case .targetBlock:     (targetAudible, referenceAudible) = (true, false)
        case .gap:             (targetAudible, referenceAudible) = (false, false)
        }
        if !targetAudible { write(muted: true, to: [targetDeviceID]) }
        if !referenceAudible { write(muted: true, to: referenceDeviceIDs) }
        if targetAudible { write(muted: false, to: [targetDeviceID]) }
        if referenceAudible { write(muted: false, to: referenceDeviceIDs) }
    }

    private func write(muted: Bool, to ids: [String]) {
        for id in ids where appliedMuted[id] != muted {
            appliedMuted[id] = muted
            setMuted(id, muted)
        }
    }

    /// The one exit path. Restores every mute this run touched to what it was
    /// at `start()`, switches the tick off, and fires `onEnd` once.
    private func end(_ outcome: Outcome) {
        guard !ended else { return }
        ended = true
        isRunning = false
        setTick(false)
        for (id, wasMuted) in priorMuted.sorted(by: { $0.key < $1.key })
        where appliedMuted[id] != nil && appliedMuted[id] != wasMuted {
            setMuted(id, wasMuted)
        }
        appliedMuted.removeAll()
        onEnd?(outcome)
    }
}
