// SPDX-License-Identifier: GPL-2.0-or-later

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>

using namespace metal;

// "The room" — the marketing hero's field, per fragment. Up to three emitters
// push ring fronts across a y-normalized space; the fronts thin to bright crests,
// fade with distance from their source, and breathe on three slightly
// different clocks so the sets never pulse together. The light that comes out
// is one number, and a four-stop single-hue ramp turns that number into the
// only colour on screen — ground included. This paints opaquely: the ramp's
// first stop IS the ground.
//
// Ported from the site's WebGL1 shader (hero-bg.js + fields/d.js) with its
// shipped tuning inlined. What arrives as data instead is what the two phone
// screens have to differ on: the emitter set and its drift and travel, the
// hue ramp, the gain, the edge feather, and the calm zones — those last are
// aimed at a layout, and the phone's layout is not the site's.

/// `smoothstep` that accepts reversed edges (edge0 > edge1 fades the other
/// way). GLSL leaves that case undefined; the field's zones depend on it.
static inline float sstep(float e0, float e1, float x) {
    float t = clamp((x - e0) / (e1 - e0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

/// Cheap value noise, one sample per pixel — dither against banding in the
/// long, flat washes the ramp makes.
static inline float hash(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

/// One elliptical calm zone: full damping by `k` inside it, none outside.
/// `z` is (centre.x, centre.y, radius.x, radius.y) in the uv frame.
static inline float calmZone(float2 uv, float4 z, float k) {
    if (k <= 0.0) { return 1.0; }
    float2 r = max(z.zw, float2(1e-4));
    float d = length((uv - z.xy) / r);
    return 1.0 - k * (1.0 - sstep(0.55, 1.0, d));
}

/// The field itself, verbatim from the site apart from the inlined constants —
/// except the emitter set and two of its terms, which arrive as data: the
/// site's three-speaker room on the primer, one centred source on the searching
/// junction. `orbit` is the drift each source takes around its given position —
/// the room wants it, the single centred source is asked to be actually
/// centred, so it gets 0. `speedScale` stretches the ring train's travel only,
/// leaving breath and orbit on their own cadence. Everything else that makes it
/// the same room (squash, density, sharpness, fade, breath, gain) stays fixed
/// here.
static float roomLight(float2 uv, float t, float lightMode,
                       float2 e0, float2 e1, float2 e2, int count,
                       float orbit, float speedScale) {
    const float2 emitters[3] = { e0, e1, e2 };
    const float squash       = 1.12;
    const float speedBase    = 1.11;
    const float speedStep    = 0.20;
    const float densBase     = 17.0;
    const float densStep     = 3.0;
    const float sharp        = 4.0;
    const float fadeK        = 1.5;
    const float breatheFloor = 0.4;
    const float breatheDepth = 0.6;
    const float breatheRate  = 0.1;
    const float breatheStep  = 0.028;
    const float gain         = 0.65;
    const float paperLift    = 1.94;

    float light = 0.0;
    for (int k = 0; k < count; k++) {
        float f = float(k);
        float seed = f * 6.13 + 1.7;
        float2 c = emitters[k]
                 + orbit * float2(sin(t * 0.030 + seed), cos(t * 0.026 + seed * 1.7));
        float r = length((uv - c) * float2(1.0, squash));
        float speed = (speedBase + speedStep * f) * speedScale;
        float dens  = densBase + densStep * f;
        float rings = 0.5 + 0.5 * sin(r * dens - t * speed + seed);
        rings = pow(rings, sharp);        // thin bright crests, wide dark gaps
        float fade = exp(-r * fadeK);     // loudest at the source
        float swell = breatheFloor + breatheDepth
            * (0.5 + 0.5 * sin(t * (breatheRate + breatheStep * f) + seed * 2.3));
        light += rings * fade * swell * gain;
    }
    light *= mix(1.0, paperLift, lightMode);  // paper needs the lift to read
    return light;
}

/// `position` arrives in the view's own points, y down; the reference frame is
/// centre-origin, y-normalized, y UP, so the sign flips here and nowhere else.
///
/// `ramp` picks the hue family: 0 = Sync Green (the site's own values, the
/// intro's guest accent), 1 = Warm Signal's gold. `lightMode` is 0 for the
/// dark ground and 1 for paper, and each family runs its light ramp the other
/// way — on paper the washes deepen instead of glowing.
[[stitchable]] half4 roomField(float2 position,
                               half4 _unused,
                               float2 size,
                               float t,
                               float lightMode,
                               float gainScale,
                               float4 calmA,
                               float4 calmB,
                               float2 calmK,
                               float2 topGuard,
                               float feather,
                               float ramp,
                               float2 emitter0,
                               float2 emitter1,
                               float2 emitter2,
                               float emitterCount,
                               float orbit,
                               float speedScale) {
    float2 uv = (position - 0.5 * size) / max(size.y, 1.0);
    uv.y = -uv.y;

    int count = clamp(int(emitterCount + 0.5), 1, 3);
    float light = roomLight(uv, t, lightMode,
                            emitter0, emitter1, emitter2, count,
                            orbit, speedScale) * gainScale;

    // Calm zones: keep the crests off the top edge and out from behind the
    // type. Re-aimed per screen, which is why they arrive as data.
    light *= sstep(topGuard.x, topGuard.y, uv.y);
    light *= calmZone(uv, calmA, calmK.x);
    light *= calmZone(uv, calmB, calmK.y);

    float l = pow(1.0 - exp(-light * 1.2), 1.35);

    // Four stops, one hue. Every value below is a shipped token; the first is
    // the ground, so this function owns the whole pixel.
    float3 bg, lo, mid, peak;
    if (ramp < 0.5) {
        // Sync Green — the site's hero values, kept exactly.
        bg   = mix(float3(0.043, 0.035, 0.031), float3(0.984, 0.984, 0.976), lightMode);
        lo   = mix(float3(0.039, 0.431, 0.247), float3(0.604, 0.886, 0.745), lightMode);
        mid  = mix(float3(0.169, 1.000, 0.561), float3(0.039, 0.420, 0.239), lightMode);
        peak = mix(float3(0.859, 1.000, 0.933), float3(0.071, 0.231, 0.141), lightMode);
    } else {
        // Warm Signal. Dark: canvas #16130F, ember #8A6A2F, gold #E8B84B,
        // glow #FFD97A. Light: paper canvas #F4F2EA, then the light-appearance
        // values ordered so the washes DEEPEN the way the green ramp's do —
        // glow #E8B84B, ember #C2A05A, gold #A97F1E.
        bg   = mix(float3(0.086, 0.075, 0.059), float3(0.957, 0.949, 0.918), lightMode);
        lo   = mix(float3(0.541, 0.416, 0.184), float3(0.910, 0.722, 0.294), lightMode);
        mid  = mix(float3(0.910, 0.722, 0.294), float3(0.761, 0.627, 0.353), lightMode);
        peak = mix(float3(1.000, 0.851, 0.478), float3(0.663, 0.498, 0.118), lightMode);
    }

    float3 col = mix(bg, lo, sstep(0.0, 0.45, l));
    col = mix(col, mid,  sstep(0.4, 0.8, l));
    col = mix(col, peak, sstep(0.78, 1.0, l));
    col += (hash(position) - 0.5) * 0.012;

    // Where the field sits inside a layout slot rather than being the screen,
    // its own ground would seam against the canvas behind it; the edge fades
    // out instead of a second ground being invented.
    float a = 1.0;
    if (feather > 0.0) {
        float d = length((position / max(size, float2(1.0)) - 0.5) * 2.0);
        a = sstep(1.0, 1.0 - feather, d);
    }
    return half4(half3(col * a), half(a));  // premultiplied
}
