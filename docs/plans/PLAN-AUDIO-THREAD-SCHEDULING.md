# Plan — Real-time scheduling parity for the AirPlay send path

**Worktree:** `.claude/worktrees/warm-signal-full` · **Branch:** `claude/warm-signal-full`
**Status: NOT EXECUTED. Rev 2 — supersedes rev 1's "just add QoS + workgroup" framing.**
**All decisions resolved (§D). Ready to execute Stage 1 on Alec's go-ahead; Stage 2 is gated on T10.**
**Merge gate:** Alec's explicit go-ahead only. Live verification is Alec-only, on a quiet machine.

Produced via `/plan` (planner agent, opus/high, two rounds). Every finding marked **[measured]** was
produced by a throwaway probe binary run on this M1 / macOS 27.0 machine during planning — not read
off a doc page.

---

## 0. Why this plan exists

**Alec's observation (2026-07-25, live):** playing audio normally on macOS — including Apple's own
AirPlay — never stutters under heavy CPU load, but Audiout's output stutters when the machine is
loaded. Measured at the time: load average 16 on 8 cores, Audiout itself using **2.1% CPU**, and
**zero** error events in its telemetry (no tap failures, no rebuild storm, no capture errors).

So the stutter is a **scheduling** problem, not a logic problem. And Alec's framing of the goal is
the requirement this plan is written against, verbatim:

> *"All I want is that the audio coming out of our system is treated with the exact same priority and
> behaves the exact same way as Apple audio would."*

That is a parity requirement, not a "add some priority and hope" requirement — which is why rev 1's
scope was insufficient and this revision reopens the real-time question rev 1 had excluded.

---

## A. End state

Every byte of audio Audiout sends leaves on a thread the kernel treats the way it treats Apple's
own audio: real-time priority with an explicit deadline, joined to the audio device's workgroup, and
*structurally* incapable of unbounded work.

Reaching that means **splitting the engine thread by ROLE, not by stream** — a control thread that
keeps today's libevent/RTSP/pairing machinery exactly as it is, plus a dedicated real-time send
thread under `THREAD_TIME_CONSTRAINT_POLICY` that touches no vendored state, takes no locks,
allocates nothing, and only calls `sendto()` on non-blocking sockets.

Ahead of all of it lands a **diagnostic** probe — not merely a before/after counter — plus a
reproducible load generator, because the measurement must discriminate between three candidate
causes before we commit to the expensive half.

---

## B. Verified findings

### B.1 Why one send thread per routed app CANNOT work

The vendored sender's state is **process-wide, not per-stream**. Every item below is walked or
mutated on the send path:

| Global | Where | Why N threads breaks it |
|---|---|---|
| `raop_aes_ctx` | `raop.c:342`, used `2929-2947` | **The decisive one.** A single stateful gcrypt CBC handle: `packet_encrypt` does `gcry_cipher_reset` → `setiv` → `encrypt` on it per packet. Two threads interleaving those three calls produce corrupted ciphertext — garbage audio on every AirPlay 1 receiver, with no error raised anywhere. |
| `airplay_sessions`, `airplay_master_sessions` | `airplay.c:488-489`; walked `2178`, `2262`, `4334`, `4373` | Traversed on every send while the control plane creates/frees sessions → use-after-free. |
| `raop_sessions`, `raop_master_sessions` | `raop.c:362-363` | Same. |
| `evbase_player` | ONE `struct event_base *`, `shims/outputs.c:43`, `extern`'d by `airplay.c:472`, `raop.c:337` | The whole cluster is built around exactly one base. N bases needs N copies of every global above. |
| `airplay_timing_svc` / `airplay_control_svc` / `raop_*_svc` | `airplay.c:475,478`; `raop.c:349,352` | Shared UDP sockets whose read events live on the one base. |
| `keep_alive_timer` | `airplay.c:484`, `event_pending` + `evtimer_add` @ `4379-4380` | One `struct event`; concurrent `evtimer_add` from N threads is libevent misuse. |
| `device_list`, `outputs_cb_register`, `outputs_state_ring` | `shims/outputs.c:48, 369, 411` | Ours, but equally process-wide. |

The package's own stated invariant agrees: *"the whole vendored cluster assumes ONE event_base owned
by ONE thread … with no cross-thread calls into the cluster"* (`EngineThread.swift:3-6`, restated in
`AirPlayEngine/AGENTS.md`).

