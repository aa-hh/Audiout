# Playback sync clock architecture

Audiout, Mac app (`aa-hh/Audiout` at `add4251`). Written 2026-09-26 from the code
and the notes in `dev/notes/`. Read-only: nothing in the repo was changed.
File references are `path:line` against that commit. Where a statement is my
inference rather than something the code or a measurement shows, it says so.

## The short answer

**No output is ever the master clock, a Bluetooth one included.** Audiout has
one timebase, the Mac's host clock (`CLOCK_MONOTONIC`). Every captured block
is stamped on it, the PTP helper serves the same clock to AirPlay receivers
as grandmaster, and every output schedules a block to sound at
`capture_pts + R`. The master is the Mac, not a speaker.

What a Bluetooth speaker *can* be, and already is, is the **slowest output in
the room**. The room delay `R` is sized to cover it, and every other output is
held back to meet it. So the open question has a split answer:

- **As a clock: never.** The Mac cannot observe a Bluetooth speaker's audio
  clock. Its latency re-rolls every time a stream starts and steps
  mid-session. And AirPlay receivers can only follow PTP, which the Mac owns.
- **As the latency anchor: yes, through trim math.** Each output delays itself
  by `R − L_i + trim_i`, where `R = max` over every output's intrinsic delay.
  That is delay-to-worst, and it is what the code does today, with one gap:
  when AirPlay is in the group, Bluetooth latencies are left out of `R`
  (Gap 1 below).

The code already follows this design. The rest of this doc says which piece
does what, and names five gaps.

---

## 1. Vocabulary

The code uses "reference" for three different things, which makes the master
question look harder than it is. This doc keeps them apart:

| Term | Meaning | Where |
|---|---|---|
| **Timebase** | The clock every timestamp lives on: Mac host time, rebased to `CLOCK_MONOTONIC`. It never jumps, and nothing a speaker does can move it. | `SyncCore.swift:18-24` |
| **Room delay `R`** | How long after capture every output sounds a block. It is a depth on the timebase, not a clock. The code calls it the "reference timeline" or "reference buffer". | `NativeBackend.swift:3815`, `BTSyncedSink.swift:97` |
| **Intrinsic delay `L_i`** | How late output *i* plays on its own if it is fed immediately. | per transport, §2 |
| **Trim `t_i`** | The user's signed nudge on top of the measured `L_i`. Bluetooth allows ±500 ms. | `BTTrimStore.swift:23` |
| **Measurement reference** | The speaker a calibration run is judged *against*. This is an acoustic comparison partner, not a clock. | `CompanionSnapshotBuilder.swift:220` |

The one equation, from `SyncTiming.totalDelayNanos` (`SyncCore.swift:55`):

```
delay_i = max(0, R − L_i − margin_i + t_i)     sound_i(pts) = pts + delay_i + L_i ≈ pts + R
```

The zero clamp is the only way this equation can fail. An output with
`L_i > R + t_i` cannot be fed early enough, so it plays late. Choosing `R` is
therefore the whole of "who is the reference".

## 2. The four transports

