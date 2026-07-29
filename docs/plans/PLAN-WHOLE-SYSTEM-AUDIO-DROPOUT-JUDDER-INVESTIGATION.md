<!--
Handoff plan. Self-contained: a fresh agent with no prior conversation context can
execute from this file alone. Produced 2026-07-29 (late evening) from five research
dossiers (R1 capture-path inventory, R2a anchor arithmetic, R2b transport census,
R3 measurement machinery, R4 concurrency audit), the 2026-07-29 live-findings ledger,
and a full anchor RE-VERIFICATION pass against `main` @ e960a7b. Every file:line in
this document resolves at that SHA unless explicitly flagged otherwise in §B.6.
-->

# Investigation Plan — Whole-system audio judder (the dropout family, post-e960a7b)

**Status: OPEN — this is the campaign's single planning document.** The catastrophic
dropout members of this bug family were fixed and live-verified tonight (§E); what
remains is the judder/degradation family, topped by a measured, continuous,
mechanism-unknown anchor slide (§D J-1).
**Worktree:** `.claude/worktrees/judder-doc` · **Branch:** `claude/judder-doc`
**Baseline:** `main` @ **e960a7b** (tonight's merged dropout fixes, 2026-07-29,
owner checklist 7/7 — see §E). Roadmap: **016** (this doc), coordinating with
**017/018/019** (§K).

> **SUPERSESSION.** This document SUPERSEDES the branch-era doc of the same name:
> added as `22b8827` on `claude/audio-dropout-investigation-5c2a1f`, landed on `main`
> via merge `b3d733c`, then REMOVED from `main` in `d5d2414` ("completed-investigation
> artifacts"). That doc's core diagnosis ("the app cannot tell this failure from healthy
> playback in its own logs") is now FALSE — the instrumentation floor it demanded is on
> `main` and firing (§E). Do not resurrect the old doc; its still-live content is folded
> in here with anchors re-verified at e960a7b.

---

## A. End state

The owner can hear judder, look at one log stream, and name the mechanism — because
every candidate mechanism has a discriminating signature that telemetry (or the ear
table in §J) separates. Concretely:

1. **The ~3.3 ms/s continuous anchor slide has an identified source** — converter,
   IOProc, accounting, or RT-path loss — proven by stage-boundary sample-conservation
   measurement, not inference (§D J-1, tasks T-2/T-3/T-4).
2. **Each of the three original symptoms** (volume-drag judder, BT rate-flap churn,
   steady-state degradation) **maps to a mechanism** that is either fixed, owned by a
   named plan, or has an open task here (§C).
3. **The split-ownership failure class is swept**: every field on the rebuildable
   audio objects whose lifetime disagrees with the decision it feeds is enumerated and
   dispositioned (§G) — the class that produced three silent-forever criticals stops
   producing them by audit, not by luck.
4. Fixes land only where a discriminating measurement pointed first. No fix task in
   §H starts before its gating investigation task reports.

---

## B. Verified findings — anchors RE-VERIFIED against `main` @ e960a7b

Line numbers from the research dossiers (written against pre-merge trees) have
shifted; everything below was re-resolved at e960a7b. §B.6 lists dossier anchors that
no longer resolve at all.

### B.1 Anchor arithmetic (R2a — the physics of this bug family)

The vendored sender anchors receivers to a `(rtptime, wall-clock)` pair rebuilt only
on write:

| Fact | Anchor (e960a7b) |
|---|---|
| RTP `pos` advances by **delivered samples only**, never wall clock | `CAirPlayEngine/sender/rtp_common.c:186` |
| The anchor pair is built from the **producer's pts** on each write | `sender/airplay.c:2239` (`cur_stamp.ts`), `:2257` (`cur_stamp.pos`) |
| `input_buffer_samples` accrual (conservation identity `pos + input_buffer == X + S`) | `airplay.c:4371` |
| Sync send is gated on **delivered** audio: `sync_counter > 44100`, counter += 352/commit, checked once per write | `rtp_common.c:231`, `:186-187`; sole call site `airplay.c:4367` |
| Fresh session randomizes `pos` (why deselect/reselect always cures skew) | `rtp_common.c:75` |
| 352 samples/packet, 250 ms min receiver latency, keep-alive 25 s | `airplay.c:85`, `:94`, `:113` + `:485` |
| Product start buffer 1000 ms ⇒ receiver slack 750 ms | `AppSettings.swift:114` |

Consequences (verified arithmetic, R2a):

- **Every undelivered capture buffer slides the receiver schedule LATER, permanently**
  (~10.7–11.6 ms per 512-frame buffer). Nothing re-derives `pos` from a clock
  mid-session; only a session teardown or `resetAirPlaySessionForWholeSystem` resets it.
- **Re-anchor quantum is 1.006–1.014 s of delivered audio** (126×352 = 44352 or
  127×352 = 44704 samples), so anchor-caused artifacts are quantized to ~1.01 s and
  rate-capped at 0.994 Hz. **A measured period of exactly 1.000 s FALSIFIES the anchor
  mechanism** (points at PTP announce/signaling, 1000 ms). PTP Sync artifacts quantize
  to **125 ms** (8 Hz) — a clean, non-overlapping ear discriminator (§J.2).
- **pts is host time** (`mHostTime` → mach ns → cached mach→monotonic offset →
  `timespec`): formation at `NativeCaptureCoordinator.swift:2365-2374`, offset seeded
  per tap instance at `:2344`, drift self-heal (re-seed if the cached offset falls out
  of step — a one-shot pts STEP hazard, guarded at 1 s) at `:2367-2373`. pts advances
  with wall clock while `pos` advances with delivered samples — that asymmetry IS the
  slide mechanism.
- A dropped RTP packet on the wire (send EAGAIN) causes **zero** slide — content loss
  plus a retransmit opportunity, not schedule skew.

### B.2 Capture path: drop sites, RT hygiene (R1)

- **~22 silent drop sites** capture→write; every one upstream of the engine's write
  entry slides the anchor. The load-bearing ones at e960a7b:
  - `snapshotLock.try()` miss drops the buffer — `NativeCaptureCoordinator.swift:971`
    (correct try-discipline; a miss is a drop by design).
  - **7 uninstrumented nil-return drop sites in `AVFormatConverter.convertToAirPlayPCM`**
    — `NativeCaptureCoordinator.swift:2883-2940` (`:2886` format/frame guard, `:2890`
    inBuf alloc, `:2897` interleaved src nil, `:2914` rate guard, `:2918` outBuf alloc,
    `:2933` convert status, `:2938` outData guard). **Counters are IN FLIGHT (I1 —
    §F).**
  - Engine backpressure refusal — `AirPlayEngine.swift:1218` (`writeBacklog.admit`),
    cap 2.0 s (`:1362`). The cadence tracker records at `:1194`, BEFORE the admission
    check — refused writes are counted as delivered. **Accounting fix IN FLIGHT (I1).**
  - `SyncedLocalSink` ring-full discard (`_ = ring.write`) — counter **IN FLIGHT (I1)**.
- **Two blocking NSLocks still violate the try()-discipline on the delivery path:**
  the converter lock (`NativeCaptureCoordinator.swift:2842`, `lock.lock()` at `:2884`,
  entered from `handleBuffer` at `:982` on the IOProc delivery queue) and
  `WriteBacklogGuard` (`AirPlayEngine.swift:2029`; R4 additionally found `os_log`
  emitted inside the lock). Every other RT-path lock in the codebase is `try()`-only.
- **A fresh `AVAudioConverter` per tap rebuild** (`NativeCaptureCoordinator.swift:2877`)
  discards resampler filter state — a guaranteed waveform discontinuity per rebuild,
  independent of the anchor question.
- **~9–11 heap operations per delivered buffer** (per-channel `[Data]` assembly in the
  IOProc block `:2349-2400`, `AVAudioPCMBuffer` in/out allocs in the converter,
  `Data` copies) and **zero `autoreleasepool` anywhere** in `AudiouterCore/Sources` or
  `AirPlayEngine/Sources` (re-grepped at e960a7b: zero hits).
- **Seven rebuild paths, not six**: the six `recreateTap` triggers, plus
  `reconcileCaptureGate`'s full `coordinator.stop()`/`coordinator.start()` cycle —
  `NativeBackend.swift:5555` — a separate teardown/rebuild kind that never passes
  through `recreateTap`'s claim/commit/reanchor machinery.

### B.3 Transport / engine-loop occupancy (R2b)

- **The timing and control UDP sockets are left BLOCKING** on the shared engine
  thread: `shims/misc.c:358` (`bind_one`) sets `O_NONBLOCK` only for `SOCK_STREAM`;
  the outbound data socket is non-blocking (`misc.c:197`) but the control socket
  (sync packets) and timing socket are not. A full control sndbuf blocks the engine
  loop — asymmetric with the deliberate data-side EAGAIN handling.
- **No `SO_SNDBUF`/`SO_RCVBUF` sizing anywhere** in the package (grep: zero hits).
  macOS default UDP sendspace ≈ 9216 B ≈ 6 AirPlay packets — a post-stall burst
  overruns it immediately (wire loss → retransmit, not slide).
- **Retransmit bursts are serviced synchronously on the engine loop**
  (`control_svc_cb`), and `timing_svc_cb` takes its receive timestamp at callback
  entry — RTP drain latency lands 1:1 in AP1/NTP receivers' clock estimates.
- **Volume writes cost two engine-loop closures per device per tick**
  (`AirPlayEngine.swift:1026-1046`: `applyVolumeOnDevice` + `startOp`) — a rapid
  system-volume drag mirrored to N devices is a 2N-closure/tick burst enqueued onto
  the same loop that paces `airplay_write`.
- The loop-occupancy census is otherwise complete in R2b (dossier); `airplay_events`
  runs on its OWN pthread/event_base and is out of scope.

### B.4 PTP (R2a §3)

- Everything the receiver is told is `CLOCK_MONOTONIC`; the sender's PTP daemon
  **software-timestamps before the wire** (`ptp_msg_handle.c:960` vs send at `:962`)
  on a **default-priority pthread** (`daemon.c:577`, no `sched_*` anywhere in
  `libairptp/` or `ptp-helper/`), with a `usleep(100)` between Sync and Follow_Up.
  Any preemption in that window lands 1:1 in the receiver's offset estimate,
  refreshed 8×/s. **A PTP offset error presents as SINGLE-receiver judder**, not just
  multi-room drift.
- The only genuine step source is a helper outage (demand-started, self-exiting after
  15 s idle) — free-run drift appears as a one-shot offset step when Sync resumes.

### B.5 Concurrency (R4)

- **NO cross-component deadlock cycle** — verified ordering table, sink nodes hold.
  The audit's findings are contention/priority findings, not deadlock findings.
- The audit's #1 contention item (per-app default-device listener missing the
  compare-before-rebuild guard) is **FIXED at e960a7b** — see §B.6/§E.
