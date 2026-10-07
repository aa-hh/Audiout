# 02 — Why the wizard sounds are unpleasant, and how to make a measurement signal pleasant

Track: psychoacoustics. Researcher 2 of 4. Date 2026-10-06.

Short answer:

- The **mic probe's Bluetooth lane (3.2–10 kHz up sweep)** is the main offender. Every instant of it is a single pure tone, it spends its first 0.39 s in the ear's most sensitive region (3.2–5 kHz) and the rest above 5 kHz, and its sharpness is 4.4 acum. That is 2.5 times the 1.75 acum level where the Zwicker/Fastl annoyance model starts adding a penalty. A rising pitch over a wide range is also the textbook recipe for an urgent alarm.
- The **Mac lane (2 kHz → 500 Hz down sweep)** is mild by every metric: 1.1 acum, no roughness. Its problem is that it is a bare sine glide played on top of the shrill one.
- The **by-ear ticks** are already short, mid-band and loudness-matched. They sound "beepy" because they are two pure sine partials with no harmonic structure. The temporal-order literature allows them to become a plucked or mallet sound (attack under about 10 ms, decay a few tens of ms) at no measurable cost to ordering, provided both sides keep the same envelope.
- The rules that follow: keep the energy below about 4–5 kHz, tilt the spectrum pink (energy falling with frequency), and make it either harmonic (musical) or noise-like, never a lone sine. Give the probe slow edges and the ticks fast edges. Make the two lanes share one envelope and, for the ticks, a consonant pitch relation, so they group as one sound when aligned.

