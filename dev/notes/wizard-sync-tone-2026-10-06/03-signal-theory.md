# 03 — Signal theory: which sounds can carry the sync measurement

Track: every known test signal for measuring arrival time, judged for our job: two speakers, one mic, up to 25 dB level difference between them, AAC or SBC on the Bluetooth lane, a few ms accuracy.

**How the numbers below were made.** Where no paper answers our exact question, I ran it. `scratchpad/sim/sim.swift` (run with `swiftc -O sim.swift -o sim && ./sim ac|iso|codec|stag`) synthesises each candidate at 48 kHz, 1 s, normalised to the same loudness (same RMS level), and runs the same plain correlation the shipping correlator uses (`SyncProbeCorrelator.correlate`, whitening exponent 0, parabolic peak refinement). The codec test does a real encode and decode with macOS's own AAC encoder (`afconvert`), which is the same vendor's encoder the Mac uses to feed AAC Bluetooth speakers. Ideal-maths isolation figures ignore speaker distortion and room noise; the live capture figure in `SyncProbeCorrelator.swift` (−134 dB) is the real-world reference. Sim results are tagged **[sim]**.

Terms used throughout:
- **Matched filter / correlation peak**: slide the known signal along the recording and multiply; the lag with the biggest sum is the arrival time.
- **Processing gain**: how far above the room noise the correlation peak rises compared to the raw signal, roughly 10·log10(duration × bandwidth). It is set by the signal's energy, not its shape: at equal energy and equal duration every candidate below gets the same detection margin ([Stan, Embrechts, Archambeau, JAES 2002](https://people.montefiore.uliege.be/stan/ArticleJAES.pdf)). Shape decides the next two terms.
- **Peak width**: width of the correlation peak's outline at −3 dB. Roughly 1/bandwidth; sets how finely a noisy peak can be placed.
- **Sidelobe / false peak**: any other bump in the correlation. A false peak within ~1 dB of the true one causes whole-period jumps (the peak lands on the wrong bump).
- **Cross-lane isolation**: how far below lane B's own peak lane A's sound shows up in lane B's matched filter. It must beat the 25 dB level difference with margin, or the loud lane drowns the quiet one.

## Comparison table

Processing gain is for 1 s in our two bands (low lane 500–2000 Hz, B = 1.5 kHz → 31.8 dB; high lane 3.2–10 kHz, B = 6.8 kHz → 38.3 dB). "False peak" is the highest correlation bump more than 3 ms from the true peak. "Fail %" is the share of 60 noisy trials (per-sample SNR −30 dB, white noise, equal-energy signals) that put the peak more than 1 ms wrong; today's sweeps score 0 %.

