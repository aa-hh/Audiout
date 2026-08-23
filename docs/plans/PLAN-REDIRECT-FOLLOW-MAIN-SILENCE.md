<!--
Handoff plan. Self-contained: a fresh agent with no prior conversation context can
execute from this file alone. Produced by a research-grounded, READ-ONLY investigation
pass on 2026-07-29 (claims verified against source at the file:line refs below, and
against the owner's own telemetry from the live failure). NOTHING IS FIXED — this is
the spec for the fix, plus the two live tests that decide which fix is right.
All file:line anchors are against `main` @ 2042de1.
-->

# Investigation + Fix Plan — "Follow-main app is silent after another app is redirected to This Mac"

**Status:** READ-ONLY research complete. No code written. Root cause identified with a
mechanism and a live-telemetry proof; ONE live A/B (§7 LT-1) separates the primary
candidate from its runner-up before any code is written.
**Worktree:** `/Users/alechenderson/Projects/AirPlay Controller/.claude/worktrees/redirect-follow-main-silence`
**Branch:** `claude/redirect-follow-main-silence` (off `main` @ 2042de1, NOT merged).

---

## 1. Symptom (the owner's live observation, 2026-07-29)

1. Audio playing to the Selected Devices (a Sonos Move) — working correctly.
2. The owner redirected the playing app (Spotify) to **"This Mac"** — a `.currentDevice`
   per-app route. Worked perfectly; Spotify came out of the Mac's speakers.
3. The owner pressed play in a **different** app that has **no** redirect — it should
   follow main output to the Sonos. **Nothing came out at all.** Not quiet, not
   stuttering: silent.
4. Deselecting the output device and reselecting it made it work again.

The deselect/reselect dance must never be required. Everything in this document is
about why step 3 is silent and why step 4 cures it.

**This is bug #6 in the 2026-07-26 onion** (redirect-order PTP gate, one-role-per-speaker,
multi-process attribution leak, self-echo, launch-reset-all-redirects). The pattern held:
each fix unmasked the next. This one was masked by the fact that the earlier bugs kept
audio *flowing* through the failure windows.

---

## 2. Live evidence, 2026-07-29 (`~/Library/Logs/Audiout/telemetry.jsonl`)

Session `C98DF1E0-87FD-4200-AB18-13E5FFC060B2`. Build: the merge candidate
`claude/dropout-merge-5c2a1f` @ e960a7b (= `main` + 3 semantic-fix pins; the redirect
logic is identical to `main`). All times UTC.

### 2.1 The timeline

| Time | Event | Meaning |
|---|---|---|
| 19:14:25.248 | `airplay/set_output_set added=[Sonos Move]` | Step 1 — streaming, audible. |
| 19:15:04.958, 19:15:23.403 | `airplay/session_reset scope=wholeSystem recovery=flush_first` + `rebind_recover_flush outcome=issued` | Two **device/rate** rebuilds earlier in the same session. Both re-anchored. Both stayed audible. **This is the in-session control.** |
| 19:17:32.127–.185 | `capturePA` Spotify tap up; `localPlayback/output_device_pinned device=82`, `start_done isRunning=true`, `add_app_ok` | Step 2 — redirect to This Mac armed and working. |
| 19:17:32.214 | `captureWS/exclusion_changed excluded=com.spotify.client recreate=true` → `transition capturing→creatingTap` | WS tap teardown for the exclusion-set change. |
| 19:17:32.327 | `create_and_start_done rate=44100` → `transition creatingTap→capturing` | New WS tap up, **113 ms**. Same device (82), same rate (44100). **No `session_reset`. No `rebuild_reanchored`. No flush.** |
| 19:17:32.2 → 19:17:41.3 | *(silence in the log)* | **THE 9.14-SECOND WRITE STARVATION — see §2.2.** |
| ~19:17:41.3 → 19:18:02 | writes at full cadence (86/s) | Step 3 — the second app IS playing, its PCM IS reaching the tap, the engine IS writing. **The owner hears nothing.** |
| 19:18:02.247 | `set_output_set removed=[Sonos Move]` → `capturing→stopping→idle` | Step 4a — deselect. |
| 19:18:04.248 | `set_output_set added=[Sonos Move]`, `connect_addoutput_start` → `connect_addoutput_resolved` @ .902 | Step 4b — reselect. **Audio returns.** |

### 2.2 The 9.14-second write starvation (the load-bearing measurement)

