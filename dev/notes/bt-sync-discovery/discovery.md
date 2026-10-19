# Keeping every speaker in sync: technical discovery

Copied into the repo 2026-09-26. The sync clock architecture document linked below lives on branch `claude/project-thread-wk2iwa` (PR #228) and lands in `dev/notes/` when that PR merges.

Written 2026-09-26 for Ali, from five parallel research tracks (current code, Bluetooth
transport, Cast, the user journey and calibration, prior art) plus two sibling reports
written the same day. Everything below is read-only research; nothing in any repository
was changed. The five full research files are in `research/` next to this document and
carry the `file:line` and URL evidence for every claim here. Where a claim rests on
reading code rather than a measurement, it says *inferred*.

Companion documents this one builds on and does not repeat:

- `research/code.md` (data path, sink state machine, every lifecycle edge, what was tried)
- `research/bluetooth.md` (A2DP behaviour, codecs, delay reporting, AVRCP volume, LE Audio)
- `research/cast.md` (Cast today, receiver buffering, Cast Streaming as the fix)
- `research/journey.md` (the user journey step by step, calibration limits, a redesigned journey)
- `research/priorart.md` (every product, paper, standard and patent that tried this)
- `../sync-clock-architecture-2026-09-26.md` (the master-clock answer and gaps 1–5, "ARCH")
- `../bt-sync-version-comparison/report.md` (which 1.2.0 fixes exist and where, "VER"; no copy in this repository, only in the claude.ai project files)

---

## 1. The answer in one page

**The vision is technically possible, and it is closer than it looks.** No shipped
product takes stock Bluetooth speakers, measures them acoustically, and keeps them in
sync with network speakers for a whole session (priorart §1.0, §3.10). Audiout already has
the hard half of that: a one-shot acoustic calibration that converges to about ±1–3 ms
(runs at confidence 1668–3425 in the 2026-09-03 handoff), a single host timebase that
AirPlay follows by PTP, and a delay-to-worst room delay. What it lacks is the *easy*
half that every working sync system has, plus a few structural gaps that make the hard
half unreliable in the field.

**What is missing, in order of how much sync it costs:**

1. **A continuous host-side loop on every Bluetooth sink.** After release, the sink is
   a plain FIFO at ratio 1.0 that never computes a phase error (`BTSyncedSink.swift:930-950,
   :1176-1179`). Every uneven pull, dropped chunk, missed render lock, pause, and rate
   mismatch becomes a permanent, invisible offset. This is the 1.2.0 customer's 240 ms
   storm and 290 ms creep. Snapcast, shairport-sync, PipeWire, Roon, Bose and Sendspin
   all run this loop; Audiout runs it for the Mac's own output (`PhaseController`,
   ±200 ppm) and not for Bluetooth. The unmerged `ed6f00a` is a 20 ms threshold-and-seek
   partial; the full fix is a timestamped ring plus the existing PI loop and resampler.
