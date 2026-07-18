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

### C5 — start() holds the state lock across blocking HAL work

**Site:** `AudioutedCore/Sources/AudioutedCore/NativeCaptureCoordinator.swift`
`start()` at line 159 wraps `beginStart()` (194–219) in `queue.sync`, and
`beginStart()` calls `tap.createAndStart(...)` at line 205 — a blocking Core
Audio call — from inside that same lock.

**Mechanism:** every other reader of the state queue (the `stop()` path, a
concurrent buffer delivery, or a plain state read) blocks behind however
long `createAndStart` takes on the HAL. On a slow or contended device that
turns a start into an app-wide stall; a caller waiting on quit or state read
sees a freeze, not a crash, but the shape is identical to the deadlock this
audit found elsewhere in the same file's `handleDeviceChange`.

**Fix sketch:** apply the claim-under-lock / create-off-lock / commit-under-
lock pattern `handleDeviceChange()` already uses (251–299): claim the "we're
starting" state and hand off any old tap reference inside a short lock,
call `createAndStart` outside any lock, then commit the new tap/converter
back under a second short lock (guarding against a race with `stop()`).

**Rough cost:** medium — restructuring one method to mirror an existing
sibling pattern in the same file; the hard design work is already done.

When fixed: delete the STABILITY(C5) marker(s) at
`NativeCaptureCoordinator.swift:159,194,205` and move this entry to
Resolved.

### C6 — a device change during tap recreation is silently dropped

**Site:** `AudioutedCore/Sources/AudioutedCore/NativeCaptureCoordinator.swift`
`handleDeviceChange()`, guard at line 258 (`guard case .capturing = _state
else { return (false, nil) }`).

**Mechanism:** if a second default-device change arrives while the first is
still mid-flight (state is `.creatingTap`, not `.capturing`), the guard's
`false` branch drops it on the floor — there is no queued retry. Capture
stays pinned to the stale device until some unrelated state transition
happens to re-trigger a device read.

**Fix sketch:** a `pendingDeviceChange` flag set when the guard rejects a
change; the commit path in `handleDeviceChange()` checks and replays it
after landing in `.capturing`.

**Rough cost:** small — one flag plus a check at the existing commit point.

When fixed: delete the STABILITY(C6) marker(s) at
`NativeCaptureCoordinator.swift:258` and move this entry to Resolved.

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

### D3 — per-buffer level fan-out amplifies every stall

**Site:** `AudioutedCore/Sources/AudioutedCore/NativeBackend.swift`,
`emitLevel(_:)` at lines 1544–1550 — an `async` hop onto `stateQueue`,
followed by a `MainActor` emit, fired once per captured buffer (roughly
86/s per device at the current tap format).

**Mechanism:** each fan-out is cheap alone, but at 86/s per selected device
it is by far the highest-frequency traffic on `stateQueue` and the
`MainActor`. Any other work queued behind it (including the C8 sites above)
inherits that cadence as its worst-case latency, and multiple selected
devices multiply the rate directly.

**Fix sketch:** coalesce level emission to display cadence (~25 Hz) —
either a leading-edge/trailing-edge sampler in `emitLevel` or a downstream
throttle before the `MainActor` hop.

**Rough cost:** small — a rate limiter around one function.

When fixed: delete the STABILITY(D3) marker(s) at
`NativeBackend.swift:1544` and move this entry to Resolved.

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

These are tracked outside this file — by pending one-click task chips
(B1/B2/C4) or as phase-2/3 backlog (B3/B4/B5/B6/B9/C1/C2/C3) — and
deliberately carry **no** `STABILITY(id)` marker in source. Don't add one;
duplicating tracking here would just drift.

- **B1** — `NativeCaptureCoordinator.swift`, the HAL property-listener
  registration — passes a `nil` dispatch queue, so the callback lands on an
  unspecified (potentially the HAL's own) thread instead of a queue this
  code controls.
- **B2** — `NativeCaptureCoordinator.swift`, `handleDeviceChange()` — the
  old tap's teardown historically ran inside the state lock in this path
  (distinct from the `beginStart` case tracked as C5); risk is the same
  head-of-line blocking shape.
- **C4** — `NativeCaptureCoordinator.swift`, tap format construction — no
  guard against a NaN/zero sample rate reaching the converter, which would
  propagate silently rather than failing loud.
- **B7** — `PopoverController.swift`, a per-tick rebuild path — risk of
  redundant work on a timer-driven cadence rather than only on real state
  change.
- **B8** — `PopoverController.swift`, rebuild while the popover is hidden —
  risk of doing full rebuild work the user can't see, wasting cycles that
  matter more while other operations are in flight.
- **B3–B6, B9, C1–C3** — phase-2/3 backlog items from the same audit pass;
  tracked in the scheduling system, not restated here to avoid two sources
  of truth.

## Section 3 — Resolved by this merge

- **A2** — null-session guard added in the output-removal path (`removeOutput`)
  so a session already torn down doesn't get operated on a second time.
- **D1** — SIGPIPE is ignored at launch, and a crash-proof stderr log is
  established before anything else runs, so an early crash still leaves a
  diagnosable trace.
- **D2** — an uncaught-exception handler now leaves a breadcrumb before the
  process dies.
- **A1 (partial)** — an Objective-C exception shim was built on `main`;
  adoption in the per-app-routing branch is still pending. See
  `dev/notes/objc-exception-shim-handoff.md` for the handoff.
