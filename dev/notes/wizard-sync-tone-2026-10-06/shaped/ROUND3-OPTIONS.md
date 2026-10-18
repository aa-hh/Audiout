# Mic probe, round 3: beds, a wide dark sweep, and raising the level in a loud room

Same setup as round 2 (`../dark/DARK-OPTIONS.md`): the same sound on both speakers, played in turn, Bluetooth first, each in its own 3.5 s window, 1.0 s apart, each lane searched only inside its own window. Real level unless a row says otherwise: Bluetooth peak −15 dBFS, Mac peak −27 dBFS.

Listen first:
- `audition.wav`: today, D2, D4, E1c, E1t, E1n, E24, E26, E26c, E29, E29c, with 2 s gaps.
- `audition_broken_control.wav`: D4, E1x, E1x0, D2, E1y, E1y0.
- `audition_raised.wav`: D4 at real level, +6 dB and +12 dB, then E1c the same way. **The +12 dB parts are 12 dB louder; turn down first.**
- Single files at real level beside this one; raised versions in `raised/`. Levels in `LEVELS.txt`.

Terms are as defined in round 2 (lane, window, matched filter, confidence, ceiling, realistic floor, rumble, false-peak margin, sone, acum, annoyance). New here:
- **Bed**: a steady sound added under the glide that the matched filter does not look for.
- **Loud room**: the bench's "+10 dB noise" condition, room noise 10 dB above the standard.
- **Rough live figure**: round 1's rule. The bench score × 5.5 (684 live ÷ 124 bench), capped at the lane's ceiling, weaker lane shown. For the loud room it is applied to the +10 dB score. Every lane here is limited by the room, not by its own structure, so the rule applies to all of them.
- **Clears the loud room at level X**: the lowest probe level of 0, +6 or +12 dB at which the rough live figure is 25 or more (the phone's floor, above the Mac's 20) in both the loud room and the rumble condition.

Bench: Apple AAC 128 kbit/s on the Bluetooth lane, 23 dB quieter at the mic at equal digital level, 6 echoes, 10 seeds × 4 offsets = 40 trials per condition (round 2 used 20 seeds). Noise-estimate smoothing over a fixed 100 Hz. Sharpness, loudness and annoyance: the Bluetooth window as played, full scale taken as 94 dB SPL.

## Comparison at real level

Confidence is Mac / Bluetooth, median of 40 trials.

