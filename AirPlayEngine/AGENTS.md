# AirPlayEngine

## Purpose

A standalone SwiftPM package (sibling of `AirPlayControllerCore`, not a
target inside it) that vendors OwnTone's AirPlay 2 sender — `airplay.c`,
`airplay_events.c`, `rtp_common.c`, `pair_ap`, `evrtsp`, `libairptp` — under
`Sources/CAirPlayEngine/`, replaces every OwnTone-plumbing dependency it used
to call with a thin shim we own (`Sources/CAirPlayEngine/shims/`), and wraps
the result in a neutral Swift `async`/`await` API (`Sources/AirPlayEngine/`).
The goal is an app that streams AirPlay 2 with **no OwnTone runtime
dependency**. See `README.md` for the full build/licensing/package-layout
story (PLAN-PHASE-2.md task history, shim inventory, brew dependencies) —
this file only covers what changes an agent's approach.

**Not yet wired into the app.** `AirPlayControllerCore`'s `OutputBackend`
protocol has no implementation backed by this package yet (`OwnToneBackend`
is what ships today) — that's `NativeBackend`, still to be written; see
`../dev/notes/p2b-nativebackend-seam-brief.md` for the gap analysis.

**Gated live test PASSED 2026-07-17** — the engine audibly played a real
AirPlay 2 speaker (Sonos, PTP timing) for the first time. Full ledger — six
hosting-layer bugs found and fixed, all forensic evidence, operational
gotchas, ranked follow-ups — is in `docs/first-light-report.md`. Read it
before debugging anything that looks like a repeat of a first-light symptom.

Keep this file up to date when: the Swift API surface changes,
`NativeBackend` starts consuming this package (link that milestone here),
or a new first-light-class issue is found and written up.

## Notable Patterns

- **One engine thread, one `event_base`, no exceptions.** The whole vendored
  cluster assumes a single libevent base owned by a single thread
  (`evbase_player`, a C global) — every call into the cluster, including
  `airplay_write()`, must run on that thread. `EngineThread` is the only
  thing that touches it; callers go through `EngineThread.run`/`.enqueue`,
  never a raw C entry point. See `docs/seam-map.md` §8 (risk R-B).
- **When the engine misbehaves, suspect the hosting/shim layer first, not
  the vendored protocol code.** Every one of the six first-light bugs
  (2026-07-17) was an application-layer duty OwnTone's `main()`/player used
  to perform that this package's hosting code didn't yet (libevent thread
  init, libgcrypt app-init, the privileged PTP bind, callback-terminal-state
  classification, write timestamp advancement, a volume-scaling unit bug) —
  never a bug in `sender/`, `pair_ap/`, `evrtsp/`, or `libairptp/` itself.
  `docs/first-light-report.md` has the full diagnostic method (compare
  against OwnTone's real `main.c`/`player.c`, verify with round-trip/counter
  instrumentation before touching vendored code).
- **Vendored sources (`sender/`, `evrtsp/`, `pair_ap/`, `libairptp/`) are
  edited only as a last resort**, minimally, and marked with a dated
  `[AirPlayEngine vendored change …]` comment (one example:
  `libairptp/src/ptp_msg_handle.c`, guarding a hard-coded debug `#define` so
  a build flag can enable it). Prefer fixing `shims/` or the Swift layer.
- **`engine-probe` refuses to open a socket without an explicit flag**
  (`--i-have-a-receiver-and-owntone-is-stopped`) — it needs a real receiver,
  OwnTone's PTP daemon stopped (port 319/320 contention), and a human
  present to confirm audio and stop the run. Never add a default that
  removes this gate. See `Sources/engine-probe/main.swift`'s header comment.
- **Firewall verdicts stick to already-bound sockets.** The macOS
  Application Firewall must allowlist the binary *before* it binds, or
  inbound PTP is silently dropped (session succeeds, receiver stays silent —
  the same trap Phase 0 hit with OwnTone). See `docs/first-light-report.md`
  "Operational gotchas."

## Key Types

