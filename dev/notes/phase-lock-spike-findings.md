# Phase-lock feasibility spike — findings (T-SPIKE-PHASE)

Status: **CHECKPOINT — the owner must confirm/renegotiate the target below before
T-CORRECTION starts.** This is not a pass-through rubber stamp (plan §T-SPIKE-PHASE,
Risk R7).

Harness: `dev/phase-spike/` (throwaway SPM tool, pattern of `dev/audiocap/`; does
**not** link AudioutCore — it re-derives the timing math independently as a
cross-check). Evaluated against the real `SyncedLocalSink` graph shape and its
`latestPhaseErrorNanos` seam (`AudioutCore/Sources/AudioutCore/SyncedLocalSink.swift`,
the `T-CORRECTION / T-SPIKE-PHASE INSERTION SEAM` ~line 236).

Machine: this MacBook, macOS 14.4.1 (23E224), Apple silicon, Swift 5.10.

---

## 0. TL;DR + go/no-go

**GO for studio-grade / "phase-perfect" — but the target must be re-worded to
"sample-accurate at the electronic output boundary, ± a manual per-room offset,"
not "phase-perfect at the listener's ear" (physically impossible across a room).**
Public `AVAudioEngine` is sufficient; **no raw HAL IOProc is required.**

- The frame-accurate silent-prefix placement already in `SyncTiming.plan` holds the
  **initial** release phase to **≤ ½ frame ≈ ±10.4 µs @ 48 kHz** — measured, and
  **independent of buffer size**. That already defeats R7's "bottoms out at buffer
  granularity (~10 ms)" worry for the anchor. Buffer size sets the correction
  *cadence*, not its *precision*.
- A continuous ppm-level rate correction can be driven **click-free** through the
  graph — verified on `AVAudioUnitTimePitch`, `AVAudioUnitVarispeed`, and a custom
  4-tap cubic resampler under a continuous 0→200 ppm sweep (all: output stayed
  within the clean-signal slope bound, ratio 1.00×, no discontinuity).
- **Recommended T-CORRECTION mechanism: a custom fractional resampler embedded in
  the existing `AVAudioSourceNode` render block** (drive the ring read at `1 ± ppm`),
  driven by a PI loop nulling `latestPhaseErrorNanos`. Not an AVAudioUnit.
  `AVAudioUnitVarispeed` is the acceptable off-the-shelf fallback. `AVAudioUnitTimePitch`
  is over-engineered for this and should not be used.

**The one number I could NOT measure headlessly** is the *real* per-cycle `hostTime`
jitter the HAL hands the render block against a live output device — offline manual
rendering does not provide a valid `hostTime` (see §3). My principled prediction is
sub-µs to low-µs because `mHostTime` is a clock-anchored presentation anchor, not
"wall time when the callback woke," but **the owner should confirm it** with the silent
`realdevice` probe (§6) or fold it into the T-DOCS-LIVE by-ear run.

---

## 1. What the harness measures (all silent)

`dev/phase-spike` — `swift build`, then:

| Command | What | Touches a device? | Audible? |
|---|---|---|---|
| `phase-spike offline` | plan-math Monte-Carlo · offline timestamp cadence · TimePitch/Varispeed probe · custom-resampler probe | **No** | **No** |
| `phase-spike realdevice [--seconds N]` | real per-cycle `hostTime` jitter on the default output device | Yes (opens IO) | **No — emits only zeros, `isSilence=true`, mainMixer volume 0** |
| `phase-spike all` | both | Yes | No |

I ran **`offline` only** (repeatedly, deterministic). I deliberately did **not** run
`realdevice` unattended: it is silent, but starting the audio subsystem can produce a
physical speaker-relay click on some Macs, which is exactly the class of surprise the
standing "don't touch his audio during a session" rule guards against. It is safe for
the owner to run themselves anytime (it makes no sound); it is *not* the by-ear T-DOCS-LIVE
test.

---

## 2. Q1 — how tight a phase error can render-block feedback hold?

### Algorithmic floor (measured headlessly, `plan-math` Monte-Carlo, 200k trials/config)

`SyncTiming.plan`'s sub-buffer silent-frame trick was re-implemented independently and
Monte-Carlo'd over random target/cycle phasing:

