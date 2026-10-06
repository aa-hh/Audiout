# Mic probe: four candidate pairs against today's

Scope: the mic probe only (the sounds the two speakers play at once while the mic listens). Not the by-ear ticks. Probe lengths from 1 s to 10 s, since the owner now allows a longer probe behind a progress bar.

Listen first: `audition.wav` plays today's probe, then P1, P2a, P2b, P3, P4 (all the 1 s and 2 s versions), each after 1.5 s of silence (starts at 0.5, 3.3, 6.1, 8.9, 12.7 and 15.5 s). Single files: `baseline.wav`, `P1.wav`, `P2a.wav`, `P2b.wav`, `P3.wav`, `P4.wav`, `p1_3s.wav` (same as `P1L3.wav`), `p5_2s.wav`, `p5_4s.wav`, `p5_6s.wav`, `p5_10s.wav`, `p3r_4s.wav`, `p3r_10s.wav` (Mac lane 6 dB louder in all of them), and the longer versions `0L3.wav`, `P1L3.wav`, `P2L2/4/6/10.wav`, `P2R2/4/6/10.wav`, `P3L2/4/6/10.wav`. Every file is matched in loudness to today's probe, lane by lane, and they share one file gain. Exceptions: `P2L4`, `P2L6` and `P2L10` are 0.5, 0.6 and 1.1 dB quieter, to avoid clipping on rare noise peaks.

Terms used below:
- **Lane**: one speaker's sound. Mac lane = the near speaker (the Mac, or the AirPlay reference). Bluetooth lane = the far speaker.
- **Matched filter**: slide the known sound along the recording and multiply; the lag with the biggest sum is the arrival time.
- **Confidence**: the correlator's score, the peak's height over the background of the correlation. Reported as Mac lane / Bluetooth lane, median of the trials. The apps use the weaker lane (`ProbeAnalyzer.swift:122`). ProbeKit refuses below 5, the Mac app below 20 (`MicProbeSession.swift:488`), the phone app below 25 (`AlignmentRunController.swift:149`).
- **Realistic floor**: room noise 12 dB lower above 3 kHz than below, as the 2026-08-28 live capture measured (`SyncProbeCorrelator.swift` lines 52-54). Level below 3 kHz is the same as the standard run.
- **Equal loudness**: each lane scaled so its loudness (Zwicker method, ISO 532-1, in sone) equals the same lane of today's probe. The standard runs instead hold every lane at the same average level (RMS) as today's sweep. Noise sounds louder than a sweep at the same RMS, so at equal loudness it plays about 8 dB quieter.
- **Ceiling**: the confidence a lane scores with no room noise and no echoes. For a sweep it is in the thousands. A noise lane's correlation carries its own random background, so its ceiling is low and does not improve in a quieter room.
- **False-peak margin**: the tallest wrong peak within ±50 ms of the true one, more than 3 ms away, in dB below the true peak, worse lane shown. The wizard never checks this.

## Bench units against the apps' floors

The bench is tuned so today's sweep scores about 31 at the standard noise. Live sweeps score far higher: real arrivals on 2026-09-26 scored 684, 734 and 1,724, and a false match with the Bluetooth speaker silent scored 55 (comment above `MicProbeSession.swift:488`). So bench numbers cannot be compared with the floors of 20 and 25 directly. The "rough live figure" below does it in two steps:

