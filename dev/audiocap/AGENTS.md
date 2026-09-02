# dev/audiocap

## Purpose

A standalone SwiftPM CLI that captures system audio through a Core Audio
process tap and writes raw PCM to a file, stdout or a FIFO. Deliberately
separate from the app: it targets a newer macOS and links nothing shipping.

## Rules

- The capture callback allocates, locks and logs nothing; conversion and writing happen on other threads.
- Teardown order is strict and each step is guarded, so the tap is destroyed last.
- Silent capture with bytes seen means a missing TCC grant, not a bug; the ad-hoc identity resets per build.
- The tap rate follows the default output device; a pipe consumer configured otherwise pitch-shifts silently.
- The usage-description string is baked in at link time, because a bare executable carries no Info.plist.
- Long-form traps, dated decisions and the changelog: [AGENTS-HISTORY.md](AGENTS-HISTORY.md). Grep it before debugging anything here.

## Map

- `TapEngine` → owns the tap lifecycle: create, aggregate, register, start, tear down.
- `RingBuffer` → lock-free ring between the realtime callback and writer threads.
- `WriterThread` → drains the ring to a file or stdout, tracking peak amplitude.
- `PipeWriterThread` → drains the ring, converts to signed 16-bit, writes the FIFO.
- `parseArgs` → hand-rolled parsing of the sink and target flags.
