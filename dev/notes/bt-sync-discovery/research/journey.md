# Journey: how a user gets speakers into sync and keeps them there

Researcher: journey. Written 2026-09-26 against `aa-hh/Audiout` main at `add4251`,
`audiout-shared` main at `2c0eb59` (the Mac pins 0.15.1), and `audiout-remote` at
`543de22`. Read-only.

This file follows one user from first launch to months of use and asks, at each step:
what the user has to do, what the system knows and what it only assumes, where sync
can go wrong without anyone noticing, and how the user would find out. Two sibling
documents already cover ground this one relies on. I cite them and do not re-derive them:

- **Architecture:** `/mnt/project-files/sync-architecture/sync-clock-architecture.md`,
  cited as "ARCH". It covers the timebase, the room delay `R`, measurement order of
  trust (§4.1), the steady gate (§4.2), stored vs applied values and the reconnect
  rules (§4.3), passive-drift layers and the correction policy (§5.2), and gaps 1–5
  (§6).
- **Regressions across versions:** `/mnt/project-files/bt-sync-version-comparison/report.md`,
  cited as "VER". Five 1.2.0 customer bugs and whether each fix exists. None of them
  is on main.

Anything marked *inferred* is my reading of the code, not a measurement.

---

## 0. Summary

1. **"In sync" is measured at three different places, and nothing reconciles them.**
   - The phone probe aligns at the listener's seat (`ProbeAnalyzer.swift:39-45`).
   - The Mac-mic wizard aligns at the laptop.
   - The passive drift tracker compares each speaker against a *model* baseline
     (`room + trim`, `NativeBackend+Bluetooth.swift:1130-1136`), not against what the
     Mac mic heard when the room was last known good.

   So the tracker treats the difference in acoustic path from the Mac's mic to each
   speaker as error. When that difference is at least 10 ms (about 3.4 m of path
   difference), the tracker "corrects" the room toward being aligned at the laptop.
   That undoes a correct phone calibration made at the sofa, and verify-before-apply
   cannot catch it, because the second window agrees with the first (*inferred*,
   §3.7).
2. **Many Macs have no microphone the app will use.** `BuiltInMicRecorder` accepts only
   `kAudioDeviceTransportTypeBuiltIn` (`MicProbeSession.swift:231-252`). Mac mini,
   Mac Studio and Mac Pro have no built-in mic. The 2024 Mac mini spec lists speaker
   and headphone output only (https://support.apple.com/en-in/121555). A Studio
   Display's mic is USB, so it is excluded. A clamshell MacBook's mic is off.

   The phone is switched off in release builds (`AppSettings.remoteAppIsOffered =
   false`, `AppSettings.swift:396`). So on a desktop Mac, which is the natural home
   audio hub, a shipping user gets the by-ear wizard only and no drift tracking at all.
3. **Degraded sync is almost invisible on the Mac.** These states are computed but have
   no UI consumer (a grep across every UI target and the app target finds no reader):
   - the drift tracker's "I corrected ≥40 ms" notice (`btDriftCorrectionNoticeMs`,
     `NativeBackend+Bluetooth.swift:1102`);
   - its "mic has gone blind" state (`btDriftTrackingIsBlind`, `:1114`);
   - the clock verdict `moved`/stale.

   The only Mac-side degradation text is `movedNotice`, a tooltip and drawer caption
   shown after a *phone* re-measure (`BTOffsetSource.swift:59`). Most of the time the
   user's ear is the only sync-health monitor.
4. **The common "Mac speakers + one Bluetooth speaker" room gets no drift tracking.**
   The Mac's own output is not an anchor (`NativeBackend+Bluetooth.swift:1189-1191`).
   Tracking runs only with two measured BT speakers, or one plus an AirPlay speaker
   (`driftTrackingRuns`, `:1152`). A speaker aligned by ear only (trim, no measured
   latency) is never tracked (`:1130-1133`).
5. **Tracking can only see small errors.** The search window is ±120 ms
   (`PassiveDriftSampler.swift:83`). The 1.2.0 customer's 240 ms runaway (VER §1 #1)
   falls outside it. Errors under 10 ms are left alone by policy
   (`DriftCorrectionPolicy.swift:106`), and at 1–10 ms the stereo image collapses onto
   the earlier speaker (`bt-latency-stability-research-2026-09-05.md` §3). So the
   tracker can neither catch big failures nor hold "perfect".
