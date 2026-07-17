# P2b — Multi-stream sender feasibility & per-app-routing architecture (T-R2b)

**IMPLEMENTED 2026-07-17.** The recommended option-(b) surgery (§4) was built
as specified: `stream_id` added to the vendored sender
(`AirPlayEngine/docs/VENDORED-DIFFS.md` Entry 2), the Swift mix stage landed
as `PerAppCaptureCoordinator` + `AppRouteMixer`, and `NativeBackend.updateAppRoutes(_:excludedBundleIDs:)`
wires the two together — see `AirPlayControllerCore/AGENTS.md`. The
verdicts, walls, and open questions below are the design record this was
built from; not updated post-implementation.

Research brief for the architectural unknown behind **per-app routing** (SPEC §3
v2, §9 "Applications routing view"): *route Spotify→Kitchen while Zoom stays
local; overlapping routes MIX per speaker — every speaker receives exactly one
stream = the mix of everything routed to it.*

Grounded in a line-by-line read of the vendored sender
`AirPlayEngine/Sources/CAirPlayEngine/sender/airplay.c` (OwnTone 29.2, 4446 LOC),
`sender/rtp_common.c` / `rtp_common.h`, the shims
(`shims/outputs.h`, `shims/ptpd.c`, `shims/mdns.c`, `shims/conffile.{h,c}`,
`shims/misc.c`), the Swift wrapper `Sources/AirPlayEngine/AirPlayEngine.swift` +
`EngineThread.swift`, and cross-checked against `AirPlayEngine/docs/seam-map.md`
and `PLAN-PHASE-2.md`. Line numbers are current-worktree absolute.

All `file:line` claims below were read directly this session. No web sources were
needed — the answer is fully determined by the vendored code — but the
shairport-sync / OwnTone design lineage is noted where it explains *why*.

---

## 0. TL;DR verdicts (report answers)

- **Q (headline): Can the vendored sender host N independent-content streams
  simultaneously? → NO, not as written, and it is NOT close.** The sender's
  entire fan-out is keyed on **audio quality**, never on a stream identity.
  `airplay_write` (airplay.c:4261) matches an incoming `output_buffer` to a
  master session purely by `quality_is_equal` (airplay.c:4273), and
  `master_session_make` (airplay.c:1147) **returns an existing master session
  for any device whose quality matches** (airplay.c:1157-1161). Since every
  AirPlay device is forced to the ONE default quality 44100/16/2
  (airplay.c:4102-4104, unconditional), **all devices share exactly one master
  session, one RTP stream, one input buffer, one ALAC encoder** — they are
  guaranteed to receive byte-identical audio. There is no per-stream dimension
  at all; "quality" cannot be abused as a stream-id without collisions (see §2).

- **The single most important architectural consequence: the mix belongs
  BEFORE the engine, not inside it.** SPEC §9 already decided this (SPEC.md:530-
  533: *"a per-speaker mix stage before the sender"*). Once you accept that,
  the sender does **not** need to be multi-content at all in the general sense —
  it needs to host **one independent PCM stream per _destination-set_** (a
  destination-set = a group of speakers that must all receive the same mix,
  because their routed-app membership is identical). "Multi-stream" collapses to
  **"multiple destination-sets, each fed its own pre-mixed PCM."** See §5.

- **Recommended architecture: option (a) with a surgical twist — ONE engine
  process, but the sender needs a real stream dimension added (option b)
  because option (a-as-written) mis-routes.** Specifically: keep one
  `AirPlayEngine` / one engine thread / one ptpd / one evbase, and add a
  **stream-id** to `master_session` + `session` + the write call so N master
  sessions with different content coexist and each device binds to its chosen
  one. This is ~a day of vendored surgery (§4 checklist), far cheaper than N
  engine instances (which break on 6+ process-global singletons, §3) or N
  processes (§3c). The per-speaker MIX runs in Swift/Core Audio upstream and
  hands the engine **one PCM buffer per stream-id**.

