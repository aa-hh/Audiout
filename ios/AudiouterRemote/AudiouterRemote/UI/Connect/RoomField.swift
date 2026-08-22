// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// "The room": rings of light expanding from emitters out past the edges,
/// fading as they cross the space — the way sound spreads from speakers. The
/// marketing hero's field, and the same fragment shader the site runs, ported
/// to Metal (`RoomField.metal`).
///
/// It paints the whole rect, ground included: the ramp's first stop is the
/// ground value, which is how the site gets one hue family across the entire
/// image instead of light sitting on top of a separately-chosen background.
/// On the primer this view therefore IS the screen's ground.
///
/// Decorative: hidden from VoiceOver, and it never takes a touch. Under Reduce
/// Motion it holds one composed frame rather than going blank.
struct RoomField: View {
    /// One field, two tunings. What makes it the same room — ring density,
    /// crest sharpness, breath, distance fade — is fixed in the shader; the
    /// screens differ in where the light comes from and how it drifts and
    /// travels, its hue family, its overall level, where it stands back for
    /// type, and whether it fades out at its own edge.
    struct Tuning {
        /// 0 = Sync Green, 1 = Warm Signal gold.
        var ramp: Float
        /// Overall level. The search field sits under live copy and must not
        /// compete with it.
        var gain: Float
        /// Keeps light off the top edge: `(from, to)` in the shader's uv frame,
        /// where +0.5 is the top of the rect. Reversed edges fade upward.
        var topGuard: SIMD2<Float>
        /// Two elliptical zones the field eases behind, `(x, y, rx, ry)` in the
        /// uv frame, with their strengths in ``calmStrength``.
        var calmA: SIMD4<Float>
        var calmB: SIMD4<Float>
        var calmStrength: SIMD2<Float>
        /// Radial fade to transparent at the rect boundary, as a fraction of
        /// the radius. Zero where the field is the screen and has no seam.
        var feather: Float
        /// Where the light comes from, in the shader's uv frame. Up to three
        /// sources; only the first ``emitterCount`` are lit. This, with
        /// ``orbit`` and ``speedScale``, is what separates a room of speakers
        /// from one speaker calling across it.
        /// razor: three is the shipped ceiling (the site's room); more means
        /// packing the positions into an array argument.
        var emitters: (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)
        var emitterCount: Float
        /// How far each source drifts around the position above. A room of
        /// speakers wants the drift; a source that is meant to be AT the
        /// centre wants none, so this is per-tuning rather than fixed.
        var orbit: Float
        /// Multiplies the ring train's travel, and nothing else — breath and
        /// orbit keep their own cadence.
        var speedScale: Float
    }

    let tuning: Tuning

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    /// The clock starts here rather than at zero: the composition at t≈0 has
    /// every emitter in step, which is the one moment the field looks drawn.
    private static let startTime: Double = 40

    @State private var birth = Date()

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            GeometryReader { geo in
                Rectangle().colorEffect(shader(size: geo.size, at: time(timeline.date)))
            }
        }
        // The field VANISHES on a light/dark switch without this — the system
        // re-renders the hierarchy under new traits mid-transition, the shader
        // effect on the old layer is dropped, and the screen is left showing
        // only the ground behind it. A new identity per appearance rebuilds the
        // effect cleanly. `birth` lives on RoomField, not in here, so the clock
        // (and the Reduce Motion still frame) carries across untouched.
        .id(scheme)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func time(_ date: Date) -> Double {
        reduceMotion ? Self.startTime : Self.startTime + date.timeIntervalSince(birth)
    }

    private func shader(size: CGSize, at t: Double) -> Shader {
        ShaderLibrary.roomField(
            .float2(Float(size.width), Float(size.height)),
            .float(Float(t)),
            .float(scheme == .dark ? 0 : 1),
            .float(tuning.gain),
            .float4(tuning.calmA.x, tuning.calmA.y, tuning.calmA.z, tuning.calmA.w),
            .float4(tuning.calmB.x, tuning.calmB.y, tuning.calmB.z, tuning.calmB.w),
            .float2(tuning.calmStrength.x, tuning.calmStrength.y),
            .float2(tuning.topGuard.x, tuning.topGuard.y),
            .float(tuning.feather),
            .float(tuning.ramp),
            .float2(tuning.emitters.0.x, tuning.emitters.0.y),
            .float2(tuning.emitters.1.x, tuning.emitters.1.y),
            .float2(tuning.emitters.2.x, tuning.emitters.2.y),
            .float(tuning.emitterCount),
            .float(tuning.orbit),
            .float(tuning.speedScale))
    }
}

extension RoomField.Tuning {
    /// The intro's field: green light, the whole screen, and the bolder of the
    /// two — it is the only thing on that screen besides the mark, the name and
    /// the way in. Its calm zones are aimed at that layout: one centred zone
    /// eases the light behind the icon, the name and the line under it; a lower,
    /// wider one eases it behind the mechanism caption and the button. Both stay
    /// well inside the rect, so the edges and corners keep their crests — the
    /// field is quieter under type and unchanged everywhere else. The top edge
    /// stays dark so it reads as a room with a ceiling rather than as a
    /// wallpaper.
    ///
    /// The site's Sync Green lives HERE and nowhere else in the app — as
    /// emitted light in the shader's ramp, never as a fill, never as type,
    /// never marking state. Gold is the app's signal, and a second accent that
    /// meant something would break that.
    static let intro = Self(
        ramp: 0,
        gain: 1,
        topGuard: SIMD2(0.50, 0.28),
        calmA: SIMD4(0.00, 0.05, 0.30, 0.18),
        calmB: SIMD4(0.00, -0.37, 0.34, 0.13),
        calmStrength: SIMD2(0.42, 0.5),
        feather: 0,
        emitters: (SIMD2(-0.60, 0.24), SIMD2(0.86, -0.04), SIMD2(0.08, 0.52)),
        emitterCount: 3,
        orbit: 0.10,
        speedScale: 1)

    /// The searching junction's field: ONE source at the centre of the slot,
    /// wavefronts spreading outward — one speaker calling across the house,
    /// which is exactly what the app is doing while it browses. Gold and
    /// quieter, in a slot on the canvas rather than as the screen — so it
    /// keeps no calm zones (nothing sits over it) and fades out at its own
    /// edge instead of meeting the canvas with a hard line.
    ///
    /// The source is pinned dead centre — no orbit. The drift the room's
    /// speakers take reads as a wobble on a lone source in a slot, and the
    /// centre of the slot is where the wavefronts are supposed to start. The
    /// waves themselves run a little faster than the room's, since one source
    /// alone has no set-against-set interference to carry the motion.
    static let search = Self(
        ramp: 1,
        gain: 0.62,
        topGuard: SIMD2(1.0, 0.9),
        calmA: .zero,
        calmB: .zero,
        calmStrength: .zero,
        feather: 0.45,
        emitters: (.zero, .zero, .zero),
        emitterCount: 1,
        orbit: 0,
        speedScale: 1.4)
}
