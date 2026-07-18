# Stability audit — 2026-07-18

Five real crash logs were root-caused against this codebase. The audit
produced 31 findings; this file is the single source of truth for all of
them — what each one is, where it lives, and its current status.

**Marker convention.** Findings in Section 1 get an inline comment at each
cited site: `// STABILITY(id): one-line constraint — see this file`. The id
matches the heading below. The marker exists so an agent editing that code
later sees the constraint before it re-introduces the bug.

**Maintenance rule.** Fixing a finding is not done until, in the same
change: delete every `STABILITY(id)` marker for that id, and move the entry
from Section 1 to Section 3 (Resolved) here. A fix that leaves a stale
marker is worse than no marker — it teaches the next reader to stop trusting
them.

As of this writing `git grep -n 'STABILITY('` returns nothing — the markers
land with the fix-sites task that follows this one. IDs and sites below are
the contract that task transcribes from; if a site shifts before the marker
lands, re-verify against source rather than trusting this line number.

## Section 1 — Fix when you touch this code

### C6a — per-app play/pause recovery (T2/T3/T4 redesign)

Per-app routed capture previously went silent when a paused app resumed if the rebuild hit a rate mismatch or the app's process object disappeared (the pid was no longer audible). Three coordinated fixes eliminate the failure modes:

**T2 — indefinite capped-exponential backoff:** `NativeBackend.scheduleProcessNotYetAudibleRetry` (line 1363) changed from bounded (5×2s, then permanent silent dead) to capped-exponential `retryDelay × 2^(attempt-1)`, capped at `processNotYetAudibleMaxBackoff` (default 10s, injected at line 471). The retry runs indefinitely while the route is desired, removing the permanent-failure cliff.

**T3 — paused-app process-object recovery:** `PerAppCaptureCoordinator` now registers a system-wide `kAudioHardwarePropertyProcessObjectList` listener (installed lazily in `installProcessListListenerLocked`, line 139) — when a paused app resumes and its process object reappears (line 139: `mSelector: kAudioHardwarePropertyProcessObjectList`), the listener fires `handleProcessListChanged()` (line 514), which re-drives every failed slot through the normal `.capturing` recovery path (lines 515–523). Dead slots that were retrying before the resume self-heal near-instantly.

**T4 — bounded AirPlay rebind recovery:** `NativeBackend.resetAirPlaySessionForRoutedApp` (line 1235) is called after a per-app tap rebuild (line 1192) to recover the AirPlay session if the rebuild changed the audio format. The rebind (removeOutput → addOutput) now has bounded recovery via `enqueueRebindRecovery` (line 1272): 3 attempts (line 1290: `maxRebindRecoveryAttempts`, injected), backoff 0.5s→1s (line 1299, `rebindRecoveryRetryDelay`), single-flighted per device via `rebindRecoveryGen` (line 396, bumped on each reset at line 1243), and loud failure logging (line 1291–1294). Succeeds if the device re-locks (removeOutput + addOutput both succeeding), gives up if the device is truly gone (e.g. powered off mid-playback).

Together, T2/T3/T4 form the "lost tap" recovery loop for per-app capture:
- **T2** retries the tap creation indefinitely while waiting for the process to become audible.
- **T3** detects when the paused process wakes and re-drives creation attempts.
- **T4** ensures the AirPlay session is rebinced cleanly after each tap rebuild, with bounded recovery if the device briefly rejects the rebind.

This is the production per-app routing safety net; the system-wide tap has only the device-change coalescing from C6 (see Section 3 — resolved).

### C7 — discovery re-resolve clears the failure gate with no backoff

**Site:** `AudioutedCore/Sources/AudioutedCore/NativeBackend.swift`, the
`self.failedGate.remove(id)` at line 1065, and the re-kick block ending in
`Task { [weak self] in await self?.convergeDevice(...) }` around
1094–1102.

**Mechanism:** every AP2 discovery re-resolution for a device — which
happens on ordinary Bonjour re-adverts, not just recovery — clears
`failedGate` and, if the device is still desired-on, re-kicks the converge
loop unconditionally. A receiver that's flapping (dropping and re-
advertising repeatedly) drives an unbounded reconnect loop with no backoff,
competing for the same converge/network resources that a healthy device
needs.

