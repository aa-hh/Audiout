# Wizard alignment tick: is the stimulus right?

Research brief, 2026-08-24. Question from the owner: *"Are the two tones we're
using the scientifically proven best ones? Is there something we can do that
makes it easier for the user to distinguish?"*

**Short answer.** The wizard already plays two different sounds, and the way it
does it happens to match what the temporal-order literature would recommend:
identical onset and envelope, difference in spectral colour only, one octave
apart. Widening that difference (a proper "tick / tock") would make the two
easier to *label* but measurably worse to *order*, and it is the ordering that
the estimator converts into milliseconds. The two real gaps are (1) the two
variants are not loudness-matched, which is a genuine, uncancelled bias in the
measurement, and (2) the two sounds are only different when the pair spans two
transports — a Bluetooth-vs-Bluetooth run plays *identical* clicks today.

---

## 1. What the stimulus actually is (from source)

Generator: `AudiouterCore/Sources/AudiouterCore/AlignmentTickInjector.swift`.
Nothing is synthesized in `AirPlayEngine`; the engine only encodes what it is
handed.

### Waveform

`renderTick(sampleRate:amplitude:partialHz:)`, lines 210-224:

- **Two decaying sine partials**, `0.7·sin(2π·f₁t) + 0.3·sin(2π·f₂t)`.
- **Duration 30 ms** (`frames = sampleRate * 0.03`), exponential decay
  `exp(−t/τ)`, **τ = 6 ms** — so it is inaudible well before 30 ms; the tail is
  padding, not sound.
- **Attack: 8 samples** (~0.18 ms at 44.1 kHz) of linear ramp, "sharp but not a
  raw DC step".
- **Amplitude 0.35** of full scale, before the per-device volume product.
- Rendered once at init into an `[Int32]` table; mixing is table lookup by beat
  phase.

Two timbres, from the same envelope family and the same frame count:

| variant | partials | goes to |
|---|---|---|
| `brightTick` | **1 800 + 2 900 Hz** | the Bluetooth fan-out (`bedded` block) |
| `lowTick` | **900 + 1 450 Hz** | the engine feed — AirPlay + the Mac's own synced-local sink |

`mixWizardVariants(into:bedded:)` (lines 350-362) renders both from the same
source block, the same `start` cursor and the same `tickEpochFrame`, then
advances the cursor once. The file states the intent outright (lines 48-52):
*two timbres off one beat clock, "so the two sides of the judgement are told
apart by colour, not only by order. Same onset instant either way; only the
partials differ."* So **option (b) of the ladder is already built** — for
cross-transport pairs.

### The two speakers do NOT always play different sounds

The split is by **transport**, not by role. `NativeCaptureCoordinator.deliver`
(line 1361-1363) hands `bedded` to `btSink`, which fans **one identical block**
to every per-device Bluetooth delay line; `pcm` goes to the engine sink and the
synced-local Mac sink. Consequence:

| run | target hears | reference hears | distinct? |
|---|---|---|---|
| BT target vs **Mac** (the default reference) | bright | low | **yes** |
| BT target vs AirPlay speaker | bright | low | **yes** |
| BT target vs **another BT speaker** | bright | bright | **no** |
| Mac's own sync-offset run vs AirPlay | low | low | **no** |

The default reference is the Mac (`PopoverController.btWizardDefaultReference`,
line 3968: *"The Mac's own output first — it is always present, always in step"*),
so the common path is the distinct one. The identical-sound cases are reachable
whenever the user picks a same-transport reference from the picker.

### Alternation, tempo, level, and what else is in the feed

- **Not alternating.** Both speakers are hit on the **same beat**; the whole
  question is how far apart they land after their own delays. One beat = one
  judgment.
