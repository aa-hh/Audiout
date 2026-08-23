# cast-spike

## Purpose

The roadmap 006 Phase-0 measurement CLI: connect to a Cast receiver, launch the
Default Media Receiver, serve it a 440 Hz sine from `SineSource`, and print how
long every step took. No capture, no encoding — the question is how a receiver
behaves, not what it plays. **Development only; not shipped in the app.**

## Rules

- **LICENSE-CLEAN.** All hand-rolled; no GPL/copyleft dependencies.
- **Exactly one mode per run:** `--list` browses for receivers, `--fake` runs
  against an in-process `FakeCastReceiver`, `--device` runs against real
  hardware. Anything else is a usage error.
- **`--fake` needs macOS 15** — the fake receiver's TLS identity is imported
  in-memory, which that release is the floor for.
- **Unbundled CLI, so no `NSBonjourServices` entry is needed.** Browsing works
  here and will not work from the bundled app until that key gains
  `_googlecast._tcp` — do not conclude discovery is fine from a green `--list`.
- **Output is fully buffered under a pipe.** Run it under a pty (`script -q
  /dev/null …`) or the log arrives in one lump at exit, which destroys the
  timings the tool exists to show.
- **`Retainer` is the only owner** of `FakeCastReceiver` and `CastSpikeRun`.
  A `let` inside a `switch` case dies at the end of that case and the objects
  hold their callbacks weakly, so the sockets go quiet with no error. Anything
  new that outlives its statement goes in the retainer too.

## Map

| Type | What it is |
|---|---|
| `Options` | Parsed arguments and the chosen mode. |
| `Exit` | The status a network callback hands back to the main thread. |
| `Once` | One-shot latch: the browse callback and its deadline race. |
| `Retainer` | Top-level strong references for the process lifetime. |
