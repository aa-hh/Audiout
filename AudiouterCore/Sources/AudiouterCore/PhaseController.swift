// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 ahh and contributors.

import Foundation

/// T-CORRECTION — the continuous phase-lock DSP for ``SyncedLocalSink``.
///
/// Two pure, hardware-free pieces, split out of `SyncedLocalSink` so they are
/// unit-testable with SYNTHETIC clock drift — no `AVAudioEngine`, no real output
/// device, no sound (plan T-CORRECTION / T-TESTS):
///
///  - ``FractionalResampler`` — a 4-tap cubic (Catmull-Rom) streaming resampler
///    that reads the sink's ring at a variable rate of `1 ± ppm` input frames per
///    output frame. This is the mechanism T-SPIKE-PHASE validated
///    (`dev/notes/phase-lock-spike-findings.md` §4/§5, prototype in
///    `dev/phase-spike/Sources/phase-spike/ResamplerProbe.swift`): custom resampler
///    in the render block, NOT `AVAudioUnitVarispeed` (fixed 1 ms latency) and NOT
///    `AVAudioUnitTimePitch` (an unsuitable phase vocoder). Sample-accurate, zero
///    added AU latency, arbitrary ppm resolution via a `Double` phase accumulator,
///    click-free under a continuous sweep to the ±200 ppm the spike measured.
///
///  - ``PhaseController`` — a PI (proportional-integral) control loop that nulls
///    the per-cycle residual phase error to ~zero and drives the resampler's rate.
///
/// Both are real-time-safe: no allocation and no locks on the methods the render
/// block calls (``FractionalResampler/render(into:outFrameOffset:outFrames:ratio:pullFrame:)``
/// and ``PhaseController/update(phaseErrorNanos:nsPerFrame:)``). They are touched
/// only by the single render (consumer) thread while streaming, and reset only
/// while the engine is stopped, so they need no synchronization of their own —
/// the same single-consumer contract the ring read already relies on.

// MARK: - FractionalResampler

/// A streaming 4-point cubic (Catmull-Rom) fractional resampler.
///
/// The math is ported verbatim from the validated spike prototype
/// (`ResamplerProbe.cubic`): for an interpolation position with fractional part
/// `frac ∈ [0, 1)` bracketed by taps `d1` (the sample at the integer position) and
/// `d2` (the next), with `d0`/`d3` the neighbours on either side,
///
/// ```
/// a = -0.5·d0 + 1.5·d1 - 1.5·d2 + 0.5·d3
/// b =  d0     - 2.5·d1 + 2.0·d2 - 0.5·d3
/// c = -0.5·d0          + 0.5·d2
/// out = ((a·frac + b)·frac + c)·frac + d1
/// ```
///
/// Streaming form: a 4-sample shift register per channel plus a `Double` phase
/// accumulator. Each output frame interpolates at the current `frac`, then advances
/// `frac += ratio`; every time `frac` crosses an integer the register shifts left
/// and pulls one fresh input frame. `ratio` is the input frames consumed per output
/// frame (`1 ± ppm`), so `ratio > 1` plays the buffered audio slightly FAST (catch
/// up), `ratio < 1` slightly slow (fall back).
///
/// Priming detail that keeps the release sample-exact: the register is seeded with
/// `d0 = 0` (no history before the first buffered sample — a linear/constant ramp's
/// implicit `x[-1]` is 0 anyway) and `d1/d2/d3` = the first three input frames, with
/// `frac = 0`. At `frac = 0` the cubic collapses to exactly `d1`, so the very first
/// emitted sample is bit-exactly input frame 0 regardless of `ratio`, and at a
/// constant `ratio == 1.0` the whole resampler is a bit-exact pass-through.
final class FractionalResampler {

    private let channelCount: Int
    /// `5 · channelCount` floats: taps `d0..d3` at `[t·cc + ch]` for `t ∈ 0...3`,
    /// plus a one-frame pull scratch at `t == 4` so an underrun mid-shift leaves the
    /// register untouched (clean resume) instead of half-rotated.
    private let taps: UnsafeMutablePointer<Float>
    private var frac: Double = 0
    private var primed = false

    /// Cumulative count of real input frames pulled from the ring since the last
    /// ``reset()``.
    private(set) var inputFramesConsumed: Int64 = 0