**Verdict: making the sender N-thread-safe is a FORK of the vendored files, not a diff.** It would
touch session lifetime, the cipher context, the service sockets and the event base across
`airplay.c` (4500 lines) and `raop.c` — against the standing rule that vendored sources are *"edited
only as a last resort, minimally … otherwise byte-identical, so upstream diffs stay legible."*
`VENDORED-DIFFS.md` has 3 entries today. This would not be a fourth; it would end the ledger's
usefulness.

### B.2 What IS separable — and it is a clean line

| # | Finding | Evidence |
|---|---|---|
| F19 | All per-stream send state is **already** per-`master_session`: `input_buffer`, `encode_ctx`, `encoded_buffer`, `rtp_session`, `cur_stamp`, `rawbuf`, `stream_id`. | `struct airplay_master_session`, `airplay.c` |
| F20 | `rtp_common.c` has **zero file-scope statics** — RTP packetization is pure per-`rtp_session`. | `grep '^static' sender/rtp_common.c` |
| F21 | **The socket send is the only truly separable stage**, and it is trivially isolable: `packet_send` is encrypt-then-`send(fd, bytes, len)`. Nothing after encryption touches shared state except the fd. | `airplay.c:2036-2087`; `raop.c:2959-2971` |
| F22 | **Allocation on the send path:** `airplay.c packet_encrypt` does `malloc` + `free` **per packet**. `rtp_packet_next` mallocs only while filling its 1000-packet ring, then reuses → amortises to zero after ~8s. RAOP encrypts **in place**, allocating nothing. | `airplay.c:1998-2034`; `rtp_common.c:130-138, 356`; `raop.c:2947` |
| F23 | **Making the data sockets non-blocking costs ZERO vendored diff.** `net_connect` lives in `shims/misc.c` — ours. Only two callers pass `SOCK_DGRAM` (`airplay.c:3187`, `raop.c:3497`); the third is `SOCK_STREAM` (`airplay_events.c:767`). A shim-local "DGRAM ⇒ leave non-blocking" rule fixes both data sockets. | `misc.c:171-291`, blocking-restore @ `236-244` |
| F24 | **But EAGAIN handling DOES cost a vendored diff.** Both senders treat `sent < 0` as fatal → `deferred_session_failure`. A transient `EWOULDBLOCK` would tear down a healthy session. Two small hunks. | `airplay.c:2063-2071`; `raop.c:2966-2971` |

### B.3 Real numbers for the time-constraint arithmetic **[measured]**

| Quantity | Value | Source |
|---|---|---|
| Default output nominal rate | 44100 Hz | `kAudioDevicePropertyNominalSampleRate` |
| `kAudioDevicePropertyBufferFrameSize` | **512 frames** | measured |
| **IOProc period** | **512 / 44100 = 11.610 ms → 86.1 cycles/sec** | derived |
| RTP packet size | 352 samples (`AIRPLAY_SAMPLES_PER_PACKET`, `airplay.c:85`) | source |
| RTP packets per IOProc cycle, per stream | 512 / 352 = **1.45** | derived |
| mach timebase (M1) | `numer=125, denom=3` → 41.667 ns/tick → **1 ms = 24 000 ticks** | measured |

> **F25 — a doc bug found in passing.** `AirPlayEngine.swift:1535` claims *"~226 writes/sec for
> 352-sample frames at 44.1kHz."* Both halves are wrong: 44100/352 = 125.3 packets/sec, and the
> actual **write** cadence is the IOProc cadence, 86.1/sec at 512 frames. Fix in T1.

### B.4 The finding that should govern this whole plan

**F26 — sender-side jitter of tens of milliseconds should NOT, on its own, cause an audible
dropout.** AirPlay receivers apply ≥250 ms of buffering, and packets carry RTP timestamps — the
receiver plays by timestamp, not by arrival time. `start_buffer_ms` puts the sender further ahead
still (`AirPlayEngine.swift:1658-1663`).

That leaves **three live hypotheses**, needing different fixes:

- **H1 — send starvation.** Under load-avg 16, a `QOS_CLASS_DEFAULT` thread on a 4P+4E M1 is delayed
  not by tens but by *hundreds* of ms, blowing through the receiver's buffer. → QoS + workgroup + RT.
- **H2 — capture-side underrun.** The tap IOProc misses cycles, or `handleBuffer` stalls on the F12
  lock, so audio never reaches the engine on time. → the F12 lock fix, **not** anything on the send
  thread.
