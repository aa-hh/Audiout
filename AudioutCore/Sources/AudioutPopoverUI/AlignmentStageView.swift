// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import AudioutCore
import AudioutSharedUI

/// The alignment wizard's live belief, drawn: two lights riding one wire on a
/// fixed dark plate.
///
/// The lights are the two ENDS of the run's 95% credible interval — the gap
/// between them IS the uncertainty, so they can meet but never cross, and the
/// lit span of the wire between them is the interval itself. Colour names
/// WHICH speaker, never state (wizard-stage v2 spec §2): the target light is
/// `syncSignal`, the reference `partySignal`, and the two fuse to `fuseWhite`
/// at the lock. The stage IS the plate — it fills its own bounds with
/// `stagePlate`, so every hue inside it is an instrument value, fixed in both
/// appearances.
///
/// **The ladder is the system** (spec §5). Confidence is not a continuous
/// dial: the run climbs eight named RUNGS, each with one settled look, and the
/// only thing that ever animates is the AUTHORED TRANSITION between two rungs.
/// `Rung.resolve` owns the boundaries — with hysteresis, so a belief hovering
/// on a boundary cannot flicker — and `Transition` owns the choreography.
/// A window change is played as a CAMERA GESTURE on `fieldLayer` (seed the
/// transform that maps the new window back onto the old one, animate to
/// identity): a promotion pushes in, a demotion pulls back, which is what
/// stops a zoom from reading as a regression.
///
/// A custom-drawn instrument by necessity (approved in this target's
/// AGENTS.md): no stock control renders a probability interval as light.
/// Deliberately NOT synced to the audible ticks — the AirPlay path buffers
/// 1–2 s and there is no beat callback, so the stage reacts to ANSWERS only;
/// a visual metronome would lie.
///
/// **The lights are LIVING RINGS, ported from the marketing site's emitter
/// component** (`src/scripts/fields/emitters.js` in the Audiouter Website
/// repo, at the values `house-bg.js` saves for its cabinet instance:
/// `wobble` 0.03, `wobbleRate` 0.5, `squash` 1.12, breathe `0.4 + 0.6·u` at
/// rate `0.1 + 0.028·f`, per-light seed `f·6.13 + 1.7`). Three things carry
/// over and one deliberately does not. The RADIUS bends — two slow-turning
/// harmonics, three lobes and five, phased by the light's own seed — so parts
/// of the ring run ahead and the lead drifts, while the CENTRE never moves
/// (the centre is data: it marks a millisecond value). The wavefront is
/// squashed 1.12 in y, so a light reads as a slight oval rather than a clock
/// face. The breathing swell rides the ring's and halo's OPACITY. What is
/// dropped is the field itself: no outward propagation, no orbit drift — the
/// website's rings travel because they are sound leaving a speaker; here the
/// light IS a reading, and a reading that wanders is a lie.
///
/// **The swell modulates WITHIN a rung, never across one.** Brightness is the
/// look table's certainty signal, so the emitter's ±43 % swell is remapped to
/// ±`swellDepth` (6 %) around whatever opacity the rung settled on — well
/// under the ~13 % step between two rungs' halos. **Pinned phase is the
/// settled model**: with no clock running — Reduce Motion, `HeadlessRuntime`,
/// off screen, or a rung that does not breathe — the wobble term is zero and
/// the swell factor is exactly 1, so the ring is a plain squashed ellipse at
/// the table's own opacity and `cacheDisplay` is byte-deterministic. Only the
/// TIME-VARYING half of the port is pinned; the squash is a settled property
/// and is present in every render.
///
/// Layer colors are stamped `CGColor`s, so the view re-stamps on appearance
/// flips, accessibility-display changes AND the accent dial (the three live
/// re-resolution triggers, `AudioutSharedUI/AGENTS.md`). Model values stay
/// SETTLED underneath every transient, so snapshots are deterministic and the
/// test seams read the truth rather than a frame. Decorative to
/// accessibility — the readout caption beside the stage carries the same
/// information in words.
final class AlignmentStageView: NSView {

    /// What the stage is showing. Value/interval numbers are in the session's
    /// VALUE space; `range` is the candidate range the wire windows onto.
    enum State: Equatable {
        /// Intro: wide open and soft — the run hasn't started.
        case armed(range: ClosedRange<Double>)
        /// A question is live: the lights sit at the interval's ends.
        case question(intervalMs: ClosedRange<Double>, range: ClosedRange<Double>)
        /// The proposal is playing: fused, concentric, breathing while the
        /// user listens.
        case listening(valueMs: Double, range: ClosedRange<Double>)
        /// Kept: one crisp ring. The lock sequence fires on the transition in.
        case locked(valueMs: Double, range: ClosedRange<Double>)
        /// A bow-out: the stage dims to the plate's rule tone and goes still.
        case dormant
    }

    // MARK: - The ladder

    /// One rung of the confidence ladder (spec §5). The rung is the ONE thing
    /// that decides how the stage looks: a `Look` row, a status word, a window
    /// span and a breathing tempo all hang off it, so the words and the light
    /// can never disagree.
    enum Rung: Equatable {
        case armed, open, closing, near, threshold, fused, locked, dormant

        /// Boundaries the STAGE owns. The 250 ms rung boundary is the
        /// session's own `fineTempoHalfWidthMs` (the number that also quickens
        /// the audible clicks) and the ladder's floor is the run's propose
        /// stop — both READ, never retyped.
        private static let nearEnterMs: Double = 60
        private static let nearDemoteMs: Double = 75
        private static let thresholdEnterMs: Double = 12
        private static let thresholdDemoteMs: Double = 15
        private static let closingDemoteMs: Double = 300

        /// Where a rung sits on the ladder — the promotion/demotion compare.
        var ladderIndex: Int {
            switch self {
            case .armed: return 0
            case .open: return 1
            case .closing: return 2
            case .near: return 3
            case .threshold: return 4
            case .fused: return 5
            case .locked: return 6
            case .dormant: return 7
            }
        }

        /// The four question rungs are the only ones the half-width decides;
        /// everything else is decided by the STATE, so hysteresis applies to
        /// these alone.
        var isQuestionRung: Bool {
            switch self {
            case .open, .closing, .near, .threshold: return true
            default: return false
            }
        }

        /// The half-width this rung gives way at — deliberately wider than the
        /// one it was entered at (spec §5's mandatory hysteresis).
        var demoteHalfWidthMs: Double {
            switch self {
            case .open: return .infinity   // the widest question rung — nothing below it
            case .closing: return Self.closingDemoteMs
            case .near: return Self.nearDemoteMs
            case .threshold: return Self.thresholdDemoteMs
            default: return .infinity
            }
        }

        /// The readout's status word — FOUR words, matched 1:1 to the question
        /// rungs (spec §1). Owned here so a word boundary and a look boundary
        /// are physically the same constant.
        ///
        /// All four are short progress phrases about the BELIEF, because they
        /// sit beside the question in one line: "the clicks are quicker now"
        /// reported the stimulus tempo instead, and at five words it read as a
        /// second clause of the question rather than a status beside it.
        var word: String? {
            switch self {
            case .open: return "narrowing in"
            case .closing: return "closing in"
            case .near: return "getting close"
            case .threshold: return "nearly there"
            default: return nil
            }
        }

        /// The ladder's one decision point. Tightening enters a rung the
        /// instant its boundary is crossed; WIDENING holds the rung it is on
        /// until the wider demote boundary is passed, so a belief breathing
        /// across a boundary cannot strobe the whole stage.
        static func resolve(_ state: State, previous: Rung) -> Rung {
            switch state {
            case .armed: return .armed
            case .listening: return .fused
            case .locked: return .locked
            case .dormant: return .dormant
            case .question(let interval, _):
                // The ladder's floor is the run's own stop: the session
                // proposes at `proposeHalfWidthMs`, so nothing narrower than
                // that is a belief the stage ever has to draw.
                let halfWidth = Swift.max((interval.upperBound - interval.lowerBound) / 2,
                                          BTAlignmentWizardSession.proposeHalfWidthMs)
                let entered: Rung
                if halfWidth <= thresholdEnterMs {
                    entered = .threshold
                } else if halfWidth <= nearEnterMs {
                    entered = .near
                } else if halfWidth <= BTAlignmentWizardSession.fineTempoHalfWidthMs {
                    entered = .closing
                } else {
                    entered = .open
                }
                // Arriving from armed/fused/locked/dormant: no rung to hold.
                guard previous.isQuestionRung else { return entered }
                // Tightening always lands immediately; only widening waits.
                guard entered.ladderIndex < previous.ladderIndex else { return entered }
                return halfWidth > previous.demoteHalfWidthMs ? entered : previous
            }
        }
    }

    /// The settled look of one rung — spec §5's parameter table, transcribed.
    /// Every value here is a MODEL value: a transition animates towards it and
    /// a transient rides over it, but this is what the layer holds at rest.
    struct Look: Equatable {
        let haloDiameter: CGFloat
        let haloOpacity: Float
        let ringRadius: CGFloat
        let ringOpacity: Float
        let ringLineWidth: CGFloat
        let wireOpacity: Float
        let tickHalfHeight: CGFloat
        let tickOpacity: Float
        let spanOpacity: Float
        let spanHeight: CGFloat
        let spanShadowRadius: CGFloat
        /// The window the wire shows, in ms — `nil` = the whole candidate
        /// range. Quantized per rung, so every rung change re-gears the ruler.
        let windowSpanMs: Double?
        /// Derived with the table's min tick count (4/4/6/6/6) from the window
        /// span above; stored rather than re-derived so the ruler's gearing is
        /// a property of the RUNG, not of an accidental window width.
        let tickStepMs: Double
        /// Idle breathing period — `nil` = this rung does not breathe. Never
        /// an integer multiple of the click period, so the two can't lock.
        let breathePeriod: TimeInterval?
        let breatheAmplitude: CGFloat
        /// How much of the wire the window maps onto. Below 1 the ruler sits
        /// inside unlit wire on both sides — the wide-open rungs show the
        /// whole candidate range, and lights parked 10 pt from the plate's
        /// edges left nothing for the interval to be narrower THAN.
        var rulerFill: CGFloat = 1
    }