1. A lane whose score falls when room noise rises 10 dB is limited by the room. Its realistic-floor score is multiplied by 5.5 (684 live ÷ 124, today's realistic-floor Bluetooth score), then capped at its ceiling.
2. A lane whose score barely moves with 10 dB more noise (more than 70 % kept) is limited by its own structure. Its bench score is taken as its live score, since a quieter room will not raise it.

The figure for the pair is its weaker lane. "Clears with margin" means 37.5 or more, 1.5 times the phone's floor. It is a rough projection from one live data point.

## Comparison at 1 s (and P2b at 2 s)

Bench figures: Bluetooth lane through Apple AAC at 128 kbit/s, 23 dB quieter at the mic than the Mac lane, 20 noise seeds × 4 offsets. Sharpness and annoyance: the mix as heard (Mac lane 6 dB louder), whole mix scaled to 10 sone.

| Candidate | Confidence, standard noise | +10 dB noise | Realistic floor | Realistic floor, equal loudness | Realistic floor +10 dB, equal loudness | Worst error | False-peak margin | Sharpness, mix (Bluetooth lane alone) | Annoyance | Rough live figure; clears 20 and 25? | What it sounds like | Biggest risk |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Today: down 2000→500 / up 3200→10000 Hz | 150 / 31 | 55 / 10 | 150 / 124 | 150 / 124 | 55 / 40 | 0.00 ms | −21.6 dB at 3.3 ms | 2.40 (4.28) acum | 12.1 | ~680; yes | A falling whistle under a shrill rising one; two tones moving apart | The 3.2–10 kHz rising whistle is the complaint |
| P1 low glide pair | 114 / 23 | 43 / 7 | 114 / 68 | 107 / 52 | 40 / 17 | 0.01 ms | −23.7 dB at 4.4 ms | 1.50 (2.34) | 10.0 | ~380; yes | One falling glide with a quieter higher copy gliding with it | Still two plain sines, so it may still read as a test tone, only lower |
| P2a whoosh, 1.0 s | 12 / 15 | 11 / 6 | 12 / 18 | 12 / 13 | 10 / 6 (min 5.4) | 0.01 ms | −18.5 dB at 5.4 ms | 1.39 (2.06) | 10.2 | 12; **no** | A single soft "shh", like a breath | Mac lane's own ceiling (12) is below both app floors in any room |
| P2b whoosh, 3 swells in 2.0 s | 17 / 21 | 16 / 9 | 17 / 23 | 16 / 18 | 14 / 9 | 0.01 ms | −20.7 dB at 5.2 ms | 1.39 (2.07) | 10.2 | 17; **no** | Three soft breaths | Same: Mac lane ceiling 18 |
| P3 glide plus breath | 113 / 14 | 43 / 6 | 113 / 14 | 106 / 12 | 40 / 7 (min 6.2) | 0.01 ms | **−16.6 dB at 19.9 ms** | 1.55 (2.07) | 10.1 | 20; **no** | A fast falling run of notes over a soft hiss | Bluetooth noise lane's ceiling (20) sits at the Mac floor; tallest false peak |
| P4 minimal change | 149 / 24 | 56 / 8 | 149 / 85 | 133 / 62 | 49 / 20 | 0.00 ms | −36.8 dB at 3.8 ms | 1.78 (2.57) | 10.1 | ~470; yes | Today's falling whistle with a second, higher whistle also falling | Bluetooth lane is still a whistle at 2.7–4.5 kHz, the ear's most sensitive band |

No candidate gave a wrong answer (off by more than 2 ms) or a refusal at ProbeKit's gate of 5 in any of the 14,280 trials across all runs and lengths. The worst error anywhere was 0.023 ms. Annoyance is the Zwicker and Fastl psychoacoustic annoyance figure. It adds a penalty only above 1.75 acum, so at equal loudness every candidate sits near its floor of 10 and today's is 21 % above it.

Other columns:

| Candidate | Leak into Bluetooth filter vs true peak, 23 dB imbalance | Same, with 3 % speaker distortion on the Mac lane | AAC survival (Bluetooth confidence no codec → AAC; codec signal-to-error) | Neighbouring-cycle peak within 3 ms | Share of energy in one hearing band (100 % = pure tone) | Level vs today at equal loudness, Mac / Bluetooth lane |
|---|---|---|---|---|---|---|
| Today | −151 dB | −43 dB | 31 → 31; 43 dB | −11.7 dB at 0.23 ms | 79 % | 0 / 0 dB |
| P1 | −154 dB | −23 dB | 23 → 23; 44 dB | −12.8 dB at 1.48 ms | 77 % | −0.7 / −2.4 dB |
| P2a | −166 dB | −44 dB | 15 → 15; 34 dB | −12.7 dB at 2.27 ms | 32 % | −6.9 / −8.4 dB |
| P2b | −168 dB | −47 dB | 21 → 21; 34 dB | −12.5 dB at 0.52 ms | 31 % | −6.7 / −8.2 dB |
| P3 | −92 dB | −33 dB | 14 → 14; 30 dB | −13.1 dB at 0.50 ms | 77 % | −0.7 / −6.7 dB |
| P4 | −162 dB | −40 dB | 24 → 24; 45 dB | **−1.5 dB at 0.27 ms** | 79 % | −1.3 / −3.0 dB |

The SBC codec (ffmpeg, 345 kbit/s) gave the same confidences as no codec for every 1 s candidate (`run_flat.log` and siblings). Per-lane loudness matching leaves every heard mix within 6 % of today's loudness (P1 highest).

## Longer probes

Same bench, equal RMS (not equal loudness), AAC only. The 6 s and 10 s runs use 10 seeds (40 trials per condition) to keep runtime down.

| Candidate | Length | Seeds | Standard | +10 dB | Realistic floor | Weaker lane ÷ today's (std / +10 / realistic) | Ceiling, Mac / BT | Lane that limits | Rough live figure | Clears 20 and 25 by 1.5×? |
|---|---|---|---|---|---|---|---|---|---|---|
| Today | 1 s | 20 | 150 / 31 | 55 / 10 | 150 / 124 | 1.00 / 1.00 / 1.00 | >1000 / >1000 | BT (room) | ~680 | yes |
| Today | 3 s | 20 | 155 / 50 | 76 / 17 | 154 / 197 | 1.60 / 1.66 / 1.24 | >1000 / >1000 | Mac (room) | ~850 | yes |
| P1 | 1 s | 20 | 114 / 23 | 43 / 7 | 114 / 68 | 0.74 / 0.74 / 0.55 | >1000 / >1000 | BT (room) | ~380 | yes |
| P1 | 3 s | 20 | 114 / 36 | 58 / 12 | 113 / 105 | 1.14 / 1.19 / 0.85 | >1000 / >1000 | BT (room) | ~580 | yes |
| P2, one long template | 1 s | 20 | 12 / 15 | 11 / 6 | 12 / 18 | 0.38 / 0.64 / 0.10 | 12 / 26 | Mac (own structure) | 12 | **no** |
| P2, one long template | 2 s | 20 | 16 / 20 | 15 / 9 | 16 / 24 | 0.50 / 0.89 / 0.13 | 16 / 33 | Mac (own structure) | 16 | **no** |
| P2, one long template | 4 s | 20 | 20 / 27 | 20 / 12 | 20 / 32 | 0.65 / 1.18 / 0.16 | 22 / 46 | Mac (own structure) | 20 | **no** |
| P2, one long template | 6 s | 10 | 21 / 28 | 20 / 13 | 21 / 36 | 0.66 / 1.31 / 0.17 | 28 / 56 | Mac (own structure) | 21 | **no** |
| P2, one long template | 10 s | 10 | 24 / 34 | 24 / 16 | 24 / 44 | 0.78 / 1.64 / 0.20 | 32 / 69 | Mac (own structure) | 24 | **no** |
| P2b, three swells | 2 s | 20 | 17 / 21 | 16 / 9 | 17 / 23 | 0.53 / 0.89 / 0.13 | 18 / 34 | Mac (own structure) | 17 | **no** |
| P2, same 1 s swell repeated, median | 2 s | 20 | 8 / 13 | 8 / 6 | 8 / 13 | 0.25 / 0.63 / 0.06 | 8 / 18 | Mac (own structure) | 8 | **no** |
| P2, same 1 s swell repeated, median | 4 s | 20 | 8 / 13 | 8 / 6 | 8 / 13 | 0.25 / 0.63 / 0.06 | 8 / 18 | Mac (own structure) | 8 | **no** |
| P2, same 1 s swell repeated, median | 6 s | 10 | 8 / 13 | 8 / 6 | 8 / 12 | 0.25 / 0.63 / 0.06 | 8 / 18 | Mac (own structure) | 8 | **no** |
| P2, same 1 s swell repeated, median | 10 s | 10 | 8 / 13 | 8 / 6 | 8 / 12 | 0.25 / 0.63 / 0.06 | 8 / 18 | Mac (own structure) | 8 | **no** |
| P3 | 1 s | 20 | 113 / 14 | 43 / 6 | 113 / 14 | 0.44 / 0.64 / 0.11 | >1000 / 20 | BT (room, then own ceiling) | 20 | **no** |
| P3 | 2 s | 20 | 124 / 17 | 53 / 9 | 124 / 17 | 0.54 / 0.86 / 0.13 | >1000 / 22 | BT (room, then own ceiling) | 22 | **no** |
| P3 | 4 s | 20 | 66 / 23 | 48 / 12 | 66 / 23 | 0.73 / 1.16 / 0.19 | 287 / 32 | BT (room, then own ceiling) | 32 | **no** |
| P3 | 6 s | 10 | 20 / 24 | 20 / 13 | 20 / 26 | 0.64 / 1.26 / 0.16 | 109 / 39 | Mac (own structure) | 20 | **no** |
| P3 | 10 s | 10 | 8 / 28 | 8 / 16 | 8 / 31 | 0.24 / 0.75 / 0.06 | 16 / 48 | Mac (own structure) | 8 | **no** |
| P4 | 1 s | 20 | 149 / 24 | 56 / 8 | 149 / 85 | 0.78 / 0.79 / 0.69 | >1000 / >1000 | BT (room) | ~470 | yes |
| P5 (P1's Mac sweep + BT whoosh) | 2 s | 20 | 147 / 17 | 58 / 9 | 147 / 17 | 0.55 / 0.90 / 0.14 | >1000 / 22 | BT (room, then own ceiling) | 22 | **no** |
| P5 | 4 s | 20 | 121 / 23 | 65 / 12 | 121 / 23 | 0.74 / 1.20 / 0.19 | >1000 / 32 | BT (room, then own ceiling) | 32 | **no** |
| P5 | 6 s | 10 | 54 / 24 | 44 / 13 | 54 / 26 | 0.77 / 1.30 / 0.21 | >1000 / 39 | BT (room, then own ceiling) | 39 | just (by 1.5) |
| P5 | 10 s | 10 | 58 / 28 | 49 / 16 | 57 / 31 | 0.90 / 1.60 / 0.25 | >1000 / 48 | BT (room, then own ceiling) | 48 | yes |
| P3R (fast 1 s note run repeated + BT whoosh) | 4 s | 20 | 113 / 23 | 65 / 12 | 113 / 23 | 0.74 / 1.20 / 0.19 | >1000 / 32 | BT (room, then own ceiling) | 32 | **no** |
| P3R | 10 s | 10 | 48 / 28 | 44 / 16 | 48 / 31 | 0.90 / 1.60 / 0.25 | >1000 / 48 | BT (room, then own ceiling) | 48 | yes, but see the 1 s rival |

**Rule observed:** confidence grows close to the square root of duration. Room-limited sweep lanes gain ×1.6 for 3× the length (√3 = 1.73). A noise lane's ceiling tracks √(time × bandwidth) but falls short as the probe gets longer: 0–6 % short up to 6 s and 15 % short at 10 s for the Mac whoosh (12, 16, 22, 28, 32 against a predicted 12, 17, 21, 29, 38), 10–16 % short for the Bluetooth whoosh (26, 33, 46, 56, 69 against 26, 37, 52, 64, 82).

Notes on the table:
- The 300–1100 Hz Mac whoosh is the bottleneck of every P2 version. At 10 s it reaches 32 with no room at all and 24 in the bench. Extending from the 10 s figure by the √ rule, it would need about 14 s to reach 37.5, and more if the shortfall keeps growing. It also stays below the 55 a false match scored live, so for a whoosh the score can no longer tell a true arrival from a false one.
- The Bluetooth whoosh (1500–4500 Hz, about 3.7 times wider) clears 37.5 from about 4 s (ceiling 46). A sweep on the Mac lane with a whoosh of 4 s or more on the Bluetooth lane was not benched. Its Bluetooth lane would land near P2's figures, roughly 32–44 in the bench and 46–69 at the ceiling.
- The repeated swell does not raise the score. Each swell is measured alone as a 1 s probe, so each scores like a 1 s whoosh or lower. Each 1.75 s search slice also takes in the edges of the neighbouring identical swells, which likely explains why it scores 8 / 13 against P2a's 12 / 15. The median of several arrivals guards against one swell spoiled by a passing noise, which this bench does not model. Errors were already under 0.02 ms without it.
- Slowing P3's scale ruins its Mac lane. Spreading 24 semitones over 6 s or 10 s holds each note for 250 or 420 ms. The correlation of a held note stays tall far from the peak: false peaks at −10.1 dB (45 ms, 6 s version) and −9.1 dB (48 ms, 10 s version), and Mac-lane scores of 20 and 8 regardless of room noise. A longer P3 would need the fast 1 s run repeated instead. That version was not benched.
- Sweeps lengthen cleanly: today's probe at 3 s scored 50 against 31, and P1 at 3 s scored 36 against 23, taking P1 past today's 1 s probe in every condition but the realistic floor (105 vs 124).

## P5 and P3R: a sweep-type Mac lane with the whoosh on the Bluetooth lane

Same columns as the 1 s comparison. Bluetooth lane through AAC; 20 seeds at 2 and 4 s, 10 seeds at 6 and 10 s. Sharpness and annoyance: heard mix (Mac lane 6 dB louder) scaled to 10 sone.

| Candidate | Standard | +10 dB | Realistic floor | Realistic floor, equal loudness | Realistic floor +10 dB, equal loudness | Worst error | False-peak margin, Mac / BT (±50 ms) | Sharpness, mix (BT alone) | Annoyance | Rough live figure; clears 20 and 25 by 1.5×? |
|---|---|---|---|---|---|---|---|---|---|---|
| Today, 1 s | 150 / 31 | 55 / 10 | 150 / 124 | 150 / 124 | 55 / 40 | 0.00 ms | −21.6 / −41.7 dB | 2.40 (4.28) | 12.1 | ~680; yes |
| P5, 2 s | 147 / 17 | 58 / 9 | 147 / 17 | 148 / 15 | 59 / 10 | 0.01 ms | −21.0 / −27.4 dB | 1.52 (2.05) | 10.1 | 22; **no** |
| P5, 4 s | 121 / 23 | 65 / 12 | 121 / 23 | 123 / 22 | 66 / 14 | 0.01 ms | −22.2 / −30.4 dB | 1.52 (2.05) | 10.1 | 32; **no** |
| P5, 6 s | 54 / 24 | 44 / 13 | 54 / 26 | 54 / 24 | 44 / 16 | 0.01 ms | −21.7 / −31.9 dB | 1.52 (2.04) | 10.1 | 39; just |
| P5, 10 s | 58 / 28 | 49 / 16 | 57 / 31 | 57 / 30 | 49 / 20 | 0.01 ms | −21.0 / −31.4 dB | 1.52 (2.04) | 10.1 | 48; yes |
| P3R, 4 s | 113 / 23 | 65 / 12 | 113 / 23 | 114 / 22 | 66 / 14 | 0.01 ms | −18.6 (17.7 ms) / −30.4 dB; **−2.5 dB at 1 s** | 1.53 (2.05) | 10.2 | 32; **no** |
| P3R, 10 s | 48 / 28 | 44 / 16 | 48 / 31 | 48 / 30 | 44 / 20 | 0.01 ms | −18.5 (17.7 ms) / −31.4 dB; **−0.9 dB at 1 s** | 1.53 (2.04) | 10.2 | 48; yes, if the 1 s rival is kept out of the search |

No wrong answer and no refusal at ProbeKit's gate of 5 in any P5 or P3R trial. Level vs today at equal loudness: Mac lane +0.2 to +0.5 dB, Bluetooth lane −5.4 to −6.0 dB. One-band energy share 77 % for both (the louder Mac lane is a pure tone at every instant).

What these rows show:
- The Bluetooth whoosh decides both. Its ceiling (22, 32, 39, 48 at 2, 4, 6, 10 s) is the pair's rough live figure. P5 and P3R share the same whoosh, so they share these figures.
- The whoosh needs about 6 s to reach 37.5 and 10 s to clear it comfortably. At 10 s the bench's hardest run (realistic floor, +10 dB noise, equal loudness) still scored it 20, worst trial 19.
- **P3R's repeat creates a near-copy of the true peak exactly 1 s away**: 2.5 dB lower at 4 s (3 of 4 runs overlap) and 0.9 dB lower at 10 s (9 of 10). Measured from the full correlation of the Mac lane with its own template. The bench cannot see it: its search spans only about 1.1 s of lags, and the true peak sits 0.6 s in, so neither ±1 s lag is inside. In the real wizard the rival is reachable whenever the capture runs more than 1 s past the probe on either side. With noise or one echo, the correlator could then pick it and report an offset wrong by exactly 1000 ms, at full confidence. Shipping P3R needs the search limited to lags under 1 s around the expected arrival (Bluetooth latency is 100–300 ms), or a run that changes from repeat to repeat. Neither is in the code today.
- Inside ±50 ms, P3R's Mac lane keeps the 1 s P3 note structure: −18.6 dB at 17.7 ms.

**A finding that affects every long probe: the noise weighting caps long sweeps.** The Mac lane of P5 scores 147 at 2 s, then 121, 54 and 58 at 4, 6 and 10 s. A sweep should improve with length. With the noise weighting turned off, the same 10 s sweep scores 402 on the same recording (2 s: 201, 4 s: 276, 6 s: 318). The weighting divides each frequency by the room-noise spectrum measured in the 0.5 s before the probe, smoothed over 64 FFT bins either side. A longer probe means a bigger FFT, so 64 bins cover fewer Hz, the smoothed noise estimate gets ragged, and the raggedness acts like a random filter that raises the background of the correlation. The shipping correlator uses the same 64-bin radius (`SyncProbeCorrelator.swift:541`), so a live probe longer than about 4 s would hit the same cap. P3R's Mac lane (113 → 48) and the slowed P3 rows above are hit the same way, so their long-probe Mac scores are partly this cap rather than the sound. Fix if a long probe is chosen: smooth over a fixed width in Hz, not a fixed bin count. Not benched.

## Candidates

All lanes are 48 kHz. "Fades 200/400" means a raised-cosine fade (half a cosine cycle) 200 ms in and 400 ms out. An exponential sweep is a sine whose frequency changes by a fixed ratio per second (Farina's sweep, the kind used today). Synthesis code: `research/bench/bench.py`, function `candidates()`, rows starting `P`, `0L3`.

### Today (baseline)
- Mac lane: exponential sweep down 2000 → 500 Hz. Bluetooth lane: up 3200 → 10000 Hz. Fades 80/80 ms. 1.0 s, and a 3.0 s version (`0L3`) with the same bands and fades.
- Guard gap 2000–3200 Hz.

### P1 low glide pair
- Mac lane: exponential sweep down 1100 → 300 Hz, plain sine.
- Bluetooth lane: exponential sweep down 5500 → 1500 Hz. At every instant its frequency is exactly 5× the Mac lane's (two octaves and a major third), and both glide at the same rate, so they move together.
- Fades 200/400 on both. 1.0 s, and a 3.0 s version (`P1L3`) with the same bands and fades.
- Bands over the whole probe: 300–1100 and 1500–5500 Hz, guard gap 1100–1500 Hz. At 1 s the Bluetooth lane is above 4.5 kHz only for its first 0.15 s, while still fading in.
- Level: −0.7 dB (Mac) and −2.4 dB (Bluetooth) below today's RMS sounds as loud as today.
- **The harmonic Mac lane does not fit.** With 2nd and 3rd partials (amplitudes 1, 0.5, 0.25), the 3rd partial sweeps 3300 → 900 Hz and crosses the Bluetooth band 0.39 s before the Bluetooth lane gets there. Because both are exponential sweeps at the same rate, the Bluetooth matched filter turns that into a sharp peak 3.4 dB taller than the real one. Bench row `P1h`: wrong by about 390 ms in 79 of 80 trials. Under the realistic floor it happened to pass, because the noise weighting favours the band above 3 kHz, where the partial never goes. A plain sine is the only safe Mac lane here.
- Real speaker distortion causes the same effect in a weaker form: a 3 % 2nd harmonic on the Mac lane leaks to 23 dB below the true Bluetooth peak, against 43 dB today. Distortion would have to reach about 45 % to win.

### P2 whoosh
- Both lanes: pink noise (power falling 3 dB per octave), band-limited in the frequency domain to Mac 300–1100 Hz and Bluetooth 1500–4500 Hz, with raised-cosine skirts over the inner 10 % of each band edge. Fixed seeds 31 (Mac) and 32 (Bluetooth), numpy's default generator. Guard gap 1100–1500 Hz.
- **P2a**: one Hann swell over 1.0 s (rises for 0.5 s, falls for 0.5 s, no flat top), identical on both lanes.
- **P2b**: 2.0 s, three Hann swells of 0.667 s back to back. This is the shape the earlier bench found best (`04-experiments.md`, row 2c).
- **P2, one long template** (`P2L2`, `P2L4`, `P2L6`, `P2L10`): fresh noise for the whole 2, 4, 6 or 10 s, shaped into back-to-back 1 s Hann swells, matched as one template of the full length.
- **P2, repeated** (`P2R2` … `P2R10`): the P2a swell, sample for sample, played 2, 4, 6 or 10 times back to back. Each swell is searched on its own in a slice from 0.3 s before to 1.45 s after its expected start, with the 1 s swell as the template. Swells where both lanes reach 5 count; the reported offset is their median; the pair is refused if fewer than half count. Reported confidences are the medians over swells.
- Level: about −7 dB (Mac) and −8.3 dB (Bluetooth) below today's RMS to sound as loud as today. Equal loudness lowers the room-limited part of the score but not the ceiling, which scales with the signal.
- Shipping it needs a noise generator defined in ProbeKit, because the phone rebuilds the probe from the same code and must produce the same samples. numpy's generator is not that.

### P3 glide plus breath
- Mac lane: exponential sweep 1200 → 300 Hz held on equal-tempered semitones (24 notes, about 42 ms each at 1 s), joined by 10 ms glides with no phase jump. The brief asked for 10 ms crossfades; glides are what the earlier bench used (row 3a), and they keep the waveform continuous.
- Bluetooth lane: the P2 Bluetooth noise (1500–4500 Hz, seed 32) with no swell.
- Fades 200/400 on both, so the two lanes share one envelope. Guard gap 1200–1500 Hz.
- Longer versions (`P3L2` … `P3L10`): the same 24-note run spread over 2, 4, 6 or 10 s (notes 83, 167, 250, 420 ms), with the noise lengthened to match.
- Level: −0.7 dB (Mac) and −6.7 dB (Bluetooth) below today's RMS.
- At 1 s the notes share a common period, which puts a correlation peak 19.9 ms from the true one at −16.6 dB on the Mac lane.

### P4 minimal change
- Mac lane: today's sweep, down 2000 → 500 Hz.
- Bluetooth lane: exponential sweep **down** 4500 → 2700 Hz, 1.0 s.
- Fades 200/400 on both.
- Why 2700, not 1600: 1600 Hz sits inside the Mac lane's 500–2000 Hz band, and the code says to keep a guard gap (`SyncProbeCorrelator.swift` line 49). 2000–2700 Hz gives the same 1.35 ratio as P1's gap. The literal 4500 → 1600 version was benched as row `P4x`. It measured correctly, but its leak sat only 25 dB under the true peak instead of 162 dB, and its realistic-floor confidence was 55 against P4's 85.
- Level: −1.3 dB (Mac) and −3.0 dB (Bluetooth) below today's RMS.
- The Bluetooth lane is narrow for its pitch (1.8 kHz wide around 3.5 kHz), so the neighbouring cycle of the correlation, 0.27 ms away, is only 1.5 dB lower. A slip onto it costs 0.27 ms, far inside the ±6 ms blend bar.

### P5 sweep plus whoosh
- Mac lane: P1's exponential sweep down 1100 → 300 Hz, plain sine, stretched to the full length (2, 4, 6 or 10 s).
- Bluetooth lane: 1500–4500 Hz pink noise (seed 32), same length.
- Fades 200/400 on both, so both lanes start and end together with one envelope. Guard gap 1100–1500 Hz.
- Level at equal loudness: Mac lane +0.2 to +0.5 dB, Bluetooth lane −5.4 to −6.0 dB against today's RMS.

### P3R repeated note run plus whoosh
- Mac lane: P3's 1 s run (1200 → 300 Hz, 24 semitone notes of about 42 ms, 10 ms glides between notes), repeated back to back 4 or 10 times. Each repeat has a 10 ms fade in and out so the jump from 300 Hz back up to 1200 Hz does not click. One template covers the whole length.
- Bluetooth lane: 1500–4500 Hz pink noise (seed 32), same length.
- Fades 200/400 over the whole length on both lanes.
- Level at equal loudness: Mac +0.3 / +0.4 dB, Bluetooth −5.6 / −5.4 dB.

## What the numbers say

1. Every version measured within 0.023 ms in all 14,280 trials. The differences lie in how far each scores above the apps' floors of 20 (Mac) and 25 (phone).
2. Only the sweep pairs clear both floors with margin: today's, P1 and P4, at 1 s and at 3 s.
3. No whoosh version clears them, up to 10 s. The 300–1100 Hz Mac whoosh is capped by its own randomness at 12 (1 s) to 32 (10 s), whatever the room.
4. P3 fails on its 1500–4500 Hz Bluetooth noise lane at 1–4 s, and on its slowed Mac scale at 6 and 10 s.
5. Confidence grows near √duration. Noise ceilings follow √(time × bandwidth), up to 15 % short at 10 s.
6. Repeating one identical 1 s swell and taking the median arrival leaves the score where a single swell puts it.
7. Today's Bluetooth lane gains the full 12 dB from the realistic floor (31 → 124). Moving it lower gives part back: P4 85, P1 68 at equal RMS; 62 and 52 at equal loudness.
8. A 3 s P1 (105 realistic, 36 standard) roughly matches today's 1 s probe while being far less sharp.
9. Sharpness drops from 2.40 acum today to 1.39–1.78 for every candidate. The Bluetooth lane alone drops from 4.28 to 2.06–2.57.
10. Sweeps and P3 put 77–79 % of their energy in one hearing band at a time, like a pure tone. Whooshes put 31–32 %.
11. A harmonic Mac lane under a parallel Bluetooth glide produces a confident 390 ms error.
12. P1 is the most exposed to the Mac speaker's distortion: leak 23 dB under the true peak at 3 %, against 43 dB today.
13. AAC and SBC changed no confidence.
14. A sweep or note run on the Mac lane with the whoosh on the Bluetooth lane (P5, P3R) clears both floors from about 6 s and comfortably at 10 s; the whoosh's ceiling is the limit.
15. P3R at 10 s puts a rival peak 0.9 dB under the true one, exactly 1 s away, outside what this bench searches.
16. The shipping noise weighting caps any sweep longer than about 4 s; a long probe needs it changed.

## Simplifications (read before trusting a number)

- Everything in the simplifications list of `04-experiments.md` applies: pink-noise room with no voices or hum, 6 discrete echoes with no diffuse tail, a perfect mic, no speaker frequency response, one AAC and one SBC encoder setting, no Bluetooth packet loss.
- The rough live figure rests on one live data point (684) and a simple rule for which lanes the room limits. Treat it as an order of magnitude. Its strongest part is the noise lanes: their ceilings come from the signal alone and should carry over to a real room, though the real capture length shifts the score somewhat.
- The realistic floor is one live capture's figure turned into a step: 12 dB lower above 3 kHz, with a half-octave transition centred on 3 kHz. Real rooms vary.
- The "+10 dB noise" column uses flat noise. That is harsher on today's probe and on P4 than a real louder room would be, because both live mostly above 3 kHz.
- The longer runs use AAC only, equal RMS only, and 10 seeds at 6 s and 10 s. No psychoacoustic figures were computed for the longer versions; their spectra match the 1 s versions, so sharpness does not change, and the effect of a longer exposure on annoyance is not modelled.
- Equal-loudness trims are computed on each lane alone, dry, with full scale assumed to be 94 dB SPL. The sharpness and annoyance figures scale the whole heard mix to 10 sone instead.
- The annoyance figure takes fluctuation strength (slow loudness wobble) as zero. Swells at 1–1.5 Hz would add a little.
- Speaker distortion is a simple formula on the Mac lane (2nd harmonic at −30 dB, 3rd at −40 dB). The level is an assumption. Nobody has measured a Mac speaker at probe volume.
- False peaks are measured on a clean recording with no noise and no echoes, so they show the sound's own structure. Echoes add real secondary arrivals 5–60 ms after the true one for every candidate.
- Listening files have no room, no codec and no speaker colouring. The left/right placement is a 2 dB level difference. The "sounds like" column describes the signal as synthesised; nobody has listened to it yet.

## Files

- Listening files listed at the top, 48 kHz stereo, 0.5 s silence first.
- 1 s runs: `bench_flat.csv`, `bench_flat_noise+10.csv`, `bench_step12.csv`, `bench_step12_equal_loudness.csv`, `bench_step12_noise+10_equal_loudness.csv`. Longer runs: `bench_{flat,flat_noise+10,step12}_dur_upto4s.csv` and `..._dur_6_10s.csv`. P5 and P3R: `bench_*_p5p3r_short.csv` (2 and 4 s) and `bench_*_p5p3r_long.csv` (6 and 10 s), including the two equal-loudness conditions. Each has a matching `run_*.log`.
- `psy_metrics.tsv`: loudness, sharpness, roughness, annoyance, one-band energy share, trims. `equal_loudness_trims.json`: per-lane trims.
- Re-run from `research/bench`: `.venv/bin/python bench.py --only=<ids>` plus any of `--noise-boost=10`, `--noise-shape=step12`, `--trims=../shaped/probe/equal_loudness_trims.json`, `--seeds=N`, `--codecs=aac`, `--tag=name`. Psychoacoustics and 1 s listening files, from `scratchpad/`: `venv/bin/python psy/probe_options.py`; longer listening files: `venv/bin/python psy/probe_long_wavs.py`; P5 metrics and files: `venv/bin/python psy/probe_p5.py`, and `IDS=P3R4,P3R10 venv/bin/python psy/probe_p5.py` for P3R.
