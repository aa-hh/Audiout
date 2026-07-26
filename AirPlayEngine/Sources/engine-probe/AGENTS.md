# engine-probe

## Purpose

`engine-probe` is the gated, manual multi-device AirPlay session probe
(T-API-1, extended by T-ENG-MULTIROOM-CLI-1 and the `--raop` RAOP path). It
is a diagnostic executable a human runs later, by hand, against real
receivers — it drives one or more real `AirPlayEngine` sessions end-to-end
(discovery descriptor → `addOutput` → `setVolume` → pump one shared PCM file
to all outputs off one advancing pts → `stop`). It is built green by
`swift build`/CI (dry-run only) but is NEVER invoked by the build or by any
automated test — see the file-header comment for the three preconditions a
live run needs (real receiver(s), OwnTone/any PTP daemon stopped, a human
watching).

Keep this file up to date if the gate flag, the RAOP-vs-AirPlay2 TXT/descriptor
shape, or the PCM pacing scheme changes.

## Notable Patterns

- **Gate flag**: nothing opens a socket unless
  `--i-have-a-receiver-and-owntone-is-stopped` is passed. Without it, the CLI
  only parses args and prints the plan (exit 0). Never add a default that
  bypasses this gate.
- **Parse problems are fatal in every mode**, dry-run included: `ProbeArgs.problems`
  non-empty prints the plan + problems to stderr and exits 2 before the gate
  check even runs — so the exact command line for a later gated run can be
  validated un-gated first. See `EngineProbeParsing`'s AGENTS.md for the
  device-slot grammar that produces `problems`.
- **RAOP vs AirPlay 2 descriptor shape differs deliberately**: for
  `.airplay`, the TXT record carries `deviceid`/`features`/`model`; for
  `.raop`, the device ID is encoded into the mDNS-style instance `name` as
  `<hex-id-no-colons>@<name>` (mirroring how `raop_device_cb` in vendored
  `raop.c` re-derives the id), TXT carries only `deviceid` (kept in sync with
  `name` for the engine's own `OutputID` bookkeeping) and `tp: "UDP"`, and
  never `features`/`model`. Do not "flip a kind flag" on an otherwise
  AirPlay-2-shaped descriptor — a real RAOP receiver rejects that shape.
- **PCM pacing**: `runLiveSession` pumps 352-sample chunks against a
  CALCULATED clock (`samples/sampleRate` since start), not the actual
  wall clock, because `airplay.c`'s `timestamp_set()` prefers a calculated
  clock the same way OwnTone's player does — a frozen/wrong pts makes the
  receiver keep the session but schedule no audible audio (this was the
  2026-07-16 first-light failure mode).

## External Dependencies

| Dependency | Usage |
|---|---|
| `AirPlayEngine` | The engine driven by `runLiveSession` (`start`, `updateDiscovery`, `addOutput`, `setVolume`, `write`, `stop`). |
| `EngineProbeParsing` | Supplies `parseProbeArgs`, `usage()`, `ProbeArgs`/`ProbeDevice` — all argv handling lives there, not in `main.swift`. |

## Tests

No test files target this executable directly (executables can't be
imported by a test target). Its argument-parsing logic is covered indirectly
via `EngineProbeParsing`'s own tests — see
`../EngineProbeParsing/AGENTS.md`.