2. **Common-mode drift of all Bluetooth speakers against the host clock is real, unmeasured
   and uncorrected.** Bluetooth-to-Bluetooth drift is closed (PR #200). But the "−0.02 ppm
   over 30 min" figure that justified "no rate loop" was a 120 s BT-vs-BT run
   (commit `efb67775`), extrapolated. One 9-minute recording shows both speakers sliding
   ~1 ms/min together; the Move 2's pacing clock runs +21.7 ppm against host. That is
   ~70 ms/hour between every BT speaker and every AirPlay speaker (code A2, bluetooth §1.1).
   Item 1 fixes this too, if the sink servos to the delivery rate, which the protocol
   forces it to (bluetooth Finding A).
3. **The acoustic loop is never closed at the listener, and its baseline is a model.**
   The passive tracker compares each speaker against `room + trim`, not against what the
   Mac mic heard when the room was last known good (`NativeBackend+Bluetooth.swift:1130-1136`).
   So the laptop-to-speaker geometry (2.9 ms/m) reads as error, and a ≥10 ms asymmetry
   "corrects" a phone calibration made at the sofa back toward the laptop (journey §3.7,
   *inferred*, needs the geometry test in §6). It has also never landed a correction live
   end to end and scored under 1 against a gate of 3 in the customer's room (VER).
4. **Every structural event restarts the stream being timed, and nothing re-measures after.**
   AirPlay or Cast joining or leaving, a BT-only floor move, wizard entry and exit, a config
   change or HFP all rebuild every Bluetooth engine: a full-`R` silence and, *inferred*, a
   fresh 20–90 ms latency re-roll each time (code §1.6). Only a baseband reconnect triggers
   a mic window.
5. **Degraded sync is invisible.** "Corrected by 40 ms", "tracker blind", stale, refused
   trim, budget exceeded and "Cast refused for sync" are all computed and none is rendered
   (journey §2). The user's ear is the only health monitor, and by the time they hear it
   they blame Bluetooth.

Plus one that costs coverage rather than milliseconds: **most desktop Macs get no mic path
at all.** Only the built-in transport is accepted (`MicProbeSession.swift:231-252`); Mac mini,
Studio and Pro have none, USB and Studio Display mics are rejected, and the phone is off in
release. Those users get by-ear alignment and no tracking.

**The recommended path** (§4 has the full ranked list):

- **Now, before any new design:** run the five cheap live tests in §6. Two of them (the
  pause/resume drain and the BT-vs-AirPlay hour) decide the shape of item 1; one settles
  Cast's suspected 500 ms error; the geometry test settles item 3.
- **Tier 1 (weeks, all pieces exist):** the timestamped ring plus PI loop on every BT sink;
  seek instead of rebuild when `R` moves; delay-to-worst `R` across all transports (ARCH
  Gap 1); acoustic baselines captured at calibration; a pre-sweep audibility check with
  the hardware-volume raise Ali asked for; a per-speaker sync-health state in the UI; any
  non-Bluetooth mic accepted; Cast's end-to-end delay stamped with capture `pts`.
- **Tier 2 (months):** Cast Streaming as a presentation-timeline transport (Cast joins
  the room like AirPlay, under the 1 s buffer); event-scheduled mini-chirps on connect
  and reconnect; a per-model latency seed; a Kalman estimator over sparse windows.
- **Tier 3 (research, do not promise):** always-on acoustic tracking via masked
  per-speaker codes; an Auracast lane through a USB transmitter dongle.

Items in Tier 1 together would already be a first in the market (priorart §3.10):
one-shot acoustic calibration, a continuous host servo, event-driven acoustic
re-verification and honest health reporting, all on stock speakers. Expected accuracy:
1–5 ms after a verified check, with excursions of one event's size (10–90 ms) until the
next verification lands.

---

## 2. Where things stand (baseline)

Read the two sibling reports for the detail; the points that shape this discovery:

- **The Mac's host clock is the only timebase.** A Bluetooth speaker can set the room
  delay `R` (it is the slowest output) but never the clock; AirPlay can only follow PTP,
  which the Mac's helper serves (ARCH §3.2). That question is settled and this document
  does not reopen it.
- **None of the 2026-09-26 Bluetooth fixes are on main** (VER). Sink re-timing
  (`ed6f00a`), the correlator search window (`2977e56`), the deselect ordering fix
  (`3ae8fea2` on `claude/bt-deselect-no-rebuild-a066`, which VER's row 4 missed), and
  the refused-trim persistence bug are all unmerged or open.
- **The first-sync silence Ali reported** has a likely cause and a draft fix in Audiout
  PR #224 (the 1.5 s wake-up signal is timed from sync start, but a cold speaker plays
  nothing for ~2 s while its delay builds, so the sweeps land before it is audible). The
  code researcher's independent reading found four hypotheses consistent with it (code
  §1.9), including that the keep-alive never arms on a sink that has never rendered
  program audio (`BTSyncedSink.swift:1224`). The pre-sweep audibility check in §4 (item 7)
  turns this whole class into a named "speaker isn't playing yet" state rather than a
  failed measurement.

---

## 3. The unified diagnosis: three loops, one of which is built

Every system that keeps speakers in sync closes three loops. Audiout has built the hardest
one and left the other two open or half open.

