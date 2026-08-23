# dev/audiocap

## Purpose

Standalone SwiftPM CLI that captures system audio via a Core Audio process tap
(macOS 14.4+) and writes raw PCM to a file, stdout, or a named FIFO. It is the
**T-0e-2** spike tool and feeds the **0f capture→OwnTone pipeline**
(`--pipe` mode, T-0f-2); see `../notes/0e-taps-brief.md` and
`../notes/0f-pipe-brief.md` for the design briefs this implements.

**Relationship to production code:** standalone — deliberately separate from
`AudioutCore`, which pins `.macOS(.v13)`; this package targets
`.macOS("14.4")` because process taps need 14.2+/14.4-public. Not linked by
and does not link the main app.

**Status:** functional capture tool with a documented, exercised procedure
(README §"Reproduce a 10-second system-audio capture", §"Per-app & exclude
verification"). Per-app/exclude tap targeting (`--pid`/`--bundle`/`--exclude`)
and the `--pipe` FIFO bridge to OwnTone are both implemented, not just
planned. This is capture tooling, not a shipping feature — treat it as a
utility for exercising and verifying the Core Audio tap API, not dead code.

**Keep this file up to date** when CLI flags, the tap lifecycle order in
`TapEngine.swift`, or the pipe/TCC caveats in README.md change.

## Notable Patterns

- **Realtime-safety discipline**: the IOProc block in `TapEngine.startCapture`
  does no allocation, locking, or logging — only pointer bumps and a
  preallocated scratch buffer for planar→interleaved conversion, then a
  lock-free `RingBuffer.write`. Conversion to S16LE (`PipeWriter.swift`) and
  all I/O happen on separate writer threads.
- **Strict teardown order** (`TapEngine.teardown`): `AudioDeviceStop` →
  `AudioDeviceDestroyIOProcID` → `AudioHardwareDestroyAggregateDevice` →
  `AudioHardwareDestroyProcessTap` (tap dies last), each step guarded so
  teardown always completes even if an earlier step errors.
- **TCC grant resets on rebuild**: ad-hoc/linker-signed binary, so its TCC
  identity is per-binary and can reset after every `swift build`. Silent
  capture (peak 0, but nonzero `inputBytesSeen`) is the signature of a missing
  grant, not a bug — the tool detects and prints this explicitly. Reset via
  `tccutil reset AudioCapture` (unscoped — the bundle-id-scoped form doesn't
  match this binary's TCC identity).
- **Sample-rate config-follows-tap**: the tap rate follows the current default
  *output* device (not necessarily 48 kHz — observed 44100 Hz on the dev
  machine) and is never assumed; `--pipe` mode requires OwnTone's
  `pipe_sample_rate` config to match exactly or playback is silently
  pitch-shifted (no autodetect, no resampler).
- **`NSAudioCaptureUsageDescription` via linker `-sectcreate`**: a bare SwiftPM
  executable has no Info.plist, so `Package.swift` bakes
  `Sources/audiocap/Info.plist` into `__TEXT,__info_plist` at link time so the
  TCC dialog has a rationale string.
- **`dev/audiocap/object`** is an empty stray file at the package root, not a
  source or build artifact of note.

## Key Types

| Type | Role |
|---|---|
| `TapEngine` | Owns the tap lifecycle: create tap → read ASBD → create aggregate device → register IOProc → start; strict-order teardown. |
| `RingBuffer` | Lock-free SPSC byte ring buffer between the realtime IOProc and writer threads; drops-oldest + counts on overflow instead of blocking the audio thread. |
| `WriterThread` (`main.swift`) | Drains the ring to `--out`/`--stdout`, tracks peak amplitude for the built-in silence check. |
| `PipeWriterThread` | Drains the ring, converts Float32→S16LE, and blocking-writes to the OwnTone FIFO; handles FIFO open-blocks-until-reader and clean EOF on stop. |
| `Options` / `parseArgs` (`main.swift`) | Hand-rolled argument parsing for sinks (`--out`/`--stdout`/`--pipe`) and targets (`--pid`/`--bundle`/`--exclude`). |

## External Dependencies

| Dependency | Usage |
|---|---|
| `AudioToolbox` | Core Audio process-tap APIs (`AudioHardwareCreateProcessTap`, aggregate device creation, IOProc). |
| `AVFoundation` | `NSRunningApplication`-adjacent APIs used for `--bundle` pid resolution (imported alongside AudioToolbox in `TapEngine.swift`/`main.swift`). |
| `AppKit` | `NSRunningApplication` in `CAHelpers.swift` (`pidForBundleID`). |

No third-party SPM packages — `Package.swift` has zero package dependencies;
argument parsing and the ring buffer are hand-rolled by design (README notes
the ring buffer intentionally avoids `swift-atomics`, using `OSMemoryBarrier`
instead).

## Tests

No XCTest target. Verification is via `audiocap --selftest`
(`SelfTest.swift`), which checks the Float32→S16LE conversion (rounding,
clamping, byte-order) with no TCC grant and no audio device — runnable from
any shell, agent or human. End-to-end capture correctness (per-app tap,
`--exclude`, non-silence) is verified manually via the tone-injection
procedure in README.md §"Per-app & exclude verification" and
`rms.py --tones`, and the plain-capture procedure in §"Reproduce a 10-second
system-audio capture" — both require a live TCC grant and are not automatable
headlessly.