`airplay/send_sched.gap_count` is a monotonic count of `AirPlayEngine.write` arrivals:

```
19:17:30.830  gap_count=15117   gap_max_ms=11.8
19:17:35.892  gap_count=15236   gap_max_ms=11.8     (+119 — writes stopped mid-window)
19:17:40.990  gap_count=15236   gap_max_ms=11.8     (+0   — ZERO writes for 5.1 s)
19:17:46.005  gap_count=15638   gap_max_ms=9136.8   (+402 — resumed at full cadence)
```

Corroborated independently by the cadence tracker:

```
19:17:29.457  write_cadence_drift  writeCount=15000  deficitTotal=1.657  deficitDelta=0.022
19:17:44.388  write_cadence_drift  writeCount=15500  deficitTotal=10.803 deficitDelta=9.146
19:17:50.193  write_cadence_drift  writeCount=16000  deficitTotal=10.829 deficitDelta=0.026
```

Arithmetic check: 15000→15500 took 14.93 s of wall clock; at the measured 86.2 writes/s
those 500 writes are 5.79 s of real work. 14.93 − 5.79 = **9.14 s of nothing**, matching
`gap_max_ms=9136.8` and `deficitDelta=9.146` exactly. Back-solving the resume point from
the 19:17:46.005 sample puts the gap at **19:17:32.2 → 19:17:41.3** — it starts at the
tap teardown (19:17:32.214) and ends ~9 s later with no telemetry event at all, i.e. at a
human action: the owner pressing play in the second app.

**What this rules out immediately.** The write path was alive and writing at full cadence
throughout the audible failure. So: the capture gate did not stop the WS tap
(`captureRunning` never flipped — there is no `stopping` transition until 19:18:02); the
IOProc was not dead; and the second app's audio was *not* being excluded (if it were,
writes would never have resumed). Those three candidates are dead for this incident.

### 2.3 The five-day corroboration

Across all 18,103 lines (2026-07-24 → 2026-07-29), correlating every
`captureWS/exclusion_changed` against `airplay` rebind/bind events in a +6 s window:

| `recreate` | AirPlay device desired | rebind within 6 s | count |
|---|---|---|---|
| `false` | no | no | 81 |
| `false` | no | yes | 19 |
| `false` | yes | no | 3 |
| **`true`** | **yes** | **no** | **25** |
| `true` | yes | **yes** | **0** |

**25 out of 25**, no counterexample: an exclusion-change tap rebuild while an AirPlay
device is live *never* re-anchors the stream-0 session. That is the documented design
(see `AudioutCore/AGENTS.md`, the R10 rule) — and it is correct for the other 24, where
audio kept flowing across the rebuild so no skew could accumulate. What made this one
fatal is §2.2.

### 2.4 Instrumentation gap found while doing this

There is **no telemetry anywhere that fires when an unrouted app begins playing audio.**
Searched all 63 distinct `evt` names and 100+ key names for
`audib|play|activ|app_start|level|process_start|running|begin|resume`; the only "audib"
strings in the whole file are `processNotYetAudible(...)` failures on *per-app* taps,
which only exist for apps that already have a redirect. Step 3 of this bug is therefore
structurally invisible in the log — it had to be inferred from the write cadence. See T-I3.

---

## 3. Verified trace — why a write gap kills a live stream-0 session

Walked against source, not docs. Anchors are `main` @ 2042de1.

### 3.1 Mac side: what happens on the redirect

1. Popover pick → `AppRoutingController.onRoutesDidChange` → `AppDelegate.pushAppRoutesToBackend`
   → `NativeBackend.updateAppRoutes(_:excludedBundleIDs:)` (**NativeBackend.swift:2132**).
2. `.currentDevice` lands in `newLocal` (**:2153-2155**), which becomes `plan.localExcluded`
   (**:2227**), unioned into the WS tap's exclusion set at
   **NativeBackend.swift:2293-2295**.
3. `NativeCaptureCoordinator.updateRouting` (**NativeCaptureCoordinator.swift:609**) logs
   `exclusion_changed` (**:625**) and calls `recreateTap(cause: .exclusionChange)`
   (**:1062**).
