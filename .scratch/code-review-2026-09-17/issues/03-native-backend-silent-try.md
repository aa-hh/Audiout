# 03 — NativeBackend: report the failures it currently swallows with `try?` and `_ =`

Status: ready-for-agent
Wave: 1
Pipeline model: opus mode
Source: [REVIEW.md](../REVIEW.md), findings capture #1, capture #5, capture #8

Three clusters in `NativeBackend.swift` discard failures the user feels: the five persisted-store loads in `init`, the four local-playback `sink.start()` calls, and the quit-time default-output restore write.

## Done when

Each site uses `do/catch` (or captures the Bool) and reports through the path its siblings already use: `StoreRecovery.noteWriteFailure` for store loads, `Telemetry.fail(.localPlayback, "local_playback:start_failed", …)` for the sink starts, the existing `aggregate_default_restore` telemetry line for the restore. Defaults-on-failure behaviour is unchanged. One test per cluster names the defect (a throwing store / sink double proves the report fires).

## Test seam

`NativeBackendTests` (extend the existing store and local-playback suites; do not add a new suite)

## Verification

```bash
bash scripts/run-tests.sh --filter NativeBackendTests
```

## Findings (verbatim from the area reports)

### 1. [BUG] Every persisted user setting is loaded with `try?` and silently reset to defaults on read failure
- Where: `NativeBackend.swift:1785`, `:1788`, `:1791`, `:1798`, `:1804`
- Evidence: `if let loaded = (try? btTrimStore?.load()) ?? nil { … }` / `if let latencies = (try? btTrimStore?.loadLatencies()) ?? nil { … }`
- Why: a truncated store silently drops measured BT latencies, sync trims, Cast offsets and per-device EQ to zero. Every WRITE on the same stores is handled (`StoreRecovery.noteWriteFailure`, `eq_save_failed`).
- Fix: `do/catch` each through `StoreRecovery.noteWriteFailure`; keep defaults-on-failure.
- Confidence: high

### 5. [BUG] "Play everywhere" and per-app local playback fail silently — `try?` on every engine start
- Where: `NativeBackend.swift:4474`, `:5243-5244`, `:5348-5349`, `:10217-10218`
- Evidence: `try? sink.start()`; `SyncedLocalSink.start()` / `LocalPlaybackEngine.start()/addApp` throw via `catchingObjCException`.
- Why: Mac stays silent in a play-everywhere selection, or a "This Mac"-routed app stops playing, no telemetry, no retry.
- Fix: `do/catch` with `Telemetry.fail(.localPlayback, "local_playback:start_failed", …)`.
- Confidence: high

### 8. [BUG] The quit-time restore of the user's prior default output is unchecked and unlogged
- Where: `NativeBackend.swift:2799` — `_ = self.aggregateControl.setDefaultOutputDevice(priorID)` then `sweepOrphans()` destroys the aggregate one line later. Sibling path `restoreWriteReturned` → `verifyRestoreLanded` (`:8452-8494`) exists because "the documented failure mode in this area is acceptance without effect".
- Fix: capture the Bool, emit the existing `aggregate_default_restore` line with outcome.
- Confidence: high
