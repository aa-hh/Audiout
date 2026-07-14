# The outputs-dispatcher (`outputs_cb`) callback-accounting contract — R-A

**Task:** T-SHIM-1, item 1 (highest risk, seam-map §2.1 / §10.1 risk R-A).
**Question this doc answers:** exactly how many times does `airplay.c` call
`outputs_cb(callback_id, device_id, state)` per `device_*` operation, and how must
our `shims/outputs.c` account for those calls so the engine unblocks (and never
hangs) under the normal, error, auth-retry, reconnect and teardown paths?

**How it was verified:** by reading the *consumer* of the callbacks —
OwnTone's own `src/outputs.c` (the file our `shims/outputs.c` replaces) and the
call sites inside the vendored `src/outputs/airplay.c` — from the pinned tag-29.2
source at `dev/owntone-src/`. This is a static + cross-referenced read of both
sides of the seam (the caller `airplay.c` and OwnTone's reference dispatcher),
which is authoritative because the contract is defined by that exact pair of files
— the same `airplay.c` we vendored, and the `outputs.c` we are re-implementing.
A live PTP session was **not** run (no receiver hardware; that is T-API-1 /
T-HARNESS-2). The dispatcher unit test (`OutputsDispatcherTests`) exercises the
accounting logic in isolation against this documented contract.

---

## 1. The core invariant (the whole contract in one sentence)

> Every `device_*` entry point in `airplay.c` that **returns a positive integer N
> promises to invoke `outputs_cb(callback_id, …)` exactly N times** for the
> `callback_id` it was handed — and in this cluster **N is always exactly 1**.
> A return of **0** or a **negative** value promises **zero** callbacks.

There is no operation in the AirPlay 2 sender that fires the callback more than
once, and none that fires it a variable number of times. The accounting is
therefore: **one op in-flight ⇒ one pending callback ⇒ one completion.**

This is enforced structurally in `airplay.c` by `session_status()`
(airplay.c:1061):

```c
outputs_cb(session->callback_id, session->device_id, state);
session->callback_id = -1;          // <- consumed; cannot fire again
```

The `callback_id = -1` immediately after the single call is the linchpin: once a
session has reported, its stored id is cleared, so no later state transition on
that same session can produce a second callback for that id. A fresh op must
re-arm the session with a new `callback_id` (via `device_cb_set`,
`airplay_device_stop`, `…flush`, or a new `session_make`).

---

## 2. Per-operation N (return value → callbacks promised)

From `airplay.c` (return values) cross-checked against how OwnTone's `outputs.c`
adds them up (`pending += ret`, only when `ret > 0`):

| op (`output_definition` slot) | fn | returns | callbacks (N) | notes |
|---|---|---|---|---|
| `device_start` | `airplay_device_start` (4159) | `1`, or `-1` if `session_make` fails | 1 (or 0 on -1) | starts the RTSP SEQ_START sequence |
| `device_probe` | `airplay_device_probe` (4145) | `1`, or `-1` | 1 (or 0) | SEQ_PROBE (connectivity only) |
| `device_stop` | `airplay_device_stop` (4173) | `1` | 1 | SEQ_STOP (TEARDOWN) — always has a live session |
| `device_flush` | `airplay_device_flush` (4185) | `1`, **or `0` if not STREAMING** | **1 or 0** | the only op that legitimately promises 0 |
| `device_volume_set` | `airplay_set_volume_one` (1875) | `1`, or `0`/`-1` | 1 (or 0) | SEQ_SEND_VOLUME |
| `device_authorize` | `airplay_device_authorize` (4217) | `1`, or `-1` | 1 (or 0) | PIN pairing sequence |
| `device_cb_set` | `airplay_device_cb_set` (4200) | `void` | 0 directly | **re-arms** callback_id on a live session; the *pending* op that set the timer (e.g. `stop_delayed`) is what eventually fires it |

**Consequence for our shim:** the shim does **not** need to know N per op. N is
reported to the layer *above* `outputs_cb` (the request issuer) by the return
value of the `device_*` call, which our engine/Swift layer captures directly. The
`outputs_cb` dispatcher's only job is to **match each incoming callback to the
waiter that holds that `callback_id` and release it** — exactly once per id.

---

## 3. The callback-id registry (how OwnTone tracks pending ops)

OwnTone's `outputs.c` owns a fixed table (this is the mechanism we reproduce):

```c
#define OUTPUTS_MAX_CALLBACKS 64
struct outputs_callback_register {
  output_status_cb cb;             // who to notify
  struct output_device *device;    // which device armed it
  bool ready;                      // backend has reported
  uint64_t device_id;              // captured at report time (device ptr may die)
  enum output_device_state state;  // the reported state
} outputs_cb_register[OUTPUTS_MAX_CALLBACKS];
```

Lifecycle of one slot:

1. **`callback_add(device, cb)`** (outputs.c:166): called *by* the wrappers
   (`outputs_device_start` etc.) right before invoking the backend. It
   `callback_remove(device)`s any prior slot for that device (**"replace any
   previously registered callback, since that's what the player expects"**), then
   finds a free slot, stores `{cb, device}`, and returns its index as the
   **`callback_id`** that is passed into the backend's `device_*(device, callback_id)`.
   → So **at most one pending callback per device** at a time; a new op on a device
   overwrites the old registration.

2. **`outputs_cb(callback_id, device_id, state)`** (outputs.c:737): the backend
   (airplay.c) calls this when its async sequence reaches a reportable state. It
   **does not call the user cb directly** — it marks the slot `ready`, stores
   `device_id`+`state`, and schedules a deferred libevent callback:
   ```c
   outputs_cb_register[callback_id].ready = true;
   outputs_cb_register[callback_id].device_id = device_id;
   outputs_cb_register[callback_id].state = state;
   event_active(outputs_deferredev, 0, 0);   // fire deferred_cb on the loop
   ```
   Guards: `callback_id < 0` → ignored; out-of-range or empty slot → logged as a
   bug and ignored (a defensive no-op, NOT a hang).

3. **`deferred_cb`** (outputs.c:205, runs on the event loop): scans for `ready`
   slots, and for each: copies `{cb, state}`, resolves `device` by `device_id`
   (NULL if it vanished), **clears the slot** (`memset`), then invokes
   `cb(device, state)`. If the device has stopped/failed and the backend no longer
   holds it (`!advertised && !session`), it's removed from the registry first.

**Two deliberate design points we must preserve:**
- **Deferral.** The user callback never runs synchronously inside `outputs_cb`
  (which airplay.c calls from deep inside its RTSP state machine). It is always
  hopped onto the event loop. This avoids re-entrancy (the callback may issue a
  new op, freeing/reallocating the very session that is mid-call).
- **device_id, not device pointer.** The completion stores the u64 `device_id` and
  re-resolves the pointer at delivery time, because the device may be freed
  between the report and the deferred delivery.

---

## 4. The edge paths that could break the 1:1 count (and why they don't)

These are the paths seam-map §10.1 flagged as "needs a runtime trace." Traced
here from `airplay.c`:

### 4a. Failure — `session_failure` (airplay.c:1287)
```c
if (session->state != AIRPLAY_STATE_AUTH) session->state = AIRPLAY_STATE_FAILED;
session_status(session);     // fires outputs_cb ONCE (state FAILED or PASSWORD)
session_cleanup(session);    // frees session; callback_id already -1
```
→ **exactly 1** callback (FAILED, or PASSWORD if it was an AUTH state). The
subsequent `session_cleanup` does **not** fire again — `session_status` already
cleared `callback_id` to -1, and `session_cleanup`/`session_free` never call
`outputs_cb`.

### 4b. Deferred failure — `deferred_session_failure` (airplay.c:1308) / `rtsp_close_cb` (1320)
Sets FAILED state, arms `session->deferredev`; the timer later runs
`session_failure` → same as 4a: **exactly 1** callback, just later. The RTSP
connection closing (`rtsp_close_cb`) routes here → still 1.

### 4c. Auth-retry / ipv6→ipv4 fallback — `start_retry` (airplay.c:2990) ⚠ the subtle one
```c
int callback_id = session->callback_id;   // SAVE the id
device = outputs_device_get(session->device_id);
if (!device)                    { session_failure(session); return; } // 1 cb
if (family != AF_INET6 || hard) { session_failure(session); return; } // 1 cb
device->v6_disabled = 1;
session_cleanup(session);                  // drop old session — does NOT fire cb
airplay_device_start(device, callback_id); // NEW session carries the SAME id
```
→ The old session is torn down **without** firing (its id was moved out first),
and a brand-new SEQ_START session is created **re-using the identical
`callback_id`**. So across the whole retry there is still **exactly 1** eventual
callback for that id. This is the one place where the callback survives a session
teardown — and it is precisely why the registry keys on a stable `callback_id`
(and stores `device_id`), not on the session/device pointer. **Our dispatcher must
therefore NOT release/clear the waiter on session teardown — only on an actual
`outputs_cb` invocation.**

### 4d. Password-required — AUTH state
`session_status` maps `AIRPLAY_STATE_AUTH` → `OUTPUT_STATE_PASSWORD` (-2) and fires
**once**. It's a terminal report for that op (the app then re-issues
`device_authorize`, a fresh op with a fresh id). No double-count.

### 4e. Teardown/stop — `airplay_device_stop` → SEQ_STOP
Re-arms `callback_id` on the existing session, runs the STOP sequence; on
completion `session_success` (1330) → `session_status` (STOPPED) **once** →
`session_cleanup`. **Exactly 1.**

### 4f. `device_cb_set` (stop-delayed) — airplay.c:4200
Sets `callback_id` on the live session but starts no sequence and returns void.
The callback fires only when the *deferred stop timer* (owned by the layer above)
later drives a stop. This is not an independent op that promises its own callback;
it re-targets an in-flight one. In our engine the "delayed stop" path is app-side
(seam-map §3.6 / §8) — `device_cb_set` just repoints the pending id.

### 4g. `device_flush` returns 0 — airplay.c:4189
If the session isn't STREAMING, flush is a no-op and returns **0** → **0**
callbacks promised. The caller (OwnTone `outputs_device_flush`, and our engine)
must treat a 0/negative return as "nothing to wait for" and **not** block on a
callback. This is the one op where "N callbacks" is legitimately zero on the happy
path, and getting it wrong (waiting for a callback that never comes) is a classic
hang — our engine's wait logic keys on the **return value**, so a 0 return simply
doesn't register a waiter.

**Summary of the trace:** across normal, failure, deferred-failure, auth-retry,
password, teardown and no-op-flush paths, the count is invariantly **N = return
value, and N ∈ {0, 1}**, delivered exactly once, deferred onto the loop, keyed by
`callback_id`, resolved by `device_id`. No path fires twice; no successful path
fires zero (only the explicit 0/negative *returns* promise zero).

---

## 5. What our shim `shims/outputs.c` must implement (the port)

Reproduce OwnTone's `outputs.c` callback machinery, narrowed to the single-backend
AirPlay engine and re-pointed at the engine's own libevent base + a Swift-visible
completion hook:

1. **A callback-id registry** (`OUTPUTS_MAX_CALLBACKS` slots) with
   `callback_add(device, cb)` / `callback_remove(device)` / `callback_get(device)`
   — *the same replace-on-add-per-device semantics.* `callback_add` returns the
   `callback_id` passed into `device_*`.
2. **`outputs_cb(callback_id, device_id, state)`** — validate the id (negative /
   out-of-range / empty-slot → defensive no-op, never hang), mark the slot ready,
   store `device_id`+`state`, and schedule the deferred delivery on
   `evbase_player`.
3. **A deferred delivery** (`deferred_cb`, driven by an `event_active`d libevent
   event on `evbase_player`) that, on the engine thread: copies the slot, clears
   it, resolves the device by id, updates `device->state`, invokes the registered
   `output_status_cb`, and — the engine-specific part — emits the Swift-visible
   completion event so T-API-1's `async` waiter unblocks.
4. **Never release a waiter except through `outputs_cb`** — session teardown
   (`session_cleanup`) must not clear a pending slot, so the `start_retry`
   id-hand-off (4c) still delivers exactly one completion.

For the **engine wait model** (feeds T-API-1): a request that issues a `device_*`
op reads its **return value**; if `> 0` it registers a waiter under the
`callback_id` and blocks (async) until the dispatcher delivers; if `<= 0` it
completes immediately with no wait. This is the exact `pending += ret` /
`(pending > 0) ? pending : ret` logic OwnTone uses in `outputs_start/stop/flush`
(outputs.c:1122–1234), reduced to the one-device case the engine drives per op.

---

## 6. Ports/state cheat-sheet (states `outputs_cb` can carry)

`enum output_device_state` values airplay.c reports (via `session_status` map):

| airplay state | reported `output_device_state` | when |
|---|---|---|
| INFO…RECORD | `OUTPUT_STATE_STARTUP` (1) | mid-setup progress (not a completion) |
| CONNECTED | `OUTPUT_STATE_CONNECTED` (2) | probe success / connected |
| STREAMING | `OUTPUT_STATE_STREAMING` (3) | start success, now streaming |
| STOPPED | `OUTPUT_STATE_STOPPED` (0) | stop success |
| AUTH | `OUTPUT_STATE_PASSWORD` (-2) | needs PIN/password |
| FAILED | `OUTPUT_STATE_FAILED` (-1) | any hard failure |

Note STARTUP is an *intermediate* state that `session_connected`/progress reports
can emit; the terminal completion for a `device_start` is STREAMING (or FAILED /
PASSWORD). The engine's waiter should treat STREAMING/CONNECTED/STOPPED/FAILED/
PASSWORD as terminal for the op that armed the id (which is exactly what the
`callback_id = -1` reset makes true — once a terminal report fires, the id is
spent).
