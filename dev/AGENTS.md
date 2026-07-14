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

## Files

| File | Role |
|---|---|
| [fake-speakers.sh](fake-speakers.sh) | Launches one or more `shairport-sync` processes as fake AirPlay-1 receivers (see single-instance caveat above). `SILENT=0` to hear audio instead of discarding it. |
| [stop-fake-speakers.sh](stop-fake-speakers.sh) | Kills every process tracked by a pidfile in `.run/` and cleans them up. |
| [README.md](README.md) | Full setup/usage/rationale for both dummy layers (in-app mock + shairport fake speaker). |
