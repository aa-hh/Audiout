# AGENTS.md history: AirPlayEngine/Sources/EngineProbeParsing

Archived verbatim from AGENTS.md on 2026-09-02 when that file was trimmed to the root rule (three sections, at most 300 words). Not maintained: symbols named below may no longer exist. Orientation lives in AGENTS.md; grep this file for the long form of a trap, the dated decisions, and the changelog.

---

# EngineProbeParsing

## Purpose

Owns the argument grammar for `engine-probe` (`ProbeArgParsing.swift`): parses
`argv` into `ProbeArgs`/`ProbeDevice`, and owns `usage()`. Split out of the
`engine-probe` executable target purely so it can be unit-tested — code in an
`main.swift` can't be imported by a test target. This library has no
dependency on `AirPlayEngine` or any C target; it is pure `Foundation` string
parsing. Boundary: it does not open sockets, print anything, or know about
`AirPlayEngine` types (`DeviceDescriptor`, `OutputID`, etc.) — `engine-probe`'s
`main.swift` converts `ProbeDevice` into engine calls.

Keep this file up to date when the flag grammar changes (new per-device flags,
changed commit rules) or when `ProbeArgs`/`ProbeDevice` gain/lose fields.

## Notable Patterns

- **Device-slot grammar**: a device slot is "complete" once it has both
  `--address` and `--device-id` (`ProbeDevice.isComplete`). Per-device flags
  (`--name`, `--port`, `--features`, `--model`, `--ipv6`, `--raop`,
  `--password`) amend the in-progress slot in any order until it's complete;
  the next per-device flag after that commits it and starts a new device.
  This exists because an earlier parser committed early on flag arrival,
  silently splitting one device into two on a 2026-07-17 live run — see the
  file-header comment for the full incident and the full grammar rules.
- **Defaults vs. in-progress slot**: per-device options given *before* the
  first `--address` edit `defaults` (the template every later slot starts
  from), not just device 0. `--device-id` is never a default.
- **Loud-not-silent errors**: anything ambiguous (an incomplete slot
  committed, trailing per-device flags with no address, an unknown flag) is
  appended to `ProbeArgs.problems` rather than dropped or guessed. Callers
  (`engine-probe`) must check `problems` and refuse to run — this library
  itself never exits or prints.
- `usage()` and the grammar comments in `ProbeArgParsing.swift` must be kept
  in lockstep — the doc claims are what `engine-probe --help` prints.

## Key Types

| Type | Role |
|---|---|
| `ProbeDevice` | One output device as described by the command line (address, port, device ID, features, model, ipv6, password, raop). |
| `ProbeArgs` | Full parse result: `devices`, `pcmPath`, `gated`, `wantsHelp`, and the `problems` diagnostic list. |
| `parseProbeArgs(_:)` | Entry point; turns `argv` into `ProbeArgs` per the device-slot grammar above. |
| `usage()` | Returns the CLI's help text (also the ordering/grouping spec for the grammar). |

## Tests

| File | Focus |
|---|---|
| `../../Tests/AirPlayEngineTests/EngineProbeParsingTests.swift` | Unit tests for `parseProbeArgs` against the device-slot grammar (single/multi-device ordering, defaults-before-first-address, incomplete-slot problems, `--raop`). |
