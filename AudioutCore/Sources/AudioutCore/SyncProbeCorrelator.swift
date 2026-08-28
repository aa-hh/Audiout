// Copyright (C) 2026 ahh and contributors.
//
// LICENSE-CLEAN by design (PLAN-UNIVERSAL-SYNC Decision 5 lineage): this file
// carries NO GPL SPDX header, unlike most siblings. Everything in it is probe
// synthesis and matched-filter math ORIGINAL to this project, written from the
// published literature (Farina's exponential sine sweep; SNR-weighted
// cross-correlation), so the Apple-only Bluetooth path can share it. Do not add
// a GPL header to this file, and do not move GPL-derived code into it.

import Accelerate
import Foundation

// MARK: - SyncProbe

/// Synthesis for the microphone-based sync calibration probe (the
/// mic-measurement tier above the by-ear wizard, dev/notes brief
/// `mic-probe-calibration-brief.md`).
///
/// The probe is an exponential sine sweep: constant amplitude, frequency
/// rising (or falling) exponentially between two band edges. Its virtue for
/// this job is the time–bandwidth product — a one-second sweep concentrates
/// 30–40 dB of processing gain into one correlation peak, so a probe played
/// quietly under real room noise still yields an unambiguous arrival time.
///
/// **The two lanes occupy DISJOINT bands, and that separation is what lets
/// both speakers play at once.** Opposite sweep DIRECTIONS over a shared band
/// are not enough: measured, an up sweep and a down sweep across 500 Hz–10 kHz
/// cross-correlate only ~33 dB down. The recording comes from the Mac's own
/// built-in microphone, so the Mac's own speakers are inches away while the
/// other speaker is across the room — a level imbalance of 23 dB in the live
/// 2026-08-28 capture. The loud lane's leakage then sits ABOVE the quiet
/// lane's true peak, and every measurement is refused for want of confidence
/// while both sweeps are plainly audible. Disjoint bands share no bins at all
/// (measured cross-correlation −134 dB), so the tolerable imbalance stops
/// being a probe property and becomes the room's own noise floor — 53 dB for
/// the distant speaker in that same capture. Keep the GUARD GAP between the
/// two bands when tuning them; abutting edges lose most of the isolation.
///
/// The quiet, distant lane gets the HIGH band: room noise is dominated by
/// low-frequency rumble, and that same capture measured its noise floor 12 dB
/// lower above 3 kHz — worth more than the extra air absorption up there.
///
/// The band edges deliberately stay inside 500 Hz–10 kHz: small speakers roll
/// off below a few hundred Hz, and A2DP codecs commonly roll off above
/// 14–18 kHz, so probe energy parked outside this band would be spent where
/// the physical path may silently drop it.
public enum SyncProbe {

    /// One sweep's parameters. `startHz > endHz` is legal and produces the
    /// DOWN sweep; both edges must be positive and distinct.
    public struct SweepDesign: Equatable, Sendable {
        public var sampleRate: Double
        public var startHz: Double
        public var endHz: Double
        public var duration: Double
        /// Raised-cosine fade applied at both ends, so the probe starts and
        /// ends without a click that would smear the correlation peak (and
        /// annoy the listener).
        public var fadeDuration: Double

        /// The Bluetooth lane — the one heard from across the room, hence the
        /// high band (see the type note).
        public static func upSweep(sampleRate: Double, duration: Double = 1.0) -> SweepDesign {
            SweepDesign(sampleRate: sampleRate, startHz: 3_200, endHz: 10_000,
                        duration: duration, fadeDuration: 0.01)
        }

        /// The engine/Mac lane — nearest the microphone, so it takes the low
        /// band and its noisier floor.
        public static func downSweep(sampleRate: Double, duration: Double = 1.0) -> SweepDesign {
            SweepDesign(sampleRate: sampleRate, startHz: 2_000, endHz: 500,
                        duration: duration, fadeDuration: 0.01)
        }
    }