- **Top-3 walls:** (W1) `ptpd`/`airptp` single GM clock is actually a *feature*
  for us (all streams want the same grandmaster) but the shim
  (`shims/ptpd.c:40`) holds one process-global `ptpd_hdl` — fine for one engine,
  fatal for N-instances. (W2) `evbase_player` is one `extern` global
  (airplay.c:459) owned by one thread (seam-map §8, R-B) — hard cap of ONE
  engine instance per process without renaming/duplicating the symbol. (W3) the
  `quality_is_equal` fan-out is load-bearing in FOUR places
  (airplay.c:1159, 4273, and the two send loops keyed off `master_session ==
  ams` at 2117-2135 & 2196-2199) — a stream-id has to be threaded through all
  of them coherently or streams cross-talk. Full ranked list in §6.

---

## 1. How the sender is wired today (the machinery, with evidence)

### 1.1 Three-level object model

```
airplay_master_sessions  (file-global list, airplay.c:475)
   └─ struct airplay_master_session (airplay.c:211)
        · input_buffer (evbuffer) + input_buffer_samples
        · encode_ctx (ALAC) + encoded_buffer
        · rtp_session  ← owns ssrc/seqnum/pos (rtp_common.h:90)
        · quality, use_ptp
        · output_buffer_samples
   ↑ many-to-one
airplay_sessions         (file-global list, airplay.c:476)
   └─ struct airplay_session (airplay.c:240)
        · device_id, master_session*  ← binds device → master session
        · ctrl (RTSP), state, crypto, ports, ptpd_slave_id
```

A **master session** = one logical audio *stream* (RTP timeline + encoder +
buffer). A **session** = one *device connection* that pulls from a master
session. This is the exact shape you'd want for "N speakers, same content" —
which is precisely the multi-room case OwnTone was built for. It is the *wrong*
shape for "N speakers, DIFFERENT content" only because of how a session gets
bound to a master session (§1.3) and how writes are routed (§1.4).

### 1.2 `master_session_make` DEDUPLICATES by quality (the crux)

`master_session_make(quality, use_ptp)` (airplay.c:1147):

```c
// airplay.c:1157-1161
for (ams = airplay_master_sessions; ams; ams = ams->next)
  {
    if (quality_is_equal(quality, &ams->rtp_session->quality) && use_ptp == ams->use_ptp)
      return ams;                 // ← REUSES an existing master session
  }
// ...else calloc a new one, prepend to airplay_master_sessions (airplay.c:1213-1214)
```

So two devices created with the same quality+ptp get the **same** master
session pointer. And `session_make` always calls it with `device->quality`
(airplay.c:1627), which `airplay_device_cb` unconditionally forces to the
default 44100/16/2 (airplay.c:4102-4104). **Net: every device in the process
shares master session #0.** There is at most one master session in practice
today.

### 1.3 `session_make` binds a device to WHICH master session

`session_make(device, callback_id)` (airplay.c:1585) → line 1627:

```c
session->master_session = master_session_make(&device->quality, extra->use_ptp);
```

The binding key is *only* `device->quality`. There is no notion of "which
content stream this device wants." To support per-app routing you must make this
binding selectable (§4).

### 1.4 `airplay_write` fans a buffer to master sessions BY QUALITY

`airplay_write(struct output_buffer *obuf)` (airplay.c:4261):

```c
for (ams = airplay_master_sessions; ams; ams = ams->next)          // 4269
  for (i = 0; obuf->data[i].buffer; i++)                           // 4271
    if (!quality_is_equal(&obuf->data[i].quality, &ams->rtp_session->quality))
      continue;                                                    // 4273-4277
    // ...append obuf->data[i] to ams->input_buffer, packetize, packets_send(ams)
```

`obuf->data[]` is an array of `struct output_data` (shims/outputs.h:165), sized
`OUTPUTS_MAX_QUALITY_SUBSCRIPTIONS + 2` (=7, shims/outputs.h:63,179). In OwnTone
this array holds the SAME audio transcoded to *different qualities* (one entry
per subscribed quality). It is emphatically **not** a per-stream array — element
`i` is "the same music at quality i," selected by `quality_is_equal`. The Swift
wrapper only ever fills `data[0]` (AirPlayEngine.swift:416-426) and NULL-
terminates at `data[1]`, so today there is exactly one PCM blob at one quality.