4. `recreateTap` tears down and rebuilds the tap + aggregate, then decides whether to
   re-anchor at **NativeCaptureCoordinator.swift:1239-1254**:
   `TapReanchor(previousRate:newRate:previousDeviceID:newDeviceID:)` — and fires
   `onDeviceRateRebuild?()` only if `cause == .deviceOrRateChange || reanchor.didReanchor`.
   Here: same device (82), same rate (44100) ⇒ `didReanchor == false`, cause is
   `.exclusionChange` ⇒ **no reset**. Matches the telemetry (no `rebuild_reanchored`).
5. `reconcileCaptureGate()` (**NativeBackend.swift:5491**) is never called by this path —
   its `want` reads only `expectedSelected` (**:5502-5503**), which the redirect does not
   touch. So `captureRunning` stays `true` and the coordinator stays `.capturing`.
   **The gate is not the bug** (contra the initial lead), and the telemetry agrees.
6. The only remaining audible process on the tapped device is now excluded (Spotify) or
   self-excluded (our own `LocalPlaybackEngine` render pid — `exclusion_resolved` shows
   `self: 3482`). The tap has nothing to mix and **delivers no buffers**:
   `handleBuffer` → `sink.write(pcm:pts:)` (**NativeCaptureCoordinator.swift:986**) is
   simply not called. There is no silence-fill anywhere on this path.

### 3.2 Receiver side: why the gap is unrecoverable

This is the mechanism, and it is in the vendored sender:

- RTP position advances by **samples written, never by wall clock**:
  `session->pos += pkt->samples` (**CAirPlayEngine/sender/rtp_common.c:186**), and that
  `pos` is what goes on the wire as the packet timestamp
  (`rtptime = htobe32(session->pos)`, **rtp_common.c:167**).
- The rtptime↔wall-clock anchor the receiver schedules against is built in
  `timestamp_set()` (**CAirPlayEngine/sender/airplay.c:2232**) from **the producer's own
  pts** — `ams->cur_stamp.ts = ts` (**:2239**) — paired with
  `ams->cur_stamp.pos = rtp_session->pos + input_buffer_samples - output_buffer_samples`
  (**:2257**). `timestamp_set` runs on write. **No write ⇒ no anchor update.**
- Consequence of a 9.14 s starvation: `pos` is frozen while wall clock advances 9.14 s.
  Sync packets during the gap keep republishing a stale `(ts, pos)` pair. When writes
  resume, `pos` continues from where it stopped while `ts` has jumped 9.14 s — a
  permanent 9.14-second skew between "what the sender says should be playing now" and
  what the receiver's clock says now. The receiver has long since drained and stopped;
  everything arriving is ~9 s stale. **Silent forever, with a healthy-looking Mac side.**
- This is the same failure family the codebase already names — "the process tap keeps
  delivering buffers but the stream-0 AirPlay sessions stay pinned to a now-stale RTP
  timeline and the receivers go silent forever (Apple-unresolved, Dev Forums 825780)"
  (**NativeBackend.swift:1375-1390**) — reached by a **different trigger** that no
  existing detector watches for.

### 3.3 Why deselect/reselect cures it

`setOutputSet` → `removeOutput` → `addOutput` builds a **brand-new RTSP/RTP session**, and
a fresh session randomizes `pos` from scratch (**rtp_common.c:75**) and re-anchors on its
first write. The accumulated skew belongs to the dead session. That is the entire reason
the dance works — and why it is a complete workaround rather than a partial one.

### 3.4 Why nothing recovered it automatically

`resetAirPlaySessionForWholeSystem()` (**NativeBackend.swift:2557**) is the *only* thing
that re-anchors stream 0 — it flushes first (`engine.flushOutput`, **NativeBackend.swift:2844**
→ `AirPlayEngine.flushOutput`, **AirPlayEngine.swift:1005**, the F-REANCHOR path) and falls
back to `removeOutput`→`addOutput`. It has exactly **two** call sites:

1. **NativeBackend.swift:1389-1391** — wired to `captureCoordinator.onDeviceRateRebuild`,
   i.e. a device-or-rate tap rebuild (§3.1 step 4).
2. **NativeBackend.swift:2020** — the synced-local churn resync, gated on `coalesced >= 2`
   rapid toggles (**:1998**).

**Neither is reachable from "the producer stalled and resumed."** There is no third
trigger. The engine already *measures* the stall — `cadence.record(...)`
(**AirPlayEngine.swift:1194**) and `schedulingProbe.recordWriteArrival()` (**:1179**),
surfaced by `EngineSink.sampleWriteCadenceIfDue()`
(**NativeCaptureCoordinator.swift:1912-1931**) — but the measurement is **telemetry-only**;
nothing consumes it as a control signal. That is the gap, precisely stated.

