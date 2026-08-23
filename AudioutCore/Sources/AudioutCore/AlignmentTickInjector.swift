// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// What shape of align-tick run a caller wants (W2) — the public vocabulary
/// the ``CaptureControlling`` seam speaks so the injector's numeric ``AlignmentTickInjector/Config``
/// stays internal. `.manual` is the row's metronome button; `.wizard` is the
/// alignment wizard's continuous run (long budget + keep-alive bed preamble).
public enum AlignTickMode: Equatable, Sendable {
    case off
    case manual
    case wizard
}

/// What the keep-alive under the ticks is made of — see
/// ``AlignmentTickInjector/Config/keepAliveKind``.
public enum KeepAliveKind: Equatable, Sendable {
    /// A ~20 Hz sine: inaudible on a speaker that cannot reproduce it, still a
    /// continuous signal to anything watching for silence. The default.
    case lowTone
    /// The original low-passed white-noise bed. Broadband, and audible as
    /// static for the whole run — kept only as the fallback if a Sonos turns
    /// out to gate on content it can actually reproduce.
    case noise
}

/// The align-by-ear aid's tick source (BT-OFFSET-UI): a synthesized
/// woodblock-style transient mixed INTO the whole-system capture's converted
/// PCM, post-capture, so every consumer of that one feed — the AirPlay engine,
/// the synced-local sink, and every Bluetooth sink — renders the SAME tick
/// through its own delay. That is what makes the alignment truthful: the user
/// nudges a device's SYNC trim until the flam between its tick and the rest of
/// the group collapses into one. Playing the tick out loud instead would never
/// work — the app's own render processes are tap-EXCLUDED by design (R-echo).
///
/// Beat spacing deliberately dodges offset aliasing: at 120 BPM (500 ms) a
/// fully-offset device (trim range is ±500 ms) sounds aligned exactly one beat
/// late, so the row's metronome runs at ~72 BPM (~833 ms). The WIZARD needs
/// more room still: while its coarse search is walking an unknown 150–700 ms
/// Bluetooth latency, an 833 ms beat aliases a 650 ms lag into an apparent
/// ~180 ms lead and the run converges a whole beat wrong. So the search stage
/// runs at ``wizardSearchBPM`` (one tick every 3 s — wider than any latency the
/// search can reach) and only the blocks stage, by which point the estimate is
/// inside ±24 ms, drops back to ``wizardBlocksBPM``.
///
/// The tick is SYNTHESIZED (two decaying sine partials with a near-instant
/// attack — a woodblock-shaped transient; the ear detects double-hits down to
/// ~10–20 ms), never a bundled audio file. The wizard renders TWO timbres off
/// one beat clock — a LOW knock for the engine/AirPlay + Mac fan-out and the
/// familiar bright click for the Bluetooth fan-out — so the two sides of the
/// judgement are told apart by colour, not only by order. Same onset instant
/// either way; only the partials differ.
///
/// Threading: created on the coordinator's control queue, then touched ONLY
/// from the tap delivery thread via the published `BufferSnapshot` — single
/// consumer, so the mutable cursor needs no lock. `mix` allocates nothing.
///
/// The injector self-limits: after ``Config/maxTicks`` beats (~30 s at the
/// default tempo) it stops emitting on its own, so a UI that forgets to switch
/// it off can only ever leak silence, not a metronome. The WIZARD is the
/// deliberate exception (``Config/unlimitedTicks``) — see ``Config/wizard``.
///
/// **Keep-alive bed** (live finding 2026-08-07): the Sonos Move power-gates
/// its amplifier after silence and swallows short transients — the first
/// ticks after a quiet stretch simply never come out of it. So while the
/// injector is active it also mixes a quiet keep-alive under the ticks, and
/// the wizard config prepends a bed-only wake preamble before the first tick.
/// The bed is necessarily ONE SHARED bed for every consumer: this injector
/// mixes into the single converted feed BEFORE the fan-outs, so per-device
/// uncorrelated beds are structurally impossible in this architecture —
/// acceptable at this level, because its only job is keeping the amps
/// powered. WHO gets it is a different question: on the Mac's own speakers,
/// which never power-gate, the bed is plain hiss and the live run heard it as
/// "heavy static" — so the wizard's pacer renders the block twice
/// (``mixWizardVariants(into:bedded:)``), bed for Bluetooth only.
///
/// The bed used to be low-passed white noise, and even Bluetooth-only that was
/// audible static for the whole run (live report, 2026-08-22). It is now a
/// ~20 Hz sine instead (``Config/keepAliveKind``): a Bluetooth speaker's driver
/// cannot reproduce 20 Hz audibly, while any digital silence gate still sees a
/// continuous signal. The noise bed is kept one static away
/// (``KeepAliveKind/noise``) in case the Move turns out to need broadband
/// content.
final class AlignmentTickInjector: @unchecked Sendable {