**Verdict on "abuse quality as a stream-id":** technically the fan-out already
keys on quality, so you *could* mint fake distinct `media_quality` structs to
tag streams. **Reject this.** (a) The `bits_per_sample`/`channels`/`sample_rate`
fields feed the ALAC encoder setup (airplay.c:1181-1206) and the RTP
sample-rate math (rtp_common.c:93, airplay.c:947,972) — you cannot pick
arbitrary values without changing what actually goes on the wire, and there are
only a couple of *valid* AP2 qualities to collide within. (b) `quality_is_equal`
(shims/misc.c:655) compares the real audio fields; a `bit_rate` you smuggle in
is not compared (misc.h:160 warns "adjust quality_is_equal if adding
elements"). A real `uint32_t stream_id` is cleaner, unambiguous, and doesn't
perturb the audio path. Add the field; don't overload quality.

### 1.5 The two send loops ALSO key off master-session identity

`packets_send(ams)` (airplay.c:2093) and `packets_sync_send(ams)`
(airplay.c:2181) both iterate **all** `airplay_sessions` and act only on those
whose `session->master_session == ams` (airplay.c:2117-2120, 2196-2199). This is
the natural "fan one stream to its bound devices" loop — it already does the
right thing *if* master-session binding encodes the stream. So the multi-stream
machinery is 80% present; what's missing is (i) letting >1 master session exist
with different content, and (ii) letting a device pick which one.

### 1.6 Per-session vs per-master-session vs global state (the audit)

| State | Scope | Multi-stream safe? |
|---|---|---|
| RTP `ssrc_id`, `seqnum`, `pos` | **per master session** (`rtp_session`, rtp_common.h:92-94; randomized per session in rtp_common.c:75-82) | ✅ each stream gets its own timeline — exactly right |
| ALAC `encode_ctx`, `input_buffer`, `encoded_buffer`, `rawbuf` | **per master session** (airplay.c:213-224) | ✅ independent content is fine |
| `quality`, `use_ptp`, `output_buffer_samples` | **per master session** | ✅ |
| RTSP `ctrl`, crypto ctx, ports, `state`, `ptpd_slave_id` | **per session (device)** (airplay.c:247-310) | ✅ each device connection independent |
| **PTP grandmaster clock** (`ptpd_clock_id_get`, airplay.c:1173) | **process-global** (`ptpd_hdl`, shims/ptpd.c:40) | ✅ *shared is CORRECT* — every stream should ride the SAME GM so cross-stream speakers stay phase-locked; this is why one engine beats N |
| `evbase_player` | **process-global extern** (airplay.c:459) | ⚠️ one thread/one base per process — caps instances (§3) |
| `airplay_master_sessions`, `airplay_sessions` | **file-global lists** (airplay.c:475-476) | ⚠️ shared across all streams — fine within one engine, collide across instances |
| `airplay_timing_svc`, `airplay_control_svc` | **file-global** (airplay.c:462,465), bound to fixed config ports (airplay.c:4346,4354) | ⚠️ single UDP timing/control listener pair — one per process |
| `keep_alive_timer`, `airplay_cur_metadata`, `airplay_device_id`, `airplay_ptp_clock_uuid` | file-global (airplay.c:468-484) | ⚠️ single-instance assumptions |

The clean read: **within one engine process, all the per-stream state is already
per-master-session and all the sharing (clock, evbase, timing socket) is stuff
that _should_ be shared.** The only real gap is the *routing* (bind + fan-out
key). That's what makes option (b) cheap and options (a)/(c) wasteful.

---

## 2. Direct answers to the seam questions

- **Could N master sessions with DIFFERENT content coexist?** *Structurally yes*
  — the list (airplay.c:475) and the per-master buffers/encoder/rtp already
  support N entries. *In practice no*, because (i) `master_session_make`
  dedups by quality so you never get a 2nd entry, and (ii) `airplay_write` has
  no way to say "this PCM is for master session X" other than quality. Fix both
  and N-coexistence works.

- **Global vs per-session (RTP ssrc/seq, ptpd clock):** RTP identity is
  per-master-session (good — independent streams get independent
  ssrc/seq/pos). The ptpd single GM clock is *shared and should be* — both
  streams want the same grandmaster, and PTP anchor packets carry the stream's
  own rtptime (airplay.c:2209-2215), so one clock serving many streams is
  correct, not a conflict.

- **Can quality be a stream-id?** No — reject (§1.4). Add a real `stream_id`.

- **`device_start` binding:** binds via `session_make`→`master_session_make`
  keyed on quality only (airplay.c:1627). Must become "bind to the stream this
  device is routed to."

- **evbase/thread constraints — one engine thread, enough for N sessions?**
  Yes. One `event_base` on one thread already fans to *all* current sessions
  every write; N master sessions add N ALAC encodes + N×(devices) sends per
  buffer, all synchronous on that thread (airplay.c:4269-4300). At 44.1kHz,
  352-sample packets = ~125 packets/s/stream; even 8 streams × 4 speakers is a
  few thousand small UDP sends/sec — trivially inside one thread's budget. No
  new thread needed. (If it ever isn't, the bottleneck is ALAC encode, and the
  fix is per-stream encode, not per-stream thread.)

---

## 3. The alternatives, evaluated honestly

### (a) N `AirPlayEngine` actor instances in ONE process — **breaks on globals**

Every one of these is a single process-global that a 2nd instance would stomp:

| Global | file:line | Why a 2nd instance breaks |
|---|---|---|
| `evbase_player` | airplay.c:459 (`extern`), set in AirPlayEngine.swift:157 | One symbol; 2nd engine overwrites the 1st's base pointer → the 1st engine's timers/RTSP run on the wrong base or crash |
| `airplay_master_sessions` / `airplay_sessions` | airplay.c:475-476 | Both instances prepend to the SAME lists; `airplay_write` from engine B walks engine A's sessions |
| `ptpd_hdl` (+ `airptp_create_own_service`) | shims/ptpd.c:40-41 | One GM daemon handle; 2nd `ptpd_init` no-ops or double-binds the PTP socket |
| `cfg` root + `libhash` | shims/conffile.c:67, conffile.h:58-63 | Single config/device-id; 2nd instance can't have its own identity |
| `airplayengine_device_cb` | shims/mdns.c:16 | The mdns shim stores ONE captured callback; 2nd `airplay_init` overwrites it, so device descriptors feed only the last engine |
| `airplay_timing_svc` / `airplay_control_svc` | airplay.c:462,465 | Fixed-port UDP listeners (airplay.c:4346-4355); 2nd bind on same port fails |
| `keep_alive_timer`, `airplay_cur_metadata`, `airplay_device_id`, `airplay_ptp_clock_uuid` | airplay.c:468-484 | Assorted single-instance assumptions |

Making instances independent means renaming/duplicating **all** of the above
into a per-engine context struct — i.e. a much *larger* vendored refactor than
option (b), AND it needlessly runs N PTP clocks (worse sync, defeats the whole
point). **Reject.**

### (b) Minimal vendored surgery: add a stream dimension — **RECOMMENDED**

Add a `uint32_t stream_id` to `master_session` and `session`, let the write
carry it, and let device-bind pick it. Keeps ONE clock, ONE evbase, ONE process,
ONE thread. Per-stream state is *already* per-master-session (§1.6), so the diff
is small and localized (§4). This is the cheapest path that is actually correct.

### (c) One engine PROCESS per stream — **isolating but wasteful; keep as fallback**

Spawn a helper process per destination-set. Pros: zero vendored changes; total
isolation (each has its own globals). Cons: **N independent PTP grandmasters** →
speakers on different processes will *not* be phase-locked to sub-ms (they'd
each be their own GM or fight over the host daemon via `airptp_daemon_find`,
shims/ptpd.c:98) — this directly undermines SPEC's "perfect sync" promise for
the case where the *same* speaker set is split by app. Also: per-process memory,
XPC plumbing, N firewall/PTP-helper registrations (SPEC §4 wants ONE tiny PTP
helper). Only reach for this if (b) hits an unforeseen wall. **Reject as
primary; note as escape hatch.**

---

## 4. Recommended approach + implementation checklist (option b)

**Design.** The per-speaker MIX lives in Swift/Core Audio *upstream* of the
engine (SPEC.md:530-533). The router computes, for the current routing table,
the set of **distinct destination-sets** (maximal groups of speakers whose
routed-app membership is identical). Each destination-set = one **stream**. For
each stream the Swift side sums (mixes) the PCM of every app routed to it and
hands the engine ONE interleaved S16LE buffer tagged with that stream's id. The
engine hosts one master session per stream-id and binds each device's session to
its destination-set's stream. So the sender still sees **one PCM stream per
destination-set** — "multi-stream" == "multiple destination-sets, each with its
own pre-mixed stream."

**Why this is small:** RTP/encoder/buffer are already per-master-session; the
clock/evbase/timing sockets are already correctly shared. We add a routing key,
nothing structural.

Checklist, dependency-ordered (each a small task):

1. **Add `uint32_t stream_id` to `struct airplay_master_session`**
   (airplay.c:211) and `struct airplay_session` (airplay.c:240). Default 0 =
   today's single-stream behavior (keeps Phase-1 path untouched).
2. **Key master-session lookup on `(stream_id, quality, use_ptp)`** in
   `master_session_make` (airplay.c:1157-1161). Change signature to
   `master_session_make(uint32_t stream_id, quality, use_ptp)`; store
   `ams->stream_id = stream_id` beside `ams->quality` (airplay.c:1203).
3. **Thread stream_id through `session_make`** (airplay.c:1585,1627): take the
   device's routed stream_id (new field on `output_device`, or a param) and pass
   it to `master_session_make`. Add `stream_id` to the device descriptor the
   Swift bridge feeds (`shims/outputs.h` `output_device` + AirPlayEngine.swift
   feedDescriptor path).
4. **Carry stream_id on the write.** Add `uint32_t stream_id` to
   `struct output_data` (shims/outputs.h:165) — the natural home, since
   `obuf->data[i]` is already the per-blob unit. In `airplay_write`
   (airplay.c:4269-4277) match on `obuf->data[i].stream_id == ams->stream_id`
   **in addition to** `quality_is_equal` (quality still selects encoder format;
   stream_id selects content).
5. **Swift: one `write(pcm:streamId:pts:)`** — extend AirPlayEngine.swift:393
   `write` to set `d0.pointee.stream_id`. The hot path stays fire-and-forget on
   the one engine thread; N streams = N `output_data` entries in one obuf (fill
   `data[0..<N]`, NULL-terminate) OR N separate write calls — prefer N entries
   in one obuf so all streams share one `pts` and stay phase-aligned.
6. **Swift router + mixer (upstream, no vendored code):** compute
   destination-sets from the routing table; per set, mix routed app taps into
   one PCM buffer; assign stable stream_ids; on route change, add/remove master
   sessions by starting/stopping the affected device sessions with their new
   stream_id. This is the bulk of the *new* work and it's all Swift/Core Audio.
7. **Rebind on route change:** when an app's destination changes, the set
   membership changes → a device may move streams. Implement as
   stop-session-then-start-session-with-new-stream_id (reuses the existing
   device_start/stop sequences, airplay.c:4188/4202). Master sessions are
   ref-counted implicitly by `master_session_cleanup` (airplay.c:1119-1145,
   frees when no session references it) — so orphaned streams self-collect.
8. **Verify with the mock rig** (two fake shairport receivers): route stream A
   to receiver 1, stream B to receiver 2, confirm distinct audio; then route
   both apps to receiver 1 and confirm the *mixed* single stream (one master
   session) — proving the "overlaps mix per speaker" rule end to end.
9. **Sync check:** metronome/Goertzel test (SPEC §6-style) across two speakers
   on DIFFERENT streams to confirm the shared GM keeps them phase-locked. This
   is the acceptance test that option (b) beats option (c).

---

## 5. Where the MIX stage goes (the reframing)

The engine should NEVER see per-app audio. It sees **one pre-mixed PCM stream
per destination-set.** Concretely:

- Router owns routing table `{app → destination}` (SPEC §9; persisted as
  `app-routes.json` per SPEC.md:473).
- Compute destination-sets: speakers with identical routed-app membership are
  one set → one stream. (Overlapping routes naturally collapse: a speaker in two
  apps' destinations lands in one set that receives both apps' mix.)
- Per set, sum the S16LE taps of its member apps (with clip/limit) → one buffer.
- Hand each buffer to the engine tagged with the set's stream_id.

This makes the "multi-stream" question mostly a **Swift mixing** problem, with a
*small* engine change (option b) to let >1 tagged stream coexist and bind. It
keeps the security posture intact (SPEC §4: nothing large runs privileged; the
only privileged bit is the tiny PTP helper, and there's still exactly ONE of it,
one GM clock, one engine process).

---

## 6. Walls / risks, ranked

1. **W1 — Cross-stream fan-out coherence.** The `quality_is_equal` /
   `master_session == ams` keying appears in FOUR coupled places
   (airplay.c:1159, 4273, 2117-2120, 2196-2199). A stream_id must be threaded
   through *all* of them consistently, or a device bound to stream A receives
   stream B's packets (silent cross-talk, hard to debug). Mitigation: change the
   match everywhere in one atomic diff; the mock-rig test (step 8) catches
   cross-talk immediately.
2. **W2 — `evbase_player` is one global on one thread** (airplay.c:459, seam-map
   §8 R-B). Hard-caps the process to ONE engine instance — which is *fine* for
   option (b) but means option (a) is off the table without a bigger refactor.
   Keep the invariant: one engine, one thread, N streams inside it.
3. **W3 — ptpd single GM handle** (shims/ptpd.c:40). Shared is correct for us,
   but it means the isolation of option (c) costs real sync quality. Do not let
   a future "just spawn a process per stream" shortcut sneak in without the
   sync acceptance test (step 9).
4. **W4 — Mixer latency/alignment.** All streams derive from the SAME capture
   clock and should share one `pts` per write (step 5) so cross-stream speakers
   stay aligned. Getting per-set mixing to preserve a common timebase is the
   subtle part; feeding all streams in one `output_buffer` with one `obuf->pts`
   (airplay.c:4282 uses `obuf->pts` for `timestamp_set`) is the lever.
5. **W5 — Only default quality is wired** (airplay.c:4102-4104). Fine — all
   streams share the one valid quality, so stream_id (not quality) is
   unambiguously the content discriminator. But it means the code path assumes
   44100/16/2; don't try to make streams differ by quality.
6. **W6 — Route-change churn.** Moving a device between streams = stop+start its
   session (RTSP re-handshake, ~audible gap). Acceptable for a user-initiated
   route change; note it so nobody expects glitch-free live re-routing.
7. **W7 — Instrumentation cruft in the hot path.** airplay.c currently carries
   `g_instr_*` counters and `fprintf` dumps (airplay.c:1916-1922, 2108-2115,
   2212-2215) from an active investigation. These are per-*process* globals and
   will conflate all streams; strip or gate them before shipping multi-stream so
   the `[INSTR]` numbers aren't misread as per-stream.

---

## 7. Open questions for Alec (genuinely his calls)

- **Destination-set granularity vs. per-device streams.** The cheap model gives
  each *destination-set* one stream (speakers with identical app-membership
  share a master session, so identical mixes aren't recomputed). The alternative
  is one stream per *speaker* always (simpler bookkeeping, slightly more ALAC
  encoding). Default recommendation: destination-sets (fewer encodes, matches
  "every speaker gets exactly one stream = its mix"). Confirm.
- **Live re-route behavior (W6).** Is a brief audible gap when an app is dragged
  to a new destination acceptable (stop/start session), or should we invest in
  gapless stream-hopping later? Recommendation: accept the gap for Phase 2,
  revisit in Phase 3 polish.
- **Local bypass + mix interaction (SPEC §9 "This Mac").** "This Mac (don't
  stream)" excludes an app from capture entirely (SPEC.md:535). Confirm that a
  local-bypassed app is NEVER part of any stream's mix (it plays on the Mac's
  own output only) — this brief assumes so.