    /// The wide-open rungs' ruler fill: the whole candidate range on ~70% of
    /// the wire, so the open interval has unlit wire to be narrower than.
    private static let openRulerFill: CGFloat = 0.72

    /// Spec §5's look table — plus the ruler fill (above), a 10 ms tick step
    /// on the tight rungs (the table's 5 ms put 13 ticks on the calmest
    /// moment of the run), and the 1.8× LIGHT SCALE below.
    ///
    /// **The lights are drawn 1.8× the spec's own sizes** (owner ruling
    /// 2026-08-24, after the living-ring port shipped): the ported wobble is
    /// ±3 % of the RADIUS, so on the spec's 9–20 pt rings the wavefront's
    /// whole peak-to-peak travel was 1.1–2.4 Retina pixels — the life that
    /// had just been ported could not be seen. Radii 36/32/25/20/16 put that
    /// travel at 1.9–4.3 px, and the ring finally fills its own halo (ring
    /// diameter ~⅔ of the halo box, where it was ~half and read as a small
    /// circle adrift in a blob).
    ///
    /// Three things move together, and none of them is a free multiply.
    /// **The halos scale with the rings**, or the glow stops being a glow —
    /// which is what forces `stageHeight` up to 132. **The line widths rise
    /// sub-linearly** (×1.25 rather than ×1.8): a stroke that scaled with the
    /// radius would read as a drawn hoop instead of a lit edge. **And the
    /// ladder's gaps grow with everything else** — adjacent rungs sit 4/7/5/4
    /// pt apart where they used to sit 2/4/3/2, so each step is twice as
    /// legible while its ratio to the wobble at that size is unchanged. That
    /// last part is the constraint: the radius is how the ladder encodes
    /// certainty, so a scale that let the wobble catch up with the gap would
    /// make the instrument lie.
    static func look(for rung: Rung) -> Look {
        switch rung {
        case .armed:
            return Look(haloDiameter: 106, haloOpacity: 0.20, ringRadius: 36,
                        ringOpacity: 0.18, ringLineWidth: 1.25, wireOpacity: 0.55,
                        tickHalfHeight: 4, tickOpacity: 0.35, spanOpacity: 0.22,
                        spanHeight: 1.5, spanShadowRadius: 3, windowSpanMs: nil,
                        tickStepMs: 250, breathePeriod: 5.2, breatheAmplitude: 1.05,
                        rulerFill: openRulerFill)
        case .open:
            return Look(haloDiameter: 96, haloOpacity: 0.40, ringRadius: 32,
                        ringOpacity: 0.30, ringLineWidth: 1.25, wireOpacity: 0.66,
                        tickHalfHeight: 4.75, tickOpacity: 0.48, spanOpacity: 0.42,
                        spanHeight: 2.0, spanShadowRadius: 3.5, windowSpanMs: nil,
                        tickStepMs: 250, breathePeriod: 4.4, breatheAmplitude: 1.045,
                        rulerFill: openRulerFill)
        case .closing:
            return Look(haloDiameter: 76, haloOpacity: 0.46, ringRadius: 25,
                        ringOpacity: 0.55, ringLineWidth: 1.6, wireOpacity: 0.78,
                        tickHalfHeight: 5.5, tickOpacity: 0.60, spanOpacity: 0.61,
                        spanHeight: 2.5, spanShadowRadius: 4, windowSpanMs: 640,
                        tickStepMs: 100, breathePeriod: 3.5, breatheAmplitude: 1.04)
        case .near:
            return Look(haloDiameter: 60, haloOpacity: 0.52, ringRadius: 20,
                        ringOpacity: 0.78, ringLineWidth: 2.0, wireOpacity: 0.89,
                        tickHalfHeight: 6.25, tickOpacity: 0.73, spanOpacity: 0.81,
                        spanHeight: 3.0, spanShadowRadius: 4.5, windowSpanMs: 200,
                        tickStepMs: 25, breathePeriod: 2.7, breatheAmplitude: 1.035)
        case .threshold:
            return Look(haloDiameter: 46, haloOpacity: 0.58, ringRadius: 16,
                        ringOpacity: 1.0, ringLineWidth: 2.5, wireOpacity: 1.0,
                        tickHalfHeight: 7, tickOpacity: 0.85, spanOpacity: 1.0,
                        spanHeight: 3.5, spanShadowRadius: 5, windowSpanMs: 64,
                        tickStepMs: 10, breathePeriod: 2.0, breatheAmplitude: 1.03)
        case .fused:
            // The span has collapsed INTO the ring, so it carries no opacity
            // of its own; the reference ring steps out to the outer companion.
            return Look(haloDiameter: 50, haloOpacity: 0.55, ringRadius: 16,
                        ringOpacity: 1.0, ringLineWidth: 2.5, wireOpacity: 1.0,
                        tickHalfHeight: 7, tickOpacity: 0.85, spanOpacity: 0,
                        spanHeight: 3.5, spanShadowRadius: 5, windowSpanMs: 64,
                        tickStepMs: 10, breathePeriod: 2.7, breatheAmplitude: 1.03)
        case .locked:
            // Halo larger and brighter than the table's 40 @ 0.42: the settled
            // look carries the fusion itself, so a Reduce Motion user who
            // never sees the lock sequence still sees the bloom.
            return Look(haloDiameter: 74, haloOpacity: 0.55, ringRadius: 20,
                        ringOpacity: 1.0, ringLineWidth: 2.5, wireOpacity: 1.0,
                        tickHalfHeight: 7, tickOpacity: 0.85, spanOpacity: 0,
                        spanHeight: 3.5, spanShadowRadius: 5, windowSpanMs: 64,
                        tickStepMs: 10, breathePeriod: nil, breatheAmplitude: 1.03)
        case .dormant:
            return Look(haloDiameter: 0, haloOpacity: 0, ringRadius: 18,
                        ringOpacity: 0.30, ringLineWidth: 1.25, wireOpacity: 0.55,
                        tickHalfHeight: 4, tickOpacity: 0.35, spanOpacity: 0,
                        spanHeight: 1.5, spanShadowRadius: 3, windowSpanMs: nil,
                        tickStepMs: 250, breathePeriod: nil, breatheAmplitude: 1.0)
        }
    }

    /// The authored move between two rungs (spec §5 "Transitions"). One is in
    /// flight at a time: a new apply cancels whatever is running.
    enum Transition: Equatable {
        /// The stage did not move — a repaint with the same state and window.
        case none
        /// Climbed `steps` rungs: push-in, staggered, with a detent.
        case promotion(steps: Int)
        /// Gave ground: pull-back, halos leading, never brightening.
        case demotion
        /// Same rung, new position: pan and light travel on one clock.
        case slide
        /// `armed → open`: the run starts. All together, nothing earned yet.
        case wake
        /// `threshold → fused`: the span collapses into the ring.
        case fuse
        /// Anything → `dormant`: a bow-out fade.
        case bowOut
        /// Back to `armed` (Try again): pull-back, no settle-breath.
        case rearm
        /// The lock: four beats, 1.62 s.
        case lock
    }

    // MARK: - Geometry constants

    /// A strip, not a screen (owner ruling 2026-08-23: the answer plates are
    /// the hero): tall enough for the armed halo (106) plus the name stamps.
    ///
    /// 112 until the lights were scaled 1.8× (see `look(for:)`), and the 20 pt
    /// it grew by is the price of that scale rather than a separate decision —
    /// the halo is the tallest thing on the plate, and a halo that did not
    /// grow with its ring would have stopped reading as glow. It feeds
    /// `BTAlignmentWizardView.chassisHeight` 1:1, so it is also the sheet's
    /// height: every screen gets 20 pt taller, none of them reflows, and the
    /// stage goes from 27 % of the question sheet to 30 % — the ratio the
    /// answer plates' primacy actually rests on. Going further (a 2.2× scale
    /// wanted 152, i.e. 33 %) is what tips the stage into being the hero.
    static let stageHeight: CGFloat = 132
    private static let horizontalInset: CGFloat = 26
    /// **The wire sits on the plate's midline** (owner ruling 2026-08-24: on
    /// the intro "the group reads low"). It used to sit at 0.62 — i.e. 42 pt
    /// up from the bottom of a 112 pt plate — which put the armed halo's lower
    /// edge and the name stamps within a few points of the plate's bottom rim
    /// while a clear 27 pt band sat empty above the lights. Centred, the armed
    /// halo leaves ~19 pt top and bottom and the stamps still clear the rim by
    /// ~13 pt, so the instrument reads as a thing floating in its case on every
    /// screen. It stays a constant of the plate's own height, so the wire never
    /// moves between screens — the fixed chassis rule.
    private static let wireYFraction: CGFloat = 0.5
    /// The stage IS the plate: a rounded-12 `stagePlate` ground under it all.
    private static let plateCornerRadius: CGFloat = 12
    /// The window never zooms tighter than this, whatever the rung asks for.
    private static let minWindowSpanMs: Double = 40
    /// The sticky centre's dead-band: the interval plus this much of the
    /// window's own span on each side must escape before the camera pans.
    private static let stickyMarginFraction: Double = 0.15

    // MARK: - The emitter (ported knobs — see the type comment)

    /// How a light is drawn. `.still` is the pre-port ring, kept as the
    /// owner's A/B; the app runs `.living`.
    enum RingStyle { case still, living }
    var ringStyle: RingStyle = .living {
        didSet { reconcileBreathing() }
    }