    /// The CONTINUOUS content position (in input-frame units) of the next output
    /// sample — what the phase-error estimate must use, NOT the integer
    /// ``inputFramesConsumed`` (which jumps by 1 at each interpolation-window shift
    /// and would inject a ±½-frame sawtooth the control loop could never null below).
    ///
    /// The interpolation reads tap `d1`, whose absolute input index is
    /// `inputFramesConsumed − 3` (d3 is the newest pulled frame at
    /// `inputFramesConsumed − 1`), offset by the fractional phase `frac`. So the
    /// smooth position is `(inputFramesConsumed − 3) + frac`. At the release cycle
    /// (`primed == false`, nothing emitted yet) it is 0, so the first phase-error
    /// reading reduces exactly to the old one-shot `firstRealNanos − target`. The
    /// constant `−3` is a fixed read-ahead the loop absorbs, not a drift.
    var consumedContentFrames: Double {
        primed ? Double(inputFramesConsumed) - 3.0 + frac : 0
    }

    init(channelCount: Int) {
        let cc = max(1, channelCount)
        self.channelCount = cc
        self.taps = UnsafeMutablePointer<Float>.allocate(capacity: 5 * cc)
        self.taps.initialize(repeating: 0, count: 5 * cc)
    }

    deinit { taps.deallocate() }

    /// Return the register to its unprimed, zeroed state. Called only while the
    /// engine is stopped (session teardown / lifecycle rebuild), never concurrently
    /// with ``render(into:outFrameOffset:outFrames:ratio:pullFrame:)``.
    func reset() {
        taps.update(repeating: 0, count: 5 * channelCount)
        frac = 0
        primed = false
        inputFramesConsumed = 0
    }

    /// Produce up to `outFrames` interleaved output frames into
    /// `out[(outFrameOffset + i)·channelCount ...]`, consuming input frames via
    /// `pullFrame` at an average rate of `ratio` input frames per output frame.
    ///
    /// `pullFrame` must fill `channelCount` contiguous samples for one input frame
    /// and return `false` when the ring is empty. Returns the number of output
    /// frames actually produced — fewer than `outFrames` only on a ring underrun,
    /// in which case the register state is preserved so the next cycle resumes
    /// seamlessly once data is available again; the caller zero-fills the shortfall.
    ///
    /// Real-time-safe: no allocation, no locks. `pullFrame` is non-escaping.
    @discardableResult
    func render(
        into out: UnsafeMutableBufferPointer<Float>,
        outFrameOffset: Int,
        outFrames: Int,
        ratio: Double,
        pullFrame: (UnsafeMutablePointer<Float>) -> Bool
    ) -> Int {
        guard let base = out.baseAddress, outFrames > 0 else { return 0 }
        let cc = channelCount
        // Hard structural clamp: the controller keeps `ratio` within ~1 ± 200 ppm,
        // but never let a wild value make the phase accumulator step backwards or
        // consume unboundedly per output frame.
        let r = min(2.0, max(0.5, ratio))
        let d0 = taps, d1 = taps + cc, d2 = taps + 2 * cc, d3 = taps + 3 * cc
        let scratch = taps + 4 * cc

        var produced = 0
        outer: for o in 0..<outFrames {
            if !primed {
                // Seed d0 = 0 (implicit pre-start history) and d1/d2/d3 with the
                // first three input frames. Only mark primed once all three land, so
                // a (near-impossible, given the seconds of pre-roll) prime-time
                // underrun just retries next cycle.
                for ch in 0..<cc { d0[ch] = 0 }
                if !pullFrame(d1) { break }
                inputFramesConsumed &+= 1
                if !pullFrame(d2) { break }
                inputFramesConsumed &+= 1
                if !pullFrame(d3) { break }
                inputFramesConsumed &+= 1
                primed = true
                frac = 0
            }

            // Advance the interpolation window BEFORE interpolating, so `frac` is
            // always in [0, 1) at the read. Pull into scratch first and only rotate
            // on success, so a ring underrun leaves the window and `frac` untouched
            // for a seamless resume next cycle (no extrapolation past the taps).
            while frac >= 1.0 {
                if !pullFrame(scratch) { break outer }
                for ch in 0..<cc {
                    d0[ch] = d1[ch]; d1[ch] = d2[ch]; d2[ch] = d3[ch]; d3[ch] = scratch[ch]
                }
                inputFramesConsumed &+= 1
                frac -= 1.0
            }

            let f = Float(frac)
            let dst = base + (outFrameOffset + o) * cc
            for ch in 0..<cc {
                let x0 = d0[ch], x1 = d1[ch], x2 = d2[ch], x3 = d3[ch]
                let a = -0.5 * x0 + 1.5 * x1 - 1.5 * x2 + 0.5 * x3
                let b = x0 - 2.5 * x1 + 2.0 * x2 - 0.5 * x3
                let c = -0.5 * x0 + 0.5 * x2
                dst[ch] = ((a * f + b) * f + c) * f + x1
            }
            produced += 1
            frac += r
        }
        return produced
    }
}

// MARK: - PhaseController