    /// ~30 s of ticks at 72 BPM.
    static let defaultMaxTicks = 36
    /// No self-limit at all — the wizard's budget (see ``Config/wizard``).
    static let unlimitedTicks = Int.max
    /// The wizard's coarse-search tempo: one tick every 3 s. Wide enough that
    /// no reachable Bluetooth latency can alias into an apparent lead.
    static let wizardSearchBPM: Double = 20
    /// The wizard's stimulus-block tempo — the estimate is inside ±24 ms by
    /// then, so the beat can close up to the metronome's own pace.
    static let wizardBlocksBPM: Double = 72

    /// One activation's shape. `.manual` is the row's metronome button
    /// (self-limits ~30 s, no preamble — the user clicked expecting a tick
    /// now); `.wizard` is the alignment wizard's continuous run (NO budget —
    /// the session turns it off on every exit path — plus the ~3 s wake
    /// preamble so the first QUESTION tick lands on already-awake amps).
    ///
    /// The wizard's budget used to be 360 beats ≈ 303 s, and a run that ran
    /// past it went dead silent with the panel still asking questions (live
    /// report, 2026-08-22): `mix` stopped emitting, the pacer kept publishing
    /// silent blocks, and the captured feed stayed gated off behind
    /// `wizardActive`. A wall-clock ceiling on a user-paced questionnaire is
    /// the wrong shape — the session's exit paths are the ONE switch-off.
    struct Config: Equatable, Sendable {
        var bpm: Double = 72
        var maxTicks: Int = AlignmentTickInjector.defaultMaxTicks
        /// Whether ticks are audible from the first frame. `.manual` is armed
        /// at birth — the user clicked expecting a tick now. The WIZARD is not:
        /// it opens on bed/silence and the backend arms it (``armTicks()``)
        /// only once every participating sink has actually released, so the
        /// first audible tick is a true pair on every speaker instead of the
        /// Mac ticking alone while a Bluetooth engine is still coming up.
        var armedAtStart: Bool = true
        var bedEnabled: Bool = true
        /// REPLACE the captured program instead of adding to it — the wizard
        /// run only (owner's call): while the user is judging which speaker
        /// ticked first, music underneath is what they are trying to hear
        /// past. `.manual` stays additive because that IS the nudge-while-
        /// listening case. Replacement ends with the tick budget, so the
        /// music comes back the instant the run stops.
        var replacesProgram: Bool = false

        /// Which keep-alive rides under the ticks. ONE line flips the whole
        /// app back to the broadband bed if a Sonos turns out to need it.
        static let keepAliveKind: KeepAliveKind = .lowTone

        /// The noise bed's target RMS (``KeepAliveKind/noise`` only). −47 dBFS:
        /// measured comfortably below music/ticks, still enough to defeat the
        /// Move's amp gate.
        static let bedRMSdBFS: Double = -47

        /// The keep-alive tone (``KeepAliveKind/lowTone``). 20 Hz is below what
        /// a portable speaker's driver can put in the room, so the run is
        /// silent between ticks, while −40 dBFS RMS is well clear of any
        /// "is this stream silent" threshold a device might apply.
        ///
        /// UNVALIDATED ON HARDWARE: nobody has yet confirmed that a Sonos Move
        /// keeps its amp awake on a 20 Hz tone, only that the noise bed did.
        /// If a live run shows the first tick after a quiet stretch swallowed
        /// again, set ``keepAliveKind`` back to ``KeepAliveKind/noise``.
        static let toneHz: Double = 20
        static let toneRMSdBFS: Double = -40