    /// The sweep's instantaneous value at time `t` seconds from its own start,
    /// fades included, zero outside `[0, duration)`. Exposed separately from
    /// ``samples(_:)`` so tests can render a FRACTIONALLY delayed arrival
    /// analytically instead of resampling one.
    public static func value(_ design: SweepDesign, at t: Double) -> Double {
        guard t >= 0, t < design.duration else { return 0 }
        let ratio = design.endHz / design.startHz
        let lnRatio = log(ratio)
        // phase(t) = 2π·f₀·T/ln r · (e^(t·ln r / T) − 1)  — Farina's sweep.
        let k = 2 * Double.pi * design.startHz * design.duration / lnRatio
        let phase = k * (exp(t / design.duration * lnRatio) - 1)
        var sample = sin(phase)
        let fade = min(design.fadeDuration, design.duration / 2)
        if fade > 0 {
            let fromStart = t
            let fromEnd = design.duration - t
            if fromStart < fade {
                sample *= 0.5 - 0.5 * cos(.pi * fromStart / fade)
            }
            if fromEnd < fade {
                sample *= 0.5 - 0.5 * cos(.pi * fromEnd / fade)
            }
        }
        return sample
    }

    /// The sweep rendered at its design sample rate.
    public static func samples(_ design: SweepDesign) -> [Float] {
        precondition(design.startHz > 0 && design.endHz > 0 && design.startHz != design.endHz,
                     "an exponential sweep needs two positive, distinct band edges")
        let count = Int((design.duration * design.sampleRate).rounded())
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            out[i] = Float(value(design, at: Double(i) / design.sampleRate))
        }
        return out
    }
}

// MARK: - SyncProbeCorrelator

/// Offline matched filter: where, in a mic recording, does each known probe
/// arrive — and how far apart are two arrivals.
///
/// The whole calibration rests on one cancellation (the BeepBeep observation):
/// one microphone hears both speakers, so the Mac's capture latency and the
/// probes' shared scheduled start are common to both arrivals and drop out of
/// the DIFFERENCE. What survives is the per-speaker output latency difference
/// plus the speakers' distance asymmetry to the mic (~2.9 ms per metre).
///
/// Weighting is SNR-aware, not PHAT: when the caller supplies an ambient-noise
/// segment (a lead-in slice of the same recording, before the probes start),
/// correlation bins are divided by the measured noise power spectrum, so a
/// tonal interferer (a hum, a voice) is discounted instead of being whitened
/// up to equal vote. PHAT-style whitening is deliberately absent — it throws
/// away per-band SNR, which is exactly the information a noisy party room
/// needs (the 2026 TDOA-probing result: trained estimators learn
/// magnitude-aware weighting and never learn PHAT).
///
/// **Confidence is measured against the background's EXPECTED largest lag,
/// never its observed one.** The observed maximum is one sample out of a
/// quarter-million, and in any real room the arrival's own reverb tail owns
/// it: the live 2026-08-28 captures put that tail 5% of peak height, so a
/// flawless arrival scored 19 where its honest floor said 3824 — a 46 dB
/// understatement, handed to a gate. Reverb is not evidence against the peak
/// it is an echo of. So the background is summarised ROBUSTLY — a median,
/// which a few percent of contaminated lags cannot move — and scaled to the
/// largest value that many Gaussian lags would be expected to reach. Pure
/// noise still scores ~1, because its best lag is exactly that expected best
/// lag; what changes is that a quiet-but-real arrival is no longer refused
/// for having echoed. Never reach for `max()` here, however natural it looks.
///
/// Everything here is pure and hardware-free; capture and probe playback live
/// elsewhere.
public struct SyncProbeCorrelator {

    public let sampleRate: Double

    public init(sampleRate: Double) { self.sampleRate = sampleRate }

    /// Correlation peaks below this peak-to-sidelobe ratio are rejected as
    /// "probe not found" — the recording's best match is not convincingly
    /// better than its own background. Pure noise scores ~1 by construction
    /// (its best lag IS the background's expected best lag); a real arrival
    /// at sane SNR runs to the hundreds.
    public var minPeakToSidelobe: Double = 5

    /// Background estimate excludes this much on either side of the peak, wide
    /// enough to cover the sweep autocorrelation's own skirt.
    public var sidelobeExclusionSeconds: Double = 0.005

    /// The background estimate also excludes this long AFTER the peak: a real
    /// room answers a probe with its reflections, so the correlation
    /// legitimately carries secondary peaks trailing the direct path — the
    /// impulse response's tail, not evidence against the measurement. Nothing
    /// physical arrives BEFORE the direct path, so the region ahead of the
    /// peak is honest background whatever the shadow's length.
    ///
    /// The shadow is a courtesy, not the guarantee: the estimator below is
    /// what actually makes reverb harmless.
    public var reverbShadowSeconds: Double = 0.25

