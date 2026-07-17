# dev/

## Purpose

Offline development tooling for working on the app with no real AirPlay speakers.
This folder owns the *optional* real-wire sanity check (a shairport-sync fake
receiver); it does not own the primary offline tool, which is the in-app
`MockBackend` in [../AirPlayControllerCore](../AirPlayControllerCore/AGENTS.md).
Full human-facing docs (setup, rationale, troubleshooting) live in
[README.md](README.md) — read that before changing these scripts; this file only
adds what an agent needs to avoid re-discovering the gotchas below.

Keep this file up to date when: a script here is renamed/replaced, the
single-instance port limitation is fixed upstream (shairport-sync starts
honouring `-p`/`port` in Classic AirPlay mode), or a new dummy-setup layer is added.

## Notable Patterns

- **At most one fake speaker will actually run.** [fake-speakers.sh](fake-speakers.sh)
  generates a distinct RTSP port per named instance, but the installed
  shairport-sync 5.1 build ignores the port setting in Classic (AirPlay-1) mode and
  binds `:5000` regardless — so every instance past the first dies with "Address
  already in use." Don't "fix" this by adding retry/backoff logic; it's a known
  upstream limitation (verified 2026-07-13, see README.md). Multi-device/group/sync
  testing is the mock backend's job, not this script's.
- **macOS's own AirPlay Receiver squats on :5000 too.** If the health check in
  `fake-speakers.sh` reports the instance died, the first thing to check is System
  Settings ▸ General ▸ AirDrop & Handoff ▸ AirPlay Receiver — it must be off.
- **`.run/` is generated, gitignored state** (pidfiles, per-instance `.conf` files,
  logs) — safe to delete, never hand-edit or commit it.
- **Real AirPlay-2 (PTP sync) cannot be faked locally.** A source build with
  `--with-airplay-2` would fight the OwnTone sender for the privileged PTP ports
  319/320 on one machine. There is no local stand-in for this — it needs the real
  Sonos/AirPort Express hardware (or a second host).

## Folder Map

- [audiocap/](audiocap/README.md) — a standalone Core Audio process-tap
  capture CLI (proved out the Phase 0e capture layer; own README covers
  build/usage). Not the mock backend, not the fake-speaker script — a third,
  independent offline dev tool.
- [notes/](notes/) — **research briefs and phase write-ups**, this project's
  established home for pre-implementation research (see below) and
  phase-completion reports.

## Research briefs (`dev/notes/*-brief.md` / `*-research.md`)

This repo's pattern for de-risking a phase of work *before* writing code: a
research brief that reads the actual code/APIs involved, proposes an
approach, and ranks the walls likely to be hit — written to `dev/notes/` so
a future agent (fresh context, no chat history) can pick it up by file path
alone. **Read the relevant brief before starting related implementation
work; don't re-derive what's already there.** Naming loosely follows the
phase that motivated it (`0e-`/`0f-` = Phase 0 capture/e2e spikes, `p1-` =
Phase 1 UI, `p2-`/`p2b-` = Phase 2 engine and its sequels — see
`../PLAN-PHASE-2.md`).

Current briefs, newest first:

| Brief | Covers |
|---|---|
| [p2b-multistream-brief.md](notes/p2b-multistream-brief.md) | Whether the vendored AirPlay 2 sender can host multiple independent-content streams — the architectural unknown behind per-app routing. Recommends a localized `stream_id` addition over per-instance or per-process alternatives. |
| [p2b-nativebackend-seam-brief.md](notes/p2b-nativebackend-seam-brief.md) | Gap analysis: every `OutputBackend`/`OwnToneBackend` behavior the UI relies on vs. what `AirPlayEngine` provides today — the checklist for writing `NativeBackend`. |
| [p2b-helper-productionization-brief.md](notes/p2b-helper-productionization-brief.md) | Reviews `AirPlayEngine/docs/ptp-helper-design.md` against real `SMAppService`/codesign/firewall behavior. Flags that the sanctioned daemon-install path needs a paid Developer ID certificate. |
| [p2b-synced-local-brief.md](notes/p2b-synced-local-brief.md) | Core Audio design for the Mac's own speakers as a first-class, PTP-synced output ("play everywhere" — SPEC §8.1). |
| [p2b-v2-smallwork-brief.md](notes/p2b-v2-smallwork-brief.md) | Combined light brief for auto-reconnect and EQ/L-R balance (SPEC §3 v2) — neither needs new infrastructure. |
| [playback-meter-research.md](notes/playback-meter-research.md) | Level-meter design (`NSLevelIndicator` in the device row) — researched, not yet built. |
| [p1-owntone-api-brief.md](notes/p1-owntone-api-brief.md), [p1-menu-brief.md](notes/p1-menu-brief.md), [p1-cc-slider-research.md](notes/p1-cc-slider-research.md) | Phase 1 UI/API research (OwnTone JSON API, popover menu structure, Control-Center-style slider). |
| [0e-taps-brief.md](notes/0e-taps-brief.md), [0f-pipe-brief.md](notes/0f-pipe-brief.md), [p2-ptp-bind-probe.md](notes/p2-ptp-bind-probe.md) | Phase 0 capture/pipe/PTP-bind spikes. |

`AirPlayEngine/docs/first-light-report.md` (in that package, not here) is the
write-up for the 2026-07-17 gated live-hardware test — read it before
debugging anything that looks like a repeat of a first-light symptom.

## Files

| File | Role |
|---|---|
| [fake-speakers.sh](fake-speakers.sh) | Launches one or more `shairport-sync` processes as fake AirPlay-1 receivers (see single-instance caveat above). `SILENT=0` to hear audio instead of discarding it. |
| [stop-fake-speakers.sh](stop-fake-speakers.sh) | Kills every process tracked by a pidfile in `.run/` and cleans them up. |
| [README.md](README.md) | Full setup/usage/rationale for both dummy layers (in-app mock + shairport fake speaker). |
