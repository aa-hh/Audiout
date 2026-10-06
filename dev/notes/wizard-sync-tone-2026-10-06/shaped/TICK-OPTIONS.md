# By-ear tick options

Three replacement tick pairs plus today's pair, rendered and measured. The owner picks by ear; this file gives the numbers.

**Listen first:** `audition.wav` plays today's pair, then T1, T2, T3, each as 4 aligned beats at 20 BPM, 1.5 s apart. Per pair (`baseline_`, `t1_`, `t2_`, `t3_`):

- `_1_single.wav`: the Mac-side tick, then the Bluetooth-side tick 0.5 s later.
- `_2_aligned.wav`: 6 beats at 20 BPM, both sides together.
- `_3_bt_40ms_late.wav` / `_4_bt_40ms_early.wav`: the same with the Bluetooth side 40 ms late or early.

All files are stereo at 48 kHz: Mac side panned slightly left and 6 dB louder, Bluetooth side slightly right. Every file uses the same playback gain, so levels compare across files. Both sides of every pair are loudness-matched, and each candidate's Mac side is matched to today's Mac-side tick.

Produced by `render.py` (run `venv/bin/python research/shaped/ticks/render.py` from the scratchpad; it reuses `psy/metrics.py` and `psy/tonal.py`). Raw numbers: `metrics.json`.

## Comparison

| | Today | T1 Mallet | T2 Pluck | T3 Wood |
|---|---|---|---|---|
| Notes, Hz (Mac / Bluetooth) | 900+1450 / 1800+2900 | 440 / 660 | 440 / 660 | 1200 / 1800 |
| Interval | octave (each side a 1 : 1.61 two-partial blip) | fifth | fifth | fifth |
| Loudness trim on Bluetooth side (ISO 532-1) | −1.60 dB needed; code applies −1.28 | −0.77 dB | −2.37 dB | −0.12 dB |
| Sharpness, acum (Mac / Bluetooth) | 1.13 / 1.59 | 0.96 / 1.24 | 1.08 / 1.45 | 1.22 / 1.67 |
| Energy in strongest critical band (Mac / Bluetooth) | 81 % / 84 % | 92 % / 94 % | 79 % / 81 % | 99 % / 100 % |
| Measured attack, 10–90 % rise, ms (Mac / Bluetooth) | 0.23 / 0.75 | 1.71 / 1.27 | 1.46 / 0.88 | 0.73 / 0.90 |
| Audible length, ms (to 40 dB below peak) | 28 | 134 / 139 | 141 / 147 | 90 / 91 |
| Spectral overlap between sides | 8.2 % | 1.7 % | 8.9 % | 0.8 % |
| AAC 128 kbps: change in rise time / onset shift (Bluetooth side) | +0.17 ms / −0.17 ms | 0.00 / 0.00 ms | 0.00 / 0.00 ms | +0.02 / 0.00 ms |
| Peak sample, Mac side (today 0.315) | 0.315 | 0.259 (−1.7 dB) | 0.160 (−5.9 dB) | 0.232 (−2.7 dB) |
| Expected sound (from the synthesis, not a listening test) | Short electronic blip, two pitches | Soft wooden bar struck with a mallet, two notes forming a fifth | Plucked string, like a muted guitar or harp, two notes a fifth apart | Hollow knock, close to today's register but longer and pitched |
| Biggest risk | The sound the owner already dislikes | Mac-side onset rests on a 440 Hz note with one partial at 1760 Hz; low notes are timed a few ms later inside the ear | Largest loudness trim, so the most depends on the loudness model being right | Sits in today's register and is nearly a single pitch per side, so it may sound like today's blip made longer |

How each column is measured:

