import Foundation

// Small dependency-free statistics + signal helpers for the spike. Kept trivial
// and self-contained (no Accelerate) so the harness stays a single obvious tool.

struct Stats {
    let n: Int
    let mean: Double
    let stddev: Double
    let min: Double
    let max: Double
    let p50: Double
    let p95: Double
    let p99: Double

    init(_ xs: [Double]) {
        let sorted = xs.sorted()
        n = xs.count
        guard n > 0 else {
            mean = 0; stddev = 0; min = 0; max = 0; p50 = 0; p95 = 0; p99 = 0
            return
        }
        let sum = xs.reduce(0, +)
        let m = sum / Double(n)
        mean = m
        let variance = xs.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(n)
        stddev = variance.squareRoot()
        min = sorted.first!
        max = sorted.last!
        let count = n
        func pct(_ p: Double) -> Double {
            if count == 1 { return sorted[0] }
            let idx = Swift.min(count - 1, Swift.max(0, Int((p / 100.0) * Double(count - 1) + 0.5)))
            return sorted[idx]
        }
        p50 = pct(50); p95 = pct(95); p99 = pct(99)
    }

    func describe(unit: String, scale: Double = 1.0) -> String {
        func f(_ v: Double) -> String { String(format: "%.4f", v * scale) }
        return "n=\(n) mean=\(f(mean)) sd=\(f(stddev)) min=\(f(min)) p50=\(f(p50)) p95=\(f(p95)) p99=\(f(p99)) max=\(f(max)) \(unit)"
    }
}

enum Signal {
    /// Full-scale sine at `freq` Hz for `frames` samples at `sr`, phase-continuous
    /// from an absolute sample index so a chunked producer stays glitch-free.
    static func sine(freq: Double, sr: Double, absoluteFrame: Int, count: Int, amp: Float = 0.9) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        let w = 2.0 * Double.pi * freq / sr
        for i in 0..<count {
            out[i] = amp * Float(sin(w * Double(absoluteFrame + i)))
        }
        return out
    }

    /// Largest absolute first-difference in a mono signal. For a clean sine of
    /// amplitude A and radian step w, the true max |x[n]-x[n-1]| ≈ A·|2·sin(w/2)|;
    /// a click (sample discontinuity) blows well past that bound.
    static func maxAbsFirstDiff(_ x: [Float]) -> (value: Float, index: Int) {
        var best: Float = 0
        var idx = 0
        if x.count < 2 { return (0, 0) }
        for i in 1..<x.count {
            let d = abs(x[i] - x[i - 1])
            if d > best { best = d; idx = i }
        }
        return (best, idx)
    }

    /// Expected max |Δ| bound for a clean sine at this freq/rate/amplitude.
    static func sineDiffBound(freq: Double, sr: Double, amp: Float) -> Float {
        let w = 2.0 * Double.pi * freq / sr
        return amp * Float(abs(2.0 * sin(w / 2.0)))
    }

    /// Index of the peak absolute sample (used to locate an impulse in the
    /// group-delay measurement).
    static func peakIndex(_ x: [Float]) -> (index: Int, value: Float) {
        var idx = 0
        var best: Float = 0
        for i in 0..<x.count {
            let a = abs(x[i])
            if a > best { best = a; idx = i }
        }
        return (idx, best)
    }
}

// MARK: - Mach ↔ nanoseconds (same conversion the shipping render block relies on)

enum MachTime {
    static let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb
    }()

    static func hostTicksToNanos(_ ticks: UInt64) -> Int64 {
        // ticks * numer / denom, done in 128-ish safe steps for typical values.
        Int64(ticks) &* Int64(timebase.numer) / Int64(timebase.denom)
    }

    static func nowNanos() -> Int64 { hostTicksToNanos(mach_absolute_time()) }

    static func monotonicNanos() -> Int64 {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return Int64(ts.tv_sec) &* 1_000_000_000 &+ Int64(ts.tv_nsec)
    }
}