The R11 silence fallback (`reconcileSilenceWatchdog`, **NativeBackend.swift:4310**) cannot
help here by construction: it watches whether a desired device is **connected**, and the
Sonos was connected and healthy the whole time. It is a connection watchdog, not an audio
watchdog.

---

## 4. Ranked root-cause candidates

### C1 — PRIMARY: stream 0 has no recovery for a producer-starvation gap

**Claim.** A long gap in writes to a live stream-0 session permanently desyncs the
receiver, and no code path detects it. Redirecting the only playing app to This Mac is
simply the most reliable way to produce that gap while the session stays live and
`captureRunning` stays `true` — the redirect is the *trigger*, not the *defect*.

**Anchors.** `rtp_common.c:186` (pos advances by data) · `airplay.c:2232,2257` (anchor
built from producer pts on write) · `NativeCaptureCoordinator.swift:986` (no write when
the tap has nothing) · `NativeBackend.swift:1389,2020` (the only two re-anchor triggers,
neither gap-related) · `NativeCaptureCoordinator.swift:1912` (the stall is measured and
discarded).

**Evidence for.** The 9.14 s gap is measured three independent ways (§2.2). The two
device/rate rebuilds earlier in the *same session* re-anchored and stayed audible (§2.1),
giving an in-session control. Step 4's cure is exactly "new session, fresh anchor" (§3.3).

**Falsifiable prediction — LT-1 (§7).** Reproduce with **no redirect at all**: stream to
the Sonos, pause *every* audio source for ≥ 15 s, then press play again. **C1 predicts
silence, identical symptom.** If audio comes back normally, C1 is wrong and C2 is the
cause.

### C2 — RUNNER-UP: the exclusion-change rebuild itself is not safe to skip re-anchoring

**Claim.** The `.exclusionChange` skip at `NativeCaptureCoordinator.swift:1242` is wrong
even when device and rate are unchanged — the tap+aggregate teardown/recreate perturbs the
stream-0 timeline in a way `TapReanchor` cannot see (a pts-continuity break across the new
aggregate, or receiver state disturbed by the ~113 ms hole), so the write gap in §2.2 is
incidental.

**Anchors.** `NativeCaptureCoordinator.swift:1239-1254` (the cause-based skip) ·
`AudioutCore/AGENTS.md` R10 rule (the skip is deliberate: resetting on every benign
rebuild caused "connects fast, then a long silence").

