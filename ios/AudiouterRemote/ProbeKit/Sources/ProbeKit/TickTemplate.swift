import Foundation

/// The alignment tick, re-synthesized at whatever rate the phone recorded at.
///
/// These constants are a COPY of `AlignmentTickInjector`'s tick synthesis in
/// `AudiouterCore` — the Mac renders the tick from them, the phone matches
/// against them, and the two must stay identical or the matched filter loses
/// its edge. ProbeKit cannot import AudiouterCore (that package shells out to
/// Homebrew for AirPlayEngine's C dependencies and does not exist on iOS), so
/// the duplication is deliberate. Change one, change the other.
enum TickTemplate {

    /// Woodblock-ish transient: ~30 ms, two partials, exponential decay
    /// (τ ≈ 6 ms), with a handful of attack samples ramped so the onset is
    /// sharp but not a raw DC step.
    static let durationSeconds = 0.03
    static let decayTau = 0.006
    static let attackFrames = 8
    static let lowPartialHz = 1_800.0
    static let lowPartialWeight = 0.7
    static let highPartialHz = 2_900.0
    static let highPartialWeight = 0.3
    /// The injector's default `amplitude:`, expressed as full-scale Float
    /// rather than its Int16 domain.
    static let amplitude = 0.35

    static func render(sampleRate: Double, amplitude: Double = amplitude) -> [Float] {
        let frames = Int(sampleRate * durationSeconds)
        guard frames > 0 else { return [] }
        return (0..<frames).map { f in
            let t = Double(f) / sampleRate
            let attack = f < attackFrames ? Double(f) / Double(attackFrames) : 1
            let envelope = exp(-t / decayTau) * attack
            let partials = lowPartialWeight * sin(2 * .pi * lowPartialHz * t)
                + highPartialWeight * sin(2 * .pi * highPartialHz * t)
            return Float(amplitude * envelope * partials)
        }
    }
}
