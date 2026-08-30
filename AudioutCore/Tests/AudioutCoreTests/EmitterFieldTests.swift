// SPDX-License-Identifier: GPL-2.0-or-later

import AudioutField
import Foundation
import Testing
@testable import AudioutOnboardingUI

/// The licence gate's emitter field against the shared numbers it is drawn
/// from (`field.json` in audiout-shared, which the marketing site's shader
/// reads too).
///
/// The rule under defense is the one the field's skill exists for: **a port
/// reads the shared numbers, it never retypes them.** Every drift the brand
/// has suffered started as a hand-copied constant, so these tests fail the
/// moment the generated shader stops carrying what `AudioutField.defaults`
/// says — including when someone bumps the shared package and the site moves
/// without this window following.
///
/// Deliberate deviations are allowed but must be DECLARED. Exactly one
/// exists (`stageScale`, on ring density and speed together) and it is
/// asserted here by name, so an undeclared second one cannot arrive quietly.
@Suite struct EmitterFieldTests {

    @MainActor private var shader: String { EmitterFieldView.shaderSource }
    private let defaults = AudioutField.defaults

    /// The shader carries every shared number as itself, at the same
    /// precision the generator writes.
    private func literal(_ value: Double) -> String {
        String(format: "%.4f", value)
    }

    // MARK: The shared numbers reach the shader unretyped

    @MainActor @Test func ringShapeAndFalloffAreTheSharedValues() {
        #expect(shader.contains("sin(r * dens - t * speed + seed), \(literal(defaults.sharp))"))
        #expect(shader.contains("exp(-r * \(literal(defaults.fade)))"))
        #expect(shader.contains("float2(1.0, \(literal(defaults.squash)))"))
    }

    @MainActor @Test func orbitAndBreathingAreTheSharedValues() {
        #expect(shader.contains("+ \(literal(defaults.orbit)) * float2(sin(t * 0.030 + seed)"))
        #expect(shader.contains("(\(literal(defaults.breatheRate)) + \(literal(defaults.breatheStep)) * f)"))
        #expect(shader.contains("float swell = \(literal(defaults.breatheFloor)) + \(literal(defaults.breatheDepth))"))
    }

    @MainActor @Test func paperLiftIsTheSharedValue() {
        #expect(shader.contains("mix(1.0, \(literal(defaults.paperLift)), u.lightMode)"))
    }

    /// `gain` reaches the shader as a uniform rather than a literal, so the
    /// scene engine can modulate it — the Swift-side base is what must match.
    @MainActor @Test func baseGainIsTheSharedGain() {
        #expect(EmitterFieldView.test_baseGain == Float(defaults.gain))
    }

    // MARK: The one declared deviation

    @MainActor @Test func densityAndSpeedCarryTheSharedBasesAtTheDeclaredScale() {
        let scale = literal(EmitterFieldView.test_stageScale)
        #expect(shader.contains(
            "float speed = (\(literal(defaults.speedBase)) + \(literal(defaults.speedStep)) * f) * \(scale)"))
        #expect(shader.contains(
            "float dens = (\(literal(defaults.densBase)) + \(literal(defaults.densStep)) * f) * \(scale)"))
    }

    /// Scaling density and speed by the SAME number is the whole reason one
    /// deviation is honest: crest velocity is speed/density, so the
    /// wavefronts still travel at the site's own pace.
    @MainActor @Test func theStageScaleLeavesCrestVelocityAtTheSites() {
        let scale = EmitterFieldView.test_stageScale
        let siteVelocity = defaults.speedBase / defaults.densBase
        let ours = (defaults.speedBase * scale) / (defaults.densBase * scale)
        #expect(abs(ours - siteVelocity) < 1e-12)
    }

    // MARK: The per-surface composition

    /// Position, size and reach are the field's per-surface knobs, so these
    /// are free — but the window's own rule is not: the key field and the
    /// Register button sit at the middle of the stage, and every source's
    /// `reach` cap has to have taken its light to nothing before it gets
    /// there.
    ///
    /// Measured in the shader's own metric: `reach` bounds
    /// `length((uv - centre) * (1, squash))`, so the cap's edge is an ellipse,
    /// not a circle, and comparing plain distances would quietly pass a
    /// source the field actually reaches with.
    @MainActor @Test func noSourceReachesTheMiddleOfTheStage() {
        let squash = defaults.squash
        for emitter in EmitterFieldView.test_emitters {
            let toCentre = (emitter.x * emitter.x
                            + (emitter.y * squash) * (emitter.y * squash)).squareRoot()
            #expect(toCentre > emitter.reach,
                    "the source at (\(emitter.x), \(emitter.y)) still carries light \(emitter.reach - toCentre) past the centre of the window")
        }
    }

    /// Sources sit past the frame's edges, so the window shows arcs arriving
    /// rather than bullseyes parked on the ground.
    @MainActor @Test func everySourceSitsOutsideTheFrame() {
        let halfWidth = (560.0 / 440.0) / 2
        for emitter in EmitterFieldView.test_emitters {
            #expect(abs(emitter.x) > halfWidth || abs(emitter.y) > 0.5)
        }
    }
}