**Evidence against (why it is #2, not #1).** 24 of the 25 exclusion rebuilds in §2.3 were
followed by working audio. The tap's pts comes from mach-absolute→monotonic
(machine-global, continuous across an aggregate swap), so a same-device rebuild should not
move the anchor. And C2 does not explain the 9.14 s gap at all.

**Falsifiable prediction — LT-2 (§7).** Have **two** apps playing. Redirect only one to
This Mac, so the system mix never goes silent and no write gap can form. **C2 predicts the
remaining app goes silent anyway. C1 predicts it keeps playing.** LT-1 and LT-2 together
separate these cleanly.

### C3 — the rebuilt tap did not actually start delivering for 9 s

**Claim.** The 9.14 s gap is a *tap-start* defect after `.exclusionChange` — the new
aggregate reported `capturing` at 19:17:32.327 but its IOProc did not deliver until
something external kicked it — rather than a genuine consequence of a silent mix.

**Anchor.** `NativeCaptureCoordinator.swift:1062` (`recreateTap`) / `:1202`
(`transition(to: .capturing(format))` fires on create success, **not** on first buffer).
The state machine's `.capturing` is a claim about setup, never evidence of delivery.

**Evidence against.** The gap ends at a moment with zero telemetry — consistent with a
human pressing play, not with a code event. But the log cannot *prove* it: nothing counts
buffers. This is exactly what T-I3 instruments.

**Falsifiable prediction.** With first-buffer-after-rebuild instrumentation, force an
exclusion rebuild **while other audio is playing**. C3 predicts a multi-second
first-buffer latency; C1/C2 predict < 200 ms.

### C4 — REFUTED: exclusion over-attribution swallowed the second app

`exclusion_resolved` at 19:17:32.233 reads exactly
`com.spotify.client=[1040:responsible,739:own]`, `self=3482`, `zeroBundles=""` — only
Spotify's own two pids plus our render process. And writes resumed at full cadence, which
is only possible if non-excluded audio was reaching the tap. The catch-all attribution
walk (c9125eb) did not over-match here.

### C5 — REFUTED: the capture gate concluded "no WS demand"

No `captureWS` transition out of `.capturing` between 19:17:32.327 and 19:18:02.247, and
`reconcileCaptureGate`'s `want` (**NativeBackend.swift:5502-5503**) reads only
`expectedSelected`, which a redirect never touches (**AudioutCore/AGENTS.md**, the T7
rule). The gate was structurally uninvolved.

### C6 — REFUTED: one-role-per-speaker (7c2cf06) cleared the main-output binding

`clearRoutes(toDevices:)` fires only from `GroupController.onMainOutMembersChanged`, and
only for redirects pointed at a **speaker**. The redirect here was `.currentDevice` (the
Mac), and there is no `set_output_set` anywhere between 19:14:25 and 19:18:02 — Main Out
membership never changed. Launch-reset (7afb04c) is launch-only and equally uninvolved.

### C7 — REFUTED as a cause, noted as an amplifier: the eager `setLocalPlaybackRenderPID` rebuild

The 5c2a1f branch originally armed an eager `recreateTap(.exclusionChange)` on
`.currentDevice`; both `main` and the merge candidate independently removed it as
redundant. The telemetry shows the rebuild **did** happen anyway via `updateRouting`
(19:17:32.214), so nothing was lost. Re-adding it would only have produced a *second*
reset-less rebuild. Not load-bearing.

---

## 5. Related context (adjacent, NOT this bug)

`write_cadence_drift` shows `deficitTotalSeconds` climbing monotonically at ~0.020 s per
~6 s (≈3.3 ms/s, ≈ one 11.6 ms buffer lost per 3.5 s) with dead-regular write gaps — a
continuous anchor slide with no stalls, reaching 14.38 s total by 19:26:58.

This is owned by the judder investigation (roadmap 016,
`docs/plans/PLAN-WHOLE-SYSTEM-AUDIO-DROPOUT-JUDDER-INVESTIGATION.md`), not by this bug —
audio was fine both before and after the incident while the slide continued. **But it is
the same physical quantity as C1's mechanism**, differing only in rate: C1 is one 9.14 s
step, the slide is 3.3 ms/s continuously. They share a fix surface. A gap-triggered
re-anchor (T-F1) with a threshold well above the slide rate does not interact with it; a
naive "re-anchor whenever deficit grows" would fire constantly and thrash. **Whoever
implements T-F1 must threshold on a single-gap step, never on cumulative deficit.**

---

## 6. Task breakdown

Investigation tasks first — **T-I1/T-I2 are live tests only the owner can run, and they
decide which fix is correct.** No fix task starts before T-I1 reports.

### Investigation

| # | Task | Scope / files | Depends on | Model + effort |
|---|---|---|---|---|
| **T-I1** | Run **LT-1** (§7): reproduce with no redirect, by pausing all audio ≥ 15 s mid-stream. Capture telemetry. This is the C1-vs-C2 discriminator and the single highest-value action in this plan. | Live, owner. No code. | — | Owner (live) |
| **T-I2** | Run **LT-2** (§7): two apps playing, redirect one. Confirms the complement of T-I1. | Live, owner. No code. | — | Owner (live) |
| **T-I3** | **Close the observability gap** (§2.4, C3): (a) count buffers delivered per tap generation and log first-buffer-after-rebuild latency in `recreateTap`'s commit path (`NativeCaptureCoordinator.swift:1202`); (b) log a `captureWS/write_starvation` line from `EngineSink` when a single inter-write gap exceeds a threshold (the value is already in `writeCadenceSnapshot().lastGapSeconds`, `NativeCaptureCoordinator.swift:1929`) — diagnostic only, no control action; (c) add an RMS>0 counter on the WS path so an all-zero-PCM tap is distinguishable from a non-delivering one. Ship this **before** T-F1 so the fix's effect is measurable. | `NativeCaptureCoordinator.swift` (`recreateTap`, `EngineSink`), `NativeCaptureCoordinatorTests`. | — | Sonnet, **medium** |
| **T-I4** | **Read the vendored sync path end to end** and write down, in `AirPlayEngine/docs/`, exactly what a receiver does with a stale-then-jumped `(cur_stamp.ts, cur_stamp.pos)` pair: `packets_sync_send` (`airplay.c:2261`), `rtp_sync_is_time`, `sync_packet_ptp_make`/`_ntp_make` (`rtp_common.c:248-343`). §3.2's mechanism is grounded in the sender code but the *receiver's* tolerance is inferred, not proven. This decides whether a FLUSH alone is sufficient or whether a full re-add is needed for some receivers. | Read-only + one doc. | — | Opus, **medium** (vendored C, subtle) |

### Fix

| # | Task | Scope / files | Depends on | Model + effort |
|---|---|---|---|---|
| **T-F1** | **If T-I1 reproduces (C1):** add the missing third trigger for `resetAirPlaySessionForWholeSystem()`. Detect a *single-gap* write starvation on stream 0 and re-anchor once when writes resume. Preferred shape: `EngineSink` (`NativeCaptureCoordinator.swift:1881`) already sees every write and already has `lastGapSeconds`; give it an `onWriteStarvationRecovered` callback that `NativeBackend.start()` wires to `resetAirPlaySessionForWholeSystem()` next to the existing `onDeviceRateRebuild` wiring (`NativeBackend.swift:1389`). **Fire on the resume edge, not during the gap** (there is nothing to re-anchor to until data flows). **Threshold on one gap, never on cumulative deficit** (§5). `resetAirPlaySessionForWholeSystem` is already single-flighted and ownership-guarded, so it cannot thrash a healthy session. **One fix in the shared reset path — do not add a guard per trigger.** | `NativeCaptureCoordinator.swift` (`EngineSink`), `NativeBackend.swift` (wiring only). | T-I1, T-I3 | Opus, **medium** |
| **T-F2** | **If T-I2 reproduces instead (C2):** make the re-anchor decision at `NativeCaptureCoordinator.swift:1242` evidence-based on the *write* side too, not just device/rate identity — i.e. an `.exclusionChange` rebuild re-anchors when the stream demonstrably lost continuity. Must NOT reintroduce the per-connect redundant re-establish the R10 rule warns about (`AudioutCore/AGENTS.md`); the synced-local sink attach fires an `.exclusionChange` rebuild on **every** Mac+AirPlay connect. | `NativeCaptureCoordinator.swift` (`recreateTap`, `TapReanchor`). | T-I2 | Opus, **medium-high** |
| **T-F3** | Choose the recovery *strength* from T-I4's finding: keep `flush_first` (cheap, no audible drop) or escalate to `removeOutput`→`addOutput` for receivers that ignore a FLUSH re-anchor. The fallback chain already exists in `enqueueRebindRecovery` (`NativeBackend.swift:2844` onward) — this is a threshold/ordering decision, not new machinery. | `NativeBackend.swift` (recovery chain only). | T-I4, T-F1 | Sonnet, **low** |
| **T-F4** | **Tests.** Hermetic coverage for whichever of T-F1/T-F2 lands: a fake sink driving a synthetic write gap must produce exactly one `session_reset`; a gap below threshold must produce none; the continuous-slide profile from §5 must produce none (the anti-thrash test that matters most); and the existing `.exclusionChange`-does-not-reset behavior must still hold for the no-gap case. Use `_installTestSink` nested under `SerializedSharedState` per `AudioutCore/AGENTS.md`. | `NativeCaptureCoordinatorTests`, `NativeBackendTests`. | T-F1 or T-F2 | Sonnet, **medium** |
| **T-F5** | **Docs.** Update `AudioutCore/AGENTS.md`'s R10 rule — it currently states that an exclusion-set rebuild "must NOT reset", which is true *about the rebuild* but reads as "stream 0 needs no reset here". Add the trap: the rebuild is safe, the **starvation window it can open** is not. Docs land with the code on the same branch. | `AudioutCore/AGENTS.md`. | T-F1 or T-F2 | Sonnet, **low** |

**Execution note.** T-I3 and T-I4 are independent of each other and of the live tests, and
can run in parallel today. Everything under Fix waits on T-I1.

---

## 7. Owner live-test steps

Run these **before** any code is written. Both take under two minutes. Note the wall-clock
time of each step so the telemetry can be aligned afterwards.

### LT-1 — the C1 discriminator (**do this one first**)

1. Select the Sonos Move as the output device. Play music in any app. Confirm it is audible
   on the Sonos.
2. **Set no redirect. Touch nothing in the app.**
3. Pause the music. Make sure **nothing else on the Mac is making sound** (no browser tab,
   no notification, no Music in the background).
4. Wait **at least 15 seconds**. Longer is better — try 30 s.
5. Press play again in the same app.

- **Silent ⇒ C1 confirmed.** The redirect is incidental; this is a general "any silence
  gap kills Main Out" bug and is more serious than the reported scenario. Proceed to T-F1.
- **Audible ⇒ C1 refuted.** Proceed to LT-2.

### LT-2 — the C2 discriminator

1. Select the Sonos Move. Start **two** apps playing at once (e.g. Spotify and a browser
   video). Confirm both are audible on the Sonos.
2. Redirect **one** of them to "This Mac". The other must keep playing without interruption
   — the system mix never goes silent, so no write gap can form.
3. Listen to the app you did **not** redirect.

- **It keeps playing ⇒ C2 refuted**, C1 stands (with LT-1).
- **It goes silent ⇒ C2 confirmed**, the rebuild itself is the defect. Proceed to T-F2.

### LT-3 — confirm the original report still reproduces (regression baseline)

Reproduce §1 exactly (one app playing → redirect it to This Mac → press play in a second,
unredirected app) and note the time. This is the acceptance test for whichever fix lands.

**Afterwards:** `~/Library/Logs/Audiout/telemetry.jsonl` holds everything needed. The
lines that matter are `airplay/send_sched` (`gap_count`, `gap_max_ms`) and
`captureWS/write_cadence_drift` (`deficitDeltaSeconds`) around each test.

---

## 8. Standing project rules the executing agent MUST honor

- **`main` is merge-only.** Author everything in a worktree; never commit on `main`, never
  edit the `main` checkout. See root `AGENTS.md`.
- **Docs orient, code decides.** Every claim in this file carries a `file:line`; re-verify
  before acting on it — line numbers move.
- **Inner loop is `swift test --filter <Suite>`**; the full run is `scripts/run-tests.sh`,
  never a bare `swift test`. See `AudioutCore/AGENTS.md`.
- **`Telemetry.log` is never called from the IOProc/render path** — only from the
  non-realtime decision points around it. T-I3(a)'s buffer counter must respect this: count
  on the RT path, log off it.
- **Real-audio-hardware tests are opt-in** (`AIRPLAY_AUDIO_HARDWARE_TESTS=1`).

---

## 9. Key file:line index (`main` @ 2042de1)

| What | Where |
|---|---|
| Route table → exclusion set | `AudioutCore/Sources/AudioutCore/NativeBackend.swift:2132`, `:2153-2155`, `:2227`, `:2293-2295` |
| Capture gate (uninvolved — `expectedSelected` only) | `NativeBackend.swift:5491`, `:5502-5503` |
| The ONLY two whole-system re-anchor triggers | `NativeBackend.swift:1389-1391` (device/rate rebuild), `:2020` (synced-local churn) |
| `resetAirPlaySessionForWholeSystem` | `NativeBackend.swift:2557` |
| F-REANCHOR flush, then removeOutput/addOutput fallback | `NativeBackend.swift:2844` → `AirPlayEngine/Sources/AirPlayEngine/AirPlayEngine.swift:1005` |
| R11 silence watchdog (connection-only — cannot see this) | `NativeBackend.swift:4310` |
| WS exclusion-change entry point | `NativeCaptureCoordinator.swift:609`, `:625` |
| `RebuildCause` / the cause-based skip | `NativeCaptureCoordinator.swift:1036`, `:1239-1254` |
| `.capturing` set on create success, not first buffer | `NativeCaptureCoordinator.swift:1202` |
| Tap buffer → engine write (no silence fill) | `NativeCaptureCoordinator.swift:986` |
| `EngineSink` — sees every write, owns `lastGapSeconds` | `NativeCaptureCoordinator.swift:1881`, `:1912-1931` |
| Engine write entry, cadence + scheduling probes | `AirPlayEngine.swift:1174`, `:1179`, `:1194` |
| RTP pos advances by SAMPLES, not wall clock | `AirPlayEngine/Sources/CAirPlayEngine/sender/rtp_common.c:186`, `:167` |
| Fresh session randomizes pos (why reselect cures it) | `rtp_common.c:75` |
| rtptime↔wall-clock anchor, built from producer pts on write | `AirPlayEngine/Sources/CAirPlayEngine/sender/airplay.c:2232`, `:2239`, `:2257` |
| Sync packet send | `airplay.c:2261` |