| sample rate | buffer | \|phase error\| mean | p99 | max | theoretical ½-frame |
|---|---|---|---|---|---|
| 48 kHz | 512 | 5.21 µs | 10.31 µs | **10.417 µs** | 10.417 µs |
| 48 kHz | 4096 | 5.20 µs | 10.31 µs | **10.417 µs** | 10.417 µs |
| 44.1 kHz | 512 | 5.67 µs | 11.22 µs | **11.338 µs** | 11.338 µs |

**The max exactly equals ½ frame and does not change with buffer size.** So the
*placement* logic already gets the initial release to ~10 µs — three orders of
magnitude below the ~10 ms "buffer granularity" ceiling R7 feared. This is the number
`latestPhaseErrorNanos` reports at release, and it is already sub-frame by construction.

### The real-thread part (NOT measurable headlessly — needs the owner)

The floor above assumes the render block is handed an *exact* per-cycle `hostTime`. The
open empirical question is how accurate that `hostTime` actually is on real hardware.
Offline mode can't answer it (§3). See §6 for the prediction + the ready probe.

---

## 3. Q3 — sub-ms continuous lock, or buffer-granular? (the key conceptual result)

Offline timestamp cadence (`phase-spike offline`):

- `sampleTime` advances by **exactly 512 frames every cycle, sd = 0** — a perfectly
  regular grid.
- **`mHostTime` is never flagged valid offline** (`AudioTimeStamp.mFlags = 1` =
  `SampleTimeValid` only; the `HostTimeValid` bit is never set). Confirms that real
  `hostTime` behaviour is only observable against a real device clock.

**The precision-vs-cadence distinction is what resolves R7:**

- **Precision is NOT buffer-limited.** `AVAudioTime.hostTime` from the render block is
  the HAL's *clock-anchored presentation timestamp* for the cycle, not "now, when the
  callback happened to wake." Thread-scheduling jitter (the thing that *is* buffer/OS
  granular) does not corrupt that anchor. A control loop reading it can therefore
  measure phase to sub-microsecond.
- **Only the correction *cadence* is buffer-limited** — you get one `hostTime`
  reading and one rate nudge per render cycle (~10.7 ms at 512/48k). For **ppm-level
  clock drift** (which accrues over *minutes*), a correction opportunity every ~10 ms
  is enormous headroom. Nyquist of the drift process is nowhere near the buffer rate.

So: **public `AVAudioEngine` can hold continuous sub-ms phase lock at the electronic
output boundary. Raw HAL is not required.** (Both AVAudioEngine and a raw IOProc ride
the same HAL timeline anyway — going raw buys no timing precision, per brief §5.2.)

---

## 4. Q2 — can a rate-correction node be driven continuously, click-free?

Offline manual rendering, 1 kHz full-scale sine, rate swept continuously 1.0 → 1.0002
(0→200 ppm — realistic drift magnitude), rate updated every render cycle. "Click" =
output first-difference exceeding the clean-sine slope bound. Deterministic across runs.

| mechanism | group delay @ unity | continuous-sweep click ratio | realised-rate error | pitch behaviour |
|---|---|---|---|---|
| **custom cubic (4-tap Catmull-Rom)** | ~2 samples ≈ **0.042 ms** | 1.00× (none) | 6.8e-5 (≈ measurement floor) | tracks rate |
| `AVAudioUnitVarispeed` | 48 samples = **1.000 ms** | 1.00× (none) | 3.2e-4 (≈ floor) | tracks rate |
| `AVAudioUnitTimePitch` | 0 samples measured¹ | 1.00× (none) | 2.1e-4 (≈ floor) | preserved |

¹ The impulse group-delay measured 0 at exactly rate 1.0, but `AVAudioUnitTimePitch`
is a **phase vocoder**: its documented `latency` is non-zero off unity and it smears
transients. Treat the 0 as "near-passthrough at unity," not "zero-latency processor."

**All three are click-free under a continuous ppm sweep.** The rate-linked pitch shift
of Varispeed / the custom resampler is inaudible at ppm scale (fractions of 0.01 %),
so TimePitch's pitch-preservation buys nothing here (brief §6 reaches the same
conclusion analytically; this measures it).

---

## 5. Recommended mechanism for T-CORRECTION