| Loop | What it corrects | Who has it | Audiout today |
|---|---|---|---|
| **A. Host-side servo** per output: frames the output consumed vs the timebase, continuous, ppm-scale | Uneven pulls, lost cycles, lock misses, pause drain, common-mode rate offset | Snapcast (single-sample insert/drop, <0.2 ms), shairport-sync (2 ms band, 50 ms resync), PipeWire (DLL resampler), Roon, Bose (ASRC), Sendspin | Mac output: yes (`PhaseController`). AirPlay: yes (PTP). Cast: 150 ms skip/insert steps. **Bluetooth: none.** |
| **B. Acoustic verification** on events: what the speaker actually played vs what it should have, ms-scale, sparse | Stream-start re-roll (20–90 ms), sink deadband wander (up to ~58 ms in a BTstack-class sink), codec change (~50 ms SBC↔AAC), OS mode steps (70–90 ms), receiver output stage | Nobody, for stock BT speakers. Tap Sound System and AmpMe did one shot. Korse et al. 2025 needed a 4-mic array. | Built: ProbeKit sweeps (phone and Mac mic), passive Mac-mic tracker. **Not working live**: model baselines, never corrected end to end, no trigger on rebuilds, no mic on desktops. |
| **C. Room delay budget**: `R = max` of every output's intrinsic delay, applied as a seek, never a restart | A slow speaker being uncorrectable; whole-house gaps | Bose (patent US11678005: reported latencies, max, play-at), Cast groups, Audiout's own Cast path | BT-only and Cast: yes. **With AirPlay present, `R` ignores BT** (ARCH Gap 1); every `R` move rebuilds every BT sink. |

The split of responsibilities that makes this work, and that every researcher converged
on independently: **the servo owns host-side error and writes the resample ratio; the mic
owns downstream latency and writes the measured latency.** They never write the same
variable, so they cannot fight.

### Per transport

- **AirPlay:** done. Not a problem, as Ali said. The only AirPlay work is Gap 1 (letting
  a slow BT speaker push `R` past the 1 s buffer through the `PCMDelayLine` Cast already
  uses) and diagnosing the 222–232 ms send stalls that can eat a calibration sweep (VER).
- **Mac / wired:** done, with one trap: **a Bluetooth device set as the Mac's default
  output goes through `SyncedLocalSink` with the HAL latency and none of the Bluetooth
  machinery, and it also becomes the capture clock** (ARCH Gap 4, confirmed in code §1.5;
  Apple forum 770218 reports +300–400 ms of tap delay in that configuration).
- **Bluetooth:** loops A and B missing or broken, C half built. Detail in §4.
- **Cast:** loop A is a 150 ms step, B does not exist (Cast is excluded from calibration
  and from drift baselines, `NativeBackend+Bluetooth.swift:1190`, while the docs call it an
  anchor), and C works but only ratchets upward. Two likely bugs, *inferred from code and
  needing one mic run*: the HTTP server's 500 ms ring cushion is never subtracted from the
  room delay, so Cast plays ~500 ms late and no trim can reach it (cast §2.1); and after
  the first pause the cushion drains and never refills, so Cast latency is bimodal
  (cast §2.2). The 5.5 s lead is the receiver player's rebuffer target and cannot be cut
  on the HTTP path; Cast Streaming (RTP with sender-timestamped frames, 400 ms default
  target delay) is the path where Cast joins the room like AirPlay (cast §3 C4).

---

## 4. Options, ranked

Feasibility is High when every piece already exists in the codebase or a BSD/MIT source.
"Owner ruling" marks options that reverse a decision Ali made earlier.

### Tier 0: land what exists and measure (days)

| # | Option | Why first | Source |
|---|---|---|---|
| 0.1 | Merge order for `ed6f00a`, `2977e56`, `3ae8fea2`, the refused-trim fix and PR #224, each with a listen on the two Moves | They are the 1.2.0 field failures; none is on main | VER, code Q8 |
| 0.2 | Persist the *applied* trim, not the requested one | A speaker that is right now comes back 205 ms off next time | VER #2, journey F |
| 0.3 | The five live tests in §6 | They decide the design of 1.1, 1.3 and 1.8 | all |
| 0.4 | Correct the "−0.02 ppm over 30 min" wording at `BTSyncedSink.swift:469-471` and in the trim spec to "120 s, BT vs BT" | The claim is load-bearing and overstated | bluetooth §1.1 |

### Tier 1: the missing loops (weeks; every piece exists)