- **H3 — sync-packet drift.** `packets_sync_send` is inline in `airplay_write`; if that call is late,
  sync packets advertise stale positions and the receiver's own scheduling degrades.

**This is exactly why "measure first" was the right call**, and it raises the bar on the probe: it
must be *diagnostic*, discriminating H1/H2/H3 — not one before/after number. Committing to the
expensive Stage 2 before knowing which hypothesis holds would be building the wrong thing carefully.

---

## C. The architecture

### Rejected — (A) one engine thread per routed app
Blocked by §B.1. Requires forking the vendored sender.

### Rejected — (B) N threads sharing the cluster behind a lock
The lock would have to be taken by *libevent-originated* callbacks (RTSP responses, retransmit
reads, `deferred_session_failure_cb`) that free sessions — none of which pass through our shim.
Wrapping each is dozens of vendored hunks; wrapping libevent's dispatch is not reliably possible
(libevent releases `th_base_lock` around callback invocation). **No safe boundary could be
established from source, so it is not being guessed at.**

### Recommended — (C) split by ROLE: control thread + one real-time send thread

```
tap IOProc  (Apple RT thread, unchanged)
      │  enqueue
      ▼
EngineControlThread   ← today's EngineThread. libevent. BEHAVIOUR UNCHANGED.
  event_base_dispatch, RTSP, pairing, getaddrinfo, connect,
  retransmit, keep-alive, session lifecycle,
  outputs_write → airplay_write → ALAC encode → encrypt
      │  packet bytes + fd → lock-free SPSC ring (preallocated)
      ▼
EngineSendThread      ← NEW. THREAD_TIME_CONSTRAINT_POLICY + os_workgroup_join.
  drains ring → sendto() on non-blocking sockets.
  Touches ZERO vendored state. No locks. No malloc. Cannot block.
```

**Why this delivers the requested parity.** Every audio-carrying packet leaves from a thread with
real-time priority, an explicit deadline, and workgroup membership — which *is* what Apple does for
auxiliary audio threads (`AudioWorkInterval.h`, case 1). Thread *count* is a throughput question,
not a parity question: at 86 cycles/sec × 1.45 packets × N streams, one P-core has enormous headroom.

**Why it is safe where (A) and (B) are not.** It honours the one-thread-one-`event_base` invariant
exactly, because the RT thread never enters the cluster. `raop_aes_ctx` stays correctly serialised.
Session lists stay single-threaded. The vendored diff is two `packet_send` hunks plus one
encryption-scratch change — small, local, ledgerable.

### Staging — the gate is the point

- **Stage 1** — probe + load-gen + QoS + workgroup + non-blocking sockets + F12 lock fix. Cheap,
  safe, no architectural change. **Plausibly the entire fix if H1 dominates.**
- **GATE** — Alec's baseline measurement decides whether Stage 2 is needed at all.
- **Stage 2** — the RT send thread. Scheduled only if the numbers justify it.

### Time-constraint parameters, with arithmetic

`thread_time_constraint_policy_data_t` fields are in **mach absolute ticks**, which differ by
architecture (M1 41.667 ns/tick; Intel 1 ns/tick). **Compute at runtime from `mach_timebase_info` —
never hardcode.** Minimum macOS is 14.2, which still supports Intel.

```
ns_to_ticks(ns) = ns * timebase.denom / timebase.numer        // M1: ns * 3/125

period      = IOProc period = 512/44100 s = 11.610 ms
            = 11 609 977 ns → 278 639 ticks (M1)      [1 ms = 24 000 ticks, measured]

computation = 3 × measured p99 in-cycle work.
              Placeholder estimate: 16 sendto() calls (8 streams × ~2 packets)
              at ~5–20 µs each ≈ 320 µs worst case → start at 1.0 ms = 24 000 ticks.
              MUST be replaced by T1's measured p99 — that is task T14.

constraint  = 5.0 ms = 120 000 ticks     (< period, so an occasional overrun still lands in-cycle)

preemptible = TRUE (1)
```

