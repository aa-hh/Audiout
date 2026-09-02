# EngineProbeParsing

## Purpose

Owns the argument grammar for `engine-probe`, split into a library purely so
it can be unit-tested. Pure Foundation string parsing: it opens no sockets,
prints nothing, and knows no engine types.

## Rules

- A device slot completes only once it has both an address and a device id.
- Per-device flags amend the slot in progress in any order; committing early once split one device into two.
- Per-device options given before the first address edit the defaults template, not device zero.
- Anything ambiguous lands in the problems list; this library never exits or prints, so callers must check it.
- The help text and the grammar comments must stay in lockstep, because the help text is the spec.
- Long-form traps, dated decisions and the changelog: [AGENTS-HISTORY.md](AGENTS-HISTORY.md). Grep it before debugging anything here.

## Map

- `ProbeDevice` → one output device as described by the command line.
- `ProbeArgs` → the full parse result, including the problems list.
- `parseProbeArgs` → entry point turning arguments into that result.
- `usage` → the help text, and the ordering spec for the grammar.
