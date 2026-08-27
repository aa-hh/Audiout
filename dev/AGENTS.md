# dev/

## Purpose

Offline development tooling for working on the app without real AirPlay
speakers, plus `dev/notes/`, home for pre-implementation research briefs.
Owns the *optional* real-wire sanity check (a shairport-sync fake receiver) —
not the primary offline tool, which is the in-app `MockBackend` in
`../AudioutCore`. Full setup docs live in `README.md`.

## Rules

- **Target `MockBackend` for UI/control work, not a fake speaker.** The fake
  speaker only exercises Classic AirPlay-1 wire framing; multi-device, group,
  and sync testing is the mock backend's job.
- **At most one fake speaker will actually run.** `fake-speakers.sh` assigns
  a distinct port per instance, but the installed shairport-sync build
  ignores the port setting in Classic mode and binds `:5000` regardless —
  every instance past the first dies "Address already in use." Known
  upstream limitation; don't add retry/backoff to work around it.
- **macOS's own AirPlay Receiver squats on `:5000` too.** If a fake speaker's
  health check reports it died, check AirDrop & Handoff ▸ AirPlay Receiver is
  off before suspecting the script.
- **`.run/` is generated, gitignored state** — safe to delete, never
  hand-edit or commit it.
- **Real AirPlay 2 (PTP sync) cannot be faked locally.** The `native` backend
  binds privileged PTP ports 319/320, fighting OwnTone's own PTP daemon on
  the same machine — needs real hardware or a second host.
- **`native` is a real sender, not a dummy layer.** `AIRPLAY_BACKEND=native`
  opens actual sockets and needs a real TCC grant; not for casual offline
  dev — see `README.md`'s "Layer 3" and `notes/p2b-nativebackend-runbook.md`.
- **Read the relevant `notes/` brief before related implementation work** —
  briefs de-risk a phase before code is written; don't re-derive it.

## Map

| Name | What it is |
|---|---|
| `fake-speakers.sh` | Launches shairport-sync fake receivers (single-instance caveat above). |
| `stop-fake-speakers.sh` | Kills every process tracked by a pidfile in `.run/`. |
| `audiocap/` | Standalone Core Audio process-tap capture CLI; own `AGENTS.md`. |
| `phase-spike/` | Standalone phase-lock feasibility harness; own `AGENTS.md`. |
| `README.md` | Setup/rationale for the mock, fake-speaker, and `native` backends. |
| `notes/` | Pre-implementation research briefs, one per initiative; see filenames. |
