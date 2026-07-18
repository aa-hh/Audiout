# AirPlayEngine

## Purpose

A standalone SwiftPM package (sibling of, not a target inside,
`AudioutedCore`) vendoring OwnTone's AirPlay 2 sender under
`Sources/CAirPlayEngine/`, wrapped in a neutral Swift `async`/`await` API.
Separate on purpose: it knows nothing about `Device`, groups, or the UI — a
session-primitives actor, not app logic — and it is a **licensing boundary**,
vendoring GPL/MIT/BSD source under per-license subdirectories. Discovery is
app-owned: no mDNS browse here, only resolved `DeviceDescriptor`s fed in.

## Rules

- **One engine thread, one `event_base`, no exceptions.** The vendored
  cluster assumes a single libevent base owned by a single thread; every call
  into it goes through `EngineThread.run`/`.enqueue`, never a raw C entry
  point.
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
