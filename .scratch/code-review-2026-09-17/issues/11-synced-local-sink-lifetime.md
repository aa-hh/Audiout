# 11 — SyncedLocalSink: deinit again, report a failed restart, fix the pre-roll comment

Status: ready-for-agent
Wave: 2
Pipeline model: fable (normal mode)
Source: [REVIEW.md](../REVIEW.md), findings sync #2, sync #3, sync #7

The render-block box is a strong `boxed = self` under a comment that says unowned, so the sink never deinits; the lifecycle `restartEngine` hook swallows a throw with `try?`; the clock-rebase comment at :643 claims pre-roll-only for code that runs every cycle.

## Done when

The box is `weak` (or the block captures `[weak self]`) and a test proves the sink deinits after `stop()`. A failed restart reports through `Telemetry.fail` (category and event named in the work order). The stale comment states what the code does. `stopObservingLifecycleEvents` from `deinit` is checked for the deadlock the review noted and either proven unreachable or fixed.

## Test seam

`SyncedLocalSinkTests`

## Verification

```bash
bash scripts/run-tests.sh --filter SyncedLocalSink
```

## Findings (verbatim from the area reports)

### 2. [BUG] `SyncedLocalSink`'s render-block box is a strong reference, so the sink never deinits
- Where: `AudioutCore/Sources/AudioutCore/SyncedLocalSink.swift:190`
- Evidence:
  ```swift
  // Render block built with an unowned box so `self` can wire it in the same
  // init; it is only ever invoked between `start()` and `stop()`.
  var boxed: SyncedLocalSink?
  self.sourceNode = AVAudioSourceNode(format: format) { isSilence, timestamp, frameCount, audioBufferList in
      boxed?.render(...) ?? noErr
  }
  boxed = self
  ```
- Why it matters: the comment says "unowned box" but `boxed` is a strong optional captured by the
  escaping render closure, so `self -> sourceNode -> closure -> box -> self` is a cycle. `deinit`
  (line 199) — which removes the process-wide `kAudioHardwarePropertyDefaultOutputDevice` listener
  and frees the deinterleave scratch — can never run. The sibling `BTDeviceSink.makeSourceNode`
  (`BTSyncedSink.swift:1102`) does this correctly with `[weak self]`.
- Fix: capture `[weak self]` in the source-node block exactly as `BTDeviceSink` does, and drop the
  box.
- Confidence: high

### 3. [BUG] A failed engine restart after a device change or wake is swallowed and never logged
- Where: `AudioutCore/Sources/AudioutCore/SyncedLocalSink.swift:372`
- Evidence:
  ```swift
  restartEngine: { [weak self] in try? self?.start() })
  ```
- Why it matters: `performLifecycleRebuild()` runs on every default-output change, sleep and wake.
  If `start()` throws (the new device rejects the format, a config change is mid-flight), the Mac's
  own speakers stay silent until the next lifecycle event and nothing anywhere records why. The
  Bluetooth twin logs it — `BTSyncedSink.startSink` emits `bt_sink_start_failed`
  (`BTSyncedSink.swift:1751`).
- Fix: `do/catch` around `start()` and emit `Telemetry.fail(.localPlayback, "sync:restart_failed",
  local: ["error": ...])`, matching `startSink`'s posture.
- Confidence: high

### 7. [SUBSTANCE] Stale comment: the clock rebase is claimed to be pre-roll only, but runs every cycle
- Where: `AudioutCore/Sources/AudioutCore/SyncedLocalSink.swift:643`
- Evidence:
  ```swift
  // Called only while still gated: once `released`, `renderInterleaved`
  // short-circuits before this timeline read, so the two `clock_gettime`
  // calls the helper resamples are paid during pre-roll only, not steady state.
  ```
  The rebase at line 650 runs before `renderInterleaved` is called at all, and the T-CORRECTION
  phase loop inside it needs `cycleStartMonotonicNanos` on every cycle (line 750).
- Why it matters: the comment is the reason a reader would believe finding 1 is not a problem.
- Fix: delete the claim; if finding 1 is fixed the cost question goes away with it.
- Confidence: high
