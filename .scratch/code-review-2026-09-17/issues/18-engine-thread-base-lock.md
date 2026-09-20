# 18 — EngineThread: put `base` behind the lock so a late write cannot hit a freed event_base

Status: ready-for-agent
Wave: 4
Pipeline model: fable (normal mode)
Source: [REVIEW.md](../REVIEW.md), findings engine #2

`EngineThread.base` is read from any thread in `enqueue` and freed on the engine thread in `stop()` with no synchronization.

## Done when

`base` reads and the free happen under `pendingLock` (or a dedicated lock), and `enqueue` after `stop()` returns false without touching the base. A test proves `enqueue` racing `stop()` never calls into libevent after the free (seam: an injected `event_base_once` hook or the existing test support).

## Test seam

AirPlayEngine `EngineThreadTests`

## Verification

```bash
bash scripts/run-tests.sh --package AirPlayEngine 2>/dev/null || echo 'use the AirPlayEngine runner named in AirPlayEngine/AGENTS.md'
```

## Findings (verbatim from the area reports)

### 2. [BUG] `EngineThread.base` is read from any thread and freed on the engine thread with no synchronization — the write path can call `event_base_once` on a freed base
- Where: `AirPlayEngine/Sources/AirPlayEngine/EngineThread.swift:23`, `:221`, `:244-245`, `:264-306`; caller `AirPlayEngine/Sources/AirPlayEngine/AirPlayEngine.swift:1348`
- Evidence:
  ```swift
  private(set) var base: OpaquePointer?           // :23, no lock
  ...
  event_base_dispatch(b)                          // :238 returns on loopbreak
  if let ka = keepAlive { event_free(ka); keepAlive = nil }
  event_base_free(b)                              // :244  engine thread
  base = nil                                      // :245
  ```
  against, on any producer thread:
  ```swift
  func enqueue(_ work: @escaping () -> Void, tracked: Bool = true) -> Bool {
      guard let base else { return false }        // :265
      ...
      event_base_once(base, -1, EngineThread.evTimeout, { ... }, box, nil)   // :294
  ```
- Why it matters: `write(streams:pts:)` is `nonisolated` and calls `enqueue` with no actor hop
  (`AirPlayEngine.swift:1348`). A frame that reads a non-nil `base` just before line 244 hands that pointer to
  `event_base_once` after `event_base_free` — a use-after-free on the audio path during every stop, plus an
  unsynchronized read/write of the pointer itself. `startedFlag` does not close this: it is stored at
  `AirPlayEngine.swift:558`, long before the thread frees the base at `:591`.
- Fix: guard `base` with one `NSLock` — take it in `enqueue` across the nil-check and the `event_base_once`
  call, and in `threadMain` across the free plus the `base = nil`. `EngineThreadHolder` right below already
  uses exactly this shape.
- Confidence: high
