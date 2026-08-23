import Foundation

// INDEPENDENT re-derivation of SyncedLocalSink's release-plan math (SyncTiming.plan
// in AudioutCore/Sources/AudioutCore/SyncedLocalSink.swift). We do NOT import
// AudioutCore — reimplementing the tiny formula here is a cross-check that the
// sub-buffer placement bound the shipping code claims ("< 1 frame at release") is
// real, and lets us Monte-Carlo it over random targets/cycles.

enum PlanMath {
    struct RenderPlan: Equatable {
        let silentFrames: Int
        let releasesThisCycle: Bool
    }

    /// Mirror of SyncTiming.plan.
    static func plan(cycleStartNanos: Int64, frameCount: Int, sampleRate: Double, targetNanos: Int64) -> RenderPlan {
        let delta = targetNanos &- cycleStartNanos
        if delta <= 0 { return RenderPlan(silentFrames: 0, releasesThisCycle: true) }
        let nsPerFrame = 1_000_000_000.0 / sampleRate
        let offsetFrames = Int((Double(delta) / nsPerFrame).rounded())
        if offsetFrames >= frameCount { return RenderPlan(silentFrames: frameCount, releasesThisCycle: false) }
        return RenderPlan(silentFrames: offsetFrames, releasesThisCycle: true)
    }

    /// Reproduce the render block's phase-error computation: the instant the first
    /// REAL sample is emitted, minus the target. This is exactly what
    /// SyncedLocalSink.latestPhaseErrorNanos reports.
    static func phaseErrorNanos(cycleStartNanos: Int64, silentFrames: Int, sampleRate: Double, targetNanos: Int64) -> Int64 {
        let firstReal = cycleStartNanos &+ Int64((Double(silentFrames) * 1_000_000_000.0 / sampleRate).rounded())
        return firstReal &- targetNanos
    }

    /// Monte-Carlo the achievable release-phase error assuming the render block is
    /// handed an EXACT per-cycle hostTime (i.e. isolating the pure algorithmic
    /// quantization floor from real hardware timestamp jitter). Cycle start is
    /// swept across a full buffer relative to the target so we see the worst case.
    static func monteCarlo(sampleRate: Double, frameCount: Int, trials: Int) -> Stats {
        var errsNs = [Double]()
        errsNs.reserveCapacity(trials)
        let nsPerFrame = 1_000_000_000.0 / sampleRate
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<trials {
            // A target somewhere in the future, and a cycle boundary randomly
            // phased against it within one buffer (the realistic case: the engine
            // pulls cycles on its own grid, not aligned to our target).
            let target: Int64 = 1_000_000_000 + Int64(UInt64.random(in: 0..<1_000_000_000, using: &rng))
            let cyclePhase = Double.random(in: 0..<(Double(frameCount) * nsPerFrame), using: &rng)
            let cycleStart = target - Int64(cyclePhase.rounded())
            let p = plan(cycleStartNanos: cycleStart, frameCount: frameCount, sampleRate: sampleRate, targetNanos: target)
            guard p.releasesThisCycle else { continue }
            let err = phaseErrorNanos(cycleStartNanos: cycleStart, silentFrames: p.silentFrames, sampleRate: sampleRate, targetNanos: target)
            errsNs.append(Double(abs(err)))
        }
        return Stats(errsNs)
    }
}