- **Tempo is stage-dependent** (`BTAlignmentWizardSession`, lines 90-93;
  `AlignmentTickInjector` lines 38-44, 92-95):
  - coarse search **20 BPM — one tick every 3 s**,
  - stimulus blocks **72 BPM (~833 ms)**, switched when the 95 % credible
    half-width drops under **250 ms**.
  - The manual row metronome is 72 BPM.
  - The *reason* is aliasing, not comfort: an unknown 150-700 ms Bluetooth
    latency at 833 ms spacing turns a 650 ms lag into an apparent ~180 ms lead,
    "and the run converges a whole beat wrong."
- **Program replacement**: during a wizard run the captured system audio is
  *overwritten*, not summed (`Config.replacesProgram`) — the user judges clicks
  in silence.
- **Keep-alive bed**: a ~20 Hz sine at −40 dBFS RMS under the ticks, **Bluetooth
  side only**, to stop a Sonos Move power-gating its amplifier and swallowing
  the first transient. Marked UNVALIDATED on hardware. Not audible; not a factor
  in the judgment. The Mac side gets no bed (it was heard as "heavy static").
- **Third speakers are muted**: every selected BT speaker that is not the target
  or the reference is held at gain 0 for the run (`btWizardHeldUIDs`), after a
  live run where a third speaker "is simply the loudest thing in the room and
  gets judged instead of the target".
- **Codec asymmetry**: the AirPlay side is **ALAC — lossless**
  (`AirPlayEngine.swift:1275`). Only the Bluetooth side is lossy (SBC or AAC,
  chosen by macOS and the device).

### What the user is asked

`BTAlignmentWizardView`: *"You'll hear a click from each speaker. Tap the one
you hear first."*, prompt *"Which clicked first?"*, plates ← target, → reference,
Space = "Both at once". **The copy never mentions that the two sounds differ**,
so the timbre cue is available but unadvertised.

### How many judgments

The task framing said ~7-9. The code says otherwise: `BTAlignmentPosterior`
proposes at a 6 ms credible half-width, *"Simulation: median ~13-15 answers,
~20 worst case"*, hard cap 40. Worth correcting wherever 7-9 is written down —
it changes the fatigue argument below.

### Roadmap 062 band-split chirp

Not relevant to the by-ear stimulus. It is a **machine** measurement tool for
"does a saved alignment survive a reconnect" (ROADMAP 056 Part 3 / spec Part
3b). It becomes relevant only as an *instrument*: it is the cheapest way to
measure the stimulus bias `b` proposed in §4. Prior art agrees on chirps for
machine measurement — Genelec's GLM AutoPhase plays chirps through a sub and a
satellite specifically to align their phase.

---

## 2. What the literature says

