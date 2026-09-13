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
        for value in [settled.orbit, settled.rollAmp, settled.rollRate, settled.taper,
                      settled.curlAmp, settled.curlRate, settled.breatheFloor,
                      settled.breatheDepth] {
            #expect(shader.contains(literal(value)), "settled \(value) missing from the shader")
        }
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

    /// Headless there is no GPU layer, so the stage keeps its bitmap halo and
    /// every snapshot stays free of a per-frame clock.
    @MainActor @Test func headlessMakesNoLayer() {
        #expect(HeadlessRuntime.isActive)
        #expect(SettledLightLayer.make() == nil)
    }
}
