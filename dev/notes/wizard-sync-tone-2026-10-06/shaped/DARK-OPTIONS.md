# Mic probe, round 2: dark sounds played in turn

Scope: the mic probe only. Every candidate plays the same low sound on both speakers, one after the other: Bluetooth speaker first, then the Mac, each in its own 3.5 s window, 1.0 s of silence between. 8.0 s of sound, plus the existing 0.5 s lead, so 8.5 s in all. Today's probe is shown as it ships: 1.0 s, both speakers at once.

Listen first: `audition.wav` plays today, then D1, D2, D3, D4, with 2 s of silence between. Single files: `today.wav`, `D1.wav` … `D4.wav`. All are at the level the app would send; nothing is normalised. `LEVELS.txt` gives peak and RMS per file.

Terms used below:
- **dBFS**: decibels below digital full scale. Bluetooth lane peaks at −15 dBFS (0.175 full scale, today's level). Mac lane peaks at −27 dBFS for every D candidate (today ships −21 dBFS).
- **Lane**: one speaker's sound. **Window**: the stretch of the recording where that speaker's sound is expected; each lane is searched only inside its own window.
- **Matched filter**: slide the known sound along the recording and multiply; the lag with the biggest sum is the arrival time.
- **Confidence**: the correlator's score, the peak's height over the background of the correlation. Shown as Mac / Bluetooth, median of 80 trials. The apps use the weaker lane. ProbeKit refuses below 5, the Mac app below 20 (`MicProbeSession.swift:488`), the phone app below 25.
- **Ceiling**: the confidence a lane scores with no room noise and no echoes.
- **Realistic floor**: room noise 12 dB lower above 3 kHz, as the 2026-08-28 live capture measured. **Rumble**: plain pink room noise with 6 dB more below 300 Hz.
- **False-peak margin**: the tallest wrong peak within ±50 ms of the true one, more than 3 ms away, in dB below the true peak.
- **Sone**: unit of loudness (Zwicker method, ISO 532-1); 2 sone sounds twice as loud as 1. **Acum**: unit of sharpness (DIN 45692); higher means more piercing. **Annoyance**: the Zwicker and Fastl psychoacoustic annoyance figure, built from loudness, sharpness and roughness.

## Comparison

Bench: Bluetooth lane through Apple AAC at 128 kbit/s and 23 dB quieter at the mic than the Mac lane at equal digital level (as in round 1), 6 echoes, 20 noise seeds × 4 offsets. Noise smoothing set to a fixed 100 Hz (see below). Sharpness, loudness and annoyance: the Bluetooth window as played (the loudest thing the user hears), full scale taken as 94 dB SPL, no rescaling.

| Candidate | Window | Total sound | Confidence, standard | +10 dB noise | Realistic floor | Rumble | Worst error | False-peak margin | Sharpness | Loudness | Annoyance | Rough live figure; clears 20 and 25? | What it sounds like | Biggest risk |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Today, as shipped | 1.0 s, both at once | 1.0 s | 95 / 33 | 31 / 10 | 95 / 128 | 95 / 33 | 0.003 ms | −21.6 dB at 3.3 ms | 3.19 acum (Bluetooth lane alone 4.40) | 25.1 sone | 39.1 | ~520; yes | A falling whistle under a shrill rising one | It is the sound the owner called grating |
| D1 dark whoosh | 3.5 s | 8.0 s | 9.5 / 3.3 | 3.6 / 1.1 | 9.5 / 3.3 | 9.5 / 2.0 | refused in every trial | −14.5 dB at 4.6 ms | 0.65 | 11.1 | 11.4 | 9 at most; **no** | One soft low rush of air per speaker, rising and falling | Refused: the noise's own randomness caps it at 9 |
| D2 Sonos-like | 3.5 s | 8.0 s | 35 / 10.4 | 11 / 2.8 (refused in every trial) | 35 / 10.4 | 34 / 9.9 | 0.014 ms | −36.0 dB at 13 ms (−20.6 dB inside 3 ms) | 0.56 | 11.7 | 11.9 | ~57; yes | Three slow low glides falling, over a faint rumble | A room 10 dB louder projects to ~15; a near-copy of the true peak 4 dB lower sits 1.1 s away |
| D3 exhale | 3.5 s | 8.0 s | 8.7 / 3.5 | 3.8 / 1.2 | 8.7 / 3.5 | 8.1 / 2.2 | refused in every trial | −17.3 dB at 4.5 ms | 0.59 | 11.7 | 11.9 | 10 at most; **no** | A breath out: a soft "hhh" that darkens to a low hush as it fades | Refused: same cap as D1 |
| D4 low harmonic glide | 3.5 s | 8.0 s | 49 / 14.4 | 16 / 4.2 (refused in 77 of 80) | 49 / 14.4 | 43 / 12.6 | 0.022 ms | **−14.0 dB at 4.1 ms** | 0.62 | 16.2 | 16.3 | ~79; yes | One low hum sliding down two octaves, with faint overtones | Wrong peak only 14 dB down, 4.1 ms away; a room 10 dB louder projects to ~23 |

No trial in any condition gave an error over 0.03 ms when it was not refused. The Mac windows are 12 dB quieter than the Bluetooth windows: 4.9 to 7.3 sone, same sharpness. Today's Mac lane alone: 8.8 sone, 1.07 acum.

Other measured figures (from `psy_metrics.tsv` and the bench CSVs):

| Candidate | Bluetooth lane RMS | Level at 94 dB SPL full scale | Energy 150–1500 Hz | Energy above 2 kHz | Share of energy in one hearing band (100 % = pure tone) | Ceiling, Mac / Bluetooth | Tallest peak 0.3 s or more from the true one (whole sound, no window) |
|---|---|---|---|---|---|---|---|
| Today | −18.6 dBFS | 76.3 dB (mix) | 17 % | 80 % | 80 % | >100,000 / >100,000 | none (each lane is one sweep) |
| D1 | −30.4 dBFS | 63.6 dB | 100 % | 0 % | 46 % | 9 / 9 | −24.3 dB at 0.93 s |
| D2 | −23.2 dBFS | 70.8 dB | 94 % | 0 % | 88 % | 64 / 64 (300 / 300 matched against the sweeps only) | **−4.2 dB at 1.1 s** |
| D3 | −30.3 dBFS | 63.7 dB | 100 % | 0 % | 42 % | 10 / 10 | −22.2 dB at 0.42 s |
| D4 | −19.2 dBFS | 74.8 dB | 100 % | 0 % | 86 % | >100,000 / 4,192 | −19.9 dB at 1.75 s |

### Rough live figure, and its limits

Same rule as `PROBE-OPTIONS.md`. A lane whose score falls with 10 dB more noise is limited by the room: its realistic-floor score × 5.5 (684 live ÷ 124 bench, today's Bluetooth lane), capped at its ceiling. The pair's figure is its weaker lane. "Clears with margin" means 37.5 or more.

- Today: Mac lane 95 × 5.5 ≈ 520, Bluetooth 128 × 5.5 ≈ 700. Round 1 said ~680 because it played the Mac lane 6 dB louder than the app does.
- D2: Bluetooth 10.4 × 5.5 ≈ 57, under its ceiling of 64. Rumble: ≈ 54. A room 10 dB louder: 2.8 × 5.5 ≈ 15.
- D4: Bluetooth 14.4 × 5.5 ≈ 79. Rumble: ≈ 69. A room 10 dB louder: 4.2 × 5.5 ≈ 23, under the phone's 25.
- D1 and D3: capped by their ceilings of 9 and 10 whatever the room.
- Limits: the 5.5 comes from one live arrival on a lane above 3 kHz. It assumes the real room's noise at 150–1500 Hz stands in the same relation to the bench as the real room above 3 kHz did. Real rooms often have more low rumble than pink noise (fans, traffic). The rumble column models +6 dB of it; more would cost more. Mac laptop speakers play little below about 200 Hz, and the bench has no speaker response: half of D4's sweep and most of D2's bed sit below 300 Hz.

### What the realistic floor does now

It changes nothing for the D candidates (standard and realistic-floor columns match). The 12 dB quieter floor sits above 3 kHz, where none of them has any energy. Today's Bluetooth lane gains 33 → 128 from it. The low band sees the full room noise. In pink noise, the noise per hertz near 300 Hz is about 17 times (12 dB) higher than near 5 kHz. D4 gets back 5.4 dB from playing 3.5 times longer, which predicts 33 × 10^(−6.9/20) ≈ 15 for its Bluetooth lane; the bench measured 14.4.

### The noise-weighting smoothing

The bench now smooths the room-noise estimate over a fixed 100 Hz (±50 Hz) instead of ±64 FFT bins. The shipping correlator (`SyncProbeCorrelator.swift:541`) uses ±64 bins and would need the same change for any probe of this length. Measured on the same recordings with ±64 bins: D4 drops from 49 / 14.4 to 36 / 12.5, D2 from 35 / 10.4 to 28 / 9.1 (`run_flat_smooth64bins.log`). The noise level is still calibrated with ±64 bins, as in round 1, so bench units match round 1.

## What the shipping code would need

These apply to any D candidate.
- **Per-lane windows in the analysis.** `MicProbeSession.analyze` searches one region, from `searchFrom` to the end, with both templates. Today that works because the two lanes play different sweeps. With the same sound on both speakers, each template would find both arrivals. The bench searches the Bluetooth lane from 0.3 s before its scheduled start to 0.6 s after its end, and the Mac lane the same way. That is 0.9 s of lags.
- **Keep each window's lag range under 1.1 s for D2.** Its three identical sweeps put a near-copy of the true peak 4.2 dB lower at ±1.1 s. The bench's 0.9 s cannot reach it. D4's overtones put one 19.9 dB lower at ±1.75 s.
- **Reversed order.** Today's `.staggered` shape plays the reference's DOWN sweep first and the Bluetooth UP sweep 2 s later (`AlignmentTickInjector.swift`, `probeStaggerSeconds = 2.0`). These candidates play the Bluetooth speaker first, with a 4.5 s stagger.
- **Smoothing in hertz**, as above.
- **A noise generator defined in ProbeKit** for D1, D2 (its bed) and D3. The phone rebuilds the probe from ProbeKit and must produce the same samples. A change ships as a package tag to both apps.

## Candidates

All lanes 48 kHz, 3.5 s, the same samples on both speakers, scaled to a peak of −15 dBFS (Bluetooth) and −27 dBFS (Mac). "Brown" means power falling 6 dB per octave; "pink" 3 dB per octave. A raised-cosine fade is half a cosine cycle. Synthesis: `research/bench/bench.py`, function `dark_lanes()`.

### Today (reference)
- Mac lane: exponential sweep down 2000 → 500 Hz at 0.0875 full scale (−21 dBFS). Bluetooth lane: up 3200 → 10000 Hz at 0.175 (−15 dBFS). 80 ms fades. 1.0 s, both at once.

### D1 dark whoosh
- Brown noise 150–1500 Hz, cut in the frequency domain with cosine skirts over the inner 10 % of each band edge. Seed 41, numpy's default generator.
- One swell: raised-cosine rise 1.2 s, flat 0.6 s, raised-cosine fall 1.7 s.
- At a −15 dBFS peak its RMS is −30.4 dBFS, 11.8 dB under today's Bluetooth sweep. Noise peaks far above its average, so a peak limit costs it more than it costs a sweep.

### D2 Sonos-like
- Three exponential sweeps down 1200 → 150 Hz, each 1.3 s with a 0.3 s fade in and 0.5 s fade out, starting every 1.1 s, so neighbours overlap by 0.2 s.
- Under them, brown noise 60–250 Hz (seed 42) at 10 dB below the sweeps' RMS, with 0.3 s / 0.5 s fades over the window.
- The matched filter knows the whole sound, bed included. Matching against the sweeps alone (row `D2s` in the CSVs) gives the same confidences in every noise condition and raises the ceiling from 64 to 300.
- The sweeps repeat at 0.9 per second, below the 2–8 Hz range to avoid.

### D3 exhale
- Pink noise 150–1500 Hz (seed 43), passed through a low-pass whose cutoff glides exponentially from 1500 Hz down to 200 Hz across the window. The low-pass has the shape of a 4th-order Butterworth filter and is applied in 85 ms frames at 75 % overlap.
- One swell: raised-cosine rise 0.8 s, fall 2.7 s, no flat part.

### D4 low harmonic glide
- Exponential sweep down 600 → 150 Hz over 3.5 s, with the 2nd and 3rd partials at −12 and −18 dB, each locked to the fundamental's phase. Fades 300 ms in, 600 ms out.
- The 3rd partial starts at 1800 Hz, so nothing reaches 2 kHz.
- False-peak check: inside ±50 ms the tallest wrong peak is the neighbouring cycle 4.1 ms away, 14.0 dB down. A slip onto it would read 4.1 ms wrong, inside the ±6 ms blend bar but using most of it. No trial slipped. The overtones produce peaks at ±1.75 s (2nd) and further, outside the 0.9 s searched.
- 86 % of its energy sits in one hearing band at a time, so it reads close to a single tone despite the partials.

## What the numbers say

1. Every candidate meets the sound rules: 0 % of energy above 2 kHz, sharpness 0.56–0.65 acum against today's 3.19.
2. At real level the Bluetooth window of every candidate is quieter than today: 11–16 sone against 25.1. Annoyance is 11–16 against 39.
3. The two noise candidates (D1, D3) are refused in every trial. Their ceiling is 9–10, below every floor, in any room. Whitening the matched filter's copy of the sound raised it only to 12–13.
4. The two sweep candidates (D2, D4) measured within 0.022 ms whenever they were not refused.
5. Their Bluetooth lanes score 10.4 and 14.4 at standard noise, against today's 33. The rough live figures are ~57 and ~79, against today's ~520.
6. A room 10 dB louder than the bench's standard projects D2 to ~15 and D4 to ~23, under the phone's 25. Today stays above.
7. The realistic floor no longer helps: the low band sees the full room noise. Extra rumble below 300 Hz costs D4 12 % and D2 5 %.
8. The Mac lane at −27 dBFS is never the weaker lane. Raising it to −21 dBFS would double its score and change no pair's figure.
9. D4's nearest wrong peak is 14 dB down at 4.1 ms. D2's is 36 dB down at 13 ms.
10. D2's repeats put a near-copy of the true peak 4 dB lower 1.1 s away. Windows must keep the search under that.
11. Smoothing the noise estimate over 100 Hz instead of ±64 bins raises D4 by 15–37 % per lane. The shipping correlator would need the same change.
12. Every D candidate also needs per-lane windows, the Bluetooth-first order and, for D2's bed, a noise generator in ProbeKit.

## Simplifications

- Everything in the simplifications list of `PROBE-OPTIONS.md` applies: pink-noise room, 6 discrete echoes, perfect mic, no speaker frequency response, one AAC setting, no Bluetooth packet loss.
- The 23 dB gap between lanes at the mic is round 1's figure at equal digital level. Whether the 2026-08-28 measurement already included the Mac lane's −6 dB is not stated in the code comments.
- Psychoacoustic figures take full scale as 94 dB SPL, the same assumption as round 1. The real level at the listener depends on the speaker's volume. Fluctuation strength is taken as zero; D2's 0.9-per-second repeat and the swells would add a little. The listening files have no room, codec or speaker colouring; the placement is a 2 dB level difference between channels.
- The "sounds like" column describes the signal as synthesised. Nobody has listened to it yet.

## Files

- Listening: `today.wav`, `D1.wav` … `D4.wav`, `audition.wav`, `LEVELS.txt`. Render: from `scratchpad/`, `DARK=wav venv/bin/python psy/probe_p5.py`.
- Bench: `bench_flat.csv`, `bench_flat_noise+10.csv`, `bench_step12.csv`, `bench_rumble6.csv`, `bench_flat_smooth64bins.csv`, each with a `run_*.log`. Re-run from `research/bench`: `.venv/bin/python bench.py --staggered --codecs=aac --smooth-hz=100` plus `--noise-boost=10`, `--noise-shape=step12` or `--noise-shape=rumble6`. Type the flags out in full: zsh does not split a flag list stored in one variable.
- Psychoacoustics: `psy_metrics.tsv`. Re-run: `DARK=psy venv/bin/python psy/probe_p5.py`.
- Round-1 copies of the scripts before this round's changes: `bench.py.round1`, `psy/probe_p5.py.round1`.
