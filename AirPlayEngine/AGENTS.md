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
- **The engine is a PTP deferred client, never a PTP binder.** `shims/ptpd.c` only calls
  `airptp_daemon_find()` — the shipped default never binds UDP 319/320 itself;
  that privileged bind belongs solely to the separate `ptp-helper` root daemon
  (see `docs/ptp-helper-design.md` §1.3, §5.1; Waves 1–2 PLAN). **The clock lookup is
  deferred per-session** (T4: `ptpd_daemon_probe()` at connect time), not at engine
  startup. This keeps the PTP ports free when idle, enabling coexistence with macOS's
  own AirPlay. `AUDIOUTER_PTP_INPROC_BIND=1` restores the old in-process bind as a
  **dev/CI-only** fallback — never rely on it in the shipped path.
- **Two sender backends share one registry.** `sender/raop.c` (classic
  AirPlay 1 / RAOP) is vendored alongside `sender/airplay.c` (AirPlay 2) as a
  second `struct output_definition` (`output_raop`); `shims/outputs.c`'s
  `backend_for(device->type)` dispatches every per-device op to whichever one
  owns the device, and `outputs_write` broadcasts to both (each self-filters
  its own session list). `NativeBackend` drives AP1 receivers through this
  same engine surface as AP2 — `addOutput`, volume, mute, select all apply;
  `supportsAirPlay2 == false` only means "no perfect multi-room sync", it is
  not an unsupported gate. See `docs/raop-seam-brief.md` for the port design
  and `docs/VENDORED-DIFFS.md` Entry 3 for the one vendored `raop.c` diff.

## Map

| Name | What it is |
|---|---|
| `AirPlayEngine` (actor) | Public Swift session API. |
| `EngineThread` | Owns the one `event_base` + OS thread. |
| `AirPlayTypes.swift` | Swift-facing types, incl. `DeviceDescriptor`, `OutputState`. |
| `CompletionRegistry` | Bridges C callback-id dispatcher to `async`/`await`. |
| `WriteBacklogGuard` | Per-stream, time-based backpressure cap on `write(streams:pts:)` (`nonisolated`, `NSLock`-guarded — the write path never hops the actor executor). Admits/drops audio-seconds against a fixed cap (`maxInFlightAudioSeconds`); the reservation releases when the enqueued write body actually drains on the engine thread, never merely on `enqueue`'s `true` return — self-heals, never a one-shot trip. The one genuinely unbounded-growth path in this layer if the engine thread ever stalls; everything else here is confirmed bounded/symmetric. |
| `Sources/CAirPlayEngine/` | Vendored+shimmed C cluster. |
| `Sources/engine-probe/` | Gated one-device live-session CLI. |
| `Sources/ptp-helper/` (`ptp-helper` target) | Privileged root PTP daemon: binds 319/320, finds nothing. |
| `Clibairptp` target | `libairptp/` (MIT PTP clock lib) as its own SwiftPM target, shared by the helper and the engine's shim. |
| `docs/ptp-helper-design.md` | The helper's privilege-boundary design and packaging. |
| `docs/seam-map.md` | Extraction blueprint, authoritative. |
| `docs/raop-seam-brief.md` | RAOP (AirPlay 1) extraction blueprint, the seam-map's counterpart. |
| `docs/first-light-report.md` | Live-hardware-test ledger, diagnostic method. |
| `docs/VENDORED-DIFFS.md` | Exceptions to byte-identical vendored C. |
| `docs/license-inventory.md`, `README.md` | Per-file license inventory; build/package-layout story. |