- **Loudness trim**: ISO 532-1 time-varying loudness (Zwicker's method, MoSQITo `loudness_zwtv`), peak over a train of 4 ticks, as `psy/ticks.py` does. The trim is the gain on the Bluetooth side that makes its peak loudness equal the Mac side's.
- **Sharpness**: DIN 45692 (MoSQITo `sharpness_din_st`) over the first 150 ms. Above 1.75 acum the standard annoyance model starts to penalise.
- **Energy in strongest critical band**: share of energy inside the single loudest critical band (one band of the ear's frequency analysis), in 20 ms windows (`psy/tonal.py`). 100 % means a lone sine. It measures how pure the sound is per window and does not separate an instrument note from a test tone.
- **Measured attack**: 10 % to 90 % rise of the signal's envelope (magnitude of the analytic signal, smoothed over 0.5 ms). Both sides of every pair use the same attack ramp; the measured values differ by up to 0.6 ms because their partials interfere differently in the first millisecond. Today's pair shows the same 0.5 ms spread.
- **Spectral overlap**: split each side's spectrum into critical bands, normalise each to 100 %, and sum the smaller of the two shares in every band. 0 % means the two sides share no band, 100 % means identical spectra.
- **AAC round trip**: six copies of the Bluetooth-side tick at different positions against the codec's frame grid, `afconvert -f m4af -d aac -b 128000`, decoded back to 48 kHz WAV. afconvert removes the codec's start-up delay itself (measured net delay 0 ms). Pre-echo (codec noise smeared ahead of the onset) peaked at −45 dB for today's tick and −52 to −62 dB for the candidates.

### Interval choice (fifth over octave)

Both intervals were rendered for T1 and T2 (`metrics.json`, keys `T1 octave`, `T2 octave`).

- T1: the octave needed a −2.21 dB trim against −0.77 dB for the fifth, and its Bluetooth side is sharper (1.53 against 1.24 acum). Spectral overlap is under 2 % either way. Fifth chosen: smaller loudness correction, so less rides on the loudness model.
- T2: the octave raises overlap from 8.9 % to 15.1 %, because every harmonic of 880 Hz lands on an even harmonic of 440 Hz. Its Bluetooth side is also sharper (1.73 acum, at the penalty line). Trims are similar (−2.23 against −2.37 dB). Fifth chosen.

## T1 Mallet

A marimba-like strike: a fundamental plus the partial a marimba bar adds at 4 times the fundamental, and a weak one at 10 times. Real marimba bars put these near 3.9 and 9.2; the exact 4 and 10 here keep the sound slightly more bell-like.

| Partial | Mac Hz | Bluetooth Hz | Level | Decay time constant |
|---|---|---|---|---|
| fundamental | 440 | 660 | 1.0 (0 dB) | 30 ms |
| 4 × | 1760 | 2640 | 0.5 (−6 dB) | 8 ms |
| 10 × | 4400 | 6600 | 0.06 (−24 dB) | 3 ms |

- All partials start in sine phase at the onset.
- Attack: 2 ms raised-cosine ramp (a half cosine from 0 to 1), the same on both sides.
- Buffer: 200 ms. Audible length: about 135 ms.
- Level: normalise the sum to peak 1, then scale to peak 0.259 on the Mac side and 0.237 on the Bluetooth side.
- 5 % of the energy sits in 1.5–4 kHz on each side, all of it in the 4 × partial, which is gone within about 35 ms.

## T2 Pluck

A plucked string made as a sum of harmonics, each decaying faster the higher it is. This is the shape a Karplus-Strong string (a plucked string simulated with a looping delay line and a smoothing filter) produces. Here it is written out per harmonic, so both sides get the same decay pattern in seconds; a real Karplus-Strong loop would make the higher note die sooner.

| Harmonic k | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 |
|---|---|---|---|---|---|---|---|---|
| Level 1/k, dB | 0 | −6.0 | −9.5 | −12.0 | −14.0 | −15.6 | −16.9 | −18.1 |
| Decay time constant 35 ms / k^0.7 | 35.0 | 21.5 | 16.2 | 13.3 | 11.3 | 10.0 | 9.0 | 8.2 |

- Mac note 440 Hz (harmonics to 3520 Hz). Bluetooth note 660 Hz (harmonics to 5280 Hz).
- All harmonics start in sine phase.
- Attack: 2 ms raised-cosine ramp, both sides.
- Buffer: 200 ms. Audible length: about 141–147 ms.
- Level: normalise to peak 1, then peak 0.160 on the Mac side and 0.122 on the Bluetooth side. It needs the least peak level of the three for the same loudness, because its energy is spread over eight harmonics.
- Energy in 1.5–4 kHz: 4 % (Mac), 7 % (Bluetooth), carried by harmonics 4–8.

## T3 Wood

A woodblock-like knock: one resonant pitch with a weak higher mode, plus a short burst of noise at the onset for the "knock".

| Part | Mac | Bluetooth | Level | Decay time constant |
|---|---|---|---|---|
| main resonance | 1200 Hz | 1800 Hz | 1.0 | 20 ms |
| upper mode, 2.3 × | 2760 Hz | 4140 Hz | 0.18 (−15 dB) | 6 ms |
| noise burst | white noise band-passed from note/1.6 to note × 1.6 | same, around 1800 Hz | peak 12 dB under the tone's peak | 2 ms |

- Noise: the same noise sample on both sides (seed 7), filtered with a 2nd-order Butterworth band-pass run forwards and backwards, so it adds no delay. That works because the tick is rendered once into a table, as today.
- Attack: 1 ms raised-cosine ramp on the tone, 0.5 ms on the noise, both sides.
- Buffer: 200 ms. Audible length: about 90 ms.
- Level: peak 0.232 on the Mac side, 0.229 on the Bluetooth side.
- The two sides need only a −0.12 dB loudness trim, because the pair sits where the ear's sensitivity curve is nearly flat (1.2–1.8 kHz).

## Today's pair (baseline)

Rendered exactly as `renderTick` in `AlignmentTickInjector.swift`: 0.7 sin(f1) + 0.3 sin(f2), decay time constant 6 ms, 8-sample linear attack at 44.1 kHz (0.18 ms), cut at 30 ms, amplitude 0.35. The Bluetooth side is scaled by the code's A-weighting factor 0.863 (−1.28 dB). Measured under ISO 532-1, an equal-loudness match needs −1.60 dB, so the Bluetooth side plays 0.32 dB louder than the Mac side. That is the side the code comment predicts would be heard early.

## What the numbers say

1. Every candidate is less sharp than today on the Bluetooth side, except T3 (1.67 against 1.59 acum). All stay under the 1.75 acum penalty point.
2. T1 is the least sharp pair (0.96 / 1.24 acum).
3. T3 needs almost no loudness trim (−0.12 dB). T1 needs −0.77 dB. T2 needs −2.37 dB, more than today's −1.60 dB.
4. T1 and T3 share almost no spectrum between sides (under 2 %). T2 shares about as much as today (9 % against 8 %).
5. T1 and T3 are close to one pitch per window (92–100 % in one critical band). T2 has a richer spectrum, at today's level (79–81 %).
6. Attack goes from today's 0.2–0.75 ms to 0.7–1.7 ms, inside the research's 1–3 ms target and well under the 10 ms limit where order judgement starts to suffer.
7. Audible length goes from 28 ms to 90 ms (T3) and 134–147 ms (T1, T2), all under the 150 ms ceiling.
8. AAC at 128 kbps barely touches any of them. Only today's tick moved, by 0.17 ms. SBC was not tested here.
9. T1 and T2 move the Mac-side pitch to 440 Hz, an octave and a bit below today's 900 Hz. T3 stays in today's register.
10. At equal loudness, every candidate peaks lower than today: T1 by 1.7 dB, T3 by 2.7 dB, T2 by 5.9 dB. That leaves more headroom before the mix clips.
