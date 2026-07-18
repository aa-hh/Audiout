# AirPlayEngine

## Purpose

A standalone SwiftPM package (sibling of, not a target inside,
`AudiouterCore`) vendoring OwnTone's AirPlay 2 sender under
`Sources/CAirPlayEngine/`, wrapped in a neutral Swift `async`/`await` API.
Separate on purpose: it knows nothing about `Device`, groups, or the UI — a
session-primitives actor, not app logic — and it is a **licensing boundary**,
vendoring GPL/MIT/BSD source under per-license subdirectories. Discovery is
app-owned: no mDNS browse here, only resolved `DeviceDescriptor`s fed in.

## Rules

- **One engine thread at a time, one `event_base`, no exceptions —
  recreatable, not reusable.** The vendored cluster assumes a single libevent
  base owned by a single thread; every call into it goes through
  `EngineThread.run`/`.enqueue`, never a raw C entry point. A given
  `EngineThread`/`Thread` is single-use (a second `Thread.start()` aborts), so
  `AirPlayEngine.start()` constructs a FRESH `EngineThread` per start and holds
  it in `EngineThreadHolder`; `stop()` clears it and `outputs_registry_clear()`
  empties the C device/callback registry so the next start begins clean.
- **`EngineThread.enqueue` returns `Bool` and `run` throws — never assume work
  ran.** A closure carrying a continuation that is dropped (base gone, or a
  once-event the broken loop never fired) freezes the caller forever, which is
  why `enqueue` reports scheduling failure, `run` fail-fasts, `stop()` sweeps
  the tracked-pending list, and its join is deadlined rather than spun.
- **The sender hosts N independent content streams inside that one thread**,
  via a `stream_id` dimension added to the vendored master-session lookup and
  the `airplay_write` fan-out (per-app routing needs one stream per
  destination-set, not one PCM feed for the whole process). `stream_id`
  defaults to 0 (pre-existing single-stream behavior unchanged). This is
  vendored surgery, not a shim — see `docs/VENDORED-DIFFS.md` Entry 2 for the
  rationale and exact hunk. Swift-side: `AirPlayEngine.addOutput(_:streamId:)`
  / `write(pcm:streamId:pts:)` / `write(streams:pts:)`.
- **Suspect the hosting/shim layer before the vendored protocol code.**
  Real-hardware bugs have consistently been an application-layer duty
  OwnTone's `main()`/player performed that the hosting code hadn't
  replicated — see `docs/first-light-report.md` for the diagnostic method.
- **Vendored sources are edited only as a last resort**, minimally, marked
  with a dated `[AirPlayEngine vendored change …]` comment, any exception
  ledgered in `docs/VENDORED-DIFFS.md` — otherwise byte-identical, so
  upstream diffs stay legible. Prefer fixing `shims/` or the Swift layer.
- **`engine-probe` refuses to open a socket without an explicit flag**
  (`--i-have-a-receiver-and-owntone-is-stopped`): needs a real receiver, OwnTone's
  PTP daemon stopped (port 319/320 contention), a human present. Never
  default this gate away.
- **Firewall verdicts stick to already-bound sockets.** Allowlist the binary
  *before* it binds, or PTP is silently dropped — session succeeds, receiver
  stays silent.
- **Not fully wired into the app.** Check `NativeBackend` and
  `../dev/notes/p2b-nativebackend-seam-brief.md` before assuming closed.

## Map

| Name | What it is |
|---|---|
| `AirPlayEngine` (actor) | Public Swift session API. |
| `EngineThread` | Owns the one `event_base` + OS thread. |
| `AirPlayTypes.swift` | Swift-facing types, incl. `DeviceDescriptor`, `OutputState`. |
| `CompletionRegistry` | Bridges C callback-id dispatcher to `async`/`await`. |
| `Sources/CAirPlayEngine/` | Vendored+shimmed C cluster. |
| `Sources/engine-probe/` | Gated one-device live-session CLI. |
| `docs/seam-map.md` | Extraction blueprint, authoritative. |
| `docs/first-light-report.md` | Live-hardware-test ledger, diagnostic method. |
| `docs/VENDORED-DIFFS.md` | Exceptions to byte-identical vendored C. |
| `docs/license-inventory.md`, `README.md` | Per-file license inventory; build/package-layout story. |