- **N private aggregates pinned to one physical device cross-fire** on device
  transitions: every live tap (whole-system + per-app + metering-only) owns its own
  aggregate on the same default output device. The rebuild-storm loop is broken by
  `DefaultOutputDeviceMonitor` + `TapRebuildDecision`
  (`DefaultOutputDeviceMonitor.swift:347-353`), but the **serialized
  destroy/create cost** of N aggregates in one transition window remains — live-tied
  to an audible artifact tonight (§D J-2).
- **The claim that HAL runs queue-backed IOProcs at RT priority regardless of queue
  QoS is UNVERIFIED** — it survives at e960a7b as an audit comment,
  `EngineThread.swift:182-188`, and the delivery queues are `.userInitiated`.
  **Never inherit this claim; measure it** (T-5).

### B.6 Dossier anchors that NO LONGER RESOLVE at e960a7b

Flagged, not silently fixed:

1. **`installDefaultDeviceListener` / `installSampleRateListener`
   (R1: NCC:2179-2203, :2238-2275; R4: PACC:1127-1138)** — GONE. Both taps' raw HAL
   listener blocks were replaced by subscriptions to the process-wide
   `DefaultOutputDeviceMonitor` (`NativeCaptureCoordinator.swift:2596`,
   `PerAppCaptureCoordinator.swift:1493`), which evaluates the pure
   `TapRebuildDecision` guard per subscriber (`DefaultOutputDeviceMonitor.swift:347-353`).
   Consequence: **R4's top-ranked contention finding (the per-app listener's missing
   compare-before-rebuild guard, D2) is fixed-tonight**, not open.
2. **R4 D3's anchor `EngineThread.swift:184-188`** — shifted to `:182-188`; the
   unverified claim itself survives verbatim.
3. **R3's "send_sched telemetry NEVER fires (dead re-arm)"** — FIXED:
   `reconcileCaptureGate` re-arms `startSchedulingSnapshotPolling()` on the
   capture-gate edge (`NativeBackend.swift:5531`); live-proven firing 2026-07-29.
4. **R3's "`writeCadenceSnapshot()` has ZERO callers"** — FIXED: sampled on both
   paths (`NativeBackend.swift:3257` per-app; `NativeCaptureCoordinator.swift:1912`
   whole-system, emitting `write_cadence_drift`).
5. **R3's "AGENTS.md claims AudioDiag handle-counters are wired into
   PerAppCaptureCoordinator — stale, zero production callers"** — the aggregate
   lifecycle telemetry gap that claim papered over is now closed differently:
   `aggregate_create`/`aggregate_create_rate_delayed`/`aggregate_destroy` Telemetry
   at `NativeCaptureCoordinator.swift:2296/:2323/:2682` and the per-app mirror.
