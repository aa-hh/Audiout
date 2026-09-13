// SPDX-License-Identifier: GPL-2.0-or-later

import AudioutField
import Foundation
import Testing
@testable import AudioutCore
@testable import AudioutPopoverUI

/// The alignment stage's lights against the shared numbers they are drawn
/// from: the emitter field's `defaults` plus its `settled` block
/// (audiout-shared ≥ 0.13.0). Same rule `EmitterFieldTests` defends for the
/// licence gate — **a port reads the shared numbers, it never retypes them** —
/// so these fail the moment the generated shader stops carrying what the
/// JSON says.
@Suite struct SettledLightLayerTests {

    @MainActor private var shader: String { SettledLightLayer.shaderSource }
    private let defaults = AudioutField.defaults
    private let settled = AudioutField.settled

    private func literal(_ value: Double) -> String { String(format: "%.4f", value) }

    @MainActor @Test func theSettledBlockReachesTheShaderUnretyped() {
        // `settled.orbit` is deliberately excluded — this surface does not
        // apply the centre-drift term (see `orbitIsDeliberatelyNotApplied`).
        for value in [settled.rollAmp, settled.rollRate, settled.taper,
                      settled.curlAmp, settled.curlRate, settled.breatheFloor,
                      settled.breatheDepth] {
            #expect(shader.contains(literal(value)), "settled \(value) missing from the shader")
        }
    }

    /// PER-SURFACE deviation: the shared orbit centre-drift is NOT applied on
    /// this stage. `AlignmentStageView` animates each light along the wire
    /// itself, so the field must not add its own centre drift on top — it would
    /// read as the light jittering off its mark. The shared `settled.orbit`
    /// stays in the JSON (the hero uses it); this surface just does not consume
    /// it, so its literal and the orbit's two drift rates are gone from the
    /// shader.
    @MainActor @Test func orbitIsDeliberatelyNotApplied() {
        #expect(!shader.contains(literal(settled.orbit)),
                "the orbit literal must be gone — this surface does not apply it")
        #expect(!shader.contains("t * 0.030"),
                "the orbit centre-drift term must be gone from this surface's shader")
    }

    @MainActor @Test func theSharedStepsReachTheShaderUnretyped() {
        for value in [defaults.squash, defaults.densBase, defaults.densStep, defaults.sharp,
                      defaults.fade, defaults.breatheRate, defaults.breatheStep, defaults.gain] {
            #expect(shader.contains(literal(value)), "shared \(value) missing from the shader")
        }
    }

    /// The settled state has no outward phase term, so the hero's speed
    /// must not sneak in; and the hero's deep breathing is overridden by the
    /// settled floor/depth, which the shader must carry instead.
    @MainActor @Test func theRetiredAndOverriddenHeroKnobsStayOut() {
        #expect(!shader.contains("t * speed"))
        #expect(!shader.contains(literal(defaults.breatheFloor) + " + " + literal(defaults.breatheDepth)))
        #expect(shader.contains(literal(settled.breatheFloor) + " + " + literal(settled.breatheDepth)))
    }

    /// `timeScale` is applied to the clock once, in the uniforms — never
    /// folded into a rate literal in the shader.
    @MainActor @Test func timeScaleIsNotFoldedIntoTheShader() {
        #expect(!shader.contains(literal(settled.rollRate * settled.timeScale)))
        #expect(!shader.contains(literal(settled.curlRate * settled.timeScale)))
    }

    /// The tone curve was tuned for a wash under an outline ring; with the
    /// ring gone this surface scales the light before it. That is its own
    /// constant — the SHARED gain still has to reach the shader as itself.
    @MainActor @Test func exposureIsThisSurfacesOwnAndTheSharedGainStays() {
        #expect(shader.contains(literal(SettledLightLayer.exposure)),
                "the per-surface exposure is missing from the shader")
        #expect(shader.contains(literal(defaults.gain)),
                "the shared gain must still reach the shader unretyped")
    }

    /// One narrow crest per light, no centre core, calmed to a near-still
    /// shimmer, is bought with the per-surface constants — the distance scale,
    /// the containment edge, the exposure, the band-narrowing power, the
    /// inner-core mask pair, and the roll/curl damps that calm the motion. The
    /// ring maths they feed is still the shared one, so those literals must
    /// stay too.
    @MainActor @Test func theOneCrestConstantsAreThisSurfacesAndTheRingMathsIsShared() {
        for value in [SettledLightLayer.crestScale, SettledLightLayer.reach,
                      SettledLightLayer.exposure, SettledLightLayer.bandNarrow,
                      SettledLightLayer.innerReach0, SettledLightLayer.innerReach1,
                      SettledLightLayer.rollDamp, SettledLightLayer.rollRateScale,
                      SettledLightLayer.curlSlow] {
            #expect(shader.contains(literal(value)), "per-surface \(value) missing from the shader")
        }
        for value in [defaults.densBase, defaults.sharp, defaults.fade] {
            #expect(shader.contains(literal(value)), "shared \(value) missing from the shader")
        }
    }

    /// The roll and curl are damped, not removed: the shared amplitudes and
    /// rates still reach the shader (just scaled by the per-surface damps), so
    /// the ring keeps a trace of the settled character. The roll's rate is also
    /// sped up by `rollRateScale`, and the curl's time rate slowed by `curlSlow`.
    @MainActor @Test func theRollAndCurlAreDampedNotRemoved() {
        for value in [settled.rollAmp, settled.rollRate, settled.curlAmp, settled.curlRate] {
            #expect(shader.contains(literal(value)),
                    "settled \(value) must still reach the shader, only scaled")
        }
        // The curl's time rate now carries the slow factor …
        #expect(shader.contains("\(literal(settled.curlRate)) * \(literal(SettledLightLayer.curlSlow))"),
                "the curl's time rate must be scaled by curlSlow")
        // … the roll sum is scaled by the damp fraction, not left at full …
        #expect(shader.contains("\(literal(SettledLightLayer.rollDamp)) * (\(literal(settled.rollAmp))"),
                "the roll amplitudes must be scaled by rollDamp")
        // … and the roll's rate is sped up by rollRateScale in both cosines.
        #expect(shader.contains("t * \(literal(settled.rollRate)) * \(literal(SettledLightLayer.rollRateScale))"),
                "the roll's rate must be scaled by rollRateScale")
    }

    /// Seed, density and breathe rate all hang off the per-light `variant`,
    /// never off the loop index — that is what lets two lights merge into one
    /// set of maths by sharing a value.
    @MainActor @Test func aSharedVariantMeansOneSeed() {
        #expect(shader.contains("variant * 6.13 + 1.7"))
        #expect(!shader.contains("float(k)"))
    }

    /// Headless there is no GPU layer, so the stage keeps its bitmap halo and
    /// every snapshot stays free of a per-frame clock.
    @MainActor @Test func headlessMakesNoLayer() {
        #expect(HeadlessRuntime.isActive)
        #expect(SettledLightLayer.make() == nil)
    }
}
