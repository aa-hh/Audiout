# 19 — AirPlayEngine.bind: take the per-output gate before touching C state; fix the arm-collision recovery

Status: ready-for-agent
Wave: 4
Pipeline model: fable (normal mode)
Source: [REVIEW.md](../REVIEW.md), findings engine #3, engine #9, engine #8

`bind()` writes `stream_id` and reads live state before the per-`OutputID` gate at :1504; the arm-collision recovery in `startOp` clears the other op's callback slot; a second `AirPlayEngine` silently steals the C hooks.

## Done when

The gate is taken first in `bind()`; the collision recovery only clears its own slot; a second engine instance either refuses or is documented as unsupported with a precondition. Tests name each defect.

## Test seam

AirPlayEngine `AirPlayEngineTests` / `CompletionRegistryTests`

## Verification

```bash
bash scripts/run-tests.sh --package AirPlayEngine 2>/dev/null || echo 'use the AirPlayEngine runner named in AirPlayEngine/AGENTS.md'
```

## Findings (verbatim from the area reports)

### 3. [BUG] `bind()` writes the C `stream_id` and reads the live state before taking the per-`OutputID` op gate
- Where: `AirPlayEngine/Sources/AirPlayEngine/AirPlayEngine.swift:853-895` (gate is taken later, at `:1504`)
- Evidence:
  ```swift
  private func bind(_ id: OutputID, streamId: UInt32, serialize: Bool) async throws -> OutputBindResult {
      ...
      let live = await liveBinding(id)                       // :873  suspension, no slot held
      ...
      await applyStreamIdOnDevice(id: id, streamId: streamId) // :889  suspension, no slot held
      let terminal = try await startOp(id: id, serialize: serialize) { ... }   // acquireOp happens in here
  ```
- Why it matters: the doc above this method says the `stream_id` write "MUST land before `device_start`" and
  that `rebindOutput` holds the slot "across BOTH halves … so no concurrent `addOutput`/`removeOutput` can
  slip between". It can: a concurrent `addOutput(id, streamId:)` writes `device->stream_id` while a
  `rebindOutput` holds the slot, and two concurrent binds on one id both pass the `liveBinding` idempotency
  check and can interleave so the session is created on the other caller's stream. Audio written to the
  requested stream then never reaches the device, which is the exact symptom `OutputBindResult` was added to
  make visible.
- Fix: take the gate at the top of `bind`/`unbind` (`await acquireOp(id)` + `defer releaseOp(id)` when
  `serialize`), and pass `serialize: false` down to `startOp`, the way `rebindOutput` already does.
- Confidence: high on the ordering; medium on live reachability (the app layer may serialize today)

### 9. [BUG] The arm-collision recovery in `startOp` clears the *other* op's C callback slot
- Where: `AirPlayEngine/Sources/AirPlayEngine/AirPlayEngine.swift:1554-1560`
- Evidence:
  ```swift
  guard armed else {
      // B5.3: a waiter was already armed for this id ...
      outputs_callback_remove(device)
      cont.resume(throwing: AirPlayEngineError.operationRejected)
      return
  }
  ```
  and the C side (`shims/outputs.c:748-762`): "Match OwnTone: clear EVERY slot for this device."
- Why it matters: this branch runs precisely when a waiter for that id already exists, i.e. when per-id
  serialization was bypassed (finding 3 is one way there). `outputs_callback_remove` then wipes the in-flight
  op's registration too, so its completion arrives at a cleared slot, logs "illegal callback id", and the
  other caller hangs until its 12 s timeout. The recovery path damages the op it was written to protect.
- Fix: clear only the slot this call took — `outputs_callback_clear(cbId)` (already available,
  `outputs.c:764-773`) instead of `outputs_callback_remove(device)`.
- Confidence: high

### 8. [SUBSTANCE] A second `AirPlayEngine` silently steals the C hooks from the first
- Where: `AirPlayEngine/Sources/AirPlayEngine/CompletionRegistry.swift:36`, `:87-92`;
  `AirPlayEngine.swift:1750`, `:1758-1763`; `:1816`, `:1823-1828`
- Evidence:
  ```swift
  static private(set) var shared: CompletionRegistry?
  func install() {
      CompletionRegistry.shared = self
      outputs_engine_completion_set({ callbackId, _, state, _ in
          CompletionRegistry.shared?.deliver(callbackId: callbackId, state: state)
      }, nil)
  ```
- Why it matters: `AirPlayEngine` is a public actor with a public `init`, and nothing prevents a second one.
  The second `start()` (or any `enterHeadlessTestMode()`) overwrites all three `shared` slots, after which the
  first engine's armed ops can only resolve by the 12 s timeout and its state/remote streams go silent, with
  no log line anywhere. The "one engine instance per process in practice" comment is the only guard.
- Fix: make the invariant enforced rather than assumed — in `install()`, log `fault` (or refuse) when
  `shared` is already set to a different instance, so the condition is visible instead of appearing as
  mysterious op timeouts.
- Confidence: high