6. All R1/R2a/R4 line anchors into `NativeCaptureCoordinator.swift` (grew 2564→2949),
   `NativeBackend.swift` (5713→6161), `AirPlayEngine.swift` (→2466) shifted; the
   re-resolved values are the ones used throughout this document. Notables:
   `handleBuffer` 871→**947**, converter 2498→**2883**, `write(streams:pts:)`
   1040→**1174**, `WriteBacklogGuard` 1884→**2029**, `recreateTap` 973→**1062**.
7. **Vendored C anchors hold byte-identically** (airplay.c, rtp_common.c, misc.c,
   ptp sources) — verified spot-for-spot.

---

## C. The three original symptoms, kept distinct

These are three different bugs sharing a family, not one bug with three moods. Do not
let a fix for one be claimed as a fix for another without its own discriminating
evidence.

### C.1 Volume-drag judder (the founding 016 symptom)

Rapid system-volume dragging while streaming → judder, historically followed by
complete silence.

- **Now-known contributors:** the 2N-closure/tick engine-loop burst (§B.3); the
  blocking control socket sharing that loop (§B.3); receiver-side DACP burst behavior
  (unobservable from our side). The historical *complete-silence* tail is plausibly
  the anchor/starvation family (§B.1) that F-REANCHOR and roadmap 017 now address —
  but that equivalence is UNPROVEN.
- **Still open:** whether the drag burst measurably delays writes (J-3, T-9). The
  original reproduction predates tonight's telemetry; it has never been re-run against
  a build that could see it.

### C.2 BT rate-flap churn (connect/disconnect, HFP)

