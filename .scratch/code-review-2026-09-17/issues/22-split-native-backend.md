# 22 — Split NativeBackend.swift along its named seams

Status: ready-for-agent
Wave: 5
Pipeline model: fable (normal mode)
Source: [REVIEW.md](../REVIEW.md), findings capture #6, capture #15, capture #21, capture #13, capture #17

13,222 lines, 234 stored properties, eight conformances on one type. The Bluetooth and Cast surfaces are already `extension NativeBackend`.

## Done when

`NativeBackend+Bluetooth.swift`, `NativeBackend+Cast.swift`, `NativeBackend+PerAppRouting.swift`, `NativeBackend+TestSupport.swift` exist and the main file is under 6,000 lines; no behaviour change (pure moves plus the duplicate-enumerator and clock-trio dedupes); the three `test_`-named production knobs are renamed; full suite green with no test edits beyond renames.

## Test seam

full suite, unchanged

## Verification

```bash
AUDIOUT_FULL_SUITE=1 bash scripts/run-tests.sh
```

## Findings (verbatim from the area reports)

### 6. [SUBSTANCE] `NativeBackend.swift` is 13,222 lines and one 234-property type — unreviewable cold
- Where: `NativeBackend.swift:64`, whole file. One class conforming to OutputBackend, LatencyConfigurable, MeteringControlling, AppRouteConfiguring, BTOutputControlling, LocalSyncOffsetControlling, CastSyncOffsetControlling, @unchecked Sendable. Correctness rules are per-property queue confinements across four locks and three queues.
- Fix: extract the Bluetooth surface (~2,500 lines) and Cast (~400) into `NativeBackend+Bluetooth.swift` / `NativeBackend+Cast.swift` (already `extension NativeBackend`); per-app routing (`updateAppRoutes` → `performBindOp` → `enqueueRebindRecovery`, ~1,800) next.
- Confidence: high

### 15. [SUBSTANCE] 22 test-only members on the shipping backend type, three of them load-bearing
- Where: `NativeBackend.swift:540-542`, `:1517-1582`, `:7740-7786` — `var test_companionAuditionPreparationSeconds: TimeInterval = 4`, `test_companionAuditionLeaseSeconds = 600` consumed at `:12072-12073` for the real deadline and lease.
- Fix: rename the three timing knobs; move read-only accessors to `NativeBackend+TestSupport.swift`.
- Confidence: high

### 21. [SUBSTANCE] `NativeBackend.stop()` is a 350-line teardown with no structure
- Where: `NativeBackend.swift:2463-2812`; teardown order is load-bearing (`captureControlQueue` FIFO relied on at `:2665-2684`).
- Fix: `stopCallbacksAndSources()`, `stopAudioPaths()`, and the `stateQueue.async` reset block.
- Confidence: medium

### 13. [SUBSTANCE] Two identical no-op `AudioProcessEnumerating` types
- Where: `NativeBackend.swift:58-62` (`NoAudioProcesses`), `NativeCaptureCoordinator.swift:2776-2780` (`EmptyAudioProcessEnumerator`).
- Fix: keep `EmptyAudioProcessEnumerator`, delete `NoAudioProcesses`, update three NativeBackend defaults plus `OwnToneBackend.swift:852`.
- Confidence: high

### 17. [SUBSTANCE] The `mHostTime → CLOCK_MONOTONIC` trio is copied between the two taps
- Where: `NativeCaptureCoordinator.swift:4190-4224`, `PerAppCaptureCoordinator.swift:1419-1446` — `machNanoseconds(fromHostTime:)`, `cachedTimebase`, `currentMonotonicNanos()`, `sampleMachToMonotonicOffsetNanos()` byte-identical; comment says duplicated because originals are `private`.
- Fix: make the four `internal` on `CoreAudioSystemTap`, delete the copies.
- Confidence: high