`preemptible = 1` because this thread makes syscalls; a non-preemptible thread blocked in the kernel
is precisely the destabilising case. (Core Audio's own HAL thread uses `0`, but it issues no syscalls.)

### Kernel demotion — the concrete guard

A time-constraint thread that overruns `computation` is **demoted by the kernel failsafe** to a
normal band and restored later. Recoverable, not fatal — but sustained overrun means thrashing.
Four layers:

1. **Headroom** — `computation` ≥ 3× measured p99 (T14).
2. **Structural** — the RT thread only drains a preallocated SPSC ring and calls `sendto` on
   non-blocking sockets. No malloc, no lock, no blocking call — *by construction, not by discipline.*
3. **Self-demotion** — the thread times its own cycle. If overruns exceed K in a rolling window it
   calls `thread_policy_set` back to `THREAD_STANDARD_POLICY`, stays `.userInteractive`, and logs
   `fault` + Telemetry. Audio keeps flowing degraded instead of thrashing. Same "guard before the
   mechanism" precedent the rapid-toggle work set.
4. **Kill switch** — one env var disabling RT entirely (see **NQ3**).

### Scaling and `max_parallel_threads == 4`

The measured `4` is the workgroup's parallelism hint (matching the M1's 4 P-cores), not a cap on
joins. **Under (C) it is moot — there is one RT thread.** It only bites under the rejected (A): more
than 4 concurrent RT threads on 4 P-cores contend for the same cores and *all* miss deadlines, which
is worse than not being RT at all. Recorded so the constraint isn't rediscovered later.

---

## D. Decisions — ALL RESOLVED (Alec, 2026-07-25)

Nothing in this plan is awaiting an answer. Every question below was put to Alec with the trade-offs
stated both ways; these are his rulings, not assumptions.

**The framing decision (supersedes an earlier answer).** Alec first chose "one send thread per routed
app". That was chosen *before* §B.1 existed — the vendored sender's shared `raop_aes_ctx` and global
session lists were not yet known. Re-put to him with that evidence, he chose the shared RT thread.
Recording the reversal deliberately: the original instinct was right about *where* the split belongs
being important; the evidence moved it from per-stream to per-role.

| # | Decision | Consequence to live with |
|---|---|---|
| **NQ1** | **One shared RT send thread** carrying every app's audio (architecture (C)). Per-app threads rejected on §B.1 evidence. | No isolation between apps: if one destination stalls the send loop, it stalls all of them. Small — the loop does <1 ms of work in an 11.6 ms window on a preallocated buffer — but real, and it is the one thing per-app threads would have bought. |
| **NQ2** | **If the measurement points away from the send path, STOP and re-plan** before building Stage 2. | The T10 gate is a hard stop, not a formality. Stage 2 tasks must not be dispatched until it reports. |
| **NQ3** | **Keep exactly ONE kill switch** for RT mode. | A safety switch is a different thing from an experiment switch (Q2 rejected the latter, and that still stands). The "off" path must be exercised by T15, or it rots. |
| **NQ4** | **Drop the packet** when the socket would block; the receiver's retransmit machinery already exists and is running. | On genuinely bad Wi-Fi, a brief artifact instead of a brief delay — the delay would likely have sounded worse. Drops must be counted in T1's probe, not silently swallowed. |

*Resolved earlier in the same session:* measure-first (Q1a) · parity, not A/B switches (Q2) · fix the
F12 lock in **this** plan (Q6b) · jitter to both console and telemetry (Q4a) · probe always-on,
rate-limited (Q5a) · leave the capture-callback registration alone (Q7a).

---

## E. Task list

> Stage 2 tasks (T11–T14) must NOT be dispatched until the T10 gate reports.

### STAGE 1 — measure

**T1 · Diagnostic scheduling probe** — `AirPlayEngine.swift` (new type near `WriteCadenceTracker`
@1537; instrument `write(streams:pts:)` @1009-1101), `AirPlayTypes.swift` @219.
Three metric families, so the measurement discriminates H1/H2/H3: (i) **wake latency** —
`CLOCK_MONOTONIC_RAW` before `enqueue` @1099 vs top of `body` @1055; (ii) **in-cycle work time** —
entry to exit of `body` (this calibrates `computation` in T14); (iii) **inter-arrival gap** at the
`write` entry, exposing capture-side starvation (H2) as distinct from send delay (H1). count/p50/
p95/p99/max each. Always-on, rate-limited to one line per 5s, os_log + stderr, following
`WriteLatencyProbe.record` @1732-1747. Honour the allocation-free hot-path contract @1525-1530.
**Also fix the wrong "226 writes/sec" comment @1535 → 86.1 (F25).**
*sonnet 5 · medium · depends: —* · **verify:** `swift test --filter SchedulingProbeTests`; stderr
summary appears under a synthetic write loop.

