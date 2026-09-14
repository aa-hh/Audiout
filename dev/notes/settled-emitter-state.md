# Settled emitter state — chosen formula (2026-09-13)

A second state for the emitter field, for a future surface (purpose TBD). The
field reads as fully emitted — the complete ring structure standing around the
source — with no outward travel. The life comes from each ring rolling over
itself like a spinning tube, a compression lobe slowly orbiting the source,
and a calmer breath. The radiating hero state is untouched; this is an
alternative `field()` body sharing the same constants and seeds.

Chosen by Alec from a four-way discovery round (angular circulation, bounded
sway, recirculating rim, rolling lobe) and two refinement rounds. Winner:
"R1 · Rolls in place" from the third round, at Alec's hand-tuned settings.

## Formula

Same structure as the hero (`emitters.js` steps 1–7). Steps 1, 2, 5, 7
unchanged. Steps 3–4 are replaced, step 6 gets its own breathing values.
Per emitter, with the hero's `seed = k*6.13 + 1.7`:

```glsl
/* orbit (hero step 1, smaller radius) */
c += orbit * vec2(sin(t*0.030 + seed), cos(t*0.026 + seed*1.7));

float r  = length((uv - c) * vec2(1.0, squash));
float th = atan(dv.y, dv.x);          /* dv = uv - c */

/* the lobe and the curl both fade to zero inside `taper`, so the
   innermost ring can never fold into itself (the clip fix) */
float taperF = smoothstep(0.0, taper, r);

/* an oval compression lobe orbits the source: rings bunch on one side,
   relax on the other, and the bunched side circles */
float roll = (rollAmp * cos(th - t*rollRate - seed)
           + rollAmp * 0.35 * cos(2.0*th + t*rollRate*0.61 + seed*1.3)) * taperF;
float ph = r*dens + seed - roll;      /* NO -t*speed: nothing travels outward */

/* each crest leans, folds under, and comes back over — the curl phase runs
   radially through the crest, a tube spinning about its own axis */
float ph2 = ph + curlAmp * sin(ph - t*curlRate) * taperF;

float rings = pow(0.5 + 0.5*sin(ph2), sharp);
float fall  = exp(-r * fade);
float swell = breatheFloor + breatheDepth * (0.5 + 0.5*sin(t*breatheRate + seed*2.3));
light += rings * fall * swell * gain;
```

## Constants

Alec's picked settings, from the lab page (Copy settings, 2026-09-13). The
lab ran its clock at 2.5× — the rates below are the lab knob values, so a
port must ALSO scale its time input by `timeScale`. One deviation number in
the stageScale style; folding it into the rates instead is equivalent
(rollRate 0.35, curlRate 3.875, breatheRate 0.25, orbit sines 0.075/0.065).

| knob | value | vs shared field.json |
|---|---|---|
| timeScale | 2.5 | new (lab `speed`) |
| rollAmp | 1.3 | new |
| rollRate | 0.14 | new |
| taper | 0.56 | new |
| curlAmp | 0.15 | new |
| curlRate | 1.55 | new |
| orbit | 0.03 | DEVIATES from 0.1 — "moves slightly", not roaming |
| breatheFloor | 0.82 | DEVIATES from 0.4 — Alec: brightness must hold steady |
| breatheDepth | 0.28 | DEVIATES from 0.6 — same ruling |
| squash | 1.12 | shared, unchanged |
| dens (densBase/Step) | 17 / 3 | shared, unchanged |
| sharp | 4.0 | shared, unchanged |
| fade | 1.5 | shared, unchanged |
| breatheRate/Step | 0.1 / 0.028 | shared, unchanged (scaled by timeScale like all rates) |
| gain | 0.65 | shared, unchanged |
| speedBase/speedStep | — | RETIRED in this state: no outward phase term |
| wobble | 0 | unchanged (off) |

Rulings from the iteration, so they don't get relitigated:
- Curl must NOT travel around the circumference (`+ th` inside the curl sin
  was rejected) — the ring rolls over itself in place.
- The deep hero breathing (0.4→1.0 swing) was explicitly rejected here:
  "it should stay at the same brightness."
- The centre taper is load-bearing: without it, roll displacement exceeds the
  innermost ring's radius and the ring self-intersects into a cusp.
- The swell/tube-flow variants (R2/R3, envelope travelling along the ring)
  lost to the uniform roll; flowDepth ended at 0.

## Where the exploration lives

Throwaway lab pages (session scratchpad, not committed — regenerate from this
brief if needed): `settled-emitter-lab.html` (first four candidates),
`c-iterations.html` (lobe cleanup + curl/flow), `roll-iterations.html`
(final round, Tweakpane knobs, settings-in-URL). Served via a python
http.server on 8471; Tweakpane comes from jsdelivr (cdnjs has no package).

## When this ships

Add the knobs to `field.json` in audiout-shared (new `settled` object or
per-knob defaults), tag a version, and port per the audiout-field skill —
constants read from the JSON, deviations above marked inline with these
reasons, one fixed-`t` frame compared against a reference render.