| | AirPlay | Mac / wired (default output) | Bluetooth | Cast |
|---|---|---|---|---|
| **What clocks the audio** | The receiver's clock, disciplined by PTP to the Mac (the helper daemon owns UDP 319/320) | The device's own crystal (~30 ppm) | The speaker's DAC. The Mac only sees the host-side Bluetooth *pacing* clock (`BTClockStability.swift:3-9`) | The receiver's own clock (~50 ppm vs the Mac) |
| **Intrinsic delay `L`** | `startBufferMs` = 1000 by default (options 1000, 1500, 2250). Sound leaves the speaker at `pts + S` | HAL formula: safety offset + device + stream latency + buffer (`LocalOutputLatency.swift:35-41`) | 100–400 ms by brand. It re-rolls 20–90 ms at every stream start and steps mid-session | ~5.5 s, chosen by the receiver and reported by it as `secondsSent − currentTime` |
| **How `L` is known** | Exactly: we set it | Read from the HAL at anchor time | Measured acoustically, by the phone mic, the Mac mic or by ear. **The HAL property is never trusted.** | Self-reported, gated by a settle window (`CastRoomDelay.swift`) |
| **Rate drift vs timebase** | None: PTP slaves it | Continuous; a PI loop nulls it | Treated as none (see §5.1 and Gap 3) | ~3 ms/min |
| **Correction** | None needed | `PhaseController` driving a cubic `FractionalResampler`, ±200 ppm (`SyncCore.swift:158, :319`, used at `SyncedLocalSink.swift:798`) | Event-driven: passive mic tracking, re-measure on reconnect, keep-alive to stop stream restarts | Skip or insert in the feed when the error exceeds 150 ms |
| **Can it be the timebase?** | No. It follows PTP and cannot lead it | No. Its crystal is slaved to host time by resampling | **No** | No |
| **Can it set `R`?** | Yes (`R ≥ S`) | No. Its `L` is tens of ms, always under the others | Yes, when AirPlay and Cast are absent (§3.2) | Yes, and it usually dominates (`R ≈ 5.5 s`) |

## 3. Who sets `R`

### 3.1 What the code does now

`roomDelayLocked()` (`NativeBackend.swift:3815-3819`):

```
today = (Bluetooth armed && no AirPlay && no Cast) ? btReferenceBufferMs : startBufferMs
R     = max(today, castTermMs)        // the Cast term is nil when no Cast device is selected
```

`btReferenceBufferMs` = `max(500, slowest measured BT latency + 100)`
(`NativeBackend+Bluetooth.swift:159, :178-182`). During a Bluetooth wizard run
it is pinned at 2000 so the search can reach any plausible latency (`:170`).

| Composition | `R` | Who sets it |
|---|---|---|
| AirPlay only / AirPlay + Mac | `S` | AirPlay |
| AirPlay + BT (+ Mac) | `S` | AirPlay. **BT latencies are ignored** (Gap 1) |
| BT only / BT + Mac | `max(500, slowest BT + 100)` | **The slowest Bluetooth speaker** |
| Anything + Cast | `max(above, Cast lead)` | Usually Cast; AirPlay is then pre-delayed by `R − S` through `PCMDelayLine` |
| Mac only | n/a | Native playback, no sink |

### 3.2 Why a Bluetooth speaker may set `R` but may not be the clock

Setting `R` from Bluetooth is safe because `R` is only a depth. When a
Bluetooth latency moves, `R` moves once. Every sink re-anchors, which is one
audible gap (`setBTOnlyBufferMs`, `BTSyncedSink.swift:1477`). The timebase
stays put, and so does every other speaker's schedule relative to it.

Making a Bluetooth speaker the *clock* would mean slaving every other output
to its playout instant. Four facts rule that out:

1. **The Mac cannot see that instant.** `AudioDeviceGetCurrentTime` on a
   Bluetooth device reads the host stack's pacing clock, not the speaker's
   converter (`BTClockStability.swift:3-9`). The acoustic playout is visible
   only to a microphone, a few times per session. A clock you can sample
   every 20 minutes cannot discipline anything.
2. **Its latency is not a constant.** Each stream start re-rolls it by
   20–90 ms. Stack re-anchoring after connect steps it (the Move 2 made 32
   jumps of ±5–100 ms, net −353 ms, in its first 42 s). Game Mode moves it by
   70–90 ms, and Apple's warm-up drifts it ~60 ms over 20–30 min
   (`dev/notes/bt-latency-stability-research-2026-09-05.md` §1-2). With a
   Bluetooth master, every AirPlay, Mac and Cast output would inherit each of
   those jumps. With the Mac as master, a jump is contained to one speaker
   and corrected on that speaker.
3. **AirPlay can only follow PTP.** The receivers discipline to the
   grandmaster, and the Mac's helper is the grandmaster. Following a
   Bluetooth clock would mean steering PTP from mic readings. Any change to
   AirPlay's schedule costs a session rebuild and the receiver's ~2 s lead
   (`Sources/AudioutCore/AGENTS.md`, the EQ rebind rule).