**TOJ acuity is roughly 20-40 ms of onset asynchrony for 75 % correct**, and it
is dominated by *duration* of the stimulus, not by its frequency, spectrum or
location. Szymaszek et al. found *no* difference in mean TOJ thresholds across
frequency, spectrum and location conditions, while the long-duration condition
was significantly worse
([Psychological Research](https://link.springer.com/article/10.1007/s00426-017-0915-1)).
**Implication: short, transient stimuli win; which pitch you pick is close to
irrelevant for acuity.** The current 30 ms / τ = 6 ms woodblock is the right
family.

**Identical stimuli in different places beat different-pitched stimuli.** In a
direct comparison, a *spatial* task (two identical 1 ms clicks, alternating
ears) gave thresholds of 88/83 ms across sessions; a *spectral* task (400 Hz vs
3 000 Hz, 10 ms) gave 114/91 ms, with much wider spread. The authors attribute
it to auditory streaming: two far-apart tones are heard as one frequency-modulated
*glide* or as two separate streams rather than two ordered events
([Frontiers in Psychology 2018](https://www.frontiersin.org/journals/psychology/articles/10.3389/fpsyg.2018.02557/full);
population was elderly, so the absolute numbers are high — the *ranking* is the
usable result).

**That streaming failure mode is the classic result.** Bregman & Campbell showed
listeners cannot judge order *across* perceptual streams: with rapid sequences
of widely-separated tones the input splits into streams and "patterns cutting
across the two streams are not easily perceived"
([J. Exp. Psychol. 1971](https://pubmed.ncbi.nlm.nih.gov/5567132/)). This is the
direct argument against a big pitch gap between the two speakers. It is *partly*
mitigated here — streaming builds up over rapid repetition, and our beats are
833 ms-3 s apart — but the pair inside one beat is exactly the cross-stream
comparison.

**The dichotic-TOJ tradition states the trade explicitly**: the two stimuli
"must differ by at least one dimension to enable identification", and the stated
advantage of the dichotic (identical-sound, different-ear) design is that "the
temporal judgment is based on the temporal relationship of the two stimuli
alone and not on other cues such as pitch"
([PLOS One 2022](https://journals.plos.org/plosone/article?id=10.1371/journal.pone.0264831)).
The wizard's differing dimension is already **location** — two speakers in a
room. Pitch is a *second* differing dimension, added for labelling.

**Fusion floor.** Below the echo threshold two transients are heard as one
event: ~5-10 ms for clicks, up to ~50 ms for speech and music
([Attention, Perception & Psychophysics](https://link.springer.com/article/10.3758/s13414-015-0907-4)).
The estimator's listener model (fusion half-window 6 ms, propose at 6 ms) sits
exactly on that number, and it is stimulus-dependent — a click is the *narrowest*
fusion window available, i.e. the sharpest possible endgame. Choosing a longer
or softer sound would widen the floor and cost final precision.

**Perceived onset is not acoustic onset.** The perceptual centre (P-centre) of a
sound sits some milliseconds after its acoustic onset, and **rise time is the
dominant factor**: longer onset ramps push the perceived timing later; centre
frequency, duration and spectral composition are secondary contributors
([APP 2019, comparison of P-centre methods](https://link.springer.com/article/10.3758/s13414-019-01747-y);
[Where is the beat in that note? — attack, duration, frequency](https://www.researchgate.net/publication/331441474_Where_is_the_beat_in_that_note_Effects_of_attack_duration_and_frequency_on_the_perceived_timing_of_musical_and_quasi-musical_sounds)).
**This is the bias mechanism to fear.** Two sounds with the same envelope and
different partials should differ in P-centre by little; two sounds with
different *attacks* (option c) would differ by a lot, and every millisecond of
that lands in the stored latency.

**Codecs.** The Bluetooth side is the only lossy leg. SBC is a subband coder
whose quantisation noise stays inside its own subband and inside one short frame
— the canonical 8-subband/16-block configuration is **208 samples ≈ 4.7 ms** of
algorithmic delay at 44.1 kHz
([IETF RTP payload draft for SBC](https://datatracker.ietf.org/doc/html/draft-ietf-payload-rtp-sbc-02))
— so any pre-echo is confined to a few milliseconds, not tens. AAC is a
transform codec where quantisation error smears across the whole analysis
window, which is why transform codecs detect transients and switch to short
windows ([pre-echo and window switching background](https://arxiv.org/pdf/1602.05311));
an isolated woodblock click is the textbook case that triggers that switch.
Both codecs band-limit at the top (roughly 14-16 kHz in practice), so **nothing
above ~6 kHz should be trusted** and both current timbres (0.9-2.9 kHz) sit
comfortably inside the passband — and comfortably above the low-frequency
roll-off of a portable speaker. Practical band for this stimulus: **~500 Hz to
~6 kHz**.

Net codec effect on *this* measurement: a few ms of softening on the Bluetooth
side only. That is arguably not error — the sound really does arrive smeared,
and the wizard is measuring what the user hears — but it is one-sided, and it
pushes the measured Bluetooth latency slightly *up*.

**Prior art on stimulus choice.** Nothing in the consumer space does a by-ear
order judgment; everything measures with a microphone, and therefore uses
sweeps and noise rather than clicks. Sonos Trueplay plays a mixture described as
brown noise, pulses and a frequency sweep while the phone is waved around the
room ([Sonos Tech Blog on Trueplay](https://tech-blog.sonos.com/posts/trueplay-spectral-correction/);
stimulus description from [Pocket-lint](https://www.pocket-lint.com/what-is-sonos-trueplay-tuning-and-how-does-it-work/));
Genelec GLM plays sine sweeps per speaker and **chirps** for sub/satellite phase
alignment ([Genelec GLM](https://www.genelec.com/glm);
[Sound On Sound GLM 4.2 review](https://www.soundonsound.com/reviews/genelec-glm-42)).
Read: sweeps are for machines, transients are for ears. No prior art argues for
making a listener's two comparison sounds spectrally dissimilar.

**Pleasantness over a run.** ~15 judgments at 3 s, then 833 ms — about 60-90 s
of clicking. The unpleasantness knob is *level*, not attack: softening the
attack is the one change that directly costs acuity (rise time → P-centre and
fusion window). If the run is judged harsh, drop the amplitude, don't round the
edge.

---

## 3. Bias analysis — does the design cancel a stimulus-induced order bias?

**No. Nothing in the design cancels it.** Checked in source:

- `BTAlignmentPosterior.judgmentProbabilities` is symmetric in target/reference
  around residual 0, with a shared 6 ms fusion half-window and a 12 % lapse
  floor. A listener who systematically hears sound A ~`b` ms earlier than it
  physically is shifts the whole psychometric function, and the posterior
  converges on the shifted crossover. **The estimate is displaced by exactly
  `b`, and it does not shrink with more trials** — extra answers narrow the
  credible interval *around the wrong value*.
- **Roles never swap.** Which timbre a speaker gets is fixed by its transport
  for the whole run (`mixWizardVariants` → `deliver`), and the wizard has no
  counterbalanced condition. There is no A/B inversion anywhere.
- The final confirm ("Sounds right", ±4 ms fused window) inherits the same
  bias, so it cannot catch it either.
- The candidate *levels* do sweep both signs of residual — that is what makes
  the psychometric fit possible — but it is the fit's centre that moves, so
  sign-sweeping is not cancellation.

Magnitude of `b` for the **current** design should be small: onsets are
sample-identical, envelopes are byte-identical, only the partials differ, and
the literature puts rise time first and centre frequency a distant second. Call
it order-1 ms — but it is **unmeasured**, and it sits against a 6 ms stop
criterion, so it is not negligible by inspection.

**The concrete bias vector that exists today is loudness, not pitch.** Both
variants are rendered at `amplitude: 0.35`, but 1.8/2.9 kHz sits near the ear's
most sensitive region while 0.9/1.45 kHz does not — at equal digital amplitude
the bright click is the louder of the two, and louder events are perceived
earlier. That biases runs toward "the Bluetooth speaker clicked first", i.e.
**systematically under-estimates Bluetooth latency**. Room position and per-device
volume already perturb this too, and the wizard does not level-match the two
speakers.

**Cheap way to measure `b` (recommended regardless of which option is chosen):**
add a debug flag that swaps the two timbres between the two fan-outs, run the
wizard twice on the same pair, and take half the difference of the two results.
That number *is* the total stimulus-induced bias, including the loudness term
and the codec term. Nothing else in the repo can produce it today; the 062
chirp tool could produce the codec half of it independently.

---

## 4. Options, costed

Ladder assessed against: distinguishability (can the user tell which speaker
is which), order acuity (how sharply they can say which was first), bias risk
to the stored millisecond value, and implementation cost against the actual
generator.

| # | Option | Distinguishability | Order acuity | Bias risk | Cost |
|---|---|---|---|---|---|
| **a** | **Identical clicks both sides** (status quo for BT-vs-BT and Mac-vs-AirPlay) | Poor — pure spatial attention, the case the owner is complaining about | **Best** — the dichotic ideal, one differing dimension only | **Lowest**: identical stimuli cannot introduce a perceived-onset difference | Zero |
| **b** | **Two spectral colours, identical envelope** (status quo for cross-transport; today 900/1450 vs 1800/2900 Hz) | Good — a clear colour cue to label the sides | Near-identical to (a): same onset, same rise time, one octave apart is inside the streaming-safe range | Low but **uncancelled**; loudness mismatch is the live term, worth ~1-3 ms | Already built |
| **b′** | **b, loudness-matched and named in the copy** | Better — the cue is advertised, so it is actually used | Same as (b) | **Loudness term removed**; residual bias measurable via the swap test | **Small.** One constant in `renderTick` (per-variant amplitude), one string in `BTAlignmentWizardView`, gated on the pair actually differing |
| **b″** | **Wider pitch gap — a true "tick / tock"** (e.g. 400 Hz vs 3 kHz) | Best | **Worse** — this is exactly the spectral-task condition that measured 114 ms vs 88 ms, and the Bregman cross-stream failure | Higher: bigger spectral distance means a bigger P-centre and loudness difference to control | Small code, bad trade — **reject** |
| **c** | **Different envelope/attack per side** (e.g. click vs soft thud) | Best | **Worst** — different rise times mean different fusion behaviour | **Highest**: rise time is the dominant P-centre factor; a several-ms constant error straight into a stored latency | Small code, **reject** |
| **d** | **Per-device timbre** (each speaker its own colour, so BT-vs-BT is distinct too) | Best coverage — fixes the identical-sound cases | Same as (b) | Same as (b), per pair | **High.** The Bluetooth fan-out is one shared block to N delay lines (`deliver` → `btSink`, one base resampler per consumer). Per-device variants means rendering N blocks in the pacer, a per-UID buffer map through `SyncedLocalPCMSink.enqueue`, and per-device resampler state — real work on the real-time path |
| **e** | **Keep the sounds; fix the pairing** — prefer/enforce a cross-transport reference so the pair is always distinct (Mac is already the default) | Good, on every run | Same as (b) | Same as (b) | **Small** — a picker ordering/notice change in `PopoverController.btWizardReferenceOptions` |
| **f** | **Literature alternative: keep both identical, label by UI** (highlight the row, flash the plate, name the speaker) | Moderate | Best | Lowest | Small, but throws away a working audio cue |

Deliberately not tabled: shortening the tick (already 30 ms with a 6 ms decay —
short enough), softening the attack (costs acuity, §2), any stimulus above
6 kHz or below 500 Hz (codec band-limit / portable-speaker roll-off).

---

## 5. Recommendation

**Take b′, plus e. Do not widen the difference between the two sounds.**

1. **Loudness-match the two variants.** Give `renderTick` a per-variant
   amplitude so the low knock and the bright click are equally loud, not equally
   scaled. This is the one live, uncancelled bias in the current stimulus, and
   it is a constant in one function. (An equal-loudness weighting at ~1.2 kHz vs
   ~2.2 kHz is a few dB — measure it rather than guessing, ideally with the swap
   test below.)
2. **Say so in the copy**, and only when the pair actually differs: *"You'll
   hear a low knock from <reference> and a bright click from <target>. Tap the
   one you hear first."* The cue exists and is currently unadvertised; this is
   the cheapest distinguishability win in the whole ladder.
3. **Keep the pair cross-transport.** The Mac is already the default reference,
   so the common path is already distinct; make the picker prefer a
   different-transport reference, or say plainly when the two speakers will
   sound the same.
4. **Measure the residual bias once** with the timbre-swap debug flag (§3). If
   half the difference between two runs comes back under ~2 ms, the stimulus is
   proven fine and this file can be closed. If it comes back larger, the
   loudness match is wrong or the codec term is bigger than expected — and it
   is then a one-constant correction, not a redesign.

**Why not the tick/tock the question implied:** the current design already *is*
the two-distinct-sounds design, built at the largest spectral separation that
does not start costing order acuity. Pushing further trades the thing being
measured for the thing being labelled — and every millisecond lost that way is
stored in the device's latency table, permanently, with no part of the estimator
able to notice.