**Fix sketch:** track a per-id last-failure timestamp; let a discovery-
driven re-kick honor a backoff window measured from that timestamp, while a
direct user toggle still re-kicks immediately (never gated).

**Rough cost:** small — one timestamp dictionary plus a threshold check
ahead of the existing re-kick condition.

When fixed: delete the STABILITY(C7) marker(s) at `NativeBackend.swift:1065`
and `NativeBackend.swift:1094` and move this entry to Resolved.

### C8 — main thread blocks on the state queue for slow work

**Sites:**
- `AudioutedCore/Sources/AudioutedCore/NativeBackend.swift:482` —
  `setOutputSet`'s `stateQueue.sync { ... }`, called from the main thread on
  every routing change.
- `AudioutedCore/Sources/AudioutedCore/NativeBackend.swift:220` — the
  `devices` getter, also a `stateQueue.sync`.
- `AudioutedCore/Sources/AudioutedCore/GroupController.swift:167` —
  `device(_ id:)` calls `backend.devices` (so re-enters the sync above) and
  is called in loops during repaints.

**Mechanism:** there is no deadlock cycle today — `stateQueue` never calls
back into the main thread — but every one of these is main-blocks-on-
worker. The queue currently only does fast dictionary/array work, so the
block is imperceptible; the risk is structural: the next feature that adds
slower work to `stateQueue` (a network call, a disk write, anything) turns
every UI click that touches routing or device state into a visible freeze,
with no warning at the call site that it's now synchronous-blocking.

