# dev/

## Purpose

Offline development tooling for working on the app without real AirPlay
speakers, plus `dev/notes/`, the home for pre-implementation research briefs.
It ships nothing.

## Rules

- Target `MockBackend` for UI and control work; a fake speaker only exercises AirPlay 1 framing.
- At most one fake speaker really runs, because the build ignores the port setting; add no retry loop.
- macOS's own AirPlay Receiver squats on port 5000 too, so check it before blaming the script.
- `.run/` is generated state: safe to delete, never hand-edit and never commit.
- Real AirPlay 2 sync cannot be faked locally; it needs real hardware or a second host.
- The native backend is a real sender: it opens sockets and needs a genuine TCC grant.
- Read the relevant brief in `notes/` before related implementation work, rather than re-deriving it.
- Long-form traps, dated decisions and the changelog: [AGENTS-HISTORY.md](AGENTS-HISTORY.md). Grep it before debugging anything here.

## Map

- `fake-speakers.sh` → launches fake receivers, with the single-instance limit above.
- `stop-fake-speakers.sh` → kills every process tracked by a pidfile.
- `audiocap/` → standalone Core Audio process-tap capture CLI.
- `phase-spike/` → throwaway phase-lock measurement harness.
- `spikes/` → older one-off experiments kept for reference.
- `notes/` → research briefs; per-file index in AGENTS-HISTORY.md
- `README.md` → setup and rationale for the mock, fake-speaker and native backends.
