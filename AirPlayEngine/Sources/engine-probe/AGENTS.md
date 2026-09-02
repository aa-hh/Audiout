# engine-probe

## Purpose

The gated, manual multi-device AirPlay session probe: a diagnostic executable
a human runs by hand against real receivers. It is built by CI but never
invoked by the build or by any automated test.

## Rules

- Nothing opens a socket without the explicit gate flag; never add a default that bypasses it.
- Parse problems are fatal in every mode, dry run included, so a command line can be validated ungated.
- The RAOP descriptor shape differs deliberately from AirPlay 2; a real receiver rejects a flipped flag.
- PCM is paced against a calculated clock, not the wall clock, or the receiver schedules no audible audio.
- Long-form traps, dated decisions and the changelog: [AGENTS-HISTORY.md](AGENTS-HISTORY.md). Grep it before debugging anything here.

## Map

- `main.swift` → the whole executable: argument handling, then one live session.