    /// `emitters.js` `wobble`: the wavefront bends by ±3 % of its radius.
    /// razor: 0.03 is the website's own value, ported literally, and the
    /// 1.8× light scale (see `look(for:)`) is what makes it visible — at the
    /// spec's original 9–20 pt rings the wavefront's peak-to-peak travel was
    /// 1.1–2.4 Retina pixels. At 16–36 pt it is 1.9–4.3. The tight
    /// rungs are still the quietest, which is the intent: a belief that has
    /// narrowed should read calmer than one that has not. If the endgame
    /// ever needs more life than that, the upgrade path is to raise THIS
    /// number (the character is the two harmonics, not the amplitude), never
    /// to reshape the harmonics and never to grow the tight rungs into the
    /// wide ones' sizes.
    private static let wobble: CGFloat = 0.03
    /// `wobbleRate` — rad/s the three-lobe harmonic turns. The five-lobe one
    /// counter-turns at ×0.73, which is what keeps the lead drifting.
    private static let wobbleRate: Double = 0.5
    /// `squash`: y is shortened by this, so the rings read as slight ovals.
    /// A SETTLED property — present at pinned phase too.
    private static let squash: CGFloat = 1.12
    /// The breathing swell, `breatheFloor + breatheDepth · u`, at
    /// `breatheRate + breatheStep · f` rad/s — a ~63 s period, a slow swell
    /// rather than a pulse.
    private static let breatheFloor: Double = 0.4
    private static let breatheDepth: Double = 0.6
    private static let breatheRate: Double = 0.1
    private static let breatheStep: Double = 0.028
    /// How far the swell is allowed to move a light's opacity, as a fraction
    /// of the rung's settled value. The emitter's own swing is ±43 %, which
    /// would carry a light clean across a rung boundary and make the
    /// instrument lie about its certainty; the smallest gap between two
    /// rungs' halo opacities is ~13 %, so the modulation is held to half of
    /// that. This is the ONE ported number that is not the website's.
    private static let swellDepth: Float = 0.06
    /// Segments per living ring. At the largest radius the table now asks for
    /// (36 pt) the chord is 2.4 pt and the sagitta 0.02 pt, so the polygon is
    /// still an ellipse on any display.
    private static let ringSegments = 96

    /// `emitters.js`'s per-emitter seed: the reason the two lights never wave
    /// in step. `f` is the light's index — 0 target, 1 reference.
    private static func seed(_ f: Double) -> Double { f * 6.13 + 1.7 }

    /// The breathing swell as a MULTIPLIER on a settled opacity: 1 at pinned
    /// phase, 1 ± `swellDepth` while the clock runs.
    private static func swellFactor(phase: Double?, index f: Double) -> Float {
        guard let phase else { return 1 }
        let rate = breatheRate + breatheStep * f
        let unit = 0.5 + 0.5 * sin(phase * rate + seed(f) * 2.3)
        let swell = breatheFloor + breatheDepth * unit
        // Centre the emitter's [floor, floor + depth] band on its own mean,
        // then scale that ±1 down to the depth the ladder can afford.
        let centred = (swell - (breatheFloor + breatheDepth / 2)) / (breatheDepth / 2)
        return 1 + swellDepth * Float(centred)
    }

    // MARK: - Curves (spec §5)