4. **Its reported latency is wrong.** `kAudioDevicePropertyLatency` reads a
   flat 160 ms for AirPods while the stack moves between 60 and 220 ms. The
   plan already calls it "a weak prior only, never the truth"
   (`PLAN-UNIVERSAL-SYNC.md` §B).

The passive-drift spec states the same rule from the measurement side
(decision 13): *"the clock is the authority, never a neighboring speaker."*

### 3.3 Bluetooth as a measurement reference

In a calibration run the target is compared against another speaker. The
order is the Mac's own output first, then any other non-Bluetooth speaker,
then a Bluetooth one as a last resort. Cast is never used
(`CompanionSnapshotBuilder.swift:220-231`). A Bluetooth reference is
legitimate, because the run measures a *difference*. But the answer then
carries both links' uncertainty. Keep it last in the order, and label a
latency measured that way (Gap 5).

## 4. Bluetooth latency: measuring and trimming

### 4.1 Where the number comes from

In order of trust:

1. **Phone microphone probe** (ProbeKit, `audiout-shared`). A DOWN sweep on
   the reference lane and an UP sweep on the target are staged together
   (`stageBTMicProbe`). The phone's capture latency cancels in the arrival
   *difference*, so the Mac gets `offsetMs`, positive when the target is late.
   ProbeKit refuses rather than guesses (`probeNotFound`,
   `recordingTooShort`).
2. **Mac by-ear wizard.** Paired clicks, a Bayesian posterior
   (`BTAlignmentPosterior.swift`, `BTAlignmentWizardSession.swift`), and at
   most `maxMicAttempts` mic tries per run.
3. **Manual trim.** Drawer or phone, ±500 ms, snapped to whole ms.
4. **Never the HAL latency property.**

### 4.2 When a measurement is allowed

A measurement taken while the pacing clock still steps measures the settling,
not the speaker. `BTClockStability` samples the pacing clock once a second.
A step over 2 ms is a jump; 10 s without one is steady (`:49, :62`).
`BTSpeakerTiming` publishes `unknown / settling / steady` and never a
countdown. A 60 s floor turns "no evidence" into steady (`:122`). The phone's
Measure button is live only at steady. A measurement made earlier is kept
but marked `firstPass` and stale, so it is re-checked later.

### 4.3 What is stored and what is applied

- The **measured latency** `L_i` and the user's **trim** `t_i` are stored
  separately, per Core Audio UID. The latency is the speaker; the trim is the
  user's ear. Drift corrections write the latency, never the trim. The drift
  baselines are `room + trim`, so a correction written into trim would read
  back as fresh error (`Sources/AudioutCore/AGENTS.md`).
- **Reconnect.** The stored value goes back on the sink immediately and is
  labelled `fromLastTime` (ADR 0001). A re-measure within 10 ms keeps the
  stored value; 10 ms or more replaces it
  (`BTSpeakerTiming.decision`, `:631`); over 40 ms the user is told.
- **Clock moved.** Summed jumps of 10 ms or more since the alignment mark the
  row stale with reason `moved` (`:125`).
- **Applying.** A trim or latency change is a ring seek on that one sink. It
  never rebuilds the sink and never clears the anchor. A move of the BT-only
  `R` floor does rebuild every sink, which is why a slew step never moves the
  floor and only the committed write at its end does.

## 5. Drift over time

There are two kinds of error, and they get different machinery.

### 5.1 Rate drift (continuous ppm)