        static let manual = Config()
        static let wizard = Config(bpm: AlignmentTickInjector.wizardSearchBPM,
                                   maxTicks: AlignmentTickInjector.unlimitedTicks,
                                   armedAtStart: false, replacesProgram: true)
    }

    private let sampleRate: Double
    /// Pacer-queue-confined once a run is under way (``setTempo(bpm:)``), like
    /// `cursor` and `tickEpochFrame`: the wizard pacer is the single consumer.
    private var beatFrames: Int
    private let channels: Int
    private let maxTicks: Int
    /// One past the last frame this injector emits into — `Int.max` when the
    /// budget is unlimited, which is also why it is computed once instead of
    /// multiplied out on every block.
    private let endFrame: Int
    private let replacesProgram: Bool
    /// The pre-rendered mono ticks, added to every channel: the bright click
    /// (1.8 + 2.9 kHz) the metronome has always used, and the low knock
    /// (0.9 + 1.45 kHz) the wizard gives the engine/Mac side.
    private let brightTick: [Int32]
    private let lowTick: [Int32]
    /// Pre-rendered mono keep-alive loop (empty when the bed is disabled).
    private let bed: [Int32]
    /// Frames consumed since injection began — tap-delivery-thread-only, or
    /// pacer-queue-only under the wizard.
    private var cursor = 0
    /// The frame the beat grid starts on; `-1` until ``armTicks()`` runs. Beat
    /// phase is a pure function of it, so both wizard variants render the same
    /// onset from the same block and a re-render is free of side effects.
    private var tickEpochFrame: Int

    init(sampleRate: Double = 44_100,
         channels: Int = 2,
         config: Config = .manual,
         amplitude: Double = 0.35) {
        self.sampleRate = sampleRate
        self.beatFrames = max(1, Int((sampleRate * 60.0 / config.bpm).rounded()))
        self.channels = max(1, channels)
        self.maxTicks = config.maxTicks
        self.tickEpochFrame = config.armedAtStart ? 0 : -1
        self.replacesProgram = config.replacesProgram
        self.bed = config.bedEnabled ? Self.renderBed(sampleRate: sampleRate) : []
        // Only the fixed-tempo `.manual` config has a finite budget, so
        // computing this once against the OPENING beat length stays exact —
        // ``setTempo(bpm:)`` belongs to the unlimited wizard run alone.
        self.endFrame = config.maxTicks == Self.unlimitedTicks
            ? Int.max
            : config.maxTicks * self.beatFrames

        self.brightTick = Self.renderTick(sampleRate: sampleRate, amplitude: amplitude,
                                          partialHz: (1_800, 2_900))
        self.lowTick = Self.renderTick(sampleRate: sampleRate, amplitude: amplitude,
                                       partialHz: (900, 1_450))
    }

    /// Woodblock-ish transient: ~30 ms, two partials, exponential decay
    /// (τ ≈ 6 ms), with a handful of attack samples ramped so the onset is
    /// sharp but not a raw DC step. Both timbres come off this ONE envelope
    /// family and the same frame count, so their onsets are sample-identical
    /// and only the colour differs.
    private static func renderTick(sampleRate: Double, amplitude: Double,
                                   partialHz: (Double, Double)) -> [Int32] {
        let frames = Int(sampleRate * 0.03)
        let tau = 0.006
        let attackFrames = 8
        var rendered = [Int32](repeating: 0, count: frames)
        for f in 0..<frames {
            let t = Double(f) / sampleRate
            let envelope = exp(-t / tau) * (f < attackFrames ? Double(f) / Double(attackFrames) : 1)
            let partials = 0.7 * sin(2 * .pi * partialHz.0 * t)
                + 0.3 * sin(2 * .pi * partialHz.1 * t)
            rendered[f] = Int32((amplitude * envelope * partials * 32_767.0).rounded())
        }
        return rendered
    }

    // MARK: Wizard run control (pacer-queue only)

    /// Start the beat grid here, with the FIRST tick one whole interval away —
    /// not at the top of the next rendered block. The arm point is wherever the
    /// gate happened to open, so a tick placed on it can land a few ms after the
    /// previous run's last one, overlapping two 30 ms tick bodies into one
    /// ambiguous smear. A full interval of silence first makes the opening tick
    /// a clean pair on every speaker. Called once per wizard run, after every
    /// participating sink has released. Idempotent: a second call would restart
    /// the phase, which the arm gate never wants.
    func armTicks() {
        guard tickEpochFrame < 0 else { return }
        tickEpochFrame = cursor + beatFrames
    }