**Fix sketch:** make `setOutputSet`'s critical section `async` where no
caller consumes a return value (most don't); have `GroupController`
snapshot `backend.devices` once per operation instead of calling `device(_:)`
per row inside a loop.

**Rough cost:** medium — touches a public API shape (`setOutputSet`) and a
hot repaint path; needs care that call sites don't rely on synchronous
ordering.

When fixed: delete the STABILITY(C8) marker(s) at `NativeBackend.swift:482`,
`NativeBackend.swift:220`, and `GroupController.swift:167` and move this
entry to Resolved.

### D4 — UI-thread stalls and stuck-drag state (several sub-items)

**Sync persistence on main per gesture:**
- `AudioutedCore/Sources/AudioutedCore/AppRoutingController.swift:31` —
  `persist()` calls `try? store.save(appRoutes)` synchronously, invoked from
  a UI gesture handler.
- `AudioutedCore/Sources/AudioutedCore/GroupController.swift:155` —
  `persistRouting()`, same shape.

**Blocking XPC on main:**
- `AudioutedCore/Sources/AudioutedSettingsUI/GeneralSettingsViewController.swift:52`
  — `launchToggled()` calls `try loginItem.setEnabled(desired)` directly on
  the button's action handler, which round-trips `SMAppService` XPC
  synchronously.

**Stuck-flag drag heuristic:** the per-row drag-in-progress flag is only
cleared when the row happens to see an event whose type is `.leftMouseUp`
at the same moment as the last continuous slider callback. `Esc` or any
other way of ending a drag without that exact coincidence leaves the flag
set, so the row keeps ignoring model updates indefinitely.
- `AudioutedCore/Sources/AudioutedSharedUI/AppRowView.swift:360` (flag set
  at 360, cleared conditionally at 362)
- `AudioutedCore/Sources/AudioutedSharedUI/DeviceRowView.swift:583`
  (set), `:585` (conditional clear)
- `AudioutedCore/Sources/AudioutedPopoverUI/MainOutRowView.swift:289`
  (set), `:296` (conditional clear) — note this row uses a differently-named
  drag flag than the two above, same shape
- `AudioutedCore/Sources/AudioutedPopoverUI/GroupRowView.swift:251` (set),
  `:258` (conditional clear) — this one additionally leaves
  `GroupController`'s per-group drag-ratio cache stale, since nothing else
  invalidates it

**Per-row global mouse monitors churned on rebuild:**
- `AudioutedCore/Sources/AudioutedSharedUI/DeviceRowView.swift:778`
- `AudioutedCore/Sources/AudioutedSharedUI/AppRowView.swift:468`
- `AudioutedCore/Sources/AudioutedPopoverUI/GroupRowView.swift:318`

IMPORTANT nuance: the app-wide `.mouseMoved` local-monitor pattern itself is
deliberate and documented in
`AudioutedCore/Sources/AudioutedSharedUI/AGENTS.md` (~line 11) as the
intentional replacement for `NSTrackingArea`. The finding here is about
per-row multiplicity and churn on every popover rebuild — each row adds its
own app-wide monitor and removes it on teardown, so a rebuild briefly
carries N live monitors doing the same job — not about the pattern choice.
Word any fix so it reduces churn (e.g. one shared monitor dispatching to
rows) without reverting to `NSTrackingArea`.

**Structural rebuild mid-drag detaches the tracked slider:**
- `AudioutedCore/Sources/AudioutedPopoverUI/PopoverController.swift:343`
  — when `deviceSetChanged` is true, the full `rebuild()` path runs even if
  a slider drag is in progress, replacing the row (and its slider) the user
  has the mouse down on.

**Fix sketch (all sub-items):** persistence — hop `save` calls off main
(existing `store` types are already narrow enough to wrap in an async
call); XPC — wrap `SMAppService` calls in a background task, update the
switch state on completion; stuck-flag — clear the flag on `mouseUp`/`
mouseExited`/any terminal Cocoa event, not only the coincidence with the
last change callback; monitor churn — hoist to one shared dispatcher keyed
by row; mid-drag rebuild — have `rebuild()` skip or defer while any row's
drag flag is set.

**Rough cost:** small per sub-item, medium in aggregate (many sites).

When fixed: delete the STABILITY(D4) marker(s) at the sites listed above
and move this entry to Resolved.

### D5 — legacy OwnTone backend (fix only if that path stays shipped)

**Sites:**
- `AudioutedCore/Sources/AudioutedCore/ConnectionDiagnostics.swift:276-291`
  — the Bonjour browse continuation inside the async diagnose flow resumes
  on `.failed` (line 288) but never on `.cancelled`; if the browser is torn
  down by cancellation instead of failing outright, the continuation is
  never resumed. *Correction vs. the original brief:* this is one
  contiguous site (276–291), not two separate ranges — the TCP-probe
  continuation a few lines below (318–333) is a different call and is
  already bounded by a sibling timeout task in the same `withTaskGroup`, so
  it does not hang.
- `AudioutedCore/Sources/AudioutedCore/OwnToneBackend.swift:568`
  (`recoverZombies(_:expected:)`) — recovery re-`setOutputSet`s the
  `expected` set captured at call time without re-checking current intent,
  so it can re-select a device the user deselected while recovery was in
  flight.

**Mechanism:** the un-resumed continuation means `diagnose()` can hang its
calling task forever on a cancellation path, leaking a `NWBrowser`/
connection per failed-and-cancelled attempt. The recovery re-select is a
plain stale-capture bug: user intent moved on, recovery didn't notice.

**Fix sketch:** resume the continuation (with `nil`) on `.cancelled` as well
as `.failed`; in `recoverZombies`, re-read current desired state before
the final `setOutputSet` rather than trusting the captured `expected`.

**Rough cost:** small for both.

When fixed: delete the STABILITY(D5) marker(s) at
`ConnectionDiagnostics.swift:276` and `OwnToneBackend.swift:568` and move
this entry to Resolved.

### D6 — narrow verified races

**Sites:**
- `AudioutedCore/Sources/AudioutedCore/DefaultOutputObserver.swift:12`
  (`onChange` closure) and `:16` (`currentDeviceName`) — both documented as
  queue-confined, but `onChange` is a plain `var` settable from any thread
  and `currentDeviceName`'s doc comment claims readable-from-any-thread
  safety that depends on every write going through `queue`, which isn't
  enforced by the type.
- `AudioutedCore/Sources/AudioutedCore/CaptureCoordinator.swift:311` — a
  `Task { [weak self] in self?.captureProcess?.stop() }` reads
  `captureProcess` off the coordinator's own queue, from inside a detached
  `Task`, racing any queue-confined mutation of the same property.
- `AudioutedCore/Sources/AudioutedCore/CaptureProcess.swift:120-129` — the
  shared `LineBuffer` is appended to from the `readabilityHandler` callback
  and flushed from the `terminationHandler` callback; both can fire on
  different GCD threads around process exit with no shared lock between
  them.

**Mechanism:** each is a narrow, low-frequency data race rather than a
reliably-reproducible crash — most likely symptom is an occasional torn
read or a dropped trailing log line right at process exit, not a hard
crash, but they're real races per the source, not speculative.

**Fix sketch:** one lock (or queue-confinement enforced by making the
property `private(set)` plus a setter method) per site.

**Rough cost:** small each.

When fixed: delete the STABILITY(D6) marker(s) at
`DefaultOutputObserver.swift:12`, `CaptureCoordinator.swift:311`, and
`CaptureProcess.swift:120` and move this entry to Resolved.

## Section 2 — Scheduled work (no inline markers)

These are tracked outside this file — as phase-2/3 backlog
(B3/B4/B5/B6/B9/C1/C2/C3) — and deliberately carry **no** `STABILITY(id)`
marker in source. Don't add one; duplicating tracking here would just drift.

- **B7** — RESOLVED by the per-app-routing landing (the app-row volume
  handler now explicitly avoids the per-tick rebuild; its comment documents
  why). No further work needed.
- **B3–B6, B9, C2–C3** — phase-2/3 backlog items from the same audit pass;
  tracked in the scheduling system, not restated here to avoid two sources
  of truth.

## Section 3 — Resolved by this merge

- **C6** — a rebuild trigger arriving mid-rebuild is no longer silently
  dropped. `NativeCaptureCoordinator` gained a queue-confined
  `pendingDeviceChange` flag: `recreateTap()`'s claim guard sets it when a
  trigger (a `handleDeviceChange()` device change, or an
  `updateRouting(...)` exclusion change) lands while the coordinator is
  already `.creatingTap`, and the successful commit path checks it and
  replays a fresh `recreateTap()` once back in `.capturing` — coalescing
  however many were dropped into a single retry. This is the whole-system
  port of `PerAppCaptureCoordinator`'s per-slot fix (branch
  `claude/play-pause-input-listening-218047`, 375c6bc). New unit test
  `testDeviceChangeDuringRebuildIsCoalescedAndReplayed` (mirroring the
  per-app test) covers it via a `FakeTap.onCreateAndStart` hook that fires a
  second device change mid-rebuild. The STABILITY(C6) markers in
  `NativeCaptureCoordinator.swift` now document the shipped fix rather than a
  TODO.