**T2 · Telemetry bridge** — `NativeBackend.swift` *(dirty — reconcile first)*. Poll
`writeSchedulingSnapshot()` every ~5s while capture is active via the existing self-rescheduling
`stateQueue.asyncAfter` idiom (@3013, @4016); `Telemetry.log(.airplay, "send_sched", …)`. Never from
the RT path — `stateQueue` satisfies `Telemetry.swift:33-35`.
*haiku 4.5 · low · depends: T1* · **verify:** `grep send_sched ~/Library/Logs/Audiout/telemetry.jsonl`.

**T3 · Load generator + runbook** — `scripts/load-gen.sh`, `dev/notes/audio-scheduling-measurement.md`.
N CPU spinners (default 16, reproducing the observed load), `uptime` before/after, clean teardown.
Runbook fixes the protocol — quiet machine, **no `swift test` running** — and a results table with a
column per hypothesis so T10's decision is mechanical, not a judgement call.
*haiku 4.5 · low · depends: —* · **verify:** `bash scripts/load-gen.sh 4 5` raises load; idle within ~30s.

### STAGE 1 — fix

**T4 · Engine thread QoS + thread audit** — `EngineThread.swift` `init` @58-67.
`t.qualityOfService = .userInteractive` **in `init`, before `start()`**. No switch (Q2). Audit
verdicts to record as prose: capture IOProc queues @1415 / `PerAppCaptureCoordinator.swift:954` —
**no change** (the block runs on the HAL RT thread regardless); `Telemetry` writer `.utility` @143 —
**no change, correct as-is**; `LocalPlaybackEngine`/`SyncedLocalSink` graph queues — **defer**
(control-plane only); `DefaultOutputObserver`/`SystemOutputVolume`/`NativeDiscovery`/`DACPServer` —
**defer** (non-audio-carrying); **`ptp-helper`** — **defer, strongest deferred candidate**: separate
root process, no Core Audio device so no workgroup to join, its jitter degrades multi-room sync
rather than causing single-device stutter, and its privilege boundary is delicate.
*sonnet 5 · low · depends: — (must precede T7, same file)* · **verify:**
`swift test --filter EngineThreadQoSTests`; `git grep -n qualityOfService AirPlayEngine/` = one site.

**T5 · C shim for `os_workgroup_join`/`leave`** — `shims/engine_workgroup.{h,c}` (new),
`include/CAirPlayEngine.h` @35-48, `Package.swift` if needed. Mandatory: those symbols are
`OS_REFINED_FOR_SWIFT` and unreachable from Swift. Opaque heap token; NULL → `EINVAL`. `shims/` is
ours → **no `VENDORED-DIFFS.md` entry.**
*sonnet 5 · medium · depends: —* — manual-memory C at an ARC boundary: the `'oswg'` property returns
**+1 retained** (`AudioHardware.h:987-989`) and leave-in-reverse-order is *undefined behaviour*, not
an error return. · **verify:** `swift build` clean; `engine_workgroup_join(NULL,&t) == EINVAL`.

**T6 · Non-blocking data sockets + EAGAIN tolerance** *(gated by NQ4)* — `shims/misc.c` @236-244,280;
`sender/airplay.c` @2063-2071; `sender/raop.c` @2966-2971; `VENDORED-DIFFS.md` Entry 4.
Per F23 make `net_connect` leave `SOCK_DGRAM` non-blocking — **shim-only, zero vendored diff**. Per
F24 both `packet_send`s must then treat `EAGAIN`/`EWOULDBLOCK` as a **dropped packet**, not
`deferred_session_failure` — two small vendored hunks, ledgered. Count drops into T1's probe.
*sonnet 5 · medium · depends: —* · **verify:** `git diff` on `sender/` is exactly two hunks; Entry 4
quotes them.

**T7 · Workgroup join lifecycle** — `NativeCaptureCoordinator.swift` (`CoreAudioSystemTap` @1214,
after `createAggregate()` @1266, `teardown()` @1663), `NativeBackend.swift`, `AirPlayEngine.swift`,
`EngineThread.swift` @87-120, @243-267.
Read `kAudioDevicePropertyIOThreadOSWorkgroup` off the **`aggregateID`**, never the default output
device — measured: they are distinct and do not nest, second join returns `EALREADY`. Join **on the
target thread itself**. Four edges: join at start; **leave before `threadMain` returns @118** or it
is UB; on tap recreate (`recreateTap` @593, fired by `handleDeviceChange` @548 and by exclusion-set
changes) **leave old → join new**; and document `stop()`'s deadline path @249-261 as an accepted
bounded leak, since `os_workgroup_leave` acts only on the calling thread. Handle `EINVAL`
(cancelled) by skipping.
*opus 4.8 · high · depends: T4, T5* — new cross-package API, four lifecycle edges, an Apple contract
whose violation is UB, interaction with a deliberate thread-leak path. · **verify:**
`swift test --filter WorkgroupLifecycleTests`; live `log stream` shows one join per connect.