    /// Change the beat interval mid-run (search → blocks). The grid is
    /// re-derived from the LAST TICK ALREADY LAID DOWN, so the next one is a
    /// full NEW interval after it and can never crowd the tick the user has
    /// just heard — at the search → blocks handover the intervals differ by
    /// seconds, and re-deriving from the bare cursor put the next tick ~20 ms
    /// behind the previous one. Inert before the arm.
    func setTempo(bpm: Double) {
        let frames = max(1, Int((sampleRate * 60.0 / bpm).rounded()))
        guard frames != beatFrames else { return }
        guard tickEpochFrame >= 0 else {
            beatFrames = frames
            return
        }
        // Armed but still inside the opening interval: no tick has been heard
        // yet, so "one interval after the last tick" is measured from HERE.
        let lastTickFrame = cursor >= tickEpochFrame
            ? tickEpochFrame + ((cursor - tickEpochFrame) / beatFrames) * beatFrames
            : cursor
        beatFrames = frames
        tickEpochFrame = lastTickFrame + frames
    }

    /// The keep-alive loop, whichever kind ``Config/keepAliveKind`` selects.
    /// Both are LOOP TABLES indexed by the absolute frame position in
    /// ``render(into:from:tick:bed:replace:)``, which is what makes them
    /// continuous across block boundaries for free. That indexing — rather
    /// than a phase carried in a stored property — is load-bearing here:
    /// ``mixWizardVariants(into:bedded:)`` renders the SAME frames twice off
    /// one cursor advance, and a stored phase would advance on both passes.
    private static func renderBed(sampleRate: Double) -> [Int32] {
        switch Config.keepAliveKind {
        case .lowTone: return renderKeepAliveTone(sampleRate: sampleRate)
        case .noise: return renderNoiseBed(sampleRate: sampleRate)
        }
    }

    /// EXACTLY one cycle of a ~``Config/toneHz`` sine at ``Config/toneRMSdBFS``
    /// RMS. One whole cycle is what makes the loop seamless at any sample rate
    /// (the table's own wrap IS the sine's wrap, so the step across a boundary
    /// is the same step as anywhere else) and DC-free (a whole cycle sums to
    /// zero). The frequency lands on the nearest rate that divides the sample
    /// rate into a whole number of frames — a fraction of a hertz off 20, which
    /// changes nothing about either property.
    private static func renderKeepAliveTone(sampleRate: Double) -> [Int32] {
        let frames = max(2, Int((sampleRate / Config.toneHz).rounded()))
        let peak = pow(10, Config.toneRMSdBFS / 20) * 2.0.squareRoot()
        return (0..<frames).map { f in
            Int32((peak * sin(2 * .pi * Double(f) / Double(frames)) * 32_767.0).rounded())
        }
    }

    /// The broadband bed: white noise through a one-pole low-pass
    /// (fc ≈ 800 Hz — a soft hiss, no crackle), normalized to
    /// ``Config/bedRMSdBFS`` RMS. Deterministically seeded so tests can assert
    /// exact output; ~0.75 s loop, long enough that the repeat is not a pitch.
    private static func renderNoiseBed(sampleRate: Double) -> [Int32] {
        let frames = max(1, Int(sampleRate * 0.75))
        let alpha = 1 - exp(-2 * .pi * 800 / sampleRate)
        var rng: UInt64 = 0x9E3779B97F4A7C15
        var filtered = 0.0
        var raw = [Double](repeating: 0, count: frames)
        var sumSquares = 0.0
        for f in 0..<frames {
            // SplitMix64 — cheap, deterministic, no Foundation RNG state.
            rng &+= 0x9E3779B97F4A7C15
            var z = rng
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            z ^= z >> 31
            let white = Double(z >> 11) / Double(1 << 53) * 2 - 1
            filtered += alpha * (white - filtered)
            raw[f] = filtered
            sumSquares += filtered * filtered
        }
        let rms = (sumSquares / Double(frames)).squareRoot()
        let targetRMS = pow(10, Config.bedRMSdBFS / 20)
        let scale = rms > 0 ? targetRMS / rms : 0
        return raw.map { Int32(($0 * scale * 32_767.0).rounded()) }
    }