| Signal | Proc. gain, 1 s | Peak width (−3 dB) [sim] | False peak >3 ms [sim] | Fail % at −30 dB [sim] | How the two lanes separate, and isolation | Codec robustness | Expected pleasantness | Verdict |
|---|---|---|---|---|---|---|---|---|
| Exponential sweep, today's pair | 31.8 / 38.3 dB | 0.71 / 0.17 ms | −21.6 / −41.5 dB | 0 / 0 | Disjoint bands: −174 dB ideal [sim], −134 dB live (`SyncProbeCorrelator.swift` note) | AAC 64 kbps: 0.1 µs shift, 0.04 dB peak loss [sim] | Low lane a falling whistle; high lane 3.2–10 kHz a shrill whistle | Reference to beat |
| Linear sweep | same | 0.67 ms | −24.7 dB | 0 | Same as above | same | Harsher: flat energy per Hz puts more in the treble ([Farina 2000](https://aes2.org/publications/elibrary-page/?id=10211)) | No gain |
| Sweep stepped to notes (semitone / major / pentatonic) | same | 0.67–0.75 ms | −16.0 / −7.7 / −4.5 dB | 0 | Disjoint bands, as today | Same family as sweep | A fast scale run; pentatonic most "musical" | **Viable** for the low lane |
| 4 × 0.25 s sweeps, repeated | same | 1.0 ms | −2.5 dB at 250 ms | 0 | As today | same | Same as sweep, more "busy" | Only if each short sweep is filtered on its own |
| MLS / band-limited pseudo-random noise | same | 0.58 ms | −22.3 dB | 0 | Disjoint bands: same as sweep. Same band, different sequences: −26 dB [sim] → fails at 25 dB | Peak loss < 0.5 dB at 64 kbps; noisy residual (−12 to −23 dB) [sim] | Hiss | Fine in disjoint bands; sounds like static |
| Golay complementary pair | same, but needs 2 plays | ≈ filter's own | none in theory | n/a | Mate pairs cancel cross-talk exactly, only if both plays are identical | Broken by any change between plays (clock drift, codec) | Hiss | Reject |
| Zadoff-Chu / other CAZAC, OFDM multitone | same | ≈ 1/B | none (periodic use) | n/a | Code separation: fails once the weaker arrival is below ≈0.4 of the stronger (≈ −8 dB); OFDM fails at half energy ([Murano et al. 2020](https://arxiv.org/abs/2402.02400)) | Noise-like, as MLS | Hiss or buzz | Reject for 25 dB |
| Schroeder-phase multisine (a chord of many harmonics) | same | 0.58 ms | −0.1 dB at 20 ms (50 Hz grid); −0.8 dB at 100 ms (10 Hz grid) | 70 / 22 | Disjoint bands | Peak loss 0.09 dB, residual −21 dB at 64 kbps [sim] | A steady buzz at the grid pitch | Reject: repeats every period |
| Pink noise burst, smooth envelope | same | 0.62 ms | −19.8 dB | 0 | Disjoint bands | As noise | Soft "shh", can read as static | Viable |
| "Whoosh": noise through a band-pass that glides across the band, smooth fade in/out | same | 0.79 / 0.21 ms | −21.2 / −25.2 dB | 0 / 0 | Disjoint bands: −90 to −208 dB ideal [sim]. Same band, time-offset: fails at 25 dB [sim, §3] | Peak loss 0.33 dB at 64 kbps, 0.07 dB at 128 [sim] | Closest to the Sonos sound | **Strong** for the high lane |
| Chord stab (C-E-G, one hit) | same energy, narrow band | 1.12 ms | −0.4 dB at 7.6 ms | 38 | Disjoint bands | Not tested | Pleasant, "branded" | Reject |
| Plucked arpeggio, consonant notes | same | 0.58 ms | −1.8 dB at 15.2 ms | 3 | Disjoint only if band-limited: harmonics leak at −44 dB unfiltered, −92 dB filtered [sim] | 0.00 dB loss at 64 kbps [sim] | Musical | Marginal |
| Plucked arpeggio where each note bends up a semitone, or whole-tone scale | same | 0.71–0.79 ms | −4.2 / −5.8 dB | 0 | Disjoint bands, band-limited | 0.01 dB loss at 64 kbps [sim] | Musical, slightly "harp-like" | **Viable** for the low lane |
| Bell strikes in 3.2–10 kHz | same | 0.38 ms | −0.7 dB at 20 ms | 23 | Disjoint bands | 0.01 dB loss | Glassy chimes | Reject as built |
| Watermark hidden in music | needs several s | n/a | music-dependent | n/a | Hard: the loud lane's music is the quiet lane's noise | Built to survive codecs | Inaudible-ish | Not a 2 s probe |

## 1. Sweeps: exponential, linear, stepped to notes, short versus long

**Exponential sine sweep** (frequency rises or falls by a fixed ratio per second; [Farina, AES 108th convention 2000](https://aes2.org/publications/elibrary-page/?id=10211)). Equal time per octave, so energy per Hz falls toward the treble like pink noise; this is why it sounds less harsh than a linear sweep ([MathWorks impzest notes](https://www.mathworks.com/help/audio/ref/impzest.html)). Its distortion products land *before* the main peak at fixed lags, which matters for §3 ([Farina 2000](https://aes2.org/publications/elibrary-page/?id=10211); [Dietrich, Masiero, Vorländer 2013](https://masiero.fee.unicamp.br/articles/Journal/Dietrich,%20Masiero,%20Vorl%C3%A4nder_2013_On%20the%20Optimization%20of%20the%20Multiple%20Exponential%20Sweep%20Method.pdf)). Stan et al. found it the best of four methods in quiet rooms and noise-like signals (MLS) slightly better under non-white noise ([JAES 2002](https://people.montefiore.uliege.be/stan/ArticleJAES.pdf)).

**Linear sweep** (frequency rises by a fixed number of Hz per second; the "time-stretched pulse" is a variant). Same peak width as ours [sim: 0.67 vs 0.71 ms], more treble energy. Nothing gained.

**Sweep stepped to notes.** Hold each note, keep the waveform continuous, move to the next. Result [sim]:
- The main peak does not change: width 0.67–0.75 ms in every variant, same 0 % fail rate as the smooth sweep.
- What changes is one false peak at the *common period* of the notes. All notes of an equal-tempered scale nearly share a period (the period of a low bass note under them), so the correlation repeats there: chromatic −16.0 dB at 11.2 ms, major scale −7.7 dB at 10.2 ms, pentatonic −4.5 dB at 15.3 ms.
- Separate beeps (each note faded in and out) are much worse: −0.5 dB at 7.6 ms and 35 % fails. The continuous waveform carries the timing; gaps let each note's period dominate.

So quantising the sweep to a scale costs nothing in peak sharpness and buys a false peak that the more "musical" the scale, the higher it gets. A smooth scale run (chromatic or major) is safe; pentatonic is borderline once room echoes add to that false peak.

**Several short sweeps versus one long.** Total energy decides detection, and averaging repeated sweeps buys the same as one longer one ([Farina 2000](https://aes2.org/publications/elibrary-page/?id=10211)). Measured [sim]: 0.5 s sweep fails 7 % at −30 dB where 1 s fails 0 %; 2 s fails 5 % at −36 dB where 1 s fails 47 %. Each doubling of length is worth 3 dB, which could instead be spent playing 3 dB quieter. Four identical 0.25 s sweeps matched against the whole 1 s reference leave a −2.5 dB false peak at 250 ms [sim]; alternating down/up sweeps push it to −6.1 dB. Filter each short sweep separately and average the results if this shape is used.

## 2. Noise-like and multitone signals

**MLS (maximum length sequence)**: a ±1 pseudo-random sequence whose repeated version has a perfectly flat correlation outside the peak ([Stan et al. 2002](https://people.montefiore.uliege.be/stan/ArticleJAES.pdf)). It is full-band, so for our bands it must be filtered, which turns it into band-limited pseudo-random noise with ordinary noise sidelobes (−22.3 dB beyond 3 ms [sim]). Sounds like hiss.

**Golay complementary pair**: two ±1 sequences whose correlation sidelobes are exact opposites, so playing both one after the other and adding the two results cancels all sidelobes ([Foster, ICASSP 1986](https://typeset.io/authors/s-foster-4lzz4qu6k5); [complementary sequences](https://en.wikipedia.org/wiki/Complementary_sequences)). The cancellation needs the system to be identical across both plays, and the room must fall silent in between ([US 5729612](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/5729612)). Our Bluetooth lane runs on its own clock and through a codec; a drift of 50 parts per million over 1 s moves the second play by 50 µs, a quarter cycle at 5 kHz, which undoes the cancellation in our high band. Reject.

**Zadoff-Chu and other CAZAC sequences** (constant amplitude, zero autocorrelation: complex sequences whose repeated version has a perfect correlation, used in 4G/5G). For sound they must be modulated onto a carrier, and they sound like noise. In a head-to-head test for indoor acoustic positioning, Zadoff-Chu with phase modulation was the most robust to unequal levels, and still only stayed error-free while the weaker beacon arrived at ≥ 0.4 of the stronger's amplitude (≈ −8 dB); the OFDM version (many carriers) failed at half energy ([Murano et al., IEEE Trans. Instrum. Meas. 2020, arXiv 2402.02400](https://arxiv.org/abs/2402.02400)). We need −25 dB. Reject for same-band sharing.

**Schroeder-phase multisine**: many harmonics of one base frequency with phases chosen by Schroeder's formula so the waveform's peaks stay low ([Schroeder, IEEE Trans. Inf. Theory 1970](https://ieeexplore.ieee.org/document/1054411)). The phase formula is quadratic in harmonic number, so each period is in effect a fast sweep; to the ear it is a steady buzz at the base pitch. Being periodic, its correlation repeats at full height every period: −0.1 dB at 20 ms for a 50 Hz grid, −0.8 dB at 100 ms for 10 Hz, 70 % and 22 % fails [sim]. To make it unambiguous the period must exceed the Bluetooth latency uncertainty (100–300 ms → under 3–4 Hz spacing), at which point it is a dense noise-like chord. Reject.

**Pink noise and band-limited noise bursts**: random noise filtered to the band, faded in and out. −19.8 to −22.3 dB false peaks, 0 % fails [sim]. Perceived as "shh". Sonos's Trueplay mixes brown noise, pulses and a sweep ([Sound & Vision](https://www.soundandvision.com/content/sonos-trueplay-bear-facts)); Sonos describes its tone as a periodic chirp, about a third of a second per period for one speaker, shaped to have "just sufficient" high-frequency energy "without being too unpleasant" ([Sonos tech blog, Sheen 2020](https://tech-blog.sonos.com/posts/trueplay-spectral-correction/)).

**Perceptual noise substitution** is an AAC encoder tool, not a test signal: the encoder replaces noise-like bands with a level, and the decoder fills them with fresh random noise ([Hydrogenaudio wiki](https://wiki.hydrogenaudio.org/index.php?title=PNS); [faad2 pns.c](https://sources.debian.org/src/faad2/2.7-8/libfaad/pns.c)). Any noise-like probe is exposed to it; see §5 for the measured effect.

## 3. Playing two speakers at once and telling them apart

| Method | What it is | Isolation | Under 25 dB imbalance |
|---|---|---|---|
| Disjoint bands (ours) | Each lane owns a frequency range with a gap between | −134 dB live; −86 dB ideal even with abutting bands [sim], but real filters and fades need the gap (`SyncProbeCorrelator.swift` note) | Works. Real limit: the loud lane's own distortion. The Mac lane's 2nd harmonic of 1.6–2 kHz lands at 3.2–4 kHz, inside the Bluetooth band. Not measured here. |
| Opposite sweep directions, shared band | Up vs down sweep | −34.9 dB [sim]; −33 dB measured in the code note | Fails (9 dB margin before echoes) |
| Different noise sequences, shared band ("different MLS polynomials") | Independent pseudo-random signals | −26 dB [sim] | Fails |
| Code-division sequences (Zadoff-Chu, Kasami, Gold) | Sequences picked for low cross-correlation | Error-free only to ≈ −8 dB level difference ([Murano et al.](https://arxiv.org/abs/2402.02400)) | Fails |
| Golay mate pairs | Cancel cross-talk across two plays | Exact in theory | Fails with clock drift (§2) |
| Multiple exponential sweep method (MESM) | Same sweep on every speaker, started at staggered times so each speaker's response lands at a different lag of one correlation; distortion products are slotted between them ([Majdak, Balazs, Laback, JAES 2007](https://aes2.org/publications/elibrary-page/?id=14190); generalised by [Dietrich et al. 2013](https://masiero.fee.unicamp.br/articles/Journal/Dietrich,%20Masiero,%20Vorl%C3%A4nder_2013_On%20the%20Optimization%20of%20the%20Multiple%20Exponential%20Sweep%20Method.pdf)) | Sweep's own sidelobes at the other lane's lag: −79 dB at 20 ms, −119 dB at 100 ms (ideal) [sim] | **Works for sweeps, fails for noise.** See below. |
| Time-interleaved short bursts | Lanes take turns | Limited by the loud lane's echo tail when the quiet lane follows it | Works with enough gap; today's `staggered` shape does this with a 2 s gap (`AlignmentTickInjector.swift:384-420`) |
| Sonos stereo pair | A test tone "with a period that's twice as long" ([Sonos tech blog](https://tech-blog.sonos.com/posts/trueplay-spectral-correction/)) | Not published | Unknown. The doubled period suggests the two speakers take turns, but Sonos does not say. |

**Same sound on both lanes, staggered in time [sim].** Room model: decay time 0.5 s, near speaker 10 dB more direct sound than echo, far speaker −3 dB, far speaker 25 dB quieter, mild distortion, Bluetooth latency unknown within ±100 ms.

| Stimulus (both lanes, 500 Hz–10 kHz) | Quiet lane plays before the loud one: 150 / 300 / 600 ms gap | Quiet lane plays after the loud one: 150 / 300 / 600 ms gap |
|---|---|---|
| Exponential sweep | 0 / 0 / 0 % fail; 11 dB margin | 0 / 0 / 0 % fail; margin only 4 dB at 150 ms |
| Whoosh (noise) | 60 / 0 / 0 % fail; 0–5 dB margin | 100 / 100 / 85 % fail |
| Glide arpeggio + whoosh | 100 % fail at every gap | 100 % fail at every gap |

Why: a sweep's correlation away from its peak is deterministic and falls off fast, so the loud lane leaves almost nothing at the quiet lane's lag. A noise burst's correlation away from the peak is random at roughly 1/√(duration × bandwidth) ≈ −37 dB of its peak. Add the 25 dB level difference and take the largest of thousands of lags, and the loud lane's random sidelobes outgrow the quiet peak. Putting the quiet lane *first* helps because "nothing physical arrives before the direct path" (correlator note): the loud lane's echoes all trail it. One catch for sweeps: an exponential sweep's distortion products also land before its peak, at −T·ln(k)/ln(f2/f1) (for 1 s at 500 Hz–10 kHz: 2nd harmonic at −231 ms, 3rd at −367 ms), so the quiet lane must avoid those lags ([Dietrich et al. 2013](https://masiero.fee.unicamp.br/articles/Journal/Dietrich,%20Masiero,%20Vorl%C3%A4nder_2013_On%20the%20Optimization%20of%20the%20Multiple%20Exponential%20Sweep%20Method.pdf)). The correlator already has the hook for a second search that skips the first arrival's lags (`claimed`, `SyncProbeCorrelator.swift`).

What this buys: the Bluetooth speaker no longer has to play only 3.2–10 kHz, the band most likely behind the "high-pitched" complaint. Both speakers can play one identical, full-range sound, one after the other, like an echo.

## 4. Musical and branded sounds

Numbers [sim] for a low-lane version in 500–2000 Hz:

- **Chord stab** (C-E-G struck once and left to ring): peak width 1.12 ms, and a −0.4 dB false peak at 7.6 ms (the period of C3, the note one octave below the chord's root, which all three notes share), 38 % fails. Consonance means the notes share a period, and a shared period is a repeat in the correlation. Reject.
- **Plucked arpeggio, consonant notes** (C-E-G-B rising over two octaves, plucks 110 ms apart): −1.8 dB at 15.2 ms (C2 period), 3 % fails. Unfiltered plucks also put harmonics into the high band: −44 dB leak into the Bluetooth lane's filter, cut to −92 dB once the plucks are band-limited [sim].
- **Same arpeggio, each note bending up one semitone over 30 ms** (a guitar-style bend): −4.2 dB, 0 % fails. **Whole-tone-scale arpeggio** (no shared short period): −5.8 dB, 0 % fails. Both keep a melodic feel and break the shared period.
- **Repeated single note** (8 plucks of 784 Hz): peak width 37 ms, 78 % fails. Anything that stays on one pitch is narrow-band and useless.
- **"Whoosh"** (noise through a band-pass whose centre glides across the band, smooth swell in and out): −21 dB (low) / −25 dB (high), 0 % fails, peak widths same as the sweep's. This is a sweep made of noise, and it measures like one.
- **Bell strikes in 3.2–10 kHz**: −0.7 dB at 20 ms, 23 % fails. Six strikes is too few events, and bell partials repeat.

Peak sharpness follows bandwidth, not musicality: every signal that covers the band, musical or not, has the same ≈0.7 ms (low) or ≈0.2 ms (high) peak. The musical risk is only the false peak at the notes' shared period.

**One musical event split across the two speakers.** "Mac plays the bass, Bluetooth plays the treble answer" is the disjoint-band design described as music, and it works if each part is filtered to its band (−92 dB [sim]). But the Bluetooth band (3.2–10 kHz) sits above every melody instrument: the top note of a piano is 4186 Hz ([piano key frequencies](https://en.wikipedia.org/wiki/Piano_key_frequencies)). Pitched "notes" there are piercing whistles. Treble content there should be air and shimmer: a whoosh, a cymbal-like swell, or the brightness of a pluck (filtered noise), with the melody carried by the Mac's low lane. With the time-staggered layout of §3 the split is no longer needed, but then noise-like parts fail (§3) and the shared sound must be sweep-like (a glissando, a harp run).

## 5. Lossy codecs

- **SBC** (the mandatory Bluetooth codec) splits audio into 4 or 8 sub-bands and quantises each with a bit budget per block (the "bitpool"); 53 is the recommended stereo bitpool ([IETF draft-ietf-avt-rtp-sbc](https://datatracker.ietf.org/doc/html/draft-ietf-avt-rtp-sbc)). It has no noise substitution and no long transform window, so it adds quantisation noise without moving timing. At 48 kHz with 8 sub-bands each sub-band is 3 kHz wide, so the 2.0–3.2 kHz gap straddles the first sub-band edge. Sub-band leakage at that edge is not measured here (no SBC encoder on this Mac).
- **AAC-LC** uses a 2048-sample transform window that switches to 256-sample windows for sharp attacks; quantisation noise can smear up to one window *before* an attack, which is called pre-echo ([AudioLabs Erlangen](https://www.audiolabs-erlangen.de/content/resources/aesCodingTutorial/preecho.html)). The AAC encoder may also use noise substitution (§2).
- **Measured with macOS's AAC encoder [sim]**, round trip at 64 / 128 / 256 kbps, mono:
  - Timing shift between candidates: ≤ 0.3 µs at every bitrate. No candidate's timing is biased by the codec.
  - Peak loss: ≤ 0.09 dB for sweeps, plucks and multisine; 0.33–0.46 dB for high-band noise at 64 kbps, ≤ 0.08 dB at 128 kbps.
  - Error left after decoding: −30 to −36 dB for sweeps and plucks, −12 to −13 dB for high-band noise at 64 kbps (−25 to −27 dB at 128). That error does not follow the probe, so it acts as extra noise 12+ dB below the signal, before the 38 dB of processing gain.
- **Published measurement of arrival-time estimation through A2DP or AAC**: none found. Searched AES, IEEE and arXiv terms; nothing measured matched filtering through a Bluetooth codec.

Implication: codecs do not decide between candidates. Noise-like probes lose a little more, which matters only at the margin.

## 6. Hiding the measurement in music

**Why one mic, two speakers and the same music is hard.** If both speakers play the same signal, the mic hears one sum, and no algorithm can say which part came from which speaker unless the two feeds differ. This is the known "non-uniqueness problem" of stereo echo cancellation ([Sondhi, Morgan, Hall, IEEE SP Letters 1995](https://ccrma.stanford.edu/~jacobliu/myPaperRevised/non_uniqueness_problem_mult.html)). The only cure is to make the two feeds differ ("decorrelate" them), ideally without the listener noticing ([Sondhi, Morgan, Benesty, Hall, ASA 1996 review](https://auditory.org/asamtgs/asa96haw/3aSPa/3aSPa1.html)).

Ways around it, ranked:
1. **Same music, deliberately offset in time.** Equivalent to §3 with music as the sound. Music's correlation repeats at every beat and bass note, so with 25 dB imbalance the loud lane's repeats bury the quiet lane. The shipping drift tracker shows the cost: it needs whitening and a local-background score because "a pop mix's ... bass repeats every 5–25 ms" (`SyncProbeCorrelator.swift`, `whiteningWeights`). Not a 2 s probe.
2. **Same music, each speaker given complementary bands for 2 s** (the Mac gets some bands, the Bluetooth speaker the rest). This is our disjoint-band trick with music as the carrier. In the room the two halves add back to roughly the full spectrum. Isolation is as good as the band filters. Accuracy depends on how much energy the track has in each speaker's bands, which varies by track and second. With a **bundled snippet**, chosen and checked in advance, this collapses into §4.
3. **Stereo left channel on one speaker, right on the other, correlate against each.** Isolation equals how different L and R are. Most mixes put vocals, bass and kick in the centre, identical in both channels: the non-uniqueness case above. Expect single-digit dB, nowhere near 25.
4. **Watermark** (a faint known pattern added to the music). Amazon's over-the-air watermark needs about 0.8–1 s for reliable *detection*, tolerates ±5 ms misalignment and reports no timing precision ([Amazon Science](https://www.amazon.science/blog/audio-watermarking-algorithm-is-first-to-solve-second-screen-problem-in-real-time); [arXiv 1903.08238](https://ar5iv.labs.arxiv.org/html/1903.08238)). For us the quiet lane's watermark would sit ~20 dB under its own music, which itself sits 25 dB under the loud lane's music: about −45 dB, against ~47 dB of gain for 1 s at full band. Several seconds per measurement at best. Related: noise sequences masked under music measured room responses above 4 kHz ([music-masked MLS](https://sonicfield.org/library/music-masked-maximal-length-sequences-for-auditorium-acoustic-measurements)), and music turned into a test signal by adding slight deterministic noise ([Kawahara, arXiv 2309.02767](https://arxiv.org/abs/2309.02767)). Both are single-source methods.

Verdict: the user's own music cannot be the 2 s wizard probe. A bundled musical snippet can, if it is built to the rules in §4 (each part band-limited to its lane, no shared short period in the low part, noise-like or swept content in the high part).

## Shortlist for Audiout

1. **Low lane: a scale run or bending-note arpeggio filtered to 500–2000 Hz; high lane: a whoosh in 3.2–10 kHz.** Same bands, same correlator, same 1 s. Sim: 0 % fails, −4 to −16 dB false peaks low, −25 dB high, AAC-safe. *Biggest risk:* the low part's false peak at the notes' shared period (−4 to −8 dB) plus a strong room echo near that lag could cost a whole period; check against the 2026-08-28 live captures before shipping.
2. **Two whooshes, one per band** (low whoosh 500–2000 Hz, high whoosh 3.2–10 kHz, smooth swell). Measures as well as today's sweeps [sim]. *Biggest risk:* noise may be heard as static, the word already used for a rejected loud sweep (`AlignmentTickInjector.swift`, `stageProbe` note); and the noise must come from a fixed-seed generator in ProbeKit so the phone rebuilds it sample-for-sample.
3. **Today's sweeps, stepped to a chromatic or major scale, at softer edges.** Smallest change: −16 dB (chromatic) false peak, 0 % fails. *Biggest risk:* still a whistle; the high lane is still 3.2–10 kHz, which may be the actual complaint.
4. **One full-range sweep-like sound (a glissando from 500 Hz to 10 kHz) played by both speakers in turn, Bluetooth (quiet) first, ≥150–300 ms apart** (the multiple exponential sweep method). Lets the Bluetooth speaker play the same full, warmer sound as the Mac, like an echo. Sim: 0 % fails, 11 dB margin. *Biggest risk:* only sweep-type sounds survive 25 dB in this layout (noise fails 85–100 %); the gap must cover the unknown Bluetooth latency and keep clear of the sweep's distortion lags (−231 / −367 ms); needs new staging code and a second correlation search.
5. **Any of the above at 2 s and 3 dB quieter.** Doubling length buys 3 dB [sim: 1 s → 2 s cut fails at −36 dB from 47 % to 5 %], spent on a softer level. *Biggest risk:* adds 1 s to the wizard.

Untested and worth a live check before choosing: speaker distortion leaking from the Mac lane into the Bluetooth band, SBC behaviour at its 3 kHz sub-band edge, and every candidate against real room recordings rather than the simulated room.