All numbers marked "computed" come from the script in `scratchpad/psy/` (MoSQITo 1.2.1, an open-source Python implementation of the standard metrics: <https://mosqito.readthedocs.io/>). The script synthesises the signals exactly as `SyncProbeCorrelator.swift` (lines 78–110) and `AlignmentTickInjector.swift` (`renderTick`, lines 305–321) do. **Absolute level is assumed**: digital full scale = 94 dB SPL, which puts the current probe at about 76 dB SPL. Sharpness and the annoyance ratios barely depend on that choice; absolute loudness does.

---

## 1. The metrics that predict annoyance

Each metric below has a standard reference sound defined as exactly 1 unit, so values compare across sounds.

### Loudness (ISO 532-1, Zwicker method), unit: sone

- **What it is**: perceived loudness. 1 sone = a 1 kHz tone at 40 dB SPL. Each +10 dB (for a tone, roughly) doubles the sone value.
- **Shape**: split the sound into 24 critical bands (the ear's frequency-resolution bands; the band number is called "Bark", 0–24). Convert each band's level into a "specific loudness" N′(z) with a compressive power law, roughly N′ ∝ E^0.23 (E = band energy), plus spreading towards higher bands to model masking. Total loudness is N = ∫₀²⁴ N′(z) dz. ISO 532-1 has one method for steady sounds and one for time-varying sounds. Reports usually quote N5, the loudness exceeded 5 % of the time.
- **Why it matters here**: a sound whose energy spreads across many critical bands at once (noise) is much louder than a sound with the same SPL in one band (a sweep). Computed: at 76 dB SPL, the 300–4000 Hz pink noise burst is 39 sone, while the 500–4000 Hz sweep is 17.5 sone. **At equal loudness, noise carries about 8 dB less energy than a sweep.** For a matched-filter measurement that directly costs about 8 dB of signal-to-noise ratio (see §5).
- Sources: ISO 532-1:2017 <https://www.iso.org/standard/63077.html>; summary of the method <https://metricgate.com/calculator/zwicker-loudness-sones-phons>.

### Equal-loudness contours and the 2–5 kHz ear-canal peak

- ISO 226:2023 gives the levels at which pure tones of different frequencies sound equally loud: <https://www.iso.org/standard/83117.html>. Hearing is most sensitive around 3–4 kHz.
- The cause is the open ear canal, which acts as a quarter-wave resonator. It adds about 15–25 dB of gain at the eardrum, peaking near 2.7 kHz, with a second peak of about 10 dB near 5 kHz from the bowl of the outer ear (Shaw 1974, summarised in <https://www.orl.uzh.ch/memro/program/3.9_Goode.pdf> and <https://scielo.br/j/codas/a/ft4Sq3xZKPXDRd7CLvvJ8KL/?lang=en>).
- In an fMRI study where 13 listeners rated a range of everyday sounds for unpleasantness (Kumar et al. 2012, J. Neurosci.), the acoustic feature that predicted unpleasantness was energy in roughly **2–5 kHz** (knife on bottle, chalk on board), and the amygdala's response tracked the ratings: <https://www.ncl.ac.uk/press/articles/archive/2012/10/nastynoiseswhydowerecoilatunpleasantsounds.html>, <https://sciencedaily.com/releases/2012/10/121012112424.htm>.

### Sharpness (DIN 45692, after Zwicker / von Bismarck), unit: acum

- **What it is**: how much of the loudness sits at high frequencies. It is the main predictor of "shrill" or "piercing". 1 acum = narrow-band noise one critical band wide at 1 kHz, 60 dB.
- **Formula**: S = 0.11 · ∫₀²⁴ N′(z)·g(z)·z dz / N acum. The weighting is g(z) = 1 up to 15.8 Bark (about 3 kHz) and g(z) = 0.066·e^(0.171·z) above it, so content above about 3 kHz is weighted progressively harder (at 20 Bark, about 6.4 kHz, g ≈ 2.0; at 22 Bark, about 9.5 kHz, g ≈ 2.8). Sources: <https://metricgate.com/docs/sharpness-acum-din45692/>, <https://community.sw.siemens.com/articles/en_US/Knowledge/Sharpness-in-Simcenter-Testlab>, <https://mosqito.readthedocs.io/en/latest/source/reference/mosqito.sq_metrics.sharpness.sharpness_din.sharpness_din_st.html>.
- Typical anchors: broadband (white-ish) noise is about 1.75 acum. That is why the annoyance model below adds no sharpness penalty under 1.75.
- Fastl and Zwicker, ch. 9 "Sharpness and Sensory Pleasantness": <https://link.springer.com/chapter/10.1007/978-3-540-68888-4_9>.

### Roughness, unit: asper

- **What it is**: the buzzy, grating quality caused by amplitude or frequency fluctuation at 15–300 Hz, strongest at about 70 Hz. 1 asper = a 1 kHz, 60 dB tone, 100 % amplitude-modulated at 70 Hz.
- **Shape**: R ≈ 0.3 · (f_mod / 1 kHz) · ∫ ΔL(z) dz asper, where ΔL(z) is the modulation depth (in dB) of the excitation in each critical band. Modern versions: Daniel & Weber 1997 (in MoSQITo), and ECMA-418-2 (the Sottek hearing model).
- In practice for us, two simultaneous components produce roughness only when they fall inside one critical band and beat at 15–300 Hz.
- Sources: <https://metricgate.com/docs/roughness-asper/>, <https://community.sw.siemens.com/articles/en_US/Knowledge/sound-modulation-metrics-fluctuation-strength-and-roughness>.

### Fluctuation strength, unit: vacil

- **What it is**: slow loudness wobble, from modulation below about 20 Hz, strongest at **4 Hz**. 1 vacil = a 1 kHz, 60 dB tone, 100 % amplitude-modulated at 4 Hz.
- **Shape**: F ≈ 0.008 · ∫ ΔL(z) dz / ((f_mod/4 Hz) + (4 Hz/f_mod)) vacil. It is a band-pass in modulation rate, peaking at 4 Hz.
- Relevance: a metronome or pulse train with repetition near 2–8 Hz scores high. The by-ear ticks at 72 BPM (1.2 Hz) and 20 BPM (0.33 Hz) are well below the peak. A single 1 s probe swell is about 0.5–1 Hz, so its fluctuation strength is negligible.
- Source: <https://metricgate.com/docs/fluctuation-strength-vacil/>.

### Tonality: Aures, DIN 45681, ECMA-74, ECMA-418-2

- **Aures tonality** (unit: tonality unit, tu): the loudness of the tonal components as a share of total loudness, times a level weighting. Shape: T = c · w_T^0.29 · w_Gr^0.79, where w_T weights each tone by its bandwidth, frequency and level above the masking noise, and w_Gr = 1 − (noise loudness / total loudness). A lone pure tone gives w_Gr = 1, the maximum. Sources: <https://metricgate.com/docs/tonality-aures/>, <https://devdocs.ansys.com/dpf/dpf-framework/operator-specifications/sound/compute_tonality_aures>.
- **DIN 45681** and **ECMA-74 tone-to-noise ratio / prominence ratio**: penalty schemes for machinery noise. They measure a tone's level against the noise in its own critical band and add a decibel penalty (DIN 45681: up to 6 dB) when the tone is audible above the masking threshold. Sources: <https://www.ioa.org.uk/system/files/proceedings/t_beckenbauer_i_stemplinger_a_selter_basics_and_use_of_din_45681_detection_of_tonal_components_and_determi.pdf>, <https://cdn.head-acoustics.com/fileadmin/data/global/Abstracts/Abstract-ASA-Acoustics-2017-Status-quo-of-standardizing-tonality-calculation-of-stationary-and-time-varying-sounds.pdf>.
- **ECMA-418-2** (Sottek hearing model, 4th edition June 2025): a time-varying tonality that separates tonal from noise parts per auditory band by autocorrelation. 1 tu_HMS = a 1 kHz, 40 dB SPL sine. The same standard also defines loudness and roughness. Spec: <https://ecma-international.org/wp-content/uploads/ECMA-418-2_4th_edition_june_2025.pdf>. Verified open implementation (SQAT): <https://salford-repository.worktribe.com/output/4237250/verified-implementations-of-the-sottek-psychoacoustic-hearing-model-standardised-sound-quality-metrics-ecma-418-2-loudness-roughness-and-tonality>.
- **Direction of effect.** In noise-annoyance standards (DIN 45681, ECMA-74) a tone in machinery noise is a penalty. In Aures's *pleasantness* model, tonality *raises* pleasantness. Both hold. A pure tone sticking out of a noise floor sounds like a fault; harmonic musical tones are tonal and pleasant. McDermott, Lehr & Oxenham (2010, 250+ listeners) found that preference for **harmonic spectra** is what predicts liking consonant chords: <https://mcdermottlab.mit.edu/papers/McDermott_Lehr_Oxenham_2010_consonance_individual_differences.pdf>. The rule is therefore not "no tones". It is: avoid a single bare sine; use harmonic tones or noise.

### Combined models

- **Zwicker & Fastl psychoacoustic annoyance (PA)**: PA = N5 · (1 + √(w_S² + w_FR²)), with
  - w_S = (S − 1.75) · 0.25 · log₁₀(N5 + 10) when S > 1.75 acum, else 0;
  - w_FR = (2.18 / N5^0.4) · (0.4·F + 0.6·R).
  - Sources: <https://metricgate.com/docs/psychoacoustic-annoyance/>, <https://www.johndcook.com/blog/2016/07/28/quantifying-how-annoying-a-sound-is/>.
- **Aures sensory pleasantness** (Aures 1985, Acustica 59(2):130–141; as given in Fastl & Zwicker, Psychoacoustics, 3rd ed., ch. 16): P/P₀ = e^(−0.7·R/R₀) · e^(−1.08·S/S₀) · (1.24 − e^(−2.43·T/T₀)) · e^(−(0.023·N/N₀)²). Some secondary sources print the loudness term without the square. Sharpness has the steepest exponent, so it dominates. Source for the coefficients: <https://link.springer.com/chapter/10.1007/978-3-662-09562-1_9>. Sensory unpleasantness of tones of 1 kHz and above rises faster with level than loudness does (Acoust. Sci. Tech. 34(1)): <https://www.jstage.jst.go.jp/article/ast/34/1/34_E1217/_article>.

---

## 2. The four current sounds against these metrics

Computed values. Probe signals are at their real code amplitudes (0.175 full scale; Mac lane × 0.5 when both play). Assumed calibration: full scale = 94 dB SPL.

| Sound | SPL | Loudness N5 | Sharpness (loudness-weighted mean; 10th–90th percentile) | Roughness | Energy in one critical band per 20 ms (100 % = pure tone) |
|---|---|---|---|---|---|
| Up sweep 3.2 → 10 kHz, 1 s (Bluetooth lane) | 75.4 dB | 17.7 sone | **4.40 acum** (3.20–6.39) | 0.04 asper | **100 %** |
| Down sweep 2 kHz → 500 Hz, 1 s (Mac lane) | 75.4 dB | 13.3 sone | 1.08 acum (0.65–1.53) | 0.07 | 98.5 % |
| Both as played (Mac × 0.5) | 76.3 dB | 25.1 sone | **3.19 acum** | 0.02 | 80 % |
| Bright tick 1800 + 2900 Hz, 30 ms | 80 dB peak | — | 1.61 acum | 0 | 84 % |
| Low tick 900 + 1450 Hz, 30 ms | 81 dB peak | — | 1.19 acum | 0 | 81 % |

Psychoacoustic annoyance for the probe as played: **PA = 39.1, of which 56 % is the sharpness penalty** (PA/N5 = 1.56). Sharpness accounts for almost all of it, and roughness for almost none.

### Up sweep 3.2 → 10 kHz (Bluetooth lane): the main problem

- **Sharpness.** It starts at 3.2 kHz, already at the 15.8 Bark point where the DIN 45692 weighting starts to climb. Instantaneous frequency is f(t) = 3200 · 3.125^t. It is inside the 3.2–5 kHz ear-canal and equal-loudness peak for the first 0.39 s, then spends 0.61 s at 5–10 kHz where g(z) is 1.6–2.8. Computed sharpness rises from 3.4 acum (t = 0.15 s) to 6.3 acum (t = 0.9 s). For scale, the annoyance model treats anything over 1.75 acum as penalised; this sound averages 4.4.
- **Tonality.** It is a single sinusoid at every instant (100 % of its energy in one critical band). That is the maximum possible on the "lone tone" axis, with no harmonics to make it musical. Brewster's earcon guidelines say outright that sine waves are ineffective and that earcons should use timbres with multiple harmonics: <https://www.dcs.gla.ac.uk/~stephen/earcon_guidelines.shtml>.
- **Range.** Brewster's guidelines cap UI sound pitch at **5 kHz**. Most of this sweep is above that.
- **Meaning.** In the auditory-warning literature, perceived urgency rises with higher pitch, rising pitch contour, a wider pitch range and faster rate (Edworthy, Loxley & Dennis 1991, Human Factors 33(2):205–231, <https://journals.sagepub.com/doi/abs/10.1177/154193129103501034>). A 1 s rise from 3.2 to 10 kHz has all four features. It reads as an alarm or a test tone, not a product sound.
- **Level dependence.** Unpleasantness of tones above 1 kHz grows faster with level than loudness does (jstage link above). Because the probe rides the user's own volume, a user with the volume up hears the worst case.

### Down sweep 2 kHz → 500 Hz (Mac lane): acceptable on its own

- Sharpness is 1.08 acum, under the 1.75 penalty point. It sits mostly below the ear-canal peak, and roughness is negligible.
- It is still a bare sine (98.5 % tonal by the measure above), so it sounds like a test generator.
- A falling glide also carries a "down/ending" association in earcon design (<https://www.dcs.gla.ac.uk/~stephen/papers/CHI93.PDF>). That is mild, and the owner may not care.
- Its main harm is context: played at the same time as the up sweep, the pair forms two glides diverging in opposite directions. Two simultaneous sines a factor of 1.6–20 apart, moving opposite ways, cannot group as one sound. By Bregman's grouping cues (common onset, harmonicity, common fate, meaning parts that change together), shared frequency movement is the strongest binder, and these two have opposite movement. They are heard as two competing tones.
- **No roughness from the pair.** The two sweeps are always more than 1.2 kHz apart, which is far outside one critical band, so they do not beat (computed roughness 0.02 asper).

### Bright tick (1800 + 2900 Hz) and low tick (900 + 1450 Hz)

- Both are short (time constant 6 ms), sit below the 3 kHz sharpness turn-up, and score 1.2–1.6 acum. By the metrics they are not harsh.
- The partial ratio 2900/1800 = 1450/900 = 1.61 is not a harmonic ratio (closest simple ratio 8:5, a minor sixth, 1.60). Two sine partials at an inharmonic-ish ratio, with no other overtones, give a thin "electronic beep" or blip timbre rather than an instrument. That is the main reason they sound cheap.
- Loudness match. The code applies a −1.28 dB trim to the bright tick, derived from A-weighting (`brightLoudnessScale`, `AlignmentTickInjector.swift:151`). Computed under ISO 532-1 time-varying loudness on a 4-tick train: the bright tick is 10.27 sone and the low tick 9.23 sone at equal amplitude, so an equal-loudness trim would be **−1.64 dB**. The code's −1.28 dB leaves a 0.36 dB residual. That is small, but it points the same way the code comment predicts.
- **Stale citation in `dev/notes/wizard-tick-stimulus-brief.md`.** It attributes "no difference in TOJ thresholds across frequency, spectrum and location" to "Szymaszek et al.". The paper at that link is **Fostick, Lifshitz-Ben-Basat & Babkoff (2019), Psychological Research 83:968–976** (identified via <https://pmc.ncbi.nlm.nih.gov/articles/PMC9269437/>; the Springer page <https://link.springer.com/article/10.1007/s00426-017-0915-1> did not load from here). The finding stands; the author name in the brief is wrong.

---

## 3. Literature on pleasant or musical test signals

### Acoustics: measuring with music or music-like signals

- **Serafini & Li (2011), "Impulse response measurement with chirp-lets and masked noise stimuli"**, Proc. Institute of Acoustics 33(2), Auditorium Acoustics 2011 (Salford). Room impulse responses were measured in occupied halls with:
  - short linear sweeps, each spanning one equal-tempered semitone, up to 4 kHz, so the stimulus is heard as a sequence of musical notes;
  - above 4 kHz, maximum-length-sequence noise (a pseudo-random binary noise used for impulse response measurement) hidden under recorded, compressed music.
  - Reported: a 50 dB noise-free decay range, "perceived as music".
  - Abstract: <https://www.academia.edu/7478497/IMPULSE_RESPONSE_MEASUREMENT_WITH_CHIRP_LETS_AND_MASKED_NOISE_STIMULI>.
  - This is the closest prior art to "make the sweep sound like notes".
- **Swept sines inserted into music for public-space measurement** (ResearchGate record <https://www.researchgate.net/publication/236663701_Impulse_response_measurement_in_public_space_using_musical_signal_including_swept-sine_signals>). It is motivated by the stated fact that a plain swept sine "sounds very peculiar to listeners".
- **AnyRIR (2025)**, Aalto / York / Erlangen: estimates room impulse responses from ordinary music as the excitation, using a robust ℓ1 regression in the time–frequency domain, and tested under codec mismatch. <https://arxiv.org/abs/2510.17788>. This is the "no test signal at all" end of the spectrum. Per CONTEXT.md, music-based tracking (the passive drift tracker) is out of scope for the wizard, but the paper shows lossy-codec playback does not stop it.
- **Psychoacoustically masked pseudo-noise under music** (patent US 7,881,485, "determining an impulse response and … presenting an audio piece"): the test signal is spectrally shaped to stay below the masking threshold of the music being played. <https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/7881485>.
- **Sweeps shaped to the noise spectrum.** Müller & Massarani, "Transfer function measurement with sweeps" (JAES 2001): a sweep's magnitude spectrum can be shaped freely (for example to the background-noise spectrum) for a higher signal-to-noise ratio. This gives the freedom to tilt a sweep pink or to restrict its band. <https://www.melaudia.net/zdoc/comparisonMesure.PDF>.
- Note: an exponential (Farina) sweep already has a pink spectrum (equal energy per octave), because it spends equal time in each octave: <https://auditory.org/postings/2009/207.html>. The current sweeps are therefore already pink-tilted within their bands. Their harshness comes from **where** the band sits, not from the tilt.

### Noise colour and pleasantness

- In ratings of white, pink and brown noise, white noise was rated most "uneasy" and brown noise most "sublime", with pink in between (Frontiers in Neuroscience 2025): <https://www.frontiersin.org/journals/neuroscience/articles/10.3389/fnins.2025.1488682/epub>. This follows directly from sharpness: computed here, pink noise band-limited to 300–4000 Hz is **1.43 acum**, and 500–8000 Hz is **2.15 acum**.
- In Kumar et al. 2012 (above), the most pleasant sounds were natural broadband ones (bubbling water). Band-passed noise with slow envelopes is how sound designers synthesise wind, breath and surf. A whoosh reads as one of those because it has no pitch (≈20 % of energy in any one critical band, versus 100 % for a sweep) and no sharp edges.
- **Sonos.** Classic Trueplay plays a repetitive pattern of tones and sweeps that reviewers likened to vintage Doctor Who effects (<https://www.whathifi.com/advice/sonos-trueplay-what-it-how-can-you-use-it>), so the owner's "whoosh" is likely the newer quick-tune sound. I found no published spec for its spectrum; the competitor track should cover it.

### UI sound and sonic-branding guidance

- **Brewster, Wright & Edwards earcon guidelines** (Glasgow; <https://www.dcs.gla.ac.uk/~stephen/earcon_guidelines.shtml>):
  - Use musical-instrument timbres with multiple harmonics; plain sines and squares are ineffective.
  - Keep pitch between **125–150 Hz and 5 kHz**.
  - Notes no shorter than 82.5 ms, except one- or two-note earcons, which may go down to **30 ms**.
  - Level **10–20 dB above the background** and no more.
  - Accent the first note.
- **Practitioner guidance** (<https://medium.com/@fivepointseven/how-to-design-a-pleasant-alert-sound-2ddf7a9724de>, <https://withfeeling.com/the-sonic-glossary/ui-sounds/>):
  - Laptop and phone speakers reproduce little below about 300 Hz.
  - Cut harsh content around 3–6 kHz.
  - Notification sounds of about 200–600 ms with short decays.
  - Sharp attacks and long tails are what wear on people over many repeats.
  - These are practitioner sources, not studies; they agree with the sharpness and Kumar results.
- **Consonance.** Harmonic spectra and simple-ratio intervals (octave 2:1, fifth 3:2, major third 5:4, and the pentatonic set built from them) are preferred, and that preference grows with musical training (McDermott et al. 2010, above).
- **Bells and mallets.** Their slightly inharmonic partials decay at different rates, with high modes dying fast. That is why a marimba or bell sounds bright at the strike and mellow after it (<https://www.bells.org/node/254>). Fundamental frequency is the strongest driver of perceived brightness, tension and roughness, ahead of the type of inharmonicity (Zacharakis & Pastiadis 2021, Acta Acustica, <https://acta-acustica.edpsciences.org/10.1051/aacus/2021007>).
- **Aures model applied.**
  - Sharpness term e^(−1.08·S) alone: the current probe pair (S = 3.19) scores 0.032. A pink noise at 300–4000 Hz (S = 1.43) scores 0.21. A sweep pair moved down to 300 Hz–4.5 kHz (S = 1.78) scores 0.15.
  - Tonality term (1.24 − e^(−2.43·T)): about 0.24 for noise (T ≈ 0) and about 1.15 for a tone (T ≈ 1).
  - Net: by Aures, a **low-sharpness tonal sound beats a low-sharpness noise** by about 4–5 times on pleasantness. The model was fitted on steady sounds, and tonality of a moving sweep is not standardised, so take this as direction, not a number.
  - This is the psychoacoustic case for "musical" over "whoosh" when both are equally soft and dull, as long as "tonal" means harmonic and musical rather than a lone sine.

---

## 4. Constraints from the by-ear task (temporal order judgement)

Temporal order judgement means deciding which of two sounds came first. The wizard asks exactly that, then converts the answers into milliseconds.

### How small an asynchrony people can order

| Study | Stimuli | Threshold (75 % correct unless stated) |
|---|---|---|
| Hirsh 1959 (practised listeners) | tone pairs incl. 440 Hz vs 4 kHz, 500 ms, varied onsets | **≈17–20 ms**; much more without practice. <https://hearinghealthmatters.org/pathways-society/2023/temporal-ordering-hirsh-revisited> |
| Fostick et al. 2019, 192 listeners | two-tone sequences varying frequency, spectrum width, duration, location | no difference across frequency, spectrum, location; **longer duration made it worse**. <https://pmc.ncbi.nlm.nih.gov/articles/PMC9269437/> (review), original in Psychological Research 83:968–976 |
| Spectral vs spatial study, ages 20–35 (PMC9269437) | 15 ms tones, **1 kHz vs 1.8 kHz** (spectral) or 1 kHz to each ear (spatial), 65 dB | spectral 60 ms (constant stimuli) / 82 ms (adaptive); spatial 64 / 63 ms. With the better method, **a 1 : 1.8 pitch difference ordered as well as identical sounds in different places** |
| Elderly listeners, Frontiers 2018 | 1 ms clicks per ear vs 400 Hz / 3 kHz tones | spatial 83–88 ms, spectral 91–114 ms. A big pitch gap was worse. <https://www.frontiersin.org/journals/psychology/articles/10.3389/fpsyg.2018.02557/full> |
| Zera & Green 1993 | onset asynchrony of one component in a harmonic complex | **detecting** (not ordering) asynchrony down to about **1 ms**. <https://auditory.org/asamtgs/asa93ott/4pPP/4pPP5.html> |

**Detecting** that two onsets differ (about 1–5 ms, and the wizard's "both at once" fusion window of 6 ms) is a different and easier task than **naming the order** (about 20 ms practised, 60+ ms untrained). The wizard's estimator works on many noisy answers, so it does not need every single judgement to be right. Even so, every stimulus property that widens these numbers costs answers.

### Are plucked, mallet or woodblock sounds as good as clicks?

- **Rise time.** Pastore (Perception & Psychophysics 44:257–271, 1988, summarised by the author at <https://www.auditory.org/postings/1992/8.html>): for onsets of **10 ms or less, the order-identification threshold does not depend on rise time**. Above that, the threshold grows with rise time. The study used tones at 1650 and 2350 Hz. A mallet or pluck with a 1–5 ms attack is therefore inside the "as good as a click" range.
- **Perceived onset time and its spread.** Danielsen et al. 2019, "Where is the beat in that note?" (J. Exp. Psych.: Human Perception and Performance 45(3):402–418; accepted manuscript <https://jyx.jyu.fi/handle/123456789/63979>). They measured the perceived onset ("P-centre") of real instruments (kick drum, snare, piano, cabasa, arco bass, fiddle) and matched synthetic sounds:
  - Fast attack + short sound: perceived onset **3.9 ms** after physical onset. Fast attack + long sound: 9.1 ms. Slow attack: 12.5 ms (short) and 24.5 ms (long).
  - Slow attack and long duration both **widen the spread** of where listeners place the sound in time. Centre frequency had **no effect on the spread**.
  - Real instrument sounds were placed with **less spread than synthetic ones** (mean 14.0 ms versus 20.4 ms). A natural-sounding pluck is, if anything, easier to time than a synthetic blip.
  - The 1 ms click had a very narrow distribution. So did the fast-attack drums (rise times 2 ms and 5 ms).
- **Ensemble music.** Musicians in real ensembles play nominally simultaneous notes a mean of about 36 ms apart (Rasch), and listeners readily hear the leading voice. When a higher tone leads a lower one by 30 ms, the higher tone is heard as fully separate (Rasch 1978, Acustica 40:21–33; summary <https://blog.zhdk.ch/zmoduletelematic/slides/>).
- **Answer: yes, with conditions.** A mallet, pluck or woodblock is as good as a click for order judgement if:
  1. the attack (onset to peak) is **≤ 5 ms**, comfortably under Pastore's 10 ms limit;
  2. the audible sound is **short**: a decay time constant of about 20–60 ms (the current 6 ms is a click; 20–40 ms reads as a woodblock or marimba with no measurable penalty in the data above). Longer ringing moves the perceived onset later (3.9 → 9.1 ms) and widens the spread;
  3. **both sides use the identical envelope**, so any shift in perceived onset is the same on both sides and cancels. Different attack or length per side is the bias case the existing brief already rejects (its option c).

### Does lower pitch (400–800 Hz fundamentals) hurt order judgement?

- **Ordering accuracy.** Fostick et al. found no frequency effect on thresholds, and Danielsen et al. found no frequency effect on the spread. Lower pitch in itself does not measurably hurt.
- **Perceived timing shifts later at low frequency** for real instrument sounds (Danielsen experiment 1, effect strongest for long sounds), but not for their synthetic sounds. Mechanism: a 4th-order gammatone filter (the standard model of one cochlear channel) peaks (n−1)/(2π·1.019·ERB) after onset, where ERB = 24.7·(4.37·f/1000 + 1) Hz (Glasberg & Moore 1990). That gives about **6 ms at 500 Hz, 3.5 ms at 1 kHz and 2 ms at 2 kHz**. A sound whose onset is carried only by a low fundamental is smeared by a few ms inside the ear.
- **Across-frequency compensation.** Wojtczak et al. 2012 (JASA 131:363–377, <https://pubmed.ncbi.nlm.nih.gov/22280598/>) found perceived synchrony of a 250 Hz tone with 1–6 kHz tones peaked at physical synchrony. The brain compensates for the cochlea's frequency-dependent delay. Their asynchrony-detection thresholds were lower when the low tone led.
- **Hove, Keller & Krumhansl 2007** (Perception & Psychophysics 69:699–708, <https://link.springer.com/article/10.3758/BF03193772>): with two-note chords onset 25–50 ms apart, the perceived beat is pulled toward the **lower** note. A small pitch-dependent pull exists, and it is the reason the two sides should not differ by much in register.
- **Rule.** A 400–800 Hz fundamental is fine **if the sound keeps upper partials (roughly 1.5–4 kHz) in the strike transient**, so the onset is marked in the fast, high-frequency channels. Marimba-like modes (1 : ≈3.9 : ≈9.2) do this naturally, with the high modes decaying in a few tens of ms. A pure low sine is the bad case: soft onset, weak high-channel marking.
- Computed sharpness of a marimba-like 523 Hz strike (first 30 ms) is 1.24 acum, the same as the current low tick and well under 1.75.

### What spectral difference between sides keeps them distinct without hurting ordering

- **Evidence.** A 1 : 1.8 ratio (1 kHz vs 1.8 kHz) ordered as well as identical sounds in different places (PMC9269437). A 400 Hz vs 3 kHz gap (1 : 7.5) was worse (Frontiers 2018). Across-stream ordering fails when sounds split into separate streams (Bregman & Campbell 1971, <https://pubmed.ncbi.nlm.nih.gov/5567132/>).
- **Recommendation: up to about one octave between the two sides, same instrument and envelope, different pitch.** A consonant interval within the octave (fifth 3:2, major sixth 5:3, octave 2:1) keeps them as one instrument. When they are in sync they fuse into one chord, because components starting within about 30 ms tend to group into one sound (Bregman; Darwin, <https://www.ioa.org.uk/system/files/proceedings/cj_darwin_auditory_grouping_and_attention_to_speech.pdf>; <https://www.frontiersin.org/journals/neuroscience/articles/10.3389/neuro.01.025.2009/full>). When they are out of sync they are heard as a flam (one drum hit doubled) or an arpeggio.
- **This plays to the wizard's own logic.** "Both at once" corresponds to hearing one chord, and the fusion floor (5–10 ms for clicks) stays narrow because the envelope is still a fast pluck.
- **Avoid two partials at an inharmonic ratio per side** (the current 1 : 1.61). Use a harmonic or marimba-mode partial set, so each side is one recognisable note.
- **Loudness-match by ISO 532-1, not A-weighting**, and re-check the timbre-swap bias measurement the existing brief proposes.

---

## 5. Concrete design rules

### Frequency band (both stimuli)

- **Keep the main energy in about 250 Hz–4 kHz.** The DIN 45692 sharpness weighting starts rising at about 3 kHz and is 2× by about 6.4 kHz. Brewster's earcon ceiling is 5 kHz. The Kumar unpleasant band is 2–5 kHz. A little energy up to 6 kHz is fine for onset definition in the ticks, but it should be the decaying tail of a strike, not a sustained tone.
- **Below about 250–300 Hz is wasted** on small speakers (and was already ruled out for the probe at 500 Hz). The usable floor is set by the speakers, not by pleasantness.
- **Computed effect of moving the probe down** (both lanes kept in disjoint bands with a guard gap, Mac lane × 0.5):

  | Probe | Sharpness | Annoyance PA (same SPL) | PA at equal loudness (10 sone) |
  |---|---|---|---|
  | current: up 3.2–10 kHz + down 2 kHz–500 Hz | 3.19 acum | 39.1 | 14.3 |
  | sweeps: up 1.6–4.5 kHz + down 1.2 kHz–300 Hz | 1.78 acum | 26.8 | 10.0 |
  | pink noise lanes: 1.5–4.5 kHz + 0.3–1.1 kHz | 1.72 acum | 43.0 | 10.0 |
  | pink noise lanes on the current bands | 2.73 acum | 56.2 | 13.2 |

  Moving the bands down removes the whole sharpness penalty (−30 % annoyance at equal loudness). Switching sweeps to noise **without** moving the band keeps most of the penalty.
- **The trade with the measurement.** Moving the Bluetooth lane below 3 kHz gives up the 12 dB quieter room-noise floor above 3 kHz that CONTEXT.md cites. That cost belongs to the signals track to quantify.
- **Timing resolution is not the constraint.** The width of a correlation peak is about 1/bandwidth. A 1.5–4.5 kHz lane (3 kHz wide) has a main lobe of about 0.33 ms; a 300–1100 Hz lane (800 Hz wide) about 1.25 ms. Both are far inside the ±6 ms blend bar. The standard lower bound on delay-estimate scatter is σ ≥ 1 / (2π · β_rms · √(2E/N₀)) (Cramér–Rao bound; β_rms = RMS bandwidth, E/N₀ = signal energy over noise density), so bandwidth trades against signal-to-noise ratio, not against feasibility, until a lane gets narrower than a few hundred Hz.

### Spectral tilt

- Pink (−3 dB per octave in power, equal energy per octave) or steeper toward brown (−6 dB per octave) for anything noise-like. An exponential sweep is already pink.
- If keeping a sweep, an extra gentle downward tilt above about 2 kHz (for example −3 dB per octave on top of the sweep's own pink tilt) costs little signal-to-noise ratio. Sweep magnitude can be shaped freely (Müller & Massarani).

### Tonality ceiling

- **No lone sine** (current: 100 % of energy in one critical band). Either:
  - **harmonic or mallet-like tones** (several partials, simple-ratio relationships, high partials decaying faster): tonal, which Aures counts as pleasant; or
  - **noise** (computed ≈ 15–20 % of energy in one critical band for a 300–4000 Hz burst; no tonal penalty under DIN 45681 or ECMA-74), which reads as wind or breath.
- Avoid the middle ground: one prominent tone over a noise floor, which DIN 45681 and ECMA-74 penalise.
- For the probe, a **harmonic sweep** (several simultaneous sweeps at integer frequency ratios, one lane) or a sequence of short semitone-wide chirps on musical notes (Serafini & Li) are the documented tonal-but-musical options. Their effect on the correlator belongs to the signals track.

### Envelope

- **Probe:** slow edges are good and cost nothing. Use a raised-cosine fade of 150–300 ms in and 300–500 ms out (current: 80 ms). A 1 s swell has a modulation rate near 1 Hz, far below the 4 Hz fluctuation-strength peak and the 15–300 Hz roughness range. Avoid any repetition or tremolo at 2–8 Hz (fluctuation-strength peak) or 15–300 Hz (roughness). The matched filter does not need sharp edges; the correlation peak width comes from bandwidth.
- **Ticks:** attack **≤ 5 ms** (current 8 samples ≈ 0.17 ms, so it can be softened to 1–3 ms with no measured cost: Pastore's 10 ms limit, and the fast drums at 2–5 ms in Danielsen). Decay time constant about 20–40 ms, inaudible by about 150 ms. **Identical envelope on both sides.**

### Level

- Brewster: **10–20 dB above the background** for UI sounds. A quiet room is about 30–35 dBA, which suggests about 50–60 dB SPL at the listener. That is well below the 76 dB SPL assumed here.
- For the probe, matched filtering gains about 10·log₁₀(bandwidth × duration): 1 s × 3 kHz ≈ **35 dB**. A lane can therefore sit near or even below the in-band room noise and still produce a clean peak. The signals track should check this against the live confidence threshold before cutting level.
- Unpleasantness of high tones grows faster with level than loudness does, so lowering the level helps more than proportionally.
- **Noise needs about 8 dB less SPL than a sweep for the same loudness** (computed: 54 dB SPL vs 62 dB SPL for 10 sone). That also means about 8 dB less energy into the correlator at the same perceived loudness. **A whoosh at equal annoyance gives about 8 dB less signal-to-noise ratio than a sweep in the same band.** This is the main measurement cost of the Sonos-style whoosh.
- The tick level should be loudness-matched under ISO 532-1. The code's A-weighting trim is 0.36 dB off the computed figure.

### Duration

- Probe: 1 s is fine for pleasantness; nothing in the metrics penalises it.
- Ticks: total audible length under about 150 ms. The order-judgement threshold gets worse with longer stimuli (Fostick et al.), and long ringing widens the perceived-onset spread (Danielsen et al.).

### Making two lanes sound like one event

From Bregman's grouping cues (common onset, harmonicity, common fate) and Darwin's onset-asynchrony results:

1. **Same envelope, same start, same end** for both lanes. Components that start within about 30 ms of each other tend to group.
2. **Harmonic or consonant relation between lanes.**
   - Ticks: two notes of one instrument a fifth, sixth or octave apart. When aligned they form one chord.
   - Probe (tonal option): if the two lanes are sweeps, make them move **in the same direction at a fixed frequency ratio**. Example: low lane 300 → 1100 Hz with high lane 1500 → 5500 Hz is a constant 5 : 1 ratio, the 5th harmonic, two octaves and a major third. Both still sit in disjoint bands with a guard gap at every instant. Parallel motion (common fate) plus a harmonic ratio makes them one gliding complex tone instead of two diverging glides. A rising glide still reads as "urgency"; a slow, low, rising swell reads far milder than today's 3.2–10 kHz one. A downward pair is the calmer choice.
   - Probe (noise option): two band-passed pink noises with the same envelope sound like one whoosh with a slight hollow at the guard gap. A 1/3-octave gap in a 1 s noise burst is audible as colour but not as two sounds (expectation from grouping cues; not measured here).
3. **Respect the level imbalance.** The near lane (Mac) is heard about 6 dB or more louder by the user as well as the mic. Put the near lane in the **lower** band. Lower bands are also less sharp, so the louder lane is the duller one, which is what the current code already does.
4. **Rhythm for the ticks.** One note per side per beat, as now. Do not add a second note or an arpeggio per side: extra onsets confuse which onset is being judged.

### What remains unknown

- No published listening test compares order-judgement accuracy for a pluck/mallet versus a click **under codec smearing** (SBC/AAC). The P-centre data are from lossless playback.
- The pleasantness ranking of "low harmonic glide" versus "pink whoosh" at equal loudness comes from the Aures model, which was not built for moving or transient sounds. A short A/B listen (owner plus two people, five candidates, rated 1–7) would settle it in under an hour.
- All SPL figures depend on the assumed calibration (full scale = 94 dB SPL). The relative comparisons (sharpness, annoyance ratios, the 8 dB loudness gap between noise and sweep, the 0.36 dB tick trim residual) do not.

Computation scripts: `scratchpad/psy/metrics.py`, `metrics2.py`, `tonal.py`, `pa.py`, `ticks.py` (run with `scratchpad/venv/bin/python`).