/// A slew-limited PI (proportional-integral) controller that drives
/// ``FractionalResampler``'s rate to null the local sink's residual phase error.
///
/// Input each render cycle: the signed phase error in nanoseconds — the difference
/// between where the local output's content position IS and where the reference
/// timeline says it SHOULD be (`> 0` ⇒ the local output is BEHIND and must speed
/// up). Output: a rate correction in ppm, consumed as `ratio = 1 + ppm·1e-6`.
///
/// ## Why PI, and how the gains were chosen
/// The plant is a discrete integrator: per cycle the content position advances by
/// `N·(1 + ppm·1e-6)` frames while the reference advances by `N·(1 + skew)` frames,
/// so `Δ(phaseError) = N·1e-6·(skew_ppm − ppm)`. A pure-P loop would leave a
/// steady-state error under a constant ppm clock skew (`e* = skew/Kp`); the integral
/// term is what pulls a CONSTANT drift to a true zero residual — which is the
/// explicit T-CORRECTION target (hold `latestPhaseErrorNanos` near zero
/// indefinitely, not just small once at release: every AirPlay receiver disciplines
/// its clock to us as PTP grandmaster, so there is no physical floor to nulling the
/// electronic-boundary phase error continuously).
///
/// Working in error-FRAMES (ns ÷ ns-per-frame) makes the gains sample-rate
/// independent. With the loop gain `β = N·1e-6` (`N` = frames/cycle), the
/// closed-loop poles are real (non-oscillatory, no overshoot) when
/// `Ki ≤ β·Kp²/4`. The defaults sit comfortably inside that bound for the ~512-frame
/// device buffer this runs against:
///  - `Kp = 150 ppm/frame` — a 1-frame error commands ~150 ppm (well within the
///    ±200 ppm click-free band the spike validated); a sub-frame residual commands
///    proportionally less.
///  - `Ki = 2.0 ppm/frame` — below the `β·Kp²/4 ≈ 2.88` critical bound at N = 512,
///    so the step response is over-damped (monotonic, no ringing).
///  - `maxPpm = 200` — clamp to the spike's validated click-free correction range.
///  - `slewPpmPerCycle = 25` — a startup transient can't step the rate audibly;
///    reaches full range in ~8 cycles (~85 ms at 512/48 k).
///
/// Anti-windup: the integrator is clamped so `Ki·integral` alone can't exceed
/// `maxPpm`, so it can't wind up during a slew-limited or clamped transient.
final class PhaseController {

    let kpPpmPerFrame: Double
    let kiPpmPerFrame: Double
    let maxPpm: Double
    let slewPpmPerCycle: Double
    private let integralMaxFrames: Double

    private var integralFrames: Double = 0
    /// The current correction (ppm). `ratio = 1 + correctionPpm·1e-6`.
    private(set) var correctionPpm: Double = 0

    init(
        kpPpmPerFrame: Double = 150,
        kiPpmPerFrame: Double = 2.0,
        maxPpm: Double = 200,
        slewPpmPerCycle: Double = 25
    ) {
        self.kpPpmPerFrame = kpPpmPerFrame
        self.kiPpmPerFrame = kiPpmPerFrame
        self.maxPpm = maxPpm
        self.slewPpmPerCycle = slewPpmPerCycle
        self.integralMaxFrames = kiPpmPerFrame > 0 ? maxPpm / kiPpmPerFrame : 0
    }

    /// Zero the integrator and correction. Called on session teardown / lifecycle
    /// rebuild, alongside ``FractionalResampler/reset()``.
    func reset() {
        integralFrames = 0
        correctionPpm = 0
    }

    /// The rate to hand the resampler this cycle: `1 + correctionPpm·1e-6`.
    var ratio: Double { 1.0 + correctionPpm * 1e-6 }

    /// Advance the loop one render cycle with the measured phase error and return
    /// the new correction (ppm). Real-time-safe: scalar math only, no allocation,
    /// no locks.
    @discardableResult
    func update(phaseErrorNanos: Double, nsPerFrame: Double) -> Double {
        let errorFrames = nsPerFrame > 0 ? phaseErrorNanos / nsPerFrame : 0

        integralFrames += errorFrames
        integralFrames = min(integralMaxFrames, max(-integralMaxFrames, integralFrames))

        var ppm = kpPpmPerFrame * errorFrames + kiPpmPerFrame * integralFrames
        ppm = min(maxPpm, max(-maxPpm, ppm))

        // Slew-limit the change per cycle so a startup step can't jump the rate.
        let lo = correctionPpm - slewPpmPerCycle
        let hi = correctionPpm + slewPpmPerCycle
        ppm = min(hi, max(lo, ppm))

        correctionPpm = ppm
        return ppm
    }
}
