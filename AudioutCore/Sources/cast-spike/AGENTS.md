# cast-spike

## Purpose

The roadmap 006 Phase-0 measurement CLI: connect to a Cast receiver, launch the
Default Media Receiver, serve it a 440 Hz sine from `SineSource`, and print how
long every step took. No capture, no encoding — the question is how a receiver
behaves, not what it plays. `--mirror` is the Cast Streaming spike: Opus over
RTP, measured with the built-in microphone. **Development only; not shipped in
the app.**

## Rules

- **LICENSE-CLEAN.** All hand-rolled; no GPL/copyleft dependencies.
- **Exactly one mode per run:** `--list` browses for receivers, `--fake` runs
  against an in-process `FakeCastReceiver`, `--device` runs against real
  hardware. Anything else is a usage error.
- **`--fake` needs macOS 15** — the fake receiver's TLS identity is imported
  in-memory, which that release is the floor for.
- **`Retainer` is the only owner** of `FakeCastReceiver` and `CastSpikeRun`.
  A `let` inside a `switch` case dies at the end of that case and the objects
  hold their callbacks weakly, so the sockets go quiet with no error. Anything
  new that outlives its statement goes in the retainer too.
- **`--mirror --mic` runs from a terminal:** the microphone prompt attributes
  to the terminal, and the embedded Info.plist exists only so the prompt
  appears at all.
- Long-form traps: [AGENTS-HISTORY.md](AGENTS-HISTORY.md).

## Map

| Type | What it is |
|---|---|
| `Options` | Parsed arguments and the chosen mode. |
| `Exit` | The status a network callback hands back to the main thread. |
| `Once` | One-shot latch: the browse callback and its deadline race. |
| `Retainer` | Top-level strong references for the process lifetime. |
| `MicArrivalRecorder` | Built-in mic capture, first sample dated on `CLOCK_MONOTONIC`. |
| `MirrorMeasurement` | Finds each probe in the recording; delay after pts. |
