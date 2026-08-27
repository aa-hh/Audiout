# Sources/AirPlayEngine

## Purpose

The Swift host layer of the `AirPlayEngine` package: the neutral async API
(`AirPlayEngine.swift`), the engine-thread/libevent wrapper
(`EngineThread.swift`), the C-completion-to-`async`/`await` bridge
(`CompletionRegistry.swift`), and the public value types
(`AirPlayTypes.swift`). Everything the package-root `../../AGENTS.md`
describes as "the neutral Swift API" lives in this one target.

Boundary: this target calls into `Sources/CAirPlayEngine` (vendored C) but
never the reverse — no vendored C file imports Swift. It is a peer of
`Sources/engine-probe` (a CLI consumer, gated live-session tool) and
`Sources/ptp-helper` (a separate privileged daemon target); neither is built
from code in this folder, and this target never binds PTP sockets itself
(see the package-root Rules for the PTP client/binder split). See
`../../docs/seam-map.md` for how the app (outside this package) is expected
to consume this API. Update this file in the same change when a new
file/type/hub lands here or a concurrency contract changes.

## Notable Patterns

- **Two nonisolated mirrors shadow actor state for the hot write path.**
  `AirPlayEngine.write(streams:pts:)` is `nonisolated` (must not hop the actor
  executor per audio frame), so it cannot read `started`/`headlessMode`
  directly. `startedFlag`/`headlessFlag` (`AtomicBool`, lock-guarded) are kept
  in lock-step with those actor-isolated properties by every writer. Same
  pattern for `engineThreadHolder` (`EngineThreadHolder`, `EngineThread.swift`)
  which the write path reads to get the *current* `EngineThread` without an
  actor hop — necessary because `start()` builds a **fresh** `EngineThread` per
  call (`Thread.start()` on an already-started thread aborts).
- **Install hooks before `airplay_init`.** `completions.install()` /
  `stateHub.install()` / `remoteHub.install()` must run before `airplay_init`
  — it spawns the events thread that fires `remoteHub`, so installing after
  init misses early callbacks.
- **Per-`OutputID` op serialization.** `opsInFlight`/`opWaiters` in
  `AirPlayEngine` ensure a second `addOutput`/`removeOutput`/`setVolume` on the
  same id awaits the first rather than racing. `acquireOp` is NOT re-entrant, so
  a composite op that must be atomic across several backend calls
  (`rebindOutput` = stop + re-add) acquires the slot ITSELF and passes
  `serialize: false` down to `startOp` — there is exactly one serialization
  mechanism here, never a second one — belt-and-suspenders with
  `CompletionRegistry.arm`'s own refusal to overwrite an already-armed
  `callbackId` (`arm` returns `false` rather than clobber).
- **Exactly one of {deliver, cancel, timeout} ever resolves a waiter.**
  `CompletionRegistry.Waiter` is removed from the `waiters` table under `lock`
  before any of its three closures runs, so a continuation is resumed exactly
  once — a leaked continuation both trips "CONTINUATION MISUSE" and hangs
  `stop()`/app-quit (cited inline in `CompletionRegistry.swift`).
- **`knownOutputs` is reconciled asynchronously, never trusted as ground
  truth by the idempotency guards.** `AirPlayEngine.addOutput`/`removeOutput`
  read `liveDeviceState(_:)` (the live C `device->state`, on the engine thread)
  before deciding to no-op, because `knownOutputs` is folded from
  `stateHub`'s own stream (`startStateReconcile`) and can momentarily lag an
  out-of-band transition (e.g. a receiver dropping RTSP).
- **`EngineThread.enqueue`'s tracked/untracked split.** Ops that carry a
  continuation register in `pending` (swept and force-run in `stop()` so no
  continuation is stranded if the loop breaks first); the hot write path opts
  out (`tracked: false`) since dropping a late frame on teardown is correct
  and a per-write dict op would be wasted cost.
- **`EngineThread.stop()` is deadlined, not spin-forever.** A wedged vendored
  callback in a blocking syscall never returns; past `stopJoinDeadline` (3s)
  the thread/base is deliberately leaked (logged fault) rather than hanging
  the actor that owns `stop()`.

## Folder Map

No subfolders — all five files sit directly here. `PTPClockProbe.swift` is a
thin wrapper over the shim's connect-time `ptpd_daemon_probe()`.

## Key Types

| Type | File | Role |
|---|---|---|
| `AirPlayEngine` (actor) | AirPlayEngine.swift | Public session API: lifecycle, discovery feed, add/remove/volume, PCM write, state/remote streams. |
| `EngineConfig` | AirPlayEngine.swift | Config applied to `conffile` at `start()`; owns `startBufferMs`/`presentationDelayMs` derivation. |
| `OutputBindResult` | AirPlayEngine.swift | `addOutput(_:streamId:)`'s outcome: `.bound` vs `.alreadyBound(streamId:)` — makes the already-live idempotent no-op visible to the caller instead of silent. |
| `EngineThread` | EngineThread.swift | Owns the one `event_base` + OS thread; sole path (`run`/`enqueue`) onto the vendored cluster. |
| `EngineThreadHolder` | EngineThread.swift | Nonisolated, lock-guarded slot holding the *current* `EngineThread` (swapped per `start()`). |
| `CompletionRegistry` | CompletionRegistry.swift | Bridges the C `outputs_engine_completion` callback to `async`/`await`, one-shot per `callbackId`, with a 12s timeout backstop. |
| `StateStreamHub` | AirPlayEngine.swift | Multicasts `(OutputID, OutputState)` transitions; feeds both `knownOutputs` reconcile and external subscribers. |
| `RemoteEventHub` | AirPlayEngine.swift | Multicasts `RemoteEvent` (speaker-originated transport/volume) from the vendored reverse-event thread. |
| `WriteCadenceTracker` / `WriteLatencyProbe` | AirPlayEngine.swift | Diagnostic-only hot-path instrumentation; never gate a write. |
| `OutputID`, `DeviceDescriptor`, `OutputState`, `RemoteEvent`, `AirPlayEngineError`, `PCMFormat` | AirPlayTypes.swift | Public, OwnTone-free value types at the FFI boundary. |
| `PTPClockProbe` | PTPClockProbe.swift | One-function connect-time readiness check (`ptpd_daemon_probe()`) for `AudioutCore`'s PTP-helper activation to poll. |

## External Dependencies

| Dependency | Used for |
|---|---|
| `CAirPlayEngine` (sibling C target) | All vendored AirPlay 2/RAOP sender + PTP-client calls; imported by all five files here. |
| `os` (Logger) | Structured logging (`ptp-clock`, `completion`, `engine-thread` subsystems/categories). |
| Foundation (`Thread`, `DispatchSource`, `NSLock`) | `EngineThread`'s OS thread + timers; `CompletionRegistry`'s lock and timeout timers. |

## Tests

No test files live under this directory; per the package layout, tests for
this target are under `AirPlayEngine/Tests/` (see package-root AGENTS.md /
README for the suite). `AirPlayEngine.issueOverride` and
`CompletionRegistry.deliverForTest`/`hasWaiter` are headless test seams
defined in this target specifically so those tests can exercise the real
completion path without a live receiver.
