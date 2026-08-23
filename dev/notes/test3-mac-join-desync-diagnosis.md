# Test 3 — "Mac joins last into an AirPlay group" desync: defect diagnosis

Build: worktree `foreman-roadmap-c1a0f5` @ `202dc4e4` ("Audiouter Bayes v1").
Evidence: `test3-session-telemetry.jsonl`, 1223 lines, 2026-08-22T23:55Z → 2026-08-23T00:19Z.
All file:line refs are that worktree.

---

## 0. Device identities (needed to read the log)

`set_output_set.desiredOn` only ever lists ids that reach the AirPlay engine
(`NativeBackend.swift:2478-2481` skips `isLocalDevice` and `isBluetooth`), so:

| Log name | What it is |
|---|---|
| `Move 2 (SONOS BF4A)` | the Sonos Move 2 over **Bluetooth**, uid `C4-38-75-0E-BF-4A:output` |
| `Move 2` (`C4:38:75:0E:BF:4A`) | the same speaker over **AirPlay** |
| `Sonos Move` (`54:2A:1B:79:08:9E`) | the older Sonos Move, **AirPlay** — the "Sonos" of the report |
| *(never named)* | the **Mac**: membership comes from `selectedDevicesQuery`, not `ids` (`NativeBackend.swift:2560`), so a Mac toggle logs `set_output_set add=[] rm=[]` with an unchanged `desiredOn` |

A Mac toggle is therefore identified in the log as: `set_output_set add=[] rm=[]`
→ `bt_sink_rebuild cause=composition_change` → `captureWS aggregate_destroy` +
`create_and_start_begin/done` (a whole-system **tap rebuild**), and — on the ON
edge only — a following `sync_session_anchored`.

---

## 1. Delay arithmetic in this build (all confirmed against the log)

`SyncTiming.totalDelayNanos = max(0, reference − ownLatency − margin + userOffset)`
(`SyncCore.swift:53-65`).

| Sink | reference | own latency | resulting delay | acoustic emission |
|---|---|---|---|---|
| Mac (`SyncedLocalSink`) AirPlay present | `_startBufferMs` = 1000 (`NativeBackend.swift:5637-5646`) | 18.1 ms measured + 3.0 margin | **978.9 ms** ✓ log | pts + 1000 |
| Mac, BT-only | `btOnlyReferenceMs = max(500, 429+100)` = 529 (`NativeBackend.swift:2874-2882`) | same | **507.9 ms** ✓ log | pts + 529 |
| Mac, wizard reference raised | 2000 (`btWizardReferenceBufferMs`) | same | **1978.9 ms** ✓ log | pts + 2000 |
| BT Move 2, AirPlay present | 1000 | 429 (wizard, trim 0) | **571.0 ms** ✓ log (`bt_sink_anchor_carried 571.0`) | pts + 1000 |
| BT Move 2, BT-only | 529 | 429 | 100 ms | pts + 529 |

**Every sink's target is `pts + reference`, and the arithmetic is identical in
both join orders.** The Mac anchors at 978.9 ms whether it joins first or last
(`sync_session_anchored` at 00:09:25.949 — good order — and 00:10:51.746 — bad
order — are the same number). *(confirmed-by-evidence)*

⇒ **The defect is not in the delay math.** It is in what the AirPlay receiver
actually does with `pts`.

---

## 2. The mechanism

### 2a. The AirPlay sender's timeline re-anchors to "now" on every write

`AirPlayEngine/Sources/CAirPlayEngine/sender/airplay.c:2232-2258`, called per
write at `airplay.c:4364`:

```c
ams->cur_stamp.ts  = ts;                       // pts of the write just made
ams->cur_stamp.pos = ams->rtp_session->pos     // SAMPLES SENT so far
                   + ams->input_buffer_samples
                   - ams->output_buffer_samples;
```

