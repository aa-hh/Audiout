// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudiouterCore

/// W1 + W2 of `docs/plans/PLAN-VOLUME-KEY-INTERCEPTION.md` — the pure decision
/// core. The `CGEventTap` shell around this is not headlessly testable, which is
/// exactly why every decision it makes lives here instead.
@Suite struct VolumeKeyInterceptionTests {

    // MARK: - The mode

    @Test func ourAggregateAsDefaultOutputMeansWeOwnVolume() {
        #expect(VolumeOwnership.weOwnVolume(
            defaultOutputUID: AggregateOutputDevice.productUID,
            systemOutputVolume: 50
        ))
    }

    /// THE regression that matters most. The aggregate advertises
    /// `vmvc=true scalarMain=true muteMain=true` and reads back a perfectly
    /// plausible volume, while every write silently no-ops. Anything that gates
    /// on capability — or on `systemOutputVolume == nil` alone — reads this as a
    /// normal settable device, never takes over, and volume just dies with no
    /// error. Identity is the only reliable signal.
    @Test func aggregateReportingASettableVolumeStillMeansWeOwnIt() {
        // A believable non-nil reading, exactly as the lying aggregate produces.
        for reported in [0, 37, 100] {
            #expect(VolumeOwnership.weOwnVolume(
                defaultOutputUID: AggregateOutputDevice.productUID,
                systemOutputVolume: reported
            ), "aggregate reporting \(reported) must still count as ours")
        }
    }

    @Test func normalSettableOutputIsNotOurs() {
        #expect(!VolumeOwnership.weOwnVolume(
            defaultOutputUID: "BuiltInSpeakerDevice",
            systemOutputVolume: 50
        ))
    }

    /// Real HDMI: readable by nobody, so macOS cannot move it either.
    @Test func unreadableOutputIsOurs() {
        #expect(VolumeOwnership.weOwnVolume(
            defaultOutputUID: "AppleHDMIOutputDevice",
            systemOutputVolume: nil
        ))
    }

    @Test func unknownDefaultOutputWithAReadableVolumeIsNotOurs() {
        #expect(!VolumeOwnership.weOwnVolume(defaultOutputUID: nil, systemOutputVolume: 20))
    }

    // MARK: - Decoding

    /// Builds a `data1` the way macOS does: key code high, state in the next
    /// byte, auto-repeat in the low bit.
    private func data1(key: Int32, down: Bool, repeat isRepeat: Bool = false) -> Int {
        (Int(key) << 16) | ((down ? 0xA : 0xB) << 8) | (isRepeat ? 1 : 0)
    }

    @Test func decodesEachVolumeKey() {
        let cases: [(Int32, AuxKeyPress.Key)] = [(0, .soundUp), (1, .soundDown), (7, .mute)]
        for (code, expected) in cases {
            let press = AuxKeyPress.decode(data1: data1(key: code, down: true))
            #expect(press?.key == expected)
            #expect(press?.isDown == true)
            #expect(press?.isRepeat == false)
        }
    }

    @Test func decodesKeyUpAndAutoRepeat() {
        #expect(AuxKeyPress.decode(data1: data1(key: 0, down: false))?.isDown == false)
        #expect(AuxKeyPress.decode(data1: data1(key: 0, down: true, repeat: true))?.isRepeat == true)
    }

    /// systemDefined events are common traffic — screen changes, power
    /// notifications, the transport keys `MediaKeyController` itself posts. A
    /// `nil` here is the ordinary case and must never be mistaken for a volume key.
    @Test func ignoresNonVolumeAuxKeys() {
        for playbackKey: Int32 in [16, 17, 18] {   // play/pause, next, previous
            #expect(AuxKeyPress.decode(data1: data1(key: playbackKey, down: true)) == nil)
        }
        #expect(AuxKeyPress.decode(data1: 0) == nil)
    }

    @Test func rejectsAnImplausibleKeyState() {
        // Volume-up key code, but a state byte that is neither 0xA nor 0xB.
        #expect(AuxKeyPress.decode(data1: (0 << 16) | (0x3 << 8)) == nil)
    }

    // MARK: - Modifier masking

    /// The aux encoding mirrors key state into the low bits of the same flags
    /// field, so an unmasked test sees phantom modifiers on every single press.
    @Test func keyStateBitsAreNotMistakenForModifiers() {
        #expect(!AuxModifierFlags.isFineStep(0xA00))
        #expect(!AuxModifierFlags.isFineStep(0xB00))
    }

    @Test func fineStepNeedsBothShiftAndOption() {
        #expect(AuxModifierFlags.isFineStep(AuxModifierFlags.shift | AuxModifierFlags.option))
        #expect(!AuxModifierFlags.isFineStep(AuxModifierFlags.shift))
        #expect(!AuxModifierFlags.isFineStep(AuxModifierFlags.option))
        // Still true with the key-state noise riding along.
        #expect(AuxModifierFlags.isFineStep(AuxModifierFlags.shift | AuxModifierFlags.option | 0xA00))
    }

    // MARK: - Step math

    @Test func coarseStepsWalkTheSixteenthDetents() {
        #expect(VolumeStep.next(from: 0, up: true, fineStep: false) == 6)
        #expect(VolumeStep.next(from: 6, up: true, fineStep: false) == 13)
        #expect(VolumeStep.next(from: 13, up: true, fineStep: false) == 19)
        #expect(VolumeStep.next(from: 50, up: true, fineStep: false) == 56)
    }

    /// Snapping to the grid (rather than adding a fixed delta) is what keeps
    /// integer volumes reversible — up N times then down N times must land back
    /// exactly where it started. Starting points stay clear of the top stop,
    /// because clamping is deliberately NOT reversible (see below).
    @Test func steppingUpThenBackDownReturnsToTheStart() {
        for start in [0, 6, 13, 25, 50] {
            for fine in [false, true] {
                var v = start
                for _ in 0..<5 { v = VolumeStep.next(from: v, up: true, fineStep: fine) }
                for _ in 0..<5 { v = VolumeStep.next(from: v, up: false, fineStep: fine) }
                #expect(v == start, "start \(start) fine=\(fine) drifted to \(v)")
            }
        }
    }

    /// Pressing up against the ceiling and back down lands on a detent, not on
    /// wherever you started — exactly like the real macOS volume. Pinned so the
    /// reversibility test above is never "fixed" by removing the clamp.
    @Test func clampingAtTheTopIsNotReversible() {
        var v = 94
        for _ in 0..<5 { v = VolumeStep.next(from: v, up: true, fineStep: false) }
        #expect(v == 100)
        for _ in 0..<5 { v = VolumeStep.next(from: v, up: false, fineStep: false) }
        #expect(v == 69)
    }

    @Test func stepsClampAtBothEnds() {
        #expect(VolumeStep.next(from: 100, up: true, fineStep: false) == 100)
        #expect(VolumeStep.next(from: 0, up: false, fineStep: false) == 0)
        #expect(VolumeStep.next(from: 100, up: true, fineStep: true) == 100)
        #expect(VolumeStep.next(from: 0, up: false, fineStep: true) == 0)
    }

    @Test func fineStepsAreAQuarterOfACoarseStep() {
        #expect(VolumeStep.next(from: 0, up: true, fineStep: true) == 2)     // 1.5625 → 2
        #expect(VolumeStep.next(from: 50, up: true, fineStep: true) == 52)
        #expect(VolumeStep.next(from: 50, up: false, fineStep: true) == 48)
    }

    // MARK: - The decision

    @Test func passesEverythingThroughWhenWeDoNotOwnVolume() {
        let outcome = VolumeKeyDecision.decide(
            data1: data1(key: 0, down: true),
            modifierFlags: 0,
            weOwnVolume: false,
            currentMainVolume: 50
        )
        // macOS moves the system volume itself here, and the existing
        // SystemOutputVolume listener already carries it into Main. Acting would
        // move Main twice per press.
        #expect(outcome == .passThrough)
    }

    @Test func passesThroughUnrelatedSystemDefinedEventsEvenWhenWeOwnVolume() {
        let outcome = VolumeKeyDecision.decide(
            data1: data1(key: 16, down: true),   // play/pause
            modifierFlags: 0,
            weOwnVolume: true,
            currentMainVolume: 50
        )
        #expect(outcome == .passThrough)
    }

    @Test func volumeKeysMoveMainAndAreConsumed() {
        #expect(VolumeKeyDecision.decide(
            data1: data1(key: 0, down: true), modifierFlags: 0,
            weOwnVolume: true, currentMainVolume: 50
        ) == .consume(.setMainVolume(56)))

        #expect(VolumeKeyDecision.decide(
            data1: data1(key: 1, down: true), modifierFlags: 0,
            weOwnVolume: true, currentMainVolume: 50
        ) == .consume(.setMainVolume(44)))
    }

    @Test func heldVolumeKeysKeepMoving() {
        #expect(VolumeKeyDecision.decide(
            data1: data1(key: 0, down: true, repeat: true), modifierFlags: 0,
            weOwnVolume: true, currentMainVolume: 50
        ) == .consume(.setMainVolume(56)))
    }

    /// Consumed, not passed through: releasing after we swallowed the down would
    /// otherwise leave downstream listeners with an unpaired release.
    @Test func keyUpIsSwallowedWithoutAction() {
        #expect(VolumeKeyDecision.decide(
            data1: data1(key: 0, down: false), modifierFlags: 0,
            weOwnVolume: true, currentMainVolume: 50
        ) == .consume(nil))
    }

    @Test func muteTogglesOnceAndDoesNotFlapWhileHeld() {
        #expect(VolumeKeyDecision.decide(
            data1: data1(key: 7, down: true), modifierFlags: 0,
            weOwnVolume: true, currentMainVolume: 50
        ) == .consume(.toggleMainMute))

        #expect(VolumeKeyDecision.decide(
            data1: data1(key: 7, down: true, repeat: true), modifierFlags: 0,
            weOwnVolume: true, currentMainVolume: 50
        ) == .consume(nil))
    }

    /// Still swallowed at the end stop — macOS would draw the crossed-out HUD
    /// otherwise — but no pointless write goes down the chain.
    @Test func pressingPastAnEndStopConsumesWithoutAction() {
        #expect(VolumeKeyDecision.decide(
            data1: data1(key: 0, down: true), modifierFlags: 0,
            weOwnVolume: true, currentMainVolume: 100
        ) == .consume(nil))

        #expect(VolumeKeyDecision.decide(
            data1: data1(key: 1, down: true), modifierFlags: 0,
            weOwnVolume: true, currentMainVolume: 0
        ) == .consume(nil))
    }

    @Test func shiftOptionGivesAQuarterStep() {
        #expect(VolumeKeyDecision.decide(
            data1: data1(key: 0, down: true),
            modifierFlags: AuxModifierFlags.shift | AuxModifierFlags.option,
            weOwnVolume: true, currentMainVolume: 50
        ) == .consume(.setMainVolume(52)))
    }
}
