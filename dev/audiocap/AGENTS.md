# dev/audiocap

## Purpose

Standalone SwiftPM CLI that captures system audio via a Core Audio process tap
(macOS 14.4+) and writes raw PCM to a file, stdout, or a named FIFO. Feeds the
capture→OwnTone pipeline (`--pipe` mode); see `../notes/0e-taps-brief.md` and
`../notes/0f-pipe-brief.md` for the design briefs this implements.

**Relationship to production code:** standalone — deliberately separate from
`AudioutCore`, which pins `.macOS(.v14)`; this package targets
`.macOS("14.4")` because process taps need 14.2+/14.4-public. Not linked by
and does not link the main app; see README.md for the verification procedure.

## Notable Patterns

- **Realtime-safety discipline**: the IOProc block in `TapEngine.startCapture`
  does no allocation, locking, or logging — only pointer bumps into a
  preallocated scratch buffer, then a lock-free `RingBuffer.write`. S16LE
  conversion (`PipeWriter.swift`) and all I/O happen on separate writer threads.
- **Strict teardown order** (`TapEngine.teardown`): tap destroyed last, and
  every step is guarded so a failure doesn't skip later steps.
- **TCC grant resets on rebuild**: ad-hoc/linker-signed binary, so its TCC
  identity resets after every `swift build`. Silent capture (peak 0, nonzero
  `inputBytesSeen`) signals a missing grant, not a bug — the tool detects and
  prints it. Reset via unscoped `tccutil reset AudioCapture` (the
  bundle-id-scoped form doesn't match this binary's TCC identity).
- **Sample-rate config-follows-tap**: the tap rate follows the current default
  *output* device (not always 48 kHz — 44100 Hz observed here) and is never
  assumed; `--pipe` mode requires OwnTone's `pipe_sample_rate` to match
  exactly or playback is silently pitch-shifted (no autodetect, no resampler).
- **`dev/audiocap/object`** is an empty stray file at the package root, not a
  source or build artifact of note.

## Key Types

| Type | Role |
|---|---|
| `TapEngine` | Owns the tap lifecycle: create → configure → start; strict teardown order. |
| `RingBuffer` | Lock-free SPSC ring buffer between the IOProc and writer threads. |
| `WriterThread` (`main.swift`) | Drains the ring to `--out`/`--stdout`; tracks peak for the silence check. |
| `PipeWriterThread` | Drains the ring, converts to S16LE, writes to the OwnTone FIFO. |
| `Options` / `parseArgs` (`main.swift`) | Hand-rolled argument parsing for sinks and capture targets. |

## Tests

No XCTest target. `--selftest` (`SelfTest.swift`) checks the Float32→S16LE
conversion headlessly — no TCC grant or audio device needed. End-to-end
capture correctness (per-app tap, `--exclude`, non-silence) is verified
manually via the tone-injection and plain-capture procedures in README.md —
both require a live TCC grant and aren't automatable headlessly.