| Candidate | Window | Total sound | Standard | Loud room (+10 dB) | Realistic floor | Rumble | Worst error | False-peak margin | Sharpness | Loudness | Annoyance | Rough live figure, standard / loud room | Clears loud room at level | What it sounds like | Biggest risk |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Today, as shipped | 1.0 s, both at once | 1.0 s | 95 / 33 | 31 / 10 | 95 / 128 | 95 / 33 | 0.003 ms | −21.6 dB at 3.3 ms | 3.19 acum | 25.1 sone | 39.1 | ~520 / ~170 | real level | Falling whistle under a shrill rising one | It is the grating sound |
| D2 (round 2) | 3.5 s | 8.0 s | 35 / 10.4 | 11 / 2.8 | 35 / 10.4 | 34 / 10.0 | 0.012 ms | −36.0 dB at 13 ms | 0.56 | 11.7 | 11.9 | 57 / 15 | +6 dB | Three slow low falling glides over a faint rumble | Ceiling 64 caps it even at +12 dB |
| D4 (round 2) | 3.5 s | 8.0 s | 49 / 14.4 | 16 / 4.2 | 49 / 14.4 | 43 / 12.7 | 0.022 ms | −14.0 dB at 4.1 ms | 0.62 | 16.2 | 16.3 | 79 / 23 | **+6 dB** | One low hum sliding down two octaves | Nearest wrong peak only 14 dB down |
| E1c glide + fifth chord bed | 3.5 s + 0.5 s bed lead | 8.5 s | 30 / 8.8 | 9.8 / 2.6 | 30 / 8.8 | 27 / 7.7 | 0.029 ms | −14.0 dB at 4.1 ms | 0.55 | 15.0 | 15.3 | 48 / 14 | +6 dB | D4's hum sliding down over a steady low open chord, like an organ drone | The bed takes 4.3 dB of the glide's level under the fixed peak |
| E1t glide + tritone bed | same | 8.5 s | 30 / 8.6 | 9.6 / 2.5 | 30 / 8.6 | 26 / 7.6 | 0.029 ms | −14.0 dB at 4.1 ms | 0.55 | 14.9 | 15.2 | 47 / 14 | +6 dB (2 of 40 bench trials refused) | The same over a steady low chord that sounds tense and unresolved | Same as E1c |
| E1n glide + brown noise bed | same | 8.5 s | 24 / 7.1 | 7.9 / 2.1 | 24 / 7.1 | 22 / 6.2 | 0.033 ms | −13.9 dB at 4.1 ms | 0.53 | 13.6 | 13.8 | 39 / 11 | +12 dB | The hum over a low rumble like distant traffic | The bed costs 6.2 dB of level and caps the ceiling at 76 |
| E24 wide sweep, −4 dB/oct | 3.5 s | 8.0 s | 38 / 10.8 | 12 / 2.9 | 45 / 12.8 | 35 / 10.0 | 0.007 ms | −13.8 dB | 0.98 | 10.5 | 10.5 | 59 / 16 | +6 dB | A faint high whistle falling into a low hum | 3 % of its energy above 2 kHz, in the first 0.8 s |
| E26 wide sweep, −6 dB/oct | 3.5 s | 8.0 s | 28 / 8.2 | 9.1 / 2.3 | 30 / 8.7 | 25 / 7.1 | 0.014 ms | −11.1 dB | 0.87 | 10.4 | 10.4 | 45 / 13 | +6 dB (9 of 40 bench trials refused) | The same with a fainter top | Weaker than D4 in every condition |
| E26c E26 + fifth chord bed | 3.5 s + 0.5 s bed lead | 8.5 s | 21 / 6.1 | 6.9 / 1.7 | 23 / 6.5 | 19 / 5.3 | 0.018 ms | −11.1 dB | 0.68 | 9.7 | 10.0 | 34 / 10 | +12 dB | The falling sweep over the organ drone | Lowest scores of the set at +6 dB |
| E29 wide sweep, −9 dB/oct | 3.5 s | 8.0 s | 22 / 6.5 | 7.1 / 2.0 | 22 / 6.5 | 17 / 3.8 | 0.028 ms | −8.6 dB | 0.68 | 10.0 | 10.0 | 36 / 11 | +12 dB | Mostly a low falling hum; the top is barely there | Nearest wrong peak only 8.6 dB down; rumble refuses 21 of 40 |
| E29c E29 + fifth chord bed | 3.5 s + 0.5 s bed lead | 8.5 s | 17 / 5.1 | 5.6 / 1.6 | 18 / 5.1 | 14 / 2.7 | 0.034 ms | −8.6 dB | 0.58 | 9.6 | 9.8 | 28 / 9 | +12 dB | The low hum over the drone | Refused in 15 of 40 trials even at standard noise |

No trial in any condition was off by more than 0.04 ms when it was not refused. Today's loud-room figure comes from round 2's Mac lane at +10 dB (31 × 5.5) and round 1's Bluetooth lane at realistic floor +10 dB (40). The other loud-room figures use flat noise; for these low sounds the 12 dB quieter floor above 3 kHz makes no difference.

## Raising the level in a loud room (E3)

The probe raised by +6 dB (Bluetooth −9, Mac −21 dBFS) and +12 dB (Bluetooth −3, Mac −15 dBFS) on both lanes. Rough live figure, loud room / rumble; bench refusals at ProbeKit's gate of 5 in the loud room; sound metrics of the Bluetooth window at that level. Today at real level for comparison: 25.1 sone, 3.19 acum, annoyance 39.1.

