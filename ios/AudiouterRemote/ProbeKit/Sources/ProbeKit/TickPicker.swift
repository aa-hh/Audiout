import Foundation

/// One detected tick: when its direct path arrived, and how strong the
/// correlation burst around it was.
struct TickArrival {
    let seconds: Double
    let strength: Float
}

/// Turns a correlation magnitude trace into tick arrival times.
///
/// Each audible tick produces a BURST of correlation energy — the direct path
/// plus every reflection behind it. The arrival we want is the burst's first
/// strong peak, not its tallest one: a reflection can beat the direct path in
/// amplitude, but it can never beat it in time.
struct TickPicker {

    /// Detection threshold, as a fraction of the way from the noise floor to
    /// the tallest peak in the trace.
    static let thresholdFraction: Float = 0.30
    /// Samples this close together belong to the same tick. Well under one
    /// beat, comfortably over a room's reflection tail.
    static let burstSpanSeconds = 0.060
    /// Within a burst, a peak this fraction of the burst maximum counts as
    /// "strong" — the earliest such peak is the direct path.
    static let strongPeakFraction: Float = 0.5
    /// A tick weaker than this fraction of the median tick is low-quality
    /// (clipped by a mute switch, or a noise peak) and is dropped.
    static let qualityFraction: Float = 0.5

    let sampleRate: Double

    func arrivals(in correlation: [Float]) -> [TickArrival] {
        guard !correlation.isEmpty else { return [] }
        let floorValue = noiseFloor(of: correlation)
        let peakValue = correlation.max() ?? 0
        guard peakValue > floorValue else { return [] }
        let threshold = floorValue + Self.thresholdFraction * (peakValue - floorValue)
        let burstSpan = Int(Self.burstSpanSeconds * sampleRate)

        var bursts: [Range<Int>] = []
        var index = 0
        while index < correlation.count {
            guard correlation[index] >= threshold else {
                index += 1
                continue
            }
            var end = index + 1
            var quiet = 0
            while end < correlation.count, quiet < burstSpan {
                quiet = correlation[end] >= threshold ? 0 : quiet + 1
                end += 1
            }
            bursts.append(index..<end)
            index = end
        }

        let detected = bursts.map { range -> TickArrival in
            let burst = correlation[range]
            let burstPeak = burst.max() ?? 0
            let strongEnough = max(threshold, Self.strongPeakFraction * burstPeak)
            let onset = range.first { correlation[$0] >= strongEnough } ?? range.lowerBound
            return TickArrival(seconds: Double(onset) / sampleRate, strength: burstPeak)
        }
        return dropLowQuality(detected)
    }

    /// The median magnitude — a floor that ignores the ticks themselves, which
    /// occupy well under half the trace.
    private func noiseFloor(of correlation: [Float]) -> Float {
        let stride = max(1, correlation.count / 20_000)
        let sampled = Swift.stride(from: 0, to: correlation.count, by: stride)
            .map { correlation[$0] }
            .sorted()
        return sampled[sampled.count / 2]
    }

    private func dropLowQuality(_ arrivals: [TickArrival]) -> [TickArrival] {
        guard !arrivals.isEmpty else { return [] }
        let strengths = arrivals.map(\.strength).sorted()
        let median = strengths[strengths.count / 2]
        return arrivals.filter { $0.strength >= Self.qualityFraction * median }
    }
}
