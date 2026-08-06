# Split-ownership lifetime sweep — rebuildable audio objects (T-1, roadmap-016)

Sweep date: 2026-08-07 · against main `02f9fbe7` · read-only audit, no code changed.

## The failure class

A stored property is **edge-written** once at some object's creation (or teardown), then
**decision-read** by a guard after a REBUILD of that object — so the old value silently
outlives the object whose state it described. Three shipped defects came from this shape
(all silent-forever audio): the `onBuffer`-after-`createAndStart` snapshot, the
device-state-vs-session-state flush guard, and the call-gate latch on the rebuildable tap.
This sweep enumerates every stored property on the rebuildable audio objects and asks, for
each: whose lifetime is the write, whose lifetime is the read, and what survives each of
the rebuild paths (`recreateTap`, full `stop()`+`start()`, the `reconcileCaptureGate`
stop/start, session flush/rebind, `resetAirPlaySessionForWholeSystem`).

Lifetime vocabulary: **process** > **coordinator** (NativeCaptureCoordinator /
PerAppCaptureCoordinator / AirPlayEngine instance) > **session** (one engine RTSP/RTP
session, reset by flush/rebind) > **tap-instance** (one CoreAudioSystemTap /
CoreAudioProcessTap generation; a rebuild makes a NEW instance).

## Disposition table

### NativeCaptureCoordinator (coordinator-lifetime; owns one tap-instance at a time)

