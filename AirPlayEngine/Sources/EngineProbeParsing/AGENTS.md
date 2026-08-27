# EngineProbeParsing

## Purpose

Owns the argument grammar for `engine-probe` (`ProbeArgParsing.swift`): parses
`argv` into `ProbeArgs`/`ProbeDevice`, and owns `usage()`. Split out of the
`engine-probe` executable target purely so it can be unit-tested — code in an
`main.swift` can't be imported by a test target. This library has no
dependency on `AirPlayEngine` or any C target; it is pure `Foundation` string
parsing. Boundary: it does not open sockets, print anything, or know about
`AirPlayEngine` types (`DeviceDescriptor`, `OutputID`, etc.) — `engine-probe`'s
`main.swift` converts `ProbeDevice` into engine calls. Update this file when
the flag grammar changes (new per-device flags, changed commit rules) or
`ProbeArgs`/`ProbeDevice` gain or lose fields.

## Notable Patterns

- **Device-slot grammar**: a device slot is "complete" once it has both
  `--address` and `--device-id` (`ProbeDevice.isComplete`). Per-device flags
  (`--name`, `--port`, `--features`, `--model`, `--ipv6`, `--raop`,
  `--password`) amend the in-progress slot in any order until it's complete;
  the next per-device flag after that commits it and starts a new device.
  This exists because an earlier parser committed early on flag arrival,
  silently splitting one device into two during a live hardware run — see
  the file-header comment for the full incident and the full grammar rules.
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

## Tests

| File | Focus |
|---|---|
| `../../Tests/AirPlayEngineTests/EngineProbeParsingTests.swift` | Unit tests for `parseProbeArgs` against the device-slot grammar (single/multi-device ordering, defaults-before-first-address, incomplete-slot problems, `--raop`). |