    /// `median(|x|) = 0.6745 σ` for zero-mean Gaussian `x` — the constant that
    /// turns a robust median into a standard deviation.
    private static let medianOfHalfNormal = 0.674_489_750_196_081_7

    /// One probe's arrival in a recording.
    public struct Arrival: Equatable {
        /// Where the probe's first sample lands in the recording, in samples
        /// from the recording's start — fractional, via parabolic
        /// interpolation on the correlation peak.
        public var sampleOffset: Double
        /// Peak height over what the background outside the exclusion window
        /// is EXPECTED to reach: the measurement's own confidence statement.
        ///
        /// Expected, not observed — see ``SyncProbeCorrelator``'s note. The
        /// observed maximum is a single worst sample and a real room hands it
        /// to the arrival's own reverb, which reads as evidence against the
        /// very peak it came from.
        public var peakToSidelobe: Double
    }

    /// Two arrivals from one recording, reduced to the number the sync engine
    /// wants.
    public struct Measurement: Equatable {
        /// Arrival of `probeB` minus arrival of `probeA`, seconds. Positive
        /// means B sounded later.
        public var offsetSeconds: Double
        public var arrivalA: Arrival
        public var arrivalB: Arrival
    }

    /// Finds `probe` in `recording`, or nil when no convincing peak exists.
    /// `ambientNoise` is an optional probe-free slice of the same capture used
    /// to weight the correlation by measured noise (see the type note).
    public func arrival(of probe: [Float], in recording: [Float],
                 ambientNoise: [Float]? = nil) -> Arrival? {
        guard probe.count > 1, recording.count >= probe.count else { return nil }
        let corr = Self.correlate(recording: recording, probe: probe,
                                  ambientNoise: ambientNoise)
        let searchCount = recording.count - probe.count + 1
        guard searchCount > 0 else { return nil }

        var peakIndex = 0
        var peakValue = -Float.infinity
        for i in 0..<searchCount where corr[i] > peakValue {
            peakValue = corr[i]
            peakIndex = i
        }
        guard peakValue > 0 else { return nil }

        let exclusion = max(1, Int(sidelobeExclusionSeconds * sampleRate))
        let shadow = max(exclusion, Int(reverbShadowSeconds * sampleRate))
        var background: [Float] = []
        background.reserveCapacity(searchCount)
        for i in 0..<searchCount where i < peakIndex - exclusion || i > peakIndex + shadow {
            background.append(abs(corr[i]))
        }
        guard background.count > 1 else { return nil }
        background.sort()
        let sigma = Double(background[background.count / 2]) / Self.medianOfHalfNormal
        let sidelobe = (2 * log(Double(background.count))).squareRoot() * sigma
        let psr = sidelobe > 0 ? Double(peakValue) / sidelobe : .infinity
        guard psr >= minPeakToSidelobe else { return nil }

        // Parabola through the peak and its neighbours: the sweep's main lobe
        // spans several samples (≈ sampleRate / bandwidth), so three points
        // resolve the true maximum to a fraction of a sample.
        var offset = Double(peakIndex)
        if peakIndex > 0, peakIndex + 1 < searchCount {
            let cm = Double(corr[peakIndex - 1])
            let c0 = Double(corr[peakIndex])
            let cp = Double(corr[peakIndex + 1])
            let denom = cm - 2 * c0 + cp
            if denom < 0 {
                offset += 0.5 * (cm - cp) / denom
            }
        }
        return Arrival(sampleOffset: offset, peakToSidelobe: psr)
    }

    /// The one-shot calibration read: both probes located in one recording,
    /// reduced to their arrival difference. Nil when either probe is missing
    /// or unconvincing — the caller falls back to the by-ear wizard, never to
    /// a shaky number.
    public func relativeOffset(probeA: [Float], probeB: [Float], recording: [Float],
                        ambientNoise: [Float]? = nil) -> Measurement? {
        guard let a = arrival(of: probeA, in: recording, ambientNoise: ambientNoise),
              let b = arrival(of: probeB, in: recording, ambientNoise: ambientNoise)
        else { return nil }
        return Measurement(offsetSeconds: (b.sampleOffset - a.sampleOffset) / sampleRate,
                           arrivalA: a, arrivalB: b)
    }

    // MARK: correlation internals

