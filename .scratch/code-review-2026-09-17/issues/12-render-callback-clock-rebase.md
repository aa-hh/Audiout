# 12 — Synced sinks: stop resampling both clocks inside every render cycle

Status: ready-for-agent
Wave: 2
Pipeline model: fable (normal mode)
Source: [REVIEW.md](../REVIEW.md), findings sync #1

`SyncedLocalSink.render` and `BTDeviceSink`'s render both call the mach-to-monotonic rebase helper per buffer, a helper whose own doc says production must never call it per buffer; the capture path already caches a per-instance offset.

## Done when

Both sinks carry a cached mach-to-monotonic offset sampled at start (and re-sampled on the existing lifecycle events), the per-cycle call is gone, and the helper's doc contract holds. Sync accuracy tests unchanged and green; a test proves the render path no longer calls the helper (call-count seam or equivalent).

## Test seam

`SyncedLocalSinkTests` and `BTSyncedSinkTests`

## Verification

```bash
bash scripts/run-tests.sh --filter 'SyncedLocalSink|BTSyncedSink'
```

## Findings (verbatim from the area reports)

### 1. [BUG] Both synced render callbacks resample two clocks per cycle through a helper marked "test/convenience"
- Where: `AudioutCore/Sources/AudioutCore/SyncedLocalSink.swift:650`,
  `AudioutCore/Sources/AudioutCore/BTSyncedSink.swift:1128`, contract at
  `AudioutCore/Sources/AudioutCore/NativeCaptureCoordinator.swift:4177`
- Evidence:
  ```swift
  // NativeCaptureCoordinator.swift:4177
  /// Test/convenience entry point: derives a fresh offset every call (no
  /// caching) ... Production code must go through the instance path
  /// (seeded in `startIOProc`, healed in the IOProc block) instead, since
  /// resampling both clocks on every single call is not something we want to
  /// pay for on every real captured buffer.
  static func timespec(fromHostTime hostTime: UInt64) -> timespec {
  ```
  ```swift
  // BTSyncedSink.swift:1128 — inside `render`, every cycle
  let cycleStart = SyncTiming.monotonicNanos(
      CoreAudioSystemTap.timespec(fromHostTime: timestamp.pointee.mHostTime))
  ```
- Why it matters: every render cycle on every Bluetooth sink and on the Mac's own sink pays a fresh
  `mach_absolute_time` + `clock_gettime` pair, and the sampling error between those two reads lands
  directly in the value the release gate compares against and that `PhaseController` reads as phase
  error — so the PI loop is fed per-cycle noise it will try to null.
- Fix: seed a per-sink offset at `startLocked()`/`start()` and rebase with the cached
  `CoreAudioSystemTap.timespec(machNanos:offset:)`, re-seeding on the same rebuild edges that
  already void the session anchor.
- Confidence: high (that the per-cycle call happens and contradicts the helper's contract); medium
  on how audible the added jitter is.
