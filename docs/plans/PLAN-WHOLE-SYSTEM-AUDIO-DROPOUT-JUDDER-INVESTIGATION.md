# Investigation — whole-system AirPlay audio judder + complete dropout

Status: **OPEN — reproduced live, root cause NOT found.** Handoff for a dedicated
deep-dive session; deliberately NOT tackled inline during the roadmap-007
audio-routing-consolidation branch, per Alec's explicit call (2026-07-26) —
that branch stays scoped to the architecture-review defects it set out to fix.
Two smaller, related bugs found along the way ARE fixed on that branch (see
"What's already landed" below); this doc is about the one that isn't.

Branch this was found on: `claude/audio-routing-consolidation-92be71`
(worktree `.claude/worktrees/audio-routing-consolidation-92be71`). Roadmap
items: `012` (diagnostic added, in_progress), `014` (a related but distinct
symptom, planned, not started).

---

## The bug

Playing audio to a selected AirPlay device (Sonos, confirmed) while dragging
the macOS system volume slider **rapidly** up and down eventually produces
audible judder, followed by **complete silence from the AirPlay device** —
while the app's own per-app meter keeps showing activity, i.e. capture is
healthy and the failure is downstream of capture.

Live-reproduced once (2026-07-26, ~07:49–07:52 local). Telemetry for that
entire window is **completely clean**: no rebuild, no exclusion change, no
`bind_failed`, no rate renegotiation event, nothing — right up to the moment
described as broken. This is the core problem this doc exists to solve: **the
app currently cannot tell the difference between this failure and healthy
playback**, in its own logs.

A second, later reproduction attempt (same session, after the write-backlog
diagnostic below was added) did NOT reproduce the dropout — instead surfaced
a *different*, related-but-distinct symptom, now tracked separately as
roadmap `014`: rapid volume dragging desyncs the displayed Main Audio /
per-device volume percentages (`GroupController.mirrorSystemVolumeToMainOut`
racing against Sonos's DACP write-back latency). Whether `014`'s root cause
and this doc's root cause are the same underlying trigger (rapid volume
writes) manifesting two ways, or two unrelated bugs sharing a trigger action,
is itself an open question — see "First question to answer" below.

---

## What's already landed on the branch (read these commits first)

- **`844c5e1`** — a real, separate, CONFIRMED-FIXED bug: redirecting an app to
  "Play on this Mac" while an AirPlay device was selected sent the app's audio
  out the AirPlay device instead of the Mac, because the whole-system tap
  never excluded the app's own local-playback render process. Live-confirmed
  fixed by Alec. Not the judder bug — but the FIRST two "judder" reports
  turned out to BE this bug (self-capture-and-mute echo), not the one
  described above. Read this commit and its doc comments first so you don't
  re-diagnose an already-fixed issue.
- **`58ad83c`** — unrelated crash fix in `AudioDiag.log`, needed to get
  `AIRPLAY_AUDIO_DIAG` diagnostics working at all for this investigation.
- **`9965bd9`** (roadmap `012`) — `EngineSink` (the whole-system/stream-0
  write path) now samples `engine.writeBacklogSnapshot()` every 500 writes,
  delta-gated, logging `write_backlog_drop` with `path=wholeSystem`. This CAN
  catch one specific failure mode (the engine's own backpressure guard
  discarding writes) but did **not** catch anything on the one dropout
  reproduction we have — either because that reproduction predates this fix
  (it does — 012 landed after), or because backpressure-drop isn't the actual
  mechanism. **Not yet confirmed either way.**
- Roadmap `013` (a concurrent session, not this doc's author) — fixed a
  reentrant-deadlock crash in `DefaultOutputDeviceMonitor.start()` triggered
  by a Bluetooth connect. Different bug, same general "today's new shared
  monitor" area — check it's not somehow implicated if your investigation
  touches that file.

---

## What's ruled out

- **Not a route/state-machine flap.** No `captureWS`/`capturePA` transition,
  no `exclusion_changed`, no rebuild of any kind logged in the failure
  window. Whatever's wrong isn't in `NativeCaptureCoordinator` or
  `NativeBackend`'s routing logic — or if it is, it's failing to log about
  itself, which would itself be a finding.
- **Not a capture-side stall.** The app's own meter (driven by captured RMS)
  kept moving through the failure, per Alec's direct observation. PCM is
  still being captured and handed to the write path.
- **Not the AirPlay engine's already-instrumented paths** (as far as existing
  telemetry shows): `write_backlog_drop` (per-app path) never fired;
  `bind_failed`/`engine_bind`/`engine_rebind` (T6/T7, this branch) never
  fired; no rate-reconciliation or format-guard rejection fired.
- **Not (necessarily) the self-capture-echo bug** (`844c5e1`) — that one
  produces a *specific*, immediately-reproducible symptom (wrong output
  entirely, from the very first buffer) and is already fixed. This bug is a
  *degradation over time* under a specific stress action (rapid volume
  dragging), which is a different shape.

## What's NOT ruled out — this is most of the actual work