- **C5** — `NativeCaptureCoordinator.start()` no longer holds `queue` across
  `createAndStart`: restructured to claim-under-lock / create-off-lock /
  commit-under-lock (the shape `recreateTap()` uses), with the commit
  detecting a racing `stop()` and discarding the new tap out of lock.
  `beginStart()` was folded away and its STABILITY(C5) markers deleted.
- **B1** — the default-output-device HAL listener is now registered (and
  removed) with a private serial `listenerQueue` instead of a `nil` queue,
  so the blocking teardown+recreate handler no longer runs re-entrantly on
  Core Audio's own notification thread. Mirrors `SystemOutputVolume`.
- **B2** — the raced-stop branch in `recreateTap()` now returns the orphan
  just-created tap from the `queue.sync` block and tears it down OUTSIDE the
  lock (its IO callback also takes `queue`, so in-lock teardown deadlocked).
- **C4** — tap format construction guards `asbd.mSampleRate.isFinite && > 0`
  before the `Int(...)` narrowing (NaN would trap), the converter guards its
  resample-ratio site, and the coordinator validates the format into
  `.failed(.formatReadFailed)` before committing to `.capturing`. New unit
  test `testZeroSampleRateFormatLandsInFailed` covers it.
- **A2** — null-session guard added in the output-removal path (`removeOutput`)
  so a session already torn down doesn't get operated on a second time.
- **D1** — SIGPIPE is ignored at launch, and a crash-proof stderr log is
  established before anything else runs, so an early crash still leaves a
  diagnosable trace.
- **D2** — an uncaught-exception handler now leaves a breadcrumb before the
  process dies.
- **D3** — `emitLevel` now coalesces per-device `.level` emission to a ~25 Hz
  leading-edge/trailing-edge sampler (`scheduleLevelEmit`/`flushPendingLevel`,
  40ms window) instead of firing on every captured buffer (~86/s), cutting
  the highest-frequency traffic on `stateQueue` while keeping meters visually
  live and guaranteeing a burst's final value is always delivered.