| Property | Lifetime | Assignment | Decision reads | Rebuild survival | Disposition |
|---|---|---|---|---|---|
| `_state` | coordinator | reconciled (every transition) | all lifecycle guards | authoritative across all paths | OK-by-design |
| `tap` / `converter` | tap-instance | edge per generation, nulled at claim/stop | commit re-checks; RT path reads snapshot, not these | replaced per generation; nulled on stop/gate-stop | OK-by-design |
| `_bufferSnapshot` | tap-instance | whole-object swap at EVERY mutation site (verified: start commit/fail, stop, recreate claim/commit/fail, `setMeteringActive`, `setSyncedLocalSink`) | RT `handleBuffer` | emptied at claim, republished at commit — the single-delivery guarantee | OK-by-design |
| `rebuildCoalescer` (pending flag) | coordinator | edge-written while `.creatingTap` (`markPending`, line ~1089) | consumed ONLY at `recreateTap`'s successful commit (`takePending`, ~1210); **`start()`'s commit never consumes it** | **survives `.failed`, `stop()`, and the gate's stop/start** | **candidate-critical — Finding F2** |
| `meteringActive` | coordinator | reconciled (popover show/hide) | RT snapshot gate | survives all rebuilds — correct: it describes the popover, not the tap | OK-by-design |
| `currentExcludedBundleIDs` | coordinator | reconciled (`updateRouting`) | resolved fresh at every tap creation | survives — correct: intent, re-resolved to live objects per generation | OK-by-design |
| `lastExcludedObjects` | tap-instance (baseline) | edge at every `.capturing` commit only | compare-before-rebuild, gated on `.capturing` | stale across stop→idle, but every path back into `.capturing` rewrites it before any reader can run | OK-by-design |
| `syncedLocalSink` / `syncedLocalRenderPID` | coordinator | reconciled (`setSyncedLocalSink`, driven by NativeBackend's settle) | exclusion resolve, RT fan-out gate | survives gate stop/start — correct: attach/detach is selection-driven, not capture-driven | OK-by-design |
| `syncedLocalBaseResampler` | attach-episode | edge at attach, from `sink.renderSampleRate` | RT fan-out every buffer | survives tap rebuilds (filter state carries — intended); ratio is only as fresh as the sink's rate — see **Finding F1** | see F1 |
| `processListBlock` / `membershipDiffWork` | coordinator | paired add/remove; cancel in deinit | none (mechanism) | n/a | OK-by-design |
| `onStateChange` / `onDeviceRateRebuild` / `onLevel` | coordinator | wired once by NativeBackend | fired per event | n/a | OK-by-design |

### CoreAudioSystemTap / CoreAudioProcessTap (tap-instance; a rebuild is a NEW instance)

| Property | Lifetime | Assignment | Decision reads | Rebuild survival | Disposition |
|---|---|---|---|---|---|
| `onBuffer` / `onDefaultDeviceChanged` | tap-instance | wired BEFORE `createAndStart` at both call sites (start ~497, recreate ~1165/1175; per-app ~418/551) | IOProc snapshots `onBuffer` by value at `startIOProc` | new instance per rebuild | **closed** (fix #1); both sites comply |
| `tapID` / `aggregateID` / `ioProcID` / `tapDescription` | tap-instance | edge in create, cleared in `teardown()` (idempotent, deinit backstop) | teardown guards, `workgroupDeviceID`, `tappedDeviceID` | die with the instance | OK-by-design |
| `format` / `asbd` | tap-instance | edge at create, **corrected** by `reconcileFormatWithAggregate` before converter/monitor consume it | converter build, monitor `tracked()` (read live per notification) | die with the instance | OK-by-design |
| `tappedOutputDeviceID` | tap-instance | edge in `createAggregate`, cleared in teardown | monitor compare (live), `TapReanchor` baseline | die with the instance; `nil` mid-teardown reads as "abstain" | OK-by-design |
| `machToMonotonicOffsetNanos` | tap-instance | reseeded per `startIOProc`, self-healed per buffer (`shouldResample`) | pts rebase on RT path | reseeded every generation — the process-lifetime version of this WAS a bug and is documented as such | OK-by-design |
| IOProc captures (`bytesPerFrame`, `nonInterleaved`, `onBuffer`) | IOProc (== tap-instance) | by value at `startIOProc` | every delivered buffer | rate-independent fields; `asbd.mSampleRate` correction after start doesn't invalidate them | OK-by-design |
| `monitorToken` | tap-instance | subscribe at end of create, unsubscribe in teardown | none | paired | OK-by-design |
| `lastAggregateUID` / `delayedRateTelemetryWork` / `lastBundleID` (per-app) | tap-instance | set in create, cancelled/cleared in teardown | telemetry only | paired | OK-by-design |

### BufferSnapshot (struct-like final class)

Fields `converter` / `meteringActive` / `syncedLocalSink` / `syncedLocalBaseResampler` —
all `let`, immutable by construction, published by whole-reference swap under
`snapshotLock`, consumed by one `try()` read on the RT thread. Torn reads structurally
impossible; `.empty` is both the pre-start and every-teardown value. **OK-by-design.**

### AVFormatConverter (tap-generation; a fresh one per `.capturing` commit)

| Property | Lifetime | Notes | Disposition |
|---|---|---|---|
| `sourceFormat` / `inputAVFormat` / `outputAVFormat` / `converter` | tap-generation | all `let`, built from the already-reconciled `TapFormat` | OK-by-design |
| `failureCounts` / `failureSampleCounter` / `lastReportedFailureTotal` | tap-generation | written under `lock` in convert; read lock-free by the sampler on the same single delivery thread (documented discipline); counters die with the generation, baselines with them — no cross-generation read | OK-by-design |

### EngineSink (coordinator-lifetime, effectively process)

| Property | Lifetime | Notes | Disposition |
|---|---|---|---|
| `backlogSampleCounter` / `lastReportedDroppedWrites`, cadence baselines | process | delta baselines against ENGINE counters; `writeBacklog.reset()` on engine `start()`/`stop()` zeroes the engine side while the sink's baseline stays high → one wrapped `droppedDelta` telemetry line after an engine restart, then self-resyncs. Telemetry-only; the app never restarts the engine mid-process today. | doc-only |

### PerAppCaptureCoordinator

| Property | Lifetime | Assignment | Decision reads | Rebuild survival | Disposition |
|---|---|---|---|---|---|
| `slots` dict / `Slot.state` / `Slot.tap` | slot (bundle-ID episode) | `stop(bundleID:)` REMOVES the slot entirely | all guards | per-slot state dies with the slot — the clean contrast to the whole-system coordinator | OK-by-design |
| `Slot.rebuildCoalescer` | slot | markPending while `.creatingTap` | consumed only at `handleDeviceChange`'s commit; **`beginStart`'s commit never consumes it** | survives `.failed` → retry (`start` from `.failed` reuses the slot) | doc-only (same asymmetry as F2, but the replay is one extra per-app rebuild + telemetry — no session reset exists on this path) |
| `Slot.lastTappedProcessObjects` | tap-generation baseline | edge at every `.capturing` commit | membership diff, gated `.capturing` + `stillStale` re-check under lock | rewritten before any reader can act | OK-by-design |
| `processListBlock` / `membershipDiffWork` | coordinator | paired; cancelled in deinit | none | n/a | OK-by-design |

### AirPlayEngine

| Property | Lifetime | Assignment | Decision reads | Reset survival | Disposition |
|---|---|---|---|---|---|
| `knownOutputs` | engine + discovery | reconciled continuously (`stateReconcileTask`) AND bypassed for decisions | `bind`/`unbind`/`flush` idempotency guards read the LIVE C `device->state` on the engine thread; `knownOutputs` only gates registration existence | cleared on `stop()` | OK-by-design (this is the already-shipped "half-fix" of the class — decisions moved to live reads) |
| `boundStreamId(for:)` | — | live C read | callers | n/a | OK-by-design |
| `writeBacklog` (`inFlight`/`dropping`/`droppedWrites`) | write-closure | reserved at `admit`, released when the enqueued body DRAINS (or on the enqueue-failed fallback) | `admit`'s cap check | **FLUSH / session reset (removeOutput→addOutput) never touches it — and doesn't need to**: reservations are keyed to enqueued closures, not sessions, and the engine thread keeps draining across a flush, so a flushed stream's budget cannot stay debited. The only stuck-reservation path (wedged engine thread whose bodies never run) is cleared by `writeBacklog.reset()` in `start()`/`stop()`. | OK-by-design — answers the plan's flush-accounting question |
| `cadence` / `latencyProbe` / `schedulingProbe` | engine | cumulative diagnostics, never gate anything | telemetry | not reset per session (intended: receiver-visible cumulative deficit) | OK-by-design |
| `currentStartBufferMs` | engine | reconciled (`setStartBufferMs`) | applied at next session creation; live sessions keep the old value | documented honestly at both the setter and `EngineConfig` | OK-by-design |
| `ptpClockAvailable` | engine-start edge | edge-written once per `start()` | advisory only (UI degradation surfacing); a helper dying mid-session leaves it `true` | not refreshed | doc-only (name says "available", meaning is "was available at start"; the PTPHelperReconciler owns live health separately) |
| `opsInFlight` / `opWaiters` | op | actor-confined, `defer`-released | per-id serialization | n/a | OK-by-design |
| `started`/`starting`/`startedFlag`/`headlessFlag` | engine | kept in lock-step, documented benign races on the hot path | write gate | n/a | OK-by-design |

### NativeBackend — `reconcileCaptureGate` (the 7th rebuild path, ~line 5881)

The gate's stop/start is a FULL coordinator `stop()` + `start()` that does **not** go
through `recreateTap`. What it clears vs leaves in the coordinator:

- cleared: `tap`, `converter`, RT snapshot (emptied), state → `.idle`; backend-side it
  cancels `pendingCaptureRetry` and the scheduling poll. Ordering is safe: decisions
  serialize on `stateQueue`, replay in order on the serial `captureControlQueue`.
- left behind (correct): `meteringActive`, `currentExcludedBundleIDs`,
  `syncedLocalSink`/`renderPID`/base resampler (selection-driven), `lastExcludedObjects`
  (rewritten at the next commit before any reader).
- left behind (incorrect): the **coalescer pending flag** — Finding F2's enabling path.
- NativeBackend's own `syncedLocalSink` cache (`applySyncedLocalSinkTransition`, ~1998:
  `if let existing`) is process-lifetime — Finding F1's enabling path.

## Findings

### F1 — candidate-critical: `SyncedLocalSink.renderSampleRate` is frozen at first construction; the "lifecycle rebuild handles it" claim is false for the rate axis

- **Write edge:** `OwnToneBackend.swift` ~921–934 — the sink factory reads the default
  output device's nominal rate ONCE and passes it to `SyncedLocalSink(renderSampleRate:)`,
  where it is a `let` (`SyncedLocalSink.swift:136`). `NativeBackend.
  applySyncedLocalSinkTransition` (~2001) caches the constructed sink for the life of the
  process (`if let existing = syncedLocalSink`), so every later enable re-attaches the
  same instance.
- **Decision reads across longer lifetimes:** (1) `SyncedLocalSink.start()` builds its
  `AVAudioFormat`/engine render format from it (line ~258) on EVERY start — including every
  `performLifecycleRebuild()` after a default-device change; (2)
  `NativeCaptureCoordinator.setSyncedLocalSink` builds the `SyncedLocalBaseResampler`
  ratio from it at every attach; (3) the sink's pacing math (`nsPerFrame`, ring sizing).
- **The doc-lie:** the factory comment says "a later default-device change is handled by
  the sink's own lifecycle rebuild." The rebuild (`LifecycleHooks`) stops the engine,
  re-measures LATENCY, resets the anchor, and restarts — it cannot touch the immutable
  rate. Nothing anywhere re-reads the device's nominal rate into the sink.
- **Concrete failure scenario:** sink first built while the default output is a 48 kHz
  device (play-everywhere enabled once). User later switches the Mac's output to a
  44.1 kHz device (or the same device renegotiates). The lifecycle rebuild restarts the
  `AVAudioEngine` still demanding a 48 kHz render format on a 44.1 kHz device. Best case
  the output node silently SRCs forever (defeating T3 Part B's whole reason to exist);
  worst case opening the engine renegotiates the device's nominal rate 44.1→48 — which
  the whole-system tap's rate listener sees as a rate change → tap rebuild → session
  reset → the sink's own device-change listener fires → another rebuild: exactly the
  rate-flap → rebuild-churn family roadmap-016's judder investigation is chasing, and
  exactly the renegotiation dropout T3 Part B was built to prevent.
- **Shape match:** edge-written at construction of a process-cached object, decision-read
  across device-change lifetimes. Fix direction (not applied here): rebuild the sink
  instance (drop the cache) when the device's nominal rate no longer matches
  `renderSampleRate`, and re-derive the coordinator's base resampler on re-attach — it
  already is per-attach, so dropping the cache alone may suffice.

### F2 — candidate-critical: stranded `TapRebuildCoalescer` pending flag replays a stale `.deviceOrRateChange` (and its whole-system session reset) against a future tap generation

- **Write edge:** `NativeCaptureCoordinator.recreateTap` marks pending when a rebuild
  trigger lands while already `.creatingTap` (~1089). The flag lives on the
  COORDINATOR (`rebuildCoalescer`, ~212) but describes a fact about ONE in-flight rebuild
  generation.
- **Decision read:** consumed only at `recreateTap`'s successful commit (~1210).
  `start()`'s `.capturing` commit (~515) does NOT consume it, and neither `.failed` nor
  `stop()` (including the `reconcileCaptureGate` stop) clears it.
- **Concrete failure scenario:** (a) a device-change notification fires from the old
  tap's still-live subscription while a rebuild is in flight → `markPending`; (b) the
  in-flight rebuild fails (`.failed`) or a gate `stop()` wins the commit race; (c) later,
  the user re-selects a speaker → gate `start()` → `.capturing` (pending silently
  survives); (d) the connect's own sink-attach rebuild (`setSyncedLocalSink` →
  `.exclusionChange`) commits, `takePending()` returns the STALE flag, and replays a
  `.deviceOrRateChange` rebuild — firing `onDeviceRateRebuild` →
  `resetAirPlaySessionForWholeSystem`, i.e. the redundant post-connect RTP re-establish
  ("connects fast, then a long silence") that the cause-split was explicitly built to
  remove. Impact is bounded (one spurious rebuild + reset, not silent-forever) and the
  race is narrow, but the mechanism is exactly the class under audit. Same asymmetry
  exists in `PerAppCaptureCoordinator` (`beginStart` commit doesn't `takePending`), where
  the replay is only an extra per-app rebuild — noted doc-only there.
- **Fix direction (not applied):** consume-or-clear the pending flag at EVERY commit of a
  new `.capturing` (start's commit included) and at `stop()`'s transition to `.idle` —
  the flag should not outlive the rebuild episode it was marked in.

### F3 — candidate-critical: `start()` lacks the post-commit re-anchor verification `recreateTap` has — the blind window is closed on one path and open on the other

- **The asymmetry:** `recreateTap` closes the "default device moved while nobody held a
  listener" window with `TapReanchor` (compare outgoing anchor vs what the new tap landed
  on; ~1243–1258) and resets the session if the clock moved. `start()` — the initial
  start AND every `reconcileCaptureGate` restart — has no equivalent: no baseline, and no
  compare of `newTap.tappedDeviceID` / landed rate against a fresh
  `resolveDefaultOutputDeviceID()` read after commit.
- **Why nothing else rescues it:** `DefaultOutputDeviceMonitor.subscribe` deliberately
  fires no callback at subscription time ("a subscriber has just read the device itself",
  DefaultOutputDeviceMonitor.swift ~229), and delivery is per-subscriber — a flip that
  happens after `createAggregate`'s device read but before the new tap's subscription
  arms is delivered to nobody who cares, and no further notification is owed.
- **Concrete failure scenario:** user selects an AirPlay speaker (gate `start()` begins);
  during `createAndStart` — a multi-step HAL window that BT connects love to land in
  (F-SETTLE measured 4 rate flips in 0.9 s on a headset connect) — the default output
  flips from device A to B after the aggregate pinned A but before the monitor
  subscription armed. The tap comes up capturing device A, which nothing plays through:
  **silence, forever**, until an unrelated device/rate event happens to fire the
  subscriber's compare. This is the class's signature symptom, on the one rebuild path
  the existing re-anchor fact-check doesn't cover.
- **Fix direction (not applied):** after `start()`'s commit, one
  `resolveDefaultOutputDeviceID()` read compared against `newTap.tappedDeviceID` —
  mismatch ⇒ drive `handleDeviceChange()` (the machinery already exists).

## Closed — the three already-fixed instances (do not reopen)

1. **onBuffer-after-createAndStart** — both `start()` (~497) and `recreateTap` (~1165/1175)
   wire delivery BEFORE the create; the empty-snapshot gate is the single-delivery
   guarantee during make-before-break overlap. Per-app `beginStart`/`handleDeviceChange`
   comply too. Verified, closed.
2. **Flush device-vs-session state** — `flushOutput` makes no `device->state` pre-guard,
   lets the vendored call decide, and reports the honest issued flag (`IssuedBox`,
   ~996–1014); callers must treat `false` as "did not re-anchor". Verified, closed.
3. **Call-gate latch on the rebuildable tap** — deleted in `d5d2414`; no successor state
   found on tap instances. The durable house rules it left (wire before start;
   single-owner state on the coordinator, never on a rebuildable instance) are what this
   sweep audited against. Closed.

## Recommendation

**Recommend promoting 3 findings to roadmap** (F1 sink rate freeze — strongest judder
candidate; F2 stranded coalescer pending; F3 start-path re-anchor gap). F1 and F3 are
plausible contributors to the roadmap-016 judder/dropout symptom family; F2 is bounded
but same-class hygiene and cheap to fix alongside F3 (both touch `start()`'s commit).
