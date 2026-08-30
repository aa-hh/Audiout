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
    /// rather than bullseyes parked on the ground — and they stay past them
    /// at the far end of the ORBIT, which drifts each centre by ±`orbit` on
    /// each axis. A source parked a hair outside sails into view twice a
    /// cycle and lands as a bullseye; an earlier composition had one 0.044
    /// outside the edge against an orbit of 0.1, and it did exactly that.
    @MainActor @Test func everySourceStaysOutsideTheFrameAcrossItsOrbit() {
        let orbit = defaults.orbit
        for emitter in EmitterFieldView.test_emitters {
            let clearsSides = abs(emitter.x) - orbit > Self.halfWidth
            let clearsTopOrBottom = abs(emitter.y) - orbit > 0.5
            #expect(clearsSides || clearsTopOrBottom,
                    "the source at (\(emitter.x), \(emitter.y)) drifts into the frame")
        }
    }

    /// Every fan reaches well INSIDE the frame. A source whose cap only
    /// grazes the edge has nothing left to lose: the breathing dip and the
    /// orbit drift together take it to bare canvas and one of the three
    /// visibly switches off. Measured on the composition that did this — a
    /// source 0.36 below the frame whose fan penetrated 0.22 — its brightest
    /// crest sat at the canvas floor for ~110 s at a stretch, against a
    /// healthy source's 0.10. Three times the orbit is the floor: the drift
    /// alone can spend most of a shallower penetration.
    @MainActor @Test func everyFanReachesWellInsideTheFrame() {
        for emitter in EmitterFieldView.test_emitters {
            // Nearest point of the frame to this centre, in the shader's
            // squashed metric — the same one `reach` is expressed in.
            let dx = max(0, abs(emitter.x) - Self.halfWidth)
            let dy = max(0, abs(emitter.y) - 0.5) * defaults.squash
            let penetration = emitter.reach - (dx * dx + dy * dy).squareRoot()
            #expect(penetration > 3 * defaults.orbit,
                    "the source at (\(emitter.x), \(emitter.y)) only reaches \(penetration) into the frame")
        }
    }

    /// The bottom calm zone has to cover the whole Quit/Buy row, not just
    /// clip its lower edge — those two are bordered buttons and the field
    /// crossing them is what made "Buy Audiout" unreadable.
    @MainActor @Test func theCalmZoneCoversTheWholeButtonRow() {
        // The row: 14 pt up from the bottom edge, and a `.regular` push
        // button is about 21 pt tall.
        let rowTop = -0.5 + (14.0 + 21.0) / 440.0
        let zone = EmitterFieldView.test_bottomCalmZone
        #expect(zone.lit > rowTop,
                "the field is back to full strength at \(zone.lit), inside a button row that reaches \(rowTop)")
        #expect(shader.contains("sstep(\(literal(zone.dark)), \(literal(zone.lit)), uv.y)"))
    }

    /// Half the 560 × 440 stage's width, in the field's uv (units of height).
    private static let halfWidth = (560.0 / 440.0) / 2
}