**T8 · F12 — get the shared lock off the real-time path** (Q6b) —
`NativeCaptureCoordinator.swift` @105, @509; mutators @278, 317, 331, 343, 386, 424, 593, 625, 676.
`handleBuffer` @509 does `queue.sync` on an unqualified default-QoS serial queue **every buffer from
the RT thread**, while `recreateTap`/`start`/`stop`/`updateRouting` take the same queue from non-RT
threads — a textbook priority inversion. Replace the RT-side read with a lock-free snapshot: publish
`(converter, meteringActive, syncedLocalSink, syncedLocalBaseResampler)` as an immutable,
atomically-swapped box that `handleBuffer` reads without blocking. **Precedent in-repo:**
`LocalPlaybackEngine` already resolved its own RT-path inversion with `stateLock` + serial
`graphQueue` + trylock on the RT path — follow that shape. Preserve the documented ordering around
`machToMonotonicOffsetNanos` @1231-1236.
*opus 4.8 · high · depends: — (serialize against T7, same file)* — the failure mode is a torn read of
a converter pointer mid-teardown, i.e. a crash on the audio thread. · **verify:**
`swift test --filter NativeCaptureCoordinatorTests`; no `queue.sync` reachable from `handleBuffer`.

### GATE

**T9 · Combined-tree verification** — `swift build` + full suite in both packages after every wave.
Parallel agents in one worktree have clobbered each other here before.

**T10 · Alec baseline + Stage-1 live measurement (human gate)** — results into
`dev/notes/audio-scheduling-measurement.md`. Quiet machine, no test suite, real receiver. Idle and
loaded readings, before and after Stage 1, recording all three hypothesis columns.
**Decision output:** does H1 dominate? yes → Stage 2 proceeds. H2 dominates → T8 was the fix, Stage 2
deferred. H3 → re-plan (NQ2).

### STAGE 2 — real-time send thread *(do not dispatch before T10)*

**T11 · SPSC packet ring + `packet_send` → enqueue + preallocated encrypt scratch** —
`shims/engine_sendring.{h,c}` (new), `sender/airplay.c` @1998-2034 & @2036-2087, `sender/raop.c`
@2959-2971, `VENDORED-DIFFS.md` Entry 5. Preallocated SPSC ring of `{fd,len,bytes}` sized for ≥4
IOProc cycles of worst-case packets. `packet_send` writes a ring slot instead of calling `send()`.
Per F22 give each `airplay_session` a preallocated encryption scratch so `packet_encrypt` stops
doing a per-packet malloc/free; RAOP already encrypts in place.
*opus 4.8 · **xhigh** · depends: T6, T10* — lock-free ring correctness plus a vendored ownership
change to the encryption buffer; a subtle bug is corrupted audio or use-after-free on the audio path.
· **verify:** hermetic ring tests (fill/drain/wrap/overflow-drop); ASan run; Entry 5 quotes every hunk.

**T12 · `EngineSendThread`: time-constraint + workgroup + demotion guard** —
`EngineSendThread.swift` (new), `shims/engine_workgroup.{h,c}` (extend for `thread_policy_set`),
`AirPlayEngine.swift`. Parameters computed at runtime from `mach_timebase_info` (**never
hardcoded**). `os_workgroup_join` on the aggregate workgroup T7 resolves. Loop: wait → drain ring →
`sendto` → record cycle time. Implements all four demotion guards from §C including self-demotion
with `fault`-level logging. Kill switch per NQ3.
*opus 4.8 · **xhigh** · depends: T5, T7, T11* — the highest-consequence task here: misconfigured, it
degrades the whole system's audio, not just ours. · **verify:** hermetic tests of the parameter
arithmetic across BOTH timebases (inject `mach_timebase_info`) and of the demotion state machine
(inject synthetic overruns); live `log stream` shows RT engaged at connect and zero demotion faults
over a 10-minute loaded run.

**T13 · Route the write path through the split** — `AirPlayEngine.swift`, `EngineThread.swift`.
Rename/clarify `EngineThread` → control thread in docs; start/stop the send thread alongside it;
ensure `stop()`'s deadline-and-leak path @243-267 covers both threads and that the send thread
leaves its workgroup before exiting.
*opus 4.8 · high · depends: T12* · **verify:** `swift test --filter E1StabilityTests`; repeated
start/stop leaks neither thread nor membership.

