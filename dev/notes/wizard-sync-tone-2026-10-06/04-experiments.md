# 04 — Numerical experiments on candidate sync-probe sounds

Bench: `bench/bench.py` (Python 3.14, numpy 2.5.3, scipy 1.18.1 in `bench/.venv`). Raw numbers: `bench/results.csv` (calibrated noise) and `bench/results_noise+10.csv` (10 dB more noise). Listening files: `bench/out/*.wav` (left = reference lane, right = target lane), levels in `bench/out/levels.tsv`.

## Method

1. Each candidate is two lanes at 48 kHz: a reference lane (the Mac side) and a target lane (the Bluetooth side).
2. Every lane is scaled to the same RMS as today's sweep at 0.175 full scale (-18.6 dBFS RMS), so candidates are compared at equal average level, not equal peak.
3. The target lane goes through a real codec round trip before mixing: Apple AAC at 128 kbit/s (`afconvert`), and SBC at 345 kbit/s (ffmpeg's built-in SBC encoder, stereo). The fixed codec delay (AAC 0 samples after `afconvert` trims priming, SBC 73 samples) was measured once with white noise and removed.
4. Simulated mic tape: 0.5 s probe-free lead-in, reference lane at 0 dB arriving at 0.6 s, target lane at -23 dB arriving 0.6 s + offset. Offsets: -40, -7, +3.3, +120 ms, applied as exact fractional delays in the frequency domain.
5. Each arrival gets 6 discrete echoes 5-60 ms later, gain 0.2-0.5 times exp(-delay/30 ms), random per trial.
6. Pink noise is added over the whole tape. Its level (-35.5 dBFS RMS) was set by bisection so today's sweep pair scores a median weaker-lane confidence of about 30. A second full run uses 10 dB more noise (-25.5 dBFS).
7. The correlator is a line-by-line Python copy of `SyncProbeCorrelator.swift`: matched filter via FFT, per-bin weighting by the smoothed lead-in noise spectrum (64-bin box, 5% floor), highest positive peak, parabolic interpolation, confidence = peak / (sqrt(2 ln N) x median|background| / 0.6745), background taken outside [peak - 5 ms, peak + 250 ms].
8. Like `ProbeAnalyzer`, it tries the noise-weighted filter first and falls back to the plain one if either lane scores below 5; a lane below 5 counts as refused.
9. Measured per trial: offset error (ms), confidence per lane, and `peakMargin` as the real code defines it (peak over the best lag more than 3 ms away).
10. Leak: the target lane's matched filter run on the reference lane alone, peak over the peak it gives the real target lane, at equal level, then shifted by the 23 dB imbalance. Positive means the loud lane's leak beats the quiet lane's real peak.
11. Confidence with no room noise and no echoes: the most a stimulus can score on this tape, set by its own structure.
12. 20 noise seeds x 4 offsets = 80 trials per candidate per codec. "Wrong" = accepted (both lanes at 5 or more) but off by more than 2 ms. That is a confident wrong answer, the worst outcome.
13. Main table numbers are the AAC condition, since that is the Bluetooth path the Mac most often uses.
14. The shared-band check row (0x) reproduces the field figure: down and up sweeps sharing 500 Hz-10 kHz isolate by 34.9 dB here, against the 33 dB measured live. The bench and the field agree on that number.

## Results (AAC on the target lane, calibrated noise unless the column says otherwise)

| Candidate | Median err ms | Worst err ms | Wrong (>2 ms) / refused, of 80 | Median confidence ref / tgt | Confidence with no noise or echoes, ref / tgt | Median peak margin | Leak into target filter vs real target peak, dB (23 dB imbalance) | AAC survival: tgt confidence no codec → AAC; codec signal-to-error dB | SBC signal-to-error dB | +10 dB noise: tgt confidence; wrong / refused |
|---|---|---|---|---|---|---|---|---|---|---|
| 0 baseline: down 2000→500 / up 3200→10000 | 0.001 | 0.00 | 0 / 0 | 150 / 31 | >1000 / >1000 | 3.64 | < -60 | yes: 31→31; 43 | 63 | 10; 0 / 0 |
| 0x check: down/up sweeps sharing 500 Hz-10 kHz | – | – | 0 / 80 | 203 / 2 | 310 / 2 | 2.86 | -11.9 | 2→2; 47 | 64 | 2; 0 / 80 |
| 1a up sweep capped 3200→6000 | 0.001 | 0.00 | 0 / 0 | 150 / 27 | >1000 / >1000 | 3.65 | < -60 | yes: 27→27; 45 | 64 | 9; 0 / 0 |
| 1b up sweep capped 3200→4500 | 0.001 | 0.00 | 0 / 0 | 150 / 25 | >1000 / >1000 | 3.63 | < -60 | yes: 25→25; 44 | 64 | 8; 0 / 0 |
| 2a whoosh 1.0 s (400-1800 / 2500-7000 Hz pink noise, raised-cosine swell) | 0.001 | 0.00 | 0 / 0 | 16 / 18 | 17 / 31 | 3.54 | < -60 | yes: 18→18; 32 | 46 | 8; 0 / 0 |
| 2b whoosh 2.0 s | 0.001 | 0.00 | 0 / 0 | 12 / 18 | 13 / 23 | 3.63 | < -60 | yes: 18→18; 41 | 46 | 10; 0 / 0 |
| 2c whoosh, three swells in 2.0 s | 0.001 | 0.00 | 0 / 0 | 22 / 25 | 22 / 40 | 3.64 | < -60 | yes: 25→25; 32 | 46 | 11; 0 / 0 |
| 2o whoosh 1.0 s, both lanes 500-6000 Hz (different seeds) | – | – | 0 / 80 | 28 / 2 | 30 / 2 | 1.08 | -0.6 | 2→2; 34 | 51 | 2; 0 / 80 |
| 2o' whoosh 2.0 s, both lanes 500-6000 Hz | – | – | 0 / 80 | 21 / 2 | 22 / 1 | 1.43 | -2.8 | 2→2; 43 | 51 | 1; 0 / 80 |
| 3a sweep held on semitones (10 ms glides) | 0.003 | 0.01 | 0 / 0 | 141 / 29 | >1000 / >1000 | 2.57 | < -60 | yes: 29→29; 44 | 63 | 9; 0 / 0 |
| 3b sweep held on major-pentatonic notes | 0.007 | 0.02 | 0 / 0 | 105 / 23 | >1000 / >1000 | 1.32 | < -60 | yes: 23→23; 45 | 64 | 8; 0 / 0 |
| 4a plucked phrase 1.5 s, low lane 220-554 Hz, answer 2 octaves up (as specified) | 368 | 495 | 63 / 2 | 15 / 6 | 16 / 8 | 1.08 | +5.2 | 6→6; 45 | 54 | 5; 54 / 26 |
| 4b chord stab 0.5 s (same notes, all at once) | 2.2 | 120 | 41 / 0 | 65 / 11 | 756 / 475 | 1.04 | +3.9 | 11→11; 31 | 52 | 5; 32 / 38 |
| 4c plucked phrase kept inside today's bands (low 554-988 Hz + 2nd harmonic; high 3 octaves up, 4.4-7.9 kHz) | 0.007 | 0.03 | 0 / 0 | 53 / 14 | 63 / 24 | 1.19 | < -60 | yes: 14→14; 45 | 54 | 7; 0 / 0 |
| 4o plucked phrases, both lanes 660-1480 Hz fundamentals | 377 | 415 | 80 / 0 | 27 / 7 | 34 / 8 | 1.27 | +13.7 | 7→7; 47 | 60 | 7; 80 / 0 |
| 5 Schroeder-phase multisine, 50 Hz grid (31 / 137 tones) | 0.002 | 0.01 | 0 / 0 | 7 / 16 | 12 / 50 | 1.01 | < -60 | yes: 16→16; 25 | 37 | 8; 1 wrong by exactly 20.00 ms / 0 |
| 6 Golay A (1024 chips at 1024/s, 1250 Hz carrier) / Golay B (4096 at 4096/s, 6600 Hz) | 0.001 | 0.00 | 0 / 0 | 26 / 26 | 47 / 103 | 3.55 | < -60 | yes: 27→26; 24 | 37 | 10; 0 / 0 |
| 6o Golay pair A / B, both lanes 500-6000 Hz | 205 | 240 | 73 / 7 | 71 / 6 | 109 / 9 | 1.21 | +2.2 | 6→6; 27 | 49 | 4; 0 / 80 |
| 7a today's sweeps under same-band pink noise bed, bed 6 dB louder than the sweep (filter knows the sweep only) | 0.006 | 0.01 | 0 / 0 | 7 / 10 | 6 / 15 | 3.49 | < -60 | yes: 10→10; 27 | 35 | 5; 0 / 79 |
| 7b same, bed 12 dB louder | – | – | 0 / 80 | 3 / 6 | 3 / 8 | 2.88 | < -60 | 6→6; 26 | 34 | 3; 0 / 80 |

Leak at equal level (before the 23 dB imbalance): sweeps sharing a band -34.9 dB, whoosh sharing a band -23.6 dB (1 s) and -25.8 dB (2 s), Golay A against B -20.9 dB, plucked phrases sharing a register -9.3 dB, every disjoint-band pair below -90 dB.

The SBC column changes nothing anywhere: every candidate's errors, refusals and median confidences under SBC match the no-codec run to the printed precision; the only difference is one worst-trial confidence (Schroeder, 10.6 vs 10.7) (`bench/run_base.log`).

## What the numbers say

- **Codecs are not the problem.** AAC at 128 kbit/s and SBC at 345 kbit/s left every candidate's timing and confidence unchanged, including the noise bursts, the plucks and the Golay code, whose waveforms AAC altered most (signal-to-error 24-32 dB). Within 500 Hz-10 kHz the codecs keep phase well enough for a matched filter.
- **Disjoint bands stay mandatory.** Shared-band isolation from different noise seeds is 24-26 dB, from a Golay complementary pair 21 dB, and from opposite sweeps 35 dB. Under a 23 dB imbalance all of them leave the quiet lane at confidence 1-2 (refused) or, for the Golay pair, confidently wrong by about 200 ms in 73 of 80 trials. A random or coded signal does not buy isolation that a sweep cannot; doubling the whoosh from 1 s to 2 s bought 2.2 dB.
- **A whoosh in disjoint bands works.** Zero errors above 0.01 ms in 160 trials across both noise levels. Its price is confidence: the target lane scored 18 against the sweep's 31 at the same RMS level, and the loud reference lane is capped near 16 even with no room noise, because a random signal's correlation carries its own background ripple that a sweep's does not. That cap does not threaten the gate of 5. At 10 dB more noise the 1 s whoosh's target scored 8 against the sweep's 10; the 2 s and three-swell versions scored 10 and 11, level with the sweep.
- **The three-swell whoosh was the best noise variant:** 22 / 25 confidence against 16 / 18 for one swell.
- **Losing the top of the up sweep costs little at these noise levels.** Capping at 6 kHz dropped target confidence 31 → 27, at 4.5 kHz to 25 (about 1.5-2 dB), with no timing loss. At much lower signal levels the narrower peak would start to cost accuracy; this bench did not reach that point.
- **Musical stepping of the sweep is nearly free for semitones, riskier for pentatonic.** Semitone steps: confidence 29, errors 0.003 ms. Pentatonic: confidence 23, but the peak margin fell to 1.32, meaning a second correlation peak a few ms away reaches 76% of the true one. The wizard does not check `peakMargin` (only `PassiveDriftCorrelator` and the struct itself mention it), so a confidence of 23 would be trusted while the runner-up sits close.
- **Plucked melodies fail as specified, for frequency overlap, not because they are plucks.** The specified low phrase (220-554 Hz with harmonics to 1.7 kHz) and its answer 2 octaves up share partials, and the leak beats the real target peak by 5 dB. Result: 63 of 80 trials confidently wrong by up to 495 ms. The chord stab: 41 of 80 wrong. The same pluck shape kept inside today's disjoint bands (4c) measured correctly in all 160 trials, with lower confidence (14 at calibrated noise, 7 at +10 dB) and a peak margin of 1.19.
- **Schroeder multisine is periodic, and the numbers show it:** peak margin 1.01, so peaks every 20 ms are nearly as tall as the true one. At +10 dB noise one trial locked exactly 20.00 ms off with a passing confidence. Any repeating stimulus with a period shorter than the largest offset to be measured carries this risk.
- **Golay codes in disjoint bands measured as well as the whoosh** (26 / 26 confidence), but there is no reason to prefer them: they sound like a hissy buzz and have no edge over band-limited noise.
- **Hiding the sweep under a louder noise bed costs more than the level it takes.** With the bed 6 dB over the sweep the reference lane, at 0 dB and nowhere near the room noise, dropped from 150 to 7. The bed's noise is as loud as the speaker, so turning the volume up does not help. At +12 dB, or at +6 dB with 10 dB more room noise, nearly every trial was refused. If the bed is part of the known template instead, the signal is simply a whoosh (row 2).
- **Level and peak matter for the ear.** At equal RMS the noise bursts and plucks peak 12-17 dB above the sweep (crest factor 15-20 dB against 3.5 dB; `out/levels.tsv`). Holding today's peak level instead of today's RMS would lower the whoosh by about 12 dB and its confidence by about 4x, which would put the target lane near the gate at the calibrated noise.

## Simplifications (read before trusting a number)

- The room is a model. Pink noise with no hum, voices or music; 6 discrete echoes with no diffuse tail and no change of tone with frequency; no speaker or mic frequency response; no air absorption at 7-10 kHz.
- The mic is perfect: no clipping, no automatic gain, no built-in-mic noise reduction. The real Mac and iPhone mics apply processing this bench does not.
- Codecs: Apple's AAC encoder at 128 kbit/s and ffmpeg's SBC encoder at 345 kbit/s. Real headphones and speakers negotiate their own bitrate and SBC bitpool, and Bluetooth adds packet loss, which this bench does not model.
- Only the target lane went through a codec. The reference lane is the lossless AirPlay or built-in path.
- Equal RMS is a choice. Perceived loudness differs between a sweep and a noise burst at the same RMS, and the owner's listen decides that, not this table.
- Confidence for the noise-based stimuli depends on the tape length (this bench: 2.4-3.4 s). The real correlator measures its background over the whole tape, so a longer real capture would change their scores somewhat. Sweeps are unaffected because their background is close to zero.
- The "confidence ~30" noise level fixes the comparison point; it does not say how often real rooms are that quiet. The +10 dB run is the only harder point measured.
- Golay lanes deviate from the prompt: 1024 chips at 1024 chips/s would give the high lane only 1 kHz of bandwidth, so the high lane uses a 4096-chip code at 4096 chips/s. The low lane is the requested 1024. A and B of different lengths are not a complementary pair; the overlapping-band row (6o) uses a true A/B pair of length 4096.
- Plucked notes: 2 ms linear attack, exponential decay with a 50 ms time constant (-26 dB at 150 ms), harmonics at 1, 0.5, 0.25. The specified 150-600 Hz fundamentals put some energy below 500 Hz, where small speakers roll off; the bench does not model that roll-off.
- Stepped sweeps glide between notes over 10 ms with continuous phase instead of crossfading two tones.
- Schroeder multisine uses the 50 Hz grid across each whole lane band (31 and 137 tones), not 60 tones, so the bands match today's.

## Re-run

```bash
cd /private/tmp/claude-501/-Users-alechenderson-Projects-AirPlay-Controller--claude-worktrees-wizard-sync-tone-research-000c03/5eeb55d6-3a07-4dc1-b247-fff65b5c04f4/scratchpad/research/bench
python3 -m venv .venv && .venv/bin/pip install numpy scipy   # once
.venv/bin/python bench.py                    # calibrated noise, 20 seeds, ~3.5 min; writes results.csv and out/*.wav
.venv/bin/python bench.py --noise-boost=10   # 10 dB more noise; writes results_noise+10.csv
.venv/bin/python bench.py --quick            # 5 seeds, smoke test
```

Needs `afconvert` (macOS) and `ffmpeg` with its built-in `sbc` encoder on PATH.