| Type | Role |
|---|---|
| `AirPlayEngine` (actor) | The public Swift session API: `start()`/`addOutput`/`setVolume`/`write(pcm:pts:)`/`stop()`. `Sources/AirPlayEngine/AirPlayEngine.swift`. |
| `EngineThread` | Owns the one `event_base` + dedicated OS thread the vendored cluster requires; `run`/`enqueue` are the only ways in. `Sources/AirPlayEngine/EngineThread.swift`. |
| `AirPlayTypes` | Swift-facing types incl. `OutputState` and its terminal-state classification (`.connected` is terminal for `device_start` — see first-light bug #4). `Sources/AirPlayEngine/AirPlayTypes.swift`. |
| `CompletionRegistry` | Bridges the C async-completion dispatcher (`shims/outputs.c`'s callback-id registry) to Swift `async`/`await` continuations. `Sources/AirPlayEngine/CompletionRegistry.swift`. |
| `CAirPlayEngine` (C target) | The vendored+shimmed cluster itself — see README.md's package-layout diagram for the per-license subdirectory breakdown. |
| `engine-probe` | The gated one-device live-session CLI (`swift run engine-probe --help`); the artifact every first-light/regression test runs through. `Sources/engine-probe/main.swift`. |

## Folder Map

- `Sources/AirPlayEngine/` — the neutral Swift wrapper (see Key Types).
- `Sources/CAirPlayEngine/` — vendored sender/evrtsp/pair_ap/libairptp +
  our shims; see README.md for the license-boundary rationale.
- `Sources/engine-probe/` — the gated live-session CLI.
- `Tests/AirPlayEngineTests/` — see Tests below.
- `docs/` — `seam-map.md` (extraction blueprint, authoritative),
  `first-light-report.md` (the 2026-07-17 live-test ledger),
  `ptp-helper-design.md` (privileged PTP daemon design — see
  `../dev/notes/p2b-helper-productionization-brief.md` for the
  production-readiness review of it), `outputs-dispatcher-contract.md`
  (the callback-id/completion contract), `receiver-harness-guide.md`,
  `build-notes.md`, `license-inventory.md`.

## In-Progress Work

| Area | Status |
|---|---|
| `NativeBackend` | Not started. `../dev/notes/p2b-nativebackend-seam-brief.md` has the dependency-ordered checklist (discovery ownership has no code yet; capture-side integration needs a structural rewrite, not a port; no async device-state-change channel exists post-`addOutput`). |
| Per-app routing (multi-stream) | Architecture validated, not implemented — `../dev/notes/p2b-multistream-brief.md` recommends threading a real `stream_id` through the vendored quality/master-session match sites (one engine thread, one PTP clock, N content streams) over per-instance or per-process alternatives. |
| Synced local Core Audio output | Designed, not implemented — `../dev/notes/p2b-synced-local-brief.md`. |
| PTP helper (`SMAppService` daemon) | Designed (`docs/ptp-helper-design.md`); production install path reviewed and found to require a paid Apple Developer ID certificate — `../dev/notes/p2b-helper-productionization-brief.md`. Not urgent: development continues via `sudo`-run CLIs. |
| Post-first-light hardening | Ranked list in `docs/first-light-report.md`: teardown `SIGABRT` after `stop()`, unprotected `SIGPIPE`, no async channel for post-CONNECTED session failures, no write-cadence deficit detection, a hard-coded `libhash` constant (two installs on one LAN would collide). |

## Tests

| File | Focus |
|---|---|
| `AirPlayEngineAPITests.swift` | The Swift session API end-to-end against synthetic C callbacks — start/addOutput/setVolume/write/stop, terminal-state classification, volume percent mapping. |
| `OutputsDispatcherTests.swift` | The C callback-id dispatcher (`shims/outputs.c`) against `docs/outputs-dispatcher-contract.md`'s exactly-once-per-callback-id guarantee. |
| `ShimUnitTests.swift` | Individual shim units (conffile, logger, transcode/ALAC, etc.) in isolation. |
| `AirPlayEngineScaffoldTests.swift` | Package/target scaffold smoke test. |