The sync packet tells the receiver "rtptime `pos` is playing at wall time `ts`".
`pos` counts **samples delivered**; `ts` is **wall time**. With a continuous feed
that is `playout(S) = pts_S + reference`. If the producer stops feeding for `G`
ms, `pos` does not advance but `ts` does, so the next sync packet re-states the
same rtptime `G` ms later — **every receiver in that master session plays `G` ms
LATE, permanently, for the life of the session.** *(strong-inference: the C is
unambiguous, but the receiver's response was not instrumented)*

### 2b. Every Mac join/leave opens exactly such a hole; a BT join/leave does not

`NativeCaptureCoordinator.setSyncedLocalSink(_:renderProcessPID:)`
(**`NativeCaptureCoordinator.swift:757-792`**) ends with an **unconditional**
`recreateTap(cause: .exclusionChange)` (line **792**) whenever the tap is
capturing and the sink's render pid enters/leaves the exclusion set — i.e. on
every Mac ON and every Mac OFF.

Its own comment (lines 785-791) asserts:

> "this rebuild does NOT desync the AirPlay receivers — no whole-system session reset"

Skipping the RTP re-establish is correct. The assertion that the rebuild does not
desync the receivers is **false**, because of 2a.

The Bluetooth twin, `setBTSink` (**`NativeCaptureCoordinator.swift:814-838`**),
deliberately does **not** force a recreate — it delegates to
`rebuildIfExclusionObjectsChanged()` (line 838), whose compare-before-rebuild
finds the resolved exclusion set unchanged (our own pid is already excluded
unconditionally on every tap creation) and rebuilds nothing.

**That asymmetry is the whole defect.** The Mac is the only member whose join
starves the sender.

### 2c. The measured cost of one rebuild: 192–203 ms

`write_cadence_drift path=wholeSystem` is the sender's own bookkeeping:
`netDriftSeconds = deficit − overrun` = cumulative wall-clock-minus-audio-delivered
(`AirPlayEngine.swift:1893-1975`, `WriteCadenceTracker.record`). Every tap rebuild
in this session steps it by **+0.192 s to +0.203 s**, 1:1, with nothing else moving
it. Cumulative net drift over the session: **8.81 s**. *(confirmed-by-evidence)*

### 2d. Why the Mac (and not the Sonos) is what the ear picks out

`SyncedLocalSink` and `BTDeviceSink` are plain sample FIFOs anchored ONCE at
`anchorPts + delay`; nothing ever re-states that anchor. So the two sides move in
**opposite directions** across the same hole:

* the AirPlay sender re-anchors to the latest write → **late by G**;
* a FIFO anchored *before* the hole plays contiguously with G ms of content
  missing → **early by G**;
* a FIFO that re-anchors *after* the hole → **on pts, 0 error**.

The Mac's PI phase loop (`SyncCore.swift` `PhaseController`) cannot see a content
hole: it compares *frames consumed* to wall time, and the FIFO consumes 1:1 either
way. Its ±200 ppm ceiling would need ~25 min to remove 200 ms even if it could.
*(strong-inference)*

---

## 3. Reconstructed timeline of the experiments (00:07 → 00:11)

`SEL` = `set_output_set`; `TAP` = whole-system tap rebuild; `Δdrift` = the
`netDriftTotalSeconds` step attributable to it.

### E1 — BT → Sonos → **BT joins last** (00:08:09 → 00:08:14) — GOOD, and the control case

| t | event |
|---|---|
| 00:08:09.590 | SEL add=[Sonos Move] on=[Sonos Move] |
| 00:08:09.598–.641 | TAP rebuild (selection start) |
| 00:08:10.188 | **AirPlay master session created** |
| 00:08:13.955 | SEL add=[Move 2 (SONOS BF4A)] — BT joins the LIVE session |
| 00:08:14.114 | `bt_sink_rebuild cause=config_change` → `bt_sink_anchor_carried 571.0` |
| — | **no TAP rebuild, no drift step** |

BT joining an already-playing AirPlay session costs **zero** feed gap. This is the
"Bluetooth + AirPlay perfectly in sync" case. *(confirmed-by-evidence)*

### E2 — …then **Mac joins last** (00:08:19) — BAD

| t | event |
|---|---|
| 00:08:19.772 | SEL add=[] rm=[] on=[Sonos Move] — **Mac ON** |
| 00:08:19.801 | `bt_sink_rebuild cause=composition_change` (BT re-anchors ~290 ms *before* the hole) |
| 00:08:20.095–.146 | **TAP rebuild** |
| 00:08:20.231 | `sync_session_anchored 978.9` — Mac anchors *after* the hole |
| 00:08:21.736 | **Δdrift +0.192 s**, inside the session created at 00:08:10.188 |

⇒ Sonos permanently 192 ms late; Mac on pts. *(confirmed-by-evidence for the drift
and the anchor order; strong-inference for the audible result)*

### E3 — BT → **Mac** → Sonos (00:09:19 → 00:09:26) — GOOD

| t | event |
|---|---|
| 00:09:19.040 | SEL rm=[Sonos Move] — previous AirPlay session torn down |
| 00:09:20.307–.360 | SEL add=[BT], TAP rebuild |
| 00:09:21.456 | SEL add=[] rm=[] — **Mac ON** |
| 00:09:21.783–.835 | **TAP rebuild** (the Mac's exclusion-change recreate) |
| 00:09:21.917 | `sync_session_anchored 507.9` (BT-only reference 529) |
| 00:09:22.194 | **Δdrift +1.601 s** — but **no AirPlay session exists yet** |
| 00:09:25.790 | SEL add=[Sonos Move] |
| 00:09:25.816 | `bt_sink_rebuild composition_change` |
| 00:09:25.949 | `sync_session_anchored 978.9` (re-anchor onto the AirPlay reference) |
| 00:09:26.391 | **AirPlay master session created — `pos` starts clean** |
| 00:09:27.5 → 00:10:15 | netDrift flat (8.608 → 8.715, +0.107 s over 48 s of normal jitter) |

The Mac's tap rebuild is paid **before** the master session exists, so the session
never sees a hole. All three land on `pts + 1000`. *(confirmed-by-evidence)*

### E4 — the failing repro, BT → Sonos → **Mac** (00:10:46 → 00:10:54) — BAD

| t | event |
|---|---|
| 00:10:46.394 | SEL rm=[Sonos Move] |
| 00:10:46.711 | SEL add=[Sonos Move] |
| 00:10:47.268 | **AirPlay master session created** |
| 00:10:48.504 | drift sample +0.192 s — attributable to the 00:10:45.1 rebuild, i.e. *before* this session |
| 00:10:51.278 | SEL add=[] rm=[] — **Mac ON** |
| 00:10:51.304 | `bt_sink_rebuild composition_change` (BT re-anchors ~240 ms before the hole) |
| 00:10:51.607–.656 | **TAP rebuild** |
| 00:10:51.746 | `sync_session_anchored 978.9` — Mac anchors *after* the hole |
| 00:10:51.855 | BT gate opens, `overshoot 0.0` ⇒ BT anchor pts = 51.855 − 0.571 = **51.284** (pre-hole) |
| 00:10:54.040 | **Δdrift +0.203 s**, inside the session created at 00:10:47.268 |

Inferred hole window: **[51.543, 51.746]**, 203 ms — starts when the 250 ms
synced-local settle (`NativeBackend.swift:248`) fires, ends at the Mac's first
enqueue. *(confirmed-by-evidence for the drift step and both anchor times)*

### Mac toggle storm 00:10:19 → 00:10:45 (6 toggles)

Every one — ON **and** OFF — produced a TAP rebuild and a +0.192…+0.203 s drift
step, all inside a live Sonos session. Six toggles ≈ **1.2 s of cumulative slip**
on that receiver. This is why repeated fiddling makes it worse, not better.

---

## 4. Root cause

**Primary — confirmed-by-evidence.**

> `AudiouterCore/Sources/AudiouterCore/NativeCaptureCoordinator.swift:792` —
> `setSyncedLocalSink(_:renderProcessPID:)` forces
> `recreateTap(cause: .exclusionChange)` on every Mac join/leave. The resulting
> ~200 ms capture hole starves the vendored sender, whose presentation timeline is
> re-anchored to the wall time of the latest write
> (`AirPlayEngine/Sources/CAirPlayEngine/sender/airplay.c:2257`, called at
> `airplay.c:4364`), so every receiver in the live master session is permanently
> retarded by exactly the hole. The Mac's own sink re-anchors on pts *after* the
> hole and is therefore correct-but-alone. When the Mac joins FIRST the identical
> hole is paid before any master session exists, so nothing slips.

Evidence chain: E1 (BT joins live session → no rebuild, no drift, in sync) vs E2/E4
(Mac joins live session → rebuild, +0.192/+0.203 s drift, out of sync) vs E3 (Mac
joins first → same rebuild, same drift, but pre-session → in sync). The drift
counter is the sender's own measurement of undelivered audio, and it steps 1:1 with
the tap rebuilds and with nothing else.

**Secondary, contributing — strong-inference.**

> `NativeBackend.swift:2664` compares the whole `BTGroupComposition`
> (`|| (wantBT && composition != self.btComposition)`), including
> `macLocalPresent` — a field `BTReferenceTimeline.delayNanos`
> (`BTSyncedSink.swift:56-70`) documents it *never* uses. So a Mac toggle drives
> `setComposition` → `requestRebuild(cause: "composition_change")`
> (`BTSyncedSink.swift:1266`) on every BT speaker: ~570 ms of silence per toggle,
> plus a re-anchor that lands ~240–290 ms *before* the hole the Mac's own attach is
> about to open. A pre-hole anchor makes that BT speaker run ~200 ms **early** for
> the rest of the session (§2d).

**Latent, same class — hypothesis (not active in this log).**

> `SyncedLocalSink` has no equivalent of `BTDeviceSink.catchUpToTargetLocked`
> (`BTSyncedSink.swift:1063-1069`). `SyncTiming.plan` (`SyncCore.swift:93`) releases
> at frame 0 when the gate opens late, so a slow `AVAudioEngine.start()` makes the
> Mac's delay permanently longer by the overshoot. Every Mac anchor in this log is
> clean, so it did not fire here.

### The one thing the evidence cannot settle

The owner reports **BT + Sonos still in sync, Mac alone off**. The mechanism above
predicts a three-way spread: Sonos **+G**, Mac **0**, BT **−G** (because the BT
sink's `composition_change` re-anchor lands pre-hole, per E4's
`gate_open − 571 ms = 51.284` vs the hole at 51.543). Either

* **(A)** the BT speaker was in fact also displaced and the owner's pairing was
  judged on the two that happened to sound closest, or
* **(B)** the BT delay line does not actually swallow the hole (e.g. its anchor
  landed post-hole in the owner's specific run, which the 250 ms settle window makes
  timing-dependent).

This does not change the primary root cause — the Mac↔Sonos error is `G` either
way — but it does change whether fix (3) below is cosmetic or load-bearing.

**Discriminating capture — one live repro.** Add two log lines first:

1. `captureWS / tap_feed_gap {cause, gapMs}` at the tap-rebuild seam
   (`NativeCaptureCoordinator.recreateTap`) — last-buffer pts to first-buffer pts.
   Turns the inferred 203 ms into a measured number.
2. `anchorPtsNanos` on `sync_session_anchored` (`SyncedLocalSink.swift:603`) and a
   new `bt_sink_anchored {uid, anchorPtsNanos, delayNanos}` in
   `BTDeviceSink.enqueue` (`BTSyncedSink.swift:786-800`). Makes pre-hole vs
   post-hole anchoring a fact instead of `gate_open − delay`.

Then run exactly: BT on → Sonos on → wait 10 s → Mac on → hold 30 s, and rate all
three pairs by ear. Predicted if (A): `bt_sink_anchored.anchorPtsNanos` < the
`tap_feed_gap` start, and BT is ~`gapMs` early. Predicted if (B): the BT anchor is
after the gap and BT sits with the Mac.

---

## 5. Fix direction (file-level, no code)

**1. Stop opening the hole — this is a deletion.** `setSyncedLocalSink` is the last
caller in `NativeCaptureCoordinator` that forces an unconditional recreate. Its
render pid is *our own process*, which
`resolveExcludedObjectIDsLoggingAttribution(bundleIDs:)` already excludes on every
tap creation — the exact reasoning `setBTSink` cites at
`NativeCaptureCoordinator.swift:804-813` for routing through
`rebuildIfExclusionObjectsChanged()`'s compare-before-rebuild instead. Give the
synced-local attach the same treatment: in production the resolved exclusion object
set does not change when the in-process Mac sink attaches, so the rebuild — and the
whole 200 ms hole — simply stops happening. Keep the recreate only for the case
`rebuildIfExclusionObjectsChanged` is designed to catch (a genuinely new render
process). This alone makes the reported repro symmetric.

**2. Make an unavoidable hole harmless.** Device changes and rate renegotiations
still tear the tap down. Both damaged parties — the sender's `pos` counter and every
FIFO delay line — are fixed by the same thing: at the tap-rebuild seam
(`NativeCaptureCoordinator`/`TapRebuildLifecycle`), measure the pts discontinuity
and push exactly that much **silence** through `deliver(_:pts:snapshot:)` before the
first post-rebuild buffer. `timestamp_set`'s pos↔pts relation stays intact (no
receiver slip) and every already-anchored ring stays whole (no early playout). One
change, both sides, and it needs no new state in either sink. This is the durable
fix; (1) is the one that closes the reported bug.

**3. Narrow the BT rebuild trigger.** `NativeBackend.swift:2660-2667` should compare
only the composition fields that move a BT delay (`airPlayPresent`), not the whole
struct. `macLocalPresent` is already documented as irrelevant
(`BTSyncedSink.swift:27-31`, `56-70`); honouring that doc removes a ~570 ms silence
and a spurious re-anchor from every Mac toggle.

**4. Give `SyncedLocalSink` the catch-up `BTDeviceSink` already has.** Port
`catchUpToTargetLocked` (`BTSyncedSink.swift:1063-1069`) — skip the overshoot's worth
of ring frames at gate open rather than releasing the oldest frame — so a slow engine
start cannot silently lengthen the Mac's delay for a whole session. Low urgency; it
is the same defect class and the same three lines of arithmetic.

---

## 6. Confidence summary

| Conclusion | Confidence |
|---|---|
| Delay arithmetic is identical in both join orders; the Mac anchors at 978.9 ms either way | confirmed-by-evidence |
| Every Mac join/leave forces a whole-system tap rebuild; a BT join/leave does not | confirmed-by-evidence (code + E1 vs E2/E4) |
| Each such rebuild costs 192–203 ms of undelivered audio (`netDriftTotalSeconds`) | confirmed-by-evidence |
| In the bad order that hole lands inside a live AirPlay master session; in the good order it lands before the session exists | confirmed-by-evidence (E2/E4 vs E3) |
| Undelivered audio permanently retards the AirPlay receivers by that amount (`timestamp_set` is sample-count anchored) | strong-inference (C source is explicit; receiver behaviour not instrumented) |
| A FIFO sink anchored across the hole runs *early* by the hole; the PI loop cannot correct it | strong-inference |
| The BT sink's `composition_change` re-anchor lands pre-hole and therefore also displaces it | hypothesis — see the discriminating capture in §4 |
| `SyncedLocalSink`'s missing overshoot catch-up | hypothesis, not active in this log |