    /// Promotion: banked progress landing in a notch.
    private static let ratchetCurve = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)
    /// Demotion: giving ground, settling, never snapping back.
    private static let settleCurve = CAMediaTimingFunction(controlPoints: 0.33, 0, 0.25, 1.0)
    /// Within-rung travel. §5 names the curve but not its control points, so
    /// this is AppKit's own ease-in-ease-out.
    private static let glideCurve = CAMediaTimingFunction(name: .easeInEaseOut)

    // MARK: - State

    private(set) var state: State = .dormant
    private(set) var rung: Rung = .dormant
    private var hasApplied = false

    /// Fired on every rung change, and once on the first apply — the readout's
    /// status word and the window's room spill both ride this.
    ///
    /// A handler assigned AFTER that first apply (the window controller wires
    /// itself up once the wizard view — which applies `.armed` in its own
    /// init — already exists) is seeded with the live rung right here:
    /// `hasReportedRung` suppresses the re-report, so without this the intro's
    /// `.armed` spill never arrived.
    var onRungChange: ((Rung) -> Void)? {
        didSet { if hasApplied { onRungChange?(rung) } }
    }
    /// Fired when the lock sequence has settled (1.62 s script, cue at 1.44 s;
    /// synchronously under Reduce Motion and headless) — the driver's cue to
    /// crossfade the kept line in.
    var onLockedSettled: (() -> Void)?

    private var lastTransition: Transition = .none

    // MARK: - Layers

    /// The fixed dark plate the whole instrument sits on.
    private let plateLayer = CALayer()
    /// The wire, in two halves: OUTSIDE the field, because the rail does not
    /// move with the camera — it is the fixed thing the ruler slides under.
    /// Two layers so that, fused and locked, each side can carry its own
    /// voice up to the ring (green from the left, magenta from the right)
    /// instead of one rule running straight through it.
    private let wireLeft = CAShapeLayer()
    private let wireRight = CAShapeLayer()
    /// Everything the camera moves: ticks, span, halos, rings. Clipped, so a
    /// seeded push-in reads as an iris rather than as content spilling out.
    private let fieldLayer = CALayer()
    private let tickLayer = CAShapeLayer()
    /// The credible interval: a `syncSignal → partySignal` bar between the two
    /// lights, with a low `fuseWhite` glow.
    private let spanLayer = CAGradientLayer()
    private let targetHalo = CALayer()
    private let targetRing = CAShapeLayer()
    private let referenceHalo = CALayer()
    private let referenceRing = CAShapeLayer()

    private static let breatheKey = "alignmentStage.breathe"
    /// `CATransition` is filed under this literal reserved key whatever key is
    /// passed to `add(_:forKey:)` — see `AudioutSharedUI/AGENTS.md`.
    private static let catransitionKey = "transition"

    /// Transients (bloom, gather bars) live here so one cancel removes them
    /// all; `transientGeneration` invalidates their deferred cleanups.
    private var transientLayers: [CALayer] = []
    private var transientGeneration = 0

    /// The window of value space the wire currently shows, kept so `layout()`
    /// can re-map settled positions after a resize.
    private(set) var displayRange: ClosedRange<Double> = -500...500
    private var lastTickStep: Double?

    /// The two speakers' names, stamped under their lights while ARMED — the
    /// intro is where the user learns which colour is which speaker. Real
    /// text fields (tokens resolve, VoiceOver reads them), hidden on every
    /// other rung.
    var lightNames: (target: String, reference: String) = ("", "") {
        didSet { needsLayout = true }
    }
    private let targetNameLabel = NSTextField(labelWithString: "")
    private let referenceNameLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false

        plateLayer.cornerRadius = Self.plateCornerRadius
        plateLayer.borderWidth = 1
        for wire in [wireLeft, wireRight] {
            wire.fillColor = nil
            wire.lineWidth = 1.5
            wire.lineCap = .round
        }
        fieldLayer.masksToBounds = true
        // Anchor at the origin so the camera transform is a plain
        // `x → sx·x + tx` in the view's own coordinates.
        fieldLayer.anchorPoint = .zero
        tickLayer.fillColor = nil
        tickLayer.lineWidth = 1
        spanLayer.startPoint = CGPoint(x: 0, y: 0.5)
        spanLayer.endPoint = CGPoint(x: 1, y: 0.5)
        spanLayer.shadowOffset = .zero
        for halo in [targetHalo, referenceHalo] {
            halo.contentsGravity = .resize
        }
        for ring in [targetRing, referenceRing] {
            ring.fillColor = nil
        }
        // Halos under the span, rings above it, so the fused state reads as
        // one glowing bead on the wire rather than a bar through a ring.
        for sub in [tickLayer, targetHalo, referenceHalo,
                    spanLayer, targetRing, referenceRing] {
            fieldLayer.addSublayer(sub)
        }
        for sub in [plateLayer, wireLeft, wireRight, fieldLayer] {
            layer?.addSublayer(sub)
        }
        for label in [targetNameLabel, referenceNameLabel] {
            label.alignment = .center
            label.lineBreakMode = .byTruncatingTail
            addSubview(label)
        }

        // The three live re-resolution triggers (see the type comment).
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(accessibilityDisplayOptionsDidChange),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(accentStyleDidChange),
            name: Tokens.accentStyleDidChangeNotification, object: nil)

        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.stageHeight)
    }

    // MARK: - Apply

    /// Render `state`. The rung is resolved, the transition between the old
    /// rung and the new one is dispatched, and the settled model lands
    /// immediately underneath whatever is animating.
    func apply(_ newState: State, animated: Bool) {
        let previousState = state
        let previousRung = rung
        let newRung = Rung.resolve(newState, previous: previousRung)
        let newWindow = Self.displayWindow(for: newState, rung: newRung,
                                           previous: displayRange)

        // No-op guard: an identical repaint (the reference picker rebuilding
        // its options, an appearance flip) re-stamps colors and NOTHING else.
        // Replaying a transition here is what made the stage twitch on every
        // unrelated repaint.
        if hasApplied, newState == previousState, newWindow == displayRange {
            lastTransition = .none
            stampColors()
            return
        }

        let previousWindow = displayRange
        state = newState
        rung = newRung
        displayRange = newWindow

        let transition = Self.transition(previousState: previousState,
                                         previousRung: previousRung,
                                         newState: newState, newRung: newRung,
                                         isFirstApply: !hasApplied)
        lastTransition = transition
        hasApplied = true

        stampColors()
        cancelInFlight()
        needsLayout = true
        play(transition, previousWindow: previousWindow,
             previousRung: previousRung,
             animated: animated && !reduceMotion && !HeadlessRuntime.isActive)
        reconcileBreathing()
        if newRung != previousRung || !hasReportedRung {
            hasReportedRung = true
            onRungChange?(newRung)
        }
    }

    /// The rung is reported once on the first apply even when it hasn't
    /// changed, so a consumer never has to seed itself.
    private var hasReportedRung = false

    /// Which authored move gets us from one rung to the next. Ordered: the
    /// state-owned edges first, then the ladder compare.
    private static func transition(previousState: State, previousRung: Rung,
                                   newState: State, newRung: Rung,
                                   isFirstApply: Bool) -> Transition {
        if newRung == .locked && previousRung != .locked { return .lock }
        if newRung == .dormant { return .bowOut }
        if isFirstApply { return .wake }
        if newRung == .armed { return .rearm }
        if previousRung == .armed && newRung == .open { return .wake }
        if newRung == .fused && previousRung != .fused { return .fuse }

        if newRung.ladderIndex > previousRung.ladderIndex {
            return .promotion(steps: newRung.ladderIndex - previousRung.ladderIndex)
        }
        if newRung.ladderIndex < previousRung.ladderIndex { return .demotion }

        // Same rung. A belief that WIDENED gave ground even though it stayed
        // on its rung — ⌘Z Back is exactly this — and gave-ground always plays
        // the demotion, never a brightening slide.
        if let was = intervalWidth(previousState), let now = intervalWidth(newState),
           now > was + 0.01 {
            return .demotion
        }
        return .slide
    }

    private static func intervalWidth(_ state: State) -> Double? {
        switch state {
        case .armed(let range): return range.upperBound - range.lowerBound
        case .question(let interval, _): return interval.upperBound - interval.lowerBound
        case .listening, .locked: return 0
        case .dormant: return nil
        }
    }

    // MARK: - The window (sticky centre, quantized spans)

    /// Where the wire's window sits for a state. The SPAN is the rung's (spec
    /// §5's quantized ladder), never derived from the interval, so the ruler
    /// re-gears on rung changes alone. The CENTRE is sticky: it only re-frames
    /// when the interval plus its margin would escape, and a re-frame is a
    /// pan, so a within-rung answer slides the lights instead of moving the
    /// world under them.
    private static func displayWindow(for state: State, rung: Rung,
                                      previous: ClosedRange<Double>) -> ClosedRange<Double> {
        let interval: ClosedRange<Double>
        let range: ClosedRange<Double>
        switch state {
        case .armed(let r):
            return r
        case .question(let i, let r):
            interval = i
            range = r
        case .listening(let v, let r), .locked(let v, let r):
            interval = v...v
            range = r
        case .dormant:
            return previous
        }
        let rangeSpan = range.upperBound - range.lowerBound
        guard let quantized = look(for: rung).windowSpanMs else { return range }
        let span = Swift.min(Swift.max(quantized, minWindowSpanMs), rangeSpan)

        var lower: Double
        var upper: Double
        let previousSpan = previous.upperBound - previous.lowerBound
        let margin = span * stickyMarginFraction
        let holds = abs(previousSpan - span) < 0.01
            && interval.lowerBound - margin >= previous.lowerBound
            && interval.upperBound + margin <= previous.upperBound
        if holds {
            lower = previous.lowerBound
            upper = previous.upperBound
        } else {
            let centre = (interval.lowerBound + interval.upperBound) / 2
            lower = centre - span / 2
            upper = centre + span / 2
        }
        // Clamp by sliding, so the window never shrinks against an edge.
        if lower < range.lowerBound {
            upper = Swift.min(upper + (range.lowerBound - lower), range.upperBound)
            lower = range.lowerBound
        }
        if upper > range.upperBound {
            lower = Swift.max(lower - (upper - range.upperBound), range.lowerBound)
            upper = range.upperBound
        }
        return lower...upper
    }

    // MARK: - Geometry

    private var wireY: CGFloat { bounds.height * (1 - Self.wireYFraction) }

    /// The window widened about its centre by the rung's ruler fill — what
    /// the wire actually maps. `displayRange` stays the model (and the test
    /// seams' truth); this is only how it lands on the wire.
    private static func mapped(_ window: ClosedRange<Double>, rung: Rung) -> ClosedRange<Double> {
        let fill = Double(look(for: rung).rulerFill)
        guard fill < 1 else { return window }
        let centre = (window.lowerBound + window.upperBound) / 2
        let half = (window.upperBound - window.lowerBound) / 2 / fill
        return (centre - half)...(centre + half)
    }

    private var mappedRange: ClosedRange<Double> { Self.mapped(displayRange, rung: rung) }

    private func xFor(_ ms: Double) -> CGFloat {
        let mapped = mappedRange
        let span = mapped.upperBound - mapped.lowerBound
        guard span > 0 else { return bounds.midX }
        let fraction = (ms - mapped.lowerBound) / span
        let usable = bounds.width - 2 * Self.horizontalInset
        return Self.horizontalInset + usable * CGFloat(fraction)
    }

    /// The candidate range the state carries — the ruler never draws a tick
    /// past it, whatever the wire maps.
    private var candidateRange: ClosedRange<Double>? {
        switch state {
        case .armed(let range): return range
        case .question(_, let range), .listening(_, let range), .locked(_, let range): return range
        case .dormant: return nil
        }
    }

    /// The two light values for the current state — the interval's ends, or
    /// one point once they have fused.
    private func lightValues() -> (low: Double, high: Double) {
        switch state {
        case .armed(let range):
            return (range.lowerBound, range.upperBound)
        case .question(let interval, _):
            return (interval.lowerBound, interval.upperBound)
        case .listening(let value, _), .locked(let value, _):
            return (value, value)
        case .dormant:
            let mid = (displayRange.lowerBound + displayRange.upperBound) / 2
            return (mid, mid)
        }
    }

    override func layout() {
        super.layout()
        applyGeometry(Self.instantScript)
        layoutNameStamps()
    }

    /// The armed rung's two name stamps, centred under their lights in the
    /// micro-label voice on `stageInk`.
    private func layoutNameStamps() {
        let armed: Bool
        if case .armed = state { armed = true } else { armed = false }
        let (lowMs, highMs) = lightValues()
        let look = Self.look(for: rung)
        // Un-flipped view: "under the light" is LOWER y — just below the ring.
        let ringBottom = wireY - look.ringRadius - Self.nameStampGap
        let width = (bounds.width - 2 * Self.horizontalInset) / 2 - Self.nameStampGap
        for (label, x, name) in [(targetNameLabel, xFor(lowMs), lightNames.target),
                                 (referenceNameLabel, xFor(highMs), lightNames.reference)] {
            label.isHidden = !armed || name.isEmpty
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byTruncatingTail
            label.attributedStringValue = NSAttributedString(
                string: name,
                attributes: [.font: Tokens.Font.microLabel,
                             .foregroundColor: Tokens.Color.stageInk.withAlphaComponent(0.6),
                             .paragraphStyle: paragraph])
            let height = label.intrinsicContentSize.height
            // Centred under the light, but never past the plate's own edge.
            let minX = Self.plateCornerRadius
            let maxX = bounds.width - Self.plateCornerRadius - width
            let originX = Swift.min(Swift.max(x - width / 2, minX), maxX)
            label.frame = NSRect(x: originX.rounded(), y: (ringBottom - height).rounded(),
                                 width: width, height: height)
        }
    }

    private static let nameStampGap: CGFloat = 6

    /// The plate and the field fill the view. Kept off the animated path —
    /// the camera moves the field's TRANSFORM, never its bounds.
    private func layoutContainerLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        plateLayer.frame = bounds
        fieldLayer.bounds = CGRect(origin: .zero, size: bounds.size)
        fieldLayer.position = .zero
        CATransaction.commit()
    }

    // MARK: - Transition scripts

    /// The timing of one authored move: a `(duration, delay)` leg per element,
    /// plus the two flourishes that ride over them.
    private struct Script {
        typealias Leg = (duration: TimeInterval, delay: TimeInterval)
        var curve: CAMediaTimingFunction
        var camera: Leg
        var rings: Leg
        var halos: Leg
        var span: Leg
        var wire: Leg
        /// When the ruler's re-gear crossfade lands; `nil` = no crossfade.
        var tickCrossfade: TimeInterval?
        /// Promotion only: the notch the push-in lands in.
        var detentAt: TimeInterval?
        /// Demotion only: the halo's exhale as it comes to rest.
        var settleBreathAt: TimeInterval?
        var seedsCamera: Bool

        func scaled(by factor: Double) -> Script {
            guard factor != 1 else { return self }
            func s(_ leg: Leg) -> Leg { (leg.duration * factor, leg.delay * factor) }
            return Script(curve: curve, camera: s(camera), rings: s(rings),
                          halos: s(halos), span: s(span), wire: s(wire),
                          tickCrossfade: tickCrossfade.map { $0 * factor },
                          detentAt: detentAt.map { $0 * factor },
                          settleBreathAt: settleBreathAt.map { $0 * factor },
                          seedsCamera: seedsCamera)
        }
    }

    /// Everything at rest, right now — Reduce Motion, headless, a resize.
    private static let instantScript = Script(
        curve: glideCurve, camera: (0, 0), rings: (0, 0), halos: (0, 0),
        span: (0, 0), wire: (0, 0), tickCrossfade: nil, detentAt: nil,
        settleBreathAt: nil, seedsCamera: false)

    /// **Promotion — 0.62 s, RATCHET.** The push-in leads, the rings follow,
    /// the halos lag most, and the detent lands as the push-in settles: the
    /// stage banking progress the user just earned.
    private static let promotionScript = Script(
        curve: ratchetCurve, camera: (0.34, 0), rings: (0.28, 0.06),
        halos: (0.32, 0.10), span: (0.30, 0.08), wire: (0.34, 0),
        tickCrossfade: 0.28, detentAt: 0.34, settleBreathAt: nil,
        seedsCamera: true)

    /// **Demotion — 0.86 s, SETTLE.** Ordering inverted from the promotion:
    /// the halos SOFTEN first, the camera pulls back over 0.62 s, the rings
    /// and span follow, the ruler briefly loses focus, and it ends on a
    /// settle-breath. Nothing brightens at any frame; there is no detent.
    private static let demotionScript = Script(
        curve: settleCurve, camera: (0.62, 0), rings: (0.34, 0.10),
        halos: (0.34, 0), span: (0.34, 0.12), wire: (0.62, 0),
        tickCrossfade: 0.28, detentAt: nil, settleBreathAt: 0.62,
        seedsCamera: true)

    /// **Slide — 0.42 s, GLIDE.** Within-rung position only: the pan
    /// compensation and the lights' travel share one duration and one curve,
    /// or they would visibly disagree.
    private static let slideScript = Script(
        curve: glideCurve, camera: (0.42, 0), rings: (0.42, 0), halos: (0.42, 0),
        span: (0.42, 0), wire: (0.42, 0), tickCrossfade: nil, detentAt: nil,
        settleBreathAt: nil, seedsCamera: true)

    /// **Wake — 0.45 s.** `armed → open`, all together: no stagger and no
    /// detent, because nothing has been earned yet.
    private static let wakeScript = Script(
        curve: ratchetCurve, camera: (0.45, 0), rings: (0.45, 0), halos: (0.45, 0),
        span: (0.45, 0), wire: (0.45, 0), tickCrossfade: 0.45 / 2, detentAt: nil,
        settleBreathAt: nil, seedsCamera: false)

    /// **Fuse — 0.40 s.** The span collapses into the ring and the reference
    /// ring steps out to the outer companion.
    private static let fuseScript = Script(
        curve: glideCurve, camera: (0.40, 0), rings: (0.40, 0), halos: (0.40, 0),
        span: (0.40, 0), wire: (0.40, 0), tickCrossfade: 0.20, detentAt: nil,
        settleBreathAt: nil, seedsCamera: true)

    /// **Bow-out — 0.30 s.** Everything fades to the plate's rule tone.
    private static let bowOutScript = Script(
        curve: settleCurve, camera: (0.30, 0), rings: (0.30, 0), halos: (0.30, 0),
        span: (0.30, 0), wire: (0.30, 0), tickCrossfade: nil, detentAt: nil,
        settleBreathAt: nil, seedsCamera: false)

    /// **Re-arm — 0.50 s.** Try again: a pull-back to wide open, with no
    /// settle-breath — the run has not given ground, it has been reset.
    private static let rearmScript = Script(
        curve: settleCurve, camera: (0.50, 0), rings: (0.50, 0), halos: (0.50, 0),
        span: (0.50, 0), wire: (0.50, 0), tickCrossfade: 0.25, detentAt: nil,
        settleBreathAt: nil, seedsCamera: true)

    private static func script(for transition: Transition) -> Script {
        switch transition {
        case .none: return instantScript
        case .promotion(let steps):
            // Multi-rung: the same script, stretched — two rungs at once is a
            // bigger move and has to be given the time to read as one.
            return promotionScript.scaled(by: steps >= 2 ? 1.15 : 1)
        case .demotion: return demotionScript
        case .slide: return slideScript
        case .wake: return wakeScript
        case .fuse: return fuseScript
        case .bowOut: return bowOutScript
        case .rearm: return rearmScript
        case .lock: return instantScript   // the lock runs its own four beats
        }
    }

    // MARK: - Playing a transition

    private func play(_ transition: Transition, previousWindow: ClosedRange<Double>,
                      previousRung: Rung, animated: Bool) {
        guard transition != .none else { return }
        guard animated else {
            applyGeometry(Self.instantScript)
            // Reduce Motion still CHANGES look-state — it removes the travel,
            // not the information. One short crossfade carries the change so
            // the ruler doesn't teleport; headless gets nothing at all.
            if reduceMotion && !HeadlessRuntime.isActive && previousRung != rung {
                let fade = CATransition()
                fade.duration = transition == .lock ? 0.15 : 0.12
                fieldLayer.add(fade, forKey: Self.catransitionKey)
            }
            if transition == .lock { onLockedSettled?() }
            return
        }
        if transition == .lock {
            playLock()
            return
        }
        let script = Self.script(for: transition)
        if script.seedsCamera {
            seedCamera(from: Self.mapped(previousWindow, rung: previousRung), script: script)
        }
        applyGeometry(script)
    }

    /// Seed the field with the transform that maps the NEW window's screen
    /// positions back onto the OLD window's, then let it animate to identity.
    /// That is the camera gesture: zooming in becomes a push-in, zooming out a
    /// pull-back, and a pure pan becomes a translate.
    private func seedCamera(from previousWindow: ClosedRange<Double>, script: Script) {
        let displayRange = mappedRange
        let oldSpan = previousWindow.upperBound - previousWindow.lowerBound
        let newSpan = displayRange.upperBound - displayRange.lowerBound
        let usable = Double(bounds.width - 2 * Self.horizontalInset)
        guard oldSpan > 0, newSpan > 0, usable > 0, script.camera.duration > 0 else { return }
        // razor: the scale is clamped to 0.30…3.33. A single apply that jumps
        // the window more than ~3.3× would seed a frame that is either an
        // unreadable smear or a speck, and the gesture stops reading as one
        // camera move. Upgrade path is to CHAIN two gestures for such a jump,
        // not to widen the clamp.
        let sx = Swift.min(Swift.max(newSpan / oldSpan, 0.30), 3.33)
        let tx = Double(Self.horizontalInset) * (1 - sx)
            + usable * (displayRange.lowerBound - previousWindow.lowerBound) / oldSpan
        guard abs(sx - 1) > 0.0001 || abs(tx) > 0.01 else { return }

        // Row-vector convention: x' = m11·x + m41.
        var seeded = CATransform3DIdentity
        seeded.m11 = CGFloat(sx)
        seeded.m41 = CGFloat(tx)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fieldLayer.transform = CATransform3DIdentity
        CATransaction.commit()

        let camera = CABasicAnimation(keyPath: "transform")
        camera.fromValue = NSValue(caTransform3D: seeded)
        camera.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        camera.beginTime = CACurrentMediaTime() + script.camera.delay
        camera.duration = script.camera.duration
        camera.timingFunction = script.curve
        camera.fillMode = .backwards
        fieldLayer.add(camera, forKey: "transform")
    }

    /// Write every settled model value, and — when the script has time in it —
    /// animate each element into place on its own leg.
    private func applyGeometry(_ script: Script) {
        guard bounds.width > 0 else { return }
        layoutContainerLayers()
        let look = Self.look(for: rung)
        let (lowMs, highMs) = lightValues()
        let lowX = xFor(lowMs)
        let highX = xFor(highMs)
        let y = wireY
        let curve = script.curve

        let fused = rung == .fused
        let locked = rung == .locked
        // Inside threshold the interval still closes from 12 ms to the
        // run's 6 ms stop — the hardest-clicked stretch. The ring thickens
        // and the halo brightens with it, so the top rung is not a frozen
        // frame.
        let progress = thresholdProgress
        let ringLineWidth = look.ringLineWidth + 0.5 * progress
        let haloOpacity = look.haloOpacity + 0.10 * Float(progress)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tickLayer.frame = CGRect(origin: .zero, size: bounds.size)
        // Fused/locked: the wire stops short of the ring on both sides, so
        // the rule never runs through the one light the run has earned.
        let gap: CGFloat = fused || locked ? look.ringRadius + 6 : 0
        let midX = fused || locked ? lowX : bounds.midX
        let left = CGMutablePath()
        left.move(to: CGPoint(x: Self.horizontalInset, y: y))
        left.addLine(to: CGPoint(x: Swift.max(midX - gap, Self.horizontalInset), y: y))
        let right = CGMutablePath()
        right.move(to: CGPoint(x: Swift.min(midX + gap, bounds.width - Self.horizontalInset), y: y))
        right.addLine(to: CGPoint(x: bounds.width - Self.horizontalInset, y: y))
        wireLeft.path = left
        wireRight.path = right
        CATransaction.commit()

        for wire in [wireLeft, wireRight] {
            animate(layer: wire, keyPath: "opacity", to: look.wireOpacity,
                    leg: script.wire, curve: curve)
        }

        layoutTicks(look: look, y: y, lightXs: [lowX, highX],
                    clearance: look.ringRadius + 3, script: script, curve: curve)

        // The span: a gradient bar between the lights, invisible once fused.
        let spanWidth = Swift.max(highX - lowX, 0)
        animate(layer: spanLayer, keyPath: "bounds",
                to: NSValue(rect: CGRect(x: 0, y: 0, width: spanWidth,
                                         height: look.spanHeight)),
                leg: script.span, curve: curve)
        animate(layer: spanLayer, keyPath: "position",
                to: NSValue(point: CGPoint(x: (lowX + highX) / 2, y: y)),
                leg: script.span, curve: curve)
        animate(layer: spanLayer, keyPath: "cornerRadius", to: look.spanHeight / 2,
                leg: script.span, curve: curve)
        animate(layer: spanLayer, keyPath: "shadowRadius", to: look.spanShadowRadius,
                leg: script.span, curve: curve)
        animate(layer: spanLayer, keyPath: "opacity", to: look.spanOpacity,
                leg: script.span, curve: curve)

        // The two lights. Fused, the reference ring steps OUT to the outer
        // companion at reduced weight and its halo hides, so "as one" still
        // shows both parties; locked, the reference is gone entirely.
        layoutLight(halo: targetHalo, ring: targetRing,
                    centre: CGPoint(x: lowX, y: y),
                    haloDiameter: look.haloDiameter,
                    haloOpacity: haloOpacity,
                    ringRadius: look.ringRadius,
                    ringOpacity: look.ringOpacity,
                    ringLineWidth: ringLineWidth,
                    script: script, curve: curve)
        layoutLight(halo: referenceHalo, ring: referenceRing,
                    centre: CGPoint(x: highX, y: y),
                    haloDiameter: look.haloDiameter,
                    haloOpacity: fused || locked ? 0 : haloOpacity,
                    ringRadius: fused ? look.ringRadius + 6 : look.ringRadius,
                    // ×0.85, not the table's ×0.55: over the green halo the
                    // outer ring measured dusty mauve, not magenta.
                    ringOpacity: locked ? 0 : (fused ? look.ringOpacity * 0.85
                                                     : look.ringOpacity),
                    ringLineWidth: ringLineWidth,
                    script: script, curve: curve)

        if let detentAt = script.detentAt { fireDetent(at: detentAt, look: look) }
        if let breathAt = script.settleBreathAt {
            fireSettleBreath(at: breathAt, look: look)
        }
    }

    /// 0 at the threshold rung's entry (half-width 12) rising to 1 at the
    /// run's propose stop (8); 0 on every other rung.
    private var thresholdProgress: CGFloat {
        guard rung == .threshold, case .question(let interval, _) = state else { return 0 }
        let halfWidth = (interval.upperBound - interval.lowerBound) / 2
        let floor = BTAlignmentWizardSession.proposeHalfWidthMs
        let entry = 12.0
        guard entry > floor else { return 0 }
        return CGFloat(Swift.min(Swift.max((entry - halfWidth) / (entry - floor), 0), 1))
    }

    private func layoutLight(halo: CALayer, ring: CAShapeLayer, centre: CGPoint,
                             haloDiameter: CGFloat, haloOpacity: Float,
                             ringRadius: CGFloat, ringOpacity: Float,
                             ringLineWidth: CGFloat,
                             script: Script, curve: CAMediaTimingFunction) {
        // The swell modulates AROUND these, so they are recorded rather than
        // read back off the layer — compounding a factor on a layer's own
        // value would walk the light's brightness away from its rung.
        settledOpacity[ObjectIdentifier(halo)] = haloOpacity
        settledOpacity[ObjectIdentifier(ring)] = ringOpacity

        animate(layer: halo, keyPath: "bounds",
                to: NSValue(rect: Self.haloBox(haloDiameter)),
                leg: script.halos, curve: curve)
        animate(layer: halo, keyPath: "position", to: NSValue(point: centre),
                leg: script.halos, curve: curve)
        animate(layer: halo, keyPath: "opacity", to: haloOpacity,
                leg: script.halos, curve: curve)

        let box = CGRect(x: 0, y: 0, width: ringRadius * 2, height: ringRadius * 2)
        animate(layer: ring, keyPath: "bounds", to: NSValue(rect: box),
                leg: script.rings, curve: curve)
        animate(layer: ring, keyPath: "position", to: NSValue(point: centre),
                leg: script.rings, curve: curve)
        animate(layer: ring, keyPath: "lineWidth", to: ringLineWidth,
                leg: script.rings, curve: curve)
        // The stroke straddles the path, so the circle is inset by half the
        // line width — a fixed 1 pt inset made a 2 pt ring overflow its box.
        animatePath(ring: ring, to: Self.ringPath(in: box, lineWidth: ringLineWidth),
                    leg: script.rings, curve: curve)
        animate(layer: ring, keyPath: "opacity", to: ringOpacity,
                leg: script.rings, curve: curve)
    }

    /// `animate`'s typed twin for the one property KVC can't carry: a
    /// `CGPathRef` is a CF pointer, so it is read and written directly and
    /// only the ANIMATION takes it as a value.
    private func animatePath(ring: CAShapeLayer, to path: CGPath,
                             leg: Script.Leg, curve: CAMediaTimingFunction) {
        let from = (ring.presentation() ?? ring).path
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.path = path
        CATransaction.commit()
        guard leg.duration > 0 else { return }
        let animation = CABasicAnimation(keyPath: "path")
        animation.fromValue = from
        animation.toValue = path
        animation.beginTime = CACurrentMediaTime() + leg.delay
        animation.duration = leg.duration
        animation.timingFunction = curve
        animation.fillMode = .backwards
        ring.add(animation, forKey: "path")
    }

    /// One light's wavefront. At PINNED phase this is the settled model — a
    /// plain ellipse, squashed in y — and every existing caller gets it by
    /// default. Given a phase, the radius is bent by the emitter's two
    /// harmonics, phased by the light's own seed.
    private static func ringPath(in box: CGRect, lineWidth: CGFloat,
                                 phase: Double? = nil, index f: Double = 0) -> CGPath {
        let inset = box.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        let squashed = CGRect(x: inset.midX - inset.width / 2,
                              y: inset.midY - inset.height / squash / 2,
                              width: inset.width, height: inset.height / squash)
        guard let phase, wobble > 0 else {
            return CGPath(ellipseIn: squashed, transform: nil)
        }
        // The GLSL measures r in SQUASHED space and takes θ there too, so the
        // bend is applied to the circle and the squash lands on the result.
        let radius = inset.width / 2
        let seed = self.seed(f)
        let path = CGMutablePath()
        for step in 0..<ringSegments {
            let theta = Double(step) / Double(ringSegments) * 2 * .pi
            let bend = (sin(3 * theta + phase * wobbleRate + seed)
                        + 0.5 * sin(5 * theta - phase * wobbleRate * 0.73 + seed * 1.3)) / 1.5
            let r = radius * (1 + wobble * CGFloat(bend))
            let point = CGPoint(x: inset.midX + r * CGFloat(cos(theta)),
                                y: inset.midY + r * CGFloat(sin(theta)) / squash)
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    /// A halo's box. The halo is bitmap contents, so it wears the emitter's
    /// squash in its BOUNDS rather than in a path — same oval, other
    /// mechanism.
    private static func haloBox(_ diameter: CGFloat) -> CGRect {
        CGRect(x: 0, y: 0, width: diameter, height: diameter / squash)
    }

    /// Scale ticks along the wire. The step is the RUNG's, so every rung
    /// change re-gears the ruler; a step change crossfades so it reads as
    /// re-gearing rather than as jumping.
    private func layoutTicks(look: Look, y: CGFloat, lightXs: [CGFloat], clearance: CGFloat,
                             script: Script, curve: CAMediaTimingFunction) {
        let window = mappedRange
        let span = window.upperBound - window.lowerBound
        guard span > 0 else { return }
        // Dormant freezes the window where it was (spec: everything to
        // `stageRule`, not gone) — re-gearing it to 250 ms emptied a 64 ms
        // window of every tick.
        let step = rung == .dormant ? (lastTickStep ?? look.tickStepMs) : look.tickStepMs
        let path = CGMutablePath()
        var ms = (window.lowerBound / step).rounded(.up) * step
        while ms <= window.upperBound {
            defer { ms += step }
            if let range = candidateRange, !range.contains(ms) { continue }
            let x = xFor(ms)
            // A tick under a light would cross its ring.
            if lightXs.contains(where: { abs($0 - x) < clearance }) { continue }
            path.move(to: CGPoint(x: x, y: y - look.tickHalfHeight))
            path.addLine(to: CGPoint(x: x, y: y + look.tickHalfHeight))
        }
        if let at = script.tickCrossfade, let last = lastTickStep, last != step {
            let fade = CATransition()
            fade.beginTime = CACurrentMediaTime() + at
            fade.duration = 0.3
            fade.fillMode = .backwards
            tickLayer.add(fade, forKey: Self.catransitionKey)
        }
        lastTickStep = step
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tickLayer.path = path
        CATransaction.commit()
        animate(layer: tickLayer, keyPath: "opacity", to: look.tickOpacity,
                leg: script.span, curve: curve)
    }

    /// The one animation primitive: write the settled model value, then run a
    /// `CABasicAnimation` from wherever the layer VISIBLY was to it. Reading
    /// `from` off the presentation layer is what lets a new transition
    /// retarget mid-flight without a snap.
    private func animate(layer: CALayer, keyPath: String, to value: Any,
                         leg: Script.Leg, curve: CAMediaTimingFunction) {
        let from = (layer.presentation() ?? layer).value(forKeyPath: keyPath)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(value, forKeyPath: keyPath)
        CATransaction.commit()
        guard leg.duration > 0 else { return }
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = value
        animation.beginTime = CACurrentMediaTime() + leg.delay
        animation.duration = leg.duration
        animation.timingFunction = curve
        // Backwards fill holds the FROM value through the delay, so a
        // staggered leg waits in place instead of jumping ahead.
        animation.fillMode = .backwards
        layer.add(animation, forKey: keyPath)
    }

    /// A transient that rides over the settled model and leaves it untouched:
    /// out to `peak` and back to the value the layer already holds.
    private func pulse(layer: CALayer, keyPath: String, peak: Any, settled: Any,
                       at begin: TimeInterval, duration: TimeInterval,
                       key: String) {
        let keyframe = CAKeyframeAnimation(keyPath: keyPath)
        keyframe.values = [settled, peak, settled]
        keyframe.keyTimes = [0, 0.5, 1]
        keyframe.beginTime = CACurrentMediaTime() + begin
        keyframe.duration = duration
        keyframe.timingFunction = Self.glideCurve
        keyframe.fillMode = .backwards
        layer.add(keyframe, forKey: key)
    }

    // MARK: - Flourishes

    /// The promotion's DETENT: the notch the push-in lands in. The span's glow
    /// swells and takes the instrument's own gold voice for a moment, and the
    /// target ring overshoots its new weight by a hair. Span shadow only — the
    /// identity hues never move.
    private func fireDetent(at begin: TimeInterval, look: Look) {
        guard window != nil else { return }
        pulse(layer: spanLayer, keyPath: "shadowRadius", peak: CGFloat(7),
              settled: look.spanShadowRadius, at: begin, duration: 0.2,
              key: "detent.shadowRadius")
        pulse(layer: spanLayer, keyPath: "shadowColor", peak: resolvedDetentAccent,
              settled: resolvedSpanGlow, at: begin, duration: 0.1,
              key: "detent.shadowColor")
        pulse(layer: targetRing, keyPath: "lineWidth",
              peak: look.ringLineWidth + 0.4, settled: look.ringLineWidth,
              at: begin, duration: 0.2, key: "detent.lineWidth")
    }

    /// The demotion's closing exhale — the halo swells a touch and comes back
    /// to the table. It is the only thing that moves after the pull-back, and
    /// it never goes brighter, only wider.
    ///
    /// It rides the halo's BOUNDS, not `transform.scale`, because the idle
    /// breathing owns that keypath: the reconcile re-adds breathing right
    /// after a transition is dispatched, so a scale-based breath would be
    /// composited away the instant it was created.
    private func fireSettleBreath(at begin: TimeInterval, look: Look) {
        guard window != nil, look.haloDiameter > 0 else { return }
        let settled = Self.haloBox(look.haloDiameter)
        let swelled = Self.haloBox(look.haloDiameter * 1.04)
        for halo in [targetHalo, referenceHalo] {
            pulse(layer: halo, keyPath: "bounds", peak: NSValue(rect: swelled),
                  settled: NSValue(rect: settled), at: begin, duration: 0.24,
                  key: "settleBreath")
        }
    }

    // MARK: - The lock (spec §5, four beats, 1.62 s — input never gated)

    private static let lockDuration: TimeInterval = 1.62
    private static let lockSettledAt: TimeInterval = 1.44

    private func playLock() {
        let look = Self.look(for: .locked)
        let (value, _) = lightValues()
        let centre = CGPoint(x: xFor(value), y: wireY)

        // Beat 1 — merge (0.14–0.70): the reference ring contracts onto the
        // target's radius and both reach full weight; once they are
        // pixel-identical the reference is removed invisibly.
        let mergeLeg: Script.Leg = (duration: 0.56, delay: 0.14)
        let script = Script(curve: Self.settleCurve, camera: (0, 0),
                            rings: mergeLeg, halos: (0.42, 0.78),
                            span: mergeLeg, wire: mergeLeg, tickCrossfade: nil,
                            detentAt: nil, settleBreathAt: nil, seedsCamera: false)
        applyGeometry(script)
        animate(layer: referenceRing, keyPath: "opacity", to: Float(0),
                leg: (duration: 0.02, delay: 0.70), curve: Self.settleCurve)

        guard window != nil else {
            onLockedSettled?()
            return
        }
        let generation = transientGeneration
        isLockSettlePending = true

        // Beat 0 — intake (0.14): breathing off (the caller's reconcile does
        // that), and the room quiets. Beat 4 — settle (1.20–1.44): back up.
        let quiet = CAKeyframeAnimation(keyPath: "opacity")
        quiet.values = [1.0, 0.88, 0.88, 1.0]
        quiet.keyTimes = [0, 0.14 / 1.62, 1.20 / 1.62, 1.44 / 1.62].map { NSNumber(value: $0) }
        quiet.duration = Self.lockDuration
        quiet.beginTime = CACurrentMediaTime()
        quiet.timingFunction = Self.glideCurve
        fieldLayer.add(quiet, forKey: "lock.intake")
        let ticksQuiet = CAKeyframeAnimation(keyPath: "opacity")
        ticksQuiet.values = [look.tickOpacity, 0.25, 0.25, look.tickOpacity]
        ticksQuiet.keyTimes = quiet.keyTimes
        ticksQuiet.duration = Self.lockDuration
        ticksQuiet.beginTime = quiet.beginTime
        ticksQuiet.timingFunction = Self.glideCurve
        tickLayer.add(ticksQuiet, forKey: "lock.intake")

        // Beat 1's soft collision: the two rings meeting is felt, not heard.
        pulse(layer: targetRing, keyPath: "lineWidth", peak: CGFloat(2.6),
              settled: CGFloat(2.0), at: 0.56, duration: 0.28, key: "lock.collide")
        pulse(layer: targetHalo, keyPath: "opacity", peak: Float(0.68),
              settled: Float(0.55), at: 0.56, duration: 0.28, key: "lock.collideHalo")

        // Beat 2 — gather (0.30–0.90).
        fireGatherBars(centre: centre, ringRadius: look.ringRadius)

        // Beat 3 — contract + bloom (0.78–1.34): the ring draws breath before
        // it releases, and ONE `fuseWhite` bloom leaves it.
        let contracted = CGRect(x: 0, y: 0, width: 9.4 * 2, height: 9.4 * 2)
        let settledBox = CGRect(x: 0, y: 0, width: look.ringRadius * 2,
                                height: look.ringRadius * 2)
        pulse(layer: targetRing, keyPath: "bounds",
              peak: NSValue(rect: contracted), settled: NSValue(rect: settledBox),
              at: 0.78, duration: 0.56, key: "lock.contractBounds")
        pulse(layer: targetRing, keyPath: "path",
              peak: Self.ringPath(in: contracted, lineWidth: look.ringLineWidth),
              settled: Self.ringPath(in: settledBox, lineWidth: look.ringLineWidth),
              at: 0.78, duration: 0.56, key: "lock.contractPath")
        fireLockBloom(at: 0.78, centre: centre, radius: look.ringRadius,
                      lineWidth: look.ringLineWidth)
        // The fusion itself: the settled colour is already `fuseWhite`
        // (stamped for `.locked`); hold the target's green until the bloom
        // releases it, then cross to white with it.
        let crosses: [(layer: CALayer, keyPath: String, from: Any?)] = [
            (targetRing, "strokeColor", resolvedTargetLight),
            (targetHalo, "contents", Self.haloImage(color: Tokens.Color.syncSignal)),
        ]
        for (layer, keyPath, from) in crosses {
            let cross = CABasicAnimation(keyPath: keyPath)
            cross.fromValue = from
            cross.toValue = layer.value(forKeyPath: keyPath)
            cross.beginTime = CACurrentMediaTime() + 0.78
            cross.duration = 0.44
            cross.fillMode = .backwards
            cross.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(cross, forKey: "lock.fuse.\(keyPath)")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.lockSettledAt) { [weak self] in
            guard let self, self.transientGeneration == generation else { return }
            self.fireLockSettled()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.lockDuration) { [weak self] in
            guard let self, self.transientGeneration == generation else { return }
            self.removeTransients()
        }
    }

    /// Beat 2: two bars sweep the wire's light into the ring — green from the
    /// left, magenta from the right, each keeping its own hue as it arrives.
    ///
    /// The fixed edge is the one AT THE RING, so the bar collapses INTO it —
    /// the beat is a GATHER, and light draining outward would read as the
    /// opposite. (§5's line reads "anchored at the outer ends"; the same
    /// sentence says the light sweeps INTO the ring, and that is the sense
    /// the beat is named for.)
    private func fireGatherBars(centre: CGPoint, ringRadius: CGFloat) {
        let height: CGFloat = 2.5
        let sides: [(isLeft: Bool, color: CGColor)] = [
            (true, resolvedTargetLight), (false, resolvedReferenceLight)
        ]
        for side in sides {
            let innerX = side.isLeft ? centre.x - ringRadius : centre.x + ringRadius
            let outerX = side.isLeft ? Self.horizontalInset
                                     : bounds.width - Self.horizontalInset
            let width = abs(innerX - outerX)
            guard width > 1 else { continue }
            let bar = CALayer()
            bar.backgroundColor = side.color
            bar.cornerRadius = height / 2
            bar.anchorPoint = CGPoint(x: side.isLeft ? 1 : 0, y: 0.5)
            bar.position = CGPoint(x: innerX, y: centre.y)
            bar.bounds = CGRect(x: 0, y: 0, width: 0, height: height)
            bar.opacity = 0
            fieldLayer.addSublayer(bar)
            transientLayers.append(bar)

            let shrink = CABasicAnimation(keyPath: "bounds.size.width")
            shrink.fromValue = width
            shrink.toValue = 0
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.85
            fade.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [shrink, fade]
            group.beginTime = CACurrentMediaTime() + 0.30
            group.duration = 0.60
            group.timingFunction = Self.settleCurve
            // NO backwards fill: it would display the animation's `fromValue`
            // — a full-width bar at 0.85 — from the moment the layer is added
            // until beat 2 actually begins. The layer's own settled model
            // values (zero width, zero opacity) are the truth before the beat
            // and after it, so the bar is invisible outside its own interval.
            bar.add(group, forKey: "lock.gather")
        }
    }

    /// The kept moment: ONE contained `fuseWhite` bloom — a copy of the target
    /// ring that starts on the circumference and expands as it fades. A
    /// transient over the settled model (`HaloRingView`'s acknowledgment
    /// pattern).
    private func fireLockBloom(at begin: TimeInterval, centre: CGPoint,
                               radius: CGFloat, lineWidth: CGFloat) {
        let box = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
        let bloom = CAShapeLayer()
        bloom.bounds = box
        bloom.position = centre
        bloom.path = Self.ringPath(in: box, lineWidth: lineWidth)
        bloom.fillColor = nil
        bloom.lineWidth = lineWidth
        bloom.strokeColor = resolvedFuse
        bloom.opacity = 0
        fieldLayer.addSublayer(bloom)
        transientLayers.append(bloom)

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.0
        scale.toValue = 1.85
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.9
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.beginTime = CACurrentMediaTime() + begin
        group.duration = 0.44
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        // NO backwards fill — see `fireGatherBars`: it would park the bloom's
        // `fromValue` (a fully drawn ring at 0.9) on screen for the whole
        // 0.78 s delay. The settled model opacity of 0 keeps it invisible
        // until beat 3 releases it.
        bloom.add(group, forKey: "lock.bloom")
    }

    // MARK: - Cancellation

    /// True between the lock sequence starting and its `onLockedSettled`
    /// firing — the obligation a cancel has to honour rather than drop.
    private var isLockSettlePending = false

    /// The lock's one settle cue: fired at most once per sequence, whether the
    /// script ran to its 1.44 s beat or a cancel cut it short.
    private func fireLockSettled() {
        guard isLockSettlePending else { return }
        isLockSettlePending = false
        onLockedSettled?()
    }

    /// One transition in flight: a new apply drops every running animation and
    /// every transient, so two scripts can never share the stage.
    ///
    /// A cancel that lands MID-LOCK settles the sequence instead of losing it:
    /// the geometry is already at the locked look, and the driver's kept line
    /// is waiting on this cue (a Reduce Motion / accent toggle mid-lock used to
    /// swallow it, leaving the readout on the proposal's number forever).
    private func cancelInFlight() {
        fireLockSettled()
        transientGeneration &+= 1
        removeTransients()
        for sub in [plateLayer, wireLeft, wireRight, fieldLayer, tickLayer, spanLayer,
                    targetHalo, targetRing, referenceHalo, referenceRing] {
            sub.removeAllAnimations()
        }
    }

    private func removeTransients() {
        for layer in transientLayers { layer.removeFromSuperlayer() }
        transientLayers.removeAll()
    }

    // MARK: - Breathing (ambient life, never beat-synced)

    /// Each light breathes slowly, out of phase with the other — the tempo is
    /// the RUNG's, so the mood follows the run's real progress without ever
    /// claiming to pulse on the beat. Stops when the rung doesn't breathe, off
    /// screen, headless, or Reduce Motion is on.
    ///
    /// The living ring's clock rides the SAME gate, deliberately: a rung that
    /// does not breathe is a rung at rest — `locked` above all, where
    /// stillness IS the reward — so one condition governs both, and there is
    /// no second lifecycle to keep in step.
    private func reconcileBreathing() {
        let look = Self.look(for: rung)
        guard let period = look.breathePeriod, !reduceMotion,
              !HeadlessRuntime.isActive, window != nil else {
            targetHalo.removeAnimation(forKey: Self.breatheKey)
            referenceHalo.removeAnimation(forKey: Self.breatheKey)
            stopLivingRing()
            return
        }
        startLivingRing()
        for (halo, phase) in [(targetHalo, 0.0), (referenceHalo, 0.5)] {
            // Re-add only when absent or the tempo class changed.
            if let existing = halo.animation(forKey: Self.breatheKey),
               existing.duration == period { continue }
            let breathe = CABasicAnimation(keyPath: "transform.scale")
            breathe.fromValue = 1.0
            breathe.toValue = look.breatheAmplitude
            breathe.duration = period
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            breathe.timeOffset = period * phase
            halo.add(breathe, forKey: Self.breatheKey)
        }
    }

    // MARK: - The living ring's clock

    private var livingRingLink: CADisplayLink?
    private var livingRingEpoch: CFTimeInterval = 0
    /// The rung's opacity for each light layer, written by `layoutLight`.
    private var settledOpacity: [ObjectIdentifier: Float] = [:]

    private func startLivingRing() {
        guard ringStyle == .living else { stopLivingRing(); return }
        guard livingRingLink == nil else { return }
        let link = displayLink(target: self, selector: #selector(livingRingTick))
        // 30 fps: a ±3 % bend turning at 0.5 rad/s has nothing to say at 120.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30,
                                                        preferred: 30)
        livingRingEpoch = CACurrentMediaTime()
        link.add(to: .main, forMode: .common)
        livingRingLink = link
    }

    /// Invalidating leaves the last frame's wobble on the layers, so the stop
    /// writes the PINNED model back — the settled ellipse at the table's own
    /// opacity. Model values only, so a transition mid-flight is untouched.
    private func stopLivingRing() {
        guard livingRingLink != nil else { return }
        livingRingLink?.invalidate()
        livingRingLink = nil
        drawLights(phase: nil)
    }

    @objc private func livingRingTick(_ link: CADisplayLink) {
        drawLights(phase: link.targetTimestamp - livingRingEpoch)
    }

    /// One path and two opacities per light. Everything it needs is already on
    /// the layers (radius, line width) or in `settledOpacity`, so a frame
    /// never re-derives the look table and never allocates beyond the two
    /// paths it draws.
    private func drawLights(phase: Double?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, halo, ring) in [(0.0, targetHalo, targetRing),
                                    (1.0, referenceHalo, referenceRing)] {
            ring.path = Self.ringPath(in: ring.bounds, lineWidth: ring.lineWidth,
                                      phase: phase, index: index)
            let factor = Self.swellFactor(phase: phase, index: index)
            if let base = settledOpacity[ObjectIdentifier(ring)] {
                ring.opacity = base * factor
            }
            if let base = settledOpacity[ObjectIdentifier(halo)] {
                halo.opacity = base * factor
            }
        }
        CATransaction.commit()
    }

    // MARK: - Colors

    private var resolvedFuse: CGColor = NSColor.clear.cgColor
    private var resolvedDetentAccent: CGColor = NSColor.clear.cgColor
    private var resolvedSpanGlow: CGColor = NSColor.clear.cgColor
    private var resolvedTargetLight: CGColor = NSColor.clear.cgColor
    private var resolvedReferenceLight: CGColor = NSColor.clear.cgColor

    private func stampColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dormant = rung == .dormant
            // Fused: the wire carries each voice up to the ring. Locked: the
            // voices are gone INTO the ring — a two-toned wire under a white
            // ring would say they never met.
            let asOne = rung == .fused
            // Armed: no belief yet, so no identity on the span either.
            let neutralSpan = dormant || rung == .armed
            let rule = Tokens.Color.stageRule
            let target = Tokens.Color.syncSignal
            let reference = Tokens.Color.partySignal
            let fuse = Tokens.Color.fuseWhite
            let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua

            plateLayer.backgroundColor = Tokens.Color.stagePlate.cgColor
            // A recessed screen's bezel: faint in the dark chassis, a real
            // warm rim in light, where the plate is a black rectangle on
            // white without it.
            plateLayer.borderColor = Tokens.Color.plateRim
                .withAlphaComponent(isDark ? 0.35 : 0.9).cgColor
            // Fused/locked, the two halves of the wire carry their own voice
            // up to the ring; otherwise one rule.
            wireLeft.strokeColor = (asOne ? target.withAlphaComponent(0.5) : rule).cgColor
            wireRight.strokeColor = (asOne ? reference.withAlphaComponent(0.5) : rule).cgColor
            tickLayer.strokeColor = rule.cgColor

            // The interval reads as the two speakers' hues meeting at a
            // crisp seam: green from the target's end, magenta from the
            // reference's. No blend between them — a gradient's pale
            // midpoint made the instrument look half-fused all run, and
            // turned the lock's white into a hue shift instead of an arrival.
            let spanColors = neutralSpan ? [rule, rule, rule, rule]
                                         : [target, target, reference, reference]
            spanLayer.colors = spanColors.map { $0.cgColor }
            spanLayer.locations = [0, 0.5, 0.5, 1]
            spanLayer.shadowColor = fuse.cgColor
            spanLayer.shadowOpacity = neutralSpan ? 0 : 0.35

            // Locked, the target light IS the fused pair: warm white.
            let targetHue = dormant ? rule : (rung == .locked ? fuse : target)
            targetRing.strokeColor = targetHue.cgColor
            referenceRing.strokeColor = (dormant ? rule : reference).cgColor
            targetHalo.contents = Self.haloImage(color: targetHue)
            referenceHalo.contents = Self.haloImage(color: dormant ? rule : reference)

            resolvedFuse = fuse.cgColor
            resolvedSpanGlow = fuse.cgColor
            resolvedTargetLight = target.cgColor
            resolvedReferenceLight = reference.cgColor
            // The detent is the INSTRUMENT's own voice acknowledging banked
            // progress, so it is gold — the one gold left on the stage. The
            // subtle dial has no gold to spend, so it falls back to ember.
            resolvedDetentAccent = (Tokens.accentStyle == .subtle
                                    ? Tokens.Color.ember : Tokens.Color.glow).cgColor
        }
    }

    /// A soft radial falloff for a light's halo, rendered once per stamp so
    /// the layer only ever scales bitmap contents.
    private static func haloImage(color: NSColor) -> CGImage? {
        let size = 64
        guard let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let centre = CGPoint(x: CGFloat(size) / 2, y: CGFloat(size) / 2)
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [color.withAlphaComponent(0.9).cgColor,
                     color.withAlphaComponent(0).cgColor] as CFArray,
            locations: [0, 1]) else { return nil }
        context.drawRadialGradient(
            gradient, startCenter: centre, startRadius: 0,
            endCenter: centre, endRadius: CGFloat(size) / 2, options: [])
        return context.makeImage()
    }

    // MARK: - Live re-resolution

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        stampColors()
        needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reconcileBreathing()
    }

    @objc private func accessibilityDisplayOptionsDidChange() {
        // A mid-flight Reduce Motion toggle must not leave half a script
        // running over the settled model.
        cancelInFlight()
        stampColors()
        applyGeometry(Self.instantScript)
        reconcileBreathing()
    }

    @objc private func accentStyleDidChange() {
        cancelInFlight()
        stampColors()
        applyGeometry(Self.instantScript)
        reconcileBreathing()
    }

    private var reduceMotion: Bool {
        test_reduceMotionOverride
            ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // MARK: - Test seams (pure reads + the standard Reduce Motion override)

    var test_reduceMotionOverride: Bool?
    var test_state: State { state }
    var test_rung: Rung { rung }
    var test_lastTransition: Transition { lastTransition }
    var test_displayRange: ClosedRange<Double> { displayRange }
    /// The two light centres in view space — the mapping under test.
    var test_lightCentres: (target: CGPoint, reference: CGPoint) {
        (targetHalo.position, referenceHalo.position)
    }
    var test_spanFrame: CGRect { spanLayer.frame }
    /// The target light's SETTLED geometry — the pinned-phase truth the
    /// renders and the goldens rest on: a squashed ellipse at the rung's own
    /// opacity, with no wobble and no swell in it.
    var test_targetLight: (ring: CGRect, halo: CGRect, ringOpacity: Float) {
        (targetRing.path?.boundingBox ?? .zero, targetHalo.bounds, targetRing.opacity)
    }
    /// The target ring's settled stroke — `fuseWhite` once locked.
    var test_targetRingColor: NSColor? { targetRing.strokeColor.map(NSColor.init(cgColor:)) ?? nil }
    var test_isBreathing: Bool {
        targetHalo.animation(forKey: Self.breatheKey) != nil
    }
}