| Output | Mechanism |
|---|---|
| AirPlay | None needed: PTP disciplines the receiver to the timebase. |
| Mac / wired | A PI loop on the render thread: Kp 150, Ki 2 ppm per frame, slew 25 ppm per cycle, clamp ±200 ppm, over-damped at 512-frame buffers. It holds phase error near zero indefinitely. |
| Bluetooth | **None, by decision.** A2DP sinks servo to the host's delivery rate. Measured inter-speaker drift was −0.02 ppm over 30 min (`BTSyncedSink.swift:469-471`). Passive-drift live tests 2–4 found no continuous drift once the sender's dropped cycles were padded (spec decision 18). The sink releases once at `pts + delay` and then drains at unity rate. |
| Cast | Skip or insert zeros in the HTTP feed when the error passes 150 ms, about once an hour. Driving the resampler from the lead slope is listed as the future step (Cast brief §4). |

### 5.2 Latency events (discrete jumps)

On Bluetooth, this is what actually moves. The design has three layers:
prevent the jump, detect it, then correct it.

- **Prevent.** A keep-alive feeds silence so the link never restarts, with a
  10 min default timeout (`BTSyncedSink.swift:574`, spec decision 4). The
  sender shim pads dropped cycles (PR #200).
- **Detect with the pacing clock.** Cheap and continuous, but it only sees the
  host side. It raises `moved` and triggers a mic window, rate-limited per
  speaker.
- **Detect with the microphone.** `PassiveDriftTracker` and
  `PassiveDriftSampler` cross-correlate 4 s of Mac-mic audio against the
  retained outgoing mix. The mix is stamped on the timebase, so each speaker
  arrives as a peak at a known delay. Attribution is by which peak moved from
  its calibrated baseline. Rules that matter:
  - An AirPlay or Cast arrival is read-only. It measures the mic's own
    offset, which is then subtracted from every Bluetooth reading
    (decision 13).
  - Every peak shifting together with no anchor means the mic moved:
    re-baseline, don't correct.
  - One peak inside two speakers' windows means they are in sync
    (decision 14).
  - Five unusable windows in a row turn tracking off quietly.
  - Windows run on events: reconnect, a clock step, silence→audio, the manual
    re-sync, plus at most one periodic check every 20–30 min (decision 18).
- **Correct.** `DriftCorrectionPolicy`: under 10 ms, leave it; 10–40 ms,
  correct silently; 40 ms or more, correct and tell the user (`:106-108`). A
  guessed attribution waits for a second window that agrees within 1.5 ms
  (`verifyBeforeApply`). The move lands whole in a gap when the program is
  silent, or slews over ~20 s while music plays. It writes the measured
  latency and marks the calibration stale.
- **Cast** uses the same shape with its own numbers. It trusts nothing until
  ten samples agree within ±100 ms; its term only ever rises while the
  receiver stays selected; a receiver past 9.5 s is refused for sync.

## 6. Gaps

Ordered by how likely a user is to hear them.

**Gap 1. With AirPlay in the group, `R` ignores Bluetooth latency.**
`roomDelayLocked` returns `S` whenever AirPlay is present, and
`btReferenceDelayMs` does the same (`NativeBackend.swift:3831-3834`). A
Bluetooth speaker with `L > S + trim` hits the zero clamp and plays late with
no correction possible. At the default S = 1000 most speakers fit, but the
2026-09-03 handoff hit exactly this (blocker 1: the budget shrank from 1500
to 500 ms when AirPlay joined). This is about latency, not drift: AirPlay
keeps its clock. A speaker that plays 1.2 s after it is fed can't be fed
before the audio is captured, so the only way to line the two up is for
AirPlay to wait longer. Raising the AirPlay buffer setting to 1500 or
2250 ms does the same thing by hand today. *Recommendation:* make `R` delay-to-worst
across all transports:

```
R = max(S, slowestMeasuredBT + headroom, castTerm)
```

Pre-delay AirPlay by `R − S` through the `PCMDelayLine` that Cast already
installs (`setAirPlayPreDelay`). This is the Cast brief's N-way rule with
Bluetooth added as one more `max` operand. It keeps the no-change invariant
by construction: when no Bluetooth speaker is slower than `S`, the operand
never wins and AirPlay is untouched. The cost is that a slow Bluetooth
speaker now pushes AirPlay later, and each change to `R` is one gap for the
whole house. Use the Cast policy's hysteresis so `R` never falls while that
speaker stays selected.

**Gap 2. A Bluetooth speaker used only for per-app routing is left out of
`R`.** This is deliberate: one app's speaker should not re-anchor the house
(`NativeBackend.swift:620-631`). But a slow one plays late. It is already
written up as a known limitation; left as is.

**Gap 3 (corrected 2026-09-26). "Bluetooth has no rate drift" is backed by
evidence.** An earlier version of this doc called the 11 ms desync
unexplained. That was wrong: `.scratch/passive-drift-tracking/HANDOFF.md`
root-caused it on 2026-09-14. The whole-system tap sometimes dropped an 11.6 ms
IOProc cycle and never padded it, and the keep-alive then padded one
Bluetooth sink but not the other. PR #200 fixed it; net drift afterwards was
−0.002 s over 3 min. The evidence against continuous Bluetooth drift:
the 2026-08-12 acoustic measurement (−0.02 ppm over 30 min,
`dev/notes/per-device-trim-spec.md:46-49`); live tests 2–4 after the fix
(spec decision 18); and the labelled 2026-09-14 recording, where untouched
blocks held ~15 ms apart and a deliberate +40 ms trim read back as +41 ms.
The old `BTDriftCorrector` was removed because it servoed the pacing clock
against itself and did nothing. One thread is still loose: in that same
recording, block 6 showed both speakers sliding together ~1 ms/min (567 → 556 ms
over 9 min) with the tap counter flat, logged as "real speaker drift, or mic".
Because the slide was common to both, it cannot be inter-speaker drift. It only
matters if Bluetooth drifts against AirPlay or the Mac. *Recommendation:* build
nothing. Next time Bluetooth and AirPlay play together, check whether the
`bt_clock_deviation` log shows that slide.

**Gap 4. A Bluetooth device as the Mac's default output.** `SyncedLocalSink`
reads `L` from the HAL formula (`LocalOutputLatency`). If the default output
is itself a Bluetooth device, that is exactly the property §3.2 says is
wrong. I found no code that special-cases it. *This is inferred from not
finding it, so verify first.* If it is real, route that device through the
Bluetooth path (measured `L`) instead of the local sink.

**Gap 5. One word, three meanings.** "Reference" means `R`, the
measurement partner, and (in comments) PTP. Adding the §1 vocabulary to
`CONTEXT.md` would stop the next reader re-asking the master question. While
there, label a latency measured against a Bluetooth partner (a `Source` or a
telemetry field) so field data can tell how much worse those measurements
are.

## 7. Invariants to keep

- The timebase is `CLOCK_MONOTONIC` host time. Nothing measured from a
  speaker ever moves it.
- `R` is only ever `max` of intrinsic delays. It is delay-to-worst, because no
  output's own latency can be shortened.
- AirPlay and Cast arrivals are read-only for drift. Only Bluetooth is ever
  corrected by the mic.
- Drift corrections write measured latency, never trim, and never record an
  alignment.
- A trim or latency change is a seek, never a sink rebuild. Only a change in
  `R` rebuilds, and it costs every speaker one gap.
- Refuse rather than guess: ProbeKit, the passive gates, verify-before-apply
  and the Cast settle gate all prefer no number to a wrong one.
- No Cast (and, under Gap 1, no slow Bluetooth speaker) means AirPlay is
  byte-identical to today, proven by `max(x, nil) == x`, not by a flag.

## 8. Decisions for Ali

1. **Gap 1. DECIDED 2026-09-26 (Ali): delay-to-worst.** A Bluetooth speaker
   slower than `S` raises `R`, and AirPlay is pre-delayed by `R − S` through
   the existing `PCMDelayLine`, the same way Cast already works. `R` never
   falls while that speaker stays selected. Draft PR #228
   (`claude/project-thread-wk2iwa`), unbuilt as of 2026-09-26.
2. ~~Gap 3~~ Settled by existing evidence (see Gap 3): no Bluetooth
   rate servo.