**T14 · Calibrate `computation` from measured p99** — `EngineSendThread.swift`, runbook. Replace the
1.0 ms placeholder with 3× the p99 in-cycle work T1 measured on real hardware; record the arithmetic.
*haiku 4.5 · low · depends: T12, T10* · **verify:** recorded p99 × 3 == shipped constant; no demotion
faults under load.

### CLOSE-OUT

**T15 · Tests** — `AirPlayEngineTests/EngineSchedulingTests.swift` (plain `XCTestCase`, that
package's convention), `AudioutCoreTests/WorkgroupLifecycleTests.swift` (**must** subclass
`IsolatedTestCase`).
**Can test:** engine-thread QoS asserted from inside the running thread (`qos_class_self()`); probe
arithmetic against synthetic timestamps; workgroup join/leave **ordering and counts** via a spy
provider; shim NULL contracts; ring fill/drain/wrap/overflow; time-constraint arithmetic across both
mach timebases; the self-demotion state machine under injected overruns.
**Cannot test — say so in the file header, do not fake it:** that QoS/workgroup/RT actually reduce
jitter (scheduler behaviour under load → T17 only); that the HAL publishes `'oswg'` for a
*tap-bearing* aggregate on Alec's machine (only a synthetic one was verified); any real
`os_workgroup_join` or `thread_policy_set` effect. **Do not write a `jitter < N ms` assertion** —
flaky under `--parallel`, vacuous when idle.
*sonnet 5 · medium · depends: all implementation tasks* — the judgement is in what to leave untested.

**T16 · Docs** — `AirPlayEngine/AGENTS.md`, `AudioutCore/AGENTS.md`, `VENDORED-DIFFS.md`.
The engine file must record: the one-thread invariant is now **one thread *into the cluster*** with a
second RT thread that never enters it (the single most important thing for a future agent not to get
wrong); the RTP send is inline in the enqueued write closure, not timer-driven; `os_workgroup_join`
is unreachable from Swift hence the shim; **why per-app send threads are blocked** (`raop_aes_ctx` +
global session lists) so nobody re-proposes it; DGRAM sockets are non-blocking and `EAGAIN` is a
drop. The core file must record that the workgroup comes from the **aggregate**, never the default
output, with the `EALREADY` evidence — same class of fact as the already-documented
`DefaultSystemOutput` selector that keeps drifting back. Ledger Entries 4 and 5.
*haiku 4.5 · low · depends: all implementation tasks* · **verify:** every backticked symbol resolves
via `git grep` at the same commit (Guard 2); ≤~300 words per folder file — trim, don't append.

**T17 · Alec final live A/B (human)** — same protocol as T10, full stack. Success criterion agreed in
advance: loaded p95/max wake latency materially closer to the idle baseline, zero demotion faults, no
audible stutter under `load-gen.sh 16`.

---

## F. Waves

**Hot files forcing serialization:** `EngineThread.swift` → T4,T7,T13 · `AirPlayEngine.swift` →
T1,T7,T12,T13 · `NativeCaptureCoordinator.swift` → T7,T8 · `NativeBackend.swift` → T2,T7 *(dirty)* ·
`shims/engine_workgroup.{h,c}` → T5,T12 · `sender/*.c` + `VENDORED-DIFFS.md` → T6,T11.

| Wave | Tasks | Notes |
|---|---|---|
| 1 | T1 ‖ T3 | Engine Swift vs `scripts/`+`dev/` — disjoint |
| 2 | T2 ‖ T4 ‖ T5 ‖ T6 | `NativeBackend` / `EngineThread` / new shim / `misc.c`+`sender/` — disjoint |
| 3 | T7, then T8 — **serialized, same file** | Both opus/high |
| **GATE** | **T10 (Alec)** | **Stop. Stage 2 is not dispatched until this reports (NQ2).** |
| 4 | T11 | Alone — vendored `sender/` + new ring shim |
| 5 | T12, then T13 — serialized | Both touch `AirPlayEngine.swift` |
| 6 | T14 ‖ T15 ‖ T16 | One constant / tests / docs |
| 7 | T17 (Alec) | |

