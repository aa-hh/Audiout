# 13 — Capture delivery: one real-time policy, and no blocking queue.sync in the mixers

Status: ready-for-agent
Wave: 2
Pipeline model: fable (normal mode)
Source: [REVIEW.md](../REVIEW.md), findings capture #4, capture #10

`handleBuffer` drops a buffer rather than wait on a two-instruction lock, then blocks on an `NSLock` around an `AVAudioConverter` run; `AppRouteMixer.handleBuffer` and `LeveledAppInjector.handleBuffer` block the delivery thread with `queue.sync` on a default-QoS queue the main thread also takes.

## Done when

One comment at the IOProc registration site states the real-time policy and both sites in `NativeCaptureCoordinator` agree with it. Both mixers publish an immutable snapshot under their queue and read it on the delivery thread with a `try()`-guarded read (the T8 pattern at `NativeCaptureCoordinator.swift:1660-1681`). Existing mixer tests green; a test proves a route edit on main no longer blocks a concurrent `handleBuffer`.

## Test seam

`AppRouteMixerTests`, `LeveledAppInjectorTests`, `NativeCaptureCoordinatorTests`

## Verification

```bash
bash scripts/run-tests.sh --filter 'AppRouteMixer|LeveledAppInjector|NativeCaptureCoordinator'
```

## Findings (verbatim from the area reports)

### 4. [BUG] The real-time contract is asserted, then broken three lines later in the same buffer
- Where: `NativeCaptureCoordinator.swift:1683-1688`, `:1696`, `:4419-4420`, `:3766`; same label at `PerAppCaptureCoordinator.swift:1346`
- Evidence: `if snapshotLock.try() { … } else { return }` (drops the buffer rather than park), then `converter.convertToAirPlayPCM(buffer)` whose body is `lock.lock(); defer { lock.unlock() }` around an AVAudioConverter run and two AVAudioPCMBuffer allocs. Block labelled `// ---- REALTIME THREAD ----` while registered on an explicit `.userInitiated` serial DispatchQueue.
- Fix: settle the question in one comment at the IOProc registration site and make both sites agree.
- Confidence: high (inconsistency); medium (which side is right)

### 10. [BUG] Both mixers block the tap delivery thread on a default-QoS serial queue
- Where: `AppRouteMixer.swift:389-390`, `LeveledAppInjector.swift:264-266` — `handleBuffer` does `queue.sync {` on an unqualified `DispatchQueue(label: "AppRouteMixer.state")` that `updateRoutes`/`removeApp`/`flush`/`destinationSets` take from main. Same priority inversion the T8 refactor (`NativeCaptureCoordinator.swift:1660-1681`) removed from the whole-system path. `LeveledAppInjector.handleBuffer` runs an AVAudioConverter inside the held queue.
- Fix: T8 pattern — immutable snapshot published under the queue, `try()`-guarded read on delivery.
- Confidence: high (blocking); medium (audibility)