- **The vendored C RTP send path has essentially no Swift-side visibility.**
  `engine.write(pcm:pts:)` is fire-and-forget (`nonisolated`, no return
  value, no error channel) by design — see `EngineSink`'s doc comment. Below
  that, `AirPlayEngine.swift` exposes FOUR snapshot APIs, of which only ONE
  (`writeBacklogSnapshot`) is now sampled for stream 0 (see `012`):
  - `writeBacklogSnapshot()` — per-stream backpressure-drop counter. Sampled
    for stream 0 as of `012`. NOT yet proven to correlate with this bug.
  - `writeCadenceSnapshot()` — write-cadence deficit/overrun counters
    ("first-light backlog #4"). **Never sampled for either stream.**
  - `writeLatencySnapshot()` — env-gated pts-freshness probe
    (`AIRPLAY_DEBUG_LATENCY=1`, see `docs/latency-analysis.md`). **Never
    wired into ongoing telemetry at all**, only available as an ad-hoc poll.
  - `writeSchedulingSnapshot()` — wake latency / in-cycle work time /
    inter-arrival gap (T-ENG-SCHED-1). **CONFIRMED DEAD CODE, found during
    this investigation.** `NativeBackend.pollSchedulingSnapshot()`
    (`:3971-4002`) logs this as `send_sched` telemetry and reschedules
    itself ~5s later — but ONLY reaches the reschedule call (`:3999-4001`)
    AFTER its own guard `guard self.started, self.captureRunning else {
    return }` (`:3972`) passes. It is armed exactly ONCE, from
    `startSchedulingSnapshotPolling()` (`:3962-3966`), called from a single
    call site inside `start()` (`:1240`) — i.e. at app launch, before any
    device is ever selected, when `captureRunning` is `false`. The guard
    fails, the function returns, and NOTHING ever calls it again — not on
    the next capture start, not ever. Verified: `grep -c '"evt":"send_sched"'
    ~/Library/Logs/Audiouter/telemetry.jsonl` returns **0** across this
    machine's ENTIRE telemetry history, every session, ever. This is
    real, valuable scheduling telemetry that has never once fired in
    production. Fixing the re-arm (call `startSchedulingSnapshotPolling()`
    wherever `captureRunning` flips to `true`, not just once at `start()`)
    is a prerequisite for step 2 below, and is arguably a bug worth fixing
    on its own regardless of this investigation's outcome.
- **The trigger action itself is suspicious in a way nothing here explains.**
  Dragging the SYSTEM volume slider produces a rapid burst of
  `kAudioDevicePropertyVolumeScalar`-driven writes into
  `GroupController.mirrorSystemVolumeToMainOut` → `backend.setVolume` for
  every Main Out member, i.e. a burst of Sonos DACP volume-set network calls,
  potentially many per second, layered ON TOP of whatever's happening on the
  audio engine thread. Two live, real possibilities neither confirmed nor
  ruled out:
  1. The DACP volume-write burst competes for the same event loop / socket
     resources the AirPlay engine's RTP send uses (`event_base_dispatch`,
     per `AirPlayEngine.swift`'s workgroup doc comment — the engine thread
     does both `outputs_write`/`airplay_write`/encode/encrypt/send AND
     apparently whatever drives DACP), and enough concurrent volume writes
     starve or block the send path.
  2. Sonos itself, receiving a burst of volume-set commands, deprioritizes or
     drops the RTP stream on its end — a receiver-side behavior this app has
     no way to observe or distinguish from its own bug.
- **No packet-level (send success/failure/retry) telemetry exists anywhere**
  in the vendored engine, as far as this investigation got. If the RTP send
  itself is failing (not just backlogged), there may be nothing to sample —
  new instrumentation in the vendored C (`engine_bridge.c`/`outputs.c`/
  `player.c`) may be required, not just a new Swift-side sampler.

---

## First question to answer

Is this bug's trigger really "rapid volume dragging" specifically, or is it
"rapid Main Out mirror writes" — which `014`'s bug is ALSO caused by? If
they share a root cause (e.g., the DACP write burst itself is what
destabilizes something), fixing `014`'s desync might also fix or shed light
on this. Try to reproduce this dropout WITHOUT touching the system volume
slider at all — e.g. scripted/rapid `backend.setVolume` calls, or rapidly
toggling a device's own row slider in the app — to see if volume-key/slider
specificity is real or incidental.

## Suggested investigation order

1. Try to get a MORE RELIABLE repro. One live reproduction is not enough to
   root-cause from. Vary: with vs. without an active per-app redirect, with
   vs. without the Mac in Selected Devices, drag speed, drag via the Sound
   menu vs. media keys vs. this app's own Main Audio slider.
2. First, fix `pollSchedulingSnapshot()`'s dead re-arm (above) so `send_sched`
   actually fires during a real session — currently zero signal, so there is
   nothing to read even once reproduced. Then wire `writeCadenceSnapshot()`
   into ongoing telemetry too (never sampled anywhere today), same throttled
   pattern as `012`, so a reproduction has maximum diagnostic surface next
   time.
3. Reproduce with `AIRPLAY_DEBUG_LATENCY=1` AND `AIRPLAY_AUDIO_DIAG=<path>`
   both set, plus `AIRPLAYENGINE_LOG_FILE`/`AIRPLAYENGINE_LOG_LEVEL` (see
   `scripts/make-app.sh`'s diagnostic env passthrough list) to get the
   vendored engine's own logging, if any exists at a useful level.
3a. If none of the above shows anything DURING a live dropout, the next step
    is almost certainly adding new counters inside the vendored C send path
    itself (`AirPlayEngine/Sources/CAirPlayEngine/`) — a materially bigger
    change than anything in this doc, and worth a fresh `/plan` pass of its
    own once there's a concrete signal to design against, rather than
    guessing at instrumentation now.
4. Answer "First question to answer" above early — it changes whether this
   is one investigation or two.

## Non-goals for this investigation

- Do not attempt a fix before the mechanism is understood — no speculative
  debouncing/throttling of volume writes "just in case." That would hide the
  bug rather than fix it, and this codebase has explicit prior guidance
  against exactly that shape of fix (see `AudioDiag`'s and
  `DefaultOutputDeviceMonitor`'s doc comments on watcher-only, no
  pinning/throttling-as-a-workaround).
- Do not fold `014` (volume-percentage desync) into this investigation's
  scope unless "First question to answer" above concludes they share a root
  cause. Keep them as separate roadmap entries otherwise.