**Critical path:** T1 → T2 → T7 → T8 → **T10** → T11 → T12 → T13 → T15/T16 → T17.
**Stage 1 alone is waves 1–3 plus the gate — four steps to a testable improvement**, which matters
because Stage 1 may be the whole fix.

---

## G. Recommended execution

**`hybrid`, split at the T10 gate — and only Stage 1 should be scheduled now.**

- **Stage 1 (waves 1–3, 8 tasks) → `agents`.** Not uniform work: T7 and T8 are opus/high judgement
  calls on the audio path, T4's deliverable is an audit decision, and T1's brief may need mid-course
  correction once we see what the probe shows. Visibility is cheap to keep; a workflow must earn its
  overhead and here it doesn't.
- **Stage 2 (waves 4–6) → do not schedule yet.** Dispatching T11–T14 before T10 reports defeats the
  entire point of measure-first. When scheduled, T11/T12/T13 should each be **individually watched
  opus agents** — three sequential xhigh/high tasks with no real concurrency between them is the
  textbook case where a workflow adds overhead and no benefit — with T14/T15/T16 as a small
  mechanical fan-out afterwards.

**Caveat, stated because it cuts against this:** per-task effort is only settable per call in
`workflow` mode, and this plan spans low to xhigh. If precise effort control matters more than
steerability, wave 6 is a reasonable workflow candidate. Everything before it is not.

---

## H. Risks

1. **Stage 2 may be unnecessary.** F26: a quarter-second of receiver buffering should absorb tens of
   ms of sender jitter. If H2 dominates, T8 is the fix and T11–T14 are wasted. The gate exists for
   exactly this. → NQ2.
2. **The workgroup may be inert without RT priority.** Apple frames workgroups as for threads that
   *already* have realtime priority. Stage 1 ships QoS and workgroup together and cannot separate
   their contributions, because A/B switches were declined. Accepted — stated so it isn't
   rediscovered as a surprise.
3. **Time-constraint scheduling is the highest-consequence change here.** Misconfigured, it degrades
   the whole system's audio stack. The four-layer guard in §C is the mitigation; the self-demotion
   path is the one that MUST actually be tested (T15) — it is what turns a bad day into a degraded day.
4. **Vendored diff growth** — Entries 4 and 5 take the ledger 3 → 5. Acceptable and each is small and
   local, but a real cost against the "byte-identical so upstream diffs stay legible" rule, and the
   reason architecture (A) is rejected rather than merely deprioritised.
5. **`rtp_packet_next`'s warm-up allocations** (F22) mean the first ~8s after connect still allocates
   on the encode thread. Under (C) that is NOT the RT thread, so it is tolerable — but if encode ever
   moves onto the RT thread this becomes a blocker.
6. **Tap-bearing aggregates are unproven.** The workgroup was measured on a synthetic aggregate with
   no `CATapDescription`. If the real one doesn't publish `'oswg'`, the plan degrades to QoS-only —
   report it, don't work around it.
7. **`NativeBackend.swift`, `OwnToneBackend.swift`, `NativeBackendTests.swift` are dirty.** T2 and T7
   both edit the first. Reconcile before starting.
8. **Measurement hygiene.** `swift test --parallel` is itself a known load source on this Mac;
   running it during T10/T17 invalidates the result. Both human gates must honour this.
9. **Live testing is single-instance** (PTP 319/320 exclusive) — T10 and T17 each need one combined
   session on a quiet machine. Nothing merges without Alec's go-ahead.

---

## I. The honest summary

**What we can get:** full parity on the property that matters — every audio packet leaving on a
real-time thread with a deadline and workgroup membership, structurally unable to block or allocate.
That is what Apple does for auxiliary audio threads, and architecture (C) reaches it.

**What we cannot get, and why:** per-app isolation. The vendored AirPlay sender keeps one shared
cipher context for AirPlay 1 (`raop_aes_ctx`) and one shared session list. Running it on several
threads at once corrupts audio by design, and fixing that means rewriting code we deliberately don't
own so we can keep taking upstream fixes. So all apps' audio shares one RT send thread. **The gap
that leaves:** if one destination stalls the send loop, it stalls all of them. Given the loop does
well under a millisecond of work in an 11.6 ms window on a preallocated buffer, that gap is small —
but it is real, and it is the one thing per-app threads would have bought.

**The thing most worth seeing:** receivers buffer about a quarter-second, so late sending has to be
*very* late to be audible. Entirely plausible under load-avg 16 — but there are two other suspects,
and the measure-first instinct is what will tell us which. Stage 1 is four waves and may be the whole
fix.
