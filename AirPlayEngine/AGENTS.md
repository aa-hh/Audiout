# AirPlayEngine

## Purpose

A standalone SwiftPM package (sibling of, not a target inside,
`AudioutCore`) vendoring OwnTone's AirPlay 2 sender under
`Sources/CAirPlayEngine/`, wrapped in a neutral Swift `async`/`await` API.
Separate on purpose: it knows nothing about `Device`, groups, or the UI — a
session-primitives actor, not app logic — and it is a **licensing boundary**,
vendoring GPL/MIT/BSD source under per-license subdirectories. Discovery is
app-owned: no mDNS browse here, only resolved `DeviceDescriptor`s fed in.

## Rules

- One engine thread at a time, one `event_base` — recreatable, not reusable.
  All calls funnel through `EngineThread.run`/`.enqueue`, never a raw C entry
  point, since the vendored cluster assumes a single libevent base on a
  single thread. `Thread.start()` on an already-started thread aborts, so
  `start()` builds a fresh `EngineThread` each time; `stop()` clears it and
  calls `outputs_registry_clear()` so the next start begins clean.
- `EngineThread.enqueue` returns `Bool`, `run` throws — never assume work
  ran. A dropped continuation (base gone, or a once-event the broken loop
  never fires) hangs the caller forever, so `enqueue` reports scheduling
  failure, `run` fail-fasts, and `stop()` sweeps pending work with a
  deadlined join rather than spinning.
- The sender hosts N independent content streams on one thread, via a
  `stream_id` dimension added to the vendored master-session lookup and
  `airplay_write` fan-out (per-app routing needs one stream per
  destination-set). Defaults to 0 (legacy single-stream behavior unchanged).
  Vendored surgery, not a shim — see `docs/VENDORED-DIFFS.md` Entry 2.
- `WriteBacklogGuard` self-heals; it never gates in `enqueue`. Per-stream
  backpressure cap on `write(streams:pts:)`, `nonisolated`/`NSLock`-guarded;
  the reservation releases only when the write body actually drains on the
  engine thread, never merely when `enqueue` returns `true` — the one
  genuinely unbounded-growth path in this layer if the engine thread stalls.
- **Suspect the hosting/shim layer before the vendored protocol code.**
  Real-hardware bugs have consistently been an application-layer duty
  OwnTone's `main()`/player performed that the hosting code hadn't
  replicated — see `docs/first-light-report.md` for the diagnostic method.
- **Vendored sources are edited only as a last resort**, minimally, marked
  with a dated `[AirPlayEngine vendored change …]` comment, any exception
  ledgered in `docs/VENDORED-DIFFS.md` — otherwise byte-identical, so
  upstream diffs stay legible. Prefer fixing `shims/` or the Swift layer.
- **Firewall verdicts stick to already-bound sockets.** Allowlist the binary
  *before* it binds, or PTP is silently dropped — session succeeds, receiver
  stays silent.
- The engine is a PTP deferred client, never a PTP binder. `shims/ptpd.c`
  only calls `airptp_daemon_find()` — binding UDP 319/320 belongs solely to
  the separate `ptp-helper` root daemon (`docs/ptp-helper-design.md`). The
  clock lookup happens per-session at connect time, not at engine startup,
  keeping PTP ports free when idle so macOS's own AirPlay can coexist.
  `AUDIOUT_PTP_INPROC_BIND=1` restores the old in-process bind as a
  dev/CI-only fallback — never rely on it shipped.
- Two sender backends share one registry. `sender/raop.c` (AirPlay 1) is
  vendored alongside `sender/airplay.c` (AirPlay 2); `NativeBackend` drives
  AP1 receivers through the same engine surface as AP2 — `addOutput`,
  volume, mute, select all apply. `supportsAirPlay2 == false` means only "no
  perfect multi-room sync," not an unsupported gate. See
  `docs/raop-seam-brief.md`. (C-dispatch mechanics stay in CAirPlayEngine's
  file only.)

## Map

| Name | What it is |
|---|---|
| `AirPlayEngine` (actor) | Public Swift session API. |
| `EngineThread` | Owns the one `event_base` + OS thread. |
| `AirPlayTypes.swift` | Swift-facing types, incl. `DeviceDescriptor`, `OutputState`. |
| `CompletionRegistry` | Bridges C callback-id dispatcher to `async`/`await`. |
| `WriteBacklogGuard` | Per-stream backpressure cap on write(streams:pts:); see Rules. |
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