**Custom fractional resampler inside the existing `AVAudioSourceNode` render block —
NOT an AVAudioUnit.**

Why:

1. **Zero graph surgery, zero added AU latency.** The T-CORRECTION seam in
   `SyncedLocalSink` already has the render block draining the ring and deinterleaving.
   A fractional resampler is a drop-in on that ring read: instead of reading `N` samples
   per `N` output frames, read at `N·(1 ± ppm)` with cubic interpolation between taps.
   No `engine.attach`/`connect` of a correction node, no reconnection race with
   T-LIFECYCLE, and it does **not** consume the ~1 ms fixed latency that Varispeed would
   force you to fold back into the T-LATENCY delay budget.
2. **Sample-accurate, arbitrary ppm resolution.** A `double`-precision phase accumulator
   steers to any rate — ideal for a PI loop nulling `latestPhaseErrorNanos` to the
   ~10 µs floor without over/under-shoot.
3. **Inaudible at ppm scale** (measured: click-free, and the pitch shift is far below
   audibility). Matches brief §6's recommendation to prefer rate-linked correction for
   tiny nudges.

**Fallback (if the custom DSP is deemed too much for the timeline):**
`AVAudioUnitVarispeed`, inserted at the seam and driven via `.rate`. It is click-free
and off-the-shelf, but (a) adds a fixed ~1 ms latency that MUST be added into the
T-LATENCY total delay so the anchor still lands correctly, and (b) is slightly coarser.
**Do not use `AVAudioUnitTimePitch`** — it is a phase vocoder (transient smear, more
latency) solving a pitch-preservation problem that does not exist at ppm scale.

Control loop: PI over `latestPhaseErrorNanos`, output = ppm rate offset, clamped to a
sane band (e.g. ±500 ppm) with slew limiting so a startup transient can't step the rate
audibly. T-CORRECTION's own unit test (per plan) drives synthetic drift and asserts
convergence/hold — the `PlanMath` + resampler code here is a starting reference for it.

---

## 6. What still needs the owner (do NOT skip before declaring victory)

1. **Real per-cycle `hostTime` jitter.** Run (silent — zeros only):
   ```
   cd dev/phase-spike && swift build && ./.build/debug/phase-spike realdevice --seconds 8
   ```
   Report `per-cycle hostTime Δ jitter` and `mono↔host rebase skew`. Prediction:
   jitter is sub-µs to low-µs (anchor is clock-derived). If it were instead tens of µs
   or buffer-granular, that would be the signal to escalate to raw HAL — I do not
   expect it, but it is the one unverified assumption.
2. **The by-ear T-DOCS-LIVE run** against a real AirPlay 2 receiver + Mac speakers —
   the only test of alignment *at the ear*, which §7 explains is a per-room manual trim.

---

## 7. Target renegotiation ask (the CHECKPOINT decision for the owner)

R7 flags, and I confirm, that **"phase-perfect at the listener's ear" is physically
unattainable**: acoustic propagation is ~2.9 ms per metre, so a Mac speaker and a
cross-room AirPlay speaker cannot be ear-aligned by any electronic means — the offset
depends on where the listener stands.

**Proposed re-wording of the studio-grade target, for your yes/no:**

> Sample-accurate phase lock at the **electronic output boundary** (≤ ~½ frame ≈ 10 µs
> residual, held continuously by micro-rate correction), with the user-facing ms offset
> (T-OFFSET-UI) as the acknowledged manual per-room ear-alignment trim.

- **Upside:** this is genuinely achievable with public APIs (this spike shows it), it's
  an honest "studio-grade" claim (studios sync at the *interface*, not the listener's
  chair), and it keeps the plan on `AVAudioEngine` — no raw-HAL scope blowout.
- **Downside:** it explicitly concedes we are not aligning at the ear without the manual
  offset. If you intended "walk anywhere in the room and it's perfect," that is not
  buildable and the honest answer is to say so now rather than at T-DOCS-LIVE.
- **Recommended:** accept the re-wording and proceed to T-CORRECTION with the custom
  resampler.

If you accept, T-CORRECTION is a **GO** on the mechanism in §5. If you want the jitter
number nailed down first, run §6.1 (silent) before T-CORRECTION starts.