| Candidate | Real level | +6 dB | +12 dB | Loudness / sharpness / annoyance at +6 | at +12 |
|---|---|---|---|---|---|
| D2 | 15 / 55 (40 of 40 refused) | 36 / 64 (0 refused) | 64 / 64 (0) | 17.8 sone / 0.57 / 18.1 | 27.1 / 0.58 / 27.6 |
| D4 | 23 / 70 (37 refused) | **50 / 139** (0) | 100 / 272 (0) | 24.0 / 0.62 / 24.3 | 35.1 / 0.63 / 35.7 |
| E1c | 14 / 43 (40) | 31 / 85 (0) | 61 / 168 (0) | 22.3 / 0.55 / 22.7 | 33.1 / 0.55 / 33.9 |
| E1t | 14 / 42 (40) | 30 / 83 (2) | 60 / 165 (0) | 22.1 / 0.55 / 22.6 | 32.8 / 0.55 / 33.6 |
| E1n | 11 / 34 (40) | 22 / 68 (39) | 49 / 76 (0) | 20.2 / 0.53 / 20.6 | 30.0 / 0.53 / 30.6 |
| E24 | 16 / 55 (40) | 37 / 110 (0) | 74 / 217 (0) | 16.3 / 1.00 / 16.3 | 24.6 / 1.02 / 24.7 |
| E26 | 13 / 39 (40) | 28 / 78 (9) | 57 / 154 (0) | 16.1 / 0.88 / 16.1 | 24.2 / 0.90 / 24.3 |
| E26c | 10 / 29 (40) | 19 / 59 (40) | 43 / 116 (0) | 14.9 / 0.69 / 15.5 | 22.6 / 0.70 / 23.5 |
| E29 | 11 / 21 (40) | 21 / 55 (40) | 45 / 108 (0) | 15.7 / 0.68 / 15.7 | 23.7 / 0.69 / 23.7 |
| E29c | 9 / 15 (40) | 17 / 43 (40) | 35 / 86 (0) | 14.8 / 0.58 / 15.3 | 22.4 / 0.59 / 23.2 |

