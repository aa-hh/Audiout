# Click-to-sound latency: budget, knobs, and the gated re-verify checklist

**Context (2026-07-17).** Gated-session measurement by Alec against the real
Sonos fleet: steady-state click-to-sound on `AIRPLAY_BACKEND=native` was
**~3.5 s** (same for sound starting and stopping), measured after the session
was established. Phase 0 measured OwnTone at ~2 s on the same fleet, so
~1.5 s of the delay lives in our hosting path. This doc is the trace of where
every millisecond goes, what was changed, and the user-gated checklist to
re-verify by ear.

## The budget: where a captured sample's 3.5 s went

A sample captured at time `T` (on `CLOCK_MONOTONIC`) plays out of the Sonos at
`T + (1) + (2) + (3)`:

| # | Contribution | Size | Where |
|---|--------------|------|-------|
| 1 | Capture → `write(pcm:pts:)` (“pts age”) | **~10–30 ms** | tap IOProc buffer (~10 ms) + AVAudioConverter + one queue hop. There is NO aggregation: `NativeCaptureCoordinator.handleBuffer` converts and forwards each IOProc buffer immediately, pts straight off the buffer's `mHostTime` (rebased to `CLOCK_MONOTONIC`). |
| 2 | Sender scheduling lead | **2000 ms with the old hardcoded 2250** | `airplay.c master_session_make`: `output_buffer_samples = (start_buffer_ms − 250) × rate/1000`; `timestamp_set` then tells receivers (via every sync packet) “the sample playing at `pts` is the one from `output_buffer_samples` ago”. `start_buffer_ms` comes from OUR shim: `shims/outputs.c outputs_buffer_duration_ms_get()`, previously hardcoded 2250 (OwnTone's default). |
| 3 | Receiver-applied latency | **≥ 250 ms advertised; Sonos apparently applies ~1.2–1.5 s** | `latencyMin = 11025` samples (250 ms, = `AIRPLAY_AUDIO_LATENCY_MS`) in the SETUP stream plist (`airplay.c payload_make_setup_stream`). The receiver's actual choice is invisible from the sender; it is the residual after (1) and (2) are subtracted from a stopwatch measurement. Byte-identical vendored code — OwnTone advertises the same values, so this term is not ours to change. |

Ruled out while tracing:

- **Clock domains are consistent** — pts (mach→`CLOCK_MONOTONIC` rebase in
  `CoreAudioSystemTap`), the vendored sync path (`clock_gettime(CLOCK_MONOTONIC)`),
  and libairptp's served PTP time (`ptp_msg_handle.c current_time_get()`) are all
  `CLOCK_MONOTONIC`. No fixed offset hides here.
- **`session->offset_samples` is 0** — `device->offset_ms` is zero-initialized and
  nothing in the shims sets it.
- **No engine-side queuing** — `AirPlayEngine.write` enqueues to the engine thread
  per call; `airplay_write` drains `input_buffer` down to < 352 samples (~8 ms)
  on every write.

So: (2) was the dominant, deterministic, safely-reducible term, and it is ours
(a shim value, not vendored code). (3) is the suspected remainder — the gated
run below measures it precisely for the first time.

## What changed

- `shims/outputs.c/h`: `outputs_set_buffer_duration_ms()` — the start buffer is
  now settable (clamped LOUDLY to 300…5000 ms; ≤ 250 would make `airplay.c`
  reject every session). Default unchanged at 2250 (OwnTone parity).
- `EngineConfig.startBufferMs` (default 2250) — applied before `airplay_init`.
- `makeBackend(.native)` passes a **product default of 1000 ms**, overridable
  per run via **`AIRPLAY_START_BUFFER_MS`** (300…5000; garbage/out-of-range →
  1000 with a stderr warning).
- **`AIRPLAY_DEBUG_LATENCY=1`** enables a pts-freshness probe in the engine's
  write path (`WriteLatencyProbe`): one line per ~5 s to os_log + stderr with
  the measured pts age, write rate, configured sender lead, and the predicted
  sender-side click-to-sound.
- **No vendored C was touched** (VENDORED-DIFFS.md unchanged). Volume mapping
  untouched.

Expected effect of the 1000 ms default: click-to-sound drops by ~1.25 s
(3.5 s → ~2.2 s) with receivers still holding a 750 ms jitter/multi-room buffer.

## Decomposing a stopwatch measurement

With `AIRPLAY_DEBUG_LATENCY=1`, the probe prints e.g.

```
latency probe: pts age avg 14.2ms (…) | 94 writes/s | sender lead 750ms (start_buffer 1000ms − 250) | click-to-sound ≈ 0.76s + receiver-applied (≥0.25s)
```

Then for any stopwatch measurement:

```
receiver-applied latency = measured click-to-sound − pts age − sender lead
```

If the old 3.5 s decomposes as `3.5 = 0.02 + 2.00 + receiver-applied`, Sonos is
applying ~1.5 s of its own — knowing that number tells us how low
`AIRPLAY_START_BUFFER_MS` is worth pushing (total can never go below
pts-age + receiver-applied).

## GATED: by-ear re-verify checklist (real Sonos fleet, user present)

Run the app per `dev/notes/p2b-nativebackend-runbook.md` §3, with
`AIRPLAY_DEBUG_LATENCY=1` in the environment and a terminal visible for the
probe lines. For each step, note the probe's `sender lead` line and a
phone-stopwatch click-to-sound estimate (start/stop a song; both directions
should match).

1. **Baseline (confirms the harness):** `AIRPLAY_START_BUFFER_MS=2250`.
   Expect ~3.5 s click-to-sound, probe showing `sender lead 2000ms`,
   pts age ~10–30 ms. → Record receiver-applied = measured − 2.0 s − pts age.
2. **New default:** unset `AIRPLAY_START_BUFFER_MS` (product default 1000).
   Expect ~1.25 s faster than baseline. Listen for dropouts/underruns over
   ≥ 10 min of continuous music on ONE device.
3. **Multi-room sync (the invariant that must not regress):** stream to ≥ 2
   Sonos rooms, stand between them — no echo/flanging; walk test. Then have a
   device JOIN mid-stream (enable a second speaker while playing): it must come
   in synced (the join path uses the same lead via the init sync packet).
4. **Stress the floor (optional, finds the safe minimum):**
   `AIRPLAY_START_BUFFER_MS=750`, then `500`, then `300`. At each: 10 min music,
   multi-room walk test, note first sign of dropouts. One step back from the
   first failure = the fleet's floor; consider it for the product default if
   comfortably below 1000.
5. **Volume smoke (do-not-touch confirmation):** volume slider still smooth
   0→100 on one device; mute/unmute restores level. (Mapping was not modified —
   this is a regression tripwire only.)
6. **Stop/teardown:** disable all speakers → app returns to idle without
   SIGPIPE/zombie sessions (same as first-light close-out behavior).

Pass = steps 2, 3, 5, 6 clean at the chosen default. Record the numbers from
steps 1–2 back into this doc (receiver-applied latency is fleet-specific data
we don't have yet).

## File map (for the next reader)

- `shims/outputs.c` `outputs_buffer_duration_ms_get/…_set` — the knob.
- `sender/airplay.c:1196-1207` — start buffer → `output_buffer_samples`.
- `sender/airplay.c:2128-2155` (`timestamp_set`) — pts → “what should be playing now”.
- `sender/rtp_common.c sync_packet_ptp_make` — (pos, pts-ns) → receiver playout anchor.
- `sender/airplay.c:2628-2629` — advertised `latencyMax`/`latencyMin`.
- `AirPlayEngine.swift` `EngineConfig.startBufferMs`, `WriteLatencyProbe`.
- `OwnToneBackend.swift` `nativeStartBufferMs()` — env parsing (native path).
- `NativeCaptureCoordinator.swift` — capture→write path (no aggregation; pts source).