- **B8** — `PopoverController.update(devices:)` no longer rebuilds while the
  popover is closed: state is ingested, the view tree is left alone, and
  `rebuildForOpen()` (which runs on every open) rebuilds from current state.
  Headless tests exercise the shown-path repaint via `test_isShownOverride`;
  closed-state no-rebuild + correct-on-next-open have dedicated tests.
- **A1 (partial)** — an Objective-C exception shim was built on `main`;
  adoption in the per-app-routing branch is still pending. See
  `dev/notes/objc-exception-shim-handoff.md` for the handoff.
- **C1** — quitting while streaming no longer outruns the AirPlay goodbye:
  `AppDelegate.applicationShouldTerminate` calls `backend.stop()` then
  `.terminateLater`, awaits the bounded `OutputBackend.stopAndWait(timeout:
  .seconds(2))` seam, shows a delayed (~300ms) "Disconnecting…" indicator so a
  slow quit doesn't read as a hang, then replies. Residual (not resolved by
  C1): `NativeBackend.stop()` still runs `perAppCapture.stopAll()` /
  `routeMixer.flush()` / `localPlaybackEngine?.stop()` on the caller thread —
  bounded, graphQueue-serialized work, but a follow-up candidate to move off
  the quit path.
- **B4** (E1) — `EngineThread.enqueue` no longer silently drops work: it returns
  `Bool`, `run` throws `engineNotRunning` when scheduling fails, tracked pending
  bodies are swept in `stop()`, and `startOp` fails its continuation on a failed
  enqueue — so a pre-start/post-stop op fails fast instead of freezing forever.
- **B5** (E1) — completion-slot reuse closed three ways: per-`OutputID` op
  serialization in the `AirPlayEngine` actor (a second op on an id awaits the
  first), a `outputs_callback_clear(callback_id)` shim enqueued on op timeout to
  free the leaked C slot (plus a `device_cb_set(-1)` session reset when live),
  and `CompletionRegistry.arm` now refuses (returns false) rather than clobber an
  existing waiter. Coexists with NativeBackend's per-output volume serialization.
- **C2** (E1) — the engine survives stop→start: `start()` builds a FRESH
  `EngineThread` per start (held in `EngineThreadHolder`), guarded by a `starting`
  reentrancy flag set before the first suspension point, and `stop()` calls the
  new `outputs_registry_clear()` shim (empties `device_list`, NULLs sessions,
  resets the callback register) so a later start begins clean.
- **C3** (E1) — `EngineThread.stop()` deadlines its join (~3s): a callback wedged
  in a blocking syscall no longer hangs `stop()` (and the engine actor) forever —
  on expiry it logs loudly (stderr + os_log fault), sweeps pending continuations,
  and deliberately LEAKS the thread/base. Wedged-thread + real rapid stop→start
  behaviour still needs a gated live test.
- **B6a** (Phase 3) — the mach→CLOCK_MONOTONIC pts offset is no longer a
  process-lifetime `static let`: it lives per tap instance, reseeded on every
  tap create/recreate, and every buffer runs a cheap signed-drift check that
  resamples the offset if it diverges >1s (a sleep mid-tap self-heals with no
  observer). Streaming surviving a real >1 min sleep still needs a gated live
  test.
- **B6b** (Phase 3) — the app's first sleep/wake handling: NSWorkspace
  observers (app layer) drive a new backend seam; sleep gracefully removes
  engine outputs WITHOUT clearing selection intent (events suppressed while
  suspended so the reverse auto-swap can't fire), wake re-converges every
  desired-on device (reseeding volume via the normal added edge). A
  user-configurable wake watchdog (Settings › Audio, Never/1/2/5/10 min,
  default 2) un-gates capture — un-muting the Mac — if speakers never return,
  without touching intent; a late reconnect re-engages the gate. Live
  sleep/wake proof pending.
- **B9** (Phase 3) — discovery survives NWBrowser `.failed` (previously
  terminal = discovery dead for the session): per-service-type browser
  recreate with capped backoff (1s→30s, reset on `.ready`), stop-safe
  cancellation of pending recreates; both stale "browser owns its own retry"
  comments corrected. Live mDNSResponder-kill recovery proof pending.