Read with care:
- When the bench refuses a lane (median score under 5), the rule can still project a live figure of 25 or more, because 5 × 5.5 = 27.5. Rows where the two disagree are D2 and E1n at real level, and E1t, E26 and E1x0 at +6 dB. The bench has no notion of the real room's level; the rule rests on one live arrival.
- Clearing 37.5 (1.5 times the phone's floor) in the loud room takes +6 dB for D4 only. D2, E1c, E1t, E24 and E26 need +12 dB.
- At +12 dB every candidate is louder than today in sone terms except the E2 sweeps (22–25 sone). D4 at +12 dB reaches 35 sone, about 40 % louder than today. Sharpness stays at 0.53–1.02 acum at every level.
- Raising the level is not modelled for the speaker itself. A Mac speaker or a Bluetooth speaker at −3 dBFS peak on a low sweep may distort or buzz. Nobody has measured either.

## Beds: confidence with and without, and rival peaks

| Pair | Standard, without → with bed | Glide level lost to the bed under the fixed peak | Tallest peak more than 50 ms from the true one, with the bed |
|---|---|---|---|
| D4 → E1c (fifth chord) | 49 / 14.4 → 30 / 8.8 | 4.3 dB | −46.4 dB at −298 ms |
| D4 → E1t (tritone) | 49 / 14.4 → 30 / 8.6 | 4.4 dB | −63.4 dB at −296 ms |
| D4 → E1n (brown noise) | 49 / 14.4 → 24 / 7.1 | 6.2 dB | −38.9 dB at −85 ms |
| E26 → E26c | 28 / 8.2 → 21 / 6.1 | 2.5 dB | −57.1 dB at −297 ms |
| E29 → E29c | 22 / 6.5 → 17 / 5.1 | 2.1 dB | −54.3 dB at −297 ms |

- No bed creates a rival peak. The nearest wrong peak inside ±50 ms is unchanged by every bed (−14.0 dB for D4's glide).
- The whole cost is level. The lane's peak is fixed at −15 dBFS, the bed's peaks add to the glide's, so the glide must play quieter. The confidence drop matches the level lost almost exactly (E1c: 4.3 dB lost, score down 4.3 dB).
- Whether the bed sits in the ambient sample makes no difference. With a room-only ambient sample, as if the bed started after the sample ended, E1c scored 9.7 / 2.6 in the loud room against 9.8 / 2.6 with the bed inside it (`bench_flat_noise+10_bed_free_ambient.csv`). The app's real ambient sample ends 0.25 s before the arm and the probe starts 0.5 s after it (`MicProbeSession.swift`, `measure`), so a bed starting 0.5 s before the glide would in fact fall outside it. By this check that does not matter.
- Fifth against tritone: no measurable difference to the measurement (30 / 8.8 against 30 / 8.6). The choice is by ear.
- The brown-noise bed costs more than the chords: 6.2 dB of level, and its own randomness lowers the ceiling to 76.

## The broken controls: a parallel glide a fifth below

A glide that falls at a fixed rate looks, at a fixed frequency ratio, like the same glide shifted in time. A copy a fifth below (ratio 2:3) of an exponential sweep therefore matches the matched filter's template at a time offset of (sweep length) × ln 1.5 ÷ ln (start ÷ end frequency).

| Control | Decoration | Where the false peak lands | Its height under the true peak | Inside the bench's window? | Bench result |
|---|---|---|---|---|---|
| E1x | D4's glide + a parallel glide 400 → 100 Hz at −6 dB | 1,024 ms early | −8.9 dB | No; the window reaches 0.3 s early | Correct in all 40 trials; costs 3.3 dB of level (14.4 → 10.2) |
| E1x0 | same at equal level | 1,024 ms early | **−3.3 dB** | No | Correct in all 40; with the window widened to 1.3 s early, still correct in all 40 |
| E1y | D2's three glides + parallel glides 800 → 100 Hz at −6 dB | 253 ms early | −8.0 dB | **Yes** | Correct in all 40 at standard noise |
| E1y0 | same at equal level | 253 ms early | **−2.0 dB** | **Yes** | Correct in all 40 at standard noise |

- The control produced a second, false arrival every time: a peak 2.0 to 8.9 dB under the true one, 253 or 1,024 ms early.
- In this bench the true peak still won every trial. At equal level, 2 dB is all that separates a correct reading from one 253 ms wrong. Anything that weakens the glide's band against the decoration's would flip it. Examples: a speaker with more output at 100–200 Hz than at 150–300 Hz, or a reflection that cancels part of the band. Neither is modelled. The wizard does not check the peak margin today.
- A steady chord has no such effect. A held note matches no moment of a moving glide better than any other, so its correlation stays flat: −46 to −63 dB.

## Candidates

All lanes 48 kHz, peaks −15 dBFS (Bluetooth) and −27 dBFS (Mac) at real level. A raised-cosine fade is half a cosine cycle. Synthesis: `research/bench/bench.py`, function `round3_lanes()`.

### E1 glide + drone bed
- Glide: D4's, picked because it scored higher than D2 in every round-2 condition. Exponential sweep 600 → 150 Hz over 3.5 s, 2nd and 3rd partials at −12 and −18 dB, fades 300 ms in, 600 ms out.
- Bed: 4.0 s, starting 0.5 s before the glide and ending with it, RMS 6 dB under the glide's, fades 300 ms in, 600 ms out.
  - E1c: two equal sines, 110 and 165 Hz (root and fifth).
  - E1t: 110 and 155.56 Hz (root and tritone, 110 × √2).
  - E1n: brown noise 60–250 Hz, seed 52.
- The matched filter's template is the glide alone, at the level it sits at inside the lane. The bed plays in the 0.5 s before each glide, so the Mac's bed starts inside the 1 s gap.

### E2 wide dark sweep
- Exponential sweep 4500 → 150 Hz over 3.5 s (4.9 octaves). Its amplitude follows the instantaneous frequency at −4, −6 or −9 dB per octave, 0 dB at 150 Hz, on top of the sweep's own pink spectrum. −4 dB/oct puts the top 20 dB under the bottom; −6 puts it 29 dB under, −9 puts it 44 dB under.
- Fades 300 ms in, 600 ms out. The template is the tilted sweep, as played.
- E26c and E29c add E1c's chord bed at −6 dB, with the 0.5 s lead.
- The tilt costs more than the faint top gives back. In pink room noise the score depends on the signal's strength over the noise at each frequency, summed across the band. The tilt puts the strength at the bottom, and covering 4.9 octaves in 3.5 s gives each octave less time than D4's 2 octaves. The quieter floor above 3 kHz lifts E24 only from 10.8 to 12.8.

### E3 adaptive level
- Both lanes raised together by +6 or +12 dB. In the app this would follow a measurement of the room in the lead-in. Audyssey's room correction plays its test signal at a fixed 75 dB SPL, set by the user with a meter. Nothing in the code does this today.

## What the numbers say

1. At real level, no candidate in this set clears the loud room. Today's probe does (~170).
2. Raised 6 dB, D4, D2, E1c, E1t, E24 and E26 clear 25 in the loud room. Only D4 clears it with margin (50).
3. Raised 12 dB, every candidate clears 25 in the loud room; D4 projects to 100.
4. The cost of +6 dB on D4 is 24 sone against today's 25; +12 dB is 35 sone. Sharpness stays near 0.6 acum at every level.
5. A bed under a fixed peak costs confidence equal to the level it takes from the glide: 4.3 dB for either chord, 6.2 dB for noise.
6. No bed creates a rival peak; the nearest false peak is unchanged.
7. Fifth and tritone beds measure the same; the choice is by ear.
8. A parallel glide a fifth below creates a second arrival 253 or 1,024 ms early, 2.0 to 8.9 dB under the true one. It did not win in the bench.
9. On D2's short glides that second arrival falls inside the search window, 2 dB under the true one at equal level.
10. Tilting a wide sweep darker lowers its score at the same peak: −4 dB/oct 10.8, −6 dB/oct 8.2, −9 dB/oct 6.5, against D4's 14.4.
11. The wide sweep at −4 dB/oct is the only candidate with energy above 2 kHz (3 %).
12. Every result rests on the one-arrival scaling rule, and on speakers that do not distort at −3 dBFS on a low sweep. Neither is measured.

## Simplifications

- Everything in round 2's list applies.
- 10 seeds (40 trials) per condition instead of 20. The wide-search control run calibrated its noise 0.2 dB lower because the first arrival moves later (`--d1=1.6`).
- The level the app would raise to, and how it would measure the room first, are assumptions. The bench raises both lanes by the same amount.
- Psychoacoustic figures assume full scale = 94 dB SPL and take fluctuation strength as zero.

## Files

- Listening: `today.wav`, `D2.wav`, `D4.wav`, `E1c.wav`, `E1t.wav`, `E1n.wav`, `E1x.wav`, `E1x0.wav`, `E1y.wav`, `E1y0.wav`, `E24.wav`, `E26.wav`, `E26c.wav`, `E29.wav`, `E29c.wav`, `raised/<id>_plus6dB.wav`, `raised/<id>_plus12dB.wav`, `audition.wav`, `audition_broken_control.wav`, `audition_raised.wav`, `LEVELS.txt`. Render from `scratchpad/`: `DARK=wav3 venv/bin/python psy/probe_p5.py`.
- Bench CSVs and logs: `bench_flat`, `bench_flat_noise+10`, `bench_step12`, `bench_rumble6`, each plus `_probe+6dB` / `_probe+12dB` for the loud room and rumble; `bench_flat_wide_search`, `bench_flat_control2`, `bench_flat_noise+10_control2`, `bench_flat_noise+10_bed_free_ambient`. Re-run from `research/bench`: `.venv/bin/python bench.py --staggered --round3 --codecs=aac --smooth-hz=100 --seeds=10`, plus `--noise-boost=10`, `--noise-shape=rumble6`, `--gain-db=6`, `--only=<ids>`, `--slack-before=1.3 --d1=1.6`, `--bed-free-ambient`. Type the flags out in full; zsh does not split a flag list held in one variable.
- Sound metrics: `psy_metrics.tsv`. Re-run: `DARK=psy3 venv/bin/python psy/probe_p5.py`.
- Script copies from before this round: `research/bench/bench.py.round2`.
