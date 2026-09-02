# AirPlayEngine

## Purpose

A standalone SwiftPM package vendoring OwnTone's AirPlay 2 sender behind a
neutral async Swift API. It knows nothing about devices, groups or the UI, and
it is a licensing boundary. Discovery is app-owned.

## Rules

- One engine thread and one event base; a thread is single-use, so each start builds a fresh one.
- `EngineThread.enqueue` reports whether it scheduled and `run` throws; never assume the work ran.
- One thread hosts N content streams through a `stream_id` dimension; that is vendored surgery, ledgered.
- Suspect the hosting and shim layer before the vendored protocol code, as every real bug has been.
- Vendored sources change only as a last resort, marked in place and ledgered as an exception.
- `engine-probe` refuses to open a socket without its explicit flag; never default that gate away.
- Firewall verdicts stick to already-bound sockets: allowlist the binary before it binds, or PTP dies silently.
- The engine is a deferred PTP client, never a binder; the root helper owns the privileged bind.
- Two sender backends share one registry, and AirPlay 1 is not an unsupported gate.
- Long-form traps, dated decisions and the changelog: [AGENTS-HISTORY.md](AGENTS-HISTORY.md). Grep it before debugging anything here.

## Map

- [AirPlayEngine](Sources/AirPlayEngine/AGENTS.md) → Swift host layer
- [CAirPlayEngine](Sources/CAirPlayEngine/AGENTS.md) → vendored C cluster
- [EngineProbeParsing](Sources/EngineProbeParsing/AGENTS.md) → probe output parsing
- [PTPHelperTestSupport](Sources/PTPHelperTestSupport/AGENTS.md) → test-only C bridge
- [engine-probe](Sources/engine-probe/AGENTS.md) → gated live CLI
- [ptp-helper](Sources/ptp-helper/AGENTS.md) → privileged root daemon
- `docs/` → design docs; per-file index in AGENTS-HISTORY.md
