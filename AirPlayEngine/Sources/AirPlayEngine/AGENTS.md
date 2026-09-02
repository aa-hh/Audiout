# Sources/AirPlayEngine

## Purpose

The Swift host layer of the `AirPlayEngine` package: the neutral async API, the
engine-thread wrapper, the completion bridge, and the public value types. It
calls into `CAirPlayEngine`, never the reverse, and binds no PTP sockets.

## Rules

- Two nonisolated mirrors shadow actor state for the hot write path; every writer keeps them in lock-step.
- `start()` builds a fresh `EngineThread` each call, because starting an already-started thread aborts.
- Ops on one `OutputID` serialize through one mechanism; `acquireOp` is not re-entrant, so composite ops take the slot themselves.
- Exactly one of deliver, cancel or timeout resolves a waiter; a leaked continuation hangs quit.
- `knownOutputs` can lag reality, so the idempotency guards read the live device state instead.
- Ops carrying a continuation are tracked and force-run on teardown; the write path opts out deliberately.
- `EngineThread` teardown is deadlined: a wedged thread is leaked and logged, never waited on forever.
- Long-form traps, dated decisions and the changelog: [AGENTS-HISTORY.md](AGENTS-HISTORY.md). Grep it before debugging anything here.

## Map

- `AirPlayEngine` → the actor: lifecycle, discovery feed, outputs, PCM write.
- `EngineConfig` → configuration applied to the vendored C settings at start.
- `OutputBindResult` → makes an already-bound idempotent no-op visible to callers.
- `EngineThread` → owns the one event base and OS thread onto the C cluster.
- `EngineThreadHolder` → nonisolated, lock-guarded slot holding the current thread.
- `CompletionRegistry` → bridges C completions to async, one shot per callback id.
- `StateStreamHub` → multicasts output-state transitions to reconcile and to subscribers.
- `RemoteEventHub` → multicasts speaker-originated transport and volume events.