    /// Mix the bed + tick into one converted S16LE interleaved buffer in place.
    /// Native-endian Int16 math is correct here: the airplay PCM format is
    /// little-endian and so is every Apple-silicon/Intel Mac this runs on.
    /// Ticks start once the grid is armed and stop after `maxTicks` beats; the
    /// bed stops with them, so an expired injector adds nothing.
    ///
    /// Under ``Config/replacesProgram`` the captured content is OVERWRITTEN for
    /// the run's frames rather than summed, so the fan-out carries ticks and
    /// bed alone. Frames past the budget are left untouched by the same
    /// `endFrame` bound the additive path uses — that, and dropping the
    /// injector, are the two ways the music comes back.
    func mix(into pcm: inout Data) {
        cursor += render(into: &pcm, from: cursor, tick: brightTick, bed: !bed.isEmpty,
                         replace: replacesProgram)
    }

    /// The wizard pacer's two-variant render. `pcm` comes back with the LOW
    /// KNOCK and no bed — the Mac's own speakers never power-gate, so there is
    /// nothing there for a keep-alive to hold awake and the run stays clean
    /// whatever ``Config/keepAliveKind`` is set to (live report, 2026-08-22:
    /// the noise bed reached the Mac as plain hiss). `bedded` carries the
    /// BRIGHT CLICK plus the keep-alive, for the Bluetooth fan-out whose amps
    /// it exists for.
    ///
    /// Two timbres, ONE beat grid: both renders read the same `start` and the
    /// same `tickEpochFrame`, so the onsets are sample-identical and the
    /// question stays "which side first", never "which side louder". ONE cursor
    /// advance covers both, which keeps the pacer the single consumer of this
    /// injector's lock-free cursor.
    func mixWizardVariants(into pcm: inout Data, bedded: inout Data) {
        let start = cursor
        // Rendered from the SAME source block, not from the finished tick-only
        // one: the two variants carry different ticks, so one cannot be built
        // by adding to the other.
        var beddedBlock = pcm
        let frames = render(into: &pcm, from: start, tick: lowTick, bed: false,
                            replace: replacesProgram)
        _ = render(into: &beddedBlock, from: start, tick: brightTick, bed: !bed.isEmpty,
                   replace: replacesProgram)
        bedded = beddedBlock
        cursor += frames
    }

    /// The one mixing loop. Returns the frame count it walked, so the caller
    /// owns the cursor — ``mixWizardVariants(into:bedded:)`` renders the same
    /// frames twice and advances once.
    private func render(into pcm: inout Data, from start: Int,
                        tick tickTable: [Int32]?, bed useBed: Bool, replace: Bool) -> Int {
        let bytesPerFrame = channels * MemoryLayout<Int16>.size
        guard bytesPerFrame > 0 else { return 0 }
        let frameCount = pcm.count / bytesPerFrame
        guard frameCount > 0, start < endFrame else { return frameCount }
        pcm.withUnsafeMutableBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for f in 0..<frameCount {
                let position = start + f
                guard position < endFrame else { break }
                var add: Int32 = 0
                if useBed, !bed.isEmpty { add = bed[position % bed.count] }
                if let tickTable, tickEpochFrame >= 0, position >= tickEpochFrame {
                    let phase = (position - tickEpochFrame) % beatFrames
                    if phase < tickTable.count { add += tickTable[phase] }
                }
                if replace {
                    for ch in 0..<channels {
                        samples[f * channels + ch] = Int16(clamping: add)
                    }
                    continue
                }
                guard add != 0 else { continue }
                for ch in 0..<channels {
                    let idx = f * channels + ch
                    samples[idx] = Int16(clamping: Int32(samples[idx]) + add)
                }
            }
        }
        return frameCount
    }

    // MARK: Test seams (pure reads)

    var test_beatFrames: Int { beatFrames }
    var test_tickFrameCount: Int { brightTick.count }
    var test_maxTicks: Int { maxTicks }
    var test_isArmed: Bool { tickEpochFrame >= 0 }
    var test_bedFrameCount: Int { bed.count }
}