6. **ProbeKit's DSP is not the weak link.**
   - Accuracy is well under 1 ms: 6.8 kHz of sweep bandwidth on the target lane gives
     a ~0.15 ms lobe plus parabolic interpolation, and there are about 38 dB of
     processing gain.
   - What limits the answer is where the mic is (2.9 ms/m), when the measurement is
     taken (20–90 ms re-rolls, a 0–42 s settle), stalls in the reference path, and a
     BT sweep that never arrives (VER #5).
   - One more *inferred* limit: the correlator takes the tallest peak, not the first
     arrival, so a speaker aimed at a wall can be timed by its reflection.
7. **The single most important missing piece is a sync-health loop that is closed at
   the listener.** That means:
   - a baseline captured at the moment the room was confirmed good, not taken from the
     model;
   - a measurement channel that works during music on every Mac and is attributable
     per speaker;
   - a visible per-speaker health state that tells the user when the app cannot see
     or cannot fix the room.

   Section 5 proposes one.

---

## 1. The journey as built today

Each step lists what the user does, what the system knows vs assumes, how sync
silently goes wrong, and how the user would notice.

### Step 1: first launch and permissions

**User:** works through the Setup window's cards in fixed order: system audio, local
network, Bluetooth, Speaker Sync (Login Items approval for the PTP helper), remote
control, Audiout Remote, usage stats (`SetupFlowModel.swift:146`). Speaker Sync cannot
be skipped (owner, 2026-09-07, `:154-160`). Bluetooth can be skipped.

**Knows:** each grant's real status.

**Assumes:** that a later microphone ask will be acceptable. There is **no microphone
card**. The mic is first requested inside the alignment wizard
(`MicCapturePermission.ensure`, `MicProbeSession.swift:39`). The wizard now keeps its
surface up and returns focus after the answer (commit `78bf8ee`), but the "Measure on
this Mac" panel is the first place anyone learns the app wants to listen.

**Silent sync risk:** none yet. But Bluetooth being skippable means a user who skipped
it sees only already-connected BT endpoints and cannot connect a greyed speaker
(`AudioutCore/AGENTS.md`: "Never touch IOBluetooth outside the authorization gates").

**Noticing:** n/a.

**Gap for the redesign:** the Speaker Sync card is the only onboarding moment that
talks about sync, and it only asks for the PTP helper. It never says "Bluetooth
speakers need a one-time timing check, and a microphone makes it automatic". Asking
for the mic belongs here, with a reason attached.

### Step 2: getting a Bluetooth speaker

**User:** pairs in System Settings. Pairing is Apple's; Audiout can only connect
existing pairings (`BTConnectionManager.swift:58`, "pairing itself is Apple's, one
Settings trip"). Clicking a greyed BT row's name connects it (`AudioutSharedUI/AGENTS.md`).
A powered-off speaker takes about 15.4 s to fail; after about 5 s the app suggests
Bluetooth Settings (`BTConnectionManager.swift:20-43`).

**Knows:** the paired list, the device class (headphones vs loudspeaker), and the
Core Audio UID.

**Assumes:** that the codec stays the same across reconnects. Nothing reads it:
`BTSpeakerTiming`'s `codec` closure defaults to nil, and "No `bluetoothaudiod` line
appears in this Mac's unified log over 14 days" (`BTSpeakerTiming.swift:175-181`).

**Silent sync risk:**
- A first pairing, or a speaker already connected when the app launches, used to get
  no settle window at all (`sync-sheet-wait-discovery-2026-09-04/synthesis.md` §1).
  The owner ruled it should (work-order ruling 3). `BTSpeakerTiming` now falls back to
  a 60 s floor (`:122`), so a speaker with no evidence reads *steady* after a minute
  whether or not it has settled.
- Headphones selected as a "speaker" behave like speakers with very large latency.

**Noticing:** none.

### Step 3: first mix of Bluetooth + AirPlay + local

**User:** ticks the BT speaker in the popover. By decision there is no hold: a
never-aligned speaker plays immediately, out of step (`first-mix-wizard-default-work-order.md`,
decision 1). A one-sentence note mounts under the row. Its ✕ hides it for the session
only (`AudioutPopoverUI/AGENTS.md`). The row's SYNC chip reads **Align** with a
tuning-fork glyph and opens the wizard.

**Knows:**
- the AirPlay presentation delay `S`, default 1000 ms (`AppSettings.swift:130`);
- whether AirPlay or Cast is present, which chooses the reference (`BTSyncedSink.swift:42`);
- the Mac local latency, read from the HAL formula (`LocalOutputLatency.swift:34-41`).

**Assumes:**
- that the speaker's own latency is 0, so it plays `L` late: 100–400 ms in the wild
  (`BTSyncedSink.swift:58-61`);
- that the Mac's local output lands with AirPlay because the HAL latency says so.
  Nobody measures this: AirPlay rows get no trim by decision
  (`per-device-trim-spec.md` decision 1), and the Mac↔AirPlay pair is never probed
  unless the user aligns the Mac row by ear.

**Silent sync risk:**
1. **Budget collapse when AirPlay joins.** The BT latency ceiling falls from 1500 ms
   to 500 ms (ARCH Gap 1, VER §3 #6,
   `NativeBackend+Bluetooth.swift:2468-2497`). A speaker needing more than 500 ms
   (headsets need up to 616 ms, per `handoff-2026-09-03-bt-airplay-alignment-blockers.md`)
   cannot be aligned at all. Nothing in the UI says so. The only fix is a hidden
   setting (start buffer 2250).
2. **Cast in the room.** `R` jumps to about 5.5 s and tolerates ±150 ms before
   correcting (`CastRoomDelay.swift:66-76`). That is echo-level error by the audibility
   table in `bt-latency-stability-research-2026-09-05.md` §3. Cast can never be the
   measurement partner (`CompanionSnapshotBuilder.swift:226`). Cast depth is the cast
   researcher's.

**Noticing:** immediately and loudly: a BT speaker 100–400 ms late is an echo. That is
the point of the note. The budget-collapse case looks exactly like "not aligned yet",
so the user runs the wizard and it cannot finish (Step 4).

### Step 4: the alignment wizard on the Mac

There are two panels: "Measure with your iPhone" (absent in release, because
`remoteAppIsOffered` is false) and "Measure on this Mac"
(`BTAlignmentWizardView.swift:182-227`).

**Mac-mic path:**
1. The wizard stages sweeps. A DOWN sweep (2000→500 Hz, amplitude × 0.5, −6 dB)
   plays on the engine/Mac lane, and an UP sweep (3.2→10 kHz) on the BT lane, both at
   amplitude 0.175 (≈ −15 dBFS) riding the device volume
   (`AlignmentTickInjector.swift:442-489`). A staggered shape exists for BT-vs-BT
   pairs (`:404-420`).
2. It captures on the built-in mic and reduces the capture to Δ.
3. The result becomes the wizard's *proposal*, and the user confirms it by ear
   (`mic-probe-calibration-brief.md` step 2). A rejected measured proposal gets "Try
   again" once, then falls to by-ear questions (`Sources/AudioutCore/AGENTS.md`).

**By-ear path:** a Bayesian posterior over paired clicks at about 72 BPM, "Click n of
about 15" (`BTAlignmentWizardView.swift:138`). About 15 answers is the
information-theoretic floor (`mic-probe-calibration-brief.md`).

**Knows:** the arrival difference *at the Mac's mic*, and the correlator's confidence.

**Assumes:**
- **The reference is right.** The reference is the Mac's own output when it is
  audible, then any non-BT device, then anything else
  (`CompanionSnapshotBuilder.swift:220-231`). While the MacBook speakers play, the BT
  speaker is aligned to them and never to AirPlay. Any Mac↔AirPlay disagreement is
  inherited whole (`handoff-2026-09-03-...blockers.md`, "Where the reference comes
  from").
- **The laptop is where the listener is.** With the Mac mic, the Mac speaker is about
  0.1 m away and the BT speaker is d metres away, so the measurement bakes in
  (d − 0.1) × 2.9 ms. At a listener who is equidistant, the correct offset differs by
  that amount. Example: BT speaker 4 m from the desk and 2 m from the sofa, Mac
  speakers 3 m from the sofa. The Mac-mic answer is off by about 11.3 − (5.8 − 8.7)
  ≈ 14 ms at the sofa (*inferred arithmetic*). The copy says "listening through its
  built-in microphone" and never "sit at your Mac".
- **The BT sweep arrived.** If it did not (volume down, HFP collapse, dropout), the
  pre-1.2.0-fix correlator could lock onto the loudest pre-sweep sound and return
  −778 to −3748 ms at confidence 5.9–7.9, shown as "implausible". The fix `2977e56` is
  unmerged (VER §1 #5).

**Silent sync risk:**
- The "Moved" and "stale" states are not rendered here. A Keep made while the clock
  was settling is stored and marked `firstPass`/stale only on the wire, where the
  phone can see it and the Mac row cannot (§3.8).
- A Mac-mic measurement is labelled `byEar` ("Aligned by ear on this Mac"), because
  only phone reports go through `recordMeasurement` (`BTSpeakerTiming.swift:280-310`).
  That is harmless for sync, but it means field data cannot separate Mac-mic results
  from ear results.
- A refused forward seek is persisted anyway (VER §1 #2), so the speaker returns
  205 ms off on the next reselect.

**Noticing:** the by-ear confirm step catches gross errors (it sounds wrong). Errors of
10–20 ms usually pass the confirm: 1–10 ms fuses into a shifted image, and 10–20 ms
is where transients only start to thicken (research note §3).

**Known failure, reported by the owner (crosstalk 2026-09-26 00:46):** on a freshly
connected Bluetooth speaker, running the sync produces **no sound from that speaker at
all**. It works only after the user has played ordinary audio to the speaker once and
paused it. Another thread is diagnosing this, so it is not root-caused here.

For the journey, what matters is that the first sync on a new speaker is exactly the
moment the product most needs to work, and this failure looks like one of two things:
- **Mac mic:** a measurement that "couldn't find the alignment" (BT sweep missing). On
  builds without `2977e56`, it can instead look like an "implausible" dead end (VER #5).
- **Phone:** the confirm clicks are simply absent from one speaker.

The user has no way to know that play-then-pause is the workaround. The redesign
(§5.4 step 3) makes the first measurement follow a confirmed-audible step, which would
also expose this failure as "the speaker isn't playing yet" instead of a failed
measurement.

### Step 4b: the iPhone companion (dev and TestFlight only today)

**User:** opens the sync sheet on the phone and works through these pages:
1. Both speakers playing.
2. Allow the microphone.
3. "Stand where you usually listen. Hold this iPhone still." (`SyncSheetCopy.swift:185-201`)
4. Start.
5. The sweeps play, the reading comes back, and the user confirms with clicks:
   "Sounds right", "Try again", or "Align by ear".

Start is live only when the Mac says the clock is steady.

**Knows:** the arrival difference *at the listener*. This is the only place the product
measures what it claims to optimise.

**Assumes:**
- the user really is at the seat. ProbeKit states it cannot tell
  (`ProbeAnalyzer.swift:39-45`);
- the confidence is real: the phone floor is 25 (`AlignmentRunController.swift:149`),
  but the Mac accepts any finite value of 0 or more (VER §3 #5);
- the reference tone reached AirPlay: 222–232 ms send stalls are undiagnosed
  (VER §3 #7).

**Silent sync risk:** the phone measurement is a *one-off at one seat*. The Mac-mic
tracker that follows (Step 7) does not inherit the phone's geometry. It inherits the
model (`room + trim`), so the phone's listener-position answer can be walked back
toward the laptop's answer (§3.7).

**Noticing:** the verdict page shows the reading. After that there is nothing.

### Step 5: per-device trim UI

**User:** a measured chip opens the drawer: a SYNC stepper (±500 ms, 1 ms steps, fine
steps at 0.1 ms), "Align again…" and "Align by ear" (metronome). The Mac's own row has
the same SYNC control bound to `AppSettings.syncOffsetMs` (`per-device-trim-spec.md`
Part 1). AirPlay rows have none.

**Knows:** the user's intent.

**Assumes:** that the value typed is the value applied. It is not, whenever the sink
clamps a forward seek (VER §1 #2, `BTSyncedSink.swift:1062-1106` logs
`bt_sink_seek_clamped` and the store saves anyway).

**Silent sync risk:** a trim-only speaker drops out of drift tracking
(`NativeBackend+Bluetooth.swift:1130-1133`). The user who fixes things by ear is also
opting out of automatic maintenance, and nothing tells them.

**Noticing:** by ear only.

### Step 6: reconnect, sleep/wake, relaunch (ADR 0001)

**User:** does nothing. The stored latency goes back on the sink and the row says
"Timing from last time" (ADR 0001; ARCH §4.3).

**Knows:** the last latency, and the pacing-clock verdict (unknown/settling/steady).

**Assumes:** the re-roll is small. Research puts it at 20–90 ms per stream start,
about 60 ms of warm-up on Apple's stack over 20–30 min, and 70–90 ms Game-Mode steps
(`bt-latency-stability-research-2026-09-05.md` §1–2). Live: "a relaunch/reconnect
re-rolled one link by ~10 ms" (`.scratch/passive-drift-tracking/HANDOFF.md`).

**Silent sync risk:** with the phone unavailable (release), the ADR's re-check offer
has no surface to appear on. The Mac never offers a re-check. The mic tracker fires a
window 15 s after a reconnect (`PassiveDriftSampler.swift:408`), but only in the rooms
where it runs (Step 7).

**Noticing:** a 20–40 ms re-roll thickens drums. A user who hears it has to open the
drawer and choose "Align again…". No state tells them *this speaker, just now*.

### Step 7: passive drift correction during music

This is ARCH §5.2; I do not repeat its mechanics. From the user's side:

**User:** nothing. The mic indicator lights a few times per session: 3 min after
tracking starts, then every 25 min (`:398-401`), plus event windows.

**Preconditions a user cannot see:**
- a built-in mic that is open and awake (the lid is open);
- at least two BT speakers with *measured* latencies, or one plus an AirPlay speaker;
- music with treble above the mic floor. The live finding was that 1–8 kHz sat at
  −50 to −59 dBFS and the plain filter never resolved a peak (HANDOFF, live test 3);
- the Mac not moved since calibration (§3.7).

**Knows:** the arrival lag of each peak relative to the retained mix.

**Assumes:** the model baseline (`room + trim`) is where each speaker "should" arrive
at the Mac mic. It is not: it lacks each speaker's acoustic path to the mic (§3.7).

**Silent sync risk:**
- 1.2.0 windows scored under 1 against a gate of 3 in the customer's room (VER §3 #4).
- End-to-end correction has never been proven live (VER §3 #4; HANDOFF owed item 2).
- The ±120 ms search misses large runaways.
- After five unusable windows the tracker goes **blind** and stops, and nothing
  renders that (`PassiveDriftSampler.swift:79, 149-164`; no UI consumer).

**Noticing:** none. A correction of 40 ms or more sets `surfacedMs`, which nothing
reads.

### Step 8: months of use

**User:** the product holds per-UID latency and trim in `bt-sync-trims.json`.

**Knows:** one stored number per speaker, plus a label for where it came from. The
source label lives in memory only and resets at launch (`BTSpeakerTiming.swift:20-25`).

**Assumes:** that speaker firmware updates, a new macOS (codec or stack changes, for
example Game Mode or AAC→SBC), a moved speaker, and a new room layout all leave the
number valid.

**Silent sync risk:** nothing ages a calibration. There is no "measured 94 days ago on
macOS 26.3", and no per-model seed learned from accepted results. Step 3 of
`mic-probe-calibration-brief.md` ("seed database") is not built.

**Noticing:** only by ear, and by then the user has probably blamed Bluetooth rather
than the app.

---

## 2. What the user can actually see about sync health today

| State (computed) | Where it is computed | Rendered on Mac? | Rendered on phone? |
|---|---|---|---|
| Never aligned | trims store has no entry | Yes: Align chip + session note | Yes: "Timing not set" |
| Source (measured / firstPass / fromLastTime / byEar) | `BTSpeakerTiming` | Tooltip and drawer caption only (`BTOffsetSource.swift:33-50`) | Yes |
| Stale: measured while settling | `BTSpeakerTiming.swift:96-108` | No *(inferred: no UI reads `staleReason`)* | Yes |
| Stale: clock moved ≥10 ms since alignment | `BTSpeakerTiming.swift:125` | No | Yes |
| Re-measure moved >40 ms | `movedNotice` | Tooltip/drawer, session only | Yes |
| Drift corrected ≥40 ms | `DriftCorrectionApplier.swift:181` | **No consumer** | No |
| Drift tracker blind | `PassiveDriftSampler.isBlind` | **No consumer** | No |
| Drift tracking off (preconditions unmet) | `drift_tracking_state` log | No | No |
| Seek clamped / trim refused | `bt_sink_seek_clamped` log | No | No |
| Budget exceeded (L > R) | clamp in `SyncTiming.totalDelayNanos` | No | No |
| Bad link (clock-step storm) | `bt_clock_jump` storm marking (VER §2) | No | No |
| Cast refused for sync (>9.5 s) | `CastRoomDelay` | *(not checked; cast researcher)* | — |

Outcome: the product has good internal telemetry and almost no external sync-health
signal. That follows from the "no nagging" rulings (spec decision 9: "stop sampling
quietly and show a small status note"), but the small status note was never built.

---

## 3. Failure modes and gaps, with numbers

### 3.1 ProbeKit measurement limits

| Limit | Value | Evidence |
|---|---|---|
| Timing resolution, target lane | 3.2–10 kHz, B ≈ 6.8 kHz; main-lobe width ~1/B ≈ 0.15 ms; parabolic sub-sample interpolation | `SyncProbeCorrelator.swift:77-82`; `drift-tde-algorithms-brief.md` §6 |
| Timing resolution, reference lane | 500–2000 Hz, B = 1.5 kHz → ~0.7 ms lobe | `:86-89` |
| Processing gain (1 s sweep) | 10·log10(B·T): ≈ 38 dB (UP), ≈ 32 dB (DOWN) (*computed*; the file says "30–40 dB") | `:31-35` |
| Lane isolation | disjoint bands, cross-correlation −134 dB; up/down over a shared band only −33 dB | `:37-50` |
| Level budget | 0.175 FS ≈ −15 dBFS × the device's own volume; no normalisation; a quiet or far speaker loses margin | `AlignmentTickInjector.swift:489`; mic-probe brief "rides the device's own volume" |
| Confidence | background-expected peak ratio; noise ≈ 1; good runs 1668–3425; phone floor 25; Mac-mic path correlator floor 5 | `SyncProbeCorrelator.swift:180`; `AlignmentRunController.swift:149`; blockers handoff table |
| Echoes | background excludes a 250 ms post-peak shadow; median background, so reverb does not deflate the score | `:185-195` |
| Direct vs reflected | the peak is the *largest* lag, not the *first*. A speaker firing into a wall or corner, or across the room with its back to the mic, can present a stronger reflection than the direct path. Error = extra path × 2.9 ms/m, typically 1–5 ms, bounded by the 5 ms sidelobe exclusion (*inferred*: no first-arrival logic found by grep) | `SyncProbeCorrelator.swift` |
| Acoustic distance | 2.9 ms/m (343 m/s). Phone: the listener's own distances, which is correct. Mac mic: the laptop's distances, which are wrong for anyone not at the laptop. Neither accounts for multiple seats. | `ProbeAnalyzer.swift:39-45`; `per-device-trim-spec.md` "Out of scope" reversal |

**BT codec low-pass vs sweep bands:**
- A2DP SBC and AAC as macOS negotiates them normally pass audio to about 16–20 kHz.
  The mic-probe brief assumes a 14–18 kHz roll-off, so the 10 kHz ceiling is
  deliberately safe.
- **HFP is the real threat.** If the BT device drops to HFP (a CVSD or mSBC voice
  link), the link carries 300–3400 Hz or up to about 7 kHz. The UP sweep (3.2–10 kHz)
  then loses most or all of its band, and the reading fails. That is the correct
  outcome: refusal, not a wrong number.
- The app pins the *built-in* mic precisely to avoid triggering HFP
  (`MicProbeSession.swift:70-75`). But "does A2DP survive while the built-in mic
  records" is listed as still owed on hardware (`mic-probe-calibration-brief.md`,
  constraints).
- The HFP pass-band figures above are the standard CVSD/mSBC numbers from general
  knowledge, not a primary source fetched here. The bluetooth researcher should
  confirm them.

**Passive correlator band:** 300 Hz–8 kHz with four voting sub-bands; 2-of-4 must agree
(0.15.1); whitening exponent 0.7; ±120 ms search; 4 s windows
(`PassiveDriftCorrelator.swift:258-280`; HANDOFF). Live: true arrivals scored 2.5–2.9
unwhitened. Whitened plus gates accepted three live windows within 1 ms. A labelled
+40 ms jump read back as 39.2 ms.

**SNR regime:**
- The chirp path works at normal volume.
- Passive tracking is limited by the program's treble reaching the mic, not by the
  DSP. Normal listening level at the Mac was about 50 dBA, and the 1–8 kHz band sat at
  the mic floor (HANDOFF, live test 3).

### 3.2 The timing of a measurement

- **Settle:** pacing-clock jumps run for 0–42 s after link-up (Sonos Move 2), or none
  at all (Sony XM3) (`bt-spike-findings-2026-08-07.md`). The steady gate is 10 s
  without a jump, falling back to the 60 s floor (ARCH §4.2).
- **Re-rolls:** 20–90 ms per stream start. The keep-alive prevents re-rolls through
  silence for 10 min by default, with options 0/5/10/30 (`AppSettings.swift:242-246`).
  After that, one re-roll is accepted on the next play.
- **Apple warm-up:** about 60 ms over 20–30 min (AirPods; forum measurement). No
  window is scheduled for it beyond the 25-minute periodic check.

### 3.3 The reference is not what the user thinks

The measurement partner is the Mac's speakers whenever they play
(`CompanionSnapshotBuilder.swift:228`). So "aligned" means aligned to the MacBook.
MacBook vs AirPlay is trusted from the HAL formula, and AirPlay receivers are never
trimmed (`per-device-trim-spec.md` decision 1). Nothing on screen names the partner
outside the wizard's "Compare against {name}".

### 3.4 Budget collapse

This is ARCH Gap 1 and VER §3 #6. Journey consequence: the wizard runs, proposes, and
its Keep is clamped. The user hears no change, re-runs, and gets the same answer. It is
the most confusing possible failure. The copy "Couldn't find the alignment…"
(`BTAlignmentWizardView.swift:110`) blames the user's position.

### 3.5 Refused trims persisted

VER §1 #2. Journey consequence: sync is fine now and wrong *next time*. The delay
between cause and symptom makes it effectively undiagnosable for a user.

### 3.6 Sink never re-times after release

VER §1 #1 (`ed6f00a`, unmerged). This is the 240 ms runaway. It sits outside the
tracker's ±120 ms search, so even a working tracker would not see it.

### 3.7 The drift baseline is a model, not an observation (new here)

This is *inferred from code*, but the chain is short:

1. The BT baseline is `roomMs + trim` (`NativeBackend+Bluetooth.swift:1130-1136`).
2. An AirPlay anchor's baseline is `room` (`:1192`).
3. The sampler subtracts the anchor's deviation as the mic offset (`PassiveDriftSampler.swift:236-238`).
   Without an anchor, it rebaselines only when *every* BT deviation shifts by the same
   amount, within 5 ms (`:222-232`).
4. What survives into `errorMs` for speaker i is therefore
   `(acoustic_path_i − acoustic_path_anchor)/c` plus any genuine latency error.
5. Nothing ever measures the geometry term and folds it into the baseline. The merged
   rule (decision 14) does, but only for speakers that arrive within one peak.

Consequences:

- **The laptop's geometry is written into the room.** If the Mac mic's path to BT
  speaker A is 3.4 m or more longer than its path to the anchor (≥10 ms), the policy
  "corrects" A earlier by that amount. After the second agreeing window it slews
  (ARCH §5.2). If the user had calibrated at the sofa with the phone, this pulls A off
  the sofa-correct value toward laptop-correct. Verify-before-apply does not help: the
  geometry is stable, so the verify window agrees.
- **Moving the laptop moves the room.** Carrying a MacBook from desk to sofa changes
  each speaker's path by a *different* amount. Deviations spread by more than 5 ms read
  as independent jumps, not a common shift. A 2 m move toward one speaker and away
  from another spreads the deviations by up to 11.6 ms, which crosses the 10 ms line
  and triggers false corrections. With an AirPlay anchor, only the common part is
  removed.
- **Under 10 ms, the error is permanent and unmeasured.** Differential paths below
  3.4 m sit under `ignoreBelowMs` and are neither corrected nor recorded as a baseline
  offset. The system cannot distinguish "the room is fine" from "the room is 9 ms off".
- **Why live tests did not show this:** two Moves placed near-symmetrically about the
  Mac, and the merged rule absorbed in-sync arrivals (HANDOFF live test 2, defect 1).

Fix direction (§4, option A): capture the baseline acoustically, at the moment the
room was confirmed good.

### 3.8 Invisible degradation

See the table in §2. Also:
- The Mac row cannot say "stale". The phone can.
- The Mac never offers "Check timing again" after a reconnect, which is the ADR's
  intended recovery. That recovery lives only on the phone.

### 3.8b Sweep level: nothing makes sure the mic can hear the speaker (owner requirement 2026-09-26)

**How the app detects real volume control today:**
- A BT speaker is `btHardwareVolumeCapable` when two things hold:
  - Core Audio's volume property is present and settable
    (`BTHardwareVolume.isControllable`, `BTHardwareVolume.swift:67`);
  - the cached AVRCP Target SDP record claims absolute volume, meaning AVRCP ≥ 1.4 or
    the category-2 bit 0x0002 in attribute 0x0311 (`BTAbsoluteVolumeSDP.claim`,
    `BTAbsoluteVolumeSDP.swift:21-57`).
- Evaluated in `reevaluateBTHardwareControlLocked` (`NativeBackend+Bluetooth.swift:29-79`).
- A missing SDP verdict (no grant or no cached record) falls back to settable-only
  (`btSDPClaimByUID[uid] ?? true`, `:39`).
- A failed hardware write demotes the speaker to software gain for the session
  (`noteBTHardwareWriteFailedLocked`, `:113-119`).
- The user can opt out per speaker (`BTHardwareVolumeStore.isEnabled`).
- The research note's second discriminator, the n/127 read-back signature
  (`bt-absolute-volume-detection.md` finding 3), is **not implemented** (grep finds no
  127 check). Neither is the only end-to-end proof: the speaker-button listener round
  trip (finding 5).
- **Limit:** a speaker that advertises category 2 and ignores SetAbsoluteVolume passes
  every check (finding 4). The detection is a claim check, not proof that the level
  reaches the air.

**What the calibration does with level today: nothing.**
- The sweeps are fixed at 0.175 FS (≈ −15 dBFS), with the Mac lane a further −6 dB
  (`AlignmentTickInjector.swift:481-489`).
- They are mixed into the feed *before* the Bluetooth sink. So, *inferred* from
  `btSinkGain` (`NativeBackend.swift:3052-3060`), the sweep is scaled by the software
  gain like any audio:
  - **Main × device level** for a software-volume speaker;
  - **Main alone** for a hardware-controlled one, with the speaker's own hardware
    volume then applying on the speaker.
- A user at Main 30% and speaker volume 20% therefore plays the sweep about 24 dB
  quieter than one at 100%/100%.
- The mic-probe brief states this by design: "The probe rides the device's own volume.
  Nothing normalises it … the option is briefly standardising output volume for the
  sweep the way an AVR's room calibration does; it is NOT built, and it needs its own
  UX decision" (`mic-probe-calibration-brief.md`, plan step 1).
- No pre-sweep level check exists: `MicProbeSession` has no level or RMS gate before or
  during capture (grep). A too-quiet speaker surfaces only *after* the run, as a
  low-confidence refusal. The copy blames position: "Try moving closer to the
  speakers" (`BTAlignmentWizardView.swift:110`).
- The phone (`ProbeCaptureSession`) pins its own input gain to maximum
  (`ProbeCaptureSession.swift:136`) but does nothing about the speaker's output level.
- **The worst case:** the speaker is quiet enough that the BT sweep is missing, and the
  loudest pre-sweep sound wins. VER #5 is exactly this: the customer's readings scored
  5.9–7.9 while a real reading scored 42.

**Proposed flow: "make it audible, measure, restore"**, in two branches. Both start
with a **level check before the sweep**. That check is cheap because the Mac already
has what it needs:
1. Play a 300 ms quiet noise burst, or the first 300 ms of the UP sweep, on the target
   lane alone.
2. Capture on the same mic.
3. Compare the in-band energy (3.2–10 kHz) of that window with a 300 ms ambient window
   taken just before.
4. Require an in-band SNR of at least 15–20 dB. That is a *proposed* number. It is set
   below what the correlator's 38 dB processing gain can recover, so the sweep will
   then score far above the phone's floor of 25.
   *Needs:* a small ProbeKit function (band energy ratio, pure DSP) and a Mac staging
   step before `stageProbe`.

**A. Hardware volume control available** (`btHardwareVolumeCapable`, not opted out):
1. Record the speaker's current hardware level and the Main level.
2. If the level check fails, raise the **speaker's hardware volume** in steps (for
   example +6 dB-equivalent steps up to a cap), re-checking level after each step. Stop
   at the first pass. The cap is a product decision: 70–80% of hardware range is a
   reasonable start, because the sweep is a chirp next to the user (the "heavy static"
   complaint).
   - Raise hardware, not Main: Main moves every speaker and the sink's software gain.
   - Hold Main's software term at unity **for the sweep lanes only**, by injecting the
     sweep after the gain stage or dividing it out.
3. Run the sweep pair.
4. **Restore the exact prior hardware level**, using the echo-suppression machinery
   that already exists (`BTHardwareVolume.isEcho`) so the restore does not read as a
   user gesture.
5. If the user presses the speaker's own buttons mid-run (the listener fires), abort
   the raise, keep their level, and continue at that level. Their gesture wins.
6. If a raise does not change the measured level (the advertised-but-fake case), mark
   the speaker "hardware volume not delivered" for the session and fall to branch B.
   This is the round-trip proof the detection note says only a behavioural test can
   give.

**B. No hardware control** (software volume, fake absolute volume, or opted out):
1. The Mac can only raise the digital level it sends. For the sweep lanes, bypass the
   device's software gain: sweep at 0.175 FS regardless of the row's volume, since the
   sweep is injected before the gain today.
   - If the level check still fails, ask the user in one line with one action: "Turn up
     the {name} on the speaker itself, then Check again." Show a live level meter from
     the mic while they do, so they can see the bar cross a mark.
   - Never raise the digital sweep above its current amplitude. That is the rejected
     "near-full-scale" path.
2. After two failed checks, offer the phone ("Measure from your seat") or by-ear. The
   by-ear path's clicks need the same audibility, so show the same meter on its intro.

**Both branches:**
- The pre-check makes a missing sweep a *named* failure ("the {name} is too quiet for
  your Mac to hear") before any number is computed. That closes VER #5's class of
  confident wrong answer at the source, independent of the `2977e56` search-window fix.
- It also catches the owner's first-sync silent-speaker failure (Step 4) as "not
  audible" rather than as a failed measurement.

**What it needs from code and hardware:**
- ProbeKit: an in-band SNR helper.
- Mac:
  - a pre-sweep stage in the wizard and the phone-driven run (the phone run needs a
    wire message to show the "turn it up" page; additive command);
  - a hardware-volume raise/restore on `btHardwareVolumeControl` with a cap;
  - a sweep path that bypasses the per-device software gain.
- Hardware tests:
  - the n/127 read-back and the raise/restore on the Moves;
  - one known software-volume speaker, to confirm the negative case;
  - one "fake absolute volume" speaker if one can be found.
- Analytics: `bt_sync:level_check_ended` with `result`, `branch` and `steps` enums, no
  names.

### 3.9 Hardware coverage

| Mac | Built-in mic the app accepts | Mac-mic wizard | Passive tracking |
|---|---|---|---|
| MacBook Air/Pro, lid open | yes | yes | yes, if preconditions hold |
| MacBook in clamshell | no (mic off) *(inferred)* | falls back to by-ear | blind |
| iMac | yes | yes | yes |
| Mac mini / Studio / Pro | **none** | by-ear only | **never** |
| any Mac + Studio Display or USB mic | the external mic is rejected (transport ≠ built-in) | by-ear only | never |

This coverage is combined with `remoteAppIsOffered = false`, so the phone is not
available in release.

### 3.10 Trim-only speakers opt out of tracking

See Step 5. A user who never had a mic reading (mini, denied mic, noisy room) is
exactly the user who needs maintenance most, and gets none.

---

## 4. Options, per gap

| # | Option | Gap | Feasibility | What it takes | Risk |
|---|---|---|---|---|---|
| A | **Acoustic baselines.** At every accepted calibration (phone or Mac mic), or on a user "Sounds right", run one passive window. Store each speaker's *observed* Mac-mic arrival as its baseline. Later, track deviation from that observation, never from `room + trim`. | 3.7 | High. The sampler already has `setBaselines`; the tracker already takes windows on demand. | Mac: a `captureBaselineWindow()` after Keep/verdict; persist per-UID baselines keyed to a "Mac position epoch"; drop the model baseline except as the search centre. | A bad first window becomes a bad baseline. Mitigate with two agreeing windows (the same 1.5 ms rule). |
| B | **Mac-position epoch.** Detect that the laptop moved: lid close/open, power source change, Wi-Fi BSSID/RSSI step, a change in the built-in-mic noise spectrum. Mark acoustic baselines invalid, capture new ones only after a phone check or when all peaks shift together. | 3.7 | Medium. The signals are cheap; none is certain. | Mac: a heuristic epoch counter; baselines carry it. | False "moved" signals cause re-baselines. That is harmless: it re-anchors and never corrects. |
| C | **Surface sync health** (Section 5.3). | 3.8 | High. Most states already exist. | UI: consume `btDriftCorrectionNoticeMs`, `btDriftTrackingIsBlind`, stale reasons, seek-clamped and budget-exceeded; one per-row glyph plus one popover line. | Nagging. Spec decision 9 asks for a *small* note; keep it glanceable. |
| D | **Accept any input device for the mic,** with measured capture-latency handling. The difference method cancels capture latency, so external or USB mics (Studio Display, webcams) work for chirps and passive tracking. Exclude any device whose transport is Bluetooth (the HFP trap). | 3.9 | High for chirps. Passive tracking needs `firstSampleHostNanos` accuracy only to within the ±120 ms search, and the anchor absorbs it. | Mac: relax `builtInMicrophoneID()` to "not Bluetooth, not an aggregate that contains a BT input". | A USB mic's clock differs from the output clock (ppm), so over 4 s that is negligible. Low risk. |
| E | **Budget sized to the room** (ARCH Gap 1 recommendation) plus a user-visible "this speaker is too slow for AirPlay at this buffer" when the owner picks the fixed-S branch. | 3.4 | Medium | ARCH §8.1 decision | One gap in the whole house on `R` change |
| F | **Refuse-then-don't-persist:** persist the *applied* trim, not the requested one. | 3.5 | High | VER #2 fix | none |
| G | **Tracker search width follows the clock.** Widen from ±120 to ±400 ms when a clock-step storm or re-time event fires (the prior from ticket 14). | 3.6 | Medium | Mac: `searchHalfWidthMs` from the pacing-clock prior | More false lobes. The gates and verify are already there. |
| H | **Track trim-only speakers.** After a by-ear Keep, capture an acoustic baseline (option A). A trim-only speaker then gets a real observed baseline and no longer needs a measured latency. | 3.10 | High once A exists | Drop the `latencies[$0] != nil` filter when an acoustic baseline exists | none new |
| I | **Calibration age and context:** store `measuredAt`, macOS build, codec (once readable), and source persistently. Show "Measured in May" in the drawer. After an OS update or 90 days, schedule one passive verify rather than asking the user. | Step 8 | High | store fields plus one trigger | none |
| J | **Per-model seed.** Use the anonymised accepted latency per device-class/model, crowd median from the licence server (deferred in ADR 0001) or local-only, as the opening value, so a first mix starts about 30 ms off instead of 100–400 ms off. | Step 3 | Medium; needs a data policy | server table + analytics consent | privacy fence: a model string is not a device name, but check PRODUCT.md |
| K | **Continuous inaudible probe** (Section 5.2). | 3.1, 3.6, 3.7, attribution | Medium-low; needs an owner reversal of spec decisions 1/7 ("no injected probe", "no watermarks") | ProbeKit: PN-sequence synthesis + psychoacoustic shaping; Mac: per-lane injection | audibility, codec mangling, owner ruling |

---

## 5. Redesigned journey: sync established automatically, kept continuously

Design goal: **the user never has to think about sync unless the app cannot fix it, and
then the app says exactly what it needs.** Four pieces, in dependency order.

### 5.1 One notion of "in sync": at the listener, carried by the Mac

- **Establish at the listener once.** The phone probe at the seat is the gold
  standard. The Mac-mic wizard is the fallback, relabelled honestly: "Measuring from
  your Mac. For the best result, measure from where you sit."
- **Carry it with the Mac.** Right after a listener-position calibration, take one
  passive window, or a staged chirp window if music is off, with the **Mac's** mic and
  store what the Mac heard as the acoustic baseline (option A). This captures the
  laptop-to-speaker geometry *as it was when the room was correct at the seat*. From
  then on the Mac tracks deviations from that state. It never tries to align the room
  at itself.
- **Listener position is solved this way**, without localising the listener: the
  phone defines "good", and the Mac records what "good" sounds like from where the Mac
  sits.
- The same trick covers multiple seats: calibrate the compromise seat once, and the
  Mac keeps that compromise.
- **Needs:**
  - Mac: an acoustic-baseline store keyed per UID and per Mac-position epoch (option B);
  - a wire message so a phone verdict triggers the Mac's baseline capture (additive
    `CompanionCommand` case, no protocol version bump per audiout-shared rules);
  - ProbeKit unchanged.

### 5.2 A measurement channel that works during music, on every Mac, per speaker

**Today:** music-as-probe (whitened, gated) cannot say *which* speaker moved without a
prior baseline, and at normal level it is often below the mic floor in 1–8 kHz.

**Proposal, in three tiers (use the first that is available):**

1. **Program audio** (what exists), with acoustic baselines (5.1) and a widened search
   on clock events (option G).

2. **Per-speaker spread-spectrum "fingerprint", psychoacoustically masked.** This is
   the novel piece.
   - Each BT lane gets its own low-level pseudo-noise sequence: a maximal-length or
     Gold code, different per speaker, spectrally shaped under the music's masking
     threshold and confined to about 1–8 kHz. This is spread-spectrum audio
     watermarking (Kirovski and Malvar, IEEE TSP 51(4), 2003,
     https://www.microsoft.com/en-us/research/wp-content/uploads/2016/02/KirovskiMalvarTSPApr03.pdf)
     used for ranging, as BeepBeep did with audible chirps (Peng et al., SenSys 2007,
     https://dl.acm.org/doi/10.1145/1322263.1322265).
   - A code correlated over 4 s gains 10·log10(B·T) ≈ 10·log10(7000·4) ≈ 44 dB, so a
     code 25–30 dB below the program still yields a clean peak at the mic.
     *Computed*; real masking margins with A2DP AAC/SBC re-encoding need a test, because
     perceptual codecs are designed to discard content below the masking threshold. A
     code tuned just under the threshold may be partly removed by the codec itself, so
     the working point is "just audible as faint hiss in quiet passages", which is
     exactly the owner-ruling risk.
   - **What it buys:**
     - **attribution:** each speaker is its own peak, so "which moved" is answered by
       the signal, and verify-before-apply stops needing a second window for guesses;
     - **works in quiet passages and between tracks** (the code can run over the
       10-minute keep-alive silence at a floor level);
     - **works for BT-vs-BT in one sink fan-out** (each sink carries its own code
       after the per-sink split in `NativeCaptureCoordinator.deliver`).
   - **Conflicts:** spec decisions 1 and 7 and the drift ensemble brief §7 ("No
     per-speaker signal tweaks … no watermarks … no injected probe during playback").
     **Owner reversal required.** Offer it as an opt-in "Continuous sync" setting
     before the owner rules on a default.
   - **Ultrasonic is not an option for Bluetooth.** A2DP may cut at 14–18 kHz, as the
     mic-probe brief itself notes, and MacBook mics are not specified above 20 kHz.
     Keep the code in the audible band and hide it by masking.

3. **Event-scheduled mini-chirps.** At moments the user already accepts a sound, play
   a 150 ms branded sweep pair and correlate it: speaker connect, the "Sounds right"
   tap, wake from sleep with the app already playing. The owner accepted a branded
   chirp on connect (`mic-probe-calibration-brief.md`: "A short branded chirp on
   connect is the accepted UX (AVRs trained everyone)"). It is not built. Build it for
   the reconnect case. This is ADR 0001's re-check without the phone.

**Mic coverage:** option D (any non-Bluetooth input), plus the phone as a background
sensor:
- The iPhone companion is barred from background mic capture by design (spec
  decision 3; no background audio mode). HomePod and other smart speakers give third
  parties no mic access, so they cannot stand in either.
- The realistic answer for desktop Macs is a cheap USB mic or a Studio Display mic
  (option D), or the phone's manual re-sync button (ticket 07, untouched).

**Needs:**
- ProbeKit: code synthesis, a masking-shaped injector spec, and a multi-code
  correlator. This is pure DSP, which fits the "pure DSP" rule. The masking model is
  the hard part.
- Mac: per-sink code injection after the fan-out, below the EQ, bypassed when
  "Continuous sync" is off; a live test on AAC and SBC to measure code survival.

### 5.3 A "sync health" signal the user can read

One per-speaker state, one word, glanceable. It follows the Dante precedent the
sync-sheet discovery found (a per-device clock lamp), not a dashboard.

| State | Meaning | Mac row | Popover footer line | Action offered |
|---|---|---|---|---|
| **Locked** | Measured, acoustic baseline fresh, last window agreed within 5 ms | quiet (nothing drawn) | — | — |
| **Settling** | Clock stepping after connect | subtle pulse on the SYNC chip | — | none: wait is automatic |
| **Adjusting** | Correction slewing | chip shows "→ 23 ms" transiently | — | — |
| **Corrected** | ≥40 ms correction landed | chip dot plus tooltip "Re-timed by 52 ms after reconnect" | "Adjusted {name}" once | "Undo" (revert latency) |
| **Unverified** | No window has confirmed since reconnect / OS update / 90 days | hollow dot | — | "Check now" (mini-chirp) |
| **Can't hear** | Tracker blind (lid shut, mini with no mic, wrong room) | none per row | "Audiout can't hear your speakers, so it can't keep them in time." | "Check with iPhone" / "Choose microphone…" |
| **Can't fix** | Budget exceeded, trim clamped, bad link (clock storm), Cast refused | red-free warning glyph | names the cause | "Raise start buffer" / "Reconnect {name}" |

The data already exists for most rows: `BTSpeakerTiming.ClockState`, `Source`,
`staleReason`, `surfacedCorrectionMs`, `isBlind`, `bt_sink_seek_clamped`,
`bt_clock_jump` storm marking, and `CastRoomDelay.Settlement.refused`. Missing:
- the budget-exceeded check (`L_i > R + t_i`, a trivial comparison);
- an "Unverified" age;
- an `OutputBackend` path from these values to the UI. Today they are `NativeBackend`
  publics with no protocol requirement, which is why the UI never grew consumers
  (*inferred*).

**Analytics** (per CLAUDE.md, names in `audiout-shared/docs/analytics-events.md`
first): `bt_sync:health_changed` with `state` enum and `transport` enum, no names or
UIDs.

### 5.4 The redesigned journey, step by step

1. **Onboarding.** The Speaker Sync card grows one line and one ask: "Audiout listens
   briefly through your Mac's microphone to keep Bluetooth speakers in time. Nothing
   is recorded or sent." The mic prompt goes here. On a Mac with no usable mic, the
   card says so and offers "Use a USB microphone" or "Use iPhone later".
   *Needs:* SetupFlowModel step; mic availability probe (option D).
2. **Pairing and first connect.** When a BT speaker connects, the app shows it as
   *Settling* while the clock steps. The row plays muted, or at the seed latency
   (option J), instead of 100–400 ms late (this reverses first-mix decision 1 for the
   seeded case only: it plays in near-sync from the first second).
3. **Automatic first measurement.** Once steady, the app first runs the audibility
   check and, where it can, the hardware-volume raise (§3.8b). Then it plays one 1 s
   branded sweep pair (the accepted "chirp on connect") through the target and the reference
   *chosen for the room*. The reference is an AirPlay speaker when one is present,
   not the MacBook, fixing §3.3. The Mac mic measures. The result is applied at once,
   labelled "Measured from your Mac", and followed by a passive acoustic-baseline
   window.
   *Needs:* auto-trigger on the steady edge (today's rule that "no measurement is
   app-initiated" needs an owner reversal, scoped to the connect chirp he already
   accepted); reference chooser; the wizard's measurement path without the sheet.
4. **Optional listener refinement.** A one-line invite on the row: "Sit where you
   listen and check with iPhone". The phone measures at the seat. The Mac replaces the
   value and re-captures its acoustic baseline (5.1). Without a phone, the by-ear
   wizard stays as the refinement path.
5. **During music.** Program-audio windows on events plus the sparse periodic check
   (existing), measured against acoustic baselines. With "Continuous sync" on,
   per-speaker codes (5.2 tier 2) make every window attributable and usable through
   quiet passages. Corrections follow the existing 10/40 ms policy, but the 10 ms
   floor drops to about 3–4 ms once attribution is signal-based. That brings the
   holding target inside the localisation-dominance band, instead of leaving up to
   10 ms permanently.
6. **Reconnect / wake / relaunch.** Apply the stored value (ADR 0001) and mark the
   speaker *Unverified*. On steady: with music playing, take a passive window; with
   nothing playing, take one mini-chirp at the next play start (masked by the track
   onset). Move to *Locked* or *Corrected*.
7. **Degradation.** The signal from 5.3 says which speaker, what happened, and the one
   action that fixes it. Examples:
   - a clock-step storm: "Reconnect {name}", because a power cycle cleared it live
     (HANDOFF live test 2);
   - budget exceeded: "Raise the AirPlay buffer" or automatic delay-to-worst (ARCH §8.1);
   - blind: "Choose microphone" or "Check with iPhone".
8. **Months.** Calibration age plus OS-update triggers schedule silent re-verification
   (option I). Seeds improve with every accepted result (option J). The user sees
   *Locked* and nothing else.

### 5.5 What each redesigned step needs, summarised

| Step | Code (Mac) | Code (shared) | Code (phone) | Hardware / data | Owner ruling |
|---|---|---|---|---|---|
| Mic in onboarding | SetupFlowModel step | — | — | — | yes (card order) |
| Any non-BT mic | relax `builtInMicrophoneID` | — | — | test a USB mic and a Studio Display | no |
| Seeded first play | seed lookup | — | — | seed data / server | yes (data) |
| Auto connect chirp | steady-edge trigger, reference chooser | — | — | — | yes ("no app-initiated measurement" rule) |
| Acoustic baselines | baseline capture/store, position epoch | — | verdict → Mac message | — | no |
| Per-speaker codes | per-sink injection | code synthesis + multi-code correlator | — | AAC/SBC survival test, masking listening test | **yes** (spec decisions 1/7) |
| Health signal | `OutputBackend` exposure, budget check | analytics row | same states on the phone | — | copy review |
| Wide search on events | pacing-clock prior | — | — | ticket 14 fit data | no |
| Persist applied trim | VER #2 | — | — | — | no |
| Calibration age | store fields, triggers | — | — | — | no |

---

## 6. Open questions for a live test or the owner

1. **Geometry test (checks §3.7):** calibrate two BT speakers with the phone at the
   sofa. Put the MacBook about 4 m nearer one speaker than the other. Play 30 min.
   Does the tracker slew them apart by about the differential path? Log
   `drift_correction_started` and listen at the sofa.
2. **Laptop-move test:** after (1), carry the MacBook 2 m. Count false corrections.
3. **HFP band test:** force a BT speaker into HFP (open its mic in another app), run the
   Mac-mic wizard, and confirm it refuses rather than returning a number. This also
   settles the owed "A2DP survives built-in mic capture" check.
4. **Reflection test:** turn one speaker to face a wall 0.5 m away. Compare the chirp
   answer with the speaker facing the mic. A few ms of difference would confirm the
   largest-peak-not-first-arrival bias.
5. **Owner:** may the app play a sweep on connect without a tap (the "no app-initiated
   measurement" rule vs the "branded chirp on connect is accepted UX" line in the
   mic-probe brief)?
6. **Owner:** reopen spec decisions 1/7 for an opt-in masked per-speaker code?
7. **Owner:** should a desktop Mac with no mic be told at onboarding that Bluetooth
   sync will be by ear only, until a USB mic or the phone is available?
8. **Owner:** the correction floor. Is 10 ms the product's definition of "in sync"? At
   1–10 ms the image collapses onto the early speaker. "Perfect sync" (SPEC.md:27)
   suggests a tighter target once attribution is signal-based.
9. **Owner:** the cap on the hardware-volume raise for the sweep (§3.8b), and whether the
   raise needs a visible "Turning up the {name} for a moment" line.
10. **Live:** on the Moves, does a raise to the cap followed by a restore land back on
    the exact n/127 step, and does the listener echo stay suppressed?
11. **Data:** how many buyers own a Mac without a usable mic? PostHog could carry a
   boolean `has_builtin_mic` (privacy-safe) on an existing event.

## Sources (external)

- Apple, Mac mini (2024) tech specs: https://support.apple.com/en-in/121555. No mic
  listed.
- Apple, Wireless Audio Sync: "hold your iPhone close to your TV or receiver speakers".
  Apple aligns at the source, not at the listener, which is a precedent for Mac-side
  measurement:
  https://support.apple.com/guide/tv/calibrate-video-and-audio-atvb228b7711/tvos
- Sonos, Automatic Trueplay: "starts tuning as soon as you begin playing audio … re-tunes
  as you play new content". This is a shipped precedent for in-music continuous
  measurement (EQ, not timing): https://support.sonos.com/en-us/article/automatic-trueplay-tm
- Kirovski and Malvar, "Spread-spectrum watermarking of audio signals", IEEE TSP 51(4),
  2003:
  https://www.microsoft.com/en-us/research/wp-content/uploads/2016/02/KirovskiMalvarTSPApr03.pdf
- Peng et al., "BeepBeep", SenSys 2007: https://dl.acm.org/doi/10.1145/1322263.1322265
- All other numbers cite repo notes; their primary sources are in
  `dev/notes/bt-latency-stability-research-2026-09-05.md` and
  `drift-tde-algorithms-brief.md`.