- **Fixed-tonight:** the rebuild storm (F-SETTLE: exactly ONE whole-system rebuild on
  BT connect, 34 ms create — live finding #1); the reentrant-monitor crash; the
  desync-after-rebuild (F-REANCHOR + TapReanchor evidence-based reset).
- **Still open, with owners:** residual ~0.5 s stutter = 4 serialized aggregate
  destroy/creates in ~500 ms (3 metering taps + WS) — **J-2, this doc**. The
  16 kHz HFP corpse-pin (rebuild during BT teardown captured transient HFP state for
  16 s until the rate listener self-healed — live finding #4) and the app↔BT
  rebuild oscillation under a mic trigger (live finding #6) — **roadmap 019 + the
  rate-pin plan** (`docs/plans/PLAN-CONSISTENT-MAINOUT-RATE-PIN.md`) own that fix
  surface; this doc only coordinates (§K).

### C.3 Steady-state degradation

No user action, audio nominally healthy — and `write_cadence_drift` shows
`deficitTotalSeconds` climbing **~3.3 ms/s, continuously, with dead-regular ~11.6 ms
write gaps** (live finding #2). Equivalent to one 512-frame buffer per ~3.5 s;
predicts ~1 s of added latency per 5 minutes. **Mechanism source UNIDENTIFIED — the
top open item of this plan (J-1).**

---

## D. Ranked candidate causes for the remaining judder

Each: mechanism · anchor · falsifiable prediction · status
(**fixed-tonight** / **in-flight** / **open**).

### J-1 — Continuous ~3.3 ms/s anchor slide, source unidentified — **open, TOP PRIORITY**

**Measured:** `write_cadence_drift` `deficitTotalSeconds` grows ~0.020 s per ~6 s with
dead-regular ~11.6 ms inter-write gaps and no stalls (live 2026-07-29, build e960a7b).
Deficit direction = schedule-LATER = genuine missing audio or mis-accounting, NOT
device-clock ppm error (crystal error is 20–100 ppm ≈ 0.02–0.1 ms/s, 30–150× too
small, and its sign is opposite).

**The deduction that shapes the measurement:** a *whole-buffer* loss every 3.5 s would
appear as a ~23 ms gap outlier every 3.5 s. The gaps are dead-regular at ~11.6 ms
(`send_sched gap_max_ms` ≈ 11.8 healthy). Therefore the deficit accrues **inside the
writes** — each write carries slightly less audio than its wall spacing — or **inside
the accounting**. That already *disfavors* the discrete-loss candidates (IOProc cycle
skips, `snapshotLock.try` misses, enqueue failures), which all present as gap
outliers.

Candidate mechanisms, in the order the measurement should discriminate:

1. **Converter under-emission** — `AVAudioConverter` systematically emitting fewer
   output frames than `ratio × input` (`convertToAirPlayPCM`,
   `NativeCaptureCoordinator.swift:2883-2940`; output capacity capped at
   `frameCount*ratio + 1`, single-input `.noDataNow` drain contract). R2a flagged
   exactly this as S3.
2. **Accounting rate mismatch** — `WriteCadenceTracker.record(samples:sampleRate:)`
   (`AirPlayEngine.swift:1908`, fed at `:1194`) computing `audioSeconds` at a rate
   that disagrees with what the samples actually represent, i.e. the slide is partly
   or wholly a **measurement artifact**.
3. **IOProc under-delivery** — buffers carrying fewer frames than the device period
   (would conserve gap regularity while shorting content).
4. **Backpressure refusals counted as delivered** — known accounting hole,
   `cadence.record` at `:1194` runs before `admit` at `:1218`. **I1 is fixing this
   (§F)** — it is a confounder remover, not the likely 3.3 ms/s source (backpressure
   at steady state should be zero).

**Falsifiable predictions:**
- If the slide is REAL: owner-measured click-to-sound latency grows by exactly
  `deficitTotalSeconds` (~1 s per 5 min) — T-4's stopwatch run confirms; and one
  stage boundary in T-2's conservation counters will show the loss.
- If the slide is ACCOUNTING: all stage boundaries conserve, latency does NOT grow,
  and the fix is in the tracker, not the audio path.
- If T-2 shows conservation *and* T-4 shows growth: the loss is below the engine
  write (vendored sender), and the investigation moves to `airplay_write`'s drain.

**Status: open.** Tasks T-2, T-3, T-4; fix task F-1 gated on them.

### J-2 — Serialized aggregate destroy/create storm on device transitions — **open**

**Mechanism:** every live tap owns a private aggregate on the same physical device;
a device transition tears down and recreates all of them back-to-back on serial
queues. Live finding #1 tied this to an audible artifact: BT connect = exactly one
WS rebuild (34 ms, F-SETTLE working) but **~0.5 s residual stutter matching 4
serialized aggregate destroy/creates in ~500 ms (3 metering-only taps + WS)** —
first live correlation of R4's C5.

**Anchor:** `aggregate_create`/`aggregate_destroy` telemetry
(`NativeCaptureCoordinator.swift:2296/:2682`, per-app mirror
`PerAppCaptureCoordinator.swift:1025` region); metering-only tap lifecycle
(`NativeBackend` metering reconcile on the captureControlQueue funnel).

**Falsifiable prediction:** with the popover CLOSED (metering taps torn down), the
same BT connect produces a single 34 ms rebuild and the residual stutter shrinks or
vanishes; with it open, stutter scales with metering-tap count. T-8 is that A/B.

**Status: open.** Fix F-2 (defer/coalesce metering-tap rebuilds out of the
transition window) gated on T-8.

### J-3 — Volume-drag engine-loop occupancy — **open**

**Mechanism:** a drag mirrors to N devices at UI tick rate; each write costs two
engine-loop closures (`AirPlayEngine.swift:1026-1046`) on the same loop pacing
`airplay_write`; the control socket those syncs leave on is BLOCKING
(`shims/misc.c:358`) so a full sndbuf stalls the loop outright.

**Falsifiable prediction:** during a scripted 10 s drag against 1 vs 2 devices,
`send_sched` wake-latency/gap percentiles rise measurably with N; if they stay flat
while judder is audible, the mechanism is receiver-side (Sonos DACP handling) and
our loop is exonerated.

**Status: open.** T-9 measures; F-3 (non-blocking control/timing sockets + EAGAIN
tolerance, a small ledgered vendored diff) gated on it.

### J-4 — BT/HFP family: transient-state rebuilds and oscillation — **open, owned elsewhere**

**Mechanism:** rebuilds during BT renegotiation capture transient HFP state (16 kHz
corpse-pin, 16 s, live finding #4 — NEW defect: treat 16000 Hz as a settling marker,
defer rebuild) and our own aggregate IO can prolong HFP (input side unrestricted —
oscillation, live finding #6).

**Anchor:** `createAggregate` (`NativeCaptureCoordinator.swift:2277-2296` region);
live findings #4/#6/#7.

**Falsifiable prediction:** rate-pin + settle-marker means a BT disconnect/mic
trigger never yields a >1 s window of 16 kHz capture (`create_and_start_done
rate=16000` disappears from telemetry).

**Status: open — fix surface owned by `PLAN-CONSISTENT-MAINOUT-RATE-PIN.md` +
roadmap 019.** This plan must not touch it (§K).

### J-5 — Blocking locks on the RT delivery path — **open**

**Mechanism:** converter `lock.lock()` (`NativeCaptureCoordinator.swift:2884`) and
`WriteBacklogGuard` (`AirPlayEngine.swift:2029`, os_log inside the lock) are the two
remaining blocking locks reachable from delivery threads; a rebuild holding the
converter lock makes the delivery thread WAIT (priority inversion) instead of
dropping.

**Falsifiable prediction:** judder-under-churn (rebuilds, connects) correlates with
`send_sched` gap OUTLIERS; tonight's dead-regular steady-state gaps say this is NOT
J-1's mechanism. If T-2's counters show stalls only inside rebuild windows, this is
the cause of churn-judder specifically.

**Status: open.** Fix F-4 gated on outlier evidence.

### J-6 — RT-path heap traffic, no autoreleasepool — **open, hygiene-class**

**Anchor:** §B.2 (9–11 heap ops/buffer; zero `autoreleasepool`).
**Falsifiable prediction:** allocation stalls present as scattered gap outliers under
memory pressure, never as a dead-regular deficit. **Status: open** — measure before
touching (piggybacks on T-2's counters); F-5 is deliberately last.

### J-7 — PTP software timestamping on a non-RT thread — **open**

**Anchor:** §B.4 (`ptp_msg_handle.c:960-965`, `daemon.c:577`).
**Falsifiable prediction:** PTP-caused judder quantizes to 125 ms (≤8 Hz) — cleanly
separable by ear/log from the ~1.01 s anchor quantum (§J.2). Multi-room drift-apart
implicates PTP/receiver, never the anchor (anchor skew is common-mode across
receivers).
**Status: open.** T-10 classifies; F-6 (timestamp-after-send + thread priority)
gated on a 125 ms signature actually being observed.

### J-8 — Anchor slide from drops/rebuilds with no mid-session re-anchor — **split: fixed-tonight / owned by 017**

**Mechanism (proven, §B.1):** drops and rebuild holes slide the receiver schedule
later, permanently; nothing re-anchors mid-session except
`resetAirPlaySessionForWholeSystem` (`NativeBackend.swift:2563`), which has exactly
two triggers (`:1390` device/rate rebuild, `:2020` synced-local churn).

- **Fixed-tonight:** device/rate rebuilds and any rebuild that *demonstrably*
  re-anchored now reset (TapReanchor, `NativeCaptureCoordinator.swift:1238-1253`;
  F-REANCHOR flush-first with honest issued-flag + fallback,
  `AirPlayEngine.swift:1005`, `NativeBackend.swift:2599-2659`).
- **Owned by roadmap 017:** the producer-starvation gap (writes stop → anchor
  freezes → permanent skew) — `PLAN-REDIRECT-FOLLOW-MAIN-SILENCE.md` C1, with its
  25/25 telemetry proof. **Its hard constraint is imported here as binding (§K.2):
  any write-cadence-triggered re-anchor must threshold on a SINGLE gap, never on
  cumulative deficit — J-1's chronic slide would thrash a cumulative trigger.**
- **Remaining here:** the chronic slide itself = J-1.

**Status: fixed-tonight (rebuild family) / open-elsewhere (starvation, 017) /
open-here (chronic slide, J-1).**

### J-9 — Unverified HAL IOProc priority claim — **open, cheap to kill**

**Anchor:** `EngineThread.swift:182-188` (audit comment: "HAL invokes the IOProc
block at real-time priority regardless of the DispatchQueue's declared QoS");
delivery queues `.userInitiated`.
**Falsifiable prediction:** a one-shot pthread introspection inside the IOProc block
reports the actual policy/priority. If it is NOT time-constraint, the entire
delivery chain is load-sensitive and PLAN-AUDIO-THREAD-SCHEDULING's H2 reopens.
**Status: open.** T-5.

---

## E. Fixed-tonight ledger — `main` @ e960a7b (live-verified 2026-07-29)

Nobody re-investigates these. Owner checklist: tests 1, 2, 3, 6, 7 PASS; 4/5 pass
per owner ("everything in the test works").

| Fix | What it is | Live evidence |
|---|---|---|
| **F-SETTLE** | `DefaultOutputDeviceMonitor` settle window absorbs the BT negotiation burst | BT connect 19:15:23 = exactly ONE WS rebuild, 34 ms create |
| **F-REBIND** | Rebind-recovery chain with ownership bow-out, backoff, `.streamHealth` events | rebind success after the HFP self-heal, 19:28:05 |
| **F-REANCHOR** | Flush-first session re-anchor with honest "issued" flag + `removeOutput`→`addOutput` fallback; fixes the flush **device-vs-session state mismatch** (`device->state` vs `device->session->state`, `airplay.c:4298`; `AirPlayEngine.swift:985-1024`) | `session_reset recovery=flush_first` + `rebind_recover_flush outcome=issued` in the live ledger |
| **Make-before-break WS rebuild** | Device-identity rebuilds overlap old/new taps; includes the **onBuffer-before-createAndStart** fix (`NativeCaptureCoordinator.swift:1162-1171`) | one-rebuild BT connect above |
| **TapReanchor evidence-based reset** | Reset decision compares outgoing vs incoming device/rate — never trusts `RebuildCause` alone (`NativeCaptureCoordinator.swift:1238-1253`) | `rebuild_reanchored` event live |
| **DefaultOutputDeviceMonitor consolidation** | ONE process-wide listener pair, `TapRebuildDecision` per subscriber — kills the multi-tap rebuild storm loop AND closes R4-D2 (per-app unguarded listener); plus the reentrant-`queue.sync` deadlock fix | no rebuild storm on any transition tonight |
| **send_sched re-arm** | Dead-since-birth scheduling telemetry now fires on every capture-gate edge (`NativeBackend.swift:5531`) | send_sched lines throughout tonight's ledger |
| **write_cadence / write_backlog on BOTH paths** | `write_cadence_drift` + `write_backlog_drop` for stream 0 and per-app (`NativeCaptureCoordinator.swift:1887/:1912`, `NativeBackend.swift:3216/:3257`) | J-1 was MEASURED with it |
| **Aggregate lifecycle telemetry** | `aggregate_create`/`_rate_delayed`/`_destroy`, correlation ids (`:2296/:2323/:2682` + per-app) | J-2's 4-in-500 ms storm was counted with it |
| **Pause-on-call REMOVED** | Flawed premise; deleted in `d5d2414` rather than left dormant — removes the **call-gate edge state on the tap** (third split-ownership critical) | n/a (deletion) |
| **HFP self-heal observed** | 16 s 16 kHz corpse-pin ended by the rate listener catching 44100 → rebuild + session_reset + rebind — pipeline self-healed; the defect that remains is J-4 | live finding #4 |

Also live-adjudicated tonight, NOT ours: Spotify pausing itself on BT disconnect is
macOS app behavior on output-device removal (finding #5) — possible UX hint later,
not a defect.

---

## F. In-flight — do NOT touch these surfaces

**I1 (parallel agent, branch `claude/judder-instrumentation-remainder`, worktree
just started)** is implementing exactly four items. List them as in-flight;
every task in §H stays off these surfaces until I1 merges:

1. **Cadence accounting fix**: `cadence.record` (`AirPlayEngine.swift:1194`) runs
   before `writeBacklog.admit` (`:1218`), so refused writes count as delivered —
   I1 corrects the accounting (record after admission, or record refusals for
   subtraction). Removes J-1's confounder #4.
2. **Converter drop-site counters**: grouped-by-reason atomic counters on the ~7
   nil-return paths in `convertToAirPlayPCM` (`NativeCaptureCoordinator.swift:
   2883-2940`), surfaced through the existing whole-system sampler, emitted
   only-when-nonzero.
3. **`scripts/make-app.sh` LSEnvironment passthrough (~:542)**: add
   `AIRPLAY_AUDIO_DIAG` and `AIRPLAY_DEBUG_LATENCY` so the debug gates are reachable
   in `open`-launched bundles (today they are structurally unreachable — R3).
4. **`SyncedLocalSink` ring-full drop counter**: the discarded `ring.write` result
   (`SyncedLocalSink.swift` enqueue), atomic count, off-thread only-when-nonzero
   emission.

**I1's hard rule is inherited by every instrumentation task in this plan:**
nothing allocates, takes a blocking lock, or logs on delivery/RT threads —
counters on-thread, emission off-thread, only-when-nonzero.

**Roadmap 017** owns the single-gap write-starvation trigger (T-F1 of
`PLAN-REDIRECT-FOLLOW-MAIN-SILENCE.md`) and its `EngineSink` surface. Not ours.

---

## G. The split-ownership sweep (dedicated section)

**The failure class:** a decision reads state whose LIFETIME disagrees with the
decision's subject — long-lived owner state consulted about a rebuildable object, or
an edge-assigned latch that a rebuild wrongly keeps or silently loses. It produced
**three silent-forever criticals** in this family, all now closed:

1. **Flush device-vs-session mismatch** — the vendored flush no-ops unless
   `device->session->state == STREAMING` (`airplay.c:4298`), a per-SESSION field; a
   guard on the long-lived `device->state` diverges and lets the no-op masquerade as
   success. Closed by the honest issued-flag (`AirPlayEngine.swift:985-1024`).
2. **onBuffer after createAndStart** — the IOProc snapshots `onBuffer` by value at
   start; a handler assigned after start is never seen and the tap delivers nothing
   forever. Closed by wiring before start (`NativeCaptureCoordinator.swift:1162-1171`).
3. **Call-gate edge on the tap** — pause-on-call latched call/HFP state on the
   rebuildable tap object; a rebuild could immortalize a transient. Closed by
   deleting the feature (`d5d2414`).

Three instances of one class is a pattern, not a coincidence. **T-1 sweeps the whole
class**: enumerate every stored property on

- `CoreAudioSystemTap` (`NativeCaptureCoordinator.swift:2051` — e.g.
  `tappedOutputDeviceID` `:2063`, `machToMonotonicOffsetNanos` `:2107`, the
  aggregate-telemetry correlation id `:2079`, `onBuffer`/`onDefaultDeviceChanged`
  wiring, monitor subscription tokens),
- `CoreAudioProcessTap` + per-app slot state (`PerAppCaptureCoordinator.swift`),
- `EngineSink` + `AVFormatConverter` (`converter`, formats, the published snapshot),
- the engine's per-output state (`knownOutputs`, `boundStreamId`, `liveDeviceState`
  vs vendored `session->state`, `WriteBacklogGuard` per-stream accounting — e.g.
  does a FLUSH release the guard's in-flight accounting, or can a flushed stream's
  budget stay debited?),

and for each field answer: (a) whose lifetime is it (process / coordinator / tap
instance / session / aggregate)? (b) edge-assigned or continuously reconciled?
(c) which decisions read it, and do THEY live on the same lifetime? (d) what happens
to it across `recreateTap`, `teardown`/`createAndStart`, `reconcileCaptureGate`
stop/start (the 7th path, `NativeBackend.swift:5555`), and a flush/rebind?
**Any field that is edge-written on one lifetime and decision-read across another is
a finding.** Deliverable: a disposition table (OK-by-design / doc-only /
candidate-critical), filed as a note under `dev/notes/`, criticals promoted to
roadmap entries.

---

## H. Task list

Investigation phases are visibly separate from fix phases. Every task is marked
**[read-only]**, **[code-writing]**, or **[owner-live]**. House rules for every
**[code-writing]** task: own worktree · `main` is merge-only · **no merge without
explicit owner go-ahead** · **agents never run live audio tests** (owner-only) ·
**allocation-free on RT paths** (I1 rule, §F) · full suite via `scripts/run-tests.sh`
before commit (Guard 4 enforces).

### Phase 1 — INVESTIGATION (no fixes)

**T-1 — Split-ownership lifetime sweep** *(opus / high)* **[read-only]**
Execute §G exactly. Rationale for tier: the three shipped criticals were each missed
by multiple reviews; finding lifetime mismatches in 5k-line files is judgment-dense,
zero-code work where a false "all clear" is expensive.
*Depends: nothing. Off I1's surfaces (reads only).*

**T-2 — Stage-boundary sample-conservation counters (the J-1 discriminator)**
*(sonnet / high)* **[code-writing]**
Atomic cumulative counters at three boundaries, sampled through the existing
`EngineSink` cadence sampler (same 500-write throttle, new fields on
`write_cadence_drift` or one sibling event): (i) IOProc frames-in + expected frames
from `mHostTime` deltas (`CoreAudioSystemTap` IOProc block, `:2349-2400`);
(ii) converter frames-in / frames-out cumulative (success path only — I1 owns the
nil/drop paths); (iii) samples handed to `engine.write` (`EngineSink.write`,
`:1881-1885`). The three deltas name the losing stage per §D J-1's candidate list.
Honor the I1 RT rule strictly.
*Depends: **I1 merged** (shares `NativeCaptureCoordinator.swift` and the converter
region). Rationale: mechanical instrumentation but on the RT path with a merge-order
hazard — mid-tier model, high care.*

**T-3 — Converter conservation test + tracker accounting audit** *(sonnet / medium)*
**[code-writing — test/target files only]**
(a) Hermetic test: drive `AVFormatConverter` with a synthetic known-length stream
(≥10 s worth, both 48 k→44.1 k and 44.1 k passthrough) and assert
`sum(out) ≈ ratio × sum(in)` within one frame per buffer — R2a's S3, finally run.
(b) Read-only audit of `WriteCadenceTracker.record` (`AirPlayEngine.swift:1888-1908`
onward) + its call site `:1194`: confirm `samples`/`sampleRate` agree with the actual
payload semantics on both the WS and per-app paths; document the arithmetic in the
test file. New test files only — no production-code collision with I1.
*Depends: nothing.*

**T-4 — Owner steady-state ruler run** *(owner / live)* **[owner-live]**
One 10-minute quiet-machine stream. At t≈0 and t≈10 min, measure click-to-sound
latency by stopwatch (or camera) and note `deficitTotalSeconds` at both instants
(§J.1 grep). **If latency growth ≈ deficit growth → the slide is real (audio path).
If latency is flat while deficit grows → accounting artifact (tracker).** This single
run halves J-1's candidate space.
*Depends: nothing (today's telemetry suffices). Combine with T-8/T-9/T-10 in one
live session.*

**T-5 — Measure the HAL IOProc thread's actual scheduling** *(sonnet / low)*
**[code-writing — diagnostic, env-gated]**
One-shot, env-gated (`AIRPLAY_AUDIO_DIAG`) pthread introspection
(`pthread_mach_thread_np` + `thread_policy_get`, or `pthread_get_qos_class_np`)
inside the WS IOProc block and once on the delivery queue; log once per tap
generation, off-thread. Kills or confirms `EngineThread.swift:182-188`'s claim
(J-9). Never inherit the claim.
*Depends: I1 merged (same file). Rationale: small, but touching the IOProc block
demands the RT rules.*

**T-6 — First-buffer-after-rebuild latency probe** *(sonnet / medium)*
**[code-writing]**
In `recreateTap`'s commit path, record create-done→first-`handleBuffer` latency per
tap generation (counter on RT path, emission off-thread). Discriminates
"capturing-but-not-delivering" states — `.capturing` is set on create success, not
first buffer — the C3-family blind spot named in the redirect plan. Open and
unowned per coordination; belongs here.
*Depends: I1 merged (same file). Serialize with T-2/T-5 (same file) — one agent or
sequential.*

**T-7 — All-zero-PCM discriminator on the WS path** *(sonnet / low)* **[code-writing]**
Cheap RMS>0 flag per sampling window on the WS delivery path (piggyback on the
existing level computation if metering is active; otherwise a comparison against
zero during the copy loop — NO new pass over samples). Distinguishes "tap delivering
silence" from "tap not delivering" — the missing discriminator for the
live-but-silent-tap family. Open and unowned per coordination.
*Depends: I1 merged; serialize with T-2/T-5/T-6 (same file).*

**T-8 — Owner A/B: metering-tap storm (J-2)** *(owner / live)* **[owner-live]**
BT connect twice: once with the popover CLOSED (no metering taps), once OPEN.
Compare audible stutter and count `aggregate_destroy`/`aggregate_create` bursts in
the transition window (§J.1 grep). Confirms/refutes J-2's prediction.
*Depends: nothing.*

**T-9 — Owner volume-drag occupancy run (J-3)** *(owner / live)* **[owner-live]**
10 s continuous system-volume drag while streaming, against 1 device and then 2.
Watch `send_sched` gap/wake percentiles and `write_cadence_drift` deltas across the
drag window. Rising-with-N implicates our loop (J-3); flat-but-audible implicates the
receiver.
*Depends: nothing.*

**T-10 — Owner ear/log classification of any live judder (J-7 vs J-8)**
*(owner / live)* **[owner-live]**
When judder is audible, classify its periodicity per the §J.2 table (by ear, or by
timing artifact events in the log). 125 ms quantization arms F-6; ~1.01 s confirms
anchor; exactly 1.000 s falsifies anchor.
*Depends: nothing.*

**T-11 — Engine-probe bisect (capture-side vs engine-side), owner-run**
*(owner / live, agent prepares nothing — recipe in §J.3)* **[owner-live]**
The structural bisector: `engine-probe` feeds the engine from a FILE, bypassing
capture entirely. Judder present under the probe ⇒ engine/transport/receiver;
absent ⇒ capture side. Run idle and under `load-gen.sh 16`.
*Depends: nothing. Recipe: §J.3.*

### Phase 2 — FIX (every task gated on a named investigation result)

**F-1 — Fix J-1's identified mechanism** *(opus / high)* **[code-writing]**
Cannot be specified until T-2/T-3/T-4 name the stage. Placeholder disciplines:
if converter → fix emission/drain (and add the conservation test as a regression
gate); if accounting → fix the tracker and RE-BASELINE all deficit-derived claims
(017's telemetry evidence included); if IOProc → escalate to the rate-pin/aggregate
family with measurements in hand. **Never** "fix" J-1 by adding a re-anchor trigger
on cumulative deficit — §K.2's imported constraint forbids it.
*Depends: T-2 + T-3 + T-4. Gate: owner reviews the discriminating evidence first.*

**F-2 — Metering-tap storm mitigation (J-2)** *(sonnet / medium)* **[code-writing]**
Gated on T-8 confirming. Direction: defer/coalesce metering-only tap rebuilds until
the WS transition settles (they are diagnostic-grade consumers; a late meter is
free), or serialize them behind the WS rebuild with a settle delay. Surface:
`NativeBackend` metering reconcile + `PerAppCaptureCoordinator` metering path — NOT
the primary routing taps.
*Depends: T-8. Watch §K.3 file contention.*

**F-3 — Non-blocking control/timing sockets + EAGAIN tolerance (J-3)**
*(sonnet / medium)* **[code-writing — vendored diff, ledgered]**
Gated on T-9 implicating our loop. `bind_one` (`shims/misc.c:358`): stop restricting
`O_NONBLOCK` to `SOCK_STREAM` (shim-only); then make the control-path send sites
EAGAIN-tolerant (count + drop, mirroring the data-socket Entry-4 discipline) — small
vendored hunks, `VENDORED-DIFFS.md` entry, per the byte-identical rule's exception
process. Consider `SO_SNDBUF` sizing for the control socket in the same pass.
*Depends: T-9.*

**F-4 — Converter lock + WriteBacklogGuard off the blocking path (J-5)**
*(opus / high)* **[code-writing]**
Gated on outlier evidence (T-2 stall windows / send_sched outliers under churn).
Converter: follow the `snapshotLock` publish/try pattern already proven in this file
— an immutable converter box swapped atomically, RT side try-reads and drops on
miss. WriteBacklogGuard: move `os_log` out of the lock unconditionally (that half is
evidence-free hygiene, allowed); reshape admission to try-discipline only if
measurements demand. RT-path crash risk on a torn converter swap is the failure
mode — highest-care tier.
*Depends: T-2 evidence. Serialize with anything touching `NativeCaptureCoordinator.swift`.*

**F-5 — RT-path allocation diet (J-6)** *(sonnet / medium)* **[code-writing]**
Deliberately LAST. Gated on T-2/T-5 showing allocation-shaped stalls. Preallocate
the per-buffer channel assembly and converter buffers per tap generation; add
`autoreleasepool` only where measurement shows ObjC autorelease traffic.
*Depends: T-2, T-5, F-1 landed (don't churn the file mid-measurement).*

**F-6 — PTP timestamp-after-send + helper thread priority (J-7)**
*(opus / medium)* **[code-writing — vendored/helper C]**
Gated on T-10 observing a 125 ms-quantized signature. Sample the Sync timestamp
immediately after `sendto` returns (or bracket midpoint) and raise the PTP thread
priority. Privilege boundary (root helper) — small diff, careful review.
*Depends: T-10.*

**F-7 — Docs + AGENTS.md + roadmap close-out** *(haiku / low)* **[code-writing]**
Update `AudiouterCore/AGENTS.md` / `AirPlayEngine/AGENTS.md` for whatever landed
(≤300-word budget, Guard 2 symbol check), append roadmap 016 notes, retire this
doc's superseded sections. Rationale: mechanical, but Guard-2-sensitive.
*Depends: all landed fixes.*

---

## I. Waves + critical path

**Hot-file serialization:** `NativeCaptureCoordinator.swift` → I1, T-2, T-5, T-6,
T-7, F-2(part), F-4, F-5 — everything touching it is SEQUENTIAL, and all of it
waits for I1. `NativeBackend.swift` → F-2 + unmerged-branch contention (§K.3).
Vendored `sender/`+`shims/` → F-3, F-6 (disjoint files, can parallel).

| Wave | Tasks | Notes |
|---|---|---|
| 0 (now) | T-1 ‖ T-3 ‖ (T-4, T-8, T-9, T-10 as ONE owner live session) | None touch I1 surfaces; owner session needs only tonight's build |
| 1 (I1 merged) | T-2 → T-5 → T-6 → T-7 (one agent, sequential, same file) | The instrumentation build for wave 2 |
| 2 (owner) | Repeat T-4 ruler on the wave-1 build; T-11 bisect if wave-0/1 evidence is ambiguous | One quiet-machine session |
| GATE | **Owner + planner review: which J-1 mechanism did the evidence name?** | Nothing in Phase 2 dispatches before this |
| 3 | F-1 (critical path) ‖ F-3 (vendored, disjoint) ‖ F-2 (if T-8 confirmed) | F-1 owns `NativeCaptureCoordinator.swift`/engine as needed |
| 4 | F-4 → F-5 (same file, in that order) ‖ F-6 (if armed) | |
| 5 | F-7 · owner live verification of everything landed | |

**Critical path:** I1 merge → T-2 → owner ruler (T-4 rerun) → GATE → F-1 → owner
verify. Everything else is parallel garnish. **The single highest-information action
available TODAY is the wave-0 owner live session** — four measurements, one sitting,
no new code.

---

## J. Owner run-books (plain language)

### J.1 Always-on posture — what ships in every build of e960a7b+

Telemetry file: `~/Library/Logs/Audiouter/telemetry.jsonl` (rotates to
`telemetry.jsonl.1`; 10 MB total). Always on — no env vars needed.

Watch live while reproducing anything:

```
tail -f ~/Library/Logs/Audiouter/telemetry.jsonl | grep --line-buffered -E \
  'write_cadence_drift|send_sched|session_reset|rebuild_reanchored|rebind_recover_flush|aggregate_|exclusion_changed|device_change|create_and_start'
```

After the fact, the questions and their greps:

| Question | Command |
|---|---|
| Is the anchor sliding, and how fast? | `grep write_cadence_drift ~/Library/Logs/Audiouter/telemetry.jsonl \| tail -20` — read `deficitTotalSeconds` growth per timestamp. Healthy = flat; the known open defect = ~0.02 per 6 s. |
| Did writes stall (single gap)? | `grep send_sched ... \| tail -20` — `gap_max_ms` ≈ 11.8 is healthy cadence; hundreds/thousands = a starvation window (017's territory). |
| Did anything re-anchor? | `grep -E 'session_reset\|rebuild_reanchored\|rebind_recover_flush' ... \| tail` |
| Rebuild storm? | `grep -E 'aggregate_create\|aggregate_destroy' ... \| tail -30` — count creates/destroys inside one transition second. |
| What rate did the tap come up at? | `grep create_and_start_done ... \| tail` — `rate=16000` is the HFP marker. |

Engine-side probes (os_log, independent of the JSONL):

```
log stream --predicate 'subsystem == "com.airplayengine" AND category == "write-scheduling"'
log stream --predicate 'subsystem == "com.airplayengine" AND category == "write-cadence"'
```

Extra debug gates (once I1's make-app.sh passthrough lands): build with
`AIRPLAY_AUDIO_DIAG=1` / `AIRPLAY_DEBUG_LATENCY=1` set at `make-app.sh` time; until
then those gates are unreachable in `open`-launched bundles. Always launch the
bundle via `open` (raw exec inherits Terminal's TCC and breaks the tap grant).

### J.2 The ear-discriminator table

When you HEAR judder, its rhythm names the suspect before any log is opened:

| What you hear / measure | Points at | Why |
|---|---|---|
| Steps/skips at ~**1.0-second-ish** intervals (strictly 1.006–1.014 s) | Anchor arithmetic (sync cadence) | Re-anchor quantum = 44352–44704 delivered samples (§B.1) |
| Period of **exactly 1.000 s** | **PTP announce/signaling — FALSIFIES anchor** | PTP announce interval is 1000 ms; sync quantum can never be 1.000 |
| Artifacts quantized to **125 ms** (up to 8/s) | PTP Sync path (J-7) | Sync interval 125 ms; non-overlapping with the ~1.01 s quantum |
| Sudden **"AM-radio" / muffled 16 kHz quality** | HFP capture pin (J-4) | Tap came up at 16000 during BT renegotiation |
| **Click-to-sound latency growing** over minutes, no artifacts | Chronic anchor slide (J-1) | Deficit accrues silently; receivers play ever-later |
| Multiple rooms **drifting apart** from each other | PTP or receiver-side — NOT the anchor | Anchor skew is common-mode: all receivers of a master session step together |
| Brief stutter burst exactly at a BT connect/route change | Aggregate storm (J-2) / rebuild splice | Correlate with `aggregate_*` burst in J.1 |

### J.3 Bisect mode — the engine-probe recipe (from R3, adapted; run by the OWNER only)

`engine-probe` drives the real AirPlay engine from a raw PCM FILE — no tap, no
converter, no coordinator. If judder survives the probe, the capture side is
innocent; if it vanishes, the capture side is guilty. That one bit halves the
search space.

1. **Quit Audiouter first** — PTP ports 319/320 are exclusive; two instances fight.
2. **Build:** `swift build --package-path AirPlayEngine --product engine-probe`
3. **Make a PCM fixture** (none exists in-repo; ffmpeg is already a build dep):
   ```
   ffmpeg -f lavfi -i "sine=frequency=440:duration=600" -ar 44100 -ac 2 -f s16le \
     /tmp/audio-s16le-44100-2ch.raw
   ```
   (Required format: raw interleaved S16LE, 44100 Hz, 2ch. Music via
   `ffmpeg -i song.m4a -ar 44100 -ac 2 -f s16le ...` works too and makes judder
   easier to hear.)
4. **Find the receiver's device id** (colon-hex, from its TXT record):
   ```
   dns-sd -L "<AirPlay device name>" _airplay._tcp
   ```
5. **PTP without the root helper** (probe is a bare CLI, no SMAppService daemon):
   run with `AUDIOUTER_PTP_INPROC_BIND=1` (the documented dev fallback,
   `AirPlayEngine/docs/ptp-helper-design.md` §6.3 option b — no sudo).
6. **Run** (the gate flag is mandatory — without it the probe dry-runs and exits 0):
   ```
   AUDIOUTER_PTP_INPROC_BIND=1 swift run --package-path AirPlayEngine engine-probe \
     --address <receiver-ip> --device-id <colon-hex-id> \
     --pcm /tmp/audio-s16le-44100-2ch.raw \
     --i-have-a-receiver-and-owntone-is-stopped
   ```
   (Arg grammar: `EngineProbeParsing/ProbeArgParsing.swift`; any problem → exit 2.)
7. **Two arms:** once on a quiet machine, once under load —
   `bash scripts/load-gen.sh 16 60` — following the measurement protocol in
   `dev/notes/audio-scheduling-measurement.md` (no `swift test` running anywhere;
   it is itself a load source).
8. **Read the result with §J.2's table**, then §J.1's greps on the same window.

Decision table: judder under probe **and** app ⇒ engine/transport/receiver (J-3,
J-5 engine half, J-7, vendored). Judder under app only ⇒ capture side (J-1
mechanisms, J-2, J-5 converter half). Judder under neither ⇒ it needed real capture
load — rerun the app arm with `load-gen`.

---

## K. Risks + coordination

### K.1 Roadmap ownership boundaries (016–019)

| Entry | Owns | This plan's contract with it |
|---|---|---|
| **016** (this doc) | The judder family: J-1 slide, J-2 storm, J-3 drag, J-5/J-6 RT hygiene, J-7 PTP, J-9 | — |
| **017** redirect/producer-starvation silence (`PLAN-REDIRECT-FOLLOW-MAIN-SILENCE.md`, branch `claude/redirect-follow-main-silence`) | The single-gap write-starvation re-anchor trigger (its T-F1), the `EngineSink` starvation surface, LT-1/LT-2 live tests | Do not duplicate its fix. **Import its hard constraint (K.2).** Share the C1 anchor mechanism (§B.1) — it is the same physics as J-1 at a different rate (9.14 s step vs 3.3 ms/s chronic). |
| **018** volume seed | Connect-volume seeding | **Not present in the ROADMAP.jsonl copy on `claude/redirect-follow-main-silence` @ c28a8b5 (verified: entries 001–017 + 019, no 018)** — being added by the volume-seed planning session. Coordinate before touching any connect/volume-seed surface; J-3's volume work is drag-time loop occupancy, not seeding — keep it that way. |
| **019** BT-HFP oscillation (+ `PLAN-CONSISTENT-MAINOUT-RATE-PIN.md` on main) | J-4's whole fix surface: rate pin, 16 kHz settling marker, output-only sub-device streams | This plan measures and classifies (T-8 partially, ear table) but writes NO code on that surface. |

### K.2 The imported hard constraint (binding on every task here)

From 017: **any write-cadence-derived trigger must threshold on a SINGLE gap, never
on cumulative deficit** — J-1's chronic ~3.3 ms/s slide grows the cumulative deficit
forever, so a cumulative trigger would fire endlessly and thrash healthy sessions
with re-anchors. Symmetrically: if F-1 proves the slide is an accounting artifact,
017's fix must be notified — its LT thresholds and telemetry evidence cite
`deficitDeltaSeconds`.

### K.3 File contention with unmerged branches

`NativeBackend.swift` and `NativeCaptureCoordinator.swift` are hot across:
`claude/judder-instrumentation-remainder` (I1, in flight — §F),
`claude/aggregate-device-wave3` (aggregate default-device takeover, touches
`NativeBackend` + both coordinators), `claude/audio-routing-exception-bug-1ef721`
(gate-ordering, 186-line `NativeBackend` touch), and 017's future fix branch. Every
Phase-2 task must start from fresh `main`, check `git log main..<branch>` for these,
and expect merge-order arbitration by the owner. Do not rebase someone else's
surface away.

### K.4 Other standing risks

- **Live testing is owner-only and single-instance** (PTP 319/320 exclusive; TCC
  grant requires the `open`-launched signed bundle). Agents produce builds and
  greps, never sounds.
- **Measurement hygiene:** `swift test` (especially `--parallel`) is a load source;
  no suite may run during any owner measurement session (`load-gen.sh` protocol).
- **Vendored C stays byte-identical** except ledgered hunks (F-3/F-6 must add
  `VENDORED-DIFFS.md` entries; growth of that ledger is a real cost — keep hunks
  minimal).
- **Guard 2** (AGENTS.md symbol check) and **Guard 4** (full suite on Swift
  changes) fire on commit; docs-only commits (like this one) pass Guard 4 trivially
  but Guard 1 still forbids committing on `main`.
- **This doc's own anchors rot.** Every file:line here resolves at e960a7b; any
  agent acting on one later must re-verify it first (docs orient, code decides).