| # | Option | Gap closed | What it takes | Risk | Source |
|---|---|---|---|---|---|
| 1.1 | **Timestamped ring + per-cycle phase error on every BT sink**, driving the existing `FractionalResampler` through `PhaseController`; gap-fill at enqueue when `pts` jumps past expected + 50 ms; freeze while `BTClockStability` says settling; treat steps > 2 ms as re-anchors, not rate; seek only past ~50 ms | Loop A for Bluetooth: uneven pulls, lock misses, pause drain, common-mode rate | ~200 lines in `BTDeviceSink`: store `anchorPts + framesWritten`, compare each enqueue's `pts`, compute error in `renderInterleaved`. Subsumes `ed6f00a`. Gate on test §6.2 | Servoing to a clock the stack is deliberately slewing (Game Mode at 1.1×) fights the stack; the freeze handles it | code O1, bluetooth §3.1, priorart §3.1 |
| 1.2 | **Seek instead of rebuild when `R` moves** (`setBTOnlyBufferMs`, `setComposition` become per-sink `ΔR` seeks; the ring holds 11 s) | Loop C: no whole-house gap and no re-roll on AirPlay/Cast join, floor move, wizard edges | Change `BTSyncedSink.swift:1468-1491`; keep rebuilds for true device or rate changes; hysteresis so `R` never shrinks while the slow speaker stays | A large forward `ΔR` hits the 100 ms seek margin; hysteresis avoids it | code O2 |
| 1.3 | **Delay-to-worst `R` across all transports**: `R = max(S, slowestBT + headroom, castTerm)`, AirPlay pre-delayed by `R − S` through the existing `PCMDelayLine` | ARCH Gap 1: a BT speaker over 500 ms can be aligned with AirPlay present | The Cast N-way rule with BT as one more operand; no-change invariant by construction | A slow BT speaker pushes AirPlay later; one gap per `R` change. **Approved by Ali 2026-09-26** (ARCH §8.1) | ARCH Gap 1, journey E |
| 1.4 | **Trigger a mic window on every sink restart**, not only baseband reconnect | Loop B after every re-roll | Call the drift trigger from `rebuildLocked` for config, rate, composition and HFP edges; the per-speaker rate limit exists | Mic-window budget | code O3 |
| 1.5 | **Acoustic baselines**: after every accepted calibration (phone verdict, Mac-mic Keep, "Sounds right"), take one passive window and store each speaker's *observed* Mac-mic arrival as its baseline; track deviation from that, never from `room + trim` | Loop B's reference: geometry no longer reads as error; a seat calibration stays a seat calibration; trim-only speakers can be tracked | `setBaselines` exists; a `captureBaselineWindow()` after Keep; per-UID baselines keyed to a Mac-position epoch; an additive `CompanionCommand` case so a phone verdict triggers it | A bad first window is a bad baseline: require two agreeing (the 1.5 ms rule) | journey A, B, H; priorart §3.5 |
| 1.6 | **Mac's own speaker as the passive anchor** when no AirPlay or Cast is in the room (BeepBeep's second arrival) | The "Mac speakers + one BT speaker" room, the most common one, gets tracking at all | Add the local output to `driftTrackingRuns` anchors; its HAL latency is honest | Near-field anchor may mask far speakers; whitening handles ~20 dB, needs a test; laptops only | priorart §3.5, journey §0.4 |
| 1.7 | **Pre-sweep audibility check with hardware-volume raise** (Ali's requirement): play band-limited noise on the target lane, measure in-band SNR at the mic, require ~15–20 dB; if `btHardwareVolumeCapable`, step the speaker's own volume (~+8/127) up to a cap and restore the exact prior level in a guaranteed cleanup; if not, bypass the per-device software gain for the sweep lanes and ask the user in one line with a live meter; a raise that does not change the mic level marks the speaker "hardware volume not delivered" | The confident-wrong-number class (VER #5), first-sync silence, HFP collapse, parked amps | ProbeKit: an in-band SNR helper (pure DSP); Mac: a stage before `stageProbe`, raise/restore on `btHardwareVolumeControl` modelled on `beginCompanionAuditionCleanup`; phone: one additive "turn it up" page. ~3–4 s per calibration | Loudness surprise; the cap and whether the raise needs a visible line are **owner rulings**. Detection today is an SDP claim check only; the n/127 read-back from `bt-absolute-volume-detection.md` is not built | journey §3.8b, bluetooth §1.12, code §1.7 |
| 1.8 | **Cast: stamp stream positions with capture `pts`** and drive the room delay from true end-to-end delay `now − pts(currentTime)` sampled at the request/reply midpoint; then **rate-match the Cast feed** from the regressed slope (±3.5 ppm per 10 min) instead of 150 ms steps | Cast's suspected 500 ms error, the pause bimodality, hourly 150 ms gaps, the upward ratchet | The ring already receives `pts` and drops it; one side table; `CastRoomDelay` ingests E2E; the license-clean resampler on the ring's render side | Low; loop must freeze during stalls | cast C1–C3 |
| 1.9 | **Sync-health state per speaker**, one word: Locked, Settling, Adjusting, Corrected, Unverified, Can't hear, Can't fix; one popover line naming the cause and the one action that fixes it | Invisible degradation | Consume `btDriftCorrectionNoticeMs`, `btDriftTrackingIsBlind`, stale reasons, seek-clamped, `bt_clock_jump` storm, `CastRoomDelay.refused`; add the trivial budget-exceeded check; expose through `OutputBackend` | Nagging; keep it glanceable (spec decision 9) | journey §5.3 |
| 1.10 | **Accept any non-Bluetooth microphone** (USB, Studio Display, webcam); exclude BT transports and aggregates containing one | Desktop Macs get the wizard and tracking; the difference method cancels capture latency | Relax `builtInMicrophoneID()` | Low | journey D |
| 1.11 | **Refuse or reroute a Bluetooth default output**: a BT device that is the system default is routed through the BT sink with a measured `L`, or refused as "This Mac", and never used as the capture aggregate's clock when a wired or built-in device exists | ARCH Gap 4; the tap delay and pacing-jump trap | Transport check in `SyncedLocalSink` and in the aggregate builder (`NativeCaptureCoordinator.swift:3654-3684`) | **Owner ruling** on refuse vs reroute | code §1.5, Q7; bluetooth F5 |

### Tier 2: automatic and self-maintaining (months)

| # | Option | What it buys | What it takes | Risk | Source |
|---|---|---|---|---|---|
| 2.1 | **Cast Streaming output** (mirroring apps `85CDB22F`/`0F5096E8`): Opus 48 kHz over RTP, RTCP Sender Reports carrying the Mac timebase, `targetDelay = R − outputStage`; the receiver plays each frame at `capture_pts + targetDelay` on a clock slaved to ours | Cast joins the room like AirPlay, under the 1 s buffer: no ~4.5 s house gap on join, no drift loop, no 5.5 s floor. OwnTone ships this path; the owner's spike already launched the apps | Opus encoder (libopus, BSD, if AudioToolbox cannot encode Opus), AES-CTR, RTP/RTCP packetiser, OFFER/ANSWER; clean-room from openscreen (BSD-3), never OwnTone (GPL). ~1.5–2.5k lines. A half-day to two-day spike first (cast C4) | Undocumented protocol; unknown on Android TV and on GC4A 2.0 speakers (a large share of third-party Cast speakers and 2025+ Nest firmware), so it must fall back per device; output stage still needs one acoustic measurement | cast C4 |
| 2.2 | **Event-scheduled mini-chirps**: a 150 ms–1 s branded sweep pair on speaker connect (the UX Ali already accepted), on reconnect, on the "Sounds right" tap, and at wake with the app playing; auto-triggered on the steady edge with the reference chosen for the room (AirPlay when present, not the MacBook) | ADR 0001's re-check without the phone; first play near-sync instead of 100–400 ms late | Steady-edge trigger, reference chooser, the wizard's measurement path without the sheet | **Owner ruling**: today's "no app-initiated measurement" rule vs the accepted connect chirp | journey §5.2 tier 3, §5.4 step 3 |
| 2.3 | **Predictive re-check scheduling** (Amazon US11336424's idea): extra windows when a second BT device joins, Game Mode toggles, wake from sleep, Wi-Fi load spikes, and 20–30 min after connect (Apple's warm-up window) | Catches the event-shaped moves before the 25-minute periodic check | Add triggers to decision 18's list; rate-limit as the clock-step trigger is | More mic-light events | priorart §3.8 |
| 2.4 | **A prior for unmeasured speakers**: HAL latency plus a class offset, or a fleet median by BT vendor/product ID and codec, bucketed and anonymous; used only as the wizard's opening proposal | A fresh speaker starts ~30 ms off instead of 100–400 ms; narrows a 2000 ms search | Analytics row in `audiout-shared/docs/analytics-events.md` first; a bundled table; `Source.estimated` label | Google's Nest Mini case: a model constant was 500 ms wrong on another host, so macOS numbers only from macOS measurements. **Owner ruling** on whether VID/PID passes the privacy fence. Patent: Tap Sound System EP3402220A1 claims the server upload | code O4, journey J, priorart §3.2 |
| 2.5 | **2-D Kalman estimator** per speaker (latency, latency rate, covariance), fed by accepted windows and by pacing-clock steps as process-noise events | Carries evidence across sparse, noisy windows instead of the fixed "two agree within 1.5 ms" rule; gives the health lamp a principled number | Small, pure math; tuning needs the field logs (ticket 06) | Tuning without data | priorart §3.4 |
| 2.6 | **Per-model sink profiles**: run the drift meter's line/staircase classifier and a 10-minute passive run per speaker model; record deadband width and re-roll spread; feed the settle gate and the "leave it" band | A BTstack-class sink (up to ~58 ms deadband) needs a wider band than 10 ms | Tools exist on `claude/bt-multi-spike`; data collection is the cost | Low | bluetooth §3.2 |
| 2.7 | **Widen the tracker search on clock events** (±120 → ±400 ms when a clock-step storm or re-time fires) | The 240 ms runaway is outside today's search | `searchHalfWidthMs` from the pacing-clock prior | More false lobes; gates exist | journey G |
| 2.8 | **Calibration age and context**: store `measuredAt`, macOS build, codec once readable; after an OS update or 90 days schedule one silent verify | Nothing ages a calibration today | Store fields plus one trigger | Low | journey I |
| 2.9 | **Party-mode groups as one sink**: a JBL PartyBoost/Auracast or Bose SimpleSync group is one A2DP device; calibrate the leader only | Halves airtime and calibration count; sidesteps BT-vs-BT probing for same-brand pairs | UX and copy only; one live check of leader-to-follower offset | Vendor relays add their own follower delay (UE Double Up complaints) | priorart §3.9, bluetooth §3.3.2 |
| 2.10 | **Hygiene that removes failure classes**: warn on 2.4 GHz Wi-Fi with ≥2 BT sinks plus AirPlay; recommend ≤2 BT sinks per Mac and a USB A2DP dongle per extra 1–2; never open a BT mic during playback; log the capture aggregate's main sub-device transport | Fewer lost cycles, re-buffers and HFP collapses | Small | None | bluetooth §3.5 |

### Tier 3: novel, research-grade (do not promise)

| # | Option | What it buys | Honest feasibility | Source |
|---|---|---|---|---|
| 3.1 | **Auracast lane via a USB transmitter dongle** (Sennheiser BTD 700, FlooGoo FMA120): the Mac sees a class-compliant USB output with honest HAL latency, slaved by the existing local PI loop; every Auracast receiver renders at the BIG sync point + presentation delay (20–40 ms, set by the standard), so they are in sync with each other by construction and Audiout aligns one latency to AirPlay | "Calibrate once" becomes literally true for LE Audio speakers; nobody has put Auracast receivers in a synced group with AirPlay | Medium. Works today on hardware that exists; Apple ships no Auracast source through WWDC26. JBL Auracast speakers refuse third-party broadcasts; hearing aids, Galaxy Buds and some speakers accept them. Does nothing for existing A2DP speakers. One dongle and one open receiver on the desk answers the constancy question | bluetooth §1.9, §3.3.1; priorart §1.5, §3.3 |
| 3.2 | **Per-speaker masked spread-spectrum code** in each BT lane (1–8 kHz, psychoacoustically shaped, ~44 dB processing gain over 4 s) so every passive window is attributable and works through quiet passages | Signal-based attribution; a correction floor of 3–4 ms instead of 10 ms | Low to medium. A2DP SBC/AAC are perceptual coders designed to discard what is masked, and no source demonstrates sample-level timing from a masked mark through a room (Nadeau 2017: 70% resync, frame-level, slightly audible). Expect to run it at "faint hiss in quiet passages". Reverses spec decisions 1 and 7 (**owner ruling**). Ultrasonic is not an option: A2DP cuts at 14–18 kHz. Test code survival offline through reference SBC/AAC encoders before anything else. **FTO flag:** InterDigital US20190116395A1 reads onto it almost word for word | journey §5.2 tier 2, priorart §3.6, bluetooth §3.3.3 |
| 3.3 | **MacBook mic array for spatial separation** (Korse et al. 2025 needed a 4-mic array to separate same-program speakers) | Separates arrivals that share a program | Low to unknown: `.measurement` mode uses the primary mic only; whether Core Audio exposes raw channels is an open question | priorart §3.7 |
| 3.4 | **Cast SEEK-within-buffer** to cut the HTTP lead from ~5 s to ~2.5 s | Smaller house delay while Cast stays on HTTP | Low confidence; `Accept-Ranges: none` may force a re-GET; an hour in `cast-spike` | cast C6 |

---

## 5. What the product looks like when it works

The journey researcher's redesign (journey §5) in one paragraph, because it is the thing
Ali is building toward: **the user never thinks about sync unless the app cannot fix it,
and then the app says exactly what it needs.** Onboarding asks for the mic with a reason.
A new Bluetooth speaker shows *Settling* while its clock steps, plays at a seeded latency
instead of 100–400 ms late, and once steady the app checks it is audible, raises its
volume if it can, plays one branded sweep pair against the right reference, applies the
result and records what the room sounds like from the Mac. An optional "check from your
seat" with the phone refines it, and the Mac re-records its baseline. During music the
host servo holds every speaker to the timebase continuously; the mic verifies on events
and on a sparse timer against the acoustic baseline; corrections follow the 10/40 ms
policy. Reconnect, wake and relaunch apply the stored value, mark the speaker *Unverified*,
and verify at the next opportunity. Degradation shows one word per speaker and one action.
Cast joins under the AirPlay buffer through Cast Streaming, with a per-device fallback to
the HTTP path shown honestly as "joins unsynced" or "adds ~5 s".

Two rulings Ali made earlier would have to be reopened for this journey: app-initiated
measurement on connect (scoped to the chirp he already accepted), and, only for Tier 3,
injected signals during playback.

---

## 6. Live tests to run first (ordered by decision value per minute)

Each is a short session on Ali's hardware. Together they settle the design of the biggest
Tier 1 items.

1. **Pause/resume drain (2 min).** One BT speaker plus one AirPlay speaker, Music.app,
   pause 60 s (long enough for the tap to idle and the BT ring to drain), resume. Is the
   BT speaker ~`S − L` (600–900 ms) early? Repeat with two *different* BT speakers in
   BT-only. A unit test can settle the code half first (anchor, drain, resume with a `pts`
   60 s later). *Decides whether gap-fill in 1.1 is needed.* Counter-evidence exists
   (a trim held across start/stops on 2026-08-23), so this is a test, not a conclusion.
   (code A1/Q1)
2. **BT-vs-AirPlay hour (60 min).** One BT speaker and one AirPlay speaker, no events.
   Does the steady-state slope of the existing `bt_clock_deviation` line equal the
   BT-vs-AirPlay acoustic slide? Does the AirPlay peak stay still (ruling out the mic's
   own clock)? *Decides 1.1's error signal: if the slope matches, servo against
   pacing-vs-host and it is cheap and continuous; if the slide is there without a slope,
   the sink is not following delivery and only the mic can see it.* (bluetooth §1.1, §4.1)
3. **Cast 500 ms (5 min).** Mac mic, AirPlay plus Cast on the current build, before any
   pause and again after a 5 s pause. `cast_lead_sample.achieved_delay_ms` minus the feed
   delay should read ~500 before and ~0 after. *Confirms or refutes cast §2.1–2.2 in one
   session.*
4. **Geometry (30 min).** Calibrate two BT speakers with the phone at the sofa; put the
   MacBook ~4 m nearer one speaker than the other; play 30 min; watch for
   `drift_correction_started` and listen at the sofa. Then carry the MacBook 2 m and count
   false corrections. *Confirms journey §3.7 and the need for 1.5.*
5. **Rebuild re-roll (10 min).** Probe a BT speaker before and after a forced
   `config_change` rebuild. Does the engine restart re-roll `L` by 20–90 ms? *If yes,
   1.2 and 1.4 move up.* (code Q3)

Cheaper still, from existing telemetry: does `bt_device_reported_latency` differ between
speaker models? If it does, macOS is folding in something device-specific (most likely an
AVDTP delay report) and it becomes a free prior for 2.4. And `log stream --predicate
'process == "bluetoothaudiod"'` during a connect answers whether the codec and the delay
report are visible at all.

---

## 7. Decisions for Ali

1. **Gap 1:** ~~may a slow Bluetooth speaker push AirPlay's room delay past its 1 s buffer?~~
   **Settled by Ali on 2026-09-26 (clock architecture thread): full delay-to-worst.** A slow
   Bluetooth speaker may push AirPlay's room delay later, through the delay line Cast
   already uses. Option 1.3 is approved as designed.
2. **The volume raise (1.7):** may the app raise a speaker's hardware volume for 2–3 s
   during calibration without a prompt, and to what cap (70–80% of range is the
   suggested start)? Does it need a visible "Turning up the {name} for a moment" line?
3. **App-initiated measurement (2.2):** may the app play a sweep on connect and reconnect
   without a tap? The mic-probe brief says a branded chirp on connect is accepted UX;
   the standing rule says no measurement is app-initiated.
4. **A Bluetooth default output (1.11):** refuse it as "This Mac", or reroute it through
   the Bluetooth path with a measured latency?
5. **Merge order and model (0.1):** 1.1 replaces `ed6f00a`'s mechanism. Decide before
   merging whether pulls-vs-wall-time is the model to keep, or go straight to the
   timestamped ring.
6. **Cast:** is a permanent ~5 s house delay acceptable as the HTTP-path cost, or should
   Cast default to "joins unsynced" until Cast Streaming exists? Go/no-go on the Cast
   Streaming spike and on a libopus dependency if AudioToolbox cannot encode Opus.
7. **Seed data (2.4):** may an analytics event carry BT vendor/product ID plus a rounded
   latency under the privacy fence?
8. **Tier 3 (3.2):** reopen spec decisions 1 and 7 for an opt-in masked per-speaker code,
   after the offline codec-survival test?
9. **Freedom to operate (not legal advice):** now that Audiout is paid, commission a
   patent check on InterDigital US20190116395A1 (per-device watermark + mic → latency),
   Bose US11678005B2 (delay-to-worst with negotiated latencies) and Tap Sound System
   EP3402220A1 (mic-measured BT speaker latency by two-receiver difference, server upload)
   before marketing claims?
10. **The definition of "in sync":** is 10 ms the product's floor? At 1–10 ms the stereo
    image collapses onto the earlier speaker; SPEC.md says "perfect sync". Once
    attribution is signal-based the floor can drop to 3–4 ms.

---

## 8. What cannot be fixed from a Mac, and how each is routed around

| Not controllable or observable | Route around it |
|---|---|
| Codec choice (macOS picks SBC or AAC; aptX gone since Monterey; ~50 ms step between them, unreported) | Catch it as a latency step at reconnect (1.4, 2.2); a USB A2DP dongle removes bluetoothd from the path entirely for users who want it |
| The sink's own buffer depth, deadband wander and per-start re-roll (70–90% of BT latency lives in a firmware buffer) | Acoustic verification on events (1.4, 1.5, 2.2); per-model profiles (2.6); keep-alive already prevents the most common re-roll |
| AVDTP delay reports (Linux reads them; macOS exposes nothing, and touching the BT HAL plugin's custom properties crashes coreaudiod) | Treat as unobservable; check telemetry for a model-dependent HAL figure as a free prior |
| The render instant on A2DP (no presentation timestamp in the protocol) | LE Audio's presentation delay gives one; reachable today only through a USB Auracast transmitter (3.1) |
| RF contention, retransmits, Wi-Fi coexistence on 2.4 GHz | Hygiene warnings and the ≤2-sink guidance (2.10) |
| A Bluetooth speaker's real acoustic level (AVRCP guarantees a 0–127 number, not loudness; some speakers advertise it and ignore it) | The mic level probe before every sweep (1.7), which works with or without AVRCP |
| Always-on separation of same-program speakers from one laptop mic | Event-driven verification plus a continuous host servo is what "continuous" should mean at launch; masked codes and the mic array stay research (Tier 3) |

The one property that makes all of this tractable: **the rate is observable where it
matters.** The sink follows what the Mac delivers, and the Mac can see and set the
delivery rate. So common-mode drift is a host-side servo problem, not an acoustic one,
and the acoustic loop only has to find each speaker's latency on events, not repair every
hole, pause, drift and restart after the fact.