    /// Linear cross-correlation of `recording` against `probe` via FFT:
    /// `corr[lag] = Σ recording[lag+i] · probe[i]`, optionally divided per
    /// frequency bin by the ambient noise power spectrum.
    static func correlate(recording: [Float], probe: [Float],
                          ambientNoise: [Float]?) -> [Float] {
        let n = fftLength(for: recording.count + probe.count)
        guard let forward = vDSP.DFT(count: n, direction: .forward,
                                     transformType: .complexComplex, ofType: Float.self),
              let inverse = vDSP.DFT(count: n, direction: .inverse,
                                     transformType: .complexComplex, ofType: Float.self)
        else { return [] }

        let zeros = [Float](repeating: 0, count: n)
        let recPadded = recording + [Float](repeating: 0, count: n - recording.count)
        var recRe = [Float](repeating: 0, count: n)
        var recIm = [Float](repeating: 0, count: n)
        forward.transform(inputReal: recPadded, inputImaginary: zeros,
                          outputReal: &recRe, outputImaginary: &recIm)

        let probePadded = probe + [Float](repeating: 0, count: n - probe.count)
        var probeRe = [Float](repeating: 0, count: n)
        var probeIm = [Float](repeating: 0, count: n)
        forward.transform(inputReal: probePadded, inputImaginary: zeros,
                          outputReal: &probeRe, outputImaginary: &probeIm)

        // recording · conj(probe), per bin.
        var crossRe = [Float](repeating: 0, count: n)
        var crossIm = [Float](repeating: 0, count: n)
        for k in 0..<n {
            crossRe[k] = recRe[k] * probeRe[k] + recIm[k] * probeIm[k]
            crossIm[k] = recIm[k] * probeRe[k] - recRe[k] * probeIm[k]
        }

        if let ambientNoise, !ambientNoise.isEmpty {
            let weight = noiseWeights(ambient: ambientNoise, fftLength: n, forward: forward)
            for k in 0..<n {
                crossRe[k] *= weight[k]
                crossIm[k] *= weight[k]
            }
        }

        var corrRe = [Float](repeating: 0, count: n)
        var corrIm = [Float](repeating: 0, count: n)
        inverse.transform(inputReal: crossRe, inputImaginary: crossIm,
                          outputReal: &corrRe, outputImaginary: &corrIm)
        let scale = 1 / Float(n)
        for k in 0..<n { corrRe[k] *= scale }
        return corrRe
    }

    /// Per-bin `1 / (noisePower + ε)` from a probe-free ambient slice: the
    /// slice's zero-padded periodogram, box-smoothed (a single periodogram's
    /// per-bin variance is ~100%; averaging ~129 neighbours makes it a usable
    /// estimate), then regularised so near-silent bins cannot explode.
    private static func noiseWeights(ambient: [Float], fftLength n: Int,
                                     forward: vDSP.DFT<Float>) -> [Float] {
        let zeros = [Float](repeating: 0, count: n)
        let padded = Array(ambient.prefix(n)) + [Float](repeating: 0, count: max(0, n - ambient.count))
        var re = [Float](repeating: 0, count: n)
        var im = [Float](repeating: 0, count: n)
        forward.transform(inputReal: padded, inputImaginary: zeros,
                          outputReal: &re, outputImaginary: &im)
        var power = [Float](repeating: 0, count: n)
        for k in 0..<n { power[k] = re[k] * re[k] + im[k] * im[k] }

        let radius = min(64, n / 2)
        var smoothed = [Float](repeating: 0, count: n)
        var prefix = [Float](repeating: 0, count: n + 1)
        for k in 0..<n { prefix[k + 1] = prefix[k] + power[k] }
        for k in 0..<n {
            let lo = max(0, k - radius)
            let hi = min(n - 1, k + radius)
            smoothed[k] = (prefix[hi + 1] - prefix[lo]) / Float(hi - lo + 1)
        }

        let mean = prefix[n] / Float(n)
        let epsilon = max(mean * 0.05, .leastNormalMagnitude)
        var weights = [Float](repeating: 0, count: n)
        for k in 0..<n { weights[k] = 1 / (smoothed[k] + epsilon) }
        return weights
    }

    /// Power of two covering `minimum` — vDSP's DFT wants a friendly length,
    /// and a power of two (of at least 16) always is one.
    private static func fftLength(for minimum: Int) -> Int {
        var n = 16
        while n < minimum { n <<= 1 }
        return n
    }
}
